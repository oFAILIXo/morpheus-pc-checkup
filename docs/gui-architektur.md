# pc-check GUI (v2.0): Architektur

Stand: 27.10.2026 (Version 2.3.3)

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
6. **Edge fehlt:** Die Konsole zeigt die Adresse (mit Einmal-Code) zum Öffnen von Hand. Seit 2.3.3 startet der Admin-Prozess keinen Standardbrowser mehr (Abschnitt 17). Das Ende erkennt dann nur der Heartbeat.
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
| `GET /assets/<name>.png\|svg\|jpg` | Bilder aus `gui/assets/` (Name `^[a-z0-9-]+\.(png\|svg\|jpg)$`), ohne Token; `/favicon.ico` = `morpheus-icon.png` |
| `GET /api/live` | Letzter Schnappschuss `{ stand, cpu, ram, gpu, net, top, drives, verlauf }`; erster Abruf `{ stand: null }` |

Den Schnappschuss sammelt ein Hintergrund-Runspace alle 2 s, aber nur, solange `/api/live` in den letzten 20 s abgefragt wurde. Der Server-Thread blockiert dabei nie.

## 13. Sicherer Betrieb (Install, Datenordner, Nur-Lesen)

Die GUI führt ihren Code mit Adminrechten aus. Deshalb gilt:

- **Code** liegt nur in einem Ordner, den ausschließlich Administratoren, SYSTEM und TrustedInstaller ändern dürfen (Standard `C:\Program Files\Morpheus`). `gui/lib/Install.ps1` prüft das mit SIDs (`Test-MorpheusSecurePath`, `Test-MorpheusCodeSecure`) und installiert dorthin (`Install-Morpheus`).
- **Daten** (`reports\`, `changes\journal.json`, `state\`, `accepted.psd1`) liegen in `C:\ProgramData\Morpheus` (`Initialize-MorpheusDataDir`: Besitzer Administratoren, ohne Vererbung, Schreiben nur Administratoren/SYSTEM). Das alte Journal wird bei der Installation nicht übernommen.
- `pc-check-gui.ps1`: sicher -> normaler Betrieb; unsicher + Admin -> Rückfrage „Installieren? [J/n]“, bei Nein oder ohne Adminrechte **Nur-Lesen-Modus** (`-ReadOnly` erzwingt ihn, `-NoInstallPrompt` für Tests). Im Nur-Lesen-Modus bleiben die Datenpfade beim Quellordner.
- `GET /api/session` liefert zusätzlich `readOnly`, `readOnlyReason`, `dataRoot`. Im Nur-Lesen-Modus antworten `POST /api/actions/run`, `POST /api/journal/<id>/undo` und `POST /api/scan` mit 403.
- Safety: alle Journal-Funktionen nehmen `-DataRoot` (Standard `-Root`). `Undo-PcCheckChange` prüft vor dem Ausführen, dass `vorher.zustand` zur Form passt, die `Lesen` liefert (gleiche Eigenschaftsnamen und Grundformen), sonst „Journal-Eintrag passt nicht zur Aktion“.

## 14. Ergänzungen v2.2 (Vertrag für alle Teilaufgaben)



### 14.1 Neue Dateien

Alle unter `gui\lib\` und damit automatisch in `Get-MorpheusCodeFiles` (Muster `gui\lib\*.ps1`). UTF-8 mit BOM, Windows PowerShell 5.1. **Keine Funktion ändert etwas am System**, außer den drei Defender-Funktionen in 14.4.

| Datei | Inhalt | geladen von |
|---|---|---|
| `gui\lib\Speicher.ps1` | Speicherverbraucher (#36) und Spieleliste (#38) | `pc-check.ps1` (Dot-Source), Job `speicher` |
| `gui\lib\Sicherung.ps1` | Datensicherung erkennen und bewerten (#35) | `pc-check.ps1` (Dot-Source) |
| `gui\lib\Defender.ps1` | Defender-Stand, Signaturen, Schnellscan, Offline-Scan (#34) | `pc-check-gui.ps1` (Dot-Source), Job `defender` |

`pc-check.ps1` lädt seine beiden Dateien per `. (Join-Path $PSScriptRoot 'gui\lib\<Datei>')`. Fehlt eine, ergibt die Prüfung `SKIP` mit „gui\lib\<Datei> fehlt“, und der Scan läuft weiter.

Kein `Add-Type` in den neuen Dateien: Der C#-Compiler schreibt in das %TEMP% des Benutzers.

### 14.2 Speicher.ps1

Ordner werden **ohne Verfolgen von Reparse Points** aufgezählt: Ordner mit `[IO.FileAttributes]::ReparsePoint` nicht betreten, Dateien mit dem Attribut nicht zählen. Aufzählung per `[IO.DirectoryInfo]` mit eigenem Stapel, `EnumerateFiles()`/`EnumerateDirectories()` je Ordner, kein `-Recurse`, kein `Get-ChildItem` in Schleifen. Ordner ohne Zugriff überspringen und zählen.

| Funktion | Rückgabe |
|---|---|
| `Get-MorpheusFesteLaufwerke` | `string[]` wie `'C:'`, `'F:'`: `Win32_LogicalDisk` mit `DriveType=3`, ohne Laufwerke auf Datenträgern mit `BusType` `USB` (wenn ermittelbar) |
| `Measure-MorpheusOrdnerGroesse -Pfad <string>` | `{ bytes:[double], dateien:[int], uebersprungen:[int] }` |
| `Select-MorpheusTopOrdner -Groessen <hashtable Pfad→Bytes> [-Top 10] [-Anteil 0.75]` | Array `{ pfad, bytes }`, absteigend. **Reine Funktion** ohne Dateizugriff, Algorithmus unten |
| `Measure-MorpheusLaufwerk -Laufwerk 'C:' [-Tiefe 3] [-Top 10] [-Anteil 0.75] [-Fortschritt <scriptblock>]` | Laufwerksobjekt (unten) |
| `ConvertFrom-MorpheusVdf -Text <string>` | verschachtelte Hashtable (Valve-KeyValues: `"key" "value"` und `"key" { … }`, Escapes `\\` und `\"`) |
| `Get-MorpheusSteamSpiele [-SteamPfad]` | Spiele-Array. Standard: `HKCU:\Software\Valve\Steam` `SteamPath`, sonst `HKLM:\SOFTWARE\WOW6432Node\Valve\Steam` `InstallPath` |
| `Get-MorpheusEpicSpiele [-ManifestOrdner]` | Spiele-Array. Standard `%ProgramData%\Epic\EpicGamesLauncher\Data\Manifests\*.item` |
| `Get-MorpheusGogSpiele`, `Get-MorpheusEaSpiele`, `Get-MorpheusUbisoftSpiele` | Spiele-Array aus der Registry (siehe unten) |
| `Get-MorpheusXboxSpiele [-Laufwerke]` | Spiele-Array: `<LW>\.GamingRoot` vorhanden → Unterordner von `<LW>\XboxGames` außer `GameSave` |
| `Get-MorpheusSpiele [-Laufwerke]` | alle Plattformen zusammen; doppelte Pfade (ohne Groß-/Kleinschreibung) nur einmal; absteigend nach `bytes` |
| `Get-MorpheusSpeicher [-Laufwerke] [-Fortschritt <scriptblock>] [-OhneSpiele]` | Gesamtobjekt (unten) |

`-Fortschritt` bekommt einen Text (`param($Text)`), z. B. „C: wird gezählt …“, „C:\Windows“, „Spiele werden gesucht …“. Aufruf je Laufwerk, je Ordner der obersten Ebene und je Plattform.

**Ordner ohne Doppelzählung (`Select-MorpheusTopOrdner`):** Die Schlüssel sind volle Pfade der Ordner in Tiefe 1 bis `-Tiefe` (Tiefe 1 = `C:\Windows`). Der Wert ist die Gesamtgröße inklusive aller Unterordner, auch der tieferen.
1. Ein Ordner, dessen größter direkter Unterordner (unter den Schlüsseln) mindestens `Anteil` × seiner Größe ausmacht, wird entfernt; der Unterordner vertritt ihn. Das gilt über mehrere Ebenen.
2. Die übrigen absteigend nach Größe. Ein Ordner wird übersprungen, wenn schon ein Vorfahr oder Nachfahr gewählt ist.
3. Höchstens `Top` Einträge, nie Ordner mit 0 Bytes.

Festlegung (25.10.2026): **Anteil 0,75**.

**Laufwerksobjekt** (JSON-Namen klein wie in der API):
```json
{ "laufwerk": "C:", "bezeichnung": "System", "groesse": 1000202039296, "frei": 300000000000,
  "ordner":  [ { "pfad": "C:\\Users\\Demo\\AppData", "bytes": 81234567890 } ],
  "dateien": [ { "pfad": "C:\\pagefile.sys", "bytes": 17179869184, "windows": true, "geaendert": "2026-10-25T09:12:00" } ],
  "gezaehlt": 812345, "uebersprungen": 224, "dauerSek": 94, "fehler": null }
```
`windows` ist `true` genau für `pagefile.sys`, `hiberfil.sys` und `swapfile.sys` im Stammordner. `fehler` enthält einen Text, wenn das ganze Laufwerk nicht lesbar war, sonst `null`.

**Spiel:**
```json
{ "plattform": "Steam", "name": "Demo Game", "pfad": "F:\\SteamLibrary\\steamapps\\common\\Demo Game", "laufwerk": "F:",
  "bytes": 98765432100, "zuletztGespielt": "2026-10-20T21:14:03", "groesseUnsicher": false }
```
- `plattform` ∈ `Steam`, `Epic`, `GOG`, `EA`, `Ubisoft`, `Xbox`.
- **Steam:** `libraryfolders.vdf` (alle Bibliotheken), je Bibliothek `steamapps\appmanifest_*.acf`: `name`, `installdir` (→ `steamapps\common\<installdir>`), `SizeOnDisk`, `LastPlayed` (Unix-Sekunden, 0 = nie → `null`). „Steamworks Common Redistributables“ (AppID 228980) weglassen.
- **Epic:** `DisplayName`, `InstallLocation`, `InstallSize`; ohne „zuletzt gespielt“.
- **GOG:** `HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games\*` (`gameName`, `path`); Größe gemessen.
- **EA app:** Deinstallationseinträge (`HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` und unter `WOW6432Node`) mit `Publisher` „Electronic Arts“ und vorhandenem `InstallLocation`, ohne die EA app selbst; Größe gemessen.
- **Ubisoft:** `HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs\*` (`InstallDir`); Name aus dem Deinstallationseintrag „Uplay Install <Id>“, sonst Ordnername; Größe gemessen.
- **Xbox:** Name aus `Content\MicrosoftGame.config` (`ShellVisuals/@DefaultDisplayName`), wenn lesbar, sonst Ordnername; Größe gemessen; `groesseUnsicher = $true`, wenn dabei Ordner übersprungen wurden.
- Gemessen wird mit `Measure-MorpheusOrdnerGroesse`. Ordner, die nicht existieren, kommen nicht in die Liste.

**Gesamtobjekt** (auch Cache-Datei `state\speicher.json` und Feld `Speicher` im JSON-Bericht):
```json
{ "version": 1, "stand": "2026-10-25T14:02:11", "laufwerke": [ "<Laufwerksobjekt>" ], "spiele": [ "<Spiel>" ] }
```

### 14.3 Sicherung.ps1 (#35)

| Funktion | Rückgabe |
|---|---|
| `Get-MorpheusDateiversionsverlauf [-ConfigOrdner] [-RegistryPfad]` | `{ art:'Dateiversionsverlauf', gefunden, aktiv, ziel, letzteSicherung, hinweis }` |
| `Get-MorpheusOneDriveSicherung` | wie oben mit `art:'OneDrive-Ordnersicherung'`, zusätzlich `ordner` (die gesicherten aus Desktop, Dokumente, Bilder) |
| `Get-MorpheusSystemabbild [-Laufwerke] [-IsAdmin]` | wie oben mit `art:'Systemabbild'` |
| `Get-MorpheusSicherung` | Array der drei Objekte |
| `Get-MorpheusSicherungBewertung -Eintraege <Array> [-Jetzt <datetime>]` | `{ status:'OK'\|'WARN', wert, empfehlung }`. **Reine Funktion** |

`letzteSicherung` ist ein ISO-Text (`yyyy-MM-ddTHH:mm:ss`) oder `$null`.

- **Dateiversionsverlauf:** `%LOCALAPPDATA%\Microsoft\Windows\FileHistory\Configuration\Config*.xml`: Ziel (`TargetUrl`/`TargetName`), an/aus. Letzte Sicherung aus `HKCU:\Software\Microsoft\Windows\CurrentVersion\FileHistory` `ProtectedUpToTime` (FILETIME), sonst Änderungszeit der Konfiguration. Ohne Konfiguration: `gefunden=$false`.
- **OneDrive:** Stammordner aus `HKCU:\Software\Microsoft\OneDrive\Accounts\*` (`UserFolder`). Ein Ordner gilt als gesichert, wenn sein Pfad aus `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders` (`Desktop`, `Personal`, `My Pictures`, Umgebungsvariablen aufgelöst) darin liegt. Das deckt die App „Windows-Sicherung“ mit ab, sie sichert Ordner über OneDrive; `hinweis` sagt das. Letzte Sicherung: unbekannt (`$null`).
- **Systemabbild:** Ordner `<LW>\WindowsImageBackup\*` auf allen Laufwerken mit Buchstaben (letzte Sicherung = jüngste Änderungszeit darin); mit Adminrechten zusätzlich `wbadmin get versions` (deutsche und englische Ausgabe). Älter als 180 Tage: `aktiv=$false`, Hinweis „veraltet“.
- **Bewertung:** OK, wenn mindestens ein Eintrag `gefunden` und `aktiv` ist und die letzte Sicherung, sofern bekannt, höchstens 30 Tage zurückliegt (Systemabbild 180 Tage). Sonst **WARN**. `wert` fasst alle drei zusammen, z. B. „Dateiversionsverlauf aus; OneDrive: Desktop, Dokumente; kein Systemabbild“. Die Empfehlung bei WARN nennt Dateiversionsverlauf bzw. OneDrive und ausdrücklich: „Sicherst du mit einem anderen Programm oder auf ein NAS, trag den Befund in die Akzeptanzliste (accepted.psd1) ein.“

### 14.4 Defender.ps1 (#34)

Testbar über `$script:MorpheusDefenderImpl`, eine Hashtable von Scriptblöcken (Standard = echte Cmdlets): `Status` (`Get-MpComputerStatus`), `Signaturen` (`Update-MpSignature -ErrorAction Stop`), `Schnellscan` (`Start-MpScan -ScanType QuickScan -ErrorAction Stop`), `Funde` (`param($Seit)`: `Get-MpThreatDetection` ab `$Seit`, Namen aus `Get-MpThreat`), `Offline` (`Start-MpWDOScan -ErrorAction Stop`). Tests ersetzen die Einträge.

| Funktion | Rückgabe |
|---|---|
| `Get-MorpheusDefenderStand` | `{ modus, signaturen (ISO), signaturVersion, signaturAlterTage, schnellscan (ISO von QuickScanEndTime), schnellscanAlterTage, echtzeit }`; bei Fehler `{ fehler: Text }` |
| `Invoke-MorpheusDefenderAktion -Art 'signaturen'\|'schnellscan'` | `{ art, vorher:<Stand>, nachher:<Stand>, funde:[{ zeit, name, aktion, erfolg, dateien }], dauerSek, meldung }` |
| `Start-MorpheusDefenderOffline` | ruft `Offline` auf; der PC startet danach neu |

- Fortschritt per `Write-Information "[HH:mm:ss] …" -InformationAction Continue`. Das Ergebnis ist das einzige Objekt auf der Ausgabe (wie in Abschnitt 11).
- Andere Werte als `signaturen`/`schnellscan` → `throw`.
- Funde werden nur angezeigt. Quarantäne und Entfernen bleiben in Windows-Sicherheit; `meldung` sagt das, wenn es Funde gibt.
- Kein Journal-Eintrag (keine Einstellungsänderung), aber die Windows-Bestätigung im Admin-Prozess vor jeder der drei Funktionen.

### 14.5 Scan (`pc-check.ps1`)

- Neuer Schalter `-SkipSpeicher` (wie `-SkipWinget`). Die GUI übergibt ihn bei `skipSpeicher: true` in `POST /api/scan`.
- Abschnitt „Laufwerke & Speicherplatz“, nach „Freier Speicherplatz“: `Invoke-Check 'Größte Speicherverbraucher'` → `Get-MorpheusSpeicher` (Fortschritt als `Write-Host`-Zeile), Ergebnis in `$script:Speicher`. Tabellen `Speicherverbraucher: Ordner` (`Laufwerk, Pfad, Groesse, Bytes`) und `Speicherverbraucher: Dateien` (`Laufwerk, Pfad, Groesse, Bytes, Windows`). Befund `INFO` mit dem größten Ordner je Laufwerk; mit `-SkipSpeicher` `SKIP 'Übersprungen (-SkipSpeicher)'`.
- In „Spielebibliotheken“ zusätzlich die Tabelle `Installierte Spiele` (`Plattform, Name, Laufwerk, Groesse, Bytes, ZuletztGespielt, Pfad, Hinweis`) aus `$script:Speicher.spiele`, sonst aus `Get-MorpheusSpiele`. Die bisherige Auswertung bleibt.
- Abschnitt „Verschlüsselung & Firmware“, nach „Wiederherstellung“: `Invoke-Check 'Datensicherung'` → Tabelle `Datensicherung` (`Art, Gefunden, Aktiv, Ziel, LetzteSicherung, Hinweis`) und ein Befund aus `Get-MorpheusSicherungBewertung`.
- JSON-Bericht: neues Feld `Speicher` (Gesamtobjekt oder `null`).

### 14.6 API

| Methode und Pfad | Antwort / Zweck |
|---|---|
| `GET /api/speicher` | Inhalt von `<DataRoot>\state\speicher.json` (Gesamtobjekt) oder `{ "stand": null }` |
| `POST /api/speicher/refresh` | Job `speicher` → `{ jobId }`; läuft schon einer, dessen `jobId`. Der Job schreibt den Cache atomar; Ergebnis `{ stand }` |
| `GET /api/defender` | `{ stand:<Defender-Stand>, laufend:<jobId\|null>, offline:<Offline-Zustand> }` |
| `POST /api/defender/run` | Body `{ art: "signaturen"\|"schnellscan" }` → Windows-Bestätigung → Job `defender` → `{ jobId }`; 409, wenn schon eine Defender-Aufgabe läuft |
| `POST /api/defender/offline` | Body `{ bestaetigt: true }` (sonst 400) → Windows-Bestätigung → Countdown 15 s → `<Offline-Zustand>` |
| `GET /api/defender/offline` | `<Offline-Zustand>`; jeder Abruf gilt als Lebenszeichen des Fensters |
| `POST /api/defender/offline/abbrechen` | Countdown beenden → `<Offline-Zustand>` |
| `POST /api/defender/offline/jetzt` | nur während des Countdowns: sofort starten → `<Offline-Zustand>` |

`<Offline-Zustand>` = `{ status: "keiner"|"countdown"|"abgebrochen"|"gestartet"|"fehler", rest: <Sekunden>, meldung }`.

- Im Nur-Lesen-Modus antworten `POST /api/speicher/refresh`, `POST /api/defender/run` und alle `POST /api/defender/offline*` mit 403, weil der Job Code aus einem ungesicherten Ordner mit Adminrechten ausführen würde. `Start-GuiJob` sperrt `speicher` und `defender` zusätzlich.
- **Countdown im Server:** Zustand in `$script:Gui.Offline`. Die Hauptschleife prüft ihn bei jedem Durchlauf (höchstens alle 500 ms) und während des Countdowns jede Sekunde die Edge-Prozesse. Abbruch, wenn (a) seit 3 s kein `GET /api/defender/offline` kam, (b) kein Edge-Prozess mit dem Profil mehr läuft oder (c) die Schleife endet. Erst bei `rest = 0` bzw. „jetzt“ ruft der Server `Start-MorpheusDefenderOffline`. Jeder Zustandswechsel steht in `gui.log`.
- Die Texte im Windows-Bestätigungsdialog nennen genau, was passiert. Beim Offline-Scan: „Der PC startet nach 15 Sekunden neu und wird ca. 15 Minuten lang offline gescannt. Vorher alles speichern.“

### 14.7 Oberfläche

- **Neue Ansicht `#/werkzeuge` „Werkzeuge“** (Navigation, Symbol `i-tool`): Karte „Microsoft Defender“ mit Stand (Signaturen, Alter, letzter Schnellscan) und drei Knöpfen „Signaturen aktualisieren“, „Schnellscan starten“, „Offline-Scan …“. Ergebnisdialog: Stand vorher → nachher, Funde (oder „Keine Funde“) mit Hinweis auf Windows-Sicherheit > Schutzverlauf.
- **Knopf am Befund:** „Defender: Signaturen“ → „Signaturen aktualisieren“, „Defender: Scans“ → „Schnellscan starten“, jeweils wenn der Status nicht `OK` ist (Festlegung 25.10.2026). Gleicher Dialog wie unter „Werkzeuge“.
- **Offline-Scan:** Dialog mit Warnung und Häkchen („Ich habe alles gespeichert …“), erst dann „Weiter“ → Windows-Bestätigung → Countdown-Dialog (große Zahl, „Abbrechen“ vorbelegt, „Jetzt neu starten“), Abfrage jede Sekunde.
- **Speicher-Fenster:** Jede Zeile der Live-Karte „Laufwerke“ ist fokussierbar (`tabindex=0`, `role=button`, `aria-haspopup=dialog`). Hover (300 ms Verzögerung), Klick, Enter oder Leertaste öffnen ein Fenster links neben der Statusleiste. Escape oder ein Klick daneben schließt es; die Maus darf hineinwandern. Inhalt für das Laufwerk: „Stand: …“ (Datum und Quelle: Bericht oder neu berechnet), Ordner (10), Dateien (10; Systemdateien mit Kennzeichen „Windows“ und Erklärung), Spiele (10; Plattform, Größe, zuletzt gespielt, ggf. „Größe eingeschränkt lesbar“). Ein Klick auf einen Eintrag kopiert den Pfad (`navigator.clipboard`) und zeigt „Pfad kopiert“. Fußzeile: „Neu berechnen“ (Job mit Fortschritt, gesperrt im Nur-Lesen-Modus), „Alle Spiele“ (→ Rohdaten `Installierte Spiele`), Hinweis „Deinstallieren nur über die Plattform; Morpheus löscht nichts.“
- **Datenquelle:** das jüngere von `S.report.Speicher` und `GET /api/speicher` (Feld `stand`). Geladen beim Start, nach „Neu berechnen“ und nach einem Scan. **Der Hover lädt und rechnet nichts.**
- Kein `innerHTML`; alle Texte über `h()`.

### 14.8 Eigene Spiele-Ordner (Ergänzung zu #38)

Findet die automatische Erkennung eine Bibliothek nicht, trägt man sie selbst ein: je Eintrag eine **Plattform** und ein **Ordner**. Der Ordner gilt als **Bibliothek**: Jeder direkte Unterordner ist ein Spiel (Name = Ordnername, Größe gemessen, kein „zuletzt gespielt“). Eingabe als **Pfad im Textfeld** (kein Ordnerdialog, der würde mit Adminrechten laufen). Das Laufwerk ergibt sich aus dem Pfad.

- **Datei:** `<DataRoot>\state\spielordner.json` = `[{ "plattform": "Steam", "pfad": "G:\\Games\\Steam" }]`. Höchstens 50 Einträge. `plattform` ∈ `Steam`, `Epic`, `GOG`, `EA`, `Ubisoft`, `Xbox`, `Andere`.
- **Speicher.ps1:**
  - `Read-MorpheusSpielordner -Datei <string>` → bereinigtes Array (unbekannte Plattform, ungültige oder nicht lokale Pfade fallen weg, fehlende/kaputte Datei = leeres Array).
  - `Get-MorpheusManuelleSpiele -Eintraege <Array>` → Spiele-Array. Pfad über `MorpheusSpeicherPfadNorm` (nur `X:\…`), Ordner muss existieren und darf kein Reparse Point sein; Unterordner, die Reparse Points sind, werden übersprungen.
  - `Get-MorpheusSpiele` und `Get-MorpheusSpeicher` bekommen `-Manuell <Array>`. Doppelte Pfade: der automatisch erkannte Eintrag gewinnt (er hat ggf. „zuletzt gespielt“).
- **Scan:** `pc-check.ps1 -SpielOrdnerFile <Pfad>`, Standard `Join-Path (Split-Path -Parent $OutputDir) 'state\spielordner.json'` (GUI und `pc-check-start.ps1` landen damit in `<DataRoot>\state`). Die Datei wird nur gelesen.
- **API:**
  - `GET /api/spielordner` → Array (leer, wenn die Datei fehlt).
  - `POST /api/spielordner` Body `{ "eintraege": [ { "plattform", "pfad" } ] }` → prüft jeden Eintrag (Plattform per `-cin` aus der Liste; `pfad` Text ≤ 260 Zeichen, `^[A-Za-z]:\\`, keine Steuerzeichen, keine Segmente `.`/`..`, Ordner existiert und ist kein Reparse Point) → 400 mit dem Namen des fehlerhaften Eintrags, sonst atomar speichern und das gespeicherte Array zurückgeben. Im Nur-Lesen-Modus 403. Keine Windows-Bestätigung (keine Systemänderung; die Datei liegt im Datenordner nur für Admins).
  - Der Job `speicher` liest die Datei und übergibt `-Manuell`.
- **Oberfläche:** In „Werkzeuge“ eine Karte „Spiele-Ordner“: Liste der Einträge (Plattform-Auswahl, Pfadfeld, „Entfernen“), „Ordner hinzufügen“, „Speichern“; Erklärung „Ordner, in dem jeder Unterordner ein Spiel ist, z. B. F:\Games. Pfad im Explorer kopieren (Adressleiste) und hier einfügen.“ Nach dem Speichern Hinweis mit Knopf „Jetzt neu berechnen“ (startet den Speicher-Job). Im Speicher-Fenster in der Fußzeile der Link „Spiele-Ordner festlegen …“ (→ `#/werkzeuge`). Im Nur-Lesen-Modus gesperrt.

## 15. Ergänzungen v2.3: Sysinternals (Vertrag für alle Teilaufgaben)

Werkzeuge: `autorunsc64.exe` (alle Autostarts) und `sigcheck64.exe` (Signaturen) von Microsoft Sysinternals. **Kein VirusTotal** (`-v`, `-vt`, `-vr`, `-vs` sind verboten; `-u` nur ohne VirusTotal), weil dabei Daten den PC verlassen.

### 15.1 Grundsätze

- **Bezug nur auf Klick** in der Ansicht „Werkzeuge“: Lizenz zeigen → Nutzer nimmt ausdrücklich an (Häkchen) → Windows-Bestätigung im Admin-Prozess → Job lädt herunter. Einzige neue Netzadressen: `https://download.sysinternals.com/files/Autoruns.zip` und `…/Sigcheck.zip` (feste Konstanten, keine Weiterleitungen, höchstens 20 MB).
- **Ablage** `<DataRoot>\tools` (= `C:\ProgramData\Morpheus\tools`), angelegt mit `New-MorpheusSecureDirectory` (fertige Rechte, nur Administratoren und SYSTEM). Ein vorhandener, unsicherer `tools`-Ordner wird nicht benutzt (Fehler).
- **ZIP:** Nur Einträge, deren `FullName` exakt (`-ceq`) `autorunsc64.exe`, `sigcheck64.exe` bzw. `Eula.txt` lautet (kein Pfadanteil, damit kein Zip-Slip), je höchstens 30 MB entpackt. Alles andere bleibt im ZIP; das ZIP wird danach gelöscht.
- **Vertrauensprüfung vor jedem Start** (nicht nur nach dem Download), im selben Ablauf wie der Start (siehe 15.3): Datei vorhanden und kein Reparse Point; `Test-MorpheusSecurePath` (Datei mit Elternordnern) sicher; SHA256 gleich dem Eintrag in `tools\werkzeuge.json`; `Get-AuthenticodeSignature` = `Valid`; Signierer-Zertifikat mit `O=Microsoft Corporation`; Kette endet an einer der Microsoft-Wurzeln `3B1EFD3A66EA28B16697394703A72CA340A05BD5` (Root CA 2010) oder `8F43288AD272F3103B6FB1428485EA3014C0BCFE` (Root CA 2011). Schlägt eine Prüfung fehl: nicht starten, Grund melden.
- **TOCTOU:** Der Start öffnet die EXE vorher mit `FileShare.Read` (kein Schreiben, Umbenennen, Löschen durch andere), berechnet den Hash aus diesem Handle, prüft die Signatur und startet den Prozess, während das Handle offen bleibt. Erst nach Prozessende wird es geschlossen.
- **Lizenz-Zustimmung:** `<DataRoot>\state\sysinternals.json` = `{ "version": 1, "eulaAkzeptiert": true, "zeit": "yyyy-MM-ddTHH:mm:ss", "benutzer": "<Name>" }`. Gilt nur, wenn die Datei sicher liegt (`Test-MorpheusSecurePath`). `-accepteula` wird nur übergeben, wenn die Zustimmung gilt; ohne Zustimmung startet kein Werkzeug (sonst hinge es am Lizenzdialog).
- **Scan bleibt lesend.** Er startet die Werkzeuge nur, wenn sie vorhanden und geprüft sind, mit festen Argumenten (keine freien Argumente von außen). Fehlen sie oder fehlt die Zustimmung: `SKIP` mit Hinweis auf „Werkzeuge“. Sind sie vorhanden, aber die Prüfung schlägt fehl: `WARN` „nicht ausgeführt“ mit Grund.
- **Ausgaben sind Daten:** CSV robust parsen (eigener RFC-4180-Parser), Steuerzeichen entfernen, Felder auf 2048 Zeichen und Zeilen auf 5000 begrenzen. Angezeigt wird nur über `h()`/`textContent` bzw. die vorhandene HTML-Kodierung der Berichte.
- Kein `Add-Type` mit C#-Code in den neuen Dateien. `Add-Type -AssemblyName System.IO.Compression.FileSystem` (lädt nur eine vorhandene Assembly) ist erlaubt.

### 15.2 Neue Dateien

| Datei | Inhalt | geladen von |
|---|---|---|
| `gui\lib\Sysinternals.ps1` | Bezug, Zustimmung, Vertrauensprüfung, gesicherter Start | `pc-check.ps1`, `pc-check-gui.ps1`, Job `sysinternals` |
| `gui\lib\SysinternalsAuswertung.ps1` | Ausgabe dekodieren, CSV parsen, Bewertung (ohne Netz) | wie oben |

`Sysinternals.ps1` lädt `Install.ps1` und `SysinternalsAuswertung.ps1` (gleicher Ordner) per Dot-Source, falls deren Funktionen fehlen. Beide liegen unter `gui\lib\*.ps1` und sind damit in `Get-MorpheusCodeFiles`.

### 15.3 Sysinternals.ps1

Konstanten: `$script:MorpheusSysWerkzeuge` (geordnet) mit `autorunsc = @{ Zip='Autoruns.zip'; Url='https://download.sysinternals.com/files/Autoruns.zip'; Exe='autorunsc64.exe'; Titel='Autoruns' }` und `sigcheck = @{ Zip='Sigcheck.zip'; Url='https://download.sysinternals.com/files/Sigcheck.zip'; Exe='sigcheck64.exe'; Titel='Sigcheck' }`, `$script:MorpheusSysWurzeln` (die zwei Fingerabdrücke), `$script:MorpheusSysLizenzUrl = 'https://learn.microsoft.com/sysinternals/license-terms'`.

Testbar über `$script:MorpheusSysImpl` (Hashtable von Scriptblöcken, nur gesetzt, wenn noch nicht vorhanden): `Download` (`param($Url, $Ziel, $MaxBytes)`, HttpWebRequest, TLS 1.2, `AllowAutoRedirect = $false`, Status 200 Pflicht, Abbruch über `$MaxBytes`, Zeitlimit 120 s), `Signatur` (`param($Pfad)` → Objekt mit `Status`, `SignerCertificate`), `Wurzel` (`param($Zertifikat)` → Fingerabdruck der Wurzel oder `$null`; `X509Chain` ohne Sperrprüfung, `IgnoreNotTimeValid`), `SicherPfad` (`param($Pfad)` → `Test-MorpheusSecurePath`), `Admin` (→ bool). Tests ersetzen die Einträge; **Tests laden nie etwas herunter**.

| Funktion | Rückgabe |
|---|---|
| `Get-MorpheusSysZustimmung -DataRoot` | `{ akzeptiert:[bool], zeit, benutzer }` (fehlende, kaputte oder unsicher liegende Datei → `akzeptiert = $false`) |
| `Set-MorpheusSysZustimmung -DataRoot -Akzeptiert [bool]` | schreibt atomar (`.tmp` + Replace/Move) bzw. löscht die Datei; gibt den neuen Stand zurück |
| `Test-MorpheusSysWerkzeug -DataRoot -Name autorunsc\|sigcheck` | `{ name, titel, datei, pfad, vorhanden, geprueft, grund, signierer, version, sha256, geladen }`. `grund` ist bei `geprueft = $false` ein deutscher Satz, sonst `$null`. Nur lesend, < 1 s |
| `Get-MorpheusSysStand -DataRoot` | `{ zustimmung:<Zustimmung>, werkzeuge:[<Werkzeug>, <Werkzeug>], ordner, lizenzUrl }` |
| `Invoke-MorpheusSysWerkzeug -DataRoot -Auftrag autostarts\|system32\|treiber [-TimeoutSek 900]` | `{ ok:[bool], auftrag, code, text, fehler, dauerSek, nichtVertrauenswuerdig:[bool], nichtEingerichtet:[bool] }`. Wirft nie. `nichtVertrauenswuerdig = $true`, wenn die Vertrauensprüfung einer vorhandenen Datei fehlschlug; `nichtEingerichtet = $true`, wenn die Datei oder die Zustimmung fehlt (`fehler` = Grund) |
| `Install-MorpheusSysWerkzeuge -DataRoot` | Job: lädt beide Werkzeuge, prüft, entpackt; `{ werkzeuge:[<Werkzeug>…], meldung }`. Wirft (deutsch) ohne Adminrechte oder ohne Zustimmung |
| `Remove-MorpheusSysWerkzeuge -DataRoot` | löscht EXEs, `*-Eula.txt`, `werkzeuge.json` und die Zustimmung; gibt `Get-MorpheusSysStand` zurück |
| `Get-MorpheusSysEula -DataRoot -Name` | Text aus `tools\<name>-Eula.txt` (höchstens 64 KB) oder `$null` |

**Aufträge (feste Argumente, sonst nichts):**

| Auftrag | Werkzeug | Argumente |
|---|---|---|
| `autostarts` | autorunsc | `-accepteula -nobanner -a * -c -s *` (letztes `*` = alle Benutzerprofile) |
| `system32` | sigcheck | `-accepteula -nobanner -c -u -e -r "%SystemRoot%\System32"` (`-r` = keine Online-Sperrlistenprüfung) |
| `treiber` | sigcheck | `-accepteula -nobanner -c -u -e -r "%SystemRoot%\System32\drivers"` |

**Nachträge nach Review und Sicherheitsprüfung**: Die Vertrauensprüfung verlangt zusätzlich, dass die Versionsinfo `Sysinternals` als Firma oder Produkt nennt (Impl `Herkunft`). Die Kette wird mit den Zertifikaten aus der eingebetteten Signatur als `ExtraStore` gebaut (Impl `Wurzel` mit `param($Zertifikat, $Pfad)`). ZIP-Namen werden ohne Groß-/Kleinschreibung verglichen, weiterhin ohne Pfadanteil. `Remove` löscht zuerst die EXEs und bricht ab, wenn eine benutzt wird. `install`/`entfernen` antworten 409, solange ein Scan läuft, und umgekehrt. `Test-MorpheusSysKopf -Text -Art autoruns|sigcheck` erkennt Ausgaben ohne CSV-Kopf (dann SKIP statt OK). Aufgaben (`Tasks`/`Scheduled Tasks`) gelten nur als erhöht, wenn sie laut `Get-ScheduledTask` als SYSTEM, Dienstkonto oder mit höchsten Rechten laufen (`-Aufgaben`). Dienste und Treiber ergeben in den Autoruns-Befunden höchstens INFO, weil eigene Prüfungen sie bewerten. Für den Elternordner zählt nur die Maske für Löschen, Ersetzen und Rechte ändern. Die drei Prüfungen brauchen Adminrechte.

**Start (`MorpheusSysStart`, privat):** `System.Diagnostics.Process`, `UseShellExecute = $false`, `CreateNoWindow`, Standardausgabe und Fehlerausgabe umgeleitet und als **Bytes** gelesen (asynchron, damit nichts blockiert), Zeitlimit → Prozess beenden, `ok = $false`. Text über `ConvertFrom-MorpheusSysAusgabe`. Arbeitsordner = `tools`.

**`tools\werkzeuge.json`** = `{ "version": 1, "werkzeuge": { "autorunsc": { "datei": "autorunsc64.exe", "sha256": "…", "version": "14.11", "geladen": "…" }, "sigcheck": { … } } }`, atomar geschrieben vom Install-Job.

**Install-Ablauf je Werkzeug:** ZIP nach `tools\<Zip>.download` laden → Einträge prüfen → EXE nach `tools\<name>.neu.exe` entpacken → Vertrauensprüfung dieser Datei (ohne Hash-Vergleich) → an den endgültigen Namen verschieben (vorhandene ersetzen) → SHA256 und Dateiversion in `werkzeuge.json` → `Eula.txt` als `tools\<name>-Eula.txt` → ZIP und Reste löschen (auch bei Fehlern, `finally`). Fortschritt per `Write-Information "[HH:mm:ss] …"`, einziges Ausgabeobjekt ist das Ergebnis.

### 15.4 SysinternalsAuswertung.ps1

| Funktion | Rückgabe |
|---|---|
| `ConvertFrom-MorpheusSysAusgabe -Bytes [byte[]]` | Text: BOM `FF FE` → UTF-16LE, `EF BB BF` → UTF-8; sonst UTF-16LE, wenn in den ersten 400 Bytes ≥ 30 % der ungeraden Stellen 0 sind; sonst UTF-8 (streng), bei ungültigen Bytes ANSI (`[Text.Encoding]::Default`). Leer/`$null` → `''` |
| `ConvertFrom-MorpheusCsvText -Text [-Trenner ',']` | Liste von `string[]` (RFC 4180: Anführungszeichen, `""`, Zeilenumbrüche in Feldern, CRLF/LF/CR) |
| `ConvertFrom-MorpheusAutorunsCsv -Text` | Einträge `{ Ort, Eintrag, Aktiv:[bool], Kategorie, Profil, Beschreibung, Signierer, Verifiziert:[bool], Firma, Pfad, DateiFehlt:[bool], Version, Befehl, Sha256 }` |
| `ConvertFrom-MorpheusSigcheckCsv -Text` | Einträge `{ Pfad, Verifiziert, Signiert:[bool], Datum, Herausgeber, Firma, Beschreibung, Produkt, Version, Typ }` |
| `Test-MorpheusPfadBenutzerBeschreibbar -Pfad` | `$true`/`$false`, `$null` wenn die Datei fehlt |
| `Test-MorpheusAutorunsErhoeht -Eintrag` | bool |
| `Get-MorpheusAutorunsSignaturBefund -Eintraege` | `{ status, wert, empfehlung, liste }` |
| `Get-MorpheusAutorunsPfadBefund -Eintraege [-Beschreibbar <scriptblock>]` | `{ status, wert, empfehlung, liste }` |
| `Get-MorpheusSystemdateienBefund -System32 -Treiber` | `{ status, wert, empfehlung, liste }` |

- **Autoruns-CSV:** Kopfzeile = erste Zeile mit den Spalten `Entry Location` und `Image Path` (Groß-/Kleinschreibung egal), Spalten über den Namen zuordnen (`Entry Location`, `Entry`, `Enabled`, `Category`, `Profile`, `Description`, `Signer`, `Company`, `Image Path`, `Version`, `Launch String`, `SHA-256`); fehlende Spalten = `''`. Zeilen ohne `Entry` und ohne `Image Path` entfallen. `Aktiv` = `Enabled` ist `enabled`. `Verifiziert` = `Signer` beginnt mit `(Verified)`. `Image Path` mit Präfix `File not found: ` → Präfix entfernen, `DateiFehlt = $true`. Ohne Kopfzeile: leeres Array.
- **Sigcheck-CSV:** Kopfzeile = erste Zeile, deren erstes Feld `Path` ist; Spalten `Path`, `Verified`, `Date`, `Publisher`, `Company`, `Description`, `Product`, `File version`, `Machine type`. `Signiert` = `Verified` ist `Signed`.
- **Beschreibbar:** Datei und Elternordner; Besitzer nicht Administratoren/SYSTEM/TrustedInstaller → `$true`; ein Allow-Eintrag (nicht nur vererbend) mit Schreibbits (wie `$script:MorpheusWriteMask` in `Install.ps1`) für eine andere SID als Administratoren, SYSTEM, TrustedInstaller, ERSTELLER-BESITZER (`S-1-3-0`), BESITZERRECHTE (`S-1-3-4`) → `$true`.
- **Erhöht** (läuft als SYSTEM, Dienst oder Kernel): Kategorie (ohne Leerzeichen, Groß-/Kleinschreibung egal) ∈ `Services`, `Drivers`, `ScheduledTasks`, `Winlogon`, `BootExecute`, `LSAProviders`, `PrintMonitors`, `KnownDLLs`, `WinsockProviders`, `NetworkProviders`, `WMI`, `ImageHijacks`, `AppInit`. Alles andere (z. B. `Logon`, `Explorer`) läuft als angemeldeter Benutzer.
- **Signatur-Befund** (nur `Aktiv`, nicht `DateiFehlt`, nicht `Verifiziert`): erhöhte vorhanden → `WARN`; nur Benutzer-Ebene → `INFO`; keine → `OK`. `wert` z. B. „2 Dienste/Treiber/Aufgaben ohne verifizierte Signatur: A, B; 3 weitere Autostarts ohne Signatur“ (höchstens 5 Namen je Gruppe, dann „…“). `liste` = betroffene Einträge.
- **Pfad-Befund** (nur `Aktiv`, nicht `DateiFehlt`, `Beschreibbar` = `$true`): erhöhte → `WARN` (ein Benutzerprogramm könnte die Datei austauschen und so SYSTEM-Rechte erlangen); nur Benutzer-Ebene → `INFO` (üblich bei Programmen in AppData, kein Rechtegewinn); keine → `OK`.
- **Systemdateien-Befund:** unsignierte in `System32` oder `drivers` → `WARN` mit Anzahl und bis zu 5 Dateinamen, sonst `OK`.

### 15.5 Scan (`pc-check.ps1`)

- Neuer Schalter `-SkipSysinternals` (wie `-SkipWinget`); die GUI übergibt ihn bei `skipSysinternals: true` in `POST /api/scan`.
- DataRoot des Scans = `Split-Path -Parent $OutputDir` (wie `SpielOrdnerFile`).
- Abschnitt „Autostart & Persistenz“, nach „Autostart-Einträge“: `Invoke-Check 'Autostarts: Signaturen (Autoruns)'` und `Invoke-Check 'Autostarts: beschreibbare Pfade (Autoruns)'`. Autoruns läuft einmal (Ergebnis in `$script:Autoruns`). Tabelle `Autostarts (Autoruns, ohne Microsoft)` mit `Kategorie, Eintrag, Aktiv, Signierer, Verifiziert, Beschreibbar, Erhoeht, Pfad, Ort, Befehl` (Einträge, die nicht verifiziert von Microsoft signiert sind).
- Abschnitt „Systemhärtung“, am Ende: `Invoke-Check 'Systemdateien: Signaturen (Sigcheck)'` (Aufträge `system32` und `treiber`), Tabelle `Unsignierte Systemdateien (Sigcheck)` mit `Ordner, Datei, Firma, Beschreibung, Version, Datum, Pfad`.
- SKIP-Texte: „Übersprungen (-SkipSysinternals)“; „Sysinternals nicht eingerichtet: in Morpheus unter Werkzeuge herunterladen“ (fehlende Datei oder Zustimmung); Zeitüberschreitung/Fehler: „Fehler: …“. Vertrauensprüfung fehlgeschlagen: `WARN` „<Werkzeug> nicht ausgeführt: <Grund>“ mit Empfehlung „Unter Werkzeuge neu herunterladen; bleibt die Meldung, die Datei nicht verwenden.“

### 15.6 API

| Methode und Pfad | Antwort / Zweck |
|---|---|
| `GET /api/sysinternals` | `Get-MorpheusSysStand` plus `laufend:<jobId\|null>` |
| `POST /api/sysinternals/install` | Body `{ eulaAkzeptiert: true }` (genau Boolean `true`, sonst 400) → 409, wenn ein `sysinternals`-Job läuft → Windows-Bestätigung → Job `sysinternals` (speichert erst dort die Zustimmung, dann `Install-MorpheusSysWerkzeuge`) → `{ jobId }` |
| `POST /api/sysinternals/entfernen` | 409 bei laufendem Job → Windows-Bestätigung → `Remove-MorpheusSysWerkzeuge` → Stand |
| `GET /api/sysinternals/eula?name=autorunsc\|sigcheck` | `{ name, text }` (`text` = `$null`, wenn nicht vorhanden); `name` per `-cin` aus der Liste, sonst 400 |

- Nur-Lesen-Modus: beide `POST` → 403; `Start-GuiJob` sperrt `sysinternals` zusätzlich und verlangt einen Bestätigungstext.
- Bestätigungstext Install: „Sysinternals-Werkzeuge Autoruns und Sigcheck von download.sysinternals.com (Microsoft) herunterladen? Du nimmst damit die Sysinternals-Lizenzbedingungen an. Die Dateien landen in <Ordner> und werden vor jedem Start auf eine gültige Microsoft-Signatur geprüft. Hast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'.“

### 15.7 Oberfläche

- Ansicht „Werkzeuge“: neue Karte „Sysinternals (Microsoft)“ unter „Microsoft Defender“. Je Werkzeug eine Zeile mit Zustand (geprüft: „Signiert von Microsoft Corporation · Version · geladen am“; sonst Grund) und Lizenzstand.
- Nicht eingerichtet: Knopf „Herunterladen …“ (türkis, Primär) → Dialog: was passiert (Quelle, Größe ca. 4 MB, Ablage, Signaturprüfung vor jedem Start, kein VirusTotal, keine Daten verlassen den PC außer der Download-Anfrage), kurze Zusammenfassung der Lizenz mit Link „Lizenzbedingungen lesen“ (`lizenzUrl`, `target=_blank`, `rel=noopener noreferrer`), Häkchen „Ich habe die Sysinternals-Lizenzbedingungen gelesen und nehme sie an.“; „Herunterladen“ erst mit Häkchen aktiv → Job-Fortschritt → Ergebnis.
- Eingerichtet: „Neu herunterladen …“ (gleicher Ablauf), „Lizenztext“ (Dialog mit dem Text aus `GET /api/sysinternals/eula`, `white-space: pre-wrap`), „Entfernen …“ (`.btn.danger`, rot). Hinweis: „Die Ergebnisse erscheinen nach dem nächsten Scan unter Sicherheit.“
- Befunde der drei neuen Prüfungen mit Status `SKIP` bekommen den Link „Sysinternals einrichten →“ (`#/werkzeuge`).
- Neuer Scan: Häkchen „Sysinternals-Prüfungen überspringen“ (`skipSysinternals`).
- **Design v3:** keine neue Akzent-Stelle, keine orange Schrift; Primärknöpfe türkis, Entfernen rot. Kein `innerHTML` mit Daten.

## 16. Ergänzungen v2.3.1 (Vertrag für alle Teilaufgaben)

Prüfhilfe für unsignierte Systemdateien, Akzeptieren in der GUI, breites Layout, Kontrast der Tabellen. Tester-Feedback (26.10.2026).

**Grundsatz:** Der Browser schickt **nie** Muster, Prüfungsnamen-Wildcards oder freie Pfade, die der Server ungeprüft übernimmt. Der Server baut jede Regel und jeden Scan-Pfad aus einem gespeicherten Bericht (`reports\`, nur Admins) und prüft ihn selbst. Jedes Schreiben der Akzeptanzliste und jeder Defender-Einzelscan läuft erst nach der Windows-Bestätigung im Admin-Prozess.

### 16.1 Akzeptanzliste (`gui\lib\Akzeptanz.ps1`, neu)

Datei bleibt `<DataRoot>\accepted.psd1` (Format wie `accepted.example.psd1`). Neue optionale Felder je Regel: `Id` (8 Hex-Zeichen, von der GUI vergeben), `Datei` (voller Pfad) und `Sha256` (64 Hex klein) für Datei-Regeln, `Erstellt` (`yyyy-MM-ddTHH:mm:ss`).

| Funktion | Rückgabe |
|---|---|
| `Read-MorpheusAkzeptanz -Datei` | Array `{ id, check, match, reason, until, datei, sha256, erstellt, quelle:'gui'\|'hand', abgelaufen:[bool] }`; fehlende Datei → `@()`; unlesbar → throw. `id` = `Id` oder, bei Regeln ohne `Id`, `'h' + ` erste 11 Hex des SHA256 über `check\|match\|reason\|until\|datei\|sha256` |
| `ConvertTo-MorpheusAkzeptanzPsd1 -Regeln` | psd1-Text: Kopfkommentar (Hinweis „wird von Morpheus geschrieben; Handänderungen bleiben als Regeln erhalten, Kommentare nicht“), `@{ Accepted = @( … ) }`, jedes Feld als `'…'` mit verdoppeltem `'`. Wirft bei Steuerzeichen (U+0000–U+001F, U+007F) in einem Wert |
| `Add-MorpheusAkzeptanz -Datei -Regel <hashtable>` | prüft (unten), vergibt `Id` und `Erstellt`, schreibt atomar (vorher Kopie nach `accepted.psd1.bak`), gibt die neue Regel zurück |
| `Remove-MorpheusAkzeptanz -Datei -Id` | entfernt genau eine Regel (unbekannte Id → throw), schreibt atomar mit `.bak`, gibt die entfernte Regel zurück |
| `Add-MorpheusAkzeptanzHistorie -Datei <state\akzeptanz-historie.json> -Art 'akzeptiert'\|'zurueckgenommen' -Regel -Benutzer` | hängt `{ zeit, art, regel, benutzer }` an (höchstens 1000 Einträge, älteste fallen weg), atomar |
| `Find-MorpheusAkzeptanzDatei -Regeln -Pfad -Sha256 [-Heute]` | passende, nicht abgelaufene Datei-Regel (Pfad ohne Groß-/Kleinschreibung, Hash gleich) oder `$null`. **Rein** |

**Prüfregeln in `Add`:** `Check` 1–200 Zeichen; `Reason` 3–300 Zeichen; `Until` leer oder `^\d{4}-\d{2}-\d{2}$`, gültiges Datum, ≥ heute, ≤ heute + 5 Jahre; `Match` ≤ 2000 Zeichen und als Regex gültig; `Datei` nur zusammen mit `Sha256` (`^[0-9a-f]{64}$`), Pfad `^[A-Za-z]:\\`, ≤ 260 Zeichen; in keinem Feld Steuerzeichen. Höchstens 500 Regeln.

### 16.2 Scan (`pc-check.ps1`)

- Die allgemeine Akzeptanz-Schleife überspringt Regeln mit `Datei` (die gelten nur für Datei-Zeilen).
- **Sigcheck:** Für jede unsignierte Datei SHA256 berechnen (`Get-FileHash -Algorithm SHA256`, Fehler → leer). Tabelle `Unsignierte Systemdateien (Sigcheck)` bekommt die Spalten `Sha256` und `Akzeptiert` (Begründung der passenden Regel bzw. `''`). Bewertet werden nur nicht akzeptierte Zeilen: Bleiben welche, `WARN` mit diesen (Wert endet auf `; k akzeptiert`, wenn k > 0). Sind alle akzeptiert, wird der Befund `ACK` (`OriginalStatus = 'WARN'`, `Note` = „n Dateien akzeptiert (je SHA256)“). Ändert sich eine Datei, passt der Hash nicht mehr und sie zählt wieder.
- `pc-check.hilfe.psd1`, Abschnitt `Tipps`, Eintrag `'Systemdateien: Signaturen (Sigcheck)'`: Schritte (Herkunft klären: Firma, Datum, `pnputil /enum-drivers`; Signatur von Hand: Eigenschaften > Digitale Signaturen; Hash selbst bei VirusTotal nachschlagen, Morpheus sendet nichts; alten Treiber über Geräte-Manager bzw. `pnputil /delete-driver` entfernen, nur wenn das Gerät nicht mehr genutzt wird; in Morpheus je Datei „Mit Defender prüfen“ und „Akzeptieren“), `Befehl = 'pnputil /enum-drivers'`, `NurAnleitung = $true`, Nutzen/Aufwand/Risiko mittel/gering/gering.
- `$ScriptVersion = '2.3.1'`.

### 16.3 Defender-Einzelscan (#44)

- `Defender.ps1`: Impl-Eintrag `Datei = { param($Pfad) Start-MpScan -ScanType CustomScan -ScanPath $Pfad -ErrorAction Stop }`. `Invoke-MorpheusDefenderAktion -Art 'datei' -Pfad <string>`; `Pfad` Pflicht bei `datei`, sonst verboten; Ergebnis wie bisher plus `pfad`. Funde nur ab Start, nur anzeigen.
- Server-Hilfsfunktion `Resolve-GuiSigcheckDatei -Bericht <name> -Pfad <string>` → `{ pfad, sha256 }` oder `Stop-GuiRequest 400/404/409`: Berichtsname wie bisher geprüft; Bericht-JSON laden; Zeile in `Data.'Unsignierte Systemdateien (Sigcheck)'` mit `Pfad -ieq`; Pfad per `GetFullPath` unter `%SystemRoot%\System32\` (Präfix, ohne Groß-/Kleinschreibung), keine `..`, Datei existiert, kein Reparse Point; `Sha256` der Zeile `^[0-9a-f]{64}$`; aktueller SHA256 gleich (sonst 409 „Die Datei hat sich seit dem Scan geändert. Bitte neu scannen.“).

### 16.4 API

| Methode und Pfad | Antwort / Zweck |
|---|---|
| `GET /api/akzeptanz` | `{ regeln:[…Read-MorpheusAkzeptanz…], datei, bearbeitbar:[bool] }` |
| `POST /api/akzeptanz` | Body `{ art:'befund', bericht:'pc-check_….json', check, begruendung, bis? }` oder `{ art:'datei', bericht, pfad, begruendung, bis? }` → 403 im Nur-Lesen-Modus → **befund:** Befund mit `Check -ceq check` im Bericht, Status (bzw. `OriginalStatus`) ∈ CRIT/WARN/TIPP/INFO, nicht `Systemdateien: Signaturen (Sigcheck)` (dort je Datei); Regel `Check = [WildcardPattern]::Escape(check)`, `Match = '^' + [regex]::Escape(Value) + '$'`. **datei:** `Resolve-GuiSigcheckDatei`; Regel `Check = 'Systemdateien: Signaturen (Sigcheck)'`, `Datei`, `Sha256`. → Windows-Bestätigung (Text nennt Prüfung bzw. Datei, Begründung, Ablauf; „Hast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'.“) → `Add` + Historie → `{ regel, regeln }`. Fehler der Prüfregeln → 400 mit Text |
| `POST /api/akzeptanz/<id>/entfernen` | `<id>` `^h?[0-9a-f]{8,11}$`; 403 Nur-Lesen; Windows-Bestätigung; `Remove` + Historie → `{ regeln }` |
| `POST /api/defender/datei` | Body `{ bericht, pfad }` → `Resolve-GuiSigcheckDatei` → 409 bei laufender Defender-Aufgabe/Countdown → Windows-Bestätigung (Text nennt die Datei) → Job `defender` mit `Art 'datei'` → `{ jobId }` |

`Start-GuiJob`: Job `defender` bekommt für `datei` den Pfad als weiteres Argument (Job-Script `param($Root, $DefenderPath, $Art, $Pfad)`).

### 16.5 Oberfläche (#44, #45)

- **Tabelle `Unsignierte Systemdateien (Sigcheck)`** (überall, wo „Daten ansehen“ sie zeigt): je Zeile „Mit Defender prüfen“ (Job-Dialog wie Defender, Ergebnis: Funde oder „Keine Funde“), „Akzeptieren …“, Link „VirusTotal ↗“ (`https://www.virustotal.com/gui/file/<sha256>`, `target=_blank`, `rel=noopener noreferrer`, `title`: „Öffnet deinen Browser; dabei geht nur der Hash an VirusTotal.“), „Hash kopieren“. Zeilen mit `Akzeptiert` zeigen einen Chip „akzeptiert“ (Text = Begründung im `title`). Nur für den angezeigten Bericht; im Nur-Lesen-Modus gesperrt.
- **Akzeptieren-Dialog:** Begründung (Pflicht, 3–300 Zeichen), „Gilt bis“ (optional, `input type=date`), Erklärung: Befund → „Gilt, solange der Befund genau so lautet. Ändert er sich, kommt die Warnung zurück.“; Datei → „Gilt nur für genau diese Datei (SHA256 …). Ändert sie sich, kommt die Warnung zurück.“ Danach Hinweis „Wirkt ab dem nächsten Scan“ mit Knopf „Neuer Scan“.
- **Befundkarten** mit Status CRIT/WARN/TIPP/INFO (außer der Sigcheck-Prüfung) bekommen einen kleinen Knopf „Akzeptieren …“ neben „erledigt/später“.
- **Einstellungen > Akzeptanzliste:** Tabelle aller Regeln (Prüfung, Datei bzw. Muster, Begründung, gilt bis, Quelle, abgelaufen) mit „Zurücknehmen …“ je Regel. Regeln von Hand (`quelle = 'hand'`) lassen sich ebenso zurücknehmen.

### 16.6 Layout und Tabellen (#46, #47)

- **Breite:** Bis 1920 px Fensterbreite bleibt alles wie heute. Darüber wächst die Mittelspalte bis ca. 1800 px; die rechte Leiste ist `clamp(280px, 16vw, 400px)`; Kartenraster (Tipps, Übersicht, Werkzeuge) bekommen ab ca. 2200 px eine Spalte mehr. Tabellen nutzen die volle Breite der Mittelspalte.
- **Neuer Scan:** „Scan starten“ ist `.btn.brand` (oranger Rahmen und Glow wie „Neuer Scan“ oben). Die Häkchen bleiben türkis. Die Ansicht trägt die Klasse `noaccent`, damit die Linie unter dem Seitentitel dort entfällt (höchstens 3 Akzent-Stellen).
- **Tabellen** (Rohdaten und „Daten ansehen“): `app.js` packt jede Datentabelle in `div.tbl-scroll` (eigener Scrollbereich) und gibt Zellen von Spalten, deren Name auf `Pfad|Path|Befehl|Ort|Datei|Sha256|Launch` passt, die Klasse `mono`. `app.css`: deckende dunkle Fläche (kein Backdrop durchscheinend), Zebra-Zeilen, Schrift mit Kontrast ≥ 4.5:1 zur Fläche, Kopf `position: sticky`, Hover-Zeile, `.mono` in Monospace mit Umbruch an beliebiger Stelle. Kein Orange in Tabellen.

## 17. Ergänzungen v2.3.3: sichere Pfade (Hotfix #60, verbindlich für alle Erweiterungen)

Admin-Code darf nichts über Suchpfade nachladen, die ein Benutzerprogramm beschreiben kann. Befunde und Nachweise: `docs/sicherheitspruefung-2.3.3.md`.

### 17.1 Regeln

1. **Modulpfad als erste Anweisung** in jedem Einstiegspunkt (`pc-check.ps1`, `pc-check-gui.ps1`, `pc-check-start.ps1`; bei `param()` direkt danach) und in jedem Scriptblock für `Start-Job` (alle Einträge in `$script:GuiJobScripts`, UPnP-Job im Scan):
   ```powershell
   $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
   ```
   Nur .NET, kein Cmdlet davor, damit vorher nichts automatisch geladen wird. Ein neuer Job bekommt dieselbe Zeile. Direkt danach setzen die Einstiegspunkte `PATH` auf Systemordner und leeren `COR_*`, `CORECLR_*`, `COMPlus_*`, `DOTNET_*` (Kindprozesse erben das). `pc-check.ps1` merkt sich vorher `$script:BenutzerPath` und `$script:BenutzerTemp` für Anzeige und Prüfungen.
2. **Programme nur mit vollem Pfad** aus `[Environment]::SystemDirectory` bzw. `[Environment]::GetFolderPath('Windows'|'ProgramFiles'|'ProgramFilesX86'|'CommonApplicationData')`, nie aus `$env:SystemRoot`, `$env:ProgramFiles` usw. und nie über `PATH`/`Get-Command`. Systemlaufwerk: `[IO.Path]::GetPathRoot([Environment]::SystemDirectory)`. Reine Anzeige- und Größenpfade im Scan dürfen Umgebungsvariablen nutzen (verfälschen höchstens das Ergebnis). `Invoke-Native` im Scan wirft bei Namen ohne Pfad. Katalog-Aktionen schreiben `& (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') …`, weil sie in sich geschlossen sein müssen.
3. **winget** nur über `Get-MorpheusWinget`, sonst SKIP. Kein Rückgriff auf PATH.
4. **TEMP** des Admin-Prozesses liegt im gesicherten Datenordner (`Set-MorpheusTempPfad`, je Prozess `temp\<PID>`). Gelingt das in der GUI nicht, startet sie im Nur-Lesen-Modus. Neue Funktionen, die temporäre Dateien schreiben und danach lesen oder ausführen, nutzen `[IO.Path]::GetTempPath()` bzw. `$env:TEMP` und erben das. **Messen** (Prüfungen, Anzeige, Auflösen fremder Pfade) nie über `$env:TEMP`, `$env:TMP`, `$env:PATH` oder `$env:PSModulePath`: Die sind gehärtet und werden an Jobs vererbt. Stattdessen `Get-MorpheusBenutzerTemp`, `Get-MorpheusBenutzerPath` und `Expand-MorpheusUmgebung` statt `[Environment]::ExpandEnvironmentVariables`.
5. **Kein Standardbrowser und keine Dateizuordnung** aus dem Admin-Prozess (`Start-Process <url|datei>`). Dateien für den Benutzer öffnet der Explorer mit vollem Pfad (startet ohne Adminrechte).
6. Jeder Start von `powershell.exe` mit vollem Pfad und `-NoProfile`.

### 17.2 `gui\lib\Systempfade.ps1` (neu)

Beim Dot-Sourcen wird nichts ausgeführt. Austauschbare Teile für Tests in `$script:MorpheusPfadImpl` (`Pakete`, `Signatur`, `Wurzel`, `Datei`, `ProgrammeOrdner`).

| Funktion | Zweck |
|---|---|
| `Get-MorpheusModulPfad` | der gesicherte Modulpfad (System32 zuerst, dann Program Files) |
| `Get-MorpheusSystemProgramm <Name>` | voller Pfad eines Programms in System32 (auch mit Unterordner, z. B. `WindowsPowerShell\v1.0\powershell.exe`); kein `..`, nur `.exe`/`.com`; fehlt es, Ausnahme statt PATH |
| `Test-MorpheusMicrosoftSignatur -Pfad` | `$null`, wenn gültig von Microsoft signiert und die Kette an Root CA 2010/2011 endet, sonst Grund |
| `Get-MorpheusWinget` | `{ Pfad, Version, Grund }`: winget.exe aus `Microsoft.DesktopAppInstaller` (PublisherId `8wekyb3d8bbwe`) direkt unter `<Program Files>\WindowsApps`, keine Verknüpfung, Microsoft-Signatur; höchste Version gewinnt; sonst `Pfad = $null` mit Grund |
| `Set-MorpheusTempPfad -DataRoot` | `TEMP`/`TMP` nach `<DataRoot>\temp\<PID>`, nur wenn `DataRoot`, `temp` und der Unterordner laut `Test-MorpheusSecurePath` gesichert sind; gibt den Pfad oder `$null` zurück |
| `Get-MorpheusBenutzerTemp` | echter Temp-Ordner des Benutzers aus `HKCU\Environment` (ohne Expansion gelesen, `%USERPROFILE%` ersetzt), Rückfall `<LocalAppData>\Temp`; nur zum Messen |
| `Get-MorpheusBenutzerPath` | `Path` aus HKLM- und HKCU-Umgebung, expandiert; nur zum Nachsehen, nie zum Starten |
| `Expand-MorpheusUmgebung <Text>` | wie `ExpandEnvironmentVariables`, aber `%TEMP%`/`%TMP%` = Benutzer-Temp |

Aufrufer: `pc-check-gui.ps1` (lädt die Datei, setzt TEMP nach `Initialize-MorpheusDataDir`), `pc-check.ps1` (winget-Prüfung, Update-Dialog, TEMP). Der **Inhalt** von `temp\` zählt nicht zur Rechteprüfung des Datenordners (`Test-MorpheusSecurePath -Recurse -Ausnahmen 'temp'` in `Initialize-MorpheusDataDir` und `Install-Morpheus`): winget gibt seinen Ordner `TEMP\WinGet` dem Benutzer frei. Morpheus vertraut in `temp\` nichts über einen Lauf hinaus. `Initialize-MorpheusDataDir` entfernt bei jedem Start vor der rekursiven Rechteprüfung alles in `temp\` außer den Ordnern laufender Prozesse (`MorpheusLeereTemp`; nur im gesicherten Ordner, Verknüpfungen werden einzeln entfernt, nie betreten).

### 17.3 Test

`tests\Systempfade.Tests.ps1` prüft die Regeln aus 17.1 statisch über den Syntaxbaum aller Admin-Dateien und die Funktionen aus 17.2 mit Attrappen. Ein neuer Aufruf eines externen Programms ohne vollen Pfad oder ein neuer Job ohne Modulpfad lässt den Test scheitern.
