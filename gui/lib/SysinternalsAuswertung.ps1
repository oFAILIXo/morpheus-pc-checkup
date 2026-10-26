#Requires -Version 5.1
# Morpheus - Auswertung der Sysinternals-Ausgaben (Autoruns, Sigcheck). Vertrag: docs\gui-architektur.md, Abschnitt 15.4.
# Reine Auswertung: kein Netz, keine Prozessstarts, kein Add-Type. Beim Dot-Sourcen werden nur Definitionen angelegt.
# Die Ausgaben der Werkzeuge sind Daten: Steuerzeichen werden entfernt, Felder auf 2048 Zeichen und Ausgaben auf
# 5000 Eintraege begrenzt. Angezeigt wird nur ueber die vorhandene HTML-Kodierung (h()/textContent).
# Bewertung: Geplante Aufgaben (Kategorie Tasks/ScheduledTasks) sind nur ueber -Aufgaben (Name -> Bool) erhoeht.
# Dienste und Treiber haben im Scan eigene Pruefungen und fuehren in Signatur-/Pfad-Befund hoechstens zu INFO.
# Test-MorpheusSysKopf prueft, ob eine CSV-Kopfzeile vorhanden ist (Werkzeug lieferte CSV oder nicht).
# Beschreibbar: Datei mit voller Schreibmaske, Elternordner nur mit Austausch-/Loesch-Rechten.

$script:MorpheusSysAwMaxFeld = 2048
$script:MorpheusSysAwMaxEintraege = 5000
$script:MorpheusSysAwMaxNamen = 5

# Schreibrechte wie $script:MorpheusWriteMask in Install.ps1 (bewusst eigene Kopie, damit diese Datei unabhaengig bleibt).
$script:MorpheusSysAwSchreibMaske = (0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000)
# Administratoren, SYSTEM, TrustedInstaller
$script:MorpheusSysAwVertraut = @(
    'S-1-5-32-544',
    'S-1-5-18',
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
)
# Fuer die Rechtepruefung unerheblich: ERSTELLER-BESITZER, BESITZERRECHTE
$script:MorpheusSysAwIgnoriert = @('S-1-3-0', 'S-1-3-4')

# Fuer den Elternordner zaehlen nur Rechte, mit denen sich die Datei austauschen, loeschen oder umbenennen laesst
# (wie $script:MorpheusParentMask in Install.ps1). "Dateien anlegen" allein genuegt nicht (C:\ProgramData vererbt es).
$script:MorpheusSysAwElternMaske = (0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000)

# Kategorien, die als SYSTEM, Dienst oder Kernel laufen (ohne Leerzeichen, Gross-/Kleinschreibung egal).
# Geplante Aufgaben (autorunsc: 'Tasks', GUI: 'Scheduled Tasks') sind NICHT pauschal erhoeht, siehe -Aufgaben.
$script:MorpheusSysAwErhoehteKategorien = @(
    'Services', 'Drivers', 'Winlogon', 'BootExecute', 'LSAProviders', 'PrintMonitors',
    'KnownDLLs', 'WinsockProviders', 'NetworkProviders', 'WMI', 'ImageHijacks', 'AppInit'
)
# Kategorien mit eigenen Pruefungen im Scan (Dienste, Dienstpfade, Treiber)
$script:MorpheusSysAwDienstKategorien = @('Services', 'Drivers')

#region Hilfsfunktionen (privat)

# Entfernt Steuer- und Bidi-Zeichen (durch Leerzeichen ersetzt), kuerzt Leerraum und begrenzt die Laenge.
function MorpheusSysAwBereinigen {
    param($Wert)
    if ($null -eq $Wert) { return '' }
    $s = [string]$Wert
    $s = [regex]::Replace($s, '[\u0000-\u001F\u007F\u2028\u2029\u202A-\u202E\u2066-\u2069]+', ' ')
    $s = $s.Trim()
    if ($s.Length -gt $script:MorpheusSysAwMaxFeld) { $s = $s.Substring(0, $script:MorpheusSysAwMaxFeld).Trim() }
    $s
}

# Spaltenname (klein) -> Index
function MorpheusSysAwSpaltenIndex {
    param([string[]]$Kopf)
    $map = @{}
    for ($i = 0; $i -lt $Kopf.Count; $i++) {
        $n = (MorpheusSysAwBereinigen $Kopf[$i]).ToLowerInvariant()
        if ((-not $map.ContainsKey($n)) -and ($n.Length -gt 0)) { $map[$n] = $i }
    }
    $map
}

function MorpheusSysAwFeld {
    param([string[]]$Zeile, [hashtable]$Index, [string]$Name)
    $key = $Name.ToLowerInvariant()
    if (-not $Index.ContainsKey($key)) { return '' }
    $i = [int]$Index[$key]
    if ($i -ge $Zeile.Count) { return '' }
    MorpheusSysAwBereinigen $Zeile[$i]
}

function MorpheusSysAwProp {
    param($Objekt, [string]$Name)
    if ($null -eq $Objekt) { return $null }
    $p = $Objekt.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    $p.Value
}

# Liefert den Vergleichsschluessel eines Pfads fuer den Cache
function MorpheusSysAwCacheWert {
    param([string]$Pfad, [hashtable]$Cache, [scriptblock]$Block)
    $key = $Pfad.ToLowerInvariant()
    if ($Cache.ContainsKey($key)) { return $Cache[$key] }
    $r = $null
    try { $r = & $Block $Pfad } catch { $r = $null }
    if ($r -is [array]) { $r = $r | Select-Object -Last 1 }
    $Cache[$key] = $r
    $r
}

# Kopie des Eintrags mit zusaetzlichen Eigenschaften (Eingabe bleibt unveraendert)
function MorpheusSysAwErgaenzen {
    param($Eintrag, [hashtable]$Zusatz)
    $c = $Eintrag.PSObject.Copy()
    foreach ($k in $Zusatz.Keys) { Add-Member -InputObject $c -NotePropertyName $k -NotePropertyValue $Zusatz[$k] -Force }
    $c
}

# 'A, B, C, D, E, ...' (hoechstens 5 Namen)
function MorpheusSysAwNamenListe {
    param([string[]]$Namen)
    $u = @($Namen | Where-Object { $_ } | Select-Object -Unique)
    $max = $script:MorpheusSysAwMaxNamen
    $teil = @($u | Select-Object -First $max)
    $s = $teil -join ', '
    if ($u.Count -gt $max) { $s += ', ' + [string][char]0x2026 }
    $s
}

function MorpheusSysAwEintragName {
    param($Eintrag)
    $n = [string](MorpheusSysAwProp $Eintrag 'Eintrag')
    if ([string]::IsNullOrWhiteSpace($n)) {
        $p = [string](MorpheusSysAwProp $Eintrag 'Pfad')
        if ($p) { $n = ($p -split '[\\/]')[-1] }
    }
    $n
}

# Kopfzeile der Autoruns-CSV suchen: @{ Index; Zeile } oder $null (gemeinsam fuer Parser und Test-MorpheusSysKopf)
function MorpheusSysAwKopfAutoruns {
    param($Zeilen)
    for ($r = 0; $r -lt $Zeilen.Count; $r++) {
        $m = MorpheusSysAwSpaltenIndex $Zeilen[$r]
        if ($m.ContainsKey('entry location') -and $m.ContainsKey('image path')) { return @{ Index = $m; Zeile = $r } }
    }
    $null
}

# Kopfzeile der Sigcheck-CSV suchen (erstes Feld 'Path')
function MorpheusSysAwKopfSigcheck {
    param($Zeilen)
    for ($r = 0; $r -lt $Zeilen.Count; $r++) {
        $z = $Zeilen[$r]
        if (($z.Count -gt 0) -and ((MorpheusSysAwBereinigen $z[0]) -ieq 'Path')) {
            return @{ Index = (MorpheusSysAwSpaltenIndex $z); Zeile = $r }
        }
    }
    $null
}

# $true, wenn die Rechte-Bits die Maske beruehren
function MorpheusSysAwRegelSchreibt {
    param([int]$Rechte, [int]$Maske)
    (($Rechte -band $Maske) -ne 0)
}

# Schluessel einer geplanten Aufgabe: Trim, klein, fuehrendes Backslash
function MorpheusSysAwAufgabenSchluessel {
    param($Name)
    $s = (MorpheusSysAwBereinigen $Name).ToLowerInvariant()
    if (($s.Length -gt 0) -and (-not $s.StartsWith('\'))) { $s = '\' + $s }
    $s
}

function MorpheusSysAwKategorie {
    param($Eintrag)
    ([string](MorpheusSysAwProp $Eintrag 'Kategorie')) -replace '\s', ''
}

function MorpheusSysAwIstDienstTreiber {
    param($Eintrag)
    $k = MorpheusSysAwKategorie $Eintrag
    [bool]($script:MorpheusSysAwDienstKategorien -contains $k)
}

function MorpheusSysAwBefund {
    param([string]$Status, [string]$Wert, [string]$Empfehlung, $Liste)
    [ordered]@{ status = $Status; wert = $Wert; empfehlung = $Empfehlung; liste = @($Liste) }
}

#endregion

#region Dekodieren und CSV

<#
.SYNOPSIS
    Dekodiert die Rohbytes einer Werkzeug-Ausgabe zu Text.
.DESCRIPTION
    BOM FF FE -> UTF-16LE, EF BB BF -> UTF-8. Ohne BOM: UTF-16LE, wenn in den ersten 400 Bytes mindestens 30 % der
    ungeraden Stellen 0 sind; sonst strenges UTF-8, bei ungueltigen Bytes ANSI. Leer/$null -> ''.
#>
function ConvertFrom-MorpheusSysAusgabe {
    [CmdletBinding()]
    param([byte[]]$Bytes)
    if (($null -eq $Bytes) -or ($Bytes.Length -eq 0)) { return '' }
    $n = $Bytes.Length
    $text = $null
    if (($n -ge 2) -and ($Bytes[0] -eq 0xFF) -and ($Bytes[1] -eq 0xFE)) {
        $text = [Text.Encoding]::Unicode.GetString($Bytes, 2, $n - 2)
    }
    elseif (($n -ge 3) -and ($Bytes[0] -eq 0xEF) -and ($Bytes[1] -eq 0xBB) -and ($Bytes[2] -eq 0xBF)) {
        $text = (New-Object Text.UTF8Encoding($false)).GetString($Bytes, 3, $n - 3)
    }
    else {
        $pruef = [Math]::Min(400, $n)
        $ungerade = 0; $nullen = 0
        for ($i = 1; $i -lt $pruef; $i += 2) {
            $ungerade++
            if ($Bytes[$i] -eq 0) { $nullen++ }
        }
        if (($ungerade -gt 0) -and (($nullen / $ungerade) -ge 0.3)) {
            $text = [Text.Encoding]::Unicode.GetString($Bytes)
        }
        else {
            try { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes) }
            catch { $text = [Text.Encoding]::Default.GetString($Bytes) }
        }
    }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $text
}

<#
.SYNOPSIS
    Eigener CSV-Parser (RFC 4180): Anfuehrungszeichen, "", Zeilenumbrueche in Feldern, CRLF/LF/CR. Leere Zeilen entfallen.
.OUTPUTS
    System.Collections.Generic.List[string[]]. Die Liste wird mit vorangestelltem Komma ausgegeben, damit PowerShell sie
    in der Pipeline nicht aufloest; bei Zuweisung ($zeilen = ConvertFrom-MorpheusCsvText ...) erhaelt man die Liste selbst.
#>
function ConvertFrom-MorpheusCsvText {
    [CmdletBinding()]
    param([string]$Text, [string]$Trenner = ',')
    $rows = New-Object 'System.Collections.Generic.List[string[]]'
    if ([string]::IsNullOrEmpty($Text)) { return , $rows }
    $sep = $Trenner[0]
    $fields = New-Object 'System.Collections.Generic.List[string]'
    $sb = New-Object System.Text.StringBuilder
    $inQ = $false
    $gequotet = $false
    $len = $Text.Length
    $i = 0
    while ($i -lt $len) {
        $c = $Text[$i]
        if ($inQ) {
            if ($c -eq '"') {
                if ((($i + 1) -lt $len) -and ($Text[$i + 1] -eq '"')) { [void]$sb.Append('"'); $i++ }
                else { $inQ = $false }
            }
            else { [void]$sb.Append($c) }
        }
        elseif (($c -eq '"') -and ($sb.Length -eq 0) -and (-not $gequotet)) {
            $inQ = $true; $gequotet = $true
        }
        elseif ($c -eq $sep) {
            $fields.Add($sb.ToString()); [void]$sb.Clear(); $gequotet = $false
        }
        elseif (($c -eq "`r") -or ($c -eq "`n")) {
            if (($c -eq "`r") -and (($i + 1) -lt $len) -and ($Text[$i + 1] -eq "`n")) { $i++ }
            $fields.Add($sb.ToString())
            $leer = (($fields.Count -eq 1) -and ($fields[0].Length -eq 0) -and (-not $gequotet))
            if (-not $leer) { $rows.Add($fields.ToArray()) }
            $fields = New-Object 'System.Collections.Generic.List[string]'
            [void]$sb.Clear(); $gequotet = $false
        }
        else { [void]$sb.Append($c) }
        $i++
    }
    if (($sb.Length -gt 0) -or ($fields.Count -gt 0) -or $gequotet) {
        $fields.Add($sb.ToString())
        $leer = (($fields.Count -eq 1) -and ($fields[0].Length -eq 0) -and (-not $gequotet))
        if (-not $leer) { $rows.Add($fields.ToArray()) }
    }
    , $rows
}

#endregion

#region Parser

<#
.SYNOPSIS
    $true, wenn der Parser in dem Text eine Kopfzeile finden wuerde (Art 'autoruns' oder 'sigcheck'). Leerer Text -> $false.
    Unterscheidet 'Werkzeug lieferte keine CSV' von 'CSV ohne Eintraege'.
#>
function Test-MorpheusSysKopf {
    [CmdletBinding()]
    param([string]$Text, [ValidateSet('autoruns', 'sigcheck')][string]$Art)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $zeilen = ConvertFrom-MorpheusCsvText -Text $Text
    if ($Art -eq 'autoruns') { return [bool]($null -ne (MorpheusSysAwKopfAutoruns $zeilen)) }
    [bool]($null -ne (MorpheusSysAwKopfSigcheck $zeilen))
}

<#
.SYNOPSIS
    Autoruns-CSV (autorunsc -c) -> Eintraege. Ausgabe als Array (unaufgeloest in die Pipeline); Aufrufer verwenden @(...), damit auch 0 oder 1 Eintrag ein Array ergibt.
#>
function ConvertFrom-MorpheusAutorunsCsv {
    [CmdletBinding()]
    param([string]$Text)
    $zeilen = ConvertFrom-MorpheusCsvText -Text $Text
    $out = New-Object System.Collections.Generic.List[object]
    $kopf = MorpheusSysAwKopfAutoruns $zeilen
    if ($null -eq $kopf) { return @() }
    $idx = $kopf.Index
    $kopfNr = $kopf.Zeile
    for ($r = $kopfNr + 1; $r -lt $zeilen.Count; $r++) {
        if ($out.Count -ge $script:MorpheusSysAwMaxEintraege) { break }
        $z = $zeilen[$r]
        $eintrag = MorpheusSysAwFeld $z $idx 'Entry'
        $pfad = MorpheusSysAwFeld $z $idx 'Image Path'
        if (($eintrag.Length -eq 0) -and ($pfad.Length -eq 0)) { continue }
        $fehlt = $false
        $praefix = 'File not found: '
        if ($pfad.StartsWith($praefix, [StringComparison]::OrdinalIgnoreCase)) {
            $pfad = $pfad.Substring($praefix.Length).Trim()
            $fehlt = $true
        }
        $signer = MorpheusSysAwFeld $z $idx 'Signer'
        $out.Add([pscustomobject][ordered]@{
                Ort          = MorpheusSysAwFeld $z $idx 'Entry Location'
                Eintrag      = $eintrag
                Aktiv        = ((MorpheusSysAwFeld $z $idx 'Enabled') -ieq 'enabled')
                Kategorie    = MorpheusSysAwFeld $z $idx 'Category'
                Profil       = MorpheusSysAwFeld $z $idx 'Profile'
                Beschreibung = MorpheusSysAwFeld $z $idx 'Description'
                Signierer    = $signer
                Verifiziert  = $signer.StartsWith('(Verified)', [StringComparison]::OrdinalIgnoreCase)
                Firma        = MorpheusSysAwFeld $z $idx 'Company'
                Pfad         = $pfad
                DateiFehlt   = $fehlt
                Version      = MorpheusSysAwFeld $z $idx 'Version'
                Befehl       = MorpheusSysAwFeld $z $idx 'Launch String'
                Sha256       = MorpheusSysAwFeld $z $idx 'SHA-256'
            })
    }
    $out.ToArray()
}

<#
.SYNOPSIS
    Sigcheck-CSV (sigcheck -c) -> Eintraege. Ausgabe wie bei ConvertFrom-MorpheusAutorunsCsv: Aufrufer verwenden @(...).
#>
function ConvertFrom-MorpheusSigcheckCsv {
    [CmdletBinding()]
    param([string]$Text)
    $zeilen = ConvertFrom-MorpheusCsvText -Text $Text
    $out = New-Object System.Collections.Generic.List[object]
    $kopf = MorpheusSysAwKopfSigcheck $zeilen
    if ($null -eq $kopf) { return @() }
    $idx = $kopf.Index
    $kopfNr = $kopf.Zeile
    for ($r = $kopfNr + 1; $r -lt $zeilen.Count; $r++) {
        if ($out.Count -ge $script:MorpheusSysAwMaxEintraege) { break }
        $z = $zeilen[$r]
        $pfad = MorpheusSysAwFeld $z $idx 'Path'
        if ($pfad.Length -eq 0) { continue }
        $ver = MorpheusSysAwFeld $z $idx 'Verified'
        $out.Add([pscustomobject][ordered]@{
                Pfad         = $pfad
                Verifiziert  = $ver
                Signiert     = ($ver -ieq 'Signed')
                Datum        = MorpheusSysAwFeld $z $idx 'Date'
                Herausgeber  = MorpheusSysAwFeld $z $idx 'Publisher'
                Firma        = MorpheusSysAwFeld $z $idx 'Company'
                Beschreibung = MorpheusSysAwFeld $z $idx 'Description'
                Produkt      = MorpheusSysAwFeld $z $idx 'Product'
                Version      = MorpheusSysAwFeld $z $idx 'File version'
                Typ          = MorpheusSysAwFeld $z $idx 'Machine type'
            })
    }
    $out.ToArray()
}

#endregion

#region Bewertung

<#
.SYNOPSIS
    $true, wenn jemand ausser Administratoren/SYSTEM/TrustedInstaller die Datei aendern oder im Ordner austauschen kann
    (Datei: volle Schreibmaske; Elternordner: nur Loeschen/Rechte aendern/Besitz uebernehmen/Unterobjekte loeschen/GENERIC_ALL;
    ein Besitzer des Ordners ausserhalb der vertrauenswuerdigen SIDs zaehlt immer).
.OUTPUTS
    $true / $false; $null, wenn die Datei fehlt oder die Rechte nicht lesbar sind.
#>
function Test-MorpheusPfadBenutzerBeschreibbar {
    [CmdletBinding()]
    param([string]$Pfad)
    if ([string]::IsNullOrWhiteSpace($Pfad)) { return $null }
    $p = $Pfad.Trim().Trim('"').Trim()
    try {
        $p = [Environment]::ExpandEnvironmentVariables($p)
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        $voll = [IO.Path]::GetFullPath($p)
        $eltern = Split-Path -Parent $voll
    }
    catch { return $null }
    # Datei: volle Schreibmaske; Elternordner: nur Rechte, mit denen sich die Datei austauschen laesst
    $ziele = @(, @($voll, $script:MorpheusSysAwSchreibMaske))
    if ($eltern) { $ziele += , @($eltern, $script:MorpheusSysAwElternMaske) }
    $unlesbar = $false
    foreach ($zm in $ziele) {
        $z = [string]$zm[0]
        $maske = [int]$zm[1]
        $acl = $null
        try { $acl = Get-Acl -LiteralPath $z -ErrorAction Stop } catch { $unlesbar = $true; continue }
        $owner = $null
        try { $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { }
        if ((-not $owner) -or ($script:MorpheusSysAwVertraut -notcontains $owner)) {
            if ($owner) { return $true }
            $unlesbar = $true
        }
        $regeln = $null
        try { $regeln = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) } catch { $unlesbar = $true; continue }
        foreach ($rule in $regeln) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            if (([int]$rule.PropagationFlags -band [int][Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
            $sid = $rule.IdentityReference.Value
            if ($script:MorpheusSysAwVertraut -contains $sid) { continue }
            if ($script:MorpheusSysAwIgnoriert -contains $sid) { continue }
            if (MorpheusSysAwRegelSchreibt -Rechte ([int]$rule.FileSystemRights) -Maske $maske) { return $true }
        }
    }
    if ($unlesbar) { return $null }
    $false
}

<#
.SYNOPSIS
    $true, wenn der Autostart-Eintrag als SYSTEM, Dienst oder Kernel laeuft (nach Kategorie).
    Geplante Aufgaben (Kategorie 'Tasks' oder 'Scheduled Tasks') nur, wenn -Aufgaben den Namen (Trim, klein, mit
    fuehrendem Backslash) als Schluessel mit $true enthaelt; sonst $false.
.PARAMETER Aufgaben
    Hashtable: normalisierter Aufgabenname -> [bool] (laeuft als SYSTEM oder mit hoechsten Rechten). Optional.
#>
function Test-MorpheusAutorunsErhoeht {
    [CmdletBinding()]
    param($Eintrag, [hashtable]$Aufgaben = @{})
    $k = MorpheusSysAwKategorie $Eintrag
    if ($k.Length -eq 0) { return $false }
    if (($k -ieq 'Tasks') -or ($k -ieq 'ScheduledTasks')) {
        $key = MorpheusSysAwAufgabenSchluessel (MorpheusSysAwProp $Eintrag 'Eintrag')
        if (($null -ne $Aufgaben) -and ($key.Length -gt 0) -and $Aufgaben.ContainsKey($key)) { return [bool]$Aufgaben[$key] }
        return $false
    }
    [bool]($script:MorpheusSysAwErhoehteKategorien -contains $k)
}

<#
.SYNOPSIS
    Teilt betroffene Eintraege in drei Gruppen: systemnah/erhoeht (ohne Dienste/Treiber), Dienste und Treiber
    (eigene Pruefungen im Scan), uebrige. Liefert @{ Hoch; Dienst; User } (Listen).
#>
function MorpheusSysAwGruppieren {
    param($Betroffen)
    $g = @{ Hoch = @(); Dienst = @(); User = @() }
    foreach ($c in $Betroffen) {
        if (MorpheusSysAwIstDienstTreiber $c) { $g.Dienst += $c }
        elseif ([bool](MorpheusSysAwProp $c 'Erhoeht')) { $g.Hoch += $c }
        else { $g.User += $c }
    }
    $g
}

# 'Kopf (n): A, B' fuer eine Gruppe
function MorpheusSysAwGruppenText {
    param([string]$Kopf, $Liste)
    '{0} ({1}): {2}' -f $Kopf, @($Liste).Count, (MorpheusSysAwNamenListe @($Liste | ForEach-Object { MorpheusSysAwEintragName $_ }))
}

<#
.SYNOPSIS
    Befund: aktive Autostarts ohne verifizierte Signatur. WARN nur bei systemnahen Eintraegen ausser Diensten und
    Treibern (Winlogon, LSA, Aufgaben als SYSTEM usw.); Dienste/Treiber haben eigene Pruefungen und ergeben hoechstens INFO.
    Eintraege ohne Pfad zaehlen nicht.
.PARAMETER Aufgaben
    Hashtable normalisierter Aufgabenname -> bool (siehe Test-MorpheusAutorunsErhoeht).
#>
function Get-MorpheusAutorunsSignaturBefund {
    [CmdletBinding()]
    param($Eintraege, [hashtable]$Aufgaben = @{})
    $betroffen = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($Eintraege)) {
        if ($null -eq $e) { continue }
        if (-not [bool](MorpheusSysAwProp $e 'Aktiv')) { continue }
        if ([bool](MorpheusSysAwProp $e 'DateiFehlt')) { continue }
        if ([bool](MorpheusSysAwProp $e 'Verifiziert')) { continue }
        if ([string]::IsNullOrWhiteSpace([string](MorpheusSysAwProp $e 'Pfad'))) { continue }
        $erh = Test-MorpheusAutorunsErhoeht -Eintrag $e -Aufgaben $Aufgaben
        $betroffen.Add((MorpheusSysAwErgaenzen $e @{ Erhoeht = $erh }))
    }
    if ($betroffen.Count -eq 0) {
        return (MorpheusSysAwBefund 'OK' 'Alle aktiven Autostarts sind signiert.' '' @())
    }
    $g = MorpheusSysAwGruppieren $betroffen
    $teile = @()
    if ($g.Hoch.Count -gt 0) { $teile += (MorpheusSysAwGruppenText 'Systemnahe Autostarts ohne verifizierte Signatur' $g.Hoch) }
    if ($g.Dienst.Count -gt 0) { $teile += (MorpheusSysAwGruppenText 'Dienste und Treiber (bereits eigene Prüfungen)' $g.Dienst) }
    if ($g.User.Count -gt 0) {
        $kopf = 'Autostarts ohne Signatur'
        if ($teile.Count -gt 0) { $kopf = 'weitere Autostarts' }
        $teile += (MorpheusSysAwGruppenText $kopf $g.User)
    }
    $wert = $teile -join '; '
    if ($g.Hoch.Count -gt 0) {
        return (MorpheusSysAwBefund 'WARN' $wert 'Herkunft der Einträge prüfen (Tabelle). Unsignierte systemnahe Autostarts sind selten und typisch für alte Software oder Schadsoftware.' $betroffen.ToArray())
    }
    MorpheusSysAwBefund 'INFO' $wert 'Unsignierte Programme im Benutzerbereich sind häufig (z. B. kleine Hilfsprogramme). Unsignierte Dienste und Treiber bewertet der Scan in eigenen Prüfungen. Herkunft in der Tabelle prüfen und Unbekanntes entfernen.' $betroffen.ToArray()
}

<#
.SYNOPSIS
    Befund: aktive Autostarts, deren Datei oder Ordner fuer normale Benutzer beschreibbar ist (Elternordner: nur
    Austauschen/Loeschen zaehlt). WARN nur bei systemnahen Eintraegen ausser Diensten und Treibern (eigene Pruefung
    'Dienstpfade und Berechtigungen'); Dienste/Treiber ergeben hoechstens INFO.
.PARAMETER Beschreibbar
    Scriptblock { param($Pfad) ... } -> $true/$false/$null. Standard: Test-MorpheusPfadBenutzerBeschreibbar. Je Pfad gecacht.
.PARAMETER Aufgaben
    Hashtable normalisierter Aufgabenname -> bool (siehe Test-MorpheusAutorunsErhoeht).
#>
function Get-MorpheusAutorunsPfadBefund {
    [CmdletBinding()]
    param($Eintraege, [scriptblock]$Beschreibbar, [hashtable]$Aufgaben = @{})
    if ($null -eq $Beschreibbar) { $Beschreibbar = { param($Pfad) Test-MorpheusPfadBenutzerBeschreibbar -Pfad $Pfad } }
    $cache = @{}
    $betroffen = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($Eintraege)) {
        if ($null -eq $e) { continue }
        if (-not [bool](MorpheusSysAwProp $e 'Aktiv')) { continue }
        if ([bool](MorpheusSysAwProp $e 'DateiFehlt')) { continue }
        $pfad = [string](MorpheusSysAwProp $e 'Pfad')
        if ([string]::IsNullOrWhiteSpace($pfad)) { continue }
        $b = MorpheusSysAwCacheWert $pfad $cache $Beschreibbar
        if ($b -ne $true) { continue }
        $erh = Test-MorpheusAutorunsErhoeht -Eintrag $e -Aufgaben $Aufgaben
        $betroffen.Add((MorpheusSysAwErgaenzen $e @{ Beschreibbar = $true; Erhoeht = $erh }))
    }
    if ($betroffen.Count -eq 0) {
        return (MorpheusSysAwBefund 'OK' 'Keine aktiven Autostarts in für Benutzer beschreibbaren Ordnern gefunden.' '' @())
    }
    $g = MorpheusSysAwGruppieren $betroffen
    $teile = @()
    if ($g.Hoch.Count -gt 0) { $teile += (MorpheusSysAwGruppenText 'Systemnahe Autostarts und Aufgaben mit erhöhten Rechten' $g.Hoch) }
    if ($g.Dienst.Count -gt 0) { $teile += (MorpheusSysAwGruppenText 'Dienste und Treiber (bereits eigene Prüfungen)' $g.Dienst) }
    if ($g.User.Count -gt 0) {
        $kopf = 'Autostarts in beschreibbaren Ordnern'
        if ($teile.Count -gt 0) { $kopf = 'weitere Autostarts' }
        $teile += (MorpheusSysAwGruppenText $kopf $g.User)
    }
    $wert = $teile -join '; '
    if ($g.Hoch.Count -gt 0) {
        return (MorpheusSysAwBefund 'WARN' $wert 'Programmordner prüfen: Systemnahe Autostarts und Aufgaben, die als SYSTEM laufen, sollten nur aus Ordnern starten, die nur Administratoren ändern dürfen (z. B. C:\Program Files). Unbekannte Einträge mit Autoruns (Werkzeuge) genauer ansehen.' $betroffen.ToArray())
    }
    MorpheusSysAwBefund 'INFO' $wert 'Programme in AppData oder im Benutzerordner sind üblich und geben keine erhöhten Rechte. Dienste und Treiber bewertet der Scan in eigenen Prüfungen. Nur bei unbekannten Namen genauer hinsehen.' $betroffen.ToArray()
}

<#
.SYNOPSIS
    Befund: unsignierte Dateien in System32 und System32\drivers (Sigcheck-Eintraege).
#>
function Get-MorpheusSystemdateienBefund {
    [CmdletBinding()]
    param($System32, $Treiber)
    $betroffen = New-Object System.Collections.Generic.List[object]
    $gruppen = @(@('System32', $System32), @('drivers', $Treiber))
    foreach ($g in $gruppen) {
        foreach ($e in @($g[1])) {
            if ($null -eq $e) { continue }
            if ([bool](MorpheusSysAwProp $e 'Signiert')) { continue }
            $betroffen.Add((MorpheusSysAwErgaenzen $e @{ Ordner = $g[0] }))
        }
    }
    if ($betroffen.Count -eq 0) {
        return (MorpheusSysAwBefund 'OK' 'Keine unsignierten Dateien in System32 und drivers gefunden.' '' @())
    }
    $namen = MorpheusSysAwNamenListe @($betroffen | ForEach-Object { ([string]$_.Pfad -split '[\\/]')[-1] })
    $wert = ('{0} unsignierte Dateien: {1}' -f $betroffen.Count, $namen)
    if ($betroffen.Count -eq 1) { $wert = ('1 unsignierte Datei: {0}' -f $namen) }
    MorpheusSysAwBefund 'WARN' $wert 'Dateien prüfen (Tabelle). Unsignierte Dateien in System32 stammen meist von alter Treiber- oder Drucker-Software; Unbekanntes mit Defender scannen.' $betroffen.ToArray()
}

#endregion

#region Tabellen fuer den Bericht

<#
.SYNOPSIS
    Zeilen fuer die Tabelle 'Autostarts (Autoruns, ohne Microsoft)'. Ausgelassen werden verifiziert von Microsoft
    signierte Eintraege (Verifiziert und Signierer 'Microsoft Windows', 'Microsoft Corporation' oder
    'Microsoft Windows Publisher'; nicht der WHQL-Herausgeber 'Microsoft Windows Hardware Compatibility Publisher').
    Beschreibbar: $true/$false, $null wenn unbekannt.
#>
function Get-MorpheusAutorunsTabelle {
    [CmdletBinding()]
    param($Eintraege, [scriptblock]$Beschreibbar, [hashtable]$Aufgaben = @{})
    if ($null -eq $Beschreibbar) { $Beschreibbar = { param($Pfad) Test-MorpheusPfadBenutzerBeschreibbar -Pfad $Pfad } }
    $cache = @{}
    $zeilen = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($Eintraege)) {
        if ($null -eq $e) { continue }
        $signer = [string](MorpheusSysAwProp $e 'Signierer')
        if (([bool](MorpheusSysAwProp $e 'Verifiziert')) -and ($signer -match '^\(Verified\)\s+Microsoft (Windows|Corporation|Windows Publisher)$')) { continue }
        $pfad = [string](MorpheusSysAwProp $e 'Pfad')
        $b = $null
        if ((-not [string]::IsNullOrWhiteSpace($pfad)) -and (-not [bool](MorpheusSysAwProp $e 'DateiFehlt'))) {
            $b = MorpheusSysAwCacheWert $pfad $cache $Beschreibbar
        }
        $zeilen.Add([pscustomobject][ordered]@{
                Kategorie    = [string](MorpheusSysAwProp $e 'Kategorie')
                Eintrag      = [string](MorpheusSysAwProp $e 'Eintrag')
                Aktiv        = [bool](MorpheusSysAwProp $e 'Aktiv')
                Signierer    = $signer
                Verifiziert  = [bool](MorpheusSysAwProp $e 'Verifiziert')
                Beschreibbar = $b
                Erhoeht      = (Test-MorpheusAutorunsErhoeht -Eintrag $e -Aufgaben $Aufgaben)
                Pfad         = $pfad
                Ort          = [string](MorpheusSysAwProp $e 'Ort')
                Befehl       = [string](MorpheusSysAwProp $e 'Befehl')
            })
    }
    $zeilen.ToArray()
}

<#
.SYNOPSIS
    Zeilen fuer die Tabelle 'Unsignierte Systemdateien (Sigcheck)': Ordner, Datei, Firma, Beschreibung, Version, Datum, Pfad.
#>
function Get-MorpheusSigcheckTabelle {
    [CmdletBinding()]
    param($System32, $Treiber)
    $zeilen = New-Object System.Collections.Generic.List[object]
    $gruppen = @(@('System32', $System32), @('drivers', $Treiber))
    foreach ($g in $gruppen) {
        foreach ($e in @($g[1])) {
            if ($null -eq $e) { continue }
            if ([bool](MorpheusSysAwProp $e 'Signiert')) { continue }
            $pfad = [string](MorpheusSysAwProp $e 'Pfad')
            $zeilen.Add([pscustomobject][ordered]@{
                    Ordner       = $g[0]
                    Datei        = ($pfad -split '[\\/]')[-1]
                    Firma        = [string](MorpheusSysAwProp $e 'Firma')
                    Beschreibung = [string](MorpheusSysAwProp $e 'Beschreibung')
                    Version      = [string](MorpheusSysAwProp $e 'Version')
                    Datum        = [string](MorpheusSysAwProp $e 'Datum')
                    Pfad         = $pfad
                })
        }
    }
    $zeilen.ToArray()
}

#endregion
