# pc-check GUI (v2.0): Architektur

Stand: 25.10.2026 · Karte: oFAILIXo/pc-check-dev#24 · Branch `feature/v2.0-gui`

Dieses Dokument ist der Vertrag für alle Teilaufgaben. Wer an einem Teil arbeitet, hält sich an Dateinamen, API und Schema. Abweichungen erst hier eintragen, dann umsetzen.

## 1. Ziele und Grenzen

- Eine Oberfläche für alles: alle Berichte, Befunde nach Kategorien, Anpassungen per Button, Checkliste, Verlauf, neuer Scan.
- Jede Anpassung zeigt bei Bedarf den PowerShell-Befehl dahinter und erklärt ihn.
- **Vor jeder Änderung entsteht ein geprüfter Wiederherstellungspunkt.** Fehlt er, wird nichts geändert.
- Jede Änderung ist einzeln rückgängig zu machen (Journal mit dem alten Zustand).
- Farbschema Solarized Dark (Tokens wie im HTML-Bericht).
- **Der Scan (`pc-check.ps1`) bleibt rein lesend.** Ändern kann nur die GUI.
- Nichts zu installieren: Windows PowerShell 5.1 und Microsoft Edge (Windows 11 Standard). Kein Internet, kein CDN.
- Nicht-Ziele: BIOS, Secure Boot, BitLocker, Treiber deinstallieren, Dateien löschen, Konten ändern. Dafür gibt es nur Anleitungen.

## 2. Dateien

| Datei | Inhalt | Zuständig (Teilaufgabe) |
|---|---|---|
| `pc-check-gui.cmd` | Doppelklick-Start, fordert Adminrechte an (wie `pc-check.cmd`) | T1 |
| `pc-check-gui.ps1` | Einstieg: Prüfungen, Server starten, Edge öffnen, Hauptschleife | T1 |
| `gui/lib/Server.ps1` | HTTP-Server, Routing, Sicherheitsprüfungen, Jobs | T1 |
| `gui/lib/Safety.ps1` | Wiederherstellungspunkt anlegen und prüfen, Journal, Ausführen/Rückgängig-Ablauf | T2 |
| `pc-check.aktionen.ps1` | Aktionskatalog (gibt ein Array von Hashtables zurück) | T3 |
| `gui/index.html`, `gui/app.css`, `gui/app.js` | Oberfläche (Vanilla JS, Hash-Routing) | T4 |
| `docs/gui-mockup.html` | klickbares Mockup mit Demodaten, Vorlage für T4 | T0 |
| `tests/*.Tests.ps1` | Pester-3.4-Tests (in Windows enthalten) | T5 |

Laufzeitdaten (per `.gitignore` ausgeschlossen):
- `changes/journal.json`: Änderungsjournal
- `state/checklist.json`: Checkliste der GUI. Das eigenständige HTML nutzt weiter localStorage.
- `state/gui.log`: Protokoll des Servers

Alle `.ps1` als UTF-8 **mit** BOM (PowerShell 5.1), `.html/.css/.js/.md` ohne BOM.

## 3. Start und Ende

1. **Start:** `pc-check-gui.ps1` prüft die Adminrechte und startet sich sonst neu mit `-Verb RunAs`.
2. **Einzelinstanz:** Ein benannter Mutex `Global\pc-check-gui` sorgt dafür, dass nur eine Instanz läuft. Läuft schon eine, öffnet das Script deren Fenster und beendet sich.
3. **Port und Token:**
   - Port: ein freier Port per `TcpListener(127.0.0.1, 0)`.
   - Token: 32 Zufallsbytes (`RandomNumberGenerator`), base64url.
4. **Server:** `HttpListener` auf `http://127.0.0.1:<Port>/`. Als Admin ist keine URL-ACL nötig.
5. **Fenster:** `msedge.exe --app=http://127.0.0.1:<Port>/#t=<Token> --user-data-dir="%LOCALAPPDATA%\pc-check\edge"`.
   - Das eigene Profil sorgt für einen eigenen Edge-Prozess, auf dessen Ende man warten kann.
   - Das Token steht im Fragment (`#`) und wird deshalb nie an den Server geschickt oder protokolliert.
   - `app.js` liest das Token, legt es in `sessionStorage` ab und entfernt es per `history.replaceState` aus der Adresse.
6. **Edge fehlt:** Dann wird der Standardbrowser geöffnet. Das Ende erkennt dann nur der Heartbeat.
7. **Ende:** Der Server beendet sich, wenn
   - der Edge-Prozess endet, oder
   - 45 s kein Heartbeat kommt (die Oberfläche sendet alle 10 s `POST /api/heartbeat`), oder
   - `POST /api/shutdown` kommt.

   Laufende Jobs werden abgewartet. Die Konsole zeigt „GUI läuft … (Fenster schließen beendet)“.

**Hauptschleife:** `GetContextAsync()` mit `Wait(500)`, damit Heartbeat-Zeitüberschreitung und Edge-Ende geprüft werden. Anfragen werden synchron beantwortet, sie müssen schnell sein (< 1 s). Alles Langsame läuft als Job (Abschnitt 6).

## 4. Sicherheit (verbindlich)

Der Server läuft mit Adminrechten. Jede Webseite im Browser kann Anfragen an `127.0.0.1` schicken. Deshalb gilt:

1. **Nur 127.0.0.1** (nicht `localhost`, nicht `+`).
2. **Host-Prüfung:** `Host` muss genau `127.0.0.1:<Port>` sein, sonst 403. Das schützt vor DNS-Rebinding.
3. **Token:** Jede Anfrage unter `/api/` und `/report/` braucht das Token, sonst 401.
   - API: Header `X-PcCheck-Token`.
   - `/report/…`: Parameter `?t=`, weil ein iframe keinen Header setzen kann.
   - Statische Dateien (`/`, `/app.js`, `/app.css`) gibt es ohne Token. Sie enthalten keine Daten.
   - Vergleich in konstanter Zeit.
4. **Origin:** Ist `Origin` gesetzt, muss er `http://127.0.0.1:<Port>` sein, sonst 403. Der Server sendet **nie** CORS-Header und beantwortet `OPTIONS` mit 405.
5. **Änderungen nur per `POST`** mit `Content-Type: application/json`. Fremde Seiten lösen damit einen CORS-Preflight aus, der scheitert.
6. **Allowlist:**
   - Der Browser schickt nur Aktions-IDs und gegebenenfalls eine Variante aus der im Katalog festgelegten Liste.
   - **Nie** einen Befehl, Pfad oder Scriptblock.
   - Unbekannte IDs oder Varianten ergeben 400.
7. **Dateinamen** von Berichten: nur `^pc-check_\d{4}-\d{2}-\d{2}_\d{4}\.(json|html|md)$`, aufgelöst im Ordner `reports\` (zusätzlich `GetFullPath` und Präfix-Prüfung).
8. **Antwort-Header** für alles:
   - `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'`
   - `X-Content-Type-Options: nosniff`
   - `Referrer-Policy: no-referrer`
   - `Cache-Control: no-store`
9. **Alte Berichte im iframe:** Sie enthalten Inline-Script. `/report/<name>.html` bekommt deshalb eine eigene CSP (`script-src 'unsafe-inline'`, `connect-src 'none'`), und der iframe hat `sandbox="allow-scripts allow-popups"` ohne `allow-same-origin`. Der Bericht kann dadurch weder die API aufrufen noch das Token lesen.
10. **Protokoll** (`state/gui.log`): Zeit, Methode, Pfad ohne Query, Status. Nie Tokens.

## 5. API

Alle Antworten sind JSON (`application/json; charset=utf-8`). Fehler: `{ "error": "Text für den Nutzer" }` mit passendem Status.

| Methode und Pfad | Antwort / Zweck |
|---|---|
| `GET /api/session` | `{ version, pc, admin, profil, safety }`. `safety` siehe 7.3 |
| `GET /api/reports` | `[{ name, created, version, admin, profil, counts:{CRIT,WARN,TIPP,ACK,INFO,OK,SKIP} }]`, neueste zuerst. Liest nur `Meta` und `Findings` |
| `GET /api/reports/<name>.json` | ganzer Bericht wie von `pc-check.ps1` geschrieben (`Meta`, `Findings`, `Data`, `Changes`) |
| `GET /report/<name>.html?t=` | Original-HTML-Bericht für den iframe |
| `GET /api/actions` | Katalog ohne Scriptblöcke, plus zuletzt gelesener Zustand: `[{ id, kategorie, pruefung, titel, erklaerung, nutzen, aufwand, risiko, neustart, varianten, befehle:{ausfuehren,rueckgaengig}, zustand:{aktiv,wert,stand} }]` |
| `POST /api/actions/refresh` | Job: alle `Lesen` neu ausführen → `{ jobId }` |
| `POST /api/actions/run` | Body `{ ids:[...], variante? }` → `{ jobId }`. Mehrere IDs = ein Wiederherstellungspunkt |
| `POST /api/journal/<eintragId>/undo` | → `{ jobId }` |
| `GET /api/journal` | Journal-Einträge, neueste zuerst |
| `GET /api/restorepoints` | `[{ seq, zeit, beschreibung, typ }]` aus `Get-ComputerRestorePoint` |
| `POST /api/scan` | Body `{ profil, eventDays, skipWinget, skipUpdateSearch }` (Werte validieren) → `{ jobId }` |
| `GET /api/jobs/<id>?from=<n>` | `{ id, art, status: running\|done\|failed, log:[Zeilen ab n], next, ergebnis }` |
| `GET /api/checklist` / `POST /api/checklist` | `{ "<Prüfung>": { state:"done"\|"later", date, report } }`, gleiches Format wie im HTML |
| `POST /api/heartbeat` · `POST /api/shutdown` | `{}` |

Der Scan läuft als `powershell.exe -NoProfile -ExecutionPolicy Bypass -File pc-check.ps1 -NoUpdatePrompt -NoOpen …`. Die Ausgabe wird zeilenweise ins Job-Log geschrieben. Programm-Updates (winget) bietet die GUI später als eigene Ansicht an, nicht im Scan.

## 6. Jobs

- Ein Job ist ein `Start-Job`, also ein eigener Prozess, der die Adminrechte erbt. Der Server pollt die Jobs in der Hauptschleife und sammelt die Ausgabe in einer Liste je Job.
- **Es läuft immer nur ein ändernder Job** (Aktion, Rückgängig). Ein zweiter ergibt 409 „Es läuft bereits eine Änderung“. Lesen und Scan dürfen parallel laufen.
- Das Job-Log hat Zeilen der Form `"[HH:mm:ss] Text"`. Die Oberfläche fragt alle 1 s mit `from` nach.
- Abgeschlossene Jobs bleiben 30 Minuten abrufbar.

## 7. Änderungen absichern (T2)

### 7.1 Ablauf „Ausführen“ (ein Job für eine oder mehrere Aktionen)

1. **Lesen:** Für jede Aktion `Lesen` ausführen und den Vorher-Zustand festhalten. Ist der Zielzustand schon erreicht: Aktion überspringen und protokollieren.
2. **Voraussetzungen prüfen:** `Voraussetzung` jeder Aktion, z. B. Manipulationsschutz, Edition oder Hardware. Bei Fehlschlag diese Aktion mit Begründung überspringen.
3. **Wiederherstellungspunkt:**
   - `Checkpoint-Computer -Description "pc-check: <Titel bzw. n Änderungen>" -RestorePointType MODIFY_SETTINGS`.
   - Danach prüfen: Es muss einen Punkt mit `CreationTime` ≥ Jobstart − 1 min geben.
   - **Fehlt er, bricht der ganze Job ab und ändert nichts.** Die Meldung nennt die Ursache (Computerschutz aus oder 24-h-Sperre) und den Befehl zur Behebung.
4. **Journal-Eintrag vor der Änderung schreiben** (Status `begonnen`, mit Vorher-Zustand und Nummer des Wiederherstellungspunkts). Wenn der Prozess abstürzt, ist so trotzdem bekannt, was zurückzusetzen ist.
5. **Ausführen:** `Ausfuehren`, danach `Lesen` erneut.
   - Zielzustand erreicht: Status `erledigt`, Nachher-Zustand speichern.
   - Nicht erreicht oder Ausnahme: sofort `Rueckgaengig` mit dem Vorher-Zustand. Status `fehlgeschlagen` bzw. `fehlgeschlagen-zurueckgesetzt`.
6. **Ergebnis:** je Aktion `{ id, status, vorher, nachher, neustart }`. Braucht eine Aktion einen Neustart, zeigt die Oberfläche einen Hinweis. Neu gestartet wird nie automatisch.

### 7.2 Ablauf „Rückgängig“

Rückgängig ist selbst eine Änderung und folgt deshalb demselben Ablauf:
- neuer Wiederherstellungspunkt,
- Journal-Eintrag `rueckgaengig` mit `bezug = <eintragId>`,
- `Rueckgaengig` mit dem gespeicherten Vorher-Zustand,
- Prüfung per `Lesen`.

Hat sich der Zustand seit der Änderung geändert (aktuell ≠ gespeicherter Nachher-Zustand), fragt die Oberfläche vorher nach. Rückgängig gemachte Einträge kann man nicht noch einmal zurücknehmen; dafür führt man die Aktion neu aus.

### 7.3 `safety` in `/api/session`

```json
{ "schutzAn": true, "laufwerk": "C:", "sperre24h": true, "letzterPunkt": "2026-10-25T12:02:11",
  "befehl": "New-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore' -Name SystemRestorePointCreationFrequency -PropertyType DWord -Value 0 -Force" }
```

- `sperre24h` ist wahr, wenn `SystemRestorePointCreationFrequency` fehlt oder > 0 ist.
- Die Oberfläche zeigt dann ein Banner mit Erklärung und Befehl zum Kopieren.
- **Die GUI ändert das nicht selbst.** Es ist eine Systemeinstellung, die der Nutzer bewusst setzt.
- Ist der Computerschutz aus, sind alle Ausführen-Buttons gesperrt, und es gibt den Befehl `Enable-ComputerRestore -Drive 'C:\'`.

### 7.4 Journal (`changes/journal.json`)

```json
[{ "id": "20261025-132611-01", "zeit": "2026-10-25T13:26:11", "art": "ausfuehren|rueckgaengig",
   "aktion": "defender.netzwerkschutz", "titel": "Netzwerkschutz einschalten", "variante": null,
   "vorher": { ... }, "nachher": { ... }, "wiederherstellungspunkt": { "seq": 57, "zeit": "..." },
   "status": "begonnen|erledigt|fehlgeschlagen|fehlgeschlagen-zurueckgesetzt|zurueckgenommen",
   "bezug": null, "meldung": "", "benutzer": "demo" }]
```

- **Schreiben atomar:** erst in eine `.tmp`-Datei, dann `[IO.File]::Replace`.
- Einträge werden nie gelöscht. Wird ein Eintrag zurückgenommen, bekommt nur der ursprüngliche Eintrag den Status `zurueckgenommen`.

## 8. Aktionskatalog (`pc-check.aktionen.ps1`, T3)

Die Datei gibt ein Array von Hashtables zurück. `.psd1` kommt nicht in Frage, weil es keine Scriptblöcke erlaubt. Der Server lädt die Datei einmal per Dot-Source, Jobs laden sie erneut.

```powershell
@{
    Id          = 'defender.netzwerkschutz'          # eindeutig, [a-z0-9.-]
    Kategorie   = 'Sicherheit'                       # Sicherheit | Leistung | Gaming
    Pruefung    = 'Defender: Einstellungen'          # Check-Name aus dem Bericht → Karte erscheint beim Befund
    Titel       = 'Netzwerkschutz einschalten'
    Erklaerung  = 'Blockiert Verbindungen zu bekannten Phishing- und Malware-Servern, in allen Programmen.'
    Nutzen = 'mittel'; Aufwand = 'gering'; Risiko = 'gering'
    Neustart    = $false
    Bereich     = 'System'                           # System | Benutzer (HKCU: nur korrekt, wenn der angemeldete Nutzer selbst Admin ist)
    Varianten   = $null                              # oder @('Enabled','AuditMode') → Auswahl in der Oberfläche
    Befehle     = @{
        Ausfuehren   = 'Set-MpPreference -EnableNetworkProtection Enabled'
        Rueckgaengig = 'Set-MpPreference -EnableNetworkProtection <vorher>'
        Erklaerung   = @('Set-MpPreference ändert eine Einstellung von Microsoft Defender.',
                         '-EnableNetworkProtection Enabled schaltet den Schutz scharf; AuditMode würde nur protokollieren.')
    }
    Voraussetzung = { if ((Get-MpComputerStatus).IsTamperProtected -and $false) { 'Grund' } }   # $null/leer = ok, sonst Grund
    Lesen         = { $v = (Get-MpPreference).EnableNetworkProtection
                      [pscustomobject]@{ Aktiv = ($v -eq 1); Wert = @('aus','an','nur protokollieren')[$v]; Zustand = $v } }
    Ausfuehren    = { param($Variante) Set-MpPreference -EnableNetworkProtection Enabled }
    Rueckgaengig  = { param($Vorher) Set-MpPreference -EnableNetworkProtection $Vorher }
}
```

**Regeln:**
- `Lesen` ändert nie etwas und ist schnell (< 2 s).
- `Zustand` muss JSON-serialisierbar sein und reicht aus, um den alten Zustand exakt wiederherzustellen. Ein Registry-Wert, der vorher **nicht existierte**, wird als `$null` gespeichert. Rückgängig löscht ihn dann wieder, statt einen Standardwert zu setzen.
- `Ausfuehren` und `Rueckgaengig` sind idempotent und werfen bei Fehlern eine Ausnahme (`-ErrorAction Stop`).
- `Befehle.Ausfuehren` zeigt genau das, was `Ausfuehren` tut. Bei Varianten steht `<variante>` als Platzhalter.
- Keine Aktion, die sich nicht sauber zurücknehmen lässt.

**Erste Aktionen** (nur wenn der zugehörige Befund sie nahelegt, sonst grau mit Zustand):

| Id | Was |
|---|---|
| `defender.netzwerkschutz` | Netzwerkschutz an |
| `defender.pua` | Schutz vor potenziell unerwünschten Apps an |
| `defender.asr-basis` | ASR-Regeln „anfällige signierte Treiber“ und „LSASS-Diebstahl“ (Varianten Enabled/AuditMode) |
| `fernzugriff.remoteunterstuetzung` | Remoteunterstützung aus |
| `fernzugriff.rdp` | Remotedesktop aus |
| `netz.llmnr` | LLMNR aus (Policy) |
| `system.schnellstart` | Schnellstart aus (`HiberbootEnabled`) |
| `system.wiederherstellung` | Computerschutz auf C: an (ohne Wiederherstellungspunkt-Pflicht; Sonderfall) |
| `haertung.lsa` | LSA-Schutz an (Neustart; `RunAsPPL=2`, weil 1 eine nicht umkehrbare UEFI-Sperre setzt) |
| `haertung.treibersperrliste` | Sperrliste anfälliger Treiber an (Neustart) |
| ~~`energie.plan`~~ | entfällt: Das Ziel hängt von der Variante ab, `Lesen().Aktiv` kann es nicht eindeutig prüfen |
| `energie.aspm` | PCIe-Energieverwaltung (ASPM) im aktiven Plan aus |
| `gaming.spielmodus` | Spielmodus an (HKCU) |
| `gaming.hags` | Hardwarebeschleunigte GPU-Planung an (Neustart) |
| `gaming.gamedvr` | Hintergrundaufnahme (Game DVR) aus (HKCU) |
| `gaming.maus` | Mausbeschleunigung aus (HKCU) |
| `netz.eee` | Energiesparfunktionen der Netzwerkkarte aus (Varianten: Adapter) |

**Sonderfall `system.wiederherstellung`:** Diese Aktion schaltet die Wiederherstellungspunkte erst ein und kann deshalb vorher keinen anlegen. Sie ist die einzige Aktion mit `OhneWiederherstellungspunkt = $true`. Die Oberfläche weist ausdrücklich darauf hin.

## 9. Oberfläche (T4)

- Vanilla JS ohne Build-Schritt; die Tokens aus dem HTML-Bericht (`:root{--b03:#002b36 …}`) als CSS-Variablen.
- **Hash-Routing.** Navigation links, auf schmalen Fenstern oben:

| Route | Inhalt |
|---|---|
| `#/uebersicht` | Ampel, Zähler, nächste Schritte, lohnendste Tipps, Verlauf-Diagramme, Banner zur Absicherung |
| `#/sicherheit` | Kategorien 1–10 des Berichts, je Befund mit passender Aktionskarte |
| `#/leistung` | Hardware, Laufwerke & Speicherplatz, Energie, Auslastung |
| `#/gaming` | Gaming & Grafik plus Gaming-Check-Raster |
| `#/stabilitaet` | Stabilität |
| `#/checkliste` | wie im HTML, gespeichert über `/api/checklist` |
| `#/aenderungen` | Journal mit „↶ Rückgängig“, Liste der Wiederherstellungspunkte, Hinweis auf `rstrui.exe` |
| `#/berichte` | alle Berichte; öffnen (Original im iframe), zwei beliebige vergleichen (Status-Unterschiede) |
| `#/scan` | Optionen, Start, Live-Log, danach automatisch der neue Bericht |
| `#/einstellungen` | Profil, Zeitraum, Akzeptanzliste (erst nur anzeigen; bearbeiten später) |

- Angezeigt wird immer der **neueste Bericht**. Ein anderer lässt sich unter „Berichte“ wählen; oben steht dann ein Hinweis „Du siehst den Bericht vom …“.
- **Aktionskarte:**
  - Titel, Kennzeichen Nutzen/Aufwand/Risiko, aktueller Zustand, Button.
  - Darunter „▸ Befehl zeigen“: Ausführen- und Rückgängig-Befehl mit Erklärung je Zeile, Kopieren-Button.
  - Vor dem Ausführen ein Bestätigungsdialog mit Befehl, Hinweis auf den Wiederherstellungspunkt und gegebenenfalls Neustart.
- Mehrfachauswahl ist möglich („3 ausgewählte ausführen“ → ein Wiederherstellungspunkt).
- Hilfetexte (ⓘ, „So geht's“) kommen aus den Feldern `Steps`/`Command` der Befunde. `pc-check.hilfe.psd1` liefert der Server als JSON mit (`GET /api/help`, ergänzt).
- Die Seite muss ohne Netz funktionieren und darf nur Ressourcen von `'self'` laden.

## 10. Teilaufgaben und Modelle

| # | Aufgabe | Modell | hängt ab von | Dateien |
|---|---|---|---|---|
| T0 | Architektur, Mockup | Opus | – | `docs/` |
| T1 | Server, Start, Jobs, Scan | Sonnet | T0 | `pc-check-gui.*`, `gui/lib/Server.ps1` |
| T2 | Wiederherstellungspunkt, Journal, Ausführen/Rückgängig | Sonnet, Review Opus | T0 | `gui/lib/Safety.ps1` |
| T3 | Aktionskatalog | Sonnet, Review Opus | T2 (Schema) | `pc-check.aktionen.ps1` |
| T4 | Oberfläche | Sonnet | T0 (Mockup, API) | `gui/index.html`, `gui/app.*` |
| T5 | Tests, README, Hilfetexte | Haiku | T1–T4 | `tests/`, `README.md` |
| T6 | Zusammenbau, Sicherheitsreview, Test am PC | Opus + Nutzer | alle | – |

T1, T2 und T4 laufen parallel, da sie getrennte Dateien bearbeiten. T3 kommt nach T2. **Keine Teilaufgabe führt ändernde Aktionen am echten System aus.** Ausführen und Rückgängig testet der Nutzer in T6 selbst.

## 11. Schnittstelle Server ↔ Safety (T1 ↔ T2)

`gui/lib/Safety.ps1` wird per Dot-Source geladen, im Server **und** in jedem Job. Sie definiert genau diese Funktionen; alle bekommen `-Root` (Projektordner):

| Funktion | Rückgabe | Wo |
|---|---|---|
| `Get-PcCheckCatalog -Root` | Array der Katalog-Hashtables (lädt `pc-check.aktionen.ps1`; fehlt die Datei: leeres Array) | Server + Job |
| `ConvertTo-PublicAction -Action -State` | Objekt für `GET /api/actions` (ohne Scriptblöcke, Felder wie in Abschnitt 5) | Server |
| `Get-PcCheckActionStates -Root -Catalog` | Hashtable `Id → @{ aktiv; wert; stand }` (ruft alle `Lesen`; Fehler je Aktion → `wert = 'Fehler: …'`) | Job |
| `Get-PcCheckSafetyStatus` | Objekt wie in 7.3 | Server (muss < 1 s sein) |
| `Get-PcCheckRestorePoints` | Array `{ seq, zeit, beschreibung, typ }`, neueste zuerst | Server |
| `Get-PcCheckJournal -Root` | Array der Journal-Einträge, neueste zuerst | Server |
| `Invoke-PcCheckChange -Root -Ids [-Variante]` | Array `{ id, status, vorher, nachher, neustart, meldung }` | Job |
| `Undo-PcCheckChange -Root -EntryId [-Force]` | ein solches Objekt | Job |

**Protokoll in Jobs:**
- Fortschritt per `Write-Information -MessageData "[HH:mm:ss] Text" -InformationAction Continue`. Der Server liest `$job.ChildJobs[0].Information`.
- Das **einzige** Objekt auf der Ausgabe ist das Ergebnis. Der Server nimmt `Receive-Job` und stellt es als `ergebnis` bereit.
- Fehler, die den ganzen Job abbrechen (z. B. fehlender Wiederherstellungspunkt), sind `throw` mit einer verständlichen deutschen Meldung. Der Job wird dann `failed`, und `ergebnis = { error: Meldung }`.

**Testbarkeit:** Safety ruft den Wiederherstellungspunkt nur über `$script:PcCheckRestorePointImpl` auf, einen Scriptblock mit `param($Description)`, standardmäßig `Checkpoint-Computer`. Die Liste kommt aus `$script:PcCheckRestorePointListImpl`, standardmäßig `Get-ComputerRestorePoint`. Tests ersetzen beide.

## 12. Ergänzungen v2.1

| Methode und Pfad | Antwort / Zweck |
|---|---|
| `GET /assets/<name>.png\|svg` | Bilder aus `gui/assets/` (Name `^[a-z0-9-]+\.(png\|svg)$`), ohne Token; `/favicon.ico` = `morpheus-icon.png` |
| `GET /api/live` | Letzter Schnappschuss `{ stand, cpu, ram, gpu, net, top, drives, verlauf }`; erster Abruf `{ stand: null }` |

Den Schnappschuss sammelt ein Hintergrund-Runspace alle 2 s, aber nur, solange `/api/live` in den letzten 20 s abgefragt wurde. Der Server-Thread blockiert dabei nie.

## 13. Sicherer Betrieb (Install, Datenordner, Nur-Lesen)

Die GUI führt ihren Code mit Adminrechten aus. Deshalb gilt:

- **Code** liegt nur in einem Ordner, den ausschließlich Administratoren, SYSTEM und TrustedInstaller ändern dürfen (Standard `C:\Program Files\Morpheus`). `gui/lib/Install.ps1` prüft das mit SIDs (`Test-MorpheusSecurePath`, `Test-MorpheusCodeSecure`) und installiert dorthin (`Install-Morpheus`).
- **Daten** (`reports\`, `changes\journal.json`, `state\`, `accepted.psd1`) liegen in `C:\ProgramData\Morpheus` (`Initialize-MorpheusDataDir`: Besitzer Administratoren, ohne Vererbung, Schreiben nur Administratoren/SYSTEM). Das alte Journal wird bei der Installation nicht übernommen.
- `pc-check-gui.ps1`: sicher -> normaler Betrieb; unsicher + Admin -> Rückfrage „Installieren? [J/n]“, bei Nein oder ohne Adminrechte **Nur-Lesen-Modus** (`-ReadOnly` erzwingt ihn, `-NoInstallPrompt` für Tests). Im Nur-Lesen-Modus bleiben die Datenpfade beim Quellordner.
- `GET /api/session` liefert zusätzlich `readOnly`, `readOnlyReason`, `dataRoot`. Im Nur-Lesen-Modus antworten `POST /api/actions/run`, `POST /api/journal/<id>/undo` und `POST /api/scan` mit 403.
- Safety: alle Journal-Funktionen nehmen `-DataRoot` (Standard `-Root`). `Undo-PcCheckChange` prüft vor dem Ausführen, dass `vorher.zustand` zur Form passt, die `Lesen` liefert (gleiche Eigenschaftsnamen und Grundformen), sonst „Journal-Eintrag passt nicht zur Aktion“.
