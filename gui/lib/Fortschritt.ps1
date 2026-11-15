#Requires -Version 5.1
# Morpheus - Fortschrittsvertrag der Jobs (Vertrag: docs\gui-architektur.md, Job-API; Plan docs\plaene\2026-11-12-fortschritt-jobs-status.md).
# Nur Funktionen. Kein Dateizugriff, keine Prozesse, keine eingebetteten .NET-Typen.
#
# Weg der Daten: Der Job ruft Write-MorpheusFortschritt. Das schreibt EINEN Information-Record mit einer Hashtable als
# MessageData und dem Tag 'morpheus.fortschritt'. Der Server (Get-GuiJobStreamLines) nimmt nur solche Records an und
# prueft sie mit ConvertTo-MorpheusFortschritt. Eine Zeichenkette (Logtext, Ausgabe von winget/DISM/Benutzer-Pipe) kann
# nie ein IDictionary sein und setzt den Fortschritt deshalb nie.

if (-not (Get-Command -Name Format-MorpheusWartungZeile -ErrorAction SilentlyContinue)) {
    $__fAusw = Join-Path $PSScriptRoot 'WartungAuswertung.ps1'
    if (Test-Path -LiteralPath $__fAusw -PathType Leaf) { . $__fAusw }
}

# Feste Listen als Funktionen (nicht $script:-Variablen): Die Datei wird auch in Job-Skriptblöcken per Dot-Source geladen.
function Get-MorpheusFortschrittTag { 'morpheus.fortschritt' }

function Get-MorpheusFortschrittPhasen {
    param([AllowNull()][string]$Art)
    switch -CaseSensitive ($Art) {
        'run' { return @('zustand', 'punkt', 'journal', 'ausfuehren', 'pruefen') }
        'undo' { return @('zustand', 'punkt', 'journal', 'ausfuehren', 'pruefen') }
        'wartung' { return @('punkt', 'ausfuehren', 'auswerten') }
        'scan' { return @('scan') }
    }
    return @()
}

function Write-MorpheusFortschritt {
    # Sender im Job. Schreibt nur in den Information-Stream; ohne Prozess, Datei oder Netz.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Modus,
        [AllowNull()]$Prozent = $null,
        [AllowNull()]$I = $null,
        [AllowNull()]$N = $null,
        [AllowNull()][string]$Phase = $null,
        [AllowNull()][string]$Text = $null,
        [AllowNull()]$Elemente = $null
    )
    $d = @{ modus = $Modus }
    if ($null -ne $Prozent) { $d['prozent'] = $Prozent }
    if ($null -ne $I) { $d['i'] = $I }
    if ($null -ne $N) { $d['n'] = $N }
    if (-not [string]::IsNullOrEmpty($Phase)) { $d['phase'] = $Phase }
    if (-not [string]::IsNullOrEmpty($Text)) { $d['text'] = $Text }
    if ($null -ne $Elemente) { $d['elemente'] = $Elemente }
    Write-Information -MessageData $d -Tags (Get-MorpheusFortschrittTag) -InformationAction Continue
}

function Test-MorpheusKonsolenFortschritt {
    # Konsolenpfade (Scan, Installer, Selbst-Update, winget-Dialog; 2.9, #142): Write-Progress nur in einer echten Konsole.
    # $false, wenn die GUI den Lauf gestartet hat (MORPHEUS_FS gesetzt), der Code in einem Job läuft (Host ist nicht die
    # Konsole) oder die Ausgabe umgeleitet ist: dort landete der Fortschritt sonst als CLIXML im Log bzw. in der Datei.
    # Die Parameter sind nur für Tests da.
    param(
        [AllowNull()][string]$Kennung = $env:MORPHEUS_FS,
        [AllowNull()][string]$HostName = $Host.Name,
        [AllowNull()]$Umgeleitet = $null
    )
    if ($Kennung) { return $false }
    if ($HostName -cne 'ConsoleHost') { return $false }
    if ($null -eq $Umgeleitet) { try { $Umgeleitet = [Console]::IsOutputRedirected } catch { $Umgeleitet = $true } }
    return (-not [bool]$Umgeleitet)
}

function Test-MorpheusFortschrittRecord {
    # $true, wenn der Information-Record ein Fortschritts-Record ist: MessageData ist ein IDictionary UND das Tag ist gesetzt.
    # Nach der Job-Grenze ist MessageData eine deserialisierte Hashtable (weiter IDictionary), Tags eine Liste von Zeichenketten.
    param($Record)
    if ($null -eq $Record) { return $false }
    $md = $null; $tags = $null
    try { $md = $Record.MessageData; $tags = $Record.Tags } catch { return $false }
    if (-not ($md -is [System.Collections.IDictionary])) { return $false }
    $tag = Get-MorpheusFortschrittTag
    foreach ($t in @($tags)) { if (([string]$t) -ceq $tag) { return $true } }
    return $false
}

function MorpheusFortschrittZahl {
    # Ganzzahl per TryParse (invariant), sonst $null. Kommazahlen werden abgeschnitten.
    param($Wert)
    if ($null -eq $Wert) { return $null }
    if (($Wert -is [int]) -or ($Wert -is [long]) -or ($Wert -is [int16]) -or ($Wert -is [byte])) { return [long]$Wert }
    if (($Wert -is [double]) -or ($Wert -is [single]) -or ($Wert -is [decimal])) {
        $f = [double]$Wert
        if ([double]::IsNaN($f) -or [double]::IsInfinity($f) -or ($f -gt 1e9) -or ($f -lt -1e9)) { return $null }
        return [long][math]::Floor($f)
    }
    if (-not ($Wert -is [string])) { return $null }
    $s = $Wert.Trim()
    if ($s.Length -gt 12) { return $null }
    $n = 0
    if ([int]::TryParse($s, [Globalization.NumberStyles]::AllowLeadingSign, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return [long]$n }
    return $null
}

function MorpheusFortschrittGrenze {
    param([long]$Wert, [long]$Min, [long]$Max)
    if ($Wert -lt $Min) { return [int]$Min }
    if ($Wert -gt $Max) { return [int]$Max }
    return [int]$Wert
}

function ConvertTo-MorpheusFortschritt {
    # Reine Funktion: prueft einen Fortschritts-Record des Jobs. Rueckgabe: geordnete Hashtable oder $null (Record verwerfen).
    # -Pakete (2.9, #140): Paketliste, die der Server dem Job beim Start mitgegeben hat. Ohne sie bleibt 'elemente' $null.
    [CmdletBinding()]
    param([AllowNull()]$Daten, [AllowNull()][string]$Art, [AllowNull()][object[]]$Pakete)
    if (-not ($Daten -is [System.Collections.IDictionary])) { return $null }
    $modus = $Daten['modus']
    if (-not ($modus -is [string])) { return $null }
    if (-not (@('prozent', 'zaehler', 'offen') -ccontains $modus)) { return $null }

    $prozent = $null; $i = $null; $n = $null
    if ($modus -ceq 'prozent') {
        $p = MorpheusFortschrittZahl $Daten['prozent']
        if ($null -eq $p) { return $null }
        $prozent = MorpheusFortschrittGrenze $p 0 100
    }
    elseif ($modus -ceq 'zaehler') {
        $nn = MorpheusFortschrittZahl $Daten['n']
        $ii = MorpheusFortschrittZahl $Daten['i']
        if (($null -eq $nn) -or ($null -eq $ii) -or ($nn -lt 1)) { return $null }
        $n = MorpheusFortschrittGrenze $nn 1 9999
        $i = MorpheusFortschrittGrenze $ii 0 $n
        # Der Server rechnet selbst; ein mitgeschicktes 'prozent' zaehlt nicht
        $prozent = [int][math]::Floor(100.0 * $i / $n)
    }

    $phase = $null
    $ph = $Daten['phase']
    if (($ph -is [string]) -and (@(Get-MorpheusFortschrittPhasen $Art) -ccontains $ph)) { $phase = $ph }

    $text = $null
    $tx = $Daten['text']
    if ($tx -is [string]) {
        $t = $tx
        if ($t.Length -gt 1000) { $t = $t.Substring(0, 1000) }
        if (Get-Command -Name Format-MorpheusWartungZeile -ErrorAction SilentlyContinue) { $t = Format-MorpheusWartungZeile -Text $t }
        else { $t = ([regex]::Replace($t, '[\u0000-\u001F\u007F\u0085؜​-‏  ‪-‮⁦-⁩﻿]', '')).Trim() }
        # Tabulator laesst Format-MorpheusWartungZeile stehen; im Fortschritt nur ein Leerzeichen
        $t = $t.Replace([string][char]9, ' ')
        if ($t.Length -gt 120) { $t = $t.Substring(0, 120) }
        if ($t.Length -gt 0) { $text = $t }
    }

    $elemente = $null
    if ($Daten.Contains('elemente') -and ($null -ne $Pakete)) { $elemente = ConvertTo-MorpheusFortschrittElemente -Elemente $Daten['elemente'] -Pakete $Pakete }

    return [ordered]@{ modus = $modus; prozent = $prozent; i = $i; n = $n; phase = $phase; text = $text; elemente = $elemente }
}

function Get-MorpheusFortschrittElementStatus { @('offen', 'laeuft', 'fertig', 'fehler', 'abgebrochen') }

function ConvertTo-MorpheusFortschrittElemente {
    # Reine Funktion (2.9, #140): prueft die Paketliste eines Fortschritts-Records.
    # -Pakete ist die Liste, die der Server dem Job beim Start selbst mitgegeben hat ({id, name, von, auf}).
    # Aus dem Record zaehlen nur 'id' (muss in -Pakete stehen, gross/klein genau) und 'status' (feste Liste).
    # name/von/auf kommen immer aus -Pakete. Unbekannte oder doppelte id -> Eintrag verworfen; hoechstens 200 Eintraege.
    param([AllowNull()]$Elemente, [AllowNull()][object[]]$Pakete)
    $liste = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Pakete) { return , $liste.ToArray() }
    $bekannt = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($p in @($Pakete)) {
        if ($null -eq $p) { continue }
        $pk = [string]$p.id
        if (($pk.Length -gt 0) -and (-not $bekannt.ContainsKey($pk))) { $bekannt[$pk] = $p }
    }
    if (($null -eq $Elemente) -or ($Elemente -is [string]) -or ($Elemente -is [System.Collections.IDictionary]) -or (-not ($Elemente -is [System.Collections.IEnumerable]))) { return , $liste.ToArray() }
    $erlaubt = Get-MorpheusFortschrittElementStatus
    $gesehen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $geprueft = 0
    foreach ($e in $Elemente) {
        # Obergrenze auch fuer die Pruefarbeit, nicht nur fuer die Ausgabe
        $geprueft++
        if (($geprueft -gt 1000) -or ($liste.Count -ge 200)) { break }
        if (-not ($e -is [System.Collections.IDictionary])) { continue }
        $id = $e['id']; $st = $e['status']
        if ((-not ($id -is [string])) -or (-not ($st -is [string]))) { continue }
        if (-not ($erlaubt -ccontains $st)) { continue }
        if (-not $bekannt.ContainsKey($id)) { continue }
        if (-not $gesehen.Add($id)) { continue }
        $p = $bekannt[$id]
        $liste.Add([ordered]@{ id = $id; name = [string]$p.name; von = [string]$p.von; auf = [string]$p.auf; status = $st })
    }
    return , $liste.ToArray()
}

# Scan-Fortschritt (2.8, #139, Variante A): Der Scan laeuft als eigener powershell.exe-Prozess; der Job sieht nur Text.
# Der Job erzeugt je Lauf eine Einmal-Kennung (32 Hex-Zeichen) und gibt sie per Umgebungsvariable MORPHEUS_FS weiter.
# Nur eine Zeile mit GENAU dieser Kennung zaehlt als Fortschritt; jede andere Zeile (auch mit falscher Kennung) bleibt Logzeile.
function Get-MorpheusScanMarkerMuster { '^@@MORPHEUS-FORTSCHRITT ([0-9a-f]{32}) ([0-9]{1,4}) ([0-9]{1,4}) ([0-9]{1,2}) ([0-9]{1,2}) (.{0,200})$' }

function Get-MorpheusScanMarkerDaten {
    # Reine Funktion. Rueckgabe: Hashtable fuer Write-MorpheusFortschritt (modus, i, n, phase, text, bereich, bereiche)
    # oder $null (keine Markerzeile mit der richtigen Kennung -> normale Logzeile).
    param([AllowNull()][string]$Zeile, [AllowNull()][string]$Kennung)
    if ([string]::IsNullOrEmpty($Kennung) -or ($Kennung -cnotmatch '^[0-9a-f]{32}$')) { return $null }
    if ([string]::IsNullOrEmpty($Zeile) -or (-not $Zeile.StartsWith('@@MORPHEUS-FORTSCHRITT ', [StringComparison]::Ordinal))) { return $null }
    $m = [regex]::Match($Zeile, (Get-MorpheusScanMarkerMuster))
    if (-not $m.Success) { return $null }
    if (-not ($m.Groups[1].Value -ceq $Kennung)) { return $null }
    return @{
        modus = 'zaehler'; phase = 'scan'
        i = [int]$m.Groups[2].Value; n = [int]$m.Groups[3].Value
        bereich = [int]$m.Groups[4].Value; bereiche = [int]$m.Groups[5].Value
        # Der Scan trennt mit ' > ' (ASCII, übersteht die Codepage der Konsole); angezeigt wird ' › '
        text = $m.Groups[6].Value.Replace(' > ', (' ' + [char]0x203A + ' '))
    }
}
