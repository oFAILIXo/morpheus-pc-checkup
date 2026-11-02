# Schreibt die Oberflächentexte für den Mock (gui\dev\mock.html) als texte.de.json und texte.en.json (UTF-8 ohne BOM).
# Aufruf: powershell -NoProfile -ExecutionPolicy Bypass -File gui\dev\make-mock-texte.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'gui\lib\Sprache.ps1')
$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($sp in 'de', 'en') {
    $texte = Get-MorpheusGuiTexte -Sprache $sp -Root $root
    $json = [ordered]@{ sprache = $sp; texte = $texte } | ConvertTo-Json -Depth 4 -Compress
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot "texte.$sp.json"), $json, $utf8)
}
