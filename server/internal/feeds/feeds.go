// Package feeds fetches and parses podcast RSS/Atom feeds, the iTunes search
// API and OPML documents.
package feeds

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/mmcdole/gofeed"
	ext "github.com/mmcdole/gofeed/extensions"

	"github.com/sebseifert/castqueue/internal/store"
)

const userAgent = "CastQueue/1.0 (+https://github.com/sebseifert/castqueue)"

var ErrNotModified = errors.New("not modified")

// ErrUnparseable means the server responded but the body is not a feed.
type ErrUnparseable struct{ Err error }

func (e ErrUnparseable) Error() string { return "feed could not be parsed: " + e.Err.Error() }
func (e ErrUnparseable) Unwrap() error { return e.Err }

type Client struct {
	HTTP *http.Client
}

func NewClient() *Client {
	return &Client{HTTP: &http.Client{Timeout: 45 * time.Second}}
}

type Result struct {
	Podcast  store.Podcast // Title, Description, Author, ImageURL, Website, ETag, LastModified filled
	Episodes []store.NewEpisode
}

// Fetch downloads and parses a feed. Conditional headers use etag/lastModified;
// ErrNotModified is returned on 304.
func (c *Client) Fetch(ctx context.Context, feedURL, username, password, etag, lastModified string) (Result, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, feedURL, nil)
	if err != nil {
		return Result{}, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "application/rss+xml, application/atom+xml, application/xml, text/xml, */*")
	if username != "" || password != "" {
		req.SetBasicAuth(username, password)
	}
	if etag != "" {
		req.Header.Set("If-None-Match", etag)
	}
	if lastModified != "" {
		req.Header.Set("If-Modified-Since", lastModified)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return Result{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotModified {
		return Result{}, ErrNotModified
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return Result{}, fmt.Errorf("feed returned HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 50<<20))
	if err != nil {
		return Result{}, err
	}
	res, err := Parse(body)
	if err != nil {
		return Result{}, err
	}
	res.Podcast.FeedURL = feedURL
	res.Podcast.ETag = resp.Header.Get("ETag")
	res.Podcast.LastModified = resp.Header.Get("Last-Modified")
	return res, nil
}

func Parse(body []byte) (Result, error) {
	feed, err := gofeed.NewParser().ParseString(string(body))
	if err != nil {
		return Result{}, ErrUnparseable{err}
	}
	var res Result
	p := &res.Podcast
	p.Title = strings.TrimSpace(feed.Title)
	p.Description = strings.TrimSpace(feed.Description)
	p.Website = feed.Link
	p.Language = strings.TrimSpace(feed.Language)
	p.Copyright = strings.TrimSpace(feed.Copyright)
	p.Categories = mergeCategories(feed.Categories, nil)
	if feed.Image != nil {
		p.ImageURL = feed.Image.URL
	}
	if feed.ITunesExt != nil {
		if feed.ITunesExt.Image != "" {
			p.ImageURL = feed.ITunesExt.Image
		}
		if feed.ITunesExt.Author != "" {
			p.Author = feed.ITunesExt.Author
		}
		if p.Description == "" && feed.ITunesExt.Summary != "" {
			p.Description = feed.ITunesExt.Summary
		}
		p.Categories = mergeCategories(feed.Categories, feed.ITunesExt.Categories)
		p.Explicit = isExplicit(feed.ITunesExt.Explicit)
		p.PodcastType = normalizePodcastType(feed.ITunesExt.Type)
		if feed.ITunesExt.Owner != nil {
			p.OwnerName = strings.TrimSpace(feed.ITunesExt.Owner.Name)
		}
	}
	if p.Author == "" && len(feed.Authors) > 0 {
		p.Author = feed.Authors[0].Name
	}
	for _, it := range feed.Items {
		e, ok := toEpisode(it)
		if ok {
			res.Episodes = append(res.Episodes, e)
		}
	}
	return res, nil
}

func toEpisode(it *gofeed.Item) (store.NewEpisode, bool) {
	var e store.NewEpisode
	for _, enc := range it.Enclosures {
		if enc == nil || enc.URL == "" {
			continue
		}
		if enc.Type == "" || strings.HasPrefix(enc.Type, "audio/") || strings.HasPrefix(enc.Type, "video/") || strings.HasPrefix(enc.Type, "application/octet") {
			e.MediaURL = enc.URL
			e.MediaType = enc.Type
			if n, err := strconv.ParseInt(strings.TrimSpace(enc.Length), 10, 64); err == nil {
				e.MediaSize = n
			}
			break
		}
	}
	if e.MediaURL == "" {
		return e, false // not a playable episode
	}
	e.GUID = strings.TrimSpace(it.GUID)
	if e.GUID == "" {
		e.GUID = e.MediaURL
	}
	e.Title = strings.TrimSpace(it.Title)
	e.Description = it.Content
	if e.Description == "" {
		e.Description = it.Description
	}
	e.Link = it.Link
	if it.Image != nil {
		e.ImageURL = it.Image.URL
	}
	if it.ITunesExt != nil {
		if it.ITunesExt.Image != "" {
			e.ImageURL = it.ITunesExt.Image
		}
		e.DurationMs = parseDuration(it.ITunesExt.Duration)
		if e.Description == "" {
			e.Description = it.ITunesExt.Summary
		}
		e.Season = parseSmallInt(it.ITunesExt.Season)
		e.EpisodeNumber = parseSmallInt(it.ITunesExt.Episode)
		e.EpisodeType = normalizeEpisodeType(it.ITunesExt.EpisodeType)
		e.Explicit = isExplicit(it.ITunesExt.Explicit)
		e.Author = strings.TrimSpace(it.ITunesExt.Author)
	}
	if e.Author == "" && len(it.Authors) > 0 && it.Authors[0] != nil {
		e.Author = strings.TrimSpace(it.Authors[0].Name)
	}
	if it.PublishedParsed != nil {
		e.PublishedAt = it.PublishedParsed.UTC()
	} else if it.UpdatedParsed != nil {
		e.PublishedAt = it.UpdatedParsed.UTC()
	}
	if e.MediaType == "" {
		e.MediaType = guessMime(e.MediaURL)
	}
	return e, true
}

// mergeCategories flattens plain RSS categories and iTunes categories (with
// subcategories) into one de-duplicated list, preserving first-seen order.
func mergeCategories(plain []string, itunes []*ext.ITunesCategory) []string {
	out := []string{}
	seen := map[string]bool{}
	add := func(c string) {
		c = strings.TrimSpace(c)
		if c == "" {
			return
		}
		key := strings.ToLower(c)
		if seen[key] {
			return
		}
		seen[key] = true
		out = append(out, c)
	}
	for _, c := range itunes {
		for cur := c; cur != nil; cur = cur.Subcategory {
			add(cur.Text)
		}
	}
	for _, c := range plain {
		add(c)
	}
	return out
}

func isExplicit(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "yes", "true", "explicit":
		return true
	}
	return false
}

func normalizePodcastType(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "episodic":
		return "episodic"
	case "serial":
		return "serial"
	}
	return ""
}

func normalizeEpisodeType(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "full":
		return "full"
	case "trailer":
		return "trailer"
	case "bonus":
		return "bonus"
	}
	return ""
}

// parseSmallInt reads season/episode numbers; anything odd becomes 0.
func parseSmallInt(s string) int {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil || n < 0 || n > 1_000_000 {
		return 0
	}
	return n
}

func guessMime(u string) string {
	parsed, err := url.Parse(u)
	if err != nil {
		return "audio/mpeg"
	}
	path := strings.ToLower(parsed.Path)
	switch {
	case strings.HasSuffix(path, ".m4a"), strings.HasSuffix(path, ".mp4"):
		return "audio/mp4"
	case strings.HasSuffix(path, ".aac"):
		return "audio/aac"
	case strings.HasSuffix(path, ".ogg"), strings.HasSuffix(path, ".oga"):
		return "audio/ogg"
	case strings.HasSuffix(path, ".opus"):
		return "audio/opus"
	case strings.HasSuffix(path, ".flac"):
		return "audio/flac"
	case strings.HasSuffix(path, ".wav"):
		return "audio/wav"
	}
	return "audio/mpeg"
}

// parseDuration handles "HH:MM:SS", "MM:SS", "SS" and "1234.5" (seconds).
func parseDuration(s string) int64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	parts := strings.Split(s, ":")
	var total float64
	for _, p := range parts {
		f, err := strconv.ParseFloat(strings.TrimSpace(p), 64)
		if err != nil {
			return 0
		}
		total = total*60 + f
	}
	if total < 0 {
		return 0
	}
	return int64(total * 1000)
}

// ---- iTunes search ----

type SearchResult struct {
	Title           string   `json:"title"`
	Author          string   `json:"author"`
	FeedURL         string   `json:"feed_url"`
	ImageURL        string   `json:"image_url"`
	Genres          []string `json:"genres"`
	EpisodeCount    int      `json:"episode_count"`
	LatestReleaseAt string   `json:"latest_release_at"` // RFC3339 or ""
	ITunesURL       string   `json:"itunes_url"`
	Explicit        bool     `json:"explicit"`
	Country         string   `json:"country"`
}

func (c *Client) Search(ctx context.Context, term string, limit int) ([]SearchResult, error) {
	q := url.Values{"media": {"podcast"}, "entity": {"podcast"}, "term": {term}, "limit": {strconv.Itoa(limit)}}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://itunes.apple.com/search?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("itunes search returned HTTP %d", resp.StatusCode)
	}
	var payload struct {
		Results []struct {
			CollectionName        string   `json:"collectionName"`
			ArtistName            string   `json:"artistName"`
			FeedURL               string   `json:"feedUrl"`
			ArtworkURL600         string   `json:"artworkUrl600"`
			ArtworkURL100         string   `json:"artworkUrl100"`
			Genres                []string `json:"genres"`
			TrackCount            int      `json:"trackCount"`
			ReleaseDate           string   `json:"releaseDate"`
			CollectionViewURL     string   `json:"collectionViewUrl"`
			ContentAdvisoryRating string   `json:"contentAdvisoryRating"`
			Country               string   `json:"country"`
		} `json:"results"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 5<<20)).Decode(&payload); err != nil {
		return nil, err
	}
	out := []SearchResult{}
	for _, r := range payload.Results {
		if r.FeedURL == "" {
			continue
		}
		img := r.ArtworkURL600
		if img == "" {
			img = r.ArtworkURL100
		}
		genres := []string{}
		for _, g := range r.Genres {
			g = strings.TrimSpace(g)
			if g != "" && !strings.EqualFold(g, "Podcasts") {
				genres = append(genres, g)
			}
		}
		release := ""
		if t, err := time.Parse(time.RFC3339, strings.TrimSpace(r.ReleaseDate)); err == nil {
			release = t.UTC().Format(time.RFC3339)
		}
		out = append(out, SearchResult{
			Title: r.CollectionName, Author: r.ArtistName, FeedURL: r.FeedURL, ImageURL: img,
			Genres: genres, EpisodeCount: r.TrackCount, LatestReleaseAt: release,
			ITunesURL: r.CollectionViewURL, Explicit: strings.EqualFold(r.ContentAdvisoryRating, "Explicit"),
			Country: r.Country,
		})
	}
	return out, nil
}

// ---- OPML ----

type opml struct {
	XMLName xml.Name    `xml:"opml"`
	Version string      `xml:"version,attr"`
	Head    opmlHead    `xml:"head"`
	Body    opmlOutline `xml:"body"`
}

type opmlHead struct {
	Title string `xml:"title"`
}

type opmlOutline struct {
	Outlines []opmlEntry `xml:"outline"`
}

type opmlEntry struct {
	Text     string      `xml:"text,attr,omitempty"`
	Title    string      `xml:"title,attr,omitempty"`
	Type     string      `xml:"type,attr,omitempty"`
	XMLURL   string      `xml:"xmlUrl,attr,omitempty"`
	HTMLURL  string      `xml:"htmlUrl,attr,omitempty"`
	Outlines []opmlEntry `xml:"outline,omitempty"`
}

func ExportOPML(podcasts []store.Podcast) ([]byte, error) {
	doc := opml{Version: "2.0", Head: opmlHead{Title: "CastQueue subscriptions"}}
	for _, p := range podcasts {
		doc.Body.Outlines = append(doc.Body.Outlines, opmlEntry{Text: p.Title, Title: p.Title, Type: "rss", XMLURL: p.FeedURL, HTMLURL: p.Website})
	}
	out, err := xml.MarshalIndent(doc, "", "  ")
	if err != nil {
		return nil, err
	}
	return append([]byte(xml.Header), out...), nil
}

// ParseOPML returns all feed URLs found (recursively).
func ParseOPML(body []byte) ([]string, error) {
	var doc opml
	if err := xml.Unmarshal(body, &doc); err != nil {
		return nil, err
	}
	var urls []string
	var walk func([]opmlEntry)
	walk = func(entries []opmlEntry) {
		for _, e := range entries {
			if u := strings.TrimSpace(e.XMLURL); u != "" {
				urls = append(urls, u)
			}
			walk(e.Outlines)
		}
	}
	walk(doc.Body.Outlines)
	return urls, nil
}
