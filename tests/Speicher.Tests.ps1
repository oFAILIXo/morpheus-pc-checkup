#Requires -Version 5.1
# Pester-3.4-Tests für gui\lib\Speicher.ps1. Rein lesend am System: alle Testdaten liegen in $TestDrive
# (unter %TEMP%, wird von Pester entfernt), Registry-Abfragen sind gemockt.
# Ausführen: Invoke-Pester tests\Speicher.Tests.ps1

$script:SpeicherDatei = Join-Path $PSScriptRoot '..\gui\lib\Speicher.ps1'
$script:Fixtures = Join-Path $PSScriptRoot 'fixtures\speicher'
. $script:SpeicherDatei

function New-TestDatei {
    param([string]$Pfad, [int]$Bytes)
    $dir = Split-Path -Parent $Pfad
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllBytes($Pfad, (New-Object byte[] $Bytes))
}

Describe 'Speicher.ps1 Datei' {
    It 'hat ein UTF-8-BOM' {
        $b = [IO.File]::ReadAllBytes($script:SpeicherDatei)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
    }
    It 'parst ohne Fehler' {
        $err = $null; $tok = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script:SpeicherDatei, [ref]$tok, [ref]$err)
        @($err).Count | Should Be 0
    }
    It 'enthält kein Add-Type' {
        $err = $null; $tok = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:SpeicherDatei, [ref]$tok, [ref]$err)
        $cmds = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' }, $true)
        @($cmds).Count | Should Be 0
    }
}

Describe 'Select-MorpheusTopOrdner' {
    It 'ersetzt den Elternordner durch den dominanten Kind-Ordner' {
        $g = @{ 'C:\Users' = 100; 'C:\Users\Demo' = 90; 'C:\Windows' = 50 }
        $r = @(Select-MorpheusTopOrdner -Groessen $g)
        $r.Count | Should Be 2
        $r[0].pfad | Should Be 'C:\Users\Demo'
        $r[1].pfad | Should Be 'C:\Windows'
    }
    It 'ersetzt über mehrere Ebenen' {
        $g = @{ 'C:\Users' = 100; 'C:\Users\Demo' = 90; 'C:\Users\Demo\AppData' = 80 }
        $r = @(Select-MorpheusTopOrdner -Groessen $g)
        $r.Count | Should Be 1
        $r[0].pfad | Should Be 'C:\Users\Demo\AppData'
        $r[0].bytes | Should Be 80
    }
    It 'behält den Elternordner, wenn kein Kind dominiert' {
        $g = @{ 'C:\A' = 100; 'C:\A\B' = 50; 'C:\A\C' = 40 }
        $r = @(Select-MorpheusTopOrdner -Groessen $g)
        $r.Count | Should Be 1
        $r[0].pfad | Should Be 'C:\A'
    }
    It 'wählt nie Vorfahr und Nachfahr zugleich' {
        $g = @{ 'C:\A' = 100; 'C:\A\B' = 50; 'C:\A\C' = 40; 'C:\D' = 30 }
        $r = @(Select-MorpheusTopOrdner -Groessen $g)
        ($r | ForEach-Object { $_.pfad }) -join ';' | Should Be 'C:\A;C:\D'
    }
    It 'begrenzt auf Top' {
        $g = @{}
        1..8 | ForEach-Object { $g["C:\Ordner$_"] = $_ * 10 }
        $r = @(Select-MorpheusTopOrdner -Groessen $g -Top 3)
        $r.Count | Should Be 3
        $r[0].pfad | Should Be 'C:\Ordner8'
        $r[2].pfad | Should Be 'C:\Ordner6'
    }
    It 'lässt Ordner mit 0 Bytes weg' {
        $g = @{ 'C:\Leer' = 0; 'C:\Voll' = 5 }
        $r = @(Select-MorpheusTopOrdner -Groessen $g)
        $r.Count | Should Be 1
        $r[0].pfad | Should Be 'C:\Voll'
    }
    It 'ignoriert Groß-/Kleinschreibung' {
        $g = @{ 'C:\Users' = 100; 'c:\users\demo' = 90 }
        $r = @(Select-MorpheusTopOrdner -Groessen $g)
        $r.Count | Should Be 1
        $r[0].pfad | Should Be 'c:\users\demo'
        $g2 = @{ 'C:\Users' = 100; 'C:\Users\Demo' = 10; 'c:\USERS\demo\x' = 5 }
        @(Select-MorpheusTopOrdner -Groessen $g2).Count | Should Be 1
    }
    It 'liefert ein Array auch bei leerer Eingabe' {
        $r = @(Select-MorpheusTopOrdner -Groessen @{})
        $r.Count | Should Be 0
    }
}

Describe 'Messen auf Testordner' {
    $stamm = Join-Path $TestDrive 'stamm'
    $fremd = Join-Path $TestDrive 'fremd'
    New-TestDatei (Join-Path $stamm 'a\eins.bin') 1000
    New-TestDatei (Join-Path $stamm 'a\b\zwei.bin') 2000
    New-TestDatei (Join-Path $stamm 'c\drei.bin') 500
    New-TestDatei (Join-Path $stamm 'pagefile.sys') 5000
    New-TestDatei (Join-Path $stamm 'normal.txt') 10
    New-TestDatei (Join-Path $fremd 'gross.bin') 99999
    cmd /c mklink /J "$stamm\link" "$fremd" | Out-Null

    It 'Junction wurde angelegt' {
        (Test-Path -LiteralPath (Join-Path $stamm 'link')) | Should Be $true
    }
    It 'Measure-MorpheusOrdnerGroesse zählt Dateien, aber nicht die Junction' {
        $r = Measure-MorpheusOrdnerGroesse -Pfad $stamm
        $r.bytes | Should Be 8510
        $r.dateien | Should Be 5
        $r.uebersprungen | Should Be 0
    }
    It 'Measure-MorpheusOrdnerGroesse auf Unterordner' {
        $r = Measure-MorpheusOrdnerGroesse -Pfad (Join-Path $stamm 'a')
        $r.bytes | Should Be 3000
        $r.dateien | Should Be 2
    }
    It 'Measure-MorpheusLaufwerk mit -Stamm liefert die Vertragsfelder' {
        $l = Measure-MorpheusLaufwerk -Stamm $stamm
        ($l.PSObject.Properties.Name -join ',') | Should Be 'laufwerk,bezeichnung,groesse,frei,ordner,dateien,gezaehlt,uebersprungen,dauerSek,fehler'
        $l.gezaehlt | Should Be 5
        $l.fehler | Should Be $null
    }
    It 'Ordner: a (Gesamtgröße) und c, ohne Junction' {
        $l = Measure-MorpheusLaufwerk -Stamm $stamm
        $o = @($l.ordner)
        $o.Count | Should Be 2
        $o[0].pfad | Should Be (Join-Path $stamm 'a')
        $o[0].bytes | Should Be 3000
        $o[1].pfad | Should Be (Join-Path $stamm 'c')
        ($o | Where-Object { $_.pfad -like '*link*' -or $_.pfad -like '*fremd*' }) | Should BeNullOrEmpty
    }
    It 'Dateien: pagefile.sys im Stamm ist Windows-Datei, Junction-Inhalt fehlt' {
        $l = Measure-MorpheusLaufwerk -Stamm $stamm
        $d = @($l.dateien)
        $d[0].pfad | Should Be (Join-Path $stamm 'pagefile.sys')
        $d[0].bytes | Should Be 5000
        $d[0].windows | Should Be $true
        $d[0].geaendert | Should Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$'
        ($d | Where-Object { $_.pfad -like '*gross.bin' }) | Should BeNullOrEmpty
        ($d | Where-Object { $_.pfad -like '*eins.bin' }).windows | Should Be $false
    }
    It 'Top begrenzt die Dateiliste' {
        $l = Measure-MorpheusLaufwerk -Stamm $stamm -Top 2
        @($l.dateien).Count | Should Be 2
        @($l.dateien)[1].bytes | Should Be 2000
    }
    It 'meldet Fortschritt für Ordner der obersten Ebene' {
        $script:fort = @()
        [void](Measure-MorpheusLaufwerk -Stamm $stamm -Fortschritt { param($t) $script:fort += $t })
        ($script:fort -contains (Join-Path $stamm 'a')) | Should Be $true
    }
    It 'nicht vorhandener Stamm ergibt fehler' {
        $l = Measure-MorpheusLaufwerk -Stamm (Join-Path $TestDrive 'gibtsnicht')
        $l.fehler | Should Not BeNullOrEmpty
        @($l.ordner).Count | Should Be 0
    }
}

Describe 'ConvertFrom-MorpheusVdf' {
    It 'liest verschachtelte Werte und Escapes' {
        $t = '"root" { "a" "C:\\Pfad" "b" "Sag \"Hallo\"" "k" { "x" "1" } }'
        $v = ConvertFrom-MorpheusVdf -Text $t
        $v['root']['a'] | Should Be 'C:\Pfad'
        $v['root']['b'] | Should Be 'Sag "Hallo"'
        $v['root']['k']['x'] | Should Be '1'
    }
    It 'liest die Beispiel-acf' {
        $v = ConvertFrom-MorpheusVdf -Text ([IO.File]::ReadAllText((Join-Path $script:Fixtures 'appmanifest_730.acf')))
        $v['AppState']['name'] | Should Be 'Counter-Strike "Demo"'
        $v['AppState']['SizeOnDisk'] | Should Be '98765432100'
    }
    It 'liest die Beispiel-libraryfolders.vdf' {
        $t = [IO.File]::ReadAllText((Join-Path $script:Fixtures 'libraryfolders.vdf.tmpl')).Replace('{{STEAM}}', 'C:\\Steam').Replace('{{LIB2}}', 'X:\\SteamLibrary')
        $v = ConvertFrom-MorpheusVdf -Text $t
        $v['libraryfolders']['1']['path'] | Should Be 'X:\SteamLibrary'
        $v['libraryfolders']['0']['apps']['440'] | Should Be '12345678'
    }
    It 'liefert bei leerem Text eine leere Hashtable' {
        (ConvertFrom-MorpheusVdf -Text '').Count | Should Be 0
    }
}

Describe 'Spieleparser mit Fixtures' {
    $steam = Join-Path $TestDrive 'Steam'
    $lib2 = Join-Path $TestDrive 'SteamLibrary'
    $epicLib = Join-Path $TestDrive 'EpicGames\Demo'
    New-Item -ItemType Directory -Path "$steam\steamapps\common\Team Fortress 2" -Force | Out-Null
    New-Item -ItemType Directory -Path "$steam\steamapps\common\Steamworks Shared" -Force | Out-Null
    New-Item -ItemType Directory -Path "$lib2\steamapps\common\Counter-Strike Global Offensive" -Force | Out-Null
    New-Item -ItemType Directory -Path $epicLib -Force | Out-Null
    $vdf = [IO.File]::ReadAllText((Join-Path $script:Fixtures 'libraryfolders.vdf.tmpl')).Replace('{{STEAM}}', $steam.Replace('\', '\\')).Replace('{{LIB2}}', $lib2.Replace('\', '\\'))
    [IO.File]::WriteAllText("$steam\steamapps\libraryfolders.vdf", $vdf)
    Copy-Item (Join-Path $script:Fixtures 'appmanifest_440.acf') "$steam\steamapps\"
    Copy-Item (Join-Path $script:Fixtures 'appmanifest_228980.acf') "$steam\steamapps\"
    Copy-Item (Join-Path $script:Fixtures 'appmanifest_730.acf') "$lib2\steamapps\"
    $manif = Join-Path $TestDrive 'Manifests'
    New-Item -ItemType Directory -Path $manif -Force | Out-Null
    foreach ($f in Get-ChildItem (Join-Path $script:Fixtures 'epic') -Filter '*.item') {
        $t = [IO.File]::ReadAllText($f.FullName).Replace('{{EPIC}}', $epicLib.Replace('\', '\\'))
        [IO.File]::WriteAllText((Join-Path $manif $f.Name), $t)
    }

    It 'Steam: findet beide Bibliotheken, lässt AppID 228980 weg' {
        $s = @(Get-MorpheusSteamSpiele -SteamPfad $steam)
        $s.Count | Should Be 2
        ($s | Where-Object { $_.name -eq 'Steamworks Common Redistributables' }) | Should BeNullOrEmpty
    }
    It 'Steam: Name, Pfad, Bytes, Plattform' {
        $s = @(Get-MorpheusSteamSpiele -SteamPfad $steam)
        $tf = $s | Where-Object { $_.name -eq 'Team Fortress 2' }
        $tf.plattform | Should Be 'Steam'
        $tf.pfad | Should Be "$steam\steamapps\common\Team Fortress 2"
        $tf.bytes | Should Be 12345678
        $tf.groesseUnsicher | Should Be $false
        $cs = $s | Where-Object { $_.name -eq 'Counter-Strike "Demo"' }
        $cs.pfad | Should Be "$lib2\steamapps\common\Counter-Strike Global Offensive"
        $cs.bytes | Should Be 98765432100
        $cs.laufwerk | Should Match '^[A-Z]:$'
    }
    It 'Steam: zuletztGespielt als lokale ISO-Zeit, 0 ergibt null' {
        $s = @(Get-MorpheusSteamSpiele -SteamPfad $steam)
        $erwartet = [DateTimeOffset]::FromUnixTimeSeconds(1760000000).LocalDateTime.ToString('s')
        ($s | Where-Object { $_.name -eq 'Team Fortress 2' }).zuletztGespielt | Should Be $erwartet
        ($s | Where-Object { $_.name -like 'Counter*' }).zuletztGespielt | Should Be $null
    }
    It 'Steam: ohne Pfad und ohne Registry leeres Array' {
        Mock Get-MorpheusRegWert { $null }
        @(Get-MorpheusSteamSpiele).Count | Should Be 0
    }
    It 'Epic: liest .item-Dateien, lässt fehlende Ordner weg' {
        $e = @(Get-MorpheusEpicSpiele -ManifestOrdner $manif)
        $e.Count | Should Be 1
        $e[0].plattform | Should Be 'Epic'
        $e[0].name | Should Be 'Epic Demo Game'
        $e[0].pfad | Should Be $epicLib
        $e[0].bytes | Should Be 5000000000
        $e[0].zuletztGespielt | Should Be $null
    }
    It 'Epic: fehlender Manifestordner ergibt leeres Array' {
        @(Get-MorpheusEpicSpiele -ManifestOrdner (Join-Path $TestDrive 'nix')).Count | Should Be 0
    }

    It 'GOG: Registry (Mock), Größe gemessen' {
        New-TestDatei (Join-Path $TestDrive 'GOG\Spiel\daten.bin') 1234
        Mock Get-MorpheusRegEintraege { @([pscustomobject]@{ gameName = 'GOG Demo'; path = (Join-Path $TestDrive 'GOG\Spiel') }, [pscustomobject]@{ gameName = 'Weg'; path = (Join-Path $TestDrive 'GOG\weg') }) } -ParameterFilter { $Pfad -like '*GOG.com*' }
        $g = @(Get-MorpheusGogSpiele)
        $g.Count | Should Be 1
        $g[0].plattform | Should Be 'GOG'
        $g[0].name | Should Be 'GOG Demo'
        $g[0].bytes | Should Be 1234
    }
    It 'EA: nur Publisher Electronic Arts mit InstallLocation, ohne die EA app' {
        New-TestDatei (Join-Path $TestDrive 'EA\Spiel\x.bin') 77
        Mock Get-MorpheusRegEintraege {
            @(
                [pscustomobject]@{ DisplayName = 'EA Demo'; Publisher = 'Electronic Arts'; InstallLocation = (Join-Path $TestDrive 'EA\Spiel') },
                [pscustomobject]@{ DisplayName = 'EA app'; Publisher = 'Electronic Arts'; InstallLocation = (Join-Path $TestDrive 'EA\Spiel') },
                [pscustomobject]@{ DisplayName = 'Anderes'; Publisher = 'Fremd'; InstallLocation = (Join-Path $TestDrive 'EA\Spiel') }
            )
        } -ParameterFilter { $Pfad -like '*WOW6432Node*' }
        Mock Get-MorpheusRegEintraege { @() }
        $e = @(Get-MorpheusEaSpiele)
        $e.Count | Should Be 1
        $e[0].name | Should Be 'EA Demo'
        $e[0].plattform | Should Be 'EA'
        $e[0].bytes | Should Be 77
    }
    It 'Ubisoft: Name aus Uplay-Install-Eintrag, sonst Ordnername' {
        New-TestDatei (Join-Path $TestDrive 'Ubi\Far\x.bin') 10
        New-TestDatei (Join-Path $TestDrive 'Ubi\Ohne Name\x.bin') 20
        Mock Get-MorpheusRegEintraege { @([pscustomobject]@{ PSChildName = '42'; InstallDir = (Join-Path $TestDrive 'Ubi\Far') }, [pscustomobject]@{ PSChildName = '99'; InstallDir = ((Join-Path $TestDrive 'Ubi\Ohne Name') + '\') }) } -ParameterFilter { $Pfad -like '*Launcher\Installs*' }
        Mock Get-MorpheusRegEintraege { @([pscustomobject]@{ PSChildName = 'Uplay Install 42'; DisplayName = 'Far Demo' }) } -ParameterFilter { $Pfad -like '*Uplay Install*' -and $Pfad -like '*WOW6432Node*' }
        Mock Get-MorpheusRegEintraege { @() }
        $u = @(Get-MorpheusUbisoftSpiele)
        $u.Count | Should Be 2
        ($u | Where-Object { $_.name -eq 'Far Demo' }).bytes | Should Be 10
        ($u | Where-Object { $_.name -eq 'Ohne Name' }).bytes | Should Be 20
    }
    It 'Xbox: nur Laufwerke mit .GamingRoot, GameSave ausgenommen' {
        $lw = Join-Path $TestDrive 'XLW'
        New-TestDatei (Join-Path $lw '.GamingRoot') 1
        New-TestDatei (Join-Path $lw 'XboxGames\Forza\Content\x.bin') 5
        [IO.File]::WriteAllText((Join-Path $lw 'XboxGames\Forza\Content\MicrosoftGame.config'), '<Game><ShellVisuals DefaultDisplayName="Forza Demo" /></Game>')
        New-TestDatei (Join-Path $lw 'XboxGames\Halo\x.bin') 300
        New-TestDatei (Join-Path $lw 'XboxGames\GameSave\s.bin') 5
        $x = @(Get-MorpheusXboxSpiele -Laufwerke @($lw, (Join-Path $TestDrive 'ohne')))
        $x.Count | Should Be 2
        ($x | Where-Object { $_.name -eq 'Forza Demo' }) | Should Not BeNullOrEmpty
        (($x | Where-Object { $_.name -eq 'Halo' }).bytes) | Should Be 300
    }
    It 'Xbox: Ordnername aus .GamingRoot (z. B. XBOX), unsichere Namen ergeben XboxGames' {
        $lw = Join-Path $TestDrive 'XLW2'
        New-TestDatei (Join-Path $lw 'XBOX\Starfield\x.bin') 7
        $kopf = [byte[]](0x52, 0x47, 0x42, 0x58, 1, 0, 0, 0)
        [IO.File]::WriteAllBytes((Join-Path $lw '.GamingRoot'), $kopf + [Text.Encoding]::Unicode.GetBytes("XBOX`0"))
        $x = @(Get-MorpheusXboxSpiele -Laufwerke @($lw))
        $x.Count | Should Be 1
        $x[0].pfad | Should Be (Join-Path $lw 'XBOX\Starfield')
        $boese = Join-Path $TestDrive 'gr-boese'
        [IO.File]::WriteAllBytes($boese, $kopf + [Text.Encoding]::Unicode.GetBytes("..\Windows`0"))
        Get-MorpheusXboxOrdner -Datei $boese | Should Be 'XboxGames'
    }

    It 'Spielpfade: nur lokale Laufwerkspfade, kein UNC (Admin-Prozess soll keine fremden Rechner kontaktieren)' {
        MorpheusSpeicherPfadNorm '\\server\share\Spiel' | Should Be ''
        MorpheusSpeicherPfadNorm '//server/share' | Should Be ''
        MorpheusSpeicherPfadNorm '\\?\C:\Spiel' | Should Be ''
        MorpheusSpeicherPfadNorm 'F:/SteamLibrary/' | Should Be 'F:\SteamLibrary'
        @(Get-MorpheusSteamSpiele -SteamPfad '\\server\steam').Count | Should Be 0
        New-MorpheusGemessenesSpiel -Plattform 'GOG' -Name 'x' -Pfad '\\server\share\x' | Should BeNullOrEmpty
    }

    It 'Get-MorpheusSpiele entfernt doppelte Pfade und sortiert absteigend' {
        Mock Get-MorpheusSteamSpiele { @((New-MorpheusSpiel 'Steam' 'A' 'D:\Spiele\A' 100), (New-MorpheusSpiel 'Steam' 'B' 'D:\Spiele\B' 500)) }
        Mock Get-MorpheusEpicSpiele { @((New-MorpheusSpiel 'Epic' 'A-Epic' 'd:\spiele\a\' 100)) }
        Mock Get-MorpheusGogSpiele { @() }
        Mock Get-MorpheusEaSpiele { @() }
        Mock Get-MorpheusUbisoftSpiele { @() }
        Mock Get-MorpheusXboxSpiele { @() }
        $s = @(Get-MorpheusSpiele -Laufwerke @('D:'))
        $s.Count | Should Be 2
        $s[0].name | Should Be 'B'
        $s[1].plattform | Should Be 'Steam'
    }
}

Describe 'Read-MorpheusSpielordner' {
    It 'fehlende, leere und kaputte Datei ergeben ein leeres Array' {
        @(Read-MorpheusSpielordner -Datei (Join-Path $TestDrive 'gibtsnicht.json')).Count | Should Be 0
        $leer = Join-Path $TestDrive 'so-leer.json'
        [IO.File]::WriteAllText($leer, '  ')
        @(Read-MorpheusSpielordner -Datei $leer).Count | Should Be 0
        $kaputt = Join-Path $TestDrive 'so-kaputt.json'
        [IO.File]::WriteAllText($kaputt, '{ nicht [ json')
        @(Read-MorpheusSpielordner -Datei $kaputt).Count | Should Be 0
    }
    It 'behält gültige Einträge, verwirft unbekannte Plattform, UNC und relative Pfade' {
        $d = Join-Path $TestDrive 'so-mix.json'
        $json = '[{"plattform":"Steam","pfad":"G:\\Games\\Steam"},{"plattform":"steam","pfad":"G:\\x"},{"plattform":"Foo","pfad":"G:\\x"},' +
            '{"plattform":"Epic","pfad":"\\\\server\\share"},{"plattform":"GOG","pfad":"relativ\\ordner"},{"plattform":"Andere","pfad":"H:\\Spiele"},{"plattform":"Xbox"}]'
        [IO.File]::WriteAllText($d, $json)
        $r = @(Read-MorpheusSpielordner -Datei $d)
        $r.Count | Should Be 2
        $r[0].plattform | Should Be 'Steam'
        $r[0].pfad | Should Be 'G:\Games\Steam'
        $r[1].plattform | Should Be 'Andere'
    }
    It 'liest auch ein einzelnes Objekt und kürzt auf 50 Einträge' {
        $d = Join-Path $TestDrive 'so-eins.json'
        [IO.File]::WriteAllText($d, '{"plattform":"EA","pfad":"D:\\EA"}')
        @(Read-MorpheusSpielordner -Datei $d).Count | Should Be 1
        $viele = (1..60 | ForEach-Object { '{"plattform":"Steam","pfad":"G:\\Lib' + $_ + '"}' }) -join ','
        $d2 = Join-Path $TestDrive 'so-viele.json'
        [IO.File]::WriteAllText($d2, '[' + $viele + ']')
        @(Read-MorpheusSpielordner -Datei $d2).Count | Should Be 50
    }
}

Describe 'Get-MorpheusManuelleSpiele' {
    $lib = Join-Path $TestDrive 'manuell\Bibliothek'
    $fremd = Join-Path $TestDrive 'manuell\fremd'
    New-TestDatei (Join-Path $lib 'Spiel Eins\a.bin') 100
    New-TestDatei (Join-Path $lib 'Spiel Zwei\b.bin') 250
    New-TestDatei (Join-Path $fremd 'gross.bin') 9999
    cmd /c mklink /J "$lib\Verknuepft" "$fremd" | Out-Null
    $libLink = Join-Path $TestDrive 'manuell\LibLink'
    cmd /c mklink /J "$libLink" "$lib" | Out-Null

    It 'jeder direkte Unterordner ist ein Spiel, Junctions fehlen' {
        $s = @(Get-MorpheusManuelleSpiele -Eintraege @([pscustomobject]@{ plattform = 'Andere'; pfad = $lib }))
        $s.Count | Should Be 2
        ($s | Where-Object { $_.name -eq 'Verknuepft' }) | Should BeNullOrEmpty
        $e = $s | Where-Object { $_.name -eq 'Spiel Zwei' }
        $e.plattform | Should Be 'Andere'
        $e.bytes | Should Be 250
        $e.pfad | Should Be (Join-Path $lib 'Spiel Zwei')
        $e.zuletztGespielt | Should Be $null
    }
    It 'ein Ordner, der selbst eine Junction ist, ergibt keine Spiele' {
        @(Get-MorpheusManuelleSpiele -Eintraege @([pscustomobject]@{ plattform = 'Steam'; pfad = $libLink })).Count | Should Be 0
    }
    It 'fehlender Ordner, UNC und leere Eingabe ergeben keine Spiele und keinen Fehler' {
        @(Get-MorpheusManuelleSpiele -Eintraege @([pscustomobject]@{ plattform = 'Steam'; pfad = (Join-Path $TestDrive 'nix') }, [pscustomobject]@{ plattform = 'Steam'; pfad = '\\server\share' })).Count | Should Be 0
        @(Get-MorpheusManuelleSpiele -Eintraege @()).Count | Should Be 0
    }
    It 'Get-MorpheusSpiele: automatischer Eintrag gewinnt bei doppeltem Pfad, Fortschritt wird gemeldet' {
        Mock Get-MorpheusSteamSpiele { @((New-MorpheusSpiel 'Steam' 'Auto Eins' ((Join-Path $lib 'Spiel Eins').ToUpper()) 5 '2026-10-20T21:14:03')) }
        Mock Get-MorpheusEpicSpiele { @() }
        Mock Get-MorpheusGogSpiele { @() }
        Mock Get-MorpheusEaSpiele { @() }
        Mock Get-MorpheusUbisoftSpiele { @() }
        Mock Get-MorpheusXboxSpiele { @() }
        $script:fort2 = @()
        $s = @(Get-MorpheusSpiele -Laufwerke @('D:') -Manuell @([pscustomobject]@{ plattform = 'Andere'; pfad = $lib }) -Fortschritt { param($t) $script:fort2 += $t })
        $s.Count | Should Be 2
        ($s | Where-Object { $_.name -eq 'Auto Eins' }).plattform | Should Be 'Steam'
        ($s | Where-Object { $_.name -eq 'Spiel Eins' }) | Should BeNullOrEmpty
        ($s | Where-Object { $_.name -eq 'Spiel Zwei' }).plattform | Should Be 'Andere'
        ($script:fort2 -contains 'Eigene Spiele-Ordner werden gemessen …') | Should Be $true
    }
    It 'Get-MorpheusSpeicher reicht -Manuell an Get-MorpheusSpiele weiter' {
        Mock Measure-MorpheusLaufwerk { [pscustomobject]@{ laufwerk = 'Z:' } }
        Mock Get-MorpheusSpiele { @() } -ParameterFilter { @($Manuell).Count -eq 1 -and $Manuell[0].pfad -eq 'G:\Lib' }
        $r = Get-MorpheusSpeicher -Laufwerke @('Z:') -Manuell @([pscustomobject]@{ plattform = 'Steam'; pfad = 'G:\Lib' })
        Assert-MockCalled Get-MorpheusSpiele -Exactly 1 -Scope It -ParameterFilter { @($Manuell).Count -eq 1 }
    }
}

Describe 'Get-MorpheusSpeicher' {
    $stamm = Join-Path $TestDrive 'gesamt'
    New-TestDatei (Join-Path $stamm 'x\a.bin') 100
    It 'liefert das Vertragsobjekt und serialisiert mit Arrays' {
        Mock Get-MorpheusSpiele { @((New-MorpheusSpiel 'Steam' 'Demo' 'D:\Demo' 42 '2026-10-20T21:14:03')) }
        Mock Measure-MorpheusLaufwerk { [pscustomobject]@{ laufwerk = 'Z:' } }
        $r = Get-MorpheusSpeicher -Laufwerke @('Z:')
        ($r.PSObject.Properties.Name -join ',') | Should Be 'version,stand,laufwerke,spiele'
        $r.version | Should Be 1
        $r.stand | Should Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$'
        $json = $r | ConvertTo-Json -Depth 6
        $back = $json | ConvertFrom-Json
        @($back.spiele).Count | Should Be 1
        $back.spiele[0].name | Should Be 'Demo'
        ($back.spiele[0].PSObject.Properties.Name -join ',') | Should Be 'plattform,name,pfad,laufwerk,bytes,zuletztGespielt,groesseUnsicher'
        $json | Should Match '"spiele":\s*\['
        $json | Should Match '"laufwerke":\s*\['
    }
    It 'OhneSpiele ergibt leeres Spiele-Array' {
        Mock Measure-MorpheusLaufwerk { [pscustomobject]@{ laufwerk = 'Z:' } }
        $r = Get-MorpheusSpeicher -Laufwerke @('Z:') -OhneSpiele
        @($r.spiele).Count | Should Be 0
        ($r | ConvertTo-Json -Depth 6) | Should Match '"spiele":\s*\[\s*\]'
    }
}

# Eigener Describe, damit die Mocks oben nicht wirken
Describe 'Laufwerksobjekt serialisieren' {
    $stamm = Join-Path $TestDrive 'gesamt2'
    New-TestDatei (Join-Path $stamm 'x\a.bin') 100
    It 'echte Laufwerksmessung (Teststamm) lässt sich serialisieren' {
        $l = Measure-MorpheusLaufwerk -Stamm $stamm
        $o = [pscustomobject][ordered]@{ version = 1; stand = 'x'; laufwerke = @($l); spiele = @() }
        $json = $o | ConvertTo-Json -Depth 6
        $json | Should Match '"ordner":\s*\['
        $json | Should Match '"dateien":\s*\['
        $json | Should Match '"windows"'
    }
}
