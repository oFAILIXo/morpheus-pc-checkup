#Requires -Version 5.1
<#
.SYNOPSIS
    Akzeptanzliste (accepted.psd1) lesen, pruefen und atomar schreiben (v2.3.1) fuer Morpheus - PC Check-up.

.DESCRIPTION
    Wird per Dot-Source geladen. Definiert die Funktionen aus docs/gui-architektur.md, Abschnitt 16.1.
    Beim Dot-Sourcen wird nichts ausgefuehrt. Kein Add-Type, kein Netz.
    Gelesen wird die Datei als Bytes (BOM beachtet; ohne BOM erst striktes UTF-8, sonst ANSI) und mit dem
    PowerShell-Parser ausgewertet (oberster Hashtable-Ausdruck per SafeGetValue, wie Import-PowerShellDataFile:
    Daten, kein Code). Geschrieben wird jeder Wert als '...' (Hochkommas, auch typografische, per
    EscapeSingleQuotedStringContent verdoppelt). Vor dem Ersetzen wird die .tmp-Datei zur Probe gelesen und
    mit den Regeln verglichen; bei Abweichung bleibt die alte Datei unveraendert.

    Hand-Regeln: Unbekannte Schluessel bleiben beim Umschreiben erhalten (Werte als String). Steuerzeichen in
    vorhandenen Regeln werden beim Schreiben durch ein Leerzeichen ersetzt. Eintraege in Accepted, die keine
    Hashtable sind, werden beim Lesen ignoriert und beim Schreiben verworfen.

    Rueckgaben: Funktionen, die Listen liefern, geben die Elemente einzeln aus. Aufrufer muessen
    das Ergebnis mit @() umhuellen (leer = nichts, ein Element = kein Array).
#>

#region Hilfsfunktionen (privat)

$script:AkzeptanzFelder = @('Id', 'Check', 'Match', 'Datei', 'Sha256', 'Reason', 'Until', 'Erstellt')
$script:AkzeptanzMaxRegeln = 500
$script:AkzeptanzMaxHistorie = 1000
$script:AkzeptanzSigcheckName = 'Systemdateien: Signaturen (Sigcheck)'

# Feldwert einer Regel (Hashtable, geordnetes Dictionary oder Objekt), unabhaengig von der Schreibweise; sonst ''
function PcCheckAkzWert {
    param($Regel, [string]$Name)
    if ($null -eq $Regel) { return '' }
    $v = $null
    if ($Regel -is [System.Collections.IDictionary]) {
        foreach ($k in @($Regel.Keys)) {
            if ([string]$k -ieq $Name) { $v = $Regel[$k]; break }
        }
    } else {
        $p = $Regel.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
        if ($p) { $v = $p.Value }
    }
    if ($null -eq $v) { return '' }
    if ($v -is [datetime]) { return $v.ToString('yyyy-MM-dd') }
    [string]$v
}

# Steuerzeichen: C0, DEL, C1, Zeilen-/Absatztrenner
$script:AkzeptanzSteuerRegex = '[\x00-\x1F\x7F-\x9F\u2028\u2029]'

function PcCheckAkzSteuerzeichen {
    param([string]$Text)
    [regex]::IsMatch($Text, $script:AkzeptanzSteuerRegex)
}

# Datum (yyyy-MM-dd) oder $null
function PcCheckAkzDatum {
    param([string]$Text)
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    $null
}

# Abgelaufen? Leer = nie; unlesbares Datum = abgelaufen (sicherer Fall)
function PcCheckAkzAbgelaufen {
    param([string]$Until, [datetime]$Heute)
    if ($Until -eq '') { return $false }
    $d = PcCheckAkzDatum $Until
    if ($null -eq $d) {
        try { $d = [datetime]$Until } catch { $d = $null }
    }
    if ($null -eq $d) { return $true }
    ($d.Date -lt $Heute.Date)
}

function PcCheckAkzHex {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    } finally { $sha.Dispose() }
    (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function PcCheckAkzNeueId {
    param([string[]]$Vorhanden)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        do {
            $b = New-Object byte[] 4
            $rng.GetBytes($b)
            $id = (($b | ForEach-Object { $_.ToString('x2') }) -join '')
        } while ($Vorhanden -contains $id)
    } finally { $rng.Dispose() }
    $id
}

# Wert fuer '...' maskieren (auch typografische Hochkommas)
function PcCheckAkzEscape {
    param([string]$Wert)
    [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Wert)
}

# Bytes -> Text: BOM beachten; ohne BOM striktes UTF-8, sonst ANSI
function PcCheckAkzBytesZuText {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    try {
        $strikt = New-Object System.Text.UTF8Encoding($false, $true)
        return $strikt.GetString($Bytes)
    } catch {
        return [Text.Encoding]::Default.GetString($Bytes)
    }
}

# psd1-Text -> Hashtables der Accepted-Liste (Elemente einzeln); Parse-Fehler / kein Hashtable -> throw
function PcCheckAkzTextParsen {
    param([string]$Text)
    $Text = $Text.TrimStart([char]0xFEFF)
    $tokens = $null
    $fehler = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$fehler)
    if (@($fehler).Count -gt 0) { throw @($fehler)[0].Message }
    $anw = @($ast.EndBlock.Statements)
    if (($anw.Count -ne 1) -or ($anw[0] -isnot [System.Management.Automation.Language.PipelineAst])) {
        throw 'Erwartet wird genau ein Hashtable (@{ ... }).'
    }
    $elemente = @($anw[0].PipelineElements)
    if (($elemente.Count -ne 1) -or ($elemente[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) -or
        ($elemente[0].Expression -isnot [System.Management.Automation.Language.HashtableAst])) {
        throw 'Erwartet wird genau ein Hashtable (@{ ... }).'
    }
    try {
        $daten = $elemente[0].Expression.SafeGetValue()
    } catch {
        throw "Die Datei enthaelt mehr als reine Daten: $($_.Exception.Message)"
    }
    $liste = $null
    if ($daten -is [System.Collections.IDictionary]) {
        foreach ($k in @($daten.Keys)) { if ([string]$k -ieq 'Accepted') { $liste = $daten[$k] } }
    }
    foreach ($r in @($liste)) {
        if ($null -eq $r) { continue }
        if (-not ($r -is [System.Collections.IDictionary])) { continue }
        $r
    }
}

# Datei -> Hashtables; fehlende Datei -> nichts; unlesbar -> throw
function PcCheckAkzDateiParsen {
    param([string]$Datei)
    if (-not (Test-Path -LiteralPath $Datei -PathType Leaf)) { return }
    try {
        $text = PcCheckAkzBytesZuText ([IO.File]::ReadAllBytes($Datei))
        PcCheckAkzTextParsen $text
    } catch {
        throw "Die Akzeptanzliste ist nicht lesbar: $($_.Exception.Message)"
    }
}

# Hashtable aus der Datei -> geordnetes Dictionary: Id, bekannte Felder, danach unbekannte Schluessel (alles String)
function PcCheckAkzRoh {
    param([System.Collections.IDictionary]$Eintrag)
    $r = [ordered]@{}
    foreach ($f in $script:AkzeptanzFelder) { $r[$f] = (PcCheckAkzWert $Eintrag $f) }
    foreach ($k in @($Eintrag.Keys)) {
        $name = [string]$k
        $bekannt = $false
        foreach ($f in $script:AkzeptanzFelder) { if ($name -ieq $f) { $bekannt = $true; break } }
        if ($bekannt) { continue }
        $v = $Eintrag[$k]
        if ($null -eq $v) { continue }
        if ($v -is [datetime]) { $v = $v.ToString('yyyy-MM-dd') }
        $r[$name] = [string]$v
    }
    $r
}

# Regel (Roh-Dictionary) in die Ausgabeform bringen; $AbgeleiteteId nur fuer Hand-Regeln
function PcCheckAkzAlsObjekt {
    param($Regel, [datetime]$Heute, [string]$AbgeleiteteId = '')
    $id = PcCheckAkzWert $Regel 'Id'
    $check = PcCheckAkzWert $Regel 'Check'
    $match = PcCheckAkzWert $Regel 'Match'
    $reason = PcCheckAkzWert $Regel 'Reason'
    $until = PcCheckAkzWert $Regel 'Until'
    $datei = PcCheckAkzWert $Regel 'Datei'
    $sha = PcCheckAkzWert $Regel 'Sha256'
    $erstellt = PcCheckAkzWert $Regel 'Erstellt'
    $quelle = 'gui'
    if ($id -cnotmatch '^[0-9a-f]{8}$') {
        $quelle = 'hand'
        $id = $AbgeleiteteId
    }
    [pscustomobject]@{
        id         = $id
        check      = $check
        match      = $match
        reason     = $reason
        until      = $until
        datei      = $datei
        sha256     = $sha
        erstellt   = $erstellt
        quelle     = $quelle
        abgelaufen = (PcCheckAkzAbgelaufen $until $Heute)
    }
}

# Datei laden: @{ Roh = List der Roh-Dictionaries; Objekte = List der Ausgabeobjekte (gleiche Reihenfolge) }
function PcCheckAkzLaden {
    param([string]$Datei, [datetime]$Heute)
    $roh = New-Object System.Collections.Generic.List[object]
    $obj = New-Object System.Collections.Generic.List[object]
    $zaehler = @{}
    foreach ($e in @(PcCheckAkzDateiParsen $Datei)) {
        if ($null -eq $e) { continue }
        $r = PcCheckAkzRoh $e
        $abg = ''
        if ($r['Id'] -cnotmatch '^[0-9a-f]{8}$') {
            $schluessel = ($r['Check'], $r['Match'], $r['Reason'], $r['Until'], $r['Datei'], $r['Sha256']) -join '|'
            $n = 0
            if ($zaehler.ContainsKey($schluessel)) { $n = [int]$zaehler[$schluessel] }
            $zaehler[$schluessel] = $n + 1
            $abg = 'h' + (PcCheckAkzHex ($schluessel + '|' + $n)).Substring(0, 11)
        }
        $roh.Add($r)
        $obj.Add((PcCheckAkzAlsObjekt -Regel $r -Heute $Heute -AbgeleiteteId $abg))
    }
    @{ Roh = $roh; Objekte = $obj }
}

# Felder einer Regel als Liste von @{ N; W } (nur nicht leere; feste Reihenfolge, Extras am Ende)
function PcCheckAkzFelderListe {
    param($Regel, [bool]$Ersetzen)
    $liste = New-Object System.Collections.Generic.List[object]
    $namen = New-Object System.Collections.Generic.List[string]
    foreach ($f in $script:AkzeptanzFelder) { $namen.Add($f) }
    if ($Regel -is [System.Collections.IDictionary]) {
        foreach ($k in @($Regel.Keys)) {
            $name = [string]$k
            $bekannt = $false
            foreach ($f in $script:AkzeptanzFelder) { if ($name -ieq $f) { $bekannt = $true; break } }
            if (-not $bekannt) { $namen.Add($name) }
        }
    }
    foreach ($f in $namen) {
        $w = PcCheckAkzWert $Regel $f
        if ($f -eq 'Id') {
            # GUI-Id und fremde Hand-Ids bleiben; abgeleitete h-Ids werden nie geschrieben
            if ($w -cmatch '^h[0-9a-f]{11}$') { $w = '' }
        }
        if ($w -eq '') { continue }
        if (PcCheckAkzSteuerzeichen $w) {
            if (-not $Ersetzen) { throw "Das Feld '$f' enthaelt Steuerzeichen." }
            $w = [regex]::Replace($w, $script:AkzeptanzSteuerRegex, ' ')
        }
        $n = $f
        if (PcCheckAkzSteuerzeichen $n) { $n = [regex]::Replace($n, $script:AkzeptanzSteuerRegex, ' ') }
        $liste.Add(@{ N = $n; W = $w })
    }
    ,$liste
}

# Regeln -> Liste der Feldlisten (Regeln ohne Felder entfallen)
function PcCheckAkzPaare {
    param([object[]]$Regeln, [bool]$Ersetzen)
    $alle = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Regeln)) {
        if ($null -eq $r) { continue }
        $felder = PcCheckAkzFelderListe -Regel $r -Ersetzen $Ersetzen
        if ($felder.Count -eq 0) { continue }
        $alle.Add($felder)
    }
    ,$alle
}

function PcCheckAkzPsd1Text {
    param($Paare)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Akzeptanzliste von Morpheus - PC Check-up.')
    [void]$sb.AppendLine('# Diese Datei wird von Morpheus geschrieben. Handaenderungen bleiben als Regeln erhalten, Kommentare nicht.')
    [void]$sb.AppendLine('@{')
    [void]$sb.AppendLine('    Accepted = @(')
    foreach ($felder in $Paare) {
        $teile = @()
        foreach ($p in $felder) {
            $n = $p.N
            if ($n -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $n = "'" + (PcCheckAkzEscape $n) + "'" }
            $teile += ("{0} = '{1}'" -f $n, (PcCheckAkzEscape $p.W))
        }
        [void]$sb.AppendLine('        @{ ' + ($teile -join '; ') + ' }')
    }
    [void]$sb.AppendLine('    )')
    [void]$sb.AppendLine('}')
    $sb.ToString()
}

# Probe: geschriebene Datei lesen und mit den erwarteten Feldern vergleichen; sonst throw
function PcCheckAkzProbe {
    param([string]$Pfad, $Paare)
    $fehlt = 'Die Akzeptanzliste ließ sich nicht sicher schreiben; die bisherige Datei bleibt unverändert.'
    try {
        $gelesen = @(PcCheckAkzTextParsen (PcCheckAkzBytesZuText ([IO.File]::ReadAllBytes($Pfad))))
    } catch { throw $fehlt }
    if ($gelesen.Count -ne $Paare.Count) { throw $fehlt }
    for ($i = 0; $i -lt $gelesen.Count; $i++) {
        $g = $gelesen[$i]
        $erwartet = $Paare[$i]
        if (@($g.Keys).Count -ne $erwartet.Count) { throw $fehlt }
        foreach ($p in $erwartet) {
            $gefunden = $false
            foreach ($k in @($g.Keys)) {
                if ([string]$k -ceq $p.N) {
                    $gefunden = $true
                    if (-not (([string]$g[$k]) -ceq $p.W)) { throw $fehlt }
                }
            }
            if (-not $gefunden) { throw $fehlt }
        }
    }
}

# Text atomar schreiben: erst <Datei>.tmp, optional Probe, vorhandene Datei vorher nach <Datei>.bak (optional), dann ersetzen
function PcCheckAkzSchreiben {
    param([string]$Datei, [string]$Text, [bool]$Bom, [bool]$Sicherung, $ProbePaare = $null)
    $ordner = Split-Path -Path $Datei -Parent
    if ($ordner -and -not (Test-Path -LiteralPath $ordner -PathType Container)) {
        throw "Der Ordner '$ordner' existiert nicht."
    }
    $tmp = $Datei + '.tmp'
    $enc = New-Object System.Text.UTF8Encoding($Bom)
    [IO.File]::WriteAllText($tmp, $Text, $enc)
    try {
        if ($null -ne $ProbePaare) { PcCheckAkzProbe -Pfad $tmp -Paare $ProbePaare }
        if (Test-Path -LiteralPath $Datei -PathType Leaf) {
            if ($Sicherung) { Copy-Item -LiteralPath $Datei -Destination ($Datei + '.bak') -Force }
            [IO.File]::Replace($tmp, $Datei, [NullString]::Value)
        } else {
            [IO.File]::Move($tmp, $Datei)
        }
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

#endregion

#region Lesen und Schreiben

# Array { id, check, match, reason, until, datei, sha256, erstellt, quelle, abgelaufen }; fehlende Datei -> nichts; unlesbar -> throw
function Read-MorpheusAkzeptanz {
    param([Parameter(Mandatory)][string]$Datei, [datetime]$Heute = (Get-Date).Date)
    $l = PcCheckAkzLaden -Datei $Datei -Heute $Heute
    foreach ($o in $l.Objekte) { $o }
}

# psd1-Text aus Regeln (Reihenfolge bleibt, feste Feldreihenfolge, leere Felder entfallen, unbekannte Schluessel am Ende)
function ConvertTo-MorpheusAkzeptanzPsd1 {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Regeln, [switch]$SteuerzeichenErsetzen)
    $paare = PcCheckAkzPaare -Regeln $Regeln -Ersetzen ([bool]$SteuerzeichenErsetzen)
    PcCheckAkzPsd1Text $paare
}

# Regeln (Roh-Dictionaries) in die Datei schreiben (mit .bak, UTF-8 mit BOM, Probe-Lesen vor dem Ersetzen)
function PcCheckAkzSpeichern {
    param([string]$Datei, [object[]]$Regeln)
    $paare = PcCheckAkzPaare -Regeln $Regeln -Ersetzen $true
    $text = PcCheckAkzPsd1Text $paare
    PcCheckAkzSchreiben -Datei $Datei -Text $text -Bom $true -Sicherung $true -ProbePaare $paare
}

# Pruefregeln aus Abschnitt 16.1; wirft mit kurzer deutscher Meldung
function PcCheckAkzPruefen {
    param($Regel, [datetime]$Heute)
    $check = PcCheckAkzWert $Regel 'Check'
    $reason = PcCheckAkzWert $Regel 'Reason'
    $until = PcCheckAkzWert $Regel 'Until'
    $match = PcCheckAkzWert $Regel 'Match'
    $datei = PcCheckAkzWert $Regel 'Datei'
    $sha = PcCheckAkzWert $Regel 'Sha256'
    foreach ($f in 'Check', 'Match', 'Reason', 'Until', 'Datei', 'Sha256') {
        if (PcCheckAkzSteuerzeichen (PcCheckAkzWert $Regel $f)) { throw "Das Feld '$f' darf keine Steuerzeichen enthalten." }
    }
    if (($check.Length -lt 1) -or ($check.Length -gt 200)) { throw 'Der Name der Pruefung muss 1 bis 200 Zeichen lang sein.' }
    $rl = $reason.Trim().Length
    if (($rl -lt 3) -or ($rl -gt 300)) { throw 'Die Begruendung muss 3 bis 300 Zeichen lang sein.' }
    if ($until -ne '') {
        if ($until -notmatch '^\d{4}-\d{2}-\d{2}$') { throw "'Gilt bis' muss ein Datum im Format JJJJ-MM-TT sein." }
        $d = PcCheckAkzDatum $until
        if ($null -eq $d) { throw "'Gilt bis' ist kein gueltiges Datum." }
        if ($d -lt $Heute.Date) { throw "'Gilt bis' darf nicht in der Vergangenheit liegen." }
        if ($d -gt $Heute.Date.AddYears(5)) { throw "'Gilt bis' darf hoechstens 5 Jahre in der Zukunft liegen." }
    }
    if ($match.Length -gt 2000) { throw 'Das Muster ist zu lang (hoechstens 2000 Zeichen).' }
    if ($match -ne '') {
        try { [void](New-Object System.Text.RegularExpressions.Regex($match)) }
        catch { throw 'Das Muster ist kein gueltiger regulaerer Ausdruck.' }
    }
    if (($datei -ne '') -or ($sha -ne '')) {
        if (($datei -eq '') -or ($sha -eq '')) { throw 'Datei und Pruefsumme (SHA256) gehoeren zusammen.' }
        if ($sha -cnotmatch '^[0-9a-f]{64}$') { throw 'Die SHA256-Pruefsumme muss aus 64 Hex-Zeichen (Kleinbuchstaben) bestehen.' }
        if ($datei -notmatch '^[A-Za-z]:\\') { throw 'Der Dateipfad muss mit einem Laufwerk beginnen (z. B. C:\).' }
        if ($datei.Length -gt 260) { throw 'Der Dateipfad ist zu lang (hoechstens 260 Zeichen).' }
    }
}

# Vollstaendige Pruefung fuer Add (Regeln, Datei lesbar, Limit, Duplikat); wirft mit Text, gibt die geladene Liste zurueck
function PcCheckAkzVollPruefen {
    param([string]$Datei, $Regel, [datetime]$Heute)
    PcCheckAkzPruefen -Regel $Regel -Heute $Heute
    $ordner = Split-Path -Path $Datei -Parent
    if ($ordner -and -not (Test-Path -LiteralPath $ordner -PathType Container)) {
        throw "Der Ordner '$ordner' existiert nicht."
    }
    $l = PcCheckAkzLaden -Datei $Datei -Heute $Heute
    if ($l.Objekte.Count -ge $script:AkzeptanzMaxRegeln) {
        throw "Die Akzeptanzliste ist voll (hoechstens $($script:AkzeptanzMaxRegeln) Regeln)."
    }
    $check = PcCheckAkzWert $Regel 'Check'
    $match = PcCheckAkzWert $Regel 'Match'
    $datei = PcCheckAkzWert $Regel 'Datei'
    $sha = PcCheckAkzWert $Regel 'Sha256'
    foreach ($o in $l.Objekte) {
        if ($o.abgelaufen) { continue }
        $gleich = $false
        if ($datei -ne '') {
            $gleich = ($o.datei -ieq $datei) -and ($o.sha256 -ieq $sha)
        } else {
            $gleich = ($o.datei -eq '') -and ($o.check -ceq $check) -and ($o.match -ceq $match)
        }
        if ($gleich) { throw 'Das ist bereits akzeptiert.' }
    }
    $l
}

# $null, wenn Add mit dieser Regel klappen wuerde, sonst deutscher Fehlertext
function Test-MorpheusAkzeptanzRegel {
    param(
        [Parameter(Mandatory)][string]$Datei,
        [Parameter(Mandatory)][hashtable]$Regel,
        [datetime]$Heute = (Get-Date).Date
    )
    try {
        [void](PcCheckAkzVollPruefen -Datei $Datei -Regel $Regel -Heute $Heute)
    } catch {
        return [string]$_.Exception.Message
    }
    return $null
}

# Regel (Leseformat) zur Id oder $null
function Get-MorpheusAkzeptanzRegel {
    param([Parameter(Mandatory)][string]$Datei, [Parameter(Mandatory)][string]$Id)
    foreach ($o in @(Read-MorpheusAkzeptanz -Datei $Datei)) {
        if ($o.id -ceq $Id) { return $o }
    }
    return $null
}

# Neue Regel pruefen, Id und Erstellt vergeben, atomar schreiben; gibt die neue Regel (Ausgabeform) zurueck
function Add-MorpheusAkzeptanz {
    param(
        [Parameter(Mandatory)][string]$Datei,
        [Parameter(Mandatory)][hashtable]$Regel,
        [datetime]$Heute = (Get-Date).Date
    )
    $l = PcCheckAkzVollPruefen -Datei $Datei -Regel $Regel -Heute $Heute
    $id = PcCheckAkzNeueId -Vorhanden @($l.Objekte | ForEach-Object { $_.id })
    $neu = [ordered]@{
        Id       = $id
        Check    = (PcCheckAkzWert $Regel 'Check')
        Match    = (PcCheckAkzWert $Regel 'Match')
        Datei    = (PcCheckAkzWert $Regel 'Datei')
        Sha256   = (PcCheckAkzWert $Regel 'Sha256')
        Reason   = (PcCheckAkzWert $Regel 'Reason').Trim()
        Until    = (PcCheckAkzWert $Regel 'Until')
        Erstellt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    }
    PcCheckAkzSpeichern -Datei $Datei -Regeln (@($l.Roh.ToArray()) + @($neu))
    PcCheckAkzAlsObjekt -Regel $neu -Heute $Heute
}

# Genau eine Regel entfernen (unbekannte Id -> throw); gibt die entfernte Regel zurueck
function Remove-MorpheusAkzeptanz {
    param([Parameter(Mandatory)][string]$Datei, [Parameter(Mandatory)][string]$Id)
    $l = PcCheckAkzLaden -Datei $Datei -Heute (Get-Date).Date
    $index = -1
    for ($i = 0; $i -lt $l.Objekte.Count; $i++) {
        if ($l.Objekte[$i].id -ceq $Id) { $index = $i; break }
    }
    if ($index -lt 0) { throw 'Diese Regel gibt es nicht (mehr).' }
    $ziel = $l.Objekte[$index]
    $rest = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $l.Roh.Count; $i++) {
        if ($i -ne $index) { $rest.Add($l.Roh[$i]) }
    }
    PcCheckAkzSpeichern -Datei $Datei -Regeln $rest.ToArray()
    $ziel
}

#endregion

#region Historie

# Eintrag { zeit, art, regel, benutzer } an das JSON-Array haengen (max. 1000, UTF-8 ohne BOM, atomar)
function Add-MorpheusAkzeptanzHistorie {
    param(
        [Parameter(Mandatory)][string]$Datei,
        [Parameter(Mandatory)][ValidateSet('akzeptiert', 'zurueckgenommen')][string]$Art,
        [Parameter(Mandatory)]$Regel,
        [Parameter(Mandatory)][string]$Benutzer
    )
    $eintraege = @()
    if (Test-Path -LiteralPath $Datei -PathType Leaf) {
        $ok = $false
        try {
            $roh = [IO.File]::ReadAllText($Datei, [Text.Encoding]::UTF8).Trim([char]0xFEFF).Trim()
            if ($roh -eq '[]') { $eintraege = @(); $ok = $true }
            elseif ($roh.StartsWith('[')) {
                $eintraege = @(ConvertFrom-Json -InputObject $roh -ErrorAction Stop | ForEach-Object { $_ })
                $ok = $true
            }
        } catch { $ok = $false }
        if (-not $ok) {
            $eintraege = @()
            Move-Item -LiteralPath $Datei -Destination ($Datei + '.kaputt') -Force
        }
    }
    $eintrag = [ordered]@{
        zeit     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        art      = $Art
        regel    = $Regel
        benutzer = $Benutzer
    }
    $alle = @($eintraege) + @($eintrag)
    if ($alle.Count -gt $script:AkzeptanzMaxHistorie) {
        $alle = @($alle | Select-Object -Last $script:AkzeptanzMaxHistorie)
    }
    $json = ConvertTo-Json -InputObject @($alle) -Depth 6
    PcCheckAkzSchreiben -Datei $Datei -Text $json -Bom $false -Sicherung $false
}

#endregion

#region Suchen

# Passende, nicht abgelaufene Datei-Regel oder $null. Rein (kein Dateizugriff).
# Nur Regeln, deren check per -like auf den Sigcheck-Namen passt; unlesbares Until gilt als abgelaufen.
function Find-MorpheusAkzeptanzDatei {
    param(
        [AllowEmptyCollection()][object[]]$Regeln = @(),
        [Parameter(Mandatory)][string]$Pfad,
        [Parameter(Mandatory)][string]$Sha256,
        [datetime]$Heute = (Get-Date).Date
    )
    foreach ($r in @($Regeln)) {
        if ($null -eq $r) { continue }
        $check = PcCheckAkzWert $r 'check'
        if ($check -eq '') { continue }
        if (-not ($script:AkzeptanzSigcheckName -like $check)) { continue }
        $datei = PcCheckAkzWert $r 'datei'
        $sha = PcCheckAkzWert $r 'sha256'
        if (($datei -eq '') -or ($sha -eq '')) { continue }
        if ($datei -ine $Pfad) { continue }
        if ($sha -ine $Sha256) { continue }
        if (PcCheckAkzAbgelaufen (PcCheckAkzWert $r 'until') $Heute) { continue }
        return $r
    }
    return $null
}

#endregion
