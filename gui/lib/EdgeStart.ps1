#Requires -Version 5.1
<#
.SYNOPSIS
    Edge-Start ohne Adminrechte und Prüfung der Integritätsstufe (v2.10, #115, N1 aus sicherheitspruefung-2.3.3.md).

.DESCRIPTION
    Wird per Dot-Source geladen (pc-check-gui.ps1 und Server.ps1). Vertrag: docs/gui-architektur.md Abschnitt 21.
    Bedrohung: Das Edge-Profil liegt in %LOCALAPPDATA%\pc-check\edge und ist vom Benutzer beschreibbar (Erweiterungen, Startseite,
    Flags). Liefe Edge mit Adminrechten, bekäme alles, was ein Benutzerprogramm dort ablegt, Adminrechte.
    - Start: Der Admin-Prozess startet msedge.exe nie selbst. ShellExecute läuft über das Desktop-Shell-Objekt von explorer.exe
      (Shell.Application.Windows().FindWindowSW, Desktop); der Prozess entsteht damit im nicht erhöhten Benutzerkontext (Elternprozess
      explorer.exe, Umgebung des Benutzers, nicht des erhöhten Prozesses). Das ist kein Rechtegewinn: Wer explorer.exe als Benutzer
      steuern kann, hat Benutzerrechte ohnehin. Geht das nicht, startet Morpheus kein Edge, sondern nennt die Adresse in der Konsole.
    - Prüfung (belegt statt angenommen): Der Server liest mit OpenProcessToken/GetTokenInformation(TokenIntegrityLevel) die
      Integritätsstufe jedes msedge.exe mit unserem Profil. Hohe Stufe (>= 0x3000) heißt: erhöht. Dann beendet Morpheus diese
      Prozesse und wechselt in den Nur-Lesen-Modus. Die Abfrage ist reines Lesen; P/Invoke im Speicher per Reflection.Emit
      statt Add-Type (kein Kompilieren über %TEMP%).
    Seiteneffekte laufen über $script:MorpheusEdgeImpl; Tests ersetzen sie.
#>

. (Join-Path $PSScriptRoot 'Sprache.ps1')

# Windows-Integritätsstufen (letzter Teil der Label-SID): Mittel 0x2000, Hoch 0x3000 (erhöht), System 0x4000
$script:MorpheusRidHoch = 0x3000

# Befehlszeile für Edge. Url und Profil kommen aus dem eigenen Code; Anführungszeichen darin wären ein Programmfehler.
function Get-MorpheusEdgeArgumente {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Profil)
    if (($Url.IndexOf('"') -ge 0) -or ($Profil.IndexOf('"') -ge 0)) { throw (T 'server.edge.argumentUngueltig') }
    # --start-maximized: bildschirmfüllend (ein App-Fenster merkt sich sonst die letzte Größe)
    # Die drei --disable-*-Schalter verhindern, dass Edge das Fenster im Hintergrund drosselt (Heartbeat bliebe sonst aus)
    '"--app={0}" "--user-data-dir={1}" --start-maximized --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows' -f $Url, $Profil
}

#region Windows-Aufrufe (privat, von Tests ersetzbar)

# ShellExecute über den Desktop von explorer.exe: Prozess ohne Adminrechte. Wirft, wenn der Desktop nicht erreichbar ist.
function MorpheusEdgeShellStarten {
    param([string]$Datei, [string]$Argumente)
    $shell = New-Object -ComObject Shell.Application
    $hwnd = 0
    # SWC_DESKTOP = 8, SWFO_NEEDDISPATCH = 1
    $disp = $shell.Windows().FindWindowSW([ref]0, [ref]0, 8, [ref]$hwnd, 1)
    if ($null -eq $disp) { throw (T 'server.edge.keinDesktop') }
    $disp.Document.Application.ShellExecute($Datei, $Argumente, [IO.Path]::GetDirectoryName($Datei), 'open', 1)
}

# Integritätsstufe (RID der Label-SID) eines Prozesses oder $null (Prozess weg, nicht lesbar, Aufruf fehlgeschlagen)
function MorpheusProzessRidLesen {
    param([int]$ProcessId)
    $t = $null
    foreach ($a in [AppDomain]::CurrentDomain.GetAssemblies()) { if ($a.IsDynamic -and ($a.GetName().Name -eq 'MorpheusToken')) { $t = $a.GetType('MorpheusToken.Native', $false) } }
    if (-not $t) {
        $asm = [AppDomain]::CurrentDomain.DefineDynamicAssembly((New-Object Reflection.AssemblyName 'MorpheusToken'), [Reflection.Emit.AssemblyBuilderAccess]::Run)
        $tb = $asm.DefineDynamicModule('MorpheusToken').DefineType('MorpheusToken.Native', 'Public, Class')
        $attr = [Reflection.MethodAttributes]'Public, Static, PinvokeImpl'
        $cc = [Reflection.CallingConventions]::Standard
        $defs = @(
            @{ N = 'OpenProcess'; D = 'kernel32.dll'; R = [IntPtr]; P = [Type[]]@([uint32], [bool], [uint32]) },
            @{ N = 'CloseHandle'; D = 'kernel32.dll'; R = [bool]; P = [Type[]]@([IntPtr]) },
            @{ N = 'OpenProcessToken'; D = 'advapi32.dll'; R = [bool]; P = [Type[]]@([IntPtr], [uint32], [IntPtr].MakeByRefType()) },
            @{ N = 'GetTokenInformation'; D = 'advapi32.dll'; R = [bool]; P = [Type[]]@([IntPtr], [int], [IntPtr], [uint32], [uint32].MakeByRefType()) }
        )
        foreach ($d in $defs) {
            $m = $tb.DefinePInvokeMethod($d.N, $d.D, $attr, $cc, $d.R, $d.P, [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::Auto)
            $m.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
        }
        $t = $tb.CreateType()
    }
    $hProc = [IntPtr]::Zero; $hTok = [IntPtr]::Zero; $buf = [IntPtr]::Zero
    try {
        # PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, TOKEN_QUERY = 0x8, TokenIntegrityLevel = 25
        $hProc = $t::OpenProcess(0x1000, $false, [uint32]$ProcessId)
        if ($hProc -eq [IntPtr]::Zero) { return $null }
        if (-not $t::OpenProcessToken($hProc, 0x8, [ref]$hTok)) { return $null }
        $len = [uint32]0
        [void]$t::GetTokenInformation($hTok, 25, [IntPtr]::Zero, 0, [ref]$len)
        if (($len -lt 8) -or ($len -gt 1024)) { return $null }
        $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal([int]$len)
        if (-not $t::GetTokenInformation($hTok, 25, $buf, $len, [ref]$len)) { return $null }
        # TOKEN_MANDATORY_LABEL beginnt mit dem Zeiger auf die SID
        $sidPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($buf)
        $sid = New-Object Security.Principal.SecurityIdentifier $sidPtr
        if ($sid.Value -cnotmatch '^S-1-16-(\d+)$') { return $null }
        [int]$Matches[1]
    }
    catch { $null }
    finally {
        if ($buf -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
        if ($hTok -ne [IntPtr]::Zero) { [void]$t::CloseHandle($hTok) }
        if ($hProc -ne [IntPtr]::Zero) { [void]$t::CloseHandle($hProc) }
    }
}

$script:MorpheusEdgeImpl = @{
    Starten = { param($Datei, $Argumente) MorpheusEdgeShellStarten -Datei $Datei -Argumente $Argumente }
    Rid     = { param($ProcessId) MorpheusProzessRidLesen -ProcessId $ProcessId }
    Beenden = { param($ProcessId) Stop-Process -Id $ProcessId -Force -ErrorAction Stop }
}

#endregion

# Startet Edge im Benutzerkontext (nicht erhöht). Gibt $true bei Erfolg zurück, sonst $false (dann keinen Rückfall auf Start-Process!).
function Start-MorpheusEdgeOhneAdmin {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EdgeExe, [Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Profil)
    try {
        & $script:MorpheusEdgeImpl.Starten $EdgeExe (Get-MorpheusEdgeArgumente -Url $Url -Profil $Profil)
        $true
    }
    catch { $false }
}

# Prüft die msedge-Prozesse mit unserem Profil. Prozesse: Objekte mit ProcessId und CommandLine (Win32_Process).
# Rückgabe: { Erhoeht = Liste der Prozesse mit hoher Integrität (ProcessId, Rid); Unbekannt = Anzahl nicht lesbarer Prozesse; Geprueft = Anzahl }
# Die Sandbox-Kindprozesse von Edge haben niedrige Stufen und fallen nicht auf; nur hoch oder System zählt als erhöht.
function Test-MorpheusEdgeIntegritaet {
    [CmdletBinding()]
    param([AllowNull()][object[]]$Prozesse, [Parameter(Mandatory)][string]$Profil)
    $erhoeht = New-Object System.Collections.Generic.List[object]
    $unbekannt = 0; $geprueft = 0
    foreach ($p in @($Prozesse)) {
        if ($null -eq $p) { continue }
        $cl = [string]$p.CommandLine
        if (($cl.Length -eq 0) -or ($cl.IndexOf($Profil, [StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
        $geprueft++
        $rid = & $script:MorpheusEdgeImpl.Rid ([int]$p.ProcessId)
        if ($null -eq $rid) { $unbekannt++; continue }
        if ([int]$rid -ge $script:MorpheusRidHoch) { $erhoeht.Add([pscustomobject]@{ ProcessId = [int]$p.ProcessId; Rid = [int]$rid }) }
    }
    [pscustomobject]@{ Erhoeht = $erhoeht.ToArray(); Unbekannt = $unbekannt; Geprueft = $geprueft }
}
