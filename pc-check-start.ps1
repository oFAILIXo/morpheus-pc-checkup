<#
.SYNOPSIS
    Startet den Scan (pc-check.ps1) mit Adminrechten aus der sicheren Fassung.
.DESCRIPTION
    Läuft OHNE Adminrechte (aufgerufen von pc-check.cmd) und entscheidet, welche Fassung erhöht gestartet wird:
    - Dieser Ordner ist gesichert (z. B. C:\Program Files\Morpheus): diese Fassung; Berichte und Akzeptanzliste
      liegen in C:\ProgramData\Morpheus (nur für Administratoren lesbar, also in der GUI ansehen).
    - Dieser Ordner ist ungesichert, aber eine aktuelle Installation existiert: die installierte Fassung. So bekommt Code
      aus einem Ordner, den auch Programme ohne Adminrechte ändern können, keine Adminrechte. Berichte landen weiter
      im Unterordner reports\ dieses Ordners.
    - Sonst (keine oder veraltete Installation, z. B. beim Entwickeln): diese Fassung, mit Hinweis.
#>
# Sicherheit (2.3.3): Module nur aus System32 und Program Files laden, nie aus Benutzerordnern (gui\lib\Systempfade.ps1).
# Als erste Anweisung, damit vorher nichts automatisch geladen wird; Kindprozesse und Jobs erben den Wert.
$env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
# Kindprozesse (Jobs, Scan, winget, Windows-Programme): PATH nur Systemordner, keine .NET-Profiler-Variablen aus der
# Benutzerumgebung (HKCU\Environment), über die sich eine DLL in jeden .NET-Prozess laden ließe (2.3.3, N6)
$env:PATH = [Environment]::SystemDirectory + ';' + [Environment]::GetFolderPath('Windows') + ';' + [Environment]::SystemDirectory + '\Wbem;' + [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0'
foreach ($morpheusVar in @([Environment]::GetEnvironmentVariables().Keys)) { if ([string]$morpheusVar -match '^(COR_|CORECLR_|COMPlus_|DOTNET_)') { [Environment]::SetEnvironmentVariable([string]$morpheusVar, $null) } }
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
# Texte (2.6): Sprache aus der gespeicherten Wahl bzw. der Windows-Sprache (Lesen kann ohne Rechte scheitern)
. (Join-Path $Root 'gui\lib\Sprache.ps1')
$env:MORPHEUS_SPRACHE = Get-MorpheusSprache -DataRoot (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Morpheus')
$script = Join-Path $Root 'pc-check.ps1'
$extra = @()
try {
    . (Join-Path $Root 'gui\lib\Install.ps1')
    $inst = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Morpheus'
    $data = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Morpheus'
    if ((Test-MorpheusCodeSecure -Root $Root).Sicher) {
        $extra = @('-OutputDir', ('"{0}"' -f (Join-Path $data 'reports')), '-AcceptedFile', ('"{0}"' -f (Join-Path $data 'accepted.psd1')), '-NoOpen')
        Write-Host (T 'server.start.berichtProgramData') -ForegroundColor Green
    }
    elseif ((Test-MorpheusCodeSecure -Root $inst).Sicher -and (Test-MorpheusInstallCurrent -Source $Root -Target $inst)) {
        $script = Join-Path $inst 'pc-check.ps1'
        $extra = @('-OutputDir', ('"{0}"' -f (Join-Path $Root 'reports')))
        if (Test-Path -LiteralPath (Join-Path $data 'accepted.psd1')) { $extra += @('-AcceptedFile', ('"{0}"' -f (Join-Path $data 'accepted.psd1'))) }
        Write-Host (T 'server.start.installierteFassung' $inst) -ForegroundColor Green
    }
    else {
        Write-Host (T 'server.start.hinweisOrdner') -ForegroundColor Yellow
    }
}
catch { $script = Join-Path $Root 'pc-check.ps1'; $extra = @() }

$argLine = ('-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}" ' -f $script) + ($extra -join ' ')
# Voller Pfad: Ein Programm namens powershell.exe im Arbeitsordner bekäme sonst die Adminabfrage (2.3.3)
$psExe = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\powershell.exe'
try { Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $argLine }
catch { Write-Host (T 'server.start.abgebrochen') -ForegroundColor Yellow; exit 1 }
