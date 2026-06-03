# OrtsschilderSprint — Regelwerk & Projektgedächtnis

## Projektübersicht
Garmin Edge 530 DataField-App: Ortsschilder werden zu Sprint-Zielen. Crossing-Zeiten live via ANT+ zwischen Fahrern. Fahrten + Crossings nach Aktivität per Background-Service zu Supabase hochgeladen. Website zeigt Fahrten + Ranglisten.

---

## Architektur

### Garmin-App (Monkey C)
- `OrtsschilderField.mc` — DataField (Anzeige, GPS, Crossing-Erkennung, ANT+)
- `OrtsschilderBackground.mc` — Background ServiceDelegate (HTTP-Uploads)
- `OrtsschilderApp.mc` — AppBase (Lifecycle, onActivitySaved)
- `OrtsschilderAnt.mc` — ANT+ Peer-to-Peer Live-Ranking
- `CrossingDetector.mc` — Haversine + Annäherungserkennung

### Backend (Supabase)
- **Tabellen:** `rides`, `crossings`, `signs`, `profiles`, `claim_attempts`
- **Edge Functions:** `upload-ride`, `claim-device`, `delete-account`
- **View:** `rides_public` (ohne `gps_track` — öffentlich)
- **RLS:** GPS-Track nur für Eigentümer; Löschen nur eingeloggt + eigene Daten

### Website
- `docs/index.html` — Hauptseite (GitHub Pages, LIVE)
- `docs/datenschutz.html` — Datenschutzerklärung
- `docs/impressum.html` — Impressum
- ⚠️ `website/index.html` existiert NICHT mehr (gelöscht — war veraltetes Duplikat)

---

## Kritische iOS-Garmin-Besonderheiten
- **Content-Type: application/json setzen → -200 (INVALID_HTTP_HEADER_FIELDS_IN_REQUEST)** auf iOS
- Lösung: Edge Function `upload-ride` als Relay — akzeptiert form-encoded (iOS) UND JSON (Android)
- Garmin serialisiert Arrays (gps_track, crossings) als JSON-Strings vor makeWebRequest
- Edge Function parst sie zurück mit JSON.parse()
- `_rideHeaders()` sendet NUR `apikey` (kein Authorization, kein Content-Type)
- Signs-Fetch (GET) nutzt `_authHeaders(false)` — dort kein -200-Problem

---

## Deploy-Pfad
```bash
# Garmin kompilieren + deployen
"/Users/xaver_efinger/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.1.0-2026-03-09-6a872a80b/bin/monkeyc" \
  -o bin/OrtsschilderSprint.prg -f monkey.jungle -y developer_key.der -d edge530 -w

cp bin/OrtsschilderSprint.prg "/Volumes/GARMIN/Garmin/Apps/Media/OrtsschilderSprint.PRG" && sync
```
- Supabase URL: `https://slcprtkqkqwgstnyfpus.supabase.co`
- GitHub Pages URL: `https://85tvcgwnjr-jpg.github.io/ortsschildersprint/`
- Edge Functions: Supabase Dashboard → Edge Functions (manuell deployen)

---

## Sicherheits-Regeln (NIEMALS vergessen)

### XSS
- **ALLE** nutzergesteuerten Strings in innerHTML/setContent MÜSSEN durch `esc()` laufen
- Betrifft: `display_name`, `sign_name`, `e.message` in innerHTML
- `esc()` ist in `docs/index.html` definiert — immer nutzen

### RLS / Datenbankzugriff
- GPS-Tracks: nur Eigentümer (device_id aus JWT user_metadata)
- Profile schreiben: nur eingeloggt + eigene device_id
- Crossings schreiben: nur über `upload-ride` Edge Function (Service-Role)
- Löschen: nur eingeloggt + eigene device_id
- `rides_public` View: öffentlich, aber OHNE gps_track

### Edge Functions
- `upload-ride`: JWT OFF (`--no-verify-jwt`), Auth via `apikey` Header
- `claim-device`: JWT ON, Auth via Bearer Token
- `delete-account`: JWT ON, Auth via Bearer Token
- Service-Role-Key NIEMALS im Browser/Client exponieren
- CORS: `*` (unkritisch, Auth läuft über JWT-Header nicht Cookies)

### Claim-Code (Besitznachweis)
- 6-stelliger Zufallscode, einmalig pro Gerät generiert, in Storage gespeichert
- Wird auf dem Garmin-Display angezeigt (Code: XXXXXX)
- Bei jedem Upload in `rides.claim_code` gespeichert
- `claim-device` prüft Code serverseitig — nach 5 Fehlversuchen 15 min Sperre

---

## Datenfluss

### Upload (Garmin → Supabase)
1. `onTimerStop` schreibt `track_buf` + setzt `timer_stopped_at`
2. Background fired nach 5 min (Garmin-Minimum)
3. `onTimerReset` (Edge 530: fires statt onActivitySaved) → promoted `track_buf` → `pending_ride`
4. Background lädt `pending_ride` via `upload-ride` Edge Function hoch
5. Edge Function: upsert in `rides` + insert in `crossings` (idempotent) + prüft `profiles` → `registered`

### Crossings (WICHTIG!)
- Garmin speichert Crossings in `Storage("crossings")` (Array)
- Beim Upload → `upload-ride` schreibt sie in die **`crossings`-Tabelle** (NICHT in rides)
- Website liest Ranglisten aus `crossings`-Tabelle
- ⚠️ Crossings werden NICHT direkt per REST-API geschrieben (Policy geschlossen)

### Gerät verknüpfen
1. Nutzer registriert sich auf Website (Name, E-Mail, Passwort — KEINE Device-ID)
2. Nach Login: Verknüpfen-Screen → "Aus Fahrten auswählen"
3. Fahrt wählen → Code vom Garmin-Display eingeben
4. `claim-device` prüft Code → schreibt device_id in Auth-Metadaten + `profiles`
5. Garmin: nach Upload mit `registered=true` → "Code: XXXXXX" verschwindet

---

## Häufige Fehler & Lösungen

| Fehler | Ursache | Lösung |
|---|---|---|
| -200 | Content-Type Header gesetzt auf iOS | Nie Content-Type in `_rideHeaders()` setzen |
| -104 | BLE nicht verbunden | Garmin von USB trennen, Handy verbinden |
| 400 | Kein Content-Type → form-encoded → REST lehnt ab | Edge Function als Relay nutzen |
| 204 | Upload erfolgreich ✅ | |
| rides_public leer | SQL-Migrations nicht ausgeführt | `protect_gps_tracks.sql` + `harden_security.sql` ausführen |

---

## Garmin Edge 530 Besonderheiten
- `onActivitySaved` feuert NICHT für DataFields → `onTimerReset` als Fallback
- `onTimerReset` feuert bei SAVE und DISCARD → über `timer_stopped_at` unterscheiden
- Background-Minimum: 300s (5 min)
- Storage-Limit: ~16 KB pro Wert
- Kein `Communications` im DataField-Kontext (nur im Background)

---

## SQL-Migrations (Ausführungsreihenfolge)
1. `scripts/create_tables.sql` — Basis-Schema
2. `scripts/protect_gps_tracks.sql` — GPS-Schutz + rides_public View
3. `scripts/harden_security.sql` — Security-Härtung (Profiles, claim_attempts)
4. `alter table rides add column if not exists claim_code text;`

---

## Kontakt / Impressum
- Name: Xaver Efinger
- E-Mail: ortsschildersprint@gmail.com
- Adresse: 50858 Köln, Deutschland
- GitHub-Repo: public (Source-Code gitignored, nur docs/ + scripts/ tracked)
