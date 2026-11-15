<#
.SYNOPSIS
    CI-Pruefungen (Parser und Kodierung), lokal und im GitHub-Workflow identisch.
.DESCRIPTION
    Prueft alle von Git verfolgten Dateien (git ls-files):
    - .ps1/.psd1 muessen ohne Parserfehler einlesbar sein und mit UTF-8-BOM (EF BB BF) beginnen.
    - .cmd muessen reines ASCII sein und ausschliesslich CRLF-Zeilenenden haben.
    dist/ und .claude/ werden ausgelassen. Aendert nichts. Ausgabe: Verstoesse; Exitcode 1 bei Fehlern.
    Gehoert nicht zur Installation (nur Entwicklung/CI), steht daher nicht in Get-MorpheusCodeFiles.
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $Root
$dateien = @(& git ls-files | Where-Object { $_ -notmatch '^(dist|\.claude)/' })
if ($dateien.Count -eq 0) { Write-Host 'Keine Dateien gefunden (git ls-files leer).'; exit 1 }

$fehler = New-Object System.Collections.Generic.List[string]
$nPs = 0; $nCmd = 0
foreach ($rel in $dateien) {
    $ext = [IO.Path]::GetExtension($rel).ToLowerInvariant()
    if ($ext -ne '.ps1' -and $ext -ne '.psd1' -and $ext -ne '.cmd') { continue }
    $pfad = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $pfad -PathType Leaf)) { continue }
    $bytes = [IO.File]::ReadAllBytes($pfad)
    if ($ext -eq '.cmd') {
        $nCmd++
        $nichtAscii = $false
        foreach ($b in $bytes) { if ($b -gt 127) { $nichtAscii = $true; break } }
        if ($nichtAscii) { $fehler.Add("$rel : .cmd enthaelt Nicht-ASCII-Zeichen") }
        $lf = 0; $crlf = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10) { $lf++; if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ } }
        }
        if ($lf -ne $crlf) { $fehler.Add("$rel : .cmd hat $($lf - $crlf) Zeilenende(n) ohne CR (CRLF erwartet)") }
        continue
    }
    $nPs++
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        $fehler.Add("$rel : UTF-8-BOM fehlt")
    }
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($pfad, [ref]$tokens, [ref]$errs)
    foreach ($e in @($errs)) { $fehler.Add("$rel : Parserfehler Zeile $($e.Extent.StartLineNumber): $($e.Message)") }
}
Write-Host "Geprueft: $nPs .ps1/.psd1, $nCmd .cmd"
if ($fehler.Count -gt 0) {
    $fehler | ForEach-Object { Write-Host "FEHLER $_" }
    Write-Host "$($fehler.Count) Verstoss/Verstoesse."
    exit 1
}
Write-Host 'Alles in Ordnung.'
exit 0
