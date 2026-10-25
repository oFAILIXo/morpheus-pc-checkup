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
    if ($null -eq $raw) { throw 'Lesen lieferte kein Ergebnis.' }
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
    if ($kc -ne $ks) { return "$Path`: erwartet $kc, gespeichert $ks" }
    if ($kc -ne 'object') { return $null }
    $nc = @($Cur.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    $ns = @($Saved.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    if ((($nc -join "`n")) -cne (($ns -join "`n"))) { return "$Path`: Eigenschaften '$($ns -join ',')' statt '$($nc -join ',')'" }
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
    if ($diff) { throw "Journal-Eintrag passt nicht zur Aktion ($diff). Es wird nichts geändert." }
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
        throw "Das Änderungsjournal ($path) ist beschädigt und wird nicht überschrieben. Bitte die Datei prüfen. Ursache: $($_.Exception.Message)"
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
    if (-not $found) { throw "Journal-Eintrag '$Id' nicht gefunden." }
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
    $drive = $env:SystemDrive
    if (-not $drive) { $drive = 'C:' }
    "Enable-ComputerRestore -Drive '$drive\'"
}

# Ursache für einen fehlenden Punkt und der Befehl zur Behebung
function PcCheckSafetyDiagnose {
    $causes = New-Object System.Collections.ArrayList
    $cmds = New-Object System.Collections.ArrayList
    if (-not (PcCheckSafetyIsAdmin)) {
        [void]$causes.Add('Die Anwendung läuft ohne Administratorrechte.')
        [void]$cmds.Add('Die Anwendung über pc-check-gui.cmd neu starten und die Rechteabfrage bestätigen.')
    }
    $disable = PcCheckSafetyRegValue $script:PcCheckSafetyRegPolicy 'DisableSR'
    $interval = PcCheckSafetyRegValue $script:PcCheckSafetyRegRestore 'RPSessionInterval'
    if ($disable -eq 1) {
        [void]$causes.Add('Der Computerschutz ist per Richtlinie abgeschaltet (DisableSR = 1).')
        [void]$cmds.Add('Die Gruppenrichtlinie "Systemwiederherstellung deaktivieren" auf "Nicht konfiguriert" setzen.')
    } elseif ($interval -ne 1) {
        [void]$causes.Add('Der Computerschutz ist für das Systemlaufwerk ausgeschaltet.')
        [void]$cmds.Add((PcCheckSafetyCommandEnable))
    }
    $freq = PcCheckSafetyRegValue $script:PcCheckSafetyRegRestore 'SystemRestorePointCreationFrequency'
    if (($null -eq $freq) -or ([int64]$freq -gt 0)) {
        [void]$causes.Add('Windows legt standardmäßig höchstens alle 24 Stunden einen Wiederherstellungspunkt an (24-h-Sperre); vermutlich gab es schon einen.')
        [void]$cmds.Add((PcCheckSafetyCommandFrequency))
    }
    if ($causes.Count -eq 0) { [void]$causes.Add('Die Ursache ließ sich nicht eindeutig bestimmen (Dienst "Volumeschattenkopie" oder Speicherplatz prüfen).') }
    @{ ursache = ($causes -join ' '); befehl = ($cmds -join "`n") }
}

# Legt einen Punkt an und prüft ihn; wirft, wenn er fehlt. Rückgabe @{ seq; zeit }
function PcCheckSafetyEnsureRestorePoint {
    param([string]$Description, [datetime]$JobStart)
    PcCheckSafetyLog "Lege Wiederherstellungspunkt an: $Description"
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
            [void]$problems.Add("Liste der Wiederherstellungspunkte nicht lesbar: $($_.Exception.Message)")
            $hit = $null
        }
        if ($null -ne $hit) { break }
        if ($waited -ge $script:PcCheckRestorePointWaitSeconds) { break }
        Start-Sleep -Seconds 2
        $waited += 2
    }

    if ($null -eq $hit) {
        $diag = PcCheckSafetyDiagnose
        $msg = 'Es konnte kein Wiederherstellungspunkt angelegt werden, deshalb wurde nichts geändert. Ursache: ' + $diag.ursache
        if ($problems.Count -gt 0) { $msg += ' Meldung von Windows: ' + (($problems | Select-Object -Unique) -join ' | ') }
        $msg += " Zur Behebung (Administrator-PowerShell): $($diag.befehl)"
        throw $msg
    }
    PcCheckSafetyLog ("Wiederherstellungspunkt #{0} geprüft ({1})." -f $hit.seq, $hit.zeit.ToString('HH:mm:ss'))
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
        if ($seen.ContainsKey($id)) { throw "Aktionskatalog: Id '$id' ist doppelt." }
        $seen[$id] = $true
        [void]$result.Add($i)
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
            $result[[string]$a.Id] = @{ aktiv = $false; wert = ('Fehler: ' + $_.Exception.Message); stand = (Get-Date).ToString('s') }
        }
    }
    $result
}

# Schnell (nur Registry und Journal, kein Get-ComputerRestorePoint)
function Get-PcCheckSafetyStatus {
    [CmdletBinding()]
    param([string]$Root, [string]$DataRoot)
    if (-not $Root) { $Root = PcCheckSafetyDefaultRoot }
    if (-not $DataRoot) { $DataRoot = $Root }   # Journal liegt im Datenordner (Standard: Projektordner)
    $drive = $env:SystemDrive
    if (-not $drive) { $drive = 'C:' }
    $interval = PcCheckSafetyRegValue $script:PcCheckSafetyRegRestore 'RPSessionInterval'
    $disable = PcCheckSafetyRegValue $script:PcCheckSafetyRegPolicy 'DisableSR'
    $freq = PcCheckSafetyRegValue $script:PcCheckSafetyRegRestore 'SystemRestorePointCreationFrequency'
    $last = $null
    try {
        $entries = @(PcCheckSafetyReadJournal $DataRoot)
        for ($i = $entries.Count - 1; $i -ge 0; $i--) {
            if ($entries[$i].wiederherstellungspunkt) { $last = [string]$entries[$i].wiederherstellungspunkt.zeit; break }
        }
    } catch { $last = $null }
    $sperre = $true
    if (($null -ne $freq) -and ([int64]$freq -eq 0)) { $sperre = $false }
    [pscustomobject]@{
        schutzAn     = (($interval -eq 1) -and ($disable -ne 1))
        laufwerk     = $drive
        sperre24h    = $sperre
        letzterPunkt = $last
        befehl       = (PcCheckSafetyCommandFrequency)
        befehlSchutz = (PcCheckSafetyCommandEnable)
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
    if ($idList.Count -eq 0) { throw 'Keine Aktion angegeben.' }
    $actions = New-Object System.Collections.ArrayList
    foreach ($id in $idList) {
        if ($id -notmatch '^[a-z0-9.-]+$') { throw "Unbekannte Aktion '$id'." }
        $a = PcCheckSafetyFindAction $catalog $id
        if ($null -eq $a) { throw "Unbekannte Aktion '$id'." }
        [void]$actions.Add($a)
    }
    foreach ($a in $actions) {
        $flag = ($a.OhneWiederherstellungspunkt -eq $true)
        if ($flag -and ([string]$a.Id -cne 'system.wiederherstellung')) {
            throw "Aktionskatalog fehlerhaft: Nur 'system.wiederherstellung' darf ohne Wiederherstellungspunkt laufen ('$($a.Id)')."
        }
        if ($flag -and ($actions.Count -gt 1)) {
            throw "'$($a.Titel)' legt keinen Wiederherstellungspunkt an und muss einzeln ausgeführt werden, nicht zusammen mit anderen Aktionen."
        }
        if ($a.Varianten) {
            if (-not (@($a.Varianten) -ccontains $Variante)) {
                throw "Ungültige Variante '$Variante' für '$($a.Id)'. Erlaubt: $(@($a.Varianten) -join ', ')."
            }
        } elseif ((-not [string]::IsNullOrEmpty($Variante)) -and ($actions.Count -eq 1)) {
            throw "Die Aktion '$($a.Id)' hat keine Varianten, '$Variante' ist ungültig."
        }
    }

    # --- 1./2. Lesen und Voraussetzungen ---
    $results = New-Object System.Collections.ArrayList
    $plan = New-Object System.Collections.ArrayList
    foreach ($a in $actions) {
        PcCheckSafetyLog "Prüfe: $($a.Titel)"
        try {
            $before = PcCheckSafetyReadState $a
        } catch {
            $m = "Zustand nicht lesbar: $($_.Exception.Message)"
            PcCheckSafetyLog "$($a.Titel): $m (übersprungen)"
            [void]$results.Add((PcCheckSafetyNewResult $a 'fehlgeschlagen' $null $null $m $null))
            continue
        }
        if ($before.aktiv) {
            PcCheckSafetyLog "$($a.Titel): Ziel bereits erreicht (übersprungen)"
            [void]$results.Add((PcCheckSafetyNewResult $a 'uebersprungen-erreicht' (PcCheckSafetyJournalState $before) (PcCheckSafetyJournalState $before) 'Ziel war bereits erreicht, nichts geändert.' $null))
            continue
        }
        $reason = $null
        if ($a.Voraussetzung) {
            try { $reason = (@(& $a.Voraussetzung) | Out-String).Trim() } catch { $reason = "Voraussetzung nicht prüfbar: $($_.Exception.Message)" }
        }
        if (-not [string]::IsNullOrEmpty($reason)) {
            PcCheckSafetyLog "$($a.Titel): Voraussetzung nicht erfüllt: $reason (übersprungen)"
            [void]$results.Add((PcCheckSafetyNewResult $a 'uebersprungen-voraussetzung' (PcCheckSafetyJournalState $before) $null "Voraussetzung nicht erfüllt: $reason" $null))
            continue
        }
        [void]$plan.Add(@{ action = $a; before = $before })
    }
    if ($plan.Count -eq 0) {
        PcCheckSafetyLog 'Nichts zu ändern, kein Wiederherstellungspunkt nötig.'
        return $results.ToArray()
    }

    # --- 3. Wiederherstellungspunkt (ein Punkt für alle) ---
    $point = $null
    $noPoint = ($plan[0].action.OhneWiederherstellungspunkt -eq $true)
    if ($noPoint) {
        PcCheckSafetyLog "Hinweis: '$($plan[0].action.Titel)' läuft bewusst ohne Wiederherstellungspunkt."
    } else {
        if ($plan.Count -eq 1) { $desc = 'pc-check: ' + $plan[0].action.Titel } else { $desc = "pc-check: $($plan.Count) Änderungen" }
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
        PcCheckSafetyLog "Führe aus: $($a.Titel)"

        $err = ''
        $after = $null
        try { & $a.Ausfuehren $var | Out-Null } catch { $err = $_.Exception.Message }
        if ($err -eq '') {
            try { $after = PcCheckSafetyReadState $a } catch { $err = "Kontrolle fehlgeschlagen: $($_.Exception.Message)" }
        }
        if (($err -eq '') -and $after.aktiv) {
            $nach = PcCheckSafetyJournalState $after
            PcCheckSafetyUpdateEntry $DataRoot $entryId @{ status = 'erledigt'; nachher = $nach; meldung = '' }
            PcCheckSafetyLog "$($a.Titel): erledigt"
            [void]$results.Add((PcCheckSafetyNewResult $a 'erledigt' $vorherJ $nach '' $entryId))
            continue
        }
        if ($err -eq '') { $err = 'Das Ziel wurde nach dem Ausführen nicht erreicht.' }
        PcCheckSafetyLog "$($a.Titel): Fehler: $err Setze zurück ..."

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
                $msg = "$err Der vorherige Zustand wurde wiederhergestellt."
            } else {
                $msg = "$err Zurücksetzen nicht bestätigt: Der Zustand weicht vom vorherigen ab. Bitte den Wiederherstellungspunkt verwenden."
            }
        } catch {
            $msg = "$err Zurücksetzen fehlgeschlagen: $($_.Exception.Message). Bitte den Wiederherstellungspunkt verwenden."
        }
        PcCheckSafetyUpdateEntry $DataRoot $entryId @{ status = $status; nachher = $nach; meldung = $msg }
        PcCheckSafetyLog "$($a.Titel): $status"
        [void]$results.Add((PcCheckSafetyNewResult $a $status $vorherJ $nach $msg $entryId))
    }
    $results.ToArray()
}

function Undo-PcCheckChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$EntryId,
        [switch]$Force,
        [string]$DataRoot
    )
    if (-not $DataRoot) { $DataRoot = $Root }
    $jobStart = Get-Date
    $catalog = @(Get-PcCheckCatalog -Root $Root)
    $entry = $null
    foreach ($e in @(PcCheckSafetyReadJournal $DataRoot)) { if ([string]$e.id -ceq $EntryId) { $entry = $e } }
    if ($null -eq $entry) { throw "Journal-Eintrag '$EntryId' nicht gefunden." }
    if ([string]$entry.art -cne 'ausfuehren') { throw 'Nur ausgeführte Änderungen lassen sich zurücknehmen. Eine Rücknahme kann nicht erneut zurückgenommen werden; dafür die Aktion neu ausführen.' }
    if ([string]$entry.status -cne 'erledigt') {
        throw "Der Eintrag hat den Status '$($entry.status)' und lässt sich nicht zurücknehmen (nur 'erledigt')."
    }
    $a = PcCheckSafetyFindAction $catalog ([string]$entry.aktion)
    if ($null -eq $a) { throw "Die Aktion '$($entry.aktion)' ist nicht mehr im Katalog; Rücknahme nicht möglich." }

    PcCheckSafetyLog "Prüfe aktuellen Zustand: $($a.Titel)"
    $current = PcCheckSafetyReadState $a
    # Verteidigung in der Tiefe: Ein gefälschter Journal-Eintrag darf der Aktion keinen Zustand unterschieben,
    # den ihr Lesen nie liefern würde. Das gilt auch mit -Force.
    $target0 = $null
    if ($entry.vorher) { $target0 = $entry.vorher.zustand }
    PcCheckSafetyAssertStateShape -Current $current.zustand -Saved $target0
    $saved = $null
    if ($entry.nachher) { $saved = $entry.nachher.zustand }
    if (((PcCheckSafetyStateKey $current.zustand) -cne (PcCheckSafetyStateKey $saved)) -and (-not $Force)) {
        throw "Der Zustand von '$($a.Titel)' hat sich seit der Änderung geändert (aktuell: '$($current.wert)'). Die Rücknahme würde auch diese spätere Änderung überschreiben. Zum Fortfahren mit Force bestätigen."
    }

    $point = $null
    if ($a.OhneWiederherstellungspunkt -eq $true) {
        PcCheckSafetyLog "Hinweis: '$($a.Titel)' wird bewusst ohne Wiederherstellungspunkt zurückgenommen."
    } else {
        $point = PcCheckSafetyEnsureRestorePoint -Description ('pc-check: Rücknahme ' + $a.Titel) -JobStart $jobStart
    }

    $vorherJ = PcCheckSafetyJournalState $current
    $undoId = PcCheckSafetyNewEntryId $DataRoot
    $var = $null
    if ($entry.variante) { $var = [string]$entry.variante }
    PcCheckSafetyAddEntry $DataRoot (PcCheckSafetyNewEntry $undoId 'rueckgaengig' $a $var $vorherJ $point $EntryId)
    PcCheckSafetyLog "Nehme zurück: $($a.Titel)"

    $target = $null
    if ($entry.vorher) { $target = $entry.vorher.zustand }
    $err = ''
    $after = $null
    try { & $a.Rueckgaengig $target | Out-Null } catch { $err = $_.Exception.Message }
    if ($err -eq '') {
        try { $after = PcCheckSafetyReadState $a } catch { $err = "Kontrolle fehlgeschlagen: $($_.Exception.Message)" }
    }
    if (($err -eq '') -and ((PcCheckSafetyStateKey $after.zustand) -cne (PcCheckSafetyStateKey $target))) {
        $err = 'Der Zustand entspricht nach der Rücknahme nicht dem gespeicherten Vorher-Zustand.'
    }
    if ($err -eq '') {
        $nach = PcCheckSafetyJournalState $after
        PcCheckSafetyUpdateEntry $DataRoot $undoId @{ status = 'erledigt'; nachher = $nach; meldung = '' }
        PcCheckSafetyUpdateEntry $DataRoot $EntryId @{ status = 'zurueckgenommen' }
        PcCheckSafetyLog "$($a.Titel): zurückgenommen"
        return (PcCheckSafetyNewResult $a 'erledigt' $vorherJ $nach '' $undoId)
    }
    $msg = "$err Der ursprüngliche Eintrag bleibt 'erledigt'; bei Bedarf den Wiederherstellungspunkt verwenden."
    PcCheckSafetyUpdateEntry $DataRoot $undoId @{ status = 'fehlgeschlagen'; meldung = $msg }
    PcCheckSafetyLog "$($a.Titel): Rücknahme fehlgeschlagen: $err"
    PcCheckSafetyNewResult $a 'fehlgeschlagen' $vorherJ (PcCheckSafetyJournalState $after) $msg $undoId
}
#endregion
