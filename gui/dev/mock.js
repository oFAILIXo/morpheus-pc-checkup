/* Entwicklungsmodus: fängt fetch('/api/*') ab und antwortet mit erfundenen Demodaten (PC "DEMO-PC").
   Öffnen: gui/dev/mock.html (direkt als Datei oder über einen lokalen Webserver). Keine echten Daten. */
'use strict';
(() => {
  try { sessionStorage.setItem('pcCheckToken', 'demo-token'); } catch { /* egal */ }
  const iso = d => { const p = n => String(n).padStart(2, '0'); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`; };
  const F = (Area, Category, Check, Status, Value, Recommendation = '', x = {}) => ({ Area, Category, Check, Status, Value, Recommendation, OriginalStatus: '', Note: '', Effort: '', Benefit: '', Risk: '', Steps: [], Command: '', ...x });
  const base = [
    F('Sicherheit', 'System & Updates', 'Windows-Version', 'OK', 'Windows 11 Pro 24H2 (Demo)'),
    F('Sicherheit', 'System & Updates', 'Windows Update: ausstehend', 'TIPP', 'Nur optional: Treiber', 'Optionale Treiber nur bei Problemen installieren.', { Effort: 'gering', Benefit: 'mittel', Risk: 'gering', Steps: ['Einstellungen > Windows Update > „Nach Updates suchen“.', 'Danach neu starten.'] }),
    F('Sicherheit', 'Virenschutz', 'Microsoft Defender: Status', 'OK', 'Echtzeit-, Verhaltens- und Download-Schutz aktiv'),
    F('Sicherheit', 'Virenschutz', 'Defender: Einstellungen', 'TIPP', 'Netzwerkschutz aus; PUA-Schutz an', 'Netzwerkschutz einschalten.', { Effort: 'gering', Benefit: 'mittel', Risk: 'gering', Steps: ['Rechtsklick auf Start > „Terminal (Administrator)“.', 'Befehl einfügen.'], Command: 'Set-MpPreference -EnableNetworkProtection Enabled' }),
    F('Sicherheit', 'Virenschutz', 'Defender: ASR-Regeln', 'TIPP', 'Keine Regeln aktiv', 'Zwei Basisregeln aktivieren.', { Effort: 'gering', Benefit: 'mittel', Risk: 'gering' }),
    F('Sicherheit', 'Fernzugriff & Dienste', 'Remoteunterstützung', 'OK', 'Nicht erlaubt'),
    F('Sicherheit', 'Firewall & Netzwerk', 'Firewall-Profile', 'OK', 'Alle Profile aktiv, eingehend blockiert'),
    F('Sicherheit', 'Fernzugriff & Dienste', 'Offene Ports', 'WARN', '3 Ports lauschen auf allen Adressen (192.168.0.15, DEMO-PC)', 'Prüfen, ob die Dienste nötig sind.', { Effort: 'mittel', Benefit: 'mittel', Risk: 'gering' }),
    F('Sicherheit', 'Verschlüsselung & Firmware', 'Secure Boot', 'OK', 'UEFI, Secure Boot an'),
    F('Sicherheit', 'Verschlüsselung & Firmware', 'TPM', 'SKIP', 'Nur mit Adminrechten prüfbar'),
    F('Sicherheit', 'Systemhärtung', 'Kernisolierung (VBS / Speicherintegrität)', 'INFO', 'VBS läuft, Speicherintegrität aus'),
    F('Sicherheit', 'Verschlüsselung & Firmware', 'BitLocker', 'ACK', 'Systemlaufwerk nicht verschlüsselt', '', { OriginalStatus: 'WARN', Note: 'Bewusst zurückgestellt bis 30.04.2027' }),
    F('Sicherheit', 'Systemhärtung', 'LSA-Schutz', 'TIPP', 'aus', 'LSA-Schutz einschalten (Neustart).', { Effort: 'gering', Benefit: 'hoch', Risk: 'gering' }),
    F('Sicherheit', 'Software', 'Software-Updates', 'WARN', 'Beispielprogramm 1.2 verfügbar (C:\\Users\\Demo\\Apps)', 'Programm aktualisieren.', { Effort: 'gering', Benefit: 'hoch', Risk: 'gering' }),
    F('Performance', 'Hardware', 'Arbeitsspeicher', 'OK', '32 GB DDR5'),
    F('Performance', 'Laufwerke & Speicherplatz', 'Speicherplatz', 'INFO', 'C: 32 % frei, F: 13 % frei'),
    F('Performance', 'Energie', 'Energieplan', 'OK', 'Ausbalanciert aktiv'),
    F('Performance', 'Energie', 'Schnellstart', 'TIPP', 'an: Treiberprobleme überdauern das Herunterfahren', 'Schnellstart ausschalten.', { Effort: 'gering', Benefit: 'mittel', Risk: 'gering' }),
    F('Performance', 'Auslastung', 'CPU-Auslastung', 'OK', 'Im Leerlauf 3 %'),
    F('Performance', 'Gaming & Grafik', 'Spielmodus', 'OK', 'an'),
    F('Performance', 'Gaming & Grafik', 'Hardwarebeschleunigte GPU-Planung (HAGS)', 'TIPP', 'aus', 'HAGS einschalten (Neustart).', { Effort: 'gering', Benefit: 'mittel', Risk: 'mittel' }),
    F('Performance', 'Gaming & Grafik', 'Spielebibliotheken', 'WARN', 'F: nur 13 % frei', 'Platz schaffen oder Bibliothek verschieben.', { Effort: 'mittel', Benefit: 'hoch', Risk: 'gering', Steps: ['Steam > Einstellungen > Speicher.'] }),
    F('Performance', 'Gaming & Grafik', 'Bildschirme und Bildwiederholrate', 'OK', '165 Hz'),
    F('Performance', 'Stabilität', 'Zuverlässigkeitsindex', 'OK', '9,2 von 10'),
    F('Performance', 'Stabilität', 'Abstürze und unerwartete Neustarts', 'OK', '0 unerwartete Neustarts, 0 Bluescreens in 14 Tagen; 0 Minidumps insgesamt'),
    F('Performance', 'Stabilität', 'Programmabstürze', 'INFO', '2 Abstürze, 0 Hänger: demo-app.exe (2)'),
    F('Performance', 'Stabilität', 'Startdauer', 'OK', 'Ø 26 s bis zum Desktop'),
  ];
  const mkReport = i => {   // i = 0 neuester
    const d = new Date(2026, 9, 25 - i, 13, 21);
    const F2 = base.map(f => ({ ...f }));
    if (i > 0) F2.forEach(f => { if (f.Check === 'Offene Ports' && i > 2) f.Status = 'CRIT'; if (f.Check === 'Software-Updates' && i > 4) f.Status = 'OK'; if (f.Check === 'Spielebibliotheken' && i > 6) f.Status = 'INFO'; });
    const name = `pc-check_${iso(d).slice(0, 10)}_1321`;
    return { name, json: { Meta: { Computer: 'DEMO-PC', Erstellt: iso(d), Version: '2.1.0', Admin: true, EventDays: 14, DauerSek: 120 + i, Profil: 'Gaming' }, Findings: F2,
      Changes: i < 11 ? { VerglichenMit: 'vorher.json', Erstellt: iso(new Date(2026, 9, 24 - i, 13, 21)), AdminVorher: true, Status: [{ 'Prüfung': 'Offene Ports', Vorher: 'Kritisch', Jetzt: 'Warnung', Befund: '3 Ports' }], Bestand: { 'Autostart-Einträge': { Neu: ['Demo-Tool <b>fett</b>'], Entfernt: ['Altes Tool'] } } } : null,
      Data: { System: [{ Computer: 'DEMO-PC', Edition: 'Windows 11 Pro', Version: '24H2' }],
        'Startdauer (letzte Messungen)': [{ Zeit: 'x', GesamtSek: 40, HauptpfadSek: 22 + (i % 5) * 3, NachAnmeldungSek: 5 }, { Zeit: 'y', GesamtSek: 41, HauptpfadSek: 24 + (i % 4) * 2, NachAnmeldungSek: 6 }],
        'Laufwerke (Volumes)': [{ Laufwerk: 'C:', Name: '', Dateisystem: 'NTFS', Groesse: '238 GB', Frei: '76 GB', FreiProzent: 30 + ((11 - i) % 7) * 2 }, { Laufwerk: 'F:', Name: 'Spiele', Dateisystem: 'NTFS', Groesse: '1 TB', Frei: '130 GB', FreiProzent: 13 }],
        'Offene Netzwerkports (nicht nur lokal)': [
          { Protokoll: 'TCP', Port: 135, Adressen: '0.0.0.0', Prozess: 'svchost', Dienste: 'RpcSs', PID: 1020 }, { Protokoll: 'TCP', Port: 445, Adressen: '0.0.0.0', Prozess: 'System', Dienste: null, PID: 4 },
          { Protokoll: 'TCP', Port: 3389, Adressen: '0.0.0.0', Prozess: 'svchost', Dienste: 'TermService', PID: 1180 }, { Protokoll: 'TCP', Port: 5040, Adressen: '0.0.0.0', Prozess: 'svchost', Dienste: 'CDPSvc', PID: 2200 },
          { Protokoll: 'TCP', Port: 8080, Adressen: '0.0.0.0', Prozess: 'demo-server', Dienste: null, PID: 7312 }, { Protokoll: 'TCP', Port: 49664, Adressen: '0.0.0.0', Prozess: 'lsass', Dienste: 'SamSs', PID: 780 },
          { Protokoll: 'UDP', Port: 5353, Adressen: '0.0.0.0', Prozess: 'msedge', Dienste: null, PID: 9020 }, { Protokoll: 'UDP', Port: 5355, Adressen: '0.0.0.0', Prozess: 'svchost', Dienste: 'Dnscache', PID: 1400 },
          { Protokoll: 'UDP', Port: 1900, Adressen: '0.0.0.0', Prozess: 'svchost', Dienste: 'SSDPSRV', PID: 3300 }],
        'Autostart-Einträge': [{ Name: 'Demo-Tool', Pfad: 'C:\\Demo\\tool.exe', Benutzer: 'Demo' }] },
      DataChecks: { System: 'Windows-Version', 'Startdauer (letzte Messungen)': 'Startdauer', 'Laufwerke (Volumes)': 'Speicherplatz', 'Offene Netzwerkports (nicht nur lokal)': 'Offene Ports' } } };
  };
  const reps = Array.from({ length: 12 }, (_, i) => mkReport(i));
  const cnt = js => { const c = { CRIT: 0, WARN: 0, TIPP: 0, ACK: 0, INFO: 0, OK: 0, SKIP: 0 }; js.Findings.forEach(f => { c[f.Status]++; }); return c; };
  const reportList = () => reps.map(r => ({ name: r.name, created: r.json.Meta.Erstellt, version: '2.1.0', admin: true, profil: 'Gaming', counts: cnt(r.json) }));

  const A = (id, kategorie, pruefung, titel, erkl, n, a, r, extra = {}) => ({ id, kategorie, pruefung, titel, erklaerung: erkl, nutzen: n, aufwand: a, risiko: r, neustart: false, varianten: null,
    befehle: { ausfuehren: extra.cmd || '', rueckgaengig: extra.undo || '', erklaerung: extra.expl || [] }, zustand: { aktiv: false, wert: 'aus', stand: iso(new Date()) }, ...extra.o });
  const actions = [
    A('defender.netzwerkschutz', 'Sicherheit', 'Defender: Einstellungen', 'Netzwerkschutz einschalten', 'Blockiert Verbindungen zu bekannten Phishing- und Malware-Servern, in allen Programmen.', 'mittel', 'gering', 'gering', { cmd: 'Set-MpPreference -EnableNetworkProtection Enabled', undo: 'Set-MpPreference -EnableNetworkProtection <vorher>', expl: ['Set-MpPreference ändert eine Einstellung von Microsoft Defender.', '-EnableNetworkProtection Enabled schaltet den Schutz scharf.'] }),
    A('defender.asr-basis', 'Sicherheit', 'Defender: ASR-Regeln', 'ASR-Basisregeln aktivieren', 'Zwei Regeln gegen Treiber- und Anmeldedaten-Missbrauch.', 'mittel', 'gering', 'gering', { cmd: 'Add-MpPreference -AttackSurfaceReductionRules_Ids 56a863a9-875e-4185-98a7-b882c64b5ce5 -AttackSurfaceReductionRules_Actions <variante>', undo: 'Remove-MpPreference …', o: { varianten: ['Enabled', 'AuditMode'], zustand: { aktiv: false, wert: '0 Regeln', stand: iso(new Date()) } } }),
    A('fernzugriff.remoteunterstuetzung', 'Sicherheit', 'Remoteunterstützung', 'Remoteunterstützung ausschalten', 'Verhindert Fernhilfe-Einladungen.', 'gering', 'gering', 'gering', { cmd: 'Set-ItemProperty …', o: { zustand: { aktiv: true, wert: 'aus', stand: iso(new Date()) } } }),
    A('haertung.lsa', 'Sicherheit', 'LSA-Schutz', 'LSA-Schutz einschalten', 'Schützt gespeicherte Anmeldedaten im Arbeitsspeicher.', 'hoch', 'gering', 'gering', { cmd: 'New-ItemProperty -Path HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa -Name RunAsPPL -Value 1 -Force', o: { neustart: true } }),
    A('system.schnellstart', 'Leistung', 'Schnellstart', 'Schnellstart ausschalten', 'Windows fährt dann wirklich herunter.', 'mittel', 'gering', 'gering', { cmd: 'powercfg /hibernate off', undo: 'powercfg /hibernate on', expl: ['Schaltet Ruhezustand und Schnellstart ab.'], o: { zustand: { aktiv: false, wert: 'an', stand: iso(new Date()) } } }),
    A('energie.plan', 'Leistung', 'Energieplan', 'Energieplan wechseln', 'Wechselt zu einem vorhandenen Energiesparplan.', 'mittel', 'gering', 'gering', { cmd: 'powercfg /setactive <variante>', o: { varianten: ['Ausbalanciert', 'Höchstleistung', 'Gaming (dynamisch)'], zustand: { aktiv: false, wert: 'Ausbalanciert', stand: iso(new Date()) } } }),
    A('gaming.spielmodus', 'Gaming', 'Spielmodus', 'Spielmodus einschalten', 'Priorisiert Spiele.', 'mittel', 'gering', 'gering', { cmd: 'Set-ItemProperty …', o: { zustand: { aktiv: true, wert: 'an', stand: iso(new Date()) } } }),
    A('gaming.hags', 'Gaming', 'Hardwarebeschleunigte GPU-Planung (HAGS)', 'HAGS einschalten', 'Die Grafikkarte plant ihren Speicher selbst.', 'mittel', 'gering', 'mittel', { cmd: 'Set-ItemProperty -Path HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers -Name HwSchMode -Value 2', o: { neustart: true } }),
    A('gaming.maus', 'Gaming', 'Mausbeschleunigung', 'Mausbeschleunigung ausschalten', 'Gleichmäßigeres Zielen.', 'mittel', 'gering', 'gering', { cmd: 'Set-ItemProperty -Path "HKCU:\\Control Panel\\Mouse" -Name MouseSpeed -Value 0', o: { zustand: { aktiv: false, wert: 'an', stand: iso(new Date()) } } }),
  ];
  const journal = [
    { id: '20261024-190211-01', zeit: '2026-10-24T19:02:11', art: 'ausfuehren', aktion: 'netz.eee', titel: 'Energiesparfunktionen Netzwerkkarte aus', variante: null, vorher: 'an', nachher: 'aus', wiederherstellungspunkt: { seq: 56, zeit: '2026-10-24T19:02:00' }, status: 'erledigt', bezug: null, meldung: '', benutzer: 'demo' },
    { id: '20261024-110000-01', zeit: '2026-10-24T11:00:00', art: 'ausfuehren', aktion: 'gaming.gamedvr', titel: 'Game DVR aus (Zustand wurde danach geändert)', variante: null, vorher: 1, nachher: 0, wiederherstellungspunkt: { seq: 55, zeit: '2026-10-24T10:59:50' }, status: 'erledigt', bezug: null, meldung: '', benutzer: 'demo' },
  ];
  const session = { version: '2.1.0', pc: 'DEMO-PC', admin: true, profil: 'Gaming', benutzer: 'demo',
    safety: { schutzAn: true, laufwerk: 'C:', sperre24h: true, letzterPunkt: '2026-10-25T12:02:11', befehl: "New-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore' -Name SystemRestorePointCreationFrequency -PropertyType DWord -Value 0 -Force" } };
  const help = { Status: { CRIT: 'Kritisch: echtes Risiko. Zuerst beheben.', WARN: 'Warnung: sollte behoben werden.', ACK: 'Akzeptiert: bewusst als gewollt eingetragen.', TIPP: 'Tipp: lohnende Verbesserung.', INFO: 'Hinweis: reine Information.', OK: 'OK: alles in Ordnung.', SKIP: 'Nicht geprüft.' },
    Kategorien: { Virenschutz: 'Microsoft Defender reicht für Privat-PCs, solange alle Schutzfunktionen an sind.', 'Gaming & Grafik': 'Einstellungen, die Bildraten und Frametimes beeinflussen.' },
    Pruefungen: { 'Defender: Einstellungen': { Was: 'Ob die Schutzfunktionen von Defender eingeschaltet sind.', Warum: 'Abgeschaltete Funktionen lassen Lücken.', Harmlos: 'Wenn ein anderes Virenprogramm aktiv ist.' } } };
  let checklist = { 'Offene Ports': { state: 'later', date: '24.10.2026', report: '2026-10-24T13:21:00' }, 'Software-Updates': { state: 'done', date: '25.10.2026', report: reps[0].json.Meta.Erstellt } };

  // ---- Jobs: jede Zeile erscheint 700 ms nach der vorigen
  const jobs = {}; let jobSeq = 0;
  const clock = () => { const d = new Date(); const p = n => String(n).padStart(2, '0'); return `[${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}]`; };
  function newJob(art, lines, finish) {
    const id = 'job' + (++jobSeq);
    jobs[id] = { art, t0: Date.now(), lines: lines.map(l => clock() + ' ' + l), step: 700, finish, done: false, ergebnis: null };
    return id;
  }
  function jobState(id, from) {
    const j = jobs[id]; if (!j) return [404, { error: 'Job unbekannt' }];
    const n = Math.min(j.lines.length, Math.floor((Date.now() - j.t0) / j.step));
    const finished = n >= j.lines.length;
    if (finished && !j.done) { j.done = true; j.ergebnis = j.finish(); }
    return [200, { id, art: j.art, status: finished ? 'done' : 'running', log: j.lines.slice(from, n), next: n, ergebnis: finished ? j.ergebnis : null }];
  }
  function runActions(ids, variante) {
    const sel = ids.map(i => actions.find(a => a.id === i));
    if (!sel.length || sel.some(a => !a)) return [400, { error: 'Unbekannte Aktion' }];
    if (Object.values(jobs).some(j => j.art === 'aendern' && !j.done)) return [409, { error: 'Es läuft bereits eine Änderung' }];
    const lines = ['Lese aktuellen Zustand …', 'Lege Wiederherstellungspunkt an …', 'Prüfe Wiederherstellungspunkt: vorhanden (#57)', 'Schreibe Journal-Eintrag …', ...sel.map(a => `Führe aus: ${a.titel}`), 'Prüfe Ergebnis …'];
    const id = newJob('aendern', lines, () => sel.map(a => {
      const vorher = a.zustand.wert; a.zustand = { aktiv: true, wert: variante || 'geändert', stand: iso(new Date()) };
      journal.unshift({ id: 'e' + Date.now() + a.id, zeit: iso(new Date()), art: 'ausfuehren', aktion: a.id, titel: a.titel, variante: variante || null, vorher, nachher: a.zustand.wert, wiederherstellungspunkt: { seq: 57, zeit: iso(new Date()) }, status: 'erledigt', bezug: null, meldung: '', benutzer: 'demo' });
      return { id: a.id, status: 'erledigt', vorher, nachher: a.zustand.wert, neustart: !!a.neustart, meldung: '' };
    }));
    return [200, { jobId: id }];
  }
  function undo(entryId, force) {
    const e = journal.find(x => x.id === entryId);
    if (!e) return [404, { error: 'Eintrag unbekannt' }];
    if (e.status !== 'erledigt') return [400, { error: 'Nicht rückgängig zu machen' }];
    if (e.titel.includes('geändert') && !force) return [409, { error: 'Der Zustand hat sich seit der Änderung geändert (aktuell ≠ gespeicherter Nachher-Zustand).' }];
    const id = newJob('aendern', ['Lese aktuellen Zustand …', 'Lege Wiederherstellungspunkt an …', 'Prüfe Wiederherstellungspunkt: vorhanden (#58)', 'Schreibe Journal-Eintrag …', 'Führe aus: Rückgängig', 'Prüfe Ergebnis …'], () => {
      e.status = 'zurueckgenommen';
      const a = actions.find(x => x.id === e.aktion); if (a) a.zustand = { aktiv: false, wert: String(e.vorher), stand: iso(new Date()) };
      journal.unshift({ id: 'u' + Date.now(), zeit: iso(new Date()), art: 'rueckgaengig', aktion: e.aktion, titel: e.titel, variante: null, vorher: e.nachher, nachher: e.vorher, wiederherstellungspunkt: { seq: 58, zeit: iso(new Date()) }, status: 'erledigt', bezug: e.id, meldung: '', benutzer: 'demo' });
      return { id: e.aktion, status: 'erledigt', vorher: e.nachher, nachher: e.vorher, neustart: false, meldung: '' };
    });
    return [200, { jobId: id }];
  }
  function scan(body) {
    if (!(body.eventDays >= 1 && body.eventDays <= 90)) return [400, { error: 'Zeitraum ungültig' }];
    const lines = ['[Sicherheit] System & Updates', '  - Windows-Version', '  - Windows Update: ausstehend', '[Sicherheit] Virenschutz', '  - Defender: Einstellungen', '[Performance] Gaming & Grafik', '  - Resizable BAR und PCIe-Anbindung', `Profil: ${body.profil}, Zeitraum ${body.eventDays} Tage`, 'Schreibe Bericht …'];
    const id = newJob('scan', lines, () => {
      const r = mkReport(0), d = new Date(), p = n => String(n).padStart(2, '0');
      r.name = `pc-check_${iso(d).slice(0, 10)}_${p(d.getHours())}${p(d.getMinutes())}`;
      r.json.Meta.Erstellt = iso(d); r.json.Findings = r.json.Findings.filter(f => f.Check !== 'Offene Ports');
      reps.unshift(r); return { name: r.name };
    });
    return [200, { jobId: id }];
  }

  // ---- /api/live: sich bewegende Demo-Werte (erster Abruf: stand = null, wie beim echten Server)
  const walk = (v, step, lo = 1, hi = 99) => Math.max(lo, Math.min(hi, v + (Math.random() - 0.5) * 2 * step));
  const hist = { cpu: [], ram: [], gpu: [] };
  const lv = { cpu: 18, ram: 52, gpu: 34, temp: 62, rx: 480, tx: 90, calls: 0 };
  const push = (a, v) => { a.push(Math.round(v)); if (a.length > 30) a.shift(); };
  for (let i = 0; i < 24; i++) { lv.cpu = walk(lv.cpu, 9); lv.ram = walk(lv.ram, 2); lv.gpu = walk(lv.gpu, 8); push(hist.cpu, lv.cpu); push(hist.ram, lv.ram); push(hist.gpu, lv.gpu); }
  function live() {
    if (lv.calls++ === 0) return { stand: null, cpu: null, ram: null, gpu: null, net: null, top: [], drives: [], verlauf: { cpu: [], ram: [], gpu: [] } };
    lv.cpu = walk(lv.cpu, 9); lv.ram = walk(lv.ram, 2); lv.gpu = walk(lv.gpu, 8); lv.temp = walk(lv.temp, 4, 45, 92); lv.rx = walk(lv.rx, 400, 0, 6000); lv.tx = walk(lv.tx, 60, 0, 900);
    push(hist.cpu, lv.cpu); push(hist.ram, lv.ram); push(hist.gpu, lv.gpu);
    return { stand: iso(new Date()), cpu: Math.round(lv.cpu), ram: { usedPct: Math.round(lv.ram), usedGB: Math.round(lv.ram * 0.32 * 10) / 10, totalGB: 32 },
      gpu: { name: 'Demo GPU RTX 4070', util: Math.round(lv.gpu), temp: Math.round(lv.temp), memUsedPct: 41 },
      net: { adapter: 'Ethernet (Demo)', linkMbps: 1000, rxKBs: Math.round(lv.rx), txKBs: Math.round(lv.tx) },
      top: [{ name: 'demo-game', cpu: Math.round(lv.cpu * 0.5 * 10) / 10 }, { name: 'msedge', cpu: Math.round(lv.cpu * 0.2 * 10) / 10 }, { name: 'demo-tool', cpu: 0.8 }],
      drives: [{ letter: 'C:', label: 'System', type: 'SSD', freePct: 32, freeGB: 76, sizeGB: 238 }, { letter: 'F:', label: 'Spiele', type: 'SSD', freePct: 13, freeGB: 130, sizeGB: 1000 }, { letter: 'D:', label: 'Daten', type: 'HDD', freePct: 6, freeGB: 110, sizeGB: 1863 }],
      verlauf: { cpu: hist.cpu.slice(), ram: hist.ram.slice(), gpu: hist.gpu.slice() } };
  }

  const realFetch = window.fetch.bind(window);
  window.fetch = async (url, opt = {}) => {
    const u = String(url);
    if (!u.startsWith('/api/')) return realFetch(url, opt);
    if (!(opt.headers && opt.headers['X-PcCheck-Token'])) return new Response(JSON.stringify({ error: 'Token fehlt' }), { status: 401 });
    const method = (opt.method || 'GET').toUpperCase();
    const body = opt.body ? JSON.parse(opt.body) : {};
    const path = u.split('?')[0], q = new URLSearchParams(u.split('?')[1] || '');
    await new Promise(r => setTimeout(r, 80));
    let res = [404, { error: 'Unbekannter Pfad (Mock): ' + path }], m;
    if (path === '/api/session') res = [200, session];
    else if (path === '/api/live') res = [200, live()];
    else if (path === '/api/reports') res = [200, reportList()];
    else if ((m = path.match(/^\/api\/reports\/(pc-check_[\d_-]+)\.json$/))) { const r = reps.find(x => x.name === m[1]); res = r ? [200, r.json] : [404, { error: 'Bericht nicht gefunden' }]; }
    else if (path === '/api/actions') res = [200, actions];
    else if (path === '/api/actions/refresh') res = [200, { jobId: newJob('lesen', ['Lese Zustände …'], () => ({})) }];
    else if (path === '/api/actions/run') res = runActions(body.ids || [], body.variante);
    else if (path === '/api/journal') res = [200, journal];
    else if ((m = path.match(/^\/api\/journal\/([^/]+)\/undo$/))) res = undo(decodeURIComponent(m[1]), !!body.force);
    else if (path === '/api/restorepoints') res = [200, [{ seq: 57, zeit: '2026-10-25T12:02:11', beschreibung: 'pc-check: Demo-Änderung', typ: 'MODIFY_SETTINGS' }, { seq: 56, zeit: '2026-10-24T19:02:00', beschreibung: 'pc-check: Energiesparfunktionen Netzwerkkarte aus', typ: 'MODIFY_SETTINGS' }, { seq: 55, zeit: '2026-10-24T11:40:00', beschreibung: 'Windows Update', typ: 'APPLICATION_INSTALL' }]];
    else if (path === '/api/scan') res = scan(body);
    else if ((m = path.match(/^\/api\/jobs\/([^/]+)$/))) res = jobState(m[1], parseInt(q.get('from') || '0', 10));
    else if (path === '/api/checklist') { if (method === 'POST') checklist = body; res = [200, checklist]; }
    else if (path === '/api/help') res = [200, help];
    else if (path === '/api/heartbeat' || path === '/api/shutdown') res = [200, {}];
    return new Response(JSON.stringify(res[1]), { status: res[0], headers: { 'Content-Type': 'application/json' } });
  };
  // Original-HTML-Bericht: im Mock ein kleines data:-Dokument statt /report/…
  window.PCCHECK_REPORT_SRC = name => 'data:text/html;charset=utf-8,' + encodeURIComponent(`<body style="font:14px sans-serif"><h2>Demo: Original-HTML ${name}</h2><p>Im echten Betrieb liefert der Server /report/&lt;name&gt;.html.</p></body>`);
})();
