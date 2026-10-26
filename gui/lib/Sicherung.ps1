#Requires -Version 5.1
<#
.SYNOPSIS
    Datensicherung erkennen und bewerten (v2.2, #35) für Morpheus – PC Check-up.

.DESCRIPTION
    Wird per Dot-Source geladen (pc-check.ps1). Definiert die Funktionen aus
    docs/gui-architektur.md, Abschnitt 14.3. Alle Funktionen sind rein lesend.
    Beim Dot-Sourcen wird nichts ausgeführt. Keine Compiler-Aufrufe (siehe Vertrag 14.1).
#>

#region Hilfsfunktionen (privat)

function PcCheckSicherungIso {
    param($Date)
    if ($null -eq $Date) { return $null }
    ([datetime]$Date).ToString('s')
}

# Native Programme ohne Fehlerabbruch aufrufen (stderr wird verworfen)
function PcCheckSicherungNative {
    param([string]$Exe, [string[]]$Argumente)
    $alt = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Argumente 2>$null
        return @($out)
    } catch {
        return @()
    } finally {
        $ErrorActionPreference = $alt
    }
}

function PcCheckSicherungNeu {
    param([string]$Art, [bool]$Gefunden = $false, [bool]$Aktiv = $false, $Ziel = $null, $Letzte = $null, [string]$Hinweis = '')
    [ordered]@{
        art             = $Art
        gefunden        = $Gefunden
        aktiv           = $Aktiv
        ziel            = $Ziel
        letzteSicherung = (PcCheckSicherungIso $Letzte)
        hinweis         = $Hinweis
    }
}

function PcCheckSicherungText {
    param($Node)
    if ($null -eq $Node) { return '' }
    ([string]$Node.InnerText).Trim()
}

# Erste nicht leere Textstelle eines Elementnamens (Namespace-tolerant)
function PcCheckSicherungXmlWert {
    param($Doc, [string[]]$Namen)
    foreach ($n in $Namen) {
        $nodes = @($Doc.SelectNodes("//*[local-name()='$n']"))
        foreach ($node in $nodes) {
            $t = PcCheckSicherungText $node
            if ($t -ne '') { return $t }
        }
    }
    return ''
}

function PcCheckSicherungFileTime {
    param([string]$RegistryPfad)
    try {
        if (-not (Test-Path -LiteralPath $RegistryPfad)) { return $null }
        $p = Get-ItemProperty -LiteralPath $RegistryPfad -ErrorAction Stop
        $v = $p.ProtectedUpToTime
        if ($null -eq $v) { return $null }
        if ($v -is [byte[]]) { $v = [BitConverter]::ToInt64($v, 0) }
        $ft = [long]$v
        if ($ft -le 0) { return $null }
        return [DateTime]::FromFileTime($ft)
    } catch { return $null }
}

# Reine Funktion: Zeitpunkte aus der Ausgabe von "wbadmin get versions"
function PcCheckSicherungWbadminZeiten {
    param([string[]]$Zeilen)
    $kulturen = @()
    foreach ($k in @([Globalization.CultureInfo]::CurrentCulture.Name, 'de-DE', 'en-US', 'en-GB')) {
        try { $kulturen += [Globalization.CultureInfo]::GetCultureInfo($k) } catch { }
    }
    $erg = @()
    foreach ($z in @($Zeilen)) {
        if ($z -match '^\s*(Backup time|Sicherungszeit)\s*:\s*(.+?)\s*$') {
            $text = $Matches[2]
            foreach ($c in $kulturen) {
                $d = [datetime]::MinValue
                if ([datetime]::TryParse($text, $c, [Globalization.DateTimeStyles]::None, [ref]$d)) { $erg += $d; break }
            }
        }
    }
    $erg
}

function PcCheckSicherungLaufwerke {
    try {
        @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop |
            Where-Object { $_.DriveType -ne 5 -and $_.DeviceID } |
            ForEach-Object { [string]$_.DeviceID })
    } catch { @() }
}

# Reine Funktion: welche der Shell-Ordner liegen in einem OneDrive-Konto?
#   -Konten: Objekte mit Name und UserFolder
#   -ShellOrdner: Hashtable mit den Schlüsseln Desktop, Dokumente, Bilder (Pfade, bereits aufgelöst)
function PcCheckSicherungOneDriveAuswahl {
    param($Konten, $ShellOrdner)
    $konten = @($Konten | Where-Object { $_ -and $_.UserFolder })
    $gesichert = @()
    $kontenNamen = @()
    foreach ($name in @('Desktop', 'Dokumente', 'Bilder')) {
        $pfad = [string]$ShellOrdner[$name]
        if ([string]::IsNullOrWhiteSpace($pfad)) { continue }
        $pfad = $pfad.TrimEnd('\') + '\'
        foreach ($k in $konten) {
            $wurzel = ([string]$k.UserFolder).TrimEnd('\') + '\'
            if ($pfad.StartsWith($wurzel, [StringComparison]::OrdinalIgnoreCase)) {
                $gesichert += $name
                if ($kontenNamen -notcontains [string]$k.Name) { $kontenNamen += [string]$k.Name }
                break
            }
        }
    }
    [pscustomobject]@{ ordner = @($gesichert); konten = @($kontenNamen) }
}

#endregion

function Get-MorpheusDateiversionsverlauf {
    [CmdletBinding()]
    param(
        [string]$ConfigOrdner = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\FileHistory\Configuration'),
        [string]$RegistryPfad = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\FileHistory'
    )
    $art = 'Dateiversionsverlauf'
    try {
        $dateien = @()
        if (Test-Path -LiteralPath $ConfigOrdner -PathType Container) {
            $dateien = @(Get-ChildItem -LiteralPath $ConfigOrdner -Filter 'Config*.xml' -File -ErrorAction SilentlyContinue)
        }
        if ($dateien.Count -eq 0) {
            return [pscustomobject](PcCheckSicherungNeu -Art $art -Hinweis 'Nicht eingerichtet.')
        }

        $kandidaten = @()
        foreach ($f in $dateien) {
            $doc = New-Object System.Xml.XmlDocument
            try { $doc.Load($f.FullName) } catch { continue }
            $ziel = PcCheckSicherungXmlWert $doc @('TargetUrl', 'TargetName')
            $an = PcCheckSicherungXmlWert $doc @('Enabled', 'DPStatus')
            $kandidaten += [pscustomobject]@{ Datei = $f; Ziel = $ziel; An = $an }
        }
        if ($kandidaten.Count -eq 0) {
            return [pscustomobject](PcCheckSicherungNeu -Art $art -Hinweis 'Nicht lesbar: Konfiguration enthält kein gültiges XML.')
        }
        $mitZiel = @($kandidaten | Where-Object { $_.Ziel -ne '' })
        $wahl = $null
        if ($mitZiel.Count -gt 0) {
            $wahl = $mitZiel | Where-Object { $_.An -match '^(true|1)$' } | Select-Object -First 1
            if (-not $wahl) { $wahl = $mitZiel[0] }
        } else {
            $wahl = $kandidaten[0]
        }

        $ziel = $null
        if ($wahl.Ziel -ne '') { $ziel = $wahl.Ziel }

        $letzte = PcCheckSicherungFileTime -RegistryPfad $RegistryPfad
        $quelle = 'Registry'
        if ($null -eq $letzte) { $letzte = $wahl.Datei.LastWriteTime; $quelle = 'Konfigurationsdatei' }

        $hinweis = ''
        $aktiv = $false
        if ($wahl.An -match '^(true|1)$') {
            $aktiv = $true
        } elseif ($wahl.An -match '^(false|0)$') {
            $aktiv = $false
            $hinweis = 'Dateiversionsverlauf ist ausgeschaltet.'
        } else {
            # An/aus nicht sicher erkennbar: aktiv, wenn ein Ziel konfiguriert ist
            $aktiv = ($null -ne $ziel)
            if ($aktiv) {
                $hinweis = 'Ob der Dateiversionsverlauf eingeschaltet ist, war der Konfiguration nicht sicher zu entnehmen; gewertet wird: Ziel konfiguriert = aktiv. Letzte Sicherung aus: ' + $quelle + '.'
            } else {
                $hinweis = 'Kein Sicherungsziel konfiguriert.'
            }
        }
        [pscustomobject](PcCheckSicherungNeu -Art $art -Gefunden $true -Aktiv $aktiv -Ziel $ziel -Letzte $letzte -Hinweis $hinweis)
    } catch {
        [pscustomobject](PcCheckSicherungNeu -Art $art -Hinweis ('Nicht lesbar: ' + $_.Exception.Message))
    }
}

function Get-MorpheusOneDriveSicherung {
    [CmdletBinding()]
    param()
    $art = 'OneDrive-Ordnersicherung'
    try {
        $konten = @()
        $basis = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
        if (Test-Path -LiteralPath $basis) {
            foreach ($k in @(Get-ChildItem -LiteralPath $basis -ErrorAction SilentlyContinue)) {
                $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                if ($p -and $p.UserFolder) {
                    $konten += [pscustomobject]@{ Name = $k.PSChildName; UserFolder = [string]$p.UserFolder }
                }
            }
        }
        $shell = @{}
        $sp = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
        if ($sp) {
            $map = @{ Desktop = 'Desktop'; Dokumente = 'Personal'; Bilder = 'My Pictures' }
            foreach ($n in $map.Keys) {
                $v = $sp.($map[$n])
                if ($v) { $shell[$n] = [Environment]::ExpandEnvironmentVariables([string]$v) }
            }
        }
        $hinweisApp = 'Die App „Windows-Sicherung“ sichert Ordner ebenfalls über OneDrive; sie ist hier mit abgedeckt.'
        if ($konten.Count -eq 0) {
            $o = PcCheckSicherungNeu -Art $art -Hinweis ('Kein OneDrive-Konto angemeldet. ' + $hinweisApp)
            $o['ordner'] = @()
            return [pscustomobject]$o
        }
        $auswahl = PcCheckSicherungOneDriveAuswahl -Konten $konten -ShellOrdner $shell
        $aktiv = (@($auswahl.ordner).Count -gt 0)
        $ziel = $null
        if ($aktiv) { $ziel = 'OneDrive (' + (@($auswahl.konten) -join ', ') + ')' }
        $hinweis = $hinweisApp + ' Der Zeitpunkt der letzten Sicherung ist nicht auslesbar.'
        if (-not $aktiv) { $hinweis = 'Desktop, Dokumente und Bilder liegen nicht in OneDrive. ' + $hinweis }
        $o = PcCheckSicherungNeu -Art $art -Gefunden $true -Aktiv $aktiv -Ziel $ziel -Hinweis $hinweis
        $o['ordner'] = @($auswahl.ordner)
        [pscustomobject]$o
    } catch {
        $o = PcCheckSicherungNeu -Art $art -Hinweis ('Nicht lesbar: ' + $_.Exception.Message)
        $o['ordner'] = @()
        [pscustomobject]$o
    }
}

function Get-MorpheusSystemabbild {
    [CmdletBinding()]
    param(
        [string[]]$Laufwerke,
        [switch]$IsAdmin
    )
    $art = 'Systemabbild'
    try {
        if (-not $PSBoundParameters.ContainsKey('Laufwerke')) { $Laufwerke = @(PcCheckSicherungLaufwerke) }
        $letzte = $null
        $ziel = $null
        foreach ($lw in @($Laufwerke)) {
            if ([string]::IsNullOrWhiteSpace($lw)) { continue }
            $wurzel = $lw
            if ($lw -match '^[A-Za-z]:$') { $wurzel = $lw + '\' }
            $ordner = Join-Path $wurzel 'WindowsImageBackup'
            if (-not (Test-Path -LiteralPath $ordner -PathType Container)) { continue }
            foreach ($u in @(Get-ChildItem -LiteralPath $ordner -Directory -ErrorAction SilentlyContinue)) {
                if ($null -eq $letzte -or $u.LastWriteTime -gt $letzte) { $letzte = $u.LastWriteTime; $ziel = $ordner }
            }
        }
        if ($IsAdmin) {
            # Fester Pfad statt PATH-Suche: läuft mit Adminrechten, ein Benutzerordner im PATH darf nichts unterschieben
            $wb = Join-Path $env:SystemRoot 'System32\wbadmin.exe'
            if (Test-Path -LiteralPath $wb -PathType Leaf) {
                $zeilen = PcCheckSicherungNative -Exe $wb -Argumente @('get', 'versions')
                $zeiten = @(PcCheckSicherungWbadminZeiten -Zeilen ([string[]]$zeilen))
                foreach ($d in $zeiten) {
                    if ($null -eq $letzte -or $d -gt $letzte) { $letzte = $d; if (-not $ziel) { $ziel = 'wbadmin' } }
                }
            }
        }
        if ($null -eq $letzte) {
            $h = 'Kein Systemabbild gefunden.'
            if (-not $IsAdmin) { $h += ' Ohne Administratorrechte wurde nur nach Ordnern WindowsImageBackup gesucht.' }
            return [pscustomobject](PcCheckSicherungNeu -Art $art -Hinweis $h)
        }
        $alter = ((Get-Date) - $letzte).TotalDays
        if ($alter -gt 180) {
            return [pscustomobject](PcCheckSicherungNeu -Art $art -Gefunden $true -Aktiv $false -Ziel $ziel -Letzte $letzte -Hinweis 'Systemabbild ist veraltet (älter als 180 Tage).')
        }
        [pscustomobject](PcCheckSicherungNeu -Art $art -Gefunden $true -Aktiv $true -Ziel $ziel -Letzte $letzte -Hinweis '')
    } catch {
        [pscustomobject](PcCheckSicherungNeu -Art $art -Hinweis ('Nicht lesbar: ' + $_.Exception.Message))
    }
}

function Get-MorpheusSicherung {
    [CmdletBinding()]
    param()
    $admin = $false
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    $erg = @()
    foreach ($def in @(
            @{ Art = 'Dateiversionsverlauf'; Block = { Get-MorpheusDateiversionsverlauf } },
            @{ Art = 'OneDrive-Ordnersicherung'; Block = { Get-MorpheusOneDriveSicherung } },
            @{ Art = 'Systemabbild'; Block = { Get-MorpheusSystemabbild -IsAdmin:$admin } })) {
        try {
            $erg += (& $def.Block)
        } catch {
            $o = PcCheckSicherungNeu -Art $def.Art -Hinweis ('Nicht lesbar: ' + $_.Exception.Message)
            if ($def.Art -eq 'OneDrive-Ordnersicherung') { $o['ordner'] = @() }
            $erg += [pscustomobject]$o
        }
    }
    $erg
}

function Get-MorpheusSicherungBewertung {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Eintraege,
        [datetime]$Jetzt = (Get-Date)
    )
    $dv = @($Eintraege | Where-Object { $_.art -eq 'Dateiversionsverlauf' }) | Select-Object -First 1
    $od = @($Eintraege | Where-Object { $_.art -eq 'OneDrive-Ordnersicherung' }) | Select-Object -First 1
    $sa = @($Eintraege | Where-Object { $_.art -eq 'Systemabbild' }) | Select-Object -First 1

    $alterTage = {
        param($e)
        if ($null -eq $e -or [string]::IsNullOrWhiteSpace([string]$e.letzteSicherung)) { return $null }
        ($Jetzt - [datetime]$e.letzteSicherung).TotalDays
    }
    $gut = {
        param($e, [double]$Limit)
        if ($null -eq $e -or -not $e.gefunden -or -not $e.aktiv) { return $false }
        $a = & $alterTage $e
        ($null -eq $a -or $a -le $Limit)
    }
    $datum = { param($e) ([datetime]$e.letzteSicherung).ToString('dd.MM.yyyy') }

    $okDv = [bool](& $gut $dv 30)
    $okOd = [bool](& $gut $od 30)
    $okSa = [bool](& $gut $sa 180)

    $teile = @()
    if ($null -ne $dv -and $dv.gefunden -and $dv.aktiv) {
        if ($okDv) {
            $t = 'Dateiversionsverlauf aktiv'
        } else {
            $t = 'Dateiversionsverlauf veraltet'
        }
        if ($dv.letzteSicherung) { $t += ' (letzte Sicherung ' + (& $datum $dv) + ')' }
        $teile += $t
    } else {
        $teile += 'Dateiversionsverlauf aus'
    }
    if ($null -ne $od -and $od.gefunden -and $od.aktiv -and @($od.ordner).Count -gt 0) {
        $teile += ('OneDrive: ' + (@($od.ordner) -join ', '))
    } else {
        $teile += 'OneDrive: keine Ordner gesichert'
    }
    if ($null -ne $sa -and $sa.gefunden) {
        if ($okSa) {
            $teile += ('Systemabbild vom ' + (& $datum $sa))
        } else {
            $teile += ('Systemabbild veraltet (' + (& $datum $sa) + ')')
        }
    } else {
        $teile += 'kein Systemabbild'
    }
    $wert = $teile -join '; '

    if ($okDv -or $okOd -or $okSa) {
        $empf = ''
        if (-not $okDv -and -not $okSa -and $okOd) {
            $empf = 'Nur OneDrive sichert deine Ordner. Cloud-Synchronisation schützt nicht vor allem: Eine Ransomware-Verschlüsselung wird mitsynchronisiert (dann helfen Versionsverlauf und Papierkorb von OneDrive). Eine zusätzliche Sicherung auf ein externes Laufwerk (Dateiversionsverlauf) ist sinnvoll.'
        }
        return [pscustomobject]@{ status = 'OK'; wert = $wert; empfehlung = $empf }
    }
    $empf = 'Keine aktuelle Datensicherung erkannt. Schalte den Dateiversionsverlauf ein (Einstellungen > System > Speicher > Erweiterte Speichereinstellungen > Sicherungsoptionen bzw. Systemsteuerung > Dateiversionsverlauf, mit einem externen Laufwerk) oder die OneDrive-Ordnersicherung (OneDrive > Einstellungen > Synchronisieren und sichern > Sicherung verwalten). Sicherst du mit einem anderen Programm oder auf ein NAS, trag den Befund in die Akzeptanzliste (accepted.psd1) ein.'
    [pscustomobject]@{ status = 'WARN'; wert = $wert; empfehlung = $empf }
}
