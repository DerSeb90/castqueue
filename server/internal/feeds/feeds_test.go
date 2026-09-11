package feeds

import "testing"

const sampleFeed = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
<channel>
  <title>Sample Cast</title>
  <link>https://example.com</link>
  <language>de-de</language>
  <copyright>© 2026 Sample</copyright>
  <category>News</category>
  <itunes:author>Sample Author</itunes:author>
  <itunes:explicit>yes</itunes:explicit>
  <itunes:type>serial</itunes:type>
  <itunes:owner><itunes:name>Owner Name</itunes:name><itunes:email>o@example.com</itunes:email></itunes:owner>
  <itunes:category text="Technology"><itunes:category text="Tech News"/></itunes:category>
  <itunes:category text="News"/>
  <item>
    <title>Ep 1</title>
    <guid>g1</guid>
    <enclosure url="https://cdn.example.com/1.mp3" length="1000" type="audio/mpeg"/>
    <itunes:season>2</itunes:season>
    <itunes:episode>14</itunes:episode>
    <itunes:episodeType>bonus</itunes:episodeType>
    <itunes:explicit>true</itunes:explicit>
    <itunes:author>Guest Host</itunes:author>
    <itunes:duration>01:02:03</itunes:duration>
  </item>
</channel>
</rss>`

func TestParseExtractsMetadata(t *testing.T) {
	res, err := Parse([]byte(sampleFeed))
	if err != nil {
		t.Fatal(err)
	}
	p := res.Podcast
	if p.Language != "de-de" || p.Copyright != "© 2026 Sample" || !p.Explicit || p.PodcastType != "serial" || p.OwnerName != "Owner Name" {
		t.Fatalf("podcast metadata: %+v", p)
	}
	want := []string{"Technology", "Tech News", "News"}
	if len(p.Categories) != len(want) {
		t.Fatalf("categories: %v", p.Categories)
	}
	for i := range want {
		if p.Categories[i] != want[i] {
			t.Fatalf("categories: %v, want %v", p.Categories, want)
		}
	}
	if len(res.Episodes) != 1 {
		t.Fatalf("episodes: %d", len(res.Episodes))
	}
	e := res.Episodes[0]
	if e.Season != 2 || e.EpisodeNumber != 14 || e.EpisodeType != "bonus" || !e.Explicit || e.Author != "Guest Host" {
		t.Fatalf("episode metadata: %+v", e)
	}
	if e.DurationMs != (1*3600+2*60+3)*1000 {
		t.Fatalf("duration: %d", e.DurationMs)
	}
}

func TestNormalizers(t *testing.T) {
	if !isExplicit("Yes") || isExplicit("no") || isExplicit("") || !isExplicit("explicit") {
		t.Fatal("isExplicit")
	}
	if normalizePodcastType("Serial") != "serial" || normalizePodcastType("weird") != "" {
		t.Fatal("normalizePodcastType")
	}
	if normalizeEpisodeType("TRAILER") != "trailer" || normalizeEpisodeType("") != "" {
		t.Fatal("normalizeEpisodeType")
	}
	if parseSmallInt(" 7 ") != 7 || parseSmallInt("-1") != 0 || parseSmallInt("x") != 0 {
		t.Fatal("parseSmallInt")
	}
}
