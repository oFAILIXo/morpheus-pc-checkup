#Requires -Version 5.1
# Pester-3.4-Tests für gui\lib\Winget.ps1.
# Startet nie echtes winget und braucht kein echtes Get-AppxPackage: Paket, Signatur, Existiert, Attribute,
# Ausfuehren, ArpNamen und Appx sind Attrappen. Existiert/Attribute sind Impl-Einträge, damit die Pfadprüfung
# ohne echten Ordner <ProgramFiles>\WindowsApps läuft.
# Ausführen: Invoke-Pester tests\Winget.Tests.ps1

. (Join-Path $PSScriptRoot '..\gui\lib\Winget.ps1')

$script:Fix = Join-Path $PSScriptRoot 'fixtures\winget'
function Get-Fix { param($Name) [IO.File]::ReadAllText((Join-Path $script:Fix $Name), [Text.Encoding]::UTF8) }

$script:Wa = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsApps'
$script:GoodDir = Join-Path $script:Wa 'Microsoft.DesktopAppInstaller_1.24.1_x64__8wekyb3d8bbwe'
$script:GoodSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'

function Set-FakeWinget {
    param([string]$Ort = $script:GoodDir, [string]$Status = 'Valid', [string]$Subject = $script:GoodSubject, [bool]$Paket = $true, [bool]$Datei = $true, [int]$Attr = 0)
    $script:FOrt = $Ort; $script:FStatus = $Status; $script:FSubject = $Subject; $script:FPaket = $Paket; $script:FDatei = $Datei; $script:FAttr = $Attr
    # Winget-Fund über die Attrappen von Systempfade.ps1 (Get-MorpheusWinget prüft Paket, Ordner, Reparse Point, Signatur)
    $script:MorpheusPfadImpl.ProgrammeOrdner = { [Environment]::GetFolderPath('ProgramFiles') }
    $script:MorpheusPfadImpl.Pakete = {
        if ($script:FPaket) { @([pscustomobject]@{ Name = 'Microsoft.DesktopAppInstaller'; PackageFullName = 'Microsoft.DesktopAppInstaller_1.24.1'; Version = '1.24.1.0'; PublisherId = '8wekyb3d8bbwe'; InstallLocation = $script:FOrt }) } else { @() }
    }
    $script:MorpheusPfadImpl.Datei = { param($Pfad) if (-not $script:FDatei) { throw 'fehlt' }; [pscustomobject]@{ Attributes = [IO.FileAttributes]$script:FAttr } }
    $script:MorpheusPfadImpl.Signatur = { param($Pfad) [pscustomobject]@{ Status = $script:FStatus; SignerCertificate = [pscustomobject]@{ Subject = $script:FSubject } } }
    $script:MorpheusPfadImpl.Wurzel = { param($Zertifikat) '8F43288AD272F3103B6FB1428485EA3014C0BCFE' }
    $script:MorpheusWingetImpl = @{
        ArpNamen  = { @() }
        Appx      = { param($Id) $false }
        Ausfuehren = { param($Pfad, $Argumente, $ZeitlimitMs) throw 'Echter Aufruf in Test' }
    }
}

Describe 'Get-MorpheusWingetPfad' {
    BeforeEach { $script:OrigPfadImpl = @{} + $script:MorpheusPfadImpl }
    AfterEach { foreach ($k in $script:OrigPfadImpl.Keys) { $script:MorpheusPfadImpl[$k] = $script:OrigPfadImpl[$k] } }

    It 'gibt den Pfad aus dem signierten Paket zurück' {
        Set-FakeWinget
        $r = Get-MorpheusWingetPfad
        $r.pfad | Should Be (Join-Path $script:GoodDir 'winget.exe')
        $r.grund | Should BeNullOrEmpty
    }
    It 'lehnt kein Paket ab' {
        Set-FakeWinget -Paket $false
        $r = Get-MorpheusWingetPfad
        $r.pfad | Should BeNullOrEmpty
        $r.grund | Should Match 'nicht als signiertes'
    }
    It 'lehnt Pfad außerhalb von WindowsApps ab' {
        Set-FakeWinget -Ort 'C:\Temp\Microsoft.DesktopAppInstaller_1.0_x64__8wekyb3d8bbwe'
        $r = Get-MorpheusWingetPfad
        $r.pfad | Should BeNullOrEmpty
        $r.grund | Should Match 'nicht im geschützten Ordner'
    }
    It 'lehnt den Benutzer-Alias in %LOCALAPPDATA%\Microsoft\WindowsApps ab' {
        $alias = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\WindowsApps\Microsoft.DesktopAppInstaller_1.0_x64__8wekyb3d8bbwe'
        Set-FakeWinget -Ort $alias
        $r = Get-MorpheusWingetPfad
        $r.pfad | Should BeNullOrEmpty
        $r.grund | Should Match 'nicht im geschützten Ordner'
    }
    It 'lehnt Pfadtricks mit .. ab' {
        Set-FakeWinget -Ort ($script:Wa + '\..\..\Temp\Microsoft.DesktopAppInstaller_1.0_x64__8wekyb3d8bbwe')
        (Get-MorpheusWingetPfad).pfad | Should BeNullOrEmpty
    }
    It 'lehnt einen falschen Paketordnernamen ab' {
        Set-FakeWinget -Ort (Join-Path $script:Wa 'Evil.Paket_1.0_x64__abc')
        (Get-MorpheusWingetPfad).pfad | Should BeNullOrEmpty
    }
    It 'lehnt fehlende winget.exe ab' {
        Set-FakeWinget -Datei $false
        (Get-MorpheusWingetPfad).pfad | Should BeNullOrEmpty
    }
    It 'lehnt Reparse Points ab' {
        Set-FakeWinget -Attr ([int][IO.FileAttributes]::ReparsePoint)
        $r = Get-MorpheusWingetPfad
        $r.pfad | Should BeNullOrEmpty
        $r.grund | Should Match 'Verknüpfung'
    }
    It 'lehnt ungültige Signatur ab' {
        Set-FakeWinget -Status 'HashMismatch'
        $r = Get-MorpheusWingetPfad
        $r.pfad | Should BeNullOrEmpty
        $r.grund | Should Match 'Signatur'
    }
    It 'lehnt falschen Signierer ab' {
        Set-FakeWinget -Subject 'CN=Evil Corp, O=Evil Corp, C=US'
        $r = Get-MorpheusWingetPfad
        $r.pfad | Should BeNullOrEmpty
        $r.grund | Should Match 'Microsoft'
    }
    It 'wirft nie, auch wenn die Paketabfrage wirft' {
        Set-FakeWinget
        $script:MorpheusPfadImpl.Pakete = { throw 'kaputt' }
        $r = Get-MorpheusWingetPfad
        $r.pfad | Should BeNullOrEmpty
        $r.grund | Should Match 'kaputt'
    }
    It 'wirft nie, wenn Get-MorpheusWinget selbst wirft' {
        Mock Get-MorpheusWinget { throw 'unerwartet' }
        $r = Get-MorpheusWingetPfad
        $r.pfad | Should BeNullOrEmpty
        $r.grund | Should Match 'unerwartet'
    }
    It 'Systempfade.ps1 fehlt -> kein Pfad und kein Rückgriff auf PATH' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-MorpheusWinget' }
        $r = Get-MorpheusWingetPfad
        $r.pfad | Should BeNullOrEmpty
        $r.grund | Should Be 'gui\lib\Systempfade.ps1 fehlt'
    }
}

Describe 'ConvertFrom-MorpheusWingetListe' {
    It 'liest die deutsche Ausgabe' {
        $r = ConvertFrom-MorpheusWingetListe -Text (Get-Fix 'de.txt')
        $r.status | Should Be 'ok'
        @($r.zeilen).Count | Should Be 3
        $r.zeilen[0].Name | Should Be 'Demo Editor'
        $r.zeilen[0].Id | Should Be 'Demo.Editor'
        $r.zeilen[0].Installiert | Should Be '1.2.0'
        $r.zeilen[0].Verfuegbar | Should Be '1.3.0'
        $r.zeilen[2].Id | Should Be 'EpicGames.Launcher'
    }
    It 'liest die englische Ausgabe und endet bei der Zusammenfassung' {
        $r = ConvertFrom-MorpheusWingetListe -Text (Get-Fix 'en.txt')
        $r.status | Should Be 'ok'
        @($r.zeilen).Count | Should Be 2
        $r.zeilen[1].Name | Should Be 'Sample Player'
        $r.zeilen[1].Verfuegbar | Should Be '4.1'
    }
    It 'nimmt bei \r-Fortschritt nur den Teil nach dem letzten \r' {
        $r = ConvertFrom-MorpheusWingetListe -Text (Get-Fix 'progress.txt')
        $r.status | Should Be 'ok'
        @($r.zeilen).Count | Should Be 1
        $r.zeilen[0].Id | Should Be 'Demo.Editor'
    }
    It 'meldet keine Updates (englisch und deutsch)' {
        (ConvertFrom-MorpheusWingetListe -Text (Get-Fix 'keine-en.txt')).status | Should Be 'keine'
        $r = ConvertFrom-MorpheusWingetListe -Text (Get-Fix 'keine-de.txt')
        $r.status | Should Be 'keine'
        @($r.zeilen).Count | Should Be 0
    }
    It 'meldet unlesbare Ausgabe, auch bei leerem Text und $null' {
        (ConvertFrom-MorpheusWingetListe -Text (Get-Fix 'unlesbar.txt')).status | Should Be 'unlesbar'
        (ConvertFrom-MorpheusWingetListe -Text '').status | Should Be 'unlesbar'
        (ConvertFrom-MorpheusWingetListe -Text $null).status | Should Be 'unlesbar'
    }
    It 'behält abgeschnittene Namen mit Auslassungszeichen' {
        $r = ConvertFrom-MorpheusWingetListe -Text (Get-Fix 'abgeschnitten.txt')
        $r.status | Should Be 'ok'
        $r.zeilen[0].Name | Should Be ('Ein sehr langer Prog' + [char]0x2026)
        $r.zeilen[0].Id | Should Be 'Demo.LangerName'
    }
}

Describe 'Get-MorpheusUpdateKategorie' {
    It 'erkennt Spiele und Launcher' {
        Get-MorpheusUpdateKategorie -Id 'Valve.Steam' -Name 'Steam' | Should Be 'Spiel/Launcher'
        Get-MorpheusUpdateKategorie -Id 'Demo.X' -Name 'Demo Launcher' | Should Be 'Spiel/Launcher'
        Get-MorpheusUpdateKategorie -Id 'Microsoft.Xbox.Foo' -Name 'Foo' | Should Be 'Spiel/Launcher'
    }
    It 'erkennt selbstaktualisierende Programme' {
        foreach ($i in 'Autodesk.Fusion', 'Microsoft.Edge', 'Microsoft.Teams', 'Microsoft.Outlook', 'Microsoft.VisualStudioCode', 'Vial.Vial') {
            Get-MorpheusUpdateKategorie -Id $i -Name 'x' | Should Be 'aktualisiert sich selbst'
        }
    }
    It 'stuft sonstige Programme als Programm ein' {
        Get-MorpheusUpdateKategorie -Id 'Demo.Editor' -Name 'Demo Editor' | Should Be 'Programm'
    }
}

Describe 'Get-MorpheusWingetUpdates' {
    BeforeEach {
        Set-FakeWinget
        $script:Aufrufe = @()
        $script:ArpListe = @('Demo Editor 1.2', 'Sample Player', 'Ein sehr langer Programmname')
        $script:AppxIds = @()
        $script:MorpheusWingetImpl.ArpNamen = { $script:ArpListe }
        $script:MorpheusWingetImpl.Appx = { param($Id) $Id -in $script:AppxIds }
        $script:Antworten = @([pscustomobject]@{ text = (Get-Fix 'de.txt'); fehlerText = ''; exitCode = 0; zeitueberschritten = $false })
        $script:MorpheusWingetImpl.Ausfuehren = {
            param($Pfad, $Argumente, $ZeitlimitMs)
            $script:Aufrufe += , @($Pfad, $Argumente, $ZeitlimitMs)
            $i = [Math]::Min($script:Aufrufe.Count, $script:Antworten.Count) - 1
            $script:Antworten[$i]
        }
    }
    It 'ruft winget mit festen Argumenten und 180000 ms Zeitlimit auf und liefert Kategorien' {
        $r = Get-MorpheusWingetUpdates -InformationAction SilentlyContinue
        $r.status | Should Be 'ok'
        $r.exitCode | Should Be 0
        $r.stand | Should Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
        $script:Aufrufe.Count | Should Be 1
        $script:Aufrufe[0][0] | Should Be (Join-Path $script:GoodDir 'winget.exe')
        $script:Aufrufe[0][1] | Should Be 'upgrade --source winget --include-unknown --disable-interactivity'
        $script:Aufrufe[0][2] | Should Be 180000
        @($r.zeilen).Count | Should Be 3
        $r.zeilen[0].Kategorie | Should Be 'Programm'
        $r.zeilen[2].Kategorie | Should Be 'Spiel/Launcher'
        # "Beispiel Player" ist in ArpNamen nicht vorhanden und kein Appx-Paket
        $r.zeilen[1].Kategorie | Should Be 'nicht mehr installiert'
    }
    It 'erkennt Programme über Appx' {
        $script:AppxIds = @('Beispiel.Player')
        $r = Get-MorpheusWingetUpdates -InformationAction SilentlyContinue
        $r.zeilen[1].Kategorie | Should Be 'Programm'
    }
    It 'gleicht abgeschnittene Namen mit dem Anfang des Programmnamens ab' {
        $script:Antworten = @([pscustomobject]@{ text = (Get-Fix 'abgeschnitten.txt'); fehlerText = ''; exitCode = 0; zeitueberschritten = $false })
        $r = Get-MorpheusWingetUpdates -InformationAction SilentlyContinue
        $r.zeilen[0].Kategorie | Should Be 'Programm'
        $r.zeilen[1].Kategorie | Should Be 'nicht mehr installiert'
    }
    It 'wiederholt einmal bei leerer erster Ausgabe' {
        $script:Antworten = @(
            [pscustomobject]@{ text = ''; fehlerText = ''; exitCode = 0; zeitueberschritten = $false },
            [pscustomobject]@{ text = (Get-Fix 'en.txt'); fehlerText = ''; exitCode = 0; zeitueberschritten = $false })
        $r = Get-MorpheusWingetUpdates -InformationAction SilentlyContinue
        $script:Aufrufe.Count | Should Be 2
        $r.status | Should Be 'ok'
        @($r.zeilen).Count | Should Be 2
    }
    It 'wiederholt höchstens einmal' {
        $script:Antworten = @([pscustomobject]@{ text = ''; fehlerText = 'Fehler'; exitCode = 1; zeitueberschritten = $false })
        $r = Get-MorpheusWingetUpdates -InformationAction SilentlyContinue
        $script:Aufrufe.Count | Should Be 2
        $r.status | Should Be 'unlesbar'
        $r.fehler | Should Match 'Exit-Code 1'
    }
    It 'meldet Zeitüberschreitung' {
        $script:Antworten = @([pscustomobject]@{ text = ''; fehlerText = ''; exitCode = $null; zeitueberschritten = $true })
        $r = Get-MorpheusWingetUpdates -InformationAction SilentlyContinue
        $r.status | Should Be 'zeitlimit'
        $r.fehler | Should Match '3 Minuten'
        $script:Aufrufe.Count | Should Be 1
    }
    It 'meldet keine Updates' {
        $script:Antworten = @([pscustomobject]@{ text = (Get-Fix 'keine-de.txt'); fehlerText = ''; exitCode = 0; zeitueberschritten = $false })
        $r = Get-MorpheusWingetUpdates -InformationAction SilentlyContinue
        $r.status | Should Be 'keine'
        @($r.zeilen).Count | Should Be 0
    }
    It 'meldet fehler mit Grund, wenn winget fehlt, und startet nichts' {
        Set-FakeWinget -Paket $false
        $script:MorpheusWingetImpl.Ausfuehren = { throw 'darf nicht laufen' }
        $r = Get-MorpheusWingetUpdates -InformationAction SilentlyContinue
        $r.status | Should Be 'fehler'
        $r.fehler | Should Match 'nicht als signiertes'
    }
    It 'wertet -Text ohne Aufruf von winget aus' {
        $r = Get-MorpheusWingetUpdates -Text (Get-Fix 'en.txt') -InformationAction SilentlyContinue
        $script:Aufrufe.Count | Should Be 0
        $r.status | Should Be 'ok'
        $r.exitCode | Should BeNullOrEmpty
    }
    It 'markiert gekürzte Ids als Id gekürzt (vor der Programm-Prüfung)' {
        $script:Antworten = @([pscustomobject]@{ text = (Get-Fix 'id-gekuerzt.txt'); fehlerText = ''; exitCode = 0; zeitueberschritten = $false })
        $script:ArpListe = @('Demo Editor', 'Build Tools')
        $r = Get-MorpheusWingetUpdates -InformationAction SilentlyContinue
        $r.zeilen[0].Id | Should Match ([string][char]0x2026)
        $r.zeilen[0].Kategorie | Should Be 'Id gekürzt'
        $r.zeilen[1].Kategorie | Should Be 'Programm'
    }
    It 'zeigt Fortschritt nur nach Wunsch des Aufrufers' {
        $null = Get-MorpheusWingetUpdates -InformationAction Ignore -InformationVariable iv1
        @($iv1).Count | Should Be 0
        $null = Get-MorpheusWingetUpdates -InformationAction Ignore -Fortschritt -InformationVariable iv2
        @($iv2).Count | Should BeGreaterThan 0
    }
    It 'gibt nur das Ergebnis aus (Fortschritt über Information)' {
        $out = @(Get-MorpheusWingetUpdates -InformationAction SilentlyContinue)
        $out.Count | Should Be 1
        $info = Get-MorpheusWingetUpdates -InformationAction SilentlyContinue -InformationVariable iv
        ($iv | Out-String) | Should Match '\[\d\d:\d\d:\d\d\]'
    }
}

Describe 'Test-MorpheusWingetId' {
    It 'akzeptiert gültige Ids' {
        foreach ($i in 'Demo.Editor', '7zip.7zip', 'Foo.Bar-Baz_1+2', 'a') { Test-MorpheusWingetId -Id $i | Should Be $true }
    }
    It 'lehnt Injection-Versuche und ungültige Zeichen ab' {
        foreach ($i in 'a --source evil', 'a;b', 'a"b', 'a b', 'a&b', 'a|b', '-a', '.a', '', ' ', "a`nb", 'a%PATH%', 'ä.b') {
            Test-MorpheusWingetId -Id $i | Should Be $false
        }
    }
    It 'prüft die Länge 128 / 129' {
        Test-MorpheusWingetId -Id ('a' * 128) | Should Be $true
        Test-MorpheusWingetId -Id ('a' * 129) | Should Be $false
    }
    It 'lehnt Nicht-Strings und $null ab' {
        Test-MorpheusWingetId -Id 5 | Should Be $false
        Test-MorpheusWingetId -Id $null | Should Be $false
        Test-MorpheusWingetId -Id @('a', 'b') | Should Be $false
    }
}

Describe 'Paketauswahl-Sortierung' {
    It 'sortiert Versionen numerisch (1.23.0 vor 1.9.0)' {
        $l = @([pscustomobject]@{ Version = '1.9.0' }, [pscustomobject]@{ Version = '1.23.0' }, [pscustomobject]@{ Version = 'kaputt' })
        $s = @($l | Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending)
        $s[0].Version | Should Be '1.23.0'
    }
}

Describe 'Get-MorpheusWingetUpgradeArgumente' {
    It 'baut die feste Argumentzeile' {
        Get-MorpheusWingetUpgradeArgumente -Id 'Demo.Editor' | Should Be 'upgrade --id Demo.Editor --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
    }
    It 'wirft bei ungültiger Id' {
        { Get-MorpheusWingetUpgradeArgumente -Id 'a --source evil' } | Should Throw
        { Get-MorpheusWingetUpgradeArgumente -Id $null } | Should Throw
        { Get-MorpheusWingetUpgradeArgumente -Id 7 } | Should Throw
    }
}

Describe 'Get-MorpheusWingetErgebnis' {
    It 'ordnet bekannte Codes zu' {
        (Get-MorpheusWingetErgebnis -ExitCode 0).status | Should Be 'aktualisiert'
        (Get-MorpheusWingetErgebnis -ExitCode -1978334975).status | Should Be 'laeuft-noch'
        (Get-MorpheusWingetErgebnis -ExitCode -1978335226).status | Should Be 'fehlgeschlagen'
        (Get-MorpheusWingetErgebnis -ExitCode 2316632329).status | Should Be 'neustart'
        (Get-MorpheusWingetErgebnis -ExitCode -1978334966).status | Should Be 'neustart'
        (Get-MorpheusWingetErgebnis -ExitCode -1978335189).status | Should Be 'kein-update'
        (Get-MorpheusWingetErgebnis -ExitCode -1978334974).status | Should Be 'fehlgeschlagen'
    }
    It 'führt Upgrade-nicht-unterstützt (0x8A150114) und keinen passenden Installer (0x8A150010) als fehlgeschlagen' {
        (Get-MorpheusWingetErgebnis -ExitCode -1978334956).status | Should Be 'fehlgeschlagen'
        (Get-MorpheusWingetErgebnis -ExitCode 0x8A150114).status | Should Be 'fehlgeschlagen'
        (Get-MorpheusWingetErgebnis -ExitCode -1978335216).status | Should Be 'fehlgeschlagen'
        (Get-MorpheusWingetErgebnis -ExitCode -1978335216).text | Should Match 'Installer'
        (Get-MorpheusWingetErgebnis -ExitCode -1978334962).status | Should Be 'kein-update'
    }
    It 'akzeptiert vorzeichenlose und vorzeichenbehaftete Form gleich' {
        (Get-MorpheusWingetErgebnis -ExitCode 0x8A15002B).status | Should Be 'kein-update'
        (Get-MorpheusWingetErgebnis -ExitCode ([long]0x8A15002B -band 0xFFFFFFFFL)).status | Should Be 'kein-update'
    }
    It 'liefert für unbekannte Codes Dezimal- und Hexwert' {
        $r = Get-MorpheusWingetErgebnis -ExitCode 1603
        $r.status | Should Be 'fehlgeschlagen'
        $r.text | Should Be 'winget-Fehlercode 1603 (0x00000643)'
        (Get-MorpheusWingetErgebnis -ExitCode -5).text | Should Match '^winget-Fehlercode -5 \(0xFFFFFFFB\)$'
    }
    It 'gibt jedem Ergebnis einen deutschen Text' {
        foreach ($c in 0, -1978334975, -1978335226, -1978334966, -1978335189, -1978334974, 99) {
            (Get-MorpheusWingetErgebnis -ExitCode $c).text | Should Not BeNullOrEmpty
        }
    }
}

# ---------------------------------------------------------------- WinGet-Ordner in TEMP (W11/G3)
# Echte Ordner unter $TestDrive. Ohne Adminrechte bleibt der Testbenutzer Besitzer; er gilt über
# $script:MorpheusWingetOrdnerImpl.ZusatzVertraut als vertrauenswürdig (und bekommt Vollzugriff), IstAdmin ist eine Attrappe.
Describe 'Initialize-MorpheusWingetOrdner / Test-MorpheusWingetOrdner' {
    BeforeEach {
        $script:WoSave = @{ IstAdmin = $script:MorpheusWingetOrdnerImpl.IstAdmin; ZusatzVertraut = $script:MorpheusWingetOrdnerImpl.ZusatzVertraut }
        $script:MorpheusWingetOrdnerImpl.IstAdmin = { $false }
        $script:MorpheusWingetOrdnerImpl.ZusatzVertraut = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $script:wt = Join-Path $TestDrive ('t' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:wt)
    }
    AfterEach {
        $script:MorpheusWingetOrdnerImpl.IstAdmin = $script:WoSave.IstAdmin
        $script:MorpheusWingetOrdnerImpl.ZusatzVertraut = $script:WoSave.ZusatzVertraut
    }
    function Add-UsersAce {
        param([string]$Pfad)
        $sid = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'
        $item = Get-Item -LiteralPath $Pfad -Force
        $acl = $item.GetAccessControl()
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, [Security.AccessControl.FileSystemRights]::ReadAndExecute, [Security.AccessControl.AccessControlType]::Allow)))
        $item.SetAccessControl($acl)
    }

    It 'Test: nicht vorhanden -> gehalten, genauer Text' {
        $t = Test-MorpheusWingetOrdner -TempPfad $script:wt
        $t.vorhanden | Should Be $false
        $t.gehalten | Should Be $true
        @($t.konten).Count | Should Be 0
        $t.pfad | Should Be (Join-Path $script:wt 'WinGet')
        $t.text | Should Be 'WinGet-Ordner: nicht vorhanden (winget hat ihn nicht benutzt).'
    }
    It 'Initialize: legt den Ordner an, nur Administratoren, SYSTEM (und Testbenutzer), keine Vererbung' {
        $r = Initialize-MorpheusWingetOrdner -TempPfad $script:wt
        $r.ok | Should Be $true
        $r.pfad | Should Be (Join-Path $script:wt 'WinGet')
        [IO.Directory]::Exists($r.pfad) | Should Be $true
        $acl = (New-Object IO.DirectoryInfo $r.pfad).GetAccessControl()
        $acl.AreAccessRulesProtected | Should Be $true
        $sids = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
        ($sids -contains 'S-1-5-32-544') | Should Be $true
        ($sids -contains 'S-1-5-18') | Should Be $true
        ($sids -contains 'S-1-5-32-545') | Should Be $false
        $t = Test-MorpheusWingetOrdner -TempPfad $script:wt
        $t.vorhanden | Should Be $true
        $t.gehalten | Should Be $true
        $t.text | Should Be 'WinGet-Ordner: Rechte gehalten (nur Administratoren und SYSTEM).'
    }
    It 'Initialize: vorhandenen Inhalt (auch Unterordner, schreibgeschützte Datei) entfernt und neu anlegt' {
        $w = Join-Path $script:wt 'WinGet'
        [void][IO.Directory]::CreateDirectory((Join-Path $w 'Paket\tief'))
        $d = Join-Path $w 'Paket\tief\setup.exe'
        [IO.File]::WriteAllText($d, 'x')
        [IO.File]::SetAttributes($d, [IO.FileAttributes]::ReadOnly)
        $r = Initialize-MorpheusWingetOrdner -TempPfad $script:wt
        $r.ok | Should Be $true
        @([IO.Directory]::GetFileSystemEntries($w)).Count | Should Be 0
    }
    It 'Test: Zusatz-ACE für Benutzer auf Unterordner -> nicht gehalten, Konto genannt' {
        [void](Initialize-MorpheusWingetOrdner -TempPfad $script:wt)
        $sub = Join-Path $script:wt 'WinGet\Paket'
        [void][IO.Directory]::CreateDirectory($sub)
        Add-UsersAce -Pfad $sub
        $t = Test-MorpheusWingetOrdner -TempPfad $script:wt
        $t.gehalten | Should Be $false
        @($t.konten).Count | Should Be 1
        $name = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545').Translate([Security.Principal.NTAccount]).Value
        $t.konten[0] | Should Be $name
        $t.text | Should Be ('WinGet hat den Ordner für ' + $name + ' freigegeben.')
    }
    It 'Test: Zusatz-ACE für Benutzer auf einer Datei -> nicht gehalten' {
        [void](Initialize-MorpheusWingetOrdner -TempPfad $script:wt)
        $f = Join-Path $script:wt 'WinGet\setup.exe'
        [IO.File]::WriteAllText($f, 'x')
        Add-UsersAce -Pfad $f
        (Test-MorpheusWingetOrdner -TempPfad $script:wt).gehalten | Should Be $false
    }
    It 'Initialize: stellt einen Ordner mit fremden Rechten wieder her' {
        [void](Initialize-MorpheusWingetOrdner -TempPfad $script:wt)
        $sub = Join-Path $script:wt 'WinGet\Paket'
        [void][IO.Directory]::CreateDirectory($sub)
        Add-UsersAce -Pfad $sub
        $r = Initialize-MorpheusWingetOrdner -TempPfad $script:wt
        $r.ok | Should Be $true
        (Test-MorpheusWingetOrdner -TempPfad $script:wt).gehalten | Should Be $true
    }
    It 'Test: Verknüpfung im Ordner zählt als nicht gehalten (Konto Verknüpfung), wird nicht betreten' {
        [void](Initialize-MorpheusWingetOrdner -TempPfad $script:wt)
        $ziel = Join-Path $script:wt 'ziel'
        [void][IO.Directory]::CreateDirectory($ziel)
        $link = Join-Path $script:wt 'WinGet\link'
        $cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
        & $cmd /c mklink /J "$link" "$ziel" | Out-Null
        $t = Test-MorpheusWingetOrdner -TempPfad $script:wt
        $t.gehalten | Should Be $false
        ($t.konten -contains 'Verknüpfung') | Should Be $true
    }
    It 'Initialize: ist WinGet eine Junction, wird nur der Link entfernt, das Ziel bleibt' {
        $ziel = Join-Path $script:wt 'ziel'
        [void][IO.Directory]::CreateDirectory($ziel)
        [IO.File]::WriteAllText((Join-Path $ziel 'wichtig.txt'), 'x')
        $link = Join-Path $script:wt 'WinGet'
        $cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
        & $cmd /c mklink /J "$link" "$ziel" | Out-Null
        $r = Initialize-MorpheusWingetOrdner -TempPfad $script:wt
        $r.ok | Should Be $true
        [IO.File]::Exists((Join-Path $ziel 'wichtig.txt')) | Should Be $true
        (([IO.File]::GetAttributes($link) -band [IO.FileAttributes]::ReparsePoint) -ne 0) | Should Be $false
        (Test-MorpheusWingetOrdner -TempPfad $script:wt).gehalten | Should Be $true
    }
    It 'Initialize: Junction im Inhalt wird nicht betreten, das Ziel bleibt' {
        $ziel = Join-Path $script:wt 'ziel'
        [void][IO.Directory]::CreateDirectory($ziel)
        [IO.File]::WriteAllText((Join-Path $ziel 'wichtig.txt'), 'x')
        $w = Join-Path $script:wt 'WinGet'
        [void][IO.Directory]::CreateDirectory($w)
        $cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
        & $cmd /c mklink /J "$(Join-Path $w 'link')" "$ziel" | Out-Null
        $r = Initialize-MorpheusWingetOrdner -TempPfad $script:wt
        $r.ok | Should Be $true
        [IO.File]::Exists((Join-Path $ziel 'wichtig.txt')) | Should Be $true
    }
    It 'Initialize: Fehler wird als ok false gemeldet, kein throw' {
        # Datei als Elternordner: CreateDirectory scheitert
        $blocker = Join-Path $script:wt 'datei'
        [IO.File]::WriteAllText($blocker, 'x')
        $r = Initialize-MorpheusWingetOrdner -TempPfad $blocker
        $r.ok | Should Be $false
        $r.meldung | Should Not BeNullOrEmpty
    }
    It 'Ohne -TempPfad zeigt der Pfad auf <GetTempPath>\WinGet' {
        (Test-MorpheusWingetOrdner).pfad | Should Be (Join-Path ([IO.Path]::GetTempPath()) 'WinGet')
    }
}
