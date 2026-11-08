#Requires -Version 5.1
<#
.SYNOPSIS
    Absicherung von Änderungen für die pc-check-GUI (T2): Wiederherstellungspunkt, Journal, Ausführen/Rückgängig.

.DESCRIPTION
    Wird per Dot-Source geladen (Server und jeder Job). Definiert die Funktionen aus
    docs/gui-architektur.md, Abschnitt 11. Regeln:
    - Vor jeder Änderung muss ein geprüfter Wiederherstellungspunkt existieren, sonst wird nichts geändert.
    - Jede Änderung steht vor dem Ausführen im Journal (changes\journal.json) und ist zurücknehmbar.
    - Fortschritt nur über Write-Information, einzige Pipeline-Ausgabe ist das Ergebnis.
    - Der Wiederherstellungspunkt wird nur über $script:PcCheckRestorePointImpl /
      $script:PcCheckRestorePointListImpl angelegt bzw. gelesen (Tests ersetzen beide).
#>

$script:PcCheckSafetyDir = $PSScriptRoot
# Texte (2.6, #66): T und die Katalogtexte aus lang\<sprache>\aktionen.psd1; auch die Katalog-Scriptblöcke nutzen T,
# weil sie nur dort laufen, wo diese Datei geladen ist (Server und Jobs)
. (Join-Path $PSScriptRoot 'Sprache.ps1')

# Standard-Implementierungen (Tests ersetzen sie)
$script:PcCheckRestorePointImpl = {
    param($Description)
    Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
}
$script:PcCheckRestorePointListImpl = {
    Get-ComputerRestorePoint -ErrorAction Stop
}
# So lange (Sekunden) wird nach dem Anlegen auf den Punkt gewartet, bevor er als fehlend gilt
$script:PcCheckRestorePointWaitSeconds = 6
# Letzter Windows-Start (ändert sich nicht, solange der Prozess läuft; einmal gelesen). Tests ersetzen den Block.
$script:PcCheckBootTimeImpl = {
    if (-not $script:PcCheckBootTimeCache) {
        try { $script:PcCheckBootTimeCache = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { return $null }
    }
    $script:PcCheckBootTimeCache
}

$script:PcCheckSafetyRegRestore = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$script:PcCheckSafetyRegPolicy = 'SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'

#region Hilfsfunktionen (privat)

function PcCheckSafetyLog {
    param([string]$Text)
    Write-Information -MessageData ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text) -InformationAction Continue
}

function PcCheckSafetyDefaultRoot {
    Split-Path -Parent (Split-Path -Parent $script:PcCheckSafetyDir)
}

function PcCheckSafetyIso {
    param($Date)
    if ($null -eq $Date) { return $null }
    ([datetime]$Date).ToString('s')
}

function PcCheckSafetyRegValue {
    param([string]$SubKey, [string]$Name)
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $key = $base.OpenSubKey($SubKey)
        if ($null -eq $key) { return $null }
        try { return $key.GetValue($Name, $null) } finally { $key.Close() }
    } catch { return $null }
}

function PcCheckSafetyIsAdmin {
    try {
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

# Vergleichsschlüssel für Zustände: JSON-normalisiert, $null bleibt 'null'
function PcCheckSafetyStateKey {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    $json = ConvertTo-Json -InputObject $Value -Depth 10 -Compress
    if ($json -eq '[]') { return '[]' }
    $obj = ConvertFrom-Json -InputObject $json
    if ($null -eq $obj) { return 'null' }
    ConvertTo-Json -InputObject $obj -Depth 10 -Compress
}

# Liest den Zustand einer Aktion (Lesen) und normiert ihn
function PcCheckSafetyReadState {
    param($Action)
    $raw = @(& $Action.Lesen) | Select-Object -Last 1
    if ($null -eq $raw) { throw (T 'server.safety.keinErgebnis') }
    [pscustomobject]@{
        aktiv   = ($raw.Aktiv -eq $true)
        wert    = $raw.Wert
        zustand = $raw.Zustand
        stand   = (Get-Date).ToString('s')
    }
}

# Zustand in der Form, wie sie ins Journal und ins Ergebnis kommt
function PcCheckSafetyJournalState {
    param($State)
    if ($null -eq $State) { return $null }
    [ordered]@{ aktiv = [bool]$State.aktiv; wert = $State.wert; zustand = $State.zustand }
}

# Form eines JSON-Werts: null | scalar | array | object (Eingabe: JavaScriptSerializer-Ergebnis)
function PcCheckSafetyJsonKind {
    param($V)
    if ($null -eq $V) { return 'null' }
    if ($V -is [System.Collections.IDictionary]) { return 'object' }
    if (($V -isnot [string]) -and ($V -is [System.Collections.IEnumerable])) { return 'array' }
    'scalar'
}

# Vergleicht Eigenschaftsnamen und Grundformen (Objekt/Liste/Einzelwert) rekursiv durch Objekte, nicht durch Listen
function PcCheckSafetyShapeDiff {
    param($Cur, $Saved, [string]$Path)
    $kc = PcCheckSafetyJsonKind $Cur
    $ks = PcCheckSafetyJsonKind $Saved
    if (($kc -eq 'null') -or ($ks -eq 'null')) { return $null }   # fehlender Wert ist erlaubt (Wert existierte nicht)
    if ($kc -ne $ks) { return (T 'server.safety.formErwartet' $Path $kc $ks) }
    if ($kc -ne 'object') { return $null }
    $nc = @($Cur.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    $ns = @($Saved.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    if ((($nc -join "`n")) -cne (($ns -join "`n"))) { return (T 'server.safety.formEigenschaften' $Path ($ns -join ',') ($nc -join ',')) }
    foreach ($k in $nc) {
        $d = PcCheckSafetyShapeDiff $Cur[$k] $Saved[$k] "$Path.$k"
        if ($d) { return $d }
    }
    $null
}

# Wirft, wenn der gespeicherte Vorher-Zustand nicht zur Form passt, die Lesen der Aktion liefert.
# Ist der aktuelle Zustand nicht vorhanden ($null), lässt sich nichts vergleichen; dann gilt der Eintrag als zulässig.
function PcCheckSafetyAssertStateShape {
    param($Current, $Saved)
    if (($null -eq $Current) -or ($null -eq $Saved)) { return }
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 100
    $c = $ser.DeserializeObject((ConvertTo-Json -InputObject $Current -Depth 10 -Compress))
    $s = $ser.DeserializeObject((ConvertTo-Json -InputObject $Saved -Depth 10 -Compress))
    $diff = PcCheckSafetyShapeDiff $c $s 'Zustand'
    if ($diff) { throw (T 'server.safety.journalPasstNicht' $diff) }
}

function PcCheckSafetyToDate {
    param($Value)
    if ($Value -is [datetime]) { return $Value }
    if ($null -eq $Value -or [string]$Value -eq '') { return $null }
    try { return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Value) } catch { }
    try { return [datetime]$Value } catch { return $null }
}

function PcCheckSafetyTypeName {
    param($Type)
    switch ([string]$Type) {
        '0'  { 'APPLICATION_INSTALL' }
        '1'  { 'APPLICATION_UNINSTALL' }
        '10' { 'DEVICE_DRIVER_INSTALL' }
        '12' { 'MODIFY_SETTINGS' }
        '13' { 'CANCELLED_OPERATION' }
        default { [string]$Type }
    }
}

# Wiederherstellungspunkte (nur über die ersetzbare Liste), neueste zuerst; wirft bei Lesefehler
function PcCheckSafetyListPoints {
    $raw = @(& $script:PcCheckRestorePointListImpl)
    $list = New-Object System.Collections.ArrayList
    foreach ($p in $raw) {
        if ($null -eq $p) { continue }
        $time = PcCheckSafetyToDate $p.CreationTime
        $seq = 0
        [void][int]::TryParse([string]$p.SequenceNumber, [ref]$seq)
        [void]$list.Add([pscustomobject]@{
                seq          = $seq
                zeit         = $time
                beschreibung = [string]$p.Description
                typ          = (PcCheckSafetyTypeName $p.RestorePointType)
            })
    }
    $sorted = @($list | Sort-Object -Property seq -Descending)
    $sorted
}

#region Journal

function PcCheckSafetyJournalPath {
    param([string]$Root)
    Join-Path (Join-Path $Root 'changes') 'journal.json'
}

# Journal in Dateireihenfolge (älteste zuerst); beschädigte Datei -> Fehler, nie überschreiben
function PcCheckSafetyReadJournal {
    param([string]$Root)
    $path = PcCheckSafetyJournalPath $Root
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    try {
        $obj = ConvertFrom-Json -InputObject $text
    } catch {
        throw (T 'server.safety.journalKaputt' $path $_.Exception.Message)
    }
    @($obj)
}

# Atomar schreiben: tmp-Datei, dann Replace (beim ersten Mal Move); UTF-8 ohne BOM
function PcCheckSafetyWriteJournal {
    param([string]$Root, $Entries)
    $path = PcCheckSafetyJournalPath $Root
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject @($Entries) -Depth 12
    $tmp = $path + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $path) {
        [IO.File]::Replace($tmp, $path, [NullString]::Value)
    } else {
        [IO.File]::Move($tmp, $path)
    }
}

function PcCheckSafetyNewEntryId {
    param([string]$Root)
    $used = @(PcCheckSafetyReadJournal $Root | ForEach-Object { [string]$_.id })
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $n = 1
    while ($used -contains ('{0}-{1:00}' -f $stamp, $n)) { $n++ }
    '{0}-{1:00}' -f $stamp, $n
}

function PcCheckSafetyAddEntry {
    param([string]$Root, $Entry)
    $all = New-Object System.Collections.ArrayList
    foreach ($e in @(PcCheckSafetyReadJournal $Root)) { [void]$all.Add($e) }
    [void]$all.Add($Entry)
    PcCheckSafetyWriteJournal $Root $all.ToArray()
}

function PcCheckSafetyUpdateEntry {
    param([string]$Root, [string]$Id, [hashtable]$Changes)
    $all = @(PcCheckSafetyReadJournal $Root)
    $found = $false
    foreach ($e in $all) {
        if ([string]$e.id -ceq $Id) {
            foreach ($k in $Changes.Keys) { $e.$k = $Changes[$k] }
            $found = $true
        }
    }
    if (-not $found) { throw (T 'server.safety.eintragFehlt' $Id) }
    PcCheckSafetyWriteJournal $Root $all
}

function PcCheckSafetyNewEntry {
    param($Id, $Art, $Action, $Variante, $Vorher, $Point, $Bezug)
    $var = $null
    if (-not [string]::IsNullOrEmpty($Variante)) { $var = [string]$Variante }
    [ordered]@{
        id                      = $Id
        zeit                    = (Get-Date).ToString('s')
        art                     = $Art
        aktion                  = [string]$Action.Id
        titel                   = [string]$Action.Titel
        variante                = $var
        vorher                  = $Vorher
        nachher                 = $null
        wiederherstellungspunkt = $Point
        status                  = 'begonnen'
        bezug                   = $Bezug
        meldung                 = ''
        benutzer                = $env:USERNAME
    }
}
#endregion

#region Wiederherstellungspunkt

function PcCheckSafetyCommandFrequency {
    "New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name SystemRestorePointCreationFrequency -PropertyType DWord -Value 0 -Force"
}

function PcCheckSafetyCommandEnable {
    $drive = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\'))
    if (-not $drive) { $drive = 'C:' }
    "Enable-ComputerRestore -Drive '$drive\'"
}

# Ursache für einen fehlenden Punkt und der Befehl zur Behebung
function PcCheckSafetyDiagnose {
    $causes = New-Object System.Collections.ArrayList
    $cmds = New-Object System.Collections.ArrayList
    if (-not (PcCheckSafetyIsAdmin)) {
        [void]$causes.Add((T 'server.safety.diagOhneAdmin'))
        [void]$cmds.Add((T 'server.safety.diagOhneAdminBefehl'))
    }
    $disable = PcCheckSafetyRegValue $script:PcCheckSafetyRegPolicy 'DisableSR'
    $interval = PcCheckSafetyRegValue $script:PcCheckSafetyRegRestore 'RPSessionInterval'
    if ($disable -eq 1) {
        [void]$causes.Add((T 'server.safety.ursachePolicy'))
        [void]$cmds.Add((T 'server.safety.behebungPolicy'))
    } elseif ($interval -ne 1) {
        [void]$causes.Add((T 'server.safety.diagSchutzAus'))
        [void]$cmds.Add((PcCheckSafetyCommandEnable))
    }
    $freq = PcCheckSafetyRegValue $script:PcCheckSafetyRegRestore 'SystemRestorePointCreationFrequency'
    if (($null -eq $freq) -or ([int64]$freq -gt 0)) {
        [void]$causes.Add((T 'server.safety.diagSperre24h'))
        [void]$cmds.Add((PcCheckSafetyCommandFrequency))
    }
    if ($causes.Count -eq 0) { [void]$causes.Add((T 'server.safety.diagUnklar')) }
    @{ ursache = ($causes -join ' '); befehl = ($cmds -join "`n") }
}

# Legt einen Punkt an und prüft ihn; wirft, wenn er fehlt. Rückgabe @{ seq; zeit }
function PcCheckSafetyEnsureRestorePoint {
    param([string]$Description, [datetime]$JobStart)
    PcCheckSafetyLog (T 'server.safety.logLegePunkt' $Description)
    $problems = New-Object System.Collections.ArrayList
    # Höchste Sequenznummer vor dem Anlegen: Nur ein danach entstandener Punkt zählt, nicht einer,
    # den z. B. Windows Update kurz vorher angelegt hat. Ist die Liste nicht lesbar, gilt die Zeitgrenze.
    $beforeSeq = $null
    try { $beforeSeq = [int](@(PcCheckSafetyListPoints) | Measure-Object -Property seq -Maximum).Maximum } catch { }
    try {
        $warn = @(& $script:PcCheckRestorePointImpl $Description 3>&1 |
                Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
                ForEach-Object { $_.Message })
        foreach ($w in $warn) { [void]$problems.Add([string]$w) }
    } catch {
        [void]$problems.Add($_.Exception.Message)
    }

    $limit = $JobStart.AddMinutes(-1)
    $hit = $null
    $waited = 0
    while ($true) {
        try {
            $hit = @(PcCheckSafetyListPoints) | Where-Object {
                ($null -ne $_.zeit) -and ($_.zeit -ge $limit) -and (($null -eq $beforeSeq) -or ($_.seq -gt $beforeSeq))
            } | Select-Object -First 1
        } catch {
            [void]$problems.Add((T 'server.safety.listeNichtLesbar' $_.Exception.Message))
            $hit = $null
        }
        if ($null -ne $hit) { break }
        if ($waited -ge $script:PcCheckRestorePointWaitSeconds) { break }
        Start-Sleep -Seconds 2
        $waited += 2
    }

    if ($null -eq $hit) {
        $diag = PcCheckSafetyDiagnose
        $msg = (T 'server.safety.punktFehlt' $diag.ursache)
        if ($problems.Count -gt 0) { $msg += ' ' + (T 'server.safety.meldungWindows' (($problems | Select-Object -Unique) -join ' | ')) }
        $msg += ' ' + (T 'server.safety.behebung' $diag.befehl)
        throw $msg
    }
    PcCheckSafetyLog (T 'server.safety.punktGeprueft' $hit.seq $hit.zeit.ToString('HH:mm:ss'))
    @{ seq = [int]$hit.seq; zeit = (PcCheckSafetyIso $hit.zeit) }
}
#endregion

function PcCheckSafetyNewResult {
    param($Action, $Status, $Vorher, $Nachher, $Meldung, $Eintrag)
    $restart = $false
    if (($Status -eq 'erledigt') -and ($Action.Neustart -eq $true)) { $restart = $true }
    [pscustomobject]@{
        id      = [string]$Action.Id
        status  = $Status
        vorher  = $Vorher
        nachher = $Nachher
        neustart = $restart
        meldung = $Meldung
        eintrag = $Eintrag
    }
}

function PcCheckSafetyFindAction {
    param($Catalog, [string]$Id)
    foreach ($a in $Catalog) { if ([string]$a.Id -ceq $Id) { return $a } }
    $null
}

#endregion

#region Öffentliche Funktionen

function Get-PcCheckCatalog {
    [CmdletBinding()]
    param([string]$Root)
    if (-not $Root) { $Root = PcCheckSafetyDefaultRoot }
    $file = Join-Path $Root 'pc-check.aktionen.ps1'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $items = @(& $file)
    $result = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($i in $items) {
        if ($null -eq $i -or -not ($i -is [System.Collections.IDictionary])) { continue }
        $id = [string]$i.Id
        if ($id -notmatch '^[a-z0-9.-]+$') { throw "Aktionskatalog: ungültige Id '$id'." }
        if ($seen.ContainsKey($id)) { throw (T 'server.safety.katalogIdDoppelt' $id) }
        $seen[$id] = $true
        [void]$result.Add($i)
    }
    # Anzeigetexte in der eingestellten Sprache (Deutsch als Rückfall). Varianten bleiben Kennungen, die Namen kommen dazu.
    $sp = Get-MorpheusAktiveSprache
    $texte = @(Import-MorpheusSprachDatei -Sprache 'de' -Teil 'aktionen' -Root $Root)
    if ($sp -ne 'de') { $texte += Import-MorpheusSprachDatei -Sprache $sp -Teil 'aktionen' -Root $Root }
    foreach ($i in $result) {
        foreach ($tx in $texte) {
            $e = $tx[[string]$i.Id]
            if (-not ($e -is [hashtable])) { continue }
            foreach ($feld in 'Titel', 'Erklaerung', 'Befehle', 'VariantenNamen') { if ($e.ContainsKey($feld)) { $i[$feld] = $e[$feld] } }
        }
    }
    $result.ToArray()
}

function ConvertTo-PublicAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Action, $State)
    $var = $null
    if ($Action.Varianten) { $var = @($Action.Varianten) }
    $cmdRun = $null; $cmdUndo = $null; $cmdHelp = @()
    if ($Action.Befehle) {
        $cmdRun = $Action.Befehle.Ausfuehren
        $cmdUndo = $Action.Befehle.Rueckgaengig
        if ($Action.Befehle.Erklaerung) { $cmdHelp = @($Action.Befehle.Erklaerung) }
    }
    $zustand = $null
    if ($State) { $zustand = [pscustomobject]@{ aktiv = $State.aktiv; wert = $State.wert; stand = $State.stand } }
    [pscustomobject]@{
        id        = [string]$Action.Id
        kategorie = $Action.Kategorie
        pruefung  = $Action.Pruefung
        titel     = $Action.Titel
        erklaerung = $Action.Erklaerung
        nutzen    = $Action.Nutzen
        aufwand   = $Action.Aufwand
        risiko    = $Action.Risiko
        neustart  = ($Action.Neustart -eq $true)
        bereich   = $Action.Bereich
        varianten = $var
        variantenNamen = $(if ($var -and $Action.VariantenNamen) { @($Action.VariantenNamen) } else { $var })
        ohneWiederherstellungspunkt = ($Action.OhneWiederherstellungspunkt -eq $true)
        befehle   = [pscustomobject]@{ ausfuehren = $cmdRun; rueckgaengig = $cmdUndo; erklaerung = $cmdHelp }
        zustand   = $zustand
    }
}

function Get-PcCheckActionStates {
    [CmdletBinding()]
    param([string]$Root, $Catalog)
    if ($null -eq $Catalog) { $Catalog = @(Get-PcCheckCatalog -Root $Root) }
    $result = @{}
    foreach ($a in @($Catalog)) {
        try {
            $s = PcCheckSafetyReadState $a
            $result[[string]$a.Id] = @{ aktiv = $s.aktiv; wert = $s.wert; stand = $s.stand }
        } catch {
            $result[[string]$a.Id] = @{ aktiv = $false; wert = (T 'server.safety.fehlerWert' $_.Exception.Message); stand = (Get-Date).ToString('s') }
        }
    }
    $result
}

# Schnell (nur Registry und Journal, kein Get-ComputerRestorePoint)
# Speichergrenze der Schattenkopien auf dem Systemlaufwerk (nur mit Adminrechten lesbar), 60 s zwischengespeichert,
# weil /api/session häufig abgefragt wird. klein = unter 5 % bzw. 8 GB: Windows löscht dann ältere Punkte schnell.
function PcCheckSafetyShadowLimit {
    if ($script:PcCheckSafetyShadowCache -and (((Get-Date) - $script:PcCheckSafetyShadowCache.Zeit).TotalSeconds -lt 60)) { return $script:PcCheckSafetyShadowCache.Wert }
    $res = $null
    try {
        $lw = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\')); if (-not $lw) { $lw = 'C:' }
        $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='$lw'" -ErrorAction Stop
        $ss = @(Get-CimInstance Win32_ShadowStorage -ErrorAction Stop | Where-Object { $_.Volume.DeviceID -eq $vol.DeviceID }) | Select-Object -First 1
        if ($ss) {
            $max = [uint64]$ss.MaxSpace
            if ($max -eq [uint64]::MaxValue) { $res = [pscustomobject]@{ klein = $false; text = 'unbegrenzt' } }
            else {
                $pct = [Math]::Round(100 * [double]$max / [double]$vol.Capacity, 1)
                $res = [pscustomobject]@{ klein = (($pct -lt 5) -or ([double]$max -lt 8GB)); text = ('{0:N1} GB ({1} %)' -f ([double]$max / 1GB), $pct) }
            }
        }
    }
    catch { $res = $null }
    $script:PcCheckSafetyShadowCache = @{ Zeit = Get-Date; Wert = $res }
    $res
}

function Get-PcCheckSafetyStatus {
    [CmdletBinding()]
    param([string]$Root, [string]$DataRoot)
    if (-not $Root) { $Root = PcCheckSafetyDefaultRoot }
    if (-not $DataRoot) { $DataRoot = $Root }   # Journal liegt im Datenordner (Standard: Projektordner)
    $drive = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\'))
    if (-not $drive) { $drive = 'C:' }
    $interval = PcCheckSafetyRegValue $script:PcCheckSafetyRegRestore 'RPSessionInterval'
    $disable = PcCheckSafetyRegValue $script:PcCheckSafetyRegPolicy 'DisableSR'
    $freq = PcCheckSafetyRegValue $script:PcCheckSafetyRegRestore 'SystemRestorePointCreationFrequency'
    $last = $null
    $seitStart = New-Object System.Collections.ArrayList
    try {
        $entries = @(PcCheckSafetyReadJournal $DataRoot)
        for ($i = $entries.Count - 1; $i -ge 0; $i--) {
            if ($entries[$i].wiederherstellungspunkt) { $last = [string]$entries[$i].wiederherstellungspunkt.zeit; break }
        }
        # Seit dem letzten Windows-Start ausgeführte Aktionen (2.7, #95); die GUI markiert davon die mit Neustart
        # als 'ausgeführt - Neustart ausstehend'. Ohne lesbare Startzeit bleibt die Liste leer.
        $boot = & $script:PcCheckBootTimeImpl
        if ($null -ne $boot) {
            foreach ($e in $entries) {
                $ez = PcCheckSafetyToDate $e.zeit
                if (([string]$e.art -ceq 'ausfuehren') -and ([string]$e.status -ceq 'erledigt') -and ($null -ne $ez) -and ($ez -ge $boot) -and (-not $seitStart.Contains([string]$e.aktion))) {
                    [void]$seitStart.Add([string]$e.aktion)
                }
            }
        }
    } catch { $last = $null }
    $sperre = $true
    if (($null -ne $freq) -and ([int64]$freq -eq 0)) { $sperre = $false }
    $sp = $null
    if (($interval -eq 1) -and ($disable -ne 1)) { $sp = PcCheckSafetyShadowLimit }
    [pscustomobject]@{
        schutzAn     = (($interval -eq 1) -and ($disable -ne 1))
        laufwerk     = $drive
        sperre24h    = $sperre
        letzterPunkt = $last
        befehl       = (PcCheckSafetyCommandFrequency)
        befehlSchutz = (PcCheckSafetyCommandEnable)
        speicherKlein = [bool]($sp -and $sp.klein)
        speicherMax  = $(if ($sp) { $sp.text } else { $null })
        seitStart    = [string[]]@($seitStart)
    }
}

function Get-PcCheckRestorePoints {
    [CmdletBinding()]
    param()
    try {
        $points = @(PcCheckSafetyListPoints)
    } catch {
        return @()
    }
    foreach ($p in $points) {
        [pscustomobject]@{ seq = $p.seq; zeit = (PcCheckSafetyIso $p.zeit); beschreibung = $p.beschreibung; typ = $p.typ }
    }
}

function Get-PcCheckJournal {
    [CmdletBinding()]
    param([string]$Root, [string]$DataRoot)
    if (-not $Root) { $Root = PcCheckSafetyDefaultRoot }
    if (-not $DataRoot) { $DataRoot = $Root }
    $entries = @(PcCheckSafetyReadJournal $DataRoot)
    [array]::Reverse($entries)
    $entries
}

function Invoke-PcCheckChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Ids,
        [string]$Variante,
        [string]$DataRoot
    )
    # Katalog (Code) kommt aus -Root, das Journal aus -DataRoot (Standard: -Root)
    if (-not $DataRoot) { $DataRoot = $Root }
    $jobStart = Get-Date
    $catalog = @(Get-PcCheckCatalog -Root $Root)
    # Journal vorab prüfen: ist es beschädigt, wird gar nichts angelegt oder geändert
    [void]@(PcCheckSafetyReadJournal $DataRoot)

    # --- Prüfen der Anfrage (ändert nichts) ---
    $idList = New-Object System.Collections.ArrayList
    foreach ($i in $Ids) { if (($i -ne '') -and (-not ($idList -ccontains $i))) { [void]$idList.Add($i) } }
    if ($idList.Count -eq 0) { throw (T 'server.safety.keineAktion') }
    $actions = New-Object System.Collections.ArrayList
    foreach ($id in $idList) {
        if ($id -notmatch '^[a-z0-9.-]+$') { throw (T 'server.safety.aktionUnbekannt' $id) }
        $a = PcCheckSafetyFindAction $catalog $id
        if ($null -eq $a) { throw (T 'server.safety.aktionUnbekannt' $id) }
        [void]$actions.Add($a)
    }
    foreach ($a in $actions) {
        $flag = ($a.OhneWiederherstellungspunkt -eq $true)
        if ($flag -and ([string]$a.Id -cne 'system.wiederherstellung')) {
            throw (T 'server.safety.katalogOhnePunkt' $a.Id)
        }
        if ($flag -and ($actions.Count -gt 1)) {
            throw (T 'server.safety.einzeln' $a.Titel)
        }
        if ($a.Varianten) {
            if (-not (@($a.Varianten) -ccontains $Variante)) {
                throw (T 'server.safety.varianteUngueltig' $Variante $a.Id (@($a.Varianten) -join ', '))
            }
        } elseif ((-not [string]::IsNullOrEmpty($Variante)) -and ($actions.Count -eq 1)) {
            throw (T 'server.safety.keineVarianten' $a.Id $Variante)
        }
    }

    # --- 1./2. Lesen und Voraussetzungen ---
    $results = New-Object System.Collections.ArrayList
    $plan = New-Object System.Collections.ArrayList
    foreach ($a in $actions) {
        PcCheckSafetyLog (T 'server.safety.pruefe' $a.Titel)
        try {
            $before = PcCheckSafetyReadState $a
        } catch {
            $m = (T 'server.safety.zustandNichtLesbar' $_.Exception.Message)
            PcCheckSafetyLog (T 'server.safety.uebersprungen' $a.Titel $m)
            [void]$results.Add((PcCheckSafetyNewResult $a 'fehlgeschlagen' $null $null $m $null))
            continue
        }
        if ($before.aktiv) {
            PcCheckSafetyLog (T 'server.safety.zielErreichtLog' $a.Titel)
            [void]$results.Add((PcCheckSafetyNewResult $a 'uebersprungen-erreicht' (PcCheckSafetyJournalState $before) (PcCheckSafetyJournalState $before) (T 'server.safety.zielErreicht') $null))
            continue
        }
        $reason = $null
        if ($a.Voraussetzung) {
            try { $reason = (@(& $a.Voraussetzung) | Out-String).Trim() } catch { $reason = (T 'server.safety.vorNichtPruefbar' $_.Exception.Message) }
        }
        if (-not [string]::IsNullOrEmpty($reason)) {
            PcCheckSafetyLog (T 'server.safety.vorNichtErfuelltLog' $a.Titel $reason)
            [void]$results.Add((PcCheckSafetyNewResult $a 'uebersprungen-voraussetzung' (PcCheckSafetyJournalState $before) $null (T 'server.safety.vorNichtErfuellt' $reason) $null))
            continue
        }
        [void]$plan.Add(@{ action = $a; before = $before })
    }
    if ($plan.Count -eq 0) {
        PcCheckSafetyLog (T 'server.safety.nichtsZuAendern')
        return $results.ToArray()
    }

    # --- 3. Wiederherstellungspunkt (ein Punkt für alle) ---
    $point = $null
    $noPoint = ($plan[0].action.OhneWiederherstellungspunkt -eq $true)
    if ($noPoint) {
        PcCheckSafetyLog (T 'server.safety.ohnePunkt' $plan[0].action.Titel)
    } else {
        if ($plan.Count -eq 1) { $desc = (T 'server.safety.punktBeschreibung' $plan[0].action.Titel) } else { $desc = (T 'server.safety.punktBeschreibungMehrere' $plan.Count) }
        $point = PcCheckSafetyEnsureRestorePoint -Description $desc -JobStart $jobStart
    }

    # --- 4./5. Journal, Ausführen, Kontrolle ---
    foreach ($item in $plan) {
        $a = $item.action
        $before = $item.before
        $var = $null
        if ($a.Varianten) { $var = $Variante }
        $vorherJ = PcCheckSafetyJournalState $before
        $entryId = PcCheckSafetyNewEntryId $DataRoot
        PcCheckSafetyAddEntry $DataRoot (PcCheckSafetyNewEntry $entryId 'ausfuehren' $a $var $vorherJ $point $null)
        PcCheckSafetyLog (T 'server.safety.fuehreAus' $a.Titel)

        $err = ''
        $after = $null
        try { & $a.Ausfuehren $var | Out-Null } catch { $err = $_.Exception.Message }
        if ($err -eq '') {
            try { $after = PcCheckSafetyReadState $a } catch { $err = (T 'server.safety.kontrolleFehler' $_.Exception.Message) }
        }
        if (($err -eq '') -and $after.aktiv) {
            $nach = PcCheckSafetyJournalState $after
            PcCheckSafetyUpdateEntry $DataRoot $entryId @{ status = 'erledigt'; nachher = $nach; meldung = '' }
            PcCheckSafetyLog (T 'server.safety.logErledigt' $a.Titel)
            [void]$results.Add((PcCheckSafetyNewResult $a 'erledigt' $vorherJ $nach '' $entryId))
            continue
        }
        if ($err -eq '') { $err = (T 'server.safety.zielNichtErreicht') }
        PcCheckSafetyLog (T 'server.safety.fehlerSetzeZurueck' $a.Titel $err)

        # Sofort zurücksetzen mit dem Vorher-Zustand
        $status = 'fehlgeschlagen'
        $msg = $err
        $nach = $null
        try {
            & $a.Rueckgaengig $before.zustand | Out-Null
            $check = PcCheckSafetyReadState $a
            $nach = PcCheckSafetyJournalState $check
            if ((PcCheckSafetyStateKey $check.zustand) -ceq (PcCheckSafetyStateKey $before.zustand)) {
                $status = 'fehlgeschlagen-zurueckgesetzt'
                $msg = (T 'server.safety.zurueckgesetzt' $err)
            } else {
                $msg = (T 'server.safety.zuruecksetzenNichtBestaetigt' $err)
            }
        } catch {
            $msg = (T 'server.safety.zuruecksetzenFehlgeschlagen' $err $_.Exception.Message)
        }
        PcCheckSafetyUpdateEntry $DataRoot $entryId @{ status = $status; nachher = $nach; meldung = $msg }
        PcCheckSafetyLog "$($a.Titel): $status"
        [void]$results.Add((PcCheckSafetyNewResult $a $status $vorherJ $nach $msg $entryId))
    }
    $results.ToArray()
}

function Test-PcCheckVorReparatur {
    # Datenordner-Reparatur (18.10): Gilt der Journal-Eintrag als "vor der Reparatur" (kann von einem Programm mit Schreibrechten stammen)?
    # Ja, wenn die Sperrdatei state\datenordner-reparatur.json existiert UND (sie nicht lesbar ist ODER journalUnlesbar true ist
    # ODER die Id des Eintrags in "eintraege" steht ODER - nur bei altem Format ohne "eintraege" - die Zeit des Eintrags nicht
    # nach der Reparatur liegt bzw. nicht lesbar ist). Die Zeit allein reicht nicht: Sie steht im Journal und ist fälschbar.
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)]$Eintrag)
    $repFile = Join-Path $DataRoot 'state\datenordner-reparatur.json'
    if (-not (Test-Path -LiteralPath $repFile -PathType Leaf)) { return $false }
    $j = $null
    try { $j = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($repFile, [Text.Encoding]::UTF8)) } catch { return $true }
    if ($null -eq $j) { return $true }
    $ju = $j.PSObject.Properties['journalUnlesbar']
    if ($ju -and ($ju.Value -eq $true)) { return $true }
    $ep = $j.PSObject.Properties['eintraege']
    if ($ep) {
        $id = [string]$Eintrag.id
        foreach ($x in @($ep.Value)) { if ([string]$x -ceq $id) { return $true } }
        return $false
    }
    # Altes Format (version 1): Zeitvergleich. Unlesbare Zeiten gelten als älter.
    $fmt = [string[]]@('yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mm:ss.FFFFFFF')
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $repZeit = $null; $eintragZeit = $null
    try { $repZeit = [datetime]::ParseExact([string]$j.zeit, $fmt, $ci, [Globalization.DateTimeStyles]::None) } catch { }
    try { $eintragZeit = [datetime]::ParseExact([string]$Eintrag.zeit, $fmt, $ci, [Globalization.DateTimeStyles]::None) } catch { }
    return (($null -eq $repZeit) -or ($null -eq $eintragZeit) -or ($eintragZeit -lt $repZeit))
}

# Punkt der Ausführung eines Journal-Eintrags, wenn er in der Liste noch existiert (Sequenznummer und Zeit gleich).
# Rückgabe @{ seq; zeit; wiederverwendet = $true } oder $null (auch wenn die Liste nicht lesbar ist).
function PcCheckSafetyFindExecutionPoint {
    param($Entry)
    $p = $Entry.wiederherstellungspunkt
    if ($null -eq $p) { return $null }
    $seq = 0
    if (-not [int]::TryParse([string]$p.seq, [ref]$seq)) { return $null }
    if ($seq -le 0) { return $null }
    $zeit = [string]$p.zeit
    try {
        foreach ($x in @(PcCheckSafetyListPoints)) {
            if (($x.seq -eq $seq) -and ((PcCheckSafetyIso $x.zeit) -ceq $zeit)) {
                return @{ seq = $seq; zeit = $zeit; wiederverwendet = $true }
            }
        }
    } catch { }
    $null
}

function Undo-PcCheckChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$EntryId,
        [switch]$Force,
        [string]$DataRoot,
        [switch]$VorReparaturBestaetigt
    )
    if (-not $DataRoot) { $DataRoot = $Root }
    $jobStart = Get-Date
    $catalog = @(Get-PcCheckCatalog -Root $Root)
    $entry = $null
    foreach ($e in @(PcCheckSafetyReadJournal $DataRoot)) { if ([string]$e.id -ceq $EntryId) { $entry = $e } }
    if ($null -eq $entry) { throw (T 'server.safety.eintragFehlt' $EntryId) }
    if ([string]$entry.art -cne 'ausfuehren') { throw (T 'server.safety.keinRueckgaengig') }
    if ([string]$entry.status -cne 'erledigt') {
        throw (T 'server.safety.statusNichtZuruecknehmbar' $entry.status)
    }
    # Datenordner-Reparatur (18.10): Einträge aus der Zeit davor können von einem Programm mit Schreibrechten stammen.
    # Ohne ausdrückliche Bestätigung keine Rücknahme. Ist die Datei unlesbar oder die Zeit nicht lesbar, gilt der Eintrag als älter.
    if ((-not $VorReparaturBestaetigt) -and (Test-PcCheckVorReparatur -DataRoot $DataRoot -Eintrag $entry)) {
        throw (T 'server.safety.vorReparatur')
    }
    $a = PcCheckSafetyFindAction $catalog ([string]$entry.aktion)
    if ($null -eq $a) { throw (T 'server.safety.nichtImKatalog' $entry.aktion) }

    PcCheckSafetyLog (T 'server.safety.pruefeZustand' $a.Titel)
    $current = PcCheckSafetyReadState $a
    # Verteidigung in der Tiefe: Ein gefälschter Journal-Eintrag darf der Aktion keinen Zustand unterschieben,
    # den ihr Lesen nie liefern würde. Das gilt auch mit -Force.
    $target0 = $null
    if ($entry.vorher) { $target0 = $entry.vorher.zustand }
    PcCheckSafetyAssertStateShape -Current $current.zustand -Saved $target0
    $saved = $null
    if ($entry.nachher) { $saved = $entry.nachher.zustand }
    if (((PcCheckSafetyStateKey $current.zustand) -cne (PcCheckSafetyStateKey $saved)) -and (-not $Force)) {
        throw (T 'server.safety.zustandGeaendert' $a.Titel $current.wert)
    }

    $point = $null
    if ($a.OhneWiederherstellungspunkt -eq $true) {
        PcCheckSafetyLog (T 'server.safety.ohnePunktRuecknahme' $a.Titel)
    } else {
        try {
            $point = PcCheckSafetyEnsureRestorePoint -Description (T 'server.safety.punktRuecknahme' $a.Titel) -JobStart $jobStart
        } catch {
            # 24-h-Sperre (2.7, #95): Der Punkt der Ausführung zeigt genau den Zustand, zu dem die Rücknahme
            # zurückkehrt. Existiert er noch (gleiche Sequenznummer und Zeit), dient er als Sicherung.
            $orig = PcCheckSafetyFindExecutionPoint $entry
            if ($null -eq $orig) { throw }
            PcCheckSafetyLog (T 'server.safety.punktDerAusfuehrung' $orig.seq)
            $point = $orig
        }
    }

    $vorherJ = PcCheckSafetyJournalState $current
    $undoId = PcCheckSafetyNewEntryId $DataRoot
    $var = $null
    if ($entry.variante) { $var = [string]$entry.variante }
    PcCheckSafetyAddEntry $DataRoot (PcCheckSafetyNewEntry $undoId 'rueckgaengig' $a $var $vorherJ $point $EntryId)
    PcCheckSafetyLog (T 'server.safety.nehmeZurueck' $a.Titel)

    $target = $null
    if ($entry.vorher) { $target = $entry.vorher.zustand }
    $err = ''
    $after = $null
    try { & $a.Rueckgaengig $target | Out-Null } catch { $err = $_.Exception.Message }
    if ($err -eq '') {
        try { $after = PcCheckSafetyReadState $a } catch { $err = (T 'server.safety.kontrolleFehler' $_.Exception.Message) }
    }
    if (($err -eq '') -and ((PcCheckSafetyStateKey $after.zustand) -cne (PcCheckSafetyStateKey $target))) {
        $err = (T 'server.safety.nachRuecknahmeAbweichend')
    }
    if ($err -eq '') {
        $nach = PcCheckSafetyJournalState $after
        PcCheckSafetyUpdateEntry $DataRoot $undoId @{ status = 'erledigt'; nachher = $nach; meldung = '' }
        PcCheckSafetyUpdateEntry $DataRoot $EntryId @{ status = 'zurueckgenommen' }
        PcCheckSafetyLog (T 'server.safety.zurueckgenommen' $a.Titel)
        return (PcCheckSafetyNewResult $a 'erledigt' $vorherJ $nach '' $undoId)
    }
    $msg = (T 'server.safety.ruecknahmeFehlgeschlagen' $err)
    PcCheckSafetyUpdateEntry $DataRoot $undoId @{ status = 'fehlgeschlagen'; meldung = $msg }
    PcCheckSafetyLog (T 'server.safety.ruecknahmeFehlgeschlagenLog' $a.Titel $err)
    PcCheckSafetyNewResult $a 'fehlgeschlagen' $vorherJ (PcCheckSafetyJournalState $after) $msg $undoId
}
#endregion
