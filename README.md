# CastQueue

Privater Podcast-Sync mit eigenem Backend: Abos, Hörfortschritt und **eine geräteübergreifende
Warteschlange**, synchronisiert zwischen Windows, Android, Web und Sonos.

| Teil | Was |
|---|---|
| `server/` | Go-API + Feed-Refresh + Stream-Proxy für Premium-Feeds + eingebettete Web-UI (reine Verwaltung: Abos, Warteschlange, Gehört-Status, Geräte; keine Wiedergabe). SQLite, Docker, Caddy (TLS). |
| `app/` | Flutter-App für **Windows** (Stream only) und **Android** (mit Downloads). Sonos-Wiedergabe im LAN. |
| `docs/` | [API-Vertrag](docs/API.md), [Architektur](docs/ARCHITECTURE.md). |

## Server auf Hetzner (Debian) deployen

```bash
apt install -y docker.io docker-compose-v2 git
git clone <dieses repo> castqueue && cd castqueue/server
cp .env.example .env && nano .env     # Domain, Benutzer, Passwort
docker compose up -d --build
```

Caddy holt automatisch ein Let's-Encrypt-Zertifikat für `CQ_DOMAIN` (Port 80/443 müssen offen sein,
DNS-A-Record auf den Server). Danach: `https://<domain>` → Web-UI-Login. Abspielen passiert nur in den Apps, die Web-UI verwaltet Abos und Warteschlange zentral.

- Datenbank liegt in `server/data/castqueue.db` (Backup: Datei kopieren, WAL-Dateien mitnehmen).
- Nur ein Benutzer (aus `.env`). Jeder Login erzeugt ein Geräte-Token; Geräte lassen sich in den
  Einstellungen abmelden. 5 Fehlversuche/15 min pro IP → Sperre.
- Premium-Feeds (HTTP-Basic-Auth): Zugangsdaten werden nur serverseitig gespeichert. Audio solcher
  Feeds läuft über `/stream/<id>?t=<token>` durch den Server, damit auch Sonos streamen kann.
  Token in den Einstellungen rotierbar.
- Feed-Refresh alle 30 min (einstellbar), manuell per Knopf. Neue Folgen abonnierter Podcasts
  landen automatisch in der Warteschlange (pro Podcast abschaltbar). Beim Abonnieren wird der
  Back-Katalog **nicht** eingereiht.
- Deabonnieren entfernt alle Folgen des Podcasts auch aus der Warteschlange – auf allen Geräten.

Lokal ohne Docker:

```bash
cd server
CQ_USERNAME=seb CQ_PASSWORD=test CQ_PUBLIC_URL=http://localhost:8080 CQ_DATA_DIR=./data go run ./cmd/castqueue
go test ./...
```

## App bauen

Voraussetzungen: Flutter 3.47+, Visual Studio Build Tools (Windows), Android SDK.

```bash
cd app
flutter pub get
flutter build windows --release      # build/windows/x64/runner/Release/castqueue.exe
flutter build apk --release          # build/app/outputs/flutter-apk/app-release.apk
```

Beim ersten Start: Server-URL (`https://<domain>`), Benutzer, Passwort. Die App cached alles lokal
und synchronisiert alle 30 s bzw. nach jeder Aktion.

### Wiedergabe

- Fortschritt wird alle 10 s sowie bei Pause/Seek/Ende an den Server gemeldet; andere Geräte
  steigen 3 s vor der letzten Position ein.
- Warteschlange ist die Haupt-Playlist: nach Ende einer Folge wird sie als gehört markiert
  (Server nimmt sie aus der Queue) und die nächste startet.
- **Sonos**: Ausgabegerät im Now-Playing-Screen wählen. Die App findet Sonos-Gruppen per SSDP im
  LAN, alternativ IP manuell eintragen. Sonos holt die Audio-URL selbst – dafür muss der Server
  per HTTPS mit gültigem Zertifikat erreichbar sein (Caddy erledigt das). Position wird per
  Polling gelesen und ebenfalls synchronisiert.
- Android: Downloads (manuell oder automatisch für Queue-Einträge), Benachrichtigung/Lockscreen,
  Headset-Tasten. Windows: nur Streaming.

## Sicherheit

Der Server ist für genau eine Person gedacht. Alles außer Login, Health und dem Stream-Proxy
(mit eigenem Token) erfordert ein Geräte-Token. Zusätzlich empfehlenswert: Hetzner-Firewall auf
80/443 beschränken, SSH nur per Key.
