// Command castqueue runs the CastQueue podcast sync server.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sebseifert/castqueue/internal/api"
	"github.com/sebseifert/castqueue/internal/config"
	"github.com/sebseifert/castqueue/internal/feeds"
	"github.com/sebseifert/castqueue/internal/refresh"
	"github.com/sebseifert/castqueue/internal/store"
	"github.com/sebseifert/castqueue/web"
)

func main() {
	cfg, err := config.FromEnv()
	if err != nil {
		slog.Error("config", "err", err)
		os.Exit(2)
	}
	level := slog.LevelInfo
	if cfg.LogLevel == "debug" {
		level = slog.LevelDebug
	}
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: level}))

	if err := os.MkdirAll(cfg.DataDir, 0o755); err != nil {
		log.Error("data dir", "err", err)
		os.Exit(1)
	}
	st, err := store.Open(cfg.DataDir)
	if err != nil {
		log.Error("open store", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	fc := feeds.NewClient()
	settings, _ := st.GetSettings(ctx, store.DefaultSettings(cfg.RefreshMinutes))
	rf := refresh.New(st, fc, time.Duration(settings.RefreshIntervalMinutes)*time.Minute, log)
	go rf.Run(ctx)

	srv := api.New(cfg, st, fc, rf, web.FS(), log)
	httpSrv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           logRequests(log, srv.Handler()),
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		log.Info("listening", "addr", cfg.Listen, "public_url", cfg.PublicURL)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("http", "err", err)
			stop()
		}
	}()
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(shutdownCtx)
	log.Info("bye")
}

func logRequests(log *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		log.Debug("req", "method", r.Method, "path", r.URL.Path, "status", rec.status, "ms", time.Since(start).Milliseconds())
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// Flush lets the stream proxy flush chunks through the recorder.
func (s *statusRecorder) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
