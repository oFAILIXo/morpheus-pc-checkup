#Requires -Version 5.1
<#
.SYNOPSIS
    Morpheus – PC Check-up: Texte auf Deutsch und Englisch (2.6, Karte #66).

.DESCRIPTION
    Alle Texte stehen in lang\<sprache>\*.psd1 im Programmordner (nur gelesen, Import-PowerShellDataFile führt keinen
    Code aus). Feste Dateiliste, kein Suchmuster:
    Je Datei höchstens 500 Schlüssel (Grenze von Import-PowerShellDataFile), deshalb mehrere Teile je Bereich:
    - scan.psd1, scannamen.psd1 (Anzeigenamen) und leistung.psd1 (Prüfungen, Präfix scan.), bericht.psd1 (Berichte, Konsole und Update-Dialog am Ende des
      Scans, Präfix bericht.), server.psd1 und serverlib.psd1 (GUI-Server, Starter, gui\lib, Präfix server.), katalog.psd1
      (Meldungen der Katalog-Scriptblöcke, Präfix katalog.), gui.psd1 und gui2.psd1 (Oberfläche, Präfix gui.):
      flache Tabellen Schlüssel -> Text.
      Platzhalter {0}, {1} … wie bei [string]::Format; eine wörtliche Klammer steht als {{ bzw. }}.
      Anzeigenamen fester deutscher Kennungen: scan.bereich.<Id>, scan.kategorie.<Id>, scan.pruefung.<Id>,
      scan.tabelle.<Titel>, scan.spalte.<Spalte> (Get-MorpheusAnzeige).
    - hilfe.psd1: Erklärungen und Tipps (Aufbau wie früher pc-check.hilfe.psd1)
    - aktionen.psd1: Titel, Erklärungen und Befehlsanzeige je Katalog-Aktion (Schlüssel = Aktions-Id)
    Die Sprache kommt aus $env:MORPHEUS_SPRACHE (setzt der GUI-Server für Jobs und Scan bzw. der Scan aus -Sprache),
    sonst aus <Datenordner>\state\sprache.json (nur 'de'/'en'), sonst aus der Windows-Sprache (de-* = Deutsch, sonst
    Englisch). Ein ungültiger Wert zählt nie, es gilt dann die nächste Quelle.
    Beim Dot-Sourcen wird nichts ausgeführt.
#>

$script:MorpheusSprachen = @('de', 'en')
$script:MorpheusTextTeile = @('scan', 'scannamen', 'leistung', 'bericht', 'server', 'serverlib', 'katalog', 'gui', 'gui2')

function Get-MorpheusSpracheRoot {
    # Programmordner: gui\lib\Sprache.ps1 -> zwei Ebenen höher
    Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

function Test-MorpheusSprache {
    param([AllowNull()]$Sprache)
    return (($Sprache -is [string]) -and ($script:MorpheusSprachen -ccontains $Sprache))
}

function Get-MorpheusWindowsSprache {
    $n = ''
    try { $n = [string](Get-UICulture).Name } catch { }
    if ($n -like 'de-*' -or $n -eq 'de') { return 'de' }
    return 'en'
}

function Read-MorpheusSpracheDatei {
    # state\sprache.json tolerant lesen: fehlend, kaputt oder ungültig = $null
    param([string]$DataRoot)
    if (-not $DataRoot) { return $null }
    try {
        $p = Join-Path $DataRoot 'state\sprache.json'
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        if ((Get-Item -LiteralPath $p).Length -gt 1024) { return $null }
        $o = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        $s = $o.sprache
        if (Test-MorpheusSprache $s) { return $s }
    }
    catch { }
    return $null
}

function Get-MorpheusSprache {
    # Gespeicherte Wahl, sonst Windows-Sprache
    param([string]$DataRoot)
    $s = Read-MorpheusSpracheDatei -DataRoot $DataRoot
    if ($s) { return $s }
    return (Get-MorpheusWindowsSprache)
}

function Get-MorpheusAktiveSprache {
    if (Test-MorpheusSprache $env:MORPHEUS_SPRACHE) { return $env:MORPHEUS_SPRACHE }
    return (Get-MorpheusWindowsSprache)
}

function Import-MorpheusSprachDatei {
    # Eine Sprachdatei aus dem Programmordner; fehlt sie, leere Tabelle
    param([string]$Sprache, [string]$Teil, [string]$Root)
    if (-not (Test-MorpheusSprache $Sprache)) { throw "Unbekannte Sprache '$Sprache'." }
    if (-not $Root) { $Root = Get-MorpheusSpracheRoot }
    $p = Join-Path $Root ('lang\{0}\{1}.psd1' -f $Sprache, $Teil)
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @{} }
    return (Import-PowerShellDataFile -LiteralPath $p)
}

function Import-MorpheusTexte {
    # Flache Texte der Sprache laden; Deutsch liegt darunter, damit ein fehlender Schlüssel nie leer bleibt
    param([string]$Sprache, [string]$Root)
    if (-not (Test-MorpheusSprache $Sprache)) { $Sprache = Get-MorpheusAktiveSprache }
    $t = @{}
    $folge = @('de')
    if ($Sprache -ne 'de') { $folge += $Sprache }
    foreach ($sp in $folge) {
        foreach ($teil in $script:MorpheusTextTeile) {
            $d = Import-MorpheusSprachDatei -Sprache $sp -Teil $teil -Root $Root
            foreach ($k in $d.Keys) { $t[[string]$k] = [string]$d[$k] }
        }
    }
    $global:MorpheusTexte = $t
    $global:MorpheusTexteSprache = $Sprache
    # Deutsche Texte getrennt, für Get-MorpheusDeutscherText (Akzeptanzregeln und Tipps vergleichen deutsche Befundtexte)
    $global:MorpheusTexteDe = $null
    if ($Sprache -ne 'de') {
        $de = @{}
        foreach ($teil in $script:MorpheusTextTeile) {
            $d = Import-MorpheusSprachDatei -Sprache 'de' -Teil $teil -Root $Root
            foreach ($k in $d.Keys) { $de[[string]$k] = [string]$d[$k] }
        }
        $global:MorpheusTexteDe = $de
    }
}

function Start-MorpheusTextSpur {
    # Ab jetzt merkt sich T zu jedem nicht deutschen Text die deutsche Fassung (nur im Scan)
    $global:MorpheusTextSpur = New-Object System.Collections.Generic.List[object]
}

function Get-MorpheusDeutscherText {
    # Deutsche Fassung eines Textes, der aus T-Ergebnissen zusammengesetzt ist: Jedes seit dem letzten Aufruf gemerkte
    # T-Ergebnis wird durch seine deutsche Fassung ersetzt (längste zuerst, nur an Wortgrenzen, damit z. B. „on“ nicht
    # mitten in einem Wort ersetzt wird). Leert danach die Spur.
    param([AllowEmptyString()][string]$Text)
    $spur = $global:MorpheusTextSpur
    if ($null -eq $spur) { return $Text }
    $s = $Text
    if ($s -and $spur.Count -gt 0) {
        foreach ($p in @($spur | Sort-Object { $_[0].Length } -Descending)) {
            if ($p[0] -and $s.Contains($p[0])) {
                $ersatz = $p[1]
                $s = [regex]::Replace($s, '(?<![\p{L}\p{N}])' + [regex]::Escape($p[0]) + '(?![\p{L}\p{N}])', { param($m) $ersatz })
            }
        }
    }
    $spur.Clear()
    return $s
}

function T {
    # Text zum Schlüssel, Platzhalter {0}, {1} … aus den weiteren Argumenten. Unbekannter Schlüssel = der Schlüssel selbst.
    param([Parameter(Mandatory, Position = 0)][string]$Key, [Parameter(Position = 1, ValueFromRemainingArguments)][object[]]$Werte)
    $sp = Get-MorpheusAktiveSprache
    if (-not $global:MorpheusTexte -or $global:MorpheusTexteSprache -ne $sp) { Import-MorpheusTexte -Sprache $sp }
    $s = $global:MorpheusTexte[$Key]
    if ($null -eq $s) { return $Key }
    # Auch ohne Werte formatieren, damit {{ und }} immer zu einer Klammer werden (wie t() in der Oberfläche)
    # $null-Vergleich statt -not: @(0) oder @('') gilt in PowerShell als falsch
    if ($null -eq $Werte) { $Werte = @() }
    if ($s.Contains('{') -or $s.Contains('}')) { try { $s = [string]::Format($s, [object[]]$Werte) } catch { } }
    if (($null -ne $global:MorpheusTextSpur) -and $global:MorpheusTexteDe) {
        $de = $global:MorpheusTexteDe[$Key]
        if ($null -ne $de) {
            if ($de.Contains('{') -or $de.Contains('}')) { try { $de = [string]::Format($de, [object[]]$Werte) } catch { } }
            if (($de -cne $s) -and ($global:MorpheusTextSpur.Count -lt 5000)) { $global:MorpheusTextSpur.Add(@($s, $de)) }
        }
    }
    return $s
}

function Get-MorpheusGuiTexte {
    # Alle gui.*-Texte der Sprache für die Oberfläche (Schlüssel ohne Präfix)
    param([string]$Sprache, [string]$Root)
    $alt = $global:MorpheusTexte; $altSp = $global:MorpheusTexteSprache
    Import-MorpheusTexte -Sprache $Sprache -Root $Root
    $out = @{}
    foreach ($k in $global:MorpheusTexte.Keys) { if ($k.StartsWith('gui.')) { $out[$k.Substring(4)] = $global:MorpheusTexte[$k] } }
    $global:MorpheusTexte = $alt; $global:MorpheusTexteSprache = $altSp
    return $out
}

function Get-MorpheusHilfe {
    # Erklärungen und Tipps; fehlt eine Prüfung in der Sprache, gilt die deutsche Fassung
    param([string]$Sprache, [string]$Root)
    if (-not (Test-MorpheusSprache $Sprache)) { $Sprache = Get-MorpheusAktiveSprache }
    $de = Import-MorpheusSprachDatei -Sprache 'de' -Teil 'hilfe' -Root $Root
    if ($Sprache -eq 'de') { return $de }
    $x = Import-MorpheusSprachDatei -Sprache $Sprache -Teil 'hilfe' -Root $Root
    foreach ($abschnitt in @($de.Keys)) {
        if (-not $x.ContainsKey($abschnitt)) { $x[$abschnitt] = $de[$abschnitt]; continue }
        if (($de[$abschnitt] -is [hashtable]) -and ($x[$abschnitt] -is [hashtable])) {
            foreach ($k in @($de[$abschnitt].Keys)) { if (-not $x[$abschnitt].ContainsKey($k)) { $x[$abschnitt][$k] = $de[$abschnitt][$k] } }
        }
    }
    return $x
}

function Get-MorpheusAnzeige {
    # Anzeigename für eine feste deutsche Kennung (Bereich, Kategorie, Prüfung, Tabelle, Spalte); ohne Übersetzung die Kennung
    param([Parameter(Mandatory)][string]$Art, [AllowEmptyString()][string]$Id)
    if (-not $Id) { return $Id }
    $k = 'scan.' + $Art + '.' + $Id
    $s = T $k
    if ($s -ceq $k) { return $Id }
    return $s
}
