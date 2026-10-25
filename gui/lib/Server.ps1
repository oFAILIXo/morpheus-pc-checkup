# pc-check GUI: lokaler HTTP-Server (Routing, Sicherheitsprüfungen, Jobs).
# Wird von pc-check-gui.ps1 per Dot-Source im Script-Scope geladen. Vertrag: docs/gui-architektur.md (Abschnitte 3-6, 11).
# Windows PowerShell 5.1. Der Server nimmt nur Aktions-IDs entgegen, nie Befehle oder Pfade (Abschnitt 4.6).

$script:GuiReportRx = '^pc-check_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}\.(json|html|md)\z'
$script:GuiCsp = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"
$script:GuiReportCsp = "default-src 'self'; script-src 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"
$script:GuiMaxBody = 262144
$script:GuiJobKeepMinutes = 30

#region Hilfsfunktionen

function Write-GuiLog {
    param([string]$Text)
    try {
        $dir = Join-Path $script:Gui.DataRoot 'state'
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $p = Join-Path $dir 'gui.log'
        if ((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p).Length -gt 2MB)) {
            Move-Item -LiteralPath $p -Destination ($p + '.1') -Force
        }
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Text + "`r`n"
        [IO.File]::AppendAllText($p, $line, (New-Object Text.UTF8Encoding $false))
    }
    catch { }
}

function Stop-GuiRequest {
    # Bricht die aktuelle Anfrage mit Status und Nutzertext ab (wird im Handler gefangen).
    param([int]$Status, [string]$Message)
    $ex = New-Object System.Exception $Message
    $ex.Data['status'] = $Status
    throw $ex
}

function Test-GuiFn {
    param([string[]]$Name)
    foreach ($n in $Name) {
        if (-not (Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue)) { return $false }
    }
    return $true
}

function Get-GuiReadOnlyMessage {
    $why = [string]$script:Gui.ReadOnlyReason
    if (-not $why) { $why = 'Morpheus läuft im Nur-Lesen-Modus.' }
    $why + ' Änderungen, „Rückgängig“ und Scans sind gesperrt (ein Scan würde Code aus einem ungesicherten Ordner mit Administratorrechten ausführen). Starte Morpheus über das Startmenü bzw. C:\Program Files\Morpheus\pc-check-gui.cmd.'
}

function Assert-GuiWritable {
    # Ändernde Endpunkte und der Scan: im Nur-Lesen-Modus immer 403
    if ($script:Gui.ReadOnly) { Stop-GuiRequest 403 (Get-GuiReadOnlyMessage) }
}

function Assert-GuiFn {
    # Fehlt eine Safety-Funktion, antwortet der Endpunkt mit 501.
    param([string[]]$Name)
    if (-not (Test-GuiFn $Name)) { Stop-GuiRequest 501 'Diese Funktion ist noch nicht verfügbar (Safety.ps1 fehlt oder ist unvollständig).' }
}

function New-GuiSecret {
    # 32 Zufallsbytes als base64url (für Token, Startcode und Lesemarken)
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Test-GuiTokenEqual {
    # Vergleich in konstanter Zeit (unabhängig davon, wo sich die Werte unterscheiden).
    param([string]$A, [string]$B)
    $x = [Text.Encoding]::UTF8.GetBytes([string]$A)
    $y = [Text.Encoding]::UTF8.GetBytes([string]$B)
    $d = [int]($x.Length -bxor $y.Length)
    $n = [Math]::Max($x.Length, $y.Length)
    for ($i = 0; $i -lt $n; $i++) {
        $xi = 0; if ($i -lt $x.Length) { $xi = [int]$x[$i] }
        $yi = 0; if ($i -lt $y.Length) { $yi = [int]$y[$i] }
        $d = $d -bor ($xi -bxor $yi)
    }
    return ($d -eq 0)
}

function Send-GuiBytes {
    param($Res, [int]$Status, [string]$ContentType, [byte[]]$Bytes, [string]$Csp)
    $script:Gui.Status = $Status
    if (-not $Csp) { $Csp = $script:GuiCsp }
    $Res.StatusCode = $Status
    $Res.ContentType = $ContentType
    $Res.Headers.Set('Content-Security-Policy', $Csp)
    $Res.Headers.Set('X-Content-Type-Options', 'nosniff')
    $Res.Headers.Set('Referrer-Policy', 'no-referrer')
    $Res.Headers.Set('Cache-Control', 'no-store')
    if ($Status -eq 405) { $Res.Headers.Set('Allow', 'GET, POST') }
    $Res.ContentLength64 = $Bytes.Length
    if ($Bytes.Length -gt 0) { $Res.OutputStream.Write($Bytes, 0, $Bytes.Length) }
}

function Send-GuiJson {
    param($Res, [int]$Status, $Object)
    $json = ConvertTo-Json -InputObject $Object -Depth 8 -Compress
    Send-GuiBytes $Res $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Read-GuiBody {
    # Liest den JSON-Body (max. 256 KB). Leerer Body ergibt ein leeres Objekt.
    param($Req)
    if (-not $Req.HasEntityBody) { return [pscustomobject]@{} }
    if ($Req.ContentLength64 -gt $script:GuiMaxBody) { Stop-GuiRequest 413 'Anfrage zu groß.' }
    $sr = New-Object IO.StreamReader($Req.InputStream, [Text.Encoding]::UTF8)
    try {
        $buf = New-Object char[] 4096
        $sb = New-Object Text.StringBuilder
        while (($n = $sr.Read($buf, 0, $buf.Length)) -gt 0) {
            [void]$sb.Append($buf, 0, $n)
            if ($sb.Length -gt $script:GuiMaxBody) { Stop-GuiRequest 413 'Anfrage zu groß.' }
        }
        $text = $sb.ToString()
    }
    finally { $sr.Dispose() }
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    try { $obj = $text | ConvertFrom-Json -ErrorAction Stop }
    catch { Stop-GuiRequest 400 'Ungültiges JSON.' }
    if ($null -eq $obj) { return [pscustomobject]@{} }
    return $obj
}

function Get-GuiProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Resolve-GuiReportPath {
    # Nur Dateinamen im festen Muster, aufgelöst im Ordner reports\ (Regex + GetFullPath + Präfix-Prüfung).
    param([string]$FileName, [string]$Ext)
    if ($FileName -notmatch $script:GuiReportRx) { return $null }
    if ([IO.Path]::GetExtension($FileName).TrimStart('.').ToLowerInvariant() -ne $Ext) { return $null }
    $dir = [IO.Path]::GetFullPath((Join-Path $script:Gui.DataRoot 'reports')).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $dir $FileName))
    if (-not $full.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
    return $full
}

function Get-GuiReportList {
    # Liest je Bericht nur Meta und zählt die Befunde (pro Datei nach Name + Änderungszeit gecacht).
    $dir = Join-Path $script:Gui.DataRoot 'reports'
    $files = @(Get-ChildItem -LiteralPath $dir -Filter 'pc-check_*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $script:GuiReportRx })
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($f in $files) {
        $seen[$f.Name] = $true
        $stamp = '{0}-{1}' -f $f.LastWriteTimeUtc.Ticks, $f.Length
        $c = $script:Gui.ReportCache[$f.Name]
        if ($c -and $c.Stamp -eq $stamp) { $list.Add($c.Info); continue }
        try {
            $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $ser.MaxJsonLength = [int]::MaxValue
            $ser.RecursionLimit = 500
            $obj = $ser.DeserializeObject([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
            $meta = $obj['Meta']
            $counts = [ordered]@{ CRIT = 0; WARN = 0; TIPP = 0; ACK = 0; INFO = 0; OK = 0; SKIP = 0 }
            foreach ($fd in $obj['Findings']) {
                $s = [string]$fd['Status']
                if ($counts.Contains($s)) { $counts[$s] = [int]$counts[$s] + 1 }
            }
            $info = [ordered]@{
                name     = $f.BaseName
                created  = [string]$meta['Erstellt']
                version  = [string]$meta['Version']
                admin    = [bool]$meta['Admin']
                profil   = [string]$meta['Profil']
                computer = [string]$meta['Computer']
                hasHtml  = (Test-Path -LiteralPath (Join-Path $dir ($f.BaseName + '.html')) -PathType Leaf)
                counts   = $counts
            }
            $script:Gui.ReportCache[$f.Name] = @{ Stamp = $stamp; Info = $info }
            $list.Add($info)
        }
        catch { Write-GuiLog ("Bericht nicht lesbar: {0}: {1}" -f $f.Name, $_.Exception.Message) }
    }
    foreach ($k in @($script:Gui.ReportCache.Keys)) { if (-not $seen.ContainsKey($k)) { $script:Gui.ReportCache.Remove($k) } }
    return @($list | Sort-Object { $_.created } -Descending)
}

function Get-GuiHelp {
    $p = Join-Path $script:Gui.Root 'pc-check.hilfe.psd1'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Stop-GuiRequest 404 'pc-check.hilfe.psd1 nicht gefunden.' }
    $stamp = (Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks
    if ($script:Gui.HelpCache -and $script:Gui.HelpCache.Stamp -eq $stamp) { return $script:Gui.HelpCache.Data }
    $data = Import-PowerShellDataFile -LiteralPath $p
    $script:Gui.HelpCache = @{ Stamp = $stamp; Data = $data }
    return $data
}

function Save-GuiTextAtomic {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, $null) }
    else { Move-Item -LiteralPath $tmp -Destination $Path -Force }
}

#endregion

#region Jobs

$script:GuiJobScripts = @{
    refresh = {
        param($Root, $Safety)
        . $Safety
        Write-Information -MessageData "[$(Get-Date -Format HH:mm:ss)] Zustände der Anpassungen lesen" -InformationAction Continue
        $cat = @(Get-PcCheckCatalog -Root $Root)
        Get-PcCheckActionStates -Root $Root -Catalog $cat
    }
    # Code kommt aus $Root, Daten (Journal) aus $DataRoot
    run     = {
        param($Root, $Safety, $Ids, $Variante, $DataRoot)
        . $Safety
        if ($Variante) { Invoke-PcCheckChange -Root $Root -DataRoot $DataRoot -Ids $Ids -Variante $Variante }
        else { Invoke-PcCheckChange -Root $Root -DataRoot $DataRoot -Ids $Ids }
    }
    undo    = {
        param($Root, $Safety, $EntryId, $Force, $DataRoot)
        . $Safety
        if ($Force) { Undo-PcCheckChange -Root $Root -DataRoot $DataRoot -EntryId $EntryId -Force }
        else { Undo-PcCheckChange -Root $Root -DataRoot $DataRoot -EntryId $EntryId }
    }
    scan    = {
        param($Root, $ScanArgs, $DataRoot)
        $t0 = Get-Date
        $ps1 = Join-Path $Root 'pc-check.ps1'
        if (-not (Test-Path -LiteralPath $ps1)) { throw 'pc-check.ps1 wurde nicht gefunden.' }
        Write-Information -MessageData "[$(Get-Date -Format HH:mm:ss)] Scan gestartet" -InformationAction Continue
        $al = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps1) + @($ScanArgs)
        & powershell.exe @al 2>&1 | ForEach-Object {
            $s = ("$_").TrimEnd()
            if ($s.Trim()) { Write-Information -MessageData "[$(Get-Date -Format HH:mm:ss)] $s" -InformationAction Continue }
        }
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw "Der Scan wurde mit Fehlercode $code beendet." }
        $neu = Get-ChildItem -LiteralPath (Join-Path $DataRoot 'reports') -Filter 'pc-check_*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $t0.AddSeconds(-5) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $name = $null; if ($neu) { $name = $neu.BaseName }
        [pscustomobject]@{ exitCode = $code; bericht = $name }
    }
}

function Confirm-GuiElevated {
    # Bestätigung durch ein Windows-Dialogfenster DIESES (Admin-)Prozesses. Windows verhindert per UIPI, dass Programme
    # ohne Adminrechte in dieses Fenster klicken oder tippen. Ein Schadprogramm, das das Edge-Fenster fernsteuert oder das
    # Token aus dessen Speicher liest, kann eine Änderung also anstoßen, aber nicht bestätigen.
    param([string]$Text)
    if (-not ('MorpheusUi.Native' -as [type])) {
        Add-Type -Namespace MorpheusUi -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);'
    }
    # MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2 (Nein vorbelegt) | MB_SYSTEMMODAL | MB_SETFOREGROUND | MB_TOPMOST
    $r = [MorpheusUi.Native]::MessageBoxW([IntPtr]::Zero, $Text, 'Morpheus – Änderung bestätigen', 0x00051124)
    return ($r -eq 6)
}

function Start-GuiJob {
    param([string]$Art, [object[]]$JobArgs, [bool]$Mutating, [string]$Confirm)
    # Verteidigung in der Tiefe: Im Nur-Lesen-Modus startet kein ändernder Job und kein Scan, egal wer fragt
    if ($script:Gui.ReadOnly -and ($Art -in 'run', 'undo', 'scan')) { Stop-GuiRequest 403 (Get-GuiReadOnlyMessage) }
    if ($Art -in 'run', 'undo') {
        if (-not $Confirm) { Stop-GuiRequest 500 'Interner Fehler: Bestätigungstext fehlt.' }
        Write-GuiLog "Warte auf Bestätigung im Windows-Dialog ($Art)"
        $ok = Confirm-GuiElevated $Confirm
        # Während der Dialog offen war, stand die Hauptschleife: Heartbeat-Uhr neu starten, sonst endet der Server danach
        $script:Gui.LastHeartbeat = Get-Date
        if (-not $ok) {
            Write-GuiLog "Im Windows-Dialog abgelehnt ($Art)"
            Stop-GuiRequest 403 'Im Windows-Bestätigungsdialog abgelehnt. Es wurde nichts geändert.'
        }
    }
    $job = Start-Job -ScriptBlock $script:GuiJobScripts[$Art] -ArgumentList $JobArgs
    $id = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
    $rec = @{
        Id = $id; Art = $Art; Job = $job; Status = 'running'; Mutating = $Mutating
        Log = (New-Object System.Collections.Generic.List[string])
        Seen = @{ Information = 0; Warning = 0; Error = 0 }
        Started = Get-Date; Finished = $null; Ergebnis = $null
    }
    $script:Gui.Jobs[$id] = $rec
    Write-GuiLog "Job $id gestartet ($Art)"
    return $id
}

function Get-GuiJobStreamLines {
    param($Rec)
    $cj = $null
    if ($Rec.Job.ChildJobs.Count -gt 0) { $cj = $Rec.Job.ChildJobs[0] }
    if (-not $cj) { return }
    foreach ($stream in 'Information', 'Warning', 'Error') {
        $col = $cj.$stream
        for ($i = [int]$Rec.Seen[$stream]; $i -lt $col.Count; $i++) {
            $item = $col[$i]
            if ($stream -eq 'Information') { $text = [string]$item.MessageData }
            elseif ($stream -eq 'Warning') { $text = '[' + (Get-Date -Format HH:mm:ss) + '] WARNUNG: ' + [string]$item.Message }
            else { $text = '[' + (Get-Date -Format HH:mm:ss) + '] FEHLER: ' + [string]$item }
            $Rec.Log.Add($text)
        }
        $Rec.Seen[$stream] = $col.Count
    }
}

function Remove-GuiJobNoise {
    # Receive-Job hängt PSComputerName/RunspaceId/PSShowComputerName an; die gehören nicht ins Ergebnis.
    param($Item)
    $noise = 'PSComputerName', 'RunspaceId', 'PSShowComputerName'
    if ($Item -is [System.Collections.IDictionary]) { foreach ($n in $noise) { if ($Item.Contains($n)) { $Item.Remove($n) } }; return $Item }
    if (($Item -is [psobject]) -and ($Item -isnot [string]) -and $Item.PSObject.Properties['RunspaceId']) { return ($Item | Select-Object -Property * -ExcludeProperty $noise) }
    return $Item
}
function Update-GuiJobs {
    foreach ($rec in @($script:Gui.Jobs.Values)) {
        if ($rec.Status -eq 'running') {
            try {
                Get-GuiJobStreamLines $rec
                $state = $rec.Job.State
                if ($state -in 'Completed', 'Failed', 'Stopped') {
                    $reason = $null
                    if (($rec.Job.ChildJobs.Count -gt 0) -and $rec.Job.ChildJobs[0].JobStateInfo.Reason) { $reason = $rec.Job.ChildJobs[0].JobStateInfo.Reason.Message }
                    $out = @(Receive-Job -Job $rec.Job -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -InformationAction SilentlyContinue)
                    $out = @($out | ForEach-Object { Remove-GuiJobNoise $_ })
                    if ($state -eq 'Completed') {
                        $rec.Status = 'done'
                        if ($rec.Art -eq 'run') { $rec.Ergebnis = @($out) }
                        elseif ($out.Count -gt 0) { $rec.Ergebnis = $out[$out.Count - 1] }
                        if (($rec.Art -eq 'refresh') -and ($rec.Ergebnis -is [System.Collections.IDictionary])) { $script:Gui.ActionStates = $rec.Ergebnis }
                    }
                    else {
                        $rec.Status = 'failed'
                        if (-not $reason) { $reason = 'Der Job wurde abgebrochen.' }
                        $rec.Ergebnis = [ordered]@{ error = $reason }
                        $rec.Log.Add('[' + (Get-Date -Format HH:mm:ss) + '] FEHLER: ' + $reason)
                    }
                    $rec.Finished = Get-Date
                    Remove-Job -Job $rec.Job -Force -ErrorAction SilentlyContinue
                    $rec.Job = $null
                    Write-GuiLog ("Job {0} beendet ({1}): {2}" -f $rec.Id, $rec.Art, $rec.Status)
                }
            }
            catch {
                $rec.Status = 'failed'; $rec.Finished = Get-Date
                $rec.Ergebnis = [ordered]@{ error = $_.Exception.Message }
                Write-GuiLog ("Job {0} Auswertung fehlgeschlagen: {1}" -f $rec.Id, $_.Exception.Message)
            }
        }
        elseif ($rec.Finished -and (((Get-Date) - $rec.Finished).TotalMinutes -gt $script:GuiJobKeepMinutes)) {
            $script:Gui.Jobs.Remove($rec.Id)
        }
    }
}

function Get-GuiRunningJobs {
    param([switch]$MutatingOnly)
    return @($script:Gui.Jobs.Values | Where-Object { ($_.Status -eq 'running') -and ((-not $MutatingOnly) -or $_.Mutating) })
}

#endregion

#region Live-Werte (Hintergrund-Runspace)

# Der Scriptblock läuft in einem eigenen Runspace (kein Job, kein Prozess) und schreibt in die synchronisierte
# Hashtable $State: Snap = letzter Schnappschuss, LastRequest = letzter /api/live-Abruf, Stop = Beenden-Signal.
# Gesammelt wird nur, solange in den letzten 20 s abgefragt wurde. Jede Quelle hat ihr eigenes try/catch.
$script:GuiLiveScript = {
    param($State)
    $ErrorActionPreference = 'Stop'
    $cpuCount = 1
    try { $cpuCount = [int]([Environment]::ProcessorCount); if ($cpuCount -lt 1) { $cpuCount = 1 } } catch { }
    $prevCpu = $null; $prevTime = $null   # für die CPU-Zeit-Differenzen der Top-Prozesse
    $histCpu = New-Object System.Collections.Generic.List[double]
    $histRam = New-Object System.Collections.Generic.List[double]
    $histGpu = New-Object System.Collections.Generic.List[double]
    $driveTypes = $null; $typesDone = $false   # Laufwerksbuchstabe -> SSD/HDD/? (einmal ermittelt)
    $smiPath = $null; $smiChecked = $false
    $prevRx = $null; $prevTx = $null; $prevT = $null; $prevAdapter = $null
    $adCache = $null; $cycle = 0

    while (-not $State.Stop) {
        # Schlafen, wenn niemand zuschaut
        if ((([datetime]::Now) - $State.LastRequest).TotalSeconds -gt 20) {
            $prevRx = $null; $prevTx = $null; $prevT = $null   # Raten nach Pause nicht über die Lücke mitteln
            Start-Sleep -Milliseconds 500
            continue
        }
        $t0 = [datetime]::Now
        $cycle++

        # --- CPU ---
        $cpu = $null
        try {
            $p = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
            if ($p) { $cpu = [Math]::Round([double]@($p)[0].PercentProcessorTime, 1) }
        } catch { $cpu = $null }

        # --- RAM ---
        $ram = $null
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem
            $totKB = [double]$os.TotalVisibleMemorySize; $freeKB = [double]$os.FreePhysicalMemory
            $usedKB = $totKB - $freeKB
            $ram = [ordered]@{
                usedPct = [int][Math]::Round(100 * $usedKB / $totKB)
                usedGB  = [Math]::Round($usedKB / 1MB, 1)
                totalGB = [Math]::Round($totKB / 1MB, 1)
            }
        } catch { $ram = $null }

        # --- GPU (nur NVIDIA, nvidia-smi mit Timeout) ---
        $gpu = $null
        try {
            if (-not $smiChecked) {
                $smiChecked = $true
                $c = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
                if ($c) { $smiPath = $c.Source }
                else {
                    foreach ($cand in @((Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'), (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'))) {
                        if (Test-Path -LiteralPath $cand -PathType Leaf) { $smiPath = $cand; break }
                    }
                }
            }
            if ($smiPath) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $smiPath
                $psi.Arguments = '--query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits'
                $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                try {
                    $outTask = $proc.StandardOutput.ReadToEndAsync()
                    if ($proc.WaitForExit(3000)) {
                        $line = ([string]$outTask.Result -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                        $f = @($line -split ',' | ForEach-Object { $_.Trim() })
                        if ($f.Count -ge 5) {
                            $mu = [double]$f[3]; $mt = [double]$f[4]
                            $memPct = 0; if ($mt -gt 0) { $memPct = [int][Math]::Round(100 * $mu / $mt) }
                            $gpu = [ordered]@{ name = $f[0]; util = [int]$f[1]; temp = [int]$f[2]; memUsedPct = $memPct }
                        }
                    }
                    else { try { $proc.Kill() } catch { } }
                }
                finally { $proc.Dispose() }
            }
        } catch { $gpu = $null }

        # --- Netzwerk: verbundener physischer Adapter mit Standardroute ---
        $net = $null
        try {
            # Adapter nur alle 10 Zyklen (~20 s) neu bestimmen, das ist der langsame Teil
            if (($null -eq $adCache) -or ($cycle % 10 -eq 0)) {
                $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object { $_.RouteMetric + $_.InterfaceMetric }
                $adCache = $null
                foreach ($r in $route) {
                    $a = Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
                    if ($a) { $adCache = $a; break }
                }
            }
            $ad = $adCache
            if ($ad) {
                $st = Get-NetAdapterStatistics -Name $ad.Name -ErrorAction Stop
                $now = [datetime]::Now
                $rxKB = 0.0; $txKB = 0.0
                if (($null -ne $prevT) -and ($prevAdapter -eq $ad.Name)) {
                    $dt = ($now - $prevT).TotalSeconds
                    if ($dt -gt 0.2) {
                        $rxKB = [Math]::Max(0.0, ([double]$st.ReceivedBytes - $prevRx) / 1KB / $dt)
                        $txKB = [Math]::Max(0.0, ([double]$st.SentBytes - $prevTx) / 1KB / $dt)
                    }
                }
                $prevRx = [double]$st.ReceivedBytes; $prevTx = [double]$st.SentBytes; $prevT = $now; $prevAdapter = $ad.Name
                $mbps = $null
                if ($ad.LinkSpeed -match '^\s*([0-9.,]+)\s*(Gbps|Mbps|Kbps|bps)') {
                    $v = [double]($Matches[1] -replace ',', '.')
                    switch ($Matches[2]) { 'Gbps' { $v = $v * 1000 } 'Kbps' { $v = $v / 1000 } 'bps' { $v = $v / 1000000 } }
                    $mbps = [Math]::Round($v)
                }
                $net = [ordered]@{ adapter = [string]$ad.Name; linkMbps = $mbps; rxKBs = [Math]::Round($rxKB, 1); txKBs = [Math]::Round($txKB, 1) }
            }
        } catch { $net = $null }

        # --- Top-3-Prozesse nach CPU ---
        $top = $null
        try {
            # CPU-Zeit-Differenzen aus Get-Process: deutlich günstiger als die WMI-Klasse PerfProc_Process,
            # die bei jedem Abruf fast einen ganzen Kern belegt hat
            $nowCpu = @{}; $nowTime = Get-Date
            foreach ($pr in @(Get-Process -ErrorAction SilentlyContinue)) { if ($null -ne $pr.CPU) { $nowCpu[$pr.Id] = @($pr.ProcessName, [double]$pr.CPU) } }
            if ($prevCpu) {
                $secs = ($nowTime - $prevTime).TotalSeconds
                $sum = @{}
                foreach ($k in $nowCpu.Keys) {
                    if (-not $prevCpu.ContainsKey($k)) { continue }
                    $d = $nowCpu[$k][1] - $prevCpu[$k][1]
                    if ($d -le 0) { continue }
                    $n = $nowCpu[$k][0]
                    if (-not $sum.ContainsKey($n)) { $sum[$n] = 0.0 }
                    $sum[$n] += $d
                }
                $top = @($sum.GetEnumerator() | Sort-Object { $_.Value } -Descending | Select-Object -First 3 |
                        ForEach-Object { [ordered]@{ name = [string]$_.Key; cpu = [Math]::Round(100 * [double]$_.Value / $secs / $cpuCount, 1) } })
            }
            $prevCpu = $nowCpu; $prevTime = $nowTime
        } catch { $top = $null }

        # --- Laufwerke (Typ einmal ermitteln und cachen) ---
        $drives = $null
        try {
            if ($null -eq $driveTypes) { $driveTypes = @{} }   # Typen werden nach dem ersten Schnappschuss nachgeladen
            $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
                    $sz = [double]$_.Size; $fr = [double]$_.FreeSpace
                    $ty = $driveTypes[[string]$_.DeviceID]; if (-not $ty) { $ty = '?' }
                    $pct = 0; if ($sz -gt 0) { $pct = [int][Math]::Round(100 * $fr / $sz) }
                    [ordered]@{ letter = [string]$_.DeviceID; label = [string]$_.VolumeName; type = $ty; freePct = $pct
                        freeGB = [Math]::Round($fr / 1GB, 1); sizeGB = [Math]::Round($sz / 1GB, 1) }
                })
        } catch { $drives = $null }

        # --- Verlauf (Ringpuffer, 30 Werte = 60 s) ---
        if ($null -ne $cpu) { $histCpu.Add($cpu); if ($histCpu.Count -gt 30) { $histCpu.RemoveAt(0) } }
        if ($null -ne $ram) { $histRam.Add([double]$ram.usedPct); if ($histRam.Count -gt 30) { $histRam.RemoveAt(0) } }
        if ($null -ne $gpu) { $histGpu.Add([double]$gpu.util); if ($histGpu.Count -gt 30) { $histGpu.RemoveAt(0) } }

        $State.Snap = [ordered]@{
            stand  = $t0.ToString('yyyy-MM-ddTHH:mm:ss')
            cpu    = $cpu
            ram    = $ram
            gpu    = $gpu
            net    = $net
            top    = $top
            drives = $drives
            verlauf = [ordered]@{ cpu = [double[]]$histCpu.ToArray(); ram = [double[]]$histRam.ToArray(); gpu = [double[]]$histGpu.ToArray() }
        }

        # Laufwerkstypen einmalig nachladen (langsam, deshalb erst nach dem ersten Schnappschuss) und danach cachen
        if (-not $typesDone) {
            $typesDone = $true
            try {
                $pds = @(Get-PhysicalDisk -ErrorAction Stop)
                foreach ($part in @(Get-Partition -ErrorAction Stop | Where-Object { $_.DriveLetter })) {
                    $pd = $pds | Where-Object { [string]$_.DeviceId -eq [string]$part.DiskNumber } | Select-Object -First 1
                    $ty = '?'
                    if ($pd) { if ($pd.MediaType -eq 'SSD') { $ty = 'SSD' } elseif ($pd.MediaType -eq 'HDD') { $ty = 'HDD' } }
                    $driveTypes[([string]$part.DriveLetter).ToUpperInvariant() + ':'] = $ty
                }
            } catch { }
        }

        # 2 s Takt (abzüglich Sammeldauer), in kleinen Schritten, damit Stop schnell greift
        $wait = 2000 - [int](([datetime]::Now) - $t0).TotalMilliseconds
        while (($wait -gt 0) -and (-not $State.Stop)) { $s = [Math]::Min(250, $wait); Start-Sleep -Milliseconds $s; $wait -= $s }
    }
}

function Start-GuiLive {
    # Startet den Sammel-Runspace (schläft, bis /api/live abgefragt wird).
    $state = [hashtable]::Synchronized(@{ Snap = $null; LastRequest = [datetime]::MinValue; Stop = $false })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:GuiLiveScript.ToString()).AddArgument($state)
    $handle = $ps.BeginInvoke()
    $script:Gui.Live = @{ State = $state; Runspace = $rs; PS = $ps; Handle = $handle }
}

function Stop-GuiLive {
    # Beendet den Runspace sauber und gibt ihn frei.
    $l = $script:Gui.Live
    if (-not $l) { return }
    $script:Gui.Live = $null
    try { $l.State.Stop = $true } catch { }
    try { [void]$l.Handle.AsyncWaitHandle.WaitOne(3000) } catch { }
    try { $l.PS.Stop() } catch { }
    try { $l.PS.Dispose() } catch { }
    try { $l.Runspace.Close(); $l.Runspace.Dispose() } catch { }
}

#endregion

#region Anfragen

function Send-GuiStatic {
    param($Res, [string]$RelPath)
    $guiDir = [IO.Path]::GetFullPath((Join-Path $script:Gui.Root 'gui')).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $guiDir $RelPath))
    if ((-not $full.StartsWith($guiDir, [StringComparison]::OrdinalIgnoreCase)) -or (-not (Test-Path -LiteralPath $full -PathType Leaf))) {
        Stop-GuiRequest 404 'Nicht gefunden.'
    }
    $types = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
        '.json' = 'application/json; charset=utf-8'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon' }
    $ct = $types[[IO.Path]::GetExtension($full).ToLowerInvariant()]
    if (-not $ct) { $ct = 'application/octet-stream' }
    Send-GuiBytes $Res 200 $ct ([IO.File]::ReadAllBytes($full))
}

function Invoke-GuiScanStart {
    param($Body)
    Assert-GuiWritable
    $profil = 'Auto'
    $p = Get-GuiProp $Body 'profil'
    if ($null -ne $p) {
        $match = @('Auto', 'Gaming', 'Office', 'Laptop') | Where-Object { ($p -is [string]) -and ($_ -ieq $p) }
        if (-not $match) { Stop-GuiRequest 400 'Unbekanntes Profil. Erlaubt: Auto, Gaming, Office, Laptop.' }
        $profil = [string]$match
    }
    $days = 14
    $d = Get-GuiProp $Body 'eventDays'
    if ($null -ne $d) {
        if (-not (($d -is [int]) -or ($d -is [long]) -or ($d -is [double]))) { Stop-GuiRequest 400 'eventDays muss eine Zahl von 1 bis 90 sein.' }
        if (($d -ne [Math]::Floor($d)) -or ($d -lt 1) -or ($d -gt 90)) { Stop-GuiRequest 400 'eventDays muss eine ganze Zahl von 1 bis 90 sein.' }
        $days = [int]$d
    }
    $flags = @{}
    foreach ($n in 'skipWinget', 'skipUpdateSearch') {
        $v = Get-GuiProp $Body $n
        if ($null -eq $v) { $flags[$n] = $false }
        elseif ($v -is [bool]) { $flags[$n] = $v }
        else { Stop-GuiRequest 400 "$n muss true oder false sein." }
    }
    if (@($script:Gui.Jobs.Values | Where-Object { ($_.Status -eq 'running') -and ($_.Art -eq 'scan') }).Count -gt 0) {
        Stop-GuiRequest 409 'Es läuft bereits ein Scan.'
    }
    # Berichte und Akzeptanzliste liegen im Datenordner, nicht neben dem Code
    $a = @('-NoUpdatePrompt', '-NoOpen', '-Profil', $profil, '-EventDays', [string]$days,
        '-OutputDir', (Join-Path $script:Gui.DataRoot 'reports'), '-AcceptedFile', (Join-Path $script:Gui.DataRoot 'accepted.psd1'))
    if ($flags['skipWinget']) { $a += '-SkipWinget' }
    if ($flags['skipUpdateSearch']) { $a += '-SkipUpdateSearch' }
    return (Start-GuiJob 'scan' @($script:Gui.Root, [string[]]$a, $script:Gui.DataRoot) $false)
}

function Invoke-GuiActionRun {
    param($Body)
    Assert-GuiWritable
    Assert-GuiFn 'Get-PcCheckCatalog', 'Invoke-PcCheckChange'
    $rawIds = Get-GuiProp $Body 'ids'
    if ($null -eq $rawIds) { Stop-GuiRequest 400 'ids fehlt.' }
    $ids = @($rawIds)
    if ($ids.Count -eq 0) { Stop-GuiRequest 400 'ids ist leer.' }
    $clean = New-Object System.Collections.Generic.List[string]
    foreach ($i in $ids) {
        if (($i -isnot [string]) -or ($i -cnotmatch '^[a-z0-9.-]{1,80}\z')) { Stop-GuiRequest 400 'Ungültige Aktions-ID.' }
        $act = $script:Gui.Catalog | Where-Object { $_.Id -ceq $i } | Select-Object -First 1
        if (-not $act) { Stop-GuiRequest 400 "Unbekannte Aktions-ID: $i" }
        if (-not $clean.Contains($i)) { $clean.Add($i) }
    }
    $variante = $null
    $v = Get-GuiProp $Body 'variante'
    if (($null -ne $v) -and ("$v" -ne '')) {
        if ($v -isnot [string]) { Stop-GuiRequest 400 'Ungültige Variante.' }
        if ($clean.Count -ne 1) { Stop-GuiRequest 400 'Eine Variante ist nur bei genau einer Aktion möglich.' }
        $act = $script:Gui.Catalog | Where-Object { $_.Id -ceq $clean[0] } | Select-Object -First 1
        if (-not (@($act.Varianten) -ccontains $v)) { Stop-GuiRequest 400 'Unbekannte Variante.' }
        $variante = $v
    }
    if ((Get-GuiRunningJobs -MutatingOnly).Count -gt 0) { Stop-GuiRequest 409 'Es läuft bereits eine Änderung.' }
    $lines = foreach ($cid in $clean) {
        $a = $script:Gui.Catalog | Where-Object { $_.Id -ceq $cid } | Select-Object -First 1
        $t = '• ' + [string]$a.Titel
        if ($variante) { $t += " ($variante)" }
        if ($a.Neustart -eq $true) { $t += ' – Neustart nötig' }
        $t
    }
    $text = "Folgende Änderung(en) mit Administratorrechten ausführen?`n`n" + ($lines -join "`n") +
        "`n`nVorher wird ein Wiederherstellungspunkt angelegt. Jede Änderung lässt sich unter 'Änderungen' zurücknehmen." +
        "`n`nHast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'."
    return (Start-GuiJob 'run' @($script:Gui.Root, $script:Gui.SafetyPath, [string[]]$clean.ToArray(), $variante, $script:Gui.DataRoot) $true $text)
}

function Invoke-GuiRoute {
    param($Req, $Res, [string]$Method, [string]$Path)
    $g = $script:Gui

    # --- statische Dateien (ohne Token) ---
    if (($Path -notlike '/api/*') -and ($Path -notlike '/report/*')) {
        if ($Method -ne 'GET') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        if (($Path -eq '/') -or ($Path -eq '/index.html')) { Send-GuiStatic $Res 'index.html'; return }
        if ($Path -in '/app.js', '/app.css') { Send-GuiStatic $Res $Path.TrimStart('/'); return }
        # Bilder: nur feste Namensform aus gui\assets\ (Regex + Präfix-Prüfung in Send-GuiStatic), ohne Token (keine Daten)
        if ($Path -cmatch '^/assets/([a-z0-9-]+\.(png|svg))\z') { Send-GuiStatic $Res ('assets\' + $Matches[1]); return }
        if ($Path -eq '/favicon.ico') { Send-GuiStatic $Res 'assets\morpheus-icon.png'; return }
        if ($Path -cmatch '^/dev/[A-Za-z0-9._-]+\z') { Send-GuiStatic $Res $Path.TrimStart('/'); return }
        Stop-GuiRequest 404 'Nicht gefunden.'
    }

    # --- Einmal-Code gegen Token tauschen (ohne Token) ---
    # Edge bekommt nur diesen Code in der Befehlszeile (für alle Benutzerprozesse lesbar), nie das Token.
    # Jeder Versuch verbraucht den Code: Wer mitliest und zuerst tauscht, lässt die GUI sichtbar scheitern.
    if ($Path -eq '/api/session/claim') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        if ([string]$Req.ContentType -notmatch '^\s*application/json\s*(;|\z)') { Stop-GuiRequest 415 'Content-Type muss application/json sein.' }
        $code = Get-GuiProp (Read-GuiBody $Req) 'code'
        $ok = ($null -ne $g.BootCode) -and ((Get-Date) -lt $g.BootExpires) -and ($code -is [string]) -and (Test-GuiTokenEqual $code $g.BootCode)
        $g.BootCode = $null
        if (-not $ok) {
            Write-GuiLog 'WARNUNG: Startcode ungültig oder bereits verbraucht.'
            Stop-GuiRequest 403 'Der Startcode ist ungültig oder wurde bereits verwendet. Bitte die GUI neu starten.'
        }
        Send-GuiJson $Res 200 ([ordered]@{ token = $g.Token })
        return
    }

    # --- Berichte als HTML (iframe) mit einmaliger Lesemarke statt Token ---
    # Das Script im Bericht kann seine eigene Adresse lesen; dort darf deshalb nie das Token stehen.
    if ($Path -cmatch '^/report/([^/]+)\z') {
        if ($Method -ne 'GET') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $name = $Matches[1]
        $k = [string]$Req.QueryString['k']
        $t = $null
        if ($k -and $g.Tickets.ContainsKey($k)) { $t = $g.Tickets[$k]; $g.Tickets.Remove($k) }
        if ((-not $t) -or ($t.Name -cne $name) -or ((Get-Date) -gt $t.Expires)) { Stop-GuiRequest 401 'Lesemarke fehlt, ist abgelaufen oder wurde schon benutzt.' }
        $full = Resolve-GuiReportPath $name 'html'
        if (-not $full) { Stop-GuiRequest 404 'Bericht nicht gefunden.' }
        Send-GuiBytes $Res 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($full)) $script:GuiReportCsp
        return
    }

    # --- Token (Abschnitt 4.3) ---
    $tok = $Req.Headers['X-PcCheck-Token']
    if ((-not $tok) -or (-not (Test-GuiTokenEqual $tok $g.Token))) { Stop-GuiRequest 401 'Token fehlt oder ist ungültig.' }

    # --- POST nur mit JSON ---
    $body = $null
    if ($Method -eq 'POST') {
        $ct = [string]$Req.ContentType
        if ($ct -notmatch '^\s*application/json\s*(;|\z)') { Stop-GuiRequest 415 'Content-Type muss application/json sein.' }
        $body = Read-GuiBody $Req
    }

    $isGet = ($Method -eq 'GET')

    if ($Path -eq '/api/session') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $safety = $null
        if (Test-GuiFn 'Get-PcCheckSafetyStatus') { try { $safety = Get-PcCheckSafetyStatus -Root $g.Root -DataRoot $g.DataRoot } catch { Write-GuiLog ('Safety-Status: ' + $_.Exception.Message) } }
        $profil = $null
        $rl = @(Get-GuiReportList)
        if ($rl.Count -gt 0) { $profil = $rl[0].profil }
        Send-GuiJson $Res 200 ([ordered]@{ version = $g.Version; pc = $env:COMPUTERNAME; admin = $g.Admin; profil = $profil; safety = $safety
                readOnly = [bool]$g.ReadOnly; readOnlyReason = $(if ($g.ReadOnly) { [string]$g.ReadOnlyReason } else { $null }); dataRoot = $g.DataRoot })
        return
    }
    if ($Path -eq '/api/report-ticket') {
        # Einmalige Lesemarke (60 s) für genau einen Original-Bericht im iframe
        if ($isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $name = Get-GuiProp $body 'name'
        if (($name -isnot [string]) -or (-not (Resolve-GuiReportPath $name 'html'))) { Stop-GuiRequest 404 'Bericht nicht gefunden.' }
        $now = Get-Date
        foreach ($key in @($g.Tickets.Keys)) { if ($g.Tickets[$key].Expires -lt $now) { $g.Tickets.Remove($key) } }
        $k = New-GuiSecret
        $g.Tickets[$k] = @{ Name = $name; Expires = $now.AddSeconds(60) }
        Send-GuiJson $Res 200 ([ordered]@{ ticket = $k })
        return
    }
    if ($Path -eq '/api/reports') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Send-GuiJson $Res 200 @(Get-GuiReportList)
        return
    }
    if ($Path -cmatch '^/api/reports/([^/]+)\z') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $full = Resolve-GuiReportPath $Matches[1] 'json'
        if (-not $full) { Stop-GuiRequest 404 'Bericht nicht gefunden.' }
        $bytes = [IO.File]::ReadAllBytes($full)
        if (($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)) { $bytes = $bytes[3..($bytes.Length - 1)] }
        Send-GuiBytes $Res 200 'application/json; charset=utf-8' $bytes
        return
    }
    if ($Path -eq '/api/help') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Send-GuiJson $Res 200 (Get-GuiHelp)
        return
    }
    if ($Path -eq '/api/actions') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiFn 'Get-PcCheckCatalog', 'ConvertTo-PublicAction'
        $st = $g.ActionStates
        $list = @(foreach ($a in $g.Catalog) { $s = $null; if ($st) { $s = $st[$a.Id] }; ConvertTo-PublicAction -Action $a -State $s })
        Send-GuiJson $Res 200 $list
        return
    }
    if ($Path -eq '/api/actions/refresh') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiFn 'Get-PcCheckCatalog', 'Get-PcCheckActionStates'
        $running = @($g.Jobs.Values | Where-Object { ($_.Status -eq 'running') -and ($_.Art -eq 'refresh') })
        if ($running.Count -gt 0) { Send-GuiJson $Res 200 ([ordered]@{ jobId = $running[0].Id }); return }
        $id = Start-GuiJob 'refresh' @($g.Root, $g.SafetyPath) $false
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -eq '/api/actions/run') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $id = Invoke-GuiActionRun $body
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -cmatch '^/api/journal/([^/]+)/undo\z') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiWritable
        Assert-GuiFn 'Get-PcCheckJournal', 'Undo-PcCheckChange'
        $eid = $Matches[1]
        if ($eid -cnotmatch '^[A-Za-z0-9-]{1,40}\z') { Stop-GuiRequest 400 'Ungültige Journal-ID.' }
        $entry = @(Get-PcCheckJournal -Root $g.Root -DataRoot $g.DataRoot) | Where-Object { [string]$_.id -ceq $eid } | Select-Object -First 1
        if (-not $entry) { Stop-GuiRequest 404 'Journal-Eintrag nicht gefunden.' }
        $force = $false
        $f = Get-GuiProp $body 'force'
        if ($null -ne $f) { if ($f -is [bool]) { $force = $f } else { Stop-GuiRequest 400 'force muss true oder false sein.' } }
        if ((Get-GuiRunningJobs -MutatingOnly).Count -gt 0) { Stop-GuiRequest 409 'Es läuft bereits eine Änderung.' }
        $text = "Diese Änderung mit Administratorrechten zurücknehmen?`n`n• " + [string]$entry.titel + ' (vom ' + ([string]$entry.zeit).Replace('T', ' ') + ')' +
            $(if ($force) { "`n`nAchtung: Der Zustand wurde inzwischen anders geändert; auch diese spätere Änderung wird überschrieben." } else { '' }) +
            "`n`nVorher wird ein Wiederherstellungspunkt angelegt.`n`nHast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'."
        $id = Start-GuiJob 'undo' @($g.Root, $g.SafetyPath, $eid, $force, $g.DataRoot) $true $text
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -eq '/api/journal') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiFn 'Get-PcCheckJournal'
        Send-GuiJson $Res 200 @(Get-PcCheckJournal -Root $g.Root -DataRoot $g.DataRoot)
        return
    }
    if ($Path -eq '/api/restorepoints') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Assert-GuiFn 'Get-PcCheckRestorePoints'
        Send-GuiJson $Res 200 @(Get-PcCheckRestorePoints)
        return
    }
    if ($Path -eq '/api/scan') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $id = Invoke-GuiScanStart $body
        Send-GuiJson $Res 200 ([ordered]@{ jobId = $id })
        return
    }
    if ($Path -cmatch '^/api/jobs/([^/]+)\z') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        Update-GuiJobs
        $rec = $g.Jobs[$Matches[1]]
        if (-not $rec) { Stop-GuiRequest 404 'Job nicht gefunden (oder älter als 30 Minuten).' }
        $from = 0
        $fq = $Req.QueryString['from']
        if ($fq -and ($fq -cmatch '^[0-9]{1,9}\z')) { $from = [int]$fq }
        $total = $rec.Log.Count
        if ($from -gt $total) { $from = $total }
        $lines = @()
        if ($total -gt $from) { $lines = @($rec.Log.GetRange($from, $total - $from)) }
        $erg = $null
        if ($rec.Status -ne 'running') { $erg = $rec.Ergebnis }
        Send-GuiJson $Res 200 ([ordered]@{ id = $rec.Id; art = $rec.Art; status = $rec.Status; log = $lines; next = $total; ergebnis = $erg })
        return
    }
    if ($Path -eq '/api/checklist') {
        $cp = Join-Path $g.DataRoot 'state\checklist.json'
        if ($isGet) {
            $text = '{}'
            if (Test-Path -LiteralPath $cp -PathType Leaf) { $text = [IO.File]::ReadAllText($cp, [Text.Encoding]::UTF8); if ([string]::IsNullOrWhiteSpace($text)) { $text = '{}' } }
            Send-GuiBytes $Res 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($text))
            return
        }
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        if (($body -isnot [pscustomobject]) -or (@($body.PSObject.Properties).Count -gt 500)) { Stop-GuiRequest 400 'Die Checkliste muss ein Objekt sein.' }
        $clean = [ordered]@{}
        foreach ($p in $body.PSObject.Properties) {
            $key = [string]$p.Name
            if (($key.Length -eq 0) -or ($key.Length -gt 200) -or ($key -match '[\x00-\x1f]')) { Stop-GuiRequest 400 'Ungültiger Name in der Checkliste.' }
            $e = $p.Value
            $state = Get-GuiProp $e 'state'
            if (($e -isnot [pscustomobject]) -or (@('done', 'later') -cnotcontains $state)) { Stop-GuiRequest 400 "Ungültiger Eintrag: $key (state muss done oder later sein)." }
            $date = Get-GuiProp $e 'date'; $rep = Get-GuiProp $e 'report'
            if ((($null -ne $date) -and ($date -isnot [string])) -or (($null -ne $rep) -and ($rep -isnot [string]))) { Stop-GuiRequest 400 "Ungültiger Eintrag: $key" }
            if ((([string]$date).Length -gt 64) -or (([string]$rep).Length -gt 200)) { Stop-GuiRequest 400 "Eintrag zu lang: $key" }
            $clean[$key] = [ordered]@{ state = [string]$state; date = [string]$date; report = [string]$rep }
        }
        $json = ConvertTo-Json -InputObject $clean -Depth 4 -Compress
        Save-GuiTextAtomic $cp $json
        Send-GuiBytes $Res 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
        return
    }
    if ($Path -eq '/api/live') {
        if (-not $isGet) { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        # Abruf weckt den Sammel-Runspace; geantwortet wird sofort mit dem letzten Schnappschuss
        $snap = $null
        if ($g.Live) { $g.Live.State.LastRequest = [datetime]::Now; $snap = $g.Live.State.Snap }
        if ($null -eq $snap) { $snap = [ordered]@{ stand = $null } }
        Send-GuiJson $Res 200 $snap
        return
    }
    if ($Path -eq '/api/heartbeat') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $g.LastHeartbeat = Get-Date; $g.HeartbeatSeen = $true
        Send-GuiJson $Res 200 ([ordered]@{ ok = $true })
        return
    }
    if ($Path -eq '/api/shutdown') {
        if ($Method -ne 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }
        $g.Stop = $true
        Send-GuiJson $Res 200 ([ordered]@{ ok = $true })
        return
    }
    Stop-GuiRequest 404 'Nicht gefunden.'
}

function Invoke-GuiRequest {
    # Behandelt genau eine Anfrage. Jeder Fehler wird zu einer JSON-Antwort, nie zum Absturz.
    param($Ctx)
    $req = $Ctx.Request; $res = $Ctx.Response
    $g = $script:Gui
    $g.Status = 0
    $method = '?'; $logPath = '?'
    try {
        $method = [string]$req.HttpMethod
        $raw = [string]$req.RawUrl
        $q = $raw.IndexOf('?')
        $rawPath = $raw; if ($q -ge 0) { $rawPath = $raw.Substring(0, $q) }
        $logPath = (($rawPath -replace '[\x00-\x1f]', '?'))
        if ($logPath.Length -gt 200) { $logPath = $logPath.Substring(0, 200) }

        # 2. Host-Prüfung gegen DNS-Rebinding
        if ([string]$req.Headers['Host'] -cne $g.HostHeader) { Stop-GuiRequest 403 'Ungültiger Host.' }
        # 4. Origin
        $origin = $req.Headers['Origin']
        if (($null -ne $origin) -and ($origin -cne $g.Origin)) { Stop-GuiRequest 403 'Ungültiger Origin.' }
        # Methoden: OPTIONS und alles außer GET/POST -> 405, nie CORS-Header
        if ($method -notin 'GET', 'POST') { Stop-GuiRequest 405 'Methode nicht erlaubt.' }

        try { $path = [Uri]::UnescapeDataString($rawPath) } catch { Stop-GuiRequest 400 'Ungültiger Pfad.' }
        if (($path -notmatch '^/') -or ($path -match '[\x00-\x1f\\]') -or (($path -split '/') -contains '..') -or (($path -split '/') -contains '.')) {
            Stop-GuiRequest 403 'Ungültiger Pfad.'
        }
        Invoke-GuiRoute $req $res $method $path
    }
    catch {
        $st = 500; $msg = 'Interner Fehler im Server.'
        if ($_.Exception.Data.Contains('status')) { $st = [int]$_.Exception.Data['status']; $msg = $_.Exception.Message }
        else { Write-GuiLog ("FEHLER bei {0} {1}: {2}" -f $method, $logPath, $_.Exception.Message) }
        try { Send-GuiJson $res $st ([ordered]@{ error = $msg }) } catch { }
    }
    finally {
        try { $res.Close() } catch { }
        Write-GuiLog ("{0} {1} {2}" -f $method, $logPath, $g.Status)
    }
}

#endregion

#region Start und Hauptschleife

function Initialize-GuiServer {
    # Root = Codeordner (Katalog, Hilfe, Oberfläche), DataRoot = Daten (reports, changes, state, accepted.psd1; Standard: Root).
    # ReadOnly: Ändern, Rückgängig und Scan sind gesperrt (403), weil der Codeordner nicht gesichert ist.
    param([string]$Root, [int]$Port, [string]$Token, [string]$BootCode, [string]$SafetyPath,
        [string]$DataRoot, [switch]$ReadOnly, [string]$ReadOnlyReason)
    if (-not $DataRoot) { $DataRoot = $Root }
    Add-Type -AssemblyName System.Web.Extensions
    $version = ''
    try {
        $m = [regex]::Match([IO.File]::ReadAllText((Join-Path $Root 'pc-check.ps1')), '\$ScriptVersion\s*=\s*''([^'']+)''')
        if ($m.Success) { $version = $m.Groups[1].Value }
    }
    catch { }
    $script:Gui = @{
        Root = $Root; DataRoot = $DataRoot; ReadOnly = [bool]$ReadOnly; ReadOnlyReason = $ReadOnlyReason
        Port = $Port; Token = $Token; SafetyPath = $SafetyPath
        BootCode = $BootCode; BootExpires = (Get-Date).AddMinutes(2); Tickets = @{}
        Origin = "http://127.0.0.1:$Port"; HostHeader = "127.0.0.1:$Port"
        Admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Version = $version
        Jobs = @{}; ReportCache = @{}; HelpCache = $null; ActionStates = @{}; Catalog = @()
        Stop = $false; Status = 0; LastHeartbeat = Get-Date; HeartbeatSeen = $false; Listener = $null; Live = $null
    }
    try { Start-GuiLive } catch { Write-GuiLog ('Live-Runspace nicht startbar: ' + $_.Exception.Message) }
    if (Test-GuiFn 'Get-PcCheckCatalog') {
        try { $script:Gui.Catalog = @(Get-PcCheckCatalog -Root $Root) }
        catch { Write-GuiLog ('Katalog nicht ladbar: ' + $_.Exception.Message) }
    }
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://127.0.0.1:$Port/")
    $l.Start()
    $script:Gui.Listener = $l
    Write-GuiLog "Server gestartet auf Port $Port (Admin: $($script:Gui.Admin), NurLesen: $($script:Gui.ReadOnly), Daten: $DataRoot, Katalog: $($script:Gui.Catalog.Count) Aktionen, Safety: $(Test-GuiFn 'Invoke-PcCheckChange'))"
}

function Start-GuiServerLoop {
    # EdgeProfile: --user-data-dir des App-Fensters oder $null. Gibt den Grund des Endes zurück.
    # Edge startet sich ohne Adminrechte neu, der gestartete Prozess endet also sofort. Deshalb zählen
    # alle msedge-Prozesse mit diesem Profil: Waren welche da und sind alle weg, ist das Fenster zu.
    param([string]$EdgeProfile, [int]$HeartbeatTimeoutSec = 45)
    $g = $script:Gui
    $edgeStart = Get-Date
    $edgeSeen = $false
    $edgeCheck = [datetime]::MinValue
    $reason = ''
    $task = $null
    while (-not $g.Stop) {
        try {
            if ($null -eq $task) { $task = $g.Listener.GetContextAsync() }
            if ($task.Wait(500)) {
                $ctx = $task.Result; $task = $null
                Invoke-GuiRequest $ctx
            }
        }
        catch {
            $task = $null
            Write-GuiLog ('Schleife: ' + $_.Exception.Message)
            Start-Sleep -Milliseconds 200
        }
        try { Update-GuiJobs } catch { Write-GuiLog ('Update-GuiJobs: ' + $_.Exception.Message) }

        if ($g.Stop) { $reason = 'Beenden angefordert'; break }
        $busy = (Get-GuiRunningJobs).Count -gt 0
        # Edge-Ende: alle 3 s die Prozesse mit unserem Profil zählen
        if ($EdgeProfile -and (((Get-Date) - $edgeCheck).TotalSeconds -ge 3)) {
            $edgeCheck = Get-Date
            $count = -1
            try {
                $count = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
                        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($EdgeProfile, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count
            } catch { }
            if ($count -gt 0) { $edgeSeen = $true }
            elseif (($count -eq 0) -and $edgeSeen -and (-not $busy)) { $reason = 'Fenster geschlossen'; break }
        }
        # Heartbeat: ohne Browser-Start erst nach dem ersten Heartbeat, und nie während Jobs laufen
        if ((-not $busy) -and ($g.HeartbeatSeen -or $EdgeProfile) -and (((Get-Date) - $g.LastHeartbeat).TotalSeconds -gt $HeartbeatTimeoutSec)) {
            $reason = 'Kein Heartbeat mehr'; break
        }
    }
    if (-not $reason) { $reason = 'Beenden angefordert' }

    # laufende Jobs abwarten
    $warned = $false
    while ((Get-GuiRunningJobs).Count -gt 0) {
        if (-not $warned) { Write-Host ("Warte auf {0} laufende(n) Job(s) ..." -f (Get-GuiRunningJobs).Count); $warned = $true }
        Start-Sleep -Milliseconds 500
        Update-GuiJobs
    }
    try { $g.Listener.Stop(); $g.Listener.Close() } catch { }
    try { Stop-GuiLive } catch { }
    Write-GuiLog "Server beendet ($reason)"
    return $reason
}

#endregion
