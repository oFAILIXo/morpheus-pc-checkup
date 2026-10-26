#Requires -Version 5.1
# Pester 3.4 - Akzeptanzliste (docs/gui-architektur.md, Abschnitt 16.1)

$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'gui\lib\Akzeptanz.ps1')

$script:Sha = ('a' * 64)
$script:Sha2 = ('b' * 64)

function NeueDatei {
    param([string]$Name = 'accepted.psd1')
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    Join-Path $d $Name
}

function SchreibePsd1 {
    param([string]$Pfad, [string]$Text)
    [IO.File]::WriteAllText($Pfad, $Text, (New-Object System.Text.UTF8Encoding($true)))
}

function Gut {
    param([hashtable]$Aenderung = @{})
    $r = @{ Check = 'BitLocker'; Match = '^x$'; Reason = 'Bewusst so gewollt' }
    foreach ($k in $Aenderung.Keys) { $r[$k] = $Aenderung[$k] }
    $r
}

Describe 'Dot-Source' {
    It 'definiert nur Funktionen und hat BOM' {
        $b = [IO.File]::ReadAllBytes((Join-Path $script:Root 'gui\lib\Akzeptanz.ps1'))
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
        (Get-Command Read-MorpheusAkzeptanz).CommandType | Should Be 'Function'
    }
}

Describe 'Read-MorpheusAkzeptanz' {
    It 'fehlende Datei ergibt leere Liste' {
        @(Read-MorpheusAkzeptanz -Datei (NeueDatei)).Count | Should Be 0
    }
    It 'leere Accepted-Liste ergibt leere Liste' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @() }"
        @(Read-MorpheusAkzeptanz -Datei $f).Count | Should Be 0
    }
    It 'fehlendes Accepted ergibt leere Liste' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ }"
        @(Read-MorpheusAkzeptanz -Datei $f).Count | Should Be 0
    }
    It 'unlesbare Datei wirft' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @( "
        { Read-MorpheusAkzeptanz -Datei $f } | Should Throw
    }
    It 'Handregel ohne Id bekommt stabile h-Id' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @( @{ Check = 'A'; Match = '^b$'; Reason = 'Grund' } ) }"
        $a = @(Read-MorpheusAkzeptanz -Datei $f)
        $b = @(Read-MorpheusAkzeptanz -Datei $f)
        $a.Count | Should Be 1
        $a[0].id | Should Match '^h[0-9a-f]{11}$'
        $a[0].id | Should Be $b[0].id
        $a[0].quelle | Should Be 'hand'
        $a[0].abgelaufen | Should Be $false
    }
    It 'Felder in beliebiger Schreibweise, Id macht quelle gui' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ accepted = @( @{ id = '0123abcd'; CHECK = 'A'; match = 'm'; reason = 'Grund'; until = '2999-01-01'; datei = 'C:\x.dll'; sha256 = '$($script:Sha)'; erstellt = '2026-10-26T10:00:00' } ) }"
        $r = @(Read-MorpheusAkzeptanz -Datei $f)[0]
        $r.id | Should Be '0123abcd'
        $r.quelle | Should Be 'gui'
        $r.check | Should Be 'A'
        $r.datei | Should Be 'C:\x.dll'
        $r.sha256 | Should Be $script:Sha
        $r.erstellt | Should Be '2026-10-26T10:00:00'
    }
    It 'abgelaufen: Until vor heute ja, heute und spaeter nein' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @( @{ Check='A'; Reason='r1'; Until='2020-01-01' }, @{ Check='B'; Reason='r2'; Until='2026-10-26' }, @{ Check='C'; Reason='r3' } ) }"
        $r = @(Read-MorpheusAkzeptanz -Datei $f -Heute ([datetime]'2026-10-26'))
        $r[0].abgelaufen | Should Be $true
        $r[1].abgelaufen | Should Be $false
        $r[2].abgelaufen | Should Be $false
    }
}

Describe 'ConvertTo-MorpheusAkzeptanzPsd1 Rundreise' {
    It 'Sonderzeichen kommen unveraendert zurueck' {
        $sonder = @(
            "it's", 'sag "hallo"', '$(Remove-Item C:\x)', 'back`tick', 'a;b', '@{', '}', 'Umlaute äöüß', 'a|b', 'x*y', '[abc]', '# kein Kommentar'
        )
        $regeln = @()
        $i = 0
        foreach ($s in $sonder) {
            $i++
            $regeln += [ordered]@{ Id = ('{0:x8}' -f $i); Check = "C$i $s"; Match = "^$s$"; Reason = "R $s"; Until = '2999-12-31' }
        }
        $f = NeueDatei
        SchreibePsd1 $f (ConvertTo-MorpheusAkzeptanzPsd1 -Regeln $regeln)
        $roh = (Import-PowerShellDataFile -LiteralPath $f).Accepted
        @($roh).Count | Should Be $sonder.Count
        for ($k = 0; $k -lt $sonder.Count; $k++) {
            $roh[$k].Check | Should BeExactly $regeln[$k].Check
            $roh[$k].Match | Should BeExactly $regeln[$k].Match
            $roh[$k].Reason | Should BeExactly $regeln[$k].Reason
            $roh[$k].Id | Should BeExactly $regeln[$k].Id
        }
    }
    It 'Feldreihenfolge fest, leere Felder fehlen' {
        $t = ConvertTo-MorpheusAkzeptanzPsd1 -Regeln @(@{ Reason = 'RR'; Check = 'CC'; Id = '0000000a'; Match = '' })
        $t | Should Match "@\{ Id = '0000000a'; Check = 'CC'; Reason = 'RR' \}"
        $t | Should Not Match 'Match ='
    }
    It 'h-Ids werden nicht geschrieben, Reihenfolge der Regeln bleibt' {
        $t = ConvertTo-MorpheusAkzeptanzPsd1 -Regeln @(@{ Id = 'h0123456789a'; Check = 'Z'; Reason = 'rrr' }, @{ Id = 'abcdef01'; Check = 'A'; Reason = 'rrr' })
        $t | Should Not Match 'h0123456789a'
        $t.IndexOf("Check = 'Z'") | Should BeLessThan $t.IndexOf("Check = 'A'")
    }
    It 'leere Liste ergibt gueltige Datei' {
        $f = NeueDatei
        SchreibePsd1 $f (ConvertTo-MorpheusAkzeptanzPsd1 -Regeln @())
        @((Import-PowerShellDataFile -LiteralPath $f).Accepted).Count | Should Be 0
    }
    It 'Steuerzeichen in einem Wert werfen' {
        foreach ($c in @("a`nb", "a`rb", "a`tb", "a$([char]0)b", "a$([char]0x7F)b")) {
            { ConvertTo-MorpheusAkzeptanzPsd1 -Regeln @(@{ Check = 'X'; Reason = $c }) } | Should Throw
        }
    }
    It 'boesartiger Begruendungstext kommt nur als Text an' {
        $boese = "'); Remove-Item C:\x; ('"
        $f = NeueDatei
        SchreibePsd1 $f (ConvertTo-MorpheusAkzeptanzPsd1 -Regeln @(@{ Id = '00000001'; Check = 'X'; Reason = $boese }))
        $r = @(Read-MorpheusAkzeptanz -Datei $f)
        $r.Count | Should Be 1
        $r[0].reason | Should BeExactly $boese
    }
}

Describe 'Add-MorpheusAkzeptanz Pruefregeln' {
    $heute = [datetime]'2026-10-26'
    function Versuch { param([hashtable]$A) Add-MorpheusAkzeptanz -Datei (NeueDatei) -Regel (Gut $A) -Heute ([datetime]'2026-10-26') }

    It 'gueltige Regel geht durch' { { Versuch @{} } | Should Not Throw }
    It 'Check 1 bis 200' {
        { Versuch @{ Check = '' } } | Should Throw
        { Versuch @{ Check = ('c' * 200) } } | Should Not Throw
        { Versuch @{ Check = ('c' * 201) } } | Should Throw
        { Versuch @{ Check = 'c' } } | Should Not Throw
    }
    It 'Reason 3 bis 300' {
        { Versuch @{ Reason = 'ab' } } | Should Throw
        { Versuch @{ Reason = 'abc' } } | Should Not Throw
        { Versuch @{ Reason = ('r' * 300) } } | Should Not Throw
        { Versuch @{ Reason = ('r' * 301) } } | Should Throw
    }
    It 'Until Format, Datum, Grenzen' {
        { Versuch @{ Until = '26.10.2027' } } | Should Throw
        { Versuch @{ Until = '2027-02-30' } } | Should Throw
        { Versuch @{ Until = '2026-10-25' } } | Should Throw
        { Versuch @{ Until = '2026-10-26' } } | Should Not Throw
        { Versuch @{ Until = '2031-10-26' } } | Should Not Throw
        { Versuch @{ Until = '2031-10-27' } } | Should Throw
        { Versuch @{ Until = '' } } | Should Not Throw
    }
    It 'Match bis 2000 und gueltiger Regex' {
        { Versuch @{ Match = ('m' * 2000) } } | Should Not Throw
        { Versuch @{ Match = ('m' * 2001) } } | Should Throw
        { Versuch @{ Match = '(' } } | Should Throw
        { Versuch @{ Match = '' } } | Should Not Throw
    }
    It 'Datei nur zusammen mit Sha256' {
        { Versuch @{ Datei = 'C:\Windows\System32\a.dll' } } | Should Throw
        { Versuch @{ Sha256 = $script:Sha } } | Should Throw
        { Versuch @{ Datei = 'C:\Windows\System32\a.dll'; Sha256 = $script:Sha } } | Should Not Throw
    }
    It 'Sha256 genau 64 Hex klein' {
        $d = 'C:\a.dll'
        { Versuch @{ Datei = $d; Sha256 = ('a' * 63) } } | Should Throw
        { Versuch @{ Datei = $d; Sha256 = ('a' * 65) } } | Should Throw
        { Versuch @{ Datei = $d; Sha256 = ('A' * 64) } } | Should Throw
        { Versuch @{ Datei = $d; Sha256 = ('g' * 64) } } | Should Throw
    }
    It 'Pfad: Laufwerk und Laenge 260' {
        { Versuch @{ Datei = 'relativ\a.dll'; Sha256 = $script:Sha } } | Should Throw
        { Versuch @{ Datei = '\\server\share\a.dll'; Sha256 = $script:Sha } } | Should Throw
        { Versuch @{ Datei = ('C:\' + ('p' * 257)); Sha256 = $script:Sha } } | Should Not Throw
        { Versuch @{ Datei = ('C:\' + ('p' * 258)); Sha256 = $script:Sha } } | Should Throw
    }
    It 'Steuerzeichen in jedem Feld werfen' {
        { Versuch @{ Check = "a`nb" } } | Should Throw
        { Versuch @{ Match = "a`tb" } } | Should Throw
        { Versuch @{ Reason = "abc`r" } } | Should Throw
        { Versuch @{ Datei = "C:\a`nb"; Sha256 = $script:Sha } } | Should Throw
    }
    It 'Fehlermeldungen sind deutsch' {
        $m = ''
        try { Versuch @{ Reason = 'a' } } catch { $m = $_.Exception.Message }
        $m | Should Match 'Begruendung'
    }
    It 'mehr als 500 Regeln werden abgelehnt' {
        $f = NeueDatei
        $regeln = 1..500 | ForEach-Object { @{ Id = ('{0:x8}' -f $_); Check = "C$_"; Reason = 'rrr' } }
        SchreibePsd1 $f (ConvertTo-MorpheusAkzeptanzPsd1 -Regeln $regeln)
        { Add-MorpheusAkzeptanz -Datei $f -Regel (Gut) } | Should Throw
        $regeln2 = $regeln[0..498]
        SchreibePsd1 $f (ConvertTo-MorpheusAkzeptanzPsd1 -Regeln $regeln2)
        { Add-MorpheusAkzeptanz -Datei $f -Regel (Gut) } | Should Not Throw
        @(Read-MorpheusAkzeptanz -Datei $f).Count | Should Be 500
    }
}

Describe 'Add-MorpheusAkzeptanz Schreiben' {
    It 'vergibt Id und Erstellt, Datei ist UTF-8 mit BOM' {
        $f = NeueDatei
        $n = Add-MorpheusAkzeptanz -Datei $f -Regel (Gut @{ Reason = 'Umlaut äö' })
        $n.id | Should Match '^[0-9a-f]{8}$'
        $n.erstellt | Should Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
        $n.quelle | Should Be 'gui'
        $b = [IO.File]::ReadAllBytes($f)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
        @(Read-MorpheusAkzeptanz -Datei $f)[0].reason | Should BeExactly 'Umlaut äö'
        (Test-Path -LiteralPath ($f + '.tmp')) | Should Be $false
    }
    It 'Ids sind eindeutig' {
        $f = NeueDatei
        1..20 | ForEach-Object { [void](Add-MorpheusAkzeptanz -Datei $f -Regel (Gut @{ Check = "C$_" })) }
        $ids = @(Read-MorpheusAkzeptanz -Datei $f | ForEach-Object { $_.id })
        $ids.Count | Should Be 20
        @($ids | Select-Object -Unique).Count | Should Be 20
    }
    It 'erhaelt Handregeln (ohne Id) und Reihenfolge' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @( @{ Check='Hand'; Match='^h$'; Reason='von Hand'; Until='2999-01-01' } ) }"
        $vorher = @(Read-MorpheusAkzeptanz -Datei $f)[0].id
        [void](Add-MorpheusAkzeptanz -Datei $f -Regel (Gut))
        $r = @(Read-MorpheusAkzeptanz -Datei $f)
        $r.Count | Should Be 2
        $r[0].check | Should Be 'Hand'
        $r[0].id | Should Be $vorher
        $r[0].quelle | Should Be 'hand'
        $r[0].until | Should Be '2999-01-01'
        $r[1].quelle | Should Be 'gui'
    }
    It 'legt .bak mit dem alten Stand an' {
        $f = NeueDatei
        [void](Add-MorpheusAkzeptanz -Datei $f -Regel (Gut @{ Check = 'Erste' }))
        (Test-Path -LiteralPath ($f + '.bak')) | Should Be $false
        [void](Add-MorpheusAkzeptanz -Datei $f -Regel (Gut @{ Check = 'Zweite' }))
        (Test-Path -LiteralPath ($f + '.bak')) | Should Be $true
        @(Read-MorpheusAkzeptanz -Datei ($f + '.bak')).Count | Should Be 1
        @(Read-MorpheusAkzeptanz -Datei $f).Count | Should Be 2
    }
    It 'fehlender Ordner wirft' {
        { Add-MorpheusAkzeptanz -Datei (Join-Path $TestDrive 'gibtsnicht\accepted.psd1') -Regel (Gut) } | Should Throw
    }
    It 'Datei-Regel wird mit Datei und Sha256 gespeichert' {
        $f = NeueDatei
        [void](Add-MorpheusAkzeptanz -Datei $f -Regel (Gut @{ Check = 'Systemdateien: Signaturen (Sigcheck)'; Match = ''; Datei = 'C:\Windows\System32\a.dll'; Sha256 = $script:Sha }))
        $r = @(Read-MorpheusAkzeptanz -Datei $f)[0]
        $r.datei | Should Be 'C:\Windows\System32\a.dll'
        $r.sha256 | Should Be $script:Sha
    }
}

Describe 'Remove-MorpheusAkzeptanz' {
    It 'entfernt genau eine Regel und gibt sie zurueck' {
        $f = NeueDatei
        $a = Add-MorpheusAkzeptanz -Datei $f -Regel (Gut @{ Check = 'A' })
        $b = Add-MorpheusAkzeptanz -Datei $f -Regel (Gut @{ Check = 'B' })
        $x = Remove-MorpheusAkzeptanz -Datei $f -Id $a.id
        $x.check | Should Be 'A'
        $rest = @(Read-MorpheusAkzeptanz -Datei $f)
        $rest.Count | Should Be 1
        $rest[0].id | Should Be $b.id
        (Test-Path -LiteralPath ($f + '.bak')) | Should Be $true
    }
    It 'entfernt Handregel ueber h-Id' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @( @{ Check='Hand'; Reason='von Hand' } ) }"
        $id = @(Read-MorpheusAkzeptanz -Datei $f)[0].id
        [void](Remove-MorpheusAkzeptanz -Datei $f -Id $id)
        @(Read-MorpheusAkzeptanz -Datei $f).Count | Should Be 0
    }
    It 'unbekannte Id wirft und aendert nichts' {
        $f = NeueDatei
        [void](Add-MorpheusAkzeptanz -Datei $f -Regel (Gut))
        { Remove-MorpheusAkzeptanz -Datei $f -Id 'deadbeef' } | Should Throw
        @(Read-MorpheusAkzeptanz -Datei $f).Count | Should Be 1
    }
}

Describe 'Add-MorpheusAkzeptanzHistorie' {
    It 'haengt Eintraege an (UTF-8 ohne BOM)' {
        $f = NeueDatei 'h.json'
        Add-MorpheusAkzeptanzHistorie -Datei $f -Art 'akzeptiert' -Regel @{ id = '1'; check = 'A' } -Benutzer 'PC\demo'
        Add-MorpheusAkzeptanzHistorie -Datei $f -Art 'zurueckgenommen' -Regel @{ id = '1'; check = 'A' } -Benutzer 'PC\demo'
        $b = [IO.File]::ReadAllBytes($f)
        ($b[0] -eq 0xEF) | Should Be $false
        $h = @(ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($f)) | ForEach-Object { $_ })
        $h.Count | Should Be 2
        $h[0].art | Should Be 'akzeptiert'
        $h[1].art | Should Be 'zurueckgenommen'
        $h[0].benutzer | Should Be 'PC\demo'
        $h[0].regel.check | Should Be 'A'
        $h[0].zeit | Should Match '^\d{4}-\d{2}-\d{2}T'
    }
    It 'ein einzelner Eintrag bleibt ein Array' {
        $f = NeueDatei 'h.json'
        Add-MorpheusAkzeptanzHistorie -Datei $f -Art 'akzeptiert' -Regel @{ id = '1' } -Benutzer 'u'
        ([IO.File]::ReadAllText($f)).TrimStart().StartsWith('[') | Should Be $true
    }
    It 'kappt auf 1000, aelteste fallen weg' {
        $f = NeueDatei 'h.json'
        $alt = 1..1000 | ForEach-Object { [ordered]@{ zeit = '2020-01-01T00:00:00'; art = 'akzeptiert'; regel = @{ id = "$_" }; benutzer = 'u' } }
        [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject @($alt) -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        Add-MorpheusAkzeptanzHistorie -Datei $f -Art 'zurueckgenommen' -Regel @{ id = 'neu' } -Benutzer 'u'
        $h = @(ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($f)) | ForEach-Object { $_ })
        $h.Count | Should Be 1000
        $h[0].regel.id | Should Be '2'
        $h[999].regel.id | Should Be 'neu'
    }
    It 'kaputte Datei wird nach .kaputt verschoben und neu begonnen' {
        $f = NeueDatei 'h.json'
        [IO.File]::WriteAllText($f, '{ kaputt [[', (New-Object System.Text.UTF8Encoding($false)))
        Add-MorpheusAkzeptanzHistorie -Datei $f -Art 'akzeptiert' -Regel @{ id = '1' } -Benutzer 'u'
        (Test-Path -LiteralPath ($f + '.kaputt')) | Should Be $true
        @(ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($f)) | ForEach-Object { $_ }).Count | Should Be 1
    }
    It 'ungueltige Art wird abgelehnt' {
        { Add-MorpheusAkzeptanzHistorie -Datei (NeueDatei 'h.json') -Art 'egal' -Regel @{} -Benutzer 'u' } | Should Throw
    }
}

Describe 'Find-MorpheusAkzeptanzDatei' {
    $heute = [datetime]'2026-10-26'
    $regeln = @(
        [pscustomobject]@{ id = '1'; check = 'Systemdateien: Signaturen (Sigcheck)'; datei = 'C:\Windows\System32\a.dll'; sha256 = ('a' * 64); until = '' },
        [pscustomobject]@{ id = '2'; check = 'Systemdateien: Signaturen (Sigcheck)'; datei = 'C:\Windows\System32\alt.dll'; sha256 = ('a' * 64); until = '2020-01-01' },
        [pscustomobject]@{ id = '3'; check = 'Systemdateien: Signaturen (Sigcheck)'; datei = ''; sha256 = ''; until = '' }
    )
    It 'Treffer' {
        (Find-MorpheusAkzeptanzDatei -Regeln $regeln -Pfad 'C:\Windows\System32\a.dll' -Sha256 ('a' * 64) -Heute $heute).id | Should Be '1'
    }
    It 'anderer Hash kein Treffer' {
        Find-MorpheusAkzeptanzDatei -Regeln $regeln -Pfad 'C:\Windows\System32\a.dll' -Sha256 ('b' * 64) -Heute $heute | Should BeNullOrEmpty
    }
    It 'andere Schreibweise des Pfads trifft' {
        (Find-MorpheusAkzeptanzDatei -Regeln $regeln -Pfad 'c:\WINDOWS\system32\A.DLL' -Sha256 (('A') * 64) -Heute $heute).id | Should Be '1'
    }
    It 'abgelaufene Regel trifft nicht' {
        Find-MorpheusAkzeptanzDatei -Regeln $regeln -Pfad 'C:\Windows\System32\alt.dll' -Sha256 ('a' * 64) -Heute $heute | Should BeNullOrEmpty
    }
    It 'heute noch gueltig' {
        $r = @([pscustomobject]@{ id = '9'; check = 'Systemdateien*'; datei = 'C:\a.dll'; sha256 = ('a' * 64); until = '2026-10-26' })
        (Find-MorpheusAkzeptanzDatei -Regeln $r -Pfad 'C:\a.dll' -Sha256 ('a' * 64) -Heute $heute).id | Should Be '9'
    }
    It 'leere Liste ergibt null' {
        Find-MorpheusAkzeptanzDatei -Regeln @() -Pfad 'C:\a.dll' -Sha256 ('a' * 64) | Should BeNullOrEmpty
    }
}

Describe 'Typografische Anfuehrungszeichen (Rundreise)' {
    $typo = @([string][char]0x2019, [string][char]0x2018, [string][char]0x201A, [string][char]0x201B, ([string][char]0x201E + 'x' + [char]0x201C))
    It 'Add/Read/Add/Remove ueberleben alle Zeichen in Reason und Match' {
        $f = NeueDatei
        $ids = @()
        foreach ($t in $typo) {
            $g = Gut @{ Check = "C$t"; Reason = "Grund $t ok $t"; Match = "^a${t}b$" }
            $n = Add-MorpheusAkzeptanz -Datei $f -Regel $g
            $ids += $n.id
            $r = Get-MorpheusAkzeptanzRegel -Datei $f -Id $n.id
            $r.reason | Should BeExactly $g.Reason
            $r.match | Should BeExactly $g.Match
            $r.check | Should BeExactly $g.Check
        }
        @(Read-MorpheusAkzeptanz -Datei $f).Count | Should Be $typo.Count
        [void](Remove-MorpheusAkzeptanz -Datei $f -Id $ids[1])
        $alle = @(Read-MorpheusAkzeptanz -Datei $f)
        $alle.Count | Should Be ($typo.Count - 1)
        $alle[1].reason | Should BeExactly ("Grund $($typo[2]) ok $($typo[2])")
    }
    It 'Probe-Lesen schlaegt fehl: wirft, alte Datei unveraendert, kein .tmp' {
        $f = NeueDatei
        [void](Add-MorpheusAkzeptanz -Datei $f -Regel (Gut @{ Check = 'Alt' }))
        $vorher = [BitConverter]::ToString([IO.File]::ReadAllBytes($f))
        Mock PcCheckAkzEscape { param([string]$Wert) $Wert }
        $m = ''
        try { Add-MorpheusAkzeptanz -Datei $f -Regel (Gut @{ Check = 'Neu'; Reason = ('x' + [char]0x2019 + 'y') }) } catch { $m = $_.Exception.Message }
        $m | Should Match 'sicher schreiben'
        [BitConverter]::ToString([IO.File]::ReadAllBytes($f)) | Should Be $vorher
        (Test-Path -LiteralPath ($f + '.tmp')) | Should Be $false
    }
}

Describe 'Lesen ohne BOM' {
    It 'UTF-8 ohne BOM mit Umlauten' {
        $f = NeueDatei
        [IO.File]::WriteAllText($f, "@{ Accepted = @( @{ Check='Pr$([char]0xFC)fung'; Reason='Gr$([char]0xFC)$([char]0xDF)e'; Match='$([char]0xE4)' } ) }", (New-Object System.Text.UTF8Encoding($false)))
        $r = @(Read-MorpheusAkzeptanz -Datei $f)
        $r[0].check | Should BeExactly "Pr$([char]0xFC)fung"
        $r[0].reason | Should BeExactly "Gr$([char]0xFC)$([char]0xDF)e"
        $r[0].match | Should BeExactly "$([char]0xE4)"
    }
    It 'ANSI-Datei (kein gueltiges UTF-8) wird als ANSI gelesen' {
        $f = NeueDatei
        [IO.File]::WriteAllBytes($f, [Text.Encoding]::Default.GetBytes("@{ Accepted = @( @{ Check='Pr$([char]0xFC)fung'; Reason='Grund' } ) }"))
        @(Read-MorpheusAkzeptanz -Datei $f)[0].check | Should BeExactly "Pr$([char]0xFC)fung"
    }
    It 'Code in der Datei wird nicht ausgefuehrt, sondern ist ein Fehler' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @( @{ Check = (Get-Date); Reason='Grund' } ) }"
        { Read-MorpheusAkzeptanz -Datei $f } | Should Throw
    }
    It 'kein Hashtable wirft' {
        $f = NeueDatei
        SchreibePsd1 $f "'nur Text'"
        { Read-MorpheusAkzeptanz -Datei $f } | Should Throw
    }
}

Describe 'Hand-Regeln beim Umschreiben' {
    It 'Here-String-Reason: Zeilenumbruch wird zu Leerzeichen, Ergaenzen klappt' {
        $f = NeueDatei
        SchreibePsd1 $f ("@{ Accepted = @( @{ Check = 'Hand'; Reason = @'" + "`r`n" + "zeile eins`r`nzeile zwei`r`n" + "'@ } ) }")
        { Add-MorpheusAkzeptanz -Datei $f -Regel (Gut) } | Should Not Throw
        $r = @(Read-MorpheusAkzeptanz -Datei $f)
        $r.Count | Should Be 2
        $r[0].reason | Should Match 'zeile eins\s+zeile zwei'
        $r[0].reason | Should Not Match '[\r\n]'
    }
    It 'neue Regel mit Steuerzeichen bleibt ein Fehler' {
        { Add-MorpheusAkzeptanz -Datei (NeueDatei) -Regel (Gut @{ Reason = "ab`ncd" }) } | Should Throw
    }
    It 'doppelte Hand-Regeln bekommen verschiedene, stabile Ids; Remove entfernt eine' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @( @{ Check='D'; Reason='gleich' }, @{ Check='D'; Reason='gleich' } ) }"
        $a = @(Read-MorpheusAkzeptanz -Datei $f)
        $a.Count | Should Be 2
        $a[0].id | Should Match '^h[0-9a-f]{11}$'
        $a[0].id | Should Not Be $a[1].id
        $b = @(Read-MorpheusAkzeptanz -Datei $f)
        $b[1].id | Should Be $a[1].id
        [void](Remove-MorpheusAkzeptanz -Datei $f -Id $a[1].id)
        $c = @(Read-MorpheusAkzeptanz -Datei $f)
        $c.Count | Should Be 1
        $c[0].id | Should Be $a[0].id
    }
    It 'Id H1234567 und Grossbuchstaben-Hex sind Hand-Regeln, Id bleibt in der Datei' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @( @{ Id='H1234567'; Check='A'; Reason='rrr' }, @{ Id='ABCDEF01'; Check='B'; Reason='rrr' }, @{ Id=''; Check='C'; Reason='rrr' } ) }"
        $r = @(Read-MorpheusAkzeptanz -Datei $f)
        foreach ($x in $r) { $x.quelle | Should Be 'hand'; $x.id | Should Match '^h[0-9a-f]{11}$' }
        [void](Add-MorpheusAkzeptanz -Datei $f -Regel (Gut))
        $roh = (Import-PowerShellDataFile -LiteralPath $f).Accepted
        $roh[0].Id | Should BeExactly 'H1234567'
        $roh[1].Id | Should BeExactly 'ABCDEF01'
        $roh[2].ContainsKey('Id') | Should Be $false
        $roh[3].Id | Should Match '^[0-9a-f]{8}$'
        @(Read-MorpheusAkzeptanz -Datei $f)[3].quelle | Should Be 'gui'
    }
    It 'unbekannte Schluessel bleiben erhalten (als String)' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @( @{ Check='A'; Reason='rrr'; Kommentar = 'it''s mine'; Zahl = 5 } ) }"
        [void](Add-MorpheusAkzeptanz -Datei $f -Regel (Gut))
        $roh = (Import-PowerShellDataFile -LiteralPath $f).Accepted
        $roh[0].Kommentar | Should BeExactly "it's mine"
        $roh[0].Zahl | Should BeExactly '5'
        $roh[0].Check | Should Be 'A'
    }
    It 'Eintraege, die keine Hashtable sind, werden gelesen ignoriert und beim Schreiben verworfen' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @( 'Text', @{ Check='A'; Reason='rrr' } ) }"
        @(Read-MorpheusAkzeptanz -Datei $f).Count | Should Be 1
        [void](Add-MorpheusAkzeptanz -Datei $f -Regel (Gut))
        @((Import-PowerShellDataFile -LiteralPath $f).Accepted).Count | Should Be 2
    }
}

Describe 'Test-MorpheusAkzeptanzRegel' {
    $heute = [datetime]'2026-10-26'
    It 'gueltige Regel ergibt null' {
        Test-MorpheusAkzeptanzRegel -Datei (NeueDatei) -Regel (Gut) -Heute $heute | Should BeNullOrEmpty
    }
    It 'Pruefregel-Fehler ergeben deutschen Text und schreiben nichts' {
        $f = NeueDatei
        Test-MorpheusAkzeptanzRegel -Datei $f -Regel (Gut @{ Reason = 'a' }) -Heute $heute | Should Match 'Begruendung'
        Test-MorpheusAkzeptanzRegel -Datei $f -Regel (Gut @{ Match = '(' }) -Heute $heute | Should Match 'Muster'
        Test-MorpheusAkzeptanzRegel -Datei $f -Regel (Gut @{ Until = '2020-01-01' }) -Heute $heute | Should Match 'Vergangenheit'
        (Test-Path -LiteralPath $f) | Should Be $false
    }
    It 'unlesbare Datei ergibt Text' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @( "
        Test-MorpheusAkzeptanzRegel -Datei $f -Regel (Gut) -Heute $heute | Should Match 'nicht lesbar'
    }
    It 'fehlender Ordner ergibt Text' {
        Test-MorpheusAkzeptanzRegel -Datei (Join-Path $TestDrive 'gibtsnicht\a.psd1') -Regel (Gut) -Heute $heute | Should Match 'Ordner'
    }
    It 'Limit 500 ergibt Text' {
        $f = NeueDatei
        $regeln = 1..500 | ForEach-Object { @{ Id = ('{0:x8}' -f $_); Check = "C$_"; Reason = 'rrr' } }
        SchreibePsd1 $f (ConvertTo-MorpheusAkzeptanzPsd1 -Regeln $regeln)
        Test-MorpheusAkzeptanzRegel -Datei $f -Regel (Gut) -Heute $heute | Should Match 'voll'
    }
    It 'gleichwertige Regel (Check+Match) ist bereits akzeptiert, abgelaufene zaehlt nicht' {
        $f = NeueDatei
        [void](Add-MorpheusAkzeptanz -Datei $f -Regel (Gut) -Heute $heute)
        Test-MorpheusAkzeptanzRegel -Datei $f -Regel (Gut @{ Reason = 'ganz anderer Grund' }) -Heute $heute | Should Be 'Das ist bereits akzeptiert.'
        Test-MorpheusAkzeptanzRegel -Datei $f -Regel (Gut @{ Match = '^y$' }) -Heute $heute | Should BeNullOrEmpty
        { Add-MorpheusAkzeptanz -Datei $f -Regel (Gut) -Heute $heute } | Should Throw 'bereits akzeptiert'
        $g = NeueDatei
        SchreibePsd1 $g "@{ Accepted = @( @{ Check='BitLocker'; Match='^x$'; Reason='alt'; Until='2020-01-01' } ) }"
        Test-MorpheusAkzeptanzRegel -Datei $g -Regel (Gut) -Heute $heute | Should BeNullOrEmpty
    }
    It 'gleichwertige Datei-Regel (Datei ohne Gross/Klein + Sha256)' {
        $f = NeueDatei
        $d = @{ Check = 'Systemdateien: Signaturen (Sigcheck)'; Match = ''; Datei = 'C:\Windows\System32\a.dll'; Sha256 = $script:Sha }
        [void](Add-MorpheusAkzeptanz -Datei $f -Regel (Gut $d) -Heute $heute)
        $gleich = $d.Clone(); $gleich.Datei = 'c:\WINDOWS\system32\A.DLL'
        Test-MorpheusAkzeptanzRegel -Datei $f -Regel (Gut $gleich) -Heute $heute | Should Be 'Das ist bereits akzeptiert.'
        $anders = $d.Clone(); $anders.Sha256 = $script:Sha2
        Test-MorpheusAkzeptanzRegel -Datei $f -Regel (Gut $anders) -Heute $heute | Should BeNullOrEmpty
    }
}

Describe 'Get-MorpheusAkzeptanzRegel' {
    It 'liefert die Regel im Leseformat oder null' {
        $f = NeueDatei
        $n = Add-MorpheusAkzeptanz -Datei $f -Regel (Gut)
        (Get-MorpheusAkzeptanzRegel -Datei $f -Id $n.id).check | Should Be 'BitLocker'
        Get-MorpheusAkzeptanzRegel -Datei $f -Id 'deadbeef' | Should BeNullOrEmpty
        Get-MorpheusAkzeptanzRegel -Datei (NeueDatei) -Id 'deadbeef' | Should BeNullOrEmpty
    }
}

Describe 'Datei-Regeln: Check und Until' {
    $heute = [datetime]'2026-10-26'
    It 'Find ignoriert Regeln mit anderem Check' {
        $r = @([pscustomobject]@{ id = '1'; check = 'BitLocker'; datei = 'C:\a.dll'; sha256 = ('a' * 64); until = '' })
        Find-MorpheusAkzeptanzDatei -Regeln $r -Pfad 'C:\a.dll' -Sha256 ('a' * 64) -Heute $heute | Should BeNullOrEmpty
    }
    It 'unlesbares Until gilt als abgelaufen (Read und Find)' {
        $f = NeueDatei
        SchreibePsd1 $f "@{ Accepted = @( @{ Check='Systemdateien: Signaturen (Sigcheck)'; Reason='rrr'; Datei='C:\a.dll'; Sha256='$($script:Sha)'; Until='irgendwann' } ) }"
        $r = @(Read-MorpheusAkzeptanz -Datei $f -Heute $heute)
        $r[0].abgelaufen | Should Be $true
        Find-MorpheusAkzeptanzDatei -Regeln $r -Pfad 'C:\a.dll' -Sha256 $script:Sha -Heute $heute | Should BeNullOrEmpty
    }
}
