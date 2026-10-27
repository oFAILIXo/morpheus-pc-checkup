#Requires -Version 5.1
<#
.SYNOPSIS
    Sysinternals-Werkzeuge für Morpheus (v2.3, #41): Bezug, Lizenz-Zustimmung, Vertrauensprüfung, gesicherter Start.

.DESCRIPTION
    Wird per Dot-Source geladen (pc-check.ps1, pc-check-gui.ps1, Job `sysinternals`). Definiert die Funktionen aus
    docs/gui-architektur.md, Abschnitt 15.3. Regeln:
    - Kein VirusTotal: die festen Aufträge verwenden nie -v, -vt, -vr oder -vs.
    - Bezug nur von https://download.sysinternals.com/files/ (feste Konstanten, keine Weiterleitungen).
    - Vor jedem Start: Datei mit FileShare.Read öffnen, Hash aus diesem Handle, Vergleich mit werkzeuge.json,
      Signatur (Microsoft Corporation) und Wurzel prüfen, Prozess starten, Handle erst nach Prozessende schließen
      (Schutz vor Austausch zwischen Prüfung und Start).
    - Alle Netz-, Signatur-, Rechte- und Admin-Zugriffe laufen über $script:MorpheusSysImpl (Tests ersetzen die Einträge).
    - Fortschritt nur über Write-Information, einzige Pipeline-Ausgabe ist das Ergebnis.
    - Kein Add-Type mit C#-Code.
    Festlegungen: Get-MorpheusSysEula liefert bei Dateien über 64 KB die ersten 64 KB plus Hinweiszeile
    (gekürzt statt $null). Invoke-MorpheusSysWerkzeug: ok = kein Zeitlimit und (Exitcode 0 oder Ausgabe vorhanden).
    Aufträge: autostarts = -a * -c -s * (alle Benutzerprofile, kein -h); system32/treiber = -c -u -e -r <Ordner>
    (-r: keine Online-Sperrlistenprüfung, nichts geht ins Netz). Wurzelprüfung mit ExtraStore aus der eingebetteten
    Signatur (Kette auch offline vollständig). Herkunftsprüfung: Firma oder Produkt der Versionsinfo muss
    "Sysinternals" enthalten (ein anderes, von Microsoft signiertes Programm darf nicht unter dem Werkzeugnamen laufen).
    ZIP-Einträge: Name ohne Groß-/Kleinschreibung gleich, ohne Pfadanteil, genau ein Treffer; entpackt wird unter dem
    festen Zielnamen. Entfernen löscht zuerst die EXEs und bricht ab, wenn eine in Benutzung ist.
#>

# Abhängigkeiten aus dem gleichen Ordner laden, falls ihre Funktionen fehlen
if (-not (Get-Command -Name Test-MorpheusSecurePath -ErrorAction SilentlyContinue)) {
    $__sysInstall = Join-Path $PSScriptRoot 'Install.ps1'
    if (Test-Path -LiteralPath $__sysInstall -PathType Leaf) { . $__sysInstall }
}
if (-not (Get-Command -Name ConvertFrom-MorpheusSysAusgabe -ErrorAction SilentlyContinue)) {
    $__sysAusw = Join-Path $PSScriptRoot 'SysinternalsAuswertung.ps1'
    if (Test-Path -LiteralPath $__sysAusw -PathType Leaf) { . $__sysAusw }
}

$script:MorpheusSysWerkzeuge = [ordered]@{
    autorunsc = @{ Zip = 'Autoruns.zip'; Url = 'https://download.sysinternals.com/files/Autoruns.zip'; Exe = 'autorunsc64.exe'; Titel = 'Autoruns' }
    sigcheck  = @{ Zip = 'Sigcheck.zip'; Url = 'https://download.sysinternals.com/files/Sigcheck.zip'; Exe = 'sigcheck64.exe'; Titel = 'Sigcheck' }
}
# Microsoft Root Certificate Authority 2010 und 2011
$script:MorpheusSysWurzeln = @('3B1EFD3A66EA28B16697394703A72CA340A05BD5', '8F43288AD272F3103B6FB1428485EA3014C0BCFE')
$script:MorpheusSysLizenzUrl = 'https://learn.microsoft.com/sysinternals/license-terms'
$script:MorpheusSysUrlPraefix = 'https://download.sysinternals.com/files/'
$script:MorpheusSysZipMaxBytes = 20MB
$script:MorpheusSysExeMaxBytes = 30MB
$script:MorpheusSysEulaMaxBytes = 64KB

# Standard-Implementierungen (Tests ersetzen die Einträge)
if (-not $script:MorpheusSysImpl) {
    $script:MorpheusSysImpl = @{
        Download   = {
            param($Url, $Ziel, $MaxBytes)
            if (-not ([string]$Url).StartsWith('https://download.sysinternals.com/files/', [StringComparison]::Ordinal)) {
                throw "Der Download von '$Url' ist nicht erlaubt; erlaubt ist nur https://download.sysinternals.com/files/."
            }
            try { [Net.ServicePointManager]::SecurityProtocol = ([Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12) } catch { }
            $req = [Net.HttpWebRequest]::Create([string]$Url)
            $req.AllowAutoRedirect = $false
            $req.Timeout = 120000
            $req.ReadWriteTimeout = 120000
            $req.UserAgent = 'Morpheus-PC-Check-up'
            $resp = $null
            try {
                try { $resp = $req.GetResponse() }
                catch [Net.WebException] { throw ('Der Download ist fehlgeschlagen: ' + $_.Exception.Message) }
                if ([int]$resp.StatusCode -ne 200) { throw ('Der Server antwortete mit Status {0} statt 200 (Weiterleitungen sind nicht erlaubt).' -f [int]$resp.StatusCode) }
                if (($resp.ContentLength -ge 0) -and ($resp.ContentLength -gt $MaxBytes)) { throw ('Die Datei ist mit {0} Bytes größer als erlaubt ({1}).' -f $resp.ContentLength, $MaxBytes) }
                $in = $resp.GetResponseStream()
                $out = New-Object IO.FileStream($Ziel, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $buf = New-Object byte[] 81920
                    [long]$sum = 0
                    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                        $sum += $n
                        if ($sum -gt $MaxBytes) { throw "Der Download überschreitet die erlaubte Größe von $MaxBytes Bytes und wurde abgebrochen." }
                        $out.Write($buf, 0, $n)
                    }
                } finally { $out.Dispose(); $in.Dispose() }
            } finally { if ($resp) { $resp.Close() } }
        }
        Signatur   = { param($Pfad) Get-AuthenticodeSignature -LiteralPath $Pfad -ErrorAction Stop }
        # Fingerabdruck des obersten Kettenglieds oder $null
        Wurzel     = {
            param($Zertifikat, $Pfad)
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            try {
                if ($Pfad) {
                    $extra = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
                    try { $extra.Import($Pfad) } catch { }
                    if ($extra.Count -gt 0) { $chain.ChainPolicy.ExtraStore.AddRange($extra) }
                }
                $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
                [void]$chain.Build($Zertifikat)
                if ($chain.ChainElements.Count -lt 1) { return $null }
                $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.Thumbprint
            } finally { $chain.Reset() }
        }
        # Versionsinfo der Datei (von der Signatur abgedeckt)
        Herkunft   = { param($Pfad) [Diagnostics.FileVersionInfo]::GetVersionInfo($Pfad) }
        SicherPfad = { param($Pfad) Test-MorpheusSecurePath -Path $Pfad }
        Admin      = { MorpheusIsAdmin }
    }
}

#region Hilfsfunktionen (privat)

function MorpheusSysLog {
    param([string]$Text)
    Write-Information -MessageData ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text) -InformationAction Continue
}

function MorpheusSysToolsDir { param([string]$DataRoot) Join-Path $DataRoot 'tools' }
function MorpheusSysZustimmungPfad { param([string]$DataRoot) Join-Path (Join-Path $DataRoot 'state') 'sysinternals.json' }

function MorpheusSysSchreibeText {
    # UTF-8 ohne BOM, atomar (.tmp + Replace/Move)
    param([string]$Pfad, [string]$Text)
    $tmp = $Pfad + '.tmp'
    try {
        [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Pfad -PathType Leaf) { [IO.File]::Replace($tmp, $Pfad, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $Pfad) }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function MorpheusSysIstVerknuepfung {
    param([string]$Pfad)
    $it = Get-Item -LiteralPath $Pfad -Force -ErrorAction SilentlyContinue
    if ($null -eq $it) { return $false }
    [bool](MorpheusIsReparse $it)
}

# Argumente eines Auftrags: @{ Name = 'autorunsc'|'sigcheck'; Argumente = string[] }. Unbekannter Auftrag: throw.
function MorpheusSysArgumente {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Auftrag)
    # Windows-Ordner über die Windows-API, nicht aus %SystemRoot% (vom Benutzer über HKCU\Environment beeinflussbar, 2.3.3)
    $sys = [Environment]::GetFolderPath('Windows')
    if (-not $sys) { $sys = 'C:\Windows' }
    if ($Auftrag -ceq 'autostarts') {
        return [ordered]@{ Name = 'autorunsc'; Argumente = [string[]]@('-accepteula', '-nobanner', '-a', '*', '-c', '-s', '*') }
    }
    if ($Auftrag -ceq 'system32') {
        return [ordered]@{ Name = 'sigcheck'; Argumente = [string[]]@('-accepteula', '-nobanner', '-c', '-u', '-e', '-r', (Join-Path $sys 'System32')) }
    }
    if ($Auftrag -ceq 'treiber') {
        return [ordered]@{ Name = 'sigcheck'; Argumente = [string[]]@('-accepteula', '-nobanner', '-c', '-u', '-e', '-r', (Join-Path (Join-Path $sys 'System32') 'drivers')) }
    }
    throw "Unbekannter Sysinternals-Auftrag '$Auftrag'. Erlaubt sind 'autostarts', 'system32' und 'treiber'."
}

# Argumentliste -> Befehlszeile (Windows-Regeln für CommandLineToArgvW)
function MorpheusSysArgString {
    param([string[]]$Argumente)
    $teile = foreach ($a in @($Argumente)) {
        if ($a.Length -eq 0) { '""'; continue }
        if ($a -notmatch '[\s"]') { $a; continue }
        $s = $a -replace '(\\*)"', '$1$1\"'
        $s = $s -replace '(\\+)$', '$1$1'
        '"' + $s + '"'
    }
    ($teile -join ' ')
}

function MorpheusSysHash {
    param([IO.Stream]$Stream)
    [void]$Stream.Seek(0, [IO.SeekOrigin]::Begin)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash($Stream) } finally { $sha.Dispose() }
    ([BitConverter]::ToString($h) -replace '-', '').ToLowerInvariant()
}

function MorpheusSysOeffnen {
    # Lesen erlaubt, Schreiben/Umbenennen/Löschen durch andere gesperrt
    param([string]$Pfad)
    New-Object IO.FileStream($Pfad, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
}

# Grund, warum der tools-Ordner nicht benutzt werden darf, sonst $null
function MorpheusSysOrdnerGrund {
    param([string]$ToolsDir)
    if (MorpheusSysIstVerknuepfung $ToolsDir) { return "Der Ordner $ToolsDir ist eine Verknüpfung (Junction/Symlink)." }
    $s = & $script:MorpheusSysImpl.SicherPfad $ToolsDir
    if (-not $s.Sicher) { return ('Der Ordner ist nicht nur für Administratoren beschreibbar: ' + (@($s.Gruende) -join ' | ')) }
    $null
}

# Liest werkzeuge.json (nur wenn sicher abgelegt). Rückgabe: @{ Daten = Objekt|$null; Grund = string|$null }
function MorpheusSysLeseJson {
    param([string]$ToolsDir)
    $p = Join-Path $ToolsDir 'werkzeuge.json'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @{ Daten = $null; Grund = 'Die Datei werkzeuge.json fehlt; die Werkzeuge müssen neu heruntergeladen werden.' } }
    if (MorpheusSysIstVerknuepfung $p) { return @{ Daten = $null; Grund = 'Die Datei werkzeuge.json ist eine Verknüpfung.' } }
    try {
        $s = & $script:MorpheusSysImpl.SicherPfad $p
        if (-not $s.Sicher) { return @{ Daten = $null; Grund = ('Die Datei werkzeuge.json ist nicht nur für Administratoren beschreibbar: ' + (@($s.Gruende) -join ' | ')) } }
        $d = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if (($null -eq $d) -or ($null -eq $d.werkzeuge)) { return @{ Daten = $null; Grund = 'Die Datei werkzeuge.json hat kein gültiges Format.' } }
        @{ Daten = $d; Grund = $null }
    } catch {
        @{ Daten = $null; Grund = ('Die Datei werkzeuge.json ist nicht lesbar: ' + $_.Exception.Message) }
    }
}

# Gemeinsame Vertrauensprüfung für Test-MorpheusSysWerkzeug, Start und Install.
# $Stream = bereits (mit FileShare.Read) geöffnete Datei. $SollSha256 leer = kein Hash-Vergleich (frischer Download).
# Rückgabe: @{ ok; grund; signierer; sha256 }
function MorpheusSysPruefen {
    param(
        [string]$ToolsDir,
        [string]$Pfad,
        [IO.Stream]$Stream,
        [string]$SollSha256
    )
    $datei = Split-Path -Leaf $Pfad
    $r = [ordered]@{ ok = $false; grund = $null; signierer = $null; sha256 = $null }
    try {
        if (MorpheusSysIstVerknuepfung $Pfad) { $r.grund = "Die Datei $datei ist eine Verknüpfung (Junction/Symlink)."; return $r }
        $og = MorpheusSysOrdnerGrund $ToolsDir
        if ($og) { $r.grund = $og; return $r }
        $s = & $script:MorpheusSysImpl.SicherPfad $Pfad
        if (-not $s.Sicher) { $r.grund = "Die Datei $datei ist nicht nur für Administratoren beschreibbar: " + (@($s.Gruende) -join ' | '); return $r }

        $hash = MorpheusSysHash $Stream
        $r.sha256 = $hash
        if ($SollSha256 -and ($hash -ine $SollSha256)) { $r.grund = 'Die Datei wurde seit dem Download verändert (SHA256 passt nicht).'; return $r }

        $sig = & $script:MorpheusSysImpl.Signatur $Pfad
        $status = if ($null -ne $sig) { [string]$sig.Status } else { 'Unbekannt' }
        if ($status -cne 'Valid') { $r.grund = "Die Signatur ist ungültig (Status: $status)."; return $r }
        $cert = $sig.SignerCertificate
        $subject = if ($null -ne $cert) { [string]$cert.Subject } else { '' }
        if ($subject -cnotmatch '(?:^|,\s*)O="?Microsoft Corporation"?(?:,|$)') {
            $r.grund = "Die Datei ist nicht von Microsoft Corporation signiert (Signierer: $subject)."
            return $r
        }
        $wurzel = & $script:MorpheusSysImpl.Wurzel $cert $Pfad
        $erlaubt = $false
        if ($wurzel) { foreach ($w in $script:MorpheusSysWurzeln) { if ([string]$wurzel -ieq $w) { $erlaubt = $true } } }
        if (-not $erlaubt) { $r.grund = 'Die Zertifikatskette endet nicht an einer Microsoft-Stammzertifizierungsstelle (ggf. unvollständig, weil offline).'; return $r }

        $vi = & $script:MorpheusSysImpl.Herkunft $Pfad
        $firma = if ($null -ne $vi) { [string]$vi.CompanyName } else { '' }
        $produkt = if ($null -ne $vi) { [string]$vi.ProductName } else { '' }
        if (-not (($firma -match 'Sysinternals') -or ($produkt -match 'Sysinternals'))) {
            $r.grund = "Die Datei ist kein Sysinternals-Programm (Firma: $firma, Produkt: $produkt)."
            return $r
        }

        $r.signierer = 'Microsoft Corporation'
        $r.ok = $true
        $r
    } catch {
        $r.ok = $false
        $r.grund = 'Die Prüfung ist fehlgeschlagen: ' + $_.Exception.Message
        $r
    }
}

# Startet den Prozess und liest stdout/stderr als Bytes. Schließt $Stream NICHT (das tut der Aufrufer nach der Rückkehr).
# -ImLauf: optionaler Scriptblock (param($ProzessId, $Stream)), läuft nach dem Start, vor dem Warten (für Tests).
function MorpheusSysStart {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Argumente = @(),
        [int]$TimeoutSek = 900,
        [string]$Arbeitsordner,
        [IO.Stream]$Stream,
        [scriptblock]$ImLauf
    )
    $res = [ordered]@{ ok = $false; code = $null; ausgabe = (New-Object byte[] 0); fehlerAusgabe = (New-Object byte[] 0); zeitueberschreitung = $false; fehler = $null }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = MorpheusSysArgString $Argumente
    if ($Arbeitsordner) { $psi.WorkingDirectory = $Arbeitsordner }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    $msOut = New-Object IO.MemoryStream
    $msErr = New-Object IO.MemoryStream
    try {
        [void]$p.Start()
        try { $p.StandardInput.Close() } catch { }
        $tOut = $p.StandardOutput.BaseStream.CopyToAsync($msOut)
        $tErr = $p.StandardError.BaseStream.CopyToAsync($msErr)
        if ($ImLauf) { & $ImLauf $p.Id $Stream }
        if ($p.WaitForExit([int]([Math]::Min([long]$TimeoutSek * 1000, [long][int]::MaxValue)))) {
            $p.WaitForExit()
            $res.code = $p.ExitCode
            $res.ok = $true
        } else {
            $res.zeitueberschreitung = $true
            $res.fehler = "Zeitüberschreitung nach $TimeoutSek Sekunden; der Prozess wurde beendet."
            try { & (Join-Path ([Environment]::SystemDirectory) 'taskkill.exe') /PID $p.Id /T /F 2>&1 | Out-Null } catch { }
            try { $p.Kill() } catch { }
            [void]$p.WaitForExit(5000)
        }
        try { [void][Threading.Tasks.Task]::WaitAll(@($tOut, $tErr), 5000) } catch { }
        $res.ausgabe = $msOut.ToArray()
        $res.fehlerAusgabe = $msErr.ToArray()
    } catch {
        $res.ok = $false
        $res.fehler = 'Der Prozess ließ sich nicht starten oder lesen: ' + $_.Exception.Message
        try { if (-not $p.HasExited) { $p.Kill() } } catch { }
    } finally {
        $p.Dispose()
    }
    $res
}

function MorpheusSysBytesText {
    param([byte[]]$Bytes)
    if (($null -eq $Bytes) -or ($Bytes.Length -eq 0)) { return '' }
    if (Get-Command -Name ConvertFrom-MorpheusSysAusgabe -ErrorAction SilentlyContinue) { return [string](ConvertFrom-MorpheusSysAusgabe -Bytes $Bytes) }
    [Text.Encoding]::UTF8.GetString($Bytes)
}

function MorpheusSysEntpacken {
    # Zip-Eintrag in eine Datei schreiben; die tatsächlich gelesenen Bytes werden mitgezählt (Länge im Header kann lügen)
    param($Eintrag, [string]$Ziel, [long]$MaxBytes)
    if ($Eintrag.Length -gt $MaxBytes) { throw ("Der Eintrag {0} ist mit {1} Bytes größer als erlaubt ({2})." -f $Eintrag.FullName, $Eintrag.Length, $MaxBytes) }
    $in = $Eintrag.Open()
    $out = $null
    try {
        $out = New-Object IO.FileStream($Ziel, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buf = New-Object byte[] 81920
        [long]$sum = 0
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $sum += $n
            if ($sum -gt $MaxBytes) { throw ("Der Eintrag {0} ist entpackt größer als erlaubt ({1} Bytes)." -f $Eintrag.FullName, $MaxBytes) }
            $out.Write($buf, 0, $n)
        }
    } finally {
        if ($out) { $out.Dispose() }
        $in.Dispose()
    }
}

function MorpheusSysEntferneDatei {
    param([string]$Pfad)
    if (Test-Path -LiteralPath $Pfad) { Remove-Item -LiteralPath $Pfad -Force -ErrorAction SilentlyContinue }
}

#endregion

function Get-MorpheusSysZustimmung {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DataRoot)
    $nein = [ordered]@{ akzeptiert = $false; zeit = $null; benutzer = $null }
    try {
        $p = MorpheusSysZustimmungPfad $DataRoot
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $nein }
        if (MorpheusSysIstVerknuepfung $p) { return $nein }
        $s = & $script:MorpheusSysImpl.SicherPfad $p
        if (-not $s.Sicher) { return $nein }
        $d = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if (($null -eq $d) -or ($d.eulaAkzeptiert -isnot [bool]) -or (-not $d.eulaAkzeptiert)) { return $nein }
        if ([string]$d.version -ne '1') { return $nein }
        [ordered]@{ akzeptiert = $true; zeit = [string]$d.zeit; benutzer = [string]$d.benutzer }
    } catch {
        $nein
    }
}

function Set-MorpheusSysZustimmung {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][bool]$Akzeptiert
    )
    $p = MorpheusSysZustimmungPfad $DataRoot
    if ($Akzeptiert) {
        $dir = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { [void][IO.Directory]::CreateDirectory($dir) }
        $obj = [ordered]@{
            version         = 1
            eulaAkzeptiert  = $true
            zeit            = (Get-Date).ToString('s', [Globalization.CultureInfo]::InvariantCulture)
            benutzer        = [Environment]::UserName
        }
        MorpheusSysSchreibeText -Pfad $p -Text ($obj | ConvertTo-Json)
    } else {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    Get-MorpheusSysZustimmung -DataRoot $DataRoot
}

function Test-MorpheusSysWerkzeug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][ValidateSet('autorunsc', 'sigcheck')][string]$Name
    )
    $def = $script:MorpheusSysWerkzeuge[$Name]
    $tools = MorpheusSysToolsDir $DataRoot
    $pfad = Join-Path $tools $def.Exe
    $o = [ordered]@{
        name = $Name; titel = $def.Titel; datei = $def.Exe; pfad = $pfad
        vorhanden = $false; geprueft = $false; grund = $null
        signierer = $null; version = $null; sha256 = $null; geladen = $null
    }
    try {
        if (-not (Test-Path -LiteralPath $pfad -PathType Leaf)) {
            $o.grund = "Die Datei $($def.Exe) fehlt."
            return [pscustomobject]$o
        }
        $o.vorhanden = $true
        $stream = $null
        try {
            try { $stream = MorpheusSysOeffnen $pfad }
            catch { $o.grund = "Die Datei $($def.Exe) ließ sich nicht öffnen: " + $_.Exception.Message; return [pscustomobject]$o }
            $og = MorpheusSysOrdnerGrund $tools
            if ($og) { $o.grund = $og; return [pscustomobject]$o }
            $j = MorpheusSysLeseJson -ToolsDir $tools
            if ($null -eq $j.Daten) { $o.grund = $j.Grund; return [pscustomobject]$o }
            $eintrag = $j.Daten.werkzeuge.PSObject.Properties[$Name]
            if (($null -eq $eintrag) -or (-not $eintrag.Value.sha256)) {
                $o.grund = "In werkzeuge.json gibt es keinen Eintrag für $($def.Exe)."
                return [pscustomobject]$o
            }
            $pr = MorpheusSysPruefen -ToolsDir $tools -Pfad $pfad -Stream $stream -SollSha256 ([string]$eintrag.Value.sha256)
            if (-not $pr.ok) { $o.grund = $pr.grund; return [pscustomobject]$o }
            $o.geprueft = $true
            $o.signierer = $pr.signierer
            $o.sha256 = $pr.sha256
            $o.version = [string]$eintrag.Value.version
            $o.geladen = [string]$eintrag.Value.geladen
        } finally {
            if ($stream) { $stream.Dispose() }
        }
    } catch {
        $o.geprueft = $false
        $o.grund = 'Die Prüfung ist fehlgeschlagen: ' + $_.Exception.Message
    }
    [pscustomobject]$o
}

function Get-MorpheusSysStand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DataRoot)
    $liste = @()
    foreach ($n in $script:MorpheusSysWerkzeuge.Keys) { $liste += , (Test-MorpheusSysWerkzeug -DataRoot $DataRoot -Name $n) }
    [ordered]@{
        zustimmung = (Get-MorpheusSysZustimmung -DataRoot $DataRoot)
        werkzeuge  = @($liste)
        ordner     = (MorpheusSysToolsDir $DataRoot)
        lizenzUrl  = $script:MorpheusSysLizenzUrl
    }
}

function Invoke-MorpheusSysWerkzeug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Auftrag,
        [int]$TimeoutSek = 900
    )
    $start = Get-Date
    $res = [ordered]@{
        ok = $false; auftrag = $Auftrag; code = $null; text = ''; fehler = $null; dauerSek = 0
        nichtVertrauenswuerdig = $false; nichtEingerichtet = $false
    }
    $stream = $null
    try {
        try { $a = MorpheusSysArgumente -Auftrag $Auftrag }
        catch { $res.fehler = $_.Exception.Message; return $res }
        $def = $script:MorpheusSysWerkzeuge[$a.Name]
        $tools = MorpheusSysToolsDir $DataRoot
        $pfad = Join-Path $tools $def.Exe

        if (-not (Test-Path -LiteralPath $pfad -PathType Leaf)) {
            $res.nichtEingerichtet = $true
            $res.fehler = "Die Datei $($def.Exe) fehlt."
            return $res
        }
        if (-not (Get-MorpheusSysZustimmung -DataRoot $DataRoot).akzeptiert) {
            $res.nichtEingerichtet = $true
            $res.fehler = 'Die Sysinternals-Lizenzbedingungen sind nicht angenommen.'
            return $res
        }

        # Datei sperren (kein Schreiben/Umbenennen/Löschen), dann Hash, Signatur usw. aus diesem Handle
        try { $stream = MorpheusSysOeffnen $pfad }
        catch {
            $res.nichtVertrauenswuerdig = $true
            $res.fehler = "Die Datei $($def.Exe) ließ sich nicht sperren und öffnen: " + $_.Exception.Message
            return $res
        }
        $og = MorpheusSysOrdnerGrund $tools
        if ($og) { $res.nichtVertrauenswuerdig = $true; $res.fehler = $og; return $res }
        $j = MorpheusSysLeseJson -ToolsDir $tools
        if ($null -eq $j.Daten) { $res.nichtVertrauenswuerdig = $true; $res.fehler = $j.Grund; return $res }
        $eintrag = $j.Daten.werkzeuge.PSObject.Properties[$a.Name]
        if (($null -eq $eintrag) -or (-not $eintrag.Value.sha256)) {
            $res.nichtVertrauenswuerdig = $true
            $res.fehler = "In werkzeuge.json gibt es keinen Eintrag für $($def.Exe)."
            return $res
        }
        $pr = MorpheusSysPruefen -ToolsDir $tools -Pfad $pfad -Stream $stream -SollSha256 ([string]$eintrag.Value.sha256)
        if (-not $pr.ok) { $res.nichtVertrauenswuerdig = $true; $res.fehler = $pr.grund; return $res }

        $s = MorpheusSysStart -Exe $pfad -Argumente $a.Argumente -TimeoutSek $TimeoutSek -Arbeitsordner $tools -Stream $stream
        $res.code = $s.code
        $res.text = MorpheusSysBytesText $s.ausgabe
        $err = (MorpheusSysBytesText $s.fehlerAusgabe).Trim()
        if ($s.zeitueberschreitung) {
            $res.fehler = $s.fehler
        } elseif (-not $s.ok) {
            $res.fehler = $s.fehler
        } elseif (($s.code -eq 0) -or ($res.text.Length -gt 0)) {
            $res.ok = $true
            if ($err -and ($s.code -ne 0)) { $res.fehler = $err }
        } else {
            $res.fehler = if ($err) { $err } else { "Das Werkzeug endete mit Code $($s.code) ohne Ausgabe." }
        }
    } catch {
        $res.ok = $false
        $res.fehler = $_.Exception.Message
    } finally {
        if ($stream) { $stream.Dispose() }
        $res.dauerSek = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
    }
    $res
}

function Install-MorpheusSysWerkzeuge {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DataRoot)

    if (-not (& $script:MorpheusSysImpl.Admin)) { throw 'Zum Herunterladen der Sysinternals-Werkzeuge sind Administratorrechte nötig.' }
    if (-not (Get-MorpheusSysZustimmung -DataRoot $DataRoot).akzeptiert) { throw 'Die Sysinternals-Lizenzbedingungen sind nicht angenommen. Ohne Zustimmung werden die Werkzeuge nicht heruntergeladen.' }
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { throw ('Die ZIP-Unterstützung von Windows ließ sich nicht laden: ' + $_.Exception.Message) }

    $tools = MorpheusSysToolsDir $DataRoot
    if (Test-Path -LiteralPath $tools -PathType Leaf) { throw "Der Pfad $tools ist eine Datei statt eines Ordners." }
    if (-not (Test-Path -LiteralPath $tools -PathType Container)) {
        MorpheusSysLog "Lege den gesicherten Ordner $tools an …"
        New-MorpheusSecureDirectory -Path $tools
    } else {
        if (MorpheusSysIstVerknuepfung $tools) { throw "Der Ordner $tools ist eine Verknüpfung (Junction/Symlink) und wird nicht verwendet." }
        $s = & $script:MorpheusSysImpl.SicherPfad $tools
        if (-not $s.Sicher) { throw "Der Ordner $tools ist nicht nur für Administratoren beschreibbar und wird nicht verwendet: " + (@($s.Gruende) -join ' | ') }
    }

    $fehler = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($script:MorpheusSysWerkzeuge.Keys)) {
        $def = $script:MorpheusSysWerkzeuge[$name]
        $zip = Join-Path $tools ($def.Zip + '.download')
        $neu = Join-Path $tools ($name + '.neu.exe')
        $eulaNeu = Join-Path $tools ($name + '.eula.neu')
        $ziel = Join-Path $tools $def.Exe
        $eulaZiel = Join-Path $tools ($name + '-Eula.txt')
        try {
            MorpheusSysEntferneDatei $zip; MorpheusSysEntferneDatei $neu; MorpheusSysEntferneDatei $eulaNeu

            MorpheusSysLog "Lade $($def.Titel) von $($def.Url) …"
            & $script:MorpheusSysImpl.Download $def.Url $zip $script:MorpheusSysZipMaxBytes
            if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw 'Der Download hat keine Datei geliefert.' }
            if ((Get-Item -LiteralPath $zip -Force).Length -gt $script:MorpheusSysZipMaxBytes) { throw 'Die heruntergeladene Datei ist größer als erlaubt.' }

            MorpheusSysLog "Prüfe das ZIP-Archiv von $($def.Titel) …"
            $archiv = [IO.Compression.ZipFile]::OpenRead($zip)
            $hatEula = $false
            try {
                $exeEintraege = @($archiv.Entries | Where-Object { ($_.FullName -ieq $def.Exe) -and ($_.FullName -notmatch '[\\/]') })
                if ($exeEintraege.Count -ne 1) { throw "Das Archiv enthält $($exeEintraege.Count) Einträge namens $($def.Exe) statt genau einem." }
                MorpheusSysEntpacken -Eintrag $exeEintraege[0] -Ziel $neu -MaxBytes $script:MorpheusSysExeMaxBytes
                $eulaEintraege = @($archiv.Entries | Where-Object { ($_.FullName -ieq 'Eula.txt') -and ($_.FullName -notmatch '[\\/]') })
                if ($eulaEintraege.Count -gt 1) { throw 'Das Archiv enthält mehrere Einträge namens Eula.txt.' }
                if ($eulaEintraege.Count -eq 1) {
                    MorpheusSysEntpacken -Eintrag $eulaEintraege[0] -Ziel $eulaNeu -MaxBytes $script:MorpheusSysExeMaxBytes
                    $hatEula = $true
                }
            } finally { $archiv.Dispose() }

            MorpheusSysLog "Prüfe die Signatur von $($def.Exe) …"
            $st = MorpheusSysOeffnen $neu
            try { $pr = MorpheusSysPruefen -ToolsDir $tools -Pfad $neu -Stream $st } finally { $st.Dispose() }
            if (-not $pr.ok) { throw "Die heruntergeladene Datei $($def.Exe) ist nicht vertrauenswürdig: $($pr.grund)" }
            $hash = $pr.sha256

            if (Test-Path -LiteralPath $ziel -PathType Leaf) { [IO.File]::Replace($neu, $ziel, [NullString]::Value) }
            else { [IO.File]::Move($neu, $ziel) }

            # Nach dem Verschieben erneut prüfen (Hash muss unverändert sein)
            $st = MorpheusSysOeffnen $ziel
            try { $pr2 = MorpheusSysPruefen -ToolsDir $tools -Pfad $ziel -Stream $st -SollSha256 $hash } finally { $st.Dispose() }
            if (-not $pr2.ok) {
                MorpheusSysEntferneDatei $ziel
                throw "Die Datei $($def.Exe) war nach dem Verschieben nicht mehr vertrauenswürdig: $($pr2.grund)"
            }

            $version = ''
            try { $version = [string][Diagnostics.FileVersionInfo]::GetVersionInfo($ziel).FileVersion } catch { }

            # werkzeuge.json aktualisieren (andere Einträge behalten)
            $alt = MorpheusSysLeseJson -ToolsDir $tools
            $wz = [ordered]@{}
            if ($null -ne $alt.Daten) {
                foreach ($pp in $alt.Daten.werkzeuge.PSObject.Properties) {
                    if (($pp.Name -cne $name) -and $script:MorpheusSysWerkzeuge.Contains($pp.Name)) {
                        $wz[$pp.Name] = [ordered]@{ datei = [string]$pp.Value.datei; sha256 = [string]$pp.Value.sha256; version = [string]$pp.Value.version; geladen = [string]$pp.Value.geladen }
                    }
                }
            }
            $wz[$name] = [ordered]@{
                datei   = $def.Exe
                sha256  = $hash
                version = $version
                geladen = (Get-Date).ToString('s', [Globalization.CultureInfo]::InvariantCulture)
            }
            MorpheusSysSchreibeText -Pfad (Join-Path $tools 'werkzeuge.json') -Text ([ordered]@{ version = 1; werkzeuge = $wz } | ConvertTo-Json -Depth 5)

            if ($hatEula) {
                if (Test-Path -LiteralPath $eulaZiel -PathType Leaf) { [IO.File]::Replace($eulaNeu, $eulaZiel, [NullString]::Value) }
                else { [IO.File]::Move($eulaNeu, $eulaZiel) }
            }
            MorpheusSysLog "$($def.Titel) ist eingerichtet (Version $version)."
        } catch {
            $fehler.Add("$($def.Titel): " + $_.Exception.Message)
            MorpheusSysLog ("Fehler bei $($def.Titel): " + $_.Exception.Message)
        } finally {
            MorpheusSysEntferneDatei $zip; MorpheusSysEntferneDatei $neu; MorpheusSysEntferneDatei $eulaNeu
        }
    }

    if ($fehler.Count -gt 0) { throw ('Die Sysinternals-Werkzeuge konnten nicht vollständig eingerichtet werden. ' + ($fehler -join ' ')) }

    $liste = @()
    foreach ($n in $script:MorpheusSysWerkzeuge.Keys) { $liste += , (Test-MorpheusSysWerkzeug -DataRoot $DataRoot -Name $n) }
    [ordered]@{ werkzeuge = @($liste); meldung = 'Autoruns und Sigcheck wurden heruntergeladen, geprüft und eingerichtet.' }
}

function Remove-MorpheusSysWerkzeuge {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DataRoot)
    $tools = MorpheusSysToolsDir $DataRoot
    $fehler = New-Object System.Collections.Generic.List[string]
    $ziele = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($script:MorpheusSysWerkzeuge.Keys)) {
        $def = $script:MorpheusSysWerkzeuge[$name]
        foreach ($f in @($def.Exe, ($name + '-Eula.txt'), ($def.Zip + '.download'), ($name + '.neu.exe'), ($name + '.eula.neu'))) { $ziele.Add((Join-Path $tools $f)) }
    }
    $ziele.Add((Join-Path $tools 'werkzeuge.json'))
    $ziele.Add((Join-Path $tools 'werkzeuge.json.tmp'))
    $ziele.Add((MorpheusSysZustimmungPfad $DataRoot))
    # Zuerst die EXEs: ist eine in Benutzung (Scan läuft), wird abgebrochen, bevor Zustimmung und Metadaten verschwinden
    foreach ($name in @($script:MorpheusSysWerkzeuge.Keys)) {
        $exe = Join-Path $tools $script:MorpheusSysWerkzeuge[$name].Exe
        if (Test-Path -LiteralPath $exe) {
            try { [IO.File]::Delete($exe) }
            catch { throw ("$($script:MorpheusSysWerkzeuge[$name].Exe) wird gerade verwendet (läuft ein Scan?). Bitte später erneut versuchen.") }
        }
    }
    foreach ($z in $ziele) {
        if (Test-Path -LiteralPath $z) {
            try { [IO.File]::Delete($z) } catch { $fehler.Add((Split-Path -Leaf $z) + ': ' + $_.Exception.Message) }
        }
    }
    if ($fehler.Count -gt 0) { throw ('Nicht alle Sysinternals-Dateien ließen sich löschen: ' + ($fehler -join ' | ')) }
    Get-MorpheusSysStand -DataRoot $DataRoot
}

function Get-MorpheusSysEula {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not ($script:MorpheusSysWerkzeuge.Keys -ccontains $Name)) { return $null }
    $p = Join-Path (MorpheusSysToolsDir $DataRoot) ($Name + '-Eula.txt')
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    if (MorpheusSysIstVerknuepfung $p) { return $null }
    try {
        $fs = New-Object IO.FileStream($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $max = [int]$script:MorpheusSysEulaMaxBytes
            $buf = New-Object byte[] ($max + 1)
            $gelesen = 0
            while ($gelesen -lt $buf.Length) {
                $n = $fs.Read($buf, $gelesen, $buf.Length - $gelesen)
                if ($n -le 0) { break }
                $gelesen += $n
            }
        } finally { $fs.Dispose() }
        $gekuerzt = ($gelesen -gt $max)
        if ($gekuerzt) { $gelesen = $max - ($max % 2) }
        $bytes = New-Object byte[] $gelesen
        [Array]::Copy($buf, $bytes, $gelesen)
        $text = (MorpheusSysBytesText $bytes) -replace "`0", ''
        if ($gekuerzt) { $text += "`r`n`r`n[… gekürzt; den vollständigen Text findest du unter $($script:MorpheusSysLizenzUrl)]" }
        $text
    } catch {
        $null
    }
}
