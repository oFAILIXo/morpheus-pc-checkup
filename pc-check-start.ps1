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
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$script = Join-Path $Root 'pc-check.ps1'
$extra = @()
try {
    . (Join-Path $Root 'gui\lib\Install.ps1')
    $inst = Join-Path $env:ProgramFiles 'Morpheus'
    $data = Join-Path $env:ProgramData 'Morpheus'
    if ((Test-MorpheusCodeSecure -Root $Root).Sicher) {
        $extra = @('-OutputDir', ('"{0}"' -f (Join-Path $data 'reports')), '-AcceptedFile', ('"{0}"' -f (Join-Path $data 'accepted.psd1')), '-NoOpen')
        Write-Host 'Der Bericht wird in C:\ProgramData\Morpheus abgelegt; ansehen in Morpheus unter „Berichte“.' -ForegroundColor Green
    }
    elseif ((Test-MorpheusCodeSecure -Root $inst).Sicher -and (Test-MorpheusInstallCurrent -Source $Root -Target $inst)) {
        $script = Join-Path $inst 'pc-check.ps1'
        $extra = @('-OutputDir', ('"{0}"' -f (Join-Path $Root 'reports')))
        if (Test-Path -LiteralPath (Join-Path $data 'accepted.psd1')) { $extra += @('-AcceptedFile', ('"{0}"' -f (Join-Path $data 'accepted.psd1'))) }
        Write-Host "Starte den Scan aus der installierten Fassung ($inst)." -ForegroundColor Green
    }
    else {
        Write-Host 'Hinweis: Der Scan läuft aus diesem Ordner, den auch Programme ohne Adminrechte ändern können. Sicherer ist es, Morpheus über pc-check-gui.cmd zu installieren.' -ForegroundColor Yellow
    }
}
catch { $script = Join-Path $Root 'pc-check.ps1'; $extra = @() }

$argLine = ('-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}" ' -f $script) + ($extra -join ' ')
try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine }
catch { Write-Host 'Der Start wurde abgebrochen, z. B. weil die Adminabfrage abgelehnt wurde.' -ForegroundColor Yellow; exit 1 }
