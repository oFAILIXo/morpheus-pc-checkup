#Requires -Version 5.1
# Morpheus - Wartung & Reparatur: reine Auswertung (Vertrag: docs\gui-architektur.md 18.7).
# Nur Funktionen. Kein Dateizugriff, keine Prozesse, kein Add-Type; wird von Wartung.ps1 per Dot-Source geladen.
#
# Erkennung: DEUTSCH und ENGLISCH, tolerant gegenueber Gross-/Kleinschreibung, mehrfachen Leerzeichen und
# Zeilenumbruechen mitten im Satz (SFC bricht lange Saetze um): der Text wird vor der Erkennung zu einer Zeile geglaettet.
# Umlaute werden mit '.{1,2}' abgefangen (falsche Codepage), die Erkennung haengt an Schluesselwoertern.
#
# WELCHE DEUTSCHEN FORMULIERUNGEN GESCHAETZT SIND (am echten PC zu pruefen; englisch aus der Microsoft-Dokumentation bzw. Praxis):
#   - SFC deutsch: 'keine Integritaetsverletzungen', 'beschaedigte Dateien gefunden und erfolgreich repariert', 'konnte jedoch einige ... nicht reparieren',
#     'Systemreparatur aus ... Neustart', 'konnte den angeforderten Vorgang nicht ausfuehren', Fortschritt 'Ueberpruefung 45 % abgeschlossen'
#   - DISM deutsch: 'keine Komponentenspeicherbeschaedigung erkannt', 'Der Komponentenspeicher kann repariert werden', 'kann nicht repariert werden',
#     'Der Wiederherstellungsvorgang wurde erfolgreich abgeschlossen', 'Der Vorgang wurde erfolgreich beendet', Fehlerzeile 'Fehler: 0x800f081f'
#   - AnalyzeComponentStore deutsch: 'Tatsaechliche Groesse des Komponentenspeichers', 'Anzahl der freigebbaren Pakete', 'Bereinigung des Komponentenspeichers empfohlen : Ja'
#   - chkdsk deutsch: 'keine Probleme festgestellt', 'Es sind keine weiteren Aktionen erforderlich', 'Probleme gefunden'; Fortschritt 'Prozent'
#   - ipconfig deutsch: 'Der DNS-Aufloesungscache wurde erfolgreich geleert'
#   - w32tm deutsch: 'Der Befehl wurde erfolgreich ausgefuehrt', 'keine Zeitdaten', 'Der Dienst wurde nicht gestartet'
#   - defrag deutsch: 'Der Vorgang wurde erfolgreich abgeschlossen', 'wird nicht unterstuetzt'
#   - powercfg deutsch: 'Analyse abgeschlossen', '<n> Fehler / <n> Warnungen', 'Es sind keine Batterien/Akkus vorhanden', 'Modern Standby ... nicht unterstuetzt'
#   - Alle deutschen Fortschrittsmuster ausser DISM (dort Zeichenkette sprachunabhaengig) sind geschaetzt.
# Nicht erkannte Ausgabe faellt auf den Exit-Code zurueck (0 = unbekannt, sonst fehler).

function Format-MorpheusWartungZeile {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    $t = [regex]::Replace($Text, '[\u0000-\u0008\u000A-\u001F\u007F\u0085\u061C\u200B-\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069\uFEFF]', '')
    $t = $t.Trim()
    if ($t.Length -gt 500) { $t = $t.Substring(0, 499) + [string][char]0x2026 }
    return $t
}

function Get-MorpheusWartungFortschritt {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Zeile)
    if ([string]::IsNullOrWhiteSpace($Zeile)) { return $null }
    $z = $Zeile.Trim()
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $wert = {
        param([string]$s)
        $d = 0.0
        if ([double]::TryParse($s.Replace(',', '.'), [Globalization.NumberStyles]::Float, $ci, [ref]$d) -and $d -ge 0 -and $d -le 100) { return [double]$d }
        return $null
    }
    # DISM: [====       25.0%                ] bzw. [=====100.0%=====]
    $m = [regex]::Match($z, '\[[= ]*(\d{1,3}(?:[.,]\d+)?)\s*%[= ]*\]')
    if ($m.Success) { return (& $wert $m.Groups[1].Value) }
    # chkdsk (heutiges Format): 'Progress: 123 of 421312 done; Stage:  29%; Total:  14%; ETA:   0:00:20' -> Gesamtwert, sonst Phase
    # (deutsch GESCHAETZT: 'Fortschritt: 123 von 421312 erledigt; Phase:  29 %; Gesamt:  14 %; ETA: ...')
    if ($z -match '(?i)^(?:progress|fortschritt)\s*:') {
        $m = [regex]::Match($z, '(?i)\b(?:total|gesamt)\s*:\s*(\d{1,3}(?:[.,]\d+)?)\s*%')
        if ($m.Success) { return (& $wert $m.Groups[1].Value) }
        $m = [regex]::Match($z, '(?i)\b(?:stage|phase)\s*:\s*(\d{1,3}(?:[.,]\d+)?)\s*%')
        if ($m.Success) { return (& $wert $m.Groups[1].Value) }
    }
    # chkdsk: '30 percent complete' / '30 Prozent'
    $m = [regex]::Match($z, '(?i)\b(\d{1,3}(?:[.,]\d+)?)\s*(?:percent|prozent)\b')
    if ($m.Success) { return (& $wert $m.Groups[1].Value) }
    # SFC, defrag: '45% complete', '45 % abgeschlossen'
    $m = [regex]::Match($z, '(?i)\b(\d{1,3}(?:[.,]\d+)?)\s*%\s*(?:complete|abgeschlossen|fertig|done|erledigt)')
    if ($m.Success) { return (& $wert $m.Groups[1].Value) }
    # allgemein: kurze Fortschrittszeile 'Text NN %'
    if ($z.Length -le 80) {
        $m = [regex]::Match($z, '^[^\d%]{0,60}?(\d{1,3}(?:[.,]\d+)?)\s*%[^\d%]{0,25}$')
        if ($m.Success) { return (& $wert $m.Groups[1].Value) }
    }
    return $null
}

# ---------------------------------------------------------------- interne Helfer

function ConvertTo-WaFlach {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text.Replace([string][char]0, '')
    $t = [regex]::Replace($t, '\[[= ]*\d{1,3}(?:[.,]\d+)?\s*%[= ]*\]', ' ')
    return ([regex]::Replace($t, '\s+', ' ')).Trim()
}

function New-WaErgebnis {
    param([string]$Ergebnis, [string]$Text, [string]$Empfehlung = $null, [string[]]$Details = @())
    $d = New-Object 'System.Collections.Generic.List[string]'
    foreach ($x in @($Details)) { if (-not [string]::IsNullOrWhiteSpace($x)) { $d.Add([string]$x) } }
    [pscustomobject]@{ ergebnis = $Ergebnis; text = $Text; empfehlung = $(if ([string]::IsNullOrWhiteSpace($Empfehlung)) { $null } else { $Empfehlung }); details = [string[]]$d.ToArray() }
}

function Get-WaRueckfall {
    param($ExitCode, [string]$Zusatz = '')
    if ($null -eq $ExitCode -or "$ExitCode" -eq '') {
        return (New-WaErgebnis 'unbekannt' 'Die Ausgabe ist nicht eindeutig.' $null @())
    }
    $c = [int64]$ExitCode
    if ($c -eq 0) { return (New-WaErgebnis 'unbekannt' 'Beendet mit Code 0, die Ausgabe ist nicht eindeutig.' $null @()) }
    $u = [uint32]($c -band 0xFFFFFFFFL)
    return (New-WaErgebnis 'fehler' ('Beendet mit Fehlercode {0} (0x{1:x}).' -f $c, $u) $null @())
}

function Get-WaDismFehler {
    param([string]$Flach)
    $m = [regex]::Match($Flach, '(?i)\b(?:error|fehler)\s*:\s*(0x[0-9a-f]{1,8}|\d{1,10})\b')
    $quelle = [regex]::IsMatch($Flach, '(?i)source files could not be found|quelldateien.{0,60}nicht gefunden')
    if (-not $m.Success -and -not $quelle) { return $null }
    $code = ''
    if ($m.Success) {
        $code = $m.Groups[1].Value.ToLowerInvariant()
        if ($code -match '^0x') { try { $n = [Convert]::ToInt64($code.Substring(2), 16); if ($n -lt 100000) { $code = [string]$n } } catch { } }
    }
    if ($quelle -and ($code -eq '' -or $code -eq '0x800f081f')) { $code = '0x800f081f' }
    switch ($code) {
        '0x800f081f' { return (New-WaErgebnis 'fehler' 'DISM hat die Quelldateien für die Reparatur nicht gefunden (0x800f081f).' 'Internetverbindung und Windows Update prüfen und die Reparatur erneut starten.' @('Fehlercode: 0x800f081f')) }
        '0x800f0906' { return (New-WaErgebnis 'fehler' 'DISM konnte die Quelldateien für die Reparatur nicht herunterladen (0x800f0906).' 'Internetverbindung und Windows Update prüfen und die Reparatur erneut starten.' @('Fehlercode: 0x800f0906')) }
        '0x800f0907' { return (New-WaErgebnis 'fehler' 'Eine Gruppenrichtlinie verhindert, dass DISM Reparaturdateien von Windows Update lädt (0x800f0907).' 'Die Richtlinie für alternative Reparaturquellen prüfen oder eine Windows-Installationsquelle angeben.' @('Fehlercode: 0x800f0907')) }
        '87' { return (New-WaErgebnis 'fehler' 'DISM hat den Befehl nicht angenommen (Fehler 87: ungültiger Parameter).' 'Dieser Fehler sollte in Morpheus nicht vorkommen; bitte melden.' @('Fehlercode: 87')) }
        '5' { return (New-WaErgebnis 'fehler' 'DISM hatte keinen Zugriff (Fehler 5: Zugriff verweigert).' 'Morpheus mit Administratorrechten starten und die Windows-Bestätigung zulassen.' @('Fehlercode: 5')) }
        '740' { return (New-WaErgebnis 'fehler' 'DISM braucht Administratorrechte (Fehler 740).' 'Die Windows-Bestätigung zulassen.' @('Fehlercode: 740')) }
        default { return (New-WaErgebnis 'fehler' ('DISM ist mit Fehler {0} abgebrochen.' -f $code) 'Details stehen in C:\Windows\Logs\DISM\dism.log.' @(('Fehlercode: {0}' -f $code))) }
    }
}

function Get-WaWert {
    # Wert hinter 'Bezeichnung : Wert' aus dem zeilenweisen Text
    param([string]$Text, [string]$Muster)
    $m = [regex]::Match($Text, '(?im)^[ \t]*(?:' + $Muster + ')[ \t]*:[ \t]*([^\r\n]*)$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

# ---------------------------------------------------------------- Zusammenfassung

$script:WaWerkzeuge = @('dism.checkhealth', 'dism.scanhealth', 'dism.restorehealth', 'sfc.scannow', 'dism.analyze', 'dism.cleanup',
    'chkdsk.scan', 'dns.flush', 'trim', 'zeit.resync', 'powercfg.energy', 'powercfg.akku', 'powercfg.schlaf', 'winget.upgrade')

function Get-MorpheusWartungZusammenfassung {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Werkzeug,
        [AllowNull()][AllowEmptyString()][string]$Text = '',
        [AllowNull()][object]$ExitCode = $null
    )
    if ($script:WaWerkzeuge -cnotcontains $Werkzeug) { throw "Unbekanntes Wartungswerkzeug: $Werkzeug" }
    if ($null -eq $Text) { $Text = '' }
    $zeilen = (($Text.Replace([string][char]0, '')) -replace "`r`n", "`n") -replace "`r", "`n"
    $f = ConvertTo-WaFlach $Text
    $rueck = { Get-WaRueckfall -ExitCode $ExitCode }

    switch -CaseSensitive ($Werkzeug) {
        'winget.upgrade' {
            if ($null -eq $ExitCode) { return (& $rueck) }
            if ([int64]$ExitCode -eq 0) { return (New-WaErgebnis 'ok' 'Das Programm-Update wurde abgeschlossen.') }
            return (& $rueck)
        }

        { $_ -ceq 'dism.checkhealth' -or $_ -ceq 'dism.scanhealth' } {
            $fe = Get-WaDismFehler $f
            if ($fe) { return $fe }
            if ($f -match '(?i)cannot be repaired|not repairable|nicht repariert werden|nicht reparierbar|nicht repariert') {
                return (New-WaErgebnis 'fehler' 'Der Komponentenspeicher ist beschädigt und lässt sich nicht reparieren.' 'Als Nächstes hilft meist ein Reparatur-Upgrade von Windows (Installation über die bestehende); vorher die Daten sichern.')
            }
            if ($f -match '(?i)\brepairable\b|kann repariert werden|l.{1,2}sst sich reparieren|ist reparierbar') {
                return (New-WaErgebnis 'reparierbar' 'Der Komponentenspeicher ist beschädigt, lässt sich aber reparieren.' 'DISM: Komponentenspeicher reparieren (RestoreHealth) starten, danach SFC ausführen.')
            }
            if ($f -match '(?i)no component store corruption|keine komponentenspeicherbesch.{1,2}digung|keine besch.{1,2}digung(en)? (im|am|des) komponentenspeicher') {
                return (New-WaErgebnis 'ok' 'Keine Beschädigung im Komponentenspeicher gefunden.')
            }
            return (& $rueck)
        }

        'dism.restorehealth' {
            $fe = Get-WaDismFehler $f
            if ($fe) { return $fe }
            if ($f -match '(?i)cannot be repaired|not repairable|nicht repariert werden|nicht reparierbar') {
                return (New-WaErgebnis 'fehler' 'Der Komponentenspeicher lässt sich nicht reparieren.' 'Als Nächstes hilft meist ein Reparatur-Upgrade von Windows (Installation über die bestehende); vorher die Daten sichern.')
            }
            if ($f -match '(?i)corruption was repaired|besch.{1,2}digung wurde repariert|wurde repariert') {
                return (New-WaErgebnis 'repariert' 'DISM hat den Komponentenspeicher repariert.' 'Jetzt SFC ausführen (sfc /scannow), damit Systemdateien aus dem reparierten Speicher ersetzt werden.')
            }
            if ($f -match '(?i)restore operation completed successfully|wiederherstellungsvorgang wurde erfolgreich|operation completed successfully|vorgang wurde erfolgreich') {
                return (New-WaErgebnis 'ok' 'Die Reparatur des Komponentenspeichers wurde ohne Fehler abgeschlossen.' 'Jetzt SFC ausführen (sfc /scannow).')
            }
            return (& $rueck)
        }

        'sfc.scannow' {
            $sfcRepariert = ($f -match '(?i)successfully repaired|erfolgreich repariert')
            if ((-not $sfcRepariert) -and ($f -match '(?i)system repair pending|repair pending|systemreparatur aus|reparatur steht aus|neustart.{0,40}(erfordert|erforderlich)')) {
                return (New-WaErgebnis 'problem' 'Eine Systemreparatur steht aus und braucht einen Neustart.' 'Windows neu starten und SFC danach noch einmal ausführen.')
            }
            if ($f -match '(?i)could not perform the requested operation|konnte den angeforderten vorgang nicht ausf.{1,2}hren|could not start the repair service|reparaturdienst nicht starten') {
                return (New-WaErgebnis 'fehler' 'SFC konnte nicht arbeiten.' 'Windows neu starten und es noch einmal versuchen; sonst zuerst DISM: Komponentenspeicher reparieren ausführen.' @('Hinweis: SFC im abgesicherten Modus kann helfen.'))
            }
            if ($f -match '(?i)unable to fix some|konnte (jedoch )?(einige|manche)|nicht reparieren|nicht repariert werden|unable to repair') {
                return (New-WaErgebnis 'problem' 'SFC hat beschädigte Systemdateien gefunden und konnte einige nicht reparieren.' 'DISM: Komponentenspeicher reparieren (RestoreHealth) ausführen, dann SFC erneut starten.' @('Einzelheiten stehen in C:\Windows\Logs\CBS\CBS.log'))
            }
            if ($f -match '(?i)successfully repaired|erfolgreich repariert') {
                return (New-WaErgebnis 'repariert' 'SFC hat beschädigte Systemdateien gefunden und repariert.' 'Windows neu starten. Zur Kontrolle SFC danach noch einmal ausführen.' @('Einzelheiten stehen in C:\Windows\Logs\CBS\CBS.log'))
            }
            if ($f -match '(?i)did not find any integrity violations|keine integrit.{1,2}tsverletzung') {
                return (New-WaErgebnis 'ok' 'SFC hat keine Beschädigung an Systemdateien gefunden.')
            }
            return (& $rueck)
        }

        'dism.analyze' {
            $fe = Get-WaDismFehler $f
            if ($fe) { return $fe }
            $det = New-Object 'System.Collections.Generic.List[string]'
            $groesse = Get-WaWert $zeilen '(?:actual size of component store|tats.{1,2}chliche gr.{1,3}e des komponentenspeichers)'
            if ($groesse) { $det.Add('Größe des Komponentenspeichers: ' + ($groesse -replace '(\d)\.(\d)', '$1,$2')) }
            $pakete = Get-WaWert $zeilen '(?:number of [a-z ]*packages|anzahl der [a-zäöüß ]*pakete)'
            if ($pakete) { $det.Add('Freigebbare Pakete: ' + $pakete) }
            $letzte = Get-WaWert $zeilen '(?:date of last cleanup|datum der letzten bereinigung)'
            if ($letzte) { $det.Add('Letzte Bereinigung: ' + $letzte) }
            $empf = Get-WaWert $zeilen '(?:component store cleanup recommended|bereinigung(?: des komponentenspeichers)? empfohlen)'
            if ($empf) {
                $ja = ($empf -match '(?i)^(yes|ja)\b')
                $det.Add('Bereinigung empfohlen: ' + $(if ($ja) { 'ja' } else { 'nein' }))
                if ($ja) {
                    return (New-WaErgebnis 'reparierbar' 'Der Komponentenspeicher kann bereinigt werden; Windows empfiehlt es.' 'DISM: Komponentenspeicher bereinigen (StartComponentCleanup) starten. Das gibt Platz frei.' $det.ToArray())
                }
                return (New-WaErgebnis 'ok' 'Der Komponentenspeicher ist in Ordnung; eine Bereinigung ist nicht nötig.' $null $det.ToArray())
            }
            return (& $rueck)
        }

        'dism.cleanup' {
            $fe = Get-WaDismFehler $f
            if ($fe) { return $fe }
            if ($f -match '(?i)completed successfully|erfolgreich (beendet|abgeschlossen)') {
                return (New-WaErgebnis 'ok' 'Der Komponentenspeicher wurde bereinigt.')
            }
            return (& $rueck)
        }

        'chkdsk.scan' {
            if ($f -match '(?i)access denied|zugriff (wurde )?verweigert|cannot open volume|datentr.{1,2}ger.{0,30}nicht (ge.{1,2}ffnet|zugreifen)') {
                return (New-WaErgebnis 'fehler' 'chkdsk konnte das Laufwerk nicht prüfen (Zugriff verweigert).' 'Morpheus mit Administratorrechten starten und die Windows-Bestätigung zulassen.')
            }
            if ($f -match '(?i)found no problems|no problems|keine probleme festgestellt|keine probleme gefunden|keine weiteren aktionen erforderlich|no further action is required') {
                return (New-WaErgebnis 'ok' 'Die Prüfung hat keine Probleme am Dateisystem gefunden.')
            }
            if ($f -match '(?i)found problems|errors found|problems? (were )?found|probleme (gefunden|festgestellt)|fehler gefunden|corruption|besch.{1,2}digung') {
                return (New-WaErgebnis 'problem' 'Die Prüfung hat Probleme am Dateisystem gefunden.' 'Zuerst eine Datensicherung anlegen. Eine Reparatur beim nächsten Start (chkdsk /f) macht Morpheus nicht selbst; sie ist nur nach der Sicherung sinnvoll.')
            }
            return (& $rueck)
        }

        'dns.flush' {
            if ($f -match '(?i)could not flush|konnte nicht (geleert|gel.{1,2}scht)|fehler beim leeren|failed') {
                return (New-WaErgebnis 'fehler' 'Der DNS-Cache konnte nicht geleert werden.' 'Als Administrator erneut versuchen; ist der DNS-Clientdienst gestartet?')
            }
            if ($f -match '(?i)successfully flushed|erfolgreich geleert') {
                return (New-WaErgebnis 'ok' 'Der DNS-Zwischenspeicher wurde geleert.')
            }
            return (& $rueck)
        }

        'trim' {
            if ($f -match '(?i)not supported|nicht unterst.{1,2}tzt|wird nicht unterst') {
                return (New-WaErgebnis 'problem' 'Dieses Laufwerk unterstützt TRIM nicht (oder ist keine SSD).' 'Nur SSDs mit TRIM-Unterstützung brauchen das; hier ist nichts zu tun.')
            }
            if ($f -match '(?i)completed successfully|erfolgreich (abgeschlossen|beendet)') {
                return (New-WaErgebnis 'ok' 'TRIM wurde für das Laufwerk ausgeführt.')
            }
            return (& $rueck)
        }

        'zeit.resync' {
            if ($f -match '(?i)no time data was available|keine zeitdaten') {
                return (New-WaErgebnis 'problem' 'Die Zeit wurde nicht synchronisiert: Es waren keine Zeitdaten verfügbar.' 'Internetverbindung prüfen. Der Windows-Zeitdienst braucht einen erreichbaren Zeitserver (Einstellungen, Zeit und Sprache, Datum und Uhrzeit).')
            }
            if ($f -match '(?i)service has not been started|dienst wurde nicht gestartet|0x80070426') {
                return (New-WaErgebnis 'problem' 'Der Windows-Zeitdienst läuft nicht.' 'Den Dienst Windows-Zeit starten (Dienste, Windows-Zeit) und es noch einmal versuchen.')
            }
            if ($f -match '(?i)command completed successfully|befehl wurde erfolgreich ausgef.{1,2}hrt') {
                return (New-WaErgebnis 'ok' 'Die Uhrzeit wurde neu mit dem Zeitserver abgeglichen.')
            }
            return (& $rueck)
        }

        'powercfg.energy' {
            $det = New-Object 'System.Collections.Generic.List[string]'
            $fehler = $null; $warn = $null
            $m = [regex]::Match($f, '(?i)\b(\d+)\s+(?:errors?|fehler)\b'); if ($m.Success) { $fehler = [int]$m.Groups[1].Value }
            $m = [regex]::Match($f, '(?i)\b(\d+)\s+(?:warnings?|warnungen)\b'); if ($m.Success) { $warn = [int]$m.Groups[1].Value }
            if ($null -ne $fehler -or $null -ne $warn) {
                $det.Add(('Fehler: {0}, Warnungen: {1}' -f $(if ($null -ne $fehler) { $fehler } else { 0 }), $(if ($null -ne $warn) { $warn } else { 0 })))
            }
            if ($f -match '(?i)analysis complete|analyse abgeschlossen|energy-report|energiebericht') {
                if ($det.Count -gt 0) {
                    return (New-WaErgebnis 'ok' ('Der Energiebericht ist fertig: {0}.' -f ($det[0] -replace '^Fehler: (\d+), Warnungen: (\d+)$', '$1 Fehler, $2 Warnungen')) 'Den Bericht öffnen und die Fehler und Warnungen durchsehen.' $det.ToArray())
                }
                return (New-WaErgebnis 'ok' 'Der Energiebericht ist fertig.' 'Den Bericht öffnen und durchsehen.' $det.ToArray())
            }
            return (& $rueck)
        }

        'powercfg.akku' {
            if ($f -match '(?i)no batter|keine (batterie|akku)|keinen akku|keine batterien|batterie.{0,30}nicht vorhanden|akku.{0,30}nicht vorhanden') {
                return (New-WaErgebnis 'problem' 'Dieser PC hat keinen Akku, deshalb gibt es keinen Akkubericht.' 'Der Akkubericht ist nur für Notebooks und Tablets gedacht.')
            }
            if ($f -match '(?i)report saved|gespeichert') {
                return (New-WaErgebnis 'ok' 'Der Akkubericht ist fertig.' 'Den Bericht öffnen: Entwurfskapazität und Volladekapazität zeigen den Verschleiß.')
            }
            return (& $rueck)
        }

        'powercfg.schlaf' {
            if ($f -match '(?i)modern standby|connected standby|s0 low power|s0-leerlauf|does not support|not supported|nicht unterst.{1,2}tzt|keine unterst.{1,2}tzung') {
                return (New-WaErgebnis 'problem' 'Dieser PC unterstützt Modern Standby nicht, deshalb gibt es keine Schlafstudie.' 'Die Schlafstudie gibt es nur für PCs mit Modern Standby (vor allem neuere Notebooks).')
            }
            if ($f -match '(?i)report saved|gespeichert') {
                return (New-WaErgebnis 'ok' 'Die Schlafstudie ist fertig.' 'Den Bericht öffnen: Er zeigt, was im Ruhezustand Strom verbraucht hat.')
            }
            return (& $rueck)
        }
    }
}

# ---------------------------------------------------------------- Kurzfassung

function Get-MorpheusWartungKurzfassung {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Zusammenfassung,
        [AllowNull()][object]$ExitCode = $null,
        [AllowNull()][object]$DauerSek = $null
    )
    $text = ''
    if ($Zusammenfassung -and $Zusammenfassung.text) { $text = ([string]$Zusammenfassung.text).Trim() }
    if ($text -ne '' -and $text -notmatch '[.!?]$') { $text += '.' }
    $teile = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $DauerSek -and "$DauerSek" -ne '') {
        $s = [int64][math]::Round([double]$DauerSek)
        if ($s -lt 0) { $s = 0 }
        if ($s -lt 60) { $teile.Add(('Dauer {0} s' -f $s)) }
        elseif ($s -lt 3600) { $teile.Add(('Dauer {0} min {1} s' -f [int64][math]::Floor($s / 60), ($s % 60))) }
        else { $teile.Add(('Dauer {0} h {1} min' -f [int64][math]::Floor($s / 3600), [int64][math]::Floor(($s % 3600) / 60))) }
    }
    if ($null -ne $ExitCode -and "$ExitCode" -ne '') { $teile.Add(('Exit-Code {0}' -f [int64]$ExitCode)) }
    $r = $text
    if ($teile.Count -gt 0) { $r = (($r + ' ' + ($teile -join ', ') + '.')).Trim() }
    $det = @()
    if ($Zusammenfassung -and $Zusammenfassung.details) { $det = @($Zusammenfassung.details | Where-Object { $_ } | Select-Object -First 2) }
    if ($det.Count -gt 0) { $r = $r + ' ' + (($det | ForEach-Object { [string]$_ }) -join '; ') }
    return (Format-MorpheusWartungZeile -Text $r)
}
