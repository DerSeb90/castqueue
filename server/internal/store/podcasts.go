package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

const podcastCols = `p.id, p.feed_url, p.title, p.description, p.author, p.image_url, p.website,
 p.auto_enqueue, p.auth_username, p.auth_password, p.last_refreshed_at, p.last_error, p.etag, p.last_modified,
 (SELECT COUNT(*) FROM episodes e WHERE e.podcast_id = p.id), p.created_at, p.updated_at`

func scanPodcast(row interface{ Scan(...any) error }) (Podcast, error) {
	var p Podcast
	var autoEnq int
	var refreshed, created, updated string
	err := row.Scan(&p.ID, &p.FeedURL, &p.Title, &p.Description, &p.Author, &p.ImageURL, &p.Website,
		&autoEnq, &p.AuthUsername, &p.AuthPassword, &refreshed, &p.LastError, &p.ETag, &p.LastModified,
		&p.EpisodeCount, &created, &updated)
	if err != nil {
		return p, err
	}
	p.AutoEnqueue = autoEnq == 1
	p.LastRefreshedAt, _ = ParseTime(refreshed)
	p.CreatedAt, _ = ParseTime(created)
	p.UpdatedAt, _ = ParseTime(updated)
	return p, nil
}

func (s *Store) queryPodcasts(ctx context.Context, q execer, where string, args ...any) ([]Podcast, error) {
	rows, err := q.QueryContext(ctx, `SELECT `+podcastCols+` FROM podcasts p `+where, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Podcast{}
	for rows.Next() {
		p, err := scanPodcast(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) ListPodcasts(ctx context.Context) ([]Podcast, error) {
	return s.queryPodcasts(ctx, s.db, `ORDER BY p.title COLLATE NOCASE`)
}

func (s *Store) GetPodcast(ctx context.Context, id string) (Podcast, error) {
	p, err := scanPodcast(s.db.QueryRowContext(ctx, `SELECT `+podcastCols+` FROM podcasts p WHERE p.id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return p, ErrNotFound
	}
	return p, wrap("get podcast", err)
}

func (s *Store) GetPodcastByFeedURL(ctx context.Context, feedURL string) (Podcast, error) {
	p, err := scanPodcast(s.db.QueryRowContext(ctx, `SELECT `+podcastCols+` FROM podcasts p WHERE p.feed_url = ?`, feedURL))
	if errors.Is(err, sql.ErrNoRows) {
		return p, ErrNotFound
	}
	return p, wrap("get podcast by url", err)
}

// CreatePodcast inserts the podcast (ID/timestamps assigned here) and its initial
// episodes. Initial episodes are never auto-enqueued.
func (s *Store) CreatePodcast(ctx context.Context, p *Podcast, episodes []NewEpisode) error {
	now := Now()
	p.ID = NewID()
	p.CreatedAt, p.UpdatedAt, p.LastRefreshedAt = now, now, now
	return s.tx(ctx, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `INSERT INTO podcasts
			(id, feed_url, title, description, author, image_url, website, auto_enqueue, auth_username, auth_password,
			 last_refreshed_at, last_error, etag, last_modified, created_at, updated_at)
			VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
			p.ID, p.FeedURL, p.Title, p.Description, p.Author, p.ImageURL, p.Website, boolInt(p.AutoEnqueue),
			p.AuthUsername, p.AuthPassword, FormatTime(now), "", p.ETag, p.LastModified, FormatTime(now), FormatTime(now))
		if err != nil {
			return wrap("insert podcast", err)
		}
		_, err = s.upsertEpisodes(ctx, tx, p.ID, episodes, now)
		return err
	})
}

// UpdatePodcastMeta stores fields from a feed refresh and upserts episodes.
// Returns the IDs of newly inserted episodes (for auto-enqueue).
func (s *Store) ApplyRefresh(ctx context.Context, p Podcast, episodes []NewEpisode, fetchErr string) ([]string, error) {
	now := Now()
	var newIDs []string
	err := s.tx(ctx, func(tx *sql.Tx) error {
		if fetchErr != "" {
			_, err := tx.ExecContext(ctx, `UPDATE podcasts SET last_refreshed_at = ?, last_error = ?, updated_at = ? WHERE id = ?`,
				FormatTime(now), fetchErr, FormatTime(now), p.ID)
			return wrap("update podcast error", err)
		}
		_, err := tx.ExecContext(ctx, `UPDATE podcasts SET title = ?, description = ?, author = ?, image_url = ?, website = ?,
			last_refreshed_at = ?, last_error = '', etag = ?, last_modified = ?, updated_at = ? WHERE id = ?`,
			p.Title, p.Description, p.Author, p.ImageURL, p.Website, FormatTime(now), p.ETag, p.LastModified, FormatTime(now), p.ID)
		if err != nil {
			return wrap("update podcast", err)
		}
		newIDs, err = s.upsertEpisodes(ctx, tx, p.ID, episodes, now)
		if err != nil {
			return err
		}
		if p.AutoEnqueue && len(newIDs) > 0 {
			// oldest new episode first so the queue stays chronological
			for i := len(newIDs) - 1; i >= 0; i-- {
				if err := s.queueAdd(ctx, tx, newIDs[i], -1); err != nil {
					return err
				}
			}
			if err := s.bumpQueueVersion(ctx, tx); err != nil {
				return err
			}
		}
		return nil
	})
	return newIDs, err
}

// TouchRefresh marks an unchanged feed (304) as refreshed.
func (s *Store) TouchRefresh(ctx context.Context, id string) error {
	now := FormatTime(Now())
	_, err := s.db.ExecContext(ctx, `UPDATE podcasts SET last_refreshed_at = ?, last_error = '' WHERE id = ?`, now, id)
	return wrap("touch refresh", err)
}

type PodcastPatch struct {
	AutoEnqueue  *bool
	AuthUsername *string
	AuthPassword *string
	Title        *string
}

func (s *Store) PatchPodcast(ctx context.Context, id string, patch PodcastPatch) (Podcast, error) {
	p, err := s.GetPodcast(ctx, id)
	if err != nil {
		return p, err
	}
	if patch.AutoEnqueue != nil {
		p.AutoEnqueue = *patch.AutoEnqueue
	}
	if patch.AuthUsername != nil {
		p.AuthUsername = *patch.AuthUsername
	}
	if patch.AuthPassword != nil {
		p.AuthPassword = *patch.AuthPassword
	}
	if patch.Title != nil && *patch.Title != "" {
		p.Title = *patch.Title
	}
	now := Now()
	_, err = s.db.ExecContext(ctx, `UPDATE podcasts SET auto_enqueue = ?, auth_username = ?, auth_password = ?, title = ?, updated_at = ? WHERE id = ?`,
		boolInt(p.AutoEnqueue), p.AuthUsername, p.AuthPassword, p.Title, FormatTime(now), id)
	if err != nil {
		return p, wrap("patch podcast", err)
	}
	if p.HasAuth() != podcastHadAuth(patch, p) {
		// stream_url of all episodes changes → bump episodes so clients re-sync them
		_, _ = s.db.ExecContext(ctx, `UPDATE episodes SET updated_at = ? WHERE podcast_id = ?`, FormatTime(now), id)
	}
	p.UpdatedAt = now
	return p, nil
}

// podcastHadAuth is a best-effort check whether the auth state changed with this patch.
func podcastHadAuth(patch PodcastPatch, p Podcast) bool {
	if patch.AuthUsername == nil && patch.AuthPassword == nil {
		return p.HasAuth()
	}
	// auth fields were touched: assume a change so episodes are re-synced
	return !p.HasAuth()
}

// DeletePodcast unsubscribes: removes queue entries, episodes, writes tombstones.
func (s *Store) DeletePodcast(ctx context.Context, id string) error {
	now := FormatTime(Now())
	return s.tx(ctx, func(tx *sql.Tx) error {
		var exists int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM podcasts WHERE id = ?`, id).Scan(&exists); err != nil {
			return err
		}
		if exists == 0 {
			return ErrNotFound
		}
		var queued int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM queue q JOIN episodes e ON e.id = q.episode_id WHERE e.podcast_id = ?`, id).Scan(&queued); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO tombstones(kind, id, deleted_at)
			SELECT 'episode', id, ? FROM episodes WHERE podcast_id = ?`, now, id); err != nil {
			return wrap("episode tombstones", err)
		}
		if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO tombstones(kind, id, deleted_at) VALUES ('podcast', ?, ?)`, id, now); err != nil {
			return wrap("podcast tombstone", err)
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM podcasts WHERE id = ?`, id); err != nil {
			return wrap("delete podcast", err)
		}
		if queued > 0 {
			if err := s.renumberQueue(ctx, tx); err != nil {
				return err
			}
			return s.bumpQueueVersion(ctx, tx)
		}
		return nil
	})
}

// ---- episodes ----

func (s *Store) upsertEpisodes(ctx context.Context, tx *sql.Tx, podcastID string, eps []NewEpisode, now time.Time) ([]string, error) {
	var newIDs []string
	for _, e := range eps {
		if e.GUID == "" {
			continue
		}
		var existing string
		err := tx.QueryRowContext(ctx, `SELECT id FROM episodes WHERE podcast_id = ? AND guid = ?`, podcastID, e.GUID).Scan(&existing)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			id := NewID()
			_, err := tx.ExecContext(ctx, `INSERT INTO episodes
				(id, podcast_id, guid, title, description, link, image_url, media_url, media_type, media_size, duration_ms,
				 published_at, position_ms, played, progress_updated_at, created_at, updated_at)
				VALUES (?,?,?,?,?,?,?,?,?,?,?,?,0,0,'',?,?)`,
				id, podcastID, e.GUID, e.Title, e.Description, e.Link, e.ImageURL, e.MediaURL, e.MediaType, e.MediaSize, e.DurationMs,
				FormatTime(e.PublishedAt), FormatTime(now), FormatTime(now))
			if err != nil {
				return nil, wrap("insert episode", err)
			}
			newIDs = append(newIDs, id)
		case err != nil:
			return nil, wrap("lookup episode", err)
		default:
			// update metadata only if something changed (avoid bumping updated_at needlessly)
			res, err := tx.ExecContext(ctx, `UPDATE episodes SET title = ?, description = ?, link = ?, image_url = ?, media_url = ?,
				media_type = ?, media_size = ?, duration_ms = CASE WHEN ? > 0 THEN ? ELSE duration_ms END, published_at = ?, updated_at = ?
				WHERE id = ? AND (title != ? OR description != ? OR link != ? OR image_url != ? OR media_url != ? OR media_type != ?
				  OR media_size != ? OR (? > 0 AND duration_ms != ?) OR published_at != ?)`,
				e.Title, e.Description, e.Link, e.ImageURL, e.MediaURL, e.MediaType, e.MediaSize, e.DurationMs, e.DurationMs,
				FormatTime(e.PublishedAt), FormatTime(now), existing,
				e.Title, e.Description, e.Link, e.ImageURL, e.MediaURL, e.MediaType, e.MediaSize, e.DurationMs, e.DurationMs, FormatTime(e.PublishedAt))
			if err != nil {
				return nil, wrap("update episode", err)
			}
			_, _ = res.RowsAffected()
		}
	}
	return newIDs, nil
}

const episodeCols = `e.id, e.podcast_id, p.title, p.image_url, (p.auth_username != '' OR p.auth_password != ''),
 e.guid, e.title, e.description, e.link, e.image_url, e.media_url, e.media_type, e.media_size, e.duration_ms, e.published_at,
 e.position_ms, e.played, e.progress_updated_at, (q.episode_id IS NOT NULL), e.created_at, e.updated_at`

const episodeFrom = ` FROM episodes e JOIN podcasts p ON p.id = e.podcast_id LEFT JOIN queue q ON q.episode_id = e.id `

func scanEpisode(row interface{ Scan(...any) error }) (Episode, error) {
	var e Episode
	var hasAuth, played, inQueue int
	var published, progressUpd, created, updated string
	err := row.Scan(&e.ID, &e.PodcastID, &e.PodcastTitle, &e.PodcastImageURL, &hasAuth,
		&e.GUID, &e.Title, &e.Description, &e.Link, &e.ImageURL, &e.MediaURL, &e.MediaType, &e.MediaSize, &e.DurationMs, &published,
		&e.PositionMs, &played, &progressUpd, &inQueue, &created, &updated)
	if err != nil {
		return e, err
	}
	e.PodcastHasAuth = hasAuth == 1
	e.Played = played == 1
	e.InQueue = inQueue == 1
	e.PublishedAt, _ = ParseTime(published)
	e.ProgressUpdatedAt, _ = ParseTime(progressUpd)
	e.CreatedAt, _ = ParseTime(created)
	e.UpdatedAt, _ = ParseTime(updated)
	return e, nil
}

func (s *Store) queryEpisodes(ctx context.Context, q execer, where string, args ...any) ([]Episode, error) {
	rows, err := q.QueryContext(ctx, `SELECT `+episodeCols+episodeFrom+where, args...)
	if err != nil {
		return nil, wrap("query episodes", err)
	}
	defer rows.Close()
	out := []Episode{}
	for rows.Next() {
		e, err := scanEpisode(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (s *Store) GetEpisode(ctx context.Context, id string) (Episode, error) {
	e, err := scanEpisode(s.db.QueryRowContext(ctx, `SELECT `+episodeCols+episodeFrom+`WHERE e.id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return e, ErrNotFound
	}
	return e, wrap("get episode", err)
}

func (s *Store) ListPodcastEpisodes(ctx context.Context, podcastID string, limit, offset int) ([]Episode, error) {
	return s.queryEpisodes(ctx, s.db, `WHERE e.podcast_id = ? ORDER BY e.published_at DESC, e.created_at DESC LIMIT ? OFFSET ?`, podcastID, limit, offset)
}

func (s *Store) ListRecentEpisodes(ctx context.Context, since time.Time, limit int) ([]Episode, error) {
	return s.queryEpisodes(ctx, s.db, `WHERE e.published_at > ? ORDER BY e.published_at DESC LIMIT ?`, FormatTime(since), limit)
}

func (s *Store) GetEpisodes(ctx context.Context, ids []string) ([]Episode, error) {
	if len(ids) == 0 {
		return []Episode{}, nil
	}
	eps, err := s.queryEpisodes(ctx, s.db, `WHERE e.id IN (`+placeholders(len(ids))+`)`, anySlice(ids)...)
	if err != nil {
		return nil, err
	}
	// keep requested order
	byID := make(map[string]Episode, len(eps))
	for _, e := range eps {
		byID[e.ID] = e
	}
	out := make([]Episode, 0, len(ids))
	for _, id := range ids {
		if e, ok := byID[id]; ok {
			out = append(out, e)
		}
	}
	return out, nil
}

// UpdateProgress applies a last-write-wins progress update. Returns whether it
// was applied and whether the queue changed (episode removed because played).
func (s *Store) UpdateProgress(ctx context.Context, u ProgressUpdate, autoRemovePlayed bool) (applied bool, queueChanged bool, err error) {
	err = s.tx(ctx, func(tx *sql.Tx) error {
		var stored string
		var played int
		err := tx.QueryRowContext(ctx, `SELECT progress_updated_at, played FROM episodes WHERE id = ?`, u.EpisodeID).Scan(&stored, &played)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if st, ok := ParseTime(stored); ok && !u.UpdatedAt.After(st) {
			return nil // stale
		}
		applied = true
		now := FormatTime(Now())
		newPlayed := played == 1
		if u.Played != nil {
			newPlayed = *u.Played
		}
		if u.DurationMs != nil && *u.DurationMs > 0 {
			_, err = tx.ExecContext(ctx, `UPDATE episodes SET position_ms = ?, duration_ms = ?, played = ?, progress_updated_at = ?, updated_at = ? WHERE id = ?`,
				u.PositionMs, *u.DurationMs, boolInt(newPlayed), FormatTime(u.UpdatedAt), now, u.EpisodeID)
		} else {
			_, err = tx.ExecContext(ctx, `UPDATE episodes SET position_ms = ?, played = ?, progress_updated_at = ?, updated_at = ? WHERE id = ?`,
				u.PositionMs, boolInt(newPlayed), FormatTime(u.UpdatedAt), now, u.EpisodeID)
		}
		if err != nil {
			return wrap("update progress", err)
		}
		if newPlayed && autoRemovePlayed {
			removed, err := s.queueRemove(ctx, tx, u.EpisodeID)
			if err != nil {
				return err
			}
			if removed {
				queueChanged = true
				return s.bumpQueueVersion(ctx, tx)
			}
		}
		return nil
	})
	return applied, queueChanged, err
}
