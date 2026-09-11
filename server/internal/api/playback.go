package api

import (
	"net/http"
	"strings"

	"github.com/sebseifert/castqueue/internal/store"
)

type playbackDTO struct {
	Active      bool   `json:"active"`
	DeviceID    string `json:"device_id"`
	DeviceName  string `json:"device_name"`
	EpisodeID   string `json:"episode_id"`
	Target      string `json:"target"`
	StartedAt   string `json:"started_at"`
	HeartbeatAt string `json:"heartbeat_at"`
	Stale       bool   `json:"stale"`
}

func toPlaybackDTO(l store.PlaybackLock) playbackDTO {
	if !l.Active() {
		return playbackDTO{}
	}
	return playbackDTO{
		Active: true, DeviceID: l.DeviceID, DeviceName: l.DeviceName, EpisodeID: l.EpisodeID, Target: l.Target,
		StartedAt: fmtTime(l.StartedAt), HeartbeatAt: fmtTime(l.HeartbeatAt), Stale: l.Stale(store.Now()),
	}
}

type playbackReq struct {
	EpisodeID string `json:"episode_id"`
	Target    string `json:"target"`
}

func (s *Server) readPlaybackReq(w http.ResponseWriter, r *http.Request) (playbackReq, bool) {
	var in playbackReq
	if err := readJSON(w, r, &in); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return in, false
	}
	in.EpisodeID = strings.TrimSpace(in.EpisodeID)
	in.Target = strings.TrimSpace(in.Target)
	if in.EpisodeID == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "episode_id required")
		return in, false
	}
	return in, true
}

func (s *Server) handleGetPlayback(w http.ResponseWriter, r *http.Request) {
	l, err := s.store.GetPlaybackLock(r.Context())
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toPlaybackDTO(l))
}

// handlePlaybackClaim: this device starts playing and takes over from any other.
func (s *Server) handlePlaybackClaim(w http.ResponseWriter, r *http.Request) {
	in, ok := s.readPlaybackReq(w, r)
	if !ok {
		return
	}
	l, err := s.store.ClaimPlayback(r.Context(), deviceFrom(r.Context()), in.EpisodeID, in.Target)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toPlaybackDTO(l))
}

// handlePlaybackHeartbeat: 200 with the lock while this device may keep
// playing, 409 playback_conflict with the other device's lock otherwise.
func (s *Server) handlePlaybackHeartbeat(w http.ResponseWriter, r *http.Request) {
	in, ok := s.readPlaybackReq(w, r)
	if !ok {
		return
	}
	l, mine, err := s.store.HeartbeatPlayback(r.Context(), deviceFrom(r.Context()), in.EpisodeID, in.Target)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	if !mine {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error": "playback active on " + l.DeviceName, "code": "playback_conflict", "playback": toPlaybackDTO(l),
		})
		return
	}
	writeJSON(w, http.StatusOK, toPlaybackDTO(l))
}

func (s *Server) handlePlaybackRelease(w http.ResponseWriter, r *http.Request) {
	if err := s.store.ReleasePlayback(r.Context(), deviceFrom(r.Context())); err != nil {
		s.writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
