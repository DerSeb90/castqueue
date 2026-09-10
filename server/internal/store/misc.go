package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

// ---- devices / tokens ----

func hashToken(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

// CreateDevice registers a device and returns (device, plain token).
func (s *Store) CreateDevice(ctx context.Context, name string) (Device, string, error) {
	token := RandomToken()
	now := Now()
	d := Device{ID: NewID(), Name: name, CreatedAt: now, LastSeenAt: now}
	_, err := s.db.ExecContext(ctx, `INSERT INTO devices(id, name, token_hash, created_at, last_seen_at) VALUES (?,?,?,?,?)`,
		d.ID, d.Name, hashToken(token), FormatTime(now), FormatTime(now))
	return d, token, wrap("create device", err)
}

// DeviceByToken looks up a device by bearer token and touches last_seen_at
// (at most once per minute).
func (s *Store) DeviceByToken(ctx context.Context, token string) (Device, error) {
	var d Device
	var created, seen string
	err := s.db.QueryRowContext(ctx, `SELECT id, name, created_at, last_seen_at FROM devices WHERE token_hash = ?`, hashToken(token)).
		Scan(&d.ID, &d.Name, &created, &seen)
	if errors.Is(err, sql.ErrNoRows) {
		return d, ErrNotFound
	}
	if err != nil {
		return d, wrap("device by token", err)
	}
	d.CreatedAt, _ = ParseTime(created)
	d.LastSeenAt, _ = ParseTime(seen)
	if time.Since(d.LastSeenAt) > time.Minute {
		d.LastSeenAt = Now()
		_, _ = s.db.ExecContext(ctx, `UPDATE devices SET last_seen_at = ? WHERE id = ?`, FormatTime(d.LastSeenAt), d.ID)
	}
	return d, nil
}

func (s *Store) ListDevices(ctx context.Context) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, name, created_at, last_seen_at FROM devices ORDER BY last_seen_at DESC`)
	if err != nil {
		return nil, wrap("list devices", err)
	}
	defer rows.Close()
	out := []Device{}
	for rows.Next() {
		var d Device
		var created, seen string
		if err := rows.Scan(&d.ID, &d.Name, &created, &seen); err != nil {
			return nil, err
		}
		d.CreatedAt, _ = ParseTime(created)
		d.LastSeenAt, _ = ParseTime(seen)
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Store) DeleteDevice(ctx context.Context, id string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM devices WHERE id = ?`, id)
	if err != nil {
		return wrap("delete device", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// ---- stream token ----

const kvStreamToken = "stream_token"

func (s *Store) StreamToken(ctx context.Context) (string, error) {
	t, err := s.getKV(ctx, s.db, kvStreamToken, "")
	if err != nil {
		return "", err
	}
	if t == "" {
		return s.RotateStreamToken(ctx)
	}
	return t, nil
}

func (s *Store) RotateStreamToken(ctx context.Context) (string, error) {
	t := RandomToken()
	if err := s.setKV(ctx, s.db, kvStreamToken, t); err != nil {
		return "", err
	}
	// stream_url of every auth podcast episode changes
	now := FormatTime(Now())
	_, _ = s.db.ExecContext(ctx, `UPDATE episodes SET updated_at = ? WHERE podcast_id IN (SELECT id FROM podcasts WHERE auth_username != '' OR auth_password != '')`, now)
	return t, nil
}

// ---- settings ----

const kvSettings = "settings"

func DefaultSettings(refreshMinutes int) Settings {
	return Settings{AutoRemovePlayed: true, RefreshIntervalMinutes: refreshMinutes, AutoEnqueueDefault: true}
}

func (s *Store) GetSettings(ctx context.Context, def Settings) (Settings, error) {
	raw, err := s.getKV(ctx, s.db, kvSettings, "")
	if err != nil || raw == "" {
		return def, err
	}
	st := def
	if err := json.Unmarshal([]byte(raw), &st); err != nil {
		return def, nil
	}
	if st.RefreshIntervalMinutes < 1 {
		st.RefreshIntervalMinutes = def.RefreshIntervalMinutes
	}
	return st, nil
}

func (s *Store) SaveSettings(ctx context.Context, st Settings) error {
	raw, err := json.Marshal(st)
	if err != nil {
		return err
	}
	return s.setKV(ctx, s.db, kvSettings, string(raw))
}

// ---- sync ----

const maxEpisodesPerPodcastFullSync = 300

func (s *Store) Sync(ctx context.Context, since time.Time, settings Settings) (SyncDelta, error) {
	// server_time is taken a little in the past so that writes racing this read
	// are picked up by the next delta (duplicates are harmless).
	d := SyncDelta{ServerTime: Now().Add(-2 * time.Second), Settings: settings}
	err := s.tx(ctx, func(tx *sql.Tx) error {
		var err error
		if since.IsZero() {
			if d.Podcasts, err = s.queryPodcasts(ctx, tx, `ORDER BY p.title COLLATE NOCASE`); err != nil {
				return err
			}
			d.PodcastsDeleted, d.EpisodesDeleted = []string{}, []string{}
			d.Episodes = []Episode{}
			for _, p := range d.Podcasts {
				eps, err := s.queryEpisodes(ctx, tx, `WHERE e.podcast_id = ? ORDER BY e.published_at DESC LIMIT ?`, p.ID, maxEpisodesPerPodcastFullSync)
				if err != nil {
					return err
				}
				d.Episodes = append(d.Episodes, eps...)
			}
			// queued episodes might be older than the cap → include them too
			ids, err := s.queueIDs(ctx, tx)
			if err != nil {
				return err
			}
			have := map[string]bool{}
			for _, e := range d.Episodes {
				have[e.ID] = true
			}
			var missing []string
			for _, id := range ids {
				if !have[id] {
					missing = append(missing, id)
				}
			}
			if len(missing) > 0 {
				eps, err := s.queryEpisodes(ctx, tx, `WHERE e.id IN (`+placeholders(len(missing))+`)`, anySlice(missing)...)
				if err != nil {
					return err
				}
				d.Episodes = append(d.Episodes, eps...)
			}
		} else {
			ts := FormatTime(since)
			if d.Podcasts, err = s.queryPodcasts(ctx, tx, `WHERE p.updated_at > ? ORDER BY p.title COLLATE NOCASE`, ts); err != nil {
				return err
			}
			if d.Episodes, err = s.queryEpisodes(ctx, tx, `WHERE e.updated_at > ? ORDER BY e.published_at DESC`, ts); err != nil {
				return err
			}
			if d.PodcastsDeleted, err = s.tombstones(ctx, tx, "podcast", ts); err != nil {
				return err
			}
			if d.EpisodesDeleted, err = s.tombstones(ctx, tx, "episode", ts); err != nil {
				return err
			}
		}
		if d.Queue.Version, err = s.queueVersion(ctx, tx); err != nil {
			return err
		}
		d.Queue.EpisodeIDs, err = s.queueIDs(ctx, tx)
		return err
	})
	return d, err
}

func (s *Store) tombstones(ctx context.Context, q execer, kind, since string) ([]string, error) {
	rows, err := q.QueryContext(ctx, `SELECT id FROM tombstones WHERE kind = ? AND deleted_at > ?`, kind, since)
	if err != nil {
		return nil, wrap("tombstones", err)
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// PruneTombstones deletes tombstones older than maxAge.
func (s *Store) PruneTombstones(ctx context.Context, maxAge time.Duration) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM tombstones WHERE deleted_at < ?`, FormatTime(Now().Add(-maxAge)))
	return wrap("prune tombstones", err)
}
