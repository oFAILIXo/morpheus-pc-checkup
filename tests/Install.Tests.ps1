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

# ---------------------------------------------------------------- Datenordner-Rechte reparieren (2.4, #63)
# Echte Ordner unter $TestDrive, ohne Adminrechte. Der Testbenutzer gilt über $script:MorpheusInstallImpl.ZusatzVertraut als
# vertrauenswürdig (Besitzer und Vollzugriff; ohne Adminrechte lässt sich der Besitzer nicht auf Administratoren setzen, die
# Reparatur toleriert das nur in diesem Testmodus). Fremde SID ist S-1-5-32-545 (BUILTIN\Benutzer). Nichts unter ProgramData.

function New-TestDatenordner {
    # Geschützter Ordner (keine Vererbung von Temp): Administratoren, SYSTEM, Testbenutzer Vollzugriff
    param([string]$Base)
    $d = Join-Path $Base ('daten-' + [guid]::NewGuid().ToString('N'))
    $ds = New-Object System.Security.AccessControl.DirectorySecurity
    $ds.SetAccessRuleProtection($true, $false)
    $inh = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($s in @('S-1-5-32-544', 'S-1-5-18', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) {
        $ds.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($s)), 'FullControl', $inh, 'None', 'Allow')))
    }
    [void][IO.Directory]::CreateDirectory($d, $ds)
    foreach ($sub in 'reports', 'changes', 'state', 'temp', 'tools') { [void][IO.Directory]::CreateDirectory((Join-Path $d $sub)) }
    [IO.File]::WriteAllText((Join-Path $d 'changes\journal.json'), '{"eintraege":[1,2]}')
    [IO.File]::WriteAllText((Join-Path $d 'accepted.psd1'), '@{ a = 1 }')
    [IO.File]::WriteAllText((Join-Path $d 'state\checklist.json'), '{"x":1}')
    [IO.File]::WriteAllText((Join-Path $d 'state\gui.log'), 'log')
    [IO.File]::WriteAllText((Join-Path $d 'reports\bericht.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $d 'temp\zwischen.tmp'), 'z')
    [IO.File]::WriteAllText((Join-Path $d 'tools\tool.txt'), 't')
    $d
}

function Add-TestFremdAce {
    # Allow-Eintrag für BUILTIN\Benutzer; Ordner mit Vererbung, Dateien ohne
    param([string]$Pfad, [string]$Rechte = 'Modify')
    $sid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    if (Test-Path -LiteralPath $Pfad -PathType Container) {
        $sec = [IO.Directory]::GetAccessControl($Pfad, 'Access')
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $Rechte, ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'), 'None', 'Allow')))
        [IO.Directory]::SetAccessControl($Pfad, $sec)
    }
    else {
        $sec = [IO.File]::GetAccessControl($Pfad, 'Access')
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $Rechte, 'Allow')))
        [IO.File]::SetAccessControl($Pfad, $sec)
    }
}

Describe 'Get-MorpheusDatenordnerZustand' {
    BeforeEach {
        $script:SaveImpl = @{ IstAdmin = $script:MorpheusInstallImpl.IstAdmin; ZusatzVertraut = $script:MorpheusInstallImpl.ZusatzVertraut }
        $script:MorpheusInstallImpl.ZusatzVertraut = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $script:MorpheusInstallImpl.ElternAb = $TestDrive
    }
    AfterEach {
        $script:MorpheusInstallImpl.IstAdmin = $script:SaveImpl.IstAdmin
        $script:MorpheusInstallImpl.ZusatzVertraut = $script:SaveImpl.ZusatzVertraut
        $script:MorpheusInstallImpl.ElternAb = $null
    }

    It 'meldet fehlt für einen nicht vorhandenen Ordner' {
        $z = Get-MorpheusDatenordnerZustand -Path (Join-Path $TestDrive 'gibt-es-nicht')
        $z.zustand | Should Be 'fehlt'
        @($z.konten).Count | Should Be 0
    }

    It 'meldet ok für einen gesicherten Ordner (temp-Inhalt zählt nicht)' {
        $d = New-TestDatenordner $TestDrive
        Add-TestFremdAce (Join-Path $d 'temp\zwischen.tmp')
        $z = Get-MorpheusDatenordnerZustand -Path $d
        $z.zustand | Should Be 'ok'
        $z.objekte | Should Be 0
        @($z.gruende).Count | Should Be 0
    }

    It 'meldet reparierbar mit Konto, Rechten und Objektzahl bei Zusatz-ACE auf Ordner und Datei' {
        $d = New-TestDatenordner $TestDrive
        Add-TestFremdAce $d 'Modify'
        Add-TestFremdAce (Join-Path $d 'accepted.psd1') 'ReadAndExecute'
        $z = Get-MorpheusDatenordnerZustand -Path $d
        $z.zustand | Should Be 'reparierbar'
        @($z.konten).Count | Should Be 1
        $z.konten[0].sid | Should Be 'S-1-5-32-545'
        $z.konten[0].name | Should Be 'Benutzer'
        $z.konten[0].rechte | Should Be 'schreiben'
        $z.objekte | Should BeGreaterThan 1
        ($z.gruende -join ' ') | Should Match 'S-1-5-32-545'
    }

    It 'meldet bei nur lesendem Zusatzrecht rechte = lesen' {
        $d = New-TestDatenordner $TestDrive
        Add-TestFremdAce $d 'ReadAndExecute'
        $z = Get-MorpheusDatenordnerZustand -Path $d
        $z.zustand | Should Be 'reparierbar'
        $z.konten[0].rechte | Should Be 'lesen'
    }

    It 'meldet beiseite bei einer Verknüpfung im Ordner und betritt sie nicht' {
        $d = New-TestDatenordner $TestDrive
        $ziel = Join-Path $TestDrive ('linkziel-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($ziel)
        [IO.File]::WriteAllText((Join-Path $ziel 'drin.txt'), 'x')
        $link = Join-Path $d 'state\verknuepfung'
        $cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
        & $cmd /c mklink /J "`"$link`"" "`"$ziel`"" | Out-Null
        try {
            (Test-Path -LiteralPath $link) | Should Be $true
            $z = Get-MorpheusDatenordnerZustand -Path $d
            $z.zustand | Should Be 'beiseite'
            ($z.gruende -join ' ') | Should Match 'Verknüpfung'
            ($z.gruende -join ' ') | Should Not Match 'drin\.txt'
        }
        finally { if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link, $false) } }
        (Test-Path -LiteralPath (Join-Path $ziel 'drin.txt')) | Should Be $true
    }

    It 'meldet beiseite, wenn der Ordner selbst eine Datei ist' {
        $f = Join-Path $TestDrive 'datei-statt-ordner'
        [IO.File]::WriteAllText($f, 'x')
        (Get-MorpheusDatenordnerZustand -Path $f).zustand | Should Be 'beiseite'
    }

    It 'meldet beiseite bei einem nicht vertrauenswürdigen Besitzer' {
        $d = New-TestDatenordner $TestDrive
        $script:MorpheusInstallImpl.ZusatzVertraut = @()   # Besitzer (Testbenutzer) gilt jetzt nicht mehr als vertrauenswürdig
        $z = Get-MorpheusDatenordnerZustand -Path $d
        $z.zustand | Should Be 'beiseite'
        ($z.gruende -join ' ') | Should Match 'Besitzer'
    }

    It 'meldet beiseite bei einem unsicheren Elternordner (Benutzer dürfen darin löschen/ersetzen)' {
        $eltern = New-TestDatenordner $TestDrive   # geschützter Elternordner (ohne Vererbung aus dem Temp-Pfad)
        $d = New-TestDatenordner $eltern
        (Get-MorpheusDatenordnerZustand -Path $d).zustand | Should Be 'ok'
        Add-TestFremdAce $eltern 'Modify'
        $z = Get-MorpheusDatenordnerZustand -Path $d
        $z.zustand | Should Be 'beiseite'
        ($z.gruende -join ' ') | Should Match 'Elternordner'
        ($z.gruende -join ' ') | Should Match 'S-1-5-32-545'
    }
}

Describe 'Initialize-MorpheusDataDir bei reparierbarem Datenordner' {
    BeforeEach {
        $script:SaveImpl = @{ IstAdmin = $script:MorpheusInstallImpl.IstAdmin; ZusatzVertraut = $script:MorpheusInstallImpl.ZusatzVertraut }
        $script:MorpheusInstallImpl.ZusatzVertraut = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $script:MorpheusInstallImpl.ElternAb = $TestDrive
        $script:MorpheusInstallImpl.IstAdmin = { $true }
    }
    AfterEach {
        $script:MorpheusInstallImpl.IstAdmin = $script:SaveImpl.IstAdmin
        $script:MorpheusInstallImpl.ZusatzVertraut = $script:SaveImpl.ZusatzVertraut
        $script:MorpheusInstallImpl.ElternAb = $null
    }

    It 'wirft mit Data datenordner/zustand und legt den Ordner nicht beiseite' {
        $d = New-TestDatenordner $TestDrive
        Add-TestFremdAce $d 'Modify'
        $ex = $null
        try { [void](Initialize-MorpheusDataDir -Path $d) } catch { $ex = $_.Exception }
        ($null -ne $ex) | Should Be $true
        $ex.Data['datenordner'] | Should Be 'reparierbar'
        $ex.Data['zustand'].zustand | Should Be 'reparierbar'
        @($ex.Data['zustand'].konten).Count | Should BeGreaterThan 0
        $ex.Message | Should Match 'Nur-Lesen-Modus'
        $ex.Message | Should Match 'Benutzer'
        (Test-Path -LiteralPath $d -PathType Container) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $d 'changes\journal.json')) | Should Be $true
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $d) -Filter '*.unsicher-*').Count | Should Be 0
    }

    It 'legt mit -Beiseite auch einen reparierbaren Ordner beiseite (braucht Adminrechte für icacls)' -Skip {
    }
}

Describe 'Repair-MorpheusDatenordner' {
    BeforeEach {
        $script:SaveImpl = @{ IstAdmin = $script:MorpheusInstallImpl.IstAdmin; ZusatzVertraut = $script:MorpheusInstallImpl.ZusatzVertraut }
        $script:MorpheusInstallImpl.ZusatzVertraut = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $script:MorpheusInstallImpl.ElternAb = $TestDrive
        $script:MorpheusInstallImpl.IstAdmin = { $true }
    }
    AfterEach {
        $script:MorpheusInstallImpl.IstAdmin = $script:SaveImpl.IstAdmin
        $script:MorpheusInstallImpl.ZusatzVertraut = $script:SaveImpl.ZusatzVertraut
        $script:MorpheusInstallImpl.ElternAb = $null
        $script:MorpheusInstallImpl.VorAcl = $null
    }

    It 'entfernt die Einträge, räumt tools/temp/state auf, schreibt Dateien neu und endet mit Zustand ok' {
        $d = New-TestDatenordner $TestDrive
        Add-TestFremdAce $d 'Modify'
        Add-TestFremdAce (Join-Path $d 'accepted.psd1') 'ReadAndExecute'
        # Ein Programm hält journal.json noch zum Schreiben offen (Löschen/Ersetzen erlaubt)
        $jp = Join-Path $d 'changes\journal.json'
        $alt = New-Object IO.FileStream($jp, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]'ReadWrite, Delete')
        try {
            $r = Repair-MorpheusDatenordner -Path $d
            $buf = [Text.Encoding]::ASCII.GetBytes('FREMD')
            $alt.Write($buf, 0, $buf.Length); $alt.Flush()
        }
        finally { $alt.Dispose() }
        $r.zustand | Should Be 'ok'
        $r.entfernt | Should BeGreaterThan 1
        $r.meldung | Should Match 'repariert'
        (Get-MorpheusDatenordnerZustand -Path $d).zustand | Should Be 'ok'
        # tools weg, temp neu und leer, state bis auf checklist leer (plus reparatur.json)
        (Test-Path -LiteralPath (Join-Path $d 'tools')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $d 'temp') -PathType Container) | Should Be $true
        @(Get-ChildItem -LiteralPath (Join-Path $d 'temp') -Force).Count | Should Be 0
        (Test-Path -LiteralPath (Join-Path $d 'state\gui.log')) | Should Be $false
        $stateNamen = @(Get-ChildItem -LiteralPath (Join-Path $d 'state') -Force | ForEach-Object { $_.Name } | Sort-Object)
        ($stateNamen -join '|') | Should Be 'checklist.json|datenordner-reparatur.json'
        # Berichte bleiben, Inhalte gleich, offene Schreibzugriffe gingen ins Leere
        (Test-Path -LiteralPath (Join-Path $d 'reports\bericht.json')) | Should Be $true
        [IO.File]::ReadAllText($jp) | Should Be '{"eintraege":[1,2]}'
        [IO.File]::ReadAllText((Join-Path $d 'accepted.psd1')) | Should Be '@{ a = 1 }'
        [IO.File]::ReadAllText((Join-Path $d 'state\checklist.json')) | Should Be '{"x":1}'
        @(Get-ChildItem -LiteralPath $d -Recurse -Force | Where-Object { $_.Name -like '*.neu-*' }).Count | Should Be 0
        # Zusatz-ACEs weg
        $sec = [IO.File]::GetAccessControl((Join-Path $d 'accepted.psd1'), 'Access')
        @($sec.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' }).Count | Should Be 0
        # reparatur.json
        $j = [IO.File]::ReadAllText((Join-Path $d 'state\datenordner-reparatur.json')) | ConvertFrom-Json
        $j.version | Should Be 2
        $j.journalUnlesbar | Should Be $false
        @($j.eintraege).Count | Should Be 0   # das Test-Journal ist kein Array mit Einträgen
        @($r.warnungen).Count | Should Be 0
        $j.zeit | Should Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
        @($j.konten).Count | Should Be 1
        @($j.konten)[0].sid | Should Be 'S-1-5-32-545'
        @($j.konten)[0].name | Should Be 'Benutzer'
    }

    It 'erzeugt für journal.json eine neue Datei (neue Datei-Id)' {
        $d = New-TestDatenordner $TestDrive
        Add-TestFremdAce $d 'Modify'
        $jp = Join-Path $d 'changes\journal.json'
        $idVorher = (Get-Item -LiteralPath $jp).CreationTimeUtc.Ticks
        Start-Sleep -Milliseconds 50
        [void](MorpheusDateiNeuSchreiben -Datei $jp)
        # Die Neu-Schreibung kopiert in eine neue Datei: ein zuvor geöffnetes Handle zeigt auf die ersetzte Datei
        $h = New-Object IO.FileStream($jp, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]'ReadWrite, Delete')
        try {
            [void](MorpheusDateiNeuSchreiben -Datei $jp)
            $b = [Text.Encoding]::ASCII.GetBytes('X'); $h.Write($b, 0, 1); $h.Flush()
        }
        finally { $h.Dispose() }
        [IO.File]::ReadAllText($jp) | Should Be '{"eintraege":[1,2]}'
        ((Get-Item -LiteralPath $jp).CreationTimeUtc.Ticks -ge 0) | Should Be $true
        (MorpheusDateiNeuSchreiben -Datei (Join-Path $d 'gibt-es-nicht.json')) | Should Be $false
    }

    It 'wirft bei Zustand ok und bei beiseite, ohne etwas zu ändern' {
        $d = New-TestDatenordner $TestDrive
        [IO.File]::WriteAllText((Join-Path $d 'state\datenordner-reparatur.json'), '{"version":2}')   # Sperrdatei vorhanden: nichts nachzuholen
        { Repair-MorpheusDatenordner -Path $d } | Should Throw
        (Test-Path -LiteralPath (Join-Path $d 'tools\tool.txt')) | Should Be $true
        $ziel = Join-Path $TestDrive ('linkziel-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($ziel)
        Add-TestFremdAce $d 'Modify'
        $link = Join-Path $d 'state\verknuepfung'
        $cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
        & $cmd /c mklink /J "`"$link`"" "`"$ziel`"" | Out-Null
        try {
            { Repair-MorpheusDatenordner -Path $d } | Should Throw 'beiseite'
            (Test-Path -LiteralPath (Join-Path $d 'tools\tool.txt')) | Should Be $true
        }
        finally { if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link, $false) } }
    }

    It 'wirft ohne Adminrechte' {
        $d = New-TestDatenordner $TestDrive
        Add-TestFremdAce $d 'Modify'
        $script:MorpheusInstallImpl.IstAdmin = { $false }
        { Repair-MorpheusDatenordner -Path $d } | Should Throw 'Administratorrechte'
    }

    It 'lässt sich ohne state-Ordner und ohne Journal ausführen (fehlende Dateien werden übersprungen)' {
        $d = New-TestDatenordner $TestDrive
        Remove-Item -LiteralPath (Join-Path $d 'state') -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $d 'changes\journal.json') -Force
        Add-TestFremdAce $d 'Modify'
        (Repair-MorpheusDatenordner -Path $d).zustand | Should Be 'ok'
        (Test-Path -LiteralPath (Join-Path $d 'state\datenordner-reparatur.json')) | Should Be $true
    }

    It 'schreibt die Sperrdatei (Version 2) mit den Ids aller Journal-Einträge' {
        $d = New-TestDatenordner $TestDrive
        [IO.File]::WriteAllText((Join-Path $d 'changes\journal.json'), '[{"id":"a1","x":1},{"id":"b2"},{"id":"c3"}]')
        Add-TestFremdAce $d 'Modify'
        [void](Repair-MorpheusDatenordner -Path $d)
        $j = [IO.File]::ReadAllText((Join-Path $d 'state\datenordner-reparatur.json')) | ConvertFrom-Json
        $j.version | Should Be 2
        $j.journalUnlesbar | Should Be $false
        (@($j.eintraege) -join ',') | Should Be 'a1,b2,c3'
        @($j.konten).Count | Should Be 1
    }

    It 'setzt bei unlesbarem Journal eintraege = null und journalUnlesbar = true' {
        $d = New-TestDatenordner $TestDrive
        [IO.File]::WriteAllText((Join-Path $d 'changes\journal.json'), 'das ist kein JSON {')
        Add-TestFremdAce $d 'Modify'
        [void](Repair-MorpheusDatenordner -Path $d)
        $j = [IO.File]::ReadAllText((Join-Path $d 'state\datenordner-reparatur.json')) | ConvertFrom-Json
        $j.version | Should Be 2
        $j.journalUnlesbar | Should Be $true
        ($null -eq $j.eintraege) | Should Be $true
    }

    It 'sammelt Löschfehler als Warnung (gesperrte Datei in temp), bricht nicht ab und lässt die Sperrdatei zurück' {
        $d = New-TestDatenordner $TestDrive
        Add-TestFremdAce $d 'Modify'
        $gesperrt = New-Object IO.FileStream((Join-Path $d 'temp\zwischen.tmp'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        try { $r = Repair-MorpheusDatenordner -Path $d }
        finally { $gesperrt.Dispose() }
        $r.zustand | Should Be 'ok'
        @($r.warnungen).Count | Should BeGreaterThan 0
        ($r.warnungen -join ' ') | Should Match 'temp'
        $r.meldung | Should Match 'Hinweise'
        (Test-Path -LiteralPath (Join-Path $d 'state\datenordner-reparatur.json')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $d 'tools')) | Should Be $false
    }

    It 'holt bei Zustand ok ohne Sperrdatei die Sperrdatei und die übrigen Schritte nach' {
        $d = New-TestDatenordner $TestDrive
        (Get-MorpheusDatenordnerZustand -Path $d).zustand | Should Be 'ok'
        (Test-Path -LiteralPath (Join-Path $d 'state\datenordner-reparatur.json')) | Should Be $false
        $r = Repair-MorpheusDatenordner -Path $d
        $r.zustand | Should Be 'ok'
        $r.entfernt | Should Be 0
        (Test-Path -LiteralPath (Join-Path $d 'state\datenordner-reparatur.json')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $d 'tools')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $d 'state\gui.log')) | Should Be $false
        # Danach (Sperrdatei vorhanden) gibt es nichts mehr zu reparieren
        { Repair-MorpheusDatenordner -Path $d } | Should Throw
    }

    It 'bricht ohne Änderung ab, wenn der oberste Ordner zwischen Start und ACL zur Verknüpfung wird' {
        $d = New-TestDatenordner $TestDrive
        Add-TestFremdAce $d 'Modify'
        $script:TestHookPfad = $d
        $script:TestHookZiel = Join-Path $TestDrive ('linkziel-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:TestHookZiel)
        $script:MorpheusInstallImpl.VorAcl = {
            [IO.Directory]::Move($script:TestHookPfad, $script:TestHookPfad + '.alt')
            $cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
            & $cmd /c mklink /J "`"$($script:TestHookPfad)`"" "`"$($script:TestHookZiel)`"" | Out-Null
        }
        try { { Repair-MorpheusDatenordner -Path $d } | Should Throw 'Verknüpfung' }
        finally { if (Test-Path -LiteralPath $d) { [IO.Directory]::Delete($d, $false) } }
        @(Get-ChildItem -LiteralPath $script:TestHookZiel -Force).Count | Should Be 0
        (Test-Path -LiteralPath ($d + '.alt\tools\tool.txt')) | Should Be $true
        (Test-Path -LiteralPath ($d + '.alt\state\datenordner-reparatur.json')) | Should Be $false
    }

    It 'bricht ohne Änderung ab, wenn der oberste Ordner zwischen Start und ACL ausgetauscht wird (Erstellzeit)' {
        $d = New-TestDatenordner $TestDrive
        Add-TestFremdAce $d 'Modify'
        $script:TestHookPfad = $d
        $script:MorpheusInstallImpl.VorAcl = {
            [IO.Directory]::Move($script:TestHookPfad, $script:TestHookPfad + '.alt')
            [void][IO.Directory]::CreateDirectory($script:TestHookPfad)
            [IO.Directory]::SetCreationTimeUtc($script:TestHookPfad, (Get-Date).AddDays(-3).ToUniversalTime())   # NTFS-Tunneling umgehen
        }
        { Repair-MorpheusDatenordner -Path $d } | Should Throw 'ausgetauscht'
        (Test-Path -LiteralPath ($d + '.alt\tools\tool.txt')) | Should Be $true
        (Test-Path -LiteralPath ($d + '.alt\state\datenordner-reparatur.json')) | Should Be $false
    }

    It 'schaltet bei Unterobjekten mit abgeschalteter Vererbung die Vererbung wieder ein' {
        $d = New-TestDatenordner $TestDrive
        Add-TestFremdAce $d 'Modify'
        $dir = Join-Path $d 'changes'
        $file = Join-Path $d 'accepted.psd1'
        $secD = [IO.Directory]::GetAccessControl($dir, 'Access'); $secD.SetAccessRuleProtection($true, $true); [IO.Directory]::SetAccessControl($dir, $secD)
        $secF = [IO.File]::GetAccessControl($file, 'Access'); $secF.SetAccessRuleProtection($true, $true); [IO.File]::SetAccessControl($file, $secF)
        [IO.Directory]::GetAccessControl($dir, 'Access').AreAccessRulesProtected | Should Be $true
        $r = Repair-MorpheusDatenordner -Path $d
        $r.zustand | Should Be 'ok'
        [IO.Directory]::GetAccessControl($dir, 'Access').AreAccessRulesProtected | Should Be $false
        [IO.File]::GetAccessControl($file, 'Access').AreAccessRulesProtected | Should Be $false
        $sids = @([IO.File]::GetAccessControl($file, 'Access').GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
        ($sids -contains 'S-1-5-32-544') | Should Be $true
        ($sids -contains 'S-1-5-32-545') | Should Be $false
    }
}

Describe 'Install-Morpheus bei reparierbarem Datenordner (statisch, braucht sonst Adminrechte und Systempfade)' {
    It 'fängt die Ausnahme mit Data datenordner = reparierbar ab und legt die Verknüpfung trotzdem an' {
        $def = (Get-Command Install-Morpheus).Definition
        $def | Should Match "Data\['datenordner'\] -ceq 'reparierbar'"
        $def | Should Match 'catch \{'
        $iCatch = $def.IndexOf("-ceq 'reparierbar'")
        $iLnk = $def.IndexOf('CreateShortcut')
        ($iCatch -ge 0) | Should Be $true
        ($iLnk -gt $iCatch) | Should Be $true
        $def | Should Match 'if \(\$dataRoot\)'
    }
}