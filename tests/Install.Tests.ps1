#Requires -Version 5.1
# Pester-3.4-Tests für gui\lib\Install.ps1 (sichere Installation, Rechteprüfung).
# Ändert nichts am System: geprüft wird nur lesend (Systempfade) bzw. in $TestDrive.
# Install-Morpheus und Initialize-MorpheusDataDir brauchen Adminrechte und echte Systempfade
# (C:\Program Files\Morpheus, C:\ProgramData\Morpheus) und sind deshalb mit -Skip markiert.
# Ausführen: Invoke-Pester tests\Install.Tests.ps1

$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'gui\lib\Install.ps1')

function New-FakeCodeTree {
    # Baut einen Quellordner nach: Code, aber auch Dinge, die nicht ausgeliefert werden dürfen
    param([string]$Base)
    $r = Join-Path $Base ('src-' + [guid]::NewGuid().ToString('N'))
    foreach ($d in 'gui\lib', 'gui\assets', 'gui\dev', 'tests', 'docs', 'reports', 'changes', 'state', '.git') {
        New-Item -ItemType Directory -Path (Join-Path $r $d) -Force | Out-Null
    }
    foreach ($f in 'pc-check.ps1', 'pc-check.cmd', 'pc-check.hilfe.psd1', 'pc-check.aktionen.ps1', 'pc-check-gui.ps1', 'pc-check-gui.cmd',
        'accepted.example.psd1', 'README.md', 'accepted.psd1', 'gui\index.html', 'gui\app.js', 'gui\app.css', 'gui\lib\Safety.ps1', 'gui\lib\Server.ps1',
        'gui\lib\Install.ps1', 'gui\lib\notes.txt', 'gui\assets\logo.png', 'gui\dev\mock.js', 'tests\Safety.Tests.ps1', 'docs\x.md',
        'reports\pc-check_2026-01-01_0000.json', 'changes\journal.json', 'state\gui.log', '.git\config') {
        Set-Content -LiteralPath (Join-Path $r $f) -Value 'x'
    }
    $r
}

Describe 'Test-MorpheusSecurePath' {
    It 'hält einen vom Benutzer angelegten Ordner für unsicher und nennt Gründe' {
        $d = Join-Path $TestDrive 'eigener-ordner'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $r = Test-MorpheusSecurePath -Path $d
        $r.Sicher | Should Be $false
        @($r.Gruende).Count | Should BeGreaterThan 0
        ($r.Gruende -join ' ') | Should Match 'S-1-5-'
    }

    It 'hält eine vom Benutzer angelegte Datei für unsicher' {
        $f = Join-Path $TestDrive 'eigene-datei.ps1'
        Set-Content -LiteralPath $f -Value 'x'
        (Test-MorpheusSecurePath -Path $f).Sicher | Should Be $false
    }

    It 'findet beim rekursiven Prüfen auch Unterobjekte' {
        $d = Join-Path $TestDrive 'baum'
        New-Item -ItemType Directory -Path (Join-Path $d 'unter') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'unter\a.txt') -Value 'x'
        $r = Test-MorpheusSecurePath -Path $d -Recurse
        $r.Sicher | Should Be $false
        ($r.Gruende -join "`n") | Should Match 'a\.txt'
    }

    It 'hält die Datei hosts unter System32 für sicher' {
        $p = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        if (Test-Path -LiteralPath $p) {
            $r = Test-MorpheusSecurePath -Path $p
            $r.Sicher | Should Be $true
            @($r.Gruende).Count | Should Be 0
        }
    }

    It 'hält C:\Program Files für sicher (Besitzer TrustedInstaller, keine Schreibrechte für Benutzer)' {
        if (Test-Path -LiteralPath $env:ProgramFiles) {
            $r = Test-MorpheusSecurePath -Path $env:ProgramFiles
            $r.Sicher | Should Be $true
        }
    }

    It 'meldet einen fehlenden Pfad als unsicher' {
        $r = Test-MorpheusSecurePath -Path (Join-Path $TestDrive 'gibt-es-nicht')
        $r.Sicher | Should Be $false
        ($r.Gruende -join ' ') | Should Match 'nicht gefunden'
    }

    It 'prüft Elternordner mit (Ordner unter System32 bleibt sicher), -NoParents lässt sie weg' {
        $p = Join-Path $env:SystemRoot 'System32\drivers\etc'
        (Test-MorpheusSecurePath -Path $p).Sicher | Should Be $true
        (Test-MorpheusSecurePath -Path $p -NoParents).Sicher | Should Be $true
    }

    It 'liefert Sicher und Gruende als Hashtable' {
        $r = Test-MorpheusSecurePath -Path $TestDrive
        ($r -is [hashtable]) | Should Be $true
        ($r.ContainsKey('Sicher') -and $r.ContainsKey('Gruende')) | Should Be $true
    }
}

Describe 'Get-MorpheusCodeFiles' {
    It 'enthält im Projekt pc-check.aktionen.ps1 und keine Entwicklungs-, Test- oder Datendateien' {
        $base = $script:Root.TrimEnd('\')
        $rel = @(Get-MorpheusCodeFiles -Root $script:Root | ForEach-Object { $_.Substring($base.Length).TrimStart('\') })
        ($rel -contains 'pc-check.aktionen.ps1') | Should Be $true
        ($rel -contains 'pc-check-gui.ps1') | Should Be $true
        ($rel -contains 'gui\lib\Install.ps1') | Should Be $true
        ($rel -contains 'gui\dev\mock.js') | Should Be $false
        @($rel | Where-Object { $_ -like 'tests\*' -or $_ -like 'docs\*' -or $_ -like 'reports\*' -or $_ -like 'changes\*' -or $_ -like 'state\*' -or $_ -like '.git*' -or $_ -like 'gui\dev\*' }).Count | Should Be 0
        ($rel -contains 'accepted.psd1') | Should Be $false
    }

    It 'liefert in einem nachgebauten Baum genau die Laufzeitdateien' {
        $r = New-FakeCodeTree $TestDrive
        $rel = @(Get-MorpheusCodeFiles -Root $r | ForEach-Object { $_.Substring($r.Length).TrimStart('\') } | Sort-Object)
        $expected = @('README.md', 'accepted.example.psd1', 'gui\app.css', 'gui\app.js', 'gui\assets\logo.png', 'gui\index.html', 'gui\lib\Install.ps1',
            'gui\lib\Safety.ps1', 'gui\lib\Server.ps1', 'pc-check-gui.cmd', 'pc-check-gui.ps1', 'pc-check.aktionen.ps1', 'pc-check.cmd',
            'pc-check.hilfe.psd1', 'pc-check.ps1') | Sort-Object
        ($rel -join '|') | Should Be ($expected -join '|')
    }
}

Describe 'Test-MorpheusCodeSecure und Test-MorpheusInstallCurrent' {
    It 'hält einen Ordner im Temp-Verzeichnis nicht für sicher' {
        $r = New-FakeCodeTree $TestDrive
        $c = Test-MorpheusCodeSecure -Root $r
        $c.Sicher | Should Be $false
        @($c.Gruende).Count | Should BeGreaterThan 0
    }

    It 'meldet ein fehlendes Ziel als nicht aktuell' {
        $r = New-FakeCodeTree $TestDrive
        Test-MorpheusInstallCurrent -Source $r -Target (Join-Path $TestDrive 'nicht-da') | Should Be $false
    }

    It 'meldet ein unsicheres Ziel als nicht aktuell, auch bei gleichem Inhalt' {
        $r = New-FakeCodeTree $TestDrive
        $t = Join-Path $TestDrive ('ziel-' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $r -Destination $t -Recurse
        Test-MorpheusInstallCurrent -Source $r -Target $t | Should Be $false
    }
}

Describe 'New-MorpheusIcon' {
    It 'wandelt das PNG in eine gültige ICO-Datei um (Kopf 0,0,1,0; 1 Bild; PNG ab Offset 22)' {
        $png = Join-Path $script:Root 'gui\assets\morpheus-icon.png'
        $ico = Join-Path $TestDrive 'morpheus.ico'
        New-MorpheusIcon -PngPath $png -IcoPath $ico | Should Be $true
        $b = [IO.File]::ReadAllBytes($ico)
        $b.Length | Should BeGreaterThan 100
        ($b[0] -eq 0 -and $b[1] -eq 0 -and $b[2] -eq 1 -and $b[3] -eq 0 -and $b[4] -eq 1) | Should Be $true
        ($b[22] -eq 0x89 -and $b[23] -eq 0x50 -and $b[24] -eq 0x4E -and $b[25] -eq 0x47) | Should Be $true
    }

    It 'liefert bei fehlender Quelle $false statt zu werfen' {
        New-MorpheusIcon -PngPath (Join-Path $TestDrive 'nix.png') -IcoPath (Join-Path $TestDrive 'nix.ico') | Should Be $false
    }
}

Describe 'Install-Morpheus und Initialize-MorpheusDataDir (nur mit Adminrechten, ändern Rechte unter Program Files bzw. ProgramData)' {
    It 'Install-Morpheus installiert nach C:\Program Files\Morpheus, sichert den Datenordner und legt die Verknüpfung an' -Skip {
    }
    It 'Install-Morpheus bricht bei einem vorhandenen, nicht sicheren Ziel ab, ohne zu überschreiben' -Skip {
    }
    It 'Initialize-MorpheusDataDir legt einen unsicheren vorhandenen Ordner beiseite und den neuen mit fertigen Rechten an' -Skip {
    }
    It 'Initialize-MorpheusDataDir folgt keiner Verknüpfung (nur oberster Eintrag wird umbenannt bzw. entfernt)' -Skip {
    }
}
