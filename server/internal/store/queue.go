package store

import (
	"context"
	"database/sql"
	"errors"
	"strconv"
)

const kvQueueVersion = "queue_version"

func (s *Store) queueVersion(ctx context.Context, q execer) (int64, error) {
	v, err := s.getKV(ctx, q, kvQueueVersion, "0")
	if err != nil {
		return 0, err
	}
	return strconv.ParseInt(v, 10, 64)
}

func (s *Store) bumpQueueVersion(ctx context.Context, q execer) error {
	v, err := s.queueVersion(ctx, q)
	if err != nil {
		return err
	}
	return s.setKV(ctx, q, kvQueueVersion, strconv.FormatInt(v+1, 10))
}

func (s *Store) queueIDs(ctx context.Context, q execer) ([]string, error) {
	rows, err := q.QueryContext(ctx, `SELECT episode_id FROM queue ORDER BY position`)
	if err != nil {
		return nil, wrap("queue ids", err)
	}
	defer rows.Close()
	ids := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func (s *Store) renumberQueue(ctx context.Context, q execer) error {
	ids, err := s.queueIDs(ctx, q)
	if err != nil {
		return err
	}
	return s.writeQueueOrder(ctx, q, ids)
}

func (s *Store) writeQueueOrder(ctx context.Context, q execer, ids []string) error {
	if _, err := q.ExecContext(ctx, `DELETE FROM queue`); err != nil {
		return wrap("clear queue", err)
	}
	for i, id := range ids {
		if _, err := q.ExecContext(ctx, `INSERT OR IGNORE INTO queue(episode_id, position) SELECT id, ? FROM episodes WHERE id = ?`, i, id); err != nil {
			return wrap("insert queue", err)
		}
	}
	return nil
}

// queueAdd inserts (or moves) an episode. index -1 = back, 0 = front.
func (s *Store) queueAdd(ctx context.Context, q execer, episodeID string, index int) error {
	ids, err := s.queueIDs(ctx, q)
	if err != nil {
		return err
	}
	ids = remove(ids, episodeID)
	if index < 0 || index > len(ids) {
		index = len(ids)
	}
	ids = append(ids[:index], append([]string{episodeID}, ids[index:]...)...)
	return s.writeQueueOrder(ctx, q, ids)
}

func (s *Store) queueRemove(ctx context.Context, q execer, episodeID string) (bool, error) {
	res, err := q.ExecContext(ctx, `DELETE FROM queue WHERE episode_id = ?`, episodeID)
	if err != nil {
		return false, wrap("queue remove", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return false, nil
	}
	return true, s.renumberQueue(ctx, q)
}

func remove(ids []string, id string) []string {
	out := ids[:0]
	for _, x := range ids {
		if x != id {
			out = append(out, x)
		}
	}
	return out
}

// ---- public ----

func (s *Store) GetQueue(ctx context.Context) (Queue, error) {
	var q Queue
	err := s.tx(ctx, func(tx *sql.Tx) error {
		var err error
		if q.Version, err = s.queueVersion(ctx, tx); err != nil {
			return err
		}
		q.EpisodeIDs, err = s.queueIDs(ctx, tx)
		return err
	})
	return q, err
}

var ErrQueueConflict = errors.New("queue version conflict")

func (s *Store) ReplaceQueue(ctx context.Context, baseVersion int64, ids []string) (Queue, error) {
	err := s.tx(ctx, func(tx *sql.Tx) error {
		v, err := s.queueVersion(ctx, tx)
		if err != nil {
			return err
		}
		if v != baseVersion {
			return ErrQueueConflict
		}
		if err := s.writeQueueOrder(ctx, tx, dedupe(ids)); err != nil {
			return err
		}
		return s.bumpQueueVersion(ctx, tx)
	})
	if err != nil {
		if errors.Is(err, ErrQueueConflict) {
			q, _ := s.GetQueue(ctx)
			return q, ErrQueueConflict
		}
		return Queue{}, err
	}
	return s.GetQueue(ctx)
}

func (s *Store) QueueAdd(ctx context.Context, episodeID string, index int) (Queue, error) {
	err := s.tx(ctx, func(tx *sql.Tx) error {
		var n int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM episodes WHERE id = ?`, episodeID).Scan(&n); err != nil {
			return err
		}
		if n == 0 {
			return ErrNotFound
		}
		if err := s.queueAdd(ctx, tx, episodeID, index); err != nil {
			return err
		}
		return s.bumpQueueVersion(ctx, tx)
	})
	if err != nil {
		return Queue{}, err
	}
	return s.GetQueue(ctx)
}

func (s *Store) QueueRemove(ctx context.Context, episodeID string) (Queue, error) {
	err := s.tx(ctx, func(tx *sql.Tx) error {
		removed, err := s.queueRemove(ctx, tx, episodeID)
		if err != nil || !removed {
			return err
		}
		return s.bumpQueueVersion(ctx, tx)
	})
	if err != nil {
		return Queue{}, err
	}
	return s.GetQueue(ctx)
}

func (s *Store) QueueMove(ctx context.Context, episodeID string, to int) (Queue, error) {
	err := s.tx(ctx, func(tx *sql.Tx) error {
		ids, err := s.queueIDs(ctx, tx)
		if err != nil {
			return err
		}
		found := false
		for _, id := range ids {
			if id == episodeID {
				found = true
				break
			}
		}
		if !found {
			return ErrNotFound
		}
		if err := s.queueAdd(ctx, tx, episodeID, to); err != nil {
			return err
		}
		return s.bumpQueueVersion(ctx, tx)
	})
	if err != nil {
		return Queue{}, err
	}
	return s.GetQueue(ctx)
}

func (s *Store) ClearQueue(ctx context.Context) (Queue, error) {
	err := s.tx(ctx, func(tx *sql.Tx) error {
		if _, err := tx.ExecContext(ctx, `DELETE FROM queue`); err != nil {
			return err
		}
		return s.bumpQueueVersion(ctx, tx)
	})
	if err != nil {
		return Queue{}, err
	}
	return s.GetQueue(ctx)
}

func dedupe(ids []string) []string {
	seen := make(map[string]bool, len(ids))
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		out = append(out, id)
	}
	return out
}
