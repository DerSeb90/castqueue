package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/sebseifert/castqueue/internal/config"
	"github.com/sebseifert/castqueue/internal/feeds"
	"github.com/sebseifert/castqueue/internal/refresh"
	"github.com/sebseifert/castqueue/internal/store"
)

const feedXML = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
<channel>
<title>Test Cast</title><link>https://example.com</link><description>desc</description>
<itunes:image href="https://example.com/cover.jpg"/><itunes:author>Tester</itunes:author>
%s
</channel></rss>`

func item(guid, title, day string) string {
	return fmt.Sprintf(`<item><title>%s</title><guid>%s</guid><pubDate>%s Jan 2026 10:00:00 +0000</pubDate>
<enclosure url="https://media.example.com/%s.mp3" type="audio/mpeg" length="1000"/><itunes:duration>01:00:00</itunes:duration>
<description><![CDATA[<p>Notes</p>]]></description></item>`, title, guid, day, guid)
}

type env struct {
	t       *testing.T
	srv     *httptest.Server
	feed    *httptest.Server
	items   []string
	token   string
	gotAuth string
}

func newEnv(t *testing.T) *env {
	t.Helper()
	e := &env{t: t, items: []string{item("ep1", "Episode 1", "01"), item("ep2", "Episode 2", "02")}}
	e.feed = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if u, p, ok := r.BasicAuth(); ok {
			e.gotAuth = u + ":" + p
		}
		if strings.HasSuffix(r.URL.Path, ".mp3") {
			w.Header().Set("Content-Type", "audio/mpeg")
			w.Header().Set("Accept-Ranges", "bytes")
			if rng := r.Header.Get("Range"); rng != "" {
				w.Header().Set("Content-Range", "bytes 2-4/10")
				w.WriteHeader(http.StatusPartialContent)
				_, _ = w.Write([]byte("cde"))
				return
			}
			_, _ = w.Write([]byte("abcdefghij"))
			return
		}
		w.Header().Set("Content-Type", "application/rss+xml")
		items := strings.ReplaceAll(strings.Join(e.items, "\n"), "https://media.example.com", e.feed.URL)
		fmt.Fprintf(w, feedXML, items)
	}))
	t.Cleanup(e.feed.Close)

	st, err := store.OpenMemory()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	cfg := config.Config{Username: "seb", Password: "secret", PublicURL: "https://pods.test", RefreshMinutes: 30}
	fc := feeds.NewClient()
	rf := refresh.New(st, fc, time.Hour, log)
	web := fstest.MapFS{"index.html": {Data: []byte("<html>spa</html>")}}
	s := New(cfg, st, fc, rf, web, log)
	e.srv = httptest.NewServer(s.Handler())
	t.Cleanup(e.srv.Close)
	return e
}

func (e *env) do(method, path string, body any, out any) int {
	e.t.Helper()
	var rdr io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.srv.URL+path, rdr)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if e.token != "" {
		req.Header.Set("Authorization", "Bearer "+e.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if out != nil && len(data) > 0 {
		if err := json.Unmarshal(data, out); err != nil {
			e.t.Fatalf("%s %s: bad json %q: %v", method, path, data, err)
		}
	}
	return resp.StatusCode
}

func (e *env) login() {
	e.t.Helper()
	var out struct {
		Token string `json:"token"`
	}
	if code := e.do("POST", "/api/auth/login", map[string]string{"username": "seb", "password": "secret", "device_name": "test"}, &out); code != 200 {
		e.t.Fatalf("login: %d", code)
	}
	e.token = out.Token
}

func TestAuthRequired(t *testing.T) {
	e := newEnv(t)
	if code := e.do("GET", "/api/podcasts", nil, nil); code != 401 {
		t.Fatalf("expected 401, got %d", code)
	}
	var errBody map[string]string
	if code := e.do("POST", "/api/auth/login", map[string]string{"username": "seb", "password": "wrong"}, &errBody); code != 401 {
		t.Fatalf("expected 401, got %d", code)
	}
	for range 5 {
		e.do("POST", "/api/auth/login", map[string]string{"username": "seb", "password": "wrong"}, nil)
	}
	if code := e.do("POST", "/api/auth/login", map[string]string{"username": "seb", "password": "secret"}, nil); code != 429 {
		t.Fatalf("expected rate limit 429, got %d", code)
	}
	var health map[string]any
	if code := e.do("GET", "/api/health", nil, &health); code != 200 || health["ok"] != true {
		t.Fatalf("health: %d %v", code, health)
	}
}

func TestSubscribeQueueProgressUnsubscribe(t *testing.T) {
	e := newEnv(t)
	e.login()

	var p podcastDTO
	if code := e.do("POST", "/api/podcasts", map[string]any{"feed_url": e.feed.URL + "/feed.xml"}, &p); code != 201 {
		t.Fatalf("subscribe: %d", code)
	}
	if p.Title != "Test Cast" || p.EpisodeCount != 2 || !p.AutoEnqueue {
		t.Fatalf("podcast: %+v", p)
	}
	// duplicate subscribe → 200
	if code := e.do("POST", "/api/podcasts", map[string]any{"feed_url": e.feed.URL + "/feed.xml"}, nil); code != 200 {
		t.Fatalf("duplicate subscribe: %d", code)
	}
	var eps []episodeDTO
	e.do("GET", "/api/podcasts/"+p.ID+"/episodes", nil, &eps)
	if len(eps) != 2 || eps[0].Title != "Episode 2" || eps[0].DurationMs != 3600000 || eps[0].StreamURL != eps[0].MediaURL {
		t.Fatalf("episodes: %+v", eps)
	}
	var q queueDTO
	e.do("GET", "/api/queue", nil, &q)
	if len(q.Items) != 0 {
		t.Fatal("back catalogue must not be enqueued")
	}

	// new episode appears on refresh → auto-enqueued
	e.items = append([]string{item("ep3", "Episode 3", "03")}, e.items...)
	var rr map[string]int
	if code := e.do("POST", "/api/podcasts/refresh", nil, &rr); code != 200 || rr["refreshed"] != 1 {
		t.Fatalf("refresh: %d %v", code, rr)
	}
	e.do("GET", "/api/queue", nil, &q)
	if len(q.Items) != 1 || q.Items[0].Title != "Episode 3" || q.Version != 1 {
		t.Fatalf("queue after refresh: %+v", q)
	}

	// add ep1 to front, replace with version check
	if code := e.do("POST", "/api/queue/items", map[string]any{"episode_id": eps[1].ID, "position": "front"}, &q); code != 200 || q.Items[0].ID != eps[1].ID {
		t.Fatalf("queue add: %d %+v", code, q)
	}
	var conflict queueDTO
	if code := e.do("PUT", "/api/queue", map[string]any{"version": 0, "episode_ids": []string{eps[1].ID}}, &conflict); code != 409 || conflict.Version != q.Version {
		t.Fatalf("expected 409 with current queue, got %d %+v", code, conflict)
	}
	if code := e.do("PUT", "/api/queue", map[string]any{"version": q.Version, "episode_ids": []string{q.Items[1].ID, q.Items[0].ID}}, &q); code != 200 || q.Items[0].Title != "Episode 3" {
		t.Fatalf("replace: %d %+v", code, q)
	}

	// progress: LWW + played removes from queue
	var ep episodeDTO
	ts := time.Now().UTC().Format(time.RFC3339)
	if code := e.do("PUT", "/api/episodes/"+eps[1].ID+"/progress", map[string]any{"position_ms": 12000, "updated_at": ts}, &ep); code != 200 || ep.PositionMs != 12000 {
		t.Fatalf("progress: %d %+v", code, ep)
	}
	old := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	e.do("PUT", "/api/episodes/"+eps[1].ID+"/progress", map[string]any{"position_ms": 1, "updated_at": old}, &ep)
	if ep.PositionMs != 12000 {
		t.Fatal("stale progress applied")
	}
	var batch struct {
		Episodes []episodeDTO `json:"episodes"`
	}
	later := time.Now().Add(time.Second).UTC().Format(time.RFC3339Nano)
	e.do("POST", "/api/progress/batch", map[string]any{"items": []map[string]any{{"episode_id": eps[1].ID, "position_ms": 3600000, "played": true, "updated_at": later}}}, &batch)
	if len(batch.Episodes) != 1 || !batch.Episodes[0].Played || batch.Episodes[0].InQueue {
		t.Fatalf("batch: %+v", batch)
	}
	e.do("GET", "/api/queue", nil, &q)
	if len(q.Items) != 1 {
		t.Fatalf("played episode still queued: %+v", q)
	}

	// sync delta contains the changes
	var sync struct {
		ServerTime string       `json:"server_time"`
		Episodes   []episodeDTO `json:"episodes"`
		Queue      struct {
			Version    int64    `json:"version"`
			EpisodeIDs []string `json:"episode_ids"`
		} `json:"queue"`
	}
	e.do("GET", "/api/sync", nil, &sync)
	if len(sync.Episodes) != 3 || len(sync.Queue.EpisodeIDs) != 1 {
		t.Fatalf("full sync: %d episodes, queue %v", len(sync.Episodes), sync.Queue.EpisodeIDs)
	}

	// unsubscribe → queue emptied, tombstones in delta.
	// (Windows wall clock ticks coarsely, so take `since` slightly in the past.)
	since := time.Now().Add(-50 * time.Millisecond).UTC().Format(time.RFC3339Nano)
	if code := e.do("DELETE", "/api/podcasts/"+p.ID, nil, nil); code != 204 {
		t.Fatalf("unsubscribe: %d", code)
	}
	e.do("GET", "/api/queue", nil, &q)
	if len(q.Items) != 0 {
		t.Fatalf("queue after unsubscribe: %+v", q)
	}
	var delta struct {
		PodcastsDeleted []string `json:"podcasts_deleted"`
		EpisodesDeleted []string `json:"episodes_deleted"`
	}
	e.do("GET", "/api/sync?since="+since, nil, &delta)
	if len(delta.PodcastsDeleted) != 1 || len(delta.EpisodesDeleted) != 3 {
		t.Fatalf("delta tombstones: %+v", delta)
	}
}

func TestPremiumFeedStreamProxy(t *testing.T) {
	e := newEnv(t)
	e.login()
	var p podcastDTO
	if code := e.do("POST", "/api/podcasts", map[string]any{"feed_url": e.feed.URL + "/premium.xml", "auth_username": "u", "auth_password": "p"}, &p); code != 201 || !p.HasAuth {
		t.Fatalf("subscribe premium: %d %+v", code, p)
	}
	if e.gotAuth != "u:p" {
		t.Fatalf("feed fetched without basic auth: %q", e.gotAuth)
	}
	var eps []episodeDTO
	e.do("GET", "/api/podcasts/"+p.ID+"/episodes", nil, &eps)
	if !strings.HasPrefix(eps[0].StreamURL, "https://pods.test/stream/"+eps[0].ID+"?t=") {
		t.Fatalf("stream_url: %s", eps[0].StreamURL)
	}
	// proxy: token required, range forwarded, auth added
	path := strings.TrimPrefix(eps[0].StreamURL, "https://pods.test")
	e.gotAuth = ""
	req, _ := http.NewRequest("GET", e.srv.URL+path, nil)
	req.Header.Set("Range", "bytes=2-4")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 206 || string(body) != "cde" || resp.Header.Get("Content-Range") == "" || resp.Header.Get("Content-Type") != "audio/mpeg" {
		t.Fatalf("proxy: %d %q %v", resp.StatusCode, body, resp.Header)
	}
	if e.gotAuth != "u:p" {
		t.Fatalf("media fetched without basic auth: %q", e.gotAuth)
	}
	resp, _ = http.Get(e.srv.URL + "/stream/" + eps[0].ID + "?t=wrong")
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatalf("bad token accepted: %d", resp.StatusCode)
	}
	// rotate token → old url invalid, episodes re-synced
	var rot map[string]string
	e.do("POST", "/api/stream-token/rotate", nil, &rot)
	resp, _ = http.Get(e.srv.URL + path)
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatalf("old token still valid: %d", resp.StatusCode)
	}
	var again []episodeDTO
	e.do("GET", "/api/podcasts/"+p.ID+"/episodes", nil, &again)
	if !strings.Contains(again[0].StreamURL, rot["stream_token"]) {
		t.Fatal("stream_url not rotated")
	}
}

func TestOPMLRoundTripAndSPA(t *testing.T) {
	e := newEnv(t)
	e.login()
	e.do("POST", "/api/podcasts", map[string]any{"feed_url": e.feed.URL + "/a.xml"}, nil)
	req, _ := http.NewRequest("GET", e.srv.URL+"/api/opml", nil)
	req.Header.Set("Authorization", "Bearer "+e.token)
	resp, _ := http.DefaultClient.Do(req)
	opml, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(string(opml), e.feed.URL+"/a.xml") {
		t.Fatalf("opml export: %s", opml)
	}
	imp := strings.ReplaceAll(string(opml), "/a.xml", "/b.xml")
	req, _ = http.NewRequest("POST", e.srv.URL+"/api/opml", strings.NewReader(imp))
	req.Header.Set("Authorization", "Bearer "+e.token)
	req.Header.Set("Content-Type", "text/xml")
	resp, _ = http.DefaultClient.Do(req)
	var res struct {
		Added   int `json:"added"`
		Skipped int `json:"skipped"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&res)
	resp.Body.Close()
	if res.Added != 1 {
		t.Fatalf("opml import: %+v", res)
	}
	// SPA fallback for deep links
	resp, _ = http.Get(e.srv.URL + "/some/deep/link")
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(body), "spa") {
		t.Fatalf("spa fallback: %d %s", resp.StatusCode, body)
	}
}
