#Requires -Version 5.1
<#
.SYNOPSIS
    Speicherverbraucher (#36) und Spieleliste (#38) für Morpheus.

.DESCRIPTION
    Wird per Dot-Source geladen (pc-check.ps1, Job „speicher“). Definiert die Funktionen aus
    docs/gui-architektur.md, Abschnitt 14.2. Regeln:
    - Rein lesend: nichts wird geändert oder gelöscht.
    - Reparse Points (Junctions, Symlinks) werden nie betreten oder gezählt.
    - Ordner ohne Zugriff werden übersprungen und gezählt.
    - Aufzählung per [IO.DirectoryInfo] mit eigenem Stapel, kein -Recurse, kein Add-Type.
    - Die Datei führt beim Laden nichts aus.
#>

$script:MorpheusSpeicherVersion = 1
# Dateien im Stammordner, die als Windows-Systemdateien gekennzeichnet werden
$script:MorpheusSystemDateien = @('pagefile.sys', 'hiberfil.sys', 'swapfile.sys')
# Steamworks Common Redistributables
$script:MorpheusSteamIgnoriert = @('228980')

#region Hilfsfunktionen (privat)

function MorpheusSpeicherIso {
    param($Datum)
    if ($null -eq $Datum) { return $null }
    ([datetime]$Datum).ToString('s')
}

function MorpheusSpeicherLaufwerkVon {
    param([string]$Pfad)
    if ($Pfad -match '^([A-Za-z]):') { return ($Matches[1].ToUpper() + ':') }
    return $null
}

# Pfade aus Launcher-Dateien und HKCU kann jedes Programm des Benutzers ändern. Nur lokale Laufwerkspfade (X:\…)
# werden angefasst: ein UNC-Pfad (\\server\…) würde den Admin-Prozess sonst zu einem fremden Rechner verbinden lassen.
function MorpheusSpeicherPfadNorm {
    param([string]$Pfad)
    if ([string]::IsNullOrWhiteSpace($Pfad)) { return '' }
    $p = ($Pfad.Trim() -replace '/', '\').TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { return $p }
    if ($p -notmatch '^[A-Za-z]:\\[^\\]') { return '' }
    $p
}

function New-MorpheusSpiel {
    param([string]$Plattform, [string]$Name, [string]$Pfad, [double]$Bytes, $ZuletztGespielt = $null, [bool]$GroesseUnsicher = $false)
    [pscustomobject][ordered]@{
        plattform       = $Plattform
        name            = $Name
        pfad            = $Pfad
        laufwerk        = (MorpheusSpeicherLaufwerkVon $Pfad)
        bytes           = $Bytes
        zuletztGespielt = $ZuletztGespielt
        groesseUnsicher = $GroesseUnsicher
    }
}

# Registry-Abfrage gekapselt, damit Tests sie mocken können. Liefert Eigenschaftsobjekte (inkl. PSChildName).
function Get-MorpheusRegEintraege {
    param([string]$Pfad)
    @(Get-ItemProperty -Path $Pfad -ErrorAction SilentlyContinue)
}

# Registrywert gekapselt (Steam-Pfad), mockbar.
function Get-MorpheusRegWert {
    param([string]$Pfad, [string]$Name)
    try { return (Get-ItemProperty -Path $Pfad -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

# Zählt alle Dateien unter $Wurzel. Ordnergrößen (Summe aller Dateien darunter) werden für die
# Ordner der Tiefe 1..$Tiefe geführt. Gibt ein Objekt mit bytes, dateien, uebersprungen, groessen, top zurück.
function Invoke-MorpheusZaehlen {
    param([string]$Wurzel, [int]$Tiefe = 0, [int]$TopDateien = 0, [scriptblock]$Fortschritt)

    $groessen = @{}
    $total = [double]0
    $anzahl = 0
    $skip = 0
    $topOn = ($TopDateien -gt 0)
    $top = New-Object System.Collections.Generic.List[object]
    $min = [double]0
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@((New-Object System.IO.DirectoryInfo $Wurzel), @()))

    while ($stack.Count -gt 0) {
        $e = $stack.Pop()
        $d = $e[0]
        $keys = $e[1]
        if ($Fortschritt -and $keys.Count -eq 1 -and $keys[0] -eq $d.FullName) {
            try { & $Fortschritt $d.FullName } catch { }
        }
        $summe = [double]0
        $n = 0
        $bad = $false
        try {
            foreach ($f in $d.EnumerateFiles()) {
                if ($f.Attributes -band 1024) { continue }
                $len = [double]$f.Length
                $summe += $len
                $n++
                if ($topOn -and $len -gt $min) {
                    $eintrag = @($len, $f.FullName, $f.LastWriteTime)
                    if ($top.Count -lt $TopDateien) {
                        $top.Add($eintrag)
                    } else {
                        $mi = 0
                        for ($i = 1; $i -lt $top.Count; $i++) { if ($top[$i][0] -lt $top[$mi][0]) { $mi = $i } }
                        $top[$mi] = $eintrag
                    }
                    if ($top.Count -ge $TopDateien) {
                        $min = $top[0][0]
                        for ($i = 1; $i -lt $top.Count; $i++) { if ($top[$i][0] -lt $min) { $min = $top[$i][0] } }
                    }
                }
            }
        } catch { $bad = $true }
        try {
            foreach ($c in $d.EnumerateDirectories()) {
                if ($c.Attributes -band 1024) { continue }
                if ($keys.Count -lt $Tiefe) { $ck = $keys + $c.FullName } else { $ck = $keys }
                $stack.Push(@($c, $ck))
            }
        } catch { $bad = $true }
        if ($bad) { $skip++ }
        if ($n -gt 0) {
            $total += $summe
            $anzahl += $n
            foreach ($k in $keys) { $groessen[$k] += $summe }
        }
    }

    [pscustomobject]@{ bytes = $total; dateien = $anzahl; uebersprungen = $skip; groessen = $groessen; top = $top }
}

#endregion

#region Laufwerke und Ordner

function Get-MorpheusFesteLaufwerke {
    $usb = @()
    try {
        foreach ($disk in @(Get-Disk -ErrorAction Stop | Where-Object { [string]$_.BusType -eq 'USB' })) {
            foreach ($p in @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)) {
                if ($p.DriveLetter) { $usb += ([string]$p.DriveLetter).ToUpper() + ':' }
            }
        }
    } catch { }
    $liste = @()
    try {
        foreach ($l in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)) {
            $id = ([string]$l.DeviceID).ToUpper()
            if ($usb -notcontains $id) { $liste += $id }
        }
    } catch { }
    return @($liste | Sort-Object)
}

function Measure-MorpheusOrdnerGroesse {
    param([Parameter(Mandatory)][string]$Pfad)
    $r = Invoke-MorpheusZaehlen -Wurzel $Pfad
    [pscustomobject]@{ bytes = [double]$r.bytes; dateien = [int]$r.dateien; uebersprungen = [int]$r.uebersprungen }
}

function Select-MorpheusTopOrdner {
    param([Parameter(Mandatory)][hashtable]$Groessen, [int]$Top = 10, [double]$Anteil = 0.75)

    # Schlüssel normalisieren (ohne Groß-/Kleinschreibung, ohne Endbackslash)
    $bytes = @{}
    $name = @{}
    foreach ($k in $Groessen.Keys) {
        $n = (MorpheusSpeicherPfadNorm ([string]$k)).ToLowerInvariant()
        if ($n -eq '') { continue }
        $bytes[$n] = [double]$Groessen[$k]
        $name[$n] = (MorpheusSpeicherPfadNorm ([string]$k))
    }
    # größter direkter Unterordner je Elternordner
    $groesstesKind = @{}
    foreach ($n in $bytes.Keys) {
        $eltern = [IO.Path]::GetDirectoryName($n)
        if ([string]::IsNullOrEmpty($eltern)) { continue }
        $eltern = $eltern.TrimEnd('\')
        if (-not $bytes.ContainsKey($eltern)) { continue }
        if ((-not $groesstesKind.ContainsKey($eltern)) -or ($bytes[$n] -gt $groesstesKind[$eltern])) { $groesstesKind[$eltern] = $bytes[$n] }
    }
    # Schritt 1: dominanter Kind-Ordner ersetzt den Elternordner
    $kandidaten = @()
    foreach ($n in $bytes.Keys) {
        if ($bytes[$n] -le 0) { continue }
        if ($groesstesKind.ContainsKey($n) -and ($groesstesKind[$n] -ge ($Anteil * $bytes[$n]))) { continue }
        $kandidaten += [pscustomobject]@{ schluessel = $n; pfad = $name[$n]; bytes = $bytes[$n] }
    }
    # Schritt 2: Greedy ohne Vorfahr/Nachfahr
    $gewaehlt = @()
    foreach ($c in @($kandidaten | Sort-Object @{ Expression = 'bytes'; Descending = $true }, 'schluessel')) {
        if ($gewaehlt.Count -ge $Top) { break }
        $konflikt = $false
        foreach ($g in $gewaehlt) {
            if ($c.schluessel.StartsWith($g.schluessel + '\') -or $g.schluessel.StartsWith($c.schluessel + '\')) { $konflikt = $true; break }
        }
        if (-not $konflikt) { $gewaehlt += $c }
    }
    return @($gewaehlt | ForEach-Object { [pscustomobject][ordered]@{ pfad = $_.pfad; bytes = [double]$_.bytes } })
}

function Measure-MorpheusLaufwerk {
    # -Stamm (intern/Tests): zählt diesen Ordner statt des ganzen Laufwerks
    param(
        [string]$Laufwerk,
        [int]$Tiefe = 3,
        [int]$Top = 10,
        [double]$Anteil = 0.75,
        [scriptblock]$Fortschritt,
        [string]$Stamm
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($Stamm) {
        $wurzel = $Stamm
        if (-not $Laufwerk) { $Laufwerk = MorpheusSpeicherLaufwerkVon $Stamm }
    } else {
        $Laufwerk = $Laufwerk.TrimEnd('\').ToUpper()
        $wurzel = $Laufwerk + '\'
    }
    $groesse = $null; $frei = $null; $bez = ''
    try {
        $di = New-Object System.IO.DriveInfo ($Laufwerk.Substring(0, 1))
        $groesse = [double]$di.TotalSize
        $frei = [double]$di.AvailableFreeSpace
        $bez = [string]$di.VolumeLabel
    } catch { }
    $obj = [ordered]@{
        laufwerk      = $Laufwerk
        bezeichnung   = $bez
        groesse       = $groesse
        frei          = $frei
        ordner        = @()
        dateien       = @()
        gezaehlt      = 0
        uebersprungen = 0
        dauerSek      = 0
        fehler        = $null
    }
    if (-not (Test-Path -LiteralPath $wurzel -PathType Container)) {
        $obj.fehler = "$wurzel ist nicht lesbar"
        $obj.dauerSek = [int][math]::Round($sw.Elapsed.TotalSeconds)
        return [pscustomobject]$obj
    }
    if ($Fortschritt) { try { & $Fortschritt "$Laufwerk wird gezählt …" } catch { } }
    try {
        $r = Invoke-MorpheusZaehlen -Wurzel $wurzel -Tiefe $Tiefe -TopDateien $Top -Fortschritt $Fortschritt
        $stammNorm = (MorpheusSpeicherPfadNorm $wurzel).ToLowerInvariant()
        $obj.ordner = @(Select-MorpheusTopOrdner -Groessen $r.groessen -Top $Top -Anteil $Anteil)
        $dateien = @()
        foreach ($t in @($r.top | Sort-Object { $_[0] } -Descending)) {
            $pfad = [string]$t[1]
            $elt = (MorpheusSpeicherPfadNorm ([IO.Path]::GetDirectoryName($pfad))).ToLowerInvariant()
            $sys = (($elt -eq $stammNorm) -and ($script:MorpheusSystemDateien -contains ([IO.Path]::GetFileName($pfad)).ToLowerInvariant()))
            $dateien += [pscustomobject][ordered]@{ pfad = $pfad; bytes = [double]$t[0]; windows = [bool]$sys; geaendert = (MorpheusSpeicherIso $t[2]) }
        }
        $obj.dateien = @($dateien)
        $obj.gezaehlt = [int]$r.dateien
        $obj.uebersprungen = [int]$r.uebersprungen
    } catch {
        $obj.fehler = $_.Exception.Message
    }
    $obj.dauerSek = [int][math]::Round($sw.Elapsed.TotalSeconds)
    return [pscustomobject]$obj
}

#endregion

#region Spiele

function ConvertFrom-MorpheusVdf {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $root = @{}
    $cur = $root
    $stack = New-Object System.Collections.Generic.Stack[object]
    $hatSchluessel = $false
    $schluessel = $null
    foreach ($m in [regex]::Matches($Text, '"((?:[^"\\]|\\.)*)"|([{}])')) {
        if ($m.Groups[2].Success) {
            if ($m.Groups[2].Value -eq '{') {
                $neu = @{}
                if ($hatSchluessel) { $cur[$schluessel] = $neu }
                $stack.Push($cur)
                $cur = $neu
                $hatSchluessel = $false
            } else {
                if ($stack.Count -gt 0) { $cur = $stack.Pop() }
                $hatSchluessel = $false
            }
        } else {
            $s = $m.Groups[1].Value -replace '\\(["\\])', '$1'
            if (-not $hatSchluessel) { $schluessel = $s; $hatSchluessel = $true }
            else { $cur[$schluessel] = $s; $hatSchluessel = $false }
        }
    }
    return $root
}

function Get-MorpheusSteamSpiele {
    param([string]$SteamPfad)
    if (-not $SteamPfad) {
        $SteamPfad = Get-MorpheusRegWert 'HKCU:\Software\Valve\Steam' 'SteamPath'
        if (-not $SteamPfad) { $SteamPfad = Get-MorpheusRegWert 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' 'InstallPath' }
    }
    if (-not $SteamPfad) { return @() }
    $SteamPfad = MorpheusSpeicherPfadNorm $SteamPfad
    if (-not $SteamPfad) { return @() }

    $bibliotheken = New-Object System.Collections.Generic.List[string]
    $gesehen = @{}
    $addLib = {
        param($p)
        $n = MorpheusSpeicherPfadNorm $p
        if ($n -and -not $gesehen.ContainsKey($n.ToLowerInvariant())) { $gesehen[$n.ToLowerInvariant()] = $true; $bibliotheken.Add($n) }
    }
    & $addLib $SteamPfad
    $vdf = Join-Path $SteamPfad 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf -PathType Leaf) {
        try {
            $baum = ConvertFrom-MorpheusVdf -Text ([IO.File]::ReadAllText($vdf))
            $lf = $null
            foreach ($k in $baum.Keys) { if ($k -ieq 'libraryfolders') { $lf = $baum[$k] } }
            if ($lf -is [hashtable]) {
                foreach ($k in @($lf.Keys | Sort-Object)) {
                    $v = $lf[$k]
                    if ($v -is [hashtable]) { if ($v.ContainsKey('path')) { & $addLib ([string]$v['path']) } }
                    elseif ($k -match '^\d+$') { & $addLib ([string]$v) }
                }
            }
        } catch { }
    }

    $spiele = @()
    foreach ($lib in $bibliotheken) {
        $apps = Join-Path $lib 'steamapps'
        if (-not (Test-Path -LiteralPath $apps -PathType Container)) { continue }
        foreach ($acf in @(Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)) {
            try {
                $baum = ConvertFrom-MorpheusVdf -Text ([IO.File]::ReadAllText($acf.FullName))
                $st = $null
                foreach ($k in $baum.Keys) { if ($k -ieq 'AppState') { $st = $baum[$k] } }
                if ($st -isnot [hashtable]) { continue }
                $appid = [string]$st['appid']
                if ($script:MorpheusSteamIgnoriert -contains $appid) { continue }
                $dir = [string]$st['installdir']
                if ((-not $dir) -or (-not $st['name'])) { continue }
                $pfad = Join-Path (Join-Path $apps 'common') $dir
                if (-not (Test-Path -LiteralPath $pfad -PathType Container)) { continue }
                $bytes = [double]0
                if ($st['SizeOnDisk']) { [void][double]::TryParse([string]$st['SizeOnDisk'], [ref]$bytes) }
                $zuletzt = $null
                $lp = [long]0
                if ($st['LastPlayed'] -and [long]::TryParse([string]$st['LastPlayed'], [ref]$lp) -and $lp -gt 0) {
                    $zuletzt = MorpheusSpeicherIso ([DateTimeOffset]::FromUnixTimeSeconds($lp).LocalDateTime)
                }
                $spiele += New-MorpheusSpiel -Plattform 'Steam' -Name ([string]$st['name']) -Pfad $pfad -Bytes $bytes -ZuletztGespielt $zuletzt
            } catch { }
        }
    }
    return @($spiele)
}

function Get-MorpheusEpicSpiele {
    param([string]$ManifestOrdner)
    if (-not $ManifestOrdner) { $ManifestOrdner = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests' }
    if (-not (Test-Path -LiteralPath $ManifestOrdner -PathType Container)) { return @() }
    $spiele = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $ManifestOrdner -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
        try {
            $j = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
            if ((-not $j.InstallLocation) -or (-not $j.DisplayName)) { continue }
            $pfad = MorpheusSpeicherPfadNorm ([string]$j.InstallLocation)
            if (-not (Test-Path -LiteralPath $pfad -PathType Container)) { continue }
            $bytes = [double]0
            if ($j.InstallSize) { $bytes = [double]$j.InstallSize }
            $spiele += New-MorpheusSpiel -Plattform 'Epic' -Name ([string]$j.DisplayName) -Pfad $pfad -Bytes $bytes
        } catch { }
    }
    return @($spiele)
}

# Hilfsfunktion: Spiel aus Installationsordner mit gemessener Größe
function New-MorpheusGemessenesSpiel {
    param([string]$Plattform, [string]$Name, [string]$Pfad)
    $pfad = MorpheusSpeicherPfadNorm $Pfad
    if ((-not $pfad) -or (-not (Test-Path -LiteralPath $pfad -PathType Container))) { return $null }
    if (-not $Name) { $Name = Split-Path -Leaf $pfad }
    $m = Measure-MorpheusOrdnerGroesse -Pfad $pfad
    New-MorpheusSpiel -Plattform $Plattform -Name $Name -Pfad $pfad -Bytes $m.bytes -GroesseUnsicher ($m.uebersprungen -gt 0)
}

function Get-MorpheusGogSpiele {
    $spiele = @()
    foreach ($e in @(Get-MorpheusRegEintraege -Pfad 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games\*')) {
        try {
            $s = New-MorpheusGemessenesSpiel -Plattform 'GOG' -Name ([string]$e.gameName) -Pfad ([string]$e.path)
            if ($s) { $spiele += $s }
        } catch { }
    }
    return @($spiele)
}

function Get-MorpheusEaSpiele {
    $spiele = @()
    $eintraege = @()
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $eintraege += @(Get-MorpheusRegEintraege -Pfad $k)
    }
    foreach ($e in $eintraege) {
        try {
            if ([string]$e.Publisher -notlike 'Electronic Arts*') { continue }
            if (-not $e.InstallLocation) { continue }
            $n = [string]$e.DisplayName
            if ($n -match '^(EA app|EA Desktop|Origin)$') { continue }
            $s = New-MorpheusGemessenesSpiel -Plattform 'EA' -Name $n -Pfad ([string]$e.InstallLocation)
            if ($s) { $spiele += $s }
        } catch { }
    }
    return @($spiele)
}

function Get-MorpheusUbisoftSpiele {
    $spiele = @()
    $namen = @{}
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Uplay Install *', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Uplay Install *')) {
        foreach ($u in @(Get-MorpheusRegEintraege -Pfad $k)) {
            $id = ([string]$u.PSChildName) -replace '^Uplay Install\s+', ''
            if ($id -and $u.DisplayName) { $namen[$id] = [string]$u.DisplayName }
        }
    }
    foreach ($e in @(Get-MorpheusRegEintraege -Pfad 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs\*')) {
        try {
            $name = $null
            if ($namen.ContainsKey([string]$e.PSChildName)) { $name = $namen[[string]$e.PSChildName] }
            $s = New-MorpheusGemessenesSpiel -Plattform 'Ubisoft' -Name $name -Pfad ([string]$e.InstallDir)
            if ($s) { $spiele += $s }
        } catch { }
    }
    return @($spiele)
}

# .GamingRoot = 'RGBX', UInt32, dann der Name des Bibliotheksordners als UTF-16 mit Nullende (z. B. XboxGames oder XBOX).
# Nur ein einzelner Ordnername im Stammordner wird akzeptiert, sonst gilt der Standard XboxGames.
function Get-MorpheusXboxOrdner {
    param([Parameter(Mandatory)][string]$Datei)
    $name = 'XboxGames'
    try {
        $b = [IO.File]::ReadAllBytes($Datei)
        if (($b.Length -gt 10) -and ([Text.Encoding]::ASCII.GetString($b, 0, 4) -eq 'RGBX')) {
            $t = [Text.Encoding]::Unicode.GetString($b, 8, ($b.Length - 8) - (($b.Length - 8) % 2))
            $i = $t.IndexOf([char]0); if ($i -ge 0) { $t = $t.Substring(0, $i) }
            $t = $t.Trim().TrimEnd('\')
            if ($t -and ($t -notmatch '[\\/:*?"<>|]') -and ($t -ne '.') -and ($t -ne '..')) { $name = $t }
        }
    } catch { }
    return $name
}

function Get-MorpheusXboxSpiele {
    param([string[]]$Laufwerke)
    if (-not $Laufwerke) { $Laufwerke = Get-MorpheusFesteLaufwerke }
    $spiele = @()
    foreach ($lw in @($Laufwerke)) {
        $wurzel = $lw.TrimEnd('\') + '\'
        $gr = Join-Path $wurzel '.GamingRoot'
        if (-not (Test-Path -LiteralPath $gr -PathType Leaf)) { continue }
        $xbox = Join-Path $wurzel (Get-MorpheusXboxOrdner -Datei $gr)
        foreach ($d in @(Get-ChildItem -LiteralPath $xbox -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'GameSave' })) {
            try {
                $name = $d.Name
                $cfg = Join-Path $d.FullName 'Content\MicrosoftGame.config'
                if (Test-Path -LiteralPath $cfg -PathType Leaf) {
                    try {
                        $x = [xml][IO.File]::ReadAllText($cfg)
                        $dn = [string]$x.Game.ShellVisuals.DefaultDisplayName
                        if ($dn -and $dn -notlike 'ms-resource:*') { $name = $dn }
                    } catch { }
                }
                $s = New-MorpheusGemessenesSpiel -Plattform 'Xbox' -Name $name -Pfad $d.FullName
                if ($s) { $spiele += $s }
            } catch { }
        }
    }
    return @($spiele)
}

#region Eigene Spiele-Ordner (14.8)

$script:MorpheusSpielordnerPlattformen = @('Steam', 'Epic', 'GOG', 'EA', 'Ubisoft', 'Xbox', 'Andere')

# Liest state\spielordner.json tolerant: fehlend, leer oder kaputt ergibt @(). Höchstens 50 Einträge.
function Read-MorpheusSpielordner {
    param([Parameter(Mandatory)][string]$Datei)
    $ergebnis = @()
    try {
        if (-not (Test-Path -LiteralPath $Datei -PathType Leaf)) { return @() }
        $text = [IO.File]::ReadAllText($Datei)
        if ([string]::IsNullOrWhiteSpace($text)) { return @() }
        $roh = @($text | ConvertFrom-Json -ErrorAction Stop | ForEach-Object { $_ })
        foreach ($e in $roh) {
            if ($ergebnis.Count -ge 50) { break }
            if ($null -eq $e) { continue }
            $pl = $e.PSObject.Properties['plattform']
            $pf = $e.PSObject.Properties['pfad']
            if ((-not $pl) -or (-not $pf)) { continue }
            if (($pl.Value -isnot [string]) -or ($pf.Value -isnot [string])) { continue }
            if ($script:MorpheusSpielordnerPlattformen -cnotcontains $pl.Value) { continue }
            $norm = MorpheusSpeicherPfadNorm $pf.Value
            if (-not $norm) { continue }
            $ergebnis += [pscustomobject]@{ plattform = [string]$pl.Value; pfad = [string]$pf.Value }
        }
    } catch { return @() }
    return @($ergebnis)
}

# Jeder direkte Unterordner eines Eintrags ist ein Spiel (Reparse Points werden nie betreten).
function Get-MorpheusManuelleSpiele {
    param([object[]]$Eintraege)
    $spiele = @()
    foreach ($e in @($Eintraege)) {
        try {
            if ($null -eq $e) { continue }
            $pfad = MorpheusSpeicherPfadNorm ([string]$e.pfad)
            if (-not $pfad) { continue }
            if (-not (Test-Path -LiteralPath $pfad -PathType Container)) { continue }
            $di = New-Object System.IO.DirectoryInfo ($pfad + '\')
            if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $kinder = @()
            try {
                foreach ($c in $di.EnumerateDirectories()) {
                    if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $kinder += $c
                }
            } catch { }
            foreach ($c in $kinder) {
                try {
                    $s = New-MorpheusGemessenesSpiel -Plattform ([string]$e.plattform) -Name $c.Name -Pfad $c.FullName
                    if ($s) { $spiele += $s }
                } catch { }
            }
        } catch { }
    }
    return @($spiele)
}

#endregion

function Get-MorpheusSpiele {
    param([string[]]$Laufwerke, [scriptblock]$Fortschritt, [object[]]$Manuell)
    $alle = @()
    $quellen = @(
        @{ Text = 'Steam'; Block = { Get-MorpheusSteamSpiele } },
        @{ Text = 'Epic'; Block = { Get-MorpheusEpicSpiele } },
        @{ Text = 'GOG'; Block = { Get-MorpheusGogSpiele } },
        @{ Text = 'EA'; Block = { Get-MorpheusEaSpiele } },
        @{ Text = 'Ubisoft'; Block = { Get-MorpheusUbisoftSpiele } },
        @{ Text = 'Xbox'; Block = { if ($Laufwerke) { Get-MorpheusXboxSpiele -Laufwerke $Laufwerke } else { Get-MorpheusXboxSpiele } } }
    )
    foreach ($q in $quellen) {
        if ($Fortschritt) { try { & $Fortschritt ('Spiele werden gesucht: ' + $q.Text + ' …') } catch { } }
        try { $alle += @(& $q.Block) } catch { }
    }
    if (@($Manuell).Count -gt 0) {
        if ($Fortschritt) { try { & $Fortschritt 'Eigene Spiele-Ordner werden gemessen …' } catch { } }
        try { $alle += @(Get-MorpheusManuelleSpiele -Eintraege $Manuell) } catch { }
    }
    $gesehen = @{}
    $ergebnis = @()
    foreach ($s in $alle) {
        if ($null -eq $s) { continue }
        $k = (MorpheusSpeicherPfadNorm ([string]$s.pfad)).ToLowerInvariant()
        if ($gesehen.ContainsKey($k)) { continue }
        $gesehen[$k] = $true
        $ergebnis += $s
    }
    return @($ergebnis | Sort-Object @{ Expression = { [double]$_.bytes }; Descending = $true }, 'name')
}

#endregion

function Get-MorpheusSpeicher {
    param([string[]]$Laufwerke, [scriptblock]$Fortschritt, [switch]$OhneSpiele, [object[]]$Manuell)
    if (-not $Laufwerke) { $Laufwerke = Get-MorpheusFesteLaufwerke }
    $lw = @()
    foreach ($l in @($Laufwerke)) {
        $lw += Measure-MorpheusLaufwerk -Laufwerk $l -Fortschritt $Fortschritt
    }
    $spiele = @()
    if (-not $OhneSpiele) {
        if ($Fortschritt) { try { & $Fortschritt 'Spiele werden gesucht …' } catch { } }
        $spiele = @(Get-MorpheusSpiele -Laufwerke $Laufwerke -Fortschritt $Fortschritt -Manuell $Manuell)
    }
    [pscustomobject][ordered]@{
        version   = $script:MorpheusSpeicherVersion
        stand     = (MorpheusSpeicherIso (Get-Date))
        laufwerke = @($lw)
        spiele    = @($spiele)
    }
}
