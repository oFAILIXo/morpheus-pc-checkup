<#
.SYNOPSIS
  Erzeugt gui\palettes.css aus den Palettendaten unten und prüft alle Farbpaare auf WCAG AA (2.7, #100).

.DESCRIPTION
  Eine Quelle für alle Paletten: je Palette ein Satz 'dark' und 'light' mit denselben Rollen.
  Ausgabe je Palette drei Blöcke wie im Cheat Sheet (hell, dunkel explizit, dunkel per System).
  Die Seitenleiste bekommt in jedem Modus den dunklen Satz der Palette (Logo ist helle Schrift).
  Prüfung: Text >= 4.5:1 (Fehler); Punkte, Linien, Fokus >= 3:1 (Hinweis: Status steht immer auch als Wort da);
  Schweregrade Kritisch/Warnung/Tipp/OK mit OKLab-Abstand >= 0.045 (mindestens so deutlich wie Solarized dunkel).
  Exit 1 bei Fehlern. Nur lesend außer gui\palettes.css (mit -NurPruefen auch das nicht).

.EXAMPLE
  powershell -NoProfile -File gui\dev\make-palettes.ps1
  powershell -NoProfile -File gui\dev\make-palettes.ps1 -NurPruefen -Alle
#>
param([switch]$NurPruefen, [switch]$Alle, [string]$Ziel)   # -Ziel: andere Ausgabedatei (Test vergleicht damit)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# ------------------------------------------------------------------ Rollen (Reihenfolge = Reihenfolge im CSS)
$Rollen = @(
    'yellow', 'orange', 'red', 'magenta', 'violet', 'blue', 'cyan', 'green', 'grey', 'cyan-hover',
    'bg', 'surface', 'surface2', 'well', 'sidebar-1', 'sidebar-2', 'status-bg',
    'th-bg', 'row-hover', 'code-bg', 'code-head', 'code-fg', 'btn-brand', 'btn-brand-hover', 'scrim',
    'ink', 'line', 'line2', 'hover', 'bd1', 'bd2', 'bd3', 'topbar-a',
    'fg', 'fg-strong', 'fg-max', 'fg-soft', 'muted', 'on-fill', 'tip-bg', 'tip-fg', 'tip-strong',
    't-orange', 't-magenta', 't-green', 't-blue', 't-cyan', 't-red', 't-yellow', 't-violet',
    'accent', 'accent-soft')

$Lw = @{ 'code-head' = '#0000000f'; ink = '#000'; line = '#00000017'; line2 = '#00000029'; hover = '#0000000a'; bd1 = '90%'; bd2 = '95%'; bd3 = '98%'; 'topbar-a' = '84%' }
$Dw = @{ 'code-head' = '#00000026'; ink = '#fff'; line = '#ffffff10'; line2 = '#ffffff1c'; hover = '#ffffff08'; bd1 = '69.02%'; bd2 = '85.1%'; bd3 = '96.08%'; 'topbar-a' = '72.16%' }

function Satz([hashtable]$Basis, [hashtable]$Werte) { $h = @{}; foreach ($k in $Basis.Keys) { $h[$k] = $Basis[$k] }; foreach ($k in $Werte.Keys) { $h[$k] = $Werte[$k] }; $h }

# ------------------------------------------------------------------ Paletten
$Paletten = [ordered]@{
    solarized = @{
        name  = 'Solarized'
        # Petrol: Flächen wie bis 2.7; fg, muted, t-red, t-magenta, t-orange für AA leicht aufgehellt (07.11.2026)
        dark  = Satz $Dw @{
            yellow = '#b58900'; orange = '#cb4b16'; red = '#dc322f'; magenta = '#d33682'; violet = '#6c71c4'; blue = '#268bd2'; cyan = '#2aa198'; green = '#859900'; grey = '#586e75'; 'cyan-hover' = '#33b5ab'
            bg = '#00222b'; surface = '#073642'; surface2 = '#0a3d4a'; well = '#002b36'; 'sidebar-1' = '#05303b'; 'sidebar-2' = '#032833'; 'status-bg' = '#001e26'
            'th-bg' = '#0a3f4b'; 'row-hover' = '#0b4150'; 'code-bg' = '#001a21'; 'code-fg' = '#a6b9b9'; 'btn-brand' = '#06303a'; 'btn-brand-hover' = '#0b3944'; scrim = '#001319b3'
            fg = '#a0aeae'; 'fg-strong' = '#eee8d5'; 'fg-max' = '#fdf6e3'; 'fg-soft' = '#a3b2b2'; muted = '#98a9ae'; 'on-fill' = '#00242d'; 'tip-bg' = '#eee8d5'; 'tip-fg' = '#002b36'; 'tip-strong' = '#073642'
            't-orange' = '#f48c62'; 't-magenta' = '#f185b9'; 't-green' = '#a8bd2e'; 't-blue' = '#5ab0f0'; 't-cyan' = '#4fcfc2'; 't-red' = '#f78583'; 't-yellow' = '#e0b23a'; 't-violet' = '#9a9ee0'
            accent = '#cb4b16'; 'accent-soft' = '#cb4b1666'
        }
        light = Satz $Lw @{
            yellow = '#a07a00'; orange = '#cb4b16'; red = '#dc322f'; magenta = '#d33682'; violet = '#6c71c4'; blue = '#268bd2'; cyan = '#24968d'; green = '#6f8000'; grey = '#7d8d91'; 'cyan-hover' = '#2aa198'
            bg = '#f3ecd7'; surface = '#fdf6e3'; surface2 = '#f5eedb'; well = '#fffbf0'; 'sidebar-1' = '#05303b'; 'sidebar-2' = '#032833'; 'status-bg' = '#efe8d2'
            'th-bg' = '#ece5cf'; 'row-hover' = '#ebe3cc'; 'code-bg' = '#f3edda'; 'code-fg' = '#073642'; 'btn-brand' = '#fffaee'; 'btn-brand-hover' = '#f8eedb'; scrim = '#0736428c'
            fg = '#3d5259'; 'fg-strong' = '#073642'; 'fg-max' = '#002b36'; 'fg-soft' = '#46595f'; muted = '#475d64'; 'on-fill' = '#00242d'; 'tip-bg' = '#073642'; 'tip-fg' = '#eee8d5'; 'tip-strong' = '#fdf6e3'
            't-orange' = '#a63c0e'; 't-magenta' = '#a8256a'; 't-green' = '#566300'; 't-blue' = '#17629a'; 't-cyan' = '#0f6c66'; 't-red' = '#b0221f'; 't-yellow' = '#795b00'; 't-violet' = '#4d529f'
            accent = '#cb4b16'; 'accent-soft' = '#cb4b1655'
        }
    }
    gruvbox   = @{
        name  = 'Gruvbox'
        dark  = Satz $Dw @{
            yellow = '#d79921'; orange = '#d65d0e'; red = '#cc241d'; magenta = '#b16286'; violet = '#7c6fb0'; blue = '#458588'; cyan = '#689d6a'; green = '#98971a'; grey = '#7c6f64'; 'cyan-hover' = '#79ae7b'
            bg = '#1d2021'; surface = '#282828'; surface2 = '#32302f'; well = '#1f1f1f'; 'sidebar-1' = '#2a2827'; 'sidebar-2' = '#211f1e'; 'status-bg' = '#191b1c'
            'th-bg' = '#3a3633'; 'row-hover' = '#433e3a'; 'code-bg' = '#171919'; 'code-fg' = '#d5c4a1'; 'btn-brand' = '#2a2420'; 'btn-brand-hover' = '#382b22'; scrim = '#0d0e0eb3'
            fg = '#d5c4a1'; 'fg-strong' = '#ebdbb2'; 'fg-max' = '#fbf1c7'; 'fg-soft' = '#c9b99a'; muted = '#a89984'; 'on-fill' = '#1d2021'; 'tip-bg' = '#ebdbb2'; 'tip-fg' = '#282828'; 'tip-strong' = '#1d2021'
            't-orange' = '#fe8a2c'; 't-magenta' = '#de95a8'; 't-green' = '#b8bb26'; 't-blue' = '#93b5a8'; 't-cyan' = '#8ec07c'; 't-red' = '#ff7a69'; 't-yellow' = '#fabd2f'; 't-violet' = '#b3a7de'
            accent = '#d65d0e'; 'accent-soft' = '#d65d0e66'
        }
        light = Satz $Lw @{
            yellow = '#b57614'; orange = '#d65d0e'; red = '#cc241d'; magenta = '#b16286'; violet = '#6f62a6'; blue = '#458588'; cyan = '#3c7351'; green = '#79740e'; grey = '#928374'; 'cyan-hover' = '#33664a'
            bg = '#f2e5bc'; surface = '#fbf1c7'; surface2 = '#f4e8c0'; well = '#fdf6d8'; 'sidebar-1' = '#2a2827'; 'sidebar-2' = '#211f1e'; 'status-bg' = '#eee0b4'
            'th-bg' = '#ebdbb2'; 'row-hover' = '#e9dab0'; 'code-bg' = '#f2e6c0'; 'code-fg' = '#3c3836'; 'btn-brand' = '#fdf5d6'; 'btn-brand-hover' = '#f6e8c0'; scrim = '#282828a6'
            fg = '#504945'; 'fg-strong' = '#3c3836'; 'fg-max' = '#282828'; 'fg-soft' = '#554c46'; muted = '#5a514b'; 'on-fill' = '#fbf1c7'; 'tip-bg' = '#3c3836'; 'tip-fg' = '#ebdbb2'; 'tip-strong' = '#fbf1c7'
            't-orange' = '#9a3403'; 't-magenta' = '#87396b'; 't-green' = '#626008'; 't-blue' = '#076678'; 't-cyan' = '#2f5f42'; 't-red' = '#9d0006'; 't-yellow' = '#7f5207'; 't-violet' = '#58498e'
            accent = '#d65d0e'; 'accent-soft' = '#d65d0e55'
        }
    }
    oblivion  = @{
        name  = 'Oblivion'
        dark  = Satz $Dw @{
            yellow = '#c4a000'; orange = '#ce5c00'; red = '#ef2929'; magenta = '#b56aab'; violet = '#7d74c4'; blue = '#4f82c4'; cyan = '#16a3a5'; green = '#4e9a06'; grey = '#80867f'; 'cyan-hover' = '#26b4b6'
            bg = '#25292b'; surface = '#2e3436'; surface2 = '#363d40'; well = '#222628'; 'sidebar-1' = '#30373a'; 'sidebar-2' = '#272c2e'; 'status-bg' = '#1f2325'
            'th-bg' = '#3c4447'; 'row-hover' = '#454e51'; 'code-bg' = '#1d2123'; 'code-fg' = '#d3d7cf'; 'btn-brand' = '#2f2b28'; 'btn-brand-hover' = '#3d342d'; scrim = '#121516b3'
            fg = '#d3d7cf'; 'fg-strong' = '#eeeeec'; 'fg-max' = '#ffffff'; 'fg-soft' = '#c4c8c0'; muted = '#a9ada5'; 'on-fill' = '#1d2123'; 'tip-bg' = '#eeeeec'; 'tip-fg' = '#2e3436'; 'tip-strong' = '#1d2123'
            't-orange' = '#fcaf3e'; 't-magenta' = '#d6a3cf'; 't-green' = '#8ae234'; 't-blue' = '#8db8e8'; 't-cyan' = '#5fd8da'; 't-red' = '#ff8a8a'; 't-yellow' = '#fce94f'; 't-violet' = '#b4adeb'
            accent = '#f57900'; 'accent-soft' = '#f5790066'
        }
        light = Satz $Lw @{
            yellow = '#a68800'; orange = '#ce5c00'; red = '#cc0000'; magenta = '#8a4f83'; violet = '#5c55a0'; blue = '#3465a4'; cyan = '#0b7f81'; green = '#4e9a06'; grey = '#7d817a'; 'cyan-hover' = '#086f71'
            bg = '#e6e7e3'; surface = '#f7f7f5'; surface2 = '#eeeeec'; well = '#fbfbfa'; 'sidebar-1' = '#30373a'; 'sidebar-2' = '#272c2e'; 'status-bg' = '#ebebe8'
            'th-bg' = '#e3e5e0'; 'row-hover' = '#dadcd6'; 'code-bg' = '#efefec'; 'code-fg' = '#2e3436'; 'btn-brand' = '#fbfaf8'; 'btn-brand-hover' = '#f2efea'; scrim = '#2e3436a6'
            fg = '#3a4143'; 'fg-strong' = '#2e3436'; 'fg-max' = '#1b1f20'; 'fg-soft' = '#464c4e'; muted = '#4c4e4a'; 'on-fill' = '#ffffff'; 'tip-bg' = '#2e3436'; 'tip-fg' = '#eeeeec'; 'tip-strong' = '#ffffff'
            't-orange' = '#9a4500'; 't-magenta' = '#6e3d68'; 't-green' = '#336205'; 't-blue' = '#204a87'; 't-cyan' = '#06676a'; 't-red' = '#a40000'; 't-yellow' = '#6f5c00'; 't-violet' = '#4a438a'
            accent = '#ce5c00'; 'accent-soft' = '#ce5c0055'
        }
    }
    sandstone = @{
        name  = 'Sandstone'
        dark  = Satz $Dw @{
            yellow = '#b8902a'; orange = '#c86a28'; red = '#c0503a'; magenta = '#a85a7a'; violet = '#7a6aa8'; blue = '#5a82a0'; cyan = '#4f9a8c'; green = '#6f8a3a'; grey = '#7a7064'; 'cyan-hover' = '#5eab9c'
            bg = '#221f1c'; surface = '#2a2623'; surface2 = '#332e2a'; well = '#1e1b19'; 'sidebar-1' = '#2d2825'; 'sidebar-2' = '#24201d'; 'status-bg' = '#1c1917'
            'th-bg' = '#3a3430'; 'row-hover' = '#443d38'; 'code-bg' = '#1a1816'; 'code-fg' = '#e0d6c8'; 'btn-brand' = '#2e2520'; 'btn-brand-hover' = '#3c2e25'; scrim = '#110f0db3'
            fg = '#d6ccbe'; 'fg-strong' = '#e8dfd2'; 'fg-max' = '#f7f0e6'; 'fg-soft' = '#c9bdad'; muted = '#ada292'; 'on-fill' = '#1a1816'; 'tip-bg' = '#e8dfd2'; 'tip-fg' = '#2a2623'; 'tip-strong' = '#1a1816'
            't-orange' = '#f0a060'; 't-magenta' = '#de9fb9'; 't-green' = '#b5c070'; 't-blue' = '#9cc0dc'; 't-cyan' = '#8fd0c0'; 't-red' = '#f28c78'; 't-yellow' = '#e6c060'; 't-violet' = '#b8acde'
            accent = '#e07a32'; 'accent-soft' = '#e07a3266'
        }
        light = Satz $Lw @{
            yellow = '#9a7412'; orange = '#b35a14'; red = '#b8432c'; magenta = '#94466a'; violet = '#61559a'; blue = '#3f6a8a'; cyan = '#2c7a6d'; green = '#5f7a2a'; grey = '#8a7f72'; 'cyan-hover' = '#246a5e'
            bg = '#e9e1d3'; surface = '#f8f4ec'; surface2 = '#f0eadf'; well = '#fcfaf5'; 'sidebar-1' = '#2d2825'; 'sidebar-2' = '#24201d'; 'status-bg' = '#ece5d8'
            'th-bg' = '#e6dccb'; 'row-hover' = '#ddd2bf'; 'code-bg' = '#f2ece2'; 'code-fg' = '#2f2a26'; 'btn-brand' = '#fcf9f4'; 'btn-brand-hover' = '#f3ece0'; scrim = '#2a2623a6'
            fg = '#3f3934'; 'fg-strong' = '#2f2a26'; 'fg-max' = '#1f1b18'; 'fg-soft' = '#4c443d'; muted = '#544c43'; 'on-fill' = '#ffffff'; 'tip-bg' = '#2f2a26'; 'tip-fg' = '#efe8dc'; 'tip-strong' = '#ffffff'
            't-orange' = '#8c4308'; 't-magenta' = '#7a3656'; 't-green' = '#4a6120'; 't-blue' = '#305670'; 't-cyan' = '#22665b'; 't-red' = '#94301d'; 't-yellow' = '#6e5208'; 't-violet' = '#4c4282'
            accent = '#a94a08'; 'accent-soft' = '#a94a0855'
        }
    }
}

# ------------------------------------------------------------------ Farbrechnung
function RGBA([string]$hex) {
    $h = $hex.TrimStart('#')
    if ($h.Length -in 3, 4) { $h = -join ($h.ToCharArray() | ForEach-Object { "$_$_" }) }
    $a = 1.0; if ($h.Length -eq 8) { $a = [Convert]::ToInt32($h.Substring(6, 2), 16) / 255 }
    @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16), $a)
}
# Farbe mit Deckkraft p (0..1, multipliziert mit eigener Alpha) über deckenden Grund legen
function Over($fg, $bg, [double]$p = 1) { $f = RGBA $fg; $b = RGBA $bg; $a = $f[3] * $p; '#{0:x2}{1:x2}{2:x2}' -f [int][Math]::Round($f[0] * $a + $b[0] * (1 - $a)), [int][Math]::Round($f[1] * $a + $b[1] * (1 - $a)), [int][Math]::Round($f[2] * $a + $b[2] * (1 - $a)) }
function Lin([double]$c) { $c = $c / 255; if ($c -le 0.04045) { $c / 12.92 } else { [Math]::Pow(($c + 0.055) / 1.055, 2.4) } }
function Lum($hex) { $c = RGBA $hex; 0.2126 * (Lin $c[0]) + 0.7152 * (Lin $c[1]) + 0.0722 * (Lin $c[2]) }
function Ratio($a, $b) { $x = Lum $a; $y = Lum $b; [Math]::Round(([Math]::Max($x, $y) + 0.05) / ([Math]::Min($x, $y) + 0.05), 2) }
function OkLab($hex) {
    $c = RGBA $hex; $r = Lin $c[0]; $g = Lin $c[1]; $b = Lin $c[2]
    $l = [Math]::Pow(0.4122214708 * $r + 0.5363325363 * $g + 0.0514459929 * $b, 1 / 3)
    $m = [Math]::Pow(0.2119034982 * $r + 0.6806995451 * $g + 0.1073969566 * $b, 1 / 3)
    $s = [Math]::Pow(0.0883024619 * $r + 0.2817188376 * $g + 0.6299787005 * $b, 1 / 3)
    @((0.2104542553 * $l + 0.7936177850 * $m - 0.0040720468 * $s), (1.9779984951 * $l - 2.4285922050 * $m + 0.4505937099 * $s), (0.0259040371 * $l + 0.7827717662 * $m - 0.8086757660 * $s))
}
function DeltaE($a, $b) { $x = OkLab $a; $y = OkLab $b; [Math]::Round([Math]::Sqrt([Math]::Pow($x[0] - $y[0], 2) + [Math]::Pow($x[1] - $y[1], 2) + [Math]::Pow($x[2] - $y[2], 2)), 3) }
function Pct([string]$p) { [double]($p.TrimEnd('%')) / 100 }

# ------------------------------------------------------------------ Prüfung
$Fehler = 0; $Zeilen = New-Object System.Collections.Generic.List[object]
function Pruefe($pal, $modus, $was, $vg, $hg, [double]$min, [string]$Art = 'Fehler') {
    $r = Ratio $vg $hg; $ok = $r -ge $min
    if ((-not $ok) -and ($Art -eq 'Fehler')) { $script:Fehler++ }
    $script:Zeilen.Add([pscustomobject]@{ Palette = $pal; Modus = $modus; Art = $Art; Paar = $was; Vorne = $vg; Grund = $hg; Ratio = $r; Min = $min; OK = $ok })
}
$Stufen = @('red', 'orange', 'magenta', 'green')   # Kritisch, Warnung, Tipp, OK
$Signale = @('yellow', 'orange', 'red', 'magenta', 'violet', 'blue', 'cyan', 'green')
foreach ($pk in $Paletten.Keys) {
    foreach ($modus in 'dark', 'light') {
        $c = $Paletten[$pk][$modus]
        foreach ($r in $Rollen) { if (-not $c.ContainsKey($r)) { Write-Host "FEHLT: $pk/$modus --$r" -ForegroundColor Red; $Fehler++ } }
        $P = { param($a, $b, $m, $was, $art = 'Fehler') Pruefe $pk $modus $was $a $b $m $art }
        foreach ($g in 'bg', 'surface') { foreach ($t in 'fg', 'fg-strong', 'fg-max', 'muted', 'fg-soft') { & $P $c[$t] $c[$g] 4.5 "$t auf $g" } }
        foreach ($t in 'fg', 'fg-strong', 'fg-max', 'muted') { & $P $c[$t] $c.surface2 4.5 "$t auf surface2" }
        foreach ($g in 'well', 'th-bg', 'row-hover', 'status-bg') { & $P $c.fg $c[$g] 4.5 "fg auf $g" }
        foreach ($g in 'well', 'status-bg') { & $P $c.muted $c[$g] 4.5 "muted auf $g" }
        & $P $c['fg-strong'] $c['row-hover'] 4.5 'fg-strong auf row-hover'
        & $P $c['fg-soft'] (Over $c.ink $c.surface 0.051) 4.5 'fg-soft auf Zähler'
        & $P $c['code-fg'] $c['code-bg'] 4.5 'code-fg auf code-bg'
        & $P $c.muted (Over $c['code-head'] $c['code-bg']) 4.5 'muted auf Code-Kopf'
        & $P $c['tip-fg'] $c['tip-bg'] 4.5 'tip-fg auf tip-bg'
        & $P $c['tip-strong'] $c['tip-bg'] 4.5 'tip-strong auf tip-bg'
        & $P $c['on-fill'] $c.cyan 4.5 'on-fill auf cyan (Primärknopf)'
        & $P $c['on-fill'] $c['cyan-hover'] 4.5 'on-fill auf cyan-hover'
        & $P $c['on-fill'] $c.green 3 'on-fill auf green (Symbol)'
        & $P $c['on-fill'] $c.red 3 'on-fill auf red (Symbol)'
        foreach ($g in 'btn-brand', 'btn-brand-hover') { & $P $c['fg-max'] $c[$g] 4.5 "fg-max auf $g" }
        & $P $c.fg (Over $c.yellow $c.bg 0.102) 4.5 'fg auf Banner gelb'
        # Seitentitel über dem Hintergrundbild: schlimmster Fall Schleier oben über Schwarz (hell) bzw. Weiß-Anteil 25 % (dunkel)
        $bild = if ($modus -eq 'light') { '#000000' } else { '#404040' }
        $ueberBild = Over $c.bg $bild (Pct $c.bd1)
        foreach ($t in 'fg-max', 'fg', 'muted') { & $P $c[$t] $ueberBild 4.5 "$t über Bild (oben)" }
        foreach ($s in $Signale) {
            $t = $c["t-$s"]
            & $P $t $c.surface 4.5 "t-$s auf surface"
            & $P $t $c.bg 4.5 "t-$s auf bg"
            & $P $t (Over $c[$s] $c.surface 0.1333) 4.5 "t-$s auf Tönung (surface)"
            & $P $t $c.surface2 4.5 "t-$s auf surface2"
            & $P $t (Over $c[$s] $c.bg 0.102) 4.5 "t-$s auf Banner"
            & $P $c[$s] $c.surface 3 "$s auf surface (Nicht-Text)" Hinweis
        }
        & $P $c.grey $c.surface 3 'grey auf surface (Nicht-Text)' Hinweis
        & $P $c.cyan $c.bg 3 'cyan auf bg (Fokus)' Hinweis
        & $P $c.accent $c.surface 3 'accent auf surface (Linie)' Hinweis
        # Seitenleiste: im Hellmodus gilt der dunkle Satz der Palette
        if ($modus -eq 'dark') {
            foreach ($g in 'sidebar-1', 'sidebar-2') { foreach ($t in 'fg', 'muted', 'fg-max') { & $P $c[$t] $c[$g] 4.5 "$t auf $g" } }
            & $P $c['fg-max'] (Over $c.ink $c['sidebar-1'] 0.0706) 4.5 'fg-max auf aktivem Menüpunkt'
            foreach ($s in 'red', 'orange', 'magenta', 'blue') { & $P $c["t-$s"] (Over $c[$s] $c['sidebar-1'] 0.18) 4.5 "t-$s auf Menü-Zähler" }
            & $P $c.accent $c['sidebar-1'] 3 'accent auf sidebar-1' Hinweis
        }
        # Schweregrade unterscheidbar (OKLab-Abstand der Texttöne und der Signaltöne)
        for ($i = 0; $i -lt $Stufen.Count; $i++) { for ($j = $i + 1; $j -lt $Stufen.Count; $j++) {
                $a = $Stufen[$i]; $b = $Stufen[$j]
                foreach ($pre in '', 't-') {
                    $d = DeltaE $c["$pre$a"] $c["$pre$b"]; $ok = $d -ge 0.045
                    if (-not $ok) { $Fehler++ }
                    $Zeilen.Add([pscustomobject]@{ Palette = $pk; Modus = $modus; Art = 'Fehler'; Paar = "Abstand $pre$a/$pre$b"; Vorne = $c["$pre$a"]; Grund = $c["$pre$b"]; Ratio = $d; Min = 0.045; OK = $ok })
                }
            } }
    }
}

$zeig = if ($Alle) { $Zeilen } else { $Zeilen | Where-Object { -not $_.OK } }
if ($zeig) { $zeig | Format-Table -AutoSize | Out-String -Width 200 | Write-Host }
$n = $Zeilen.Count
Write-Host ("{0} Varianten, {1} Prüfungen, {2} Fehler" -f ($Paletten.Count * 2), $n, $Fehler)

# ------------------------------------------------------------------ CSS schreiben
if (-not $NurPruefen) {
    function Block([string]$sel, [hashtable]$c, [string]$schema, [string]$ein = '') {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("$ein$sel{`n$ein  color-scheme:$schema;`n$ein ")
        $i = 0
        foreach ($r in $Rollen) { [void]$sb.Append(" --${r}:$($c[$r]);"); $i++; if ($i % 8 -eq 0) { [void]$sb.Append("`n$ein ") } }
        [void]$sb.Append("`n$ein}`n"); $sb.ToString()
    }
    $css = New-Object System.Text.StringBuilder
    [void]$css.Append("/* Farbpaletten (2.7, #100). ERZEUGT von gui/dev/make-palettes.ps1 - nicht von Hand ändern.`n")
    [void]$css.Append("   data-palette auf <html> wählt die Palette, data-theme='light'|'dark' den Modus; ohne data-theme folgt der Modus dem System.`n")
    [void]$css.Append("   Die Seitenleiste nutzt in jedem Modus den dunklen Satz der Palette (Logo in heller Schrift). Rückfall ohne Attribut: Solarized dunkel. */`n")
    [void]$css.Append((Block ':root' $Paletten.solarized.dark 'dark'))
    foreach ($pk in $Paletten.Keys) {
        $p = $Paletten[$pk]
        [void]$css.Append("`n/* $($p.name) */`n")
        [void]$css.Append((Block ":root[data-palette=`"$pk`"]" $p.light 'light'))
        [void]$css.Append((Block ":root[data-palette=`"$pk`"][data-theme=`"dark`"],:root[data-palette=`"$pk`"] aside.side" $p.dark 'dark'))
        [void]$css.Append("@media (prefers-color-scheme:dark){`n")
        [void]$css.Append((Block ":root[data-palette=`"$pk`"]:not([data-theme=`"light`"])" $p.dark 'dark' '  '))
        [void]$css.Append("}`n")
    }
    # Farbmuster der Auswahl in den Einstellungen: zeigen immer die Farben der jeweiligen Palette
    [void]$css.Append("`n/* Farbmuster in den Einstellungen */`n")
    foreach ($pk in $Paletten.Keys) {
        foreach ($modus in 'dark', 'light') {
            $c = $Paletten[$pk][$modus]
            [void]$css.Append(".pal-swatch[data-pal=`"$pk`"][data-mode=`"$modus`"]{--sw-bg:$($c.bg);--sw-surface:$($c.surface);--sw-fg:$($c['fg-strong']);--sw-1:$($c.red);--sw-2:$($c.orange);--sw-3:$($c.magenta);--sw-4:$($c.green);--sw-5:$($c.cyan)}`n")
        }
    }
    $ziel = if ($Ziel) { $Ziel } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'palettes.css' }
    [IO.File]::WriteAllText($ziel, $css.ToString().Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
    Write-Host "geschrieben: $ziel"
}
if ($Fehler) { exit 1 }
