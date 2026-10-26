#Requires -Version 5.1
# Pester-3.4-Tests fuer gui\lib\SysinternalsAuswertung.ps1. Kein Netz, keine Prozessstarts; Testdaten liegen in
# tests\fixtures\sysinternals bzw. in $TestDrive.
# Ausfuehren: Invoke-Pester tests\SysinternalsAuswertung.Tests.ps1

$script:AwDatei = Join-Path $PSScriptRoot '..\gui\lib\SysinternalsAuswertung.ps1'
$script:Fix = Join-Path $PSScriptRoot 'fixtures\sysinternals'
. $script:AwDatei

function Get-Fix {
    param([string]$Name)
    [IO.File]::ReadAllBytes((Join-Path $script:Fix $Name))
}
function New-Aut {
    param([string]$Eintrag = 'X', [string]$Kategorie = 'Logon', [bool]$Aktiv = $true, [bool]$Verifiziert = $false,
        [string]$Pfad = 'C:\Apps\x.exe', [bool]$DateiFehlt = $false, [string]$Signierer = '')
    [pscustomobject]@{ Ort = 'HKLM\Run'; Eintrag = $Eintrag; Aktiv = $Aktiv; Kategorie = $Kategorie; Profil = ''; Beschreibung = ''
        Signierer = $Signierer; Verifiziert = $Verifiziert; Firma = ''; Pfad = $Pfad; DateiFehlt = $DateiFehlt; Version = ''; Befehl = ''; Sha256 = '' }
}
function New-Sig {
    param([string]$Pfad, [bool]$Signiert = $false)
    [pscustomobject]@{ Pfad = $Pfad; Verifiziert = 'Unsigned'; Signiert = $Signiert; Datum = 'n/a'; Herausgeber = 'n/a'; Firma = 'F'; Beschreibung = 'B'; Produkt = 'P'; Version = '1.0'; Typ = '64-bit' }
}

Describe 'SysinternalsAuswertung.ps1 Datei' {
    It 'hat ein UTF-8-BOM' {
        $b = [IO.File]::ReadAllBytes($script:AwDatei)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
    }
    It 'parst ohne Fehler' {
        $err = $null; $tok = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script:AwDatei, [ref]$tok, [ref]$err)
        @($err).Count | Should Be 0
    }
    It 'enthaelt kein Add-Type und startet keine Prozesse' {
        $err = $null; $tok = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:AwDatei, [ref]$tok, [ref]$err)
        $cmds = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and (@('Add-Type', 'Start-Process', 'Invoke-WebRequest', 'Invoke-RestMethod') -contains $n.GetCommandName()) }, $true)
        @($cmds).Count | Should Be 0
    }
}

Describe 'ConvertFrom-MorpheusSysAusgabe' {
    It 'leer und $null ergeben Leerstring' {
        ConvertFrom-MorpheusSysAusgabe -Bytes $null | Should Be ''
        ConvertFrom-MorpheusSysAusgabe -Bytes (New-Object byte[] 0) | Should Be ''
    }
    It 'UTF-16LE mit BOM' {
        $b = [byte[]](@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes('Entry,Wert'))
        ConvertFrom-MorpheusSysAusgabe -Bytes $b | Should Be 'Entry,Wert'
    }
    It 'UTF-8 mit BOM' {
        $b = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('Gr' + [char]0xFC + 'n'))
        ConvertFrom-MorpheusSysAusgabe -Bytes $b | Should Be ('Gr' + [char]0xFC + 'n')
    }
    It 'UTF-16LE ohne BOM wird an den Nullbytes erkannt' {
        $b = [Text.Encoding]::Unicode.GetBytes('Path,Verified')
        ConvertFrom-MorpheusSysAusgabe -Bytes $b | Should Be 'Path,Verified'
    }
    It 'UTF-8 ohne BOM mit Umlaut' {
        $b = (New-Object Text.UTF8Encoding($false)).GetBytes('Druckertreiber f' + [char]0xFC + 'r')
        ConvertFrom-MorpheusSysAusgabe -Bytes $b | Should Be ('Druckertreiber f' + [char]0xFC + 'r')
    }
    It 'ungueltiges UTF-8 faellt auf ANSI zurueck' {
        $b = [byte[]](0x66, 0xFC, 0x72)   # f, ue (ANSI), r
        ConvertFrom-MorpheusSysAusgabe -Bytes $b | Should Be ([Text.Encoding]::Default.GetString($b))
    }
    It 'reines ASCII bleibt unveraendert' {
        ConvertFrom-MorpheusSysAusgabe -Bytes ([Text.Encoding]::ASCII.GetBytes('a,b')) | Should Be 'a,b'
    }
    It 'liest die Autoruns-Fixture (UTF-16 mit BOM)' {
        $t = ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'autorunsc.csv')
        $t.StartsWith('Time,Entry Location') | Should Be $true
    }
}

Describe 'ConvertFrom-MorpheusCsvText' {
    It 'einfache Zeilen' {
        $r = ConvertFrom-MorpheusCsvText -Text "a,b,c`r`n1,2,3`r`n"
        $r.Count | Should Be 2
        $r[0].Count | Should Be 3
        $r[1][2] | Should Be '3'
    }
    It 'gibt eine Liste zurueck und loest eine einzelne Zeile nicht auf' {
        $r = ConvertFrom-MorpheusCsvText -Text 'a,b'
        $r.GetType().FullName | Should Match 'List'
        $r.Count | Should Be 1
        $r[0].Count | Should Be 2
    }
    It 'Anfuehrungszeichen, Komma und doppelte Anfuehrungszeichen im Feld' {
        $r = ConvertFrom-MorpheusCsvText -Text '"Tool ""Pro"", Edition",x'
        $r[0][0] | Should Be 'Tool "Pro", Edition'
        $r[0][1] | Should Be 'x'
    }
    It 'Zeilenumbruch im Feld' {
        $r = ConvertFrom-MorpheusCsvText -Text "`"a`r`nb`",c`r`nd,e"
        $r.Count | Should Be 2
        $r[0][0] | Should Be "a`r`nb"
        $r[1][0] | Should Be 'd'
    }
    It 'LF, CR und CRLF als Zeilenende' {
        (ConvertFrom-MorpheusCsvText -Text "a`nb`nc").Count | Should Be 3
        (ConvertFrom-MorpheusCsvText -Text "a`rb`rc").Count | Should Be 3
        (ConvertFrom-MorpheusCsvText -Text "a`r`nb`r`nc").Count | Should Be 3
    }
    It 'letzte Zeile ohne Zeilenende' {
        $r = ConvertFrom-MorpheusCsvText -Text "a,b`r`nc,d"
        $r.Count | Should Be 2
        $r[1][1] | Should Be 'd'
    }
    It 'leere Zeilen werden uebersprungen, leere Felder bleiben' {
        $r = ConvertFrom-MorpheusCsvText -Text "a,,c`r`n`r`n`r`n,,`r`n"
        $r.Count | Should Be 2
        $r[0][1] | Should Be ''
        $r[1].Count | Should Be 3
    }
    It 'ungleiche Spaltenzahl bleibt erhalten' {
        $r = ConvertFrom-MorpheusCsvText -Text "a,b,c`r`nd,e"
        $r[0].Count | Should Be 3
        $r[1].Count | Should Be 2
    }
    It 'leerer Text ergibt leere Liste' {
        (ConvertFrom-MorpheusCsvText -Text '').Count | Should Be 0
        (ConvertFrom-MorpheusCsvText -Text $null).Count | Should Be 0
    }
    It 'anderer Trenner' {
        $r = ConvertFrom-MorpheusCsvText -Text 'a;b;"c;d"' -Trenner ';'
        $r[0].Count | Should Be 3
        $r[0][2] | Should Be 'c;d'
    }
}

Describe 'ConvertFrom-MorpheusAutorunsCsv' {
    $text = ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'autorunsc.csv')
    $e = @(ConvertFrom-MorpheusAutorunsCsv -Text $text)

    It 'liest alle Eintraege der Fixture' {
        $e.Count | Should Be 9
    }
    It 'UTF-8-Variante liefert dasselbe' {
        $t2 = ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'autorunsc-utf8.csv')
        $e2 = @(ConvertFrom-MorpheusAutorunsCsv -Text $t2)
        $e2.Count | Should Be $e.Count
        $e2[3].Pfad | Should Be $e[3].Pfad
    }
    It 'verifizierter Microsoft-Eintrag' {
        $x = $e | Where-Object { $_.Eintrag -eq 'Spooler' }
        $x.Verifiziert | Should Be $true
        $x.Aktiv | Should Be $true
        $x.Kategorie | Should Be 'Services'
        $x.Signierer | Should Be '(Verified) Microsoft Windows'
        $x.Pfad | Should Be 'c:\windows\system32\spoolsv.exe'
        $x.DateiFehlt | Should Be $false
        $x.Sha256.Length | Should Be 64
    }
    It 'unsignierter Dienst' {
        $x = $e | Where-Object { $_.Eintrag -eq 'VendorSvc' }
        $x.Verifiziert | Should Be $false
        $x.Pfad | Should Be 'c:\programdata\vendor\svc.exe'
        $x.Befehl | Should Be 'C:\ProgramData\Vendor\svc.exe -service'
    }
    It 'Feld mit Komma und doppelten Anfuehrungszeichen' {
        ($e | Where-Object { $_.Eintrag -eq 'DemoTool' }).Beschreibung | Should Be 'Tool "Pro", Edition'
    }
    It 'deaktivierter Eintrag' {
        ($e | Where-Object { $_.Eintrag -eq 'OldUpdater' }).Aktiv | Should Be $false
    }
    It 'File not found wird zu DateiFehlt' {
        $x = $e | Where-Object { $_.Eintrag -eq 'GoneApp' }
        $x.DateiFehlt | Should Be $true
        $x.Pfad | Should Be 'C:\Old\gone.exe'
    }
    It 'Zeilenumbruch im Feld wird zu Leerzeichen' {
        $x = $e | Where-Object { $_.Eintrag -eq '\Vendor\Update' }
        $x.Beschreibung | Should Be ('Pr' + [char]0xFC + 'ft auf Updates. Second line')
        $x.Verifiziert | Should Be $true
    }
    It 'ohne Kopfzeile: leeres Array' {
        $t = ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'autorunsc-ohne-kopf.txt')
        @(ConvertFrom-MorpheusAutorunsCsv -Text $t).Count | Should Be 0
    }
    It 'leerer Text: leeres Array' {
        @(ConvertFrom-MorpheusAutorunsCsv -Text '').Count | Should Be 0
    }
    It 'mit @() ist auch ein einzelner Eintrag ein Array' {
        $r = @(ConvertFrom-MorpheusAutorunsCsv -Text "Entry Location,Entry,Image Path`r`nHKLM\Run,A,c:\a.exe`r`n")
        $r.Count | Should Be 1
        $r[0].Eintrag | Should Be 'A'
    }
    It 'Spalten ueber Namen, Gross-/Kleinschreibung egal, fehlende Spalten leer' {
        $r = @(ConvertFrom-MorpheusAutorunsCsv -Text "image path,ENTRY,entry location,Enabled`r`nc:\a.exe,A,HKLM\Run,Enabled`r`n")
        $r[0].Pfad | Should Be 'c:\a.exe'
        $r[0].Aktiv | Should Be $true
        $r[0].Signierer | Should Be ''
        $r[0].Verifiziert | Should Be $false
        $r[0].Befehl | Should Be ''
    }
    It 'Zeilen ohne Entry und ohne Image Path entfallen; kuerzere Zeilen sind erlaubt' {
        $r = @(ConvertFrom-MorpheusAutorunsCsv -Text "Entry Location,Entry,Image Path`r`nHKLM\Run,,`r`nHKLM\Run,B`r`n")
        $r.Count | Should Be 1
        $r[0].Eintrag | Should Be 'B'
        $r[0].Pfad | Should Be ''
    }
    It 'Steuerzeichen und Bidi-Zeichen werden entfernt' {
        $bidi = [string][char]0x202E
        $rlm = [string][char]0x2028
        $t = "Entry Location,Entry,Image Path`r`nHKLM\Run,`"A${bidi}B" + [char]0x01 + "C${rlm}D`",c:\a.exe`r`n"
        $r = @(ConvertFrom-MorpheusAutorunsCsv -Text $t)
        $r[0].Eintrag | Should Be 'A B C D'
    }
    It 'kuerzt Felder auf 2048 Zeichen' {
        $lang = 'x' * 3000
        $r = @(ConvertFrom-MorpheusAutorunsCsv -Text "Entry Location,Entry,Image Path`r`nHKLM\Run,$lang,c:\a.exe`r`n")
        $r[0].Eintrag.Length | Should Be 2048
    }
    It 'begrenzt auf 5000 Eintraege' {
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append("Entry Location,Entry,Image Path`r`n")
        for ($i = 0; $i -lt 5100; $i++) { [void]$sb.Append("HKLM\Run,E$i,c:\a$i.exe`r`n") }
        $r = @(ConvertFrom-MorpheusAutorunsCsv -Text $sb.ToString())
        $r.Count | Should Be 5000
        $r[0].Eintrag | Should Be 'E0'
    }
}

Describe 'ConvertFrom-MorpheusSigcheckCsv' {
    It 'System32-Fixture: zwei unsignierte Dateien' {
        $t = ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'sigcheck-system32.csv')
        $r = @(ConvertFrom-MorpheusSigcheckCsv -Text $t)
        $r.Count | Should Be 2
        $r[0].Pfad | Should Be 'c:\windows\system32\oldprint.dll'
        $r[0].Verifiziert | Should Be 'Unsigned'
        $r[0].Signiert | Should Be $false
        $r[0].Firma | Should Be 'Altes Druckerwerk AG'
        $r[0].Beschreibung | Should Be ('Druckertreiber f' + [char]0xFC + 'r alte Modelle')
        $r[0].Version | Should Be '2.0.0.1'
        $r[0].Typ | Should Be '64-bit'
    }
    It 'Treiber-Fixture: eine Datei' {
        $t = ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'sigcheck-drivers.csv')
        $r = @(ConvertFrom-MorpheusSigcheckCsv -Text $t)
        $r.Count | Should Be 1
        $r[0].Pfad | Should Be 'c:\windows\system32\drivers\oldfilter.sys'
    }
    It 'nur Kopfzeile: leeres Array' {
        $t = ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'sigcheck-leer.csv')
        @(ConvertFrom-MorpheusSigcheckCsv -Text $t).Count | Should Be 0
    }
    It 'ohne Kopfzeile: leeres Array' {
        @(ConvertFrom-MorpheusSigcheckCsv -Text "Fehler: nichts`r`n").Count | Should Be 0
    }
    It 'Signed wird als signiert erkannt, Meldungen vor der Kopfzeile stoeren nicht' {
        $t = "Hinweis`r`n`"Path`",`"Verified`"`r`n`"c:\a.dll`",`"Signed`"`r`n"
        $r = @(ConvertFrom-MorpheusSigcheckCsv -Text $t)
        $r.Count | Should Be 1
        $r[0].Signiert | Should Be $true
        $r[0].Firma | Should Be ''
    }
}

Describe 'Test-MorpheusAutorunsErhoeht' {
    It 'erhoehte Kategorien (ohne Leerzeichen, ohne Gross-/Kleinschreibung)' {
        foreach ($k in 'Services', 'Drivers', 'Winlogon', 'Boot Execute', 'LSA Providers', 'Print Monitors', 'Known DLLs', 'Winsock Providers', 'Network Providers', 'WMI', 'Image Hijacks', 'AppInit') {
            Test-MorpheusAutorunsErhoeht -Eintrag (New-Aut -Kategorie $k) | Should Be $true
        }
    }
    It 'Aufgaben (Tasks / Scheduled Tasks) sind ohne -Aufgaben nicht erhoeht' {
        foreach ($k in 'Tasks', 'Scheduled Tasks', 'scheduledtasks') {
            Test-MorpheusAutorunsErhoeht -Eintrag (New-Aut -Eintrag '\V\U' -Kategorie $k) | Should Be $false
        }
    }
    It 'Aufgaben: Wert aus -Aufgaben, Schluessel normalisiert (Trim, klein, fuehrender Backslash)' {
        $a = @{ '\vendor\update' = $true; '\vendor\ruhig' = $false }
        Test-MorpheusAutorunsErhoeht -Eintrag (New-Aut -Eintrag '\Vendor\Update' -Kategorie 'Tasks') -Aufgaben $a | Should Be $true
        Test-MorpheusAutorunsErhoeht -Eintrag (New-Aut -Eintrag '  Vendor\UPDATE ' -Kategorie 'Scheduled Tasks') -Aufgaben $a | Should Be $true
        Test-MorpheusAutorunsErhoeht -Eintrag (New-Aut -Eintrag '\Vendor\Ruhig' -Kategorie 'Tasks') -Aufgaben $a | Should Be $false
        Test-MorpheusAutorunsErhoeht -Eintrag (New-Aut -Eintrag '\Andere' -Kategorie 'Tasks') -Aufgaben $a | Should Be $false
        Test-MorpheusAutorunsErhoeht -Eintrag (New-Aut -Eintrag '\Vendor\Update' -Kategorie 'Logon') -Aufgaben $a | Should Be $false
    }
    It 'Benutzer-Ebene ist nicht erhoeht' {
        foreach ($k in 'Logon', 'Explorer', 'Internet Explorer', '') {
            Test-MorpheusAutorunsErhoeht -Eintrag (New-Aut -Kategorie $k) | Should Be $false
        }
    }
}

Describe 'Test-MorpheusSysKopf' {
    It 'echte Fixtures haben eine Kopfzeile' {
        Test-MorpheusSysKopf -Text (ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'autorunsc.csv')) -Art autoruns | Should Be $true
        Test-MorpheusSysKopf -Text (ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'sigcheck-system32.csv')) -Art sigcheck | Should Be $true
        Test-MorpheusSysKopf -Text (ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'sigcheck-leer.csv')) -Art sigcheck | Should Be $true
    }
    It 'Fixture ohne Kopf ergibt false' {
        Test-MorpheusSysKopf -Text (ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'autorunsc-ohne-kopf.txt')) -Art autoruns | Should Be $false
        Test-MorpheusSysKopf -Text "Fehler: nichts`r`n" -Art sigcheck | Should Be $false
    }
    It 'leerer Text ergibt false' {
        Test-MorpheusSysKopf -Text '' -Art autoruns | Should Be $false
        Test-MorpheusSysKopf -Text $null -Art sigcheck | Should Be $false
    }
    It 'Art wird beachtet' {
        Test-MorpheusSysKopf -Text (ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'autorunsc.csv')) -Art sigcheck | Should Be $false
    }
}

Describe 'MorpheusSysAwRegelSchreibt (Datei- und Elternmaske)' {
    It 'Dateien anlegen (0x2) genuegt fuer die Datei, nicht fuer den Elternordner' {
        MorpheusSysAwRegelSchreibt -Rechte 0x2 -Maske $script:MorpheusSysAwSchreibMaske | Should Be $true
        MorpheusSysAwRegelSchreibt -Rechte 0x2 -Maske $script:MorpheusSysAwElternMaske | Should Be $false
        MorpheusSysAwRegelSchreibt -Rechte 0x4 -Maske $script:MorpheusSysAwElternMaske | Should Be $false
    }
    It 'Austauschen/Loeschen zaehlt im Elternordner' {
        foreach ($r in 0x40, 0x10000, 0x40000, 0x80000, 0x10000000) {
            MorpheusSysAwRegelSchreibt -Rechte $r -Maske $script:MorpheusSysAwElternMaske | Should Be $true
        }
    }
    It 'reine Leserechte zaehlen nie' {
        MorpheusSysAwRegelSchreibt -Rechte (0x1 -bor 0x20 -bor 0x20000 -bor 0x100000) -Maske $script:MorpheusSysAwSchreibMaske | Should Be $false
    }
}

Describe 'Test-MorpheusPfadBenutzerBeschreibbar' {
    It 'eigene Datei unter $TestDrive ist beschreibbar' {
        $p = Join-Path $TestDrive 'eigene.exe'
        [IO.File]::WriteAllText($p, 'x')
        Test-MorpheusPfadBenutzerBeschreibbar -Pfad $p | Should Be $true
    }
    It 'Pfad in Anfuehrungszeichen wird akzeptiert' {
        $p = Join-Path $TestDrive 'quote.exe'
        [IO.File]::WriteAllText($p, 'x')
        Test-MorpheusPfadBenutzerBeschreibbar -Pfad ('"' + $p + '"') | Should Be $true
    }
    It 'notepad.exe in System32 ist nicht beschreibbar' {
        $p = Join-Path $env:SystemRoot 'System32\notepad.exe'
        Test-MorpheusPfadBenutzerBeschreibbar -Pfad $p | Should Be $false
    }
    It 'Umgebungsvariablen werden expandiert' {
        Test-MorpheusPfadBenutzerBeschreibbar -Pfad '%SystemRoot%\System32\notepad.exe' | Should Be $false
    }
    It 'fehlende Datei ergibt $null' {
        ($null -eq (Test-MorpheusPfadBenutzerBeschreibbar -Pfad (Join-Path $TestDrive 'gibt-es-nicht.exe'))) | Should Be $true
        ($null -eq (Test-MorpheusPfadBenutzerBeschreibbar -Pfad '')) | Should Be $true
    }
}

Describe 'Get-MorpheusAutorunsSignaturBefund' {
    It 'OK ohne unsignierte aktive Eintraege' {
        $e = @(
            (New-Aut -Verifiziert $true -Signierer '(Verified) X'),
            (New-Aut -Eintrag 'Aus' -Aktiv $false),
            (New-Aut -Eintrag 'Weg' -DateiFehlt $true)
        )
        $b = Get-MorpheusAutorunsSignaturBefund -Eintraege $e
        $b.status | Should Be 'OK'
        @($b.liste).Count | Should Be 0
    }
    It 'INFO nur mit Benutzer-Ebene' {
        $b = Get-MorpheusAutorunsSignaturBefund -Eintraege @((New-Aut -Eintrag 'Tool' -Kategorie 'Logon'))
        $b.status | Should Be 'INFO'
        $b.wert | Should Match 'Tool'
        @($b.liste).Count | Should Be 1
    }
    It 'WARN mit systemnahem Eintrag (Winlogon), Namen in wert' {
        $e = @((New-Aut -Eintrag 'Shell1' -Kategorie 'Winlogon'), (New-Aut -Eintrag 'App' -Kategorie 'Logon'))
        $b = Get-MorpheusAutorunsSignaturBefund -Eintraege $e
        $b.status | Should Be 'WARN'
        $b.wert | Should Match 'Systemnahe Autostarts ohne verifizierte Signatur \(1\): Shell1'
        $b.wert | Should Match 'weitere Autostarts \(1\): App'
        $b.empfehlung | Should Match 'Herkunft der Eintr'
        @($b.liste).Count | Should Be 2
        $b.liste[0].Erhoeht | Should Be $true
    }
    It 'hoechstens 5 Namen je Gruppe, dann Auslassung' {
        $e = @(1..8 | ForEach-Object { New-Aut -Eintrag "S$_" -Kategorie 'Winlogon' })
        $b = Get-MorpheusAutorunsSignaturBefund -Eintraege $e
        $b.wert | Should Match 'S5'
        $b.wert | Should Not Match 'S6'
        $b.wert.Contains([string][char]0x2026) | Should Be $true
        @($b.liste).Count | Should Be 8
    }
    It 'Dienste und Treiber fuehren nie zu WARN, sondern eigene Gruppe mit INFO' {
        $e = @((New-Aut -Eintrag 'A' -Kategorie 'Services'), (New-Aut -Eintrag 'B' -Kategorie 'Drivers'), (New-Aut -Eintrag 'C' -Kategorie 'Logon'))
        $b = Get-MorpheusAutorunsSignaturBefund -Eintraege $e
        $b.status | Should Be 'INFO'
        $b.wert | Should Match 'Dienste und Treiber \(bereits eigene Pr.fungen\) \(2\): A, B'
        $b.wert | Should Match 'weitere Autostarts \(1\): C'
        @($b.liste).Count | Should Be 3
    }
    It 'Aufgaben als SYSTEM (per -Aufgaben) sind systemnah und ergeben WARN; ohne -Aufgaben INFO' {
        $e = @((New-Aut -Eintrag '\V\U' -Kategorie 'Tasks'))
        (Get-MorpheusAutorunsSignaturBefund -Eintraege $e).status | Should Be 'INFO'
        (Get-MorpheusAutorunsSignaturBefund -Eintraege $e -Aufgaben @{ '\v\u' = $true }).status | Should Be 'WARN'
    }
    It 'Eintraege ohne Pfad zaehlen nicht als unsigniert' {
        $b = Get-MorpheusAutorunsSignaturBefund -Eintraege @((New-Aut -Eintrag 'Leer' -Kategorie 'Winlogon' -Pfad ''))
        $b.status | Should Be 'OK'
    }
    It 'Fixture: INFO (VendorSvc ist Dienst, Aufgabe ohne -Aufgaben nicht erhoeht)' {
        $e = @(ConvertFrom-MorpheusAutorunsCsv -Text (ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'autorunsc.csv')))
        $b = Get-MorpheusAutorunsSignaturBefund -Eintraege $e
        $b.status | Should Be 'INFO'
        $b.wert | Should Match 'Dienste und Treiber'
        $b.wert | Should Match 'VendorSvc'
        $b.wert | Should Match 'DemoTool'
        $b.wert | Should Not Match 'OldUpdater'
        $b.wert | Should Not Match 'GoneApp'
    }
    It 'leere Eingabe ist OK; Eingabe wird nicht veraendert' {
        (Get-MorpheusAutorunsSignaturBefund -Eintraege @()).status | Should Be 'OK'
        (Get-MorpheusAutorunsSignaturBefund -Eintraege $null).status | Should Be 'OK'
        $x = New-Aut -Kategorie 'Winlogon'
        $null = Get-MorpheusAutorunsSignaturBefund -Eintraege @($x)
        ($null -eq $x.PSObject.Properties['Erhoeht']) | Should Be $true
    }
}

Describe 'Get-MorpheusAutorunsPfadBefund' {
    It 'OK, wenn nichts beschreibbar ist' {
        $b = Get-MorpheusAutorunsPfadBefund -Eintraege @((New-Aut)) -Beschreibbar { param($p) $false }
        $b.status | Should Be 'OK'
    }
    It 'INFO bei Benutzer-Ebene; Eigenschaften Beschreibbar und Erhoeht in der Liste' {
        $x = New-Aut -Eintrag 'App' -Kategorie 'Logon'
        $b = Get-MorpheusAutorunsPfadBefund -Eintraege @($x) -Beschreibbar { param($p) $true }
        $b.status | Should Be 'INFO'
        $b.liste[0].Beschreibbar | Should Be $true
        $b.liste[0].Erhoeht | Should Be $false
        ($null -eq $x.PSObject.Properties['Beschreibbar']) | Should Be $true
    }
    It 'Dienste und Treiber ergeben hoechstens INFO (eigene Gruppe)' {
        $b = Get-MorpheusAutorunsPfadBefund -Eintraege @((New-Aut -Eintrag 'Svc' -Kategorie 'Services')) -Beschreibbar { param($p) $true }
        $b.status | Should Be 'INFO'
        $b.wert | Should Match 'Dienste und Treiber \(bereits eigene Pr.fungen\) \(1\): Svc'
        $b.liste[0].Erhoeht | Should Be $true
    }
    It 'Aufgabe mit hoechsten Rechten (per -Aufgaben) ergibt WARN in der Gruppe Systemnahe Autostarts und Aufgaben' {
        $e = @((New-Aut -Eintrag '\V\U' -Kategorie 'Tasks'))
        (Get-MorpheusAutorunsPfadBefund -Eintraege $e -Beschreibbar { param($p) $true }).status | Should Be 'INFO'
        $b = Get-MorpheusAutorunsPfadBefund -Eintraege $e -Beschreibbar { param($p) $true } -Aufgaben @{ '\v\u' = $true }
        $b.status | Should Be 'WARN'
        $b.wert | Should Match 'Systemnahe Autostarts und Aufgaben mit erh.hten Rechten \(1\)'
    }
    It 'WARN bei systemnahem Eintrag mit konkreter Empfehlung' {
        $b = Get-MorpheusAutorunsPfadBefund -Eintraege @((New-Aut -Eintrag 'Svc' -Kategorie 'Winlogon')) -Beschreibbar { param($p) $true }
        $b.status | Should Be 'WARN'
        $b.empfehlung | Should Match 'Programmordner pr'
        $b.empfehlung | Should Match 'Program Files'
        $b.liste[0].Erhoeht | Should Be $true
    }
    It 'inaktive, fehlende und unbekannte ($null) Pfade zaehlen nicht' {
        $e = @((New-Aut -Aktiv $false), (New-Aut -DateiFehlt $true), (New-Aut -Pfad 'C:\unbekannt.exe'))
        $b = Get-MorpheusAutorunsPfadBefund -Eintraege $e -Beschreibbar { param($p) if ($p -like '*unbekannt*') { $null } else { $true } }
        $b.status | Should Be 'OK'
    }
    It 'Ergebnis wird je Pfad gecacht' {
        $script:Zaehler = 0
        $e = @((New-Aut -Eintrag 'A' -Pfad 'C:\Apps\gleich.exe'), (New-Aut -Eintrag 'B' -Pfad 'C:\Apps\gleich.exe'), (New-Aut -Eintrag 'C' -Pfad 'C:\APPS\GLEICH.EXE'))
        $b = Get-MorpheusAutorunsPfadBefund -Eintraege $e -Beschreibbar { param($p) $script:Zaehler++; $true }
        $script:Zaehler | Should Be 1
        @($b.liste).Count | Should Be 3
    }
    It 'Standard-Pruefung: eigene Datei in $TestDrive loest INFO aus' {
        $p = Join-Path $TestDrive 'auto.exe'
        [IO.File]::WriteAllText($p, 'x')
        $b = Get-MorpheusAutorunsPfadBefund -Eintraege @((New-Aut -Pfad $p))
        $b.status | Should Be 'INFO'
    }
}

Describe 'Get-MorpheusSystemdateienBefund' {
    It 'OK ohne unsignierte Dateien' {
        (Get-MorpheusSystemdateienBefund -System32 @() -Treiber @()).status | Should Be 'OK'
        (Get-MorpheusSystemdateienBefund -System32 $null -Treiber $null).status | Should Be 'OK'
        (Get-MorpheusSystemdateienBefund -System32 @((New-Sig 'c:\a.dll' $true)) -Treiber @()).status | Should Be 'OK'
    }
    It 'WARN mit Anzahl und Dateinamen' {
        $s = @(ConvertFrom-MorpheusSigcheckCsv -Text (ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'sigcheck-system32.csv')))
        $d = @(ConvertFrom-MorpheusSigcheckCsv -Text (ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'sigcheck-drivers.csv')))
        $b = Get-MorpheusSystemdateienBefund -System32 $s -Treiber $d
        $b.status | Should Be 'WARN'
        $b.wert | Should Match '^3 unsignierte Dateien'
        $b.wert | Should Match 'oldprint.dll'
        $b.wert | Should Match 'oldfilter.sys'
        $b.empfehlung | Should Match 'Dateien pr'
        @($b.liste).Count | Should Be 3
        $b.liste[2].Ordner | Should Be 'drivers'
    }
    It 'hoechstens 5 Dateinamen' {
        $s = @(1..7 | ForEach-Object { New-Sig "c:\windows\system32\f$_.dll" })
        $b = Get-MorpheusSystemdateienBefund -System32 $s -Treiber @()
        $b.wert | Should Match 'f5.dll'
        $b.wert | Should Not Match 'f6.dll'
        $b.wert.Contains([string][char]0x2026) | Should Be $true
    }
}

Describe 'Tabellenfunktionen' {
    $e = @(ConvertFrom-MorpheusAutorunsCsv -Text (ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'autorunsc.csv')))
    It 'Autoruns-Tabelle ohne verifizierte Microsoft-Eintraege, mit genau den Spalten' {
        $t = @(Get-MorpheusAutorunsTabelle -Eintraege $e -Beschreibbar { param($p) $false })
        $t.Count | Should Be 5
        ($t | Where-Object { $_.Eintrag -eq 'Spooler' }) | Should BeNullOrEmpty
        ($t | Where-Object { $_.Eintrag -eq 'SecurityHealth' }) | Should BeNullOrEmpty
        ($t | Where-Object { $_.Eintrag -eq 'VendorSvc' }).Erhoeht | Should Be $true
        ($t | Where-Object { $_.Eintrag -eq '\Vendor\Update' }) | Should Not BeNullOrEmpty
        (@($t[0].PSObject.Properties.Name) -join ',') | Should Be 'Kategorie,Eintrag,Aktiv,Signierer,Verifiziert,Beschreibbar,Erhoeht,Pfad,Ort,Befehl'
    }
    It 'Microsoft-Filter: nur Verified Microsoft Windows/Corporation/Windows Publisher, nicht WHQL-Herausgeber' {
        $x = @(
            (New-Aut -Eintrag 'MsOk' -Verifiziert $true -Signierer '(Verified) Microsoft Windows'),
            (New-Aut -Eintrag 'MsCorp' -Verifiziert $true -Signierer '(Verified) Microsoft Corporation'),
            (New-Aut -Eintrag 'MsPub' -Verifiziert $true -Signierer '(Verified) Microsoft Windows Publisher'),
            (New-Aut -Eintrag 'Whql' -Verifiziert $true -Signierer '(Verified) Microsoft Windows Hardware Compatibility Publisher'),
            (New-Aut -Eintrag 'Unverif' -Verifiziert $false -Signierer 'Microsoft Windows')
        )
        $t = @(Get-MorpheusAutorunsTabelle -Eintraege $x -Beschreibbar { param($p) $false })
        (@($t | ForEach-Object { $_.Eintrag }) -join ',') | Should Be 'Whql,Unverif'
    }
    It 'Tabelle: Erhoeht fuer Aufgaben nur per -Aufgaben' {
        $t = @(Get-MorpheusAutorunsTabelle -Eintraege $e -Beschreibbar { param($p) $false })
        ($t | Where-Object { $_.Eintrag -eq '\Vendor\Update' }).Erhoeht | Should Be $false
        $t = @(Get-MorpheusAutorunsTabelle -Eintraege $e -Beschreibbar { param($p) $false } -Aufgaben @{ '\vendor\update' = $true })
        ($t | Where-Object { $_.Eintrag -eq '\Vendor\Update' }).Erhoeht | Should Be $true
    }
    It 'Beschreibbar-Wert kommt aus dem Scriptblock; fehlende Datei bleibt $null' {
        $t = @(Get-MorpheusAutorunsTabelle -Eintraege $e -Beschreibbar { param($p) $true })
        ($t | Where-Object { $_.Eintrag -eq 'DemoTool' }).Beschreibbar | Should Be $true
        ($null -eq ($t | Where-Object { $_.Eintrag -eq 'GoneApp' }).Beschreibbar) | Should Be $true
    }
    It 'Autoruns-Tabelle ist auch bei einer Zeile ein Array' {
        $t = @(Get-MorpheusAutorunsTabelle -Eintraege @((New-Aut)) -Beschreibbar { param($p) $false })
        $t.Count | Should Be 1
        @(Get-MorpheusAutorunsTabelle -Eintraege @() ).Count | Should Be 0
    }
    It 'Sigcheck-Tabelle: Spalten und Ordner' {
        $s = @(ConvertFrom-MorpheusSigcheckCsv -Text (ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'sigcheck-system32.csv')))
        $d = @(ConvertFrom-MorpheusSigcheckCsv -Text (ConvertFrom-MorpheusSysAusgabe -Bytes (Get-Fix 'sigcheck-drivers.csv')))
        $t = @(Get-MorpheusSigcheckTabelle -System32 $s -Treiber $d)
        $t.Count | Should Be 3
        $t[0].Ordner | Should Be 'System32'
        $t[0].Datei | Should Be 'oldprint.dll'
        $t[2].Ordner | Should Be 'drivers'
        $t[2].Datei | Should Be 'oldfilter.sys'
        (@($t[0].PSObject.Properties.Name) -join ',') | Should Be 'Ordner,Datei,Firma,Beschreibung,Version,Datum,Pfad'
    }
    It 'Sigcheck-Tabelle enthaelt keine signierten Dateien' {
        @(Get-MorpheusSigcheckTabelle -System32 @((New-Sig 'c:\a.dll' $true)) -Treiber @()).Count | Should Be 0
    }
}
