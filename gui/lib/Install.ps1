#Requires -Version 5.1
<#
.SYNOPSIS
    Morpheus – PC Check-up: sichere Installation (Schutz vor Rechteausweitung) und gesicherter Datenordner.

.DESCRIPTION
    Wird per Dot-Source geladen (pc-check-gui.ps1, Tests). Hintergrund:
    - H1: Die GUI führt ihren Code mit Adminrechten aus. Liegt er in einem Ordner, den normale Benutzer ändern
      dürfen (z. B. E:\ mit "Authentifizierte Benutzer: Ändern"), könnte ein Schadprogramm ohne Adminrechte den Code
      austauschen und so Adminrechte erlangen. Deshalb läuft Morpheus nur aus einem Ordner, den ausschließlich
      Administratoren, SYSTEM und TrustedInstaller ändern dürfen (Standard: C:\Program Files\Morpheus).
    - M1: Journal, Berichte, Zustände und Akzeptanzliste (Daten) liegen in C:\ProgramData\Morpheus, ebenfalls nur
      für Administratoren beschreibbar. Sonst könnte ein gefälschter Journal-Eintrag "Rückgängig" missbrauchen.

    Alle Rechteprüfungen arbeiten mit SIDs, nie mit Namen (sprachunabhängig).
    Test-MorpheusSecurePath und Get-MorpheusCodeFiles ändern nichts. Install-Morpheus und Initialize-MorpheusDataDir
    brauchen Adminrechte und ändern Rechte unter Program Files bzw. ProgramData.
#>

# Vertrauenswürdige Besitzer und Schreibende (SIDs)
$script:MorpheusSidAdmins = 'S-1-5-32-544'
$script:MorpheusSidSystem = 'S-1-5-18'
$script:MorpheusSidTrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$script:MorpheusSidAuthUsers = 'S-1-5-11'
$script:MorpheusTrustedSids = @($script:MorpheusSidAdmins, $script:MorpheusSidSystem, $script:MorpheusSidTrustedInstaller)

# Schreibrechte (FileSystemRights-Bits, auch Rohbits): WriteData/CreateFiles 0x2, AppendData/CreateDirectories 0x4,
# WriteExtendedAttributes 0x10, DeleteSubdirectoriesAndFiles 0x40, WriteAttributes 0x100, Delete 0x10000,
# ChangePermissions 0x40000, TakeOwnership 0x80000, GENERIC_ALL 0x10000000, GENERIC_WRITE 0x40000000
# (Write/Modify/FullControl enthalten diese Bits ohnehin).
$script:MorpheusWriteMask = (0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000)
# Für Elternordner zählt nur, was das Umbenennen, Löschen oder Ersetzen des Ordners erlaubt
# (Unterordner anlegen darf z. B. auf C:\ jeder Benutzer, das gefährdet C:\Program Files nicht).
$script:MorpheusParentMask = (0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000)

$script:MorpheusMaxReasons = 25

#region Hilfsfunktionen (privat)

function MorpheusIsAdmin {
    try { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { $false }
}

function MorpheusProgramData {
    $p = $env:ProgramData
    if (-not $p) { $p = 'C:\ProgramData' }
    $p
}

function MorpheusDefaultTarget { Join-Path $(if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }) 'Morpheus' }
function MorpheusDefaultDataDir { Join-Path (MorpheusProgramData) 'Morpheus' }

# Anzeigename einer SID (deutsch für bekannte SIDs, sonst Kontoname, sonst die SID selbst)
function MorpheusSidName {
    param([string]$Sid)
    $known = @{
        'S-1-5-32-544' = 'Administratoren'; 'S-1-5-18' = 'SYSTEM'; 'S-1-5-11' = 'Authentifizierte Benutzer'
        'S-1-5-32-545' = 'Benutzer'; 'S-1-5-32-546' = 'Gäste'; 'S-1-5-32-547' = 'Hauptbenutzer'; 'S-1-1-0' = 'Jeder'
        'S-1-3-0' = 'ERSTELLER-BESITZER'; 'S-1-5-4' = 'Interaktiv'; 'S-1-5-32-551' = 'Sicherungs-Operatoren'
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' = 'TrustedInstaller'
    }
    if ($known.ContainsKey($Sid)) { return $known[$Sid] }
    try { return ([Security.Principal.SecurityIdentifier]$Sid).Translate([Security.Principal.NTAccount]).Value } catch { return $Sid }
}

function MorpheusIsReparse {
    param([IO.FileSystemInfo]$Item)
    (([int]$Item.Attributes) -band [int][IO.FileAttributes]::ReparsePoint) -ne 0
}

# Alle Einträge unterhalb von $Path, ohne Verknüpfungen (Junctions/Symlinks) zu betreten. Liefert FileSystemInfo.
function MorpheusTreeItems {
    param([string]$Path, [System.Collections.Generic.List[string]]$Errors)
    $result = New-Object System.Collections.Generic.List[IO.FileSystemInfo]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            foreach ($e in (New-Object IO.DirectoryInfo $d).GetFileSystemInfos()) {
                $result.Add($e)
                if (($e -is [IO.DirectoryInfo]) -and (-not (MorpheusIsReparse $e))) { $stack.Push($e.FullName) }
            }
        }
        catch { if ($Errors) { $Errors.Add("Ordner $d nicht lesbar: $($_.Exception.Message)") } }
    }
    $result
}

# Prüft ein einzelnes Objekt (Besitzer und Schreibrechte). Hängt Gründe an $Reasons an.
function MorpheusCheckAcl {
    param([string]$Path, [int]$Mask, [bool]$CheckOwner, [System.Collections.Generic.List[string]]$Reasons, [string]$Context)
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop }
    catch { $Reasons.Add("Rechte von $Path nicht lesbar: $($_.Exception.Message)"); return }
    if ($CheckOwner) {
        $owner = $null
        try { $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { }
        if ((-not $owner) -or ($script:MorpheusTrustedSids -notcontains $owner)) {
            $Reasons.Add(("Besitzer von {0} ist {1} ({2}), nicht Administratoren, SYSTEM oder TrustedInstaller" -f $Path, (MorpheusSidName $owner), $owner))
        }
    }
    $seen = @{}
    foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($r.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        # Nur-Vererbungs-Einträge wirken nicht auf das Objekt selbst (gilt auch für ERSTELLER-BESITZER)
        if (([int]$r.PropagationFlags -band [int][Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        $sid = $r.IdentityReference.Value
        if ($script:MorpheusTrustedSids -contains $sid) { continue }
        if (([int]$r.FileSystemRights -band $Mask) -eq 0) { continue }
        $key = "$sid|$Path"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $verb = 'ändern'
        if ($Context) { $verb = $Context }
        $Reasons.Add(("{0} ({1}) dürfen {2} {3}" -f (MorpheusSidName $sid), $sid, $Path, $verb))
    }
}

#endregion

#region Öffentliche Funktionen

<#
.SYNOPSIS
    Prüft, ob nur Administratoren, SYSTEM und TrustedInstaller eine Datei bzw. einen Ordner ändern können.
.OUTPUTS
    @{ Sicher = [bool]; Gruende = [string[]] }
#>
function Test-MorpheusSecurePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse,
        [switch]$NoParents   # nur das Objekt selbst prüfen, nicht die Elternordner (intern: für Unterordner der Codedatei-Prüfung)
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    $total = 0
    try { $full = [IO.Path]::GetFullPath($Path) }
    catch { return @{ Sicher = $false; Gruende = @("Ungültiger Pfad: $Path") } }
    $full = $full.TrimEnd('\')
    if ($full.Length -eq 2) { $full += '\' }   # "E:" -> "E:\"

    $isDir = Test-Path -LiteralPath $full -PathType Container
    if ((-not $isDir) -and (-not (Test-Path -LiteralPath $full -PathType Leaf))) {
        return @{ Sicher = $false; Gruende = @("Pfad nicht gefunden: $full") }
    }
    $item = Get-Item -LiteralPath $full -Force
    if (MorpheusIsReparse $item) { $reasons.Add("$full ist eine Verknüpfung (Junction/Symlink); das Ziel ließe sich austauschen") }

    # Das Objekt selbst: Besitzer und Schreibrechte
    $before = $reasons.Count
    MorpheusCheckAcl -Path $full -Mask $script:MorpheusWriteMask -CheckOwner $true -Reasons $reasons -Context 'ändern'
    $total += ($reasons.Count - $before)

    # Inhalt
    if ($isDir -and $Recurse) {
        $errs = New-Object System.Collections.Generic.List[string]
        foreach ($e in (MorpheusTreeItems -Path $full -Errors $errs)) {
            if (MorpheusIsReparse $e) { $reasons.Add("$($e.FullName) ist eine Verknüpfung (Junction/Symlink)") }
            MorpheusCheckAcl -Path $e.FullName -Mask $script:MorpheusWriteMask -CheckOwner $true -Reasons $reasons -Context 'ändern'
        }
        foreach ($x in $errs) { $reasons.Add($x) }
    }

    # Elternordner: sonst ließe sich der ganze Ordner umbenennen oder ersetzen
    if ((-not $NoParents)) {
        $parent = Split-Path -Parent $full
        while ($parent) {
            MorpheusCheckAcl -Path $parent -Mask $script:MorpheusParentMask -CheckOwner $false -Reasons $reasons -Context 'ändern, löschen oder ersetzen (damit auch den Ordner darunter)'
            $parent = Split-Path -Parent $parent
        }
    }

    $list = @($reasons)
    if ($list.Count -gt $script:MorpheusMaxReasons) {
        $rest = $list.Count - $script:MorpheusMaxReasons
        $list = @($list | Select-Object -First $script:MorpheusMaxReasons) + @("... und $rest weitere Gründe")
    }
    @{ Sicher = ($reasons.Count -eq 0); Gruende = $list }
}

<#
.SYNOPSIS
    Die Dateien, die zur Laufzeit ausgeführt bzw. ausgeliefert werden (nicht gui\dev, tests, docs, reports, changes, state, .git).
#>
function Get-MorpheusCodeFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($n in 'pc-check.ps1', 'pc-check.cmd', 'pc-check-start.ps1', 'pc-check.hilfe.psd1', 'pc-check.aktionen.ps1', 'pc-check-gui.ps1', 'pc-check-gui.cmd',
        'accepted.example.psd1', 'README.md', 'LICENSE', 'gui\index.html', 'gui\app.js', 'gui\app.css') {
        $p = Join-Path $Root $n
        if (Test-Path -LiteralPath $p -PathType Leaf) { $out.Add($p) }
    }
    foreach ($sub in @(@('gui\lib', '*.ps1'), @('gui\assets', '*'))) {
        $d = Join-Path $Root $sub[0]
        if (Test-Path -LiteralPath $d -PathType Container) {
            foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter $sub[1] -File -Force -ErrorAction SilentlyContinue | Sort-Object Name)) { $out.Add($f.FullName) }
        }
    }
    $out.ToArray()
}

# Prüft Root (mit Elternordnern), die Ordner der Codedateien und jede Codedatei. Für den Start der GUI.
function Test-MorpheusCodeSecure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $reasons = New-Object System.Collections.Generic.List[string]
    $r = Test-MorpheusSecurePath -Path $Root
    foreach ($g in $r.Gruende) { $reasons.Add($g) }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $files = @(Get-MorpheusCodeFiles -Root $Root)
    $dirs = @{}
    foreach ($f in $files) {
        $d = Split-Path -Parent $f
        if ($d -ne $rootFull) { $dirs[$d] = $true }
    }
    foreach ($d in ($dirs.Keys | Sort-Object)) {
        $x = Test-MorpheusSecurePath -Path $d -NoParents
        foreach ($g in $x.Gruende) { $reasons.Add($g) }
    }
    foreach ($f in $files) {
        $x = Test-MorpheusSecurePath -Path $f -NoParents
        foreach ($g in $x.Gruende) { $reasons.Add($g) }
    }
    $list = @($reasons | Select-Object -Unique)
    if ($list.Count -gt $script:MorpheusMaxReasons) {
        $rest = $list.Count - $script:MorpheusMaxReasons
        $list = @($list | Select-Object -First $script:MorpheusMaxReasons) + @("... und $rest weitere Gründe")
    }
    @{ Sicher = ($reasons.Count -eq 0); Gruende = $list }
}

# SHA256 über den Inhalt. Textdateien werden vorher auf LF normalisiert (jedes CR direkt vor LF entfällt), damit
# Git-Checkouts mit CRLF bzw. LF denselben Stand ergeben. Jede inhaltliche Änderung ändert den Hash weiterhin.
function MorpheusContentHash {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if (($ext -in '.ps1', '.psd1', '.psm1', '.cmd', '.bat', '.md', '.txt', '.html', '.js', '.css', '.json', '.svg') -or ($ext -eq '')) {
        $out = New-Object System.Collections.Generic.List[byte] ($bytes.Length)
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if (($bytes[$i] -eq 13) -and (($i + 1) -lt $bytes.Length) -and ($bytes[$i + 1] -eq 10)) { continue }
            $out.Add($bytes[$i])
        }
        $bytes = $out.ToArray()
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
}

# Sind alle Codedateien von Quelle und Ziel gleich (relative Pfade und SHA256) und ist das Ziel sicher?
function Test-MorpheusInstallCurrent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target)
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) { return $false }
    $src = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $tgt = [IO.Path]::GetFullPath($Target).TrimEnd('\')
    $map = {
        param($root, $files)
        $h = @{}
        foreach ($f in $files) {
            $rel = $f.Substring($root.Length).TrimStart('\').ToLowerInvariant()
            $h[$rel] = MorpheusContentHash $f
        }
        $h
    }
    $a = & $map $src @(Get-MorpheusCodeFiles -Root $src)
    $b = & $map $tgt @(Get-MorpheusCodeFiles -Root $tgt)
    if ($a.Count -ne $b.Count) { return $false }
    foreach ($k in $a.Keys) { if ((-not $b.ContainsKey($k)) -or ($a[$k] -ne $b[$k])) { return $false } }
    $sec = Test-MorpheusSecurePath -Path $tgt -Recurse
    return [bool]$sec.Sicher
}

function MorpheusIcacls {
    # icacls.exe ausführen; ein Fehlercode ist ein Fehler
    param([string[]]$IcaclsArgs)
    $exe = Join-Path $env:SystemRoot 'System32\icacls.exe'
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& $exe @IcaclsArgs 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0) { throw ("icacls {0} schlug fehl (Code {1}): {2}" -f ($IcaclsArgs -join ' '), $LASTEXITCODE, (($out | Where-Object { $_.Trim() }) -join ' | ')) }
}

<#
.SYNOPSIS
    Legt den Datenordner an und sichert ihn: Besitzer Administratoren, ohne Vererbung, Schreiben nur für
    Administratoren und SYSTEM. Auch ein vorhandener Ordner wird neu gesichert (Schutz vor vorab angelegtem Ordner).
.DESCRIPTION
    Ist der Ordner bereits sicher (Test-MorpheusSecurePath -Recurse), wird nur noch geprüft und werden fehlende
    Unterordner angelegt; das hält den Start schnell. -Force sichert in jedem Fall neu.
#>
function New-MorpheusSecureDirectory {
    # Legt einen Ordner in EINEM Schritt mit fertigen Rechten an (kein Zeitfenster mit geerbten ProgramData-Rechten):
    # Besitzer Administratoren, ohne Vererbung; Administratoren und SYSTEM Vollzugriff, sonst niemand.
    param([string]$Path)
    $ds = New-Object System.Security.AccessControl.DirectorySecurity
    $ds.SetAccessRuleProtection($true, $false)
    $ds.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($script:MorpheusSidAdmins)))
    $inh = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    # Nur Administratoren und SYSTEM: Berichte enthalten Programme, Konten und Netzwerkdetails (auch andere Benutzerkonten
    # des PCs sollen sie nicht lesen). Die GUI läuft mit Adminrechten und zeigt sie an.
    foreach ($r in @(@($script:MorpheusSidAdmins, 'FullControl'), @($script:MorpheusSidSystem, 'FullControl'))) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($r[0])
        $ds.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [System.Security.AccessControl.FileSystemRights]$r[1], $inh, $none, 'Allow')))
    }
    [void][IO.Directory]::CreateDirectory($Path, $ds)
    # CreateDirectory legt einen bereits vorhandenen Ordner nicht neu an: dann wäre er nicht unserer
    $chk = Test-MorpheusSecurePath -Path $Path
    if (-not $chk.Sicher) { throw "Der Ordner $Path ließ sich nicht sicher anlegen: " + ($chk.Gruende -join ' | ') }
}

function Initialize-MorpheusDataDir {
    # Richtet C:\ProgramData\Morpheus ein. ProgramData erlaubt normalen Benutzern das Anlegen von Ordnern; ein vorab
    # angelegter (fremder) Ordner wird deshalb NIE repariert (rekursives icacls könnte dabei Verknüpfungen folgen, die der
    # Besitzer jederzeit neu anlegen kann), sondern unangetastet beiseitegelegt und durch einen neuen ersetzt.
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = MorpheusDefaultDataDir }
    $Path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (MorpheusIsAdmin)) { throw 'Der Datenordner lässt sich nur mit Administratorrechten einrichten.' }

    if (Test-Path -LiteralPath $Path) {
        $it = Get-Item -LiteralPath $Path -Force
        $ok = $false
        if (($it -is [IO.DirectoryInfo]) -and (-not (MorpheusIsReparse $it))) { $ok = (Test-MorpheusSecurePath -Path $Path -Recurse).Sicher }
        if (-not $ok) {
            # Nur den obersten Eintrag umbenennen; Inhalt und Verknüpfungen darin werden nicht angefasst
            $aside = '{0}.unsicher-{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Write-Warning "Der vorhandene Ordner $Path war nicht gesichert und wurde nach $aside verschoben (nicht verwendet)."
            if (MorpheusIsReparse $it) {
                if ($it -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($Path, $false) } else { [IO.File]::Delete($Path) }
            }
            else {
                # Umbenennen braucht Löschrecht am Ordner: Besitz nur am obersten Ordner übernehmen (ohne /T)
                MorpheusIcacls @($Path, '/setowner', ('*' + $script:MorpheusSidAdmins), '/C')
                MorpheusIcacls @($Path, '/grant', ('*{0}:(D)' -f $script:MorpheusSidAdmins), '/C')
                if ($it -is [IO.DirectoryInfo]) { [IO.Directory]::Move($Path, $aside) } else { [IO.File]::Move($Path, $aside) }
            }
        }
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-MorpheusSecureDirectory -Path $Path }
    else {
        # Ältere Fassung (v2.1 vor dem 25.10.2026) gab Authentifizierten Benutzern Leserecht: nur am obersten, bereits
        # gesicherten Ordner entfernen; die Unterobjekte erben die Änderung (ihr Inhalt stammt nur von Administratoren).
        $hasRead = @((Get-Acl -LiteralPath $Path).Access | Where-Object {
                (-not $_.IsInherited) -and ($_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $script:MorpheusSidAuthUsers) }).Count -gt 0
        if ($hasRead) { MorpheusIcacls @($Path, '/remove:g', ('*' + $script:MorpheusSidAuthUsers), '/C') }
    }
    # Unterordner erben die gesicherten Rechte des neuen Ordners
    foreach ($sub in 'reports', 'changes', 'state') {
        $d = Join-Path $Path $sub
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { [void][IO.Directory]::CreateDirectory($d) }
    }
    $final = Test-MorpheusSecurePath -Path $Path -Recurse
    if (-not $final.Sicher) { throw ("Der Datenordner $Path ließ sich nicht sichern: " + ($final.Gruende -join ' | ')) }
    $Path
}

# PNG -> ICO (ein PNG-Bild 256x256 im ICO-Container, ab Windows Vista gültig). Gibt $true bei Erfolg zurück.
function New-MorpheusIcon {
    [CmdletBinding()]
    param([string]$PngPath, [string]$IcoPath)
    try {
        Add-Type -AssemblyName System.Drawing
        $src = [System.Drawing.Image]::FromFile($PngPath)
        try {
            $bmp = New-Object System.Drawing.Bitmap 256, 256
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.Clear([System.Drawing.Color]::Transparent)
                # Seitenverhältnis erhalten, zentrieren
                $scale = [Math]::Min(256.0 / $src.Width, 256.0 / $src.Height)
                $w = [int]($src.Width * $scale); $h = [int]($src.Height * $scale)
                $g.DrawImage($src, [int]((256 - $w) / 2), [int]((256 - $h) / 2), $w, $h)
            }
            finally { $g.Dispose() }
            $ms = New-Object IO.MemoryStream
            try {
                $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                $png = $ms.ToArray()
            }
            finally { $ms.Dispose(); $bmp.Dispose() }
        }
        finally { $src.Dispose() }
        $fs = [IO.File]::Open($IcoPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
        try {
            $bw = New-Object IO.BinaryWriter $fs
            $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)             # ICONDIR: reserviert, Typ Symbol, 1 Bild
            $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0) # Breite/Höhe 0 = 256, Farben, reserviert
            $bw.Write([uint16]1); $bw.Write([uint16]32)                                    # Ebenen, Bit pro Pixel
            $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)                          # Größe, Offset
            $bw.Write($png)
            $bw.Flush()
        }
        finally { $fs.Dispose() }
        return $true
    }
    catch { return $false }
}

<#
.SYNOPSIS
    Installiert Morpheus nach C:\Program Files\Morpheus (bzw. -Target), richtet den Datenordner und die
    Startmenü-Verknüpfung ein. Gibt den Zielpfad zurück. Braucht Adminrechte.
#>
function Install-Morpheus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [string]$Target,
        [string]$DataDir
    )
    if (-not $Target) { $Target = MorpheusDefaultTarget }
    if (-not $DataDir) { $DataDir = MorpheusDefaultDataDir }
    if (-not (MorpheusIsAdmin)) { throw 'Die Installation braucht Administratorrechte.' }
    $Source = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $Target = [IO.Path]::GetFullPath($Target).TrimEnd('\')
    if ($Source -ieq $Target) { throw 'Quelle und Ziel sind derselbe Ordner.' }
    if (-not (Test-Path -LiteralPath (Join-Path $Source 'pc-check-gui.ps1') -PathType Leaf)) { throw "Im Quellordner $Source liegt kein pc-check-gui.ps1." }

    # Ein vorhandenes, nicht sicheres Ziel wird nie überschrieben (es könnte schon manipuliert sein)
    if (Test-Path -LiteralPath $Target) {
        $pre = Test-MorpheusSecurePath -Path $Target -Recurse
        if (-not $pre.Sicher) {
            throw ("Abbruch: $Target existiert, ist aber nicht sicher und wird nicht überschrieben. Grund: " + ($pre.Gruende -join ' | ') +
                ". Bitte den Ordner als Administrator prüfen oder entfernen.")
        }
    }
    else { [void](New-Item -ItemType Directory -Path $Target -Force) }

    # Codedateien kopieren (nur die Liste aus Get-MorpheusCodeFiles); der Rest bleibt draußen
    $srcFiles = @(Get-MorpheusCodeFiles -Root $Source)
    $keep = @{}
    foreach ($f in $srcFiles) {
        $rel = $f.Substring($Source.Length).TrimStart('\')
        $keep[$rel.ToLowerInvariant()] = $true
        $dest = Join-Path $Target $rel
        $dd = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $dd -PathType Container)) { [void](New-Item -ItemType Directory -Path $dd -Force) }
        Copy-Item -LiteralPath $f -Destination $dest -Force
    }
    # Codedateien, die es in der Quelle nicht mehr gibt, im Ziel entfernen
    foreach ($old in @(Get-MorpheusCodeFiles -Root $Target)) {
        $rel = $old.Substring($Target.Length).TrimStart('\')
        if (-not $keep.ContainsKey($rel.ToLowerInvariant())) { Remove-Item -LiteralPath $old -Force }
    }

    # Symbol für die Verknüpfung (misslingt es, geht es ohne Symbol weiter)
    $ico = Join-Path $Target 'morpheus.ico'
    $png = Join-Path $Source 'gui\assets\morpheus-icon.png'
    $haveIcon = $false
    if (Test-Path -LiteralPath $png -PathType Leaf) { $haveIcon = New-MorpheusIcon -PngPath $png -IcoPath $ico }

    $chk = Test-MorpheusSecurePath -Path $Target -Recurse
    if (-not $chk.Sicher) { throw ("Der installierte Ordner $Target ist nicht sicher: " + ($chk.Gruende -join ' | ')) }

    # Datenordner und einmalige Übernahme von Berichten und Akzeptanzliste (nur was noch fehlt).
    # Das Änderungsjournal wird bewusst NICHT übernommen: Der Quellordner gilt als nicht vertrauenswürdig.
    $dataRoot = Initialize-MorpheusDataDir -Path $DataDir
    $rep = Join-Path $dataRoot 'reports'
    $srcRep = Join-Path $Source 'reports'
    if (Test-Path -LiteralPath $srcRep -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $srcRep -Filter 'pc-check_*.*' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -notmatch '^pc-check_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}\.(json|html|md)$') { continue }
            if (MorpheusIsReparse $f) { continue }
            $d = Join-Path $rep $f.Name
            if (-not (Test-Path -LiteralPath $d)) { [IO.File]::Copy($f.FullName, $d, $false) }
        }
    }
    $srcAcc = Join-Path $Source 'accepted.psd1'
    $dstAcc = Join-Path $dataRoot 'accepted.psd1'
    if ((Test-Path -LiteralPath $srcAcc -PathType Leaf) -and (-not (Test-Path -LiteralPath $dstAcc)) -and (-not (MorpheusIsReparse (Get-Item -LiteralPath $srcAcc -Force)))) {
        [IO.File]::Copy($srcAcc, $dstAcc, $false)
    }
    $fin = Test-MorpheusSecurePath -Path $dataRoot -Recurse
    if (-not $fin.Sicher) { throw ("Der Datenordner $dataRoot ist nach der Übernahme nicht sicher: " + ($fin.Gruende -join ' | ')) }

    # Startmenü-Verknüpfung für alle Benutzer
    try {
        $lnkDir = Join-Path (MorpheusProgramData) 'Microsoft\Windows\Start Menu\Programs'
        if (Test-Path -LiteralPath $lnkDir -PathType Container) {
            $lnk = Join-Path $lnkDir ('Morpheus {0} PC Check-up.lnk' -f [char]0x2013)
            $sh = New-Object -ComObject WScript.Shell
            $sc = $sh.CreateShortcut($lnk)
            $sc.TargetPath = Join-Path $Target 'pc-check-gui.cmd'
            $sc.WorkingDirectory = $Target
            $sc.Description = 'Morpheus - PC Check-up'
            if ($haveIcon) { $sc.IconLocation = "$ico,0" }
            $sc.Save()
        }
    }
    catch { Write-Warning "Die Startmenü-Verknüpfung konnte nicht angelegt werden: $($_.Exception.Message)" }

    $Target
}

#endregion
