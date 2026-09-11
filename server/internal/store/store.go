// Package store is the SQLite persistence layer. Single user, single writer.
package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// TimeFormat is fixed-width so that string comparison in SQL equals time order.
const TimeFormat = "2006-01-02T15:04:05.000000Z"

var ErrNotFound = errors.New("not found")

type Store struct {
	db *sql.DB
}

func Open(dataDir string) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0o750); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	path := filepath.Join(dataDir, "castqueue.db")
	dsn := "file:" + filepath.ToSlash(path) + "?_pragma=journal_mode(WAL)&_pragma=foreign_keys(ON)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

// OpenMemory opens an in-memory database (tests).
func OpenMemory() (*Store, error) {
	db, err := sql.Open("sqlite", "file::memory:?_pragma=foreign_keys(ON)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	if _, err := s.db.Exec(schema); err != nil {
		return err
	}
	// Columns added after the first release. ADD COLUMN has no IF NOT EXISTS
	// in SQLite, so check table_info first.
	type col struct{ table, name, def string }
	added := []col{
		{"podcasts", "language", "TEXT NOT NULL DEFAULT ''"},
		{"podcasts", "copyright", "TEXT NOT NULL DEFAULT ''"},
		{"podcasts", "categories", "TEXT NOT NULL DEFAULT ''"},
		{"podcasts", "explicit", "INTEGER NOT NULL DEFAULT 0"},
		{"podcasts", "podcast_type", "TEXT NOT NULL DEFAULT ''"},
		{"podcasts", "owner_name", "TEXT NOT NULL DEFAULT ''"},
		{"episodes", "season", "INTEGER NOT NULL DEFAULT 0"},
		{"episodes", "episode_number", "INTEGER NOT NULL DEFAULT 0"},
		{"episodes", "episode_type", "TEXT NOT NULL DEFAULT ''"},
		{"episodes", "explicit", "INTEGER NOT NULL DEFAULT 0"},
		{"episodes", "author", "TEXT NOT NULL DEFAULT ''"},
	}
	for _, c := range added {
		has, err := s.hasColumn(c.table, c.name)
		if err != nil {
			return err
		}
		if has {
			continue
		}
		if _, err := s.db.Exec(`ALTER TABLE ` + c.table + ` ADD COLUMN ` + c.name + ` ` + c.def); err != nil {
			return fmt.Errorf("add column %s.%s: %w", c.table, c.name, err)
		}
	}
	return nil
}

func (s *Store) hasColumn(table, name string) (bool, error) {
	rows, err := s.db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var cname, ctype string
		var notnull, pk int
		var dflt any
		if err := rows.Scan(&cid, &cname, &ctype, &notnull, &dflt, &pk); err != nil {
			return false, err
		}
		if cname == name {
			return true, nil
		}
	}
	return false, rows.Err()
}

// categoriesToJSON / categoriesFromJSON store the category list in one TEXT column.
func categoriesToJSON(cats []string) string {
	if len(cats) == 0 {
		return ""
	}
	b, err := json.Marshal(cats)
	if err != nil {
		return ""
	}
	return string(b)
}

func categoriesFromJSON(s string) []string {
	if s == "" {
		return []string{}
	}
	var out []string
	if err := json.Unmarshal([]byte(s), &out); err != nil || out == nil {
		return []string{}
	}
	return out
}

const schema = `
CREATE TABLE IF NOT EXISTS podcasts (
  id TEXT PRIMARY KEY,
  feed_url TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  author TEXT NOT NULL DEFAULT '',
  image_url TEXT NOT NULL DEFAULT '',
  website TEXT NOT NULL DEFAULT '',
  auto_enqueue INTEGER NOT NULL DEFAULT 1,
  auth_username TEXT NOT NULL DEFAULT '',
  auth_password TEXT NOT NULL DEFAULT '',
  last_refreshed_at TEXT NOT NULL DEFAULT '',
  last_error TEXT NOT NULL DEFAULT '',
  etag TEXT NOT NULL DEFAULT '',
  last_modified TEXT NOT NULL DEFAULT '',
  language TEXT NOT NULL DEFAULT '',
  copyright TEXT NOT NULL DEFAULT '',
  categories TEXT NOT NULL DEFAULT '',
  explicit INTEGER NOT NULL DEFAULT 0,
  podcast_type TEXT NOT NULL DEFAULT '',
  owner_name TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS episodes (
  id TEXT PRIMARY KEY,
  podcast_id TEXT NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
  guid TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  link TEXT NOT NULL DEFAULT '',
  image_url TEXT NOT NULL DEFAULT '',
  media_url TEXT NOT NULL DEFAULT '',
  media_type TEXT NOT NULL DEFAULT '',
  media_size INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  published_at TEXT NOT NULL DEFAULT '',
  season INTEGER NOT NULL DEFAULT 0,
  episode_number INTEGER NOT NULL DEFAULT 0,
  episode_type TEXT NOT NULL DEFAULT '',
  explicit INTEGER NOT NULL DEFAULT 0,
  author TEXT NOT NULL DEFAULT '',
  position_ms INTEGER NOT NULL DEFAULT 0,
  played INTEGER NOT NULL DEFAULT 0,
  progress_updated_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(podcast_id, guid)
);
CREATE INDEX IF NOT EXISTS episodes_published ON episodes(published_at);
CREATE INDEX IF NOT EXISTS episodes_updated ON episodes(updated_at);
CREATE INDEX IF NOT EXISTS episodes_podcast ON episodes(podcast_id, published_at);
CREATE TABLE IF NOT EXISTS queue (
  episode_id TEXT PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE,
  position INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tombstones (
  kind TEXT NOT NULL,
  id TEXT NOT NULL,
  deleted_at TEXT NOT NULL,
  PRIMARY KEY (kind, id)
);
CREATE TABLE IF NOT EXISTS kv (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
`

// ---- helpers ----

func Now() time.Time { return time.Now().UTC() }

func FormatTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(TimeFormat)
}

func ParseTime(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return time.Time{}, false
	}
	return t.UTC(), true
}

func NewID() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func RandomToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

type execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

func (s *Store) tx(ctx context.Context, fn func(tx *sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

// ---- kv ----

func (s *Store) getKV(ctx context.Context, q execer, key, def string) (string, error) {
	var v string
	err := q.QueryRowContext(ctx, `SELECT value FROM kv WHERE key = ?`, key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return def, nil
	}
	return v, err
}

func (s *Store) setKV(ctx context.Context, q execer, key, value string) error {
	_, err := q.ExecContext(ctx, `INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
	return err
}

func placeholders(n int) string {
	if n == 0 {
		return ""
	}
	return strings.Repeat("?,", n-1) + "?"
}

func anySlice(ids []string) []any {
	out := make([]any, len(ids))
	for i, id := range ids {
		out[i] = id
	}
	return out
}

func wrap(op string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%s: %w", op, err)
}
