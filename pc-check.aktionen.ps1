#Requires -Version 5.1
<#
.SYNOPSIS
    Aktionskatalog der pc-check-GUI (T3): Einstellungen, die auf Knopfdruck geändert und exakt zurückgenommen werden können.

.DESCRIPTION
    Die Datei gibt ein Array von Hashtables zurück (Schema: docs\gui-architektur.md, Abschnitt 8).
    Der Katalog wird per `& $file` geladen. Die Scriptblöcke laufen später in einem anderen
    Scope bzw. Prozess (Start-Job) und sind deshalb vollständig in sich geschlossen: keine Hilfsfunktionen
    und keine Variablen auf Dateiebene, gemeinsame Teile stehen bewusst in jedem Block.

    Regeln für alle Aktionen:
    - Lesen ändert nichts und liefert { Aktiv; Wert; Zustand }. Zustand reicht zum exakten Wiederherstellen.
    - Registry: Ein Wert, der vorher nicht existierte, steht als $null im Zustand; Rückgängig löscht ihn dann.
      Legt Ausführen einen Schlüssel neu an, merkt sich der Zustand das (SchluesselVorhanden = $false), und
      Rückgängig entfernt nur diesen eigenen, leeren Schlüssel. Der Datentyp bleibt erhalten.
    - Ausfuehren und Rueckgaengig sind idempotent, mit -ErrorAction Stop und ohne Ausgabe auf der Pipeline.
    - HKCU-Aktionen prüfen in Voraussetzung, dass der Prozess unter dem angemeldeten Benutzer läuft.
#>

@(
    #region Sicherheit: Defender

    @{
        Id          = 'defender.netzwerkschutz'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Microsoft Defender: Einstellungen'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
            try { $s = Get-MpComputerStatus -ErrorAction Stop } catch { return (T 'katalog.defender.nichtAbrufbar' $_.Exception.Message) }
            if ($s.AMRunningMode -and $s.AMRunningMode -ne 'Normal') { return (T 'katalog.defender.modus' $s.AMRunningMode) }
            if (-not $s.AntivirusEnabled) { return (T 'katalog.defender.avAus') }
        }
        Lesen = {
            try { $v = [int](Get-MpPreference -ErrorAction Stop).EnableNetworkProtection }
            catch { return [pscustomobject]@{ Aktiv = $false; Wert = (T 'katalog.defender.nichtLesbar' $_.Exception.Message); Zustand = $null } }
            $namen = @{ 0 = (T 'katalog.wert.aus'); 1 = (T 'katalog.wert.an'); 2 = (T 'katalog.defender.nurProtokollieren') }
            [pscustomobject]@{ Aktiv = ($v -eq 1); Wert = [string]$namen[$v]; Zustand = $v }
        }
        Ausfuehren = {
            param($Variante)
            Set-MpPreference -EnableNetworkProtection Enabled -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $namen = @{ 0 = 'Disabled'; 1 = 'Enabled'; 2 = 'AuditMode' }
            $modus = $namen[[int]$Vorher]
            if (-not $modus) { throw (T 'katalog.defender.netzwerkschutzUnbekannt' $Vorher) }
            Set-MpPreference -EnableNetworkProtection $modus -ErrorAction Stop | Out-Null
        }
    },

    @{
        Id          = 'defender.pua'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Microsoft Defender: Einstellungen'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
            try { $s = Get-MpComputerStatus -ErrorAction Stop } catch { return (T 'katalog.defender.nichtAbrufbar' $_.Exception.Message) }
            if ($s.AMRunningMode -and $s.AMRunningMode -ne 'Normal') { return (T 'katalog.defender.modus' $s.AMRunningMode) }
            if (-not $s.AntivirusEnabled) { return (T 'katalog.defender.avAus') }
        }
        Lesen = {
            try { $v = [int](Get-MpPreference -ErrorAction Stop).PUAProtection }
            catch { return [pscustomobject]@{ Aktiv = $false; Wert = (T 'katalog.defender.nichtLesbar' $_.Exception.Message); Zustand = $null } }
            $namen = @{ 0 = (T 'katalog.wert.aus'); 1 = (T 'katalog.defender.anBlockieren'); 2 = (T 'katalog.defender.nurProtokollieren') }
            [pscustomobject]@{ Aktiv = ($v -eq 1); Wert = [string]$namen[$v]; Zustand = $v }
        }
        Ausfuehren = {
            param($Variante)
            Set-MpPreference -PUAProtection Enabled -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $namen = @{ 0 = 'Disabled'; 1 = 'Enabled'; 2 = 'AuditMode' }
            $modus = $namen[[int]$Vorher]
            if (-not $modus) { throw (T 'katalog.defender.puaUnbekannt' $Vorher) }
            Set-MpPreference -PUAProtection $modus -ErrorAction Stop | Out-Null
        }
    },

    @{
        Id          = 'defender.asr-basis'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Microsoft Defender: Einstellungen'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'mittel'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = @('Blockieren', 'Nur protokollieren')
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
            try { $s = Get-MpComputerStatus -ErrorAction Stop } catch { return (T 'katalog.defender.nichtAbrufbar' $_.Exception.Message) }
            if ($s.AMRunningMode -and $s.AMRunningMode -ne 'Normal') { return (T 'katalog.defender.modus' $s.AMRunningMode) }
            if (-not $s.AntivirusEnabled) { return (T 'katalog.defender.avAus') }
            if (-not $s.RealTimeProtectionEnabled) { return (T 'katalog.defender.echtzeitAus') }
        }
        Lesen = {
            $regelIds = @('56a863a9-875e-4185-98a7-b882c64b5ce5', '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2')
            $kurz = @((T 'katalog.asr.treiber'), (T 'katalog.asr.lsass'))
            try { $p = Get-MpPreference -ErrorAction Stop }
            catch { return [pscustomobject]@{ Aktiv = $false; Wert = (T 'katalog.defender.nichtLesbar' $_.Exception.Message); Zustand = $null } }
            $vid = @($p.AttackSurfaceReductionRules_Ids | ForEach-Object { ([string]$_).ToLower() })
            $vac = @($p.AttackSurfaceReductionRules_Actions)
            $namen = @{ 0 = (T 'katalog.wert.aus'); 1 = (T 'katalog.asr.blockieren'); 2 = (T 'katalog.asr.nurProtokollieren'); 5 = (T 'katalog.asr.nichtKonfiguriert'); 6 = (T 'katalog.asr.warnen') }
            $regeln = @(for ($i = 0; $i -lt $regelIds.Count; $i++) {
                    $idx = [array]::IndexOf($vid, $regelIds[$i])
                    $akt = $null
                    if ($idx -ge 0 -and $idx -lt $vac.Count) { $akt = [int]$vac[$idx] }
                    [ordered]@{ Id = $regelIds[$i]; Aktion = $akt }
                })
            $aktiv = $true
            $texte = @()
            for ($i = 0; $i -lt $regeln.Count; $i++) {
                $a = $regeln[$i].Aktion
                if ($a -ne 1 -and $a -ne 2) { $aktiv = $false }
                if ($null -eq $a) { $t = (T 'katalog.asr.nichtGesetzt') } else { $t = [string]$namen[$a]; if (-not $t) { $t = (T 'katalog.asr.wert' $a) } }
                $texte += ('{0}: {1}' -f $kurz[$i], $t)
            }
            [pscustomobject]@{ Aktiv = $aktiv; Wert = ($texte -join '; '); Zustand = [ordered]@{ Regeln = $regeln } }
        }
        Ausfuehren = {
            param($Variante)
            $modus = switch ($Variante) {
                'Blockieren' { 'Enabled' }
                'Nur protokollieren' { 'AuditMode' }
                default { throw (T 'katalog.asr.variante' $Variante) }
            }
            $regelIds = @('56a863a9-875e-4185-98a7-b882c64b5ce5', '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2')
            $p = Get-MpPreference -ErrorAction Stop
            $vid = @($p.AttackSurfaceReductionRules_Ids | ForEach-Object { ([string]$_).ToLower() })
            $vac = @($p.AttackSurfaceReductionRules_Actions)
            foreach ($id in $regelIds) {
                $idx = [array]::IndexOf($vid, $id)
                # Eine Regel, die schon blockiert oder protokolliert, bleibt unverändert (kein Herabstufen)
                if ($idx -ge 0 -and $idx -lt $vac.Count -and ([int]$vac[$idx] -eq 1 -or [int]$vac[$idx] -eq 2)) { continue }
                Add-MpPreference -AttackSurfaceReductionRules_Ids $id -AttackSurfaceReductionRules_Actions $modus -ErrorAction Stop | Out-Null
            }
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $namen = @{ 0 = 'Disabled'; 1 = 'Enabled'; 2 = 'AuditMode'; 5 = 'NotConfigured'; 6 = 'Warn' }
            foreach ($r in @($Vorher.Regeln)) {
                $id = ([string]$r.Id).ToLower()
                $p = Get-MpPreference -ErrorAction Stop
                $vid = @($p.AttackSurfaceReductionRules_Ids | ForEach-Object { ([string]$_).ToLower() })
                $vac = @($p.AttackSurfaceReductionRules_Actions)
                $idx = [array]::IndexOf($vid, $id)
                if ($null -eq $r.Aktion) {
                    # Regel war vorher nicht gesetzt: wieder entfernen
                    if ($idx -ge 0) { Remove-MpPreference -AttackSurfaceReductionRules_Ids $id -ErrorAction Stop | Out-Null }
                    continue
                }
                $modus = $namen[[int]$r.Aktion]
                if (-not $modus) { throw (T 'katalog.asr.modusUnbekannt' $r.Aktion) }
                if ($idx -ge 0 -and $idx -lt $vac.Count -and [int]$vac[$idx] -eq [int]$r.Aktion) { continue }
                Add-MpPreference -AttackSurfaceReductionRules_Ids $id -AttackSurfaceReductionRules_Actions $modus -ErrorAction Stop | Out-Null
            }
        }
    },

    #endregion

    #region Sicherheit: Fernzugriff und Netzwerk

    @{
        Id          = 'fernzugriff.remoteunterstuetzung'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Remotedesktop'
        Nutzen      = 'gering'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
            $pol = $null
            try { $pol = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fAllowToGetHelp' -ErrorAction Stop).fAllowToGetHelp } catch { }
            if ($null -ne $pol) { return (T 'katalog.remote.gpo') }
        }
        Lesen = {
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; $name = 'fAllowToGetHelp'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            $pol = $null
            try { $pol = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name $name -ErrorAction Stop).$name } catch { }
            $wirksam = $wert
            if ($null -ne $pol) { $wirksam = $pol }
            if ($wirksam -eq 0) { $text = (T 'katalog.remote.nichtErlaubt') } elseif ($null -eq $wirksam) { $text = (T 'katalog.remote.nichtGesetzt') } else { $text = (T 'katalog.remote.erlaubt') }
            if ($null -ne $pol) { $text = (T 'katalog.wert.perRichtlinie' $text) }
            [pscustomobject]@{ Aktiv = ($wirksam -eq 0); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; $name = 'fAllowToGetHelp'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; $name = 'fAllowToGetHelp'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    @{
        Id          = 'fernzugriff.rdp'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Remotedesktop'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'mittel'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
            $pol = $null
            try { $pol = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fDenyTSConnections' -ErrorAction Stop).fDenyTSConnections } catch { }
            if ($null -ne $pol) { return (T 'katalog.rdp.gpo') }
        }
        Lesen = {
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'; $name = 'fDenyTSConnections'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            $pol = $null
            try { $pol = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name $name -ErrorAction Stop).$name } catch { }
            $wirksam = $wert
            if ($null -ne $pol) { $wirksam = $pol }
            if ($wirksam -eq 1) { $text = (T 'katalog.wert.aus') } elseif ($null -eq $wirksam) { $text = (T 'katalog.rdp.nichtGesetzt') } else { $text = (T 'katalog.wert.an') }
            if ($null -ne $pol) { $text = (T 'katalog.wert.perRichtlinie' $text) }
            [pscustomobject]@{ Aktiv = ($wirksam -eq 1); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'; $name = 'fDenyTSConnections'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'; $name = 'fDenyTSConnections'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    @{
        Id          = 'netz.llmnr'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'LLMNR / NetBIOS'
        Nutzen      = 'gering'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
        }
        Lesen = {
            $pfad = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'; $name = 'EnableMulticast'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            if ($wert -eq 0) { $text = (T 'katalog.llmnr.ausRichtlinie') } elseif ($null -eq $wert) { $text = (T 'katalog.llmnr.anStandard') } else { $text = (T 'katalog.llmnr.anRichtlinie') }
            [pscustomobject]@{ Aktiv = ($wert -eq 0); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'; $name = 'EnableMulticast'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $pfad = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'; $name = 'EnableMulticast'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    #endregion

    #region System und Härtung

    @{
        Id          = 'system.wiederherstellung'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Wiederherstellung'
        Nutzen      = 'hoch'
        Aufwand     = 'gering'
        Risiko      = 'mittel'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        OhneWiederherstellungspunkt = $true
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
            $dis = $null
            try { $dis = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR' -ErrorAction Stop).DisableSR } catch { }
            if ($dis -eq 1) { return (T 'katalog.wiederherstellung.gpo') }
        }
        Lesen = {
            $laufwerk = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\'))
            if (-not $laufwerk) { $laufwerk = 'C:' }
            $intervall = $null; $dis = $null
            try { $intervall = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'RPSessionInterval' -ErrorAction Stop).RPSessionInterval } catch { }
            try { $dis = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR' -ErrorAction Stop).DisableSR } catch { }
            $an = (($intervall -eq 1) -and ($dis -ne 1))
            if ($an) { $text = (T 'katalog.wiederherstellung.an' $laufwerk) } elseif ($dis -eq 1) { $text = (T 'katalog.wiederherstellung.ausRichtlinie') } else { $text = (T 'katalog.wiederherstellung.aus' $laufwerk) }
            [pscustomobject]@{ Aktiv = $an; Wert = $text; Zustand = [ordered]@{ Eingeschaltet = $an; Laufwerk = ($laufwerk + '\') } }
        }
        Ausfuehren = {
            param($Variante)
            $laufwerk = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\'))
            if (-not $laufwerk) { $laufwerk = 'C:' }
            Enable-ComputerRestore -Drive ($laufwerk + '\') -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            # War der Schutz schon vorher an, gab es nichts zurückzunehmen; ausgeschaltet wird nur, was diese Aktion eingeschaltet hat
            if ($Vorher.Eingeschaltet -eq $true) { return }
            $laufwerk = [string]$Vorher.Laufwerk
            if (-not $laufwerk) { $laufwerk = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\')) + '\' }
            Disable-ComputerRestore -Drive $laufwerk -ErrorAction Stop | Out-Null
        }
    },

    @{
        Id          = 'system.wiederherstellung-speicher'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Wiederherstellung'
        Nutzen      = 'hoch'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
            # Point-in-time restore (Windows 11, seit 26100/26200.8737): „The maximum VSS limit equals the maximum usage
            # configuration for point-in-time restore“ (learn.microsoft.com/windows/configuration/point-in-time-restore).
            # Lokal nur über die Einstellungen oder MDM (Recovery-CSP) änderbar; vssadmin hielte nur bis zum nächsten Start.
            $pitr = $null
            try { $pitr = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Setup\' -TaskName 'PITRTask' -ErrorAction Stop } catch { }
            if ($pitr -and ([string]$pitr.State -ne 'Disabled')) {
                return (T 'katalog.speicher.pitr')
            }
            $iv = $null; $dis = $null
            try { $iv = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'RPSessionInterval' -ErrorAction Stop).RPSessionInterval } catch { }
            try { $dis = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR' -ErrorAction Stop).DisableSR } catch { }
            if (($iv -ne 1) -or ($dis -eq 1)) { return (T 'katalog.speicher.schutzAus') }
        }
        Lesen = {
            $lw = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\'))
            if (-not $lw) { $lw = 'C:' }
            try {
                $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='$lw'" -ErrorAction Stop
                $ss = @(Get-CimInstance Win32_ShadowStorage -ErrorAction Stop | Where-Object { $_.Volume.DeviceID -eq $vol.DeviceID }) | Select-Object -First 1
            }
            catch { return [pscustomobject]@{ Aktiv = $false; Wert = (T 'katalog.speicher.nurAdmin'); Zustand = [ordered]@{ Laufwerk = $lw; Max = $null } } }
            if (-not $ss) { return [pscustomobject]@{ Aktiv = $false; Wert = (T 'katalog.speicher.keinSpeicher' $lw); Zustand = [ordered]@{ Laufwerk = $lw; Max = $null } } }
            $max = [uint64]$ss.MaxSpace
            if ($max -eq [uint64]::MaxValue) {
                return [pscustomobject]@{ Aktiv = $true; Wert = (T 'katalog.speicher.unbegrenzt'); Zustand = [ordered]@{ Laufwerk = $lw; Max = 'UNBOUNDED' } }
            }
            $pct = [Math]::Round(100 * [double]$max / [double]$vol.Capacity, 1)
            $wert = (T 'katalog.speicher.max' ([double]$max / 1GB) $pct)
            $pitr = $null
            try { $pitr = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Setup\' -TaskName 'PITRTask' -ErrorAction Stop } catch { }
            if ($pitr -and ([string]$pitr.State -ne 'Disabled')) { $wert = (T 'katalog.speicher.mitPitr' $wert) }
            # Ziel erreicht ab 8 % (die Aktion setzt 10 %) oder ab 49 GB (Point-in-time restore erlaubt höchstens 50 GB). Der Zustand zählt in ganzen MB: Windows speichert die Grenze
            # gerundet, bytegenau würde die Kontrolle nach dem Rückgängigmachen fälschlich abweichen.
            [pscustomobject]@{ Aktiv = (($pct -ge 8) -or ([double]$max -ge 49GB)); Wert = $wert; Zustand = [ordered]@{ Laufwerk = $lw; Max = ('{0}MB' -f [Math]::Floor([double]$max / 1MB)) } }
        }
        Ausfuehren = {
            param($Variante)
            $lw = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\'))
            if (-not $lw) { $lw = 'C:' }
            $out = & (Join-Path ([Environment]::SystemDirectory) 'vssadmin.exe') resize shadowstorage "/for=$lw" "/on=$lw" '/maxsize=10%' 2>&1
            if ($LASTEXITCODE -ne 0) { throw (T 'katalog.speicher.vssadmin' $LASTEXITCODE (($out | Out-String).Trim())) }
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            if ($null -eq $Vorher.Max) { throw (T 'katalog.speicher.keinVorher') }
            $lw = [string]$Vorher.Laufwerk
            if ($lw -notmatch '^[A-Za-z]:$') { throw (T 'katalog.speicher.laufwerkUngueltig' $lw) }
            $max = [string]$Vorher.Max
            if ($max -ne 'UNBOUNDED') {
                if ($max -notmatch '^(\d{1,12})MB$') { throw (T 'katalog.speicher.grenzeUngueltig' $max) }
                if ([int64]$Matches[1] -lt 320) { $max = '320MB' }   # vssadmin verlangt mindestens 320 MB
            }
            $out = & (Join-Path ([Environment]::SystemDirectory) 'vssadmin.exe') resize shadowstorage "/for=$lw" "/on=$lw" "/maxsize=$max" 2>&1
            if ($LASTEXITCODE -ne 0) { throw (T 'katalog.speicher.vssadmin' $LASTEXITCODE (($out | Out-String).Trim())) }
        }
    },

    @{
        Id          = 'system.schnellstart'
        Kategorie   = 'Leistung'
        Pruefung    = 'Schnellstart und Ruhezustand'
        Nutzen      = 'gering'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
            $pol = $null
            try { $pol = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'HiberbootEnabled' -ErrorAction Stop).HiberbootEnabled } catch { }
            if ($null -ne $pol) { return (T 'katalog.schnellstart.gpo') }
        }
        Lesen = {
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; $name = 'HiberbootEnabled'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            # Wie in der Prüfung: alles außer 1 gilt als "aus"
            if ($wert -eq 1) { $text = (T 'katalog.wert.an') } elseif ($null -eq $wert) { $text = (T 'katalog.wert.ausNichtGesetzt') } else { $text = (T 'katalog.wert.aus') }
            [pscustomobject]@{ Aktiv = ($wert -ne 1); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; $name = 'HiberbootEnabled'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; $name = 'HiberbootEnabled'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    @{
        Id          = 'haertung.lsa'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'LSA-Schutz'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'mittel'
        Neustart    = $true
        Bereich     = 'System'
        Varianten   = $null
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
            if ([Environment]::OSVersion.Version.Build -lt 22621) { return (T 'katalog.lsa.version') }
        }
        Lesen = {
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; $name = 'RunAsPPL'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            if ($wert -eq 1) { $text = (T 'katalog.lsa.anUefi') } elseif ($wert -eq 2) { $text = (T 'katalog.wert.an') } elseif ($null -eq $wert) { $text = (T 'katalog.wert.ausNichtGesetzt') } else { $text = (T 'katalog.lsa.ausWert' $wert) }
            [pscustomobject]@{ Aktiv = ($wert -eq 1 -or $wert -eq 2); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; $name = 'RunAsPPL'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 2 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; $name = 'RunAsPPL'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    @{
        Id          = 'haertung.treibersperrliste'
        Kategorie   = 'Sicherheit'
        Pruefung    = 'Treiber-Sperrliste und Smart App Control'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'mittel'
        Neustart    = $true
        Bereich     = 'System'
        Varianten   = $null
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
        }
        Lesen = {
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'; $name = 'VulnerableDriverBlocklistEnable'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            # Wie in der Prüfung: nur ein ausdrückliches 0 bedeutet "aus"; ohne Wert gilt der Windows-Standard (an)
            if ($wert -eq 0) { $text = (T 'katalog.wert.aus') } elseif ($null -eq $wert) { $text = (T 'katalog.wert.anStandard') } else { $text = (T 'katalog.wert.an') }
            [pscustomobject]@{ Aktiv = ($wert -ne 0); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'; $name = 'VulnerableDriverBlocklistEnable'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'; $name = 'VulnerableDriverBlocklistEnable'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    #endregion

    #region Leistung: Energie

    @{
        Id          = 'energie.aspm'
        Kategorie   = 'Leistung'
        Pruefung    = 'Weitere Energiesparfunktionen'
        Nutzen      = 'gering'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
            $akt = (& (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /getactivescheme) -join ' '
            if ($akt -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return (T 'katalog.aspm.planUnbekannt') }
            $out = (& (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /qh $Matches[1] '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5') -join "`n"
            if (@([regex]::Matches($out, '0x([0-9a-fA-F]{8})')).Count -lt 2) { return (T 'katalog.aspm.ohnePcie') }
        }
        Lesen = {
            $teil = '501a4d13-42af-4429-9fd1-a8218c268e20'; $einst = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
            $akt = (& (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /getactivescheme) -join ' '
            if ($akt -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                return [pscustomobject]@{ Aktiv = $false; Wert = (T 'katalog.aspm.nichtLesbar'); Zustand = $null }
            }
            $plan = $Matches[1].ToLower()
            $planName = $plan
            if ($akt -match '\((.+)\)\s*\*?\s*$') { $planName = $Matches[1] }
            $out = (& (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /qh $plan $teil $einst) -join "`n"
            $hex = @([regex]::Matches($out, '0x([0-9a-fA-F]{8})') | ForEach-Object { [Convert]::ToInt64($_.Groups[1].Value, 16) })
            if ($hex.Count -lt 2) {
                return [pscustomobject]@{ Aktiv = $false; Wert = (T 'katalog.aspm.planOhnePcie' $planName); Zustand = $null }
            }
            $ac = [int]$hex[-2]; $dc = [int]$hex[-1]
            $namen = @{ 0 = (T 'katalog.wert.aus'); 1 = (T 'katalog.aspm.mittel'); 2 = (T 'katalog.aspm.maximal') }
            $text = (T 'katalog.aspm.anzeige' $planName $(if ($namen.ContainsKey($ac)) { $namen[$ac] } else { $ac }) $(if ($namen.ContainsKey($dc)) { $namen[$dc] } else { $dc }))
            [pscustomobject]@{ Aktiv = ($ac -eq 0 -and $dc -eq 0); Wert = $text; Zustand = [ordered]@{ Plan = $plan; AC = $ac; DC = $dc } }
        }
        Ausfuehren = {
            param($Variante)
            $teil = '501a4d13-42af-4429-9fd1-a8218c268e20'; $einst = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
            $akt = (& (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /getactivescheme) -join ' '
            if ($akt -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { throw (T 'katalog.aspm.planUnbekannt') }
            $plan = $Matches[1].ToLower()
            & (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /setacvalueindex $plan $teil $einst 0 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw (T 'katalog.aspm.powercfg' '/setacvalueindex' $LASTEXITCODE) }
            & (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /setdcvalueindex $plan $teil $einst 0 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw (T 'katalog.aspm.powercfg' '/setdcvalueindex' $LASTEXITCODE) }
            & (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /setactive SCHEME_CURRENT | Out-Null
            if ($LASTEXITCODE -ne 0) { throw (T 'katalog.aspm.powercfg' '/setactive' $LASTEXITCODE) }
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $teil = '501a4d13-42af-4429-9fd1-a8218c268e20'; $einst = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
            $plan = ([string]$Vorher.Plan).ToLower()
            if ($plan -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw (T 'katalog.aspm.planUngueltig' $plan) }
            & (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /setacvalueindex $plan $teil $einst ([int]$Vorher.AC) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw (T 'katalog.aspm.powercfg' '/setacvalueindex' $LASTEXITCODE) }
            & (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /setdcvalueindex $plan $teil $einst ([int]$Vorher.DC) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw (T 'katalog.aspm.powercfg' '/setdcvalueindex' $LASTEXITCODE) }
            & (Join-Path ([Environment]::SystemDirectory) 'powercfg.exe') /setactive SCHEME_CURRENT | Out-Null
            if ($LASTEXITCODE -ne 0) { throw (T 'katalog.aspm.powercfg' '/setactive' $LASTEXITCODE) }
        }
    },

    #endregion

    #region Gaming

    @{
        Id          = 'gaming.spielmodus'
        Kategorie   = 'Gaming'
        Pruefung    = 'Spielmodus'
        Nutzen      = 'gering'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'Benutzer'
        Varianten   = $null
        Voraussetzung = {
            try {
                $besitzer = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction Stop).User })
            } catch { return (T 'katalog.benutzer.nichtErmittelt' $_.Exception.Message) }
            if (-not $besitzer) { return (T 'katalog.benutzer.keinExplorer') }
            if ($besitzer -notcontains $env:USERNAME) { return (T 'katalog.benutzer.falsch' $env:USERNAME (($besitzer | Select-Object -Unique) -join ', ')) }
        }
        Lesen = {
            $pfad = 'HKCU:\Software\Microsoft\GameBar'; $name = 'AutoGameModeEnabled'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            # Wie in der Prüfung: nur ein ausdrückliches 0 bedeutet "aus"; ohne Wert gilt der Windows-Standard (an)
            if ($wert -eq 0) { $text = (T 'katalog.wert.aus') } elseif ($null -eq $wert) { $text = (T 'katalog.wert.anStandard') } else { $text = (T 'katalog.wert.an') }
            [pscustomobject]@{ Aktiv = ($wert -ne 0); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKCU:\Software\Microsoft\GameBar'; $name = 'AutoGameModeEnabled'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $pfad = 'HKCU:\Software\Microsoft\GameBar'; $name = 'AutoGameModeEnabled'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    @{
        Id          = 'gaming.hags'
        Kategorie   = 'Gaming'
        Pruefung    = 'Hardwarebeschleunigte GPU-Planung (HAGS)'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'mittel'
        Neustart    = $true
        Bereich     = 'System'
        Varianten   = $null
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
            # Nur anbieten, wenn Windows die Einstellung für diese Grafikkarte selbst angelegt hat (Treiber unterstützt HAGS)
            $h = $null
            try { $h = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -ErrorAction Stop).HwSchMode } catch { }
            if ($h -ne 1 -and $h -ne 2) { return (T 'katalog.hags.keineEinstellung') }
        }
        Lesen = {
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; $name = 'HwSchMode'
            $schluessel = Test-Path -LiteralPath $pfad
            $wert = $null; $typ = $null
            if ($schluessel) {
                $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                if ($k.GetValueNames() -contains $name) { $wert = $k.GetValue($name); $typ = $k.GetValueKind($name).ToString() }
            }
            if ($wert -eq 2) { $text = (T 'katalog.wert.an') } elseif ($wert -eq 1) { $text = (T 'katalog.wert.aus') } elseif ($null -eq $wert) { $text = (T 'katalog.hags.standard') } else { $text = (T 'katalog.hags.unbekannt' $wert) }
            [pscustomobject]@{ Aktiv = ($wert -eq 2); Wert = $text; Zustand = [ordered]@{ Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; $name = 'HwSchMode'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType DWord -Value 2 -Force -ErrorAction Stop | Out-Null
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; $name = 'HwSchMode'
            if ($null -eq $Vorher.Wert) {
                if (Test-Path -LiteralPath $pfad) {
                    if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                    if ($Vorher.SchluesselVorhanden -eq $false) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                $wert = $Vorher.Wert
                if ($Vorher.Typ -eq 'DWord') { $wert = [int]$wert }
                New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $Vorher.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
            }
        }
    },

    @{
        Id          = 'gaming.gamedvr'
        Kategorie   = 'Gaming'
        Pruefung    = 'Hintergrundaufzeichnung (Game DVR)'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'Benutzer'
        Varianten   = $null
        Voraussetzung = {
            try {
                $besitzer = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction Stop).User })
            } catch { return (T 'katalog.benutzer.nichtErmittelt' $_.Exception.Message) }
            if (-not $besitzer) { return (T 'katalog.benutzer.keinExplorer') }
            if ($besitzer -notcontains $env:USERNAME) { return (T 'katalog.benutzer.falsch' $env:USERNAME (($besitzer | Select-Object -Unique) -join ', ')) }
        }
        Lesen = {
            $ziele = @(
                @{ Pfad = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled' },
                @{ Pfad = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled' },
                @{ Pfad = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'HistoricalCaptureEnabled' }
            )
            $werte = @(foreach ($z in $ziele) {
                    $schluessel = Test-Path -LiteralPath $z.Pfad
                    $wert = $null; $typ = $null
                    if ($schluessel) {
                        $k = Get-Item -LiteralPath $z.Pfad -ErrorAction Stop
                        if ($k.GetValueNames() -contains $z.Name) { $wert = $k.GetValue($z.Name); $typ = $k.GetValueKind($z.Name).ToString() }
                    }
                    [ordered]@{ Pfad = $z.Pfad; Name = $z.Name; Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel }
                })
            $alleAus = $true
            foreach ($w in $werte) { if ($w.Wert -ne 0) { $alleAus = $false } }
            $an = @($werte | Where-Object { $_.Wert -eq 1 })
            if ($alleAus) { $text = (T 'katalog.wert.aus') } elseif ($an.Count -gt 0) { $text = (T 'katalog.gamedvr.an' (($an | ForEach-Object { $_.Name }) -join ', ')) } else { $text = (T 'katalog.gamedvr.teilweise') }
            [pscustomobject]@{ Aktiv = $alleAus; Wert = $text; Zustand = [ordered]@{ Werte = $werte } }
        }
        Ausfuehren = {
            param($Variante)
            $ziele = @(
                @{ Pfad = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled' },
                @{ Pfad = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled' },
                @{ Pfad = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'HistoricalCaptureEnabled' }
            )
            foreach ($z in $ziele) {
                if (-not (Test-Path -LiteralPath $z.Pfad)) { New-Item -Path $z.Pfad -Force -ErrorAction Stop | Out-Null }
                New-ItemProperty -LiteralPath $z.Pfad -Name $z.Name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
            }
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            foreach ($v in @($Vorher.Werte)) {
                $pfad = [string]$v.Pfad; $name = [string]$v.Name
                if ($null -eq $v.Wert) {
                    if (Test-Path -LiteralPath $pfad) {
                        if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                        if ($v.SchluesselVorhanden -eq $false) {
                            $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                            if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                        }
                    }
                } else {
                    if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                    $wert = $v.Wert
                    if ($v.Typ -eq 'DWord') { $wert = [int]$wert }
                    New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $v.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
                }
            }
        }
    },

    @{
        Id          = 'gaming.maus'
        Kategorie   = 'Gaming'
        Pruefung    = 'Mausbeschleunigung'
        Nutzen      = 'mittel'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'Benutzer'
        Varianten   = $null
        Voraussetzung = {
            try {
                $besitzer = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction Stop).User })
            } catch { return (T 'katalog.benutzer.nichtErmittelt' $_.Exception.Message) }
            if (-not $besitzer) { return (T 'katalog.benutzer.keinExplorer') }
            if ($besitzer -notcontains $env:USERNAME) { return (T 'katalog.benutzer.falsch' $env:USERNAME (($besitzer | Select-Object -Unique) -join ', ')) }
        }
        Lesen = {
            $pfad = 'HKCU:\Control Panel\Mouse'
            $namen = @('MouseSpeed', 'MouseThreshold1', 'MouseThreshold2')
            $schluessel = Test-Path -LiteralPath $pfad
            $werte = @(foreach ($n in $namen) {
                    $wert = $null; $typ = $null
                    if ($schluessel) {
                        $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                        if ($k.GetValueNames() -contains $n) { $wert = $k.GetValue($n); $typ = $k.GetValueKind($n).ToString() }
                    }
                    [ordered]@{ Pfad = $pfad; Name = $n; Wert = $wert; Typ = $typ; SchluesselVorhanden = $schluessel }
                })
            $alleNull = $true
            foreach ($w in $werte) { if ([string]$w.Wert -ne '0') { $alleNull = $false } }
            $speed = $werte[0].Wert
            if ($alleNull) { $text = (T 'katalog.maus.aus') } elseif ([string]$speed -eq '0') { $text = (T 'katalog.maus.ausSchwellen') } else { $text = (T 'katalog.maus.an' $speed) }
            [pscustomobject]@{ Aktiv = $alleNull; Wert = $text; Zustand = [ordered]@{ Werte = $werte } }
        }
        Ausfuehren = {
            param($Variante)
            $pfad = 'HKCU:\Control Panel\Mouse'
            if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
            foreach ($n in @('MouseSpeed', 'MouseThreshold1', 'MouseThreshold2')) {
                New-ItemProperty -LiteralPath $pfad -Name $n -PropertyType String -Value '0' -Force -ErrorAction Stop | Out-Null
            }
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            foreach ($v in @($Vorher.Werte)) {
                $pfad = [string]$v.Pfad; $name = [string]$v.Name
                if ($null -eq $v.Wert) {
                    if (Test-Path -LiteralPath $pfad) {
                        if ((Get-Item -LiteralPath $pfad -ErrorAction Stop).GetValueNames() -contains $name) { Remove-ItemProperty -LiteralPath $pfad -Name $name -ErrorAction Stop }
                        if ($v.SchluesselVorhanden -eq $false) {
                            $k = Get-Item -LiteralPath $pfad -ErrorAction Stop
                            if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $pfad -ErrorAction Stop }
                        }
                    }
                } else {
                    if (-not (Test-Path -LiteralPath $pfad)) { New-Item -Path $pfad -Force -ErrorAction Stop | Out-Null }
                    $wert = $v.Wert
                    if ($v.Typ -eq 'DWord') { $wert = [int]$wert }
                    New-ItemProperty -LiteralPath $pfad -Name $name -PropertyType $v.Typ -Value $wert -Force -ErrorAction Stop | Out-Null
                }
            }
        }
    },

    @{
        Id          = 'netz.eee'
        Kategorie   = 'Gaming'
        Pruefung    = 'Netzwerkkarte: Energiesparfunktionen'
        Nutzen      = 'gering'
        Aufwand     = 'gering'
        Risiko      = 'gering'
        Neustart    = $false
        Bereich     = 'System'
        Varianten   = $null
        Voraussetzung = {
            $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) { return (T 'katalog.voraus.admin') }
            if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) { return (T 'katalog.eee.keineCmdlets') }
            $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and [string]$_.PhysicalMediaType -match '802\.3' })
            if (-not $ad) { return (T 'katalog.eee.keinAdapter') }
        }
        Lesen = {
            if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{ Aktiv = $false; Wert = (T 'katalog.eee.cmdletsLesen'); Zustand = $null }
            }
            $schluessel = @('*EEE', 'EEELinkAdvertisement', '*GreenEthernet', 'EnableGreenEthernet', 'AdvancedEEE', 'ULPMode', 'PowerSavingMode')
            $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and [string]$_.PhysicalMediaType -match '802\.3' } | Sort-Object Name)
            $eintraege = @(foreach ($a in $ad) {
                    foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue | Where-Object { $_.RegistryKeyword -in $schluessel } | Sort-Object RegistryKeyword)) {
                        [ordered]@{ Adapter = [string]$a.Name; Schluessel = [string]$p.RegistryKeyword; Wert = "$(@($p.RegistryValue)[0])" }
                    }
                })
            $an = @($eintraege | Where-Object { $_.Wert -ne '0' })
            if ($ad.Count -eq 0) { $text = (T 'katalog.eee.keinAdapterLesen') }
            elseif ($eintraege.Count -eq 0) { $text = (T 'katalog.eee.keine' (($ad | ForEach-Object { $_.Name }) -join ', ')) }
            elseif ($an.Count -eq 0) { $text = (T 'katalog.eee.alleAus' (($eintraege | ForEach-Object { "$($_.Adapter): $($_.Schluessel)" }) -join ', ')) }
            else { $text = (T 'katalog.eee.aktiv' (($an | ForEach-Object { "$($_.Adapter): $($_.Schluessel) = $($_.Wert)" }) -join ', ')) }
            [pscustomobject]@{ Aktiv = ($an.Count -eq 0); Wert = $text; Zustand = [ordered]@{ Eintraege = $eintraege } }
        }
        Ausfuehren = {
            param($Variante)
            $schluessel = @('*EEE', 'EEELinkAdvertisement', '*GreenEthernet', 'EnableGreenEthernet', 'AdvancedEEE', 'ULPMode', 'PowerSavingMode')
            $ad = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and [string]$_.PhysicalMediaType -match '802\.3' } | Sort-Object Name)
            $geaendert = New-Object System.Collections.ArrayList
            foreach ($a in $ad) {
                foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction Stop | Where-Object { $_.RegistryKeyword -in $schluessel })) {
                    if ("$(@($p.RegistryValue)[0])" -ne '0') {
                        Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $p.RegistryKeyword -RegistryValue '0' -NoRestart -ErrorAction Stop | Out-Null
                        if (-not $geaendert.Contains([string]$a.Name)) { [void]$geaendert.Add([string]$a.Name) }
                    }
                }
            }
            foreach ($n in $geaendert) {
                Restart-NetAdapter -Name $n -ErrorAction Stop | Out-Null
                # Warten, bis der Adapter wieder verbunden ist (höchstens 30 s), damit die Kontrolle danach ihn wieder sieht
                for ($i = 0; $i -lt 30; $i++) {
                    $s = Get-NetAdapter -Name $n -ErrorAction SilentlyContinue
                    if ($s -and $s.Status -eq 'Up') { break }
                    Start-Sleep -Seconds 1
                }
            }
        }
        Rueckgaengig = {
            param($Vorher)
            if ($null -eq $Vorher) { throw (T 'katalog.zustand.fehlt') }
            $geaendert = New-Object System.Collections.ArrayList
            foreach ($e in @($Vorher.Eintraege)) {
                $aktuell = Get-NetAdapterAdvancedProperty -Name ([string]$e.Adapter) -RegistryKeyword ([string]$e.Schluessel) -ErrorAction Stop
                if ("$(@($aktuell.RegistryValue)[0])" -ne [string]$e.Wert) {
                    Set-NetAdapterAdvancedProperty -Name ([string]$e.Adapter) -RegistryKeyword ([string]$e.Schluessel) -RegistryValue ([string]$e.Wert) -NoRestart -ErrorAction Stop | Out-Null
                    if (-not $geaendert.Contains([string]$e.Adapter)) { [void]$geaendert.Add([string]$e.Adapter) }
                }
            }
            foreach ($n in $geaendert) {
                Restart-NetAdapter -Name $n -ErrorAction Stop | Out-Null
                for ($i = 0; $i -lt 30; $i++) {
                    $s = Get-NetAdapter -Name $n -ErrorAction SilentlyContinue
                    if ($s -and $s.Status -eq 'Up') { break }
                    Start-Sleep -Seconds 1
                }
            }
        }
    }

    #endregion
)
