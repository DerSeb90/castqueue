package store

import (
	"context"
	"testing"
	"time"
)

func TestPlaybackLock(t *testing.T) {
	s, err := OpenMemory()
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	phone := Device{ID: "phone", Name: "Handy"}
	pc := Device{ID: "pc", Name: "PC"}

	l, err := s.GetPlaybackLock(ctx)
	if err != nil || l.Active() {
		t.Fatalf("expected no lock, got %+v err=%v", l, err)
	}

	if _, err := s.ClaimPlayback(ctx, phone, "ep1", "Lokal"); err != nil {
		t.Fatal(err)
	}
	l, ok, err := s.HeartbeatPlayback(ctx, pc, "ep1", "")
	if err != nil || ok || l.DeviceID != "phone" {
		t.Fatalf("pc heartbeat should be rejected while phone holds lock: ok=%v lock=%+v err=%v", ok, l, err)
	}
	l, ok, err = s.HeartbeatPlayback(ctx, phone, "ep1", "")
	if err != nil || !ok || l.Target != "Lokal" {
		t.Fatalf("holder heartbeat: ok=%v lock=%+v err=%v", ok, l, err)
	}

	// Takeover by claim.
	if _, err := s.ClaimPlayback(ctx, pc, "ep2", "Sonos"); err != nil {
		t.Fatal(err)
	}
	l, ok, _ = s.HeartbeatPlayback(ctx, phone, "ep1", "")
	if ok || l.DeviceID != "pc" || l.EpisodeID != "ep2" {
		t.Fatalf("phone should lose after pc claim: ok=%v lock=%+v", ok, l)
	}

	// Stale lock can be taken by heartbeat.
	stale := l
	stale.HeartbeatAt = Now().Add(-2 * PlaybackStaleAfter)
	if err := s.savePlaybackLock(ctx, stale); err != nil {
		t.Fatal(err)
	}
	l, ok, _ = s.HeartbeatPlayback(ctx, phone, "ep1", "Lokal")
	if !ok || l.DeviceID != "phone" || l.EpisodeID != "ep1" {
		t.Fatalf("stale lock should be taken: ok=%v lock=%+v", ok, l)
	}
	if time.Since(l.HeartbeatAt) > time.Minute {
		t.Fatal("heartbeat not refreshed")
	}

	// Release by non-holder is a no-op, by holder clears.
	if err := s.ReleasePlayback(ctx, pc); err != nil {
		t.Fatal(err)
	}
	if l, _ := s.GetPlaybackLock(ctx); !l.Active() {
		t.Fatal("non-holder release must not clear")
	}
	if err := s.ReleasePlayback(ctx, phone); err != nil {
		t.Fatal(err)
	}
	if l, _ := s.GetPlaybackLock(ctx); l.Active() {
		t.Fatal("holder release should clear")
	}
}
