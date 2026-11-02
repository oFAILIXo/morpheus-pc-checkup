# Titles, explanations and command display of the catalog actions (English). Key = action id.
@{
    'defender.netzwerkschutz' = @{
        Titel      = 'Turn on network protection'
        Erklaerung = 'Blocks connections to known phishing and malware servers in all programs. You will not notice anything in everyday use, except that a dubious website may be blocked.'
        Befehle    = @{
            Ausfuehren   = 'Set-MpPreference -EnableNetworkProtection Enabled'
            Rueckgaengig = 'Set-MpPreference -EnableNetworkProtection <previous>   # Disabled, Enabled or AuditMode, depending on the old value'
            Erklaerung   = @(
                'Set-MpPreference changes a Microsoft Defender setting.',
                '-EnableNetworkProtection Enabled turns network protection on in blocking mode (AuditMode would only log, Disabled is off).',
                'When undoing, the old value (off, on or audit only) is restored.'
            )
        }
    }
    'defender.pua' = @{
        Titel      = 'Turn on protection against potentially unwanted apps (PUA)'
        Erklaerung = 'Defender then blocks adware, bundled extra software in installers and similar unwanted programs. Rarely, a harmless helper program is blocked as well.'
        Befehle    = @{
            Ausfuehren   = 'Set-MpPreference -PUAProtection Enabled'
            Rueckgaengig = 'Set-MpPreference -PUAProtection <previous>   # Disabled, Enabled or AuditMode, depending on the old value'
            Erklaerung   = @(
                'Set-MpPreference changes a Microsoft Defender setting.',
                '-PUAProtection Enabled blocks potentially unwanted applications (AuditMode would only report them, Disabled is off).',
                'When undoing, the old value is restored.'
            )
        }
    }
    'defender.asr-basis' = @{
        Titel      = 'Turn on two attack surface reduction rules (driver abuse, LSASS)'
        Erklaerung = 'Prevents malware from abusing known vulnerable drivers or stealing credentials from the LSASS process. Very old vendor drivers (e.g. from some overclocking tools) may be blocked as a result; "Audit only" is for testing without blocking.'
        VariantenNamen = @('Block', 'Audit only')
        Befehle    = @{
            Ausfuehren   = 'Add-MpPreference -AttackSurfaceReductionRules_Ids ''56a863a9-875e-4185-98a7-b882c64b5ce5'' -AttackSurfaceReductionRules_Actions <variant>
Add-MpPreference -AttackSurfaceReductionRules_Ids ''9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'' -AttackSurfaceReductionRules_Actions <variant>   # <variant>: Block = Enabled, Audit only = AuditMode; only for rules that are not yet set to Block/Audit'
            Rueckgaengig = 'Add-MpPreference -AttackSurfaceReductionRules_Ids <rule> -AttackSurfaceReductionRules_Actions <old mode>   # if the rule was set before
Remove-MpPreference -AttackSurfaceReductionRules_Ids <rule>   # if the rule was not set before'
            Erklaerung   = @(
                'Add-MpPreference adds an attack surface reduction (ASR) rule or changes its mode.',
                '56a863a9-… = block abuse of vulnerable signed drivers; 9e6c4e1f-… = block credential stealing from LSASS.',
                '-AttackSurfaceReductionRules_Actions: Enabled = block, AuditMode = log only.',
                'Remove-MpPreference removes a rule again, so it is afterwards exactly as "not set" as before.'
            )
        }
    }
    'fernzugriff.remoteunterstuetzung' = @{
        Titel      = 'Turn off Remote Assistance'
        Erklaerung = 'Nobody can connect to your PC through "Remote Assistance" (an invitation for remote help) any more. You will only notice this if you use that feature on purpose.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'' -Name ''fAllowToGetHelp'' -PropertyType DWord -Value 0 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'' -Name ''fAllowToGetHelp'' -PropertyType DWord -Value <previous> -Force   # if the value did not exist before: Remove-ItemProperty -Path ''…'' -Name ''fAllowToGetHelp'''
            Erklaerung   = @(
                'New-ItemProperty creates a registry value or overwrites it (-Force).',
                'fAllowToGetHelp is the setting "Allow Remote Assistance connections to this computer"; 0 = do not allow, 1 = allow.',
                '-PropertyType DWord is the registry data type (32-bit number).',
                'Undo restores the old value, or deletes the value if it did not exist before.'
            )
        }
    }
    'fernzugriff.rdp' = @{
        Titel      = 'Turn off Remote Desktop (RDP)'
        Erklaerung = 'Nobody can connect to this PC through Remote Desktop any more; this closes a door that is attacked often. If you use RDP to control this PC from elsewhere or from another computer, that will no longer work.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'' -Name ''fDenyTSConnections'' -PropertyType DWord -Value 1 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'' -Name ''fDenyTSConnections'' -PropertyType DWord -Value <previous> -Force   # if the value did not exist before: Remove-ItemProperty -Path ''…'' -Name ''fDenyTSConnections'''
            Erklaerung   = @(
                'New-ItemProperty creates a registry value or overwrites it (-Force).',
                'fDenyTSConnections is the switch behind "Remote Desktop" in Settings; 1 = deny connections, 0 = allow.',
                '-PropertyType DWord is the registry data type (32-bit number).',
                'Undo restores the old value, or deletes the value if it did not exist before.'
            )
        }
    }
    'netz.llmnr' = @{
        Titel      = 'Turn off LLMNR (name resolution by broadcast)'
        Erklaerung = 'LLMNR is an old method that lets computers on a network resolve names by broadcast; on foreign networks it can be used to capture sign-in hashes. On a home network you will not notice anything, except that devices without their own DNS entry may no longer be found by name.'
        Befehle    = @{
            Ausfuehren   = 'New-Item -Path ''HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'' -Force   # only if the key is missing
New-ItemProperty -Path ''HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'' -Name ''EnableMulticast'' -PropertyType DWord -Value 0 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'' -Name ''EnableMulticast'' -PropertyType DWord -Value <previous> -Force   # if the value did not exist before: Remove-ItemProperty -Path ''…'' -Name ''EnableMulticast''; if Run created the key, the empty key is removed with Remove-Item'
            Erklaerung   = @(
                'New-Item creates the policy key if it does not exist yet.',
                'New-ItemProperty sets the value EnableMulticast in the DNS client policy "Turn off multicast name resolution"; 0 = LLMNR off.',
                '-PropertyType DWord is the registry data type (32-bit number).',
                'Undo restores the old value, or deletes the value and (only the key it created itself, if empty) the key.'
            )
        }
    }
    'system.wiederherstellung' = @{
        Titel      = 'Turn on system protection (restore points) on the system drive'
        Erklaerung = 'Turns on System Restore so that restore points can be created before changes; this action does not create a restore point itself. WARNING: Undoing it (turning it off) permanently deletes ALL existing restore points of the drive.'
        Befehle    = @{
            Ausfuehren   = 'Enable-ComputerRestore -Drive "$env:SystemDrive\"'
            Rueckgaengig = 'Disable-ComputerRestore -Drive "$env:SystemDrive\"   # WARNING: deletes all restore points of this drive'
            Erklaerung   = @(
                'Enable-ComputerRestore turns on system protection (System Restore) for the given drive.',
                '$env:SystemDrive is the system drive (usually C:); the backslash turns it into the drive root (C:\).',
                'Disable-ComputerRestore turns the protection off again and deletes all existing restore points of this drive; they cannot be brought back.'
            )
        }
    }
    'system.wiederherstellung-speicher' = @{
        Titel      = 'Increase restore point storage to 10 %'
        Erklaerung = 'If the storage for restore points is too small, Windows deletes older points as soon as a new one is created - often after only a few hours. With 10 % of the system drive, several points are kept. The space is only used once points are created.'
        Befehle    = @{
            Ausfuehren   = 'vssadmin resize shadowstorage /for=$env:SystemDrive /on=$env:SystemDrive /maxsize=10%'
            Rueckgaengig = 'vssadmin resize shadowstorage /for=$env:SystemDrive /on=$env:SystemDrive /maxsize=<old value in MB or UNBOUNDED>   # if the old value is smaller, Windows deletes older points'
            Erklaerung   = @(
                'vssadmin resize shadowstorage changes how much space shadow copies (which restore points consist of) may use on the drive.',
                '/for and /on: the system drive (usually C:); /maxsize=10% allows up to 10 % of the drive size.',
                'Undo restores the old limit. If it is smaller than the space in use, Windows deletes the oldest points.',
                'If Windows 11 "Point-in-time restore" is active, Windows resets the limit to its own setting at every startup (default 2 %). In that case Morpheus changes nothing and points you to the settings.'
            )
        }
    }
    'system.schnellstart' = @{
        Titel      = 'Turn off fast startup'
        Erklaerung = '"Shut down" then really shuts Windows down completely, so driver, update and BIOS changes take effect reliably. With an NVMe SSD, starting takes barely noticeably longer; hibernation stays untouched.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'' -Name ''HiberbootEnabled'' -PropertyType DWord -Value 0 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'' -Name ''HiberbootEnabled'' -PropertyType DWord -Value <previous> -Force   # if the value did not exist before: Remove-ItemProperty -Path ''…'' -Name ''HiberbootEnabled'''
            Erklaerung   = @(
                'New-ItemProperty creates a registry value or overwrites it (-Force).',
                'HiberbootEnabled is the "Turn on fast startup" switch from the power options; 0 = off, 1 = on. The hibernation file and hibernation stay unchanged (deliberately no "powercfg /hibernate off").',
                'Undo restores the old value, or deletes the value if it did not exist before.'
            )
        }
    }
    'haertung.lsa' = @{
        Titel      = 'Turn on LSA protection (without UEFI lock)'
        Erklaerung = 'Protects the Windows process that manages credentials from being read by malware. Takes effect only after a restart; very rarely, older sign-in add-on programs refuse to work afterwards. The variant without UEFI lock (value 2) is set on purpose so that it can be turned off again at any time.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'' -Name ''RunAsPPL'' -PropertyType DWord -Value 2 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'' -Name ''RunAsPPL'' -PropertyType DWord -Value <previous> -Force   # if the value did not exist before: Remove-ItemProperty -Path ''…'' -Name ''RunAsPPL'''
            Erklaerung   = @(
                'New-ItemProperty creates a registry value or overwrites it (-Force).',
                'RunAsPPL controls whether the Local Security Authority (lsass.exe) starts as a protected process. 2 = on without UEFI lock (reversible), 1 = on with UEFI lock (could not be undone through the registry and is therefore not used).',
                'The change takes effect only after a restart.',
                'Undo restores the old value, or deletes the value if it did not exist before (also effective only after a restart).'
            )
        }
    }
    'haertung.treibersperrliste' = @{
        Titel      = 'Turn on the Microsoft vulnerable driver blocklist'
        Erklaerung = 'Windows then no longer loads drivers that Microsoft has classified as exploitable. Takes effect after a restart; very old drivers of hardware tools (e.g. some overclocking or fan software) may be blocked as a result.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'' -Name ''VulnerableDriverBlocklistEnable'' -PropertyType DWord -Value 1 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'' -Name ''VulnerableDriverBlocklistEnable'' -PropertyType DWord -Value <previous> -Force   # if the value did not exist before: Remove-ItemProperty -Path ''…'' -Name ''VulnerableDriverBlocklistEnable'''
            Erklaerung   = @(
                'New-ItemProperty creates a registry value or overwrites it (-Force).',
                'VulnerableDriverBlocklistEnable turns the Microsoft vulnerable driver blocklist on (1) or off (0).',
                'The change takes effect only after a restart.',
                'Undo restores the old value, or deletes the value if it did not exist before.'
            )
        }
    }
    'energie.aspm' = @{
        Titel      = 'Turn off PCIe power management (ASPM) in the active power plan'
        Erklaerung = 'The graphics card and NVMe SSD then never put their PCIe link into a sleep state, which avoids micro-stutter on some systems. Power consumption rises slightly; on a laptop running on battery it costs some battery life.'
        Befehle    = @{
            Ausfuehren   = 'powercfg /setacvalueindex <active plan> 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg /setdcvalueindex <active plan> 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg /setactive SCHEME_CURRENT'
            Rueckgaengig = 'powercfg /setacvalueindex <original plan> 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 <old AC value>
powercfg /setdcvalueindex <original plan> 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 <old DC value>
powercfg /setactive SCHEME_CURRENT'
            Erklaerung   = @(
                'powercfg changes power plan settings. /setacvalueindex applies when plugged in (AC), /setdcvalueindex on battery (DC).',
                '501a4d13-… is the group "PCI Express", ee12f906-… the setting "Link State Power Management" (ASPM); 0 = off, 1 = moderate, 2 = maximum power savings.',
                '/setactive SCHEME_CURRENT re-applies the current plan so that the change takes effect immediately.',
                'Undo restores the old values (AC and DC) in exactly the plan that was active at the time.'
            )
        }
    }
    'gaming.spielmodus' = @{
        Titel      = 'Turn on Windows Game Mode'
        Erklaerung = 'Windows then prioritizes the running game and does not start update restarts or driver installations while you play. The effect on FPS is small; if individual games have problems, it can be turned off again.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKCU:\Software\Microsoft\GameBar'' -Name ''AutoGameModeEnabled'' -PropertyType DWord -Value 1 -Force   # creates the key first if it is missing'
            Rueckgaengig = 'New-ItemProperty -Path ''HKCU:\Software\Microsoft\GameBar'' -Name ''AutoGameModeEnabled'' -PropertyType DWord -Value <previous> -Force   # if the value did not exist before: Remove-ItemProperty -Path ''…'' -Name ''AutoGameModeEnabled'''
            Erklaerung   = @(
                'New-ItemProperty creates a registry value or overwrites it (-Force).',
                'HKCU applies only to the signed-in user. AutoGameModeEnabled is the "Game Mode" switch (1 = on, 0 = off).',
                'Undo restores the old value, or deletes the value (and a key it created itself, if empty) if it did not exist before.'
            )
        }
    }
    'gaming.hags' = @{
        Titel      = 'Turn on hardware-accelerated GPU scheduling (HAGS)'
        Erklaerung = 'The graphics card then manages its own memory, which can reduce latency and is required for DLSS Frame Generation. Takes effect only after a restart; if individual games stutter, it can be turned off again.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'' -Name ''HwSchMode'' -PropertyType DWord -Value 2 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'' -Name ''HwSchMode'' -PropertyType DWord -Value <previous> -Force   # if the value did not exist before: Remove-ItemProperty -Path ''…'' -Name ''HwSchMode'''
            Erklaerung   = @(
                'New-ItemProperty creates a registry value or overwrites it (-Force).',
                'HwSchMode is the switch behind "Hardware-accelerated GPU scheduling" (Settings > System > Display > Graphics); 2 = on, 1 = off.',
                'The change takes effect only after a restart.',
                'Undo restores the old value, or deletes the value if it did not exist before.'
            )
        }
    }
    'gaming.gamedvr' = @{
        Titel      = 'Turn off background recording (Game DVR)'
        Erklaerung = 'Windows then no longer constantly records the last minutes of gameplay, which saves FPS and video memory. Recordings through the Xbox Game Bar (e.g. "Record that"/"Save the last 30 seconds") will no longer work.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKCU:\System\GameConfigStore'' -Name ''GameDVR_Enabled'' -PropertyType DWord -Value 0 -Force
New-ItemProperty -Path ''HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'' -Name ''AppCaptureEnabled'' -PropertyType DWord -Value 0 -Force
New-ItemProperty -Path ''HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'' -Name ''HistoricalCaptureEnabled'' -PropertyType DWord -Value 0 -Force   # missing keys are created first'
            Rueckgaengig = 'New-ItemProperty -Path <key> -Name <value> -PropertyType DWord -Value <previous> -Force   # for all three values; if a value did not exist before: Remove-ItemProperty -Path <key> -Name <value>'
            Erklaerung   = @(
                'New-ItemProperty creates a registry value or overwrites it (-Force). HKCU applies only to the signed-in user.',
                'GameDVR_Enabled (System\GameConfigStore) and AppCaptureEnabled are the main switches for Game Bar game capture; 0 = off.',
                'HistoricalCaptureEnabled is the "Record what happened" switch (background recording); 0 = off. This is exactly the value the check evaluates.',
                'Undo restores each of the three values individually, or deletes it if it did not exist before.'
            )
        }
    }
    'gaming.maus' = @{
        Titel      = 'Turn off mouse acceleration'
        Erklaerung = 'The mouse then always moves the pointer in proportion to your hand movement ("Enhance pointer precision" off), which gives more consistent aiming, especially in shooters. The change needs a sign-out and sign-in and feels unfamiliar at first.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKCU:\Control Panel\Mouse'' -Name ''MouseSpeed'' -PropertyType String -Value ''0'' -Force
New-ItemProperty -Path ''HKCU:\Control Panel\Mouse'' -Name ''MouseThreshold1'' -PropertyType String -Value ''0'' -Force
New-ItemProperty -Path ''HKCU:\Control Panel\Mouse'' -Name ''MouseThreshold2'' -PropertyType String -Value ''0'' -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKCU:\Control Panel\Mouse'' -Name <value> -PropertyType String -Value ''<previous>'' -Force   # for all three values; if a value did not exist before: Remove-ItemProperty -Path ''…'' -Name <value>'
            Erklaerung   = @(
                'New-ItemProperty creates a registry value or overwrites it (-Force). HKCU applies only to the signed-in user.',
                'MouseSpeed, MouseThreshold1 and MouseThreshold2 are the three values behind "Enhance pointer precision"; all three set to "0" means: no acceleration.',
                '-PropertyType String: these values are text (REG_SZ), not numbers.',
                'Windows reads the values only after the next sign-out/sign-in. Undo restores each of the three values individually.'
            )
        }
    }
    'netz.eee' = @{
        Titel      = 'Turn off power-saving features of the LAN adapter'
        Erklaerung = 'Turns off Energy Efficient Ethernet, Green Ethernet and similar sleep modes of the connected wired network adapter, which can cause short latency spikes in online games. The network adapter restarts briefly, so the connection is gone for a few seconds.'
        Befehle    = @{
            Ausfuehren   = 'Set-NetAdapterAdvancedProperty -Name ''<adapter>'' -RegistryKeyword ''<keyword>'' -RegistryValue ''0'' -NoRestart   # for each active power-saving feature (*EEE, EEELinkAdvertisement, *GreenEthernet, EnableGreenEthernet, AdvancedEEE, ULPMode, PowerSavingMode)
Restart-NetAdapter -Name ''<adapter>'''
            Rueckgaengig = 'Set-NetAdapterAdvancedProperty -Name ''<adapter>'' -RegistryKeyword ''<keyword>'' -RegistryValue ''<previous>'' -NoRestart   # for each changed feature
Restart-NetAdapter -Name ''<adapter>'''
            Erklaerung   = @(
                'Set-NetAdapterAdvancedProperty changes an advanced driver setting of the network adapter, here through its registry keyword (-RegistryKeyword).',
                'The keywords stand for Energy Efficient Ethernet, Green Ethernet, Advanced EEE, Ultra Low Power Mode and Power Saving Mode; 0 = off. Only features that exist and are not yet off are changed, and only on connected, wired adapters.',
                '-NoRestart postpones the adapter restart to the end so that it happens only once per adapter.',
                'Restart-NetAdapter restarts the network adapter so that the setting takes effect; the connection is briefly interrupted.',
                'Undo resets each changed feature to its old value.'
            )
        }
    }
}
