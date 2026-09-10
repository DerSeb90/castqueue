package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := OpenMemory()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func addPodcast(t *testing.T, s *Store, title string, n int) Podcast {
	t.Helper()
	p := Podcast{FeedURL: "https://example.com/" + title + ".xml", Title: title, AutoEnqueue: true}
	var eps []NewEpisode
	for i := range n {
		eps = append(eps, NewEpisode{GUID: title + "-" + string(rune('a'+i)), Title: "Ep " + string(rune('A'+i)), MediaURL: "https://cdn/" + title + "/" + string(rune('a'+i)) + ".mp3", PublishedAt: time.Date(2026, 1, 1+i, 0, 0, 0, 0, time.UTC), DurationMs: 60000})
	}
	if err := s.CreatePodcast(context.Background(), &p, eps); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestCreateDoesNotEnqueueBackCatalogue(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	addPodcast(t, s, "one", 3)
	q, err := s.GetQueue(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(q.EpisodeIDs) != 0 || q.Version != 0 {
		t.Fatalf("expected empty queue, got %+v", q)
	}
}

func TestRefreshAutoEnqueuesNewEpisodesInOrder(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	p := addPodcast(t, s, "one", 1)
	newEps := []NewEpisode{
		{GUID: "new-2", Title: "Newest", MediaURL: "https://cdn/n2.mp3", PublishedAt: time.Date(2026, 2, 2, 0, 0, 0, 0, time.UTC)},
		{GUID: "new-1", Title: "Newer", MediaURL: "https://cdn/n1.mp3", PublishedAt: time.Date(2026, 2, 1, 0, 0, 0, 0, time.UTC)},
		{GUID: "one-a", Title: "Ep A (renamed)", MediaURL: "https://cdn/one/a.mp3", PublishedAt: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)},
	}
	ids, err := s.ApplyRefresh(ctx, p, newEps, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) != 2 {
		t.Fatalf("expected 2 new ids, got %d", len(ids))
	}
	q, _ := s.GetQueue(ctx)
	if len(q.EpisodeIDs) != 2 || q.Version != 1 {
		t.Fatalf("queue: %+v", q)
	}
	eps, _ := s.GetEpisodes(ctx, q.EpisodeIDs)
	if eps[0].Title != "Newer" || eps[1].Title != "Newest" {
		t.Fatalf("expected chronological order, got %s, %s", eps[0].Title, eps[1].Title)
	}
	// renamed episode updated, not duplicated
	all, _ := s.ListPodcastEpisodes(ctx, p.ID, 100, 0)
	if len(all) != 3 {
		t.Fatalf("expected 3 episodes, got %d", len(all))
	}
	// second refresh with same data → nothing new, queue unchanged
	ids, _ = s.ApplyRefresh(ctx, p, newEps, "")
	q2, _ := s.GetQueue(ctx)
	if len(ids) != 0 || q2.Version != 1 {
		t.Fatalf("idempotent refresh failed: ids=%v version=%d", ids, q2.Version)
	}
}

func TestQueueOperations(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	p := addPodcast(t, s, "one", 4)
	eps, _ := s.ListPodcastEpisodes(ctx, p.ID, 10, 0) // newest first: D C B A
	a, b, c, d := eps[3].ID, eps[2].ID, eps[1].ID, eps[0].ID

	q, err := s.QueueAdd(ctx, a, -1)
	if err != nil {
		t.Fatal(err)
	}
	q, _ = s.QueueAdd(ctx, b, -1)
	q, _ = s.QueueAdd(ctx, c, 0) // front
	if got := q.EpisodeIDs; got[0] != c || got[1] != a || got[2] != b {
		t.Fatalf("order: %v", got)
	}
	// adding an existing one moves it
	q, _ = s.QueueAdd(ctx, b, 0)
	if q.EpisodeIDs[0] != b || len(q.EpisodeIDs) != 3 {
		t.Fatalf("move-on-add: %v", q.EpisodeIDs)
	}
	q, _ = s.QueueMove(ctx, b, 2)
	if q.EpisodeIDs[2] != b {
		t.Fatalf("move: %v", q.EpisodeIDs)
	}
	if _, err := s.QueueMove(ctx, d, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("move of unqueued should be not found, got %v", err)
	}
	q, _ = s.QueueRemove(ctx, a)
	if len(q.EpisodeIDs) != 2 {
		t.Fatalf("remove: %v", q.EpisodeIDs)
	}
	ver := q.Version
	// replace with stale version → conflict
	if _, err := s.ReplaceQueue(ctx, ver-1, []string{a, b}); !errors.Is(err, ErrQueueConflict) {
		t.Fatalf("expected conflict, got %v", err)
	}
	q, err = s.ReplaceQueue(ctx, ver, []string{d, a, "does-not-exist", a})
	if err != nil {
		t.Fatal(err)
	}
	if len(q.EpisodeIDs) != 2 || q.EpisodeIDs[0] != d || q.EpisodeIDs[1] != a || q.Version != ver+1 {
		t.Fatalf("replace: %+v", q)
	}
	e, _ := s.GetEpisode(ctx, d)
	if !e.InQueue {
		t.Fatal("in_queue flag not set")
	}
}

func TestProgressLastWriteWinsAndAutoRemove(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	p := addPodcast(t, s, "one", 1)
	eps, _ := s.ListPodcastEpisodes(ctx, p.ID, 10, 0)
	id := eps[0].ID
	s.QueueAdd(ctx, id, -1)

	t1 := time.Date(2026, 3, 1, 10, 0, 0, 0, time.UTC)
	applied, _, err := s.UpdateProgress(ctx, ProgressUpdate{EpisodeID: id, PositionMs: 5000, UpdatedAt: t1}, true)
	if err != nil || !applied {
		t.Fatalf("first update: applied=%v err=%v", applied, err)
	}
	// older update is ignored
	applied, _, _ = s.UpdateProgress(ctx, ProgressUpdate{EpisodeID: id, PositionMs: 1000, UpdatedAt: t1.Add(-time.Minute)}, true)
	if applied {
		t.Fatal("stale update applied")
	}
	e, _ := s.GetEpisode(ctx, id)
	if e.PositionMs != 5000 || !e.InQueue {
		t.Fatalf("unexpected %+v", e)
	}
	// played → removed from queue
	played := true
	dur := int64(60000)
	applied, queueChanged, _ := s.UpdateProgress(ctx, ProgressUpdate{EpisodeID: id, PositionMs: 60000, DurationMs: &dur, Played: &played, UpdatedAt: t1.Add(time.Minute)}, true)
	if !applied || !queueChanged {
		t.Fatalf("played update: applied=%v queueChanged=%v", applied, queueChanged)
	}
	e, _ = s.GetEpisode(ctx, id)
	if !e.Played || e.InQueue {
		t.Fatalf("expected played & dequeued, got %+v", e)
	}
	if _, _, err := s.UpdateProgress(ctx, ProgressUpdate{EpisodeID: "nope", UpdatedAt: t1}, true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected not found, got %v", err)
	}
}

func TestUnsubscribeRemovesFromQueueAndWritesTombstones(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	p1 := addPodcast(t, s, "one", 2)
	p2 := addPodcast(t, s, "two", 1)
	e1, _ := s.ListPodcastEpisodes(ctx, p1.ID, 10, 0)
	e2, _ := s.ListPodcastEpisodes(ctx, p2.ID, 10, 0)
	s.QueueAdd(ctx, e1[0].ID, -1)
	s.QueueAdd(ctx, e2[0].ID, -1)
	s.QueueAdd(ctx, e1[1].ID, -1)
	before, _ := s.GetQueue(ctx)
	time.Sleep(20 * time.Millisecond)
	syncTime := Now()
	time.Sleep(20 * time.Millisecond)

	if err := s.DeletePodcast(ctx, p1.ID); err != nil {
		t.Fatal(err)
	}
	q, _ := s.GetQueue(ctx)
	if len(q.EpisodeIDs) != 1 || q.EpisodeIDs[0] != e2[0].ID || q.Version != before.Version+1 {
		t.Fatalf("queue after unsubscribe: %+v (before %+v)", q, before)
	}
	if _, err := s.GetEpisode(ctx, e1[0].ID); !errors.Is(err, ErrNotFound) {
		t.Fatal("episode should be gone")
	}
	d, err := s.Sync(ctx, syncTime, Settings{})
	if err != nil {
		t.Fatal(err)
	}
	if len(d.PodcastsDeleted) != 1 || d.PodcastsDeleted[0] != p1.ID || len(d.EpisodesDeleted) != 2 {
		t.Fatalf("tombstones: %+v", d)
	}
	if err := s.DeletePodcast(ctx, p1.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("double delete: %v", err)
	}
}

func TestSyncFullAndDelta(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	p := addPodcast(t, s, "one", 2)
	full, err := s.Sync(ctx, time.Time{}, Settings{})
	if err != nil {
		t.Fatal(err)
	}
	if len(full.Podcasts) != 1 || len(full.Episodes) != 2 {
		t.Fatalf("full sync: %d podcasts %d episodes", len(full.Podcasts), len(full.Episodes))
	}
	// wait past the 2s server_time skew so the delta is clean
	since := full.ServerTime.Add(3 * time.Second)
	delta, _ := s.Sync(ctx, since, Settings{})
	if len(delta.Podcasts) != 0 || len(delta.Episodes) != 0 {
		t.Fatalf("expected empty delta, got %d/%d", len(delta.Podcasts), len(delta.Episodes))
	}
	eps, _ := s.ListPodcastEpisodes(ctx, p.ID, 10, 0)
	// Windows wall clock ticks coarsely: leave a gap around `since`.
	time.Sleep(20 * time.Millisecond)
	sinceProgress := Now()
	time.Sleep(20 * time.Millisecond)
	// progress update bumps the episode
	future := Now().Add(5 * time.Second)
	if _, _, err := s.UpdateProgress(ctx, ProgressUpdate{EpisodeID: eps[0].ID, PositionMs: 100, UpdatedAt: future}, true); err != nil {
		t.Fatal(err)
	}
	delta, _ = s.Sync(ctx, sinceProgress, Settings{})
	if len(delta.Episodes) != 1 || delta.Episodes[0].PositionMs != 100 {
		t.Fatalf("delta after progress: %+v", delta.Episodes)
	}
}

func TestDevicesAndTokens(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	d, token, err := s.CreateDevice(ctx, "PC")
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.DeviceByToken(ctx, token)
	if err != nil || got.ID != d.ID {
		t.Fatalf("lookup: %v %+v", err, got)
	}
	if _, err := s.DeviceByToken(ctx, "bogus"); !errors.Is(err, ErrNotFound) {
		t.Fatal("bogus token accepted")
	}
	if err := s.DeleteDevice(ctx, d.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DeviceByToken(ctx, token); !errors.Is(err, ErrNotFound) {
		t.Fatal("revoked token accepted")
	}
	t1, _ := s.StreamToken(ctx)
	t2, _ := s.StreamToken(ctx)
	if t1 == "" || t1 != t2 {
		t.Fatal("stream token not stable")
	}
	t3, _ := s.RotateStreamToken(ctx)
	if t3 == t1 {
		t.Fatal("rotate did nothing")
	}
}

func TestTimeFormatIsSortable(t *testing.T) {
	a := FormatTime(time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC))
	b := FormatTime(time.Date(2026, 1, 1, 12, 0, 0, 500_000_000, time.UTC))
	c := FormatTime(time.Date(2026, 1, 1, 12, 0, 1, 0, time.UTC))
	if !(a < b && b < c) {
		t.Fatalf("not sortable: %s %s %s", a, b, c)
	}
	if _, ok := ParseTime("2026-09-10T12:34:56Z"); !ok {
		t.Fatal("rfc3339 without fraction must parse")
	}
	if _, ok := ParseTime(a); !ok {
		t.Fatal("own format must parse")
	}
}
