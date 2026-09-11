package store

import (
	"context"
	"encoding/json"
	"time"
)

const kvPlaybackLock = "playback_lock"

// PlaybackStaleAfter is how long a lock survives without a heartbeat.
const PlaybackStaleAfter = 45 * time.Second

// PlaybackLock records which device is currently playing. Only one device
// may play at a time; a claim always takes over, a heartbeat only succeeds
// for the holder (or when the lock is stale).
type PlaybackLock struct {
	DeviceID    string    `json:"device_id"`
	DeviceName  string    `json:"device_name"`
	EpisodeID   string    `json:"episode_id"`
	Target      string    `json:"target"`
	StartedAt   time.Time `json:"started_at"`
	HeartbeatAt time.Time `json:"heartbeat_at"`
}

func (l PlaybackLock) Active() bool { return l.DeviceID != "" }

func (l PlaybackLock) Stale(now time.Time) bool {
	return !l.Active() || now.Sub(l.HeartbeatAt) > PlaybackStaleAfter
}

func (s *Store) GetPlaybackLock(ctx context.Context) (PlaybackLock, error) {
	raw, err := s.getKV(ctx, s.db, kvPlaybackLock, "")
	if err != nil || raw == "" {
		return PlaybackLock{}, err
	}
	var l PlaybackLock
	if err := json.Unmarshal([]byte(raw), &l); err != nil {
		return PlaybackLock{}, nil
	}
	return l, nil
}

func (s *Store) savePlaybackLock(ctx context.Context, l PlaybackLock) error {
	raw, err := json.Marshal(l)
	if err != nil {
		return err
	}
	return s.setKV(ctx, s.db, kvPlaybackLock, string(raw))
}

// ClaimPlayback makes dev the holder, taking over from any other device.
func (s *Store) ClaimPlayback(ctx context.Context, dev Device, episodeID, target string) (PlaybackLock, error) {
	now := Now()
	cur, err := s.GetPlaybackLock(ctx)
	if err != nil {
		return PlaybackLock{}, err
	}
	l := PlaybackLock{DeviceID: dev.ID, DeviceName: dev.Name, EpisodeID: episodeID, Target: target, StartedAt: now, HeartbeatAt: now}
	if cur.DeviceID == dev.ID && !cur.Stale(now) && cur.EpisodeID == episodeID {
		l.StartedAt = cur.StartedAt
	}
	return l, s.savePlaybackLock(ctx, l)
}

// HeartbeatPlayback refreshes the holder's lock. ok is false when another
// device holds a live lock; the returned lock then describes that device.
func (s *Store) HeartbeatPlayback(ctx context.Context, dev Device, episodeID, target string) (lock PlaybackLock, ok bool, err error) {
	now := Now()
	cur, err := s.GetPlaybackLock(ctx)
	if err != nil {
		return PlaybackLock{}, false, err
	}
	if cur.Active() && cur.DeviceID != dev.ID && !cur.Stale(now) {
		return cur, false, nil
	}
	l := cur
	if cur.DeviceID != dev.ID || cur.EpisodeID != episodeID || cur.Stale(now) {
		l = PlaybackLock{DeviceID: dev.ID, DeviceName: dev.Name, EpisodeID: episodeID, StartedAt: now}
	}
	l.DeviceName = dev.Name
	if target != "" {
		l.Target = target
	}
	l.HeartbeatAt = now
	return l, true, s.savePlaybackLock(ctx, l)
}

// ReleasePlayback clears the lock if dev holds it.
func (s *Store) ReleasePlayback(ctx context.Context, dev Device) error {
	cur, err := s.GetPlaybackLock(ctx)
	if err != nil {
		return err
	}
	if !cur.Active() || cur.DeviceID != dev.ID {
		return nil
	}
	return s.setKV(ctx, s.db, kvPlaybackLock, "")
}
