#Requires -Version 5.1
<#
.SYNOPSIS
    Audio-Analyse nur lesen und auswerten (Idee 5.7, Stufe 2, Karte #85).

.DESCRIPTION
    Wird per Dot-Source geladen (pc-check.ps1, Kategorie 'Audio'). Zwei getrennte Teile:
    - Lesen: Get-MorpheusAudioGeraete (CIM), Get-MorpheusAudioDienste (CIM), Get-MorpheusAudioStandard (WinRT MediaDevice,
      ohne Typkompilierung), Get-MorpheusAudioEndpunkt (Registry MMDevices), Get-MorpheusAudioDucking (Registry HKCU).
      Alles nur lesend, ohne Adminrechte, keine Parameter vom Browser oder Benutzer.
    - Auswerten (rein, ohne Hardware testbar): Get-MorpheusAudio*Befund geben @{ Status; Value; Recommendation } zurück.
    Bewusst nicht gebaut (keine Testdaten bzw. nicht aussagekräftig): Ereignisprotokoll, Bluetooth-HFP, DPC-Zähler.
#>

. (Join-Path $PSScriptRoot 'Sprache.ps1')

$script:MorpheusAudioMmDevices = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
$script:MorpheusAudioDienste = @('Audiosrv', 'AudioEndpointBuilder')

#region Lesen

function Get-MorpheusAudioGeraete {
    # Audio-Geräte im Geräte-Manager (Klassen MEDIA und AudioEndpoint)
    @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='MEDIA' OR PNPClass='AudioEndpoint'" -ErrorAction Stop |
            ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Code = [int]$_.ConfigManagerErrorCode; Present = ($_.Present -ne $false) } })
}

function Get-MorpheusAudioDienste {
    @(Get-CimInstance Win32_Service -Filter "Name='Audiosrv' OR Name='AudioEndpointBuilder'" -ErrorAction Stop |
            ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; State = [string]$_.State; StartMode = [string]$_.StartMode } })
}

function Get-MorpheusAudioWinRtId {
    # Endpunkt-ID des Standardgeräts über WinRT (Windows.Media.Devices.MediaDevice), ohne Typkompilierung. Wirft bei Fehlern.
    param([ValidateSet('Render', 'Capture')][string]$Fluss, [ValidateSet('Default', 'Communications')][string]$Rolle)
    $md = [Windows.Media.Devices.MediaDevice, Windows.Media.Devices, ContentType = WindowsRuntime]
    $rl = [Windows.Media.Devices.AudioDeviceRole, Windows.Media.Devices, ContentType = WindowsRuntime]
    $r = [Enum]::Parse($rl, $Rolle)
    if ($Fluss -eq 'Render') { $md::GetDefaultAudioRenderId($r) } else { $md::GetDefaultAudioCaptureId($r) }
}

function Get-MorpheusAudioGuid {
    # Endpunkt-GUID aus der WinRT-ID ({0.0.0.00000000}.{guid} = Wiedergabe, {0.0.1.00000000}.{guid} = Aufnahme)
    param([string]$Id)
    if ($Id -match '\{0\.0\.[01]\.00000000\}\.(\{[0-9a-fA-F-]+\})') { $Matches[1] }
}

function Get-MorpheusAudioEndpunkt {
    # Eigenschaften eines Endpunkts aus MMDevices; $null, wenn der Schlüssel fehlt
    param([ValidateSet('Render', 'Capture')][string]$Fluss, [string]$Guid)
    $basis = "$script:MorpheusAudioMmDevices\$Fluss\$Guid"
    if (-not (Test-Path -LiteralPath $basis)) { return $null }
    $get = { param($p, $n) try { , (Get-ItemProperty -LiteralPath $p -Name $n -ErrorAction Stop).$n } catch { $null } }
    $state = & $get $basis 'DeviceState'
    $prop = "$basis\Properties"
    $name = & $get $prop '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
    $adapter = & $get $prop '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
    $ff = & $get $prop '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},0'
    # USB: irgendeine Zeichenkette der Eigenschaften enthält eine USB-Geräte-ID
    $usb = $false
    try {
        $item = Get-ItemProperty -LiteralPath $prop -ErrorAction Stop
        foreach ($p in $item.PSObject.Properties) {
            if ($p.Value -is [string] -and $p.Value -match '(?i)\bUSB[\\#]VID_|(^|[\\#.{}])USB[\\#]') { $usb = $true; break }
        }
    }
    catch { }
    [pscustomobject]@{
        Fluss      = $Fluss
        Guid       = $Guid
        Name       = [string]$name
        Adapter    = [string]$adapter
        FormFactor = $(if ($null -ne $ff) { [int]$ff } else { -1 })
        State      = $(if ($null -ne $state) { [int]$state -band 0xF } else { 0 })
        Usb        = $usb
    }
}

function Get-MorpheusAudioEndpunkte {
    # Alle Endpunkte (Wiedergabe und Aufnahme); Geister (nicht vorhanden) bleiben mit State 4 in der Liste und werden später ignoriert
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($fluss in 'Render', 'Capture') {
        $pfad = "$script:MorpheusAudioMmDevices\$fluss"
        $kinder = @(Get-ChildItem -LiteralPath $pfad -ErrorAction SilentlyContinue)
        foreach ($k in $kinder) {
            $e = Get-MorpheusAudioEndpunkt -Fluss $fluss -Guid $k.PSChildName
            if ($e) { $out.Add($e) }
        }
    }
    $out.ToArray()
}

function Get-MorpheusAudioStandard {
    # Standardgeräte (Wiedergabe/Kommunikation, Aufnahme/Kommunikation). Gibt @{ Fehler; Eintraege } zurück; WinRT-Fehler brechen nichts ab.
    $eintraege = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($spec in @(@('Render', 'Default', 'Wiedergabe'), @('Render', 'Communications', 'WiedergabeKomm'), @('Capture', 'Default', 'Aufnahme'), @('Capture', 'Communications', 'AufnahmeKomm'))) {
            $id = Get-MorpheusAudioWinRtId -Fluss $spec[0] -Rolle $spec[1]
            $guid = Get-MorpheusAudioGuid ([string]$id)
            $ep = if ($guid) { Get-MorpheusAudioEndpunkt -Fluss $spec[0] -Guid $guid } else { $null }
            $eintraege.Add([pscustomobject]@{ Rolle = $spec[2]; Endpunkt = $ep })
        }
    }
    catch { return @{ Fehler = $_.Exception.Message; Eintraege = @() } }
    @{ Fehler = $null; Eintraege = $eintraege.ToArray() }
}

function Get-MorpheusAudioDucking {
    # $null, wenn der Wert fehlt (Windows-Standard: 80 % reduzieren)
    try { (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Multimedia\Audio' -Name 'UserDuckingPreference' -ErrorAction Stop).UserDuckingPreference } catch { $null }
}

#endregion

#region Auswerten

function Get-MorpheusAudioTreiberBefund {
    param([object[]]$Geraete)
    $schlecht = @($Geraete | Where-Object { $_ -and $_.Present -and ([int]$_.Code -ne 0) })
    if ($schlecht.Count -eq 0) { return @{ Status = 'OK'; Value = (T 'scan.audio.treiberOk' @($Geraete | Where-Object { $_ -and $_.Present }).Count); Recommendation = '' } }
    $liste = ($schlecht | ForEach-Object { '{0} (Code {1})' -f $_.Name, $_.Code }) -join '; '
    @{ Status = 'WARN'; Value = (T 'scan.audio.treiberFehler' $liste); Recommendation = (T 'scan.audio.treiberEmpf') }
}

function Get-MorpheusAudioDienstBefund {
    param([object[]]$Dienste)
    $probleme = New-Object System.Collections.Generic.List[string]
    foreach ($n in $script:MorpheusAudioDienste) {
        $d = @($Dienste | Where-Object { $_ -and $_.Name -eq $n }) | Select-Object -First 1
        if (-not $d) { $probleme.Add((T 'scan.audio.dienstFehlt' $n)); continue }
        $teile = @()
        if ($d.State -ne 'Running') { $teile += (T 'scan.audio.dienstNichtLaufend' $d.State) }
        if ($d.StartMode -ne 'Auto') { $teile += (T 'scan.audio.dienstStarttyp' $d.StartMode) }
        if ($teile.Count) { $probleme.Add("$n ($($teile -join ', '))") }
    }
    if ($probleme.Count -eq 0) { return @{ Status = 'OK'; Value = (T 'scan.audio.dienstOk'); Recommendation = '' } }
    @{ Status = 'WARN'; Value = (T 'scan.audio.dienstProblem' ($probleme -join '; ')); Recommendation = (T 'scan.audio.dienstEmpf') }
}

function Get-MorpheusAudioStandardBefund {
    # Roh: Ergebnis von Get-MorpheusAudioStandard. Gibt @{ Status; Value; Recommendation; Zeilen } zurück (Status immer INFO).
    param($Roh)
    $link = T 'scan.audio.einstellungen'
    if ($null -eq $Roh -or $Roh.Fehler) {
        return @{ Status = 'INFO'; Value = (T 'scan.audio.standardUnbekannt'); Recommendation = $link; Zeilen = @() }
    }
    $zeilen = New-Object System.Collections.Generic.List[object]
    $teile = New-Object System.Collections.Generic.List[string]
    $hinweise = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($Roh.Eintraege)) {
        $ep = $e.Endpunkt
        $rolle = T ('scan.audio.rolle.' + $e.Rolle)
        if (-not $ep -or $ep.State -eq 4) {
            # Kein Standardgerät oder Geister-Endpunkt: nie melden
            $zeilen.Add([pscustomobject][ordered]@{ Rolle = $rolle; Geraet = (T 'scan.audio.keines'); Adapter = ''; Zustand = '' })
            continue
        }
        $zustand = switch ($ep.State) { 1 { T 'scan.audio.zustandAktiv' } 2 { T 'scan.audio.zustandDeaktiviert' } 8 { T 'scan.audio.zustandAusgesteckt' } default { T 'scan.audio.zustandUnbekannt' } }
        $name = $(if ($ep.Name) { $ep.Name } else { $ep.Guid })
        $zeilen.Add([pscustomobject][ordered]@{ Rolle = $rolle; Geraet = $name; Adapter = $ep.Adapter; Zustand = $zustand })
        $teile.Add("${rolle}: $name")
        if ($e.Rolle -eq 'Wiedergabe') {
            if ($ep.State -ne 1) { $hinweise.Add((T 'scan.audio.hinweisNichtAktiv' $name $zustand)) }
            if ($ep.FormFactor -eq 9) { $hinweise.Add((T 'scan.audio.hinweisHdmi' $name)) }
        }
    }
    $value = if ($teile.Count) { $teile -join '; ' } else { T 'scan.audio.keineStandardgeraete' }
    $rec = (@($hinweise) + @((T 'scan.audio.hinweisText'), $link)) -join ' '
    @{ Status = 'INFO'; Value = $value; Recommendation = $rec; Zeilen = $zeilen.ToArray() }
}

function Get-MorpheusAudioUsbBefund {
    # Endpunkte: Get-MorpheusAudioEndpunkte. EnergieHolen: Skriptblock, der @{ AC; DC } liefert (powercfg), nur aufgerufen bei aktivem USB-Audio.
    param([object[]]$Endpunkte, [scriptblock]$EnergieHolen)
    $usb = @($Endpunkte | Where-Object { $_ -and $_.Usb -and $_.State -eq 1 })
    if ($usb.Count -eq 0) { return @{ Status = 'OK'; Value = (T 'scan.audio.usbKeins'); Recommendation = '' } }
    $e = if ($EnergieHolen) { & $EnergieHolen } else { $null }
    if (-not $e) { return @{ Status = 'INFO'; Value = (T 'scan.audio.usbUnbekannt'); Recommendation = '' } }
    $an = @()
    if ([int]$e.AC -eq 1) { $an += (T 'scan.audio.netz') }
    if ([int]$e.DC -eq 1) { $an += (T 'scan.audio.akku') }
    if ($an.Count -eq 0) { return @{ Status = 'OK'; Value = (T 'scan.audio.usbAus'); Recommendation = '' } }
    $namen = ($usb | ForEach-Object { $(if ($_.Adapter) { $_.Adapter } else { $_.Name }) } | Select-Object -Unique) -join ', '
    @{ Status = 'INFO'; Value = (T 'scan.audio.usbAn' ($an -join ' / ') $namen); Recommendation = (T 'scan.audio.usbEmpf') }
}

function Get-MorpheusAudioDuckingBefund {
    param($Wert)
    $schluessel = if ($null -eq $Wert) { 'standard' } else { switch ([int]$Wert) { 0 { 'stumm' } 1 { 'standard' } 2 { 'halb' } 3 { 'nichts' } default { 'unbekannt' } } }
    @{ Status = 'INFO'; Value = (T ('scan.audio.ducking.' + $schluessel)); Recommendation = (T 'scan.audio.duckingEmpf') }
}

#endregion
