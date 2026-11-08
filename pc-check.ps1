#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only Sicherheits- und Performance-Prüfung für Windows 11.

.DESCRIPTION
    Liest Einstellungen, Zustände und Ereignisprotokolle aus und schreibt einen Bericht
    als Markdown und JSON nach reports\. Die Prüfung ändert keine Einstellungen.

    Erst nach dem fertigen Bericht fragt das Script, ob verfügbare Programm-Updates (winget)
    installiert werden sollen. Ohne ausdrückliche Auswahl passiert nichts; abschaltbar mit -NoUpdatePrompt.

    Nebenwirkungen, die nichts am System verstellen:
    - secedit exportiert die lokale Sicherheitsrichtlinie in eine Temp-Datei, die sofort gelöscht wird.
    - Add-Type kompiliert eine kleine Hilfsklasse zum Auslesen der Bildwiederholraten.
    - Die Windows-Update-Suche, winget und die UPnP-Abfrage gehen ins Netz bzw. zum Router
      (abschaltbar mit -SkipUpdateSearch / -SkipWinget).

    - Die Speicherauswertung zählt alle Dateien der festen Laufwerke auf (nur Größen, keine Inhalte;
      abschaltbar mit -SkipSpeicher).

    - Die Sysinternals-Prüfungen (Autoruns, Sigcheck) laufen nur, wenn die Werkzeuge in Morpheus unter
      Werkzeuge eingerichtet und geprüft sind; sonst werden sie übersprungen. Es gehen keine Daten ins Netz
      (kein VirusTotal). Abschaltbar mit -SkipSysinternals.

    Für den vollen Umfang in einer Admin-PowerShell starten.

.PARAMETER OutputDir
    Zielordner für den Bericht. Standard: reports\ neben dem Script.

.PARAMETER EventDays
    Wie viele Tage die Ereignisprotokolle zurück ausgewertet werden. Standard: 14.

.PARAMETER AcceptedFile
    Liste bewusst gewollter Befunde. Standard: accepted.psd1 neben dem Script.
    Passende Warnungen erscheinen im Bericht als "Akzeptiert" statt als Handlungsbedarf.

.PARAMETER SkipSpeicher
    Größte Speicherverbraucher je Laufwerk nicht berechnen; spart je nach Laufwerken 1–3 Minuten.

.PARAMETER SkipSysinternals
    Autoruns- und Sigcheck-Prüfungen (Sysinternals) nicht ausführen; sie dauern je 1–3 Minuten.

.PARAMETER SpielOrdnerFile
    Selbst eingetragene Spiele-Ordner (GUI: Werkzeuge > Spiele-Ordner), nur gelesen.
    Standard: state\spielordner.json neben dem Berichtsordner (OutputDir).

.PARAMETER NoUpdatePrompt
    Keine Nachfrage nach Programm-Updates am Ende (rein lesender Lauf).

.PARAMETER CompareWith
    JSON-Bericht, mit dem verglichen wird. Standard: der jüngste vorhandene Bericht im Zielordner.

.PARAMETER NoOpen
    HTML-Bericht am Ende nicht automatisch im Browser öffnen.

.PARAMETER Profil
    Nutzungsprofil, nach dem Empfehlungen gewichtet werden: Gaming, Office oder Laptop.
    Standard Auto: Laptop, wenn ein Akku vorhanden ist; Gaming bei eigener Grafikkarte; sonst Office.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\pc-check.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$AcceptedFile,
    [ValidateRange(1, 90)][int]$EventDays = 14,
    [switch]$SkipUpdateSearch,
    [switch]$SkipWinget,
    [switch]$SkipSpeicher,
    [switch]$SkipSysinternals,
    [string]$SpielOrdnerFile,
    [switch]$NoUpdatePrompt,
    [string]$CompareWith,
    [switch]$NoOpen,
    [ValidateSet('Auto', 'Gaming', 'Office', 'Laptop')][string]$Profil = 'Auto',
    [ValidateSet('', 'de', 'en')][string]$Sprache = ''
)
# Sicherheit (2.3.3): Module nur aus System32 und Program Files laden, nie aus Benutzerordnern (gui\lib\Systempfade.ps1).
# Als erste Anweisung, damit vorher nichts automatisch geladen wird; Kindprozesse und Jobs erben den Wert.
$env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
# Für Anzeige und Prüfungen: PATH und Temp-Ordner des Benutzers, bevor sie unten bzw. in Set-MorpheusTempPfad ersetzt werden.
# Nur Rückfall: Läuft der Scan als Job der GUI, sind beide schon gehärtet geerbt; die echten Werte kommen unten aus der
# Registry (Get-MorpheusBenutzerTemp, Get-MorpheusBenutzerPath).
$script:BenutzerPath = $env:PATH
$script:BenutzerTemp = $env:TEMP
# Kindprozesse (Jobs, Scan, winget, Windows-Programme): PATH nur Systemordner, keine .NET-Profiler-Variablen aus der
# Benutzerumgebung (HKCU\Environment), über die sich eine DLL in jeden .NET-Prozess laden ließe (2.3.3, N6)
$env:PATH = [Environment]::SystemDirectory + ';' + [Environment]::GetFolderPath('Windows') + ';' + [Environment]::SystemDirectory + '\Wbem;' + [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0'
foreach ($morpheusVar in @([Environment]::GetEnvironmentVariables().Keys)) { if ([string]$morpheusVar -match '^(COR_|CORECLR_|COMPlus_|DOTNET_)') { [Environment]::SetEnvironmentVariable([string]$morpheusVar, $null) } }

$ScriptVersion = '2.7.0'
# Anzeigename (Dateien und Repos heißen weiter pc-check)
$ProductName = 'Morpheus'
$ProductTagline = 'PC Check-up'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Windows-Programme nur mit vollem Pfad aus System32 (über die Windows-API, nicht über PATH oder %SystemRoot%)
$script:Sys32 = [Environment]::SystemDirectory
if (-not $OutputDir) { $OutputDir = Join-Path $PSScriptRoot 'reports' }
if (-not $AcceptedFile) { $AcceptedFile = Join-Path $PSScriptRoot 'accepted.psd1' }
if (-not $SpielOrdnerFile) { $SpielOrdnerFile = Join-Path (Split-Path -Parent $OutputDir) 'state\spielordner.json' }
# Sprache (2.6, #66): -Sprache, sonst gespeicherte Wahl im Datenordner, sonst Windows-Sprache. Der Bericht entsteht in dieser Sprache.
. (Join-Path $PSScriptRoot 'gui\lib\Sprache.ps1')
if (-not $Sprache) { $Sprache = Get-MorpheusSprache -DataRoot (Split-Path -Parent $OutputDir) }
$env:MORPHEUS_SPRACHE = $Sprache
Import-MorpheusTexte -Sprache $Sprache
# Akzeptanzregeln und Tipps vergleichen den deutschen Befundtext (ValueDe), damit sie in beiden Sprachen greifen
if ($Sprache -ne 'de') { Start-MorpheusTextSpur }

$script:Findings = New-Object System.Collections.Generic.List[object]
$script:Tables = [ordered]@{}
$script:TableChecks = [ordered]@{}   # Tabellentitel -> Prüfung, aus der die Tabelle stammt (für Links in der GUI)
$script:Area = ''
$script:Category = ''
$script:CheckName = ''
$script:Since = (Get-Date).AddDays(-$EventDays)
$script:Speicher = $null
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:SigCache = @{}
$startedAt = Get-Date

#region Hilfsfunktionen

# Status: CRIT/WARN = Handlungsbedarf, TIPP = lohnende Optimierung (wird aus INFO abgeleitet, siehe Tipps in lang\<sprache>\hilfe.psd1),
# INFO = reine Information, ACK = akzeptiert, OK, SKIP = nicht geprüft.
# Area, Category und Check sind feste deutsche Kennungen (Akzeptanzliste, Katalog, Hilfe, Vergleich alter Berichte);
# angezeigt werden AreaName, CategoryName und CheckName in der Sprache des Scans (2.6, #66).
function Add-Finding {
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('OK', 'INFO', 'WARN', 'CRIT', 'SKIP')][string]$Status,
        [Parameter(Position = 1)][string]$Value = '',
        [Parameter(Position = 2)][string]$Recommendation = '',
        [string]$Check = $script:CheckName
    )
    $script:Findings.Add([pscustomobject][ordered]@{
            Area           = $script:Area
            Category       = $script:Category
            Check          = $Check
            Status         = $Status
            Value          = $Value
            ValueDe        = (Get-MorpheusDeutscherText $Value)
            Recommendation = $Recommendation
            OriginalStatus = ''
            Note           = ''
            Effort         = ''
            Benefit        = ''
            Risk           = ''
            Steps          = @()
            Command        = ''
            AreaName       = (Get-MorpheusAnzeige 'bereich' $script:Area)
            CategoryName   = (Get-MorpheusAnzeige 'kategorie' $script:Category)
            CheckName      = (Get-MorpheusAnzeige 'pruefung' $Check)
        })
}

function Add-Table {
    param([Parameter(Mandatory)][string]$Title, [object[]]$Rows)
    $script:Tables[$Title] = @($Rows | Where-Object { $null -ne $_ })
    if ($script:CheckName) { $script:TableChecks[$Title] = $script:CheckName }
}

function Start-Section {
    param([string]$Area, [string]$Category)
    $script:Area = $Area
    $script:Category = $Category
    Write-Host ("`n[" + (Get-MorpheusAnzeige 'bereich' $Area) + '] ' + (Get-MorpheusAnzeige 'kategorie' $Category)) -ForegroundColor Cyan
}

function Invoke-Check {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Script, [switch]$NeedsAdmin)
    $script:CheckName = $Name
    $null = Get-MorpheusDeutscherText ''
    if ($NeedsAdmin -and -not $script:IsAdmin) {
        Add-Finding SKIP (T 'scan.hilfe.nurAdmin')
        return
    }
    Write-Host ('  - ' + (Get-MorpheusAnzeige 'pruefung' $Name))
    try { & $Script }
    catch { Add-Finding SKIP (T 'scan.hilfe.fehler' $_.Exception.Message) }
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    # Das Komma verhindert, dass REG_BINARY/REG_MULTI_SZ in der Pipeline in Einzelwerte zerfallen.
    try { , (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

# Native Programme: stderr verwerfen, ohne dass $ErrorActionPreference = 'Stop' zuschlägt.
function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    # Nie über PATH auflösen (2.3.3): ein Programm gleichen Namens in einem Benutzerordner liefe sonst mit Adminrechten
    if ($File -notmatch '^[A-Za-z]:\\') { throw (T 'scan.hilfe.ohnePfad' $File) }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { , @(& $File @Arguments 2>$null | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $old }
}

function Get-RecentEvents {
    param([Parameter(Mandatory)][hashtable]$Filter, [int]$Max = 1000, [switch]$AllTime)
    $f = $Filter.Clone()
    if (-not $AllTime) { $f['StartTime'] = $script:Since }
    try { Get-WinEvent -FilterHashtable $f -MaxEvents $Max -ErrorAction Stop }
    catch {
        if ($_.FullyQualifiedErrorId -match '^NoMatching(Events|Logs|Providers)Found') { return }
        throw
    }
}

function Get-EventData {
    param($EventRecord)
    $h = @{}
    $xml = [xml]$EventRecord.ToXml()
    foreach ($d in @($xml.Event.EventData.Data)) {
        if ($d -and $d.Name) { $h[$d.Name] = $d.'#text' }
    }
    $h
}

function Format-Date {
    param($Date)
    if ($Date) { ([datetime]$Date).ToString('yyyy-MM-dd HH:mm') } else { '' }
}

function Format-Size {
    param($Bytes)
    if ($null -eq $Bytes) { return '' }
    $b = [double]$Bytes
    if ($b -ge 1TB) { '{0:N2} TB' -f ($b / 1TB) }
    elseif ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) }
    else { '{0:N0} KB' -f ($b / 1KB) }
}

function Get-FolderSize {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $m = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    [pscustomobject]@{ Bytes = [double]$m.Sum; Files = $m.Count }
}

# Ausführbare Datei aus einer Befehlszeile (Dienst, Autostart, Aufgabe) herauslösen.
function Get-ExePath {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    try {
        $c = Expand-MorpheusUmgebung $CommandLine.Trim()
        if ($c.StartsWith('"')) {
            $end = $c.IndexOf('"', 1)
            $p = if ($end -gt 1) { $c.Substring(1, $end - 1) } else { $c.Trim('"') }
        }
        elseif ($c -match '^(.+?\.(exe|com|sys|dll|bat|cmd|ps1|vbs|js|lnk))(\s|,|$)') { $p = $Matches[1] }
        else { $p = ($c -split '\s+')[0] }
        if ($p -match '^\\\?\?\\') { $p = $p.Substring(4) }
        if ($p -match '^\\SystemRoot\\') { $p = $env:SystemRoot + $p.Substring(11) }
        if ($p -match '^(System32|SysWOW64)\\') { $p = Join-Path $env:SystemRoot $p }
        if (-not [IO.Path]::IsPathRooted($p)) {
            foreach ($dir in "$env:SystemRoot\System32", $env:SystemRoot) {
                $cand = Join-Path $dir $p
                if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
                if (Test-Path -LiteralPath "$cand.exe" -PathType Leaf) { return "$cand.exe" }
            }
        }
        $p
    }
    catch { $CommandLine }
}

function Get-FileSignatureInfo {
    param([string]$Path)
    if (-not $Path) { return [pscustomobject]@{ Path = ''; Exists = $false; Status = 'Unbekannt'; Signer = ''; Company = '' } }
    if ($script:SigCache.ContainsKey($Path)) { return $script:SigCache[$Path] }
    $info = [pscustomobject]@{ Path = $Path; Exists = $false; Status = 'Datei fehlt'; Signer = ''; Company = '' }
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $info.Exists = $true
            $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
            $info.Status = [string]$sig.Status
            if ($sig.SignerCertificate) { $info.Signer = $sig.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) }
            $info.Company = [string](Get-Item -LiteralPath $Path -Force).VersionInfo.CompanyName
        }
    }
    catch { $info.Status = 'Nicht prüfbar' }
    $script:SigCache[$Path] = $info
    $info
}

function Test-UserWritablePath {
    param([string]$Path)
    $Path -match '\\(AppData|Temp|Downloads|Users\\Public)\\'
}

function Get-PowerSetting {
    param([string]$Sub, [string]$Setting, [switch]$Hidden)
    $mode = if ($Hidden) { '/qh' } else { '/q' }
    $out = (Invoke-Native "$script:Sys32\powercfg.exe" @($mode, 'SCHEME_CURRENT', $Sub, $Setting)) -join "`n"
    $hex = @([regex]::Matches($out, '0x([0-9a-fA-F]{8})') | ForEach-Object { [Convert]::ToInt64($_.Groups[1].Value, 16) })
    if ($hex.Count -ge 2) { [pscustomobject]@{ AC = $hex[-2]; DC = $hex[-1] } }
}

function ConvertTo-LooseVersion {
    param([string]$Text)
    if ($Text -match '(\d+)(\.(\d+))?(\.(\d+))?') { [version]('{0}.{1}.{2}' -f [int]$Matches[1], [int]$Matches[3], [int]$Matches[5]) }
}

function Resolve-ExtensionName {
    param($Manifest, [string]$Dir)
    $name = [string]$Manifest.name
    if ($name -match '^__MSG_(.+)__$') {
        $key = $Matches[1]
        foreach ($loc in @('de', 'en', 'en_US', [string]$Manifest.default_locale)) {
            if (-not $loc) { continue }
            $f = Join-Path $Dir "_locales\$loc\messages.json"
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try { $msgs = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            $prop = $msgs.PSObject.Properties | Where-Object { $_.Name -ieq $key } | Select-Object -First 1
            if ($prop) { return [string]$prop.Value.message }
        }
    }
    $name
}

# Liefert den Paketordner der Store-App (MSIX), aus der das Script gestartet wurde, sonst $null.
# Solche Apps virtualisieren Teile von HKCU für alle Prozesse, die sie starten, auch mit Adminrechten.
# GetCurrentPackageFullName erkennt das nicht (die Kindprozesse haben keine Paket-Identität), daher die Elternkette.
function Get-PackagedAncestor {
    $child = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 25 -and $child; $i++) {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($child.ParentProcessId)" -ErrorAction SilentlyContinue
        # Elternprozess muss älter sein als das Kind, sonst ist die Prozess-ID schon neu vergeben
        if (-not $parent -or $parent.CreationDate -gt $child.CreationDate) { break }
        if ([string]$parent.ExecutablePath -match '\\WindowsApps\\([^\\]+)\\') { return $Matches[1] }
        $child = $parent
    }
    $null
}

# Bewertet eine einzelne Defender-Ausnahme: 'CRIT', 'WARN' oder $null (unauffällig).
function Get-ExclusionRisk {
    param([ValidateSet('Pfad', 'Prozess', 'Endung')][string]$Type, [string]$Value)
    $v = (Expand-MorpheusUmgebung $Value).Trim().TrimEnd('\')
    switch ($Type) {
        'Pfad' {
            # Ganze Laufwerke, System- und Benutzerwurzeln sowie typische Ablageorte für Schadcode
            if ($v -match '^[A-Za-z]:$' -or
                $v -match '^[A-Za-z]:\\(Users|Windows|Program Files( \(x86\))?|ProgramData)$' -or
                $v -match '^[A-Za-z]:\\Users\\[^\\]+$' -or
                $v -match '\\(Temp|Downloads|Desktop|AppData|AppData\\(Local|Roaming|Local\\Temp))$') { return 'CRIT' }
            if ((Test-UserWritablePath "$v\") -or $v -match '[*?]') { return 'WARN' }
        }
        'Prozess' {
            $name = [IO.Path]::GetFileName($v)
            # Alles, was diese Programme starten, bliebe ungescannt
            if ($name -in 'powershell.exe', 'pwsh.exe', 'cmd.exe', 'wscript.exe', 'cscript.exe', 'mshta.exe', 'rundll32.exe', 'regsvr32.exe', 'msiexec.exe', 'explorer.exe', 'svchost.exe') { return 'CRIT' }
            if ($name -in 'node.exe', 'python.exe', 'pythonw.exe', 'java.exe', 'javaw.exe', 'dotnet.exe', 'git.exe', 'bash.exe', 'wsl.exe') { return 'WARN' }
            if (Test-UserWritablePath $v) { return 'WARN' }
        }
        'Endung' {
            if ($v.TrimStart('*', '.') -in 'exe', 'dll', 'sys', 'scr', 'com', 'msi', 'lnk', 'ps1', 'psm1', 'bat', 'cmd', 'js', 'jse', 'vbs', 'vbe', 'wsf', 'hta', 'jar', 'py') { return 'CRIT' }
        }
    }
    $null
}

# Laufwerkstyp zu einem Laufwerksbuchstaben, z. B. 'NVMe-SSD', 'SATA-SSD', 'HDD'
function Get-DriveKind {
    param([string]$Letter)
    $Letter = $Letter.TrimEnd(':', '\')
    if (-not $script:DriveKindCache) { $script:DriveKindCache = @{} }
    if ($script:DriveKindCache.ContainsKey($Letter)) { return $script:DriveKindCache[$Letter] }
    $kind = 'unbekannt'
    try {
        $num = (Get-Partition -DriveLetter $Letter -ErrorAction Stop | Get-Disk -ErrorAction Stop).Number
        $pd = Get-PhysicalDisk | Where-Object { [string]$_.DeviceId -eq [string]$num } | Select-Object -First 1
        if ($pd) {
            $media = [string]$pd.MediaType
            $kind = if ($media -eq 'HDD') { 'HDD' } elseif ([string]$pd.BusType -eq 'NVMe') { 'NVMe-SSD' } elseif ($media -eq 'SSD') { "$($pd.BusType)-SSD" } else { "$($pd.BusType)" }
        }
    }
    catch {}
    $script:DriveKindCache[$Letter] = $kind
    $kind
}

# Bibliotheken (Speicherverbraucher, Spieleliste, Datensicherung): Dot-Source auf Skriptebene, damit die Funktionen sichtbar sind
$script:SpeicherLib = $false
$script:SicherungLib = $false
$speicherLibPfad = Join-Path $PSScriptRoot 'gui\lib\Speicher.ps1'
if (Test-Path -LiteralPath $speicherLibPfad) { . $speicherLibPfad; $script:SpeicherLib = $true }
$script:NvidiaLib = $false
$nvidiaLibPfad = Join-Path $PSScriptRoot 'gui\lib\NvidiaDrs.ps1'
if (Test-Path -LiteralPath $nvidiaLibPfad) { try { . $nvidiaLibPfad; $script:NvidiaLib = $true } catch { } }
$script:AudioLib = $false
$audioLibPfad = Join-Path $PSScriptRoot 'gui\lib\Audio.ps1'
if (Test-Path -LiteralPath $audioLibPfad) { try { . $audioLibPfad; $script:AudioLib = $true } catch { } }
$script:WingetLib = $false
$wingetLibPfad = Join-Path $PSScriptRoot 'gui\lib\Winget.ps1'
if (Test-Path -LiteralPath $wingetLibPfad) { . $wingetLibPfad; $script:WingetLib = $true }
$sicherungLibPfad = Join-Path $PSScriptRoot 'gui\lib\Sicherung.ps1'
if (Test-Path -LiteralPath $sicherungLibPfad) { . $sicherungLibPfad; $script:SicherungLib = $true }
# Akzeptanzliste: früh einlesen, weil die Sigcheck-Prüfung die Datei-Regeln (je SHA256) braucht
$script:AkzeptanzLib = $false
$akzeptanzLibPfad = Join-Path $PSScriptRoot 'gui\lib\Akzeptanz.ps1'
if (Test-Path -LiteralPath $akzeptanzLibPfad) {
    try { . $akzeptanzLibPfad; $script:AkzeptanzLib = [bool](Get-Command Read-MorpheusAkzeptanz -CommandType Function -ErrorAction SilentlyContinue) }
    catch { $script:AkzeptanzLib = $false }
}
$script:AkzeptanzRegeln = @()
if (Test-Path -LiteralPath $AcceptedFile) {
    try {
        if ($script:AkzeptanzLib) { $script:AkzeptanzRegeln = @(Read-MorpheusAkzeptanz -Datei $AcceptedFile | Where-Object { $_ }) }
        else { $script:AkzeptanzRegeln = @((Import-PowerShellDataFile -LiteralPath $AcceptedFile).Accepted | Where-Object { $_ }) }
    }
    catch { Write-Warning (T 'scan.start.akzeptanzFehler' $_.Exception.Message) }
}
# Sysinternals (Autoruns, Sigcheck): Bibliotheken nur laden, nichts ausführen; die Werkzeuge starten ausschließlich über Invoke-MorpheusSysWerkzeug
$script:SysLib = $false
$script:SysDataRoot = $null
$sysInstallPfad = Join-Path $PSScriptRoot 'gui\lib\Install.ps1'
$sysAuswertungPfad = Join-Path $PSScriptRoot 'gui\lib\SysinternalsAuswertung.ps1'
$sysLibPfad = Join-Path $PSScriptRoot 'gui\lib\Sysinternals.ps1'
if ((Test-Path -LiteralPath $sysInstallPfad) -and (Test-Path -LiteralPath $sysAuswertungPfad) -and (Test-Path -LiteralPath $sysLibPfad)) {
    try {
        . $sysInstallPfad
        . $sysAuswertungPfad
        . $sysLibPfad
        $sysFunktionen = @('Invoke-MorpheusSysWerkzeug', 'Get-MorpheusSysStand', 'ConvertFrom-MorpheusAutorunsCsv', 'ConvertFrom-MorpheusSigcheckCsv', 'Get-MorpheusAutorunsSignaturBefund', 'Get-MorpheusAutorunsPfadBefund', 'Get-MorpheusAutorunsTabelle', 'Get-MorpheusSystemdateienBefund', 'Get-MorpheusSigcheckTabelle', 'Test-MorpheusSysKopf', 'Get-MorpheusSysZustimmung')
        $script:SysLib = (@($sysFunktionen | Where-Object { Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue }).Count -eq $sysFunktionen.Count)
    }
    catch { $script:SysLib = $false }
}
# Datenordner (enthält tools\): normal der Elternordner von $OutputDir (GUI-Scan). Fehlt dort tools\ (Scan aus der Befehlszeile ohne GUI),
# aber der Standard-Datenordner (C:\ProgramData\Morpheus) hat einen, wird dieser verwendet.
try {
    $sysAusgabe = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
    $script:SysDataRoot = [IO.Path]::GetFullPath((Split-Path -Parent $sysAusgabe))
    if (-not (Test-Path -LiteralPath (Join-Path $script:SysDataRoot 'tools') -PathType Container) -and (Get-Command MorpheusDefaultDataDir -CommandType Function -ErrorAction SilentlyContinue)) {
        $sysStandard = MorpheusDefaultDataDir
        if (Test-Path -LiteralPath (Join-Path $sysStandard 'tools') -PathType Container) { $script:SysDataRoot = $sysStandard }
    }
}
catch { $script:SysDataRoot = Split-Path -Parent $OutputDir }
# Sichere Pfade (2.3.3): winget-Auflösung und TEMP im gesicherten Datenordner. Add-Type kompiliert in %TEMP% und lädt die DLL
# danach, secedit schreibt die Richtlinie dorthin; im Temp-Ordner des Benutzers könnte ein Benutzerprogramm beides austauschen.
$script:PfadLib = $false
$pfadLibPfad = Join-Path $PSScriptRoot 'gui\lib\Systempfade.ps1'
if (Test-Path -LiteralPath $pfadLibPfad) {
    try {
        . $pfadLibPfad
        $script:PfadLib = $true
        if ($script:IsAdmin) {
            $tempNeu = $null
            if ($script:SysDataRoot) { $tempNeu = Set-MorpheusTempPfad -DataRoot $script:SysDataRoot }
            if (-not $tempNeu) { Write-Warning (T 'scan.start.datenordnerUngesichert') }
        }
    }
    catch { $script:PfadLib = $false }
}
if ($script:PfadLib) {
    try { $script:BenutzerTemp = Get-MorpheusBenutzerTemp } catch { }
    try { $script:BenutzerPath = Get-MorpheusBenutzerPath } catch { }
}
else {
    # Ohne Bibliothek wie vor 2.3.3 (dann gilt ohnehin noch der Temp-Ordner des Benutzers)
    function Expand-MorpheusUmgebung { param([AllowNull()][string]$Text) if (-not $Text) { return $Text }; [Environment]::ExpandEnvironmentVariables($Text) }
}
$script:SysAufgaben = $null       # Aufgabenpfad (klein) -> läuft mit erhöhten Rechten
$script:Autoruns = $null          # Ergebnis des einen Autoruns-Laufs (auch im Fehlerfall)
$script:AutorunsEintraege = $null
$script:SigcheckCache = $null

# Gemeinsame Statuslogik der Sysinternals-Prüfungen. Liefert das Ergebnis von Invoke-MorpheusSysWerkzeug,
# wenn es verwertbar ist; sonst wird der passende Befund geschrieben und $null geliefert.
function Resolve-SysErgebnis {
    param($Ergebnis, [string]$Titel, [string]$Art)
    if (-not $Ergebnis) { Add-Finding SKIP (T 'scan.sys.keineAntwort'); return $null }
    if ($Ergebnis.nichtEingerichtet) { Add-Finding SKIP (T 'scan.sys.nichtEingerichtet'); return $null }
    if ($Ergebnis.nichtVertrauenswuerdig) { Add-Finding WARN (T 'scan.sys.nichtAusgefuehrt' $Titel $Ergebnis.fehler) (T 'scan.sys.neuLaden'); return $null }
    if (-not $Ergebnis.ok) { Add-Finding SKIP (T 'scan.hilfe.fehler' $Ergebnis.fehler); return $null }
    if ($Art -and -not (Test-MorpheusSysKopf -Text $Ergebnis.text -Art $Art)) { Add-Finding SKIP (T 'scan.sys.ausgabeNichtLesbar' $Titel); return $null }
    $Ergebnis
}

# Aufgaben mit erhöhten Rechten (SYSTEM, Dienstkonten oder RunLevel Highest), einmal gebaut: Schlüssel = Pfad klein mit führendem \
function Get-SysAufgaben {
    if ($null -ne $script:SysAufgaben) { return $script:SysAufgaben }
    $tabelle = @{}
    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            $uid = [string]$t.Principal.UserId
            $hoch = ($uid -match '(^|\\)(SYSTEM|LOCAL SERVICE|LOKALER DIENST|NETWORK SERVICE|NETZWERKDIENST)$') -or ($uid -match '^S-1-5-(18|19|20)$') -or ([string]$t.Principal.RunLevel -eq 'Highest')
            $tabelle[(([string]$t.TaskPath + [string]$t.TaskName).ToLowerInvariant())] = [bool]$hoch
        }
    }
    catch { $tabelle = @{} }
    $script:SysAufgaben = $tabelle
    $tabelle
}

function Test-SysVorabAus {
    if ($SkipSysinternals) { Add-Finding SKIP (T 'scan.sys.uebersprungen'); return $true }
    if (-not $script:SysLib) { Add-Finding SKIP (T 'scan.allg.dateiFehlt' 'gui\lib\Sysinternals.ps1'); return $true }
    $false
}

# Fortschrittszeile nur, wenn das Werkzeug wirklich läuft (eingerichtet und Zustimmung vorhanden)
function Write-SysFortschritt {
    param([string]$Text, [string]$Exe)
    $bereit = $true
    try {
        # billig: nur Dateiexistenz und Zustimmung, kein Hashen/Signaturprüfen
        if (-not (Test-Path -LiteralPath (Join-Path $script:SysDataRoot "tools\$Exe") -PathType Leaf)) { $bereit = $false }
        elseif (-not (Get-MorpheusSysZustimmung -DataRoot $script:SysDataRoot).akzeptiert) { $bereit = $false }
    }
    catch { }
    if ($bereit) { Write-Host $Text -ForegroundColor DarkGray }
}

function Get-SysAutoruns {
    if (Test-SysVorabAus) { return $null }
    if (-not $script:Autoruns) {
        Write-SysFortschritt ('    ' + (T 'scan.sys.autorunsLaeuft')) 'autorunsc64.exe'
        try { $script:Autoruns = Invoke-MorpheusSysWerkzeug -DataRoot $script:SysDataRoot -Auftrag autostarts }
        catch { $script:Autoruns = [pscustomobject]@{ ok = $false; fehler = $_.Exception.Message; nichtVertrauenswuerdig = $false; nichtEingerichtet = $false; text = '' } }
    }
    $r = Resolve-SysErgebnis $script:Autoruns 'Autoruns' 'autoruns'
    if (-not $r) { return $null }
    if ($null -eq $script:AutorunsEintraege) { $script:AutorunsEintraege = @(ConvertFrom-MorpheusAutorunsCsv -Text $r.text) }
    , $script:AutorunsEintraege
}

# Bewertet die unsignierten Systemdateien: SHA256 je Datei, Abgleich mit den Datei-Regeln der Akzeptanzliste.
# -Hash ist überschreibbar (Test); Fehler beim Hashen → '' (dann nie akzeptiert).
function Get-SysSigcheckBewertung {
    param($System32, $Treiber, $Regeln = @(), [scriptblock]$Hash)
    if ($null -eq $Hash) { $Hash = { param($Pfad) (Get-FileHash -LiteralPath $Pfad -Algorithm SHA256 -ErrorAction Stop).Hash } }
    $kannFinden = [bool](Get-Command Find-MorpheusAkzeptanzDatei -CommandType Function -ErrorAction SilentlyContinue)
    $regeln = @($Regeln | Where-Object { $_ })
    $zeilen = New-Object System.Collections.Generic.List[object]
    $akzeptiert = @{}
    foreach ($z in @(Get-MorpheusSigcheckTabelle -System32 $System32 -Treiber $Treiber)) {
        $h = ''
        try { $h = ([string](& $Hash $z.Pfad)).ToLowerInvariant() } catch { $h = '' }
        if ($h -notmatch '^[0-9a-f]{64}$') { $h = '' }
        $grund = ''
        if ($kannFinden -and $h -and $regeln.Count) {
            $r = Find-MorpheusAkzeptanzDatei -Regeln $regeln -Pfad $z.Pfad -Sha256 $h
            if ($r) { $grund = [string]$r.reason; if (-not $grund) { $grund = [string]$r.Reason }; if (-not $grund) { $grund = (T 'scan.sig.grund') }; $akzeptiert[([string]$z.Pfad).ToLowerInvariant()] = $true }
        }
        $o = [ordered]@{}
        foreach ($pr in $z.PSObject.Properties) { $o[$pr.Name] = $pr.Value }
        $o['Sha256'] = $h
        $o['Akzeptiert'] = $grund
        $zeilen.Add([pscustomobject]$o)
    }
    $offen32 = @($System32 | Where-Object { $_ -and -not $akzeptiert.ContainsKey(([string]$_.Pfad).ToLowerInvariant()) })
    $offenTr = @($Treiber | Where-Object { $_ -and -not $akzeptiert.ContainsKey(([string]$_.Pfad).ToLowerInvariant()) })
    $k = $akzeptiert.Count
    $b = Get-MorpheusSystemdateienBefund -System32 $offen32 -Treiber $offenTr
    $status = [string]$b.status; $wert = [string]$b.wert; $empf = [string]$b.empfehlung; $note = ''
    if ($k -gt 0 -and $status -eq 'OK') {
        $voll = Get-MorpheusSystemdateienBefund -System32 $System32 -Treiber $Treiber
        $status = 'ACK'; $wert = [string]$voll.wert; $empf = [string]$voll.empfehlung
        $note = if ($k -eq 1) { T 'scan.sig.eineAkzeptiert' } else { T 'scan.sig.akzeptiert' $k }
    }
    elseif ($k -gt 0) { $wert += (T 'scan.sig.wertAkzeptiert' $k) }
    [pscustomobject]@{ Tabelle = $zeilen.ToArray(); Status = $status; Wert = $wert; Empfehlung = $empf; Note = $note; Akzeptiert = $k }
}

function Get-SysSigcheck {
    if (Test-SysVorabAus) { return $null }
    if (-not $script:SigcheckCache) {
        Write-SysFortschritt ('    ' + (T 'scan.sys.sigcheckLaeuft')) 'sigcheck64.exe'
        $cache = [ordered]@{}
        foreach ($auftrag in 'system32', 'treiber') {
            try { $cache[$auftrag] = Invoke-MorpheusSysWerkzeug -DataRoot $script:SysDataRoot -Auftrag $auftrag }
            catch { $cache[$auftrag] = [pscustomobject]@{ ok = $false; fehler = $_.Exception.Message; nichtVertrauenswuerdig = $false; nichtEingerichtet = $false; text = '' } }
            if (-not $cache[$auftrag].ok) { break }
        }
        $script:SigcheckCache = $cache
    }
    $teile = [ordered]@{}
    foreach ($auftrag in 'system32', 'treiber') {
        $r = Resolve-SysErgebnis $script:SigcheckCache[$auftrag] 'Sigcheck' 'sigcheck'
        if (-not $r) { return $null }
        $teile[$auftrag] = @(ConvertFrom-MorpheusSigcheckCsv -Text $r.text)
    }
    $teile
}
# Selbst eingetragene Spiele-Ordner (nur gelesen; Read-MorpheusSpielordner lässt nur lokale Pfade durch)
$script:SpielOrdner = @()
if ($script:SpeicherLib) { try { $script:SpielOrdner = @(Read-MorpheusSpielordner -Datei $SpielOrdnerFile) } catch { } }

# Bekannt harmlose Einträge in Ereignisprotokollen: Muster -> kurze Begründung für den Bericht.
$script:KnownHarmless = @{
    # Dienstfehler (Name oder Anzeigename des Dienstes)
    ServiceErrors   = [ordered]@{
        '^dam$'                    = (T 'scan.harmlos.dam')
        '^Steam Client Service$'   = (T 'scan.harmlos.steam')
        '^(edgeupdate|MicrosoftEdgeElevationService|GoogleUpdater)' = (T 'scan.harmlos.updateDienst')
        '^(gupdate|gupdatem)$'     = (T 'scan.harmlos.updateDienst')
    }
    # Code Integrity: DLLs von Overlays/Aufnahme-Tools, die Windows aus geschützten Systemprozessen fernhält
    CodeIntegrity   = 'nvspcap64\.dll|NvCamera|nvd3dumx|RTSSHooks|GameOverlayRenderer|DiscordHook|graphics-hook|obs-vulkan|igdumd|amdxx|atiu'
    # PowerShell-Skriptblöcke: Aufruf von pc-check selbst und automatisch erzeugte Modul-Exporte
    # pc-check selbst (auch per Umgebungsvariable gestartet) und der PowerShell-Wrapper von Claude Code
    PowerShell      = 'pc-check\.ps1|\$env:PCCHECK\b|^\s*-Function .* -Alias|^\s*function Write-Result\(\$Json\) \{ \[System\.Convert\]::ToBase64String|^\s*try \{ \$PSDefaultParameterValues\[''Out-File:Encoding''\] = ''utf8'' \} catch \{\}'
}
# Browser-Berechtigung für alle Webseiten (nicht: *://*.reddit.com/*)
$script:AllSitesPattern = '^<all_urls>$|^(\*|https?|wss?)://\*/'

$displayCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class PcCheckDisplay
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettings(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

    public class Mode
    {
        public string Device;
        public string Adapter;
        public string Monitor;
        public int Width;
        public int Height;
        public int Hz;
        public int MaxHzAtResolution;
        public int MaxHz;
    }

    public static List<Mode> Get()
    {
        var result = new List<Mode>();
        for (uint i = 0; i < 16; i++)
        {
            var dd = new DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
            if ((dd.StateFlags & 1) == 0) continue;
            var cur = new DEVMODE();
            cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(dd.DeviceName, -1, ref cur)) continue;
            var mon = new DISPLAY_DEVICE();
            mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            string monName = EnumDisplayDevices(dd.DeviceName, 0, ref mon, 0) ? mon.DeviceString : "";
            var m = new Mode { Device = dd.DeviceName, Adapter = dd.DeviceString, Monitor = monName, Width = cur.dmPelsWidth, Height = cur.dmPelsHeight, Hz = cur.dmDisplayFrequency };
            var mode = new DEVMODE();
            mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            for (int n = 0; EnumDisplaySettings(dd.DeviceName, n, ref mode); n++)
            {
                if (mode.dmDisplayFrequency > m.MaxHz) m.MaxHz = mode.dmDisplayFrequency;
                if (mode.dmPelsWidth == cur.dmPelsWidth && mode.dmPelsHeight == cur.dmPelsHeight && mode.dmDisplayFrequency > m.MaxHzAtResolution) m.MaxHzAtResolution = mode.dmDisplayFrequency;
            }
            result.Add(m);
        }
        return result;
    }
}
'@

#endregion

Write-Host (T 'scan.start.kopf' $ProductName $ProductTagline $ScriptVersion $script:IsAdmin $EventDays) -ForegroundColor Green
if (-not $script:IsAdmin) { Write-Warning (T 'scan.start.ohneAdmin') }
$script:PackagedFrom = Get-PackagedAncestor
if ($script:PackagedFrom) { Write-Warning (T 'scan.start.store' $script:PackagedFrom) }

$script:OS = Get-CimInstance Win32_OperatingSystem
$script:CS = Get-CimInstance Win32_ComputerSystem
$script:CV = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$script:Services = @(Get-CimInstance Win32_Service)
$script:Profile = $Profil
$script:ProfileAuto = $false
if ($Profil -eq 'Auto') {
    $script:ProfileAuto = $true
    $hasBattery = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    $hasDgpu = [bool](Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon|Arc' })
    $script:Profile = if ($hasBattery) { 'Laptop' } elseif ($hasDgpu) { 'Gaming' } else { 'Office' }
}
Write-Host ((T 'scan.start.profil' $script:Profile) + $(if ($script:ProfileAuto) { ' ' + (T 'scan.start.profilAuto') } else { '' })) -ForegroundColor Green
$script:Features = @()
$script:DeviceGuard = $null
$script:SecureBoot = $false
$script:AutostartRows = @()
$script:ThirdPartyServices = @()
$script:WingetUpdates = @()

#region Sicherheit: System & Updates

Start-Section 'Sicherheit' 'System & Updates'

Invoke-Check 'Ausführungsumgebung' {
    if ($script:PackagedFrom) { Add-Finding WARN (T 'scan.umgebung.store' $script:PackagedFrom) (T 'scan.umgebung.storeEmpf') }
    else { Add-Finding OK (T 'scan.umgebung.normal') }
}

Invoke-Check 'Windows-Version' {
    $cv = $script:CV
    $build = '{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR
    $ver = [string]$cv.DisplayVersion
    $uptime = (Get-Date) - $script:OS.LastBootUpTime
    Add-Table 'System' @([pscustomobject][ordered]@{
            Computer     = $env:COMPUTERNAME
            Edition      = $script:OS.Caption
            Version      = $ver
            Build        = $build
            Installiert  = Format-Date $script:OS.InstallDate
            LetzterStart = Format-Date $script:OS.LastBootUpTime
            Laufzeit     = (T 'scan.version.laufzeit' $uptime.Days $uptime.Hours)
            Hersteller   = $script:CS.Manufacturer
            Modell       = $script:CS.Model
        })
    # Supportende Home/Pro
    $endOfService = @{ '22H2' = '2024-10-08'; '23H2' = '2025-11-11'; '24H2' = '2026-10-13'; '25H2' = '2027-10-12' }
    if ($endOfService.ContainsKey($ver)) {
        $end = [datetime]$endOfService[$ver]
        $days = ($end - (Get-Date)).Days
        $value = T 'scan.version.support' $ver $build ($end.ToString('yyyy-MM-dd'))
        if ($days -lt 0) { Add-Finding CRIT $value (T 'scan.version.abgelaufen') }
        elseif ($days -lt 90) { Add-Finding WARN $value (T 'scan.version.bald') }
        else { Add-Finding OK $value }
    }
    else { Add-Finding INFO (T 'scan.version.info' $ver $build) (T 'scan.version.infoEmpf') }
}

Invoke-Check 'Windows-Aktivierung' {
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1
    if (-not $lic) { Add-Finding WARN (T 'scan.aktivierung.keinSchluessel') (T 'scan.aktivierung.keinSchluesselEmpf'); return }
    $states = @{ 0 = (T 'scan.aktivierung.status0'); 1 = (T 'scan.aktivierung.status1'); 2 = (T 'scan.aktivierung.status2'); 3 = (T 'scan.aktivierung.status3'); 4 = (T 'scan.aktivierung.status4'); 5 = (T 'scan.aktivierung.status5'); 6 = (T 'scan.aktivierung.status6') }
    $state = $states[[int]$lic.LicenseStatus]
    if ($lic.LicenseStatus -eq 1) { Add-Finding OK "$state ($($lic.Name))" }
    else { Add-Finding WARN "$state ($($lic.Name))" (T 'scan.aktivierung.warnEmpf') }
}

Invoke-Check 'Windows Update: Verlauf' {
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $total = $searcher.GetTotalHistoryCount()
    $history = @()
    # Defender-Signaturen kommen mehrmals täglich und verdrängen sonst alles andere aus dem Verlauf.
    if ($total -gt 0) { $history = @($searcher.QueryHistory(0, $total) | Where-Object { $_.Title -and $_.Title -notmatch 'KB2267602|Security Intelligence|Sicherheitsinformationen' }) }
    $results = @{ 0 = (T 'scan.verlauf.nichtGestartet'); 1 = (T 'scan.verlauf.laeuft'); 2 = (T 'scan.verlauf.erfolgreich'); 3 = (T 'scan.verlauf.mitFehlern'); 4 = (T 'scan.verlauf.fehlgeschlagenStatus'); 5 = (T 'scan.verlauf.abgebrochen') }
    $rows = foreach ($h in ($history | Select-Object -First 40)) {
        [pscustomobject][ordered]@{ Datum = Format-Date $h.Date.ToLocalTime(); Ergebnis = $results[[int]$h.ResultCode]; Titel = $h.Title }
    }
    Add-Table 'Windows Update: letzte Installationen (ohne Defender-Signaturen)' $rows
    # Seit 2025 heißen die Monatsupdates "JJJJ-MM Security Update (KB…)", vorher "Kumulatives Update".
    $cu = $history | Where-Object {
        $_.ResultCode -eq 2 -and $_.Title -notmatch '\.NET' -and
        $_.Title -match '^\d{4}-\d{2} (Security Update|Sicherheitsupdate|Cumulative Update|Kumulatives Update)|Kumulatives Update für Windows|Cumulative Update for Windows'
    } | Sort-Object Date -Descending | Select-Object -First 1
    if ($cu) {
        $age = ((Get-Date).ToUniversalTime() - $cu.Date).Days
        $value = T 'scan.verlauf.letztes' $age ($cu.Title)
        if ($age -gt 60) { Add-Finding CRIT $value (T 'scan.verlauf.critEmpf') }
        elseif ($age -gt 40) { Add-Finding WARN $value (T 'scan.verlauf.warnEmpf') }
        else { Add-Finding OK $value }
    }
    else { Add-Finding WARN (T 'scan.verlauf.keins') (T 'scan.verlauf.keinsEmpf') }
    $failed = @($history | Where-Object { $_.ResultCode -eq 4 -and $_.Date -gt (Get-Date).AddDays(-30) })
    if ($failed.Count) {
        Add-Finding WARN (T 'scan.verlauf.fehlgeschlagen' $failed.Count (($failed | Select-Object -ExpandProperty Title -Unique | Select-Object -First 3) -join '; ')) `
            (T 'scan.verlauf.fehlgeschlagenEmpf') -Check 'Windows Update: Fehler'
    }
}

if ($SkipUpdateSearch) {
    $script:CheckName = 'Windows Update: ausstehend'
    Add-Finding SKIP (T 'scan.update.uebersprungen')
}
else {
    Invoke-Check 'Windows Update: ausstehend' {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $res = $searcher.Search('IsInstalled=0 and IsHidden=0')
        $ups = @(for ($i = 0; $i -lt $res.Updates.Count; $i++) { $res.Updates.Item($i) })
        $rows = foreach ($u in $ups) {
            [pscustomobject][ordered]@{
                Titel          = $u.Title
                Schweregrad    = [string]$u.MsrcSeverity
                Typ            = $(if ($u.Type -eq 2) { T 'scan.update.typTreiber' } else { T 'scan.update.typSoftware' })
                Heruntergladen = [bool]$u.IsDownloaded
            }
        }
        Add-Table 'Windows Update: ausstehend' $rows
        # Defender-Signaturen holt Defender mehrmals täglich selbst; ein gerade fälliges ist kein Handlungsbedarf.
        $sigPattern = 'KB2267602|Security Intelligence|Sicherheitsinformationen'
        $sw = @($ups | Where-Object { $_.Type -ne 2 -and $_.Title -notmatch $sigPattern })
        $other = @($ups | Where-Object { $_.Type -eq 2 -or $_.Title -match $sigPattern } | ForEach-Object { $(if ($_.Type -eq 2) { T 'scan.update.typTreiber' } else { T 'scan.update.defenderSignaturen' }) } | Select-Object -Unique)
        if (-not $ups.Count) { Add-Finding OK (T 'scan.update.keine') }
        elseif ($sw | Where-Object { $_.MsrcSeverity -eq 'Critical' }) { Add-Finding CRIT (T 'scan.update.kritisch' $sw.Count) (T 'scan.update.kritischEmpf') }
        elseif ($sw.Count) { Add-Finding WARN (T 'scan.update.ausstehend' $sw.Count) (T 'scan.update.ausstehendEmpf') }
        else { Add-Finding INFO (T 'scan.update.nurOptional' ($other -join ', ')) (T 'scan.update.nurOptionalEmpf') }
    }
}

Invoke-Check 'Neustart ausstehend' {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += (T 'scan.neustart.komponenten') }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    if ($reasons) { Add-Finding WARN (T 'scan.neustart.erforderlich' ($reasons -join ', ')) (T 'scan.neustart.erforderlichEmpf') }
    else { Add-Finding OK (T 'scan.neustart.keiner') }
}

Invoke-Check 'Windows Update: Einstellungen' {
    $blocked = @(); $notes = @()
    if ((Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate') -eq 1) { $blocked += (T 'scan.wuEinst.richtlinie') }
    $wu = $script:Services | Where-Object Name -EQ 'wuauserv'
    if ($wu.StartMode -eq 'Disabled') { $blocked += (T 'scan.wuEinst.dienst') }
    $wuPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    foreach ($n in 'DeferFeatureUpdatesPeriodInDays', 'DeferQualityUpdatesPeriodInDays', 'TargetReleaseVersionInfo', 'ProductVersion') {
        $v = Get-RegValue $wuPol $n
        if ($null -ne $v) { $notes += "$n = $v" }
    }
    $paused = $null
    $pause = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'PauseUpdatesExpiryTime'
    if ($pause) {
        try {
            $p = [datetime]::Parse($pause, [Globalization.CultureInfo]::InvariantCulture)
            if ($p -gt (Get-Date)) { $paused = $p }
        }
        catch {}
    }
    if ($blocked) { Add-Finding CRIT ($blocked -join '; ') (T 'scan.wuEinst.sperreEmpf') }
    elseif ($paused) { Add-Finding WARN (T 'scan.wuEinst.pausiert' ($paused.ToString('yyyy-MM-dd'))) (T 'scan.wuEinst.pausiertEmpf') }
    elseif ($notes) { Add-Finding INFO (T 'scan.wuEinst.richtlinien' ($notes -join '; ')) }
    else { Add-Finding OK (T 'scan.wuEinst.ok') }
}

#endregion

#region Sicherheit: Virenschutz

Start-Section 'Sicherheit' 'Virenschutz'

Invoke-Check 'Registrierte Schutzprogramme' {
    $av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct)
    $rows = foreach ($a in $av) {
        $hex = '{0:X6}' -f [int]$a.productState
        [pscustomobject][ordered]@{
            Produkt    = $a.displayName
            Aktiv      = ($hex.Substring(2, 2) -in '10', '11')
            Signaturen = $(if ($hex.Substring(4, 2) -eq '00') { T 'scan.av.aktuell' } else { T 'scan.av.veraltet' })
            Pfad       = $a.pathToSignedReportingExe
        }
    }
    Add-Table 'Virenschutzprogramme (Sicherheitscenter)' $rows
    $active = @($rows | Where-Object Aktiv)
    if (-not $active) { Add-Finding CRIT (T 'scan.av.keiner') (T 'scan.av.keinerEmpf') }
    elseif ($active.Count -gt 1) { Add-Finding WARN (T 'scan.av.mehrere' (($active | ForEach-Object Produkt) -join ', ')) (T 'scan.av.mehrereEmpf') }
    else { Add-Finding OK (T 'scan.av.ok' ($active[0].Produkt) ($active[0].Signaturen)) }
}

Invoke-Check 'Microsoft Defender: Status' {
    $s = Get-MpComputerStatus
    Add-Table 'Microsoft Defender' @([pscustomobject][ordered]@{
            Modus                 = [string]$s.AMRunningMode
            Echtzeitschutz        = $s.RealTimeProtectionEnabled
            Verhaltensueberwachung = $s.BehaviorMonitorEnabled
            DownloadPruefung      = $s.IoavProtectionEnabled
            Netzwerkinspektion    = $s.NISEnabled
            Manipulationsschutz   = $s.IsTamperProtected
            Signaturen            = Format-Date $s.AntivirusSignatureLastUpdated
            SchnellscanAlterTage  = $s.QuickScanAge
            VollscanAlterTage     = $s.FullScanAge
            Engine                = $s.AMEngineVersion
            Plattform             = $s.AMProductVersion
        })
    if ($s.AMRunningMode -and $s.AMRunningMode -ne 'Normal') {
        Add-Finding INFO (T 'scan.defender.modus' ($s.AMRunningMode)) (T 'scan.defender.modusEmpf')
        return
    }
    $off = @()
    if (-not $s.AntivirusEnabled) { $off += (T 'scan.defender.kompVirenschutz') }
    if (-not $s.RealTimeProtectionEnabled) { $off += (T 'scan.defender.kompEchtzeit') }
    if (-not $s.BehaviorMonitorEnabled) { $off += (T 'scan.defender.kompVerhalten') }
    if (-not $s.IoavProtectionEnabled) { $off += (T 'scan.defender.kompDownload') }
    if (-not $s.OnAccessProtectionEnabled) { $off += (T 'scan.defender.kompZugriff') }
    if ($off) { Add-Finding CRIT (T 'scan.defender.abgeschaltet' ($off -join ', ')) (T 'scan.defender.abgeschaltetEmpf') }
    else { Add-Finding OK (T 'scan.defender.ok') }

    if ($s.IsTamperProtected) { Add-Finding OK (T 'scan.allg.an') -Check 'Defender: Manipulationsschutz' }
    else { Add-Finding WARN (T 'scan.allg.aus') (T 'scan.defender.manipulationEmpf') -Check 'Defender: Manipulationsschutz' }

    $age = [int]$s.AntivirusSignatureAge
    $value = T 'scan.defender.stand' (Format-Date $s.AntivirusSignatureLastUpdated) $age
    if ($age -gt 7) { Add-Finding CRIT $value (T 'scan.defender.sigCritEmpf') -Check 'Defender: Signaturen' }
    elseif ($age -gt 1) { Add-Finding WARN $value (T 'scan.defender.sigWarnEmpf') -Check 'Defender: Signaturen' }
    else { Add-Finding OK $value -Check 'Defender: Signaturen' }

    if ([int]$s.QuickScanAge -gt 14) { Add-Finding INFO (T 'scan.defender.schnellscan' ($s.QuickScanAge)) (T 'scan.defender.schnellscanEmpf') -Check 'Defender: Scans' }
}

Invoke-Check 'Microsoft Defender: Einstellungen' {
    $p = Get-MpPreference
    $notes = @(); $warn = @()
    switch ([int]$p.PUAProtection) {
        1 { }
        2 { $warn += (T 'scan.defEinst.puaUeberwachung') }
        default { $warn += (T 'scan.defEinst.puaAus') }
    }
    if ([int]$p.MAPSReporting -eq 0) { $warn += (T 'scan.defEinst.cloudAus') }
    if ([int]$p.SubmitSamplesConsent -eq 2) { $notes += (T 'scan.defEinst.beispiele') }
    if ([int]$p.EnableNetworkProtection -ne 1) { $notes += (T 'scan.defEinst.netzwerkschutz') }
    if ([int]$p.EnableControlledFolderAccess -ne 1) { $notes += (T 'scan.defEinst.ordnerzugriff') }
    if ($warn) { Add-Finding WARN (($warn + $notes) -join '; ') (T 'scan.defEinst.warnEmpf') }
    elseif ($notes) { Add-Finding INFO ($notes -join '; ') (T 'scan.defEinst.infoEmpf') }
    else { Add-Finding OK (T 'scan.defEinst.ok') }

    # Regeln zur Verringerung der Angriffsfläche (ASR)
    $asrNames = @{
        '56a863a9-875e-4185-98a7-b882c64b5ce5' = (T 'scan.asr.treiber')
        '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' = (T 'scan.asr.lsass')
        'd4f940ab-401b-4efc-aadc-ad5f3c50688a' = (T 'scan.asr.officeKind')
        '3b576869-a4ec-4529-8536-b80a7769e899' = (T 'scan.asr.officeExe')
        '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84' = (T 'scan.asr.officeInj')
        '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b' = (T 'scan.asr.officeMakro')
        '26190899-1602-49e8-8b27-eb1d0a1ce869' = (T 'scan.asr.officeKomm')
        '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c' = (T 'scan.asr.adobe')
        'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550' = (T 'scan.asr.email')
        '01443614-cd74-433a-b99e-2ecdc07bfc25' = (T 'scan.asr.unbekannt')
        '5beb7efe-fd9a-4556-801d-275e5ffc04cc' = (T 'scan.asr.skripte')
        'd3e037e1-3eb8-44c8-a917-57927947596d' = (T 'scan.asr.jsvbs')
        'e6db77e5-3df2-4cf1-b95a-636979351e5b' = (T 'scan.asr.wmi')
        'd1e49aac-8f56-4280-b9ba-993a6d77406c' = (T 'scan.asr.psexec')
        'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4' = (T 'scan.asr.usb')
        'c1db55ab-c21a-4637-bb3f-a12568109d35' = (T 'scan.asr.ransomware')
        '33ddedf1-c6e0-47cb-833e-de6133960387' = (T 'scan.asr.abgesichert')
        'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb' = (T 'scan.asr.kopiert')
        'a8f5898e-1dc8-49a9-9878-85004b8a61e6' = (T 'scan.asr.webshell')
    }
    $actBlock = T 'scan.asr.aktBlock'; $actWarn = T 'scan.asr.aktWarnen'; $actNames = @{ 0 = (T 'scan.asr.aktAus'); 1 = $actBlock; 2 = (T 'scan.asr.aktUeberwachen'); 5 = (T 'scan.asr.aktNichtKonf'); 6 = $actWarn }
    $ids = @($p.AttackSurfaceReductionRules_Ids | Where-Object { $_ })
    $acts = @($p.AttackSurfaceReductionRules_Actions)
    $asrRows = for ($i = 0; $i -lt $ids.Count; $i++) {
        $name = $asrNames[$ids[$i].ToLower()]
        if (-not $name) { $name = $ids[$i] }
        [pscustomobject][ordered]@{ Regel = $name; Aktion = $actNames[[int]$acts[$i]] }
    }
    Add-Table 'Defender: ASR-Regeln' $asrRows
    $activeAsr = @($asrRows | Where-Object { $_.Aktion -in $actBlock, $actWarn })
    if ($activeAsr.Count) { Add-Finding OK (T 'scan.asr.aktiv' $activeAsr.Count) -Check 'Defender: ASR-Regeln' }
    else {
        Add-Finding INFO (T 'scan.asr.keine') `
            (T 'scan.asr.keineEmpf') `
            -Check 'Defender: ASR-Regeln'
    }

    # Ausnahmen
    $excl = @()
    $excl += @($p.ExclusionPath | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Typ = 'Pfad'; Wert = $_ } })
    $excl += @($p.ExclusionProcess | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Typ = 'Prozess'; Wert = $_ } })
    $excl += @($p.ExclusionExtension | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Typ = 'Endung'; Wert = $_ } })
    if ($excl | Where-Object { $_.Wert -like 'N/A*' }) {
        Add-Finding SKIP (T 'scan.ausnahmen.nurAdmin') -Check 'Defender: Ausnahmen'
    }
    else {
        $exclRows = foreach ($e in $excl) {
            [pscustomobject][ordered]@{ Typ = $e.Typ; Wert = $e.Wert; Risiko = [string](Get-ExclusionRisk -Type $e.Typ -Value $e.Wert) }
        }
        Add-Table 'Defender: Ausnahmen' $exclRows
        $crit = @($exclRows | Where-Object Risiko -EQ 'CRIT')
        $warn = @($exclRows | Where-Object Risiko -EQ 'WARN')
        $rec = T 'scan.ausnahmen.empf'
        if ($crit) { Add-Finding CRIT (T 'scan.ausnahmen.gefaehrlich' (($crit | ForEach-Object { "$($_.Typ) $($_.Wert)" }) -join '; ')) $rec -Check 'Defender: Ausnahmen' }
        elseif ($warn) { Add-Finding WARN (T 'scan.ausnahmen.riskant' (($warn | ForEach-Object { "$($_.Typ) $($_.Wert)" }) -join '; ')) $rec -Check 'Defender: Ausnahmen' }
        elseif ($exclRows) { Add-Finding INFO (T 'scan.ausnahmen.info' (@($exclRows).Count)) -Check 'Defender: Ausnahmen' }
        else { Add-Finding OK (T 'scan.ausnahmen.keine') -Check 'Defender: Ausnahmen' }
    }
}

Invoke-Check 'Microsoft Defender: Funde' {
    $threats = @(Get-MpThreat -ErrorAction SilentlyContinue)
    $names = @{}
    foreach ($t in $threats) { $names[[string]$t.ThreatID] = $t.ThreatName }
    $det = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $script:Since })
    $rows = foreach ($d in $det) {
        [pscustomobject][ordered]@{
            Zeit      = Format-Date $d.InitialDetectionTime
            Bedrohung = $names[[string]$d.ThreatID]
            Prozess   = $d.ProcessName
            Erfolg    = $d.ActionSuccess
            Dateien   = (@($d.Resources) | Select-Object -First 3) -join '; '
        }
    }
    Add-Table 'Defender: Funde im Zeitraum' $rows
    $active = @($threats | Where-Object IsActive)
    if ($active) { Add-Finding CRIT (T 'scan.funde.aktiv' (($active | ForEach-Object ThreatName) -join ', ')) (T 'scan.funde.aktivEmpf') }
    elseif ($det) { Add-Finding WARN (T 'scan.funde.warn' $det.Count $EventDays ((@($rows | ForEach-Object Bedrohung | Select-Object -Unique)) -join ', ')) (T 'scan.funde.warnEmpf') }
    else { Add-Finding OK (T 'scan.funde.keine' $EventDays) }
}

#endregion

#region Sicherheit: Firewall & Netzwerk

Start-Section 'Sicherheit' 'Firewall & Netzwerk'

Invoke-Check 'Firewall-Profile' {
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    $rows = foreach ($fp in $profiles) {
        [pscustomobject][ordered]@{ Profil = $fp.Name; Aktiv = [string]$fp.Enabled; Eingehend = [string]$fp.DefaultInboundAction; Ausgehend = [string]$fp.DefaultOutboundAction; Benachrichtigen = [string]$fp.NotifyOnListen }
    }
    Add-Table 'Firewall-Profile' $rows
    $thirdParty = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct -ErrorAction SilentlyContinue | ForEach-Object displayName)
    $off = @($rows | Where-Object { $_.Aktiv -ne 'True' } | ForEach-Object Profil)
    $open = @($rows | Where-Object { $_.Eingehend -eq 'Allow' } | ForEach-Object Profil)
    if ($off -and -not $thirdParty) { Add-Finding CRIT (T 'scan.fw.aus' ($off -join ', ')) (T 'scan.fw.ausEmpf') }
    elseif ($open) { Add-Finding CRIT (T 'scan.fw.eingehend' ($open -join ', ')) (T 'scan.fw.eingehendEmpf') }
    elseif ($off) { Add-Finding INFO (T 'scan.fw.drittanbieter' ($thirdParty -join ', ')) }
    else { Add-Finding OK (T 'scan.fw.ok') }
}

Invoke-Check 'Netzwerkprofile' {
    $rows = foreach ($n in @(Get-NetConnectionProfile)) {
        [pscustomobject][ordered]@{ Netzwerk = $n.Name; Adapter = $n.InterfaceAlias; Kategorie = [string]$n.NetworkCategory; IPv4 = [string]$n.IPv4Connectivity }
    }
    Add-Table 'Netzwerkprofile' $rows
    Add-Finding INFO (($rows | ForEach-Object { "$($_.Adapter): $($_.Kategorie)" }) -join '; ') (T 'scan.netz.empf')
}

Invoke-Check 'Firewall: eigene Eingangsregeln' {
    $rules = @(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow)
    $custom = @($rules | Where-Object { -not $_.Group -or $_.Group -notlike '@*' })
    $rows = foreach ($r in $custom) {
        $app = ($r | Get-NetFirewallApplicationFilter).Program
        $pf = $r | Get-NetFirewallPortFilter
        $af = $r | Get-NetFirewallAddressFilter
        [pscustomobject][ordered]@{
            Name      = $r.DisplayName
            Profil    = [string]$r.Profile
            Programm  = $app
            Protokoll = [string]$pf.Protocol
            Ports     = (@($pf.LocalPort) -join ',')
            Remote    = (@($af.RemoteAddress) -join ',')
        }
    }
    Add-Table 'Firewall: eigene Eingangsregeln (Zulassen)' $rows
    $open = @($rows | Where-Object { $_.Profil -match 'Public|Any' -and $_.Remote -eq 'Any' })
    $publicNow = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { [string]$_.NetworkCategory -eq 'Public' }).Count -gt 0
    if ($open) {
        $apps = @($open | ForEach-Object { if ($_.Programm -and $_.Programm -ne 'Any') { [IO.Path]::GetFileName($_.Programm) } else { $_.Name } } | Select-Object -Unique)
        Add-Finding WARN (T 'scan.eingang.offen' $open.Count (@($rows).Count) $apps.Count $(if ($publicNow) { T 'scan.eingang.netzOeffentlich' } else { '' })) `
            (T 'scan.eingang.offenEmpf')
    }
    else { Add-Finding OK (T 'scan.eingang.ok' (@($rows).Count)) }
}

Invoke-Check 'Offene Netzwerkports' {
    $procNames = @{}
    Get-Process | ForEach-Object { $procNames[$_.Id] = $_.ProcessName }
    $svcByPid = @{}
    $script:Services | Where-Object { $_.ProcessId } | Group-Object ProcessId | ForEach-Object { $svcByPid[[int]$_.Name] = (($_.Group | ForEach-Object Name) -join ',') }
    $isRemote = { param($a) $a -notmatch '^(127\.|::1$)' }
    $tcp = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { & $isRemote $_.LocalAddress })
    $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { (& $isRemote $_.LocalAddress) -and $_.LocalPort -lt 49152 })
    $rows = @()
    foreach ($set in @(@{ Proto = 'TCP'; Items = $tcp }, @{ Proto = 'UDP'; Items = $udp })) {
        $rows += foreach ($g in ($set.Items | Group-Object LocalPort, OwningProcess)) {
            $first = $g.Group[0]
            $procId = [int]$first.OwningProcess
            [pscustomobject][ordered]@{
                Protokoll = $set.Proto
                Port      = [int]$first.LocalPort
                Adressen  = (($g.Group | ForEach-Object LocalAddress | Select-Object -Unique) -join ', ')
                Prozess   = $procNames[$procId]
                Dienste   = $svcByPid[$procId]
                PID       = $procId
            }
        }
    }
    $rows = @($rows | Sort-Object Protokoll, Port)
    Add-Table 'Offene Netzwerkports (nicht nur lokal)' $rows
    $risky = @{ 21 = 'FTP'; 22 = 'SSH'; 23 = 'Telnet'; 80 = 'HTTP'; 443 = 'HTTPS'; 1433 = 'SQL Server'; 3306 = 'MySQL'; 3389 = 'RDP'; 5432 = 'PostgreSQL'; 5900 = 'VNC'; 5985 = 'WinRM'; 5986 = 'WinRM'; 6379 = 'Redis'; 8080 = 'HTTP-Alt'; 9200 = 'Elasticsearch'; 11434 = 'Ollama'; 27017 = 'MongoDB' }
    $winProcs = 'svchost', 'lsass', 'wininit', 'services', 'spoolsv', 'System'
    $tcpRows = @($rows | Where-Object Protokoll -EQ 'TCP')
    $hits = @($tcpRows | Where-Object { $risky.ContainsKey($_.Port) } | ForEach-Object { "$($_.Port)/$($risky[$_.Port]) ($($_.Prozess))" })
    $other = @($tcpRows | Where-Object {
            -not $risky.ContainsKey($_.Port) -and -not ($_.Prozess -in $winProcs -and ($_.Port -in 135, 139, 445, 5040, 7680 -or $_.Port -ge 49664))
        } | ForEach-Object { "$($_.Port) ($($_.Prozess))" })
    if ($hits) { Add-Finding WARN (T 'scan.ports.lauschen' ($hits -join ', ')) (T 'scan.ports.lauschenEmpf') }
    elseif ($other) { Add-Finding INFO (T 'scan.ports.weitere' ($other -join ', ')) (T 'scan.ports.weitereEmpf') }
    else { Add-Finding OK (T 'scan.ports.ok') }
}

Invoke-Check 'Router-Portweiterleitungen (UPnP)' {
    $job = Start-Job -ScriptBlock {
        # Modulpfad auch im Kindprozess begrenzen (2.3.3)
        $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
        $nat = New-Object -ComObject HNetCfg.NATUPnP
        $col = $nat.StaticPortMappingCollection
        if ($null -eq $col) { return 'NODATA' }
        foreach ($m in $col) {
            [pscustomobject]@{ Extern = $m.ExternalPort; Protokoll = $m.Protocol; Intern = $m.InternalPort; Ziel = $m.InternalClient; Beschreibung = $m.Description; Aktiv = $m.Enabled }
        }
    }
    if (-not (Wait-Job $job -Timeout 30)) {
        Stop-Job $job; Remove-Job $job -Force
        Add-Finding SKIP (T 'scan.upnp.zeit')
        return
    }
    $res = @(Receive-Job $job -ErrorAction SilentlyContinue)
    Remove-Job $job -Force
    $maps = @($res | Where-Object { $_ -isnot [string] } | Select-Object Extern, Protokoll, Intern, Ziel, Beschreibung, Aktiv)
    if (-not $maps) { Add-Finding OK (T 'scan.upnp.keine'); return }
    Add-Table 'Router-Portweiterleitungen (UPnP)' $maps
    $myIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object IPAddress)
    $mine = @($maps | Where-Object { $_.Ziel -in $myIps })
    if ($mine) { Add-Finding WARN (T 'scan.upnp.meinPc' (($mine | ForEach-Object { "$($_.Extern)/$($_.Protokoll) $($_.Beschreibung)" }) -join '; ')) (T 'scan.upnp.meinPcEmpf') }
    else { Add-Finding INFO (T 'scan.upnp.andere' $maps.Count) (T 'scan.upnp.andereEmpf') }
}

Invoke-Check 'SMB-Konfiguration' {
    $issues = @(); $notes = @()
    $srv = $null; $cli = $null
    try { $srv = Get-SmbServerConfiguration -ErrorAction Stop } catch {}
    try { $cli = Get-SmbClientConfiguration -ErrorAction Stop } catch {}
    if ($srv) {
        if ($srv.EnableSMB1Protocol) { $issues += (T 'scan.smb.v1Server') }
        if (-not $srv.RequireSecuritySignature) { $notes += (T 'scan.smb.srvSignierung') }
    }
    else { $notes += (T 'scan.smb.srvNichtLesbar') }
    $mrx = 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10'
    if ((Test-Path $mrx) -and (Get-RegValue $mrx 'Start') -ne 4) { $issues += (T 'scan.smb.v1Client') }
    if ($cli) {
        if ($cli.EnableInsecureGuestLogons) { $issues += (T 'scan.smb.gast') }
        if (-not $cli.RequireSecuritySignature) { $notes += (T 'scan.smb.cliSignierung') }
    }
    if ($issues -match 'SMBv1') { Add-Finding CRIT (($issues + $notes) -join '; ') (T 'scan.smb.v1Empf') }
    elseif ($issues) { Add-Finding WARN (($issues + $notes) -join '; ') (T 'scan.smb.gastEmpf') }
    elseif ($notes) { Add-Finding INFO ($notes -join '; ') }
    else { Add-Finding OK (T 'scan.smb.ok') }
}

Invoke-Check 'Freigaben' {
    $shares = @(Get-CimInstance Win32_Share | Where-Object { $_.Name -notmatch '\$$' })
    if (-not $shares) { Add-Finding OK (T 'scan.freigaben.keine'); return }
    $everyone = ([Security.Principal.SecurityIdentifier]'S-1-1-0').Translate([Security.Principal.NTAccount]).Value
    $rows = foreach ($s in $shares) {
        $access = ''
        try { $access = ((Get-SmbShareAccess -Name $s.Name -ErrorAction Stop | ForEach-Object { "$($_.AccountName): $($_.AccessRight)" }) -join '; ') } catch {}
        [pscustomobject][ordered]@{ Name = $s.Name; Pfad = $s.Path; Zugriff = $access }
    }
    Add-Table 'Freigaben' $rows
    $open = @($rows | Where-Object { $_.Zugriff -match ([regex]::Escape($everyone) + ': (Full|Change)') })
    if ($open) { Add-Finding WARN (T 'scan.freigaben.schreib' (($open | ForEach-Object Name) -join ', ')) (T 'scan.freigaben.schreibEmpf') }
    else { Add-Finding INFO (T 'scan.freigaben.info' (($rows | ForEach-Object { "$($_.Name) ($($_.Pfad))" }) -join ', ')) (T 'scan.freigaben.infoEmpf') }
}

Invoke-Check 'LLMNR / NetBIOS' {
    $llmnr = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast'
    $nbNames = @{ 0 = (T 'scan.llmnr.standardDhcp'); 1 = (T 'scan.allg.anKlein'); 2 = (T 'scan.allg.ausKlein') }
    $nb = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | ForEach-Object { '{0}: {1}' -f $_.Description, $nbNames[[int]$_.TcpipNetbiosOptions] })
    $value = T 'scan.llmnr.wert' $(if ($llmnr -eq 0) { T 'scan.allg.ausKlein' } else { T 'scan.llmnr.anStandard' }) ($nb -join '; ')
    if ($llmnr -eq 0) { Add-Finding OK $value }
    else { Add-Finding INFO $value (T 'scan.llmnr.empf') }
}

Invoke-Check 'Proxy und Hosts-Datei' {
    $is = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $proxy = @()
    if ((Get-RegValue $is 'ProxyEnable') -eq 1) { $proxy += (T 'scan.proxy.benutzer' (Get-RegValue $is 'ProxyServer')) }
    $pac = Get-RegValue $is 'AutoConfigURL'
    if ($pac) { $proxy += (T 'scan.proxy.skript' $pac) }
    $winhttp = (Invoke-Native "$script:Sys32\netsh.exe" @('winhttp', 'show', 'proxy')) -join ' '
    if ($winhttp -and $winhttp -notmatch 'Direkt|Direct') { $proxy += (T 'scan.proxy.winhttp' (($winhttp -replace '\s+', ' ').Trim())) }

    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $entries = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    Add-Table 'Hosts-Datei (aktive Einträge)' @($entries | Select-Object -First 200 | ForEach-Object { [pscustomobject]@{ Eintrag = $_ } })
    $blocked = @($entries | Where-Object { $_ -match 'update|defender|smartscreen|wdcp|wd\.microsoft|mp\.microsoft|delivery\.mp' })

    if ($blocked) { Add-Finding WARN (T 'scan.proxy.hostsSperrt' $blocked.Count) (T 'scan.proxy.hostsSperrtEmpf') }
    elseif ($proxy) { Add-Finding WARN (T 'scan.proxy.aktiv' ($proxy -join '; ')) (T 'scan.proxy.aktivEmpf') }
    elseif ($entries) { Add-Finding INFO (T 'scan.proxy.hostsEintraege' $entries.Count) }
    else { Add-Finding OK (T 'scan.proxy.ok') }
}

Invoke-Check 'DNS-Server' {
    $rows = foreach ($a in @(Get-NetAdapter | Where-Object Status -EQ 'Up')) {
        $d = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        [pscustomobject][ordered]@{ Adapter = $a.Name; DNS = (@($d.ServerAddresses) -join ', ') }
    }
    Add-Table 'DNS-Server' $rows
    Add-Finding INFO (($rows | ForEach-Object { "$($_.Adapter): $($_.DNS)" }) -join '; ') (T 'scan.dns.empf')
}

#endregion

#region Sicherheit: Konten & Anmeldung

Start-Section 'Sicherheit' 'Konten & Anmeldung'

Invoke-Check 'Lokale Benutzerkonten' {
    $users = @(Get-LocalUser)
    $rows = foreach ($u in $users) {
        [pscustomobject][ordered]@{
            Name            = $u.Name
            Aktiv           = $u.Enabled
            Typ             = [string]$u.PrincipalSource
            KennwortPflicht = $u.PasswordRequired
            KennwortGesetzt = Format-Date $u.PasswordLastSet
            LetzteAnmeldung = Format-Date $u.LastLogon
            SID             = $u.SID.Value
        }
    }
    Add-Table 'Lokale Benutzerkonten' $rows
    $crit = @(); $warn = @()
    $admin = $users | Where-Object { $_.SID.Value -like '*-500' }
    if ($admin.Enabled) { $warn += (T 'scan.konten.admin' $admin.Name) }
    $guest = $users | Where-Object { $_.SID.Value -like '*-501' }
    if ($guest.Enabled) { $crit += (T 'scan.konten.gast' $guest.Name) }
    $noPw = @($users | Where-Object { $_.Enabled -and -not $_.PasswordRequired -and [string]$_.PrincipalSource -ne 'MicrosoftAccount' -and $_.SID.Value -notlike '*-50?' })
    if ($noPw) { $warn += (T 'scan.konten.ohneKennwort' (($noPw | ForEach-Object Name) -join ', ')) }
    $enabled = @($users | Where-Object Enabled)
    if ($crit) { Add-Finding CRIT (($crit + $warn) -join '; ') (T 'scan.konten.gastEmpf') }
    elseif ($warn) { Add-Finding WARN ($warn -join '; ') (T 'scan.konten.adminEmpf') }
    else { Add-Finding OK (T 'scan.konten.ok' $enabled.Count (($enabled | ForEach-Object Name) -join ', ')) }
}

Invoke-Check 'Administratorgruppe' {
    try { $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object Name) }
    catch {
        $group = ([Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
        $members = @(([ADSI]"WinNT://$env:COMPUTERNAME/$group,group").Invoke('Members') | ForEach-Object { $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null) })
    }
    Add-Table 'Administratoren' @($members | ForEach-Object { [pscustomobject]@{ Mitglied = $_ } })
    $tokenGroups = (Invoke-Native "$script:Sys32\whoami.exe" @('/groups', '/fo', 'csv', '/nh')) -join "`n"
    $meIsAdmin = $tokenGroups -match '"S-1-5-32-544"'
    $value = T 'scan.admin.mitglieder' $members.Count ($members -join ', ')
    if ($members.Count -gt 2) { Add-Finding WARN $value (T 'scan.admin.zuviele') }
    elseif ($meIsAdmin) { Add-Finding INFO (T 'scan.admin.ichBinAdmin' $value $env:USERNAME) (T 'scan.admin.ichBinAdminEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Kennwort- und Sperrrichtlinie' -NeedsAdmin {
    $tmp = Join-Path $env:TEMP ('pc-check-secpol-{0}.inf' -f [guid]::NewGuid())
    $cfg = @{}
    try {
        Invoke-Native "$script:Sys32\secedit.exe" @('/export', '/cfg', $tmp, '/areas', 'SECURITYPOLICY', '/quiet') | Out-Null
        Get-Content -LiteralPath $tmp | ForEach-Object { if ($_ -match '^\s*([^=;\[]+?)\s*=\s*(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() } }
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    $keys = 'MinimumPasswordLength', 'PasswordComplexity', 'MaximumPasswordAge', 'PasswordHistorySize', 'LockoutBadCount', 'LockoutDuration', 'ResetLockoutCount', 'ClearTextPassword', 'LSAAnonymousNameLookup', 'EnableGuestAccount', 'EnableAdminAccount'
    Add-Table 'Lokale Sicherheitsrichtlinie' @($keys | ForEach-Object { [pscustomobject]@{ Einstellung = $_; Wert = $cfg[$_] } })
    $lockout = [int]$cfg['LockoutBadCount']
    $minLen = [int]$cfg['MinimumPasswordLength']
    if ($cfg['ClearTextPassword'] -eq '1') { Add-Finding CRIT (T 'scan.kennwort.klartext') (T 'scan.kennwort.klartextEmpf') }
    elseif ($lockout -eq 0) { Add-Finding WARN (T 'scan.kennwort.keineSperre' $minLen) (T 'scan.kennwort.keineSperreEmpf') }
    else { Add-Finding OK (T 'scan.kennwort.ok' $lockout ($cfg['LockoutDuration']) $minLen) }
}

Invoke-Check 'Automatische Anmeldung' {
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if (Get-RegValue $wl 'DefaultPassword') { Add-Finding CRIT (T 'scan.autologon.klartext') (T 'scan.autologon.klartextEmpf') }
    elseif ((Get-RegValue $wl 'AutoAdminLogon') -eq '1') { Add-Finding WARN (T 'scan.autologon.aktiv') (T 'scan.autologon.aktivEmpf') }
    else { Add-Finding OK (T 'scan.allg.aus') }
}

Invoke-Check 'Bildschirmsperre' {
    $d = 'HKCU:\Control Panel\Desktop'
    $inact = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'InactivityTimeoutSecs'
    $ssOn = (Get-RegValue $d 'ScreenSaveActive') -eq '1' -and (Get-RegValue $d 'ScreenSaverIsSecure') -eq '1' -and (Get-RegValue $d 'SCRNSAVE.EXE')
    $timeout = [int](Get-RegValue $d 'ScreenSaveTimeOut')
    $dynLock = (Get-RegValue 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' 'EnableGoodbye') -eq 1
    if ($inact -gt 0) { Add-Finding OK (T 'scan.sperre.richtlinie' ([int]($inact / 60))) }
    elseif ($ssOn) { Add-Finding OK (T 'scan.sperre.schoner' ([int]($timeout / 60))) }
    elseif ($dynLock) { Add-Finding OK (T 'scan.sperre.dynamisch') }
    else { Add-Finding INFO (T 'scan.sperre.keine') (T 'scan.sperre.keineEmpf') }
}

#endregion

#region Sicherheit: Systemhärtung

Start-Section 'Sicherheit' 'Systemhärtung'

Invoke-Check 'Benutzerkontensteuerung (UAC)' {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lua = Get-RegValue $k 'EnableLUA'
    $cpba = Get-RegValue $k 'ConsentPromptBehaviorAdmin'
    $sd = Get-RegValue $k 'PromptOnSecureDesktop'
    $apm = Get-RegValue $k 'TypeOfAdminApprovalMode'
    $levels = @{ 0 = (T 'scan.uac.ohneNachfrage'); 1 = (T 'scan.uac.kennwortSicher'); 2 = (T 'scan.uac.immer'); 3 = (T 'scan.uac.kennwort'); 4 = (T 'scan.uac.zustimmung'); 5 = (T 'scan.uac.standard') }
    if ($lua -eq 0) { Add-Finding CRIT (T 'scan.uac.aus') (T 'scan.uac.ausEmpf') }
    elseif ($cpba -eq 0) { Add-Finding CRIT (T 'scan.uac.ohneFrage') (T 'scan.uac.ohneFrageEmpf') }
    elseif ($sd -eq 0) { Add-Finding WARN (T 'scan.uac.nichtSicher') (T 'scan.uac.nichtSicherEmpf') }
    else { Add-Finding OK (T 'scan.uac.aktiv' ($levels[[int]$cpba]) $(if ($apm -eq 2) { T 'scan.uac.adminschutz' } else { '' })) }
}

Invoke-Check 'Kernisolierung (VBS / Speicherintegrität)' {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard
    $script:DeviceGuard = $dg
    $vbs = @{ 0 = (T 'scan.allg.ausKlein'); 1 = (T 'scan.kern.vbsKonfiguriert'); 2 = (T 'scan.kern.vbsLaeuft') }[[int]$dg.VirtualizationBasedSecurityStatus]
    $running = @($dg.SecurityServicesRunning)
    $hvci = $running -contains 2
    $mbec = @($dg.AvailableSecurityProperties) -contains 7
    $value = T 'scan.kern.wert' $vbs $(if ($hvci) { T 'scan.allg.anKlein' } else { T 'scan.allg.ausKlein' }) $(if ($mbec) { T 'scan.allg.vorhanden' } else { T 'scan.allg.fehlt' })
    if ($hvci) { Add-Finding OK $value }
    else { Add-Finding WARN $value (T 'scan.kern.empf') }
}

Invoke-Check 'LSA-Schutz' {
    $ppl = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL'
    if ($ppl -in 1, 2) { Add-Finding OK (T 'scan.lsa.an' $ppl) }
    else { Add-Finding WARN (T 'scan.allg.aus') (T 'scan.lsa.empf') }
}

Invoke-Check 'Treiber-Sperrliste und Smart App Control' {
    $bl = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable'
    $sac = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' 'VerifiedAndReputablePolicyState'
    $sacText = @{ 0 = (T 'scan.allg.ausKlein'); 1 = (T 'scan.allg.anKlein'); 2 = (T 'scan.sperrliste.evaluierung') }[[int]$sac]
    $value = T 'scan.sperrliste.wert' $(if ($bl -eq 0) { T 'scan.allg.ausKlein' } else { T 'scan.allg.anKlein' }) $sacText
    if ($bl -eq 0) { Add-Finding WARN $value (T 'scan.sperrliste.empf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'SmartScreen' {
    $exp = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled'
    $pol = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
    $edgePol = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'SmartScreenEnabled'
    $off = @()
    if ($exp -eq 'Off' -or $pol -eq 0) { $off += (T 'scan.smartscreen.appsDateien') }
    if ($edgePol -eq 0) { $off += (T 'scan.smartscreen.edge') }
    if ($off) { Add-Finding WARN (T 'scan.smartscreen.aus' ($off -join ', ')) (T 'scan.smartscreen.ausEmpf') }
    else { Add-Finding OK (T 'scan.smartscreen.ok') }
}

Invoke-Check 'Exploit-Schutz (systemweit)' {
    $m = Get-ProcessMitigation -System
    $vals = [ordered]@{ 'DEP' = $m.Dep.Enable; 'ASLR Bottom-up' = $m.Aslr.BottomUp; 'ASLR hohe Entropie' = $m.Aslr.HighEntropy; 'CFG' = $m.Cfg.Enable; 'SEHOP' = $m.SEHOP.Enable }
    $off = @($vals.Keys | Where-Object { "$($vals[$_])" -eq 'OFF' })
    if ($off) { Add-Finding WARN (T 'scan.exploit.aus' ($off -join ', ')) (T 'scan.exploit.ausEmpf') }
    else { Add-Finding OK (T 'scan.exploit.ok') }
}

Invoke-Check 'Spectre/Meltdown-Schutz' {
    $mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $o = Get-RegValue $mm 'FeatureSettingsOverride'
    $mask = Get-RegValue $mm 'FeatureSettingsOverrideMask'
    if ($null -eq $o) { Add-Finding OK (T 'scan.spectre.standard') }
    elseif (([int]$o -band 3) -ne 0) { Add-Finding CRIT (T 'scan.spectre.aus' $o) (T 'scan.spectre.ausEmpf') }
    else { Add-Finding INFO (T 'scan.spectre.angepasst' $o $mask) }
}

Invoke-Check 'CPU-Microcode' {
    $k = 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0'
    # REG_BINARY mit 8 Byte (Revision in den oberen 4) oder 4 Byte, je nach Windows-Version
    $fmt = {
        param($b)
        if ($b -is [byte[]] -and $b.Length -ge 8) { '0x{0:X}' -f [BitConverter]::ToUInt32($b, 4) }
        elseif ($b -is [byte[]] -and $b.Length -ge 4) { '0x{0:X}' -f [BitConverter]::ToUInt32($b, 0) }
        else { T 'scan.allg.unbekannt' }
    }
    $cur = & $fmt (Get-RegValue $k 'Update Revision')
    $prev = & $fmt (Get-RegValue $k 'Previous Update Revision')
    Add-Finding INFO (T 'scan.microcode.wert' $cur $prev) (T 'scan.microcode.empf')
}

Invoke-Check 'PowerShell-Sicherheit' {
    $lm = [string](Get-ExecutionPolicy -Scope LocalMachine)
    $cu = [string](Get-ExecutionPolicy -Scope CurrentUser)
    $sbl = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' 'EnableScriptBlockLogging'
    $value = T 'scan.ps.wert' $lm $cu $(if ($sbl -eq 1) { T 'scan.allg.anKlein' } else { T 'scan.allg.standard' })
    if ($lm -in 'Unrestricted', 'Bypass' -or $cu -in 'Unrestricted', 'Bypass') { Add-Finding WARN $value (T 'scan.ps.empf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Veraltete Anmeldeverfahren und Protokolle' {
    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $crit = @(); $warn = @()
    if ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential') -eq 1) { $crit += (T 'scan.altprot.wdigest') }
    $lm = Get-RegValue $lsa 'LmCompatibilityLevel'
    if ($null -ne $lm -and $lm -lt 3) { $warn += (T 'scan.altprot.lm' $lm) }
    if ((Get-RegValue $lsa 'NoLMHash') -eq 0) { $warn += (T 'scan.altprot.lmHash') }
    if ((Get-RegValue $lsa 'RestrictAnonymousSAM') -eq 0) { $warn += (T 'scan.altprot.anonym') }
    foreach ($proto in 'SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1') {
        foreach ($side in 'Client', 'Server') {
            $e = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$proto\$side" 'Enabled'
            if ($null -ne $e -and $e -ne 0) { $warn += (T 'scan.altprot.protokoll' $proto $side) }
        }
    }
    if ($crit) { Add-Finding CRIT (($crit + $warn) -join '; ') (T 'scan.altprot.critEmpf') }
    elseif ($warn) { Add-Finding WARN ($warn -join '; ') (T 'scan.altprot.warnEmpf') }
    else { Add-Finding OK (T 'scan.altprot.ok') }
}

Invoke-Check 'Optionale Windows-Features' -NeedsAdmin {
    $feat = @(Get-WindowsOptionalFeature -Online | Where-Object State -EQ 'Enabled' | Sort-Object FeatureName)
    $script:Features = @($feat | ForEach-Object FeatureName)
    Add-Table 'Aktivierte optionale Features' @($feat | ForEach-Object { [pscustomobject]@{ Feature = $_.FeatureName } })
    $risky = [ordered]@{
        'SMB1Protocol'                     = 'SMBv1'
        'MicrosoftWindowsPowerShellV2Root' = 'PowerShell 2.0'
        'TelnetClient'                     = (T 'scan.features.telnetClient')
        'TFTP'                             = (T 'scan.features.tftp')
        'SimpleTCP'                        = (T 'scan.features.simpleTcp')
        'IIS-WebServerRole'                = (T 'scan.features.iis')
        'Internet-Explorer-Optional-amd64' = 'Internet Explorer'
    }
    $found = @($risky.Keys | Where-Object { $_ -in $script:Features } | ForEach-Object { $risky[$_] })
    if ($found -contains 'SMBv1') { Add-Finding CRIT (T 'scan.features.aktiv' ($found -join ', ')) (T 'scan.features.critEmpf') }
    elseif ($found) { Add-Finding WARN (T 'scan.features.aktiv' ($found -join ', ')) (T 'scan.features.warnEmpf') }
    else { Add-Finding OK (T 'scan.features.ok' $feat.Count) }
}

Invoke-Check 'Entwicklermodus und sudo' {
    $dev = (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowDevelopmentWithoutDevLicense') -eq 1
    $sudo = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' 'Enabled'
    $sudoText = @{ 0 = (T 'scan.allg.ausKlein'); 1 = (T 'scan.dev.neuesFenster'); 2 = (T 'scan.dev.eingabeGesperrt'); 3 = (T 'scan.dev.inline') }[[int]$sudo]
    $value = T 'scan.dev.wert' $(if ($dev) { T 'scan.allg.anKlein' } else { T 'scan.allg.ausKlein' }) $sudoText
    if ($sudo -eq 3) { Add-Finding INFO $value (T 'scan.dev.inlineEmpf') }
    else { Add-Finding INFO $value }
}
Invoke-Check 'Systemdateien: Signaturen (Sigcheck)' -NeedsAdmin {
    $s = Get-SysSigcheck
    if ($null -eq $s) { return }
    $b = Get-SysSigcheckBewertung -System32 $s['system32'] -Treiber $s['treiber'] -Regeln $script:AkzeptanzRegeln
    Add-Table 'Unsignierte Systemdateien (Sigcheck)' @($b.Tabelle)
    if ($b.Status -eq 'ACK') {
        # Alle unsignierten Dateien sind je SHA256 akzeptiert: als WARN anlegen und gleich auf ACK setzen (wie die allgemeine Akzeptanz)
        Add-Finding WARN $b.Wert $b.Empfehlung
        $f = $script:Findings[$script:Findings.Count - 1]
        $f.Status = 'ACK'; $f.OriginalStatus = 'WARN'; $f.Note = $b.Note
    }
    else { Add-Finding $b.Status $b.Wert $b.Empfehlung }
}

#endregion

#region Sicherheit: Verschlüsselung & Firmware

Start-Section 'Sicherheit' 'Verschlüsselung & Firmware'

Invoke-Check 'Secure Boot' {
    $fw = $env:firmware_type
    $sb = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
    if ($script:IsAdmin) { try { $sb = [int](Confirm-SecureBootUEFI) } catch {} }
    $script:SecureBoot = ($sb -eq 1)
    if ($fw -and $fw -ne 'UEFI') { Add-Finding WARN (T 'scan.boot.firmware' $fw) (T 'scan.boot.firmwareEmpf') }
    elseif ($sb -eq 1) { Add-Finding OK (T 'scan.boot.ok') }
    else { Add-Finding WARN (T 'scan.boot.aus') (T 'scan.boot.ausEmpf') }
}

Invoke-Check 'Secure-Boot-Zertifikate 2023' -NeedsAdmin {
    if (-not $script:SecureBoot) { Add-Finding INFO (T 'scan.cert.nichtRelevant'); return }
    $db = [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name db).Bytes)
    $kek = [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name KEK).Bytes)
    $has = [ordered]@{
        'Windows UEFI CA 2023 (db)'               = $db -match 'Windows UEFI CA 2023'
        'Microsoft UEFI CA 2023 (db)'             = $db -match 'Microsoft UEFI CA 2023'
        'Microsoft Corporation KEK 2K CA 2023 (KEK)' = $kek -match 'KEK 2K CA 2023'
    }
    $status = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' 'UEFICA2023Status'
    Add-Table 'Secure-Boot-Zertifikate' @($has.Keys | ForEach-Object { [pscustomobject]@{ Zertifikat = $_; Vorhanden = $has[$_] } })
    $missing = @($has.Keys | Where-Object { -not $has[$_] })
    $value = $(if ($missing) { T 'scan.cert.fehlt' ($missing -join ', ') } else { T 'scan.cert.alle' }) + $(if ($status) { T 'scan.cert.status' $status } else { '' })
    if ($missing) { Add-Finding WARN $value (T 'scan.cert.empf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'TPM' -NeedsAdmin {
    $t = Get-Tpm
    $spec = [string](Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm -ErrorAction SilentlyContinue).SpecVersion
    $value = T 'scan.tpm.wert' $t.TpmPresent $t.TpmReady (($spec -split ',')[0]) $t.ManufacturerIdTxt
    if (-not $t.TpmPresent) { Add-Finding WARN (T 'scan.tpm.keins') (T 'scan.tpm.keinsEmpf') }
    elseif (-not $t.TpmReady) { Add-Finding WARN $value (T 'scan.tpm.nichtBereit') }
    else { Add-Finding OK $value }
}

Invoke-Check 'BitLocker' {
    $osOn = $false; $recovery = $true
    if ($script:IsAdmin) {
        $vols = @(Get-BitLockerVolume)
        $rows = foreach ($v in $vols) {
            [pscustomobject][ordered]@{
                Laufwerk    = $v.MountPoint
                Typ         = [string]$v.VolumeType
                Status      = [string]$v.VolumeStatus
                Schutz      = [string]$v.ProtectionStatus
                Verfahren   = [string]$v.EncryptionMethod
                Schutzarten = ((@($v.KeyProtector) | ForEach-Object { [string]$_.KeyProtectorType }) -join ', ')
            }
        }
        Add-Table 'BitLocker' $rows
        $os = $rows | Where-Object Typ -EQ 'OperatingSystem' | Select-Object -First 1
        $osOn = $os.Schutz -eq 'On'
        $recovery = $os.Schutzarten -match 'RecoveryPassword'
    }
    else {
        $v = (New-Object -ComObject Shell.Application).NameSpace("$($env:SystemDrive)\").Self.ExtendedProperty('System.Volume.BitLockerProtection')
        $osOn = $v -in 1, 3, 5
    }
    if ($osOn -and -not $recovery) { Add-Finding WARN (T 'scan.bitlocker.ohneRecovery') (T 'scan.bitlocker.ohneRecoveryEmpf') }
    elseif ($osOn) { Add-Finding OK (T 'scan.bitlocker.ok') }
    else { Add-Finding WARN (T 'scan.bitlocker.nein') (T 'scan.bitlocker.neinEmpf') }
}

Invoke-Check 'BIOS/UEFI-Version' {
    $b = Get-CimInstance Win32_BIOS
    $bb = Get-CimInstance Win32_BaseBoard
    $age = ((Get-Date) - $b.ReleaseDate).Days
    $value = T 'scan.bios.wert' $bb.Manufacturer $bb.Product $b.SMBIOSBIOSVersion ((Get-Date $b.ReleaseDate).ToString('yyyy-MM-dd'))
    if ($age -gt 3 * 365) { Add-Finding INFO $value (T 'scan.bios.empf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Wiederherstellung' -NeedsAdmin {
    $re = (Invoke-Native "$script:Sys32\reagentc.exe" @('/info')) -join "`n"
    $reOn = $re -cmatch '\b(Enabled|Aktiviert)\b'
    $rp = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
    $last = $rp | Sort-Object SequenceNumber | Select-Object -Last 1
    $lastText = if ($last) { ' ' + (T 'scan.wh.letzter' ([Management.ManagementDateTimeConverter]::ToDateTime($last.CreationTime).ToString('yyyy-MM-dd'))) } else { '' }
    # Computerschutz an? (wie die Aktion system.wiederherstellung). Fehlende Punkte allein heißen NICHT „aus“:
    # Windows löscht Punkte auch selbst, wenn der Speicher dafür zu klein ist (volsnap-Ereignis 33).
    $sr = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $interval = (Get-ItemProperty -LiteralPath $sr -Name RPSessionInterval -ErrorAction SilentlyContinue).RPSessionInterval
    $disSR = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name DisableSR -ErrorAction SilentlyContinue).DisableSR
    $schutzAn = ($interval -eq 1) -and ($disSR -ne 1)
    # Speichergrenze der Schattenkopien auf C: (nur mit Adminrechten lesbar); UInt64.MaxValue = unbegrenzt
    $maxText = ''; $klein = $false
    try {
        $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='$($env:SystemDrive)'" -ErrorAction Stop
        $ss = @(Get-CimInstance Win32_ShadowStorage -ErrorAction Stop | Where-Object { $_.Volume.DeviceID -eq $vol.DeviceID }) | Select-Object -First 1
        if ($ss) {
            if ([uint64]$ss.MaxSpace -eq [uint64]::MaxValue) { $maxText = (T 'scan.wh.unbegrenzt') }
            else {
                $pct = [Math]::Round(100 * [double]$ss.MaxSpace / [double]$vol.Capacity, 1)
                $maxText = '{0} ({1} %)' -f (Format-Size ([double]$ss.MaxSpace)), $pct
                # Ein Punkt belegt oft 1–4 GB: unter 5 % bzw. 8 GB verdrängen neue Punkte die alten schnell.
                # Point-in-time restore erlaubt höchstens 50 GB (51200 MB): ab 49 GB gilt der Speicher auch unter 5 % als ausreichend.
                $klein = (($pct -lt 5) -and ([double]$ss.MaxSpace -lt 49GB)) -or ([double]$ss.MaxSpace -lt 8GB)
            }
        }
    }
    catch { }
    $geloescht = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'volsnap'; Id = 33; StartTime = $script:Since } -ErrorAction SilentlyContinue).Count
    $value = T 'scan.wh.wert' $(if ($reOn) { T 'scan.allg.anKlein' } else { T 'scan.allg.ausKlein' }) $env:SystemDrive $(if ($schutzAn) { T 'scan.allg.anKlein' } else { T 'scan.allg.ausKlein' }) `
        $(if ($maxText) { T 'scan.wh.speicherMax' $maxText } else { '' }) $rp.Count $lastText `
        $(if ($geloescht) { T 'scan.wh.geloescht' $geloescht $EventDays } else { '' })
    if (-not $reOn) { Add-Finding WARN $value (T 'scan.wh.reAus') }
    elseif (-not $schutzAn) { Add-Finding INFO $value (T 'scan.wh.schutzAus') }
    elseif ($klein) {
        # Point-in-time restore (Windows 11) setzt die VSS-Grenze bei jedem Start auf seine eigene Einstellung (Standard 2 %)
        $pitr = $null
        try { $pitr = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Setup\' -TaskName 'PITRTask' -ErrorAction Stop } catch { }
        if ($pitr -and ([string]$pitr.State -ne 'Disabled')) {
            Add-Finding WARN (T 'scan.wh.zuKleinPitr' $value) (T 'scan.wh.zuKleinPitrEmpf')
        }
        else { Add-Finding WARN (T 'scan.wh.zuKlein' $value) (T 'scan.wh.zuKleinEmpf') }
    }
    elseif (-not $rp) { Add-Finding OK (T 'scan.wh.okMorpheus' $value) }
    else { Add-Finding OK $value }
}

Invoke-Check 'Datensicherung' {
    if (-not $script:SicherungLib) { Add-Finding SKIP (T 'scan.allg.dateiFehlt' 'gui\lib\Sicherung.ps1'); return }
    # Get-MorpheusSicherung ermittelt die Adminrechte selbst und reicht sie an das Systemabbild weiter
    $e = @(Get-MorpheusSicherung)
    $rows = foreach ($x in $e) {
        $letzte = ''
        if ($x.letzteSicherung) { try { $letzte = ([datetime]$x.letzteSicherung).ToString('yyyy-MM-dd HH:mm') } catch { $letzte = '' } }
        $ziel = [string]$x.ziel
        if ($x.PSObject.Properties['ordner'] -and @($x.ordner).Count) { $ziel = (@($x.ordner) -join ', ') }
        [pscustomobject][ordered]@{ Art = [string]$x.art; Gefunden = [bool]$x.gefunden; Aktiv = [bool]$x.aktiv; Ziel = $ziel; LetzteSicherung = $letzte; Hinweis = [string]$x.hinweis }
    }
    Add-Table 'Datensicherung' @($rows)
    $b = Get-MorpheusSicherungBewertung -Eintraege $e
    Add-Finding $b.status $b.wert $b.empfehlung
}

#endregion

#region Sicherheit: Fernzugriff & Dienste

Start-Section 'Sicherheit' 'Fernzugriff & Dienste'

Invoke-Check 'Remotedesktop' {
    $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $deny = Get-RegValue $ts 'fDenyTSConnections'
    $nla = Get-RegValue "$ts\WinStations\RDP-Tcp" 'UserAuthentication'
    $port = Get-RegValue "$ts\WinStations\RDP-Tcp" 'PortNumber'
    # Eine Gruppenrichtlinie hat Vorrang vor der Einstellung in den Systemeigenschaften
    $ra = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' 'fAllowToGetHelp'
    if ($null -eq $ra) { $ra = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' }
    if ($deny -eq 0 -and $nla -ne 1) { Add-Finding CRIT (T 'scan.rdp.ohneNla' $port) (T 'scan.rdp.ohneNlaEmpf') }
    elseif ($deny -eq 0) { Add-Finding WARN (T 'scan.rdp.an' $port) (T 'scan.rdp.anEmpf') }
    else { Add-Finding OK (T 'scan.allg.aus') }
    if ($ra -eq 1) { Add-Finding INFO (T 'scan.rdp.hilfeErlaubt') (T 'scan.rdp.hilfeErlaubtEmpf') -Check 'Remoteunterstützung' }
    else { Add-Finding OK (T 'scan.rdp.hilfeNicht') -Check 'Remoteunterstützung' }
}

Invoke-Check 'Fernzugriffsdienste und -programme' {
    $svcCheck = [ordered]@{ WinRM = 'WinRM'; sshd = 'OpenSSH-Server'; RemoteRegistry = (T 'scan.fern.remoteregistrierung'); TlntSvr = (T 'scan.fern.telnetServer'); SNMP = 'SNMP'; FTPSVC = (T 'scan.fern.ftpServer'); W3SVC = (T 'scan.features.iis') }
    $active = foreach ($n in $svcCheck.Keys) {
        $s = $script:Services | Where-Object Name -EQ $n
        if ($s -and ($s.State -eq 'Running' -or $s.StartMode -eq 'Auto')) { "$($svcCheck[$n]) ($($s.State), $($s.StartMode))" }
    }
    $toolPattern = 'TeamViewer|AnyDesk|RustDesk|Parsec|Splashtop|VNC|LogMeIn|ScreenConnect|ConnectWise|Radmin|Ammyy|Supremo|NoMachine|nxservice|chromoting|remoting_host|Sunshine|Zoho Assist|DWService|MeshAgent|HopToDesk|rutserv|Dameware|BeyondTrust|Bomgar|GoToAssist|Atera|NinjaRMM|Kaseya|Tailscale|ZeroTier|ngrok'
    $tools = @($script:Services | Where-Object { $_.Name -match $toolPattern -or $_.DisplayName -match $toolPattern -or $_.PathName -match $toolPattern } | ForEach-Object { "$($_.DisplayName) ($($_.State))" })
    $tools += @(Get-Process | Where-Object { $_.ProcessName -match $toolPattern } | ForEach-Object { T 'scan.fern.prozess' $_.ProcessName } | Select-Object -Unique)
    $all = @($active) + $tools
    if ($all) { Add-Finding WARN (T 'scan.fern.gefunden' ($all -join '; ')) (T 'scan.fern.gefundenEmpf') }
    else { Add-Finding OK (T 'scan.fern.ok') }
}

Invoke-Check 'Dienste von Drittanbietern' {
    $rows = foreach ($s in $script:Services) {
        $exe = Get-ExePath $s.PathName
        if (-not $exe) { continue }
        $sig = Get-FileSignatureInfo $exe
        if ($sig.Signer -like 'Microsoft*') { continue }
        [pscustomobject][ordered]@{
            Name      = $s.Name
            Anzeige   = $s.DisplayName
            Status    = $s.State
            Start     = $s.StartMode
            Konto     = $s.StartName
            Signatur  = $sig.Status
            Signierer = $sig.Signer
            Pfad      = $exe
        }
    }
    $rows = @($rows)
    $script:ThirdPartyServices = $rows
    Add-Table 'Dienste von Drittanbietern' $rows
    $bad = @($rows | Where-Object { $_.Signatur -notin 'Valid', 'Datei fehlt' })
    $auto = @($rows | Where-Object Start -EQ 'Auto')
    if ($bad) { Add-Finding WARN (T 'scan.dienste.ohneSignatur' (($bad | ForEach-Object { "$($_.Name) ($($_.Signatur))" }) -join ', ')) (T 'scan.dienste.ohneSignaturEmpf') }
    else { Add-Finding OK (T 'scan.dienste.ok' $rows.Count $auto.Count) }
}

Invoke-Check 'Dienstpfade und Berechtigungen' {
    $unquoted = foreach ($s in $script:Services) {
        $p = [string]$s.PathName
        if (-not $p -or $p -match '^\s*"' -or $p -notmatch '^\s*([A-Za-z]:\\[^"]*?\.exe)') { continue }
        $exe = $Matches[1]
        if ($exe -match ' ' -and $exe -notmatch '^[A-Za-z]:\\Windows\\') { "$($s.Name): $p" }
    }
    $weakSids = 'S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4'
    # WriteData/AddFile, AppendData/AddSubdirectory, ChangePermissions, TakeOwnership, GENERIC_WRITE, GENERIC_ALL
    $writeMask = 0x2 -bor 0x4 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000
    $weak = foreach ($s in $script:ThirdPartyServices) {
        foreach ($target in @($s.Pfad, (Split-Path -Parent $s.Pfad))) {
            if (-not $target -or -not (Test-Path -LiteralPath $target)) { continue }
            try { $acl = Get-Acl -LiteralPath $target } catch { continue }
            foreach ($ace in $acl.Access) {
                if ([string]$ace.AccessControlType -ne 'Allow') { continue }
                if ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
                try { $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
                if ($sid -in $weakSids -and ([int64]$ace.FileSystemRights -band $writeMask)) {
                    "$($s.Name): $target ($($ace.IdentityReference.Value))"
                    break
                }
            }
        }
    }
    $weak = @($weak | Select-Object -Unique)
    Add-Table 'Dienste: ungeschützte Pfade und schreibbare Ordner' @(@($unquoted | ForEach-Object { [pscustomobject]@{ Art = (T 'scan.dienstpfade.ohneAnfuehrung'); Eintrag = $_ } }) + @($weak | ForEach-Object { [pscustomobject]@{ Art = (T 'scan.dienstpfade.schreibbarArt'); Eintrag = $_ } }))
    if ($weak) { Add-Finding WARN (T 'scan.dienstpfade.schreibbar' $weak.Count (($weak | Select-Object -First 5) -join '; ')) (T 'scan.dienstpfade.schreibbarEmpf') }
    elseif ($unquoted) { Add-Finding WARN (T 'scan.dienstpfade.ohneAnfuehrungWarn' ($unquoted -join '; ')) (T 'scan.dienstpfade.ohneAnfuehrungEmpf') }
    else { Add-Finding OK (T 'scan.dienstpfade.ok') }
}

Invoke-Check 'Treiber: bekannt anfällige und unsignierte' {
    $vulnerable = 'gdrv.sys', 'gdrv2.sys', 'gdrv3.sys', 'RTCore64.sys', 'RTCore32.sys', 'WinRing0x64.sys', 'WinRing0.sys', 'AsIO.sys', 'AsIO2.sys', 'AsIO3.sys', 'AsUpIO.sys',
    'AsrDrv10.sys', 'AsrDrv101.sys', 'AsrDrv103.sys', 'NTIOLib_X64.sys', 'NTIOLib.sys', 'EneIo64.sys', 'EneTechIo64.sys', 'cpuz141_x64.sys', 'iqvw64e.sys', 'dbutil_2_3.sys',
    'DBUtilDrv2.sys', 'Capcom.sys', 'atillk64.sys', 'HwRwDrv.sys', 'PhyMemx64.sys', 'speedfan.sys', 'inpoutx64.sys', 'GLCKIO2.sys', 'BS_RCIO64.sys', 'MsIo64.sys',
    'AODDriver2.sys', 'mhyprot2.sys', 'ALSysIO64.sys', 'ATSZIO64.sys', 'TfSysMon.sys', 'zam64.sys', 'LHA.sys',
    'GVCIDrv64.sys', 'GVCIDrv.sys', 'GPCIDrv64.sys', 'GPCIDrv.sys'
    $drv = @(Get-CimInstance Win32_SystemDriver); $trGeladen = T 'scan.treiber.geladen'; $trVorhanden = T 'scan.treiber.vorhanden'; $trEntfernt = T 'scan.treiber.entferntStatus'
    $driverDir = Join-Path $env:SystemRoot 'System32\drivers'
    # Version mit ausgeben, damit eine gepatchte Version gezielt in accepted.psd1 akzeptiert werden kann.
    $fileVersion = { param($p) try { (([string](Get-Item -LiteralPath $p -ErrorAction Stop).VersionInfo.FileVersion) -split ' ')[0] } catch { '' } }
    $found = foreach ($n in $vulnerable) {
        $svc = @($drv | Where-Object { [IO.Path]::GetFileName([string]$_.PathName) -ieq $n })
        $file = Test-Path -LiteralPath (Join-Path $driverDir $n)
        if ($svc -or $file) {
            $path = $(if ($svc) { (Get-ExePath $svc[0].PathName) } else { Join-Path $driverDir $n })
            [pscustomobject][ordered]@{
                Treiber = $n
                Version = & $fileVersion $path
                Status  = $(if ($svc | Where-Object State -EQ 'Running') { $trGeladen } else { $trVorhanden })
                Dienst  = (($svc | ForEach-Object Name) -join ', ')
                Pfad    = $path
            }
        }
    }
    $found = @($found)
    # Manche Tools installieren ihren Treiber nur kurz und entfernen ihn wieder: über die Dienst-Installationsereignisse nachweisen.
    $transient = @(Get-RecentEvents @{ LogName = 'System'; Id = 7045; ProviderName = 'Service Control Manager' } -Max 500 | ForEach-Object {
            $img = Get-ExePath (Get-EventData $_)['ImagePath']
            $leaf = try { [IO.Path]::GetFileName($img) } catch { '' }
            if ($leaf -and $leaf -in $vulnerable -and $leaf -notin $found.Treiber) { [pscustomobject]@{ Treiber = $leaf; Pfad = $img } }
        } | Group-Object Treiber | ForEach-Object {
            $path = $_.Group[0].Pfad
            $exists = Test-Path -LiteralPath $path
            [pscustomobject][ordered]@{
                Treiber = $_.Name
                Version = & $fileVersion $path
                Status  = $(if ($exists) { $trGeladen } else { $trEntfernt })
                Dienst  = (T 'scan.treiber.installiert' $_.Count $EventDays $(if (-not $exists) { T 'scan.treiber.geloescht' } else { '' }))
                Pfad    = $path
            }
        })
    $found = @($found) + $transient
    $third = foreach ($d in ($drv | Where-Object State -EQ 'Running')) {
        $p = Get-ExePath $d.PathName
        # Ohne ImagePath lädt Windows den Treiber aus dem Standardpfad (z. B. UCPD, UnionFS)
        if (-not $p) { $p = Join-Path $env:SystemRoot "System32\drivers\$($d.Name).sys" }
        $sig = Get-FileSignatureInfo $p
        if ($sig.Signer -like 'Microsoft*' -and $sig.Status -eq 'Valid') { continue }
        [pscustomobject][ordered]@{ Name = $d.Name; Anzeige = $d.DisplayName; Signatur = $sig.Status; Signierer = $sig.Signer; Hersteller = $sig.Company; Pfad = $p }
    }
    $third = @($third)
    Add-Table 'Treiber: bekannt anfällige' $found
    Add-Table 'Treiber: geladene Drittanbieter-Treiber' $third
    $unsigned = @($third | Where-Object { $_.Signatur -notin 'Valid', 'Datei fehlt' })
    $loaded = @($found | Where-Object Status -EQ $trGeladen)
    $rest = @($found | Where-Object Status -EQ $trVorhanden | ForEach-Object { "$($_.Treiber) ($($_.Status))" })
    # Nur kurz installierte und wieder gelöschte Treiber sind kein Befund mehr, nur eine Spur im Protokoll
    $gone = @($found | Where-Object Status -EQ $trEntfernt | ForEach-Object Treiber)
    $goneText = if ($gone) { T 'scan.treiber.frueher' ($gone -join ', ') } else { '' }
    if ($loaded) { Add-Finding WARN (T 'scan.treiber.geladenMeldung' (($loaded | ForEach-Object { "$($_.Treiber) $($_.Version) ($($_.Dienst))" }) -join ', ') $(if ($rest) { T 'scan.treiber.ausserdem' ($rest -join ', ') } else { '' })) (T 'scan.treiber.geladenEmpf') }
    elseif ($rest) { Add-Finding INFO (T 'scan.treiber.nichtGeladen' ($rest -join ', ') $goneText) (T 'scan.treiber.nichtGeladenEmpf') }
    elseif ($unsigned) { Add-Finding WARN (T 'scan.treiber.unsigniert' (($unsigned | ForEach-Object Name) -join ', ') $goneText) (T 'scan.treiber.unsigniertEmpf') }
    else { Add-Finding OK (T 'scan.treiber.ok' $third.Count $goneText) }
}

#endregion

#region Sicherheit: Autostart & Persistenz

Start-Section 'Sicherheit' 'Autostart & Persistenz'

Invoke-Check 'Autostart-Einträge' {
    $runKeys = @(
        @{ Ort = 'HKLM Run'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        @{ Ort = (T 'scan.autostart.hklmRun32'); Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
        @{ Ort = 'HKCU Run'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        @{ Ort = 'HKLM RunOnce'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = $null }
        @{ Ort = 'HKCU RunOnce'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = $null }
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $isEnabled = {
        param($ApprovedKey, $Name)
        if (-not $ApprovedKey) { return $true }
        $b = Get-RegValue $ApprovedKey $Name
        -not ($b -is [byte[]] -and $b.Length -gt 0 -and ($b[0] % 2) -eq 1)
    }
    foreach ($rk in $runKeys) {
        if (-not (Test-Path $rk.Path)) { continue }
        $key = Get-Item -LiteralPath $rk.Path
        foreach ($n in $key.GetValueNames()) {
            if (-not $n) { continue }
            $cmd = [string]$key.GetValue($n)
            $sig = Get-FileSignatureInfo (Get-ExePath $cmd)
            $rows.Add([pscustomobject][ordered]@{ Ort = $rk.Ort; Name = $n; Aktiv = (& $isEnabled $rk.Approved $n); Signatur = $sig.Status; Signierer = $sig.Signer; Befehl = $cmd })
        }
    }
    $shell = New-Object -ComObject WScript.Shell
    $folders = @(
        @{ Ort = (T 'scan.autostart.ordnerBenutzer'); Path = [Environment]::GetFolderPath('Startup'); Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
        @{ Ort = (T 'scan.autostart.ordnerAlle'); Path = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    )
    foreach ($f in $folders) {
        foreach ($file in @(Get-ChildItem -LiteralPath $f.Path -File -Force -ErrorAction SilentlyContinue | Where-Object Name -NE 'desktop.ini')) {
            $target = $file.FullName
            if ($file.Extension -eq '.lnk') { try { $target = $shell.CreateShortcut($file.FullName).TargetPath } catch {} }
            $sig = Get-FileSignatureInfo $target
            $rows.Add([pscustomobject][ordered]@{ Ort = $f.Ort; Name = $file.Name; Aktiv = (& $isEnabled $f.Approved $file.Name); Signatur = $sig.Status; Signierer = $sig.Signer; Befehl = $target })
        }
    }
    $script:AutostartRows = $rows.ToArray()
    Add-Table 'Autostart-Einträge' $rows
    $sus = @($rows | Where-Object { $_.Aktiv -and $_.Signatur -notin 'Valid', 'Datei fehlt' -and (Test-UserWritablePath $_.Befehl) })
    $unsigned = @($rows | Where-Object { $_.Aktiv -and $_.Signatur -notin 'Valid', 'Datei fehlt' })
    $activeCount = @($rows | Where-Object Aktiv).Count
    if ($sus) { Add-Finding WARN (T 'scan.autostart.unsigniertBenutzer' (($sus | ForEach-Object Name) -join ', ')) (T 'scan.autostart.unsigniertBenutzerEmpf') }
    elseif ($unsigned) { Add-Finding INFO (T 'scan.autostart.info' $activeCount (($unsigned | ForEach-Object Name) -join ', ')) (T 'scan.autostart.infoEmpf') }
    else { Add-Finding OK (T 'scan.autostart.ok' $activeCount) }
}

Invoke-Check 'Autostarts: Signaturen (Autoruns)' -NeedsAdmin {
    $e = Get-SysAutoruns
    if ($null -eq $e) { return }
    $aufgaben = Get-SysAufgaben
    Add-Table 'Autostarts (Autoruns, ohne Microsoft)' @(Get-MorpheusAutorunsTabelle -Eintraege $e -Aufgaben $aufgaben)
    $b = Get-MorpheusAutorunsSignaturBefund -Eintraege $e -Aufgaben $aufgaben
    Add-Finding $b.status $b.wert $b.empfehlung
}

Invoke-Check 'Autostarts: beschreibbare Pfade (Autoruns)' -NeedsAdmin {
    # Nicht vertrauenswürdiges Werkzeug nur einmal als Warnung zählen (bei der Signatur-Prüfung)
    if ($script:Autoruns -and $script:Autoruns.nichtVertrauenswuerdig) { Add-Finding SKIP (T 'scan.autoruns.nichtAusgefuehrt'); return }
    $e = Get-SysAutoruns
    if ($null -eq $e) { return }
    $b = Get-MorpheusAutorunsPfadBefund -Eintraege $e -Aufgaben (Get-SysAufgaben)
    Add-Finding $b.status $b.wert $b.empfehlung
}
Invoke-Check 'Systemnahe Autostarts (Winlogon, IFEO, AppInit)' {
    $issues = @()
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $shellValue = Get-RegValue $wl 'Shell'
    if ($shellValue -and $shellValue -notmatch '^\s*explorer\.exe\s*$') { $issues += "Winlogon Shell = $shellValue" }
    $ui = [string](Get-RegValue $wl 'Userinit')
    if ($ui -and $ui.TrimEnd(', ') -notmatch '^[A-Za-z]:\\Windows\\system32\\userinit\.exe$') { $issues += "Winlogon Userinit = $ui" }
    $hkcuShell = Get-RegValue 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' 'Shell'
    if ($hkcuShell) { $issues += (T 'scan.systemnah.benutzerShell' $hkcuShell) }
    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    foreach ($k in @(Get-ChildItem -LiteralPath $ifeo -ErrorAction SilentlyContinue)) {
        $dbg = $k.GetValue('Debugger')
        if ($dbg) { $issues += (T 'scan.systemnah.debugger' ($k.PSChildName) $dbg) }
    }
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Windows') {
        $dll = Get-RegValue $k 'AppInit_DLLs'
        if ($dll -and (Get-RegValue $k 'LoadAppInit_DLLs') -eq 1) { $issues += "AppInit_DLLs = $dll" }
    }
    $boot = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'BootExecute') -join ' '
    if ($boot -and $boot -notmatch '^\s*autocheck autochk \*\s*$') { $issues += "BootExecute = $boot" }
    if ($issues) { Add-Finding WARN ($issues -join '; ') (T 'scan.systemnah.empf') }
    else { Add-Finding OK (T 'scan.systemnah.ok') }
}

Invoke-Check 'Geplante Aufgaben' {
    $tasks = @(Get-ScheduledTask)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($t in $tasks) {
        $isMs = $t.TaskPath -like '\Microsoft\*'
        foreach ($a in @($t.Actions)) {
            $exeRaw = (Expand-MorpheusUmgebung ([string]$a.Execute)).Trim().Trim('"')
            $arg = [string]$a.Arguments
            if (-not $exeRaw) {
                if (-not $isMs) { $rows.Add([pscustomobject][ordered]@{ Aufgabe = "$($t.TaskPath)$($t.TaskName)"; Status = [string]$t.State; Konto = $t.Principal.UserId; Admin = ([string]$t.Principal.RunLevel -eq 'Highest'); Signierer = ''; Auffaellig = ''; Befehl = (T 'scan.aufgaben.comHandler' ($a.ClassId)) }) }
                continue
            }
            $exe = Get-ExePath "`"$exeRaw`""
            $userPath = Test-UserWritablePath $exe
            if ($isMs -and -not $userPath) { continue }
            $sig = Get-FileSignatureInfo $exe
            $flags = @()
            if ($isMs -and $userPath) { $flags += (T 'scan.aufgaben.msOrdnerBenutzer') }
            elseif ($userPath -and $sig.Status -ne 'Valid') { $flags += (T 'scan.aufgaben.unsigniertBenutzer') }
            if ("$exeRaw $arg" -match '(?i)-enc(odedcommand)?\s|frombase64string|downloadstring|downloadfile|invoke-webrequest|\biwr\b|\biex\b|invoke-expression|-w(indowstyle)?\s+h(idden)?\b|mshta|regsvr32.+/i:http|bitsadmin|certutil.+-urlcache') { $flags += (T 'scan.aufgaben.verdaechtig') }
            $rows.Add([pscustomobject][ordered]@{
                    Aufgabe    = "$($t.TaskPath)$($t.TaskName)"
                    Status     = [string]$t.State
                    Konto      = $t.Principal.UserId
                    Admin      = ([string]$t.Principal.RunLevel -eq 'Highest')
                    Signierer  = $sig.Signer
                    Auffaellig = ($flags -join ', ')
                    Befehl     = ("$exe $arg").Trim()
                })
        }
    }
    Add-Table 'Geplante Aufgaben (Drittanbieter und auffällige)' $rows
    $sus = @($rows | Where-Object { $_.Auffaellig -and $_.Status -ne 'Disabled' })
    if ($sus) { Add-Finding WARN (T 'scan.aufgaben.warn' $sus.Count (($sus | Select-Object -First 5 | ForEach-Object { "$($_.Aufgabe) ($($_.Auffaellig))" }) -join '; ')) (T 'scan.aufgaben.warnEmpf') }
    else { Add-Finding OK (T 'scan.aufgaben.ok' $rows.Count) }
}

Invoke-Check 'WMI-Ereignisabonnements' -NeedsAdmin {
    $cons = @(Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer -ErrorAction SilentlyContinue)
    $rows = foreach ($c in $cons) {
        [pscustomobject][ordered]@{ Name = $c.Name; Typ = $c.CimClass.CimClassName; Inhalt = (@($c.CommandLineTemplate, $c.ScriptText, $c.ExecutablePath) | Where-Object { $_ } | Select-Object -First 1) }
    }
    Add-Table 'WMI-Ereignisabonnements' $rows
    $sus = @($rows | Where-Object { $_.Typ -in 'CommandLineEventConsumer', 'ActiveScriptEventConsumer' })
    if ($sus) { Add-Finding WARN (T 'scan.wmi.warn' (($sus | ForEach-Object Name) -join ', ')) (T 'scan.wmi.warnEmpf') }
    else { Add-Finding OK (T 'scan.wmi.ok' $cons.Count) }
}

Invoke-Check 'Laufende Programme (Signatur und Ort)' {
    # Path ist eine Skript-Eigenschaft und wird erst beim Zugriff gelesen: einmal festhalten, sonst fehlt er bei kurzlebigen Prozessen.
    $procs = @(Get-Process | ForEach-Object { [pscustomobject]@{ ProcessName = $_.ProcessName; Path = $_.Path } } | Where-Object Path | Group-Object Path | ForEach-Object { $_.Group[0] })
    $rows = foreach ($p in $procs) {
        # Store-Apps sind über ihr Paket signiert, nicht per Authenticode an der einzelnen Datei.
        if ($p.Path -like "$env:SystemRoot\*" -or $p.Path -like "$env:ProgramFiles\WindowsApps\*") { continue }
        $sig = Get-FileSignatureInfo $p.Path
        if ($sig.Status -eq 'Valid') { continue }
        [pscustomobject][ordered]@{ Prozess = $p.ProcessName; Signatur = $sig.Status; Hersteller = $sig.Company; Benutzerordner = (Test-UserWritablePath $p.Path); Pfad = $p.Path }
    }
    $rows = @($rows)
    Add-Table 'Laufende Programme ohne gültige Signatur' $rows
    $sus = @($rows | Where-Object Benutzerordner)
    if ($sus) { Add-Finding WARN (T 'scan.laufend.warn' (($sus | ForEach-Object Prozess | Select-Object -Unique) -join ', ')) (T 'scan.laufend.warnEmpf') }
    elseif ($rows) { Add-Finding INFO (T 'scan.laufend.info' (($rows | ForEach-Object Prozess | Select-Object -Unique) -join ', ')) (T 'scan.laufend.infoEmpf') }
    else { Add-Finding OK (T 'scan.laufend.ok' $procs.Count) }
}

Invoke-Check 'Browser-Erweiterungen' {
    $rows = New-Object System.Collections.Generic.List[object]
    $chromium = [ordered]@{
        'Chrome'  = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        'Edge'    = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
        'Brave'   = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
        'Vivaldi' = "$env:LOCALAPPDATA\Vivaldi\User Data"
        'Opera'   = "$env:APPDATA\Opera Software\Opera Stable"
    }
    foreach ($b in $chromium.Keys) {
        $root = $chromium[$b]
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $profiles = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Extensions') })
        if (Test-Path -LiteralPath (Join-Path $root 'Extensions')) { $profiles += Get-Item -LiteralPath $root }
        foreach ($prof in $profiles) {
            foreach ($ext in @(Get-ChildItem -LiteralPath (Join-Path $prof.FullName 'Extensions') -Directory -ErrorAction SilentlyContinue)) {
                if ($ext.Name -eq 'Temp') { continue }
                $verDir = Get-ChildItem -LiteralPath $ext.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
                if (-not $verDir) { continue }
                $mf = Join-Path $verDir.FullName 'manifest.json'
                if (-not (Test-Path -LiteralPath $mf)) { continue }
                try { $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
                $perms = @(@($m.permissions) + @($m.host_permissions) | Where-Object { $_ -is [string] })
                # Vollzugriff aus allen Berechtigungen bestimmen (Manifest V3: host_permissions, dazu Content-Scripts), nicht aus der gekürzten Anzeige
                $hosts = @($perms) + @($m.content_scripts | ForEach-Object { $_.matches } | Where-Object { $_ -is [string] })
                $rows.Add([pscustomobject][ordered]@{
                        Browser        = $b
                        Profil         = $prof.Name
                        Name           = Resolve-ExtensionName $m $verDir.FullName
                        Version        = $m.version
                        ID             = $ext.Name
                        Vollzugriff    = [bool]($hosts | Where-Object { $_ -match $script:AllSitesPattern })
                        Berechtigungen = (($perms | Select-Object -First 8) -join ', ')
                    })
            }
        }
    }
    $ffRoot = "$env:APPDATA\Mozilla\Firefox\Profiles"
    foreach ($prof in @(Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)) {
        $f = Join-Path $prof.FullName 'extensions.json'
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try { $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        foreach ($a in @($j.addons | Where-Object { $_.location -eq 'app-profile' })) {
            $origins = @($a.userPermissions.origins | Where-Object { $_ -is [string] })
            $rows.Add([pscustomobject][ordered]@{ Browser = 'Firefox'; Profil = $prof.Name; Name = $a.defaultLocale.name; Version = $a.version; ID = $a.id; Vollzugriff = [bool]($origins | Where-Object { $_ -match $script:AllSitesPattern }); Berechtigungen = ((@($a.userPermissions.permissions) + $origins | Select-Object -First 8) -join ', ') })
        }
    }
    Add-Table 'Browser-Erweiterungen' $rows
    $broad = @($rows | Where-Object Vollzugriff)
    $broadNames = @($broad | ForEach-Object Name | Select-Object -Unique)
    if ($rows.Count) { Add-Finding INFO (T 'scan.erweiterungen.anzahl' $rows.Count $broad.Count $(if ($broadNames) { ': ' + ($broadNames -join ', ') } else { '' })) (T 'scan.erweiterungen.empf') }
    else { Add-Finding OK (T 'scan.erweiterungen.keine') }
}

#endregion

#region Sicherheit: Software

Start-Section 'Sicherheit' 'Software'

Invoke-Check 'Installierte Programme' {
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $apps = foreach ($p in $paths) {
        Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName } |
            ForEach-Object {
                $date = [string]$_.InstallDate
                [pscustomobject][ordered]@{
                    Name        = ([string]$_.DisplayName).Trim()
                    Version     = [string]$_.DisplayVersion
                    Hersteller  = [string]$_.Publisher
                    Installiert = $(if ($date -match '^(\d{4})(\d{2})(\d{2})$') { "$($Matches[1])-$($Matches[2])-$($Matches[3])" } else { '' })
                    Bereich     = $(if ($p -like 'HKCU*') { (T 'scan.software.bereichBenutzer') } else { (T 'scan.software.bereichSystem') })
                }
            }
    }
    $apps = @($apps | Sort-Object Name, Version -Unique)
    Add-Table 'Installierte Programme' $apps

    $eol = @(
        @{ Pattern = '^Adobe Flash'; Text = (T 'scan.software.eolFlash') }
        @{ Pattern = '^Microsoft Silverlight'; Text = (T 'scan.software.eolSilverlight') }
        @{ Pattern = '^QuickTime'; Text = (T 'scan.software.eolQuickTime') }
        @{ Pattern = '^Python 2\.'; Text = (T 'scan.software.eolPython2') }
        @{ Pattern = '^Python 3\.[0-9]\.'; Text = (T 'scan.software.eolPython3') }
        @{ Pattern = 'Microsoft Office.*(2007|2010|2013|2016|2019)'; Text = (T 'scan.software.eolOffice') }
        @{ Pattern = '^Java(\(TM\))? [67]\b'; Text = (T 'scan.software.eolJava') }
    )
    $minVersions = @(
        @{ Pattern = '^WinRAR'; Min = '7.13'; Text = (T 'scan.software.minWinRar') }
        @{ Pattern = '^7-Zip'; Min = '25.0'; Text = (T 'scan.software.min7Zip') }
        @{ Pattern = '^Node\.js'; Min = '22.0'; Text = (T 'scan.software.minNode') }
    )
    $hits = @()
    foreach ($a in $apps) {
        foreach ($r in $eol) { if ($a.Name -match $r.Pattern) { $hits += "$($a.Name) $($a.Version): $($r.Text)" } }
        foreach ($r in $minVersions) {
            if ($a.Name -match $r.Pattern) {
                $v = ConvertTo-LooseVersion $a.Version
                if ($v -and $v -lt (ConvertTo-LooseVersion $r.Min)) { $hits += "$($a.Name) $($a.Version): $($r.Text)" }
            }
        }
    }
    $hits = @($hits | Select-Object -Unique)
    if ($hits) { Add-Finding WARN ($hits -join '; ') (T 'scan.software.altEmpf') }
    else { Add-Finding OK (T 'scan.software.ok' $apps.Count) }
}

if ($SkipWinget) {
    $script:CheckName = 'Software-Updates (winget)'
    Add-Finding SKIP (T 'scan.software.wingetUebersprungen')
}
else {
    Invoke-Check 'Software-Updates (winget)' {
        # winget nur aus dem signierten App-Installationsprogramm unter Program Files\WindowsApps, nie über PATH (2.3.3)
        if (-not $script:PfadLib) { Add-Finding SKIP (T 'scan.software.wingetPfadLibFehlt'); return }
        if (-not $script:WingetLib) { Add-Finding SKIP (T 'scan.software.wingetLibFehlt'); return }
        $wgInfo = Get-MorpheusWinget
        if (-not $wgInfo.Pfad) { Add-Finding SKIP (T 'scan.software.wingetNichtGefunden' $wgInfo.Grund) (T 'scan.software.wingetNichtGefundenEmpf'); return }
        $wu = Get-MorpheusWingetUpdates -InformationAction SilentlyContinue
        switch ($wu.status) {
            'zeitlimit' { Add-Finding SKIP (T 'scan.software.wingetZeitlimit'); return }
            'fehler' { Add-Finding SKIP (T 'scan.software.wingetFehler' $wu.fehler); return }
            'unlesbar' { Add-Finding SKIP $wu.fehler; return }
            'keine' { Add-Finding OK (T 'scan.software.wingetAktuell'); return }
        }
        $rows = @($wu.zeilen)
        $script:WingetUpdates = $rows
        Add-Table 'Verfügbare Software-Updates (winget)' $rows
        $manual = @($rows | Where-Object Kategorie -EQ 'Programm')
        $other = @($rows | Where-Object Kategorie -NE 'Programm')
        if ($manual.Count) { Add-Finding WARN (T 'scan.software.wingetProgramme' $manual.Count (($manual | Select-Object -First 8 | ForEach-Object Name) -join ', ')) (T 'scan.software.wingetProgrammeEmpf') }
        elseif ($other.Count) { Add-Finding INFO (T 'scan.software.wingetNurSpiele' $other.Count (($other | ForEach-Object Name) -join ', ')) (T 'scan.software.wingetNurSpieleEmpf') }
        else { Add-Finding OK (T 'scan.software.wingetAktuell') }
    }
}

#endregion

#region Sicherheit: Ereignisse

Start-Section 'Sicherheit' 'Ereignisse'

$script:LocalAddressPattern = '^(-|::1|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|fe80:|::ffff:(127|10|192\.168)\.|0\.0\.0\.0|$)'

Invoke-Check 'Fehlgeschlagene Anmeldungen' -NeedsAdmin {
    $ev = @(Get-RecentEvents @{ LogName = 'Security'; Id = 4625 } -Max 2000)
    $rows = foreach ($e in $ev) {
        $d = Get-EventData $e
        [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Konto = "$($d['TargetDomainName'])\$($d['TargetUserName'])"; Anmeldetyp = $d['LogonType']; Quelle = $d['IpAddress']; Prozess = $d['ProcessName']; Status = $d['SubStatus'] }
    }
    $rows = @($rows)
    Add-Table 'Fehlgeschlagene Anmeldungen' @($rows | Select-Object -First 100)
    $ext = @($rows | Where-Object { $_.Quelle -notmatch $script:LocalAddressPattern })
    # Anmeldetyp 3 = Netzwerk (Freigaben), 10 = Remotedesktop; 2/7/11 = Eingabe direkt am PC bzw. in einer App
    $net = @($rows | Where-Object { $_.Anmeldetyp -in '3', '10' })
    $local = @($rows | Where-Object { $_.Anmeldetyp -notin '3', '10' })
    $byProc = { param($list) ($list | Group-Object { if ($_.Prozess -and $_.Prozess -ne '-') { [IO.Path]::GetFileName($_.Prozess) } else { (T 'scan.ereignisse.anmeldungKonto' $_.Konto) } } | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ', ' }
    if ($ext) { Add-Finding CRIT (T 'scan.ereignisse.anmeldungExtern' $ext.Count (($ext | ForEach-Object Quelle | Select-Object -Unique -First 5) -join ', ')) (T 'scan.ereignisse.anmeldungExternEmpf') }
    elseif ($net.Count -gt 20) { Add-Finding WARN (T 'scan.ereignisse.anmeldungNetzViele' $net.Count $EventDays (& $byProc $net)) (T 'scan.ereignisse.anmeldungNetzVieleEmpf') }
    elseif ($net) {
        if ($local) { Add-Finding INFO (T 'scan.ereignisse.anmeldungNetzLokal' $net.Count (& $byProc $net) $local.Count) }
        else { Add-Finding INFO (T 'scan.ereignisse.anmeldungNetz' $net.Count (& $byProc $net)) }
    }
    elseif ($local) { Add-Finding OK (T 'scan.ereignisse.anmeldungNurLokal' $local.Count (& $byProc $local)) }
    else { Add-Finding OK (T 'scan.ereignisse.keineInTagen' $EventDays) }
}

Invoke-Check 'Netzwerk- und RDP-Anmeldungen' -NeedsAdmin {
    $ms = [int64]((Get-Date) - $script:Since).TotalMilliseconds
    $query = {
        param($type, $max)
        $xp = "*[System[(EventID=4624) and TimeCreated[timediff(@SystemTime) <= $ms]] and EventData[Data[@Name='LogonType']='$type']]"
        try { Get-WinEvent -LogName Security -FilterXPath $xp -MaxEvents $max -ErrorAction Stop }
        catch { if ($_.FullyQualifiedErrorId -notmatch '^NoMatchingEventsFound') { throw } }
    }
    $rdp = @(& $query 10 500)
    $net = @(& $query 3 3000)
    $toRow = { param($e) $d = Get-EventData $e; [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Typ = $d['LogonType']; Konto = "$($d['TargetDomainName'])\$($d['TargetUserName'])"; Quelle = $d['IpAddress'] } }
    $rdpRows = @($rdp | ForEach-Object { & $toRow $_ })
    $extRows = @($net | ForEach-Object { & $toRow $_ } | Where-Object { $_.Quelle -notmatch $script:LocalAddressPattern })
    Add-Table 'Remote-Anmeldungen (RDP und externe Netzwerkanmeldungen)' @($rdpRows + $extRows | Select-Object -First 100)
    if ($extRows) { Add-Finding CRIT (T 'scan.ereignisse.remoteExtern' $extRows.Count (($extRows | ForEach-Object Quelle | Select-Object -Unique -First 5) -join ', ')) (T 'scan.ereignisse.remoteExternEmpf') }
    elseif ($rdpRows) { Add-Finding WARN (T 'scan.ereignisse.remoteRdp' $rdpRows.Count (($rdpRows | ForEach-Object Quelle | Select-Object -Unique) -join ', ')) (T 'scan.ereignisse.remoteRdpEmpf') }
    else { Add-Finding OK (T 'scan.ereignisse.remoteKeine') }
}

Invoke-Check 'Konto- und Gruppenänderungen' -NeedsAdmin {
    $names = @{ 4720 = (T 'scan.ereignisse.kontoErstellt'); 4722 = (T 'scan.ereignisse.kontoAktiviert'); 4724 = (T 'scan.ereignisse.kennwortZurueck'); 4726 = (T 'scan.ereignisse.kontoGeloescht'); 4728 = (T 'scan.ereignisse.zuGlobaler'); 4732 = (T 'scan.ereignisse.zuLokaler'); 4738 = (T 'scan.ereignisse.kontoGeaendert'); 4756 = (T 'scan.ereignisse.zuUniverseller'); 4781 = (T 'scan.ereignisse.kontoUmbenannt') }
    $ev = @(Get-RecentEvents @{ LogName = 'Security'; Id = [int[]]$names.Keys } -Max 300)
    $rows = foreach ($e in $ev) {
        $d = Get-EventData $e
        $member = $d['MemberName']
        if ((-not $member -or $member -eq '-') -and $d['MemberSid']) {
            try { $member = ([Security.Principal.SecurityIdentifier]$d['MemberSid']).Translate([Security.Principal.NTAccount]).Value } catch { $member = $d['MemberSid'] }
        }
        [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Ereignis = $names[$e.Id]; Ziel = $d['TargetUserName']; Mitglied = $member; Durch = $d['SubjectUserName'] }
    }
    $rows = @($rows)
    Add-Table 'Konto- und Gruppenänderungen' $rows
    $groupNames = @($names[4728], $names[4732], $names[4756])
    $groupAdds = @($rows | Where-Object { $_.Ereignis -in $groupNames })
    # "Konto geändert" durch das Computerkonto (Name endet auf $) macht Windows selbst, z. B. beim Abgleich mit dem Microsoft-Konto
    $routine = @($rows | Where-Object { $_.Ereignis -eq $names[4738] -and $_.Durch -match '\$$' })
    $other = @($rows | Where-Object { $_ -notin $routine })
    $otherText = ($other | Group-Object Ereignis | ForEach-Object { "$($_.Count)x $($_.Name)" }) -join ', '
    if ($groupAdds) { Add-Finding WARN (T 'scan.ereignisse.gruppenGeaendert' (($groupAdds | ForEach-Object { "$($_.Mitglied) -> $($_.Ziel)" }) -join '; ')) (T 'scan.ereignisse.gruppenGeaendertEmpf') }
    elseif ($other) {
        if ($routine) { Add-Finding INFO (T 'scan.ereignisse.kontoSonstRoutine' $otherText $routine.Count) (T 'scan.ereignisse.kontoSonstEmpf') }
        else { Add-Finding INFO (T 'scan.ereignisse.kontoSonst' $otherText) (T 'scan.ereignisse.kontoSonstEmpf') }
    }
    elseif ($routine) { Add-Finding OK (T 'scan.ereignisse.kontoNurRoutine' $routine.Count) }
    else { Add-Finding OK (T 'scan.ereignisse.keineInTagen' $EventDays) }
}

Invoke-Check 'Gelöschte Ereignisprotokolle' {
    $ev = @(Get-RecentEvents @{ LogName = 'System'; Id = 104; ProviderName = 'Microsoft-Windows-Eventlog' })
    if ($script:IsAdmin) { $ev += @(Get-RecentEvents @{ LogName = 'Security'; Id = 1102 }) }
    if ($ev) { Add-Finding WARN (T 'scan.ereignisse.protokollGeleert' $ev.Count (Format-Date ($ev | Sort-Object TimeCreated | Select-Object -Last 1).TimeCreated)) (T 'scan.ereignisse.protokollGeleertEmpf') }
    else { Add-Finding OK (T 'scan.ereignisse.protokollNichtGeleert' $EventDays) }
}

Invoke-Check 'Neu installierte Dienste' {
    $ev = @(Get-RecentEvents @{ LogName = 'System'; Id = 7045; ProviderName = 'Service Control Manager' } -Max 500)
    # Je Dienst eine Zeile: Manche Programme (z. B. NVIDIA FrameView) installieren ihren Treiber bei jedem Start neu
    $rows = @($ev | Group-Object { (Get-EventData $_)['ServiceName'] } | ForEach-Object {
            $d = Get-EventData $_.Group[0]
            $sig = Get-FileSignatureInfo (Get-ExePath $d['ImagePath'])
            [pscustomobject][ordered]@{ Zuletzt = Format-Date $_.Group[0].TimeCreated; Dienst = $_.Name; Anzahl = $_.Count; Signatur = $sig.Status; Signierer = $sig.Signer; Datei = $d['ImagePath'] }
        } | Sort-Object Zuletzt -Descending)
    Add-Table 'Neu installierte Dienste' $rows
    $bad = @($rows | Where-Object { $_.Signatur -notin 'Valid', 'Datei fehlt' })
    $signers = ($rows | Where-Object Signierer | Group-Object Signierer | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object Name) -join ', '
    $value = if ($signers) { T 'scan.ereignisse.diensteSigner' $rows.Count $ev.Count $signers } else { T 'scan.ereignisse.dienste' $rows.Count $ev.Count }
    if ($bad) { Add-Finding WARN (T 'scan.ereignisse.diensteUnsigniert' (($bad | ForEach-Object Dienst) -join ', ')) (T 'scan.ereignisse.diensteUnsigniertEmpf') }
    elseif ($rows) { Add-Finding OK $value }
    else { Add-Finding OK (T 'scan.ereignisse.keineInTagen' $EventDays) }
}

Invoke-Check 'Defender-Ereignisse' {
    $log = 'Microsoft-Windows-Windows Defender/Operational'
    $det = @(Get-RecentEvents @{ LogName = $log; Id = 1116, 1117 } -Max 200)
    $off = @(Get-RecentEvents @{ LogName = $log; Id = 5001, 5010, 5012 } -Max 50)
    $cfg = @(Get-RecentEvents @{ LogName = $log; Id = 5007 } -Max 300)
    $exclAdded = @($cfg | Where-Object { (Get-EventData $_)['New Value'] -match 'Exclusions' })
    $rows = foreach ($e in $det) {
        $d = Get-EventData $e
        [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Ereignis = $e.Id; Bedrohung = $d['Threat Name']; Pfad = $d['Path']; Aktion = $d['Action Name'] }
    }
    Add-Table 'Defender-Ereignisse: Erkennungen' $rows
    $issues = @()
    if ($off) { $issues += (T 'scan.ereignisse.defenderAus' $off.Count) }
    if ($exclAdded) { $issues += (T 'scan.ereignisse.defenderAusnahmen' $exclAdded.Count) }
    if ($det) { $issues += (T 'scan.ereignisse.defenderErkennungen' $det.Count ((@($rows) | ForEach-Object Bedrohung | Select-Object -Unique -First 5) -join ', ')) }
    if ($issues) { Add-Finding WARN ($issues -join '; ') (T 'scan.ereignisse.defenderEmpf') }
    else { Add-Finding OK (T 'scan.ereignisse.defenderOk' $cfg.Count) }
}

Invoke-Check 'Auffällige PowerShell-Skripte' {
    # Ereignisse ab Script-Start stammen vom Prüflauf selbst (z. B. beim Laden der CIM-Module).
    $ev = @(Get-RecentEvents @{ LogName = 'Microsoft-Windows-PowerShell/Operational'; Id = 4104; Level = 3 } -Max 500 | Where-Object { $_.TimeCreated -lt $startedAt })
    $rows = foreach ($e in $ev) {
        $d = Get-EventData $e
        if ($d['Path'] -and $d['Path'] -eq $PSCommandPath) { continue }
        $text = ([string]$d['ScriptBlockText']) -replace '\s+', ' '
        # Automatisch generierte Wrapper der CIM-Module (NetSecurity, ScheduledTasks …) sind harmlos.
        if ($text -match '__cmdletization|Cmdletization\.MethodParameter|\$script:MyModule') { continue }
        if ($text -match $script:KnownHarmless.PowerShell) { continue }
        [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Pfad = $d['Path']; Auszug = $text.Substring(0, [Math]::Min(200, $text.Length)) }
    }
    $rows = @($rows)
    Add-Table 'Auffällige PowerShell-Skriptblöcke' @($rows | Select-Object -First 50)
    if ($rows) { Add-Finding INFO (T 'scan.ereignisse.psSkripte' $rows.Count) (T 'scan.ereignisse.psSkripteEmpf') }
    else { Add-Finding OK (T 'scan.ereignisse.keineInTagen' $EventDays) }
}

Invoke-Check 'Neue Firewall-Regeln' {
    $ev = @(Get-RecentEvents @{ LogName = 'Microsoft-Windows-Windows Firewall With Advanced Security/Firewall'; Id = 2004, 2097 } -Max 300)
    $dirIn = T 'scan.ereignisse.richtungEingehend'
    $dirOut = T 'scan.ereignisse.richtungAusgehend'
    $rows = foreach ($e in $ev) {
        $d = Get-EventData $e
        [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Regel = $d['RuleName']; Richtung = $(if ($d['Direction'] -eq '1') { $dirIn } else { $dirOut }); Programm = $d['ApplicationPath']; Durch = $d['ModifyingApplication'] }
    }
    $rows = @($rows)
    Add-Table 'Neue Firewall-Regeln' @($rows | Select-Object -First 100)
    # Regeln, die der Windows-Firewalldienst (svchost) selbst anlegt, stammen von App-Installationen und -Updates aus dem Store bzw. von Windows
    $byWindows = @($rows | Where-Object { [string]$_.Durch -match '\\(svchost|MsMpEng)\.exe$' -or -not $_.Durch })
    $inbound = @($rows | Where-Object { $_.Richtung -eq $dirIn -and $_ -notin $byWindows })
    $tools = ($inbound | ForEach-Object { [IO.Path]::GetFileName([string]$_.Durch) } | Select-Object -Unique -First 5) -join ', '
    if ($inbound) { Add-Finding INFO (T 'scan.ereignisse.fwEingehend' $inbound.Count $tools $byWindows.Count) (T 'scan.ereignisse.fwEingehendEmpf') }
    elseif ($rows) { Add-Finding OK (T 'scan.ereignisse.fwNurWindows' $rows.Count) }
    else { Add-Finding OK (T 'scan.ereignisse.fwKeine' $EventDays) }
}

Invoke-Check 'Blockierte Treiber/Dateien (Code Integrity)' {
    $ev = @(Get-RecentEvents @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3033, 3077 } -Max 300)
    $rows = @($ev | Group-Object { (([string]$_.Message) -split "`n")[0].Trim() } | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object {
            [pscustomobject][ordered]@{ Anzahl = $_.Count; Einordnung = $(if ($_.Name -match $script:KnownHarmless.CodeIntegrity) { (T 'scan.ereignisse.ciBekanntHarmlos') } else { '' }); Meldung = $_.Name }
        })
    Add-Table 'Code Integrity: blockierte Dateien' $rows
    $unknown = @($rows | Where-Object { -not $_.Einordnung })
    $unknownCount = ($unknown | Measure-Object Anzahl -Sum).Sum
    if ($unknown) { Add-Finding INFO (T 'scan.ereignisse.ciUngeklaert' $unknownCount $ev.Count) (T 'scan.ereignisse.ciUngeklaertEmpf') }
    elseif ($ev) { Add-Finding OK (T 'scan.ereignisse.ciAlleHarmlos' $ev.Count) }
    else { Add-Finding OK (T 'scan.ereignisse.keineInTagen' $EventDays) }
}

#endregion

#region Performance: Hardware

Start-Section 'Performance' 'Hardware'

Invoke-Check 'Prozessor' {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $maxPerf = 0
    for ($i = 0; $i -lt 3; $i++) {
        $pi = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
        $maxPerf = [Math]::Max($maxPerf, [int]$pi.PercentProcessorPerformance)
        Start-Sleep -Milliseconds 300
    }
    $mhz = [int]($cpu.MaxClockSpeed * $maxPerf / 100)
    Add-Finding INFO (T 'scan.hardware.cpu' $cpu.Name.Trim() $cpu.NumberOfCores $cpu.NumberOfLogicalProcessors $cpu.MaxClockSpeed $mhz)
}

Invoke-Check 'Arbeitsspeicher' {
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $rows = foreach ($m in $mods) {
        [pscustomobject][ordered]@{ Steckplatz = $m.DeviceLocator; Bank = $m.BankLabel; Groesse = Format-Size $m.Capacity; SpezTakt = $m.Speed; AktTakt = $m.ConfiguredClockSpeed; Hersteller = $m.Manufacturer; Modell = ([string]$m.PartNumber).Trim() }
    }
    Add-Table 'RAM-Module' $rows
    $total = ($mods | Measure-Object Capacity -Sum).Sum
    $cfg = ($mods | Measure-Object ConfiguredClockSpeed -Minimum).Minimum
    $channels = @($mods | ForEach-Object { if ("$($_.DeviceLocator)" -match 'Channel\s*([A-D])') { $Matches[1] } } | Select-Object -Unique)
    $value = if ($channels) { T 'scan.hardware.ramKanaele' (Format-Size $total) $mods.Count $cfg ($channels -join ', ') } else { T 'scan.hardware.ram' (Format-Size $total) $mods.Count $cfg }
    if ($mods.Count -eq 1) { Add-Finding WARN (T 'scan.hardware.ramSingle' $value) (T 'scan.hardware.ramSingleEmpf') }
    elseif ($channels.Count -eq 1) { Add-Finding WARN (T 'scan.hardware.ramGleicherKanal' $value) (T 'scan.hardware.ramGleicherKanalEmpf') }
    elseif ($cfg -le 2133) { Add-Finding WARN (T 'scan.hardware.ramJedec' $value) (T 'scan.hardware.ramJedecEmpf') }
    elseif ($cfg -le 2666) { Add-Finding INFO (T 'scan.hardware.ramIntel' $value) (T 'scan.hardware.ramIntelEmpf') }
    else { Add-Finding OK (T 'scan.hardware.ramXmp' $value) }
}

Invoke-Check 'Grafikkarte und Treiber' {
    $gpus = @(Get-CimInstance Win32_VideoController)
    $rows = foreach ($g in $gpus) {
        $nv = ''
        if ($g.Name -match 'NVIDIA' -and $g.DriverVersion -match '^\d+\.\d+\.(\d+)\.(\d+)$') { $digits = $Matches[1] + $Matches[2]; $nv = $digits.Substring($digits.Length - 5).Insert(3, '.') }
        [pscustomobject][ordered]@{ Name = $g.Name; Treiber = $g.DriverVersion; NvidiaVersion = $nv; Datum = Format-Date $g.DriverDate; Aufloesung = "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)"; Hz = $g.CurrentRefreshRate; Status = $g.Status }
    }
    Add-Table 'Grafikkarten' $rows
    $dgpu = @($gpus | Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon|Arc' })
    if (-not $dgpu) { Add-Finding INFO (T 'scan.hardware.nurIntegriert' (($gpus | ForEach-Object Name) -join ', ')); return }
    foreach ($g in $dgpu) {
        $age = ((Get-Date) - $g.DriverDate).Days
        $row = $rows | Where-Object Name -EQ $g.Name | Select-Object -First 1
        $treiber = if ($row.NvidiaVersion) { $row.NvidiaVersion } else { $g.DriverVersion }
        $value = T 'scan.hardware.gpuTreiber' $g.Name $treiber ((Get-Date $g.DriverDate).ToString('yyyy-MM-dd')) $age
        if ($age -gt 180) { Add-Finding WARN $value (T 'scan.hardware.gpuTreiberAltEmpf') }
        elseif ($age -gt 90) { Add-Finding INFO $value (T 'scan.hardware.gpuTreiberPruefenEmpf') }
        else { Add-Finding OK $value }
    }
}

Invoke-Check 'Bildschirme und Bildwiederholrate' {
    if (-not ('PcCheckDisplay' -as [type])) { Add-Type -TypeDefinition $displayCode -Language CSharp }
    $mons = @([PcCheckDisplay]::Get())
    $names = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue | ForEach-Object { -join (@($_.UserFriendlyName) | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ }) })
    $rows = foreach ($m in $mons) {
        [pscustomobject][ordered]@{ Anzeige = $m.Device; Grafik = $m.Adapter; Monitor = $m.Monitor; Aufloesung = "$($m.Width)x$($m.Height)"; AktuellHz = $m.Hz; MaxHzBeiAufloesung = $m.MaxHzAtResolution; MaxHz = $m.MaxHz }
    }
    Add-Table 'Bildschirme' $rows
    $slow = @($mons | Where-Object { $_.MaxHzAtResolution -gt $_.Hz + 1 })
    $nameText = if ($names) { ' (' + ($names -join ', ') + ')' } else { '' }
    if ($slow) { Add-Finding WARN ((($slow | ForEach-Object { (T 'scan.hardware.monitorLangsam' $_.Device $_.Width $_.Height $_.Hz $_.MaxHzAtResolution) }) -join '; ') + $nameText) (T 'scan.hardware.monitorLangsamEmpf') }
    else { Add-Finding OK ((($mons | ForEach-Object { "$($_.Width)x$($_.Height) @ $($_.Hz) Hz" }) -join '; ') + $nameText) }
}

Invoke-Check 'Geräte mit Problemen' {
    $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
    $rows = foreach ($d in $bad) { [pscustomobject][ordered]@{ Geraet = $d.Name; Code = $d.ConfigManagerErrorCode; Klasse = $d.PNPClass; ID = $d.DeviceID } }
    Add-Table 'Geräte mit Problemen' $rows
    $real = @($bad | Where-Object { $_.ConfigManagerErrorCode -ne 22 })
    if ($real) { Add-Finding WARN (($real | ForEach-Object { (T 'scan.hardware.geraetCode' $_.Name $_.ConfigManagerErrorCode) }) -join '; ') (T 'scan.hardware.geraeteEmpf') }
    elseif ($bad) { Add-Finding INFO (T 'scan.hardware.geraeteDeaktiviert' (($bad | ForEach-Object Name) -join ', ')) }
    else { Add-Finding OK (T 'scan.hardware.geraeteKeine') }
}

Invoke-Check 'Wichtige Treiber' {
    $drv = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -in 'DISPLAY', 'NET', 'SCSIADAPTER', 'HDC', 'MEDIA', 'SYSTEM', 'USB' -and $_.DeviceName -and $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft' })
    $rows = @($drv | Sort-Object DeviceClass, DeviceName -Unique | ForEach-Object {
            [pscustomobject][ordered]@{ Klasse = $_.DeviceClass; Geraet = $_.DeviceName; Version = $_.DriverVersion; Datum = $(if ($_.DriverDate) { (Get-Date $_.DriverDate).ToString('yyyy-MM-dd') } else { '' }); Anbieter = $_.DriverProviderName }
        })
    Add-Table 'Herstellertreiber' $rows
    $me = $rows | Where-Object { $_.Geraet -match 'Management Engine|MEI' } | Select-Object -First 1
    if ($me) { Add-Finding INFO (T 'scan.hardware.treiberMe' $rows.Count $me.Version $me.Datum) (T 'scan.hardware.treiberEmpf') }
    else { Add-Finding INFO (T 'scan.hardware.treiber' $rows.Count) (T 'scan.hardware.treiberEmpf') }
}

#endregion

#region Performance: Laufwerke & Speicherplatz

Start-Section 'Performance' 'Laufwerke & Speicherplatz'

Invoke-Check 'Laufwerke (Typ und Zustand)' {
    $sysNum = $null
    try { $sysNum = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') | Get-Disk).Number } catch {}
    $pd = @(Get-PhysicalDisk)
    $rows = foreach ($d in $pd) {
        $rel = $null
        if ($script:IsAdmin) { try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {} }
        [pscustomobject][ordered]@{
            Nr          = $d.DeviceId
            Name        = $d.FriendlyName
            Typ         = [string]$d.MediaType
            Bus         = [string]$d.BusType
            Groesse     = Format-Size $d.Size
            Zustand     = [string]$d.HealthStatus
            System      = ([string]$d.DeviceId -eq [string]$sysNum)
            Temperatur  = $rel.Temperature
            Verschleiss = $rel.Wear
            Stunden     = $rel.PowerOnHours
            Lesefehler  = $rel.ReadErrorsUncorrected
        }
    }
    $rows = @($rows)
    Add-Table 'Physische Laufwerke' $rows
    $sys = $rows | Where-Object System | Select-Object -First 1
    $unhealthy = @($rows | Where-Object { $_.Zustand -ne 'Healthy' })
    $worn = @($rows | Where-Object { $_.Verschleiss -ge 80 })
    $hdds = @($rows | Where-Object Typ -EQ 'HDD')
    if ($unhealthy) { Add-Finding CRIT (T 'scan.laufwerke.fehler' (($unhealthy | ForEach-Object { "$($_.Name) ($($_.Zustand))" }) -join ', ')) (T 'scan.laufwerke.fehlerEmpf') }
    elseif ($worn) { Add-Finding WARN (T 'scan.laufwerke.verschleiss' (($worn | ForEach-Object { "$($_.Name) $($_.Verschleiss) %" }) -join ', ')) (T 'scan.laufwerke.verschleissEmpf') }
    elseif ($sys.Typ -eq 'HDD') { Add-Finding CRIT (T 'scan.laufwerke.windowsHdd' $sys.Name) (T 'scan.laufwerke.windowsHddEmpf') }
    elseif ($sys.Bus -eq 'SATA') { Add-Finding INFO (T 'scan.laufwerke.windowsSata' $sys.Name) (T 'scan.laufwerke.windowsSataEmpf') }
    elseif ($hdds) { Add-Finding OK (T 'scan.laufwerke.windowsAufHdds' $sys.Bus $sys.Typ $sys.Name (($hdds | ForEach-Object Name) -join ', ')) }
    else { Add-Finding OK (T 'scan.laufwerke.windowsAuf' $sys.Bus $sys.Typ $sys.Name) }
    if ($hdds -and $sys.Typ -ne 'HDD') { Add-Finding INFO (T 'scan.laufwerke.festplatten' (($hdds | ForEach-Object Name) -join ', ')) (T 'scan.laufwerke.festplattenEmpf') -Check 'Festplatten (HDD)' }
}

Invoke-Check 'Freier Speicherplatz' {
    $vols = @(Get-Volume | Where-Object { $_.DriveLetter -and [string]$_.DriveType -eq 'Fixed' -and $_.Size -gt 0 })
    $rows = foreach ($v in $vols) {
        [pscustomobject][ordered]@{ Laufwerk = "$($v.DriveLetter):"; Name = $v.FileSystemLabel; Dateisystem = $v.FileSystem; Groesse = Format-Size $v.Size; Frei = Format-Size $v.SizeRemaining; FreiProzent = [int](100 * $v.SizeRemaining / $v.Size) }
    }
    $rows = @($rows)
    Add-Table 'Laufwerke (Volumes)' $rows
    $sys = $rows | Where-Object Laufwerk -EQ $env:SystemDrive
    $low = @($rows | Where-Object { $_.FreiProzent -lt 10 -and $_.Laufwerk -ne $env:SystemDrive })
    $summary = ($rows | ForEach-Object { (T 'scan.laufwerke.frei' $_.Laufwerk $_.FreiProzent) }) -join ', '
    if ($sys.FreiProzent -lt 10) { Add-Finding CRIT $summary (T 'scan.laufwerke.freiCritEmpf') }
    elseif ($sys.FreiProzent -lt 15 -or $low) { Add-Finding WARN $summary (T 'scan.laufwerke.freiWarnEmpf') }
    else { Add-Finding OK $summary }
}

if ($SkipSpeicher) {
    $script:CheckName = 'Größte Speicherverbraucher'
    Add-Finding SKIP (T 'scan.laufwerke.speicherUebersprungen')
}
else {
    Invoke-Check 'Größte Speicherverbraucher' {
        if (-not $script:SpeicherLib) { Add-Finding SKIP (T 'scan.laufwerke.speicherLibFehlt'); return }
        $script:Speicher = Get-MorpheusSpeicher -Manuell $script:SpielOrdner -Fortschritt { param($Text) if ($Text -match '^[A-Z]: |^Spiele') { Write-Host "      $Text" -ForegroundColor DarkGray } }
        $ordnerRows = New-Object System.Collections.Generic.List[object]
        $dateiRows = New-Object System.Collections.Generic.List[object]
        $parts = New-Object System.Collections.Generic.List[string]
        $skipped = 0
        foreach ($d in @($script:Speicher.laufwerke)) {
            if ($d.fehler) { $parts.Add((T 'scan.laufwerke.nichtLesbar' $d.laufwerk)); continue }
            $skipped += [int]$d.uebersprungen
            foreach ($o in @($d.ordner)) {
                $ordnerRows.Add([pscustomobject][ordered]@{ Laufwerk = $d.laufwerk; Pfad = $o.pfad; Groesse = Format-Size ([double]$o.bytes); Bytes = [double]$o.bytes })
            }
            foreach ($f in @($d.dateien)) {
                $dateiRows.Add([pscustomobject][ordered]@{ Laufwerk = $d.laufwerk; Pfad = $f.pfad; Groesse = Format-Size ([double]$f.bytes); Bytes = [double]$f.bytes; Windows = [bool]$f.windows })
            }
            $top = @($d.ordner) | Select-Object -First 1
            if ($top) { $parts.Add("$($d.laufwerk) $($top.pfad) ($(Format-Size ([double]$top.bytes)))") }
        }
        Add-Table 'Speicherverbraucher: Ordner' $ordnerRows.ToArray()
        Add-Table 'Speicherverbraucher: Dateien' $dateiRows.ToArray()
        $value = $parts -join '; '
        if ($skipped -gt 0) { $value += (T 'scan.laufwerke.ohneZugriff' $skipped) }
        Add-Finding INFO $value (T 'scan.laufwerke.speicherEmpf')
    }
}

Invoke-Check 'TRIM und Laufwerksoptimierung' {
    $out = (Invoke-Native "$script:Sys32\fsutil.exe" @('behavior', 'query', 'DisableDeleteNotify')) -join ' '
    $trim = if ($out -match 'NTFS DisableDeleteNotify\s*=\s*(\d)') { [int]$Matches[1] } else { $null }
    $task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
    $last = if ($task) { (Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue).LastRunTime } else { $null }
    $trimText = switch ($trim) { 0 { (T 'scan.leistung.wert.an') } 1 { (T 'scan.leistung.wert.aus') } default { (T 'scan.leistung.wert.unbekannt') } }
    $taskText = if ($task) { [string]$task.State } else { T 'scan.laufwerke.nichtGefunden' }
    $value = if ($last) { T 'scan.laufwerke.trimZuletzt' $trimText $taskText (Format-Date $last) } else { T 'scan.laufwerke.trim' $trimText $taskText }
    if ($trim -eq 1) { Add-Finding WARN $value (T 'scan.laufwerke.trimAusEmpf') }
    elseif ($task -and [string]$task.State -eq 'Disabled') { Add-Finding WARN $value (T 'scan.laufwerke.trimTaskEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Auslagerungsdatei' {
    $use = @(Get-CimInstance Win32_PageFileUsage)
    $mode = if ($script:CS.AutomaticManagedPagefile) { T 'scan.laufwerke.systemverwaltet' } else { T 'scan.laufwerke.manuell' }
    if (-not $use) { Add-Finding WARN (T 'scan.laufwerke.keineAuslagerung') (T 'scan.laufwerke.keineAuslagerungEmpf'); return }
    $value = T 'scan.laufwerke.auslagerung' $mode (($use | ForEach-Object { (T 'scan.laufwerke.auslagerungEintrag' $_.Name $_.AllocatedBaseSize $_.PeakUsage) }) -join '; ')
    $tight = @($use | Where-Object { $_.PeakUsage -gt 0.8 * $_.AllocatedBaseSize })
    if ($tight -and -not $script:CS.AutomaticManagedPagefile) { Add-Finding WARN $value (T 'scan.laufwerke.auslagerungVollEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Schnellstart und Ruhezustand' {
    $hb = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
    $hib = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
    $hf = Get-Item -LiteralPath "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
    $hbText = if ($hb -eq 1) { T 'scan.leistung.wert.an' } else { T 'scan.leistung.wert.aus' }
    $hibText = if ($hib -eq 0) { T 'scan.leistung.wert.aus' } else { T 'scan.leistung.wert.an' }
    $value = if ($hf) { T 'scan.laufwerke.schnellstartHiberfil' $hbText $hibText (Format-Size $hf.Length) } else { T 'scan.laufwerke.schnellstart' $hbText $hibText }
    if ($hb -eq 1) { Add-Finding INFO $value (T 'scan.laufwerke.schnellstartEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Temporäre Dateien und Caches' {
    $targets = @(
        @{ Ort = (T 'scan.laufwerke.ortBenutzerTemp'); Pfad = $script:BenutzerTemp; Shader = $false }
        @{ Ort = (T 'scan.laufwerke.ortWindowsTemp'); Pfad = "$env:SystemRoot\Temp"; Shader = $false }
        @{ Ort = (T 'scan.laufwerke.ortUpdateDownloads'); Pfad = "$env:SystemRoot\SoftwareDistribution\Download"; Shader = $false }
        @{ Ort = (T 'scan.laufwerke.ortAbsturzabbilder'); Pfad = "$env:LOCALAPPDATA\CrashDumps"; Shader = $false }
        @{ Ort = (T 'scan.laufwerke.ortMinidumps'); Pfad = "$env:SystemRoot\Minidump"; Shader = $false }
        @{ Ort = (T 'scan.laufwerke.ortShaderDx'); Pfad = "$env:LOCALAPPDATA\D3DSCache"; Shader = $true }
        @{ Ort = (T 'scan.laufwerke.ortShaderNv'); Pfad = "$env:LOCALAPPDATA\NVIDIA\DXCache"; Shader = $true }
    )
    $junk = 0
    $rows = foreach ($t in $targets) {
        $s = Get-FolderSize $t.Pfad
        if ($s) {
            if (-not $t.Shader) { $junk += $s.Bytes }
            [pscustomobject][ordered]@{ Ort = $t.Ort; Groesse = Format-Size $s.Bytes; Bytes = $s.Bytes; Dateien = $s.Files; Pfad = $t.Pfad }
        }
    }
    $dump = Get-Item -LiteralPath "$env:SystemRoot\MEMORY.DMP" -Force -ErrorAction SilentlyContinue
    if ($dump) { $junk += [double]$dump.Length; $rows = @($rows) + [pscustomobject][ordered]@{ Ort = (T 'scan.laufwerke.ortMemoryDmp'); Groesse = Format-Size $dump.Length; Bytes = [double]$dump.Length; Dateien = 1; Pfad = $dump.FullName } }
    $rows = @($rows)
    Add-Table 'Temporäre Dateien und Caches' @($rows | Select-Object Ort, Groesse, Dateien, Pfad)
    $sense = (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01') -eq 1
    $senseText = if ($sense) { T 'scan.leistung.wert.an' } else { T 'scan.leistung.wert.aus' }
    $value = T 'scan.laufwerke.aufraeumbar' (Format-Size $junk) $senseText
    if ($junk -gt 5GB) { Add-Finding INFO $value (T 'scan.laufwerke.aufraeumbarEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Dev Drive (Entwicklung)' {
    $refs = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'ReFS' })
    if ($refs) {
        $detail = foreach ($v in $refs) { "$($v.DriveLetter): " + (((Invoke-Native "$script:Sys32\fsutil.exe" @('devdrv', 'query', "$($v.DriveLetter):")) | Where-Object { $_.Trim() } | Select-Object -First 1)) }
        Add-Finding OK (T 'scan.laufwerke.refsVolumes' ($detail -join '; '))
    }
    else {
        # Nur relevant, wenn auf dem PC entwickelt wird
        # Nur nachsehen, ob die Programme im PATH des Benutzers liegen; gestartet wird nichts (PATH des Prozesses ist begrenzt)
        $devOrdner = @(([string]$script:BenutzerPath) -split ';' | Where-Object { $_.Trim() })
        $dev = @('git.exe', 'node.exe', 'python.exe', 'dotnet.exe', 'cargo.exe', 'go.exe', 'java.exe' | Where-Object {
                $n = $_
                foreach ($d in $devOrdner) { try { if ([IO.File]::Exists([IO.Path]::Combine($d.Trim(), $n))) { return $true } } catch { } }
                $false
            } | ForEach-Object { $_ -replace '\.exe$' })
        if ($dev) { Add-Finding INFO (T 'scan.laufwerke.keinDevDriveTools' ($dev -join ', ')) (T 'scan.laufwerke.keinDevDriveEmpf') }
        else { Add-Finding OK (T 'scan.laufwerke.keinDevDriveNoetig') }
    }
}

#endregion

#region Performance: Energie

Start-Section 'Performance' 'Energie'

Invoke-Check 'Energieplan' {
    $act = (Invoke-Native "$script:Sys32\powercfg.exe" @('/getactivescheme')) -join ' '
    $guid = if ($act -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $Matches[1].ToLower() }
    $name = if ($act -match '\(([^)]+)\)\s*\*?\s*$') { $Matches[1] } else { $guid }
    $plans = @((Invoke-Native "$script:Sys32\powercfg.exe" @('/list')) | Where-Object { $_ -match '[0-9a-fA-F]{8}-' } | ForEach-Object { [pscustomobject]@{ Plan = $_.Trim() } })
    Add-Table 'Energiepläne' $plans
    $highPerf = $guid -in '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c', 'e9a42b02-d5df-448d-aa00-03f14749eb61' -or $name -match 'Ultimat|High performance|Höchstleistung'
    if ($script:Profile -eq 'Laptop') {
        if ($highPerf) { Add-Finding WARN (T 'scan.leistung.aktiv' $name) (T 'scan.energie.laptopHochleistungEmpf') }
        else { Add-Finding OK (T 'scan.leistung.aktiv' $name) }
        return
    }
    switch ($guid) {
        'a1841308-3541-4fab-bc81-f71556f20b4a' { Add-Finding WARN (T 'scan.leistung.aktiv' $name) (T 'scan.energie.desktopSparplanEmpf') }
        '381b4222-f694-41f0-9685-ff5bb260df2e' { Add-Finding OK (T 'scan.energie.aktivAusreichend' $name) }
        default { Add-Finding OK (T 'scan.leistung.aktiv' $name) }
    }
}

Invoke-Check 'Prozessor-Energieeinstellungen' {
    $min = Get-PowerSetting SUB_PROCESSOR PROCTHROTTLEMIN
    $max = Get-PowerSetting SUB_PROCESSOR PROCTHROTTLEMAX
    $boost = Get-PowerSetting SUB_PROCESSOR PERFBOOSTMODE -Hidden
    $park = Get-PowerSetting SUB_PROCESSOR CPMINCORES -Hidden
    $boostNames = @{ 0 = (T 'scan.energie.boost0'); 1 = (T 'scan.energie.boost1'); 2 = (T 'scan.energie.boost2'); 3 = (T 'scan.energie.boost3'); 4 = (T 'scan.energie.boost4'); 5 = (T 'scan.energie.boost5'); 6 = (T 'scan.energie.boost6') }
    $value = (T 'scan.energie.cpuNetz' $min.AC $max.AC) + $(if ($boost) { T 'scan.energie.cpuTurbo' ($boostNames[[int]$boost.AC]) } else { '' }) + $(if ($park) { T 'scan.energie.cpuKernparken' $park.AC } else { '' })
    if ($max -and $max.AC -lt 100) { Add-Finding WARN $value (T 'scan.energie.cpuMaxEmpf') }
    elseif ($boost -and $boost.AC -eq 0) { Add-Finding WARN $value (T 'scan.energie.cpuTurboAusEmpf') }
    elseif ($min -and $min.AC -ge 100 -and $script:Profile -eq 'Laptop') { Add-Finding WARN $value (T 'scan.energie.cpuMinLaptopEmpf') }
    elseif ($min -and $min.AC -ge 100) { Add-Finding INFO $value (T 'scan.energie.cpuMinEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Weitere Energiesparfunktionen' {
    $usb = Get-PowerSetting '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    $aspm = Get-PowerSetting SUB_PCIEXPRESS ASPM
    $sleep = Get-PowerSetting SUB_SLEEP STANDBYIDLE
    $aspmNames = @{ 0 = (T 'scan.leistung.wert.aus'); 1 = (T 'scan.energie.aspmMittel'); 2 = (T 'scan.energie.aspmMaximal') }
    $usbText = if (-not $usb) { T 'scan.leistung.wert.unbekannt' } elseif ([int]$usb.AC -eq 1) { T 'scan.leistung.wert.an' } elseif ([int]$usb.AC -eq 0) { T 'scan.leistung.wert.aus' } else { '' }
    $aspmText = if ($aspm) { $aspmNames[[int]$aspm.AC] } else { T 'scan.leistung.wert.unbekannt' }
    $sleepText = if (-not $sleep) { T 'scan.leistung.wert.unbekannt' } elseif ($sleep.AC -eq 0) { T 'scan.energie.sleepNie' } else { T 'scan.energie.sleepMin' ([int]($sleep.AC / 60)) }
    $value = T 'scan.energie.weitere' $usbText $aspmText $sleepText
    if ($aspm -and $aspm.AC -eq 2) { Add-Finding INFO $value (T 'scan.energie.aspmEmpf') }
    else { Add-Finding OK $value }
}

#endregion

#region Performance: Gaming & Grafik

Start-Section 'Performance' 'Gaming & Grafik'

Invoke-Check 'Spielmodus' {
    $gm = Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    if ($gm -eq 0) { Add-Finding INFO (T 'scan.gaming.aus') (T 'scan.gaming.spielmodusEmpf') }
    else { Add-Finding OK (T 'scan.gaming.an') }
}

Invoke-Check 'Hardwarebeschleunigte GPU-Planung (HAGS)' {
    $h = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    switch ($h) {
        2 { Add-Finding OK (T 'scan.gaming.an') }
        1 { Add-Finding INFO (T 'scan.gaming.aus') (T 'scan.gaming.hagsEmpf') }
        default { Add-Finding INFO (T 'scan.gaming.hagsStandard') (T 'scan.gaming.hagsStandardEmpf') }
    }
}

Invoke-Check 'Hintergrundaufzeichnung (Game DVR)' {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
    if ((Get-RegValue $k 'HistoricalCaptureEnabled') -eq 1) { Add-Finding WARN (T 'scan.gaming.dvrLaeuft') (T 'scan.gaming.dvrEmpf') }
    else { Add-Finding OK (T 'scan.gaming.aus') }
}

Invoke-Check 'Optimierungen für Spiele im Fenstermodus' {
    $s = [string](Get-RegValue 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings')
    $swap = if ($s -match 'SwapEffectUpgradeEnable=(\d)') { $Matches[1] } else { $null }
    $vrr = if ($s -match 'VRROptimizeEnable=(\d)') { $Matches[1] } else { $null }
    $swapText = if ($swap -eq '0') { T 'scan.leistung.wert.aus' } elseif ($swap -eq '1') { T 'scan.leistung.wert.an' } else { T 'scan.gaming.standard' }
    $vrrText = if ($vrr -eq '0') { T 'scan.leistung.wert.aus' } elseif ($vrr -eq '1') { T 'scan.leistung.wert.an' } else { T 'scan.gaming.standard' }
    $value = T 'scan.gaming.fenstermodus' $swapText $vrrText
    if ($swap -eq '0') { Add-Finding INFO $value (T 'scan.gaming.fenstermodusEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Mausbeschleunigung' {
    if ((Get-RegValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed') -eq '1') { Add-Finding INFO (T 'scan.gaming.mausBeschleunigung') (T 'scan.gaming.mausEmpf') }
    else { Add-Finding OK (T 'scan.gaming.aus') }
}

Invoke-Check 'Overlays und Hintergrund-Tools' {
    $patterns = [ordered]@{
        'Discord'                                    = '^Discord$'
        'Steam-Overlay'                              = '^GameOverlayUI'
        'NVIDIA App/Overlay'                         = '^(NVIDIA Overlay|NVIDIA app|nvcontainer)$'
        'MSI Afterburner/RTSS'                       = '^(MSIAfterburner|RTSS)$'
        'Xbox Game Bar'                              = '^(GameBar|XboxGameBarWidgets)$'
        'OBS'                                        = '^obs64$'
        'Gigabyte-Tools (RGB Fusion/EasyTune/SIV)'   = '(RGBFusion|EasyTune|SIV|AppCenter|GCC|AorusEngine|GigabyteControlCenter)'
        'Corsair iCUE'                               = '^iCUE'
        'Razer Synapse'                              = '^Razer'
        'Logitech G HUB'                             = '^lghub'
        'SignalRGB/OpenRGB'                          = '^(SignalRgb|OpenRGB)'
        'Overwolf'                                   = '^Overwolf'
        'Wallpaper Engine'                           = '^wallpaper(32|64)$'
    }
    $names = @(Get-Process | ForEach-Object ProcessName | Select-Object -Unique)
    $found = @($patterns.Keys | Where-Object { $pat = $patterns[$_]; $names | Where-Object { $_ -match $pat } })
    if ($found) { Add-Finding INFO (T 'scan.leistung.aktiv' ($found -join ', ')) (T 'scan.gaming.overlaysEmpf') }
    else { Add-Finding OK (T 'scan.gaming.keineOverlays') }
}

Invoke-Check 'Virtualisierung und Spieleleistung' {
    $dg = $script:DeviceGuard
    $vbsOn = $dg -and [int]$dg.VirtualizationBasedSecurityStatus -eq 2
    $hvci = $dg -and (@($dg.SecurityServicesRunning) -contains 2)
    $mbec = $dg -and (@($dg.AvailableSecurityProperties) -contains 7)
    $virt = @('Microsoft-Hyper-V-All', 'VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux', 'Containers-DisposableClientVM', 'HypervisorPlatform' | Where-Object { $_ -in $script:Features })
    $vbsText = if ($vbsOn) { T 'scan.gaming.vbsLaeuft' } else { T 'scan.leistung.wert.aus' }
    $hvciText = if ($hvci) { T 'scan.leistung.wert.an' } else { T 'scan.leistung.wert.aus' }
    $mbecText = if ($mbec) { T 'scan.leistung.wert.ja' } else { T 'scan.leistung.wert.nein' }
    $value = if ($virt) { T 'scan.gaming.virtFeatures' $script:CS.HypervisorPresent $vbsText $hvciText $mbecText ($virt -join ', ') } else { T 'scan.gaming.virt' $script:CS.HypervisorPresent $vbsText $hvciText $mbecText }
    Add-Finding INFO $value (T 'scan.gaming.virtEmpf')
}

Invoke-Check 'Resizable BAR und PCIe-Anbindung' {
    # nvidia-smi nur aus System32 bzw. Program Files, nie über PATH (2.3.3)
    $smi = $null
    foreach ($cand in @((Join-Path $script:Sys32 'nvidia-smi.exe'), (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'))) {
        if (Test-Path -LiteralPath $cand -PathType Leaf) { $smi = [pscustomobject]@{ Source = $cand }; break }
    }
    if (-not $smi) {
        if (Get-CimInstance Win32_VideoController | Where-Object Name -Match 'NVIDIA') { Add-Finding SKIP (T 'scan.gaming.smiFehlt') }
        else { Add-Finding SKIP (T 'scan.gaming.nurNvidia') }
        return
    }
    $q = (Invoke-Native $smi.Source @('-q', '-i', '0')) -join "`n"
    $num = { param($pattern) if ($q -match $pattern) { [int]$Matches[1] } else { $null } }
    $gpuName = if ($q -match 'Product Name\s+:\s+(.+)') { $Matches[1].Trim() } else { 'NVIDIA-GPU' }
    $bar1 = & $num 'BAR1 Memory Usage\s+Total\s+:\s+(\d+)\s*MiB'
    $vram = & $num 'FB Memory Usage\s+Total\s+:\s+(\d+)\s*MiB'
    $genMax = & $num 'PCIe Generation\s+Max\s+:\s+(\d+)'
    $devMax = & $num 'Device Max\s+:\s+(\d+)'
    $hostMax = & $num 'Host Max\s+:\s+(\d+)'
    $width = & $num 'Link Width\s+Max\s+:\s+(\d+)x'
    if ($null -eq $bar1) { Add-Finding SKIP (T 'scan.gaming.smiUnlesbar'); return }
    Add-Table 'Grafikkarte: Anbindung (nvidia-smi)' @([pscustomobject][ordered]@{ GPU = $gpuName; GrafikspeicherMiB = $vram; BAR1MiB = $bar1; PCIeGenMax = $genMax; KarteKann = $devMax; MainboardKann = $hostMax; Lanes = $width })
    # Ohne Resizable BAR ist das Fenster der CPU auf den Grafikspeicher 256 MiB groß, mit ReBAR so groß wie der Grafikspeicher
    $rebar = $bar1 -gt 1024
    $link = if ($devMax -and $hostMax -and $devMax -gt $hostMax) { T 'scan.gaming.linkBegrenzt' $genMax $width $devMax $hostMax } else { T 'scan.gaming.link' $genMax $width }
    $value = T 'scan.gaming.rebar' $gpuName $(if ($rebar) { T 'scan.leistung.wert.an' } else { T 'scan.leistung.wert.aus' }) $bar1 $link
    if ($width -and $width -lt 16) { Add-Finding INFO $value (T 'scan.gaming.lanesEmpf' $width) }
    elseif (-not $rebar) { Add-Finding INFO $value (T 'scan.gaming.rebarEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'NVIDIA-Treibereinstellungen' {
    # Nur lesen (Idee 5.6, Stufe 1): globales DRS-Profil über nvapi64.dll aus System32; Fehler beenden nur diese Prüfung
    if (-not (Get-CimInstance Win32_VideoController | Where-Object Name -Match 'NVIDIA')) { Add-Finding SKIP (T 'scan.gaming.nurNvidia'); return }
    if (-not $script:NvidiaLib) { Add-Finding SKIP (T 'scan.gaming.nvidiaUnlesbar'); return }
    $roh = Get-MorpheusNvidiaDrsRoh
    if ($null -eq $roh) { Add-Finding SKIP (T 'scan.gaming.nvidiaKeinTreiber'); return }
    $b = Get-MorpheusNvidiaBefund -Roh @($roh.Zeilen)
    if ($b.Gelesen -eq 0) { Add-Finding SKIP (T 'scan.gaming.nvidiaUnlesbar'); return }
    Add-Table 'NVIDIA-Treibereinstellungen (globales Profil)' @($b.Zeilen)
    $value = T 'scan.nvidia.wert' $roh.Treiber $b.Zusammenfassung
    if ($b.Status -eq 'OK') { Add-Finding OK $value }
    else { Add-Finding $b.Status $value (@($b.Hinweise) -join ' ') }
}

Invoke-Check 'Spielebibliotheken' {
    # Tabelle der installierten Spiele zuerst, damit die frühen return der bisherigen Auswertung sie nicht verhindern
    $spiele = @()
    if ($script:Speicher) { $spiele = @($script:Speicher.spiele) }
    elseif ($script:SpeicherLib) {
        try { $spiele = @(Get-MorpheusSpiele -Manuell $script:SpielOrdner) } catch { $spiele = @() }
    }
    $spieleRows = foreach ($g in ($spiele | Where-Object { $null -ne $_ } | Sort-Object { [double]$_.bytes } -Descending)) {
        $zuletzt = ''
        if ($g.zuletztGespielt) { try { $zuletzt = ([datetime]$g.zuletztGespielt).ToString('yyyy-MM-dd HH:mm') } catch { $zuletzt = '' } }
        [pscustomobject][ordered]@{
            Plattform       = [string]$g.plattform
            Name            = [string]$g.name
            Laufwerk        = [string]$g.laufwerk
            Groesse         = Format-Size ([double]$g.bytes)
            Bytes           = [double]$g.bytes
            ZuletztGespielt = $zuletzt
            Pfad            = [string]$g.pfad
            Hinweis         = $(if ($g.groesseUnsicher) { (T 'scan.gaming.groesseEingeschraenkt') } else { '' })
        }
    }
    Add-Table 'Installierte Spiele' @($spieleRows)
    $libs = New-Object System.Collections.Generic.List[object]
    $addLib = { param($Launcher, $Path, $Games, $Bytes) if ($Path -and (Test-Path -LiteralPath $Path)) { $libs.Add([pscustomobject]@{ Launcher = $Launcher; Pfad = $Path; Spiele = $Games; Bytes = $Bytes }) } }
    # Steam: libraryfolders.vdf listet alle Bibliotheken, appmanifest_*.acf je Spiel mit Größe
    $steam = Get-RegValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
    $vdf = if ($steam) { Join-Path ($steam -replace '/', '\') 'steamapps\libraryfolders.vdf' }
    if ($vdf -and (Test-Path -LiteralPath $vdf)) {
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $p = $m.Groups[1].Value -replace '\\\\', '\'
            $acf = @(Get-ChildItem -LiteralPath (Join-Path $p 'steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)
            $bytes = 0
            foreach ($a in $acf) { if ((Get-Content -LiteralPath $a.FullName -Raw) -match '"SizeOnDisk"\s+"(\d+)"') { $bytes += [double]$Matches[1] } }
            & $addLib 'Steam' $p $acf.Count $bytes
        }
    }
    # Epic: ein Manifest je Spiel
    $epic = @(Get-ChildItem -LiteralPath "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests" -Filter '*.item' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object InstallLocation)
    foreach ($g in ($epic | Group-Object { Split-Path -Parent $_.InstallLocation })) { & $addLib 'Epic' $g.Name $g.Count ([double]($g.Group | Measure-Object InstallSize -Sum).Sum) }
    # GOG und Ubisoft: Installationsordner je Spiel in der Registry
    $regGames = @(
        @{ Launcher = 'GOG'; Key = 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games\*'; Value = 'path' }
        @{ Launcher = 'Ubisoft'; Key = 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs\*'; Value = 'InstallDir' }
    )
    foreach ($r in $regGames) {
        $paths = @(Get-ItemProperty $r.Key -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.($r.Value) } | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') -replace '/', '\' })
        foreach ($g in ($paths | Group-Object { Split-Path -Parent $_ })) { & $addLib $r.Launcher $g.Name $g.Count 0 }
    }
    # Xbox-App: Laufwerke mit Spielebibliothek haben eine Datei .GamingRoot im Stammverzeichnis
    foreach ($v in @(Get-Volume | Where-Object { $_.DriveLetter -and [string]$_.DriveType -eq 'Fixed' })) {
        $root = "$($v.DriveLetter):\"
        if (Test-Path -LiteralPath (Join-Path $root '.GamingRoot')) {
            $dir = Join-Path $root 'XboxGames'
            & $addLib 'Xbox' $dir @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object Name -NE 'GameSave').Count 0
        }
    }
    if (-not $libs.Count) { Add-Finding OK (T 'scan.gaming.keineBibliotheken'); return }

    $vols = @{}
    Get-Volume | Where-Object DriveLetter | ForEach-Object { $vols[[string]$_.DriveLetter] = $_ }
    $rows = foreach ($l in $libs) {
        $letter = $l.Pfad.Substring(0, 1).ToUpper()
        $v = $vols[$letter]
        [pscustomobject][ordered]@{
            Launcher    = $l.Launcher
            Pfad        = $l.Pfad
            Laufwerk    = "${letter}:"
            Typ         = Get-DriveKind $letter
            Spiele      = $l.Spiele
            Groesse     = $(if ($l.Bytes) { Format-Size $l.Bytes } else { '' })
            FreiProzent = $(if ($v -and $v.Size) { [int](100 * $v.SizeRemaining / $v.Size) } else { $null })
            Frei        = $(if ($v) { Format-Size $v.SizeRemaining } else { '' })
        }
    }
    $rows = @($rows | Where-Object Spiele)
    Add-Table 'Spielebibliotheken' $rows
    if (-not $rows) { Add-Finding OK (T 'scan.gaming.bibliothekenOhneSpiele'); return }
    $drives = @($rows | Group-Object Laufwerk | ForEach-Object {
            $f = $_.Group[0]
            [pscustomobject]@{ Laufwerk = $_.Name; Typ = $f.Typ; FreiProzent = $f.FreiProzent; Frei = $f.Frei; Spiele = ($_.Group | Measure-Object Spiele -Sum).Sum; Quellen = (($_.Group | Group-Object Launcher | ForEach-Object { "$($_.Name) $(($_.Group | Measure-Object Spiele -Sum).Sum)" }) -join ', ') }
        } | Sort-Object Spiele -Descending)
    $summary = ($drives | ForEach-Object { (T 'scan.gaming.bibZeile' $_.Laufwerk $_.Typ $_.FreiProzent $_.Quellen) }) -join '; '
    $hdd = @($drives | Where-Object Typ -EQ 'HDD')
    $full = @($drives | Where-Object { $null -ne $_.FreiProzent -and $_.FreiProzent -lt 20 })
    # Ziel für umzuziehende Spiele: SSD mit dem meisten freien Platz, NVMe bevorzugt
    $target = @(Get-Volume | Where-Object { $_.DriveLetter -and [string]$_.DriveType -eq 'Fixed' -and $_.Size -gt 100GB } | ForEach-Object {
            [pscustomobject]@{ Laufwerk = "$($_.DriveLetter):"; Typ = Get-DriveKind $_.DriveLetter; Frei = $_.SizeRemaining }
        } | Where-Object { $_.Typ -like '*SSD' -and $_.Laufwerk -notin $full.Laufwerk } | Sort-Object { $_.Typ -ne 'NVMe-SSD' }, { - $_.Frei } | Select-Object -First 1)
    $targetText = if ($target) { T 'scan.gaming.bibZiel' $target[0].Laufwerk $target[0].Typ (Format-Size $target[0].Frei) } else { '' }
    $move = T 'scan.gaming.bibUmziehen'
    if (@($full | Where-Object { $_.FreiProzent -lt 10 })) { Add-Finding WARN $summary ((T 'scan.gaming.bibVoll') + $targetText + $move) }
    elseif ($hdd -or $full) {
        $why = @()
        if ($hdd) { $why += (T 'scan.gaming.bibHdd' (($hdd | ForEach-Object Laufwerk) -join ', ')) }
        if ($full) { $why += (T 'scan.gaming.bibWenigPlatz' (($full | ForEach-Object { "$($_.Laufwerk) ($($_.FreiProzent) %)" }) -join ', ')) }
        Add-Finding INFO $summary (($why -join ' ') + $targetText + $move)
    }
    else { Add-Finding OK $summary }
}

Invoke-Check 'Netzwerkkarte: Energiesparfunktionen' {
    $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and [string]$_.PhysicalMediaType -match '802\.3' })
    if (-not $ad) { Add-Finding OK (T 'scan.gaming.keinKabelAdapter'); return }
    # Energiesparfunktionen, die beim Aufwachen der Verbindung kurze Latenzspitzen verursachen können
    $saving = [ordered]@{ '*EEE' = 'Energy Efficient Ethernet'; 'EEELinkAdvertisement' = 'Energy Efficient Ethernet'; '*GreenEthernet' = 'Green Ethernet'; 'EnableGreenEthernet' = 'Green Ethernet'; 'AdvancedEEE' = 'Advanced EEE'; 'ULPMode' = 'Ultra Low Power Mode'; 'PowerSavingMode' = 'Power Saving Mode' }
    $hits = foreach ($a in $ad) {
        foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue | Where-Object { $_.RegistryKeyword -in $saving.Keys })) {
            if ("$(@($p.RegistryValue)[0])" -ne '0') { [pscustomobject]@{ Adapter = $a.Name; Name = $p.DisplayName; Keyword = $p.RegistryKeyword } }
        }
    }
    $hits = @($hits)
    if (-not $hits) { Add-Finding OK (T 'scan.gaming.keineEnergiespar' (($ad | ForEach-Object Name) -join ', ')); return }
    Add-Finding INFO (T 'scan.leistung.aktiv' (($hits | ForEach-Object { "$($_.Adapter): $($_.Name)" }) -join ', ')) (T 'scan.gaming.netzEnergiesparEmpf')
    $script:Findings[$script:Findings.Count - 1].Command = (($hits | ForEach-Object { "Set-NetAdapterAdvancedProperty -Name '$($_.Adapter)' -RegistryKeyword '$($_.Keyword)' -RegistryValue 0" }) -join "`n")
}

#endregion

#region Performance: Audio

# Idee 5.7, Stufe 2: nur lesen, nur belegte Fehlerursachen (kein Klangtuning). Logik in gui\lib\Audio.ps1.
Start-Section 'Performance' 'Audio'

Invoke-Check 'Audio: Treiberfehler' {
    if (-not $script:AudioLib) { Add-Finding SKIP (T 'scan.hilfe.fehler' 'Audio.ps1'); return }
    $b = Get-MorpheusAudioTreiberBefund -Geraete @(Get-MorpheusAudioGeraete)
    Add-Finding $b.Status $b.Value $b.Recommendation
}

Invoke-Check 'Audio: Dienste' {
    if (-not $script:AudioLib) { Add-Finding SKIP (T 'scan.hilfe.fehler' 'Audio.ps1'); return }
    $b = Get-MorpheusAudioDienstBefund -Dienste @(Get-MorpheusAudioDienste)
    Add-Finding $b.Status $b.Value $b.Recommendation
}

Invoke-Check 'Audio: Standardgeräte' {
    if (-not $script:AudioLib) { Add-Finding SKIP (T 'scan.hilfe.fehler' 'Audio.ps1'); return }
    $b = Get-MorpheusAudioStandardBefund -Roh (Get-MorpheusAudioStandard)
    if (@($b.Zeilen).Count) { Add-Table 'Audio: Standardgeräte' @($b.Zeilen) }
    Add-Finding $b.Status $b.Value $b.Recommendation
}

Invoke-Check 'Audio: USB-Energiesparen' {
    if (-not $script:AudioLib) { Add-Finding SKIP (T 'scan.hilfe.fehler' 'Audio.ps1'); return }
    $b = Get-MorpheusAudioUsbBefund -Endpunkte @(Get-MorpheusAudioEndpunkte) -EnergieHolen { Get-PowerSetting '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' }
    Add-Finding $b.Status $b.Value $b.Recommendation
}

Invoke-Check 'Audio: Ducking' {
    if (-not $script:AudioLib) { Add-Finding SKIP (T 'scan.hilfe.fehler' 'Audio.ps1'); return }
    $b = Get-MorpheusAudioDuckingBefund -Wert (Get-MorpheusAudioDucking)
    Add-Finding $b.Status $b.Value $b.Recommendation
}

#endregion

#region Performance: Auslastung

Start-Section 'Performance' 'Auslastung'

Invoke-Check 'CPU-Last (Stichprobe 5 s)' {
    $n = [Environment]::ProcessorCount
    $t0 = @{}
    Get-Process | ForEach-Object { if ($null -ne $_.CPU) { $t0[$_.Id] = $_.CPU } }
    $start = Get-Date
    $samples = for ($i = 0; $i -lt 5; $i++) {
        Start-Sleep -Seconds 1
        [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
    }
    $elapsed = ((Get-Date) - $start).TotalSeconds
    # Eigene Last herausrechnen: dieses Script und die aufrufende GUI (Elternprozesse bis zu 3 Ebenen)
    $own = @($PID)
    try {
        $id = $PID
        for ($i = 0; $i -lt 3; $i++) {
            $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop).ParentProcessId
            $pp = Get-Process -Id $parent -ErrorAction Stop
            if ($pp.ProcessName -notin 'powershell', 'pwsh', 'cmd') { break }
            $own += $parent; $id = $parent
        }
    }
    catch { }
    $ownShare = 0
    foreach ($p in @(Get-Process -Id $own -ErrorAction SilentlyContinue)) {
        if ($t0.ContainsKey($p.Id) -and $null -ne $p.CPU) { $ownShare += ($p.CPU - $t0[$p.Id]) / $elapsed / $n * 100 }
    }
    $rows = @(Get-Process | Where-Object { ($own -notcontains $_.Id) -and $t0.ContainsKey($_.Id) -and $null -ne $_.CPU } | ForEach-Object {
            [pscustomobject][ordered]@{ Prozess = $_.ProcessName; PID = $_.Id; CPU = [Math]::Round(($_.CPU - $t0[$_.Id]) / $elapsed / $n * 100, 1) }
        } | Where-Object CPU -GT 0 | Sort-Object CPU -Descending | Select-Object -First 15)
    Add-Table 'Top-Prozesse nach CPU (%, Stichprobe)' $rows
    $avg = [int][Math]::Max(0, (($samples | Measure-Object -Average).Average) - $ownShare)
    $top = ($rows | Select-Object -First 3 | ForEach-Object { "$($_.Prozess) $($_.CPU) %" }) -join ', '
    if ($avg -gt 25) { Add-Finding WARN (T 'scan.auslastung.cpuDurchschnitt' $avg $top) (T 'scan.auslastung.cpuHochEmpf') }
    elseif ($avg -gt 10) { Add-Finding INFO (T 'scan.auslastung.cpuDurchschnitt' $avg $top) (T 'scan.auslastung.cpuLeichtEmpf') }
    else { Add-Finding OK (T 'scan.auslastung.cpuDurchschnitt' $avg $top) }
}

Invoke-Check 'RAM-Auslastung' {
    $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $totalBytes = [double]$script:CS.TotalPhysicalMemory
    $usedPct = [int](100 * (1 - [double]$mem.AvailableBytes / $totalBytes))
    $commitPct = [int](100 * [double]$mem.CommittedBytes / [double]$mem.CommitLimit)
    $rows = @(Get-Process | Group-Object ProcessName | ForEach-Object {
            [pscustomobject][ordered]@{ Prozess = $_.Name; Anzahl = $_.Count; PrivatMB = [int](($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB); ArbeitssatzMB = [int](($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
        } | Sort-Object PrivatMB -Descending | Select-Object -First 15)
    Add-Table 'Top-Prozesse nach Arbeitsspeicher' $rows
    $top = ($rows | Select-Object -First 3 | ForEach-Object { "$($_.Prozess) $(Format-Size ($_.PrivatMB * 1MB))" }) -join ', '
    $value = T 'scan.auslastung.ram' $usedPct (Format-Size $totalBytes) $commitPct (Format-Size $mem.CommitLimit) $top
    if ($usedPct -gt 85) { Add-Finding WARN $value (T 'scan.auslastung.ramVollEmpf') }
    elseif ($usedPct -gt 70) { Add-Finding INFO $value (T 'scan.auslastung.ramEngEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Speicherkomprimierung' -NeedsAdmin {
    $mm = Get-MMAgent
    $mcText = if ($mm.MemoryCompression) { T 'scan.leistung.wert.an' } else { T 'scan.leistung.wert.aus' }
    $pcText = if ($mm.PageCombining) { T 'scan.leistung.wert.an' } else { T 'scan.leistung.wert.aus' }
    Add-Finding INFO (T 'scan.auslastung.kompression' $mcText $pcText) (T 'scan.auslastung.kompressionEmpf')
}

Invoke-Check 'Autostart-Umfang' {
    $active = @($script:AutostartRows | Where-Object Aktiv)
    $autoSvc = @($script:ThirdPartyServices | Where-Object Start -EQ 'Auto')
    $value = T 'scan.auslastung.autostart' $active.Count $autoSvc.Count
    if ($active.Count -gt 15) { Add-Finding WARN $value (T 'scan.auslastung.autostartVielEmpf') }
    elseif ($active.Count -gt 8) { Add-Finding INFO $value (T 'scan.auslastung.autostartEtwasEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Laufzeit seit Neustart' {
    $up = (Get-Date) - $script:OS.LastBootUpTime
    $value = T 'scan.auslastung.laufzeit' $up.Days $up.Hours
    if ($up.Days -gt 14) { Add-Finding INFO $value (T 'scan.auslastung.laufzeitEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Netzwerkverbindung' {
    $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -EQ 'Up')
    $rows = foreach ($a in $ad) {
        [pscustomobject][ordered]@{ Name = $a.Name; Beschreibung = $a.InterfaceDescription; Geschwindigkeit = $a.LinkSpeed; Medium = [string]$a.PhysicalMediaType; Treiber = $a.DriverVersion; Datum = $a.DriverDate }
    }
    Add-Table 'Netzwerkadapter' $rows
    $keywords = '*EEE', 'EEELinkAdvertisement', '*GreenEthernet', 'EnableGreenEthernet', '*InterruptModeration', '*FlowControl', '*SpeedDuplex', 'ULPMode', '*JumboPacket'
    $adv = foreach ($a in $ad) {
        Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue | Where-Object { $_.RegistryKeyword -in $keywords } |
            ForEach-Object { [pscustomobject][ordered]@{ Adapter = $a.Name; Einstellung = $_.DisplayName; Wert = $_.DisplayValue } }
    }
    Add-Table 'Netzwerkadapter: Energiespar- und Leistungseinstellungen' $adv
    $wired = @($ad | Where-Object { [string]$_.PhysicalMediaType -match '802\.3' })
    $slow = @($wired | Where-Object { $_.ReceiveLinkSpeed -lt 1e9 })
    if ($slow) { Add-Finding WARN (T 'scan.auslastung.lanLangsam' (($slow | ForEach-Object { "$($_.Name) $($_.LinkSpeed)" }) -join ', ')) (T 'scan.auslastung.lanLangsamEmpf') }
    elseif ($wired) { Add-Finding OK (($wired | ForEach-Object { "$($_.Name): $($_.LinkSpeed)" }) -join ', ') }
    elseif ($ad) { Add-Finding INFO (T 'scan.auslastung.nurWlan' (($ad | ForEach-Object { "$($_.Name) $($_.LinkSpeed)" }) -join ', ')) (T 'scan.auslastung.nurWlanEmpf') }
    else { Add-Finding INFO (T 'scan.auslastung.keinAdapter') }
}

#endregion

#region Performance: Stabilität

Start-Section 'Performance' 'Stabilität'

Invoke-Check 'Hardwarefehler (WHEA)' {
    $ev = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger' } -Max 500)
    $byId = $ev | Group-Object Id | ForEach-Object { "ID $($_.Name): $($_.Count)x" }
    Add-Table 'WHEA-Ereignisse' @($ev | Select-Object -First 50 | ForEach-Object { [pscustomobject][ordered]@{ Zeit = Format-Date $_.TimeCreated; ID = $_.Id; Meldung = ((([string]$_.Message) -split "`n")[0]).Trim() } })
    $fatal = @($ev | Where-Object { $_.Id -in 1, 18, 20 })
    $corrected = @($ev | Where-Object { $_.Id -in 19, 47 })
    $pcie = @($ev | Where-Object { $_.Id -eq 17 })
    $rec = T 'scan.stabilitaet.wheaEmpf'
    if ($fatal) { Add-Finding CRIT (T 'scan.stabilitaet.wheaSchwer' $fatal.Count ($byId -join ', ')) $rec }
    elseif ($corrected) { Add-Finding WARN (T 'scan.stabilitaet.wheaKorrigiert' $corrected.Count ($byId -join ', ')) $rec }
    elseif ($pcie) { Add-Finding INFO (T 'scan.stabilitaet.wheaPcie' $pcie.Count) (T 'scan.stabilitaet.wheaPcieEmpf') }
    else { Add-Finding OK (T 'scan.stabilitaet.wheaKeine' $EventDays) }
}

Invoke-Check 'Abstürze und unerwartete Neustarts' {
    $kp = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 } -Max 100)
    $bc = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } -Max 100)
    $artNeustart = T 'scan.stabilitaet.artNeustart'
    $artBluescreen = T 'scan.stabilitaet.artBluescreen'
    $rows = @()
    $rows += foreach ($e in $kp) { $d = Get-EventData $e; [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Art = $artNeustart; Code = $(if ([int64]$d['BugcheckCode']) { '0x{0:X}' -f [int64]$d['BugcheckCode'] } else { '' }) } }
    $rows += foreach ($e in $bc) { $d = Get-EventData $e; [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; Art = $artBluescreen; Code = (([string]$d['param1']) -split ' ')[0] } }
    $dumps = @(Get-ChildItem -LiteralPath "$env:SystemRoot\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    Add-Table 'Abstürze und unerwartete Neustarts' @($rows | Sort-Object Zeit -Descending)
    Add-Table 'Minidumps' @($dumps | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{ Datei = $_.Name; Datum = Format-Date $_.LastWriteTime } })
    $codes = @($rows | Where-Object Code | ForEach-Object Code | Select-Object -Unique)
    $value = if ($codes) { T 'scan.stabilitaet.abstuerzeCodes' $kp.Count $bc.Count $EventDays ($codes -join ', ') $dumps.Count } else { T 'scan.stabilitaet.abstuerze' $kp.Count $bc.Count $EventDays $dumps.Count }
    if ($kp -or $bc) { Add-Finding WARN $value (T 'scan.stabilitaet.abstuerzeEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Grafiktreiber-Abstürze' {
    $tdr = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101 } -Max 100)
    $nv = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'nvlddmkm'; Level = 1, 2 } -Max 100)
    if ($tdr -or $nv.Count -gt 3) { Add-Finding WARN (T 'scan.stabilitaet.tdr' $tdr.Count $nv.Count) (T 'scan.stabilitaet.tdrEmpf') }
    elseif ($nv) { Add-Finding INFO (T 'scan.stabilitaet.nvFehler' $nv.Count) (T 'scan.stabilitaet.nvFehlerEmpf') }
    else { Add-Finding OK (T 'scan.ereignisse.keineInTagen' $EventDays) }
}

Invoke-Check 'Leistungsdrosselung durch Firmware' {
    $ev = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37 } -Max 500)
    if ($ev.Count -gt 10) { Add-Finding WARN (T 'scan.stabilitaet.drosselung' $ev.Count) (T 'scan.stabilitaet.drosselungHochEmpf') }
    elseif ($ev) { Add-Finding INFO (T 'scan.stabilitaet.drosselung' $ev.Count) (T 'scan.stabilitaet.drosselungWenigEmpf') }
    else { Add-Finding OK (T 'scan.ereignisse.keineInTagen' $EventDays) }
}

Invoke-Check 'Programmabstürze' {
    $crash = @(Get-RecentEvents @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000 } -Max 500)
    $hang = @(Get-RecentEvents @{ LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002 } -Max 200)
    $all = @($crash | ForEach-Object { [pscustomobject]@{ App = [string]$_.Properties[0].Value; Art = 'Absturz' } }) + @($hang | ForEach-Object { [pscustomobject]@{ App = [string]$_.Properties[0].Value; Art = 'Hänger' } })
    $rows = @($all | Group-Object App | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
            [pscustomobject][ordered]@{ Programm = $_.Name; Abstuerze = @($_.Group | Where-Object Art -EQ 'Absturz').Count; Haenger = @($_.Group | Where-Object Art -EQ 'Hänger').Count }
        })
    Add-Table 'Programmabstürze' $rows
    $top = ($rows | Select-Object -First 3 | ForEach-Object { "$($_.Programm) ($($_.Abstuerze + $_.Haenger))" }) -join ', '
    if ($all.Count -gt 20) { Add-Finding WARN (T 'scan.stabilitaet.programme' $crash.Count $hang.Count $top) (T 'scan.stabilitaet.programmeEmpf') }
    elseif ($all) { Add-Finding INFO (T 'scan.stabilitaet.programme' $crash.Count $hang.Count $top) }
    else { Add-Finding OK (T 'scan.ereignisse.keineInTagen' $EventDays) }
}

Invoke-Check 'Dienstfehler' {
    $ev = @(Get-RecentEvents @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7000, 7001, 7009, 7011, 7022, 7023, 7024, 7026, 7031, 7034, 7038, 7043 } -Max 500)
    # Bei 7009/7011 (Zeitüberschreitung) steht zuerst die Wartezeit, dann der Dienst.
    $rows = @($ev | Group-Object { ([string]$_.Properties[$(if ($_.Id -in 7009, 7011) { 1 } else { 0 })].Value).Trim() } | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
            $n = $_.Name
            $note = ''
            foreach ($p in $script:KnownHarmless.ServiceErrors.Keys) { if ($n -match $p) { $note = (T 'scan.stabilitaet.bekanntHarmlos' ($script:KnownHarmless.ServiceErrors[$p])); break } }
            # Gibt es den Dienst nicht mehr, stammen die Fehler aus der Zeit vor der Deinstallation
            if (-not $note -and -not ($script:Services | Where-Object { $_.Name -eq $n -or $_.DisplayName -eq $n })) { $note = (T 'scan.stabilitaet.dienstEntfernt') }
            [pscustomobject][ordered]@{ Dienst = $n; Anzahl = $_.Count; Einordnung = $note }
        })
    Add-Table 'Dienstfehler' $rows
    $open = @($rows | Where-Object { -not $_.Einordnung })
    $explained = ($rows | Where-Object Einordnung | Measure-Object Anzahl -Sum).Sum
    $explainedText = if ($explained) { T 'scan.stabilitaet.dienstErklaert' $explained } else { '' }
    if ($open) { Add-Finding INFO (T 'scan.stabilitaet.dienstFehler' ($open | Measure-Object Anzahl -Sum).Sum (($open | Select-Object -First 3 | ForEach-Object { "$($_.Dienst) ($($_.Anzahl))" }) -join ', ') $explainedText) (T 'scan.stabilitaet.dienstFehlerEmpf') }
    elseif ($ev) { Add-Finding OK (T 'scan.stabilitaet.dienstAlleHarmlos' $ev.Count) }
    else { Add-Finding OK (T 'scan.ereignisse.keineInTagen' $EventDays) }
}

Invoke-Check 'Datenträgerfehler' {
    $sets = @(
        @{ ProviderName = 'disk'; Id = 7, 11, 51, 153 }
        @{ ProviderName = 'Ntfs'; Id = 55, 137, 140 }
        @{ ProviderName = 'Microsoft-Windows-Ntfs'; Id = 55, 137, 140 }
        @{ ProviderName = 'stornvme'; Id = 11 }
        @{ ProviderName = 'storahci'; Id = 129 }
    )
    $ev = @()
    foreach ($s in $sets) { $ev += @(Get-RecentEvents (@{ LogName = 'System' } + $s) -Max 200) }
    $summary = @($ev | Group-Object { "$($_.ProviderName) $($_.Id)" } | ForEach-Object { "$($_.Name): $($_.Count)x" })
    if ($ev) { Add-Finding WARN ($summary -join ', ') (T 'scan.stabilitaet.datentraegerEmpf') }
    else { Add-Finding OK (T 'scan.ereignisse.keineInTagen' $EventDays) }
}

Invoke-Check 'Startdauer' {
    $log = 'Microsoft-Windows-Diagnostics-Performance/Operational'
    $boots = @(Get-RecentEvents @{ LogName = $log; Id = 100 } -Max 5 -AllTime)
    if (-not $boots) { Add-Finding SKIP (T 'scan.stabilitaet.keineStartmessungen'); return }
    $rows = foreach ($e in $boots) {
        $d = Get-EventData $e
        [pscustomobject][ordered]@{ Zeit = Format-Date $e.TimeCreated; GesamtSek = [Math]::Round([int]$d['BootTime'] / 1000, 1); HauptpfadSek = [Math]::Round([int]$d['MainPathBootTime'] / 1000, 1); NachAnmeldungSek = [Math]::Round([int]$d['BootPostBootTime'] / 1000, 1) }
    }
    $rows = @($rows)
    Add-Table 'Startdauer (letzte Messungen)' $rows
    # Startbremsen nur aus dem Auswertungszeitraum, sonst tauchen längst behobene Ursachen auf
    $slow = @(Get-RecentEvents @{ LogName = $log; Id = 101, 102, 103, 106, 109 } -Max 50)
    $bremsArt = @{ 101 = (T 'scan.stabilitaet.bremseProgramm'); 102 = (T 'scan.stabilitaet.bremseTreiber'); 103 = (T 'scan.stabilitaet.bremseDienst'); 106 = (T 'scan.stabilitaet.bremseHintergrund'); 109 = (T 'scan.stabilitaet.bremseGeraet') }
    $slowRows = @($slow | ForEach-Object {
            $d = Get-EventData $_
            [pscustomobject][ordered]@{ Zeit = Format-Date $_.TimeCreated; Art = $bremsArt[$_.Id]; Name = $(if ($d['FriendlyName']) { $d['FriendlyName'] } else { $d['Name'] }); VerzoegerungMs = [int]$d['DegradationTime'] }
        } | Sort-Object VerzoegerungMs -Descending | Select-Object -First 15)
    Add-Table 'Startbremsen' $slowRows
    $avgMain = [Math]::Round(($rows | Measure-Object HauptpfadSek -Average).Average, 1)
    $avgPost = [Math]::Round(($rows | Measure-Object NachAnmeldungSek -Average).Average, 1)
    $topSlow = ($slowRows | Select-Object -First 3 | ForEach-Object { "$($_.Name) (+$([int]($_.VerzoegerungMs / 1000)) s)" }) -join ', '
    $value = if ($topSlow) { T 'scan.stabilitaet.startdauerBremsen' ([string]$avgMain) ([string]$avgPost) $topSlow } else { T 'scan.stabilitaet.startdauer' ([string]$avgMain) ([string]$avgPost) }
    if ($avgMain -gt 40) { Add-Finding WARN $value (T 'scan.stabilitaet.startdauerEmpf') }
    else { Add-Finding OK $value }
}

Invoke-Check 'Zuverlässigkeitsindex' {
    $r = Get-CimInstance Win32_ReliabilityStabilityMetrics -ErrorAction Stop | Sort-Object TimeGenerated -Descending | Select-Object -First 1
    if (-not $r) { Add-Finding SKIP (T 'scan.stabilitaet.keineDaten'); return }
    $idx = [Math]::Round($r.SystemStabilityIndex, 1)
    if ($idx -lt 5) { Add-Finding WARN (T 'scan.stabilitaet.index' ([string]$idx)) (T 'scan.stabilitaet.indexWarnEmpf') }
    elseif ($idx -lt 8) { Add-Finding INFO (T 'scan.stabilitaet.index' ([string]$idx)) (T 'scan.stabilitaet.indexInfoEmpf') }
    else { Add-Finding OK (T 'scan.stabilitaet.index' ([string]$idx)) }
}

#endregion

#region Tipps und Anleitungen

# Aus lang\<sprache>\hilfe.psd1: Erklärungen für den HTML-Bericht und je Prüfung Aufwand/Nutzen/Risiko plus Anleitung.
# Ein Hinweis mit passendem Tipp-Eintrag wird zum Tipp (lohnende Optimierung); ohne Eintrag bleibt er reine Information.
$script:Help = $null
try { $script:Help = Get-MorpheusHilfe -Sprache $Sprache } catch { Write-Warning (T 'bericht.hilfeNichtLesbar' $_.Exception.Message) }
$script:LevelValue = @{ gering = 1; mittel = 2; hoch = 3 }

# Reihenfolge der Tipps: Nutzen zählt doppelt, Aufwand und Risiko ziehen ab.
function Get-TipScore {
    param($F)
    if (-not $F.Benefit) { return -99 }
    $lv = $script:LevelValue
    2 * $lv[$F.Benefit] - $lv[$F.Effort] - ($lv[$F.Risk] - 1)
}

if ($script:Help -and $script:Help.Tipps) {
    foreach ($f in $script:Findings) {
        if ($f.Status -notin 'CRIT', 'WARN', 'INFO') { continue }
        $t = @($script:Help.Tipps[$f.Check]) | Where-Object { $_ -and (-not $_.Match -or $f.ValueDe -match $_.Match) } | Select-Object -First 1
        if (-not $t) { continue }
        $f.Steps = @($t.Schritte | Where-Object { $_ })
        if (-not $f.Command -and $t.Befehl) { $f.Command = [string]$t.Befehl }
        # Reine Durchsicht (NurAnleitung) bleibt ein Hinweis, ebenso Tipps für ein anderes Profil
        if ($f.Status -eq 'INFO' -and ($t.NurAnleitung -or ($t.Profile -and $script:Profile -notin @($t.Profile)))) { continue }
        $f.Effort = [string]$t.Aufwand
        $f.Benefit = [string]$t.Nutzen
        $f.Risk = [string]$t.Risiko
        if ($f.Status -eq 'INFO') { $f.Status = 'TIPP' }
    }
}

#endregion

#region Akzeptierte Abweichungen

# Eine Regel greift nur, wenn Prüfung (Wildcards erlaubt) und Muster auf den Befund passen.
# Ändert sich der Befund (z. B. ein weiteres Programm kommt hinzu), passt das Muster nicht mehr und die Warnung kehrt zurück.
# Die Regeln wurden früh eingelesen ($script:AkzeptanzRegeln); Regeln mit Datei gelten nur für Datei-Zeilen (Sigcheck-Prüfung).
$acceptRules = @($script:AkzeptanzRegeln)
$expiredSet = New-Object 'System.Collections.Generic.HashSet[object]'   # Befunde, deren Akzeptanz abgelaufen ist (für den Bericht)
foreach ($f in $script:Findings) {
    if ($f.Status -notin 'CRIT', 'WARN', 'TIPP', 'INFO') { continue }
    foreach ($r in $acceptRules) {
        if ($r.Datei) { continue }
        if ($f.Check -notlike $r.Check) { continue }
        if ($r.Match -and ($f.Value -notmatch $r.Match) -and ($f.ValueDe -notmatch $r.Match)) { continue }
        # Unlesbares Ablaufdatum (z. B. von Hand '31.12.2027') gilt als abgelaufen: Die Warnung kommt zurück, statt dass die Schleife abbricht
        $untilDate = $null
        if ($r.Until) { $tmpDate = [datetime]::MinValue; if ([datetime]::TryParseExact([string]$r.Until, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$tmpDate)) { $untilDate = $tmpDate } else { $untilDate = [datetime]::MinValue } }
        if ($r.Until -and ($untilDate -lt (Get-Date).Date)) {
            if ($untilDate -eq [datetime]::MinValue) { $f.Note = T 'bericht.akzeptanz.unlesbar' $r.Until $r.Reason; [void]$expiredSet.Remove($f) }
            else { $f.Note = T 'bericht.akzeptanz.abgelaufen' $r.Until $r.Reason; [void]$expiredSet.Add($f) }
            continue
        }
        $f.OriginalStatus = $f.Status
        $f.Status = 'ACK'
        $f.Note = $r.Reason + $(if ($r.Until) { T 'bericht.akzeptanz.giltBis' $r.Until } else { '' })
        [void]$expiredSet.Remove($f)
        break
    }
}

#endregion

#region Bericht

$duration = (Get-Date) - $startedAt
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$mdPath = Join-Path $OutputDir "pc-check_$stamp.md"
$jsonPath = Join-Path $OutputDir "pc-check_$stamp.json"

$script:StatusNamen = @{ CRIT = (T 'bericht.status.CRIT'); WARN = (T 'bericht.status.WARN'); TIPP = (T 'bericht.status.TIPP'); ACK = (T 'bericht.status.ACK'); INFO = (T 'bericht.status.INFO'); OK = (T 'bericht.status.OK'); SKIP = (T 'bericht.status.SKIP') }
$label = @{ CRIT = ('🔴 ' + $script:StatusNamen.CRIT); WARN = ('🟠 ' + $script:StatusNamen.WARN); TIPP = ('💡 ' + $script:StatusNamen.TIPP); ACK = ('✅ ' + $script:StatusNamen.ACK); INFO = ('🔵 ' + $script:StatusNamen.INFO); OK = ('🟢 ' + $script:StatusNamen.OK); SKIP = ('⚪ ' + $script:StatusNamen.SKIP) }
$rank = @{ CRIT = 0; WARN = 1; TIPP = 2; INFO = 3; ACK = 4; SKIP = 5; OK = 6 }
$tips = @($script:Findings | Where-Object Status -EQ 'TIPP' | Sort-Object { - (Get-TipScore $_) }, Area, Category)

# Anzeige der Stufen (gering/mittel/hoch bleiben in den Daten Kennungen) und des Profils
function Get-StufeName {
    param([string]$Stufe)
    switch ($Stufe) {
        'gering' { T 'bericht.stufe.gering' }
        'mittel' { T 'bericht.stufe.mittel' }
        'hoch' { T 'bericht.stufe.hoch' }
        default { $Stufe }
    }
}
function Get-ProfilName {
    param([string]$Profil)
    switch ($Profil) {
        'Gaming' { T 'bericht.profil.gaming' }
        'Office' { T 'bericht.profil.office' }
        'Laptop' { T 'bericht.profil.laptop' }
        default { $Profil }
    }
}
# Name einer Prüfung in der Sprache des Scans (CheckName setzt Add-Finding), sonst die Kennung
function Get-PruefName {
    param($F)
    if ($F.CheckName) { return [string]$F.CheckName }
    return [string]$F.Check
}
# Spaltenüberschriften der Vergleichs- und Update-Tabellen (die Eigenschaftsnamen bleiben Kennungen)
$script:ChangesSpalten = @{ 'Prüfung' = (T 'bericht.spalte.pruefung'); Vorher = (T 'bericht.spalte.vorher'); Jetzt = (T 'bericht.spalte.jetzt'); Befund = (T 'bericht.spalte.befund') }
$script:UpdateSpalten = @{ Programm = (T 'bericht.spalte.programm'); Von = (T 'bericht.spalte.von'); Auf = (T 'bericht.spalte.auf'); Ergebnis = (T 'bericht.spalte.ergebnis') }

function ConvertTo-MdCell {
    param($Text)
    if ($null -eq $Text) { return '' }
    (([string]$Text) -replace '\|', '\|' -replace '[\r\n]+', ' ').Trim()
}

function ConvertTo-MdTable {
    param([object[]]$Rows, [int]$Max = 150, [hashtable]$Spaltennamen)
    $Rows = @($Rows | Where-Object { $null -ne $_ })
    if (-not $Rows.Count) { return ((T 'bericht.md.keineEintraege') + "`n") }
    $cols = @($Rows[0].PSObject.Properties | ForEach-Object Name)
    $kopf = @($cols | ForEach-Object { if ($Spaltennamen -and $Spaltennamen[$_]) { $Spaltennamen[$_] } else { Get-MorpheusAnzeige 'spalte' $_ } })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('| ' + ($kopf -join ' | ') + ' |')
    [void]$sb.AppendLine('|' + (($cols | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in ($Rows | Select-Object -First $Max)) {
        [void]$sb.AppendLine('| ' + (($cols | ForEach-Object { ConvertTo-MdCell $r.$_ }) -join ' | ') + ' |')
    }
    if ($Rows.Count -gt $Max) { [void]$sb.AppendLine("`n" + (T 'bericht.md.weitereEintraege' ($Rows.Count - $Max))) }
    $sb.ToString()
}

# Vergleich mit dem vorigen Bericht: geänderte Prüfergebnisse und neue/verschwundene Einträge in den Bestandslisten.
# Läuft vor dem Schreiben des neuen Berichts, damit er nicht mit sich selbst verglichen wird.
# Verglichen wird über die Kennungen (Kategorie, Prüfung, Tabellentitel); der ältere Bericht kann in der anderen Sprache entstanden sein.
# Angezeigt wird der Name aus dem aktuellen Lauf, sonst die Kennung.
$changes = $null
$prevFile = if ($CompareWith) { Get-Item -LiteralPath $CompareWith -ErrorAction SilentlyContinue }
else { Get-ChildItem -LiteralPath $OutputDir -Filter 'pc-check_*.json' -ErrorAction SilentlyContinue | Where-Object FullName -NE $jsonPath | Sort-Object LastWriteTime | Select-Object -Last 1 }
if ($prevFile) {
    try {
        $prev = Get-Content -LiteralPath $prevFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $old = @{}
        foreach ($f in @($prev.Findings)) { $old["$($f.Category)|$($f.Check)"] = $f }
        $seen = @{}
        $statusRows = New-Object System.Collections.Generic.List[object]
        foreach ($f in $script:Findings) {
            $k = "$($f.Category)|$($f.Check)"
            $seen[$k] = $true
            $o = $old[$k]
            # Hinweis und Tipp sind derselbe Befund, nur anders eingeordnet (Berichte vor 1.5.0 kennen keinen Tipp)
            $same = $o -and (($o.Status -eq $f.Status) -or ((@($o.Status, $f.Status) | Where-Object { $_ -in 'INFO', 'TIPP' }).Count -eq 2 -and $o.Value -eq $f.Value))
            if (-not $o) { $statusRows.Add([pscustomobject][ordered]@{ 'Prüfung' = (Get-PruefName $f); Vorher = (T 'bericht.change.neu'); Jetzt = $label[$f.Status]; Befund = $f.Value }) }
            elseif (-not $same) { $statusRows.Add([pscustomobject][ordered]@{ 'Prüfung' = (Get-PruefName $f); Vorher = $label[$o.Status]; Jetzt = $label[$f.Status]; Befund = $f.Value }) }
        }
        foreach ($k in $old.Keys) {
            if (-not $seen.ContainsKey($k)) { $statusRows.Add([pscustomobject][ordered]@{ 'Prüfung' = (Get-MorpheusAnzeige 'pruefung' ([string]$old[$k].Check)); Vorher = $label[$old[$k].Status]; Jetzt = (T 'bericht.change.entfaellt'); Befund = $old[$k].Value }) }
        }
        # Bestandslisten mit stabilem Schlüssel je Eintrag
        $inventories = [ordered]@{
            'Dienste von Drittanbietern'                       = { "$($_.Name) ($($_.Anzeige))" }
            'Treiber: geladene Drittanbieter-Treiber'          = { "$($_.Name) ($($_.Pfad))" }
            'Autostart-Einträge'                               = { "$($_.Ort): $($_.Name)" }
            'Autostarts (Autoruns, ohne Microsoft)'            = { "$($_.Kategorie): $($_.Eintrag)" }
            'Geplante Aufgaben (Drittanbieter und auffällige)' = { $_.Aufgabe }
            'Firewall: eigene Eingangsregeln (Zulassen)'       = { "$($_.Name) ($(if ($_.Programm) { $_.Programm } else { 'ohne Programm' }))" }
            'Unsignierte Systemdateien (Sigcheck)'             = { "$($_.Ordner): $($_.Datei)" }
            'Installierte Programme'                           = { "$($_.Name) $($_.Version)".Trim() }
            'Browser-Erweiterungen'                            = { "$($_.Browser): $($_.Name)" }
            'Lokale Benutzerkonten'                            = { $_.Name }
            'Administratoren'                                  = { $_.Mitglied }
            # Dynamische Ports (ab 49152) wählen Windows-Dienste bei jedem Start neu; sie wären reines Rauschen
            'Offene Netzwerkports (nicht nur lokal)'           = { if ([int]$_.Port -lt 49152) { "$($_.Protokoll) $($_.Port) ($($_.Prozess))" } }
        }
        $prevTitles = @($prev.Data.PSObject.Properties | ForEach-Object Name)
        $inventory = [ordered]@{}
        foreach ($title in $inventories.Keys) {
            if (-not $script:Tables.Contains($title) -or $title -notin $prevTitles) { continue }
            $keyOf = $inventories[$title]
            $now = @($script:Tables[$title] | ForEach-Object $keyOf | Where-Object { $_ } | Sort-Object -Unique)
            $before = @($prev.Data.$title | ForEach-Object $keyOf | Where-Object { $_ } | Sort-Object -Unique)
            $added = @($now | Where-Object { $_ -notin $before })
            $removed = @($before | Where-Object { $_ -notin $now })
            if ($added -or $removed) { $inventory[$title] = [ordered]@{ Neu = $added; Entfernt = $removed } }
        }
        $changes = [ordered]@{ VerglichenMit = $prevFile.Name; Erstellt = $prev.Meta.Erstellt; AdminVorher = [bool]$prev.Meta.Admin; Status = $statusRows.ToArray(); Bestand = $inventory }
    }
    catch { Write-Warning (T 'bericht.vergleichNichtMoeglich' $prevFile.Name $_.Exception.Message) }
}

# Verlauf über die bisherigen Berichte: einige Kennzahlen je Lauf für kleine Diagramme im HTML-Bericht
function Get-HistoryPoint {
    param($Erstellt, $Findings, $Data)
    $boot = @($Data.'Startdauer (letzte Messungen)' | Where-Object { $_ } | ForEach-Object { [double]$_.HauptpfadSek })
    $rel = $Findings | Where-Object Check -EQ 'Zuverlässigkeitsindex' | Select-Object -First 1
    $sysVol = @($Data.'Laufwerke (Volumes)' | Where-Object { $_.Laufwerk -eq $env:SystemDrive }) | Select-Object -First 1
    [pscustomobject][ordered]@{
        Datum    = [datetime]$Erstellt
        StartSek = $(if ($boot) { [Math]::Round(($boot | Measure-Object -Average).Average, 1) } else { $null })
        # "7 von 10" (Deutsch) bzw. "7 of 10" (Englisch): Berichte beider Sprachen zählen
        Index    = $(if ($rel -and $rel.Value -match '^([\d.,]+) (?:von|of)\b') { [double]($Matches[1] -replace ',', '.') } else { $null })
        FreiC    = $(if ($sysVol) { [double]$sysVol.FreiProzent } else { $null })
        Probleme = @($Findings | Where-Object { $_.Status -in 'CRIT', 'WARN' }).Count
    }
}
$history = New-Object System.Collections.Generic.List[object]
foreach ($hf in @(Get-ChildItem -LiteralPath $OutputDir -Filter 'pc-check_*.json' -ErrorAction SilentlyContinue | Where-Object FullName -NE $jsonPath | Sort-Object LastWriteTime | Select-Object -Last 11)) {
    try {
        $hj = Get-Content -LiteralPath $hf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $history.Add((Get-HistoryPoint ([datetime]::Parse($hj.Meta.Erstellt, [Globalization.CultureInfo]::InvariantCulture)) @($hj.Findings) $hj.Data))
    }
    catch { Write-Verbose "Verlauf: $($hf.Name) nicht lesbar" }
}
$history.Add((Get-HistoryPoint (Get-Date) $script:Findings.ToArray() ([pscustomobject]$script:Tables)))

$md = New-Object System.Text.StringBuilder
function W { param([string]$Line = '') [void]$md.AppendLine($Line) }
function Write-MdKopf {
    param([string[]]$Namen)
    W ('| ' + ($Namen -join ' | ') + ' |')
    W ('|' + (($Namen | ForEach-Object { '---' }) -join '|') + '|')
}
$profilAnzeige = Get-ProfilName $script:Profile

W "# $ProductName – $($ProductTagline): $env:COMPUTERNAME"
W ''
W ('- ' + (T 'bericht.md.erstellt' (Get-Date -Format 'yyyy-MM-dd HH:mm') ([int]$duration.TotalSeconds)))
W ('- ' + (T 'bericht.md.version' $ScriptVersion $PSVersionTable.PSVersion))
W ('- ' + (T 'bericht.md.admin' $(if ($script:IsAdmin) { T 'bericht.ja' } else { T 'bericht.md.adminNein' })))
W ('- ' + (T 'bericht.md.ereigniszeitraum' $EventDays))
W ('- ' + $(if ($script:ProfileAuto) { T 'bericht.md.profilAuto' $profilAnzeige } else { T 'bericht.md.profil' $profilAnzeige }))
W ('- ' + $(if (Test-Path -LiteralPath $AcceptedFile) { T 'bericht.md.akzeptanzlisteVorhanden' $AcceptedFile $acceptRules.Count } else { T 'bericht.md.akzeptanzlisteKeine' }))
W ''
W (T 'bericht.md.zusammenfassung')
W ''
W ('| ' + (T 'bericht.spalte.bereich') + ' | ' + ((@('CRIT', 'WARN', 'TIPP', 'ACK', 'INFO', 'OK', 'SKIP') | ForEach-Object { $label[$_] }) -join ' | ') + ' |')
W '|---|---|---|---|---|---|---|---|'
foreach ($area in 'Sicherheit', 'Performance') {
    $f = @($script:Findings | Where-Object Area -EQ $area)
    $c = foreach ($s in 'CRIT', 'WARN', 'TIPP', 'ACK', 'INFO', 'OK', 'SKIP') { @($f | Where-Object Status -EQ $s).Count }
    W "| $(Get-MorpheusAnzeige 'bereich' $area) | $($c -join ' | ') |"
}
W ''
W (T 'bericht.md.handlungsbedarf')
W ''
$todo = @($script:Findings | Where-Object { $_.Status -in 'CRIT', 'WARN' } | Sort-Object { $rank[$_.Status] }, Area, Category)
if ($todo) {
    Write-MdKopf @((T 'bericht.spalte.status'), (T 'bericht.spalte.bereich'), (T 'bericht.spalte.pruefung'), (T 'bericht.spalte.befund'), (T 'bericht.spalte.empfehlung'))
    foreach ($f in $todo) { W "| $($label[$f.Status]) | $($f.AreaName) / $($f.CategoryName) | $(ConvertTo-MdCell (Get-PruefName $f)) | $(ConvertTo-MdCell $f.Value) | $(ConvertTo-MdCell $f.Recommendation) |" }
}
else { W (T 'bericht.md.keineWarnungen') }
W ''
W (T 'bericht.md.tipps')
W ''
if ($tips) {
    Write-MdKopf @((T 'bericht.spalte.pruefung'), (T 'bericht.spalte.befund'), (T 'bericht.spalte.empfehlung'), (T 'bericht.spalte.nutzen'), (T 'bericht.spalte.aufwand'), (T 'bericht.spalte.risiko'))
    foreach ($f in $tips) { W "| $(ConvertTo-MdCell (Get-PruefName $f)) | $(ConvertTo-MdCell $f.Value) | $(ConvertTo-MdCell $f.Recommendation) | $(Get-StufeName $f.Benefit) | $(Get-StufeName $f.Effort) | $(Get-StufeName $f.Risk) |" }
}
else { W (T 'bericht.md.keine') }
W ''
W (T 'bericht.md.akzeptiert')
W ''
$accepted = @($script:Findings | Where-Object Status -EQ 'ACK')
if ($accepted) {
    Write-MdKopf @((T 'bericht.spalte.urspruenglich'), (T 'bericht.spalte.pruefung'), (T 'bericht.spalte.befund'), (T 'bericht.spalte.begruendung'))
    foreach ($f in $accepted) { W "| $($label[$f.OriginalStatus]) | $(ConvertTo-MdCell (Get-PruefName $f)) | $(ConvertTo-MdCell $f.Value) | $(ConvertTo-MdCell $f.Note) |" }
}
else { W (T 'bericht.md.keine') }
$expired = @($script:Findings | Where-Object { $expiredSet.Contains($_) })
if ($expired) { W ''; W (T 'bericht.md.abgelaufen' (($expired | ForEach-Object { Get-PruefName $_ }) -join ', ')) }
W ''
W (T 'bericht.md.aenderungen')
W ''
if (-not $changes) { W (T 'bericht.md.keinVorbericht') }
else {
    $adminNote = if ($changes.AdminVorher -ne [bool]$script:IsAdmin) { ' **' + (T 'bericht.achtung') + '** ' + $(if ($changes.AdminVorher) { T 'bericht.achtungMitAdmin' } else { T 'bericht.achtungOhneAdmin' }) } else { '' }
    W ((T 'bericht.md.verglichen' $changes.VerglichenMit $changes.Erstellt) + $adminNote)
    W ''
    if ($changes.Status.Count) { W (T 'bericht.md.geaenderteErgebnisse'); W ''; W (ConvertTo-MdTable $changes.Status 150 $script:ChangesSpalten) }
    foreach ($t in $changes.Bestand.Keys) {
        W "### $(Get-MorpheusAnzeige 'tabelle' $t)"
        W ''
        foreach ($x in ($changes.Bestand[$t].Neu | Select-Object -First 40)) { W "- ➕ $(ConvertTo-MdCell $x)" }
        foreach ($x in ($changes.Bestand[$t].Entfernt | Select-Object -First 40)) { W "- ➖ $(ConvertTo-MdCell $x)" }
        $more = @($changes.Bestand[$t].Neu).Count + @($changes.Bestand[$t].Entfernt).Count - 80
        if ($more -gt 0) { W (T 'bericht.md.weitereImJson') }
        W ''
    }
    if (-not $changes.Status.Count -and -not $changes.Bestand.Count) { W (T 'bericht.md.keineAenderungen') }
}
W ''
W (T 'bericht.md.allePruefungen')
foreach ($area in 'Sicherheit', 'Performance') {
    W ''
    W "### $(Get-MorpheusAnzeige 'bereich' $area)"
    foreach ($cat in @($script:Findings | Where-Object Area -EQ $area | ForEach-Object Category | Select-Object -Unique)) {
        W ''
        W "#### $(Get-MorpheusAnzeige 'kategorie' $cat)"
        W ''
        Write-MdKopf @((T 'bericht.spalte.status'), (T 'bericht.spalte.pruefung'), (T 'bericht.spalte.befund'), (T 'bericht.spalte.empfehlung'), (T 'bericht.spalte.anmerkung'))
        foreach ($f in ($script:Findings | Where-Object { $_.Area -eq $area -and $_.Category -eq $cat })) {
            $how = if (@($f.Steps).Count) { (T 'bericht.md.soGehts') + ((@($f.Steps) | ForEach-Object -Begin { $n = 0 } -Process { $n++; "$n. $_" }) -join ' ') } else { '' }
            if ($f.Command) { $how += (T 'bericht.md.befehl' ($f.Command -replace "`n", '; ')) }
            W "| $($label[$f.Status]) | $(ConvertTo-MdCell (Get-PruefName $f)) | $(ConvertTo-MdCell $f.Value) | $(ConvertTo-MdCell ($f.Recommendation + $how)) | $(ConvertTo-MdCell $f.Note) |"
        }
    }
}
W ''
W (T 'bericht.md.anhang')
foreach ($title in $script:Tables.Keys) {
    W ''
    W "### $(Get-MorpheusAnzeige 'tabelle' $title)"
    W ''
    W (ConvertTo-MdTable $script:Tables[$title])
}

$md.ToString() | Out-File -LiteralPath $mdPath -Encoding utf8
# Anzeigenamen der Tabellen und Spalten in der Sprache des Scans; die Schlüssel in Data bleiben deutsche Kennungen (2.6)
$tabellenNamen = [ordered]@{}
$spaltenNamen = [ordered]@{}
foreach ($title in $script:Tables.Keys) {
    $tabellenNamen[$title] = Get-MorpheusAnzeige 'tabelle' $title
    foreach ($row in @($script:Tables[$title])) {
        foreach ($pn in @($row.PSObject.Properties | ForEach-Object { $_.Name })) { if (-not $spaltenNamen.Contains($pn)) { $spaltenNamen[$pn] = Get-MorpheusAnzeige 'spalte' $pn } }
    }
}
[ordered]@{
    Meta     = [ordered]@{ Computer = $env:COMPUTERNAME; Erstellt = (Get-Date).ToString('s'); Version = $ScriptVersion; Admin = $script:IsAdmin; EventDays = $EventDays; DauerSek = [int]$duration.TotalSeconds; StoreAppContainer = $script:PackagedFrom; Profil = $script:Profile; Sprache = $Sprache }
    Findings = $script:Findings
    Changes  = $changes
    Data     = $script:Tables
    DataChecks = $script:TableChecks
    DataNamen = [ordered]@{ Tabellen = $tabellenNamen; Spalten = $spaltenNamen }
    Speicher = $script:Speicher
} | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $jsonPath -Encoding utf8

Write-Host ''
Write-Host (T 'bericht.konsole.ergebnis') -ForegroundColor Green
$colors = @{ CRIT = 'Red'; WARN = 'Yellow'; TIPP = 'Magenta'; ACK = 'DarkGreen'; INFO = 'Cyan'; OK = 'Green'; SKIP = 'Gray' }
foreach ($s in 'CRIT', 'WARN', 'TIPP', 'ACK', 'INFO', 'OK', 'SKIP') {
    Write-Host ('  {0,-14} {1}' -f $script:StatusNamen[$s], @($script:Findings | Where-Object Status -EQ $s).Count) -ForegroundColor $colors[$s]
}
if ($changes) {
    $added = 0; $removed = 0
    foreach ($t in $changes.Bestand.Keys) { $added += @($changes.Bestand[$t].Neu).Count; $removed += @($changes.Bestand[$t].Entfernt).Count }
    Write-Host ''
    Write-Host (T 'bericht.konsole.seitLetztemLauf' $changes.Erstellt $changes.Status.Count $added $removed) -ForegroundColor Cyan
}
Write-Host ''
Write-Host (T 'bericht.konsole.bericht' $mdPath)
Write-Host (T 'bericht.konsole.daten' $jsonPath)

#endregion


#region HTML-Bericht (Solarized Dark, eigenständig ohne Internetzugriff)

$updateResults = $null   # $null = Dialog nicht gezeigt, leer = nichts ausgewählt (für den HTML-Bericht)
# Nur fragen bzw. öffnen, wenn jemand an der Konsole sitzt (nicht bei umgeleiteter Eingabe oder -NonInteractive)
$interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-NonI' })

function ConvertTo-HtmlText { param($Text) [System.Net.WebUtility]::HtmlEncode([string]$Text) }

# Für die KI-Kopiervorlage: PC- und Benutzernamen, IP-/MAC-Adressen, SIDs und E-Mail-Adressen entfernen
function Protect-Text {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text -replace [regex]::Escape($env:COMPUTERNAME), '<PC>'
    if ($env:USERNAME.Length -ge 3) { $t = $t -replace [regex]::Escape($env:USERNAME), (T 'bericht.ki.benutzer') }
    $t = $t -replace '[\w.+-]+@[\w-]+\.[\w.-]+', (T 'bericht.ki.email')
    $t = $t -replace 'S-1-5-21-[\d-]+', '<SID>'
    $t = $t -replace '(?i)\b([0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b', '<MAC>'
    $t = $t -replace '\b(?:\d{1,3}\.){3}\d{1,3}\b', '<IP>'
    $t = $t -replace '(?i)\bfe80:[0-9a-f:%]*|\b[0-9a-f]{4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f:]+', '<IPv6>'
    $t
}

function Write-HtmlReport {
    param([Parameter(Mandatory)][string]$Path)

    $help = $script:Help
    $statusName = $script:StatusNamen
    $order = 'CRIT', 'WARN', 'TIPP', 'ACK', 'INFO', 'OK', 'SKIP'
    # ToArray statt @(): @() auf eine List[object] wirft in Windows PowerShell 5.1 "Argument types do not match"
    $findings = $script:Findings.ToArray()
    $count = @{}
    foreach ($s in $order) { $count[$s] = @($findings | Where-Object Status -EQ $s).Count }
    $profilAnzeige = Get-ProfilName $script:Profile

    $sb = New-Object System.Text.StringBuilder
    function A([string]$Line) { [void]$sb.AppendLine($Line) }
    # Jeder Text aus den Sprachdateien und jeder Wert aus dem Scan läuft durch HEnc, bevor er ins HTML kommt
    function HEnc($Text) { ConvertTo-HtmlText $Text }

    # Infotext (Was/Warum/Wann harmlos) zu einer Prüfung, sonst Erklärung der Kategorie
    function Get-Tip([string]$Check, [string]$Category) {
        if (-not $help) { return '' }
        $e = $help.Pruefungen[$Check]
        if ($e) { return "<b>$(HEnc (T 'bericht.html.tipWas'))</b> $(HEnc $e.Was)<br><b>$(HEnc (T 'bericht.html.tipWarum'))</b> $(HEnc $e.Warum)<br><b>$(HEnc (T 'bericht.html.tipHarmlos'))</b> $(HEnc $e.Harmlos)" }
        if ($help.Kategorien[$Category]) { return HEnc $help.Kategorien[$Category] }
        ''
    }
    function Get-InfoButton([string]$TipHtml) {
        if (-not $TipHtml) { return '' }
        "<button type=`"button`" class=`"info`" aria-label=`"$(HEnc (T 'bericht.html.erklaerung'))`" aria-expanded=`"false`">i</button><span class=`"tip`" role=`"tooltip`">$TipHtml</span>"
    }
    # Nutzen/Aufwand/Risiko als kleine Kennzeichen (die Stufen gering/mittel/hoch bleiben in den Klassen Kennungen)
    function Get-Levels($F) {
        if (-not $F.Benefit) { return '' }
        $p = foreach ($x in @(@((T 'bericht.spalte.nutzen'), $F.Benefit, 'n'), @((T 'bericht.spalte.aufwand'), $F.Effort, 'a'), @((T 'bericht.spalte.risiko'), $F.Risk, 'r'))) { if ($x[1]) { "<span class=`"lv lv-$($x[2])-$($x[1])`">$(HEnc $x[0]): $(HEnc (Get-StufeName $x[1]))</span>" } }
        "<div class=`"levels`">$($p -join '')</div>"
    }
    # Aufklappbare Anleitung: Klickweg und optional Befehl zum Kopieren
    function Get-HowTo($F) {
        $steps = @($F.Steps)
        if (-not $steps.Count -and -not $F.Command) { return '' }
        $h = '<details class="how"><summary>' + (HEnc (T 'bericht.html.soGehts')) + '</summary>'
        if ($steps.Count) { $h += '<ol>' + (($steps | ForEach-Object { "<li>$(HEnc $_)</li>" }) -join '') + '</ol>' }
        if ($F.Command) { $h += "<div class=`"cmd`"><div class=`"cmd-head`">$(HEnc (T 'bericht.html.befehlKopf')) <button type=`"button`" class=`"copy`">$(HEnc (T 'bericht.html.kopieren'))</button></div><pre>$(HEnc $F.Command)</pre></div>" }
        $h + '</details>'
    }
    function Get-Row($F, [string]$Id, [switch]$Summary) {
        $note = ''
        $pruefName = Get-PruefName $F
        if ($F.Status -eq 'ACK') { $note = "<div class=`"note`">$(HEnc (T 'bericht.html.urspruenglich' $statusName[$F.OriginalStatus] $F.Note))</div>" }
        elseif ($F.Note) { $note = "<div class=`"note`">$(HEnc $F.Note)</div>" }
        $text = (HEnc ("$pruefName $($F.Value) $($F.Recommendation) $($F.CategoryName)".ToLower()))
        $cls = if ($Summary) { 'row summary' } else { 'row' }
        $idAttr = if ($Summary) { '' } else { " id=`"$Id`"" }
        $check = if ($Summary) { "<a href=`"#$Id`">$(HEnc $pruefName)</a>" } else { HEnc $pruefName }
        $hint = if ($Summary) { '<div class="cat-hint">' + (HEnc $F.AreaName) + ' · ' + (HEnc $F.CategoryName) + '</div>' } else { '' }
        $infoBtn = Get-InfoButton (Get-Tip $F.Check $F.Category)
        $todo = if (-not $Summary -and $F.Status -in 'CRIT', 'WARN', 'TIPP') { '<div class="todo"><button type="button" data-mark="done" title="' + (HEnc (T 'bericht.html.erledigtTitel')) + '">' + (HEnc (T 'bericht.html.erledigt')) + '</button><button type="button" data-mark="later" title="' + (HEnc (T 'bericht.html.spaeterTitel')) + '">' + (HEnc (T 'bericht.html.spaeter')) + '</button></div>' } else { '' }
        "<div class=`"$cls s-$($F.Status)`"$idAttr data-status=`"$($F.Status)`" data-check=`"$(HEnc $F.Check)`" data-name=`"$(HEnc $pruefName)`" data-text=`"$text`">" +
        "<div class=`"c-status`"><span class=`"badge b-$($F.Status)`">$(HEnc $statusName[$F.Status])</span>$todo</div>" +
        "<div class=`"c-check`">$check$infoBtn$hint</div>" +
        "<div class=`"c-value`">$(HEnc $F.Value)$note</div>" +
        "<div class=`"c-rec`">$((HEnc $F.Recommendation) -replace 'ms-settings:[a-z-]+', '<a href="$0">$0</a>')$(Get-Levels $F)$(if (-not $Summary) { Get-HowTo $F })</div></div>"
    }
    # Kleines Liniendiagramm (SVG) für den Verlauf
    function Get-Chart([string]$Title, [string]$Prop, [string]$Unit, [string]$Better) {
        $pts = @($history | Where-Object { $null -ne $_.$Prop })
        if ($pts.Count -lt 2) { return '' }
        $w = 300; $h = 90; $padX = 8; $padY = 14
        $vals = @($pts | ForEach-Object { [double]$_.$Prop })
        $min = ($vals | Measure-Object -Minimum).Minimum; $max = ($vals | Measure-Object -Maximum).Maximum
        if ($max -eq $min) { $max = $min + 1 }
        $xy = for ($i = 0; $i -lt $pts.Count; $i++) {
            $x = $padX + ($w - 2 * $padX) * $i / ($pts.Count - 1)
            $y = $padY + ($h - 2 * $padY) * (1 - ($vals[$i] - $min) / ($max - $min))
            [pscustomobject]@{ X = [Math]::Round($x, 1); Y = [Math]::Round($y, 1); V = $vals[$i]; D = $pts[$i].Datum.ToString('dd.MM.yy') }
        }
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $line = ($xy | ForEach-Object { $_.X.ToString($inv) + ',' + $_.Y.ToString($inv) }) -join ' '
        $unitHtml = HEnc $Unit
        $dots = ($xy | ForEach-Object { "<circle cx=`"$($_.X.ToString($inv))`" cy=`"$($_.Y.ToString($inv))`" r=`"3`"><title>$($_.D): $($_.V) $unitHtml</title></circle>" }) -join ''
        $first = $vals[0]; $last = $vals[-1]
        $trend = if ($last -eq $first) { 'gleich' } elseif (($last -lt $first) -eq ($Better -eq 'low')) { 'besser' } else { 'schlechter' }
        $trendCls = @{ gleich = 'muted'; besser = 'add'; schlechter = 'rem' }[$trend]
        $trendText = switch ($trend) { 'gleich' { T 'bericht.html.trendGleich' } 'besser' { T 'bericht.html.trendBesser' } default { T 'bericht.html.trendSchlechter' } }
        "<div class=`"chart`"><div class=`"chart-head`"><span>$(HEnc $Title)</span><span class=`"$trendCls`">$last $unitHtml · $(HEnc $trendText)</span></div>" +
        "<svg viewBox=`"0 0 $w $h`" role=`"img`" aria-label=`"$(HEnc $Title)`"><polyline points=`"$line`"/>$dots</svg>" +
        "<div class=`"chart-foot`"><span>$($xy[0].D)</span><span>$($xy[-1].D)</span></div></div>"
    }
    function Get-Table($Rows, [int]$Max = 300, [hashtable]$Spaltennamen) {
        $Rows = @($Rows | Where-Object { $null -ne $_ })
        if (-not $Rows.Count) { return '<p class="muted">' + (HEnc (T 'bericht.html.keineEintraege')) + '</p>' }
        $cols = @($Rows[0].PSObject.Properties | ForEach-Object Name)
        $t = New-Object System.Text.StringBuilder
        [void]$t.Append('<div class="tablewrap"><table><thead><tr>')
        foreach ($c in $cols) {
            $kopf = if ($Spaltennamen -and $Spaltennamen[$c]) { $Spaltennamen[$c] } else { Get-MorpheusAnzeige 'spalte' $c }
            [void]$t.Append("<th>$(HEnc $kopf)</th>")
        }
        [void]$t.Append('</tr></thead><tbody>')
        foreach ($r in ($Rows | Select-Object -First $Max)) {
            [void]$t.Append('<tr>')
            foreach ($c in $cols) { [void]$t.Append("<td>$(HEnc $r.$c)</td>") }
            [void]$t.Append('</tr>')
        }
        [void]$t.Append('</tbody></table></div>')
        if ($Rows.Count -gt $Max) { [void]$t.Append("<p class=`"muted`">$(HEnc (T 'bericht.html.weitereEintraege' ($Rows.Count - $Max)))</p>") }
        $t.ToString()
    }

    # Ampel und die nächsten Schritte (Sicherheit vor Performance, Kritisch vor Warnung)
    if ($count.CRIT) { $amp = 'red'; $ampTitle = T 'bericht.html.ampelRotTitel'; $ampSub = T 'bericht.html.ampelRotText' }
    elseif ($count.WARN) { $amp = 'yellow'; $ampTitle = T 'bericht.html.ampelGelbTitel'; $ampSub = T 'bericht.html.ampelGelbText' }
    else { $amp = 'green'; $ampTitle = T 'bericht.html.ampelGruenTitel'; $ampSub = $(if ($count.TIPP) { T 'bericht.html.ampelGruenMitTipps' $count.TIPP } else { T 'bericht.html.ampelGruenText' }) }
    $ids = @{}
    for ($i = 0; $i -lt $findings.Count; $i++) { $ids["$($findings[$i].Category)|$($findings[$i].Check)"] = "p$i" }
    $todo = @($findings | Where-Object { $_.Status -in 'CRIT', 'WARN' } | Sort-Object { $rank[$_.Status] }, { if ($_.Area -eq 'Sicherheit') { 0 } else { 1 } }, Category)

    # Gaming-Check nur im Profil Gaming
    $gamingChecks = 'Bildschirme und Bildwiederholrate', 'Grafikkarte und Treiber', 'Resizable BAR und PCIe-Anbindung', 'NVIDIA-Treibereinstellungen', 'Arbeitsspeicher', 'Prozessor-Energieeinstellungen', 'Energieplan',
    'Spielebibliotheken', 'Spielmodus', 'Hardwarebeschleunigte GPU-Planung (HAGS)', 'Hintergrundaufzeichnung (Game DVR)', 'Optimierungen für Spiele im Fenstermodus',
    'Overlays und Hintergrund-Tools', 'Mausbeschleunigung', 'Netzwerkverbindung', 'Netzwerkkarte: Energiesparfunktionen', 'Virtualisierung und Spieleleistung'
    $gamingRows = if ($script:Profile -eq 'Gaming') { @($gamingChecks | ForEach-Object { $c = $_; $findings | Where-Object Check -EQ $c | Select-Object -First 1 } | Where-Object { $_ }) } else { @() }
    $charts = (Get-Chart (T 'bericht.html.chartProbleme') 'Probleme' '' 'low') + (Get-Chart (T 'bericht.html.chartStart') 'StartSek' 's' 'low') +
    (Get-Chart (T 'bericht.html.chartIndex') 'Index' (T 'bericht.html.einheitVon10') 'high') + (Get-Chart (T 'bericht.html.chartFreiePlatz' $env:SystemDrive) 'FreiC' '%' 'high')

    # Anonymisierte Kopiervorlage für einen KI-Assistenten
    $ki = New-Object System.Text.StringBuilder
    [void]$ki.AppendLine((T 'bericht.ki.einleitung1'))
    [void]$ki.AppendLine((T 'bericht.ki.einleitung2'))
    [void]$ki.AppendLine('')
    [void]$ki.AppendLine((T 'bericht.ki.system' $script:OS.Caption $script:CV.DisplayVersion $ProductName $ScriptVersion $(if ($script:IsAdmin) { T 'bericht.ja' } else { T 'bericht.nein' })))
    [void]$ki.AppendLine((T 'bericht.ki.nutzung' $profilAnzeige))
    [void]$ki.AppendLine((T 'bericht.ki.uebersicht' $count.CRIT $count.WARN $count.TIPP $count.ACK $count.INFO $count.OK))
    foreach ($s in 'CRIT', 'WARN', 'TIPP', 'ACK', 'INFO') {
        $list = @($findings | Where-Object Status -EQ $s)
        if (-not $list) { continue }
        [void]$ki.AppendLine('')
        [void]$ki.AppendLine("== $($statusName[$s]) ==")
        foreach ($f in $list) {
            [void]$ki.AppendLine("- [$($f.AreaName) / $($f.CategoryName)] $(Get-PruefName $f): $(Protect-Text $f.Value)")
            if ($f.Recommendation) { [void]$ki.AppendLine((T 'bericht.ki.empfehlung' (Protect-Text $f.Recommendation))) }
            if ($s -eq 'ACK') { [void]$ki.AppendLine((T 'bericht.ki.akzeptiert' (Protect-Text $f.Note))) }
        }
    }
    $css = @'
:root{--b03:#002b36;--b02:#073642;--b01:#586e75;--b00:#657b83;--b0:#839496;--b1:#93a1a1;--b2:#eee8d5;--b3:#fdf6e3;--yellow:#b58900;--orange:#cb4b16;--red:#dc322f;--magenta:#d33682;--violet:#6c71c4;--blue:#268bd2;--cyan:#2aa198;--green:#859900;--line:#0d4a57}
*{box-sizing:border-box}html{scroll-behavior:smooth}
body{margin:0;background:var(--b03);color:var(--b0);font:15px/1.55 "Segoe UI",system-ui,-apple-system,sans-serif}
a{color:var(--blue);text-decoration:none}a:hover{text-decoration:underline}
h1,h2,h3{color:var(--b1);font-weight:600;margin:0}
h2{font-size:20px;margin:28px 0 12px;padding-bottom:6px;border-bottom:1px solid var(--line)}
.muted{color:var(--b01)}
header.top{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:12px;padding:18px 28px;background:var(--b02);border-bottom:1px solid var(--line)}
header.top h1{font-size:24px;letter-spacing:.5px}header.top h1 span{color:var(--cyan)}
.meta{color:var(--b01);font-size:13px;margin-top:2px}
.btn,button.btn{background:var(--b03);color:var(--b1);border:1px solid var(--b01);border-radius:6px;padding:7px 12px;font:inherit;font-size:14px;cursor:pointer}
.btn:hover{border-color:var(--cyan);color:var(--cyan);text-decoration:none}
.hero{display:flex;flex-wrap:wrap;gap:16px;padding:20px 28px 0}
.ampel{flex:1 1 320px;display:flex;align-items:center;gap:16px;background:var(--b02);border-radius:10px;padding:18px 20px;border-left:6px solid}
.ampel .dot{width:34px;height:34px;border-radius:50%;flex:none}
.amp-red{border-color:var(--red)}.amp-red .dot{background:var(--red);box-shadow:0 0 18px var(--red)}
.amp-yellow{border-color:var(--orange)}.amp-yellow .dot{background:var(--orange);box-shadow:0 0 18px var(--orange)}
.amp-green{border-color:var(--green)}.amp-green .dot{background:var(--green);box-shadow:0 0 18px var(--green)}
.amp-title{color:var(--b1);font-size:19px;font-weight:600}.amp-sub{font-size:14px}
.counters{flex:2 1 520px;display:grid;grid-template-columns:repeat(7,1fr);gap:8px}
.counter{background:var(--b02);border:0;border-top:4px solid;border-radius:8px;padding:10px 6px;color:var(--b0);font:inherit;cursor:pointer;text-align:center}
.counter:hover{background:#0a4250}.counter .n{display:block;font-size:24px;font-weight:600;color:var(--b1)}.counter .l{font-size:12px}
.c-CRIT{border-color:var(--red)}.c-WARN{border-color:var(--orange)}.c-TIPP{border-color:var(--magenta)}.c-ACK{border-color:var(--violet)}.c-INFO{border-color:var(--blue)}.c-OK{border-color:var(--green)}.c-SKIP{border-color:var(--b01)}
.layout{display:grid;grid-template-columns:230px 1fr;gap:24px;padding:0 28px 40px}
nav.side{position:sticky;top:64px;align-self:start;max-height:calc(100vh - 80px);overflow:auto;padding-top:24px;font-size:14px}
nav.side a{display:flex;justify-content:space-between;color:var(--b0);padding:3px 8px;border-radius:5px}
nav.side a:hover{background:var(--b02);color:var(--b1);text-decoration:none}
nav.side .grp{color:var(--b1);font-weight:600;margin:12px 0 4px 8px}
nav.side .cnt{font-size:11px;background:var(--orange);color:var(--b3);border-radius:8px;padding:0 6px;align-self:center}
.toolbar{position:sticky;top:0;z-index:15;display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;background:var(--b03);padding:12px 28px;border-bottom:1px solid var(--line)}
.filters{display:flex;flex-wrap:wrap;gap:6px}
.filters button{background:var(--b02);color:var(--b0);border:1px solid var(--line);border-radius:16px;padding:4px 12px;font:inherit;font-size:13px;cursor:pointer}
.filters button.active{background:var(--cyan);border-color:var(--cyan);color:var(--b03);font-weight:600}
#search{flex:0 1 320px;background:var(--b02);border:1px solid var(--line);border-radius:6px;color:var(--b1);padding:6px 10px;font:inherit}
#search:focus{outline:none;border-color:var(--cyan)}
.card{background:var(--b02);border-radius:10px;padding:14px 18px;margin-bottom:12px}
ol.steps{margin:0;padding-left:22px}ol.steps li{margin:8px 0}ol.steps .rec{font-size:14px;color:var(--b0)}
.row{display:grid;grid-template-columns:110px minmax(180px,1fr) minmax(220px,1.6fr) minmax(220px,1.6fr);gap:14px;padding:10px 14px;border-left:4px solid transparent;border-bottom:1px solid var(--line);background:var(--b02)}
.row:target{outline:2px solid var(--cyan)}.row.flash{animation:flash 1.6s}
@keyframes flash{0%{background:#0f5566}100%{background:var(--b02)}}
.s-CRIT{border-left-color:var(--red)}.s-WARN{border-left-color:var(--orange)}.s-TIPP{border-left-color:var(--magenta)}.s-ACK{border-left-color:var(--violet)}.s-INFO{border-left-color:var(--blue)}.s-OK{border-left-color:var(--green)}.s-SKIP{border-left-color:var(--b01)}
.c-check{color:var(--b1);font-weight:600;position:relative}.c-value{word-break:break-word}.c-rec{color:var(--b0);font-size:14px}
.cat-hint{font-weight:400;font-size:12px;color:var(--b01)}
.note{margin-top:4px;font-size:13px;color:var(--violet)}
.badge{display:inline-block;padding:2px 9px;border-radius:10px;font-size:12px;font-weight:600;white-space:nowrap;color:var(--b3)}
.b-CRIT{background:var(--red)}.b-WARN{background:var(--orange)}.b-TIPP{background:var(--magenta)}.b-ACK{background:var(--violet)}.b-INFO{background:var(--blue)}.b-OK{background:var(--green)}.b-SKIP{background:var(--b01)}
.levels{margin-top:6px;display:flex;flex-wrap:wrap;gap:4px}
.lv{font-size:11px;border-radius:8px;padding:1px 7px;background:var(--b03);border:1px solid var(--line);color:var(--b0)}
.lv-n-hoch,.lv-a-gering,.lv-r-gering{color:var(--green)}.lv-n-mittel{color:var(--cyan)}.lv-a-mittel,.lv-r-mittel{color:var(--yellow)}.lv-a-hoch{color:var(--orange)}.lv-r-hoch{color:var(--red)}
details.how{margin-top:6px}details.how>summary{cursor:pointer;color:var(--cyan);font-size:13px}
details.how ol{margin:6px 0;padding-left:20px;font-size:13.5px;color:var(--b1)}
.cmd{margin-top:6px;border:1px solid var(--line);border-radius:6px;overflow:hidden}
.cmd-head{display:flex;justify-content:space-between;align-items:center;gap:8px;font-size:12px;background:#0a3f4b;padding:4px 8px;color:var(--b1)}
.cmd pre{margin:0;padding:8px;font:12.5px Consolas,monospace;white-space:pre-wrap;word-break:break-all;color:var(--b2);background:var(--b03)}
button.copy{background:transparent;border:1px solid var(--b01);color:var(--b1);border-radius:4px;font:inherit;font-size:12px;padding:1px 8px;cursor:pointer}
.todo{display:flex;flex-direction:column;gap:4px;margin-top:8px}
.todo button{background:transparent;border:1px solid var(--line);color:var(--b01);border-radius:5px;font:inherit;font-size:11.5px;padding:1px 6px;cursor:pointer;text-align:left}
.todo button:hover{color:var(--b1);border-color:var(--b01)}.todo button.on{background:var(--cyan);color:var(--b03);border-color:var(--cyan)}
.row.m-done{opacity:.65}.mark-note{font-size:12px;color:var(--cyan);margin-top:4px}
.gaming{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:8px}
.g-item{background:var(--b03);border:1px solid var(--line);border-left:4px solid;border-radius:6px;padding:8px 10px;font-size:13.5px}
.g-item a{color:var(--b1);font-weight:600}.g-item .v{color:var(--b0);font-size:12.5px;margin-top:2px;word-break:break-word}
.charts{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:10px}
.chart{background:var(--b03);border:1px solid var(--line);border-radius:8px;padding:8px 10px}
.chart-head,.chart-foot{display:flex;justify-content:space-between;font-size:12.5px}.chart-head{color:var(--b1)}.chart-foot{color:var(--b01);font-size:11px}
.chart svg{width:100%;height:90px}.chart polyline{fill:none;stroke:var(--cyan);stroke-width:2}.chart circle{fill:var(--b2)}
ul.checklist{margin:4px 0 0;padding-left:20px}ul.checklist li{margin:4px 0}
ol.steps .levels{display:inline-flex;margin:0 0 0 6px;vertical-align:1px}
details.cat{margin-bottom:10px;border-radius:10px;overflow:visible}
details.cat>summary{list-style:none;cursor:pointer;display:flex;align-items:center;gap:10px;background:#0a3f4b;padding:10px 14px;border-radius:10px 10px 0 0;color:var(--b1);font-weight:600;position:relative}
details.cat:not([open])>summary{border-radius:10px}
details.cat>summary::before{content:"▸";color:var(--cyan);transition:transform .15s}details.cat[open]>summary::before{transform:rotate(90deg)}
details.cat>summary::-webkit-details-marker{display:none}
.mini{margin-left:auto;display:flex;gap:4px}.mini .badge{font-size:11px;padding:1px 7px}
.info{display:inline-flex;align-items:center;justify-content:center;width:18px;height:18px;margin-left:7px;border-radius:50%;border:1px solid var(--cyan);background:transparent;color:var(--cyan);font:italic 700 12px Georgia,serif;cursor:pointer;vertical-align:1px;padding:0}
.info:hover,.info[aria-expanded="true"]{background:var(--cyan);color:var(--b03)}
.tip{display:none;position:absolute;left:0;top:calc(100% + 8px);z-index:30;width:min(420px,85vw);background:var(--b2);color:var(--b03);border-radius:8px;padding:12px 14px;font-weight:400;font-size:13.5px;line-height:1.5;box-shadow:0 8px 24px rgba(0,0,0,.5);cursor:default}
.tip::before{content:"";position:absolute;top:-7px;left:14px;border:7px solid transparent;border-top:0;border-bottom-color:var(--b2)}
.tip.open{display:block}.tip b{color:var(--b02)}
.tablewrap{overflow:auto;max-height:520px;border:1px solid var(--line);border-radius:6px}
table{border-collapse:collapse;width:100%;font-size:13px}
th{position:sticky;top:0;background:#0a3f4b;color:var(--b1);text-align:left;padding:6px 8px}
td{padding:5px 8px;border-top:1px solid var(--line);vertical-align:top;word-break:break-word}
tr:nth-child(even) td{background:#05313b}
details.raw{margin:6px 0}details.raw>summary{cursor:pointer;color:var(--b1);padding:4px 0}
ul.chg{margin:4px 0 12px;padding-left:20px}.add{color:var(--green)}.rem{color:var(--red)}
.guide p,.guide li{max-width:900px}.guide .badge{margin-right:6px}
#ki-text{position:absolute;left:-9999px}
.hide{display:none!important}
footer{padding:16px 28px 30px;color:var(--b01);font-size:12px;border-top:1px solid var(--line)}
@media (max-width:1000px){.layout{grid-template-columns:1fr}nav.side{display:none}.counters{grid-template-columns:repeat(3,1fr)}}
@media (max-width:760px){.row{grid-template-columns:1fr;gap:4px}}
@media print{.toolbar,nav.side,.info,header .actions{display:none}body{background:#fff;color:#000}}
'@

    $js = @'
(function () {
  // Texte in der Sprache des Scans; kommen als JSON aus den Sprachdateien (lang\<sprache>\bericht.psd1)
  var L = __MORPHEUS_TEXTE__;
  var rows = Array.prototype.slice.call(document.querySelectorAll('details.cat .row'));
  var mode = 'all', term = '';
  function apply() {
    rows.forEach(function (r) {
      var s = r.getAttribute('data-status');
      var ok = mode === 'all' || (mode === 'problem' ? (s === 'CRIT' || s === 'WARN') : s === mode);
      if (ok && term) ok = r.getAttribute('data-text').indexOf(term) >= 0;
      r.classList.toggle('hide', !ok);
    });
    document.querySelectorAll('details.cat').forEach(function (c) {
      var vis = c.querySelectorAll('.row:not(.hide)').length;
      c.classList.toggle('hide', vis === 0);
      if ((term || mode !== 'all') && vis) c.open = true;
    });
    document.querySelectorAll('.filters [data-filter]').forEach(function (b) { b.classList.toggle('active', b.getAttribute('data-filter') === mode); });
    var empty = document.getElementById('empty');
    if (empty) empty.classList.toggle('hide', rows.some(function (r) { return !r.classList.contains('hide'); }));
  }
  document.querySelectorAll('[data-filter]').forEach(function (b) {
    b.addEventListener('click', function () {
      mode = b.getAttribute('data-filter'); apply();
      if (b.classList.contains('counter')) document.getElementById('pruefungen').scrollIntoView();
    });
  });
  document.getElementById('search').addEventListener('input', function (e) { term = e.target.value.trim().toLowerCase(); apply(); });

  // Sprechblasen an den i-Symbolen
  function closeTips(except) {
    document.querySelectorAll('.tip.open').forEach(function (t) {
      if (t !== except) { t.classList.remove('open'); t.previousElementSibling.setAttribute('aria-expanded', 'false'); }
    });
  }
  document.addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('.info') : null;
    if (e.target.closest && e.target.closest('.tip')) { e.preventDefault(); return; }
    if (!btn) { closeTips(null); return; }
    e.preventDefault(); e.stopPropagation();
    var tip = btn.nextElementSibling, open = !tip.classList.contains('open');
    closeTips(tip);
    tip.classList.toggle('open', open);
    btn.setAttribute('aria-expanded', open ? 'true' : 'false');
  });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeTips(null); });

  // Sprung zu einer Prüfung: Filter zurücksetzen, Kategorie öffnen, Zeile hervorheben
  function reveal(id) {
    var r = document.getElementById(id);
    if (!r) return;
    if (r.classList.contains('hide')) { mode = 'all'; term = ''; document.getElementById('search').value = ''; apply(); }
    var d = r.closest('details'); if (d) d.open = true;
    r.scrollIntoView({ block: 'center' });
    r.classList.remove('flash'); void r.offsetWidth; r.classList.add('flash');
  }
  document.querySelectorAll('a[href^="#p"]').forEach(function (a) {
    a.addEventListener('click', function (e) { e.preventDefault(); reveal(a.getAttribute('href').substring(1)); });
  });

  // Anonymisierte Kopiervorlage für ChatGPT/Claude
  var kb = document.getElementById('btn-ki');
  kb.addEventListener('click', function () {
    var ta = document.getElementById('ki-text'), label = kb.textContent;
    function done(ok) {
      kb.textContent = ok ? L.kiKopiert : L.kiNichtMoeglich;
      setTimeout(function () { kb.textContent = label; }, 4000);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(ta.value).then(function () { done(true); }, function () { ta.select(); done(document.execCommand('copy')); });
    } else { ta.select(); done(document.execCommand('copy')); }
  });

  // Befehle aus "So geht's" kopieren
  document.querySelectorAll('button.copy').forEach(function (b) {
    b.addEventListener('click', function () {
      var pre = b.closest('.cmd').querySelector('pre'), label = b.textContent;
      function done(ok) { b.textContent = ok ? L.kopiert : L.nichtMoeglich; setTimeout(function () { b.textContent = label; }, 2500); }
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(pre.textContent).then(function () { done(true); }, function () { done(false); });
      else done(false);
    });
  });

  // Checkliste: Markierungen bleiben im Browser gespeichert (je PC) und werden mit jedem neuen Bericht abgeglichen
  var store = null, key = 'pc-check:' + document.body.getAttribute('data-pc'), created = document.body.getAttribute('data-created');
  try { store = window.localStorage; store.getItem(key); } catch (e) { store = null; }
  var marks = {};
  if (store) { try { marks = JSON.parse(store.getItem(key) || '{}') || {}; } catch (e) { marks = {}; } }
  function save() { if (store) { try { store.setItem(key, JSON.stringify(marks)); } catch (e) {} } }
  var byCheck = {};
  rows.forEach(function (r) { byCheck[r.getAttribute('data-check')] = r; });
  function li(list, text, cls, id) {
    var e = document.createElement('li');
    if (id) { var a = document.createElement('a'); a.href = '#' + id; a.textContent = text; a.addEventListener('click', function (ev) { ev.preventDefault(); reveal(id); }); e.appendChild(a); }
    else e.textContent = text;
    if (cls) { var s = document.createElement('span'); s.className = 'muted'; s.textContent = ' – ' + cls; e.appendChild(s); }
    list.appendChild(e);
  }
  function hinweis(box, text) { var p = document.createElement('p'); p.className = 'muted'; p.textContent = text; box.appendChild(p); }
  function render() {
    rows.forEach(function (r) {
      var m = marks[r.getAttribute('data-check')];
      r.classList.toggle('m-done', !!(m && m.state === 'done'));
      r.querySelectorAll('.todo button').forEach(function (b) { b.classList.toggle('on', !!(m && m.state === b.getAttribute('data-mark'))); });
    });
    var groups = { pending: [], open: [], fixed: [], later: [] };
    Object.keys(marks).forEach(function (c) {
      var m = marks[c], r = byCheck[c], s = r ? r.getAttribute('data-status') : 'OK';
      var still = s === 'CRIT' || s === 'WARN' || s === 'TIPP';
      var g = m.state === 'later' ? (still ? 'later' : 'fixed') : (!still ? 'fixed' : (m.report === created ? 'pending' : 'open'));
      groups[g].push({ c: c, id: r ? r.id : '', d: m.date, n: r ? (r.getAttribute('data-name') || c) : c });
    });
    var box = document.getElementById('checklist-body');
    if (!box) return;
    box.innerHTML = '';
    var titles = { open: L.titelOffen, fixed: L.titelBehoben, pending: L.titelWartend, later: L.titelSpaeter };
    var any = false;
    ['open', 'fixed', 'pending', 'later'].forEach(function (g) {
      if (!groups[g].length) return;
      any = true;
      var h = document.createElement('h3'); h.textContent = titles[g]; h.className = g === 'open' ? 'rem' : (g === 'fixed' ? 'add' : '');
      var ul = document.createElement('ul'); ul.className = 'checklist';
      groups[g].forEach(function (x) { li(ul, x.n, L.markiertAm.replace('{0}', function () { return x.d; }), x.id); });
      box.appendChild(h); box.appendChild(ul);
    });
    if (!any) hinweis(box, L.nochNichts);
    if (!store) hinweis(box, L.keinSpeicher);
  }
  document.querySelectorAll('.todo button').forEach(function (b) {
    b.addEventListener('click', function () {
      var c = b.closest('.row').getAttribute('data-check'), st = b.getAttribute('data-mark');
      if (marks[c] && marks[c].state === st) delete marks[c];
      else marks[c] = { state: st, date: new Date().toLocaleDateString(L.datumsformat), report: created };
      save(); render();
    });
  });
  var reset = document.getElementById('checklist-reset');
  if (reset) reset.addEventListener('click', function () { if (confirm(L.loeschenFrage)) { marks = {}; save(); render(); } });
  render();
})();
'@

    # Texte des eingebetteten Skripts als JSON (ConvertTo-Json maskiert Anführungszeichen; "<" zusätzlich, damit nie ein Tag-Ende entsteht)
    $jsTexte = [ordered]@{
        kiKopiert       = (T 'bericht.js.kiKopiert')
        kiNichtMoeglich = (T 'bericht.js.kiNichtMoeglich')
        kopiert         = (T 'bericht.js.kopiert')
        nichtMoeglich   = (T 'bericht.js.nichtMoeglich')
        titelOffen      = (T 'bericht.js.titelOffen')
        titelBehoben    = (T 'bericht.js.titelBehoben')
        titelWartend    = (T 'bericht.js.titelWartend')
        titelSpaeter    = (T 'bericht.js.titelSpaeter')
        markiertAm      = (T 'bericht.js.markiertAm')
        nochNichts      = (T 'bericht.js.nochNichts')
        keinSpeicher    = (T 'bericht.js.keinSpeicher')
        loeschenFrage   = (T 'bericht.js.loeschenFrage')
        datumsformat    = $(if ($Sprache -eq 'en') { 'en-GB' } else { 'de-DE' })
    }
    # < statt <: Kein Text kann das umgebende <script> beenden
    $js = $js.Replace('__MORPHEUS_TEXTE__', (($jsTexte | ConvertTo-Json -Compress).Replace('<', '<')))

    $title = "$ProductName · $env:COMPUTERNAME · $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $htmlLang = if ($Sprache -eq 'en') { 'en' } else { 'de' }
    A '<!DOCTYPE html>'
    A "<html lang=`"$htmlLang`"><head><meta charset=`"utf-8`"><meta name=`"viewport`" content=`"width=device-width, initial-scale=1`">"
    A "<title>$(HEnc $title)</title><style>$css</style></head><body data-pc=`"$(HEnc $env:COMPUTERNAME)`" data-created=`"$(Get-Date -Format 's')`">"

    # Kopf
    A '<header class="top"><div>'
    A "<h1>$ProductName <span>$ProductTagline</span></h1>"
    $adminText = if ($script:IsAdmin) { T 'bericht.ja' } else { T 'bericht.html.adminNein' }
    $profilText = if ($script:ProfileAuto) { T 'bericht.html.profilAuto' $profilAnzeige } else { $profilAnzeige }
    A ('<div class="meta">' + (HEnc (T 'bericht.html.meta' $env:COMPUTERNAME (Get-Date -Format 'dd.MM.yyyy HH:mm') $ScriptVersion $adminText ([int]$duration.TotalSeconds) $EventDays $profilText)) + '</div>')
    A ('</div><div class="actions"><button type="button" class="btn" id="btn-ki" title="' + (HEnc (T 'bericht.html.kiTitel')) + '">' + (HEnc (T 'bericht.html.kiKnopf')) + '</button> <a class="btn" href="#anleitung">' + (HEnc (T 'bericht.html.anleitungLink')) + '</a></div></header>')

    # Ampel und Zähler
    A "<section class=`"hero`"><div class=`"ampel amp-$amp`"><span class=`"dot`"></span><div><div class=`"amp-title`">$(HEnc $ampTitle)</div><div class=`"amp-sub`">$(HEnc $ampSub)</div></div></div>"
    A '<div class="counters">'
    $nurDiese = HEnc (T 'bericht.html.nurDiese')
    foreach ($s in $order) { A "<button type=`"button`" class=`"counter c-$s`" data-filter=`"$s`" title=`"$nurDiese`"><span class=`"n`">$($count[$s])</span><span class=`"l`">$(HEnc $statusName[$s])</span></button>" }
    A '</div></section>'

    # Werkzeugleiste
    A '<div class="toolbar"><div class="filters">'
    A ('<button type="button" data-filter="all" class="active">' + (HEnc (T 'bericht.html.filterAlle')) + '</button><button type="button" data-filter="problem">' + (HEnc (T 'bericht.html.filterProbleme')) + '</button><button type="button" data-filter="TIPP">' + (HEnc (T 'bericht.html.filterTipps')) + '</button><button type="button" data-filter="INFO">' + (HEnc (T 'bericht.html.filterHinweise')) + '</button><button type="button" data-filter="ACK">' + (HEnc $statusName.ACK) + '</button><button type="button" data-filter="OK">' + (HEnc $statusName.OK) + '</button><button type="button" data-filter="SKIP">' + (HEnc $statusName.SKIP) + '</button>')
    A ('</div><input id="search" type="search" placeholder="' + (HEnc (T 'bericht.html.suchen')) + '" aria-label="' + (HEnc (T 'bericht.html.suchenLabel')) + '"></div>')

    # Navigation
    $cats = @($findings | ForEach-Object { "$($_.Area)|$($_.Category)" } | Select-Object -Unique)
    A '<div class="layout"><nav class="side">'
    A ('<a href="#schritte">' + (HEnc (T 'bericht.html.navSchritte')) + '</a>')
    A ('<a href="#checkliste">' + (HEnc (T 'bericht.html.navCheckliste')) + '</a>')
    if ($gamingRows) { A ('<a href="#gaming">' + (HEnc (T 'bericht.html.navGaming')) + '</a>') }
    if ($charts) { A ('<a href="#verlauf">' + (HEnc (T 'bericht.html.navVerlauf')) + '</a>') }
    if ($changes) { A ('<a href="#aenderungen">' + (HEnc (T 'bericht.html.navAenderungen')) + '</a>') }
    if ($count.ACK) { A "<a href=`"#akzeptiert`">$(HEnc $statusName.ACK) <span class=`"cnt`" style=`"background:var(--violet)`">$($count.ACK)</span></a>" }
    if ($null -ne $updateResults) { A ('<a href="#updates">' + (HEnc (T 'bericht.html.navUpdates')) + '</a>') }
    $lastArea = ''
    for ($i = 0; $i -lt $cats.Count; $i++) {
        $area, $cat = $cats[$i] -split '\|', 2
        if ($area -ne $lastArea) { A "<div class=`"grp`">$(HEnc (Get-MorpheusAnzeige 'bereich' $area))</div>"; $lastArea = $area }
        $prob = @($findings | Where-Object { $_.Area -eq $area -and $_.Category -eq $cat -and $_.Status -in 'CRIT', 'WARN' }).Count
        $cnt = if ($prob) { '<span class="cnt">' + $prob + '</span>' } else { '' }
        A "<a href=`"#cat$i`">$(HEnc (Get-MorpheusAnzeige 'kategorie' $cat))$cnt</a>"
    }
    A ('<div class="grp">' + (HEnc (T 'bericht.html.navMehr')) + '</div><a href="#rohdaten">' + (HEnc (T 'bericht.html.navRohdaten')) + '</a><a href="#anleitung">' + (HEnc (T 'bericht.html.navAnleitung')) + '</a></nav><main>')

    # Nächste Schritte
    A ('<h2 id="schritte">' + (HEnc (T 'bericht.html.schritte')) + '</h2>')
    if ($todo) {
        A '<div class="card"><ol class="steps">'
        foreach ($f in ($todo | Select-Object -First 3)) {
            A "<li><span class=`"badge b-$($f.Status)`">$(HEnc $statusName[$f.Status])</span> <a href=`"#$($ids["$($f.Category)|$($f.Check)"])`">$(HEnc (Get-PruefName $f))</a><div class=`"rec`">$(HEnc $f.Recommendation)</div></li>"
        }
        A '</ol>'
        if ($todo.Count -gt 3) { A ('<p class="muted">' + (HEnc (T 'bericht.html.insgesamtPunkte' $todo.Count)) + '</p>') }
        A '</div>'
    }
    else { A ('<div class="card">' + (HEnc (T 'bericht.html.keinHandlungsbedarf')) + '</div>') }
    if ($tips) {
        A ('<div class="card"><h3 style="margin-bottom:6px">' + (HEnc (T 'bericht.html.lohnendeTipps')) + '</h3><p class="muted" style="margin:0 0 4px">' + (HEnc (T 'bericht.html.tippsHinweis')) + '</p><ol class="steps">')
        foreach ($f in ($tips | Select-Object -First 5)) {
            A "<li><a href=`"#$($ids["$($f.Category)|$($f.Check)"])`">$(HEnc (Get-PruefName $f))</a>$(Get-Levels $f)<div class=`"rec`">$(HEnc $f.Recommendation)</div></li>"
        }
        A '</ol>'
        if ($tips.Count -gt 5) { A ('<p class="muted">' + (HEnc (T 'bericht.html.insgesamtTipps' $tips.Count)) + '</p>') }
        A '</div>'
    }

    # Checkliste (wird im Browser aus den gespeicherten Markierungen aufgebaut)
    A ('<h2 id="checkliste">' + (HEnc (T 'bericht.html.navCheckliste')) + '</h2><div class="card"><div id="checklist-body"><p class="muted">' + (HEnc (T 'bericht.html.laedt')) + '</p></div>')
    A ('<p class="muted" style="margin-bottom:0">' + (HEnc (T 'bericht.html.checklisteHinweis')) + ' <button type="button" class="copy" id="checklist-reset">' + (HEnc (T 'bericht.html.markierungenLoeschen')) + '</button></p></div>')

    # Gaming-Check: die spielerelevanten Prüfungen auf einen Blick
    if ($gamingRows) {
        A ('<h2 id="gaming">' + (HEnc (T 'bericht.html.navGaming')) + '</h2><div class="card"><div class="gaming">')
        foreach ($f in $gamingRows) {
            $col = @{ CRIT = 'var(--red)'; WARN = 'var(--orange)'; TIPP = 'var(--magenta)'; ACK = 'var(--violet)'; INFO = 'var(--blue)'; OK = 'var(--green)'; SKIP = 'var(--b01)' }[$f.Status]
            A "<div class=`"g-item`" style=`"border-left-color:$col`"><span class=`"badge b-$($f.Status)`">$(HEnc $statusName[$f.Status])</span> <a href=`"#$($ids["$($f.Category)|$($f.Check)"])`">$(HEnc (Get-PruefName $f))</a><div class=`"v`">$(HEnc $f.Value)</div></div>"
        }
        A '</div></div>'
    }

    # Verlauf über die bisherigen Läufe
    if ($charts) {
        A "<h2 id=`"verlauf`">$(HEnc (T 'bericht.html.navVerlauf'))</h2><div class=`"card`"><p class=`"muted`" style=`"margin-top:0`">$(HEnc (T 'bericht.html.verlaufHinweis' $history.Count))</p><div class=`"charts`">$charts</div></div>"
    }

    # Änderungen seit dem letzten Lauf
    if ($changes) {
        A ('<h2 id="aenderungen">' + (HEnc (T 'bericht.html.aenderungenTitel')) + '</h2><div class="card">')
        $adminNote = if ($changes.AdminVorher -ne [bool]$script:IsAdmin) { ' <b>' + (HEnc (T 'bericht.achtung')) + '</b> ' + (HEnc $(if ($changes.AdminVorher) { T 'bericht.achtungMitAdmin' } else { T 'bericht.achtungOhneAdmin' })) } else { '' }
        $prevDate = try { ([datetime]::Parse($changes.Erstellt, [Globalization.CultureInfo]::InvariantCulture)).ToString('dd.MM.yyyy HH:mm') } catch { $changes.Erstellt }
        A "<p class=`"muted`">$(HEnc (T 'bericht.html.verglichenMit' $prevDate))$adminNote</p>"
        if ($changes.Status.Count) {
            A ('<h3>' + (HEnc (T 'bericht.html.geaenderteErgebnisse')) + '</h3>')
            A (Get-Table $changes.Status 300 $script:ChangesSpalten)
        }
        foreach ($t in $changes.Bestand.Keys) {
            A "<h3>$(HEnc (Get-MorpheusAnzeige 'tabelle' $t))</h3><ul class=`"chg`">"
            foreach ($x in @($changes.Bestand[$t].Neu)) { A "<li class=`"add`">➕ $(HEnc $x)</li>" }
            foreach ($x in @($changes.Bestand[$t].Entfernt)) { A "<li class=`"rem`">➖ $(HEnc $x)</li>" }
            A '</ul>'
        }
        if (-not $changes.Status.Count -and -not $changes.Bestand.Count) { A ('<p>' + (HEnc (T 'bericht.html.keineAenderungen')) + '</p>') }
        A '</div>'
    }

    # Akzeptierte Abweichungen
    $acc = @($findings | Where-Object Status -EQ 'ACK')
    if ($acc) {
        A ('<h2 id="akzeptiert">' + (HEnc (T 'bericht.html.akzeptierteTitel')) + '</h2>')
        foreach ($f in $acc) { A (Get-Row $f $ids["$($f.Category)|$($f.Check)"] -Summary) }
    }

    # Update-Dialog
    if ($null -ne $updateResults) {
        A ('<h2 id="updates">' + (HEnc (T 'bericht.html.navUpdates')) + '</h2>')
        if (@($updateResults).Count) { A (Get-Table $updateResults 300 $script:UpdateSpalten) } else { A ('<div class="card">' + (HEnc (T 'bericht.html.keineUpdates')) + '</div>') }
    }

    # Alle Prüfungen nach Bereich und Kategorie
    A ('<h2 id="pruefungen">' + (HEnc (T 'bericht.html.allePruefungen')) + '</h2><p id="empty" class="card hide">' + (HEnc (T 'bericht.html.keinTreffer')) + '</p>')
    $lastArea = ''
    for ($i = 0; $i -lt $cats.Count; $i++) {
        $area, $cat = $cats[$i] -split '\|', 2
        if ($area -ne $lastArea) { A "<h3 style=`"margin:18px 0 8px`">$(HEnc (Get-MorpheusAnzeige 'bereich' $area))</h3>"; $lastArea = $area }
        $list = @($findings | Where-Object { $_.Area -eq $area -and $_.Category -eq $cat })
        $mini = foreach ($s in $order) { $n = @($list | Where-Object Status -EQ $s).Count; if ($n -and $s -ne 'OK') { "<span class=`"badge b-$s`">$n $(HEnc $statusName[$s])</span>" } }
        $okN = @($list | Where-Object Status -EQ 'OK').Count
        if ($okN) { $mini = @($mini) + "<span class=`"badge b-OK`">$okN $(HEnc $statusName.OK)</span>" }
        $catTip = if ($help -and $help.Kategorien[$cat]) { Get-InfoButton (HEnc $help.Kategorien[$cat]) } else { '' }
        $open = if (@($list | Where-Object { $_.Status -in 'CRIT', 'WARN', 'TIPP' }).Count) { ' open' } else { '' }
        A "<details class=`"cat`" id=`"cat$i`"$open><summary>$(HEnc (Get-MorpheusAnzeige 'kategorie' $cat))$catTip<span class=`"mini`">$($mini -join '')</span></summary>"
        foreach ($f in $list) { A (Get-Row $f $ids["$($f.Category)|$($f.Check)"]) }
        A '</details>'
    }

    # Rohdaten
    A ('<h2 id="rohdaten">' + (HEnc (T 'bericht.html.navRohdaten')) + '</h2><p class="muted">' + (HEnc (T 'bericht.html.rohdatenHinweis')) + '</p>')
    foreach ($title in $script:Tables.Keys) {
        $rowsT = @($script:Tables[$title])
        A "<details class=`"raw`"><summary>$(HEnc (Get-MorpheusAnzeige 'tabelle' $title)) <span class=`"muted`">($($rowsT.Count))</span></summary>$(Get-Table $rowsT)</details>"
    }

    # Anleitung (die Absätze mit Auszeichnung stehen als fertiges HTML in der Sprachdatei, feste Programmtexte ohne Werte aus dem Scan)
    A ('<h2 id="anleitung">' + (HEnc (T 'bericht.html.anleitungTitel')) + '</h2><div class="card guide">')
    A ('<p>' + (HEnc (T 'bericht.html.guideEinleitung')) + '</p><ul>')
    foreach ($s in $order) {
        $txt = if ($help -and $help.Status[$s]) { $help.Status[$s] } else { $statusName[$s] }
        A "<li><span class=`"badge b-$s`">$(HEnc $statusName[$s])</span>$(HEnc $txt)</li>"
    }
    A ('</ul><h3>' + (HEnc (T 'bericht.html.guideVorgehen')) + '</h3><ol>')
    A ('<li>' + (T 'bericht.html.guide1Html') + '</li>')
    A ('<li>' + (T 'bericht.html.guide2Html') + '</li>')
    A ('<li>' + (T 'bericht.html.guide3Html') + '</li>')
    A ('<li>' + (T 'bericht.html.guide4Html' (HEnc $profilAnzeige)) + '</li>')
    A ('<li>' + (T 'bericht.html.guide5Html') + '</li>')
    A ('<li>' + (T 'bericht.html.guide6Html') + '</li>')
    A ('<li>' + (T 'bericht.html.guide7Html') + '</li>')
    A ('<li>' + (T 'bericht.html.guide8Html') + '</li>')
    A ('<li>' + (T 'bericht.html.guide9Html') + '</li>')
    A ('</ol><p class="muted">' + (HEnc (T 'bericht.html.guideSchluss')) + '</p></div>')

    A ('</main></div><footer>' + (HEnc (T 'bericht.html.fuss' $ProductName $ProductTagline $ScriptVersion (Get-Date -Format 'dd.MM.yyyy HH:mm'))) + '</footer>')
    A "<textarea id=`"ki-text`" readonly aria-hidden=`"true`">$(HEnc $ki.ToString())</textarea>"
    A "<script>$js</script></body></html>"

    [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
}

$htmlPath = [IO.Path]::ChangeExtension($mdPath, '.html')
try {
    Write-HtmlReport -Path $htmlPath
    Write-Host (T 'bericht.konsole.html' $htmlPath) -ForegroundColor Green
    # Über den Explorer öffnen: so startet der Browser ohne Adminrechte, auch wenn pc-check als Admin läuft
    if (-not $NoOpen -and $interactive) { Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe') -ArgumentList "`"$htmlPath`"" }
}
catch { Write-Warning (T 'bericht.htmlNichtErstellt' $_.Exception.Message) }

#endregion

#region Update-Dialog (nach dem Bericht, nur mit ausdrücklicher Auswahl)

$candidates = @($script:WingetUpdates | Where-Object Kategorie -EQ 'Programm')
if (-not $NoUpdatePrompt -and $interactive -and $candidates.Count) {
    Write-Host ''
    Write-Host (T 'bericht.update.vorhanden') -ForegroundColor Yellow
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ('  [{0}] {1}  {2} -> {3}' -f ($i + 1), $candidates[$i].Name, $candidates[$i].Installiert, $candidates[$i].Verfuegbar)
    }
    $skipped = @($script:WingetUpdates | Where-Object Kategorie -NE 'Programm')
    if ($skipped) { Write-Host (T 'bericht.update.nichtAngeboten' (($skipped | ForEach-Object { "$($_.Name) ($($_.Kategorie))" }) -join ', ')) -ForegroundColor DarkGray }
    Write-Host (T 'bericht.update.lizenz') -ForegroundColor DarkGray
    $answer = Read-Host (T 'bericht.update.frage')

    $selected = @()
    if ($answer -match '^\s*a\s*$') { $selected = $candidates }
    elseif ($answer.Trim()) {
        # Doppelte über die Nummer entfernen (Select-Object -Unique taugt für Objekte ohne Textdarstellung nicht)
        $picked = @()
        foreach ($tok in ($answer -split '[,;\s]+' | Where-Object { $_ })) {
            if ($tok -match '^\d+$' -and [int]$tok -ge 1 -and [int]$tok -le $candidates.Count) { if ([int]$tok -notin $picked) { $picked += [int]$tok } }
            else { Write-Host (T 'bericht.update.ignoriert' $tok) -ForegroundColor DarkGray }
        }
        $selected = @($picked | ForEach-Object { $candidates[$_ - 1] })
    }

    $results = @()
    if ($selected) {
        # Pfad neu prüfen (zwischen Scan und Auswahl kann Zeit vergehen), nie über PATH (2.3.3)
        $wg = $null
        if ($script:PfadLib) { $wg = (Get-MorpheusWinget).Pfad }
        if (-not $wg) {
            Write-Host (T 'bericht.update.wingetFehlt') -ForegroundColor Yellow
            foreach ($u in $selected) { $results += [pscustomobject][ordered]@{ Programm = $u.Name; Von = $u.Installiert; Auf = $u.Verfuegbar; Ergebnis = (T 'bericht.update.ergebnisWingetFehlt') } }
            $selected = @()
        }
        # Von winget gekürzte oder ungültige Ids nicht übergeben (2.4)
        elseif ($script:WingetLib) { $selected = @($selected | Where-Object { Test-MorpheusWingetId -Id $_.Id }) }
        # winget läuft ohne Adminrechte (2.5, #67, G3); ohne WingetBenutzer.ps1 wird nichts aktualisiert (kein Rückfall)
        if ($selected -and -not (Get-Command -Name Invoke-MorpheusWingetBenutzer -CommandType Function -ErrorAction SilentlyContinue)) {
            Write-Host (T 'bericht.update.benutzerFehlt') -ForegroundColor Yellow
            foreach ($u in $selected) { $results += [pscustomobject][ordered]@{ Programm = $u.Name; Von = $u.Installiert; Auf = $u.Verfuegbar; Ergebnis = (T 'bericht.update.ergebnisBenutzerFehlt') } }
            $selected = @()
        }
        $wgGelaufen = [bool]$selected
        if ($selected) {
            Write-Host (T 'bericht.update.ohneAdmin') -ForegroundColor DarkGray
        }
        foreach ($u in $selected) {
            $erfolg = $false
            while ($true) {
                Write-Host ("`n" + (T 'bericht.update.aktualisiere' $u.Name $u.Installiert $u.Verfuegbar)) -ForegroundColor Cyan
                $wr = Invoke-MorpheusWingetBenutzer -WingetPfad $wg -Argumente (Get-MorpheusWingetUpgradeArgumente -Id $u.Id) -Zeile { param($z) Write-Host ('  ' + $z) }
                if ($wr.zeitueberschritten) { $result = T 'bericht.update.zeitlimit'; break }
                if ($null -eq $wr.exitCode) { $result = T 'bericht.update.fehlgeschlagenMit' $wr.fehler; break }
                $code = $wr.exitCode
                if ($code -eq 0) { $result = T 'bericht.update.aktualisiert'; $erfolg = $true; break }
                # 0x8A150006: Installer abgebrochen, meist weil das Programm noch läuft
                if ((Get-MorpheusWingetErgebnis -ExitCode $code).status -eq 'laeuft-noch') {
                    Write-Host (T 'bericht.update.abbruchLaeuft') -ForegroundColor Yellow
                    # j (Deutsch) bzw. y (Englisch) bestätigt
                    if ((Read-Host (T 'bericht.update.erneutFrage')) -match '^\s*[jy]') { continue }
                    $result = T 'bericht.update.abgebrochen'
                }
                else { $result = T 'bericht.update.fehlgeschlagenCode' $code }
                break
            }
            Write-Host "  -> $result" -ForegroundColor $(if ($erfolg) { 'Green' } else { 'Red' })
            $results += [pscustomobject][ordered]@{ Programm = $u.Name; Von = $u.Installiert; Auf = $u.Verfuegbar; Ergebnis = $result }
        }
    }
    else { Write-Host (T 'bericht.update.keine') }
    $updateResults = @($results)

    # Ergebnis an den Bericht anhängen
    $lines = @('', (T 'bericht.md.updatesTitel' (Get-Date -Format 'yyyy-MM-dd HH:mm')), '')
    if ($results) {
        $lines += (ConvertTo-MdTable $results 150 $script:UpdateSpalten)
        if ($wgGelaufen) { $lines += ''; $lines += (T 'bericht.md.wingetOhneAdmin') }
    }
    else { $lines += (T 'bericht.md.keineUpdates') }
    [IO.File]::AppendAllText($mdPath, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
    try { Write-HtmlReport -Path $htmlPath } catch { Write-Warning (T 'bericht.htmlNichtAktualisiert' $_.Exception.Message) }
    Write-Host ("`n" + (T 'bericht.update.angehaengt')) -ForegroundColor Green
}

#endregion
