// Package api implements the HTTP API and serves the embedded web UI.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"

	"github.com/sebseifert/castqueue/internal/config"
	"github.com/sebseifert/castqueue/internal/feeds"
	"github.com/sebseifert/castqueue/internal/store"
)

const (
	sessionCookie = "cq_session"
	Version       = "1.0.0"
)

type Server struct {
	cfg     config.Config
	store   *store.Store
	feeds   *feeds.Client
	refresh Refresher
	log     *slog.Logger
	web     fs.FS
	limiter *loginLimiter
	mux     *http.ServeMux
}

// Refresher is implemented by the background refresh loop.
type Refresher interface {
	RefreshPodcast(ctx context.Context, id string) (store.Podcast, error)
	RefreshAll(ctx context.Context) (refreshed, failed int)
	SettingsChanged(store.Settings)
}

func New(cfg config.Config, st *store.Store, fc *feeds.Client, r Refresher, web fs.FS, log *slog.Logger) *Server {
	s := &Server{cfg: cfg, store: st, feeds: fc, refresh: r, log: log, web: web, limiter: newLoginLimiter()}
	s.routes()
	return s
}

func (s *Server) Handler() http.Handler { return s.mux }

func (s *Server) routes() {
	m := http.NewServeMux()
	s.mux = m

	m.HandleFunc("GET /api/health", s.handleHealth)
	m.HandleFunc("POST /api/auth/login", s.handleLogin)
	m.HandleFunc("GET /stream/{id}", s.handleStream)
	m.HandleFunc("HEAD /stream/{id}", s.handleStream)

	auth := func(h http.HandlerFunc) http.HandlerFunc { return s.requireAuth(h) }

	m.HandleFunc("POST /api/auth/logout", auth(s.handleLogout))
	m.HandleFunc("GET /api/me", auth(s.handleMe))
	m.HandleFunc("GET /api/devices", auth(s.handleListDevices))
	m.HandleFunc("DELETE /api/devices/{id}", auth(s.handleDeleteDevice))
	m.HandleFunc("POST /api/stream-token/rotate", auth(s.handleRotateStreamToken))

	m.HandleFunc("GET /api/podcasts", auth(s.handleListPodcasts))
	m.HandleFunc("POST /api/podcasts", auth(s.handleCreatePodcast))
	m.HandleFunc("POST /api/podcasts/refresh", auth(s.handleRefreshAll))
	m.HandleFunc("GET /api/podcasts/{id}", auth(s.handleGetPodcast))
	m.HandleFunc("PATCH /api/podcasts/{id}", auth(s.handlePatchPodcast))
	m.HandleFunc("DELETE /api/podcasts/{id}", auth(s.handleDeletePodcast))
	m.HandleFunc("POST /api/podcasts/{id}/refresh", auth(s.handleRefreshPodcast))
	m.HandleFunc("GET /api/podcasts/{id}/episodes", auth(s.handlePodcastEpisodes))
	m.HandleFunc("GET /api/search", auth(s.handleSearch))
	m.HandleFunc("GET /api/opml", auth(s.handleExportOPML))
	m.HandleFunc("POST /api/opml", auth(s.handleImportOPML))

	m.HandleFunc("GET /api/episodes", auth(s.handleRecentEpisodes))
	m.HandleFunc("GET /api/episodes/{id}", auth(s.handleGetEpisode))
	m.HandleFunc("PUT /api/episodes/{id}/progress", auth(s.handleProgress))
	m.HandleFunc("POST /api/progress/batch", auth(s.handleProgressBatch))

	m.HandleFunc("GET /api/queue", auth(s.handleGetQueue))
	m.HandleFunc("PUT /api/queue", auth(s.handleReplaceQueue))
	m.HandleFunc("DELETE /api/queue", auth(s.handleClearQueue))
	m.HandleFunc("POST /api/queue/items", auth(s.handleQueueAdd))
	m.HandleFunc("DELETE /api/queue/items/{id}", auth(s.handleQueueRemove))
	m.HandleFunc("POST /api/queue/move", auth(s.handleQueueMove))

	m.HandleFunc("GET /api/sync", auth(s.handleSync))
	m.HandleFunc("GET /api/settings", auth(s.handleGetSettings))
	m.HandleFunc("PUT /api/settings", auth(s.handleSetSettings))

	m.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "not_found", "unknown endpoint")
	})
	m.Handle("/", s.spaHandler())
}

// ---- JSON helpers ----

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"error": msg, "code": code})
}

func (s *Server) writeStoreError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "not found")
	default:
		s.log.Error("internal error", "err", err)
		writeError(w, http.StatusInternalServerError, "internal", "internal error")
	}
}

func readJSON(w http.ResponseWriter, r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20))
	if err := dec.Decode(v); err != nil {
		return err
	}
	return nil
}

// ---- auth ----

type ctxKey int

const ctxDevice ctxKey = 1

func deviceFrom(ctx context.Context) store.Device {
	d, _ := ctx.Value(ctxDevice).(store.Device)
	return d
}

func bearerToken(r *http.Request) string {
	if h := r.Header.Get("Authorization"); strings.HasPrefix(strings.ToLower(h), "bearer ") {
		return strings.TrimSpace(h[7:])
	}
	if c, err := r.Cookie(sessionCookie); err == nil {
		return c.Value
	}
	return ""
}

func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := bearerToken(r)
		if token == "" {
			writeError(w, http.StatusUnauthorized, "unauthorized", "missing token")
			return
		}
		d, err := s.store.DeviceByToken(r.Context(), token)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "unauthorized", "invalid token")
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), ctxDevice, d)))
	}
}

func (s *Server) checkPassword(user, pass string) bool {
	if subtle.ConstantTimeCompare([]byte(user), []byte(s.cfg.Username)) != 1 {
		return false
	}
	if strings.HasPrefix(s.cfg.Password, "bcrypt:") {
		return bcrypt.CompareHashAndPassword([]byte(strings.TrimPrefix(s.cfg.Password, "bcrypt:")), []byte(pass)) == nil
	}
	return subtle.ConstantTimeCompare([]byte(pass), []byte(s.cfg.Password)) == 1
}

// ---- login rate limiting ----

type loginLimiter struct {
	mu       sync.Mutex
	failures map[string][]time.Time
}

func newLoginLimiter() *loginLimiter { return &loginLimiter{failures: map[string][]time.Time{}} }

const (
	loginMaxFailures = 5
	loginWindow      = 15 * time.Minute
)

func (l *loginLimiter) blocked(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.recent(ip)) >= loginMaxFailures
}

func (l *loginLimiter) fail(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.failures[ip] = append(l.recent(ip), time.Now())
}

func (l *loginLimiter) reset(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.failures, ip)
}

func (l *loginLimiter) recent(ip string) []time.Time {
	cutoff := time.Now().Add(-loginWindow)
	var keep []time.Time
	for _, t := range l.failures[ip] {
		if t.After(cutoff) {
			keep = append(keep, t)
		}
	}
	if len(keep) == 0 {
		delete(l.failures, ip)
	} else {
		l.failures[ip] = keep
	}
	return keep
}

func clientIP(r *http.Request) string {
	// Caddy / reverse proxy in front: trust X-Forwarded-For's first hop.
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.Index(xff, ","); i > 0 {
			return strings.TrimSpace(xff[:i])
		}
		return strings.TrimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// ---- SPA ----

func (s *Server) spaHandler() http.Handler {
	files := http.FS(s.web)
	fileServer := http.FileServer(files)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
			return
		}
		path := strings.TrimPrefix(r.URL.Path, "/")
		if path == "" {
			path = "index.html"
		}
		if f, err := s.web.Open(path); err == nil {
			f.Close()
			if path == "index.html" {
				w.Header().Set("Cache-Control", "no-cache")
			}
			fileServer.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-cache")
		r.URL.Path = "/"
		fileServer.ServeHTTP(w, r)
	})
}

// ---- misc handlers ----

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "version": Version})
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if s.limiter.blocked(ip) {
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many failed logins, try again later")
		return
	}
	var in struct {
		Username   string `json:"username"`
		Password   string `json:"password"`
		DeviceName string `json:"device_name"`
	}
	if err := readJSON(w, r, &in); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid json")
		return
	}
	if !s.checkPassword(in.Username, in.Password) {
		s.limiter.fail(ip)
		s.log.Warn("failed login", "ip", ip, "user", in.Username)
		writeError(w, http.StatusUnauthorized, "unauthorized", "wrong username or password")
		return
	}
	s.limiter.reset(ip)
	name := strings.TrimSpace(in.DeviceName)
	if name == "" {
		name = "Unbenanntes Gerät"
	}
	d, token, err := s.store.CreateDevice(r.Context(), name)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	streamToken, err := s.store.StreamToken(r.Context())
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name: sessionCookie, Value: token, Path: "/", HttpOnly: true, SameSite: http.SameSiteLaxMode,
		Secure: strings.HasPrefix(s.cfg.PublicURL, "https://"), MaxAge: 365 * 24 * 3600,
	})
	writeJSON(w, http.StatusOK, map[string]string{"token": token, "device_id": d.ID, "stream_token": streamToken})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	d := deviceFrom(r.Context())
	_ = s.store.DeleteDevice(r.Context(), d.ID)
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: "", Path: "/", HttpOnly: true, MaxAge: -1})
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	d := deviceFrom(r.Context())
	st, err := s.store.StreamToken(r.Context())
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"username": s.cfg.Username, "device_id": d.ID, "device_name": d.Name,
		"stream_token": st, "server_time": store.Now().Format(time.RFC3339Nano), "public_url": s.cfg.PublicURL,
	})
}

func (s *Server) handleListDevices(w http.ResponseWriter, r *http.Request) {
	devs, err := s.store.ListDevices(r.Context())
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	cur := deviceFrom(r.Context()).ID
	out := make([]map[string]any, 0, len(devs))
	for _, d := range devs {
		out = append(out, map[string]any{
			"id": d.ID, "name": d.Name, "created_at": fmtTime(d.CreatedAt), "last_seen_at": fmtTime(d.LastSeenAt), "current": d.ID == cur,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleDeleteDevice(w http.ResponseWriter, r *http.Request) {
	if err := s.store.DeleteDevice(r.Context(), r.PathValue("id")); err != nil {
		s.writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleRotateStreamToken(w http.ResponseWriter, r *http.Request) {
	t, err := s.store.RotateStreamToken(r.Context())
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"stream_token": t})
}

func (s *Server) settings(ctx context.Context) store.Settings {
	st, err := s.store.GetSettings(ctx, store.DefaultSettings(s.cfg.RefreshMinutes))
	if err != nil {
		s.log.Error("load settings", "err", err)
		return store.DefaultSettings(s.cfg.RefreshMinutes)
	}
	return st
}

func (s *Server) handleGetSettings(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.settings(r.Context()))
}

func (s *Server) handleSetSettings(w http.ResponseWriter, r *http.Request) {
	st := s.settings(r.Context())
	if err := readJSON(w, r, &st); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid json")
		return
	}
	if st.RefreshIntervalMinutes < 5 {
		st.RefreshIntervalMinutes = 5
	}
	if err := s.store.SaveSettings(r.Context(), st); err != nil {
		s.writeStoreError(w, err)
		return
	}
	s.refresh.SettingsChanged(st)
	writeJSON(w, http.StatusOK, st)
}

func fmtTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339Nano)
}
