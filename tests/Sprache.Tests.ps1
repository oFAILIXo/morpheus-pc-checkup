#Requires -Version 5.1
# Pester-3.4-Tests fuer die Sprachdateien lang\de und lang\en und gui\lib\Sprache.ps1 (2.6, Karte #66).
# Teil A: Beide Sprachen haben dieselben Schluessel, keine leeren Texte, dieselben Platzhalter.
# Teil B: Jeder Schluessel, den der Code nutzt (T '...', t('...'), data-t="..."), hat einen Text.
# Teil C: Funktionen aus Sprache.ps1 (Sprachwahl, Platzhalter, Rueckfall); es wird nur im TestDrive geschrieben.
# Ausfuehren: Invoke-Pester tests\Sprache.Tests.ps1

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $script:Root 'gui\lib\Sprache.ps1')

$script:Flach = @('scan', 'scannamen', 'leistung', 'bericht', 'server', 'serverlib', 'katalog', 'gui', 'gui2')
$script:Teile = $script:Flach + @('hilfe', 'aktionen')
# Praefix der Schluessel je flacher Datei
$script:Praefix = @{ scan = 'scan.'; scannamen = 'scan.'; serverlib = 'server.'; gui2 = 'gui.'; leistung = 'scan.'; bericht = 'bericht.'; server = 'server.'; katalog = 'katalog.'; gui = 'gui.' }

function Get-LangDatei {
    param([string]$Sprache, [string]$Teil)
    Import-PowerShellDataFile -LiteralPath (Join-Path $script:Root ('lang\{0}\{1}.psd1' -f $Sprache, $Teil))
}

# Alle Blatt-Pfade einer verschachtelten Struktur: Hashtable-Schluessel mit '/', Arrays mit [Anzahl]
function Get-SchluesselPfade {
    param($Wert, [string]$Pfad = '')
    if ($Wert -is [hashtable]) {
        foreach ($k in @($Wert.Keys | Sort-Object)) { Get-SchluesselPfade $Wert[$k] ($Pfad + '/' + $k) }
        return
    }
    if ($Wert -is [array]) {
        $Pfad + '[' + $Wert.Count + ']'
        for ($i = 0; $i -lt $Wert.Count; $i++) { if (($Wert[$i] -is [hashtable]) -or ($Wert[$i] -is [array])) { Get-SchluesselPfade $Wert[$i] ($Pfad + '[' + $i + ']') } }
        return
    }
    $Pfad
}

# Alle Texte (Blaetter) einer Struktur mit Pfad
function Get-Blaetter {
    param($Wert, [string]$Pfad = '')
    if ($Wert -is [hashtable]) { foreach ($k in @($Wert.Keys)) { Get-Blaetter $Wert[$k] ($Pfad + '/' + $k) }; return }
    if ($Wert -is [array]) { for ($i = 0; $i -lt $Wert.Count; $i++) { Get-Blaetter $Wert[$i] ($Pfad + '[' + $i + ']') }; return }
    [pscustomobject]@{ Pfad = $Pfad; Wert = $Wert }
}

function Get-Platzhalter {
    param([string]$Text)
    $ohne = $Text.Replace('{{', '').Replace('}}', '')
    @([regex]::Matches($ohne, '\{(\d+)(?:[,:][^}]*)?\}') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique) -join ','
}

# ---------------------------------------------------------------- Teil A

Describe 'Sprachdateien: Aufbau' {
    foreach ($teil in $script:Teile) {
        It "lang\de\$teil.psd1 und lang\en\$teil.psd1 sind lesbar" {
            (Get-LangDatei 'de' $teil) -is [hashtable] | Should Be $true
            (Get-LangDatei 'en' $teil) -is [hashtable] | Should Be $true
        }
        It "$teil`: Deutsch und Englisch haben dieselben Schluessel" {
            $de = @(Get-SchluesselPfade (Get-LangDatei 'de' $teil))
            $en = @(Get-SchluesselPfade (Get-LangDatei 'en' $teil))
            $nurDe = @($de | Where-Object { $en -notcontains $_ })
            $nurEn = @($en | Where-Object { $de -notcontains $_ })
            ('nur de: ' + ($nurDe -join ', ')) | Should Be 'nur de: '
            ('nur en: ' + ($nurEn -join ', ')) | Should Be 'nur en: '
        }
        It "$teil`: kein leerer Text" {
            foreach ($sp in 'de', 'en') {
                $leer = @(Get-Blaetter (Get-LangDatei $sp $teil) | Where-Object { ($_.Wert -is [string]) -and [string]::IsNullOrWhiteSpace($_.Wert) } | ForEach-Object { $_.Pfad })
                ("$sp leer: " + ($leer -join ', ')) | Should Be "$sp leer: "
            }
        }
    }
    foreach ($teil in $script:Flach) {
        It "$teil`: nur Texte, Schluessel mit Praefix $($script:Praefix[$teil])" {
            foreach ($sp in 'de', 'en') {
                $d = Get-LangDatei $sp $teil
                $pr = $script:Praefix[$teil]
                $falsch = @($d.Keys | Where-Object { (-not ([string]$_).StartsWith($pr)) -or ($d[$_] -isnot [string]) })
                ("$sp falsch: " + ($falsch -join ', ')) | Should Be "$sp falsch: "
            }
        }
        It "$teil`: gleiche Platzhalter in beiden Sprachen, Format gueltig" {
            $de = Get-LangDatei 'de' $teil
            $en = Get-LangDatei 'en' $teil
            $abw = New-Object System.Collections.Generic.List[string]
            foreach ($k in $de.Keys) {
                if (-not $en.ContainsKey($k)) { continue }
                if ((Get-Platzhalter $de[$k]) -ne (Get-Platzhalter $en[$k])) { $abw.Add($k) }
                foreach ($s in $de[$k], $en[$k]) {
                    $n = 0; $p = Get-Platzhalter $s; if ($p) { $n = [int](($p -split ',')[-1]) + 1 }
                    try { [void][string]::Format($s, [object[]](1..([Math]::Max($n, 1)))) } catch { $abw.Add("$k (Format)") }
                }
            }
            ('abweichend: ' + ($abw -join ', ')) | Should Be 'abweichend: '
        }
    }
    It 'kein Schluessel steht in zwei flachen Dateien' {
        $wo = @{}
        $doppelt = New-Object System.Collections.Generic.List[string]
        foreach ($teil in $script:Flach) {
            foreach ($k in (Get-LangDatei 'de' $teil).Keys) { if ($wo.ContainsKey($k)) { $doppelt.Add("$k ($($wo[$k]), $teil)") } else { $wo[$k] = $teil } }
        }
        ('doppelt: ' + ($doppelt -join ', ')) | Should Be 'doppelt: '
    }
}

# ---------------------------------------------------------------- Teil B

Describe 'Sprachdateien: jeder Schluessel im Code hat einen Text' {
    $alle = @{}
    foreach ($teil in $script:Flach) { $d = Get-LangDatei 'de' $teil; foreach ($k in $d.Keys) { $alle[[string]$k] = $true } }
    $aktionen = Get-LangDatei 'de' 'aktionen'

    It 'PowerShell: T ''schluessel'' in Scan, Starter, Katalog und gui\lib' {
        $dateien = @('pc-check.ps1', 'pc-check-gui.ps1', 'pc-check-start.ps1', 'pc-check.aktionen.ps1' | ForEach-Object { Join-Path $script:Root $_ }) +
            @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'gui\lib') -Filter *.ps1 | ForEach-Object { $_.FullName })
        $fehlt = New-Object System.Collections.Generic.List[string]
        $n = 0
        foreach ($f in $dateien) {
            $text = [IO.File]::ReadAllText($f)
            foreach ($m in [regex]::Matches($text, "(?<![\w$.-])T\s+'([^']+)'")) {
                $n++
                $k = $m.Groups[1].Value
                if (-not $alle.ContainsKey($k)) { $fehlt.Add((Split-Path -Leaf $f) + ': ' + $k) }
            }
        }
        $n | Should BeGreaterThan 0
        ('fehlt: ' + (@($fehlt | Sort-Object -Unique) -join ', ')) | Should Be 'fehlt: '
    }

    It 'Oberflaeche: t(''schluessel'') in app.js und data-t in index.html' {
        $fehlt = New-Object System.Collections.Generic.List[string]
        $js = [IO.File]::ReadAllText((Join-Path $script:Root 'gui\app.js'))
        $n = 0
        foreach ($m in [regex]::Matches($js, "(?<![\w$.])t\(\s*'([^']+)'")) {
            $n++
            if (-not $alle.ContainsKey('gui.' + $m.Groups[1].Value)) { $fehlt.Add('app.js: ' + $m.Groups[1].Value) }
        }
        $html = [IO.File]::ReadAllText((Join-Path $script:Root 'gui\index.html'))
        foreach ($m in [regex]::Matches($html, 'data-t(?:-[a-z]+)?="([^"]+)"')) {
            $n++
            if (-not $alle.ContainsKey('gui.' + $m.Groups[1].Value)) { $fehlt.Add('index.html: ' + $m.Groups[1].Value) }
        }
        $n | Should BeGreaterThan 0
        ('fehlt: ' + (@($fehlt | Sort-Object -Unique) -join ', ')) | Should Be 'fehlt: '
    }

    It 'Katalog: jede Aktion hat Titel und Erklaerung in lang\de\aktionen.psd1' {
        $ids = @([regex]::Matches([IO.File]::ReadAllText((Join-Path $script:Root 'pc-check.aktionen.ps1')), "(?m)^\s*Id\s*=\s*'([a-z0-9.-]+)'") | ForEach-Object { $_.Groups[1].Value })
        $ids.Count | Should BeGreaterThan 0
        $fehlt = @($ids | Where-Object { -not (($aktionen[$_] -is [hashtable]) -and $aktionen[$_].Titel -and $aktionen[$_].Erklaerung) })
        ('fehlt: ' + ($fehlt -join ', ')) | Should Be 'fehlt: '
    }

    It 'Scan: jede Pruefung mit festem Namen hat einen Anzeigenamen (scan.pruefung.*)' {
        $text = [IO.File]::ReadAllText((Join-Path $script:Root 'pc-check.ps1'))
        $namen = @([regex]::Matches($text, "Invoke-Check\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $namen.Count | Should BeGreaterThan 50
        $fehlt = @($namen | Where-Object { -not $alle.ContainsKey('scan.pruefung.' + $_) })
        ('fehlt: ' + ($fehlt -join ', ')) | Should Be 'fehlt: '
    }
}

# ---------------------------------------------------------------- Teil C

Describe 'Sprache.ps1' {
    $altEnv = $env:MORPHEUS_SPRACHE

    It 'liest state\sprache.json nur mit de oder en' {
        $d = Join-Path $TestDrive 'daten'
        New-Item -ItemType Directory -Path (Join-Path $d 'state') -Force | Out-Null
        $p = Join-Path $d 'state\sprache.json'
        Set-Content -LiteralPath $p -Value '{"sprache":"en"}' -Encoding UTF8
        Get-MorpheusSprache -DataRoot $d | Should Be 'en'
        Set-Content -LiteralPath $p -Value '{"sprache":"de"}' -Encoding UTF8
        Get-MorpheusSprache -DataRoot $d | Should Be 'de'
        foreach ($schlecht in '{"sprache":"fr"}', '{"sprache":"..\\x"}', '{"sprache":"EN"}', 'kaputt', '{"sprache":["en"]}') {
            Set-Content -LiteralPath $p -Value $schlecht -Encoding UTF8
            Read-MorpheusSpracheDatei -DataRoot $d | Should BeNullOrEmpty
            Get-MorpheusSprache -DataRoot $d | Should Be (Get-MorpheusWindowsSprache)
        }
    }

    It 'nimmt ohne Datei die Windows-Sprache (de-* = Deutsch, sonst Englisch)' {
        $w = Get-MorpheusWindowsSprache
        @('de', 'en') -contains $w | Should Be $true
        if (([string](Get-UICulture).Name) -like 'de-*') { $w | Should Be 'de' } else { $w | Should Be 'en' }
        Get-MorpheusSprache -DataRoot (Join-Path $TestDrive 'gibtsnicht') | Should Be $w
    }

    It 'ignoriert einen ungueltigen Wert in MORPHEUS_SPRACHE' {
        $env:MORPHEUS_SPRACHE = 'xx'
        Get-MorpheusAktiveSprache | Should Be (Get-MorpheusWindowsSprache)
        $env:MORPHEUS_SPRACHE = 'en'
        Get-MorpheusAktiveSprache | Should Be 'en'
    }

    It 'laedt nur feste Sprachen' {
        { Import-MorpheusSprachDatei -Sprache '..\..\x' -Teil 'gui' } | Should Throw
    }

    It 'T setzt Platzhalter ein, wechselt mit der Sprache und liefert bei unbekanntem Schluessel den Schluessel' {
        $env:MORPHEUS_SPRACHE = 'de'
        $de = T 'server.spracheUngueltig'
        $env:MORPHEUS_SPRACHE = 'en'
        $en = T 'server.spracheUngueltig'
        $de | Should Not Be $en
        T 'gibt.es.nicht' | Should Be 'gibt.es.nicht'
        $global:MorpheusTexte['test.format'] = 'A {0} B {1}'
        T 'test.format' 'x' 2 | Should Be 'A x B 2'
        # ein einzelner Wert 0 bzw. '' gilt in PowerShell als falsch und muss trotzdem eingesetzt werden
        $global:MorpheusTexte['test.null'] = 'Code {0}.'
        T 'test.null' 0 | Should Be 'Code 0.'
        T 'test.null' '' | Should Be 'Code .'
    }

    It 'liefert die Texte der Oberflaeche ohne Praefix' {
        $g = Get-MorpheusGuiTexte -Sprache 'en'
        $g.Count | Should BeGreaterThan 0
        @($g.Keys | Where-Object { $_.StartsWith('gui.') }).Count | Should Be 0
    }

    It 'liefert zu einem englischen Befund die deutsche Fassung (ValueDe), nur an Wortgrenzen' {
        $env:MORPHEUS_SPRACHE = 'en'
        Import-MorpheusTexte -Sprache 'en'
        $global:MorpheusTexte['test.a'] = 'Drive {0} is off'; $global:MorpheusTexteDe['test.a'] = 'Laufwerk {0} ist aus'
        $global:MorpheusTexte['test.b'] = 'on'; $global:MorpheusTexteDe['test.b'] = 'an'
        Start-MorpheusTextSpur
        $v = (T 'test.a' 'C:') + '; Configuration ' + (T 'test.b')
        Get-MorpheusDeutscherText $v | Should Be 'Laufwerk C: ist aus; Configuration an'
        # Spur ist danach leer: ein neuer Text bleibt unveraendert
        Get-MorpheusDeutscherText 'Drive C: is off' | Should Be 'Drive C: is off'
        $global:MorpheusTextSpur = $null
        Get-MorpheusDeutscherText 'x' | Should Be 'x'
    }

    It 'zeigt fuer feste Kennungen den Anzeigenamen, sonst die Kennung' {
        $env:MORPHEUS_SPRACHE = 'en'
        Get-MorpheusAnzeige 'pruefung' 'Gibt es nicht' | Should Be 'Gibt es nicht'
    }

    $env:MORPHEUS_SPRACHE = $altEnv
}

Describe 'Point-in-time restore: Hinweis (Karte #76)' {
    foreach ($sp in 'de', 'en') {
        It "nennt in $sp beide Stellen, den Einstellungs-Link und die 50-GB-Grenze" {
            $k = Get-LangDatei $sp 'katalog'
            $s = Get-LangDatei $sp 'scan'
            foreach ($text in @($k['katalog.speicher.pitr'], $s['scan.wh.zuKleinPitrEmpf'])) {
                $text | Should Match 'ms-settings:recovery'
                $text | Should Match 'sysdm\.cpl'
                $text | Should Match '50 GB'
            }
        }
    }
}
