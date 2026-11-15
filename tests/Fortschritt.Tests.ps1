#Requires -Version 5.1
$env:MORPHEUS_SPRACHE = 'de'
# Pester-3.4-Tests fuer gui\lib\Fortschritt.ps1 (Fortschrittsvertrag 2.8, #137). Reine Funktionen; ein Test startet einen
# echten, harmlosen Start-Job, um zu pruefen, dass Hashtable und Tag die Job-Grenze ueberstehen (Plan Abschnitt 7, Risiko 1).
# Ausfuehren: Invoke-Pester tests\Fortschritt.Tests.ps1

$script:FsDatei = Join-Path $PSScriptRoot '..\gui\lib\Fortschritt.ps1'
. $script:FsDatei

Describe 'ConvertTo-MorpheusFortschritt: gueltige Faelle' {
    It 'prozent' {
        $f = ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = 42; phase = 'ausfuehren' } -Art 'wartung'
        $f.modus | Should Be 'prozent'
        $f.prozent | Should Be 42
        $f.i | Should Be $null
        $f.n | Should Be $null
        $f.phase | Should Be 'ausfuehren'
        $f.text | Should Be $null
        $f.elemente | Should Be $null
        @($f.Keys) -join ',' | Should Be 'modus,prozent,i,n,phase,text,elemente'
    }
    It 'zaehler: Server rechnet prozent selbst, mitgeschicktes prozent zaehlt nicht' {
        $f = ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 5; n = 12; prozent = 99; phase = 'punkt'; text = 'Autostart' } -Art 'run'
        $f.modus | Should Be 'zaehler'
        $f.i | Should Be 5
        $f.n | Should Be 12
        $f.prozent | Should Be 41
        $f.phase | Should Be 'punkt'
        $f.text | Should Be 'Autostart'
    }
    It 'offen: prozent null' {
        $f = ConvertTo-MorpheusFortschritt -Daten @{ modus = 'offen'; prozent = 50 } -Art 'scan'
        $f.modus | Should Be 'offen'
        $f.prozent | Should Be $null
        $f.i | Should Be $null
    }
    It 'Zahlen als Zeichenkette werden per TryParse gelesen' {
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = '3'; n = ' 4 ' } -Art 'run').prozent | Should Be 75
    }
    It 'Kommazahl wird abgeschnitten' {
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = 25.9 } -Art 'wartung').prozent | Should Be 25
    }
    It 'geordnete Hashtable als Eingabe' {
        $d = [ordered]@{ modus = 'prozent'; prozent = 7 }
        (ConvertTo-MorpheusFortschritt -Daten $d -Art 'wartung').prozent | Should Be 7
    }
    It 'zurueckspringende Werte sind erlaubt (kein Zwang zu steigenden Werten)' {
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = 3 } -Art 'wartung').prozent | Should Be 3
    }
}

Describe 'ConvertTo-MorpheusFortschritt: Grenzen' {
    It 'prozent 150 -> 100, -3 -> 0' {
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = 150 } -Art 'wartung').prozent | Should Be 100
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = -3 } -Art 'wartung').prozent | Should Be 0
    }
    It 'i > n -> n' {
        $f = ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 20; n = 12 } -Art 'run'
        $f.i | Should Be 12
        $f.prozent | Should Be 100
    }
    It 'i < 0 -> 0' {
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = -2; n = 12 } -Art 'run').i | Should Be 0
    }
    It 'n > 9999 -> 9999' {
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 1; n = 50000 } -Art 'run').n | Should Be 9999
    }
    It 'n = 0 -> verworfen' {
        ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 0; n = 0 } -Art 'run' | Should Be $null
    }
    It 'zaehler ohne i oder n -> verworfen' {
        ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; n = 3 } -Art 'run' | Should Be $null
        ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 3 } -Art 'run' | Should Be $null
    }
    It 'prozent ohne Zahl -> verworfen' {
        ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent' } -Art 'wartung' | Should Be $null
        ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = 'viel' } -Art 'wartung' | Should Be $null
        ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = '1e3' } -Art 'wartung' | Should Be $null
        ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = [double]::NaN } -Art 'wartung' | Should Be $null
        ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = $true } -Art 'wartung' | Should Be $null
    }
}

Describe 'ConvertTo-MorpheusFortschritt: Kennungen und Text' {
    It 'unbekannter modus -> $null (auch andere Schreibung)' {
        ConvertTo-MorpheusFortschritt -Daten @{ modus = 'fertig'; prozent = 1 } -Art 'run' | Should Be $null
        ConvertTo-MorpheusFortschritt -Daten @{ modus = 'Prozent'; prozent = 1 } -Art 'run' | Should Be $null
        ConvertTo-MorpheusFortschritt -Daten @{ modus = 1; prozent = 1 } -Art 'run' | Should Be $null
        ConvertTo-MorpheusFortschritt -Daten @{ prozent = 1 } -Art 'run' | Should Be $null
    }
    It 'unbekannte phase -> null' {
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = 1; phase = 'boese' } -Art 'run').phase | Should Be $null
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = 1; phase = 'Punkt' } -Art 'run').phase | Should Be $null
    }
    It 'phase nur aus der Liste der Job-Art' {
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = 1; phase = 'journal' } -Art 'wartung').phase | Should Be $null
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = 1; phase = 'auswerten' } -Art 'wartung').phase | Should Be 'auswerten'
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = 1; phase = 'scan' } -Art 'scan').phase | Should Be 'scan'
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = 1; phase = 'scan' } -Art 'speicher').phase | Should Be $null
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'prozent'; prozent = 1; phase = 'scan' } -Art $null).phase | Should Be $null
    }
    It 'text mit U+202E und 300 Zeichen -> bereinigt, 120 Zeichen' {
        $roh = 'ab' + [string][char]0x202E + 'cd' + [string][char]0x0007 + ('x' * 300)
        $f = ConvertTo-MorpheusFortschritt -Daten @{ modus = 'offen'; text = $roh } -Art 'run'
        $f.text.Length | Should Be 120
        $f.text.StartsWith('abcd') | Should Be $true
        $f.text.IndexOf([char]0x202E) | Should Be -1
        $f.text.IndexOf([char]0x0007) | Should Be -1
    }
    It 'text: Zeilenumbruch und Tabulator raus, leer -> null, kein String -> null' {
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'offen'; text = "a`r`nb`tc" } -Art 'run').text | Should Be 'ab c'
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'offen'; text = "  `n " } -Art 'run').text | Should Be $null
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'offen'; text = @('a', 'b') } -Art 'run').text | Should Be $null
    }
    It 'elemente ohne Paketliste des Servers bleibt null' {
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'offen'; elemente = @(@{ id = 'x'; name = 'y'; status = 'fertig' }) } -Art 'wartung').elemente | Should Be $null
    }
    It 'Zeichenkette statt Hashtable -> $null' {
        ConvertTo-MorpheusFortschritt -Daten '{"modus":"prozent","prozent":50}' -Art 'run' | Should Be $null
        ConvertTo-MorpheusFortschritt -Daten $null -Art 'run' | Should Be $null
        ConvertTo-MorpheusFortschritt -Daten ([pscustomobject]@{ modus = 'prozent'; prozent = 50 }) -Art 'run' | Should Be $null
    }
}

Describe 'ConvertTo-MorpheusFortschritt: elemente (2.9, #140)' {
    BeforeEach {
        $script:srv = @(
            [pscustomobject]@{ id = 'A.App'; name = 'App A'; von = '1.0'; auf = '1.1' },
            [pscustomobject]@{ id = 'B.App'; name = 'App B'; von = '2.0'; auf = '2.5' }
        )
    }
    It 'fremde id -> nicht in der Antwort' {
        $f = ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 0; n = 2; elemente = @(@{ id = 'Boese.App'; status = 'laeuft' }, @{ id = 'A.App'; status = 'offen' }) } -Art 'wartung' -Pakete $script:srv
        @($f.elemente).Count | Should Be 1
        $f.elemente[0].id | Should Be 'A.App'
        (@($f.elemente) | Where-Object { $_.id -eq 'Boese.App' }) | Should Be $null
    }
    It 'id nur exakt (Gross-/Kleinschreibung)' {
        $f = ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 0; n = 2; elemente = @(@{ id = 'a.app'; status = 'offen' }) } -Art 'wartung' -Pakete $script:srv
        @($f.elemente).Count | Should Be 0
    }
    It 'name/von/auf im Record -> ignoriert, Werte aus der Serverliste' {
        $f = ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 1; n = 2; elemente = @(
                @{ id = 'B.App'; name = '<img src=x onerror=alert(1)>'; von = '9'; auf = '9'; status = 'fertig' }) } -Art 'wartung' -Pakete $script:srv
        $f.elemente[0].name | Should Be 'App B'
        $f.elemente[0].von | Should Be '2.0'
        $f.elemente[0].auf | Should Be '2.5'
        $f.elemente[0].status | Should Be 'fertig'
    }
    It 'unbekannter status, doppelte id und Nicht-Hashtables werden verworfen' {
        $f = ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 0; n = 2; elemente = @(
                @{ id = 'A.App'; status = 'Fertig' }, 'A.App', @{ id = 'B.App'; status = 'fehler' }, @{ id = 'B.App'; status = 'fertig' }, @{ id = 7; status = 'offen' }) } -Art 'wartung' -Pakete $script:srv
        @($f.elemente).Count | Should Be 1
        $f.elemente[0].id | Should Be 'B.App'
        $f.elemente[0].status | Should Be 'fehler'
    }
    It 'alle fuenf Zustaende sind erlaubt' {
        foreach ($st in 'offen', 'laeuft', 'fertig', 'fehler', 'abgebrochen') {
            $f = ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 0; n = 1; elemente = @(@{ id = 'A.App'; status = $st }) } -Art 'wartung' -Pakete $script:srv
            $f.elemente[0].status | Should Be $st
        }
    }
    It 'hoechstens 200 Eintraege' {
        $viele = @(1..250 | ForEach-Object { [pscustomobject]@{ id = ('P.' + $_); name = ('P ' + $_); von = '1'; auf = '2' } })
        $el = @(1..250 | ForEach-Object { @{ id = ('P.' + $_); status = 'offen' } })
        $f = ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 0; n = 250; elemente = $el } -Art 'wartung' -Pakete $viele
        @($f.elemente).Count | Should Be 200
        $f.elemente[199].id | Should Be 'P.200'
    }
    It 'elemente keine Liste (Zeichenkette, Hashtable) -> leere Liste' {
        @((ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 0; n = 1; elemente = 'A.App' } -Art 'wartung' -Pakete $script:srv).elemente).Count | Should Be 0
        @((ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 0; n = 1; elemente = @{ id = 'A.App'; status = 'offen' } } -Art 'wartung' -Pakete $script:srv).elemente).Count | Should Be 0
    }
    It 'ohne Feld elemente bleibt elemente null, auch mit Paketliste' {
        (ConvertTo-MorpheusFortschritt -Daten @{ modus = 'zaehler'; i = 0; n = 1 } -Art 'wartung' -Pakete $script:srv).elemente | Should Be $null
    }
}

Describe 'Write-MorpheusFortschritt und Test-MorpheusFortschrittRecord' {
    It 'schreibt genau einen getaggten Information-Record mit Hashtable' {
        $r = @(Write-MorpheusFortschritt -Modus 'zaehler' -I 2 -N 5 -Phase 'ausfuehren' -Text 'Titel' 6>&1)
        $r.Count | Should Be 1
        ($r[0] -is [System.Management.Automation.InformationRecord]) | Should Be $true
        ($r[0].MessageData -is [System.Collections.IDictionary]) | Should Be $true
        @($r[0].Tags) -ccontains 'morpheus.fortschritt' | Should Be $true
        $r[0].MessageData['i'] | Should Be 2
        $r[0].MessageData['text'] | Should Be 'Titel'
        $r[0].MessageData.ContainsKey('prozent') | Should Be $false
        Test-MorpheusFortschrittRecord $r[0] | Should Be $true
    }
    It 'Textzeile, auch mit dem Tag, ist kein Fortschritts-Record' {
        $r = @(Write-Information -MessageData '{"modus":"prozent","prozent":50}' -Tags 'morpheus.fortschritt' -InformationAction Continue 6>&1)
        Test-MorpheusFortschrittRecord $r[0] | Should Be $false
    }
    It 'Hashtable ohne Tag ist kein Fortschritts-Record' {
        $r = @(Write-Information -MessageData @{ modus = 'prozent'; prozent = 50 } -InformationAction Continue 6>&1)
        Test-MorpheusFortschrittRecord $r[0] | Should Be $false
        Test-MorpheusFortschrittRecord $null | Should Be $false
    }
    It 'Tag nur exakt (Gross-/Kleinschreibung)' {
        $r = @(Write-Information -MessageData @{ modus = 'prozent'; prozent = 50 } -Tags 'Morpheus.Fortschritt' -InformationAction Continue 6>&1)
        Test-MorpheusFortschrittRecord $r[0] | Should Be $false
    }
}

Describe 'Job-Grenze (echter Start-Job)' {
    It 'Hashtable und Tag ueberstehen die Deserialisierung' {
        $pfad = (Resolve-Path -LiteralPath $script:FsDatei).ProviderPath
        $job = Microsoft.PowerShell.Core\Start-Job -ScriptBlock {
            param($P)
            . $P
            Write-Information -MessageData 'Zeile' -InformationAction Continue
            Write-MorpheusFortschritt -Modus 'zaehler' -I 3 -N 4 -Phase 'ausfuehren' -Text 'Titel'
        } -ArgumentList $pfad
        try {
            $null = Wait-Job -Job $job -Timeout 60
            $job.State | Should Be 'Completed'
            $info = @($job.ChildJobs[0].Information)
            $info.Count | Should Be 2
            Test-MorpheusFortschrittRecord $info[0] | Should Be $false
            Test-MorpheusFortschrittRecord $info[1] | Should Be $true
            ($info[1].MessageData -is [System.Collections.IDictionary]) | Should Be $true
            $f = ConvertTo-MorpheusFortschritt -Daten $info[1].MessageData -Art 'run'
            $f.i | Should Be 3
            $f.n | Should Be 4
            $f.prozent | Should Be 75
            $f.phase | Should Be 'ausfuehren'
            $f.text | Should Be 'Titel'
        }
        finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Fortschritt.ps1 (statisch)' {
    $text = [IO.File]::ReadAllText($script:FsDatei, [Text.Encoding]::UTF8)
    It 'kein Dateizugriff, kein Prozess, kein Add-Type, kein Netz' {
        $text | Should Not Match 'Add-Type|Start-Process|Invoke-WebRequest|Invoke-RestMethod|Set-Content|Out-File|WriteAllText|New-Object\s+Net\.'
    }
    It 'UTF-8 mit BOM' {
        $b = [IO.File]::ReadAllBytes($script:FsDatei)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
    }
    It 'liegt in gui\lib und damit in Get-MorpheusCodeFiles' {
        . (Join-Path $PSScriptRoot '..\gui\lib\Install.ps1')
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
        $liste = @(Get-MorpheusCodeFiles -Root $root)
        @($liste | Where-Object { $_ -like '*\gui\lib\Fortschritt.ps1' }).Count | Should Be 1
    }
}

# Konsolen-Fortschritt (2.9, #142)
Describe 'Test-MorpheusKonsolenFortschritt' {
    It 'gesetztes MORPHEUS_FS -> $false' {
        $alt = $env:MORPHEUS_FS
        try {
            $env:MORPHEUS_FS = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
            (Test-MorpheusKonsolenFortschritt -HostName 'ConsoleHost' -Umgeleitet $false) | Should Be $false
            (Test-MorpheusKonsolenFortschritt) | Should Be $false
        }
        finally { $env:MORPHEUS_FS = $alt }
    }
    It 'umgeleitete Ausgabe -> $false' {
        (Test-MorpheusKonsolenFortschritt -Kennung '' -HostName 'ConsoleHost' -Umgeleitet $true) | Should Be $false
    }
    It 'Job (Host ist nicht die Konsole) -> $false' {
        (Test-MorpheusKonsolenFortschritt -Kennung '' -HostName 'ServerRemoteHost' -Umgeleitet $false) | Should Be $false
    }
    It 'echte Konsole ohne Kennung -> $true' {
        (Test-MorpheusKonsolenFortschritt -Kennung '' -HostName 'ConsoleHost' -Umgeleitet $false) | Should Be $true
    }
    It 'in einem echten Start-Job -> $false' {
        $job = Start-Job -ScriptBlock { param($f) . $f; Test-MorpheusKonsolenFortschritt } -ArgumentList (Resolve-Path $script:FsDatei).ProviderPath
        try { (Receive-Job -Job $job -Wait) | Should Be $false }
        finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Konsolen-Fortschritt: Aufrufer und Texte (statisch)' {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
    $lies = { param($rel) [IO.File]::ReadAllText((Join-Path $root $rel), [Text.Encoding]::UTF8) }
    It 'Install.ps1 und pc-check.ps1 fragen den Helfer, bevor sie Write-Progress nutzen' {
        $inst = & $lies 'gui\lib\Install.ps1'
        $inst | Should Match 'function MorpheusInstallFortschrittAn \{[\s\S]{0,400}Test-MorpheusKonsolenFortschritt'
        $inst | Should Match 'finally \{ if \(\$fs\) \{ MorpheusInstallFortschritt -Fertig \} \}'
        $scan = & $lies 'pc-check.ps1'
        $scan | Should Match '\$wgFs = [\s\S]{0,300}Test-MorpheusKonsolenFortschritt'
    }
    It 'winget-Dialog beendet die Anzeige vor der Rueckfrage' {
        $scan = & $lies 'pc-check.ps1'
        $a = $scan.IndexOf('& $wgFsEnde'); $b = $scan.IndexOf("Read-Host (T 'bericht.update.erneutFrage')")
        ($a -gt 0 -and $b -gt $a) | Should Be $true
    }
    It 'neue Texte in server.psd1 und scan.psd1 beider Sprachen, nicht in serverlib.psd1' {
        foreach ($s in 'de', 'en') {
            $server = Import-PowerShellDataFile -LiteralPath (Join-Path $root "lang\$s\server.psd1")
            $scanT = Import-PowerShellDataFile -LiteralPath (Join-Path $root "lang\$s\scan.psd1")
            $lib = Import-PowerShellDataFile -LiteralPath (Join-Path $root "lang\$s\serverlib.psd1")
            foreach ($k in 'server.install.fsAktivitaet', 'server.install.fsDatei', 'server.install.fsPruefen') {
                [string]::IsNullOrEmpty($server[$k]) | Should Be $false
                $lib.ContainsKey($k) | Should Be $false
            }
            foreach ($k in 'scan.winget.fsAktivitaet', 'scan.winget.fsPaket') { [string]::IsNullOrEmpty($scanT[$k]) | Should Be $false }
            $server['server.install.fsDatei'] | Should Match '\{0\}.*\{1\}'
            $scanT['scan.winget.fsPaket'] | Should Match '\{0\}.*\{1\}.*\{2\}'
        }
    }
}

# Scan-Fortschritt (2.8, #139)
Describe 'Get-MorpheusScanMarkerDaten' {
    $k = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
    It 'richtige Kennung -> zaehler mit i, n, Bereich und Text mit Trennzeichen' {
        $d = Get-MorpheusScanMarkerDaten -Zeile "@@MORPHEUS-FORTSCHRITT $k 5 119 2 9 Virenschutz > Defender: Scans" -Kennung $k
        $d.modus | Should Be 'zaehler'
        $d.i | Should Be 5
        $d.n | Should Be 119
        $d.bereich | Should Be 2
        $d.bereiche | Should Be 9
        $d.text | Should Be ('Virenschutz ' + [char]0x203A + ' Defender: Scans')
    }
    It 'falsche Kennung -> $null (Logzeile)' {
        Get-MorpheusScanMarkerDaten -Zeile '@@MORPHEUS-FORTSCHRITT 0123456789abcdef0123456789abcdef 5 119 2 9 X' -Kennung $k | Should Be $null
    }
    It 'fehlende oder ungueltige eigene Kennung -> $null' {
        Get-MorpheusScanMarkerDaten -Zeile "@@MORPHEUS-FORTSCHRITT $k 5 119 2 9 X" -Kennung $null | Should Be $null
        Get-MorpheusScanMarkerDaten -Zeile "@@MORPHEUS-FORTSCHRITT $k 5 119 2 9 X" -Kennung '' | Should Be $null
        Get-MorpheusScanMarkerDaten -Zeile "@@MORPHEUS-FORTSCHRITT $k 5 119 2 9 X" -Kennung $k.ToUpper() | Should Be $null
    }
    It 'Zeile ohne Kennung, Grossbuchstaben, Praefix davor oder zu lange Zahlen -> $null' {
        Get-MorpheusScanMarkerDaten -Zeile '@@MORPHEUS-FORTSCHRITT 5 119 2 9 X' -Kennung $k | Should Be $null
        Get-MorpheusScanMarkerDaten -Zeile ("@@MORPHEUS-FORTSCHRITT " + $k.ToUpper() + " 5 119 2 9 X") -Kennung $k | Should Be $null
        Get-MorpheusScanMarkerDaten -Zeile "x @@MORPHEUS-FORTSCHRITT $k 5 119 2 9 X" -Kennung $k | Should Be $null
        Get-MorpheusScanMarkerDaten -Zeile "@@MORPHEUS-FORTSCHRITT $k 12345 119 2 9 X" -Kennung $k | Should Be $null
        Get-MorpheusScanMarkerDaten -Zeile ("@@MORPHEUS-FORTSCHRITT $k 5 119 2 9 " + ('x' * 201)) -Kennung $k | Should Be $null
        Get-MorpheusScanMarkerDaten -Zeile $null -Kennung $k | Should Be $null
    }
    It 'Ergebnis besteht die Pruefung des Vertrags (i > n wird gekappt)' {
        $d = Get-MorpheusScanMarkerDaten -Zeile "@@MORPHEUS-FORTSCHRITT $k 130 119 9 9 X" -Kennung $k
        $f = ConvertTo-MorpheusFortschritt -Daten @{ modus = $d.modus; i = $d.i; n = $d.n; phase = $d.phase; text = $d.text } -Art 'scan'
        $f.i | Should Be 119
        $f.n | Should Be 119
        $f.phase | Should Be 'scan'
    }
}

# Zaehllogik aus pc-check.ps1: Die drei Funktionen werden per Parser herausgelöst und mit Attrappen fuer T und
# Get-MorpheusAnzeige in einer Testdatei geladen, die selbst 2 Invoke-Check- und 1 Start-Section-Aufruf enthaelt.
Describe 'pc-check.ps1: Scan-Fortschritt (Marker)' {
    $pc = Join-Path $PSScriptRoot '..\pc-check.ps1'
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $pc).ProviderPath, [ref]$tok, [ref]$err)
    $fns = @($ast.FindAll({ param($a) ($a -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($a.Name -in 'Initialize-ScanFortschritt', 'Send-ScanFortschritt', 'Complete-ScanFortschritt') }, $true))
    $hilfe = Join-Path ([IO.Path]::GetTempPath()) ('morpheus-fstest-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $text = (@($fns | ForEach-Object { $_.Extent.Text }) -join "`r`n") + "`r`nif (`$false) { Start-Section 'a' 'b'; Invoke-Check -Name 'x' -Script {}; Invoke-Check -Name 'y' -Script {} }`r`nif (`$false) { if (`$SkipWinget) { } else { Invoke-Check -Name 'w' -Script {} } }`r`n"
    [IO.File]::WriteAllText($hilfe, $text, (New-Object Text.UTF8Encoding $true))
    function T { $args -join '|' }
    function Get-MorpheusAnzeige { [string]$args[1] }
    . $hilfe

    function Get-Ausgabe([scriptblock]$Sb) {
        $alt = [Console]::Out; $sw = New-Object IO.StringWriter
        [Console]::SetOut($sw)
        try { & $Sb } finally { [Console]::SetOut($alt) }
        return $sw.ToString()
    }

    It 'gibt genau drei Funktionen her' { $fns.Count | Should Be 3 }
    It 'gueltige Kennung: Variable geloescht, Aufrufe gezaehlt, i bleibt bei n' {
        $env:MORPHEUS_FS = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
        try { Initialize-ScanFortschritt } finally { $kennungDanach = $env:MORPHEUS_FS; $env:MORPHEUS_FS = $null }
        $kennungDanach | Should BeNullOrEmpty
        $script:FsN | Should Be 3
        $script:FsBereiche | Should Be 1
        $script:Category = 'Virenschutz'
        $out = Get-Ausgabe { Send-ScanFortschritt 'Firewall'; Send-ScanFortschritt 'Defender'; Send-ScanFortschritt 'Zusatz'; Send-ScanFortschritt 'Mehr' }
        $z = @($out -split "`r?`n" | Where-Object { $_ })
        $z.Count | Should Be 4
        $z[0] | Should Be '@@MORPHEUS-FORTSCHRITT a1b2c3d4e5f60718293a4b5c6d7e8f90 1 3 1 1 Virenschutz > Firewall'
        $z[3] | Should Match '^@@MORPHEUS-FORTSCHRITT a1b2c3d4e5f60718293a4b5c6d7e8f90 3 3 1 1 '
        $d = Get-MorpheusScanMarkerDaten -Zeile $z[0] -Kennung 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
        $d.i | Should Be 1
    }
    It 'ausgelassener Bereich (-SkipWinget): Gesamtzahl ohne ihn, Text endet bei n von n (#150)' {
        $SkipWinget = $true
        $env:MORPHEUS_FS = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
        try { Initialize-ScanFortschritt } finally { $env:MORPHEUS_FS = $null }
        $script:FsN | Should Be 2
        $out = Get-Ausgabe { Send-ScanFortschritt 'x'; Send-ScanFortschritt 'y' }
        @($out -split "`r?`n" | Where-Object { $_ })[1] | Should Match '^@@MORPHEUS-FORTSCHRITT \S+ 2 2 '
    }
    It 'echte pc-check.ps1: genau die drei Skip-Bereiche fallen weg' {
        $SkipUpdateSearch = $true; $SkipWinget = $true; $SkipSpeicher = $true
        $alle = @($ast.FindAll({ param($a) ($a -is [System.Management.Automation.Language.CommandAst]) -and ($a.GetCommandName() -eq 'Invoke-Check') }, $true)).Count
        $hilfe2 = Join-Path ([IO.Path]::GetTempPath()) ('morpheus-fstest-' + [guid]::NewGuid().ToString('N') + '.ps1')
        [IO.File]::WriteAllText($hilfe2, $fns[0].Extent.Text.Replace('$PSCommandPath', '$script:FsQuelle'), (New-Object Text.UTF8Encoding $true))
        $script:FsQuelle = (Resolve-Path $pc).ProviderPath
        . $hilfe2
        $env:MORPHEUS_FS = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
        try { Initialize-ScanFortschritt } finally { $env:MORPHEUS_FS = $null; Remove-Item -LiteralPath $hilfe2 -Force -ErrorAction SilentlyContinue }
        $script:FsN | Should Be ($alle - 3)
    }
    It 'ungueltige Kennung: keine Markerzeile, auch keine Konsolenanzeige' {
        $env:MORPHEUS_FS = 'nicht-hex'
        try { Initialize-ScanFortschritt } finally { $env:MORPHEUS_FS = $null }
        $script:FsKennung | Should Be $null
        $script:FsKonsole | Should Be $false
        $out = Get-Ausgabe { Send-ScanFortschritt 'Firewall' }
        $out | Should BeNullOrEmpty
    }
    It 'Steuerzeichen im Text werden zu Leerzeichen (eine Zeile je Marker)' {
        $env:MORPHEUS_FS = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
        try { Initialize-ScanFortschritt } finally { $env:MORPHEUS_FS = $null }
        $script:Category = "Kat`r`negorie"
        $out = Get-Ausgabe { Send-ScanFortschritt "Na`tme" }
        @($out -split "`r?`n" | Where-Object { $_ }).Count | Should Be 1
        $out | Should Match 'Kat  egorie > Na me'
    }
    Remove-Item -LiteralPath $hilfe -Force -ErrorAction SilentlyContinue
}
