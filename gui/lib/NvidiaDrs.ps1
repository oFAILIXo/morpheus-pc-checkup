#Requires -Version 5.1
<#
.SYNOPSIS
    NVIDIA-Treibereinstellungen (globales DRS-Profil) nur lesen und auswerten (Idee 5.6, Stufe 1, Karte #83).

.DESCRIPTION
    Wird per Dot-Source geladen (pc-check.ps1, Prüfung 'NVIDIA-Treibereinstellungen'). Zwei getrennte Teile:
    - Lesen (nativ): Get-MorpheusNvidiaDrsRoh lädt nvapi64.dll ausschließlich mit vollem Pfad aus System32
      (LOAD_LIBRARY_SEARCH_SYSTEM32), nach Signaturprüfung (Test-MorpheusNvapiHersteller), und liest das globale
      (Basis-)Profil über NVAPI-DRS. Es werden nur die festen Einstellungs-IDs aus $script:MorpheusNvidiaIds gelesen,
      kein Parameter kommt vom Browser oder Benutzer. Das Profil wird nie verändert.
    - Auswerten (rein): ConvertFrom-MorpheusNvapiZeile und Get-MorpheusNvidiaBefund machen aus den Rohwerten Text,
      Tabellenzeilen und Status. Beides ohne NVIDIA-Hardware testbar.
    Setting-IDs und Wertekonstanten stammen aus NvApiDriverSettings.h (github.com/NVIDIA/nvapi).
    Funktions-IDs (nvapi_QueryInterface): Initialize 0x0150E828, SYS_GetDriverAndBranchVersion 0x2926AAAD,
    DRS_CreateSession 0x0694D52E, DRS_LoadSettings 0x375DBD6B, DRS_GetBaseProfile 0xDA8466A0, DRS_GetSetting 0x73BF8338,
    DRS_DestroySession 0xDAD9CFF8.
    Fehler beim Lesen werfen eine Ausnahme; der Scan fängt sie in Invoke-Check ab und bricht nie ab.
#>

. (Join-Path $PSScriptRoot 'Sprache.ps1')

# Feste Liste der gelesenen Einstellungen (ID -> Name). Die gleiche Liste steht fest im C#-Teil unten.
$script:MorpheusNvidiaIds = [ordered]@{
    Shadercache      = [uint32]0x00198FFF   # PS_SHADERDISKCACHE_ID
    ShadercacheGroesse = [uint32]0x00AC8497 # PS_SHADERDISKCACHE_MAX_SIZE_ID
    Energie          = [uint32]0x1057EB71   # PREFERRED_PSTATE_ID
    VSync            = [uint32]0x00A879CF   # VSYNCMODE_ID
    MaxBildrate      = [uint32]0x10835002   # FRL_FPS_ID
    GSync            = [uint32]0x1194F158   # VRR_MODE_ID
}

$script:MorpheusNvapiCs = @'
using System;
using System.Runtime.InteropServices;
public static class MorpheusNvDrs {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr LoadLibraryExW(string path, IntPtr h, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi)]
    static extern IntPtr GetProcAddress(IntPtr h, string name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr QI(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int F0();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FOutPtr(out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FPtr(IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FPtrOutPtr(IntPtr s, out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FGetSetting(IntPtr s, IntPtr p, uint id, IntPtr setting);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FDrv(out uint ver, IntPtr branch);

    static QI qi;
    static T Fn<T>(uint id) where T : class {
        IntPtr p = qi(id);
        if (p == IntPtr.Zero) throw new Exception("QueryInterface 0x" + id.ToString("X8") + " fehlt");
        return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
    }
    const int SETTING_SIZE = 12320;                    // sizeof(NVDRS_SETTING_V1)
    const uint SETTING_VER = SETTING_SIZE | (1u << 16);
    // Feste Liste, kein Parameter von aussen
    static readonly uint[] IDS = new uint[] { 0x00198FFF, 0x00AC8497, 0x1057EB71, 0x00A879CF, 0x10835002, 0x1194F158 };

    // Liefert Zeilen "id|status|typ|ort|vordefiniert|wert"; die erste Zeile ist "driver|<Version>"
    public static string[] Read(string dllPath) {
        IntPtr lib = LoadLibraryExW(dllPath, IntPtr.Zero, 0x800);   // LOAD_LIBRARY_SEARCH_SYSTEM32
        if (lib == IntPtr.Zero) throw new Exception("LoadLibrary " + Marshal.GetLastWin32Error());
        IntPtr q = GetProcAddress(lib, "nvapi_QueryInterface");
        if (q == IntPtr.Zero) throw new Exception("nvapi_QueryInterface fehlt");
        qi = (QI)Marshal.GetDelegateForFunctionPointer(q, typeof(QI));
        int r = Fn<F0>(0x0150E828)();                                // NvAPI_Initialize
        if (r != 0) throw new Exception("Initialize " + r);
        uint ver; IntPtr branch = Marshal.AllocHGlobal(64);
        for (int b = 0; b < 64; b += 4) Marshal.WriteInt32(branch, b, 0);
        string driver;
        try {
            r = Fn<FDrv>(0x2926AAAD)(out ver, branch);               // NvAPI_SYS_GetDriverAndBranchVersion
            driver = r == 0 ? (ver / 100) + "." + (ver % 100).ToString("00") : "";
        } finally { Marshal.FreeHGlobal(branch); }
        IntPtr s, prof;
        r = Fn<FOutPtr>(0x0694D52E)(out s);                          // DRS_CreateSession
        if (r != 0) throw new Exception("CreateSession " + r);
        string[] res = new string[IDS.Length + 1];
        res[0] = "driver|" + driver;
        IntPtr buf = Marshal.AllocHGlobal(SETTING_SIZE);
        try {
            r = Fn<FPtr>(0x375DBD6B)(s);                             // DRS_LoadSettings
            if (r != 0) throw new Exception("LoadSettings " + r);
            r = Fn<FPtrOutPtr>(0xDA8466A0)(s, out prof);             // DRS_GetBaseProfile (globales Profil)
            if (r != 0) throw new Exception("GetBaseProfile " + r);
            FGetSetting get = Fn<FGetSetting>(0x73BF8338);           // DRS_GetSetting
            for (int i = 0; i < IDS.Length; i++) {
                for (int b = 0; b < SETTING_SIZE; b += 4) Marshal.WriteInt32(buf, b, 0);
                Marshal.WriteInt32(buf, 0, (int)SETTING_VER);
                r = get(s, prof, IDS[i], buf);
                string head = "0x" + IDS[i].ToString("X8") + "|" + r;
                if (r != 0) { res[i + 1] = head + "||||"; continue; }
                int typ = Marshal.ReadInt32(buf, 4104), ort = Marshal.ReadInt32(buf, 4108), pre = Marshal.ReadInt32(buf, 4112);
                string val = typ == 0 ? ((uint)Marshal.ReadInt32(buf, 8220)).ToString() : "";   // nur DWORD-Werte
                res[i + 1] = head + "|" + typ + "|" + ort + "|" + pre + "|" + val;
            }
        } finally {
            Marshal.FreeHGlobal(buf);
            Fn<FPtr>(0xDAD9CFF8)(s);                                 // DRS_DestroySession
        }
        return res;
    }
}
'@

<#
.SYNOPSIS
    Prüft Signaturstatus, Zertifikatsinhaber und Hersteller von nvapi64.dll. Gibt $null (in Ordnung) oder den Grund zurück.
    NVIDIA-Treiber sind per WHQL von Microsoft (Windows Hardware Compatibility Publisher) oder von NVIDIA Corporation
    signiert; zusätzlich muss der Hersteller NVIDIA sein.
#>
function Test-MorpheusNvapiHersteller {
    param([string]$Status, [string]$Subject, [string]$Firma)
    if ($Status -ne 'Valid') { return ('Signatur: ' + $Status) }
    if ($Subject -notmatch '^CN=(Microsoft Windows Hardware Compatibility Publisher|NVIDIA Corporation),') { return 'Herausgeber nicht zulässig' }
    if ($Firma -notmatch '^NVIDIA') { return 'Hersteller nicht NVIDIA' }
    $null
}

<#
.SYNOPSIS
    Pfad von nvapi64.dll (nur System32) oder $null, wenn kein NVIDIA-Treiber installiert ist.
#>
function Get-MorpheusNvapiPfad {
    $p = Join-Path ([Environment]::SystemDirectory) 'nvapi64.dll'
    if ([IO.File]::Exists($p)) { $p } else { $null }
}

<#
.SYNOPSIS
    Rohzeile "0xID|status|typ|ort|vordefiniert|wert" in ein Objekt umwandeln (rein).
#>
function ConvertFrom-MorpheusNvapiZeile {
    param([Parameter(Mandatory)][string]$Zeile)
    $p = $Zeile.Split('|')
    if ($p.Count -lt 6) { return $null }
    $id = $null; $st = 0
    try { $id = [Convert]::ToUInt32($p[0].Substring(2), 16); $st = [int]$p[1] } catch { return $null }
    $wert = $null
    if ($st -eq 0 -and $p[2] -eq '0' -and $p[5] -ne '') { try { $wert = [uint32]$p[5] } catch { $wert = $null } }
    [pscustomobject][ordered]@{ Id = $id; Status = $st; Typ = $p[2]; Ort = $p[3]; Vordefiniert = $p[4]; Wert = $wert }
}

<#
.SYNOPSIS
    Liest das globale NVIDIA-Treiberprofil. Gibt @{ Treiber = '…'; Zeilen = @(Objekte aus ConvertFrom-MorpheusNvapiZeile) }
    zurück, $null ohne nvapi64.dll; wirft bei ungültiger Signatur oder Lesefehler.
#>
function Get-MorpheusNvidiaDrsRoh {
    $dll = Get-MorpheusNvapiPfad
    if (-not $dll) { return $null }
    $sig = Get-AuthenticodeSignature -LiteralPath $dll
    $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
    $grund = Test-MorpheusNvapiHersteller -Status ([string]$sig.Status) -Subject $subject -Firma ([string](Get-Item -LiteralPath $dll).VersionInfo.CompanyName)
    if ($grund) { throw (T 'scan.nvidia.signaturUngueltig' $grund) }
    if (-not ('MorpheusNvDrs' -as [type])) { Add-Type -TypeDefinition $script:MorpheusNvapiCs -ErrorAction Stop }
    $res = [MorpheusNvDrs]::Read($dll)
    $treiber = ''
    $zeilen = New-Object System.Collections.Generic.List[object]
    foreach ($r in $res) {
        if ($r -like 'driver|*') { $treiber = $r.Substring(7); continue }
        $o = ConvertFrom-MorpheusNvapiZeile $r
        if ($o) { $zeilen.Add($o) }
    }
    @{ Treiber = $treiber; Zeilen = $zeilen.ToArray() }
}

# NVAPI_SETTING_NOT_FOUND: Einstellung im globalen Profil nicht gesetzt = Treiber-Standard
$script:MorpheusNvapiNichtGesetzt = -160

<#
.SYNOPSIS
    Wertet gelesene Rohwerte aus (rein, ohne Hardware). Gibt @{ Zeilen; Status; Hinweise; Zusammenfassung; Gelesen } zurück.
    Zeilen: Einstellung, Wert, Quelle, Hinweis. Status: OK, INFO (Tipp) oder WARN.
    Gelesen = Anzahl der Einstellungen, die der Treiber lesbar geliefert hat (gesetzt oder Standard).
#>
function Get-MorpheusNvidiaBefund {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Roh)
    $ids = $script:MorpheusNvidiaIds
    $rang = @{ OK = 0; INFO = 1; WARN = 2 }
    $zeilen = New-Object System.Collections.Generic.List[object]
    $hinweise = New-Object System.Collections.Generic.List[string]
    $gesamt = 'OK'; $gelesen = 0; $abweichend = 0
    foreach ($name in $ids.Keys) {
        $z = @($Roh | Where-Object { $null -ne $_ -and $_.Id -eq $ids[$name] }) | Select-Object -First 1
        $titel = T ('scan.nvidia.n.' + $name)
        $nicht = $false; $unlesbar = $false
        if ($null -eq $z) { $unlesbar = $true }
        elseif ($z.Status -eq $script:MorpheusNvapiNichtGesetzt) { $nicht = $true }
        elseif ($z.Status -ne 0 -or $null -eq $z.Wert) { $unlesbar = $true }
        $status = 'OK'; $hinweis = ''
        if ($unlesbar) {
            $zeilen.Add([pscustomobject][ordered]@{ Einstellung = $titel; Wert = (T 'scan.nvidia.unlesbar'); Quelle = ''; Hinweis = '' })
            continue
        }
        $gelesen++
        $w = if ($nicht) { $null } else { [uint32]$z.Wert }
        $text = T 'scan.nvidia.standard'
        $quelle = if ($nicht) { T 'scan.nvidia.quelleStandard' } elseif ("$($z.Vordefiniert)" -eq '1') { T 'scan.nvidia.quelleVorgabe' } else { T 'scan.nvidia.quelleGesetzt' }
        if (-not $nicht) {
            switch ($name) {
                'Shadercache' {
                    if ($w -eq 0) { $text = T 'scan.nvidia.aus'; $status = 'WARN'; $hinweis = T 'scan.nvidia.hinweisCacheAus' }
                    elseif ($w -eq 1) { $text = T 'scan.nvidia.an' }
                    else { $text = '0x{0:X8}' -f $w }
                }
                'ShadercacheGroesse' {
                    if ($w -eq 0) { $text = T 'scan.nvidia.deaktiviert'; $status = 'WARN'; $hinweis = T 'scan.nvidia.hinweisCacheGroesse' }
                    elseif ($w -eq [uint32]::MaxValue) { $text = T 'scan.nvidia.unbegrenzt' }
                    elseif ($w -lt 1024) { $text = T 'scan.nvidia.mb' $w; $status = 'INFO'; $hinweis = T 'scan.nvidia.hinweisCacheGroesse' }
                    else { $text = T 'scan.nvidia.mb' $w }
                }
                'Energie' {
                    $text = switch ([int64]$w) {
                        0 { T 'scan.nvidia.energie0' } 1 { T 'scan.nvidia.energie1' } 2 { T 'scan.nvidia.energie2' }
                        3 { T 'scan.nvidia.energie3' } 4 { T 'scan.nvidia.energie4' } 5 { T 'scan.nvidia.energie5' }
                        default { '0x{0:X8}' -f $w }
                    }
                    if ($w -eq 1) { $status = 'INFO'; $hinweis = T 'scan.nvidia.hinweisEnergie' }
                }
                'VSync' {
                    switch ($w) {
                        0x60925292 { $text = T 'scan.nvidia.vsyncAnwendung' }
                        0x08416747 { $text = T 'scan.nvidia.vsyncAus'; $status = 'INFO'; $hinweis = T 'scan.nvidia.hinweisVSync' }
                        0x47814940 { $text = T 'scan.nvidia.vsyncAn'; $status = 'INFO'; $hinweis = T 'scan.nvidia.hinweisVSync' }
                        0x32610244 { $text = T 'scan.nvidia.vsyncHalb'; $status = 'INFO'; $hinweis = T 'scan.nvidia.hinweisVSync' }
                        0x71271021 { $text = T 'scan.nvidia.vsyncDrittel'; $status = 'INFO'; $hinweis = T 'scan.nvidia.hinweisVSync' }
                        0x13245256 { $text = T 'scan.nvidia.vsyncViertel'; $status = 'INFO'; $hinweis = T 'scan.nvidia.hinweisVSync' }
                        0x18888888 { $text = T 'scan.nvidia.vsyncVirtuell'; $status = 'INFO'; $hinweis = T 'scan.nvidia.hinweisVSync' }
                        default { $text = '0x{0:X8}' -f $w }
                    }
                }
                'MaxBildrate' {
                    if ($w -eq 0) { $text = T 'scan.nvidia.unbegrenztFps' }
                    else { $text = T 'scan.nvidia.fps' $w; $status = 'INFO'; $hinweis = T 'scan.nvidia.hinweisFps' $w }
                }
                'GSync' {
                    switch ($w) {
                        0 { $text = T 'scan.nvidia.gsync0'; $status = 'INFO'; $hinweis = T 'scan.nvidia.hinweisGSync' }
                        1 { $text = T 'scan.nvidia.gsync1' }
                        2 { $text = T 'scan.nvidia.gsync2' }
                        default { $text = '0x{0:X8}' -f $w }
                    }
                }
            }
        }
        else {
            # Nicht gesetzt: Standard des Treibers; nur anzeigen, was der Standard bedeutet
            $text = switch ($name) {
                'Shadercache' { T 'scan.nvidia.standardAn' }
                'Energie' { T 'scan.nvidia.standardEnergie' }
                'VSync' { T 'scan.nvidia.standardVSync' }
                'MaxBildrate' { T 'scan.nvidia.standardFps' }
                'GSync' { T 'scan.nvidia.standardGSync' }
                default { T 'scan.nvidia.standard' }
            }
        }
        if ($status -ne 'OK') { $abweichend++; if ($hinweis) { $hinweise.Add($hinweis) } }
        if ($rang[$status] -gt $rang[$gesamt]) { $gesamt = $status }
        $zeilen.Add([pscustomobject][ordered]@{ Einstellung = $titel; Wert = $text; Quelle = $quelle; Hinweis = $hinweis })
    }
    $abw = @($zeilen.ToArray() | Where-Object { $_.Hinweis })
    $zus = T 'scan.nvidia.alleStandard'
    if ($abw.Count -gt 0) { $zus = T 'scan.nvidia.abweichend' (($abw | ForEach-Object { $_.Einstellung + ': ' + $_.Wert }) -join '; ') }
    @{ Zeilen = $zeilen.ToArray(); Status = $gesamt; Hinweise = $hinweise.ToArray(); Zusammenfassung = $zus; Gelesen = $gelesen }
}
