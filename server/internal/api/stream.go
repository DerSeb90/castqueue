package api

import (
	"crypto/subtle"
	"io"
	"net/http"
	"time"
)

var streamClient = &http.Client{
	Timeout: 0, // streaming: no overall timeout
	Transport: &http.Transport{
		ResponseHeaderTimeout: 30 * time.Second,
		MaxIdleConns:          16,
		IdleConnTimeout:       90 * time.Second,
	},
}

// handleStream proxies an episode's enclosure, adding basic auth for premium
// feeds. Auth is a query token because Sonos and most players cannot send
// headers. Range requests are forwarded so seeking works.
func (s *Server) handleStream(w http.ResponseWriter, r *http.Request) {
	token, err := s.store.StreamToken(r.Context())
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	given := r.URL.Query().Get("t")
	if given == "" || subtle.ConstantTimeCompare([]byte(given), []byte(token)) != 1 {
		writeError(w, http.StatusUnauthorized, "unauthorized", "invalid stream token")
		return
	}
	e, err := s.store.GetEpisode(r.Context(), r.PathValue("id"))
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	if !e.PodcastHasAuth {
		// nothing to add: send the player straight to the source
		http.Redirect(w, r, e.MediaURL, http.StatusFound)
		return
	}
	p, err := s.store.GetPodcast(r.Context(), e.PodcastID)
	if err != nil {
		s.writeStoreError(w, err)
		return
	}
	req, err := http.NewRequestWithContext(r.Context(), r.Method, e.MediaURL, nil)
	if err != nil {
		writeError(w, http.StatusBadGateway, "upstream", "bad media url")
		return
	}
	req.Header.Set("User-Agent", "CastQueue/1.0")
	req.SetBasicAuth(p.AuthUsername, p.AuthPassword)
	for _, h := range []string{"Range", "If-Range", "Accept", "Accept-Encoding"} {
		if v := r.Header.Get(h); v != "" {
			req.Header.Set(h, v)
		}
	}
	resp, err := streamClient.Do(req)
	if err != nil {
		writeError(w, http.StatusBadGateway, "upstream", "media fetch failed: "+err.Error())
		return
	}
	defer resp.Body.Close()
	for _, h := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag", "Content-Disposition"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	if w.Header().Get("Content-Type") == "" && e.MediaType != "" {
		w.Header().Set("Content-Type", e.MediaType)
	}
	if w.Header().Get("Accept-Ranges") == "" {
		w.Header().Set("Accept-Ranges", "bytes")
	}
	w.Header().Set("Cache-Control", "private, max-age=0")
	w.WriteHeader(resp.StatusCode)
	if r.Method == http.MethodHead {
		return
	}
	_, _ = io.Copy(w, resp.Body)
}
