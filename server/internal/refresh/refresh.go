// Package refresh runs the periodic feed refresh loop.
package refresh

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/sebseifert/castqueue/internal/feeds"
	"github.com/sebseifert/castqueue/internal/store"
)

type Refresher struct {
	store *store.Store
	feeds *feeds.Client
	log   *slog.Logger

	mu       sync.Mutex
	interval time.Duration
	wake     chan struct{}
	inflight map[string]bool
}

func New(st *store.Store, fc *feeds.Client, interval time.Duration, log *slog.Logger) *Refresher {
	return &Refresher{store: st, feeds: fc, log: log, interval: interval, wake: make(chan struct{}, 1), inflight: map[string]bool{}}
}

// Run blocks until ctx is done. First refresh runs shortly after start.
func (r *Refresher) Run(ctx context.Context) {
	timer := time.NewTimer(10 * time.Second)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		case <-r.wake:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
		}
		ok, failed := r.RefreshAll(ctx)
		r.log.Info("refresh done", "ok", ok, "failed", failed)
		if err := r.store.PruneTombstones(ctx, 90*24*time.Hour); err != nil {
			r.log.Warn("prune tombstones", "err", err)
		}
		r.mu.Lock()
		timer.Reset(r.interval)
		r.mu.Unlock()
	}
}

func (r *Refresher) SettingsChanged(st store.Settings) {
	r.mu.Lock()
	r.interval = time.Duration(st.RefreshIntervalMinutes) * time.Minute
	r.mu.Unlock()
}

func (r *Refresher) RefreshAll(ctx context.Context) (refreshed, failed int) {
	ps, err := r.store.ListPodcasts(ctx)
	if err != nil {
		r.log.Error("list podcasts", "err", err)
		return 0, 0
	}
	for _, p := range ps {
		if ctx.Err() != nil {
			return refreshed, failed
		}
		if _, err := r.refreshOne(ctx, p); err != nil {
			failed++
			r.log.Warn("refresh failed", "podcast", p.Title, "err", err)
		} else {
			refreshed++
		}
	}
	return refreshed, failed
}

func (r *Refresher) RefreshPodcast(ctx context.Context, id string) (store.Podcast, error) {
	p, err := r.store.GetPodcast(ctx, id)
	if err != nil {
		return p, err
	}
	return r.refreshOne(ctx, p)
}

func (r *Refresher) refreshOne(ctx context.Context, p store.Podcast) (store.Podcast, error) {
	r.mu.Lock()
	if r.inflight[p.ID] {
		r.mu.Unlock()
		return p, nil
	}
	r.inflight[p.ID] = true
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.inflight, p.ID)
		r.mu.Unlock()
	}()

	fetchCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	res, err := r.feeds.Fetch(fetchCtx, p.FeedURL, p.AuthUsername, p.AuthPassword, p.ETag, p.LastModified)
	if errors.Is(err, feeds.ErrNotModified) {
		if err := r.store.TouchRefresh(ctx, p.ID); err != nil {
			return p, err
		}
		return r.store.GetPodcast(ctx, p.ID)
	}
	if err != nil {
		if _, aerr := r.store.ApplyRefresh(ctx, p, nil, err.Error()); aerr != nil {
			return p, aerr
		}
		p, _ = r.store.GetPodcast(ctx, p.ID)
		return p, err
	}
	updated := p
	updated.Title = firstNonEmpty(res.Podcast.Title, p.Title)
	updated.Description = res.Podcast.Description
	updated.Author = res.Podcast.Author
	updated.ImageURL = firstNonEmpty(res.Podcast.ImageURL, p.ImageURL)
	updated.Website = res.Podcast.Website
	updated.ETag = res.Podcast.ETag
	updated.LastModified = res.Podcast.LastModified
	newIDs, err := r.store.ApplyRefresh(ctx, updated, res.Episodes, "")
	if err != nil {
		return p, err
	}
	if len(newIDs) > 0 {
		r.log.Info("new episodes", "podcast", updated.Title, "count", len(newIDs), "enqueued", updated.AutoEnqueue)
	}
	return r.store.GetPodcast(ctx, p.ID)
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
