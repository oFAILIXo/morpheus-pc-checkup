#Requires -Version 5.1
# Pester-3.4-Tests für gui\lib\Sicherung.ps1. Rein lesend; eigene Testordner liegen in $TestDrive.
# Ausführen: Invoke-Pester tests\Sicherung.Tests.ps1

$script:SicherungDatei = Join-Path $PSScriptRoot '..\gui\lib\Sicherung.ps1'
. $script:SicherungDatei
$script:Fixtures = Join-Path $PSScriptRoot 'fixtures\sicherung'
$script:KeinReg = 'HKCU:\Software\Morpheus-Test-Gibt-Es-Nicht'

function New-Eintrag {
    param([string]$Art, [bool]$Gefunden = $true, [bool]$Aktiv = $true, $Letzte = $null, $Ordner = @())
    $o = [ordered]@{ art = $Art; gefunden = $Gefunden; aktiv = $Aktiv; ziel = 'x'; letzteSicherung = $Letzte; hinweis = '' }
    if ($Art -eq 'OneDrive-Ordnersicherung') { $o['ordner'] = @($Ordner) }
    [pscustomobject]$o
}
function New-Satz {
    param($Dv, $Od, $Sa)
    @($Dv, $Od, $Sa)
}
$script:Jetzt = [datetime]'2026-10-25T12:00:00'
function Iso { param([int]$Tage) $script:Jetzt.AddDays(-$Tage).ToString('s') }

Describe 'Datei' {
    It 'hat UTF-8-BOM' {
        $b = [IO.File]::ReadAllBytes($script:SicherungDatei)
        $b[0] | Should Be 239; $b[1] | Should Be 187; $b[2] | Should Be 191
    }
    It 'parst fehlerfrei' {
        $err = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:SicherungDatei).Path, [ref]$null, [ref]$err)
        @($err).Count | Should Be 0
    }
    It 'enthält kein Add-Type' {
        (Get-Content -LiteralPath $script:SicherungDatei -Raw) -match 'Add-Type' | Should Be $false
    }
}

Describe 'Get-MorpheusSicherungBewertung' {
    $nichts = New-Satz (New-Eintrag 'Dateiversionsverlauf' $false $false) (New-Eintrag 'OneDrive-Ordnersicherung' $false $false) (New-Eintrag 'Systemabbild' $false $false)

    It 'nichts vorhanden: WARN mit Akzeptanzlisten-Satz' {
        $r = Get-MorpheusSicherungBewertung -Eintraege $nichts -Jetzt $script:Jetzt
        $r.status | Should Be 'WARN'
        $r.empfehlung | Should Match 'Sicherst du mit einem anderen Programm oder auf ein NAS, trag den Befund in die Akzeptanzliste \(accepted\.psd1\) ein\.$'
        $r.empfehlung | Should Match 'Dateiversionsverlauf'
        $r.empfehlung | Should Match 'OneDrive'
        $r.wert | Should Be 'Dateiversionsverlauf aus; OneDrive: keine Ordner gesichert; kein Systemabbild'
    }
    It 'Dateiversionsverlauf aktiv und aktuell: OK' {
        $s = New-Satz (New-Eintrag 'Dateiversionsverlauf' $true $true (Iso 3)) (New-Eintrag 'OneDrive-Ordnersicherung' $false $false) (New-Eintrag 'Systemabbild' $false $false)
        $r = Get-MorpheusSicherungBewertung -Eintraege $s -Jetzt $script:Jetzt
        $r.status | Should Be 'OK'
        $r.empfehlung | Should Be ''
        $r.wert | Should Match '^Dateiversionsverlauf aktiv'
    }
    It 'Dateiversionsverlauf aktiv, aber 40 Tage alt: WARN' {
        $s = New-Satz (New-Eintrag 'Dateiversionsverlauf' $true $true (Iso 40)) (New-Eintrag 'OneDrive-Ordnersicherung' $false $false) (New-Eintrag 'Systemabbild' $false $false)
        $r = Get-MorpheusSicherungBewertung -Eintraege $s -Jetzt $script:Jetzt
        $r.status | Should Be 'WARN'
        $r.wert | Should Match 'veraltet'
    }
    It 'Dateiversionsverlauf aktiv ohne bekannten Zeitpunkt: OK' {
        $s = New-Satz (New-Eintrag 'Dateiversionsverlauf' $true $true $null) (New-Eintrag 'OneDrive-Ordnersicherung' $false $false) (New-Eintrag 'Systemabbild' $false $false)
        (Get-MorpheusSicherungBewertung -Eintraege $s -Jetzt $script:Jetzt).status | Should Be 'OK'
    }
    It 'nur OneDrive mit Ordnern: OK mit Hinweis zur Cloud-Synchronisation' {
        $s = New-Satz (New-Eintrag 'Dateiversionsverlauf' $false $false) (New-Eintrag 'OneDrive-Ordnersicherung' $true $true $null @('Desktop', 'Dokumente')) (New-Eintrag 'Systemabbild' $false $false)
        $r = Get-MorpheusSicherungBewertung -Eintraege $s -Jetzt $script:Jetzt
        $r.status | Should Be 'OK'
        $r.wert | Should Be 'Dateiversionsverlauf aus; OneDrive: Desktop, Dokumente; kein Systemabbild'
        $r.empfehlung | Should Match 'Ransomware'
    }
    It 'OneDrive gefunden, aber keine Ordner gesichert: WARN' {
        $s = New-Satz (New-Eintrag 'Dateiversionsverlauf' $false $false) (New-Eintrag 'OneDrive-Ordnersicherung' $true $false) (New-Eintrag 'Systemabbild' $false $false)
        (Get-MorpheusSicherungBewertung -Eintraege $s -Jetzt $script:Jetzt).status | Should Be 'WARN'
    }
    It 'Systemabbild 100 Tage alt: OK' {
        $s = New-Satz (New-Eintrag 'Dateiversionsverlauf' $false $false) (New-Eintrag 'OneDrive-Ordnersicherung' $false $false) (New-Eintrag 'Systemabbild' $true $true (Iso 100))
        $r = Get-MorpheusSicherungBewertung -Eintraege $s -Jetzt $script:Jetzt
        $r.status | Should Be 'OK'
        $r.wert | Should Match 'Systemabbild vom 17\.07\.2026'
    }
    It 'Systemabbild 200 Tage alt: WARN' {
        $s = New-Satz (New-Eintrag 'Dateiversionsverlauf' $false $false) (New-Eintrag 'OneDrive-Ordnersicherung' $false $false) (New-Eintrag 'Systemabbild' $true $false (Iso 200))
        $r = Get-MorpheusSicherungBewertung -Eintraege $s -Jetzt $script:Jetzt
        $r.status | Should Be 'WARN'
        $r.wert | Should Match 'Systemabbild veraltet'
    }
    It 'Fehler-Eintraege (nicht lesbar) ergeben WARN' {
        $r = Get-MorpheusSicherungBewertung -Eintraege (New-Satz (New-Eintrag 'Dateiversionsverlauf' $false $false) $null $null) -Jetzt $script:Jetzt
        $r.status | Should Be 'WARN'
    }
}

Describe 'Get-MorpheusDateiversionsverlauf' {
    It 'Ordner fehlt: nicht gefunden' {
        $r = Get-MorpheusDateiversionsverlauf -ConfigOrdner (Join-Path $TestDrive 'gibtesnicht') -RegistryPfad $script:KeinReg
        $r.art | Should Be 'Dateiversionsverlauf'
        $r.gefunden | Should Be $false
        $r.aktiv | Should Be $false
        $r.letzteSicherung | Should BeNullOrEmpty
    }
    It 'Fixture aktiv: Ziel, aktiv, Zeitpunkt aus Konfigurationsdatei' {
        $r = Get-MorpheusDateiversionsverlauf -ConfigOrdner (Join-Path $script:Fixtures 'aktiv') -RegistryPfad $script:KeinReg
        $r.gefunden | Should Be $true
        $r.aktiv | Should Be $true
        $r.ziel | Should Be 'E:\'
        $r.letzteSicherung | Should Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
    }
    It 'Fixture ohne Ziel und Enabled=false: gefunden, nicht aktiv' {
        $r = Get-MorpheusDateiversionsverlauf -ConfigOrdner (Join-Path $script:Fixtures 'ohneziel') -RegistryPfad $script:KeinReg
        $r.gefunden | Should Be $true
        $r.aktiv | Should Be $false
        $r.ziel | Should BeNullOrEmpty
    }
    It 'Ziel ohne erkennbares An/Aus: aktiv mit Unsicherheits-Hinweis' {
        $d = Join-Path $TestDrive 'unklar'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'Config2.xml') -Value '<Root xmlns="urn:x"><TargetUrl>\\nas\sicherung</TargetUrl></Root>' -Encoding UTF8
        $r = Get-MorpheusDateiversionsverlauf -ConfigOrdner $d -RegistryPfad $script:KeinReg
        $r.aktiv | Should Be $true
        $r.ziel | Should Be '\\nas\sicherung'
        $r.hinweis | Should Match 'nicht sicher'
    }
    It 'kaputtes XML: nicht abstürzen, nicht gefunden' {
        $d = Join-Path $TestDrive 'kaputt'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'Config1.xml') -Value '<<<nicht xml' -Encoding UTF8
        $r = Get-MorpheusDateiversionsverlauf -ConfigOrdner $d -RegistryPfad $script:KeinReg
        $r.aktiv | Should Be $false
        $r.hinweis | Should Match 'Nicht lesbar'
    }
}

Describe 'OneDrive-Pfadlogik' {
    $konten = @([pscustomobject]@{ Name = 'Personal'; UserFolder = 'C:\Users\Demo\OneDrive' })
    It 'Desktop und Dokumente in OneDrive, Bilder nicht' {
        $shell = @{ Desktop = 'C:\Users\Demo\OneDrive\Desktop'; Dokumente = 'c:\users\demo\onedrive\Dokumente'; Bilder = 'C:\Users\Demo\Pictures' }
        $r = PcCheckSicherungOneDriveAuswahl -Konten $konten -ShellOrdner $shell
        ($r.ordner -join ',') | Should Be 'Desktop,Dokumente'
        ($r.konten -join ',') | Should Be 'Personal'
    }
    It 'Ordner mit gleichem Namensanfang zählt nicht (OneDrive-Alt)' {
        $shell = @{ Desktop = 'C:\Users\Demo\OneDrive-Alt\Desktop' }
        @((PcCheckSicherungOneDriveAuswahl -Konten $konten -ShellOrdner $shell).ordner).Count | Should Be 0
    }
    It 'kein Konto: nichts gesichert' {
        @((PcCheckSicherungOneDriveAuswahl -Konten @() -ShellOrdner @{ Desktop = 'C:\x' }).ordner).Count | Should Be 0
    }
    It 'zwei Konten' {
        $k2 = @($konten[0], [pscustomobject]@{ Name = 'Business1'; UserFolder = 'C:\Users\Demo\OneDrive - Firma' })
        $shell = @{ Desktop = 'C:\Users\Demo\OneDrive\Desktop'; Bilder = 'C:\Users\Demo\OneDrive - Firma\Bilder' }
        $r = PcCheckSicherungOneDriveAuswahl -Konten $k2 -ShellOrdner $shell
        ($r.ordner -join ',') | Should Be 'Desktop,Bilder'
        ($r.konten -join ',') | Should Be 'Personal,Business1'
    }
}

Describe 'Get-MorpheusSystemabbild' {
    It 'ohne Sicherung: nicht gefunden' {
        $wurzel = Join-Path $TestDrive 'leer'
        New-Item -ItemType Directory -Path $wurzel -Force | Out-Null
        $r = Get-MorpheusSystemabbild -Laufwerke @($wurzel)
        $r.art | Should Be 'Systemabbild'
        $r.gefunden | Should Be $false
        $r.aktiv | Should Be $false
    }
    It 'frische Sicherung: aktiv' {
        $wurzel = Join-Path $TestDrive 'frisch'
        New-Item -ItemType Directory -Path (Join-Path $wurzel 'WindowsImageBackup\PC1') -Force | Out-Null
        $r = Get-MorpheusSystemabbild -Laufwerke @($wurzel)
        $r.gefunden | Should Be $true
        $r.aktiv | Should Be $true
        $r.letzteSicherung | Should Match '^\d{4}-\d{2}-\d{2}T'
    }
    It 'Sicherung älter als 180 Tage: veraltet, nicht aktiv' {
        $wurzel = Join-Path $TestDrive 'alt'
        $u = Join-Path $wurzel 'WindowsImageBackup\PC1'
        New-Item -ItemType Directory -Path $u -Force | Out-Null
        (Get-Item -LiteralPath $u).LastWriteTime = (Get-Date).AddDays(-200)
        $r = Get-MorpheusSystemabbild -Laufwerke @($wurzel)
        $r.gefunden | Should Be $true
        $r.aktiv | Should Be $false
        $r.hinweis | Should Match 'veraltet'
    }
}

Describe 'wbadmin-Ausgabe' {
    It 'liest deutsche und englische Zeitangaben' {
        $z = @('Sicherungszeit: 25.10.2026 14:02', 'Version identifier: x', 'Backup time: 10/20/2026 9:30 AM')
        $t = @(PcCheckSicherungWbadminZeiten -Zeilen $z)
        $t.Count | Should Be 2
        $t[0].Year | Should Be 2026
        $t[0].Month | Should Be 10
        $t[0].Day | Should Be 25
        $t[1].Day | Should Be 20
    }
    It 'ohne Treffer: leeres Array' {
        @(PcCheckSicherungWbadminZeiten -Zeilen @('nichts', '')).Count | Should Be 0
    }
}

Describe 'Get-MorpheusSicherung' {
    It 'liefert drei Objekte mit allen Feldern' {
        $r = @(Get-MorpheusSicherung)
        $r.Count | Should Be 3
        ($r | ForEach-Object { $_.art }) -join '|' | Should Be 'Dateiversionsverlauf|OneDrive-Ordnersicherung|Systemabbild'
        foreach ($e in $r) {
            foreach ($f in 'art', 'gefunden', 'aktiv', 'ziel', 'letzteSicherung', 'hinweis') {
                ($e.PSObject.Properties.Name -contains $f) | Should Be $true
            }
        }
        ($r[1].PSObject.Properties.Name -contains 'ordner') | Should Be $true
    }
}
