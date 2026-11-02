# Titel, Erklaerungen und Befehlsanzeige der Katalog-Aktionen (Deutsch). Schluessel = Aktions-Id.
@{
    'defender.netzwerkschutz' = @{
        Titel      = 'Netzwerkschutz einschalten'
        Erklaerung = 'Blockiert in allen Programmen Verbindungen zu bekannten Phishing- und Schadsoftware-Servern. Im Alltag merkst du nichts, höchstens wird eine unseriöse Webseite gesperrt.'
        Befehle    = @{
            Ausfuehren   = 'Set-MpPreference -EnableNetworkProtection Enabled'
            Rueckgaengig = 'Set-MpPreference -EnableNetworkProtection <vorher>   # Disabled, Enabled oder AuditMode, je nach altem Wert'
            Erklaerung   = @(
                'Set-MpPreference ändert eine Einstellung von Microsoft Defender.',
                '-EnableNetworkProtection Enabled schaltet den Netzwerkschutz scharf (AuditMode würde nur protokollieren, Disabled ist aus).',
                'Beim Rückgängigmachen wird der alte Wert (aus, an oder nur protokollieren) wieder gesetzt.'
            )
        }
    }
    'defender.pua' = @{
        Titel      = 'Schutz vor unerwünschten Apps (PUA) einschalten'
        Erklaerung = 'Defender blockiert dann Adware, Zusatzsoftware in Installern und ähnliche unerwünschte Programme. Selten wird dabei auch ein harmloses Hilfsprogramm gesperrt.'
        Befehle    = @{
            Ausfuehren   = 'Set-MpPreference -PUAProtection Enabled'
            Rueckgaengig = 'Set-MpPreference -PUAProtection <vorher>   # Disabled, Enabled oder AuditMode, je nach altem Wert'
            Erklaerung   = @(
                'Set-MpPreference ändert eine Einstellung von Microsoft Defender.',
                '-PUAProtection Enabled blockiert potenziell unerwünschte Anwendungen (AuditMode würde nur melden, Disabled ist aus).',
                'Beim Rückgängigmachen wird der alte Wert wieder gesetzt.'
            )
        }
    }
    'defender.asr-basis' = @{
        Titel      = 'Zwei Angriffsflächen-Regeln (Treiber-Missbrauch, LSASS) aktivieren'
        Erklaerung = 'Verhindert, dass Schadsoftware bekannte anfällige Treiber missbraucht oder Anmeldedaten aus dem LSASS-Prozess stiehlt. Sehr alte Hersteller-Treiber (z. B. mancher Übertaktungs-Tools) können dadurch gesperrt werden; "Nur protokollieren" ist zum Testen ohne Sperre.'
        VariantenNamen = @('Blockieren', 'Nur protokollieren')
        Befehle    = @{
            Ausfuehren   = 'Add-MpPreference -AttackSurfaceReductionRules_Ids ''56a863a9-875e-4185-98a7-b882c64b5ce5'' -AttackSurfaceReductionRules_Actions <variante>
Add-MpPreference -AttackSurfaceReductionRules_Ids ''9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'' -AttackSurfaceReductionRules_Actions <variante>   # <variante>: Blockieren = Enabled, Nur protokollieren = AuditMode; nur für Regeln, die noch nicht auf Blockieren/Protokollieren stehen'
            Rueckgaengig = 'Add-MpPreference -AttackSurfaceReductionRules_Ids <regel> -AttackSurfaceReductionRules_Actions <alter Modus>   # war die Regel vorher gesetzt
Remove-MpPreference -AttackSurfaceReductionRules_Ids <regel>   # war die Regel vorher nicht gesetzt'
            Erklaerung   = @(
                'Add-MpPreference fügt eine Regel zur Verringerung der Angriffsfläche (ASR) hinzu bzw. ändert ihren Modus.',
                '56a863a9-… = Missbrauch anfälliger signierter Treiber blockieren; 9e6c4e1f-… = Diebstahl von Anmeldedaten aus LSASS blockieren.',
                '-AttackSurfaceReductionRules_Actions: Enabled = blockieren, AuditMode = nur protokollieren.',
                'Remove-MpPreference entfernt eine Regel wieder; so ist sie danach genau so "nicht gesetzt" wie vorher.'
            )
        }
    }
    'fernzugriff.remoteunterstuetzung' = @{
        Titel      = 'Remoteunterstützung ausschalten'
        Erklaerung = 'Niemand kann sich mehr per "Remoteunterstützung" (Einladung zur Fernhilfe) auf deinen PC verbinden. Das merkst du nur, wenn du diese Funktion bewusst nutzt.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'' -Name ''fAllowToGetHelp'' -PropertyType DWord -Value 0 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'' -Name ''fAllowToGetHelp'' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path ''…'' -Name ''fAllowToGetHelp'''
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'fAllowToGetHelp ist die Einstellung "Remoteunterstützungsverbindungen mit diesem Computer zulassen"; 0 = nicht zulassen, 1 = zulassen.',
                '-PropertyType DWord ist der Registry-Datentyp (32-Bit-Zahl).',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert, wenn er vorher nicht existierte.'
            )
        }
    }
    'fernzugriff.rdp' = @{
        Titel      = 'Remotedesktop (RDP) ausschalten'
        Erklaerung = 'Niemand kann sich mehr per Remotedesktop auf diesen PC verbinden; das schließt eine häufig angegriffene Tür. Wenn du den PC von unterwegs oder von einem anderen Rechner per RDP bedienst, funktioniert das danach nicht mehr.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'' -Name ''fDenyTSConnections'' -PropertyType DWord -Value 1 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'' -Name ''fDenyTSConnections'' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path ''…'' -Name ''fDenyTSConnections'''
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'fDenyTSConnections ist der Schalter hinter "Remotedesktop" in den Einstellungen; 1 = Verbindungen verweigern, 0 = erlauben.',
                '-PropertyType DWord ist der Registry-Datentyp (32-Bit-Zahl).',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert, wenn er vorher nicht existierte.'
            )
        }
    }
    'netz.llmnr' = @{
        Titel      = 'LLMNR (Namensauflösung per Rundruf) ausschalten'
        Erklaerung = 'LLMNR ist ein altes Verfahren, mit dem Rechner im Netz Namen per Rundruf auflösen; in fremden Netzen lassen sich darüber Anmelde-Hashes abgreifen. Im Heimnetz merkst du nichts, höchstens werden Geräte ohne eigenen DNS-Eintrag nicht mehr über ihren Namen gefunden.'
        Befehle    = @{
            Ausfuehren   = 'New-Item -Path ''HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'' -Force   # nur falls der Schlüssel fehlt
New-ItemProperty -Path ''HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'' -Name ''EnableMulticast'' -PropertyType DWord -Value 0 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'' -Name ''EnableMulticast'' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path ''…'' -Name ''EnableMulticast''; hat Ausführen den Schlüssel neu angelegt, wird der leere Schlüssel mit Remove-Item entfernt'
            Erklaerung   = @(
                'New-Item legt den Richtlinien-Schlüssel an, falls er noch nicht existiert.',
                'New-ItemProperty setzt den Wert EnableMulticast in der Richtlinie "Multicastnamensauflösung deaktivieren" des DNS-Clients; 0 = LLMNR aus.',
                '-PropertyType DWord ist der Registry-Datentyp (32-Bit-Zahl).',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht Wert und (nur den selbst angelegten, leeren) Schlüssel.'
            )
        }
    }
    'system.wiederherstellung' = @{
        Titel      = 'Computerschutz (Wiederherstellungspunkte) auf dem Systemlaufwerk einschalten'
        Erklaerung = 'Schaltet die Systemwiederherstellung ein, damit vor Änderungen Wiederherstellungspunkte angelegt werden können; diese Aktion selbst legt noch keinen Punkt an. ACHTUNG: Das Rückgängigmachen (Ausschalten) löscht ALLE vorhandenen Wiederherstellungspunkte des Laufwerks unwiderruflich.'
        Befehle    = @{
            Ausfuehren   = 'Enable-ComputerRestore -Drive "$env:SystemDrive\"'
            Rueckgaengig = 'Disable-ComputerRestore -Drive "$env:SystemDrive\"   # ACHTUNG: löscht alle Wiederherstellungspunkte dieses Laufwerks'
            Erklaerung   = @(
                'Enable-ComputerRestore schaltet den Computerschutz (Systemwiederherstellung) für das angegebene Laufwerk ein.',
                '$env:SystemDrive ist das Systemlaufwerk (meist C:); der Backslash macht daraus den Laufwerksstamm (C:\).',
                'Disable-ComputerRestore schaltet den Schutz wieder aus und löscht dabei alle vorhandenen Wiederherstellungspunkte dieses Laufwerks; sie lassen sich nicht zurückholen.'
            )
        }
    }
    'system.wiederherstellung-speicher' = @{
        Titel      = 'Speicher für Wiederherstellungspunkte auf 10 % vergrößern'
        Erklaerung = 'Ist der Speicher für Wiederherstellungspunkte zu klein, löscht Windows ältere Punkte, sobald ein neuer entsteht – oft schon nach Stunden. Mit 10 % des Systemlaufwerks bleiben mehrere Punkte erhalten. Belegt wird der Platz erst, wenn Punkte entstehen.'
        Befehle    = @{
            Ausfuehren   = 'vssadmin resize shadowstorage /for=$env:SystemDrive /on=$env:SystemDrive /maxsize=10%'
            Rueckgaengig = 'vssadmin resize shadowstorage /for=$env:SystemDrive /on=$env:SystemDrive /maxsize=<alter Wert in MB bzw. UNBOUNDED>   # ist der alte Wert kleiner, löscht Windows dabei ältere Punkte'
            Erklaerung   = @(
                'vssadmin resize shadowstorage ändert, wie viel Platz Schattenkopien (daraus bestehen Wiederherstellungspunkte) auf dem Laufwerk belegen dürfen.',
                '/for und /on: das Systemlaufwerk (meist C:); /maxsize=10% erlaubt bis zu 10 % der Laufwerksgröße.',
                'Rückgängig setzt die alte Grenze wieder. Ist sie kleiner als der belegte Platz, löscht Windows dabei die ältesten Punkte.',
                'Ist „Point-in-time restore“ von Windows 11 aktiv, setzt Windows die Grenze bei jedem Start auf dessen Einstellung zurück (Standard 2 %). Dann ändert Morpheus nichts und nennt den Weg über die Einstellungen.'
            )
        }
    }
    'system.schnellstart' = @{
        Titel      = 'Schnellstart ausschalten'
        Erklaerung = '"Herunterfahren" fährt Windows dann wirklich komplett herunter, sodass Treiber-, Update- und BIOS-Änderungen sicher greifen. Der Start dauert mit einer NVMe-SSD kaum merklich länger; der Ruhezustand bleibt unberührt.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'' -Name ''HiberbootEnabled'' -PropertyType DWord -Value 0 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'' -Name ''HiberbootEnabled'' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path ''…'' -Name ''HiberbootEnabled'''
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'HiberbootEnabled ist der Schalter "Schnellstart aktivieren" aus den Energieoptionen; 0 = aus, 1 = an. Die Hibernate-Datei und der Ruhezustand bleiben unverändert (bewusst kein "powercfg /hibernate off").',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert, wenn er vorher nicht existierte.'
            )
        }
    }
    'haertung.lsa' = @{
        Titel      = 'LSA-Schutz einschalten (ohne UEFI-Sperre)'
        Erklaerung = 'Schützt den Windows-Prozess, der Anmeldedaten verwaltet, vor dem Auslesen durch Schadsoftware. Wirkt erst nach einem Neustart; sehr selten verweigern ältere Anmelde-Zusatzprogramme danach den Dienst. Es wird bewusst die Variante ohne UEFI-Sperre (Wert 2) gesetzt, damit sie sich jederzeit wieder ausschalten lässt.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'' -Name ''RunAsPPL'' -PropertyType DWord -Value 2 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'' -Name ''RunAsPPL'' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path ''…'' -Name ''RunAsPPL'''
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'RunAsPPL steuert, ob die lokale Sicherheitsautorität (lsass.exe) als geschützter Prozess startet. 2 = an ohne UEFI-Sperre (rücknehmbar), 1 = an mit UEFI-Sperre (würde sich nicht per Registry zurücknehmen lassen und wird deshalb nicht verwendet).',
                'Die Änderung wirkt erst nach einem Neustart.',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert, wenn er vorher nicht existierte (ebenfalls erst nach Neustart wirksam).'
            )
        }
    }
    'haertung.treibersperrliste' = @{
        Titel      = 'Microsoft-Sperrliste für anfällige Treiber einschalten'
        Erklaerung = 'Windows lädt dann keine Treiber mehr, die Microsoft als missbrauchbar eingestuft hat. Wirkt nach einem Neustart; sehr alte Treiber von Hardware-Tools (z. B. mancher Übertaktungs- oder Lüfter-Software) können dadurch gesperrt werden.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'' -Name ''VulnerableDriverBlocklistEnable'' -PropertyType DWord -Value 1 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'' -Name ''VulnerableDriverBlocklistEnable'' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path ''…'' -Name ''VulnerableDriverBlocklistEnable'''
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'VulnerableDriverBlocklistEnable schaltet die Microsoft-Sperrliste für anfällige Treiber ein (1) oder aus (0).',
                'Die Änderung wirkt erst nach einem Neustart.',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert, wenn er vorher nicht existierte.'
            )
        }
    }
    'energie.aspm' = @{
        Titel      = 'PCIe-Energieverwaltung (ASPM) im aktiven Energieplan ausschalten'
        Erklaerung = 'Grafikkarte und NVMe-SSD schalten ihre PCIe-Verbindung dann nie in einen Schlafzustand, was bei manchen Systemen Mikroruckler vermeidet. Der Verbrauch steigt minimal; auf einem Laptop im Akkubetrieb kostet es etwas Laufzeit.'
        Befehle    = @{
            Ausfuehren   = 'powercfg /setacvalueindex <aktiver Plan> 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg /setdcvalueindex <aktiver Plan> 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg /setactive SCHEME_CURRENT'
            Rueckgaengig = 'powercfg /setacvalueindex <damaliger Plan> 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 <alter AC-Wert>
powercfg /setdcvalueindex <damaliger Plan> 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 <alter DC-Wert>
powercfg /setactive SCHEME_CURRENT'
            Erklaerung   = @(
                'powercfg ändert Einstellungen der Energiepläne. /setacvalueindex gilt im Netzbetrieb (AC), /setdcvalueindex im Akkubetrieb (DC).',
                '501a4d13-… ist die Gruppe "PCI Express", ee12f906-… die Einstellung "Verbindungszustand-Energieverwaltung" (ASPM); 0 = aus, 1 = mittel, 2 = maximal sparen.',
                '/setactive SCHEME_CURRENT wendet den aktuellen Plan neu an, damit die Änderung sofort gilt.',
                'Rückgängig setzt in genau dem Plan, der damals aktiv war, die alten Werte (AC und DC) zurück.'
            )
        }
    }
    'gaming.spielmodus' = @{
        Titel      = 'Windows-Spielmodus einschalten'
        Erklaerung = 'Windows priorisiert dann das laufende Spiel und startet während des Spielens keine Update-Neustarts oder Treiberinstallationen. Der Effekt auf die FPS ist klein; bei Problemen in einzelnen Spielen lässt er sich wieder ausschalten.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKCU:\Software\Microsoft\GameBar'' -Name ''AutoGameModeEnabled'' -PropertyType DWord -Value 1 -Force   # legt den Schlüssel vorher an, falls er fehlt'
            Rueckgaengig = 'New-ItemProperty -Path ''HKCU:\Software\Microsoft\GameBar'' -Name ''AutoGameModeEnabled'' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path ''…'' -Name ''AutoGameModeEnabled'''
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'HKCU gilt nur für den angemeldeten Benutzer. AutoGameModeEnabled ist der Schalter "Spielmodus" (1 = an, 0 = aus).',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert (und einen selbst angelegten, leeren Schlüssel), wenn er vorher nicht existierte.'
            )
        }
    }
    'gaming.hags' = @{
        Titel      = 'Hardwarebeschleunigte GPU-Planung (HAGS) einschalten'
        Erklaerung = 'Die Grafikkarte verwaltet ihren Speicher dann selbst, was die Latenz senken kann und für DLSS Frame Generation nötig ist. Wirkt erst nach einem Neustart; bei Rucklern in einzelnen Spielen lässt es sich wieder ausschalten.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'' -Name ''HwSchMode'' -PropertyType DWord -Value 2 -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'' -Name ''HwSchMode'' -PropertyType DWord -Value <vorher> -Force   # existierte der Wert vorher nicht: Remove-ItemProperty -Path ''…'' -Name ''HwSchMode'''
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force).',
                'HwSchMode ist der Schalter hinter "Hardwarebeschleunigte GPU-Planung" (Einstellungen > System > Anzeige > Grafik); 2 = an, 1 = aus.',
                'Die Änderung wirkt erst nach einem Neustart.',
                'Rückgängig stellt den alten Wert wieder her bzw. löscht den Wert, wenn er vorher nicht existierte.'
            )
        }
    }
    'gaming.gamedvr' = @{
        Titel      = 'Hintergrundaufnahme (Game DVR) ausschalten'
        Erklaerung = 'Windows schneidet dann nicht mehr ständig die letzten Spielminuten mit, was FPS und Grafikspeicher spart. Aufnahmen per Xbox Game Bar (z. B. "Letzte 30 Sekunden speichern") gehen danach nicht mehr.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKCU:\System\GameConfigStore'' -Name ''GameDVR_Enabled'' -PropertyType DWord -Value 0 -Force
New-ItemProperty -Path ''HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'' -Name ''AppCaptureEnabled'' -PropertyType DWord -Value 0 -Force
New-ItemProperty -Path ''HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'' -Name ''HistoricalCaptureEnabled'' -PropertyType DWord -Value 0 -Force   # fehlende Schlüssel werden vorher angelegt'
            Rueckgaengig = 'New-ItemProperty -Path <Schlüssel> -Name <Wert> -PropertyType DWord -Value <vorher> -Force   # für alle drei Werte; existierte ein Wert vorher nicht: Remove-ItemProperty -Path <Schlüssel> -Name <Wert>'
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force). HKCU gilt nur für den angemeldeten Benutzer.',
                'GameDVR_Enabled (System\GameConfigStore) und AppCaptureEnabled sind die Hauptschalter für die Spielaufnahme der Game Bar; 0 = aus.',
                'HistoricalCaptureEnabled ist der Schalter "Aufzeichnen, was passiert ist" (Hintergrundaufnahme); 0 = aus. Genau diesen Wert wertet die Prüfung aus.',
                'Rückgängig stellt jeden der drei Werte einzeln wieder her bzw. löscht ihn, wenn er vorher nicht existierte.'
            )
        }
    }
    'gaming.maus' = @{
        Titel      = 'Mausbeschleunigung ausschalten'
        Erklaerung = 'Die Maus bewegt den Zeiger dann immer proportional zur Handbewegung ("Zeigerpräzision verbessern" aus), was vor allem in Shootern ein gleichmäßigeres Zielen ergibt. Die Umstellung braucht ein Ab- und Anmelden und fühlt sich anfangs ungewohnt an.'
        Befehle    = @{
            Ausfuehren   = 'New-ItemProperty -Path ''HKCU:\Control Panel\Mouse'' -Name ''MouseSpeed'' -PropertyType String -Value ''0'' -Force
New-ItemProperty -Path ''HKCU:\Control Panel\Mouse'' -Name ''MouseThreshold1'' -PropertyType String -Value ''0'' -Force
New-ItemProperty -Path ''HKCU:\Control Panel\Mouse'' -Name ''MouseThreshold2'' -PropertyType String -Value ''0'' -Force'
            Rueckgaengig = 'New-ItemProperty -Path ''HKCU:\Control Panel\Mouse'' -Name <Wert> -PropertyType String -Value ''<vorher>'' -Force   # für alle drei Werte; existierte ein Wert vorher nicht: Remove-ItemProperty -Path ''…'' -Name <Wert>'
            Erklaerung   = @(
                'New-ItemProperty legt einen Registry-Wert an bzw. überschreibt ihn (-Force). HKCU gilt nur für den angemeldeten Benutzer.',
                'MouseSpeed, MouseThreshold1 und MouseThreshold2 sind die drei Werte hinter "Zeigerpräzision verbessern"; alle drei auf "0" bedeutet: keine Beschleunigung.',
                '-PropertyType String: Diese Werte sind Text (REG_SZ), keine Zahlen.',
                'Windows liest die Werte erst nach dem nächsten Ab-/Anmelden. Rückgängig stellt jeden der drei Werte einzeln wieder her.'
            )
        }
    }
    'netz.eee' = @{
        Titel      = 'Energiesparfunktionen der LAN-Karte ausschalten'
        Erklaerung = 'Schaltet Energy Efficient Ethernet, Green Ethernet und ähnliche Schlafmodi der verbundenen Kabel-Netzwerkkarte aus, die in Online-Spielen kurze Latenzspitzen verursachen können. Dabei startet die Netzwerkkarte kurz neu, die Verbindung ist für einige Sekunden weg.'
        Befehle    = @{
            Ausfuehren   = 'Set-NetAdapterAdvancedProperty -Name ''<Adapter>'' -RegistryKeyword ''<Schlüsselwort>'' -RegistryValue ''0'' -NoRestart   # für jede aktive Energiesparfunktion (*EEE, EEELinkAdvertisement, *GreenEthernet, EnableGreenEthernet, AdvancedEEE, ULPMode, PowerSavingMode)
Restart-NetAdapter -Name ''<Adapter>'''
            Rueckgaengig = 'Set-NetAdapterAdvancedProperty -Name ''<Adapter>'' -RegistryKeyword ''<Schlüsselwort>'' -RegistryValue ''<vorher>'' -NoRestart   # für jede geänderte Funktion
Restart-NetAdapter -Name ''<Adapter>'''
            Erklaerung   = @(
                'Set-NetAdapterAdvancedProperty ändert eine erweiterte Treibereinstellung der Netzwerkkarte, hier über ihr Registry-Schlüsselwort (-RegistryKeyword).',
                'Die Schlüsselwörter stehen für Energy Efficient Ethernet, Green Ethernet, Advanced EEE, Ultra Low Power Mode und Power Saving Mode; 0 = aus. Es werden nur Funktionen geändert, die vorhanden und noch nicht aus sind, und nur bei verbundenen, kabelgebundenen Adaptern.',
                '-NoRestart verschiebt den Neustart des Adapters ans Ende, damit er nur einmal pro Adapter erfolgt.',
                'Restart-NetAdapter startet die Netzwerkkarte neu, damit die Einstellung wirkt; die Verbindung ist kurz unterbrochen.',
                'Rückgängig setzt jede geänderte Funktion auf ihren alten Wert zurück.'
            )
        }
    }
}
