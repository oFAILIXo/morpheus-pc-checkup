# Explanations for the pc-check HTML report: for each check What / Why / When harmless (English).
# Key = name of the check exactly as in the report (German identifier). If an entry is missing, the report shows the category explanation.
@{
    Status     = @{
        CRIT = 'Critical: a real security or stability risk. Fix this first.'
        WARN = 'Warning: should be fixed, but is rarely urgent. Check whether it is intended.'
        ACK  = 'Accepted: a warning that you deliberately accepted as intended (in the interface via "Accept", without it in the file accepted.psd1). It comes back after the expiry date or when the finding changes.'
        TIPP = 'Tip: not a problem, but a worthwhile improvement. Benefit, effort and risk are shown; the instructions are under "How to".'
        INFO = 'Note: information only, nothing to do.'
        OK   = 'OK: everything is fine.'
        SKIP = 'Not checked: usually admin rights are missing or the feature does not exist on this PC. Not a finding.'
    }

    Kategorien = @{
        'System & Updates'           = 'An up-to-date, activated Windows is the foundation of all security: most attacks use holes for which updates have long been available.'
        'Virenschutz'                = 'Microsoft Defender is entirely sufficient for home PCs as long as all protection features are on and the signatures are up to date.'
        'Firewall & Netzwerk'        = 'The firewall decides what may access the PC from the network. Open ports and shares are possible entry points.'
        'Konten & Anmeldung'         = 'Who can sign in and with which rights. Unnecessary or unprotected accounts are a common weak spot.'
        'Systemhärtung'              = 'Windows protection features that make attacks harder even when malware is already running. They cost hardly any performance.'
        'Verschlüsselung & Firmware' = 'Protection below Windows: the boot process, data encryption and the motherboard firmware.'
        'Fernzugriff & Dienste'      = 'Programs and services that run in the background with high rights or allow remote access. Every unnecessary one is attack surface.'
        'Autostart & Persistenz'     = 'Places where programs start automatically. This is exactly where malware settles in.'
        'Software'                   = 'Outdated programs with known holes are the most common way in after an outdated Windows.'
        'Ereignisse'                 = 'Traces in the Windows logs of recent days, e.g. failed sign-ins or disabled antivirus.'
        'Hardware'                   = 'Whether the hardware runs as well as it can: drivers, memory speed, refresh rate, faulty devices.'
        'Laufwerke & Speicherplatz'  = 'Condition and usage of the drives. Full or old drives slow things down and put data at risk.'
        'Energie'                    = 'Power-saving settings that can limit performance.'
        'Gaming & Grafik'            = 'Windows settings that make games run smoother or choppier.'
        'Auslastung'                 = 'Snapshot of the base load: what costs processing time and memory in the background.'
        'Stabilität'                 = 'Crashes, hardware errors and startup problems. If they pile up, hardware, overclocking or a driver is often behind it.'
        'Audio'                      = 'Sound settings that demonstrably cause errors: driver errors, stopped audio services, wrong default device. Read-only, no sound tuning.'
    }

    Pruefungen = @{
        'Ausführungsumgebung'                        = @{ Was = 'Whether the script was started from a Store app.'; Warum = 'Store apps distort parts of the registry for their processes. Individual results can then be wrong.'; Harmlos = 'Never: just restart by double-clicking pc-check.cmd.' }
        'Windows-Version'                            = @{ Was = 'The Windows version and whether Microsoft still provides security updates for it.'; Warum = 'After the end of support, new holes are no longer closed.'; Harmlos = 'A note about the end of support in a few months is normal; the feature update comes through Windows Update.' }
        'Windows-Aktivierung'                        = @{ Was = 'Whether Windows is properly activated.'; Warum = 'Systems that are not activated were often treated with dubious activation tools that contain malware themselves.'; Harmlos = 'Right after a fresh installation or a hardware change, activation can be pending briefly.' }
        'Windows Update: Verlauf'                    = @{ Was = 'When a monthly security update was last installed.'; Warum = 'Microsoft closes security holes on the second Tuesday of every month.'; Harmlos = 'A few days after Patch Tuesday the update can still be pending.' }
        'Windows Update: Fehler'                     = @{ Was = 'Failed update installations in the last 30 days.'; Warum = 'An update that keeps failing leaves holes open.'; Harmlos = 'A single error that worked on the next attempt.' }
        'Windows Update: ausstehend'                 = @{ Was = 'Updates that are available but not yet installed.'; Warum = 'Critical updates should be installed promptly.'; Harmlos = 'Optional driver updates and Defender signatures need no action.' }
        'Neustart ausstehend'                        = @{ Was = 'Whether Windows needs a restart for installed updates.'; Warum = 'Many updates only take effect after the restart.'; Harmlos = 'Normal right after updates; just restart soon.' }
        'Windows Update: Einstellungen'              = @{ Was = 'Whether automatic updates are turned off or paused.'; Warum = 'So-called tuning tools like to turn updates off; holes then stay open unnoticed.'; Harmlos = 'A short, deliberate pause (e.g. before an important deadline).' }
        'Registrierte Schutzprogramme'               = @{ Was = 'Which antivirus is registered with Windows and active.'; Warum = 'Without active antivirus the PC is unprotected; two at the same time slow each other down.'; Harmlos = 'A third-party antivirus instead of Defender is fine as long as exactly one is active.' }
        'Microsoft Defender: Status'                 = @{ Was = 'Whether Defender real-time, behavior and download protection are running.'; Warum = 'These are the core functions of antivirus protection.'; Harmlos = 'If another antivirus is active, Defender deliberately switches to passive mode.' }
        'Defender: Manipulationsschutz'              = @{ Was = 'Whether programs can secretly change Defender settings.'; Warum = 'Malware tries to turn off the antivirus first.'; Harmlos = 'Practically never; it should always be on.' }
        'Defender: Signaturen'                       = @{ Was = 'How old the virus signatures are.'; Warum = 'Outdated signatures do not detect new malware.'; Harmlos = 'A day of delay if the PC was off for a while.' }
        'Defender: Scans'                            = @{ Was = 'When Defender last ran a quick scan.'; Warum = 'Regular scans find what escaped real-time protection.'; Harmlos = 'If the PC is only used briefly, Defender scans less often; scanning manually now and then is enough.' }
        'Microsoft Defender: Einstellungen'          = @{ Was = 'Extra protection such as blocking unwanted apps, cloud protection, network protection, folder protection.'; Warum = 'These features catch things the basic protection does not detect.'; Harmlos = 'Network and folder protection are optional; folder protection often raises false alarms with games.' }
        'Defender: ASR-Regeln'                       = @{ Was = 'Rules that block typical attack techniques (e.g. Office starting programs).'; Warum = 'They stop whole classes of attacks, including unknown ones.'; Harmlos = 'On home PCs they are off by default; this is a note, not an error.' }
        'Defender: Ausnahmen'                        = @{ Was = 'Folders, programs and file types that Defender does not scan.'; Warum = 'Exclusions that are too broad (whole drives, downloads, PowerShell) are an open barn door.'; Harmlos = 'Narrowly defined exclusions for individual game or project folders.' }
        'Microsoft Defender: Funde'                  = @{ Was = 'What Defender found in the last few days.'; Warum = 'An active threat that was not removed is an emergency.'; Harmlos = 'Findings that were already removed, e.g. a file caught from a download.' }
        'Firewall-Profile'                           = @{ Was = 'Whether Windows Firewall is on in all network profiles and blocks inbound connections.'; Warum = 'Without a firewall every open service is reachable from the network.'; Harmlos = 'If a third-party firewall is active, Windows Firewall may be off.' }
        'Netzwerkprofile'                            = @{ Was = 'Whether your network is classified as "Private" or "Public".'; Warum = 'In the Public profile Windows is more cautious (no network discovery).'; Harmlos = 'At home both are fine; on the road always Public.' }
        'Firewall: eigene Eingangsregeln'            = @{ Was = 'Firewall rules from programs that allow inbound connections.'; Warum = 'Old rules for long-deleted programs pile up and needlessly open doors.'; Harmlos = 'Rules for games and launchers that you use are normal as long as the PC is behind a router.' }
        'Offene Netzwerkports'                       = @{ Was = 'Which programs are waiting for connections from the network.'; Warum = 'Services such as databases, VNC or RDP should not be reachable unintentionally.'; Harmlos = 'Windows default ports and ports of well-known programs (Steam, NVIDIA, Spotify) on the home network.' }
        'Router-Portweiterleitungen (UPnP)'          = @{ Was = 'Whether programs have opened ports on the router through UPnP.'; Warum = 'Then the PC is directly reachable from the internet.'; Harmlos = 'Games and consoles occasionally open ports for multiplayer features.' }
        'SMB-Konfiguration'                          = @{ Was = 'Settings of Windows file sharing (SMB).'; Warum = 'The outdated SMBv1 was the entry point of major attack waves (WannaCry).'; Harmlos = 'Missing signing is a note on a home network, not a risk.' }
        'Freigaben'                                  = @{ Was = 'Folders that are shared on the network.'; Warum = 'Shares with write permission for "Everyone" can be changed by any device on the network.'; Harmlos = 'Deliberately set up shares with user sign-in.' }
        'LLMNR / NetBIOS'                            = @{ Was = 'Old methods for name resolution on the local network.'; Warum = 'On foreign networks they can be used to capture sign-in hashes.'; Harmlos = 'On a desktop that is only connected to your own home network.' }
        'Proxy und Hosts-Datei'                      = @{ Was = 'Whether internet traffic goes through a proxy or the hosts file redirects addresses.'; Warum = 'Malware likes to redirect traffic this way; anti-telemetry tools use it to block updates.'; Harmlos = 'A deliberately set up company or school proxy.' }
        'DNS-Server'                                 = @{ Was = 'Which DNS servers the network adapters use.'; Warum = 'Manipulated DNS servers redirect to fake sites.'; Harmlos = 'Router, provider or well-known providers (Google 8.8.8.8, Cloudflare 1.1.1.1, Quad9 9.9.9.9).' }
        'Lokale Benutzerkonten'                      = @{ Was = 'Which accounts exist on the PC and are active.'; Warum = 'The guest account and the built-in administrator account are popular attack targets.'; Harmlos = 'Your own accounts and disabled system accounts created by programs.' }
        'Administratorgruppe'                        = @{ Was = 'Who has full rights on the PC.'; Warum = 'Every administrator can change everything, including protection features.'; Harmlos = 'An everyday account with admin rights is common at home as long as User Account Control is on.' }
        'Kennwort- und Sperrrichtlinie'              = @{ Was = 'Minimum password length and lockout after failed attempts.'; Warum = 'Without a lockout, passwords of local accounts can be tried as often as you like.'; Harmlos = 'When signing in with a Microsoft account and PIN (protected by the TPM).' }
        'Automatische Anmeldung'                     = @{ Was = 'Whether Windows signs in automatically without a password.'; Warum = 'Then anyone with access to the PC has immediate access; a password stored in plain text is critical.'; Harmlos = 'On a pure media PC without personal data.' }
        'Bildschirmsperre'                           = @{ Was = 'Whether the PC locks automatically after inactivity.'; Warum = 'Protects against access when you leave your seat.'; Harmlos = 'Uncritical at home without housemates; just press Win+L when you leave.' }
        'Benutzerkontensteuerung (UAC)'              = @{ Was = 'Whether Windows asks before changes with admin rights.'; Warum = 'Without UAC every program runs with full rights.'; Harmlos = 'Never turn it off.' }
        'Kernisolierung (VBS / Speicherintegrität)'  = @{ Was = 'Whether the Windows kernel is protected against manipulated drivers by virtualization.'; Warum = 'One of the most effective protection mechanisms against deep-seated malware.'; Harmlos = 'If a required old driver prevents it; Windows Security then shows which one.' }
        'LSA-Schutz'                                 = @{ Was = 'Whether the process that manages credentials is specially protected.'; Warum = 'Makes it harder to read passwords from memory.'; Harmlos = 'Rarely; it should be on.' }
        'Treiber-Sperrliste und Smart App Control'   = @{ Was = 'Whether Windows blocks known vulnerable drivers and whether Smart App Control is active.'; Warum = 'Attackers load old, vulnerable drivers to switch off protection features.'; Harmlos = 'Smart App Control being off is normal; it can only be turned on during a fresh installation.' }
        'SmartScreen'                                = @{ Was = 'Whether Windows checks downloaded programs and websites for reputation.'; Warum = 'SmartScreen warns about known malware and scam sites.'; Harmlos = 'Practically never; it should be on.' }
        'Exploit-Schutz (systemweit)'                = @{ Was = 'Basic memory protection features (DEP, ASLR, CFG, SEHOP).'; Warum = 'They make exploiting program errors considerably harder.'; Harmlos = 'Never; disabled values usually come from tuning tools.' }
        'Spectre/Meltdown-Schutz'                    = @{ Was = 'Whether protections against CPU vulnerabilities were switched off through the registry.'; Warum = 'A well-known but ineffective "performance tweak" with real risk.'; Harmlos = 'Only on test PCs without personal data.' }
        'CPU-Microcode'                              = @{ Was = 'Which microcode version the CPU uses.'; Warum = 'Microcode updates close security holes in the CPU itself.'; Harmlos = 'Information only; new microcode comes through a BIOS or Windows update.' }
        'PowerShell-Sicherheit'                      = @{ Was = 'Whether PowerShell scripts from the internet may run without a warning.'; Warum = 'Unrestricted/Bypass as a permanent setting makes script-based attacks easier.'; Harmlos = 'RemoteSigned for your own scripts; a one-time Bypass at startup (as with pc-check) changes nothing permanently.' }
        'Veraltete Anmeldeverfahren und Protokolle'  = @{ Was = 'Old sign-in methods (WDigest, LM/NTLMv1) and encryption (SSL, TLS 1.0/1.1).'; Warum = 'They are broken and let passwords or connections be captured.'; Harmlos = 'Only needed for very old devices on the home network.' }
        'Optionale Windows-Features'                 = @{ Was = 'Additional Windows features that are turned on.'; Warum = 'Old features such as SMBv1, PowerShell 2.0 or Telnet are unnecessary attack surface.'; Harmlos = 'Hyper-V, WSL or .NET 3.5 for programs that you use.' }
        'Entwicklermodus und sudo'                   = @{ Was = 'Whether features for software developers are active.'; Warum = 'They loosen some protection features.'; Harmlos = 'Normal for developers; otherwise turn them off.' }
        'Secure Boot'                                = @{ Was = 'Whether only signed software may start the PC.'; Warum = 'Protects against malware that settles in before Windows (bootkits). Many anti-cheat systems require it.'; Harmlos = 'With dual boot on some Linux variants; otherwise turn it on.' }
        'Secure-Boot-Zertifikate 2023'               = @{ Was = 'Whether the new Microsoft certificates for Secure Boot are stored in the motherboard.'; Warum = 'The old 2011 certificates expire in 2026; without the new ones there are no more updates for the boot process.'; Harmlos = 'Windows Update usually installs them itself; otherwise a BIOS update helps.' }
        'TPM'                                        = @{ Was = 'Whether the security chip (TPM) is present and ready.'; Warum = 'It protects keys for BitLocker, PIN and Windows Hello.'; Harmlos = 'On some motherboards it has to be turned on in the BIOS (Intel PTT, AMD fTPM).' }
        'BitLocker'                                  = @{ Was = 'Whether the system drive is encrypted.'; Warum = 'Protects data in case of theft, repair or disposal of the drive.'; Harmlos = 'On a desktop at home often off on purpose. Important: keep the recovery key safe if it is on.' }
        'BIOS/UEFI-Version'                          = @{ Was = 'Version and age of the motherboard firmware.'; Warum = 'BIOS updates bring CPU security fixes and new Secure Boot certificates.'; Harmlos = 'Older motherboards often no longer get updates; then there is nothing to do.' }
        'Wiederherstellung'                          = @{ Was = 'The Windows recovery environment and restore points.'; Warum = 'They rescue Windows after faulty updates or drivers.'; Harmlos = 'Missing restore points are a note; they do not replace a data backup.' }
        'Datensicherung'                             = @{ Was = 'Whether File History, OneDrive folder backup or a system image is set up.'; Warum = 'Defective drives, ransomware or accidental deletion can only be fixed with a backup; restore points do not back up your own files.'; Harmlos = 'If you back up with another program or to a NAS; then add the finding to the accepted list.' }
        'Remotedesktop'                              = @{ Was = 'Whether others can connect to this PC through Remote Desktop.'; Warum = 'RDP is one of the most attacked entry points when it is reachable from the internet.'; Harmlos = 'If you deliberately connect from the home network.' }
        'Remoteunterstützung'                        = @{ Was = 'Whether Windows Remote Assistance is allowed.'; Warum = 'It is abused in phone scams ("Microsoft support").'; Harmlos = 'If you use it to help family.' }
        'Fernzugriffsdienste und -programme'         = @{ Was = 'Installed remote maintenance programs (TeamViewer, AnyDesk ...) and remote administration services.'; Warum = 'Unused remote maintenance is a common way in, especially with scam calls.'; Harmlos = 'A current program that you deliberately use yourself.' }
        'Dienste von Drittanbietern'                 = @{ Was = 'Background services from other vendors and whether they are digitally signed.'; Warum = 'Unsigned services run with system rights without their origin being proven.'; Harmlos = 'Older driver software from well-known vendors (printers, mice) is often unsigned.' }
        'Dienstpfade und Berechtigungen'             = @{ Was = 'Whether services are set up in a way that normal users could manipulate them.'; Warum = 'Malware can gain system rights this way.'; Harmlos = 'Paths without quotation marks under Program Files are only theoretically exploitable, but should be corrected.' }
        'Treiber: bekannt anfällige und unsignierte' = @{ Was = 'Drivers with known holes (e.g. from RGB, OC or monitoring tools) and unsigned drivers.'; Warum = 'Attackers and cheats load exactly such drivers to switch off protection features.'; Harmlos = 'Drivers that only appear as "removed" in the logs.' }
        'Systemdateien: Signaturen (Sigcheck)'        = @{ Was = 'Microsoft Sysinternals Sigcheck looks in C:\Windows\System32 and System32\drivers for executable files without a valid signature.'; Warum = 'Windows files are signed by Microsoft; an unsigned file there may have been replaced or placed by malware.'; Harmlos = 'Old printer, scanner or driver software sometimes places unsigned files there. Catalog-signed Windows files that Sigcheck reports as unsigned are harmless too.' }
        'Autostart-Einträge'                         = @{ Was = 'Programs that start automatically when you sign in.'; Warum = 'Malware registers itself here; too many entries slow down startup.'; Harmlos = 'Unsigned tools from well-known vendors (e.g. mouse software).' }
        'Autostarts: Signaturen (Autoruns)'           = @{ Was = 'Microsoft Sysinternals Autoruns lists all autostarts (sign-in, services, drivers, scheduled tasks, Explorer extensions, Winlogon etc.) and checks their signature. The check only runs if Autoruns is set up under "Tools". Morpheus uses the tool without the VirusTotal comparison so that no data leaves the PC.'; Warum = 'Unsigned services, drivers and tasks often run with SYSTEM rights. Malware settles in there.'; Harmlos = 'Small tools, old software and self-built programs are often unsigned. Disabled entries do not count.' }
        'Autostarts: beschreibbare Pfade (Autoruns)'  = @{ Was = 'Checks whether a normal user program may change the started file or its folder.'; Warum = 'If such an entry runs as a service, driver or task with SYSTEM rights, malware can replace the file without admin rights and thereby gain admin rights (privilege escalation).'; Harmlos = 'Programs in AppData that only start as the signed-in user (e.g. chat or music apps) are common and only give a note.' }
        'Systemnahe Autostarts (Winlogon, IFEO, AppInit)' = @{ Was = 'Hidden startup options deep in the system.'; Warum = 'Normal programs practically never use them; malware does.'; Harmlos = 'Process Explorer as a replacement for Task Manager.' }
        'Geplante Aufgaben'                          = @{ Was = 'Scheduled tasks from third parties.'; Warum = 'A popular place for malware to settle in permanently.'; Harmlos = 'Updaters of browsers, graphics drivers and game launchers.' }
        'WMI-Ereignisabonnements'                    = @{ Was = 'Hidden automations through the Windows management interface.'; Warum = 'Used by fileless malware.'; Harmlos = 'Entries from vendor tools (e.g. Dell, HP); otherwise check closely.' }
        'Laufende Programme (Signatur und Ort)'      = @{ Was = 'Running programs without a valid digital signature.'; Warum = 'Unsigned programs from user folders are a typical malware pattern.'; Harmlos = 'Small tools, open-source programs (e.g. Git Bash) and driver software.' }
        'Browser-Erweiterungen'                      = @{ Was = 'Installed extensions in Chrome, Edge, Brave, Vivaldi, Opera and Firefox.'; Warum = 'Extensions with access to all websites can read passwords and sessions; abandoned ones are often sold and abused.'; Harmlos = 'Well-known, maintained extensions such as ad blockers or password managers.' }
        'Installierte Programme'                     = @{ Was = 'Programs with known holes or without vendor support.'; Warum = 'Outdated programs are a common way in, e.g. through manipulated files.'; Harmlos = 'Rarely; update or uninstall.' }
        'Software-Updates (winget)'                  = @{ Was = 'Programs for which a newer version is available.'; Warum = 'Updates close security holes. In Morpheus, choose and install them under Tools > Update programs; the console scan still offers them at the end.'; Harmlos = 'Game launchers and programs with their own update function update themselves.' }
        'Fehlgeschlagene Anmeldungen'                = @{ Was = 'Wrong password entries in recent days.'; Warum = 'Many failed attempts, especially from the internet, point to an attack.'; Harmlos = 'Typos and Windows sign-in dialogs (msedgewebview2) without an account name.' }
        'Netzwerk- und RDP-Anmeldungen'              = @{ Was = 'Successful sign-ins over the network or through Remote Desktop.'; Warum = 'Unexpected sign-ins from outside would be an emergency.'; Harmlos = 'Your own connections from the home network.' }
        'Konto- und Gruppenänderungen'               = @{ Was = 'Accounts that were created, changed or added to groups.'; Warum = 'Attackers like to create their own administrator accounts.'; Harmlos = 'Account changes by the system (sync with the Microsoft account) or by installations.' }
        'Gelöschte Ereignisprotokolle'               = @{ Was = 'Whether the Windows logs were cleared.'; Warum = 'Attackers cover their tracks this way.'; Harmlos = 'Cleanup programs such as CCleaner clear logs too.' }
        'Neu installierte Dienste'                   = @{ Was = 'Services and drivers that were installed in the last few days.'; Warum = 'Shows what has newly settled in the system.'; Harmlos = 'Services from updates and programs that you installed yourself.' }
        'Defender-Ereignisse'                        = @{ Was = 'Detections, shutdowns and configuration changes of Defender.'; Warum = 'Disabled protection or new exclusions without your doing are a warning sign.'; Harmlos = 'Changes that you made yourself.' }
        'Auffällige PowerShell-Skripte'              = @{ Was = 'Scripts that Windows logged as suspicious.'; Warum = 'Malware often uses PowerShell.'; Harmlos = 'Installers and administration scripts often trigger this.' }
        'Neue Firewall-Regeln'                       = @{ Was = 'Firewall rules that were created in the last few days.'; Warum = 'Shows which programs have newly gained access from the network.'; Harmlos = 'Rules from games and programs that you just installed.' }
        'Blockierte Treiber/Dateien (Code Integrity)' = @{ Was = 'Files and drivers that Windows blocked because of a missing signature.'; Warum = 'Shows that protection features are working.'; Harmlos = 'Mostly harmless, e.g. old DLLs in games.' }
        'Prozessor'                                  = @{ Was = 'CPU model and the measured clock speed.'; Warum = 'Shows whether the CPU reaches its turbo.'; Harmlos = 'Information only.' }
        'Arbeitsspeicher'                            = @{ Was = 'RAM size, speed and whether dual channel is active.'; Warum = 'Without XMP/EXPO and with only one module you noticeably give away performance.'; Harmlos = 'Laptops and prebuilt PCs often run at the standard speed on purpose.' }
        'Grafikkarte und Treiber'                    = @{ Was = 'Graphics card and age of the driver.'; Warum = 'New drivers bring performance for new games and security fixes.'; Harmlos = 'A driver that is a few months old without problems.' }
        'Bildschirme und Bildwiederholrate'          = @{ Was = 'Resolution and refresh rate of each monitor.'; Warum = 'A 144 Hz monitor running at 60 Hz is the most common wasted performance gain.'; Harmlos = '59 instead of 60 Hz is the same (59.94 Hz).' }
        'Geräte mit Problemen'                       = @{ Was = 'Devices in Device Manager with errors or without a driver.'; Warum = 'Missing drivers lead to performance or functional problems.'; Harmlos = 'Devices that were deliberately disabled.' }
        'Wichtige Treiber'                           = @{ Was = 'Vendor drivers for chipset, network, audio and storage.'; Warum = 'Outdated chipset drivers can cost performance and stability.'; Harmlos = 'Information only; Windows Update often provides suitable drivers.' }
        'Laufwerke (Typ und Zustand)'                = @{ Was = 'Type (HDD/SSD/NVMe), condition and wear of the drives.'; Warum = 'Windows on a hard disk (HDD) is the biggest performance brake; a drive that reports problems may fail soon.'; Harmlos = 'A SATA SSD is fast enough for everyday use.' }
        'Festplatten (HDD)'                          = @{ Was = 'Whether classic hard disks are installed.'; Warum = 'Games load much more slowly from an HDD.'; Harmlos = 'HDDs for data and backups make sense.' }
        'Freier Speicherplatz'                       = @{ Was = 'Free space per drive.'; Warum = 'Below 10-15 % free, Windows and SSDs become slower and updates fail.'; Harmlos = 'Pure data drives may be fuller.' }
        'Größte Speicherverbraucher'                 = @{ Was = 'The ten largest folders and files per drive (snapshot).'; Warum = 'Shows where space is lost before a drive fills up.'; Harmlos = 'Information only; pagefile.sys, hiberfil.sys and swapfile.sys belong to Windows and must not be deleted.' }
        'TRIM und Laufwerksoptimierung'              = @{ Was = 'Whether SSDs are regularly "tidied up" (TRIM).'; Warum = 'Without TRIM, SSDs become slower over time.'; Harmlos = 'Practically never; it should be on.' }
        'Auslagerungsdatei'                          = @{ Was = 'Whether and how Windows can page memory out to the drive.'; Warum = 'Without a page file, programs crash when RAM is full instead of just getting slower.'; Harmlos = 'A manually fixed size that is large enough.' }
        'Schnellstart und Ruhezustand'               = @{ Was = 'Whether Windows fast startup is active.'; Warum = 'With fast startup, "Shut down" is not a real restart; driver and update problems stick around.'; Harmlos = 'On laptops with an HDD it saves noticeable time.' }
        'Temporäre Dateien und Caches'               = @{ Was = 'How much space temporary files take up.'; Warum = 'Frees up storage space.'; Harmlos = 'Do not delete shader caches, otherwise games stutter at the next start.' }
        'Dev Drive (Entwicklung)'                    = @{ Was = 'Whether a Dev Drive is set up for programming projects.'; Warum = 'Speeds up builds and Git considerably.'; Harmlos = 'Meaningless for everyone who does not program.' }
        'Energieplan'                                = @{ Was = 'The active power plan.'; Warum = 'Power saver mode slows the CPU down considerably.'; Harmlos = '"Balanced" is almost always right on current PCs.' }
        'Prozessor-Energieeinstellungen'             = @{ Was = 'Minimum/maximum CPU performance and turbo in the power plan.'; Warum = 'A maximum below 100 % or a disabled turbo costs a lot of performance.'; Harmlos = 'A minimum of 100 % is allowed, but costs electricity.' }
        'Weitere Energiesparfunktionen'              = @{ Was = 'USB and PCIe power saving and the time until standby.'; Warum = 'Aggressive PCIe power saving causes micro-stutter with some graphics cards.'; Harmlos = 'Makes sense on laptops for battery life.' }
        'Spielmodus'                                 = @{ Was = 'Whether Windows Game Mode is on.'; Warum = 'Prioritizes games and prevents update restarts while you play.'; Harmlos = 'If individual games have problems, turn it off as a test.' }
        'Hardwarebeschleunigte GPU-Planung (HAGS)'   = @{ Was = 'Whether the graphics card manages its own memory.'; Warum = 'Reduces latency; a prerequisite for DLSS Frame Generation.'; Harmlos = 'Older graphics cards do not support it.' }
        'Hintergrundaufzeichnung (Game DVR)'         = @{ Was = 'Whether Windows constantly records the last minutes of gameplay.'; Warum = 'Costs FPS and video memory.'; Harmlos = 'If you deliberately use the feature for clips.' }
        'Optimierungen für Spiele im Fenstermodus'   = @{ Was = 'A Windows setting for games in a borderless window.'; Warum = 'Lowers latency and enables variable refresh rates.'; Harmlos = 'If individual old games have problems.' }
        'Mausbeschleunigung'                         = @{ Was = 'Whether "Enhance pointer precision" is active.'; Warum = 'In shooters it is disruptive because the mouse movement is not translated 1:1.'; Harmlos = 'For the office it is a matter of taste.' }
        'Overlays und Hintergrund-Tools'             = @{ Was = 'Running overlays and RGB/tuning tools.'; Warum = 'Each costs some performance and can cause stutter; some bring vulnerable drivers along.'; Harmlos = 'Tools that you actively use.' }
        'Virtualisierung und Spieleleistung'         = @{ Was = 'Whether virtualization and memory integrity are active.'; Warum = 'Costs a few percent of performance, but protects strongly.'; Harmlos = 'Recommendation: leave it on.' }
        'Resizable BAR und PCIe-Anbindung'           = @{ Was = 'Whether the CPU can address the whole graphics memory at once (Resizable BAR) and how the graphics card is connected.'; Warum = 'Resizable BAR brings a few percent more FPS in many current games; a card with too few lanes gives away performance.'; Harmlos = 'Older motherboards without the BIOS option; x8 for cards that only have x8; PCIe 3.0 instead of 4.0 costs hardly anything.' }
        'NVIDIA-Treibereinstellungen'                = @{ Was = 'Reads the global NVIDIA driver profile (as in the NVIDIA Control Panel under 3D settings): shader cache, power management, V-Sync, maximum frame rate and G-SYNC.'; Warum = 'An accidentally global setting such as a disabled shader cache, forced V-Sync or a frame rate limit costs performance or causes stutter in all games.'; Harmlos = 'Deliberately set values, for example a frame rate limit or V-Sync on a monitor without G-SYNC. The check only reads and changes nothing.' }
        'Audio: Treiberfehler' = @{ Was = 'Whether a present audio device reports an error code in Device Manager.'; Warum = 'A device with a driver error delivers no sound or disappears from the selection.'; Harmlos = 'Never: a reported error code is a real finding. Devices that are not present (unplugged) are not checked.' }
        'Audio: Dienste' = @{ Was = 'Whether the Windows Audio and Windows Audio Endpoint Builder services are running and start automatically.'; Warum = 'Without these services there is no sound.'; Harmlos = 'Never: both normally always run.' }
        'Audio: Standardgeräte' = @{ Was = 'Which devices Windows uses for playback and recording (each normal and communications).'; Warum = 'If no sound comes from speakers or headset, a monitor (HDMI/DisplayPort) is often selected as the default.'; Harmlos = 'Intended if sound should play through the monitor or TV. Information only.' }
        'Audio: USB-Energiesparen' = @{ Was = 'Whether Windows may switch off USB ports when idle while a USB audio device is active.'; Warum = 'Can cause dropouts or crackling on USB headsets or microphones.'; Harmlos = 'Windows default; only relevant if there are actual dropouts.' }
        'Audio: Ducking' = @{ Was = 'Whether Windows lowers other sounds during calls (Communications setting).'; Warum = 'Explains why music or games get quieter during Discord, Teams or phone calls.'; Harmlos = 'A preference, not an error.' }
        'Spielebibliotheken'                         = @{ Was = 'On which drives the games from Steam, Epic, GOG, Ubisoft and Xbox are stored and how full they are.'; Warum = 'Games on a hard disk load slowly and stutter when streaming in data; almost full SSDs become slower when writing.'; Harmlos = 'Old or rarely played games on a hard disk.' }
        'Netzwerkkarte: Energiesparfunktionen'       = @{ Was = 'Power-saving features of the LAN adapter (Energy Efficient Ethernet, Green Ethernet, Ultra Low Power).'; Warum = 'They put the connection to sleep during idle periods; waking up can cause short latency spikes.'; Harmlos = 'On laptops and pure office PCs where every watt counts.' }
        'CPU-Last (Stichprobe 5 s)'                  = @{ Was = 'CPU usage at idle over 5 seconds.'; Warum = 'A high base load without a running program points to background processes or malware.'; Harmlos = 'Shortly after startup (updates, indexing) or while pc-check itself is running.' }
        'RAM-Auslastung'                             = @{ Was = 'How much memory is in use and by which programs.'; Warum = 'If RAM is almost full even without a game, the game stutters.'; Harmlos = 'Browsers with many tabs use a lot, but release it when needed.' }
        'Speicherkomprimierung'                      = @{ Was = 'Whether Windows compresses rarely used memory.'; Warum = 'Faster than paging out to the SSD.'; Harmlos = 'Information only; leave it on.' }
        'Autostart-Umfang'                           = @{ Was = 'Number of autostart programs and services.'; Warum = 'Many autostarts lengthen startup and permanently cost performance.'; Harmlos = 'Under 10 entries is normal.' }
        'Laufzeit seit Neustart'                     = @{ Was = 'How long the PC has been running since the last restart.'; Warum = 'Long uptimes prevent updates from completing.'; Harmlos = 'A few days are not a problem.' }
        'Netzwerkverbindung'                         = @{ Was = 'Connection speed and type (LAN/Wi-Fi).'; Warum = 'LAN at 100 instead of 1000 Mbit/s points to a faulty cable.'; Harmlos = 'Wi-Fi fluctuates a bit more for online games, but is usable.' }
        'Hardwarefehler (WHEA)'                      = @{ Was = 'Errors reported by the hardware (CPU, RAM, PCIe).'; Warum = 'If they pile up, overclocking is often too tight or hardware is defective.'; Harmlos = 'Isolated corrected PCIe errors.' }
        'Abstürze und unerwartete Neustarts'         = @{ Was = 'Blue screens and unexpected restarts.'; Warum = 'Point to driver, hardware or overclocking problems.'; Harmlos = 'An unexpected restart after a power outage or the reset button.' }
        'Grafiktreiber-Abstürze'                     = @{ Was = 'Crashes and restarts of the graphics driver.'; Warum = 'Point to unstable graphics overclocking, driver problems or the power supply.'; Harmlos = 'A single error without consequences.' }
        'Leistungsdrosselung durch Firmware'         = @{ Was = 'Whether the motherboard has limited the CPU clock speed.'; Warum = 'Usually temperature too high or power limits too low.'; Harmlos = 'Isolated messages without noticeable loss.' }
        'Programmabstürze'                           = @{ Was = 'Crashed and hanging programs.'; Warum = 'If crashes of many different programs pile up, RAM or overclocking is often to blame.'; Harmlos = 'Individual crashes of one particular program.' }
        'Dienstfehler'                               = @{ Was = 'Services that did not want to start or crashed. pc-check itself classifies known harmless errors and errors of services that have since been removed.'; Warum = 'Often leftovers of uninstalled programs.'; Harmlos = 'Individual errors at startup, e.g. timeouts.' }
        'Datenträgerfehler'                          = @{ Was = 'Read and write errors of the drives.'; Warum = 'An early warning sign of a drive failure.'; Harmlos = 'Errors from a USB stick that was pulled out.' }
        'Startdauer'                                 = @{ Was = 'How long Windows takes to reach the desktop and what slows startup.'; Warum = 'Shows which programs slow down startup.'; Harmlos = 'Games and updates show up here once after their installation.' }
        'Zuverlässigkeitsindex'                      = @{ Was = 'Windows'' own stability rating from 1 to 10.'; Warum = 'Summarizes crashes and errors of recent times.'; Harmlos = 'Shortly after crashes the value drops and recovers again.' }
    }

    # Tips and instructions per check. A note with a matching entry becomes a tip; for warnings the instructions appear in addition.
    # Per check a list of variants, the first match counts:
    #   Match    = regular expression on the finding (optional)
    #   Profile  = tip only in these profiles, otherwise it stays a note (optional; Gaming, Office, Laptop)
    #   Nutzen, Aufwand, Risiko = gering | mittel | hoch (identifiers, not translated)
    #   NurAnleitung = $true: stays a note (e.g. pure review), but gets the instructions
    #   Schritte = click path; Befehl = optional, for an administrator PowerShell
    Tipps      = @{
        'Microsoft Defender: Einstellungen'          = @(
            @{ Match = 'PUA|Cloud'; Nutzen = 'hoch'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Windows Security > App & browser control > Reputation-based protection settings: turn on "Potentially unwanted app blocking".', 'Windows Security > Virus & threat protection > Manage settings: turn on "Cloud-delivered protection".') }
            @{ Match = 'Netzwerkschutz aus'; Nutzen = 'mittel'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Right-click Start > "Terminal (Admin)".', 'Paste the command below and run it with Enter. There is no switch for this in Windows Security.', 'If it wrongly blocks a site: with -EnableNetworkProtection AuditMode it only logs.'); Befehl = 'Set-MpPreference -EnableNetworkProtection Enabled' }
        )
        'Defender: ASR-Regeln'                       = @(
            @{ Match = 'Keine Regeln'; Nutzen = 'mittel'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Right-click Start > "Terminal (Admin)".', 'Run the command below. It turns on two rules that do not disturb gaming and development: block vulnerable signed drivers and block credential theft from LSASS.', 'If a tool is blocked afterwards (rare, mostly old OC/RGB tools), Event Viewer shows event 1121 for Defender; then replace Enabled with AuditMode in the command.'); Befehl = 'Add-MpPreference -AttackSurfaceReductionRules_Ids 56a863a9-875e-4185-98a7-b882c64b5ce5,9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2 -AttackSurfaceReductionRules_Actions Enabled,Enabled' }
        )
        'Defender: Manipulationsschutz'              = @(
            @{ Nutzen = 'hoch'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Windows Security > Virus & threat protection > Manage settings.', 'Turn on "Tamper Protection".') }
        )
        'Windows Update: ausstehend'                 = @(
            @{ Nutzen = 'hoch'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Settings > Windows Update > "Check for updates".', 'Then restart.') }
        )
        'Wiederherstellung'                          = @(
            @{ Match = 'Computerschutz [A-Z]: aus'; Nutzen = 'hoch'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Press Win+R, type sysdm.cpl, Enter.', 'Tab "System Protection" > select drive C: > "Configure".', 'Choose "Turn on system protection", set the slider to about 10 %, OK.', 'Or in Morpheus, under Security > Restore, run "Turn on system protection".'); Befehl = 'Enable-ComputerRestore -Drive ''C:''' }
            @{ Match = 'Speicher zu klein'; Nutzen = 'hoch'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('In Morpheus, under Security > Restore, run "Increase restore point storage".', 'Or by hand: Win+R, sysdm.cpl, tab "System Protection" > C: > "Configure" > set the "Max Usage" slider to about 10 %, OK.'); Befehl = 'vssadmin resize shadowstorage /for=C: /on=C: /maxsize=10%' }
        )
        'Datensicherung'                             = @(
            @{ Nutzen = 'hoch'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Connect an external drive (USB hard disk or SSD).', 'Settings > System > Storage > Advanced storage settings > Backup options: choose the drive and turn on the backup. Alternatively Control Panel > File History > "Turn on".', 'Alternatively without an external drive: OneDrive > Settings > Sync and backup > Manage backup; turn on Desktop, Documents and Pictures.', 'If you back up another way (another program or a NAS), add the finding to accepted.psd1.') }
        )
        'Remoteunterstützung'                        = @(
            @{ Nutzen = 'gering'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Press Win+R, type sysdm.cpl, Enter.', 'Tab "Remote": clear the check box "Allow Remote Assistance connections to this computer", OK.') }
        )
        'Remotedesktop'                              = @(
            @{ Nutzen = 'hoch'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Settings > System > Remote Desktop: turn it off.') }
        )
        'LLMNR / NetBIOS'                            = @(
            @{ Profile = @('Laptop'); Nutzen = 'mittel'; Aufwand = 'mittel'; Risiko = 'gering'; Schritte = @('Windows Pro: Win+R > gpedit.msc > Computer Configuration > Administrative Templates > Network > DNS Client > "Turn off multicast name resolution" set to "Enabled".', 'Windows Home: run the command below in an administrator PowerShell.'); Befehl = 'New-Item -Path ''HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'' -Force | Out-Null
Set-ItemProperty -Path ''HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'' -Name EnableMulticast -Value 0 -Type DWord' }
        )
        'Kennwort- und Sperrrichtlinie'              = @(
            @{ Match = 'Keine Kontosperre'; Nutzen = 'mittel'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Right-click Start > "Terminal (Admin)".', 'Run the command below: after 10 failed attempts the account is locked for 10 minutes (Windows default on a fresh installation).'); Befehl = 'net accounts /lockoutthreshold:10 /lockoutduration:10 /lockoutwindow:10' }
        )
        'Bildschirmsperre'                           = @(
            @{ Profile = @('Laptop', 'Office'); Nutzen = 'mittel'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Settings > Personalization > Lock screen > "Screen saver".', 'Choose the screen saver "Blank" (with "(None)" nothing locks), wait time e.g. 10 minutes, tick "On resume, display logon screen", OK.') }
        )
        'Administratorgruppe'                        = @(
            @{ Match = 'ist Administrator'; Nutzen = 'mittel'; Aufwand = 'hoch'; Risiko = 'mittel'; Schritte = @('Settings > Accounts > Other users > "Add account": create a second account and make it an administrator under "Change account type".', 'Sign in with the new account and give the everyday account the account type "Standard user".', 'From then on User Account Control asks for the password of the admin account during installations. Keep the password safe, otherwise you lock yourself out.') }
        )
        'Kernisolierung (VBS / Speicherintegrität)'  = @(
            @{ Nutzen = 'hoch'; Aufwand = 'mittel'; Risiko = 'gering'; Schritte = @('Windows Security > Device security > "Core isolation details".', 'Turn on "Memory integrity" and restart.', 'If Windows reports incompatible drivers: "Review incompatible drivers" shows them. Uninstall the program they belong to (often old RGB, fan or OC tools).') }
        )
        'LSA-Schutz'                                 = @(
            @{ Nutzen = 'mittel'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Windows Security > Device security > "Core isolation details".', 'Turn on "Local Security Authority protection" and restart.') }
        )
        'Treiber-Sperrliste und Smart App Control'   = @(
            @{ Nutzen = 'hoch'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Windows Security > Device security > "Core isolation details".', 'Turn on "Microsoft Vulnerable Driver Blocklist".') }
        )
        'Secure Boot'                                = @(
            @{ Match = 'Secure Boot aus'; Nutzen = 'hoch'; Aufwand = 'mittel'; Risiko = 'mittel'; Schritte = @('Restart straight into the BIOS with the command below.', 'In the "Boot" section: turn off "CSM Support" and enable "Secure Boot" (if needed "Install default keys"), save with F10.', 'If Windows does not start afterwards: turn CSM back on. The drive is then still in the old MBR format and first has to be converted with mbr2gpt.'); Befehl = 'shutdown /r /fw /t 0' }
        )
        'BitLocker'                                  = @(
            @{ Match = 'nicht verschlüsselt'; Nutzen = 'mittel'; Aufwand = 'mittel'; Risiko = 'mittel'; Schritte = @('Control Panel > System and Security > BitLocker Drive Encryption > "Turn on BitLocker" (Windows Home: Settings > Privacy & security > Device encryption).', 'Save the recovery key in your Microsoft account and print it as well.', 'Before BIOS updates and OC changes, "Suspend protection" in future, otherwise the PC asks for the key at startup.') }
        )
        'BIOS/UEFI-Version'                          = @(
            @{ Nutzen = 'mittel'; Aufwand = 'mittel'; Risiko = 'mittel'; Schritte = @('The motherboard and BIOS version are in the finding; look for a newer version on the manufacturer''s support page.', 'If overclocked, save the OC profile in the BIOS first: the update resets the settings.', 'If BitLocker is on: "Suspend protection" first.', 'Install the update from a USB stick with the tool in the BIOS (Q-Flash, EZ Flash, M-Flash) and do not interrupt the power meanwhile.') }
        )
        'Firewall: eigene Eingangsregeln'            = @(
            @{ Nutzen = 'mittel'; Aufwand = 'mittel'; Risiko = 'gering'; Schritte = @('Win+R > wf.msc > "Inbound Rules", sort by "Profile".', 'Delete rules for programs that are no longer installed.', 'For the rest, double-click > tab "Advanced" and clear the check box "Public".') }
        )
        'Treiber: bekannt anfällige und unsignierte' = @(
            @{ Match = 'Nicht geladen'; Nutzen = 'mittel'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('The appendix "Treiber: bekannt anfällige" shows where the file is located and which service it belongs to.', 'Uninstall the program it belongs to (usually an RGB, fan or overclocking tool) under Settings > Apps > Installed apps.', 'With the next pc-check run, check whether the driver is gone.') }
        )
        'Systemdateien: Signaturen (Sigcheck)'       = @(
            @{ NurAnleitung = $true; Nutzen = 'mittel'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Clarify the origin: look at company and date in the table. "pnputil /enum-drivers" (command below) shows installed driver packages with their vendor.', 'Look at the signature by hand: right-click the file > Properties > Digital Signatures. If the tab is missing, the file is often signed through a Windows catalog; Sigcheck sometimes reports such files anyway.', 'In Morpheus, choose "Scan with Defender" for each file.', 'Second opinion: search the SHA256 ("Copy hash") yourself at virustotal.com. Morpheus does not send anything.', 'If the file belongs to a device you no longer use (e.g. an old sound card), uninstall the driver in Device Manager or remove it with "pnputil /delete-driver oemNN.inf /uninstall" (oemNN.inf from pnputil /enum-drivers). This cannot be undone, so only for devices that are certainly unused.', 'If the file is known and harmless: "Accept". If it changes later, the warning comes back.'); Befehl = 'pnputil /enum-drivers' }
        )
        'Browser-Erweiterungen'                      = @(
            @{ NurAnleitung = $true; Nutzen = 'mittel'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('In the browser open edge://extensions or chrome://extensions (Firefox: about:addons).', 'Remove everything that you do not know or have not used for months.', 'Extensions with full access (listed in the finding) can often be limited to "On click": Details > Site access.') }
        )
        'Schnellstart und Ruhezustand'               = @(
            @{ Match = 'Schnellstart an'; Profile = @('Gaming', 'Office'); Nutzen = 'gering'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Control Panel > Hardware and Sound > Power Options > "Choose what the power buttons do".', 'Click "Change settings that are currently unavailable" and clear the check box "Turn on fast startup".', 'Or the command below: it also turns off hibernation and frees the file hiberfil.sys.'); Befehl = 'powercfg /hibernate off' }
        )
        'Temporäre Dateien und Caches'               = @(
            @{ Nutzen = 'gering'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Settings > System > Storage > "Cleanup recommendations".', 'Select temporary files and old update files and clean up. Do not delete shader caches.') }
        )
        'Dev Drive (Entwicklung)'                    = @(
            @{ Nutzen = 'mittel'; Aufwand = 'mittel'; Risiko = 'gering'; Schritte = @('Settings > System > Storage > Advanced storage settings > Disks & volumes > "Create Dev Drive".', 'Use free space on an SSD or create a virtual hard disk (VHDX, dynamic, e.g. 100 GB).', 'Move repos and package caches (npm, pip, NuGet) there; Defender scans there in the faster performance mode.') }
        )
        'Laufwerke (Typ und Zustand)'                = @(
            @{ Match = 'SATA-SSD'; Nutzen = 'gering'; Aufwand = 'hoch'; Risiko = 'mittel'; Schritte = @('Only worthwhile if an M.2 slot is free or a new drive is due anyway.', 'Transfer Windows to the NVMe with the SSD vendor''s clone program (e.g. Samsung Data Migration, Acronis for WD/Crucial).', 'Afterwards choose the NVMe as the first boot drive in the BIOS.') }
        )
        'Festplatten (HDD)'                          = @(
            @{ Profile = @('Gaming'); Nutzen = 'mittel'; Aufwand = 'mittel'; Risiko = 'gering'; Schritte = @('Move games that are on the hard disk to an SSD (instructions under "Spielebibliotheken").', 'Keep using the hard disk for data, videos and backups.') }
        )
        'Prozessor-Energieeinstellungen'             = @(
            @{ Match = 'min\. 100 %'; Nutzen = 'gering'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Right-click Start > "Terminal (Admin)".', 'Paste the commands below: they create a copy of "High performance" that clocks fully under load and clocks down when idle, and activate it.', 'You can go back at any time under Control Panel > Power Options.'); Befehl = '$g = (New-Guid).Guid
powercfg /duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c $g
powercfg /changename $g ''Performance (dynamic)'' ''Full performance under load, clocks down when idle''
powercfg /setacvalueindex $g SUB_PROCESSOR PROCTHROTTLEMIN 5
powercfg /setacvalueindex $g SUB_PROCESSOR PERFEPP 10
powercfg /setacvalueindex $g SUB_PROCESSOR PERFBOOSTMODE 2
powercfg /setactive $g' }
        )
        'Weitere Energiesparfunktionen'              = @(
            @{ Match = 'PCIe-Verbindungsenergieverwaltung maximal'; Profile = @('Gaming'); Nutzen = 'gering'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Control Panel > Power Options > Change plan settings > Change advanced power settings.', 'PCI Express > Link State Power Management: "Off".'); Befehl = 'powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
powercfg /setactive SCHEME_CURRENT' }
        )
        'Bildschirme und Bildwiederholrate'          = @(
            @{ Nutzen = 'hoch'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Settings > System > Display > select the monitor at the top > "Advanced display".', 'Under "Choose a refresh rate" set the highest value.', 'If the value is missing: use a DisplayPort cable instead of HDMI, or turn on the high mode (overclock/FreeSync) in the monitor menu.') }
        )
        'Arbeitsspeicher'                            = @(
            @{ Match = 'Intel-Spezifikation|JEDEC'; Profile = @('Gaming'); Nutzen = 'mittel'; Aufwand = 'mittel'; Risiko = 'gering'; Schritte = @('Check on the RAM label or via the model number (appendix "RAM-Module") which speed the kit supports.', 'Enable the XMP/EXPO profile in the BIOS (also called "Extreme Memory Profile" or "DOCP").', 'If the PC does not start with it, the BIOS usually resets itself after a few attempts; then choose the profile with the lower speed.') }
        )
        'Grafikkarte und Treiber'                    = @(
            @{ Match = 'Tage\)'; Nutzen = 'gering'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Open the NVIDIA app, AMD Adrenalin or the Intel driver assistant and check for updates.') }
        )
        'Resizable BAR und PCIe-Anbindung'           = @(
            @{ Match = 'x(1|2|4|8)\b'; Profile = @('Gaming'); Nutzen = 'mittel'; Aufwand = 'mittel'; Risiko = 'gering'; Schritte = @('Check the motherboard manual for which slot is connected with x16 (usually the top one) and whether M.2 slots take lanes from it.', 'Turn the PC off, unplug the power cable and, if necessary, move the graphics card to another slot.') }
            @{ Match = 'Resizable BAR aus'; Profile = @('Gaming'); Nutzen = 'mittel'; Aufwand = 'mittel'; Risiko = 'gering'; Schritte = @('If overclocked, save the OC profile in the BIOS first.', 'Restart straight into the BIOS with the command below.', 'Turn on "Above 4G Decoding"; then "Re-Size BAR Support" appears: set it to Auto or Enabled (Gigabyte: Settings > IO Ports; ASUS and MSI: Advanced > PCI Subsystem).', '"CSM Support" must be off (with Secure Boot active it is). Save with F10.', 'If the option is missing, look for a BIOS update. Then check with pc-check.'); Befehl = 'shutdown /r /fw /t 0' }
        )
        'Spielebibliotheken'                         = @(
            @{ Profile = @('Gaming'); Nutzen = 'mittel'; Aufwand = 'mittel'; Risiko = 'gering'; Schritte = @('Uninstall games you no longer play (Steam: right-click the game > Manage > Uninstall).', 'Move large, frequently played games to the fastest drive with space: Steam > right-click > Properties > Installed Files > "Move install folder".', 'If there is no Steam library there yet: Steam > Settings > Storage > "Add Drive".', 'Epic: Library > ... > Manage > Move. Xbox app: game > ... > Manage > Files > Move.') }
        )
        'Netzwerkkarte: Energiesparfunktionen'       = @(
            @{ Profile = @('Gaming'); Nutzen = 'gering'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Device Manager > Network adapters > double-click the LAN adapter > tab "Advanced".', 'Set the entries named in the finding to Off or Disabled. The connection is gone for a few seconds.', 'Or run the commands below in an administrator PowerShell.') }
        )
        'Spielmodus'                                 = @(
            @{ Profile = @('Gaming'); Nutzen = 'gering'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Settings > Gaming > Game Mode: turn it on.') }
        )
        'Hardwarebeschleunigte GPU-Planung (HAGS)'   = @(
            @{ Profile = @('Gaming'); Nutzen = 'mittel'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Settings > System > Display > Graphics > "Change default graphics settings".', 'Turn on "Hardware-accelerated GPU scheduling" and restart.') }
        )
        'Optimierungen für Spiele im Fenstermodus'   = @(
            @{ Profile = @('Gaming'); Nutzen = 'gering'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Settings > System > Display > Graphics > "Advanced graphics settings".', 'Turn on "Optimizations for windowed games".') }
        )
        'Mausbeschleunigung'                         = @(
            @{ Profile = @('Gaming'); Nutzen = 'gering'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Settings > Bluetooth & devices > Mouse > "Additional mouse settings".', 'Tab "Pointer Options": clear the check box "Enhance pointer precision", OK.') }
        )
        'Overlays und Hintergrund-Tools'             = @(
            @{ NurAnleitung = $true; Nutzen = 'gering'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('For each tool in the finding, check whether you use the overlay: Discord > Settings > Game Overlay; NVIDIA app > Settings > Overlay; Steam > Settings > In Game.', 'Disable unused tools in Task Manager (Ctrl+Shift+Esc) > "Startup apps".') }
        )
        'RAM-Auslastung'                             = @(
            @{ Nutzen = 'mittel'; Aufwand = 'hoch'; Risiko = 'gering'; Schritte = @('First check the big consumers (appendix "Top-Prozesse nach Arbeitsspeicher"), e.g. many browser tabs.', 'For an upgrade: the model of the existing modules is in the appendix "RAM-Module". It is best to buy a kit with the same speed and the same size per module.') }
        )
        'Autostart-Umfang'                           = @(
            @{ Nutzen = 'mittel'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Ctrl+Shift+Esc > Task Manager > "Startup apps".', 'Disable everything that does not need to run right after sign-in; launchers and chat programs can be started by hand when needed.') }
        )
        'Laufzeit seit Neustart'                     = @(
            @{ Nutzen = 'gering'; Aufwand = 'gering'; Risiko = 'gering'; Schritte = @('Start > Power > "Restart" (not "Shut down" as long as fast startup is on).') }
        )
        'Netzwerkverbindung'                         = @(
            @{ Match = 'Nur WLAN'; Profile = @('Gaming'); Nutzen = 'mittel'; Aufwand = 'mittel'; Risiko = 'gering'; Schritte = @('Run a LAN cable (Cat 5e or better) to the router.', 'If that is not possible: powerline or mesh adapters with a LAN port.') }
        )
    }

    # Help texts for the tools under "Maintenance & repair". Key = tool id (docs\gui-architektur.md, 17.3).
    Wartung    = @{
        'wiederherstellung.punkt' = @{ Was = 'Creates a restore point to which Windows can reset the PC if there are problems.'; Wann = 'By hand, for example before you install drivers or new programs.'; Hinweis = 'By default Windows creates at most one point per 24 hours (README, section 24-hour limit).' }
        'dism.checkhealth'        = @{ Was = 'A quick look at whether Windows has marked the component store as corrupted.'; Wann = 'As a first step for crashes or failing updates.'; Hinweis = 'Changes nothing and usually takes under a minute.' }
        'dism.scanhealth'         = @{ Was = 'A thorough check of the component store for corruption.'; Wann = 'If the quick check shows a finding or problems remain.'; Hinweis = 'Takes 5 to 20 minutes. Changes nothing on the system.' }
        'dism.restorehealth'      = @{ Was = 'Repairs the component store with files from Windows Update.'; Wann = 'If the check found corruption, and before sfc /scannow.'; Hinweis = 'Needs internet and cannot be undone. A restore point is created first. Do not cancel.' }
        'sfc.scannow'             = @{ Was = 'Checks for corrupted system files and replaces them from the component store.'; Wann = 'After RestoreHealth, if Windows files are missing or report errors.'; Hinweis = 'The log is in %WinDir%\Logs\CBS\CBS.log. The run can take up to an hour.' }
        'dism.analyze'            = @{ Was = 'Shows how much space cleaning up the WinSxS folder would bring.'; Wann = 'If disk space is running low and you want to check whether cleaning up is worthwhile.'; Hinweis = 'Changes nothing on the system.' }
        'dism.cleanup'            = @{ Was = 'Removes superseded versions of Windows updates and thereby frees up space.'; Wann = 'After an analysis, if the gain is noticeable and Windows runs without problems.'; Hinweis = 'Older updates can no longer be uninstalled afterwards. Morpheus does not use /ResetBase. Never delete the WinSxS folder by hand.' }
        'chkdsk.scan'             = @{ Was = 'Checks the file system of a drive while it is running, without repairing anything.'; Wann = 'For read or write errors, unusual noises from the hard disk or after data loss.'; Hinweis = 'If errors are found, back up your data first. Morpheus does not do the repair at the next startup itself.' }
        'perfmon.rel'             = @{ Was = 'The reliability history shows crashes and installations day by day as an overview.'; Wann = 'If you want to find out since when a problem has been occurring.'; Hinweis = 'Opens without admin rights. Without Morpheus: Win + R, then type perfmon /rel.' }
        'dns.flush'               = @{ Was = 'Clears the DNS cache in which Windows stores remembered addresses of websites.'; Wann = 'If websites are not reachable after a change.'; Hinweis = 'Harmless. The entries are fetched again when needed.' }
        'trim'                    = @{ Was = 'Tells the SSD which blocks are free so that it stays fast and durable (ReTrim). Corresponds to Optimize-Volume -ReTrim.'; Wann = 'Windows normally does this weekly by itself. A manual run is only needed if necessary.'; Hinweis = 'Intended for SSDs only. Do not select it for classic hard disks.' }
        'zeit.resync'             = @{ Was = 'Synchronizes the system clock with the time server immediately.'; Wann = 'If the time is wrong or after a long time without internet.'; Hinweis = 'Needs internet and the Windows Time service.' }
        'powercfg.energy'         = @{ Was = 'Observes the PC for 60 seconds and lists energy problems, for example devices that prevent sleep mode.'; Wann = 'If the battery drains quickly or the PC does not go into power-saving mode.'; Hinweis = 'Avoid using the PC during this time. The report then appears under "Generated reports".' }
        'powercfg.akku'           = @{ Was = 'Creates a battery report with capacity, charge cycles and history.'; Wann = 'If the runtime of the laptop has noticeably dropped.'; Hinweis = 'Only available on laptops with a battery.' }
        'powercfg.schlaf'         = @{ Was = 'Sleep study: shows what affects the standby state of the PC.'; Wann = 'If the PC uses power unexpectedly in standby mode or wakes up.'; Hinweis = 'Not available on most desktop PCs because the sleep study requires Modern Standby.' }
        'winget.upgrade'          = @{ Was = 'Updates selected programs through winget from the vendors'' sources.'; Wann = 'If software updates are shown in the check and you want to install them.'; Hinweis = 'Updates cannot be undone through the journal. Close the programs first.' }
    }
}
