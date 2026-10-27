#Requires -Version 5.1
<#
.SYNOPSIS
    Morpheus – PC Check-up: Programme, Module und Temp-Ordner nur aus gesicherten Pfaden (Hotfix 2.3.3, Karte #60).

.DESCRIPTION
    Scan, GUI-Server und Jobs laufen mit Adminrechten. Was sie über Suchpfade auflösen, darf nicht aus einem Ordner kommen,
    den ein Programm mit normalen Benutzerrechten beschreiben kann (Sicherheitsprinzip 4):
    - Module: $env:PSModulePath beginnt sonst mit Dokumente\WindowsPowerShell\Modules (Benutzer). Die Begrenzung steht
      als ERSTE Anweisung in jedem Einstiegspunkt und in jedem Job-Scriptblock (inline, ohne diese Datei, damit vorher
      nichts automatisch geladen wird). Get-MorpheusModulPfad liefert denselben Wert für Tests und Kontrollen.
    - Programme: nur mit vollem Pfad aus System32 (Get-MorpheusSystemProgramm), nie über PATH. winget nur aus dem
      signierten Paket Microsoft.DesktopAppInstaller unter Program Files\WindowsApps (Get-MorpheusWinget), sonst SKIP.
    - Temp: %TEMP% des Admin-Prozesses ist sonst der Temp-Ordner des Benutzers. Add-Type kompiliert dort C#-Code und lädt
      die DLL danach; winget legt dort Installer ab. Set-MorpheusTempPfad verlegt TEMP/TMP nach <Datenordner>\temp.
    Systemordner kommen aus Windows-APIs ([Environment]::SystemDirectory, GetFolderPath), nicht aus Umgebungsvariablen:
    Die erhöhte Sitzung erbt Benutzervariablen aus HKCU\Environment, und dort könnte ein Benutzerprogramm z. B.
    windir, ProgramFiles oder PSModulePath umbiegen.
    Beim Dot-Sourcen wird nichts ausgeführt.
#>

# Fingerabdrücke der Microsoft-Wurzeln (Root CA 2010 und 2011), wie in Sysinternals.ps1
$script:MorpheusPfadWurzeln = @('3B1EFD3A66EA28B16697394703A72CA340A05BD5', '8F43288AD272F3103B6FB1428485EA3014C0BCFE')

# Standard-Implementierungen (Tests ersetzen die Einträge)
if (-not $script:MorpheusPfadImpl) {
    $script:MorpheusPfadImpl = @{
        # Pakete Microsoft.DesktopAppInstaller des angemeldeten Benutzers (Name, Version, InstallLocation, PublisherId)
        # Mit Adminrechten alle Benutzer: Erhöht ein Standardkonto über ein anderes Admin-Konto, fehlt dem sonst das Paket
        Pakete   = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if ($admin) { @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -AllUsers -ErrorAction Stop) }
            else { @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop) }
        }
        Signatur = { param($Pfad) Get-AuthenticodeSignature -LiteralPath $Pfad -ErrorAction Stop }
        # Fingerabdruck des obersten Kettenglieds oder $null (ohne Sperrlisten-Abruf)
        Wurzel   = {
            param($Zertifikat)
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            try {
                $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
                [void]$chain.Build($Zertifikat)
                if ($chain.ChainElements.Count -lt 1) { return $null }
                $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.Thumbprint
            } finally { $chain.Reset() }
        }
        Datei    = { param($Pfad) Get-Item -LiteralPath $Pfad -Force -ErrorAction Stop }
        ProgrammeOrdner = { [Environment]::GetFolderPath('ProgramFiles') }
    }
}

<#
.SYNOPSIS
    Der gesicherte Modulpfad: System32\WindowsPowerShell\v1.0\Modules, danach Program Files\WindowsPowerShell\Modules.
    Beide Ordner dürfen nur Administratoren, SYSTEM und TrustedInstaller ändern. System32 steht vorn, damit die
    Windows-Module immer vor gleichnamigen Modulen aus Program Files gefunden werden.
#>
function Get-MorpheusModulPfad {
    [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
}

<#
.SYNOPSIS
    Voller Pfad eines Windows-Programms in System32, z. B. Get-MorpheusSystemProgramm 'powercfg.exe'.
    Nur einfache Dateinamen (optional mit Unterordner wie 'WindowsPowerShell\v1.0\powershell.exe'), nie '..'.
    Fehlt das Programm, gibt es eine Ausnahme statt eines Rückgriffs auf PATH.
#>
function Get-MorpheusSystemProgramm {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    if (($Name -notmatch '^[A-Za-z0-9_.\-]+(\\[A-Za-z0-9_.\-]+)*\.(exe|com)\z') -or ($Name -match '(^|\\)\.\.?(\\|\z)')) {
        throw "Ungültiger Programmname: $Name"
    }
    $p = Join-Path ([Environment]::SystemDirectory) $Name
    if (-not [IO.File]::Exists($p)) { throw "Das Windows-Programm $p wurde nicht gefunden." }
    $p
}

<#
.SYNOPSIS
    Prüft, ob eine Datei gültig von Microsoft signiert ist und die Kette an einer fest eingetragenen Microsoft-Wurzel
    endet. Get-AuthenticodeSignature allein vertraut auch Stammzertifikaten aus HKCU (vom Benutzer änderbar, vgl. T1).
    Gibt $null (in Ordnung) oder den Grund zurück.
#>
function Test-MorpheusMicrosoftSignatur {
    param([Parameter(Mandatory)][string]$Pfad)
    try { $sig = & $script:MorpheusPfadImpl.Signatur $Pfad }
    catch { return 'Die Signatur ließ sich nicht prüfen: ' + $_.Exception.Message }
    if ((-not $sig) -or ([string]$sig.Status -ne 'Valid')) { return ('Die Signatur ist nicht gültig ({0}).' -f [string]$sig.Status) }
    $subj = [string]$sig.SignerCertificate.Subject
    if ($subj -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') { return "Nicht von Microsoft signiert ($subj)." }
    $wurzel = $null
    try { $wurzel = [string](& $script:MorpheusPfadImpl.Wurzel $sig.SignerCertificate) } catch { $wurzel = $null }
    if ($script:MorpheusPfadWurzeln -notcontains $wurzel) { return 'Die Zertifikatskette endet nicht an einer Microsoft-Wurzel.' }
    $null
}

<#
.SYNOPSIS
    Findet winget.exe im signierten Paket Microsoft.DesktopAppInstaller unter Program Files\WindowsApps.
.DESCRIPTION
    Nie über PATH: Dort steht %LOCALAPPDATA%\Microsoft\WindowsApps, den jedes Benutzerprogramm beschreiben kann.
    Bedingungen: Paket von Microsoft (PublisherId 8wekyb3d8bbwe), Installationsordner direkt unter
    <Program Files>\WindowsApps\Microsoft.DesktopAppInstaller_*, winget.exe ohne Verknüpfung (Reparse Point) und
    gültig von Microsoft signiert (Test-MorpheusMicrosoftSignatur). Bei mehreren Paketen gewinnt die höchste Version.
    Rückgabe: [pscustomobject]@{ Pfad = <voller Pfad oder $null>; Version; Grund = <Hinweis, wenn nicht gefunden> }.
#>
function Get-MorpheusWinget {
    $basis = Join-Path (& $script:MorpheusPfadImpl.ProgrammeOrdner) 'WindowsApps'
    $praefix = $basis.TrimEnd('\') + '\Microsoft.DesktopAppInstaller_'
    $pakete = @()
    try { $pakete = @(& $script:MorpheusPfadImpl.Pakete) }
    catch { return [pscustomobject]@{ Pfad = $null; Version = $null; Grund = 'Das App-Installationsprogramm (winget) ließ sich nicht abfragen: ' + $_.Exception.Message } }
    $gruende = New-Object System.Collections.Generic.List[string]
    $kandidaten = @($pakete | Where-Object { $_ -and $_.InstallLocation } | Sort-Object -Property @{ Expression = { try { [version][string]$_.Version } catch { [version]'0.0' } } } -Descending)
    foreach ($p in $kandidaten) {
        $ort = [string]$p.InstallLocation
        if ([string]$p.PublisherId -cne '8wekyb3d8bbwe') { $gruende.Add("Paket $($p.PackageFullName) stammt nicht von Microsoft."); continue }
        $voll = $null
        try { $voll = [IO.Path]::GetFullPath($ort).TrimEnd('\') } catch { $gruende.Add("Ungültiger Ort: $ort"); continue }
        $rest = ''
        if ($voll.Length -gt $praefix.Length) { $rest = $voll.Substring($praefix.Length) }
        if ((-not $voll.StartsWith($praefix, [StringComparison]::OrdinalIgnoreCase)) -or ($rest -eq '') -or ($rest.Contains('\'))) {
            $gruende.Add("winget liegt nicht im geschützten Ordner $basis ($voll)."); continue
        }
        $exe = Join-Path $voll 'winget.exe'
        $it = $null
        try { $it = & $script:MorpheusPfadImpl.Datei $exe } catch { $gruende.Add("winget.exe fehlt in $voll."); continue }
        if (($it.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($it.Attributes -band [IO.FileAttributes]::Directory)) { $gruende.Add("$exe ist eine Verknüpfung."); continue }
        $sig = Test-MorpheusMicrosoftSignatur -Pfad $exe
        if ($sig) { $gruende.Add("$exe – $sig"); continue }
        return [pscustomobject]@{ Pfad = $exe; Version = [string]$p.Version; Grund = $null }
    }
    $grund = 'winget ist nicht als signiertes App-Installationsprogramm unter Program Files\WindowsApps installiert.'
    if ($gruende.Count) { $grund += ' ' + ($gruende -join ' ') }
    [pscustomobject]@{ Pfad = $null; Version = $null; Grund = $grund }
}

<#
.SYNOPSIS
    Verlegt TEMP und TMP dieses Prozesses (und damit seiner Jobs) nach <DataRoot>\temp\<Prozess-ID>.
.DESCRIPTION
    Nur wenn DataRoot gesichert ist (Test-MorpheusSecurePath aus Install.ps1). Die Unterordner erben dann die Rechte
    (nur Administratoren und SYSTEM) und werden danach selbst geprüft. Je Prozess ein eigener Ordner, damit das Aufräumen
    beim GUI-Start (Initialize-MorpheusDataDir) nur Ordner beendeter Prozesse entfernt. Gibt den neuen Pfad zurück,
    sonst $null; dann bleibt TEMP unverändert (Entwicklungsordner, Nur-Lesen-Modus).
#>
function Set-MorpheusTempPfad {
    param([Parameter(Mandatory)][string]$DataRoot)
    if (-not (Get-Command -Name Test-MorpheusSecurePath -CommandType Function -ErrorAction SilentlyContinue)) { return $null }
    try {
        $root = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
        if (-not (Test-MorpheusSecurePath -Path $root).Sicher) { return $null }
        $t = Join-Path $root 'temp'
        if (-not [IO.Directory]::Exists($t)) { [void][IO.Directory]::CreateDirectory($t) }
        if (-not (Test-MorpheusSecurePath -Path $t).Sicher) { return $null }
        $eigen = Join-Path $t ([string]$PID)
        # Ein Ordner mit derselben Prozess-ID stammt von einem beendeten Prozess (Inhalt wird nicht geprüft): neu anlegen
        if ((Test-Path -LiteralPath $eigen) -and (Get-Command -Name MorpheusEntferneEintrag -CommandType Function -ErrorAction SilentlyContinue)) {
            MorpheusEntferneEintrag (Get-Item -LiteralPath $eigen -Force)
        }
        if (-not [IO.Directory]::Exists($eigen)) { [void][IO.Directory]::CreateDirectory($eigen) }
        if (-not (Test-MorpheusSecurePath -Path $eigen).Sicher) { return $null }
        $env:TEMP = $eigen
        $env:TMP = $eigen
        $eigen
    }
    catch { $null }
}

<#
.SYNOPSIS
    Der echte Temp-Ordner des angemeldeten Benutzers, unabhängig von $env:TEMP (2.3.3, Nutzertest).
.DESCRIPTION
    $env:TEMP zeigt nach Set-MorpheusTempPfad auf Morpheus' Ordner, und Scan-Jobs der GUI erben das schon beim Start.
    Gelesen wird deshalb HKCU\Environment\TEMP ohne Expansion. %USERPROFILE% wird mit dem Profilpfad ersetzt, der Rest
    expandiert. Rückfall: <LocalAppData>\Temp. Nur zum Messen und Auflösen von Pfaden; dort wird nie etwas ausgeführt.
#>
function Get-MorpheusBenutzerTemp {
    if ($script:MorpheusBenutzerTempCache) { return $script:MorpheusBenutzerTempCache }
    $roh = $null
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
        if ($k) { try { $roh = [string]$k.GetValue('TEMP', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $k.Close() } }
    }
    catch { $roh = $null }
    $p = $null
    if ($roh -and ($roh -notmatch '%(TEMP|TMP)%')) {
        $x = $roh -ireplace '%USERPROFILE%', ([Environment]::GetFolderPath('UserProfile')).Replace('$', '$$')
        $x = [Environment]::ExpandEnvironmentVariables($x)
        if (($x -match '^[A-Za-z]:\\') -and ($x -notmatch '%')) { $p = $x }
    }
    if (-not $p) { $p = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp' }
    $script:MorpheusBenutzerTempCache = $p.TrimEnd('\')
    $script:MorpheusBenutzerTempCache
}

<#
.SYNOPSIS
    Der PATH, den Programme des Benutzers sehen (System + Benutzer aus der Registry), unabhängig vom begrenzten $env:PATH.
    Nur zum Nachsehen, ob Dateien dort liegen; es wird nichts daraus gestartet.
#>
function Get-MorpheusBenutzerPath {
    $teile = New-Object System.Collections.Generic.List[string]
    $quellen = @(
        @([Microsoft.Win32.Registry]::LocalMachine, 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'),
        @([Microsoft.Win32.Registry]::CurrentUser, 'Environment'))
    foreach ($q in $quellen) {
        try {
            $k = $q[0].OpenSubKey($q[1])
            if (-not $k) { continue }
            try { $roh = [string]$k.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $k.Close() }
            foreach ($e in @($roh -split ';')) {
                $e = $e.Trim()
                if ((-not $e) -or ($e -match '%(PATH|TEMP|TMP)%')) { continue }
                $teile.Add([Environment]::ExpandEnvironmentVariables($e))
            }
        }
        catch { }
    }
    $teile -join ';'
}

<#
.SYNOPSIS
    Wie [Environment]::ExpandEnvironmentVariables, aber %TEMP% und %TMP% werden mit dem echten Temp-Ordner des Benutzers
    aufgelöst (Get-MorpheusBenutzerTemp), nicht mit Morpheus' eigenem. Für Befehlszeilen von Aufgaben, Autostarts,
    Diensten und Defender-Ausnahmen, die der Scan bewertet.
#>
function Expand-MorpheusUmgebung {
    param([AllowNull()][string]$Text)
    if (-not $Text) { return $Text }
    $t = $Text
    if ($t -match '%(TEMP|TMP)%') { $t = $t -ireplace '%(TEMP|TMP)%', (Get-MorpheusBenutzerTemp).Replace('$', '$$') }
    [Environment]::ExpandEnvironmentVariables($t)
}
