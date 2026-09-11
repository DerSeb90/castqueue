# CastQueue API (v1)

Single-user, private podcast sync server. All endpoints under `/api` require
`Authorization: Bearer <token>` (or the `cq_session` cookie set by the web UI),
except `POST /api/auth/login` and `GET /api/health`.

All timestamps are RFC 3339 UTC strings (`2026-09-10T12:34:56Z`). All IDs are
opaque strings (server-generated, 16 hex chars). Durations/positions are in
milliseconds (int64). JSON only. Errors:

```json
{ "error": "human readable message", "code": "not_found" }
```

HTTP codes: 200 ok, 201 created, 204 no content, 400 bad request, 401 unauthorized,
404 not found, 409 conflict (queue version), 422 feed could not be parsed,
429 too many login attempts, 502 upstream feed/media fetch failed.

---

## Auth / devices

### `POST /api/auth/login`
```json
{ "username": "seb", "password": "…", "device_name": "Windows PC" }
```
→ 200
```json
{ "token": "…64 hex…", "device_id": "…", "stream_token": "…" }
```
Token is long-lived (revoked via `DELETE /api/devices/{id}` or logout).
Web UI login additionally sets cookie `cq_session=<token>; HttpOnly; SameSite=Lax`.
Rate limited: 5 failures / 15 min per IP → 429.

### `POST /api/auth/logout` → 204 (revokes the token in use)

### `GET /api/me`
```json
{ "username": "seb", "device_id": "…", "device_name": "Windows PC",
  "stream_token": "…", "server_time": "…", "public_url": "https://pods.example.com",
  "server_version": "v0.1.0" }
```

### `GET /api/devices` → `[{ "id", "name", "created_at", "last_seen_at", "current": bool }]`
### `DELETE /api/devices/{id}` → 204

### `POST /api/stream-token/rotate` → `{ "stream_token": "…" }`
Invalidates all previously issued `stream_url`s.

---

## Objects

### Podcast
```json
{
  "id": "…", "title": "…", "feed_url": "…", "description": "…", "author": "…",
  "image_url": "…", "website": "…",
  "auto_enqueue": true,          // new episodes are appended to the queue on refresh
  "has_auth": false,             // feed uses HTTP basic auth (credentials never returned)
  "episode_count": 123,
  "last_refreshed_at": "…", "last_error": "",
  "language": "de-DE",           // <language> (may be empty)
  "copyright": "…",
  "categories": ["Technology", "Tech News"],  // iTunes categories incl. subcategories + plain <category>; never null
  "explicit": false,             // <itunes:explicit>
  "podcast_type": "episodic",    // "episodic" | "serial" | ""
  "owner_name": "…",             // <itunes:owner><itunes:name>
  "created_at": "…", "updated_at": "…"
}
```

### Episode
```json
{
  "id": "…", "podcast_id": "…", "podcast_title": "…", "podcast_image_url": "…",
  "guid": "…", "title": "…", "description": "<p>html</p>", "link": "…",
  "image_url": "…",
  "media_url": "https://cdn…/ep.mp3",   // original enclosure
  "stream_url": "https://…",            // URL any player (incl. Sonos) can fetch: direct, or server proxy for auth feeds
  "media_type": "audio/mpeg", "media_size": 12345678,
  "duration_ms": 3600000,
  "published_at": "…",
  "season": 2, "episode_number": 14,   // <itunes:season>/<itunes:episode>, 0 if absent
  "episode_type": "full",              // "full" | "trailer" | "bonus" | ""
  "explicit": false,
  "author": "…",                       // <itunes:author> of the item (else first <author>)
  "position_ms": 0, "played": false, "progress_updated_at": "…",
  "in_queue": false,
  "updated_at": "…"                     // bumps on any change incl. progress
}
```

### Queue
```json
{ "version": 17, "items": [ Episode, … ] }
```
`version` increments on every mutation (server-side or via API). Clients that
replace the whole order must send the version they based it on.

### Settings
```json
{ "auto_remove_played": true, "refresh_interval_minutes": 30,
  "auto_enqueue_default": true }
```

---

## Podcasts

- `GET /api/podcasts` → `[Podcast]` (sorted by title)
- `POST /api/podcasts`
  ```json
  { "feed_url": "…", "auth_username": "", "auth_password": "", "auto_enqueue": true }
  ```
  Fetches + parses the feed synchronously. → 201 `Podcast`; if the feed_url is
  already subscribed → 200 with the existing podcast. 422 if unparseable, 502 if unreachable.
  Newly subscribed podcasts do **not** enqueue their back catalogue; only episodes
  found on later refreshes are auto-enqueued.
- `GET /api/podcasts/{id}` → `Podcast`
- `PATCH /api/podcasts/{id}`
  `{ "auto_enqueue"?: bool, "auth_username"?: "", "auth_password"?: "", "title"?: "" }`
  Sending `auth_username: ""` and `auth_password: ""` clears credentials. → `Podcast`
- `DELETE /api/podcasts/{id}` → 204. Unsubscribe: removes all of its episodes from
  the queue (queue version bump), deletes episodes + progress, writes tombstones.
- `POST /api/podcasts/{id}/refresh` → `Podcast` (synchronous refresh)
- `POST /api/podcasts/refresh` → `{ "refreshed": n, "errors": n }` (all, synchronous)
- `GET /api/podcasts/{id}/episodes?limit=50&offset=0` → `[Episode]` newest first
- `GET /api/search?q=term` (proxied iTunes Search API, max 25) →
  ```json
  [{ "title", "author", "feed_url", "image_url",
     "genres": ["Technology", …],       // iTunes genres without the generic "Podcasts"
     "episode_count": 123,              // trackCount
     "latest_release_at": "…",          // RFC3339 or ""
     "itunes_url": "https://podcasts.apple.com/…",
     "explicit": false, "country": "DEU" }]
  ```
- `GET /api/opml` → `application/xml` OPML export
- `POST /api/opml` (body: raw OPML xml, `Content-Type: text/xml`) → `{ "added": n, "skipped": n, "failed": [feed_url…] }`

## Episodes

- `GET /api/episodes?since=<rfc3339>&limit=100` → `[Episode]` published after `since`
  (default: last 14 days), newest first. "New episodes" inbox.
- `GET /api/episodes/{id}` → `Episode`
- `PUT /api/episodes/{id}/progress`
  ```json
  { "position_ms": 123456, "duration_ms": 3600000, "played": false,
    "updated_at": "<client timestamp>" }
  ```
  Last-write-wins: if `updated_at` ≤ stored `progress_updated_at` the update is
  ignored (200 with current state). `duration_ms` and `played` optional.
  `played: true` with `settings.auto_remove_played` removes the episode from the queue.
  → `Episode`
- `POST /api/progress/batch` `{ "items": [ {"episode_id", "position_ms", "duration_ms", "played", "updated_at"} ] }`
  → `{ "episodes": [Episode] }` (same rules per item)

## Queue

- `GET /api/queue` → `Queue`
- `PUT /api/queue` `{ "version": 17, "episode_ids": ["…"] }` → `Queue`.
  409 with body `Queue` (current) if version differs. Unknown ids ignored.
- `POST /api/queue/items` `{ "episode_id": "…", "position": "front" | "back" | <int index> }` → `Queue`
  Idempotent: already-queued episode is moved to the requested position.
- `DELETE /api/queue/items/{episode_id}` → `Queue`
- `POST /api/queue/move` `{ "episode_id": "…", "to": 3 }` → `Queue`
- `DELETE /api/queue` → `Queue` (empty)

## Sync

### Playback lock (one device at a time)
Only one device may play at once. A device that starts playing **claims** the lock
(always takes over), sends a **heartbeat** every ~10 s while playing and **releases** on
pause/stop. A lock without heartbeat for 45 s is stale and can be taken by a heartbeat.
Other devices learn about the lock via heartbeat 409 or the `playback` field in `/api/sync`
and pause themselves.

`PlaybackLock`: `{ "active": bool, "device_id", "device_name", "episode_id", "target", "started_at", "heartbeat_at", "stale": bool }`

- `GET /api/playback` → `PlaybackLock`
- `POST /api/playback/claim` `{ "episode_id", "target": "Lokal" | "Sonos Küche" }` → `PlaybackLock`
- `POST /api/playback/heartbeat` `{ "episode_id", "target" }` → `PlaybackLock`, or **409**
  `{ "code": "playback_conflict", "playback": PlaybackLock }` when another device holds a live lock
- `POST /api/playback/release` → 204 (no-op when not the holder)

### Sync
- `GET /api/sync?since=<rfc3339>` → delta since `since` (omit → everything):
  ```json
  {
    "server_time": "…",
    "podcasts": [Podcast],          // created/updated since
    "podcasts_deleted": ["id"],
    "episodes": [Episode],          // created/updated (incl. progress) since
    "episodes_deleted": ["id"],
    "queue": { "version": 17, "episode_ids": ["…"] },
    "settings": Settings,
    "playback": PlaybackLock      // who is playing right now, see below
  }
  ```
  Clients persist `server_time` and pass it as `since` next time. Tombstones are
  kept for 90 days. Episodes are capped to the 300 most recent per podcast in the
  full (no `since`) sync; older ones are available via the podcast episode list.

## Settings

- `GET /api/settings` → `Settings`
- `PUT /api/settings` (partial) → `Settings`

## Stream proxy (no bearer auth, token in query)

- `GET /stream/{episode_id}?t=<stream_token>` → proxies the enclosure with
  `Range` support and `Content-Type`/`Content-Length`/`Accept-Ranges` passthrough,
  adding the podcast's basic auth upstream. `HEAD` supported. This is what
  `stream_url` points to for podcasts with credentials; for public feeds
  `stream_url == media_url`.

## Misc

- `GET /api/health` → `{ "ok": true, "version": "…" }` (unauthenticated)
- `GET /` → web UI (embedded SPA), everything not under `/api` or `/stream` serves the SPA.

---

## Server configuration (env)

| Var | Default | Meaning |
|---|---|---|
| `CQ_USERNAME` | (required) | login user |
| `CQ_PASSWORD` | (required) | login password (plain, or `bcrypt:$2a$…` hash) |
| `CQ_PUBLIC_URL` | `http://localhost:8080` | absolute base used to build `stream_url` |
| `CQ_DATA_DIR` | `/data` | SQLite file location (`castqueue.db`) |
| `CQ_LISTEN` | `:8080` | listen address |
| `CQ_REFRESH_MINUTES` | `30` | initial refresh interval (settings override) |
| `CQ_LOG_LEVEL` | `info` | |
