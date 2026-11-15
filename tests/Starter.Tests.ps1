#Requires -Version 5.1
# Pester-3.4-Tests für die Starter im Hauptordner (*.cmd), Karte #121.
# Rein statisch: Die Starter werden gelesen, nie ausgeführt.
# Ausführen: Invoke-Pester tests\Starter.Tests.ps1

$script:Wurzel = Split-Path -Parent $PSScriptRoot
$script:Starter = @(
    @{ Datei = 'pc-check.cmd'; Ziel = 'pc-check-start.ps1' },
    @{ Datei = 'pc-check-gui.cmd'; Ziel = 'pc-check-gui.ps1' }
)

foreach ($s in $script:Starter) {
    Describe "Starter $($s.Datei)" {
        $pfad = Join-Path $script:Wurzel $s.Datei
        $bytes = [IO.File]::ReadAllBytes($pfad)
        $text = [Text.Encoding]::ASCII.GetString($bytes)

        It 'existiert und ist nicht leer' {
            $bytes.Length | Should BeGreaterThan 100
        }
        It 'ist reines ASCII (kein Byte über 127, kein BOM)' {
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
        }
        It 'hat durchgehend CRLF-Zeilenenden' {
            ([regex]::Matches($text, "(?<!`r)`n")).Count | Should Be 0
            ([regex]::Matches($text, "`r(?!`n)")).Count | Should Be 0
        }
        It 'beginnt mit @echo off' {
            $text | Should Match '^@echo off\r\n'
        }
        It 'ruft das erwartete Skript auf' {
            $text | Should Match ([regex]::Escape($s.Ziel))
            Test-Path -LiteralPath (Join-Path $script:Wurzel $s.Ziel) | Should Be $true
        }
        It 'startet powershell.exe mit vollem System32-Pfad, -NoProfile, -ExecutionPolicy Bypass und -File' {
            $text | Should Match '"%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe" -NoProfile -ExecutionPolicy Bypass -File '
        }
        It 'enthält keinen Aufruf von powershell ohne Pfad und kein -Command, -EncodedCommand oder Download' {
            $zeilen = $text -split "`r`n" | Where-Object { $_ -notmatch '^\s*rem\b' }
            @($zeilen | Where-Object { $_ -match '(?i)(^|[\s&|(])powershell(\.exe)?\s' -and $_ -notmatch '%SystemRoot%' }).Count | Should Be 0
            $text | Should Not Match '(?i)-(Command|EncodedCommand|enc)\b'
            $text | Should Not Match '(?i)(Invoke-WebRequest|iwr |curl |bitsadmin|DownloadString|http://|https://)'
        }
        It 'fragt nicht selbst nach Adminrechten (-Verb RunAs) und setzt keine Systemeinstellung' {
            $text | Should Not Match '(?i)RunAs'
            $text | Should Not Match '(?i)\b(reg add|setx|schtasks|netsh|sc config)\b'
        }
        It 'enthält den Schalter -SafetyLib nicht' {
            $text | Should Not Match '(?i)-SafetyLib'
        }
        It 'prüft vor dem Start, dass das Skript existiert, und meldet Fehler mit pause' {
            $text | Should Match '(?i)if not exist'
            $text | Should Match '(?i)exit /b 1'
            $text | Should Match '(?i)if errorlevel 1'
        }
    }
}

Describe 'Starter: alle *.cmd im Hauptordner sind abgedeckt' {
    It 'es gibt keinen Starter ohne Test' {
        $vorhanden = @(Get-ChildItem -LiteralPath $script:Wurzel -Filter '*.cmd' -File | ForEach-Object Name | Sort-Object)
        $geprueft = @($script:Starter | ForEach-Object { $_.Datei } | Sort-Object)
        ($vorhanden -join ',') | Should Be ($geprueft -join ',')
    }
}
