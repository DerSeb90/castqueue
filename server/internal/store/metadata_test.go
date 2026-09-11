package store

import (
	"context"
	"testing"
	"time"
)

func TestPodcastAndEpisodeMetadataRoundTrip(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	p := Podcast{
		FeedURL: "https://example.com/meta.xml", Title: "Meta", AutoEnqueue: true,
		Language: "de-DE", Copyright: "© 2026 Example", Categories: []string{"Technology", "Tech News"},
		Explicit: true, PodcastType: "serial", OwnerName: "Owner Person",
	}
	eps := []NewEpisode{{
		GUID: "m-1", Title: "Pilot", MediaURL: "https://cdn/m1.mp3", PublishedAt: time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC),
		Season: 2, EpisodeNumber: 14, EpisodeType: "trailer", Explicit: true, Author: "Host Name",
	}}
	if err := s.CreatePodcast(ctx, &p, eps); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetPodcast(ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Language != "de-DE" || got.Copyright != "© 2026 Example" || !got.Explicit || got.PodcastType != "serial" || got.OwnerName != "Owner Person" {
		t.Fatalf("podcast metadata lost: %+v", got)
	}
	if len(got.Categories) != 2 || got.Categories[0] != "Technology" || got.Categories[1] != "Tech News" {
		t.Fatalf("categories: %v", got.Categories)
	}
	list, err := s.ListPodcastEpisodes(ctx, p.ID, 10, 0)
	if err != nil || len(list) != 1 {
		t.Fatalf("episodes: %v %d", err, len(list))
	}
	e := list[0]
	if e.Season != 2 || e.EpisodeNumber != 14 || e.EpisodeType != "trailer" || !e.Explicit || e.Author != "Host Name" {
		t.Fatalf("episode metadata lost: %+v", e)
	}

	// refresh updates podcast + episode metadata, and a metadata-only change bumps updated_at
	before := e.UpdatedAt
	time.Sleep(2 * time.Millisecond)
	p.Categories = []string{"Comedy"}
	p.Explicit = false
	p.PodcastType = "episodic"
	eps[0].Season = 3
	eps[0].EpisodeType = "full"
	if _, err := s.ApplyRefresh(ctx, p, eps, ""); err != nil {
		t.Fatal(err)
	}
	got, _ = s.GetPodcast(ctx, p.ID)
	if len(got.Categories) != 1 || got.Categories[0] != "Comedy" || got.Explicit || got.PodcastType != "episodic" {
		t.Fatalf("podcast refresh metadata: %+v", got)
	}
	list, _ = s.ListPodcastEpisodes(ctx, p.ID, 10, 0)
	if list[0].Season != 3 || list[0].EpisodeType != "full" {
		t.Fatalf("episode refresh metadata: %+v", list[0])
	}
	if !list[0].UpdatedAt.After(before) {
		t.Fatalf("metadata change should bump updated_at: %v !> %v", list[0].UpdatedAt, before)
	}
}

func TestEmptyCategoriesNeverNil(t *testing.T) {
	s := newTestStore(t)
	p := addPodcast(t, s, "plain", 1)
	got, err := s.GetPodcast(context.Background(), p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Categories == nil || len(got.Categories) != 0 {
		t.Fatalf("expected empty non-nil categories, got %#v", got.Categories)
	}
}

func TestMigrateIsIdempotent(t *testing.T) {
	s := newTestStore(t)
	if err := s.migrate(); err != nil {
		t.Fatal(err)
	}
	has, err := s.hasColumn("episodes", "episode_number")
	if err != nil || !has {
		t.Fatalf("column missing after second migrate: %v", err)
	}
}
