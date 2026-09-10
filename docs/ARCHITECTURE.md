# CastQueue – Architektur

Privater Podcast-Sync für eine Person: eigener Go-Server (Hetzner, Docker, SQLite),
eine Flutter-App für Windows (Stream only) und Android (mit Downloads), Web-UI zum
Verwalten der Abos, Wiedergabe auf Sonos im LAN. Kein gpodder/Nextcloud.

```
podcastclient-win/
├── docs/            API.md (Vertrag), ARCHITECTURE.md
├── server/          Go: API + Feed-Refresh + Stream-Proxy + eingebettete Web-UI
│   ├── cmd/castqueue/main.go
│   ├── internal/{config,store,feeds,api,web}
│   ├── web/         statische SPA (Vanilla JS, Dark Mode), via embed
│   ├── Dockerfile, docker-compose.yml, Caddyfile
└── app/             Flutter (Windows + Android), Package `castqueue`
    └── lib/
        ├── main.dart
        ├── core/        models.dart, api_client.dart, session (Server-URL + Token), sync_service.dart
        ├── playback/    playback_target.dart (Interface), local_target.dart (just_audio),
        │                playback_controller.dart (Queue-Logik, Progress-Reporting, Target-Wechsel)
        ├── sonos/       discovery.dart, sonos_device.dart, sonos_target.dart (pure Dart, UPnP)
        ├── downloads/   nur Android aktiv: download_manager.dart
        ├── ui/          theme.dart, shell (NavigationRail breit / NavigationBar schmal),
        │                screens/{login,queue,podcasts,podcast_detail,episode,inbox,discover,settings,now_playing}
        │                widgets/{mini_player, episode_tile, ...}
        └── state/       Riverpod-Provider
```

## Sync-Modell

- Server ist Quelle der Wahrheit. Einzelner Benutzer → Progress liegt direkt an der Episode.
- Client hält einen lokalen Cache (JSON in App-Support-Dir) und ruft `GET /api/sync?since=`
  beim Start, alle 30 s im Vordergrund und nach jeder eigenen Mutation.
- Progress: Client sendet `PUT /api/episodes/{id}/progress` alle 10 s während Wiedergabe,
  sowie bei Pause/Stop/Seek/Track-Ende. Last-write-wins über `updated_at` (Client-Zeit).
- Queue: Server-Version. Reorder → `PUT /api/queue` mit Version; 409 → Client übernimmt
  Server-Queue und zeigt Hinweis. Add/Remove/Move → einzelne Endpunkte (keine Version nötig).
- Abspielen "Als Nächstes"/Queue-Ende: Controller nimmt Episode aus Queue-Kopf, spielt,
  bei `completed` → `played: true` (Server entfernt sie aus der Queue), nächste laden.
- Wiederaufnahme: Start immer bei `position_ms` der Episode (minus 3 s Vorlauf).
- Unsubscribe (egal wo) → Server entfernt Episoden aus Queue + Tombstones → Clients
  räumen beim nächsten Sync auf; laufende Wiedergabe der gelöschten Episode wird gestoppt.

## Wiedergabe-Ziele

- `PlaybackTarget` (siehe `app/lib/playback/playback_target.dart`).
- `LocalTarget`: just_audio; Windows über `just_audio_media_kit`; Android mit
  `audio_service` (Notification, Lockscreen, Headset-Tasten). Android spielt lokale
  Download-Datei falls vorhanden, sonst `stream_url`.
- `SonosTarget`: SSDP-Discovery (`urn:schemas-upnp-org:device:ZonePlayer:1`), Zone-Gruppen
  via `ZoneGroupTopology.GetZoneGroupState` (nur Koordinatoren anzeigen), Steuerung via
  `AVTransport` SOAP (`SetAVTransportURI` mit DIDL-Lite, `Play`, `Pause`, `Stop`, `Seek`
  REL_TIME, `GetPositionInfo`, `GetTransportInfo`, `SetNextAVTransportURI`). Position wird
  per Polling (1 s) gelesen; Progress-Reporting läuft über den gleichen Controller.
  Sonos holt die Audio-URL selbst → immer `stream_url` (öffentlich erreichbar, HTTPS mit
  gültigem Zertifikat über Caddy).
- Ziel-Wechsel: aktuelle Position wird übernommen (`load(item, startAt: pos)`).

## Premium-Feeds

Feeds mit HTTP-Basic-Auth: Zugangsdaten am Podcast gespeichert (nur auf dem Server).
Für solche Podcasts ist `stream_url` ein Server-Proxy (`/stream/{id}?t=<stream_token>`)
mit Range-Support, damit Sonos und beide Apps ohne Header-Auth streamen können.

## Server

- Go 1.25, `modernc.org/sqlite` (kein cgo → statisches Binary, `FROM scratch`-ähnliches Image).
- `github.com/mmcdole/gofeed` für RSS/Atom/iTunes-Tags.
- Refresh-Loop im Hintergrund (Intervall aus Settings), zusätzlich manuell.
- Auth: ein Benutzer aus Env, Bearer-Tokens pro Gerät (SHA-256 gehasht in DB), Login-Rate-Limit.
- Web-UI: eingebettet, Hash-Routing, nutzt dieselbe API mit Cookie. Reine Verwaltung (Abos, Warteschlange, Gehört-Status, Geräte), keine Wiedergabe.
- Deployment: `docker compose up -d` mit Caddy (automatisches TLS) vor dem Server.
