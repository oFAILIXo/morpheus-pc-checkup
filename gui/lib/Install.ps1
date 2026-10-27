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

# Testhilfe (Reparatur, 2.4): IstAdmin ersetzt die Adminprüfung von Initialize-MorpheusDataDir und Repair-MorpheusDatenordner;
# ZusatzVertraut sind SIDs (z. B. der Testbenutzer), die zusätzlich als vertrauenswürdig gelten. Produktiv unverändert.
$script:MorpheusInstallImpl = @{ IstAdmin = { MorpheusIsAdmin }; ZusatzVertraut = @(); VorAcl = $null; ElternAb = $null }

#region Hilfsfunktionen (privat)

function MorpheusIsAdmin {
    try { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { $false }
}

function MorpheusProgramData {
    # Über die Windows-API statt $env:ProgramData: Die erhöhte Sitzung erbt Benutzervariablen aus HKCU\Environment (2.3.3)
    $p = [Environment]::GetFolderPath('CommonApplicationData')
    if (-not $p) { $p = 'C:\ProgramData' }
    $p
}

function MorpheusDefaultTarget { $pf = [Environment]::GetFolderPath('ProgramFiles'); Join-Path $(if ($pf) { $pf } else { 'C:\Program Files' }) 'Morpheus' }
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
    # NichtBetreten: volle Pfade von Ordnern, die selbst geliefert, deren Inhalt aber nicht durchsucht wird
    param([string]$Path, [System.Collections.Generic.List[string]]$Errors, [string[]]$NichtBetreten = @())
    $result = New-Object System.Collections.Generic.List[IO.FileSystemInfo]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            foreach ($e in (New-Object IO.DirectoryInfo $d).GetFileSystemInfos()) {
                $result.Add($e)
                if (($e -is [IO.DirectoryInfo]) -and (-not (MorpheusIsReparse $e)) -and ($NichtBetreten -notcontains $e.FullName.TrimEnd('\'))) { $stack.Push($e.FullName) }
            }
        }
        catch { if ($Errors) { $Errors.Add("Ordner $d nicht lesbar: $($_.Exception.Message)") } }
    }
    $result
}

# Prüft ein einzelnes Objekt (Besitzer und Schreibrechte). Hängt Gründe an $Reasons an.
function MorpheusCheckAcl {
    param([string]$Path, [int]$Mask, [bool]$CheckOwner, [System.Collections.Generic.List[string]]$Reasons, [string]$Context, [string[]]$Vertraut)
    if (-not $Vertraut) { $Vertraut = $script:MorpheusTrustedSids }
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop }
    catch { $Reasons.Add("Rechte von $Path nicht lesbar: $($_.Exception.Message)"); return }
    if ($CheckOwner) {
        $owner = $null
        try { $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { }
        if ((-not $owner) -or ($Vertraut -notcontains $owner)) {
            $Reasons.Add(("Besitzer von {0} ist {1} ({2}), nicht Administratoren, SYSTEM oder TrustedInstaller" -f $Path, (MorpheusSidName $owner), $owner))
        }
    }
    $seen = @{}
    foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($r.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        # Nur-Vererbungs-Einträge wirken nicht auf das Objekt selbst (gilt auch für ERSTELLER-BESITZER)
        if (([int]$r.PropagationFlags -band [int][Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        $sid = $r.IdentityReference.Value
        if ($Vertraut -contains $sid) { continue }
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
        [switch]$NoParents,  # nur das Objekt selbst prüfen, nicht die Elternordner (intern: für Unterordner der Codedatei-Prüfung)
        # Mit -Recurse: Unterordner (relativ zu Path), die selbst geprüft werden, deren Inhalt aber nicht. Für temp\ des
        # Datenordners: winget legt dort Ordner an, die es dem Benutzer ausdrücklich freigibt (2.3.3, Nutzertest).
        [string[]]$Ausnahmen = @()
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
        $nicht = @($Ausnahmen | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $full $_)).TrimEnd('\') })
        foreach ($e in (MorpheusTreeItems -Path $full -Errors $errs -NichtBetreten $nicht)) {
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
    $exe = Join-Path ([Environment]::SystemDirectory) 'icacls.exe'
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

function MorpheusEntferneEintrag {
    # Löscht eine Datei oder einen Ordner. Verknüpfungen (Junctions, Symlinks) werden nur selbst entfernt, nie betreten;
    # auch solche tiefer im Ordner zuerst einzeln, denn Directory.Delete scheitert sonst an ihnen.
    param([IO.FileSystemInfo]$Eintrag)
    if (MorpheusIsReparse $Eintrag) {
        if ($Eintrag -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($Eintrag.FullName, $false) } else { [IO.File]::Delete($Eintrag.FullName) }
        return
    }
    if ($Eintrag -is [IO.DirectoryInfo]) {
        foreach ($x in @(MorpheusTreeItems -Path $Eintrag.FullName | Where-Object { MorpheusIsReparse $_ })) {
            if ($x -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($x.FullName, $false) } else { [IO.File]::Delete($x.FullName) }
        }
        [IO.Directory]::Delete($Eintrag.FullName, $true)
    }
    else { [IO.File]::Delete($Eintrag.FullName) }
}

function MorpheusLeereTemp {
    # temp\<Prozess-ID> laufender Prozesse bleibt (ein Scan oder winget kann gerade darin arbeiten), alles andere wird entfernt
    param([string]$Pfad)
    $ti = Get-Item -LiteralPath $Pfad -Force
    if ((MorpheusIsReparse $ti) -or ($ti -isnot [IO.DirectoryInfo])) {
        try { MorpheusEntferneEintrag $ti } catch { Write-Warning "$Pfad ließ sich nicht entfernen: $($_.Exception.Message)" }
        return
    }
    $laufend = @{}
    foreach ($p in [Diagnostics.Process]::GetProcesses()) { $laufend[[string]$p.Id] = $true; $p.Dispose() }
    foreach ($e in @($ti.GetFileSystemInfos())) {
        if (($e -is [IO.DirectoryInfo]) -and (-not (MorpheusIsReparse $e)) -and $laufend.ContainsKey($e.Name)) { continue }
        try { MorpheusEntferneEintrag $e }
        catch { Write-Warning "Im Temp-Ordner ließ sich $($e.FullName) nicht entfernen: $($_.Exception.Message)" }
    }
}

function Initialize-MorpheusDataDir {
    # Richtet C:\ProgramData\Morpheus ein. ProgramData erlaubt normalen Benutzern das Anlegen von Ordnern; ein vorab
    # angelegter (fremder) Ordner wird deshalb NIE repariert (rekursives icacls könnte dabei Verknüpfungen folgen, die der
    # Besitzer jederzeit neu anlegen kann), sondern unangetastet beiseitegelegt und durch einen neuen ersetzt.
    [CmdletBinding()]
    param([string]$Path, [switch]$Beiseite)
    if (-not $Path) { $Path = MorpheusDefaultDataDir }
    $Path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (& $script:MorpheusInstallImpl.IstAdmin)) { throw 'Der Datenordner lässt sich nur mit Administratorrechten einrichten.' }

    if (Test-Path -LiteralPath $Path) {
        $it = Get-Item -LiteralPath $Path -Force
        # temp\ (2.3.3) enthält nur Zwischendateien (Add-Type, secedit, winget), denen Morpheus über einen Lauf hinaus nie
        # vertraut. Sein INHALT zählt deshalb nicht zur Rechteprüfung: winget legt dort Ordner an, die es dem Benutzer
        # ausdrücklich freigibt, und hätte sonst den ganzen Datenordner unsicher gemacht. Der Ordner temp selbst muss gesichert
        # sein; sonst (oder als Verknüpfung) wird er entfernt und unten neu angelegt. Danach Reste beendeter Prozesse entfernen.
        $tmpDir = Join-Path $Path 'temp'
        if (($it -is [IO.DirectoryInfo]) -and (-not (MorpheusIsReparse $it)) -and (Test-Path -LiteralPath $tmpDir) -and (Test-MorpheusSecurePath -Path $Path).Sicher) {
            $ti = Get-Item -LiteralPath $tmpDir -Force
            if ((MorpheusIsReparse $ti) -or ($ti -isnot [IO.DirectoryInfo]) -or (-not (Test-MorpheusSecurePath -Path $tmpDir -NoParents).Sicher)) {
                try { MorpheusEntferneEintrag $ti } catch { Write-Warning "Der ungesicherte Temp-Ordner $tmpDir ließ sich nicht entfernen: $($_.Exception.Message)" }
            }
            else { MorpheusLeereTemp -Pfad $tmpDir }
        }
        $pruefung = $null
        if (($it -is [IO.DirectoryInfo]) -and (-not (MorpheusIsReparse $it))) { $pruefung = Test-MorpheusSecurePath -Path $Path -Recurse -Ausnahmen 'temp' }
        if ((-not $pruefung) -or (-not $pruefung.Sicher)) {
            # 2.4 (#63): Nur zusätzliche Rechte (z. B. nach „Fortsetzen“ im Explorer) sind reparierbar: nicht beiseitelegen,
            # sondern melden (Nur-Lesen-Modus mit Angebot zur Reparatur). -Beiseite erzwingt das Beiseitelegen trotzdem.
            if ((-not $Beiseite) -and ($it -is [IO.DirectoryInfo]) -and (-not (MorpheusIsReparse $it))) {
                $zst = Get-MorpheusDatenordnerZustand -Path $Path
                if ($zst.zustand -eq 'reparierbar') {
                    $kontenText = (@($zst.konten | ForEach-Object { '{0} ({1})' -f $_.name, $_.rechte }) -join ', ')
                    $ex = New-Object System.Exception ('Die Rechte des Datenordners {0} wurden geändert ({1}). Morpheus startet im Nur-Lesen-Modus und bietet die Reparatur an.' -f $Path, $kontenText)
                    $ex.Data['datenordner'] = 'reparierbar'
                    # Ganzes Zustandsobjekt (Konten, Objekte): die GUI zeigt es im Banner an (18.10)
                    $ex.Data['zustand'] = $zst
                    throw $ex
                }
            }
            # Nur den obersten Eintrag umbenennen; Inhalt und Verknüpfungen darin werden nicht angefasst
            $aside = '{0}.unsicher-{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
            $gruende = 'Verknüpfung oder kein Ordner'
            if ($pruefung) { $gruende = (@($pruefung.Gruende) | Select-Object -First 3) -join ' | ' }
            Write-Warning "Der vorhandene Ordner $Path ist nicht gesichert ($gruende). Er wird nach $aside verschoben (nicht verwendet)."
            try {
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
            catch {
                # Kein halber Zustand: Der Ordner bleibt mit seinem Inhalt, wo er ist (höchstens Besitzer und Löschrecht am
                # obersten Ordner gehen an Administratoren). Morpheus nutzt ihn nicht und startet im Nur-Lesen-Modus.
                throw ("Der Datenordner $Path ist nicht gesichert ($gruende) und ließ sich nicht beiseitelegen: " + $_.Exception.Message + ' Er bleibt unverändert an seinem Ort und wird nicht verwendet. Ist er im Explorer oder in einer Konsole geöffnet? Dann das Fenster schließen. Zusätzliche Rechte (z. B. nach „Fortsetzen“ im Explorer) entfernt man in einer Admin-PowerShell, siehe README.')
            }
            Write-Warning "Der Ordner wurde nach $aside verschoben."
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
    foreach ($sub in 'reports', 'changes', 'state', 'temp') {
        $d = Join-Path $Path $sub
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { [void][IO.Directory]::CreateDirectory($d) }
    }
    $final = Test-MorpheusSecurePath -Path $Path -Recurse -Ausnahmen 'temp'
    if (-not $final.Sicher) { throw ("Der Datenordner $Path ließ sich nicht sichern: " + ($final.Gruende -join ' | ')) }
    $Path
}

#region Datenordner-Rechte reparieren (2.4, #63, docs\gui-architektur.md Abschnitt 18.10)

# Vertrauenswürdige SIDs: Administratoren, SYSTEM, TrustedInstaller (+ nur für Tests ZusatzVertraut)
function MorpheusDatenordnerVertraut {
    @($script:MorpheusTrustedSids) + @($script:MorpheusInstallImpl.ZusatzVertraut | Where-Object { $_ })
}

<#
.SYNOPSIS
    Beurteilt die Rechte des Datenordners, rein lesend (ändert nichts, betritt keine Verknüpfungen).
.OUTPUTS
    @{ zustand = 'ok'|'reparierbar'|'beiseite'|'fehlt'; konten = @(@{ sid; name; rechte = 'lesen'|'schreiben' }); objekte = <Anzahl>; gruende = @(...) }
    beiseite:    der Ordner oder ein Objekt darin ist eine Verknüpfung bzw. kein Ordner, ein Besitzer ist nicht
                 Administratoren/SYSTEM/TrustedInstaller, oder ein Objekt ist nicht lesbar.
    reparierbar: sonst, wenn es Allow-Einträge für andere SIDs gibt (geerbt oder nicht, auch nur Lesen).
    temp wird nur als Ordner geprüft, sein Inhalt nicht. Nur-Vererbungs-Einträge (auch ERSTELLER-BESITZER) wirken nicht
    auf das Objekt selbst und zählen hier wie in MorpheusCheckAcl nicht.
#>
function Get-MorpheusDatenordnerZustand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $res = @{ zustand = 'fehlt'; konten = @(); objekte = 0; gruende = @() }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') }
    catch { $res.zustand = 'beiseite'; $res.gruende = @("Ungültiger Pfad: $Path"); return $res }
    $top = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if (-not $top) { return $res }

    $beiseite = New-Object System.Collections.Generic.List[string]
    $fremd = New-Object System.Collections.Generic.List[string]
    if ((MorpheusIsReparse $top) -or ($top -isnot [IO.DirectoryInfo])) {
        $beiseite.Add("$full ist eine Verknüpfung (Junction/Symlink) oder kein Ordner")
        $res.zustand = 'beiseite'
        $res.gruende = @($beiseite)
        return $res
    }

    $vertraut = @(MorpheusDatenordnerVertraut)
    # Elternordner wie in Test-MorpheusSecurePath (ParentMask): sonst ließe sich der Datenordner umbenennen oder ersetzen.
    # Das liegt außerhalb von Morpheus und ist nicht reparierbar -> beiseite.
    $elternGruende = New-Object System.Collections.Generic.List[string]
    $parent = Split-Path -Parent $full
    # Testhilfe ElternAb: nur Elternordner unterhalb dieses Pfads prüfen (der Temp-Pfad des Testlaufs hat fremde Konten)
    $ab = [string]$script:MorpheusInstallImpl.ElternAb
    while ($parent) {
        if ($ab -and (-not $parent.StartsWith(($ab.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase))) { break }
        MorpheusCheckAcl -Path $parent -Mask $script:MorpheusParentMask -CheckOwner $false -Reasons $elternGruende -Context 'ändern, löschen oder ersetzen (damit auch den Ordner darunter)' -Vertraut $vertraut
        $parent = Split-Path -Parent $parent
    }
    foreach ($x in $elternGruende) { $beiseite.Add("Elternordner unsicher: $x") }
    $items = New-Object System.Collections.Generic.List[IO.FileSystemInfo]
    $items.Add($top)
    $errs = New-Object System.Collections.Generic.List[string]
    $nicht = @([IO.Path]::GetFullPath((Join-Path $full 'temp')).TrimEnd('\'))
    foreach ($e in (MorpheusTreeItems -Path $full -Errors $errs -NichtBetreten $nicht)) { $items.Add($e) }
    foreach ($x in $errs) { $beiseite.Add($x) }

    $konten = @{}      # sid -> 'lesen' | 'schreiben'
    $objekte = 0
    foreach ($it in $items) {
        $p = $it.FullName
        if (MorpheusIsReparse $it) { $beiseite.Add("$p ist eine Verknüpfung (Junction/Symlink)"); continue }
        try { $acl = Get-Acl -LiteralPath $p -ErrorAction Stop }
        catch { $beiseite.Add("Rechte von $p nicht lesbar: $($_.Exception.Message)"); continue }
        $owner = $null
        try { $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { }
        if ((-not $owner) -or ($vertraut -notcontains $owner)) {
            $beiseite.Add(("Besitzer von {0} ist {1} ({2}), nicht Administratoren, SYSTEM oder TrustedInstaller" -f $p, (MorpheusSidName $owner), $owner))
        }
        $hat = $false
        foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($r.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            if (([int]$r.PropagationFlags -band [int][Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
            $sid = $r.IdentityReference.Value
            if ($vertraut -contains $sid) { continue }
            $hat = $true
            $stufe = 'lesen'
            if (([int]$r.FileSystemRights -band $script:MorpheusWriteMask) -ne 0) { $stufe = 'schreiben' }
            if ((-not $konten.ContainsKey($sid)) -or ($stufe -eq 'schreiben')) { $konten[$sid] = $stufe }
            $fremd.Add(("{0} ({1}) hat Zugriff auf {2} ({3})" -f (MorpheusSidName $sid), $sid, $p, $stufe))
        }
        if ($hat) { $objekte++ }
    }

    $res.konten = @($konten.Keys | Sort-Object | ForEach-Object { @{ sid = $_; name = (MorpheusSidName $_); rechte = $konten[$_] } })
    $res.objekte = $objekte
    if ($beiseite.Count -gt 0) { $res.zustand = 'beiseite'; $liste = @($beiseite) + @($fremd) }
    elseif ($konten.Count -gt 0) { $res.zustand = 'reparierbar'; $liste = @($fremd) }
    else { $res.zustand = 'ok'; $liste = @() }
    if ($liste.Count -gt $script:MorpheusMaxReasons) {
        $rest = $liste.Count - $script:MorpheusMaxReasons
        $liste = @($liste | Select-Object -First $script:MorpheusMaxReasons) + @("... und $rest weitere Gründe")
    }
    $res.gruende = @($liste)
    $res
}

function MorpheusDateiNeuSchreiben {
    # Kopiert die Datei in eine neue Datei im selben Ordner und ersetzt die alte damit ([IO.File]::Replace): Ein Programm, das
    # die alte Datei noch zum Schreiben offen hält, schreibt danach ins Leere. Fehlende Dateien werden übersprungen.
    param([string]$Datei)
    if (-not [IO.File]::Exists($Datei)) { return $false }
    $item = Get-Item -LiteralPath $Datei -Force
    if (MorpheusIsReparse $item) { [IO.File]::Delete($Datei); return $false }
    $neu = '{0}.neu-{1}' -f $Datei, [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::Copy($Datei, $neu, $false)
        [IO.File]::Replace($neu, $Datei, [NullString]::Value)
    }
    finally { if ([IO.File]::Exists($neu)) { try { [IO.File]::Delete($neu) } catch { } } }
    $true
}

function MorpheusPruefeOberster {
    # Der oberste Ordner muss ein echter Ordner (keine Verknüpfung) mit unveränderter Erstellzeit sein; sonst wurde er
    # zwischenzeitlich ausgetauscht (der Benutzer hat darauf Löschrecht, solange die geschützte ACL noch nicht gesetzt ist).
    param([string]$Path, [long]$Erstellt, [string]$Phase)
    $it = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ((-not $it) -or ($it -isnot [IO.DirectoryInfo]) -or (MorpheusIsReparse $it)) {
        throw ("Reparatur abgebrochen ({0}): {1} ist kein normaler Ordner mehr (Verknüpfung oder ausgetauscht). Es wurde nichts gelöscht." -f $Phase, $Path)
    }
    if ($it.CreationTimeUtc.Ticks -ne $Erstellt) {
        throw ("Reparatur abgebrochen ({0}): {1} wurde während der Reparatur ausgetauscht. Es wurde nichts gelöscht." -f $Phase, $Path)
    }
}

function MorpheusLiesJournalIds {
    # Ids ALLER Journal-Einträge zum Zeitpunkt der Reparatur. Fehlendes/leeres Journal: leere Liste; unlesbar: eintraege = $null
    param([string]$Path)
    $res = @{ eintraege = @(); unlesbar = $false }
    $jp = Join-Path $Path 'changes\journal.json'
    try {
        $ji = Get-Item -LiteralPath $jp -Force -ErrorAction SilentlyContinue
        if (-not $ji) { return $res }
        if ((MorpheusIsReparse $ji) -or ($ji -isnot [IO.FileInfo])) { throw 'Das Journal ist eine Verknüpfung oder keine Datei.' }
        # Mit FileShare ReadWrite/Delete öffnen: ein Programm, das das Journal noch zum Schreiben offen hält, darf das Lesen nicht verhindern
        $fs = New-Object IO.FileStream($jp, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try { $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $text = $sr.ReadToEnd() }
        finally { $fs.Dispose() }
        if ([string]::IsNullOrWhiteSpace($text)) { return $res }
        $obj = ConvertFrom-Json -InputObject $text
        $ids = New-Object System.Collections.Generic.List[string]
        foreach ($e in @($obj)) {
            if (($null -ne $e) -and ($null -ne $e.PSObject.Properties['id']) -and ($null -ne $e.id)) { $ids.Add([string]$e.id) }
        }
        $res.eintraege = @($ids)
    }
    catch { $res.eintraege = $null; $res.unlesbar = $true }
    $res
}

function MorpheusSchreibeSperrdatei {
    # state\datenordner-reparatur.json atomar schreiben (tmp, dann Replace bzw. Move). Format (Version 2):
    # { version = 2; zeit; konten = [{sid, name}]; eintraege = [Journal-Ids] | null; journalUnlesbar = bool }
    param([string]$Path, $Konten)
    $stateDir = Join-Path $Path 'state'
    $sd = Get-Item -LiteralPath $stateDir -Force -ErrorAction SilentlyContinue
    if ($sd -and ((MorpheusIsReparse $sd) -or ($sd -isnot [IO.DirectoryInfo]))) { MorpheusEntferneEintrag $sd; $sd = $null }   # Verknüpfung nur entfernen
    if (-not $sd) { [void][IO.Directory]::CreateDirectory($stateDir) }
    $jr = MorpheusLiesJournalIds -Path $Path
    $konten = @($Konten | ForEach-Object { @{ sid = $_.sid; name = $_.name } })
    $doc = [ordered]@{ version = 2; zeit = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); konten = $konten; eintraege = $jr.eintraege; journalUnlesbar = [bool]$jr.unlesbar }
    $json = ConvertTo-Json -InputObject $doc -Depth 4
    $ziel = Join-Path $stateDir 'datenordner-reparatur.json'
    $zi = Get-Item -LiteralPath $ziel -Force -ErrorAction SilentlyContinue
    if ($zi -and ((MorpheusIsReparse $zi) -or ($zi -isnot [IO.FileInfo]))) { MorpheusEntferneEintrag $zi }
    $tmp = '{0}.neu-{1}' -f $ziel, [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($ziel)) { [IO.File]::Replace($tmp, $ziel, [NullString]::Value) } else { [IO.File]::Move($tmp, $ziel) }
    }
    finally { if ([IO.File]::Exists($tmp)) { try { [IO.File]::Delete($tmp) } catch { } } }
}

<#
.SYNOPSIS
    Entfernt fremde Rechte aus dem Datenordner und stellt ihn wieder auf "nur Administratoren und SYSTEM" (18.10).
.DESCRIPTION
    Nur mit Adminrechten und nur im Zustand 'reparierbar' (oder 'ok', wenn state\datenordner-reparatur.json fehlt: dann wird
    die Sperrdatei nachgeholt, die Reparatur ist erneut aufrufbar). Reihenfolge:
      a) Zustand prüfen. b) Oberster Ordner: Reparse-/Erstellzeit-Prüfung, geschützte ACL (Vererbung aus, Administratoren und
      SYSTEM Vollzugriff, fremde Einträge weg), erneut prüfen, Besitzer Administratoren. c) SOFORT danach state sicherstellen und
      die Sperrdatei atomar schreiben (Konten + Ids aller Journal-Einträge). d) Erst dann: temp und tools löschen (temp neu),
      state außer checklist.json leeren, übrige Unterobjekte je einzeln (kein icacls /T, keine Verknüpfungen): nicht geerbte
      Allow-Einträge fremder SIDs entfernen, abgeschaltete Vererbung wieder einschalten; journal.json, accepted.psd1 und
      state\checklist.json neu schreiben. Zum Schluss muss der Zustand 'ok' sein.
    Fehler beim Löschen und beim Neuschreiben einzelner Dateien brechen nicht ab, sondern kommen als Warnungen zurück; Fehler bei
    den ACL-Schritten, beim Schreiben der Sperrdatei oder eine Abschlussprüfung ungleich 'ok' werfen.
    Testhilfe: $script:MorpheusInstallImpl.IstAdmin (Scriptblock) ersetzt die Adminprüfung, ZusatzVertraut (SIDs) nimmt
    zusätzliche SIDs wie den Testbenutzer als vertrauenswürdig auf (sie behalten Vollzugriff am obersten Ordner; ohne Adminrechte
    lässt sich der Besitzer nicht setzen, das wird dann nur mit ZusatzVertraut toleriert), VorAcl (Scriptblock) läuft direkt vor
    der Prüfung vor dem ersten SetAccessControl (simuliert einen Austausch des Ordners). Produktiv sind alle leer/Standard.
.OUTPUTS
    @{ zustand; entfernt = <Anzahl entfernter Einträge>; meldung; warnungen = [string[]] }
#>
function Repair-MorpheusDatenordner {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $Path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (& $script:MorpheusInstallImpl.IstAdmin)) { throw 'Die Reparatur des Datenordners braucht Administratorrechte.' }

    # a) Zustand prüfen. Erstellzeit vorher und nachher festhalten: sie muss bis zur ACL gleich bleiben.
    $top0 = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $erstellt = 0
    if ($top0) { $erstellt = $top0.CreationTimeUtc.Ticks }
    $vor = Get-MorpheusDatenordnerZustand -Path $Path
    $sperrdatei = Join-Path $Path 'state\datenordner-reparatur.json'
    $nurSperrdatei = $false
    if ($vor.zustand -eq 'ok') {
        # Halber Zustand eines früheren Laufs: Rechte schon sauber, aber die Undo-Sperre fehlt -> nachholen
        $sz = Get-Item -LiteralPath $sperrdatei -Force -ErrorAction SilentlyContinue
        if (-not $sz) { $nurSperrdatei = $true }
    }
    if (($vor.zustand -ne 'reparierbar') -and (-not $nurSperrdatei)) {
        throw ("Der Datenordner {0} hat den Zustand '{1}' und lässt sich nicht reparieren. {2}" -f $Path, $vor.zustand, (@($vor.gruende | Select-Object -First 3) -join ' | '))
    }
    $vertraut = @(MorpheusDatenordnerVertraut)
    $zusatz = @($script:MorpheusInstallImpl.ZusatzVertraut | Where-Object { $_ })
    $abschnittA = [Security.AccessControl.AccessControlSections]::Access
    $abschnittO = [Security.AccessControl.AccessControlSections]::Owner
    $sidT = [Security.Principal.SecurityIdentifier]
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $entfernt = 0
    $warn = New-Object System.Collections.Generic.List[string]

    # b) Oberster Ordner. Verbleibendes, sehr kleines Zeitfenster: zwischen der Prüfung direkt unten und dem ersten
    # SetAccessControl könnte der Benutzer (er hat auf diesen Ordner noch Löschrecht) ihn gegen eine Verknüpfung tauschen.
    # Danach hat er kein Recht mehr, ihn umzubenennen; die zweite Prüfung fängt einen Tausch im Fenster ab, bevor etwas
    # gelöscht oder an Unterobjekten geändert wird.
    if ($script:MorpheusInstallImpl.VorAcl) { & $script:MorpheusInstallImpl.VorAcl }
    MorpheusPruefeOberster -Path $Path -Erstellt $erstellt -Phase 'vor den Rechten'
    Write-Information 'Datenordner: entferne fremde Rechte am obersten Ordner'
    $sec = [IO.Directory]::GetAccessControl($Path, $abschnittA)
    foreach ($r in @($sec.GetAccessRules($true, $true, $sidT))) {
        if (($r.AccessControlType -eq $allow) -and ($vertraut -notcontains $r.IdentityReference.Value)) { $entfernt++ }
    }
    foreach ($r in @($sec.GetAccessRules($true, $false, $sidT))) {
        if (($r.AccessControlType -eq $allow) -and ($vertraut -notcontains $r.IdentityReference.Value)) { [void]$sec.RemoveAccessRuleSpecific($r) }
    }
    $sec.SetAccessRuleProtection($true, $false)
    $inh = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    foreach ($s in (@($script:MorpheusSidAdmins, $script:MorpheusSidSystem) + $zusatz)) {
        $sid = New-Object Security.Principal.SecurityIdentifier($s)
        $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, [Security.AccessControl.FileSystemRights]::FullControl, $inh, $none, $allow)))
    }
    [IO.Directory]::SetAccessControl($Path, $sec)
    MorpheusPruefeOberster -Path $Path -Erstellt $erstellt -Phase 'nach den Rechten'
    try {
        $os = [IO.Directory]::GetAccessControl($Path, $abschnittO)
        $os.SetOwner((New-Object Security.Principal.SecurityIdentifier($script:MorpheusSidAdmins)))
        [IO.Directory]::SetAccessControl($Path, $os)
    }
    catch { if ($zusatz.Count -eq 0) { throw ("Der Besitzer von {0} ließ sich nicht auf Administratoren setzen: {1}" -f $Path, $_.Exception.Message) } }

    # c) SOFORT die Undo-Sperre schreiben, bevor irgendetwas gelöscht wird: scheitert ein späterer Schritt, bleibt sie bestehen
    Write-Information 'Datenordner: schreibe die Sperrdatei'
    MorpheusSchreibeSperrdatei -Path $Path -Konten $vor.konten

    # d) Übrige Schritte; Fehler beim Löschen und Neuschreiben werden gesammelt
    # temp und tools zuerst leeren (Verknüpfungen werden nur entfernt, nie betreten): Offene Frage (nicht geklärt), ob die
    # automatische Weitergabe der Vererbung von NTFS beim Setzen der ACL am obersten Ordner Junctions im Inhalt von temp
    # folgt. Der Inhalt von temp stammt zum Teil vom Benutzer (winget); er wird deshalb vor allen anderen Unterobjekten entfernt.
    Write-Information 'Datenordner: lösche temp und tools, lege temp neu an'
    foreach ($n in 'temp', 'tools') {
        $ti = Get-Item -LiteralPath (Join-Path $Path $n) -Force -ErrorAction SilentlyContinue
        if ($ti) {
            try { MorpheusEntferneEintrag $ti }   # prüft selbst auf Reparse Points: Verknüpfungen werden nur selbst entfernt
            catch { $warn.Add(("{0} ließ sich nicht (vollständig) löschen: {1}" -f $n, $_.Exception.Message)) }
        }
    }
    try { [void][IO.Directory]::CreateDirectory((Join-Path $Path 'temp')) }
    catch { $warn.Add("temp ließ sich nicht anlegen: $($_.Exception.Message)") }

    Write-Information 'Datenordner: räume state auf'
    $stateDir = Join-Path $Path 'state'
    $sd = Get-Item -LiteralPath $stateDir -Force -ErrorAction SilentlyContinue
    if ($sd -and ($sd -is [IO.DirectoryInfo]) -and (-not (MorpheusIsReparse $sd))) {
        foreach ($e in @($sd.GetFileSystemInfos())) {
            if ($e.Name -ieq 'checklist.json') { continue }
            if ($e.Name -ieq 'datenordner-reparatur.json') { continue }   # die Sperrdatei bleibt
            try { MorpheusEntferneEintrag $e }
            catch { $warn.Add(("state\{0} ließ sich nicht löschen: {1}" -f $e.Name, $_.Exception.Message)) }
        }
    }

    Write-Information 'Datenordner: entferne fremde Rechte an den Unterobjekten'
    # temp und tools bleiben ungeöffnet (Inhalt nicht prüfen); existieren sie noch, wird ihre eigene ACL trotzdem bereinigt
    $nicht = @('temp', 'tools' | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $Path $_)).TrimEnd('\') })
    $errs = New-Object System.Collections.Generic.List[string]
    foreach ($e in (MorpheusTreeItems -Path $Path -Errors $errs -NichtBetreten $nicht)) {
        if (MorpheusIsReparse $e) { throw "Reparatur abgebrochen: $($e.FullName) ist eine Verknüpfung (Junction/Symlink)." }
        $istDir = $e -is [IO.DirectoryInfo]
        if ($istDir) { $s2 = [IO.Directory]::GetAccessControl($e.FullName, $abschnittA) } else { $s2 = [IO.File]::GetAccessControl($e.FullName, $abschnittA) }
        $n = 0
        foreach ($r in @($s2.GetAccessRules($true, $false, $sidT))) {
            if (($r.AccessControlType -eq $allow) -and ($vertraut -notcontains $r.IdentityReference.Value)) { [void]$s2.RemoveAccessRuleSpecific($r); $n++ }
        }
        # Abgeschaltete Vererbung wieder einschalten, damit Administratoren und SYSTEM den Zugriff geerbt bekommen
        $warGeschuetzt = $s2.AreAccessRulesProtected
        if ($warGeschuetzt) { $s2.SetAccessRuleProtection($false, $false) }
        if (($n -gt 0) -or $warGeschuetzt) {
            if ($istDir) { [IO.Directory]::SetAccessControl($e.FullName, $s2) } else { [IO.File]::SetAccessControl($e.FullName, $s2) }
            $entfernt += $n
        }
    }
    if ($errs.Count -gt 0) { throw ('Reparatur abgebrochen: ' + (@($errs) -join ' | ')) }

    Write-Information 'Datenordner: schreibe Journal, Akzeptanzliste und Checkliste neu'
    foreach ($rel in 'changes\journal.json', 'accepted.psd1', 'state\checklist.json') {
        try { [void](MorpheusDateiNeuSchreiben -Datei (Join-Path $Path $rel)) }
        catch { $warn.Add(("{0} ließ sich nicht neu schreiben: {1}" -f $rel, $_.Exception.Message)) }
    }

    $nach = Get-MorpheusDatenordnerZustand -Path $Path
    if ($nach.zustand -ne 'ok') {
        throw ("Der Datenordner {0} ist nach der Reparatur nicht in Ordnung (Zustand '{1}'): {2}" -f $Path, $nach.zustand, (@($nach.gruende) -join ' | '))
    }
    $meldung = "Die Rechte des Datenordners wurden repariert ($entfernt Einträge entfernt)."
    if ($warn.Count -gt 0) { $meldung += ' Hinweise: ' + (@($warn) -join ' | ') }
    @{ zustand = 'ok'; entfernt = $entfernt; meldung = $meldung; warnungen = [string[]]@($warn) }
}

#endregion

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
    # 2.4 (#63): Ist der Datenordner nur 'reparierbar' (zusätzliche Rechte), wirft Initialize-MorpheusDataDir mit
    # Data['datenordner'] = 'reparierbar'. Das darf die Installation nicht abbrechen: Datenübernahme überspringen, die
    # Verknüpfung trotzdem anlegen; die installierte GUI bietet die Reparatur an. Andere Fehler wie bisher.
    $dataRoot = $null
    try { $dataRoot = Initialize-MorpheusDataDir -Path $DataDir }
    catch {
        if ($_.Exception.Data['datenordner'] -ceq 'reparierbar') {
            Write-Warning "Der Datenordner $DataDir hat zusätzliche Rechte. Die Datenübernahme wird übersprungen; Morpheus bietet nach dem Start die Reparatur an."
        }
        else { throw }
    }
    if ($dataRoot) {
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
        $fin = Test-MorpheusSecurePath -Path $dataRoot -Recurse -Ausnahmen 'temp'
        if (-not $fin.Sicher) { throw ("Der Datenordner $dataRoot ist nach der Übernahme nicht sicher: " + ($fin.Gruende -join ' | ')) }
    }

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
