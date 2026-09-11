package api

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/sebseifert/castqueue/internal/feeds"
	"github.com/sebseifert/castqueue/internal/store"
)

// ---- podcasts ----

func (s *Server) handleListPodcasts(w http.ResponseWriter, r *http.Request) {
	ps, err := s.store.ListPodcasts(r.Context())
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toPodcastDTOs(ps))
}

func (s *Server) handleGetPodcast(w http.ResponseWriter, r *http.Request) {
	p, err := s.store.GetPodcast(r.Context(), r.PathValue("id"))
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toPodcastDTO(p))
}

type createPodcastRequest struct {
	FeedURL      string `json:"feed_url"`
	AuthUsername string `json:"auth_username"`
	AuthPassword string `json:"auth_password"`
	AutoEnqueue  *bool  `json:"auto_enqueue"`
}

// subscribe fetches the feed and creates the podcast. Returns (podcast, created, error).
func (s *Server) subscribe(ctx context.Context, in createPodcastRequest) (store.Podcast, bool, int, error) {
	feedURL := strings.TrimSpace(in.FeedURL)
	u, err := url.Parse(feedURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return store.Podcast{}, false, http.StatusBadRequest, errors.New("feed_url must be an http(s) URL")
	}
	if existing, err := s.store.GetPodcastByFeedURL(ctx, feedURL); err == nil {
		return existing, false, http.StatusOK, nil
	}
	res, err := s.feeds.Fetch(ctx, feedURL, in.AuthUsername, in.AuthPassword, "", "")
	if err != nil {
		var unparseable feeds.ErrUnparseable
		if errors.As(err, &unparseable) {
			return store.Podcast{}, false, http.StatusUnprocessableEntity, err
		}
		return store.Podcast{}, false, http.StatusBadGateway, err
	}
	p := res.Podcast
	p.AuthUsername, p.AuthPassword = in.AuthUsername, in.AuthPassword
	if in.AutoEnqueue != nil {
		p.AutoEnqueue = *in.AutoEnqueue
	} else {
		p.AutoEnqueue = s.settings(ctx).AutoEnqueueDefault
	}
	if p.Title == "" {
		p.Title = feedURL
	}
	if err := s.store.CreatePodcast(ctx, &p, res.Episodes); err != nil {
		return store.Podcast{}, false, http.StatusInternalServerError, err
	}
	p, err = s.store.GetPodcast(ctx, p.ID)
	if err != nil {
		return store.Podcast{}, false, http.StatusInternalServerError, err
	}
	return p, true, http.StatusCreated, nil
}

func (s *Server) handleCreatePodcast(w http.ResponseWriter, r *http.Request) {
	var in createPodcastRequest
	if err := readJSON(w, r, &in); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid json")
		return
	}
	p, _, status, err := s.subscribe(r.Context(), in)
	if err != nil {
		switch status {
		case http.StatusBadRequest:
			writeError(w, status, "bad_request", err.Error())
		case http.StatusUnprocessableEntity:
			writeError(w, status, "unparseable", err.Error())
		case http.StatusBadGateway:
			writeError(w, status, "upstream", "feed could not be fetched: "+err.Error())
		default:
			s.writeStoreError(w, err)
		}
		return
	}
	writeJSON(w, status, toPodcastDTO(p))
}

func (s *Server) handlePatchPodcast(w http.ResponseWriter, r *http.Request) {
	var in struct {
		AutoEnqueue  *bool   `json:"auto_enqueue"`
		AuthUsername *string `json:"auth_username"`
		AuthPassword *string `json:"auth_password"`
		Title        *string `json:"title"`
	}
	if err := readJSON(w, r, &in); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid json")
		return
	}
	p, err := s.store.PatchPodcast(r.Context(), r.PathValue("id"), store.PodcastPatch{
		AutoEnqueue: in.AutoEnqueue, AuthUsername: in.AuthUsername, AuthPassword: in.AuthPassword, Title: in.Title,
	})
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toPodcastDTO(p))
}

func (s *Server) handleDeletePodcast(w http.ResponseWriter, r *http.Request) {
	if err := s.store.DeletePodcast(r.Context(), r.PathValue("id")); err != nil {
		s.writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleRefreshPodcast(w http.ResponseWriter, r *http.Request) {
	p, err := s.refresh.RefreshPodcast(r.Context(), r.PathValue("id"))
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			s.writeStoreError(w, err)
			return
		}
		// feed error: podcast carries last_error; still 200
		s.log.Warn("refresh failed", "podcast", p.ID, "err", err)
	}
	writeJSON(w, http.StatusOK, toPodcastDTO(p))
}

func (s *Server) handleRefreshAll(w http.ResponseWriter, r *http.Request) {
	ok, failed := s.refresh.RefreshAll(r.Context())
	writeJSON(w, http.StatusOK, map[string]int{"refreshed": ok, "errors": failed})
}

func (s *Server) handlePodcastEpisodes(w http.ResponseWriter, r *http.Request) {
	limit := queryInt(r, "limit", 50, 1, 500)
	offset := queryInt(r, "offset", 0, 0, 1<<30)
	if _, err := s.store.GetPodcast(r.Context(), r.PathValue("id")); err != nil {
		s.writeStoreError(w, err)
		return
	}
	eps, err := s.store.ListPodcastEpisodes(r.Context(), r.PathValue("id"), limit, offset)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	out, err := s.toEpisodeDTOs(r.Context(), eps)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		writeJSON(w, http.StatusOK, []feeds.SearchResult{})
		return
	}
	res, err := s.feeds.Search(r.Context(), q, 25)
	if err != nil {
		writeError(w, http.StatusBadGateway, "upstream", "search failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) handleExportOPML(w http.ResponseWriter, r *http.Request) {
	ps, err := s.store.ListPodcasts(r.Context())
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	body, err := feeds.ExportOPML(ps)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="castqueue.opml"`)
	_, _ = w.Write(body)
}

func (s *Server) handleImportOPML(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 10<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "could not read body")
		return
	}
	urls, err := feeds.ParseOPML(body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid OPML: "+err.Error())
		return
	}
	added, skipped := 0, 0
	failed := []string{}
	for _, u := range urls {
		_, created, _, err := s.subscribe(r.Context(), createPodcastRequest{FeedURL: u})
		switch {
		case err != nil:
			s.log.Warn("opml import failed", "url", u, "err", err)
			failed = append(failed, u)
		case created:
			added++
		default:
			skipped++
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"added": added, "skipped": skipped, "failed": failed})
}

// ---- episodes ----

func (s *Server) handleRecentEpisodes(w http.ResponseWriter, r *http.Request) {
	since := store.Now().Add(-14 * 24 * time.Hour)
	if v := r.URL.Query().Get("since"); v != "" {
		t, ok := store.ParseTime(v)
		if !ok {
			writeError(w, http.StatusBadRequest, "bad_request", "invalid since")
			return
		}
		since = t
	}
	limit := queryInt(r, "limit", 100, 1, 1000)
	eps, err := s.store.ListRecentEpisodes(r.Context(), since, limit)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	out, err := s.toEpisodeDTOs(r.Context(), eps)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleGetEpisode(w http.ResponseWriter, r *http.Request) {
	e, err := s.store.GetEpisode(r.Context(), r.PathValue("id"))
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	s.writeEpisode(w, r, e)
}

func (s *Server) writeEpisode(w http.ResponseWriter, r *http.Request, e store.Episode) {
	token, err := s.store.StreamToken(r.Context())
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, s.toEpisodeDTO(e, token))
}

type progressRequest struct {
	EpisodeID  string `json:"episode_id"`
	PositionMs int64  `json:"position_ms"`
	DurationMs *int64 `json:"duration_ms"`
	Played     *bool  `json:"played"`
	UpdatedAt  string `json:"updated_at"`
}

func (s *Server) applyProgress(ctx context.Context, in progressRequest) error {
	ts, ok := parseClientTime(in.UpdatedAt)
	if !ok {
		return errBadTime
	}
	if in.PositionMs < 0 {
		in.PositionMs = 0
	}
	_, _, err := s.store.UpdateProgress(ctx, store.ProgressUpdate{
		EpisodeID: in.EpisodeID, PositionMs: in.PositionMs, DurationMs: in.DurationMs, Played: in.Played, UpdatedAt: ts,
	}, s.settings(ctx).AutoRemovePlayed)
	return err
}

var errBadTime = errors.New("invalid updated_at")

func (s *Server) handleProgress(w http.ResponseWriter, r *http.Request) {
	var in progressRequest
	if err := readJSON(w, r, &in); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid json")
		return
	}
	in.EpisodeID = r.PathValue("id")
	if err := s.applyProgress(r.Context(), in); err != nil {
		if errors.Is(err, errBadTime) {
			writeError(w, http.StatusBadRequest, "bad_request", err.Error())
			return
		}
		s.writeStoreError(w, err)
		return
	}
	e, err := s.store.GetEpisode(r.Context(), in.EpisodeID)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	s.writeEpisode(w, r, e)
}

func (s *Server) handleProgressBatch(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Items []progressRequest `json:"items"`
	}
	if err := readJSON(w, r, &in); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid json")
		return
	}
	ids := make([]string, 0, len(in.Items))
	for _, item := range in.Items {
		if item.EpisodeID == "" {
			continue
		}
		if err := s.applyProgress(r.Context(), item); err != nil && !errors.Is(err, store.ErrNotFound) && !errors.Is(err, errBadTime) {
			s.writeStoreError(w, err)
			return
		}
		ids = append(ids, item.EpisodeID)
	}
	eps, err := s.store.GetEpisodes(r.Context(), ids)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	out, err := s.toEpisodeDTOs(r.Context(), eps)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"episodes": out})
}

// ---- queue ----

func (s *Server) writeQueue(w http.ResponseWriter, r *http.Request, status int, q store.Queue) {
	dto, err := s.toQueueDTO(r.Context(), q)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, status, dto)
}

func (s *Server) handleGetQueue(w http.ResponseWriter, r *http.Request) {
	q, err := s.store.GetQueue(r.Context())
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	s.writeQueue(w, r, http.StatusOK, q)
}

func (s *Server) handleReplaceQueue(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Version    int64    `json:"version"`
		EpisodeIDs []string `json:"episode_ids"`
	}
	if err := readJSON(w, r, &in); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid json")
		return
	}
	q, err := s.store.ReplaceQueue(r.Context(), in.Version, in.EpisodeIDs)
	if errors.Is(err, store.ErrQueueConflict) {
		s.writeQueue(w, r, http.StatusConflict, q)
		return
	}
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	s.writeQueue(w, r, http.StatusOK, q)
}

func (s *Server) handleClearQueue(w http.ResponseWriter, r *http.Request) {
	q, err := s.store.ClearQueue(r.Context())
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	s.writeQueue(w, r, http.StatusOK, q)
}

func (s *Server) handleQueueAdd(w http.ResponseWriter, r *http.Request) {
	var in struct {
		EpisodeID string `json:"episode_id"`
		Position  any    `json:"position"`
	}
	if err := readJSON(w, r, &in); err != nil || in.EpisodeID == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "episode_id required")
		return
	}
	index := -1
	switch p := in.Position.(type) {
	case string:
		if p == "front" {
			index = 0
		}
	case float64:
		index = int(p)
	}
	q, err := s.store.QueueAdd(r.Context(), in.EpisodeID, index)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	s.writeQueue(w, r, http.StatusOK, q)
}

func (s *Server) handleQueueRemove(w http.ResponseWriter, r *http.Request) {
	q, err := s.store.QueueRemove(r.Context(), r.PathValue("id"))
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	s.writeQueue(w, r, http.StatusOK, q)
}

func (s *Server) handleQueueMove(w http.ResponseWriter, r *http.Request) {
	var in struct {
		EpisodeID string `json:"episode_id"`
		To        int    `json:"to"`
	}
	if err := readJSON(w, r, &in); err != nil || in.EpisodeID == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "episode_id and to required")
		return
	}
	q, err := s.store.QueueMove(r.Context(), in.EpisodeID, in.To)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	s.writeQueue(w, r, http.StatusOK, q)
}

// ---- sync ----

func (s *Server) handleSync(w http.ResponseWriter, r *http.Request) {
	var since time.Time
	if v := r.URL.Query().Get("since"); v != "" {
		t, ok := store.ParseTime(v)
		if !ok {
			writeError(w, http.StatusBadRequest, "bad_request", "invalid since")
			return
		}
		since = t
	}
	d, err := s.store.Sync(r.Context(), since, s.settings(r.Context()))
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	eps, err := s.toEpisodeDTOs(r.Context(), d.Episodes)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	lock, err := s.store.GetPlaybackLock(r.Context())
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"server_time":      fmtTime(d.ServerTime),
		"playback":         toPlaybackDTO(lock),
		"podcasts":         toPodcastDTOs(d.Podcasts),
		"podcasts_deleted": d.PodcastsDeleted,
		"episodes":         eps,
		"episodes_deleted": d.EpisodesDeleted,
		"queue":            map[string]any{"version": d.Queue.Version, "episode_ids": d.Queue.EpisodeIDs},
		"settings":         d.Settings,
	})
}

func queryInt(r *http.Request, key string, def, min, max int) int {
	v := r.URL.Query().Get(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	if n < min {
		return min
	}
	if n > max {
		return max
	}
	return n
}
