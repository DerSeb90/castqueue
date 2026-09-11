package api

import (
	"context"
	"time"

	"github.com/sebseifert/castqueue/internal/store"
)

type podcastDTO struct {
	ID              string   `json:"id"`
	Title           string   `json:"title"`
	FeedURL         string   `json:"feed_url"`
	Description     string   `json:"description"`
	Author          string   `json:"author"`
	ImageURL        string   `json:"image_url"`
	Website         string   `json:"website"`
	AutoEnqueue     bool     `json:"auto_enqueue"`
	HasAuth         bool     `json:"has_auth"`
	EpisodeCount    int      `json:"episode_count"`
	LastRefreshedAt string   `json:"last_refreshed_at"`
	LastError       string   `json:"last_error"`
	Language        string   `json:"language"`
	Copyright       string   `json:"copyright"`
	Categories      []string `json:"categories"`
	Explicit        bool     `json:"explicit"`
	PodcastType     string   `json:"podcast_type"`
	OwnerName       string   `json:"owner_name"`
	CreatedAt       string   `json:"created_at"`
	UpdatedAt       string   `json:"updated_at"`
}

func toPodcastDTO(p store.Podcast) podcastDTO {
	cats := p.Categories
	if cats == nil {
		cats = []string{}
	}
	return podcastDTO{
		ID: p.ID, Title: p.Title, FeedURL: p.FeedURL, Description: p.Description, Author: p.Author,
		ImageURL: p.ImageURL, Website: p.Website, AutoEnqueue: p.AutoEnqueue, HasAuth: p.HasAuth(),
		EpisodeCount: p.EpisodeCount, LastRefreshedAt: fmtTime(p.LastRefreshedAt), LastError: p.LastError,
		Language: p.Language, Copyright: p.Copyright, Categories: cats, Explicit: p.Explicit,
		PodcastType: p.PodcastType, OwnerName: p.OwnerName,
		CreatedAt: fmtTime(p.CreatedAt), UpdatedAt: fmtTime(p.UpdatedAt),
	}
}

func toPodcastDTOs(ps []store.Podcast) []podcastDTO {
	out := make([]podcastDTO, 0, len(ps))
	for _, p := range ps {
		out = append(out, toPodcastDTO(p))
	}
	return out
}

type episodeDTO struct {
	ID                string `json:"id"`
	PodcastID         string `json:"podcast_id"`
	PodcastTitle      string `json:"podcast_title"`
	PodcastImageURL   string `json:"podcast_image_url"`
	GUID              string `json:"guid"`
	Title             string `json:"title"`
	Description       string `json:"description"`
	Link              string `json:"link"`
	ImageURL          string `json:"image_url"`
	MediaURL          string `json:"media_url"`
	StreamURL         string `json:"stream_url"`
	MediaType         string `json:"media_type"`
	MediaSize         int64  `json:"media_size"`
	DurationMs        int64  `json:"duration_ms"`
	PublishedAt       string `json:"published_at"`
	Season            int    `json:"season"`
	EpisodeNumber     int    `json:"episode_number"`
	EpisodeType       string `json:"episode_type"`
	Explicit          bool   `json:"explicit"`
	Author            string `json:"author"`
	PositionMs        int64  `json:"position_ms"`
	Played            bool   `json:"played"`
	ProgressUpdatedAt string `json:"progress_updated_at"`
	InQueue           bool   `json:"in_queue"`
	UpdatedAt         string `json:"updated_at"`
}

func (s *Server) streamURL(e store.Episode, streamToken string) string {
	if !e.PodcastHasAuth {
		return e.MediaURL
	}
	return s.cfg.PublicURL + "/stream/" + e.ID + "?t=" + streamToken
}

func (s *Server) toEpisodeDTO(e store.Episode, streamToken string) episodeDTO {
	return episodeDTO{
		ID: e.ID, PodcastID: e.PodcastID, PodcastTitle: e.PodcastTitle, PodcastImageURL: e.PodcastImageURL,
		GUID: e.GUID, Title: e.Title, Description: e.Description, Link: e.Link, ImageURL: e.ImageURL,
		MediaURL: e.MediaURL, StreamURL: s.streamURL(e, streamToken), MediaType: e.MediaType, MediaSize: e.MediaSize,
		DurationMs: e.DurationMs, PublishedAt: fmtTime(e.PublishedAt),
		Season: e.Season, EpisodeNumber: e.EpisodeNumber, EpisodeType: e.EpisodeType, Explicit: e.Explicit, Author: e.Author,
		PositionMs: e.PositionMs, Played: e.Played,
		ProgressUpdatedAt: fmtTime(e.ProgressUpdatedAt), InQueue: e.InQueue, UpdatedAt: fmtTime(e.UpdatedAt),
	}
}

func (s *Server) toEpisodeDTOs(ctx context.Context, eps []store.Episode) ([]episodeDTO, error) {
	token, err := s.store.StreamToken(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]episodeDTO, 0, len(eps))
	for _, e := range eps {
		out = append(out, s.toEpisodeDTO(e, token))
	}
	return out, nil
}

type queueDTO struct {
	Version int64        `json:"version"`
	Items   []episodeDTO `json:"items"`
}

func (s *Server) toQueueDTO(ctx context.Context, q store.Queue) (queueDTO, error) {
	eps, err := s.store.GetEpisodes(ctx, q.EpisodeIDs)
	if err != nil {
		return queueDTO{}, err
	}
	items, err := s.toEpisodeDTOs(ctx, eps)
	if err != nil {
		return queueDTO{}, err
	}
	return queueDTO{Version: q.Version, Items: items}, nil
}

func parseClientTime(s string) (time.Time, bool) {
	if s == "" {
		return store.Now(), true
	}
	return store.ParseTime(s)
}
