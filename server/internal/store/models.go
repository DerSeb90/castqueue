package store

import "time"

type Podcast struct {
	ID              string
	FeedURL         string
	Title           string
	Description     string
	Author          string
	ImageURL        string
	Website         string
	AutoEnqueue     bool
	AuthUsername    string
	AuthPassword    string
	LastRefreshedAt time.Time
	LastError       string
	ETag            string
	LastModified    string
	Language        string
	Copyright       string
	Categories      []string
	Explicit        bool
	PodcastType     string // "episodic", "serial" or ""
	OwnerName       string
	EpisodeCount    int
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

func (p Podcast) HasAuth() bool { return p.AuthUsername != "" || p.AuthPassword != "" }

type Episode struct {
	ID                string
	PodcastID         string
	PodcastTitle      string
	PodcastImageURL   string
	PodcastHasAuth    bool
	GUID              string
	Title             string
	Description       string
	Link              string
	ImageURL          string
	MediaURL          string
	MediaType         string
	MediaSize         int64
	DurationMs        int64
	PublishedAt       time.Time
	Season            int
	EpisodeNumber     int
	EpisodeType       string // "full", "trailer", "bonus" or ""
	Explicit          bool
	Author            string
	PositionMs        int64
	Played            bool
	ProgressUpdatedAt time.Time
	InQueue           bool
	CreatedAt         time.Time
	UpdatedAt         time.Time
}

// NewEpisode is what the feed parser produces.
type NewEpisode struct {
	GUID          string
	Title         string
	Description   string
	Link          string
	ImageURL      string
	MediaURL      string
	MediaType     string
	MediaSize     int64
	DurationMs    int64
	PublishedAt   time.Time
	Season        int
	EpisodeNumber int
	EpisodeType   string
	Explicit      bool
	Author        string
}

type Queue struct {
	Version    int64
	EpisodeIDs []string
}

type Device struct {
	ID         string
	Name       string
	CreatedAt  time.Time
	LastSeenAt time.Time
}

type Settings struct {
	AutoRemovePlayed       bool `json:"auto_remove_played"`
	RefreshIntervalMinutes int  `json:"refresh_interval_minutes"`
	AutoEnqueueDefault     bool `json:"auto_enqueue_default"`
}

type ProgressUpdate struct {
	EpisodeID  string
	PositionMs int64
	DurationMs *int64
	Played     *bool
	UpdatedAt  time.Time
}

type SyncDelta struct {
	ServerTime      time.Time
	Podcasts        []Podcast
	PodcastsDeleted []string
	Episodes        []Episode
	EpisodesDeleted []string
	Queue           Queue
	Settings        Settings
}
