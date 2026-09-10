# Startet den Server lokal (Port 8080, Login seb/test) in einem eigenen Fenster
# und danach die Windows-App im Debug-Modus mit Hot Reload.
$root = $PSScriptRoot
Start-Process powershell -ArgumentList @(
  "-NoExit", "-Command",
  "`$env:CQ_USERNAME='seb'; `$env:CQ_PASSWORD='test'; `$env:CQ_DATA_DIR='$root\server\data'; " +
  "`$env:CQ_LISTEN=':8080'; `$env:CQ_PUBLIC_URL='http://localhost:8080'; `$env:CQ_LOG_LEVEL='debug'; " +
  "Set-Location '$root\server'; go run ./cmd/castqueue"
)
Start-Sleep -Seconds 3
Set-Location "$root\app"
flutter run -d windows
