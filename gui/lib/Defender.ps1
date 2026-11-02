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

. (Join-Path $PSScriptRoot 'Sprache.ps1')

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
            $aktionen = @{ 1 = (T 'server.defender.aktionBereinigt'); 2 = (T 'server.defender.aktionQuarantaene'); 3 = (T 'server.defender.aktionEntfernt'); 4 = (T 'server.defender.aktionBlockiert'); 6 = (T 'server.defender.aktionZugelassen'); 8 = (T 'server.defender.aktionBenutzer'); 9 = (T 'server.defender.aktionKeine'); 10 = (T 'server.defender.aktionBlockiert') }
            foreach ($d in @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $Seit })) {
                $aid = [int]$d.CleaningActionID
                $akt = if ($aktionen.ContainsKey($aid)) { $aktionen[$aid] } else { (T 'server.defender.aktionUnbekannt') }
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
        if ($null -eq $s) { throw (T 'server.defender.keinStatus') }
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
        throw (T 'server.defender.unbekannteAufgabe' $Art)
    }
    if ($Art -ceq 'datei') {
        if ([string]::IsNullOrWhiteSpace($Pfad)) { throw (T 'server.defender.pfadFehlt') }
        if (-not (Test-Path -LiteralPath $Pfad -PathType Leaf)) { throw (T 'server.defender.dateiNichtGefunden' $Pfad) }
    } elseif ($PSBoundParameters.ContainsKey('Pfad') -and (-not [string]::IsNullOrEmpty($Pfad))) {
        throw (T 'server.defender.pfadNurDatei')
    }

    $start = Get-Date
    $vorher = Get-MorpheusDefenderStand
    if ($vorher.Contains('fehler')) {
        MorpheusDefenderLog (T 'server.defender.standVorherNicht' $vorher['fehler'])
    } else {
        MorpheusDefenderLog (T 'server.defender.standVorher' $vorher['signaturen'] $vorher['signaturVersion'] $vorher['schnellscan'])
    }

    try {
        if ($Art -ceq 'signaturen') {
            MorpheusDefenderLog (T 'server.defender.signaturenWerden')
            $null = & $script:MorpheusDefenderImpl.Signaturen
        } elseif ($Art -ceq 'datei') {
            MorpheusDefenderLog (T 'server.defender.pruefeDatei' $Pfad)
            $null = & $script:MorpheusDefenderImpl.Datei $Pfad
        } else {
            MorpheusDefenderLog (T 'server.defender.schnellscanLaeuft')
            $null = & $script:MorpheusDefenderImpl.Schnellscan
        }
    } catch {
        $was = if ($Art -ceq 'signaturen') { (T 'server.defender.signaturenFehler') } elseif ($Art -ceq 'datei') { (T 'server.defender.dateiFehler') } else { (T 'server.defender.schnellscanFehler') }
        throw ('{0}: {1}' -f $was, $_.Exception.Message)
    }

    $nachher = Get-MorpheusDefenderStand
    if ($nachher.Contains('fehler')) {
        MorpheusDefenderLog (T 'server.defender.standNachherNicht' $nachher['fehler'])
    } else {
        MorpheusDefenderLog (T 'server.defender.standNachher' $nachher['signaturen'] $nachher['signaturVersion'] $nachher['schnellscan'])
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
        MorpheusDefenderLog (T 'server.defender.fundeNichtLesbar' $_.Exception.Message)
    }
    MorpheusDefenderLog (T 'server.defender.funde' (@($funde).Count))

    $dauer = [int][math]::Round(((Get-Date) - $start).TotalSeconds)
    if (@($funde).Count -gt 0) {
        $meldung = (T 'server.defender.meldungFunde')
    } elseif ($Art -ceq 'datei') {
        $meldung = (T 'server.defender.meldungDatei' (Split-Path -Leaf $Pfad))
    } elseif ($Art -ceq 'signaturen') {
        $vv = if ($vorher.Contains('signaturVersion')) { $vorher['signaturVersion'] } else { $null }
        $nv = if ($nachher.Contains('signaturVersion')) { $nachher['signaturVersion'] } else { $null }
        if (($null -ne $vv) -and ($vv -eq $nv)) { $meldung = (T 'server.defender.signaturenAktuell') }
        elseif ($null -ne $nv) { $meldung = (T 'server.defender.signaturenAktualisiert' $nv) }
        else { $meldung = (T 'server.defender.aktualisierungFertig') }
    } else {
        $meldung = (T 'server.defender.schnellscanFertig')
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
    MorpheusDefenderLog (T 'server.defender.offlineStart')
    $null = & $script:MorpheusDefenderImpl.Offline
}
