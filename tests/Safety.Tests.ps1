#Requires -Version 5.1
# Pester-3.4-Tests für gui\lib\Safety.ps1. Ändert nichts am System: Katalog und
# Wiederherstellungspunkte sind Fakes, alle Dateien liegen in $TestDrive.
# Ausführen: Invoke-Pester tests\Safety.Tests.ps1

. (Join-Path $PSScriptRoot '..\gui\lib\Safety.ps1')

# Textbaustein einer Fake-Aktion: Zustand ist der Inhalt einer Datei (fehlt die Datei = $null)
function New-FakeActionText {
    param([string]$Id, [string]$File, [string]$Mode = 'normal', [string]$Extra = '')
    $read = "Lesen = { `$p = '$File'; if (Test-Path -LiteralPath `$p) { `$v = (Get-Content -LiteralPath `$p -Raw).Trim() } else { `$v = `$null }; [pscustomobject]@{ Aktiv = (`$v -like 'an*'); Wert = `$v; Zustand = `$v } }"
    $undo = "Rueckgaengig = { param(`$Vorher) if (`$null -eq `$Vorher) { Remove-Item -LiteralPath '$File' -Force -ErrorAction SilentlyContinue } else { Set-Content -LiteralPath '$File' -Value `$Vorher } }"
    switch ($Mode) {
        'normal'  { $run = "Ausfuehren = { param(`$Variante) Set-Content -LiteralPath '$File' -Value 'an' }" }
        'variant' { $run = "Ausfuehren = { param(`$Variante) Set-Content -LiteralPath '$File' -Value `$Variante }"; $Extra += "; Varianten = @('an-1','an-2')" }
        'throws'  { $run = "Ausfuehren = { param(`$Variante) Set-Content -LiteralPath '$File' -Value 'halb'; throw 'Fehler im Fake' }" }
        'noeffect' { $run = "Ausfuehren = { param(`$Variante) }" }
    }
    if ($Extra -notmatch 'Neustart') { $Extra += "; Neustart = `$false" }
    "@{ Id = '$Id'; Kategorie = 'Test'; Pruefung = 'Test'; Titel = 'Titel $Id'$Extra; $read; $run; $undo }"
}

function New-FakeRoot {
    # Eigener Projekt-Root mit Fake-Katalog; Rückgabe: Root
    param([string]$Base)
    $root = Join-Path $Base ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $f = { param($n) Join-Path $root "$n.txt" }
    $items = @(
        (New-FakeActionText 'fake.a' (& $f 'a')),
        (New-FakeActionText 'fake.b' (& $f 'b')),
        (New-FakeActionText 'fake.c' (& $f 'c')),
        (New-FakeActionText 'fake.var' (& $f 'var') 'variant'),
        (New-FakeActionText 'fake.fail' (& $f 'fail') 'throws'),
        (New-FakeActionText 'fake.noeffect' (& $f 'noeffect') 'noeffect'),
        (New-FakeActionText 'fake.restart' (& $f 'restart') 'normal' '; Neustart = $true'),
        (New-FakeActionText 'fake.pre' (& $f 'pre') 'normal' "; Voraussetzung = { 'Edition passt nicht' }"),
        (New-FakeActionText 'system.wiederherstellung' (& $f 'sr') 'normal' '; OhneWiederherstellungspunkt = $true')
    )
    $text = "@(`n" + ($items -join ",`n") + "`n)"
    [IO.File]::WriteAllText((Join-Path $root 'pc-check.aktionen.ps1'), $text, (New-Object Text.UTF8Encoding($true)))
    $root
}

function Get-FakeFile { param($Root, $Name) Join-Path $Root "$Name.txt" }
function Read-FakeFile { param($Root, $Name) $p = Get-FakeFile $Root $Name; if (Test-Path -LiteralPath $p) { (Get-Content -LiteralPath $p -Raw).Trim() } else { $null } }
function Get-TestJournal { param($Root) @(ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $Root 'changes\journal.json')))) }

function Set-FakeRestorePoints {
    param([bool]$Works = $true)
    $script:fakePoints = New-Object System.Collections.ArrayList
    $script:fakeCreateCalls = New-Object System.Collections.ArrayList
    $script:fakeWorks = $Works
    $script:PcCheckRestorePointWaitSeconds = 0
    $script:PcCheckRestorePointImpl = {
        param($Description)
        [void]$script:fakeCreateCalls.Add($Description)
        if ($script:fakeWorks) {
            $n = 100 + $script:fakePoints.Count
            [void]$script:fakePoints.Add([pscustomobject]@{
                    SequenceNumber = $n
                    Description    = $Description
                    RestorePointType = 12
                    CreationTime   = [Management.ManagementDateTimeConverter]::ToDmtfDateTime((Get-Date))
                })
        }
    }
    $script:PcCheckRestorePointListImpl = { @($script:fakePoints) }
}

Describe 'Invoke-PcCheckChange' {
    BeforeEach {
        $script:root = New-FakeRoot $TestDrive
        Set-FakeRestorePoints $true
    }

    It 'führt aus, legt genau einen geprüften Punkt an und schreibt das Journal' {
        $r = @(Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction SilentlyContinue)
        $r.Count | Should Be 1
        $r[0].id | Should Be 'fake.a'
        $r[0].status | Should Be 'erledigt'
        $r[0].vorher.zustand | Should BeNullOrEmpty
        $r[0].nachher.zustand | Should Be 'an'
        Read-FakeFile $script:root 'a' | Should Be 'an'
        $script:fakeCreateCalls.Count | Should Be 1
        $j = Get-TestJournal $script:root
        $j.Count | Should Be 1
        $j[0].status | Should Be 'erledigt'
        $j[0].art | Should Be 'ausfuehren'
        $j[0].wiederherstellungspunkt.seq | Should Be 100
        $j[0].id | Should Match '^\d{8}-\d{6}-\d{2}$'
    }

    It 'gibt nur das Ergebnis auf der Pipeline aus' {
        $r = @(Invoke-PcCheckChange -Root $script:root -Ids 'fake.a','fake.b' -InformationAction SilentlyContinue)
        $r.Count | Should Be 2
        ($r | Where-Object { $_.GetType().Name -ne 'PSCustomObject' }) | Should BeNullOrEmpty
    }

    It 'meldet Fortschritt über den Informationsstrom' {
        $info = @(Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction Continue 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $info.Count | Should BeGreaterThan 2
        [string]$info[0].MessageData | Should Match '^\[\d\d:\d\d:\d\d\] '
    }

    It 'überspringt erreichte Ziele ohne Punkt' {
        Set-Content -LiteralPath (Get-FakeFile $script:root 'a') -Value 'an'
        $r = @(Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction SilentlyContinue)
        $r[0].status | Should Be 'uebersprungen-erreicht'
        $script:fakeCreateCalls.Count | Should Be 0
        Test-Path (Join-Path $script:root 'changes\journal.json') | Should Be $false
    }

    It 'legt für mehrere Ids genau einen Punkt an und überspringt Erreichtes' {
        Set-Content -LiteralPath (Get-FakeFile $script:root 'b') -Value 'an'
        $r = @(Invoke-PcCheckChange -Root $script:root -Ids 'fake.a', 'fake.b', 'fake.c' -InformationAction SilentlyContinue)
        $r.Count | Should Be 3
        ($r | Where-Object { $_.status -eq 'erledigt' }).Count | Should Be 2
        $script:fakeCreateCalls.Count | Should Be 1
        $script:fakeCreateCalls[0] | Should Match '2 Änderungen'
        $j = Get-TestJournal $script:root
        $j.Count | Should Be 2
        ($j | Select-Object -ExpandProperty id -Unique).Count | Should Be 2
        ($j | ForEach-Object { $_.wiederherstellungspunkt.seq } | Select-Object -Unique) | Should Be 100
    }

    It 'bricht ab, wenn der Punkt fehlt: nichts geändert, kein Journal-Eintrag erledigt' {
        Set-FakeRestorePoints $false
        $msg = $null
        try { Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'Wiederherstellungspunkt'
        $msg | Should Match 'nichts geändert'
        $msg | Should Match 'Ursache'
        Test-Path -LiteralPath (Get-FakeFile $script:root 'a') | Should Be $false
        $erledigt = 0
        $jp = Join-Path $script:root 'changes\journal.json'
        if (Test-Path $jp) { $erledigt = @(Get-TestJournal $script:root | Where-Object { $_.status -eq 'erledigt' }).Count }
        $erledigt | Should Be 0
    }

    It 'bricht ab, wenn die Anlage wirft' {
        $script:PcCheckRestorePointImpl = { param($Description) throw 'Dienst nicht verfügbar' }
        $msg = $null
        try { Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'Dienst nicht verfügbar'
        Test-Path -LiteralPath (Get-FakeFile $script:root 'a') | Should Be $false
    }

    It 'ignoriert zu alte Punkte (älter als Jobstart minus 1 Minute)' {
        Set-FakeRestorePoints $false
        [void]$script:fakePoints.Add([pscustomobject]@{ SequenceNumber = 5; Description = 'alt'; RestorePointType = 12
                CreationTime = [Management.ManagementDateTimeConverter]::ToDmtfDateTime((Get-Date).AddHours(-3)) })
        $threw = $false
        try { Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null } catch { $threw = $true }
        $threw | Should Be $true
        Test-Path -LiteralPath (Get-FakeFile $script:root 'a') | Should Be $false
    }

    It 'ignoriert einen frischen fremden Punkt von kurz vorher (z. B. Windows Update)' {
        Set-FakeRestorePoints $false
        [void]$script:fakePoints.Add([pscustomobject]@{ SequenceNumber = 7; Description = 'Windows Update'; RestorePointType = 0
                CreationTime = [Management.ManagementDateTimeConverter]::ToDmtfDateTime((Get-Date).AddSeconds(-20)) })
        $threw = $false
        try { Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null } catch { $threw = $true }
        $threw | Should Be $true
        Test-Path -LiteralPath (Get-FakeFile $script:root 'a') | Should Be $false
    }

    It 'setzt automatisch zurück, wenn Ausfuehren wirft' {
        $r = @(Invoke-PcCheckChange -Root $script:root -Ids 'fake.fail' -InformationAction SilentlyContinue)
        $r[0].status | Should Be 'fehlgeschlagen-zurueckgesetzt'
        Test-Path -LiteralPath (Get-FakeFile $script:root 'fail') | Should Be $false
        (Get-TestJournal $script:root)[0].status | Should Be 'fehlgeschlagen-zurueckgesetzt'
    }

    It 'setzt zurück, wenn das Ziel nicht erreicht wird' {
        Set-Content -LiteralPath (Get-FakeFile $script:root 'noeffect') -Value 'aus'
        $r = @(Invoke-PcCheckChange -Root $script:root -Ids 'fake.noeffect' -InformationAction SilentlyContinue)
        $r[0].status | Should Be 'fehlgeschlagen-zurueckgesetzt'
        Read-FakeFile $script:root 'noeffect' | Should Be 'aus'
    }

    It 'prüft Variante: ungültig oder fehlend wirft, gültig wird übergeben' {
        { Invoke-PcCheckChange -Root $script:root -Ids 'fake.var' -Variante 'x' -InformationAction SilentlyContinue | Out-Null } | Should Throw
        { Invoke-PcCheckChange -Root $script:root -Ids 'fake.var' -InformationAction SilentlyContinue | Out-Null } | Should Throw
        { Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -Variante 'an-1' -InformationAction SilentlyContinue | Out-Null } | Should Throw
        $script:fakeCreateCalls.Count | Should Be 0
        $r = @(Invoke-PcCheckChange -Root $script:root -Ids 'fake.var' -Variante 'an-2' -InformationAction SilentlyContinue)
        $r[0].status | Should Be 'erledigt'
        Read-FakeFile $script:root 'var' | Should Be 'an-2'
        (Get-TestJournal $script:root)[0].variante | Should Be 'an-2'
    }

    It 'wirft bei unbekannter Id, ohne etwas zu ändern' {
        { Invoke-PcCheckChange -Root $script:root -Ids 'fake.a', 'gibt.es.nicht' -InformationAction SilentlyContinue | Out-Null } | Should Throw
        Test-Path -LiteralPath (Get-FakeFile $script:root 'a') | Should Be $false
        $script:fakeCreateCalls.Count | Should Be 0
    }

    It 'überspringt Aktionen mit nicht erfüllter Voraussetzung' {
        $r = @(Invoke-PcCheckChange -Root $script:root -Ids 'fake.pre', 'fake.a' -InformationAction SilentlyContinue)
        ($r | Where-Object { $_.id -eq 'fake.pre' }).status | Should Be 'uebersprungen-voraussetzung'
        ($r | Where-Object { $_.id -eq 'fake.a' }).status | Should Be 'erledigt'
        Test-Path -LiteralPath (Get-FakeFile $script:root 'pre') | Should Be $false
        $script:fakeCreateCalls[0] | Should Match 'Titel fake.a'
    }

    It 'meldet Neustart nur bei erledigter Aktion' {
        $r = @(Invoke-PcCheckChange -Root $script:root -Ids 'fake.restart' -InformationAction SilentlyContinue)
        $r[0].neustart | Should Be $true
    }

    It 'Sonderfall ohne Wiederherstellungspunkt: einzeln erlaubt, gemischt verboten' {
        { Invoke-PcCheckChange -Root $script:root -Ids 'system.wiederherstellung', 'fake.a' -InformationAction SilentlyContinue | Out-Null } | Should Throw
        $script:fakeCreateCalls.Count | Should Be 0
        $r = @(Invoke-PcCheckChange -Root $script:root -Ids 'system.wiederherstellung' -InformationAction SilentlyContinue)
        $r[0].status | Should Be 'erledigt'
        $script:fakeCreateCalls.Count | Should Be 0
        (Get-TestJournal $script:root)[0].wiederherstellungspunkt | Should BeNullOrEmpty
    }

    It 'lässt das Journal ein gültiges JSON-Array mit 1 Eintrag bleiben (UTF-8 ohne BOM)' {
        Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null
        $path = Join-Path $script:root 'changes\journal.json'
        $bytes = [IO.File]::ReadAllBytes($path)
        ($bytes[0] -eq 0xEF) | Should Be $false
        $text = [IO.File]::ReadAllText($path)
        $text.TrimStart()[0] | Should Be '['
        @(ConvertFrom-Json -InputObject $text).Count | Should Be 1
        Test-Path ($path + '.tmp') | Should Be $false
        # zweiter Lauf: Einträge werden angehängt, nie gelöscht
        Invoke-PcCheckChange -Root $script:root -Ids 'fake.b' -InformationAction SilentlyContinue | Out-Null
        (Get-TestJournal $script:root).Count | Should Be 2
        @(Get-PcCheckJournal -Root $script:root)[0].aktion | Should Be 'fake.b'
    }
}

Describe 'Undo-PcCheckChange' {
    BeforeEach {
        $script:root = New-FakeRoot $TestDrive
        Set-FakeRestorePoints $true
    }

    It 'stellt den $null-Zustand wieder her (Wert wird gelöscht)' {
        Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null
        Read-FakeFile $script:root 'a' | Should Be 'an'
        $entry = (Get-TestJournal $script:root)[0]
        $entry.vorher.zustand | Should BeNullOrEmpty
        $raw = [IO.File]::ReadAllText((Join-Path $script:root 'changes\journal.json'))
        $raw | Should Match '"zustand":\s*null'
        $u = Undo-PcCheckChange -Root $script:root -EntryId $entry.id -InformationAction SilentlyContinue
        $u.status | Should Be 'erledigt'
        Test-Path -LiteralPath (Get-FakeFile $script:root 'a') | Should Be $false
        $j = Get-TestJournal $script:root
        $j.Count | Should Be 2
        ($j | Where-Object { $_.id -eq $entry.id }).status | Should Be 'zurueckgenommen'
        $undo = $j | Where-Object { $_.art -eq 'rueckgaengig' }
        $undo.bezug | Should Be $entry.id
        $undo.status | Should Be 'erledigt'
        $script:fakeCreateCalls.Count | Should Be 2
    }

    It 'stellt einen vorhandenen alten Wert wieder her' {
        Set-Content -LiteralPath (Get-FakeFile $script:root 'a') -Value 'aus'
        Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null
        $entry = (Get-TestJournal $script:root)[0]
        Undo-PcCheckChange -Root $script:root -EntryId $entry.id -InformationAction SilentlyContinue | Out-Null
        Read-FakeFile $script:root 'a' | Should Be 'aus'
    }

    It 'wirft bei geändertem Zustand ohne Force, mit Force läuft es' {
        Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null
        $entry = (Get-TestJournal $script:root)[0]
        Set-Content -LiteralPath (Get-FakeFile $script:root 'a') -Value 'an-spaeter-geaendert'
        $pointsBefore = $script:fakeCreateCalls.Count
        $msg = $null
        try { Undo-PcCheckChange -Root $script:root -EntryId $entry.id -InformationAction SilentlyContinue | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'geändert'
        Read-FakeFile $script:root 'a' | Should Be 'an-spaeter-geaendert'
        $script:fakeCreateCalls.Count | Should Be $pointsBefore
        (Get-TestJournal $script:root)[0].status | Should Be 'erledigt'
        $u = Undo-PcCheckChange -Root $script:root -EntryId $entry.id -Force -InformationAction SilentlyContinue
        $u.status | Should Be 'erledigt'
        Test-Path -LiteralPath (Get-FakeFile $script:root 'a') | Should Be $false
    }

    It 'nimmt nichts zurück, wenn der Wiederherstellungspunkt fehlt' {
        Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null
        $entry = (Get-TestJournal $script:root)[0]
        Set-FakeRestorePoints $false
        { Undo-PcCheckChange -Root $script:root -EntryId $entry.id -InformationAction SilentlyContinue | Out-Null } | Should Throw
        Read-FakeFile $script:root 'a' | Should Be 'an'
        (Get-TestJournal $script:root).Count | Should Be 1
    }

    It 'lässt Zurückgenommenes, Rücknahmen und unbekannte Einträge nicht zu' {
        Invoke-PcCheckChange -Root $script:root -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null
        $entry = (Get-TestJournal $script:root)[0]
        Undo-PcCheckChange -Root $script:root -EntryId $entry.id -InformationAction SilentlyContinue | Out-Null
        { Undo-PcCheckChange -Root $script:root -EntryId $entry.id -InformationAction SilentlyContinue | Out-Null } | Should Throw
        $undo = (Get-TestJournal $script:root) | Where-Object { $_.art -eq 'rueckgaengig' }
        { Undo-PcCheckChange -Root $script:root -EntryId $undo.id -InformationAction SilentlyContinue | Out-Null } | Should Throw
        { Undo-PcCheckChange -Root $script:root -EntryId '19990101-000000-01' -InformationAction SilentlyContinue | Out-Null } | Should Throw
    }

    It 'lässt fehlgeschlagene Einträge nicht zurücknehmen' {
        Invoke-PcCheckChange -Root $script:root -Ids 'fake.fail' -InformationAction SilentlyContinue | Out-Null
        $entry = (Get-TestJournal $script:root)[0]
        { Undo-PcCheckChange -Root $script:root -EntryId $entry.id -InformationAction SilentlyContinue | Out-Null } | Should Throw
    }
}

Describe 'Katalog, Status und Hilfsfunktionen' {
    It 'Get-PcCheckCatalog liefert ohne Datei ein leeres Array' {
        $empty = Join-Path $TestDrive 'leer'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        @(Get-PcCheckCatalog -Root $empty).Count | Should Be 0
    }

    It 'Get-PcCheckCatalog lädt den Fake-Katalog' {
        $root = New-FakeRoot $TestDrive
        @(Get-PcCheckCatalog -Root $root).Count | Should Be 9
    }

    It 'Get-PcCheckActionStates und ConvertTo-PublicAction' {
        $root = New-FakeRoot $TestDrive
        $cat = @(Get-PcCheckCatalog -Root $root)
        $st = Get-PcCheckActionStates -Root $root -Catalog $cat
        $st['fake.a'].aktiv | Should Be $false
        $pub = ConvertTo-PublicAction -Action ($cat | Where-Object { $_.Id -eq 'fake.var' }) -State $st['fake.var']
        $pub.id | Should Be 'fake.var'
        @($pub.varianten).Count | Should Be 2
        $json = ConvertTo-Json -InputObject $pub -Depth 5
        $json | Should Not Match 'Lesen'
    }

    It 'Get-PcCheckActionStates meldet Lesefehler je Aktion' {
        $bad = @(@{ Id = 'bad.x'; Lesen = { throw 'kaputt' } })
        $st = Get-PcCheckActionStates -Root $TestDrive -Catalog $bad
        $st['bad.x'].wert | Should Match '^Fehler: kaputt'
    }

    It 'Get-PcCheckSafetyStatus liefert die Felder aus 7.3 und ist schnell' {
        $t = Measure-Command { $s = Get-PcCheckSafetyStatus -Root $TestDrive }
        $t.TotalMilliseconds | Should BeLessThan 1000
        ($s.PSObject.Properties.Name -contains 'schutzAn') | Should Be $true
        ($s.PSObject.Properties.Name -contains 'sperre24h') | Should Be $true
        $s.laufwerk | Should Match '^[A-Z]:$'
        $s.befehl | Should Match 'SystemRestorePointCreationFrequency'
    }

    It 'Get-PcCheckRestorePoints übersetzt WMI-Zeit und sortiert neueste zuerst' {
        Set-FakeRestorePoints $true
        [void]$script:fakePoints.Add([pscustomobject]@{ SequenceNumber = 1; Description = 'a'; RestorePointType = 12; CreationTime = [Management.ManagementDateTimeConverter]::ToDmtfDateTime((Get-Date).AddDays(-1)) })
        [void]$script:fakePoints.Add([pscustomobject]@{ SequenceNumber = 2; Description = 'b'; RestorePointType = 0; CreationTime = [Management.ManagementDateTimeConverter]::ToDmtfDateTime((Get-Date)) })
        $p = @(Get-PcCheckRestorePoints)
        $p.Count | Should Be 2
        $p[0].seq | Should Be 2
        $p[0].typ | Should Be 'APPLICATION_INSTALL'
        $p[0].zeit | Should Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$'
    }

    It 'Get-PcCheckRestorePoints liefert bei Fehler eine leere Liste' {
        $script:PcCheckRestorePointListImpl = { throw 'keine Rechte' }
        @(Get-PcCheckRestorePoints).Count | Should Be 0
    }

    It 'bricht bei beschädigtem Journal ab, ohne es zu überschreiben' {
        $root = New-FakeRoot $TestDrive
        Set-FakeRestorePoints $true
        New-Item -ItemType Directory -Path (Join-Path $root 'changes') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'changes\journal.json'), '{kaputt', (New-Object Text.UTF8Encoding($false)))
        { Invoke-PcCheckChange -Root $root -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null } | Should Throw
        [IO.File]::ReadAllText((Join-Path $root 'changes\journal.json')) | Should Be '{kaputt'
        $script:fakeCreateCalls.Count | Should Be 0
    }
}

Describe '-DataRoot: Journal getrennt vom Code' {
    BeforeEach {
        $script:root = New-FakeRoot $TestDrive
        $script:data = Join-Path $TestDrive ('data-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:data -Force | Out-Null
        Set-FakeRestorePoints $true
    }

    It 'schreibt das Journal unter <DataRoot>\changes und nicht unter <Root>' {
        Invoke-PcCheckChange -Root $script:root -DataRoot $script:data -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null
        Test-Path (Join-Path $script:data 'changes\journal.json') | Should Be $true
        Test-Path (Join-Path $script:root 'changes') | Should Be $false
        Read-FakeFile $script:root 'a' | Should Be 'an'
        @(Get-PcCheckJournal -Root $script:root -DataRoot $script:data).Count | Should Be 1
        @(Get-PcCheckJournal -Root $script:root).Count | Should Be 0
    }

    It 'nimmt mit -DataRoot zurück und liest den Katalog weiter aus -Root' {
        Invoke-PcCheckChange -Root $script:root -DataRoot $script:data -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null
        $entry = @(Get-PcCheckJournal -Root $script:root -DataRoot $script:data)[0]
        $u = Undo-PcCheckChange -Root $script:root -DataRoot $script:data -EntryId $entry.id -InformationAction SilentlyContinue
        $u.status | Should Be 'erledigt'
        Test-Path -LiteralPath (Get-FakeFile $script:root 'a') | Should Be $false
        @(Get-PcCheckJournal -Root $script:root -DataRoot $script:data).Count | Should Be 2
        # ohne -DataRoot ist der Eintrag nicht zu finden (Standard = Root)
        { Undo-PcCheckChange -Root $script:root -EntryId $entry.id -InformationAction SilentlyContinue | Out-Null } | Should Throw
    }

    It 'Get-PcCheckSafetyStatus liest den letzten Punkt aus dem Datenordner' {
        Invoke-PcCheckChange -Root $script:root -DataRoot $script:data -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null
        (Get-PcCheckSafetyStatus -Root $script:root -DataRoot $script:data).letzterPunkt | Should Match '^\d{4}-\d\d-\d\dT'
        (Get-PcCheckSafetyStatus -Root $script:root).letzterPunkt | Should BeNullOrEmpty
    }
}

Describe 'Undo-PcCheckChange: Abgleich des Journal-Eintrags mit der Aktion' {
    BeforeEach {
        $script:root = New-FakeRoot $TestDrive
        Set-FakeRestorePoints $true
        # Aktion mit Objekt-Zustand (wie die Registry-Aktionen: Wert/Typ/SchluesselVorhanden)
        $f = Join-Path $script:root 'obj.txt'
        $cat = "@(@{ Id = 'fake.obj'; Kategorie = 'T'; Pruefung = 'T'; Titel = 'Obj'; Neustart = `$false; " +
            "Lesen = { `$p = '$f'; if (Test-Path -LiteralPath `$p) { `$v = (Get-Content -LiteralPath `$p -Raw).Trim() } else { `$v = `$null }; [pscustomobject]@{ Aktiv = (`$v -like 'an*'); Wert = `$v; Zustand = [ordered]@{ Wert = `$v; Typ = 'String' } } }; " +
            "Ausfuehren = { param(`$Variante) Set-Content -LiteralPath '$f' -Value 'an' }; " +
            "Rueckgaengig = { param(`$Vorher) if ((`$null -eq `$Vorher) -or (`$null -eq `$Vorher.Wert)) { Remove-Item -LiteralPath '$f' -Force -ErrorAction SilentlyContinue } else { Set-Content -LiteralPath '$f' -Value `$Vorher.Wert } } })"
        [IO.File]::WriteAllText((Join-Path $script:root 'pc-check.aktionen.ps1'), $cat, (New-Object Text.UTF8Encoding($true)))
        $script:objFile = $f
    }

    function Set-TestJournalVorher {
        param($Root, $Id, $Json)
        $path = Join-Path $Root 'changes\journal.json'
        $all = New-Object System.Collections.ArrayList
        foreach ($x in (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)))) { [void]$all.Add($x) }
        foreach ($e in $all) { if ($e.id -eq $Id) { $e.vorher.zustand = (ConvertFrom-Json -InputObject $Json) } }
        $json = '[' + ((@($all) | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 12 -Compress }) -join ',') + ']'
        [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
    }

    It 'lässt einen echten Eintrag mit passender Form zurücknehmen' {
        Invoke-PcCheckChange -Root $script:root -Ids 'fake.obj' -InformationAction SilentlyContinue | Out-Null
        $entry = (Get-TestJournal $script:root)[0]
        $u = Undo-PcCheckChange -Root $script:root -EntryId $entry.id -InformationAction SilentlyContinue
        $u.status | Should Be 'erledigt'
        Test-Path -LiteralPath $script:objFile | Should Be $false
    }

    It 'weist einen Eintrag mit fremden Eigenschaftsnamen ab, auch mit -Force' {
        Invoke-PcCheckChange -Root $script:root -Ids 'fake.obj' -InformationAction SilentlyContinue | Out-Null
        $entry = (Get-TestJournal $script:root)[0]
        Set-TestJournalVorher $script:root $entry.id '{"Evil":"x","Wert":1}'
        $points = $script:fakeCreateCalls.Count
        $msg = $null
        try { Undo-PcCheckChange -Root $script:root -EntryId $entry.id -Force -InformationAction SilentlyContinue | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'passt nicht zur Aktion'
        (Get-Content -LiteralPath $script:objFile -Raw).Trim() | Should Be 'an'
        $script:fakeCreateCalls.Count | Should Be $points
        (Get-TestJournal $script:root).Count | Should Be 1
    }

    It 'weist einen Eintrag mit falscher Grundform ab (Einzelwert statt Objekt)' {
        Invoke-PcCheckChange -Root $script:root -Ids 'fake.obj' -InformationAction SilentlyContinue | Out-Null
        $entry = (Get-TestJournal $script:root)[0]
        Set-TestJournalVorher $script:root $entry.id '"irgendwas"'
        { Undo-PcCheckChange -Root $script:root -EntryId $entry.id -Force -InformationAction SilentlyContinue | Out-Null } | Should Throw
        (Get-Content -LiteralPath $script:objFile -Raw).Trim() | Should Be 'an'
    }

    It 'weist bei Einzelwert-Aktionen ein untergeschobenes Objekt ab' {
        $root = New-FakeRoot $TestDrive
        Invoke-PcCheckChange -Root $root -Ids 'fake.a' -InformationAction SilentlyContinue | Out-Null
        $entry = (Get-TestJournal $root)[0]
        Set-TestJournalVorher $root $entry.id '{"Pfad":"x"}'
        $msg = $null
        try { Undo-PcCheckChange -Root $root -EntryId $entry.id -Force -InformationAction SilentlyContinue | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'passt nicht zur Aktion'
        Read-FakeFile $root 'a' | Should Be 'an'
    }
}
