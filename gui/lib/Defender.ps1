#Requires -Version 5.1
<#
.SYNOPSIS
    Defender-Werkzeuge für die Morpheus-GUI (v2.2, #34): Stand, Signaturen aktualisieren, Schnellscan, Offline-Scan.

.DESCRIPTION
    Wird per Dot-Source geladen (Server und Job `defender`). Definiert die Funktionen aus
    docs/gui-architektur.md, Abschnitt 14.4. Regeln:
    - Keine Einstellungsänderung an Defender und kein Journal-Eintrag. Funde werden nur angezeigt;
      Quarantäne und Entfernen bleiben in Windows-Sicherheit.
    - Die Bestätigung vor Aktion und Offline-Scan (Windows-Dialog im Admin-Prozess) macht der Server,
      nicht diese Datei.
    - Fortschritt nur über Write-Information, einzige Pipeline-Ausgabe ist das Ergebnis.
    - Alle Defender-Cmdlets laufen nur über die Scriptblöcke in $script:MorpheusDefenderImpl
      (Tests ersetzen die Einträge nach dem Dot-Source; ist die Variable schon gesetzt, bleibt sie).
    - Beim Dot-Sourcen wird nichts ausgeführt außer der Initialisierung der Impl-Hashtable.
#>

# Standard-Implementierungen (Tests ersetzen die Einträge)
if (-not $script:MorpheusDefenderImpl) {
    $script:MorpheusDefenderImpl = @{
        Status      = { Get-MpComputerStatus -ErrorAction Stop }
        Signaturen  = { Update-MpSignature -ErrorAction Stop }
        Schnellscan = { Start-MpScan -ScanType QuickScan -ErrorAction Stop }
        # Liefert Objekte { zeit; name; aktion; erfolg; dateien } ab $Seit ([datetime]::MinValue = alle)
        Funde       = {
            param($Seit)
            $namen = @{}
            foreach ($t in @(Get-MpThreat -ErrorAction SilentlyContinue)) { $namen[[string]$t.ThreatID] = $t.ThreatName }
            $aktionen = @{ 1 = 'Bereinigt'; 2 = 'In Quarantäne'; 3 = 'Entfernt'; 4 = 'Blockiert'; 6 = 'Zugelassen'; 8 = 'Benutzerentscheidung'; 9 = 'Keine Aktion'; 10 = 'Blockiert' }
            foreach ($d in @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $Seit })) {
                $aid = [int]$d.CleaningActionID
                $akt = if ($aktionen.ContainsKey($aid)) { $aktionen[$aid] } else { 'Unbekannt' }
                [pscustomobject]@{
                    zeit    = $d.InitialDetectionTime
                    name    = $namen[[string]$d.ThreatID]
                    aktion  = $akt
                    erfolg  = $d.ActionSuccess
                    dateien = @($d.Resources)
                }
            }
        }
        Datei       = { param($Pfad) Start-MpScan -ScanType CustomScan -ScanPath $Pfad -ErrorAction Stop }
        Offline     = { Start-MpWDOScan -ErrorAction Stop }
    }
}

#region Hilfsfunktionen (privat)

function MorpheusDefenderLog {
    param([string]$Text)
    Write-Information -MessageData ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text) -InformationAction Continue
}

function MorpheusDefenderIso {
    param($Date)
    if ($null -eq $Date) { return $null }
    try {
        $d = [datetime]$Date
        if ($d.Year -lt 1990) { return $null }
        $d.ToString('s', [Globalization.CultureInfo]::InvariantCulture)
    } catch { $null }
}

function MorpheusDefenderText {
    param($Wert)
    if ($null -eq $Wert) { return $null }
    [string]$Wert
}

#endregion

function Get-MorpheusDefenderStand {
    [CmdletBinding()]
    param()
    try {
        $s = @(& $script:MorpheusDefenderImpl.Status) | Select-Object -First 1
        if ($null -eq $s) { throw 'Defender lieferte keinen Status.' }
        [ordered]@{
            modus                = MorpheusDefenderText $s.AMRunningMode
            signaturen           = MorpheusDefenderIso $s.AntivirusSignatureLastUpdated
            signaturVersion      = MorpheusDefenderText $s.AntivirusSignatureVersion
            signaturAlterTage    = $s.AntivirusSignatureAge
            schnellscan          = MorpheusDefenderIso $s.QuickScanEndTime
            schnellscanAlterTage = $s.QuickScanAge
            echtzeit             = $s.RealTimeProtectionEnabled
        }
    } catch {
        [ordered]@{ fehler = [string]$_.Exception.Message }
    }
}

function Invoke-MorpheusDefenderAktion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Art,

        [string]$Pfad
    )
    if (($Art -cne 'signaturen') -and ($Art -cne 'schnellscan') -and ($Art -cne 'datei')) {
        throw "Unbekannte Defender-Aufgabe '$Art'. Erlaubt sind 'signaturen', 'schnellscan' und 'datei'."
    }
    if ($Art -ceq 'datei') {
        if ([string]::IsNullOrWhiteSpace($Pfad)) { throw 'Für die Dateiprüfung fehlt der Pfad.' }
        if (-not (Test-Path -LiteralPath $Pfad -PathType Leaf)) { throw ('Die Datei wurde nicht gefunden: ' + $Pfad) }
    } elseif ($PSBoundParameters.ContainsKey('Pfad') -and (-not [string]::IsNullOrEmpty($Pfad))) {
        throw "Ein Pfad ist nur bei der Aufgabe 'datei' erlaubt."
    }

    $start = Get-Date
    $vorher = Get-MorpheusDefenderStand
    if ($vorher.Contains('fehler')) {
        MorpheusDefenderLog ('Stand vorher nicht lesbar: ' + $vorher['fehler'])
    } else {
        MorpheusDefenderLog ('Stand vorher: Signaturen {0} (Version {1}), letzter Schnellscan {2}.' -f $vorher['signaturen'], $vorher['signaturVersion'], $vorher['schnellscan'])
    }

    try {
        if ($Art -ceq 'signaturen') {
            MorpheusDefenderLog 'Signaturen werden aktualisiert …'
            $null = & $script:MorpheusDefenderImpl.Signaturen
        } elseif ($Art -ceq 'datei') {
            MorpheusDefenderLog ('Defender prüft die Datei ' + $Pfad + ' …')
            $null = & $script:MorpheusDefenderImpl.Datei $Pfad
        } else {
            MorpheusDefenderLog 'Schnellscan läuft, das dauert meist einige Minuten …'
            $null = & $script:MorpheusDefenderImpl.Schnellscan
        }
    } catch {
        $was = if ($Art -ceq 'signaturen') { 'Die Signaturen konnten nicht aktualisiert werden' } elseif ($Art -ceq 'datei') { 'Die Dateiprüfung konnte nicht abgeschlossen werden' } else { 'Der Schnellscan konnte nicht abgeschlossen werden' }
        throw ('{0}: {1}' -f $was, $_.Exception.Message)
    }

    $nachher = Get-MorpheusDefenderStand
    if ($nachher.Contains('fehler')) {
        MorpheusDefenderLog ('Stand nachher nicht lesbar: ' + $nachher['fehler'])
    } else {
        MorpheusDefenderLog ('Stand nachher: Signaturen {0} (Version {1}), letzter Schnellscan {2}.' -f $nachher['signaturen'], $nachher['signaturVersion'], $nachher['schnellscan'])
    }

    $funde = @()
    try {
        # Bei der Dateiprüfung: alle Erkennungen (ohne Zeitgrenze), gefiltert auf diese Datei;
        # ältere als der Start der Prüfung werden mit frueher = $true gekennzeichnet.
        $seit = $start
        if ($Art -ceq 'datei') { $seit = [datetime]::MinValue }
        foreach ($f in @(& $script:MorpheusDefenderImpl.Funde $seit)) {
            if ($null -eq $f) { continue }
            $alle = @(@($f.dateien) | Where-Object { ($null -ne $_) -and ("$_" -ne '') })
            $frueher = $false
            if ($Art -ceq 'datei') {
                $alle = @($alle | Where-Object { "$_".IndexOf($Pfad, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
                if (@($alle).Count -eq 0) { continue }
                $frueher = $true
                try { if (([datetime]$f.zeit) -ge $start.AddSeconds(-2)) { $frueher = $false } } catch { }
            }
            $dateien = $alle | Select-Object -First 3
            $funde += [pscustomobject][ordered]@{
                zeit    = MorpheusDefenderIso $f.zeit
                name    = MorpheusDefenderText $f.name
                aktion  = MorpheusDefenderText $f.aktion
                erfolg  = $f.erfolg
                dateien = (@($dateien) -join '; ')
                frueher = $frueher
            }
        }
    } catch {
        MorpheusDefenderLog ('Funde konnten nicht gelesen werden: ' + $_.Exception.Message)
    }
    MorpheusDefenderLog ('Funde: {0}.' -f @($funde).Count)

    $dauer = [int][math]::Round(((Get-Date) - $start).TotalSeconds)
    if (@($funde).Count -gt 0) {
        $meldung = 'Morpheus zeigt Funde nur an. Quarantäne und Entfernen: Windows-Sicherheit > Viren- & Bedrohungsschutz > Schutzverlauf.'
    } elseif ($Art -ceq 'datei') {
        $meldung = 'Defender hat ' + (Split-Path -Leaf $Pfad) + ' geprüft und nichts gefunden. Steht die Datei unter einer Defender-Ausnahme, wird sie nicht geprüft.'
    } elseif ($Art -ceq 'signaturen') {
        $vv = if ($vorher.Contains('signaturVersion')) { $vorher['signaturVersion'] } else { $null }
        $nv = if ($nachher.Contains('signaturVersion')) { $nachher['signaturVersion'] } else { $null }
        if (($null -ne $vv) -and ($vv -eq $nv)) { $meldung = 'Die Signaturen waren schon aktuell.' }
        elseif ($null -ne $nv) { $meldung = 'Die Signaturen wurden aktualisiert (Version ' + $nv + ').' }
        else { $meldung = 'Die Aktualisierung ist abgeschlossen.' }
    } else {
        $meldung = 'Der Schnellscan ist abgeschlossen, es wurden keine Funde gemeldet.'
    }

    $pfadAus = $null; if ($Art -ceq 'datei') { $pfadAus = $Pfad }
    [pscustomobject][ordered]@{
        art      = $Art
        pfad     = $pfadAus
        vorher   = $vorher
        nachher  = $nachher
        funde    = @($funde)
        dauerSek = $dauer
        meldung  = $meldung
    }
}

function Start-MorpheusDefenderOffline {
    [CmdletBinding()]
    param()
    MorpheusDefenderLog 'Microsoft Defender Offline-Scan wird gestartet, der PC startet neu …'
    $null = & $script:MorpheusDefenderImpl.Offline
}
