/* pc-check GUI (v2.0): Oberfläche in Vanilla JS.
   Kein Inline-Script, kein eval. Alle Texte aus Berichtsdaten werden per textContent eingesetzt (siehe h()).
   Texte der Oberfläche (2.6, #66): lang\<sprache>\gui.psd1, geladen von GET /api/texte; die Funktion t liefert den Text zum Schlüssel. */
'use strict';
(() => {

// ---------------------------------------------------------------- Texte und Sprache (2.6, #66)
let TX = {}, LANG = 'de';
// Nur für Meldungen, bevor die Texte geladen sind (Startcode abgelehnt, kein Token); alles andere kommt aus gui.psd1
const PRE = {
  de: { 'api.startcodeAbgelehnt': 'Der Startcode wurde abgelehnt. Bitte die GUI neu starten.', 'api.keinToken': 'Kein Zugriffstoken. Bitte die GUI über pc-check-gui starten.', 'api.sitzungAbgelaufen': 'Sitzung abgelaufen, GUI neu starten.', 'api.keineVerbindung': 'Keine Verbindung zur GUI. Läuft sie noch?' },
  en: { 'api.startcodeAbgelehnt': 'The start code was rejected. Please restart the GUI.', 'api.keinToken': 'No access token. Please start the GUI via pc-check-gui.', 'api.sitzungAbgelaufen': 'Session expired, restart the GUI.', 'api.keineVerbindung': 'No connection to the GUI. Is it still running?' },
};
const fmtText = (s, w) => String(s).replace(/\{\{|\}\}|\{(\d+)\}/g, (m, i) => m === '{{' ? '{' : (m === '}}' ? '}' : (w[+i] != null ? String(w[+i]) : m)));
/** Text zum Schlüssel (ohne Präfix gui.); Platzhalter {0}, {1} …; {{ und }} sind wörtliche Klammern. Unbekannt = der Schlüssel selbst. */
function t(key, ...w) {
  let s = TX[key];
  if (s == null) { const pre = PRE[(typeof navigator !== 'undefined' && /^en/i.test(navigator.language || '')) ? 'en' : 'de']; s = pre[key]; }
  return s == null ? key : fmtText(s, w);
}
/** Text zu einem zur Laufzeit gebildeten Schlüssel (z. B. 'stufe.' + wert); ohne Text der Rückfall. */
const tk = (key, fallback) => TX[key] != null ? String(TX[key]) : fallback;
const lc = () => LANG === 'en' ? 'en' : 'de';             // für localeCompare
const locTag = () => LANG === 'en' ? 'en-GB' : 'de-DE';   // für toLocale…String
const cmpTxt = (a, b) => String(a).localeCompare(String(b), lc());

// ---------------------------------------------------------------- Konstanten
const STATUS = ['CRIT', 'WARN', 'TIPP', 'ACK', 'INFO', 'OK', 'SKIP'];
let STATUS_NAME = {};   // Anzeigenamen der Status, gefüllt von buildTexts()
const STATUS_COLOR = { CRIT: 'var(--red)', WARN: 'var(--orange)', TIPP: 'var(--magenta)', ACK: 'var(--violet)', INFO: 'var(--blue)', OK: 'var(--green)', SKIP: 'var(--grey)' };
const RANK = { CRIT: 0, WARN: 1, TIPP: 2, INFO: 3, ACK: 4, SKIP: 5, OK: 6 };
const LEVEL = { gering: 1, mittel: 2, hoch: 3 };
const GAMING_CHECKS = ['Bildschirme und Bildwiederholrate', 'Grafikkarte und Treiber', 'Resizable BAR und PCIe-Anbindung', 'NVIDIA-Treibereinstellungen', 'Arbeitsspeicher', 'Prozessor-Energieeinstellungen', 'Energieplan',
  'Spielebibliotheken', 'Spielmodus', 'Hardwarebeschleunigte GPU-Planung (HAGS)', 'Hintergrundaufzeichnung (Game DVR)', 'Optimierungen für Spiele im Fenstermodus',
  'Overlays und Hintergrund-Tools', 'Mausbeschleunigung', 'Netzwerkverbindung', 'Netzwerkkarte: Energiesparfunktionen', 'Virtualisierung und Spieleleistung'];
const REPORT_RE = /^pc-check_\d{4}-\d{2}-\d{2}_\d{4}$/;
// Menütexte zentral (2.5, #65); ab 2.6 aus den Sprachdateien, gefüllt von buildTexts()
let MENU_TEXTE = { gruppen: {}, punkte: {}, unter: {}, filter: {}, werkzeuge: [], aria: {} };
// kinder: 'kategorien' (aus dem Bericht), 'filter' (Status-Filter), 'werkzeuge' (Karten und Einzelwerkzeuge)
let NAV = [];
const NAV_KEY = 'morpheusNavAuf';
const NAV_STANDARD_AUF = { 'werkzeuge/wartung': true };   // Einzelwerkzeuge sofort sichtbar, sobald „Werkzeuge“ offen ist
const CAT_VIEWS = ['sicherheit', 'leistung', 'gaming', 'stabilitaet', 'alle'];
const LIVE_MS = 5000;
const SB_KEY = 'pcCheckStatusbar';
// Ansichtsmodus (2.7, #103): „einfach“ (Standard beim ersten Start) zeigt Zusammenfassung und offene Befunde, „experte“ alles.
// Nur Anzeige: Bestätigungen, Wiederherstellungspunkt, Warnbanner, Akzeptieren und Rückgängig bleiben in beiden Modi.
const MODUS_KEY = 'morpheusModus';
const NUR_EXPERTE = ['alle', 'checkliste', 'berichte', 'rohdaten'];   // Menüpunkte, die der einfache Modus nicht zeigt (per Link weiter erreichbar)
const NUR_EXPERTE_ZU = ['checkliste', 'berichte', 'rohdaten'];          // beim Wechsel nach „einfach“ von hier zur Übersicht

// ---------------------------------------------------------------- Zustand
const S = {
  token: null, session: null, reports: [], cur: null, report: null, findings: [], cache: {},
  actions: [], help: null, checklist: {}, journal: null, view: 'uebersicht', rv: 0,
  ui: { f: {}, reveal: null, focusSpOrdner: false }, sel: new Set(), variant: {}, cmp: [], origName: null, scan: null, multiBtns: [],
  points: null, live: { state: 'idle', data: null }, sbOn: true, einfach: true, rest: {},
  speicher: null, spSrc: '', spApi: null, spPop: null, spJob: null, spOrdner: null, spoMsg: null, spoJob: null,   // Speicherverbraucher (Abschnitt 14.7)
};

// ---------------------------------------------------------------- DOM-Helfer
function add(e, kids) {
  for (const k of kids.flat(Infinity)) {
    if (k == null || k === false) continue;
    e.append(k.nodeType ? k : document.createTextNode(String(k)));
  }
}
/** Element bauen. Attribute: class, text, on<Ereignis> (Funktion), checked/value/selected/disabled (Eigenschaften). */
function h(tag, attrs, ...kids) {
  const e = document.createElement(tag);
  if (tag === 'button' && attrs && !attrs['data-mark'] && !attrs['data-filter'] && !/\b(btn|info|kpi|pill|srow|tile)\b/.test(attrs.class || '')) {
    attrs = { ...attrs, class: ('btn ' + (attrs.class === 'copy' ? 'sm ghost' : (attrs.class || ''))).trim() };   // einheitlicher Button-Stil
  }
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === 'class') e.className = v;
      else if (k === 'text') e.textContent = v;
      else if (k.startsWith('on') && typeof v === 'function') e.addEventListener(k.slice(2), v);
      else if (k === 'checked' || k === 'value' || k === 'selected') e[k] = v;
      else if (v === true) e.setAttribute(k, '');
      else e.setAttribute(k, v);
    }
  }
  add(e, kids);
  return e;
}
/** Text mit klickbaren Windows-Einstellungs-Verweisen (wie im HTML-Bericht): nur das feste Muster
 *  ms-settings:<a-z-> wird zum Link, alles andere bleibt Textknoten (kein innerHTML, keine anderen Schemata). */
function settingsLinks(text) {
  const s = String(text == null ? '' : text), out = [], rx = /ms-settings:[a-z-]+/g;
  let last = 0, m;
  while ((m = rx.exec(s))) {
    if (m.index > last) out.push(s.slice(last, m.index));
    out.push(h('a', { href: m[0], text: m[0] }));
    last = rx.lastIndex;
  }
  if (last < s.length) out.push(s.slice(last));
  return out;
}
const svgNS = 'http://www.w3.org/2000/svg';
function svg(tag, attrs) {
  const e = document.createElementNS(svgNS, tag);
  for (const [k, v] of Object.entries(attrs || {})) e.setAttribute(k, v);
  return e;
}
function icon(id) { const s = svg('svg', { class: 'i', 'aria-hidden': 'true' }); s.append(svg('use', { href: '#i-' + id })); return s; }
const $ = (s, r = document) => r.querySelector(s);
const pad = n => String(n).padStart(2, '0');
function fmtDate(s) {
  const d = new Date(s);
  if (isNaN(d)) return s || '';
  if (LANG === 'en') return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  return `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
function fmtWhen(s) {   // „heute 14:25“, „gestern 11:40“, sonst „24.10. 19:02“
  const d = new Date(s); if (isNaN(d)) return s || '';
  const tm = `${pad(d.getHours())}:${pad(d.getMinutes())}`, now = new Date();
  const day = x => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((day(now) - day(d)) / 86400000);
  if (diff === 0) return t('zeit.heute', tm);
  if (diff === 1) return t('zeit.gestern', tm);
  if (LANG === 'en') return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${tm}`;
  return `${pad(d.getDate())}.${pad(d.getMonth() + 1)}. ${tm}`;
}
function fmtAgo(s) {
  const d = new Date(s); if (isNaN(d)) return '–';
  const m = Math.round((Date.now() - d.getTime()) / 60000);
  if (m < 2) return t('zeit.geradeEben');
  if (m < 60) return t('zeit.vorMin', m);
  if (m < 60 * 36) return t('zeit.vorStd', Math.round(m / 60));
  const n = Math.round(m / 1440);
  return n === 1 ? t('zeit.vorTag') : t('zeit.vorTagen', n);
}
const dec = (v, d = 0) => (v == null || isNaN(v)) ? '–' : (LANG === 'en' ? Number(v).toFixed(d) : Number(v).toFixed(d).replace('.', ','));
function fmtShort(s) {
  const d = new Date(s); if (isNaN(d)) return '';
  return LANG === 'en' ? `${String(d.getFullYear()).slice(2)}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` : `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${String(d.getFullYear()).slice(2)}`;
}
/** Technische Werte aus Windows (Defender-Modi u. a.) in Klartext (2.7, #95); Unbekanntes bleibt, wie es ist. */
const PLAIN = { enabled: 'wert.an', disabled: 'wert.aus', auditmode: 'wert.audit', notconfigured: 'wert.nichtKonfiguriert', warn: 'wert.warnen', true: 'wert.an', false: 'wert.aus' };
const plainVal = v => { const k = PLAIN[String(v).trim().toLowerCase()]; return k ? t(k) : String(v); };
/** Zustand im Journal: {aktiv, wert, zustand} als „an“/„aus“ bzw. Wert in Worten, nie als JSON (2.7, #95). */
function fmtState(v) {
  if (v == null) return t('zustand.nichtGesetzt');
  if (typeof v === 'object' && !Array.isArray(v) && ('wert' in v || 'aktiv' in v)) {
    if (v.wert != null && v.wert !== '') return plainVal(v.wert);
    if (v.zustand == null) return t('zustand.nichtGesetzt');
    if (v.aktiv === true || v.aktiv === false) return t(v.aktiv ? 'wert.an' : 'wert.aus');
  }
  if (typeof v === 'object') { let s = JSON.stringify(v); if (s.length > 120) s = s.slice(0, 117) + '…'; return s; }
  return plainVal(v);
}
function toast(msg) {
  const el = h('div', { class: 'toast', role: 'status', text: msg });
  document.body.append(el);
  setTimeout(() => el.remove(), 3500);
}
async function copyText(text, btn, okToast) {
  const label = btn ? btn.textContent : '';
  const done = ok => {
    if (btn) { btn.textContent = ok ? t('kopieren.ok') : t('kopieren.nein'); setTimeout(() => { btn.textContent = label; }, 2000); }
    if (!btn || (ok && okToast)) toast(ok ? (okToast || t('kopieren.toastOk')) : t('kopieren.toastNein'));
  };
  try { await navigator.clipboard.writeText(text); done(true); return; } catch { /* Rückfall */ }
  const ta = h('textarea', { style: 'position:fixed;left:-9999px', 'aria-hidden': 'true' });
  ta.value = text; document.body.append(ta); ta.select();
  let ok = false; try { ok = document.execCommand('copy'); } catch { ok = false; }
  ta.remove(); done(ok);
}
/** Stufe (gering/mittel/hoch) für die Anzeige; die Kennung selbst bleibt in Klassen und Vergleichen. */
const stufeName = v => tk('stufe.' + v, String(v));
function levelsNode(n, a, r) {
  const parts = [[t('stufe.nutzen'), n, 'n'], [t('stufe.aufwand'), a, 'a'], [t('stufe.risiko'), r, 'r']].filter(x => x[1]);
  if (!parts.length) return null;
  return h('span', { class: 'lv' }, parts.map(x => h('span', { class: `${x[2]}-${x[1]}`, text: `${x[0]} ${stufeName(x[1])}` })));
}
/** Befehl mit einfacher Einfärbung (Cmdlet = blau, Parameter = gelb); nur DOM-Knoten. */
function fillCmd(pre, text) {
  pre.replaceChildren();
  String(text || '').split(/(\s+)/).forEach(tok => {
    if (!tok || /^\s+$/.test(tok)) { if (tok) pre.append(document.createTextNode(tok)); return; }
    if (/^-[A-Za-z]\w*$/.test(tok)) pre.append(h('span', { class: 'p', text: tok }));
    else if (/^(Get|Set|New|Add|Remove|Enable|Disable|Start|Stop|Invoke|Test|Clear)-[A-Za-z]+$/.test(tok)) pre.append(h('span', { class: 'k', text: tok }));
    else pre.append(document.createTextNode(tok));
  });
}
function cmdBlock(text, withCopy = true, label = null) {
  const btn = withCopy ? h('button', { type: 'button', class: 'btn sm ghost', text: t('kopieren.knopf'), onclick: e => copyText(text, e.currentTarget) }) : null;
  const pre = h('pre'); fillCmd(pre, text);
  return h('div', { class: 'code' }, h('div', { class: 'ch' }, h('span', { text: label || t('cmd.psAdmin') }), btn), pre);
}
const norm = s => (s || '').normalize('NFC');
// Anzeigenamen (2.6): Der Bericht trägt neben den festen Kennungen den Namen in der Sprache des Scans; Logik bleibt bei den Kennungen
const chkName = f => f.CheckName || f.Check;
const catName = f => f.CategoryName || f.Category;
const areaName = f => f.AreaName || f.Area;
const tblName = id => (S.report && S.report.DataNamen && S.report.DataNamen.Tabellen && S.report.DataNamen.Tabellen[id]) || id;
const colName = id => (S.report && S.report.DataNamen && S.report.DataNamen.Spalten && S.report.DataNamen.Spalten[id]) || id;
/** Anzeigename einer Katalog-Variante: variantenNamen[i] zu varianten[i], gesendet wird weiter die Kennung. */
function varName(a, v) {
  const i = (a.varianten || []).indexOf(v);
  return (i >= 0 && a.variantenNamen && a.variantenNamen[i]) || v;
}

// ---------------------------------------------------------------- API
class ApiError extends Error { constructor(msg, status) { super(msg); this.status = status; } }
function fatal(msg) {
  const f = $('#fatal');
  f.replaceChildren(h('div', { class: 'card' }, h('h2', { text: msg })));
  f.classList.remove('hide');
}
async function api(path, o = {}) {
  const method = o.method || 'GET';
  const opt = { method, headers: { 'X-PcCheck-Token': S.token || '' } };
  if (method === 'POST') { opt.headers['Content-Type'] = 'application/json'; opt.body = JSON.stringify(o.body == null ? {} : o.body); }
  let r;
  try { r = await fetch(path, opt); } catch { throw new ApiError(t('api.keineVerbindung'), 0); }
  if (r.status === 401) { fatal(t('api.sitzungAbgelaufen')); throw new ApiError(t('api.sitzungAbgelaufen'), 401); }
  const txt = await r.text();
  let data = null;
  try { data = txt ? JSON.parse(txt) : null; } catch { data = null; }
  if (!r.ok) throw new ApiError((data && data.error) || t('api.fehler', r.status), r.status);
  return data;
}
/**
 * Edge bekommt nur einen Einmal-Code (#b=…), weil seine Befehlszeile für alle Programme des Benutzers lesbar ist.
 * Der Code wird sofort gegen das eigentliche Token getauscht; danach ist er wertlos.
 */
async function initToken() {
  const m = location.hash.match(/^#b=([\w-]+)/);
  if (m) {
    history.replaceState(null, '', location.pathname + location.search + '#/uebersicht');
    const r = await fetch('/api/session/claim', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code: m[1] }) });
    let data = null; try { data = await r.json(); } catch { /* leer */ }
    if (!r.ok || !data || !data.token) throw new Error((data && data.error) || t('api.startcodeAbgelehnt'));
    S.token = data.token;
    try { sessionStorage.setItem('pcCheckToken', S.token); } catch { /* ohne Speicher weiter */ }
  } else {
    try { S.token = sessionStorage.getItem('pcCheckToken'); } catch { S.token = null; }
  }
}
let hbFail = 0;
function startHeartbeat() {
  // sofort=true (Fenster wieder sichtbar/fokussiert): Ein Verbindungsfehler heißt, der Server ist beendet
  const beat = (sofort) => api('/api/heartbeat', { method: 'POST' }).then(() => { hbFail = 0; }, e => {
    if (e.status === 401) return;
    if (sofort === true && e.status === 0) { fatal(t('api.laeuftNichtMehr')); return; }
    if (++hbFail >= 3) fatal(t('api.verbindungVerloren'));
  });
  setInterval(() => beat(false), 10000);
  // Edge drosselt Hintergrundfenster: beim Zurückkehren sofort ein Lebenszeichen senden
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') beat(true); });
  window.addEventListener('focus', () => beat(true));
}
/** Job abfragen, bis er fertig ist. onLines bekommt neue Logzeilen. */
async function followJob(id, onLines) {
  let from = 0, errs = 0;
  for (;;) {
    let j;
    try { j = await api(`/api/jobs/${encodeURIComponent(id)}?from=${from}`); errs = 0; }
    catch (e) { if (e.status === 401 || ++errs > 5) throw e; await sleep(1000); continue; }
    if (j.log && j.log.length) { onLines(j.log); }
    if (typeof j.next === 'number') from = j.next; else from += (j.log || []).length;
    if (j.status !== 'running') return j;
    await sleep(1000);
  }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---------------------------------------------------------------- Daten laden
const normName = n => String(n || '').replace(/\.(json|html|md)$/i, '');
async function loadReportJson(name) {
  if (!REPORT_RE.test(name)) throw new ApiError(t('api.berichtsnameUngueltig'), 400);
  if (!S.cache[name]) S.cache[name] = await api(`/api/reports/${name}.json`);
  return S.cache[name];
}
async function showReport(name) {
  const r = await loadReportJson(name);
  S.cur = name; S.report = r; S.findings = (r.Findings || []).map(f => ({ ...f, Category: norm(f.Category), Check: norm(f.Check) }));
  pickSpeicher();
}
async function loadReports() {
  const list = await api('/api/reports');
  S.reports = (list || []).map(r => ({ ...r, name: normName(r.name) })).filter(r => REPORT_RE.test(r.name));
}
async function loadActions() { try { S.actions = (await api('/api/actions')) || []; } catch (e) { if (e.status === 401) throw e; S.actions = []; } }
async function loadHelp() { try { S.help = await api('/api/help'); } catch (e) { if (e.status === 401) throw e; S.help = null; } }
/**
 * Zustände der Aktionen am System neu lesen lassen (Job „refresh“), danach Liste und Ansicht aktualisieren.
 * Ohne diesen Anstoß kennt der Server keine Zustände: Alle Karten zeigten „Zustand unbekannt“ und „Ausführen“.
 * Läuft schon ein Lesen, liefert der Server dessen Job; parallele Aufrufe hier teilen sich ein Versprechen.
 */
let statesRun = null;
function refreshActionStates() {
  if (statesRun) return statesRun;
  statesRun = (async () => {
    try {
      const r = await api('/api/actions/refresh', { method: 'POST' });
      if (r && r.jobId) await followJob(r.jobId, () => {});
      await loadActions();
      // „Werkzeuge“ zeigt keine Anpassungen; neu zeichnen würde die Karten neu laden und die Position verschieben (2.5, #65)
      if (S.view === 'werkzeuge') renderNav(); else refreshView();
    } catch (e) { if (e.status === 401) throw e; /* ohne Zustände weiter (Mock, Nur-Lesen ohne Safety) */ }
    finally { statesRun = null; }
  })();
  return statesRun;
}
async function loadSession() { S.session = await api('/api/session'); }
async function loadAll() {
  await Promise.all([loadSession(), loadReports()]);
  await Promise.all([
    loadActions(),
    loadHelp(),
    api('/api/checklist').then(x => { S.checklist = x || {}; }, () => { S.checklist = {}; }),
    loadSpeicher(),
  ]);
  if (S.reports.length) await showReport(S.reports[0].name);
}

// ---------------------------------------------------------------- Befunde
function viewOf(f) {
  const c = norm(f.Category);
  if (f.Area === 'Sicherheit') return 'sicherheit';
  if (c === 'Gaming & Grafik') return 'gaming';
  if (c === 'Stabilität') return 'stabilitaet';
  return 'leistung';
}
const isProblem = f => f.Status === 'CRIT' || f.Status === 'WARN';
const isOpen = f => f.Status === 'CRIT' || f.Status === 'WARN' || f.Status === 'TIPP';
const findingByCheck = c => S.findings.find(f => f.Check === c);
function tipScore(f) { return f.Benefit ? 2 * (LEVEL[f.Benefit] || 0) - (LEVEL[f.Effort] || 0) - ((LEVEL[f.Risk] || 0) - 1) : -99; }
function counts(list) { const c = {}; STATUS.forEach(s => { c[s] = 0; }); list.forEach(f => { if (c[f.Status] != null) c[f.Status]++; }); return c; }
function actionsFor(f) { return S.actions.filter(a => norm(a.pruefung) === f.Check); }
function actionView(a) { return a.kategorie === 'Sicherheit' ? 'sicherheit' : a.kategorie === 'Gaming' ? 'gaming' : a.kategorie === 'Stabilität' ? 'stabilitaet' : 'leistung'; }
const safety = () => (S.session && S.session.safety) || {};
// Seit dem letzten Windows-Start ausgeführt und erst nach einem Neustart wirksam (2.7, #95; Liste vom Server aus dem Journal)
const restartPending = a => !!(a && a.neustart && a.zustand && a.zustand.aktiv === true && [].concat(safety().seitStart || []).includes(a.id));
// Nur-Lesen-Modus: der Codeordner ist nicht gesichert (oder keine Adminrechte); der Server antwortet bei Änderungen mit 403
const readOnly = () => !!(S.session && S.session.readOnly);
const locked = () => safety().schutzAn === false || readOnly();
const lockTitle = () => readOnly() ? t('sperre.nurLesen') : t('sperre.schutzAus');
function uiF(view) { return S.ui.f[view] || (S.ui.f[view] = { mode: 'all', term: '' }); }

// ---------------------------------------------------------------- Dialog
const Dlg = { prev: null, prevKey: null, running: false, onEsc: null, onClose: null };
/**
 * Fokus über ein Neuzeichnen retten (2.7, #95): Nach „Fertig“ zeichnet die Ansicht neu und der Auslöser ist weg;
 * dann gleiche Karte (data-id) und dort gleiches Bedienelement, sonst die Karte selbst, sonst der Inhaltsbereich.
 */
function focusKey(el) {
  const vw = $('#view');
  if (!el || el === document.body || !vw || !vw.contains(el) || el === vw) return null;
  const card = el.closest('[data-id],[data-check]');
  return { id: card ? (card.dataset.id || 'c:' + card.dataset.check) : null, tag: el.tagName, label: el.getAttribute('aria-label') || (el.textContent || '').trim().slice(0, 60) };
}
function focusRestore(k) {
  const vw = $('#view');
  if (!k || !vw) return false;
  const root = k.id ? [...vw.querySelectorAll('[data-id],[data-check]')].find(x => (x.dataset.id || 'c:' + x.dataset.check) === k.id) : null;
  const scope = root || vw;
  // Sichtbarkeit über checkVisibility: In geschlossenem <details> ist offsetParent in Chromium nicht null, focus() scheitert dann still
  const vis = x => (x.checkVisibility ? x.checkVisibility() : x.offsetParent !== null);
  const cand = [...scope.querySelectorAll(k.tag)].filter(x => !x.disabled && (x.getAttribute('aria-label') || (x.textContent || '').trim().slice(0, 60)) === k.label);
  const same = cand.find(vis);
  for (const target of [same, root].filter(Boolean)) {
    if (target === root && !root.hasAttribute('tabindex')) root.setAttribute('tabindex', '-1');
    target.focus({ preventScroll: true });
    if (document.activeElement === target) return true;
  }
  return false;
}
function dlgOpen(title, body, buttons, opts = {}) {
  Dlg.running = !!opts.lock; Dlg.onEsc = opts.onEsc || null; Dlg.onClose = opts.onClose || null;
  if (!$('#modal').classList.contains('on')) { Dlg.prev = document.activeElement; Dlg.prevKey = focusKey(Dlg.prev); }
  $('#dlg-title').textContent = title;
  $('#dlg-body').replaceChildren(...[].concat(body).filter(Boolean));
  const bx = $('#dlg-buttons'); bx.replaceChildren();
  buttons.forEach(b => bx.append(h('button', { type: 'button', class: b.primary ? 'primary' : (b.danger ? 'danger' : ''), disabled: !!b.disabled, onclick: b.onClick, text: b.label })));
  const m = $('#modal'); m.classList.add('on'); m.setAttribute('aria-hidden', 'false');
  // Bestätigungen (opts.focus = 'cancel') starten auf „Abbrechen“, damit Enter nichts ändert (2.7, #92)
  const first = (opts.focus === 'cancel' && bx.querySelector('button:not(.primary):not(.danger):not(:disabled)'))
    || bx.querySelector('button.primary:not(:disabled)') || bx.querySelector('button:not(:disabled)');
  // Ohne bedienbaren Knopf (Job läuft) bleibt der Fokus im Dialog, auf dem Titel, statt auf body zu fallen (2.7, #95)
  if (first) first.focus(); else $('#dlg-title').focus();
}
function dlgClose() {
  const m = $('#modal'); m.classList.remove('on'); m.setAttribute('aria-hidden', 'true'); Dlg.running = false;
  const cb = Dlg.onClose; Dlg.onClose = null; Dlg.onEsc = null; if (cb) cb();
  if (Dlg.prev && Dlg.prev.isConnected && Dlg.prev !== document.body) Dlg.prev.focus();
  else if (!focusRestore(Dlg.prevKey)) { const vw = $('#view'); if (vw) vw.focus({ preventScroll: true }); }
}
document.addEventListener('keydown', e => {
  const m = $('#modal');
  if (!m.classList.contains('on')) return;
  if (e.key === 'Escape' && Dlg.onEsc) { e.preventDefault(); Dlg.onEsc(); }
  else if (e.key === 'Escape' && !Dlg.running) { e.preventDefault(); dlgClose(); }
  if (e.key === 'Tab') {
    const f = [...$('#dlg').querySelectorAll('button:not(:disabled),a[href],input,select,textarea,summary')].filter(x => x.offsetParent !== null);
    if (!f.length) return;
    const first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    else if (!$('#dlg').contains(document.activeElement)) { e.preventDefault(); first.focus(); }
  }
});

/** Text mit eingebetteten Elementen: tn(Schlüssel, Knoten …) setzt die Knoten an die Stelle {0}, {1} … (nur DOM-Knoten, kein HTML). */
function tn(key, ...nodes) {
  const s = t(key, ...nodes.map((_, i) => `\u0001${i}\u0002`));
  return s.split(/\u0001(\d+)\u0002/).map((p, i) => i % 2 ? nodes[+p] : p);
}

// ---------------------------------------------------------------- Aktionen ausführen
let RUN_STEPS = [];   // Schritte der Anzeige: [Name, Muster für die Logzeile]; Muster stehen in gui.psd1, damit sie zur Sprache der Logzeilen passen
let RESULT_TEXT = {};
const FORCE_RE = /zustand.*ge[äa]ndert|ge[äa]ndert.*zustand|state.*changed|changed.*state/i;

/** Gemeinsame Anzeige eines laufenden Jobs im Dialog: Schritte, Live-Log, Ergebnis. */
function jobView(steps, confirm = false) {
  const ul = h('ul', { class: 'steps', 'aria-label': t('run.ablauf') }, steps.map(s => h('li', null, h('span', { class: 's' }), s[0])));
  // Das Protokoll ist zum Nachlesen; angesagt wird nur der aktuelle Schritt (2.7, #95), sonst liest ein Screenreader jede Logzeile vor
  const log = h('pre', { class: 'log', 'aria-live': 'off', tabindex: '0', 'aria-label': t('run.protokoll'), text: '' });
  const live = h('p', { class: 'vh', role: 'status', 'aria-live': 'polite', 'aria-atomic': 'true' });
  // Hinweis auf den Windows-Dialog steht über der Liste und verschwindet, sobald der Server antwortet (2.7, #92)
  let hint = confirm ? h('p', { class: 'jobhint', role: 'status', text: t('win.bestaetigen') }) : null;
  let cur = -1;
  // Nur bei echtem Wechsel neu setzen, sonst startet die Haken-Animation bei jeder Logzeile neu
  const setLi = (li, cls) => { if (li.className === cls) return; li.className = cls; li.firstChild.replaceChildren(cls === 'done' ? icon('tick') : (cls === 'fail' ? icon('x') : '')); };
  const mark = (idx, cls) => { [...ul.children].forEach((li, i) => setLi(li, i < idx ? 'done' : (i === idx ? cls : ''))); };
  return {
    get nodes() { return [hint, ul, log, live].filter(Boolean); }, ul, log,
    lines(arr) {
      if (arr.length && hint) { hint.remove(); hint = null; }
      for (const l of arr) {
        log.append(document.createTextNode(l + '\n'));
        const i = steps.findIndex((s, k) => k >= cur && s[1].test(l));
        if (i >= 0 && i > cur) { cur = i; mark(i, 'run'); live.textContent = t('run.schrittLive', i + 1, steps.length, steps[i][0]); }
        else if (i >= 0 && i >= cur) { cur = i; mark(i, 'run'); }
      }
      log.scrollTop = log.scrollHeight;
    },
    finish(ok) {
      if (hint) { hint.remove(); hint = null; }
      if (ok) [...ul.children].forEach(li => setLi(li, 'done')); else mark(Math.max(cur, 0), 'fail');
      live.textContent = ok ? t('run.liveFertig') : t('run.liveFehler');
    },
  };
}
function resultList(items, undo = false) {
  const arr = [].concat(items || []).filter(Boolean);
  if (!arr.length) return null;
  return h('ul', { class: 'result' }, arr.map(r => {
    const a = S.actions.find(x => x.id === r.id);
    const okc = r.status === 'erledigt' ? 'ok' : (String(r.status).startsWith('fehl') ? 'rem' : 'warn');
    // Beim Rückgängig heißt „erledigt“: der frühere Zustand ist wieder da (sonst klänge es nach erneutem Einschalten)
    const st = undo && r.status === 'erledigt' ? t('run.res.zurueckgenommen') : (RESULT_TEXT[r.status] || r.status || '');
    return h('li', null,
      h('b', { text: a ? a.titel : (r.id || t('run.aktion')) }), ' ',
      h('span', { class: okc, text: st }),
      r.meldung ? h('div', { class: 'note' }, settingsLinks(r.meldung)) : null,
      r.status === 'erledigt' && r.neustart ? h('div', { class: 'warn', text: t('run.neustartNoetig') }) : null);
  }));
}
async function afterChange() {
  await Promise.all([loadSession().catch(() => {}), loadActions()]);
  S.sel.clear(); refreshView(); loadExtra();
  refreshActionStates();   // Zustände nach der Änderung neu lesen
}
function runCmdText(a, variante) { return (a.befehle && a.befehle.ausfuehren || '').replace(/<variante>/g, variante || '<variante>'); }

/**
 * Bestätigung vor einer Anpassung (2.7, #92): erst die Bedeutung (was ändert sich, Risiko, Neustart),
 * dann das Sicherheitsnetz in voller Lesbarkeit, der Befehl nur aufklappbar. Startfokus auf „Abbrechen“.
 */
function openRunDialog(actions, variante) {
  if (!actions.length) return;
  const multi = actions.length > 1;
  const title = multi ? t('run.titelMehrere', actions.length) : actions[0].titel;
  const body = [];
  actions.forEach(a => {
    const v = a.varianten && a.varianten.length ? (variante || S.variant[a.id] || a.varianten[0]) : null;
    const lv = levelsNode(null, a.aufwand, a.risiko);
    body.push(h('div', { class: 'run-item' },
      multi ? h('b', { class: 'run-t', text: a.titel }) : null,
      a.erklaerung ? h('p', { class: 'run-was', text: a.erklaerung }) : null,
      lv || a.neustart ? h('div', { class: 'lv block' }, lv ? [...lv.children] : null, a.neustart ? h('span', { class: 'restart', text: t('karte.neustartNoetig') }) : null) : null,
      v ? h('p', { class: 'run-var', text: t('run.variante', varName(a, v)) }) : null,
      h('details', { class: 'cmd' }, h('summary', { text: t('run.befehlZeigen') }), cmdBlock(runCmdText(a, v), false))));
  });
  const noRp = actions.some(a => a.ohneWiederherstellungspunkt || a.id === 'system.wiederherstellung');
  body.push(h('div', { class: 'assure' + (noRp ? ' a-warn' : '') }, icon(noRp ? 'warn' : 'undo'),
    h('p', { text: noRp ? t('run.ohnePunktNote') : t('run.mitPunktNote') })));
  if (actions.some(a => a.neustart)) body.push(h('p', { class: 'run-hint', text: t('run.neustartHinweis') }));
  // 24-Stunden-Sperre: hier sagen, was sie für genau diesen Klick bedeutet, statt eines Banners (2.7, #92, #107).
  // Ruhig, solange sie nur theoretisch ist; getönt, wenn Morpheus heute schon einen Punkt angelegt hat.
  if (!noRp && safety().sperre24h) {
    const greift = sperreGreift();
    body.push(h('div', { class: 'run-hint' + (greift ? ' warn' : '') }, h('p', { text: greift ? t('run.sperre24Heute') : t('run.sperre24') }), sperreMehr()));
  }
  dlgOpen(title, body, [{ label: t('btn.abbrechen'), onClick: dlgClose }, { label: multi ? t('run.knopfMehrere', actions.length) : t('btn.ausfuehren'), primary: true, onClick: () => startRun(actions, title, variante) }], { focus: 'cancel' });
}
async function startRun(actions, title, variante) {
  const jv = jobView(RUN_STEPS, true);
  const single = actions.length === 1 && actions[0].varianten && actions[0].varianten.length;
  const v = single ? (variante || S.variant[actions[0].id] || actions[0].varianten[0]) : null;
  dlgOpen(title, jv.nodes, [{ label: t('btn.laeuft'), disabled: true }], { lock: true });
  let job = null, err = null;
  try {
    const body = { ids: actions.map(a => a.id) };
    if (v) body.variante = v;
    const r = await api('/api/actions/run', { method: 'POST', body });
    job = await followJob(r.jobId, jv.lines);
  } catch (e) { err = e; }
  const msg = err ? err.message : (job && job.status === 'failed' && job.ergebnis && job.ergebnis.error) || '';
  finishJob(title, jv, job, err, t('btn.fertig'), false, sperreAusweg(msg));
}
/** Ausweg, wenn Windows heute keinen Wiederherstellungspunkt mehr anlegt (#95, für Ausführen seit #107); Befehl nur aufklappbar. */
function sperreAusweg(msg) {
  if (!/kein Wiederherstellungspunkt angelegt|No restore point could be created/i.test(msg || '')) return null;
  const mehr = sperreMehr();
  return [h('h3', { text: t('undo.auswegTitel') }), h('ul', { class: 'ausweg' },
    h('li', { text: t('undo.auswegMorgen') }),
    mehr ? h('li', null, t('undo.auswegSperre'), mehr) : null)];
}
function finishJob(title, jv, job, err, doneLabel, undo = false, extra = null) {
  const ok = !err && job && job.status === 'done';
  jv.finish(ok);
  const body = [...jv.nodes];
  const res = job && job.ergebnis;
  if (err) body.push(h('p', { class: 'rem', text: err.message }));
  else if (job && job.status === 'failed') body.push(h('p', { class: 'rem', text: (res && res.error) || t('run.fehlgeschlagen') }));
  const list = res && !res.error ? resultList(res, undo) : null;
  if (list) body.push(h('h3', { text: t('run.ergebnis') }), list);
  if (extra) body.push(...[].concat(extra).filter(Boolean));
  // Abschluss in Worten und der Weg zurück (2.7, #92); nur wenn mindestens eine Änderung wirklich erledigt ist
  const anyDone = [].concat(res || []).some(r => r && r.status === 'erledigt');
  if (ok && anyDone) body.push(h('p', { class: 'run-next' }, undo ? t('run.nachRueck') : t('run.nachAusfuehren'), ' ',
    h('a', { href: '#/aenderungen', text: t('run.zuAenderungen'), onclick: () => dlgClose() })));
  dlgOpen(title, body, [{ label: doneLabel, primary: true, onClick: dlgClose }]);
  Dlg.running = false;
  afterChange();
}

// ---------------------------------------------------------------- Rückgängig
function openUndoDialog(e) {
  const body = [
    h('p', { text: t('undo.text', e.titel || e.aktion, fmtState(e.nachher), fmtState(e.vorher)) }),
    h('div', { class: 'assure' }, icon('undo'), h('p', { text: t('undo.note') })),
    safety().sperre24h ? h('p', { class: 'run-hint', text: e.wiederherstellungspunkt && e.wiederherstellungspunkt.seq != null ? t('undo.sperre24Punkt', '#' + e.wiederherstellungspunkt.seq) : t('undo.sperre24') }) : null,
  ];
  dlgOpen(t('undo.titel'), body, [{ label: t('btn.abbrechen'), onClick: dlgClose }, { label: t('undo.knopf'), primary: true, onClick: () => startUndo(e, false) }], { focus: 'cancel' });
}
async function startUndo(e, force, vorRep) {
  const title = t('undo.titelRun', e.titel || e.aktion);
  const jv = jobView(RUN_STEPS, true);
  dlgOpen(title, jv.nodes, [{ label: t('btn.laeuft'), disabled: true }], { lock: true });
  let job = null, err = null;
  try {
    const r = await api(`/api/journal/${encodeURIComponent(e.id)}/undo`, { method: 'POST', body: Object.assign({}, force ? { force: true } : null, vorRep ? { vorReparatur: true } : null) });
    job = await followJob(r.jobId, jv.lines);
  } catch (x) { err = x; }
  const msg = err ? err.message : (job && job.status === 'failed' && job.ergebnis && job.ergebnis.error) || '';
  if (!vorRep && /vor der Reparatur des Datenordners|before (the )?repair(ing)? (of )?the data folder/i.test(msg)) {
    Dlg.running = false;
    dlgOpen(title, [h('p', { class: 'warn', text: t('undo.vorReparatur') })],
      [{ label: t('btn.abbrechen'), onClick: dlgClose }, { label: t('undo.jaTrotzdem'), danger: true, onClick: () => startUndo(e, force, true) }]);
    return;
  }
  if (!force && FORCE_RE.test(msg)) {
    Dlg.running = false;
    dlgOpen(title, [h('p', { class: 'warn', text: msg }), h('p', { text: t('undo.zustandGeaendert') })],
      [{ label: t('btn.abbrechen'), onClick: dlgClose }, { label: t('undo.trotzdem'), danger: true, onClick: () => startUndo(e, true, vorRep) }]);
    return;
  }
  // Kein Punkt möglich und der Punkt der Ausführung fehlt (2.7, #95): Ausweg nennen statt nur abzubrechen
  finishJob(title, jv, job, err, t('btn.fertig'), true, sperreAusweg(msg));
}

// ---------------------------------------------------------------- Bausteine
function infoTip(check, cat) {
  const hp = S.help; if (!hp) return null;
  const P = hp.Pruefungen || hp.pruefungen || {}, K = hp.Kategorien || hp.kategorien || {};
  const e = P[check];
  let tip = null;
  if (e) tip = h('span', { class: 'tip', role: 'tooltip' }, h('b', { text: t('tip.was') }), e.Was, h('br'), h('b', { text: t('tip.warum') }), e.Warum, h('br'), h('b', { text: t('tip.harmlos') }), e.Harmlos);
  else if (K[cat]) tip = h('span', { class: 'tip', role: 'tooltip', text: K[cat] });
  if (!tip) return null;
  return [h('button', { type: 'button', class: 'info', 'aria-label': t('tip.aria'), 'aria-expanded': 'false' }), tip];
}
function howTo(f) {
  const steps = f.Steps || [];
  if (!steps.length && !f.Command) return null;
  return h('details', { class: 'how' }, h('summary', { text: t('howto.summary') }),
    steps.length ? h('ol', null, steps.map(s => h('li', { text: s }))) : null,
    f.Command ? cmdBlock(f.Command) : null);
}
/** Aktionskarte; inFinding: im Befund, der schon „KI fragen“ hat (#107). Umgesetzte Anpassungen als eine ruhige Zeile. */
function actionCard(a, inFinding) {
  const z = a.zustand || {};
  const done = z.aktiv === true, lock = locked();
  if (done && !restartPending(a)) {
    return h('div', { class: 'action quiet one', 'data-id': a.id },
      h('div', { class: 'ah' }, icon('tick'), h('span', { class: 'at', text: a.titel }),
        h('div', { class: 'acts' }, h('span', { class: 'state on', text: t('karte.bereitsErledigt') }))));
  }
  const hasVar = a.varianten && a.varianten.length;
  const stateNode = h('span', { class: 'state ' + (z.aktiv === true ? 'on' : (z.aktiv === false ? 'off' : 'unk')), title: z.stand ? t('karte.gelesen', fmtDate(z.stand)) : null },
    h('i'), z.wert != null && z.wert !== '' ? t('karte.zustand', plainVal(z.wert), '') : t('karte.zustandUnbekannt'));
  let sel = null, curCmd = runCmdText(a, hasVar ? (S.variant[a.id] || a.varianten[0]) : null);
  const cmdPre = h('pre'); fillCmd(cmdPre, curCmd);
  if (hasVar) {
    sel = h('select', { 'aria-label': t('karte.variante'), onchange: e => { S.variant[a.id] = e.target.value; curCmd = runCmdText(a, e.target.value); fillCmd(cmdPre, curCmd); } },
      a.varianten.map(v => h('option', { value: v, selected: (S.variant[a.id] || a.varianten[0]) === v, text: varName(a, v) })));
  }
  const chk = (!hasVar && !done && !lock && !S.einfach)   // Mehrfachauswahl nur im Experten-Modus (#103)
    ? h('input', { type: 'checkbox', checked: S.sel.has(a.id), 'aria-label': t('karte.auswaehlen', a.titel), onchange: e => { if (e.target.checked) S.sel.add(a.id); else S.sel.delete(a.id); updateMulti(); } })
    : null;
  const pend = restartPending(a);
  const btn = pend ? h('span', { class: 'restart pending', text: t('karte.neustartAusstehend') })
    : done ? h('button', { type: 'button', class: 'sm', disabled: true, text: t('karte.bereitsErledigt') })
    : lock ? h('button', { type: 'button', class: 'sm', disabled: true, title: lockTitle(), text: t('karte.gesperrt') })
      : h('button', { type: 'button', class: 'sm primary', text: t('btn.ausfuehren'), 'aria-label': t('run.ausfuehrenAria', a.titel), onclick: () => openRunDialog([a], sel ? sel.value : null) });
  const expl = (a.befehle && a.befehle.erklaerung) || [];
  const copyBtn = h('button', { type: 'button', class: 'copy', text: t('kopieren.knopf'), onclick: e => copyText(curCmd, e.currentTarget) });
  return h('div', { class: 'action' + (done ? ' quiet' : ''), 'data-id': a.id },
    h('div', { class: 'ah' }, chk, h('span', { class: 'at', text: a.titel }), levelsNode(a.nutzen, a.aufwand, a.risiko),
      a.neustart ? h('span', { class: 'lv' }, h('span', { class: 'restart', text: t('karte.neustartNoetig') })) : null,
      h('div', { class: 'acts' }, inFinding ? null : kiBtn(a.titel, () => kiAktion(a, sel ? sel.value : null)), sel, stateNode, btn)),
    a.erklaerung ? h('p', { class: 'ae', text: a.erklaerung }) : null,
    // ASR-Modi in Worten statt Enabled/AuditMode (2.7, #95)
    a.id === 'defender.asr-basis' ? h('p', { class: 'ae', text: t('karte.asrModi') }) : null,
    S.einfach ? null : h('details', { class: 'cmd' }, h('summary', { text: t('karte.befehlZeigen') }),
      h('div', { class: 'code' }, h('div', { class: 'ch' }, h('span', { text: t('cmd.psAdmin') }), copyBtn), cmdPre),
      expl.length ? h('ul', { class: 'explain' }, expl.map(x => h('li', { text: x }))) : null,
      a.befehle && a.befehle.rueckgaengig ? h('div', { class: 'note' }, tn('karte.rueckgaengig', h('code', { text: a.befehle.rueckgaengig }))) : null));
}
function updateMulti() {
  const n = S.sel.size;
  S.multiBtns.forEach(b => { b.disabled = !n || locked(); b.textContent = t('multi.knopf', n); });
}
/** Akzeptieren am Befund: nur bei angezeigtem Bericht, offenen Status und nicht bei Sigcheck (dort je Datei). */
const canAccept = f => !!S.cur && ['CRIT', 'WARN', 'TIPP', 'INFO'].includes(f.Status) && norm(f.Check) !== SIG_CHECK;
function findingRow(f, opts = {}) {
  const m = S.checklist[f.Check];
  const acts = actionsFor(f);
  const note = f.Status === 'ACK' ? t('befund.urspruenglich', STATUS_NAME[f.OriginalStatus] || f.OriginalStatus || '', f.Note || '') : f.Note;
  // Eine Hauptaktion je Karte (2.7, #95): Merken, Akzeptieren und Rohdaten ruhig in der Fußzeile; eine Markierung bleibt sichtbar
  // Einfacher Modus (#103): ohne Vormerken (Checkliste), Rohdaten und Stufen; Akzeptieren und „KI fragen“ bleiben
  const einfach = S.einfach, merken = isOpen(f) && !einfach;
  const todo = (merken || canAccept(f)) ? h('div', { class: 'todo' },
    !merken ? null : h('button', { type: 'button', class: m && m.state === 'done' ? 'on' : '', 'aria-pressed': String(!!(m && m.state === 'done')), 'data-mark': 'done', title: t('befund.erledigtTitel'), text: t('befund.erledigtText'), onclick: () => toggleMark(f.Check, 'done') }),
    !merken ? null : h('button', { type: 'button', class: m && m.state === 'later' ? 'on' : '', 'aria-pressed': String(!!(m && m.state === 'later')), 'data-mark': 'later', title: t('befund.spaeterTitel'), text: t('befund.spaeterText'), onclick: () => toggleMark(f.Check, 'later') }),
    canAccept(f) ? h('button', { type: 'button', 'data-mark': 'acc', title: readOnly() ? lockTitle() : t('befund.akzTitel'), disabled: readOnly(), text: t('befund.akzText'), onclick: () => openAkzeptieren({ art: 'befund', check: f.Check }) }) : null) : null;
  const lvl = einfach ? null : levelsNode(f.Benefit, f.Effort, f.Risk);
  const tbls = einfach ? [] : tablesFor(f.Check);
  const dataBtn = tbls.length ? h('button', { type: 'button', class: 'btn sm ghost data-link', title: t('befund.datenTitel'), text: tbls.length > 1 ? t('befund.datenMehr', tbls.length) : t('befund.datenText'), onclick: () => openRaw(tbls) }) : null;
  const marked = m && (m.state === 'done' || m.state === 'later') && isOpen(f)
    ? h('span', { class: 'mk', text: m.state === 'done' ? t('befund.markErledigt', m.date || '') : t('befund.markSpaeter') }) : null;
  // Merken, Akzeptieren und Rohdaten direkt in der Fußzeile, ohne „Mehr“-Klick (2.7, #95, Nutzertest)
  const ki = kiBtn(chkName(f), () => kiBefund(f));   // „KI fragen“ (2.7, #101)
  const more = todo || dataBtn || ki ? h('div', { class: 'fbtns' }, todo, dataBtn, ki) : null;
  return h('div', { class: 'card finding' + (m && m.state === 'done' ? ' m-done' : ''), 'data-check': f.Check, 'data-status': f.Status },
    h('div', { class: 'fhead' },
      h('span', { class: 'chip ' + f.Status, text: STATUS_NAME[f.Status] || f.Status }),
      h('span', { class: 'fname' }, chkName(f), infoTip(f.Check, f.Category)),
      opts.hint ? h('span', { class: 'cat-hint', text: `${areaName(f)} · ${catName(f)}` }) : null),
    h('p', { class: 'fval', text: f.Value }),
    note ? h('div', { class: 'fnote' }, settingsLinks(note)) : null,
    f.Recommendation ? h('div', { class: 'frec' }, settingsLinks(f.Recommendation)) : null,
    defenderTool(f),
    einfach ? null : sysTool(f),   // Sysinternals gibt es nur im Experten-Modus
    // Stufen nur ohne Aktionskarte, die zeigt sie selbst; Merken/Akzeptieren/Rohdaten ruhig in der Fußzeile (2.7, #92)
    lvl && !acts.length ? h('div', { class: 'lvwrap' }, lvl) : null,
    howTo(f),
    acts.map(a => actionCard(a, true)),
    more || marked ? h('div', { class: 'fsec' }, marked, more) : null);
}
const DEF_FIND = { 'Defender: Signaturen': 'signaturen', 'Defender: Scans': 'schnellscan' };
/** Knopf am Befund „Defender: Signaturen“ / „Defender: Scans“ (nur bei offenem Befund), startet dieselbe Aufgabe wie unter „Werkzeuge“. */
function defenderTool(f) {
  const art = DEF_FIND[norm(f.Check)];
  if (!art || f.Status === 'OK' || f.Status === 'ACK' || f.Status === 'SKIP') return null;
  return h('div', { class: 'deftool' },
    h('button', { type: 'button', class: 'sm primary', disabled: readOnly(), title: readOnly() ? lockTitle() : null, text: art === 'signaturen' ? t('def.signaturenAkt') : t('def.schnellscanStart'), onclick: () => startDefender(art) }),
    h('a', { href: '#/werkzeuge', text: t('def.alleWerkzeuge') }));
}
const SYS_FIND = new Set(['Autostarts: Signaturen (Autoruns)', 'Autostarts: beschreibbare Pfade (Autoruns)', 'Systemdateien: Signaturen (Sigcheck)']);
/** Link am Sysinternals-Befund zur Karte unter „Werkzeuge“, nur wenn dort etwas zu tun ist (nicht eingerichtet bzw. Werkzeug nicht vertrauenswürdig). */
function sysTool(f) {
  if (!SYS_FIND.has(norm(f.Check))) return null;
  const v = String(f.Value || '');
  let text = null;
  if (f.Status === 'SKIP' && /^Sysinternals (nicht eingerichtet|not set up|not installed|not configured)/i.test(v)) text = t('sys.einrichtenLink');
  else if (f.Status === 'WARN' && /nicht ausgeführt|not (run|executed)/i.test(v)) text = t('sys.neuLadenLink');
  if (!text) return null;
  return h('div', { class: 'deftool' }, h('a', { href: '#/werkzeuge', text }));
}
function toggleMark(check, state) {
  // Im Nur-Lesen-Modus speichert der Server nichts (403), also auch lokal nichts ändern
  if (readOnly()) { toast(t('check.nurLesen')); return; }
  const m = S.checklist[check];
  if (m && m.state === state) delete S.checklist[check];
  else S.checklist[check] = { state, date: new Date().toLocaleDateString(locTag()), report: S.report.Meta.Erstellt };
  api('/api/checklist', { method: 'POST', body: S.checklist }).catch(e => toast(t('check.nichtGespeichert', e.message)));
  refreshView();
}
function banner(kind, iconId, ...kids) { return h('div', { class: 'banner' + (kind ? ' b-' + kind : '') }, icon(iconId), h('div', null, ...kids)); }
function reportBar() {
  if (!S.reports.length || S.cur === S.reports[0].name) return null;
  return banner('info', 'doc', h('b', { text: t('bar.siehstBericht', fmtDate(S.report.Meta.Erstellt)) }), t('bar.neuerer'),
    h('button', { type: 'button', class: 'link', text: t('bar.zumNeuesten'), onclick: async () => { try { await showReport(S.reports[0].name); refreshView(); } catch (e) { toast(e.message); } } }));
}
// ---- Datenordner-Rechte (Vertrag 18.10)
const dOrd = () => (S.session && S.session.datenordner) || null;
const dOrdRepariert = d => Array.isArray(d.repariert) ? !!d.repariert[0] : !!d.repariert;
const dOrdReparierbar = () => { const d = dOrd(); return !!(d && d.zustand === 'reparierbar' && !dOrdRepariert(d)); };
function dOrdKonten(d) { return (d.konten || []).map(k => (k.rechte === 'schreiben' ? t('dord.vollzugriff', k.name || k.sid) : t('dord.leserecht', k.name || k.sid))).join(', '); }
function dOrdHinweis() {
  // Der Server liefert reparaturZeit auf oberster Ebene von /api/session (auch im normalen Modus, höchstens 7 Tage alt)
  const zeit = S.session && S.session.reparaturZeit;
  if (!zeit || dOrdReparierbar()) return null;
  return banner('', 'warn', h('b', { text: t('dord.repariertAm', fmtDate(zeit)) }), t('dord.pruefen'));
}
function dOrdBanner() {
  const d = dOrd();
  const b = banner('err', 'warn', h('b', { text: t('dord.geaendert') }),
    h('p', { text: t('dord.ursache', dOrdKonten(d) || t('dord.weitereKonten'), d.pfad ? t('dord.auf', d.pfad) : '') }),
    h('p', { text: t('dord.risiko') }),
    h('div', { class: 'brow' },
      h('button', { type: 'button', class: 'sm primary', 'data-f': 'repair', text: t('dord.reparieren'), onclick: () => openDatenordner('reparieren') }), ' ',
      h('button', { type: 'button', class: 'sm', 'data-f': 'neu', text: t('dord.neuAnlegen'), onclick: () => openDatenordner('neu') })));
  b.classList.add('dord-banner');
  return b;
}
/** Das Datenordner-Banner gehört auf jede Ansicht (auch ohne Bericht, z. B. auf der Übersicht beim Start). */
function dOrdBannerEinsetzen(node) {
  if (!dOrdReparierbar() || !node || node.querySelector('.dord-banner')) return;
  const h1 = node.querySelector('h1');
  const b = dOrdBanner();
  if (h1 && h1.parentNode) {
    // nach Titel und Untertitel einfügen
    let nach = h1;
    if (nach.nextElementSibling && nach.nextElementSibling.classList.contains('sub')) nach = nach.nextElementSibling;
    nach.after(b);
  } else node.prepend(b);
}
function openDatenordner(art) {
  const d = dOrd() || {}, neu = art === 'neu';
  const body = neu ? [
    h('p', { text: t('dord.neuP1', d.pfad || 'C:\\ProgramData\\Morpheus') }),
    h('p', { class: 'warn', text: t('dord.neuWarn') }),
    h('p', { class: 'muted', text: t('dord.windowsFragt') })]
  : [
    h('p', { text: t('dord.repDas') }),
    h('ul', null,
      h('li', { text: dOrdKonten(d) ? t('dord.repL1Konten', dOrdKonten(d)) : t('dord.repL1') }),
      h('li', { text: t('dord.repL2') }),
      h('li', { text: t('dord.repL3') }),
      h('li', { text: t('dord.repL4') }),
      h('li', { text: t('dord.repL5') })),
    h('p', { class: 'muted', text: t('dord.windowsFragt') })];
  dlgOpen(neu ? t('dord.titelNeu') : t('dord.titelRep'), body,
    [{ label: t('btn.abbrechen'), onClick: dlgClose }, neu ? { label: t('dord.neuKnopf'), danger: true, onClick: () => runDatenordner(art) } : { label: t('dord.repKnopf'), primary: true, onClick: () => runDatenordner(art) }]);
}
async function runDatenordner(art) {
  const title = art === 'neu' ? t('dord.titelNeu') : t('dord.titelRep');
  dlgOpen(title, [h('p', { text: t('win.bestaetigen') })], [{ label: t('btn.laeuft'), disabled: true }], { lock: true });
  let r = null, err = null;
  try { r = await api('/api/datenordner/reparieren', { method: 'POST', body: { art } }); } catch (x) { err = x; }
  Dlg.running = false;
  if (err || !r || r.ok === false) {
    const msg = err ? (err.status === 403 ? t('dord.abgelehnt') : err.message) : (r && r.meldung) || t('dord.nichtGeklappt');
    dlgOpen(title, [h('p', { class: 'rem', text: msg })], [{ label: t('btn.schliessen'), primary: true, onClick: dlgClose }]);
    return;
  }
  const d = dOrd(); if (d) d.repariert = [true];
  const note = h('p', { class: 'muted' });
  const quit = async () => {
    try { await api('/api/shutdown', { method: 'POST' }); } catch { /* Server beendet sich, die Antwort kann ausbleiben */ }
    note.textContent = t('dord.beendetKurz') + ' ' + t('dord.neuStarten');
    dlgOpen(title, [h('p', { class: 'ok', text: t('dord.beendetKurz') }), h('p', { text: t('dord.neuStarten') })], [{ label: t('btn.schliessen'), primary: true, onClick: dlgClose }]);
  };
  dlgOpen(title, [h('p', { class: 'ok', text: r.meldung || t('dord.fertig') }), h('p', { text: t('dord.neustartNoetig') }), note],
    [{ label: t('dord.spaeter'), onClick: () => { dlgClose(); refreshView(); } }, { label: t('dord.beenden'), primary: true, onClick: quit }]);
}
// Die 24-Stunden-Sperre ist kein Banner mehr (#107): Sie ist auf fast jedem PC aktiv und betrifft erst den Klick auf
// „Ausführen“ oder „Rückgängig“. Dort erklären die Dialoge sie, im Fehlerfall mit Ausweg; dazu eine Zeile unter Werkzeuge.
function safetyBanner() {
  const s = safety();
  if (dOrdReparierbar()) return dOrdBanner();
  if (readOnly()) {
    return banner('err', 'warn', h('b', { text: t('sb.nurLesen') }), tn('sb.nurLesenText', S.session.readOnlyReason || t('sb.nurLesenStandard'),
      h('code', { text: 'C:\\Program Files\\Morpheus\\pc-check-gui.cmd' })));
  }
  if (s.schutzAn === false) {
    const cmd = `Enable-ComputerRestore -Drive '${(s.laufwerk || 'C:').replace(/\\$/, '')}\\'`;
    return banner('err', 'warn', h('b', { text: t('sb.schutzAus') }), t('sb.schutzAusText'),
      h('details', { class: 'cmd' }, h('summary', { text: t('sb.einschaltenBefehl') }), cmdBlock(cmd),
        h('ul', { class: 'explain' }, h('li', { text: t('sb.einschaltenErkl') }))));
  }
  if (s.speicherKlein) {
    return banner('', 'warn', h('b', { text: t('sb.speicherKlein') }), t('sb.speicherKleinText', s.speicherMax || t('sb.wenigeGB')),
      h('a', { href: '#/sicherheit', text: t('sb.vergroessern') }), '.');
  }
  return null;
}
/** Morpheus hat in den letzten 24 Stunden selbst einen Punkt angelegt: Die Sperre greift dann sehr wahrscheinlich. */
function sperreGreift() {
  const s = safety();
  if (!s.sperre24h || !s.letzterPunkt) return false;
  const d = new Date(s.letzterPunkt).getTime();
  return !isNaN(d) && Date.now() - d < 864e5;
}
/** Befehl zum Aufheben der 24-Stunden-Sperre, in beiden Modi nur aufklappbar („Mehr …“, #107). */
function sperreMehr() {
  const s = safety();
  if (!s.befehl) return null;
  return h('details', { class: 'cmd' }, h('summary', { text: t('sb.sperre24Befehl') }), cmdBlock(s.befehl),
    h('ul', { class: 'explain' }, h('li', { text: t('sb.sperre24L1') }), h('li', null, tn('sb.sperre24L2', h('code', { text: 'Remove-ItemProperty … -Name SystemRestorePointCreationFrequency' })))));
}
const MONO_COL = /^(Pfad|Path|Image Path|Launch String|Befehl\w*|Ort|Datei(?:name|pfad)?|Sha256)$|(^|[\s_-])(Pfad|Path|Befehl|Ort|Datei|Dateiname|Sha256)($|[\s_-])/i;
const accLocal = new Set();   // lokal als „akzeptiert (ab nächstem Scan)“ markierte Sigcheck-Dateien (Pfad klein)
const SIG_TABLE = 'Unsignierte Systemdateien (Sigcheck)', SIG_CHECK = 'Systemdateien: Signaturen (Sigcheck)';
const cellText = v => v == null ? '' : (typeof v === 'boolean' ? (v ? t('tab.ja') : t('tab.nein')) : (typeof v === 'object' ? JSON.stringify(v) : v));
function tableFrom(rows, max = 300, name = '') {
  rows = (rows || []).filter(r => r != null);
  if (!rows.length) return h('p', { class: 'muted', text: t('tab.keineEintraege') });
  const cols = Object.keys(rows[0]);
  const sig = norm(name) === SIG_TABLE && !!S.cur;
  const tb = h('div', { class: 'tbl-scroll' }, h('table', null,
    h('thead', null, h('tr', null, cols.map(c => h('th', { text: colName(c) })), sig ? h('th', { text: t('tab.aktionen') }) : null)),
    h('tbody', null, rows.slice(0, max).map(r => { const cell = sig ? h('td') : null; if (cell) cell.append(sigActions(r, cell)); return h('tr', null, cols.map(c => h('td', { class: MONO_COL.test(c) ? 'mono' : null, text: cellText(r[c]) })), cell); }))));
  return rows.length > max ? h('div', null, tb, h('p', { class: 'muted', text: t('tab.weitere', rows.length - max) })) : tb;
}
/** Aktionen je Zeile der Sigcheck-Tabelle (Vertrag 16.5). */
function sigActions(r, cell) {
  const ro = readOnly(), tt = ro ? lockTitle() : null, pfad = String(r.Pfad || ''), sha = String(r.Sha256 || '');
  const okHash = /^[0-9a-fA-F]{64}$/.test(sha), acc = String(r.Akzeptiert || ''), lokal = accLocal.has(pfad.toLowerCase());
  if (!okHash) return h('div', { class: 'row-acts' }, acc ? [h('span', { class: 'chip OK', title: acc, text: t('sig.akzeptiert') }), ' '] : null, h('span', { class: 'muted', text: t('sig.neuScannen') }));
  return h('div', { class: 'row-acts' },
    h('button', { type: 'button', class: 'sm', disabled: ro, title: tt, text: t('sig.mitDefender'), onclick: () => startDefenderDatei(pfad) }), ' ',
    acc ? h('span', { class: 'chip OK', title: acc, text: t('sig.akzeptiert') })
      : lokal ? h('span', { class: 'chip OK', text: t('sig.akzeptiertSpaeter') })
      : h('button', { type: 'button', class: 'sm', disabled: ro, title: tt, text: t('befund.akzText'), onclick: () => openAkzeptieren({ art: 'datei', pfad, sha256: sha, onDone: () => { accLocal.add(pfad.toLowerCase()); if (cell && cell.isConnected) cell.replaceChildren(sigActions(r, cell)); } }) }), ' ',
    okHash ? h('a', { href: 'https://www.virustotal.com/gui/file/' + sha.toLowerCase(), target: '_blank', rel: 'noopener noreferrer', title: t('sig.vtTitel'), text: t('sig.vt') }) : null, ' ',
    okHash ? h('button', { type: 'button', class: 'sm ghost', text: t('sig.hashKopieren'), onclick: e => copyText(sha, e.currentTarget) }) : null);
}
function noReport() {
  return h('div', { class: 'card' }, h('h2', { text: t('leer.keinBericht') }), h('p', null, tn('leer.starte', h('a', { href: '#/scan', text: t('menu.scan') }))));
}

// ---------------------------------------------------------------- Navigation und Kopfleiste
function badgeFor(id) {
  if (!S.report) return null;
  const list = S.findings.filter(f => viewOf(f) === id);
  const c = counts(list), n = c.CRIT + c.WARN + c.TIPP;
  if (!n) return null;
  return h('span', { class: 'cnt ' + (c.CRIT ? 'c' : c.WARN ? 'w' : 't'), title: t('badge.titel', c.CRIT, c.WARN, c.TIPP) },
    h('span', { class: 'vh', text: t('badge.titel', c.CRIT, c.WARN, c.TIPP) }), h('span', { 'aria-hidden': 'true', text: String(n) }));
}
// ---- Aufklappbares Menü (2.5, #65): Bereiche klappen Kategorien, Filter bzw. Werkzeuge auf; Zustand je Benutzer in localStorage
function navLaden() {
  try { const o = JSON.parse(localStorage.getItem(NAV_KEY) || '{}'); return (o && typeof o === 'object' && !Array.isArray(o)) ? o : {}; } catch { return {}; }
}
function navIstAuf(key) {
  if (!S.navAuf) S.navAuf = navLaden();
  return Object.prototype.hasOwnProperty.call(S.navAuf, key) ? S.navAuf[key] === true : !!NAV_STANDARD_AUF[key];
}
function navUmschalten(key, auf) {
  const neu = auf == null ? !navIstAuf(key) : !!auf;
  if (!S.navAuf) S.navAuf = navLaden();
  S.navAuf[key] = neu;
  try { localStorage.setItem(NAV_KEY, JSON.stringify(S.navAuf)); } catch { /* ohne Speicher weiter */ }
  const item = [...document.querySelectorAll('#nav .nv-item')].find(x => x.dataset.key === key);
  if (!item) return;
  const btn = item.querySelector(':scope > .nv-row > .nv-tog'), sub = item.querySelector(':scope > .nv-sub');
  item.classList.toggle('auf', neu);
  if (sub) sub.hidden = !neu;
  if (btn) { btn.setAttribute('aria-expanded', neu ? 'true' : 'false'); btn.setAttribute('aria-label', (neu ? MENU_TEXTE.aria.zu : MENU_TEXTE.aria.auf).replace('{0}', () => btn.dataset.label)); }
}
/** Unterpunkte: [{ key, label, view, ziel?: { sel } | { kat } | { wt }, filter?, kinder?, leer? }] */
function navKinder(n) {
  if (n.kinder === 'kategorien') {
    if (!S.report) return [{ key: n.id + '/leer', label: MENU_TEXTE.unter.keinBericht, view: n.id, leer: true }];
    const kats = [];
    S.findings.forEach(f => { if (viewOf(f) === n.id && !kats.some(k => k.id === f.Category)) kats.push({ id: f.Category, name: catName(f) }); });
    const out = kats.map(k => ({ key: n.id + '/kat/' + k.id, label: k.name, view: n.id, ziel: { kat: k.id } }));
    if (n.id === 'gaming' && GAMING_CHECKS.some(c => findingByCheck(c))) out.unshift({ key: 'gaming/check', label: MENU_TEXTE.unter.gamingCheck, view: 'gaming', ziel: { sel: '#gaming-check' } });
    return out;
  }
  if (n.kinder === 'filter') return Object.entries(MENU_TEXTE.filter).map(([m, l]) => ({ key: 'alle/filter/' + m, label: l, view: 'alle', filter: m }));
  if (n.kinder === 'werkzeuge') {
    const u = MENU_TEXTE.unter;
    return [
      { key: 'werkzeuge/wartung', label: u.wartung, view: 'werkzeuge', ziel: { sel: '#wartung-card' },
        kinder: MENU_TEXTE.werkzeuge.map(([id, l]) => ({ key: 'werkzeuge/wt/' + id, label: l, view: 'werkzeuge', ziel: { wt: id } })) },
      { key: 'werkzeuge/defender', label: u.defender, view: 'werkzeuge', ziel: { sel: '#def-card' } },
      { key: 'werkzeuge/updates', label: u.updates, view: 'werkzeuge', ziel: { sel: '#upd-card' } },
      { key: 'werkzeuge/sysinternals', label: u.sysinternals, view: 'werkzeuge', ziel: { sel: '#sys-card' } },
      { key: 'werkzeuge/spiele', label: u.spieleOrdner, view: 'werkzeuge', ziel: { sel: '#spo-card' } },
    ];
  }
  return [];
}
/** Klick auf einen Unterpunkt: Ansicht öffnen, Filter setzen bzw. zum Ziel springen */
function navGehe(k) {
  S.ui.navSub = k.leer ? null : k.key;
  let neuZeichnen = false;
  if (k.filter) { const f = uiF('alle'); neuZeichnen = f.mode !== k.filter || !!f.term; S.ui.f.alle = { mode: k.filter, term: '' }; }
  if (k.ziel) {
    S.ui.navZiel = k.ziel;
    // Eine Kategorie ist nur sichtbar, wenn Filter und Suche sie nicht ausblenden
    if (k.ziel.kat) { const f = uiF(k.view); neuZeichnen = f.mode !== 'all' || !!f.term; S.ui.f[k.view] = { mode: 'all', term: '' }; }
  }
  if (location.hash === '#/' + k.view) {
    // Gleiche Ansicht: nicht neu zeichnen (Karten wie „Wartung & Reparatur“ würden neu laden und das Ziel verschieben),
    // nur Menü markieren und springen. Neu gezeichnet wird nur, wenn ein Filter das Ziel ausblendet.
    if (neuZeichnen) refreshView(); else renderNav();
    navZielZeigen();
  } else { S.ui.navSubNeu = true; location.hash = '#/' + k.view; }
}
function navZielSuchen(z) {
  if (z.sel) return $(z.sel);
  if (z.kat) return [...document.querySelectorAll('#view .section-title[data-kat]')].find(x => x.dataset.kat === z.kat) || null;
  if (z.wt) return z.wt === WT_PUNKT_ID ? $('#wt-punkt') : ([...document.querySelectorAll('#view .wt-row[data-id]')].find(x => x.dataset.id === z.wt) || null);
  return null;
}
// Scrollt so, dass das Ziel um seinen scroll-margin-top unter der Oberkante steht. Bewusst nicht scrollIntoView:
// Im Edge-App-Fenster landete das bei Sprüngen innerhalb einer Ansicht teils am Seitenende (Mock-Test 2.5).
function navScrollZu(el) {
  const soll = parseFloat(getComputedStyle(el).scrollMarginTop) || 0;
  window.scrollTo({ top: Math.max(0, Math.round(window.scrollY + el.getBoundingClientRect().top - soll)), behavior: 'instant' });
  return soll;
}
let navHalten = null;
function navHaltenStopp() {
  if (!navHalten) return;
  clearInterval(navHalten.timer);
  ['wheel', 'touchstart', 'keydown', 'mousedown'].forEach(ev => window.removeEventListener(ev, navHaltenStopp, true));
  navHalten = null;
}
/** Springt zum gemerkten Ziel. Werkzeuge laden nach: Das Ziel kann erst später entstehen (bis 30 Versuche à 150 ms) und durch
 *  nachgeladene Karten darüber verschoben werden. Deshalb hält ein Wächter es bis zu 8 s an seinem Platz, bis der Nutzer selbst
 *  scrollt, klickt oder tippt. */
function navZielZeigen(versuch = 0) {
  const z = S.ui.navZiel; if (!z) return;
  const el = navZielSuchen(z);
  if (!el) {
    if (versuch < 30) setTimeout(() => { if (S.ui.navZiel === z) navZielZeigen(versuch + 1); }, 150);
    else S.ui.navZiel = null;
    return;
  }
  S.ui.navZiel = null;
  navHaltenStopp();
  navScrollZu(el);
  if (!el.hasAttribute('tabindex')) el.setAttribute('tabindex', '-1');
  el.focus({ preventScroll: true });
  el.classList.remove('nv-flash'); void el.offsetWidth; el.classList.add('nv-flash');
  const start = Date.now(), view = S.view;
  navHalten = { timer: setInterval(() => {
    if (Date.now() - start > 8000 || S.view !== view) { navHaltenStopp(); return; }
    const ziel = el.isConnected ? el : navZielSuchen(z);
    if (!ziel) return;
    const soll = parseFloat(getComputedStyle(ziel).scrollMarginTop) || 0, ist = ziel.getBoundingClientRect().top;
    const amEnde = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2;
    if (Math.abs(ist - soll) > 6 && !(amEnde && ist > soll)) navScrollZu(ziel);
  }, 120) };
  ['wheel', 'touchstart', 'keydown', 'mousedown'].forEach(ev => window.addEventListener(ev, navHaltenStopp, true));
}
let navUid = 0;
function navEintrag(e) {
  const hat = !!(e.kinder && e.kinder.length), auf = hat && navIstAuf(e.key), subId = 'nv-sub-' + (++navUid);
  const link = h('a', { href: e.href, class: 'nv-link' + (e.aktiv ? ' on' : '') + (e.leer ? ' leer' : ''), 'aria-current': e.aktiv ? (e.ebene ? 'location' : 'page') : null, 'aria-label': e.aria || null, role: e.role || null, onclick: e.onclick },
    e.ic ? icon(e.ic) : null, h('span', { class: 'nv-label', text: e.label }), e.badge);
  const tog = hat ? h('button', { type: 'button', class: 'nv-tog', 'aria-expanded': auf ? 'true' : 'false', 'aria-controls': subId, 'data-label': e.label,
    'aria-label': (auf ? MENU_TEXTE.aria.zu : MENU_TEXTE.aria.auf).replace('{0}', () => e.label), onclick: () => navUmschalten(e.key) }, icon('chev')) : null;
  const item = h('div', { class: 'nv-item lv' + e.ebene + (auf ? ' auf' : ''), 'data-key': e.key }, h('div', { class: 'nv-row' }, link, tog));
  if (hat) item.append(h('div', { class: 'nv-sub', id: subId, role: 'group', 'aria-label': e.label, hidden: !auf }, e.kinder.map(navEintrag)));
  return item;
}
function navUnter(k, ebene) {
  const aktiv = S.view === k.view && !k.leer && (k.filter ? uiF('alle').mode === k.filter : S.ui.navSub === k.key);
  return { key: k.key, label: k.label, href: '#/' + k.view, aktiv, ebene, leer: k.leer, kinder: k.kinder ? k.kinder.map(x => navUnter(x, ebene + 1)) : null,
    onclick: ev => { ev.preventDefault(); navGehe(k); } };
}
/** Menüeintrag zum Umschalten der Sprache: bietet die jeweils andere Sprache an (Autonym) */
function spracheEintrag() {
  const ziel = LANG === 'de' ? t('menu.sprache.english') : t('menu.sprache.deutsch');
  return navEintrag({ key: 'sprache', label: ziel, href: '#', ic: 'globe', aktiv: false, ebene: 0, kinder: null, aria: t('menu.sprache.aria', ziel), role: 'button',
    onclick: ev => { ev.preventDefault(); switchLang(); } });
}
function renderNav() {
  const sess = S.session || {};
  const fokus = document.activeElement && document.activeElement.closest && document.activeElement.closest('#nav .nv-item');
  const fokusKey = fokus ? fokus.dataset.key : null, fokusTog = !!(fokusKey && document.activeElement.classList.contains('nv-tog'));
  navUid = 0;
  // Einfacher Modus (#103): ohne Expertenpunkte und ohne Unterpunkte
  $('#nav').replaceChildren(h('div', { class: 'navgroup' }, NAV.filter(n => !(S.einfach && NUR_EXPERTE.includes(n.id))).map(n => {
    if (n.group) return h('div', { class: 'navh', text: n.group });
    if (n.sprache) return spracheEintrag();
    let b = null;
    if (n.badge) b = badgeFor(n.id);
    else if (n.id === 'berichte') b = S.reports.length ? h('span', { class: 'cnt n', text: String(S.reports.length) }) : null;
    else if (n.id === 'checkliste') { const k = Object.keys(S.checklist).length; b = k ? h('span', { class: 'cnt i', text: String(k) }) : null; }
    const kinder = n.kinder && !S.einfach ? navKinder(n).map(k => navUnter(k, 1)) : null;
    // Klick auf den Bereich öffnet die Ansicht und klappt ihn auf (wie im Azure Portal)
    return navEintrag({ key: n.id, label: n.label, href: '#/' + n.id, ic: n.icon, badge: b, aktiv: S.view === n.id, ebene: 0, kinder,
      onclick: () => { if (kinder && kinder.length && !navIstAuf(n.id)) navUmschalten(n.id, true); S.ui.navSub = null; } });
  })));
  if (fokusKey) {
    const it = [...document.querySelectorAll('#nav .nv-item')].find(x => x.dataset.key === fokusKey);
    const ziel = it && it.querySelector(fokusTog ? ':scope > .nv-row > .nv-tog' : ':scope > .nv-row > a');
    if (ziel) ziel.focus({ preventScroll: true });
  }
  $('#side-foot').replaceChildren(h('span', { class: 'dot' }), `${sess.pc || ''}${sess.version ? ' · v' + sess.version : ''}${sess.admin ? t('foot.admin') : ''}`);
  updateChrome();
}
/** Tastatur: Pfeil hoch/runter wandert durch die sichtbaren Einträge, rechts klappt auf bzw. geht zum ersten Unterpunkt, links klappt zu bzw. geht zum Oberpunkt */
function initNav() {
  const nav = $('#nav');
  nav.addEventListener('keydown', ev => {
    if (ev.altKey || ev.ctrlKey || ev.metaKey || ev.shiftKey) return;
    const item = ev.target.closest && ev.target.closest('.nv-item'); if (!item) return;
    const linkVon = it => it && it.querySelector(':scope > .nv-row > a');
    const links = [...nav.querySelectorAll('a.nv-link')].filter(a => a.offsetParent !== null);
    const i = links.indexOf(linkVon(item));
    const hat = !!item.querySelector(':scope > .nv-sub'), auf = item.classList.contains('auf');
    let ziel = null;
    switch (ev.key) {
      case 'ArrowDown': ziel = links[Math.min(links.length - 1, i + 1)]; break;
      case 'ArrowUp': ziel = links[Math.max(0, i - 1)]; break;
      case 'Home': ziel = links[0]; break;
      case 'End': ziel = links[links.length - 1]; break;
      case 'ArrowRight':
        if (!hat) return;
        if (!auf) { navUmschalten(item.dataset.key, true); ziel = linkVon(item); }
        else ziel = item.querySelector(':scope > .nv-sub a.nv-link');
        break;
      case 'ArrowLeft':
        if (hat && auf) { navUmschalten(item.dataset.key, false); ziel = linkVon(item); }
        else ziel = linkVon(item.parentElement && item.parentElement.closest('.nv-item'));
        break;
      default: return;
    }
    ev.preventDefault();
    if (ziel) ziel.focus();
  });
}
function updateChrome() {
  const m = S.report && S.report.Meta;
  $('#crumb').replaceChildren(...(m ? [t('kopf.berichtVom'), h('b', { text: fmtDate(m.Erstellt) }), t('kopf.profil', m.Profil || '–')] : [t('kopf.keinBerichtVorhanden')]));
  $('#crumb').title = $('#crumb').textContent;   // ganz lesbar, wenn die Zeile gekürzt ist (#103)
  $('#ki-btn').disabled = !S.report;
  syncSearch();
  renderStatusReport();
}
function syncSearch() {
  const i = $('#gsearch');
  if (document.activeElement !== i) i.value = CAT_VIEWS.includes(S.view) ? (uiF(S.view).term || '') : '';
}
function initTopbar() {
  const gs = $('#gsearch');
  gs.addEventListener('input', e => {
    const term = e.target.value.trim().toLowerCase();
    const v = CAT_VIEWS.includes(S.view) ? S.view : 'alle';
    if (v !== S.view && !term) return;
    uiF(v).term = term;
    if (v !== S.view) location.hash = '#/' + v; else refreshView();
  });
  gs.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); if (gs.value) { gs.value = ''; gs.dispatchEvent(new Event('input')); } gs.blur(); } });
  document.addEventListener('keydown', e => {
    if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey || S.einfach || $('#modal').classList.contains('on')) return;   // Suche nur im Experten-Modus (#103)
    const tg = e.target, tag = tg && tg.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || (tg && tg.isContentEditable)) return;
    e.preventDefault(); gs.focus(); gs.select();
  });
  $('#ki-btn').addEventListener('click', e => { if (S.report) copyText(buildKi(), $('#ki-btn span')); });
}

// ---------------------------------------------------------------- Ansicht: Kategorien
const filters = () => [['all', t('filter.alle')], ['problem', t('filter.probleme')], ['CRIT', t('filter.crit')], ['WARN', t('filter.warn')], ['TIPP', t('filter.tipp')], ['INFO', t('filter.info')], ['ACK', t('filter.ack')], ['OK', t('filter.ok')], ['SKIP', t('filter.skip')]];
function passes(f, st) {
  let ok = st.mode === 'all' || (st.mode === 'problem' ? isProblem(f) : f.Status === st.mode);
  if (ok && st.term) ok = `${f.Check} ${f.CheckName || ''} ${f.Value} ${f.Recommendation} ${f.Category} ${f.CategoryName || ''}`.toLowerCase().includes(st.term);
  return ok;
}
function miniChips(list) {
  const c = counts(list);
  return [...STATUS.filter(s => c[s] && s !== 'OK'), ...(c.OK ? ['OK'] : [])].map(s => h('span', { class: 'chip ' + s, text: `${c[s]} ${STATUS_NAME[s]}` }));
}
function catView(id, title, sub, pred, extra) {
  const fs = S.findings.filter(pred), st = uiF(id), einfach = S.einfach;
  const box = h('div');
  const filtBtns = filters().map(([m, l]) => h('button', { type: 'button', 'data-filter': m, class: st.mode === m ? 'active' : '', 'aria-pressed': st.mode === m ? 'true' : 'false', text: l, onclick: () => { st.mode = m; build(); } }));
  const multi = h('button', { type: 'button', class: 'primary', text: t('multi.knopf', 0), disabled: true, onclick: () => openRunDialog(S.actions.filter(a => S.sel.has(a.id))) });
  const hasActions = S.actions.length > 0;
  // Einfacher Modus (#103): ohne Filterleiste und Mehrfachauswahl; offene Befunde zuerst, der Rest als eine aufklappbare Zeile
  const bar = einfach ? null : h('div', { class: 'toolbar sticky' }, h('div', { class: 'filters', role: 'group', 'aria-label': t('cv.filterAria') }, filtBtns), hasActions ? h('div', { class: 'tools' }, multi) : null);
  if (hasActions) { S.multiBtns = einfach ? [] : [multi]; }
  const mine = einfach ? [] : S.actions.filter(a => actionView(a) === id && !findingByCheck(norm(a.pruefung)));
  const zeigt = f => einfach ? (!!S.rest[id] || isOpen(f)) : passes(f, st);
  function build() {
    filtBtns.forEach(b => { const on = b.dataset.filter === st.mode; b.classList.toggle('active', on); b.setAttribute('aria-pressed', on ? 'true' : 'false'); });
    const groups = [];
    fs.forEach(f => { let g = groups.find(x => x.cat === f.Category); if (!g) groups.push(g = { cat: f.Category, name: catName(f), all: [], vis: [] }); g.all.push(f); if (zeigt(f)) g.vis.push(f); });
    const nodes = [];
    groups.forEach(g => {
      if (!g.vis.length) return;
      nodes.push(h('div', { class: 'section-title', 'data-kat': g.cat }, h('h2', null, g.name, infoTip('', g.cat)), miniChips(g.all), h('span', { class: 'bar' })));
      g.vis.forEach(f => nodes.push(findingRow(f)));
    });
    if (einfach && fs.length) {
      const rest = fs.filter(f => !isOpen(f)).length, auf = !!S.rest[id];
      if (!fs.some(isOpen) && !auf) nodes.push(h('div', { class: 'card muted', text: t('modus.nichtsZuTun') }));
      if (rest) nodes.push(h('div', { class: 'card einfach-rest' }, icon('tick'), h('span', { text: rest === 1 ? t('modus.rest1') : t('modus.restN', rest) }),
        h('button', { type: 'button', class: 'btn sm', 'aria-expanded': String(auf), text: auf ? t('modus.restAus') : t('modus.restZeigen'),
          onclick: () => { S.rest[id] = !auf; build(); const b = box.querySelector('.einfach-rest button'); if (b) b.focus(); } })));
    } else if (!nodes.length && fs.length) nodes.push(h('div', { class: 'card muted', text: t('cv.keinePassend') }));
    if (!fs.length && !mine.length) nodes.push(h('div', { class: 'card muted', text: t('cv.keine') }));
    if (mine.length && st.mode === 'all' && !st.term) nodes.push(h('div', { class: 'more' }, h('div', { class: 'section-title' }, h('h2', { text: t('cv.weitere') }), h('span', { class: 'bar' })), h('div', { class: 'card' }, mine.map(a => actionCard(a)))));
    box.replaceChildren(...nodes);
    updateMulti();
    if (S.ui.reveal) doReveal();
  }
  const root = h('section', null, h('h1', { text: title }), h('p', { class: 'sub', text: sub }), reportBar(), safetyBanner(), extra ? extra() : null, bar, box);
  build();
  return root;
}
function gamingGrid() {
  const rows = GAMING_CHECKS.map(c => findingByCheck(c)).filter(Boolean);
  if (!rows.length) return null;
  return h('div', { id: 'gaming-check' }, h('div', { class: 'section-title' }, h('h2', { text: t('menu.unter.gamingCheck') }), h('span', { class: 'bar' })), h('div', { class: 'card' }, h('div', { class: 'gaming' }, rows.map(f =>
    h('div', { class: 'g-item', style: `--c:${STATUS_COLOR[f.Status]}` },
      h('span', { class: 'chip ' + f.Status, text: STATUS_NAME[f.Status] }),
      h('a', { href: '#/gaming', text: chkName(f), onclick: e => { e.preventDefault(); reveal(f.Check); } }),
      h('div', { class: 'v', text: f.Value }))))));
}
const V = {};
V.sicherheit = () => catView('sicherheit', t('menu.sicherheit'), t('v.sicherheit.sub'), f => viewOf(f) === 'sicherheit');
V.leistung = () => catView('leistung', t('menu.leistung'), t('v.leistung.sub'), f => viewOf(f) === 'leistung');
V.gaming = () => catView('gaming', t('menu.gaming'), t('v.gaming.sub'), f => viewOf(f) === 'gaming', gamingGrid);
V.stabilitaet = () => catView('stabilitaet', t('menu.stabilitaet'), t('v.stabilitaet.sub'), f => viewOf(f) === 'stabilitaet');
V.alle = () => catView('alle', t('menu.alle'), t('v.alle.sub'), () => true);

// ---------------------------------------------------------------- Ansicht: Übersicht
/** Zustandswert: 100 − 20·Kritisch − 5·Warnung (mindestens 0). Tipps zählen nicht (Entscheidung 2.7, #95). */
const scoreOf = c => Math.max(0, 100 - 20 * (c.CRIT || 0) - 5 * (c.WARN || 0));
function scoreInfo(v) {
  if (v >= 85) return { title: t('score.gut'), c1: 'var(--cyan)', c2: 'var(--green)' };
  if (v >= 60) return { title: t('score.einige'), c1: 'var(--yellow)', c2: 'var(--t-yellow)' };
  return { title: t('score.handlung'), c1: 'var(--orange)', c2: 'var(--red)' };
}
function chartNode(title, pts, prop, unit, better, color) {
  pts = pts.filter(p => p[prop] != null);
  if (pts.length < 2) return null;
  const w = 300, hh = 64, px = 6, py = 8;
  const vals = pts.map(p => p[prop]);
  const min = Math.min(...vals); let max = Math.max(...vals); if (max === min) max = min + 1;
  const xy = pts.map((p, i) => ({ x: +(px + (w - 2 * px) * i / (pts.length - 1)).toFixed(1), y: +(py + (hh - 2 * py) * (1 - (p[prop] - min) / (max - min))).toFixed(1), v: p[prop], d: fmtShort(p.datum) }));
  const first = vals[0], last = vals[vals.length - 1];
  const trend = last === first ? 'gleich' : ((last < first) === (better === 'low') ? 'besser' : 'schlechter');
  const trendText = trend === 'gleich' ? t('chart.gleich') : (trend === 'besser' ? t('chart.besser') : t('chart.schlechter'));
  const s = svg('svg', { viewBox: `0 0 ${w} ${hh}`, preserveAspectRatio: 'none', role: 'img', 'aria-label': title });
  const line = xy.map(p => `${p.x},${p.y}`).join(' ');
  const gid = 'ga' + Math.random().toString(36).slice(2, 8);
  const defs = svg('defs'), lg = svg('linearGradient', { id: gid, x1: '0', y1: '0', x2: '0', y2: '1' });
  lg.append(svg('stop', { offset: '0', style: `stop-color:${color || 'var(--cyan)'};stop-opacity:.35` }), svg('stop', { offset: '1', style: `stop-color:${color || 'var(--cyan)'};stop-opacity:0` }));
  defs.append(lg); s.append(defs);
  s.append(svg('path', { class: 'area', d: `M${xy[0].x},${hh} L${line.replace(/ /g, ' L')} L${xy[xy.length - 1].x},${hh}Z`, fill: `url(#${gid})` }));
  s.append(svg('polyline', { points: line }));
  xy.forEach(p => { const c = svg('circle', { cx: p.x, cy: p.y, r: 3 }); const ti = svg('title'); ti.textContent = `${p.d}: ${p.v} ${unit}`; c.append(ti); s.append(c); });
  return h('div', { class: 'chart', style: color ? `--c:${color}` : null },
    h('div', { class: 'chart-head' }, h('span', { text: title }), h('span', { class: trend === 'gleich' ? 'muted' : (trend === 'besser' ? 'trend up' : 'trend down'), text: trendText })),
    h('div', { class: 'n', text: `${last}${unit ? ' ' + unit : ''}` }),
    s, h('div', { class: 'chart-foot' }, h('span', { text: xy[0].d }), h('span', { text: xy[xy.length - 1].d })));
}
function historyPoint(r, created) {
  const F = r.Findings || [], D = r.Data || {};
  const boot = (D['Startdauer (letzte Messungen)'] || []).filter(Boolean).map(x => Number(x.HauptpfadSek)).filter(x => !isNaN(x));
  const rel = F.find(f => norm(f.Check) === 'Zuverlässigkeitsindex');
  const mm = rel && /^([\d.,]+) (?:von|of)/.exec(rel.Value || '');
  const vol = (D['Laufwerke (Volumes)'] || []).find(v => v.Laufwerk === 'C:');
  return {
    datum: created,
    zustand: scoreOf(counts(F)),
    probleme: F.filter(isProblem).length,
    startSek: boot.length ? Math.round(boot.reduce((a, b) => a + b, 0) / boot.length * 10) / 10 : null,
    index: mm ? Number(mm[1].replace(',', '.')) : null,
    freiC: vol && vol.FreiProzent != null ? Number(vol.FreiProzent) : null,
  };
}
async function fillCharts(box, token) {
  const list = S.reports.slice(0, 12).slice().reverse();
  const quick = list.map(r => ({ datum: r.created, zustand: scoreOf(r.counts || {}), probleme: ((r.counts || {}).CRIT || 0) + ((r.counts || {}).WARN || 0), startSek: null, index: null, freiC: null }));
  const draw = pts => {
    if (token !== S.rv) return;
    const nodes = [chartNode(t('chart.zustand'), pts, 'zustand', t('chart.von100'), 'high', 'var(--cyan)'), chartNode(t('chart.probleme'), pts, 'probleme', '', 'low', 'var(--orange)'), chartNode(t('chart.start'), pts, 'startSek', 's', 'low', 'var(--blue)'),
      chartNode(t('chart.index'), pts, 'index', t('chart.von10'), 'high', 'var(--violet)'), chartNode(t('chart.freiC'), pts, 'freiC', '%', 'high', 'var(--green)')].filter(Boolean);
    box.replaceChildren(...(nodes.length ? nodes : [h('p', { class: 'muted', text: t('chart.mindestens') })]));
  };
  draw(quick);
  if (list.length < 2) return;
  const full = await Promise.all(list.map(async (r, i) => { try { return historyPoint(await loadReportJson(r.name), r.created); } catch { return quick[i]; } }));
  draw(full);
}
const jaNein = v => v ? t('allg.ja') : t('allg.nein');
function heroText(c) {
  const parts = [c.CRIT && (c.CRIT === 1 ? t('hero.krit1', c.CRIT) : t('hero.kritN', c.CRIT)), c.WARN && (c.WARN === 1 ? t('hero.warn1', c.WARN) : t('hero.warnN', c.WARN)), c.TIPP && (c.TIPP === 1 ? t('hero.tipp1', c.TIPP) : t('hero.tippN', c.TIPP))].filter(Boolean);
  if (!parts.length) return t('hero.keine');
  const n = (c.CRIT || 0) + (c.WARN || 0) + (c.TIPP || 0);
  return t('hero.satz', c.CRIT ? '' : t('hero.nichtsKritisches'), parts.length > 1 ? parts.slice(0, -1).join(', ') + t('hero.und') + parts[parts.length - 1] : parts[0], n === 1 ? t('hero.wartet') : t('hero.warten'));
}
/** Ringfarbe nach dem schwersten offenen Befund, nicht nach dem Wert (2.7, #92): kritisch rot, Warnung orange, sonst grün. */
function ringColors(c) {
  if (c.CRIT) return { c1: 'var(--orange)', c2: 'var(--red)' };
  if (c.WARN) return { c1: 'var(--yellow)', c2: 'var(--orange)' };
  return { c1: 'var(--cyan)', c2: 'var(--green)' };
}
function ringNode(score, c) {
  const C = 351.86, si = ringColors(c);
  const s = svg('svg', { viewBox: '0 0 132 132', 'aria-hidden': 'true' });
  const defs = svg('defs'), g = svg('linearGradient', { id: 'gr', x1: '0', y1: '0', x2: '1', y2: '1' });
  g.append(svg('stop', { offset: '0', style: 'stop-color:' + si.c1 }), svg('stop', { offset: '1', style: 'stop-color:' + si.c2 }));
  defs.append(g);
  const val = svg('circle', { class: 'val', cx: 66, cy: 66, r: 56, stroke: 'url(#gr)', 'stroke-width': 12, fill: 'none', 'stroke-linecap': 'round', 'stroke-dasharray': C, 'stroke-dashoffset': C });
  s.append(defs, svg('circle', { cx: 66, cy: 66, r: 56, style: 'stroke:color-mix(in srgb,var(--ink) 7.06%,transparent)', 'stroke-width': 12, fill: 'none' }), val);
  requestAnimationFrame(() => requestAnimationFrame(() => val.setAttribute('stroke-dashoffset', String(+(C * (1 - score / 100)).toFixed(1)))));
  return h('div', { class: 'ring', role: 'img', 'aria-label': t('ring.aria', score) }, s, h('div', { class: 'v' }, h('div', null, h('b', { text: String(score) }), h('span', { text: t('chart.von100') }))));
}
/**
 * Zeile in „Nächste Schritte“ / „Lohnende Tipps“. Nur der erste nächste Schritt bekommt den Primär-Knopf (#107);
 * Tipps führen nie direkt aus, sondern zum Befund: erst verstehen, dann handeln.
 */
function stepRow(f, showLevels, first) {
  // Nur bestätigt offene Aktionen: Ein noch nicht gelesener Zustand (zustand null) gilt nicht als offen,
  // sonst erscheint „Ausführen“ für Erledigtes und endet in „Schon erledigt, nichts geändert“.
  const open = actionsFor(f).filter(a => a.zustand && a.zustand.aktiv === false && !(a.varianten && a.varianten.length));
  const go = e => { e.preventDefault(); reveal(f.Check); };
  let btn;
  const pend = actionsFor(f).filter(restartPending);
  if (pend.length && !open.length) btn = h('span', { class: 'restart pending', text: t('karte.neustartAusstehend') });
  else if (f.Status === 'TIPP') btn = h('button', { type: 'button', class: 'sm', text: t('step.ansehen'), onclick: go });
  else if (open.length === 1 && !locked()) btn = h('button', { type: 'button', class: first ? 'sm primary' : 'sm', text: t('btn.ausfuehren'), 'aria-label': t('run.ausfuehrenAria', open[0].titel), onclick: () => openRunDialog([open[0]]) });
  else btn = h('button', { type: 'button', class: first ? 'sm primary' : 'sm', text: (f.Steps && f.Steps.length) || f.Command ? t('howto.summary') : t('step.ansehen'), onclick: go });
  return h('div', { class: 'row' }, h('span', { class: 'chip ' + f.Status, text: STATUS_NAME[f.Status] }),
    h('div', null, h('div', { class: 't' }, h('a', { href: '#/' + viewOf(f), text: chkName(f), onclick: go }), showLevels ? levelsNode(f.Benefit, f.Effort, f.Risk) : null),
      h('div', { class: 'd', text: f.Recommendation || f.Value })), btn);
}
V.uebersicht = () => {
  if (!S.report) return h('section', null, h('h1', { text: t('menu.uebersicht') }), noReport());
  const m = S.report.Meta, c = counts(S.findings), score = scoreOf(c), si = scoreInfo(score);
  const todo = S.findings.filter(isProblem).sort((a, b) => RANK[a.Status] - RANK[b.Status] || (a.Area === 'Sicherheit' ? 0 : 1) - (b.Area === 'Sicherheit' ? 0 : 1) || cmpTxt(catName(a), catName(b)));
  const tips = S.findings.filter(f => f.Status === 'TIPP').sort((a, b) => tipScore(b) - tipScore(a) || cmpTxt(areaName(a), areaName(b)) || cmpTxt(catName(a), catName(b)));
  const charts = h('div', { class: 'charts' }, h('p', { class: 'muted', text: t('laedt') }));
  const hp = S.help && (S.help.Status || S.help.status);
  const ch = S.report.Changes;
  const token = S.rv;
  const toFilter = s => () => { S.ui.f.alle = { mode: s, term: '' }; if (location.hash === '#/alle') refreshView(); else location.hash = '#/alle'; };
  const pill = (s, label, color) => h('button', { type: 'button', class: 'pill', style: `--c:${color}`, title: hp && hp[s] ? hp[s] : t('uebersicht.nurDiese'), onclick: toFilter(s) }, h('i'), `${c[s]} ${label}`);
  const kpi = (s, label) => h('button', { type: 'button', class: 'kpi', style: `--c:${STATUS_COLOR[s]}`, title: hp && hp[s] ? hp[s] : t('uebersicht.nurDiese'), onclick: toFilter(s) }, h('b', { text: String(c[s]) }), h('span', null, h('i'), c[s] === 1 ? { CRIT: t('kpi1.CRIT'), WARN: t('kpi1.WARN'), TIPP: t('kpi1.TIPP'), SKIP: t('kpi1.SKIP') }[s] : label));
  // Einfacher Modus (#103): Zustandsring mit Klartext, die nächsten Schritte und die besten Tipps; Kennzahlen, Verlauf und Legende nur für Experten
  if (S.einfach) {
    const mehr = (n, key, mode) => n > 3 ? h('p', { class: 'note' }, t(key, n) + ' ', h('a', { href: '#/alle', text: t('uebersicht.alleAnzeigen'), onclick: () => { S.ui.f.alle = { mode, term: '' }; } })) : null;
    return h('section', null,
      h('h1', { text: t('menu.uebersicht') }),
      h('p', { class: 'sub', text: t('uebersicht.sub', fmtDate(m.Erstellt), jaNein(m.Admin), m.DauerSek != null ? t('uebersicht.dauer', m.DauerSek) : '', m.Computer || '') }),
      reportBar(), safetyBanner(),
      h('div', { class: 'card hero' }, ringNode(score, c), h('div', null, h('h2', { text: si.title }), h('p', { text: heroText(c) }))),
      h('div', { class: 'grid g-2' },
        h('div', { class: 'card' }, h('h2', null, t('uebersicht.naechste'), h('span', { class: 'hint', text: t('uebersicht.naechsteHint') })),
          todo.length ? [h('div', { class: 'list' }, todo.slice(0, 3).map((f, i) => stepRow(f, false, i === 0))), mehr(todo.length, 'uebersicht.insgesamtPunkte', 'problem')]
            : h('p', { text: t('uebersicht.keinHandlung') })),
        h('div', { class: 'card' }, h('h2', null, t('uebersicht.tipps'), h('span', { class: 'hint', text: t('uebersicht.tippsHint') })),
          tips.length ? [h('div', { class: 'list' }, tips.slice(0, 3).map(f => stepRow(f, false))), mehr(tips.length, 'uebersicht.insgesamtTipps', 'TIPP')]
            : h('p', { class: 'muted', text: t('uebersicht.keineTipps') }))),
      einfachHinweis());
  }
  const root = h('section', null,
    h('h1', { text: t('menu.uebersicht') }),
    h('p', { class: 'sub', text: t('uebersicht.sub', fmtDate(m.Erstellt), jaNein(m.Admin), m.DauerSek != null ? t('uebersicht.dauer', m.DauerSek) : '', m.Computer || '') }),
    reportBar(), safetyBanner(),
    h('div', { class: 'grid g-hero' },
      h('div', { class: 'card hero' }, ringNode(score, c),
        h('div', null, h('h2', { text: si.title }), h('p', { text: heroText(c) }),
          h('div', { class: 'pills' }, pill('OK', t('status.ok'), 'var(--green)'), pill('ACK', t('uebersicht.akzeptiert'), 'var(--cyan)'), pill('INFO', c.INFO === 1 ? t('uebersicht.hinweis1') : t('uebersicht.hinweisN'), 'var(--blue)')),
          h('div', { class: 'formula', text: t('uebersicht.formel') }))),
      h('div', { class: 'card' }, h('h2', { text: t('uebersicht.aufEinenBlick') }),
        h('div', { class: 'kpis' }, kpi('CRIT', t('menu.filter.crit')), kpi('WARN', t('menu.filter.warn')), kpi('TIPP', t('menu.filter.tipp')), kpi('SKIP', t('menu.filter.skip'))))),
    h('div', { class: 'grid g-2' },
      h('div', { class: 'card' }, h('h2', null, t('uebersicht.naechste'), h('span', { class: 'hint', text: t('uebersicht.naechsteHint') })),
        todo.length ? [h('div', { class: 'list' }, todo.slice(0, 3).map((f, i) => stepRow(f, false, i === 0))), todo.length > 3 ? h('p', { class: 'note' }, t('uebersicht.insgesamtPunkte', todo.length) + ' ', h('a', { href: '#/alle', text: t('uebersicht.alleAnzeigen'), onclick: () => { S.ui.f.alle = { mode: 'problem', term: '' }; } })) : null]
          : h('p', { text: t('uebersicht.keinHandlung') })),
      h('div', { class: 'card' }, h('h2', null, t('uebersicht.tipps'), h('span', { class: 'hint', text: t('uebersicht.tippsHint') })),
        tips.length ? [h('div', { class: 'list' }, tips.slice(0, 5).map(f => stepRow(f, true))),
          tips.length > 5 ? h('p', { class: 'note' }, t('uebersicht.insgesamtTipps', tips.length) + ' ', h('a', { href: '#/alle', text: t('uebersicht.alleAnzeigen'), onclick: () => { S.ui.f.alle = { mode: 'TIPP', term: '' }; } })) : null]
          : h('p', { class: 'muted', text: t('uebersicht.keineTipps') }))),
    h('div', { class: 'card' }, h('h2', null, t('uebersicht.verlauf'), h('span', { class: 'hint', text: t('uebersicht.verlaufHint') })), charts),
    ch ? changesCard(ch) : null,
    hp ? h('details', { class: 'card' }, h('summary', { text: t('uebersicht.statusLesen') }), h('ul', null, STATUS.map(s => h('li', null, h('span', { class: 'chip ' + s, text: STATUS_NAME[s] }), ' ', hp[s] || '')))) : null);
  fillCharts(charts, token);
  return root;
};
function changesCard(ch) {
  const status = ch.Status || [], bestand = ch.Bestand || {};
  let prev = ch.Erstellt ? fmtDate(ch.Erstellt) : '';
  return h('details', { class: 'card' }, h('summary', { text: t('chg.summary') }),
    h('p', { class: 'muted', text: t('chg.verglichen', prev, ch.AdminVorher === false ? t('chg.adminHinweis') : '') }),
    status.length ? [h('h3', { text: t('chg.geaenderte') }), tableFrom(status)] : null,
    Object.keys(bestand).map(tab => h('div', null, h('h3', { text: tblName(tab) }), h('ul', { class: 'chg' },
      (bestand[tab].Neu || []).map(x => h('li', { class: 'add', text: '+ ' + x })), (bestand[tab].Entfernt || []).map(x => h('li', { class: 'rem', text: '− ' + x }))))),
    !status.length && !Object.keys(bestand).length ? h('p', { text: t('chg.keine') }) : null);
}

// ---------------------------------------------------------------- KI-Kopie (Anonymisierung wie Protect-Text in pc-check.ps1)
const reEsc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
function protect(text, ctx) {
  if (!text) return '';
  let s = String(text);
  if (ctx.pc) s = s.replace(new RegExp(reEsc(ctx.pc), 'gi'), '<PC>');
  if (ctx.user && ctx.user.length >= 3) s = s.replace(new RegExp(reEsc(ctx.user), 'gi'), '<Benutzer>');
  s = s.replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, '<E-Mail>')
    .replace(/S-1-5-21-[\d-]+/gi, '<SID>')
    .replace(/\b([0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b/gi, '<MAC>')
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '<IP>')
    .replace(/\bfe80:[0-9a-f:%]*|\b[0-9a-f]{4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f:]+/gi, '<IPv6>')
    .replace(/(\\Users\\)[^\\\s"']+/gi, '$1<Benutzer>'); // zusätzlich zur PS-Fassung: Profilordner
  return s;
}
function kiCtx() {
  const m = (S.report && S.report.Meta) || {};
  return { pc: m.Computer || (S.session && S.session.pc) || '', user: (S.session && (S.session.benutzer || S.session.user)) || ((S.journal || [])[0] || {}).benutzer || '' };
}
function buildKi() {
  const m = S.report.Meta, sys = ((S.report.Data || {}).System || [])[0] || {};
  const ctx = kiCtx();
  const c = counts(S.findings), L = [];
  L.push(t('ki.zeile1'));
  L.push(t('ki.zeile2'), '');
  L.push(t('ki.system', sys.Edition || 'Windows', sys.Version || '', m.Version || '', jaNein(m.Admin)));
  L.push(t('ki.nutzung', m.Profil || ''));
  L.push(t('ki.uebersicht', c.CRIT, c.WARN, c.TIPP, c.ACK, c.INFO, c.OK));
  ['CRIT', 'WARN', 'TIPP', 'ACK', 'INFO'].forEach(s => {
    const list = S.findings.filter(f => f.Status === s);
    if (!list.length) return;
    L.push('', `== ${STATUS_NAME[s]} ==`);
    list.forEach(f => {
      L.push(`- [${areaName(f)} / ${catName(f)}] ${chkName(f)}: ${protect(f.Value, ctx)}`);
      if (f.Recommendation) L.push(t('ki.empfehlung', protect(f.Recommendation, ctx)));
      if (s === 'ACK') L.push(t('ki.akzeptiert', protect(f.Note, ctx)));
    });
  });
  return L.join('\n');
}

// ---------------------------------------------------------------- Knopf „KI fragen“ (2.7, #101)
// Kopiert eine Frage für eine beliebige KI, die eine Prüfung, Anpassung oder Funktion in einfachen Worten erklären lässt.
// Nur Zwischenablage, kein Netz. Persönliches wird wie bei „Für KI kopieren“ ersetzt (protect). Werte vom PC stehen in einem
// Datenblock mit zufälliger Markierung, damit z. B. ein Autostart-Name wie „Ignoriere alles …“ für die KI keine Anweisung wird.
const KI_KEY = 'morpheusKiFragen', KI_MAX = 700, KI_MAX_GESAMT = 6000;
function kiOn() { try { return localStorage.getItem(KI_KEY) !== '0'; } catch { return true; } }
function kiClean(v, ctx) {
  if (v == null || v === '') return '';
  let s = protect(Array.isArray(v) ? v.filter(x => x != null && x !== '').join('; ') : String(v), ctx)
    .replace(/\r/g, '').replace(/[\u0000-\u0008\u000b-\u001f\u007f​-‏‪-‮⁦-⁩]/g, '').replace(/\n{3,}/g, '\n\n').trim();
  if (s.length > KI_MAX) s = s.slice(0, KI_MAX) + t('kf.gekuerzt');
  return s;
}
function kiMarke() {
  const a = new Uint8Array(4);
  try { crypto.getRandomValues(a); } catch { for (let i = 0; i < a.length; i++) a[i] = Math.floor(Math.random() * 256); }
  return Array.from(a, b => b.toString(16).padStart(2, '0')).join('').toUpperCase();
}
const kiStufen = (n, a, r) => [[t('stufe.nutzen'), n], [t('stufe.aufwand'), a], [t('stufe.risiko'), r]].filter(x => x[1]).map(x => `${x[0]} ${stufeName(x[1])}`).join(', ');
/** Prompt bauen. fragen: Texte der fünf Fragen; felder: [[Bezeichnung, Wert], …], leere Werte fallen weg. */
function kiPrompt(thema, fragen, felder) {
  const ctx = kiCtx(), mk = kiMarke();
  const sys = (((S.report && S.report.Data) || {}).System || [])[0] || {};
  let daten = felder.concat([[t('kf.f.windows'), [sys.Edition, sys.Version].filter(Boolean).join(' ')]])
    .map(([k, v]) => [k, kiClean(v, ctx)]).filter(x => x[1])
    .map(([k, v]) => v.includes('\n') ? `${k}:\n${v}` : `${k}: ${v}`).join('\n');
  // Die Markierung darf im Datenteil nicht vorkommen (praktisch ausgeschlossen, aber billig zu prüfen)
  daten = daten.split(mk).join('');
  if (daten.length > KI_MAX_GESAMT) daten = daten.slice(0, KI_MAX_GESAMT) + t('kf.gekuerzt');
  return [t('kf.einleitung'), '', thema, ...fragen, '', t('kf.stil'), '',
    t('kf.datenHinweis', mk), t('kf.anfang', mk), daten, t('kf.ende', mk), '', t('kf.sprache')].join('\n');
}
function kiBefund(f) {
  const P = (S.help && (S.help.Pruefungen || S.help.pruefungen)) || {}, e = P[f.Check] || {};
  const note = f.Status === 'ACK' ? t('befund.urspruenglich', STATUS_NAME[f.OriginalStatus] || f.OriginalStatus || '', f.Note || '') : f.Note;
  return kiPrompt(t('kf.thema.befund'), [t('kf.befund.1'), t('kf.befund.2'), t('kf.befund.3'), t('kf.befund.4'), t('kf.befund.5')], [
    [t('kf.f.pruefung'), chkName(f)],
    [t('kf.f.bereich'), [areaName(f), catName(f)].filter(Boolean).join(' / ')],
    [t('kf.f.ergebnis'), STATUS_NAME[f.Status] || f.Status],
    [t('kf.f.wert'), f.Value],
    [t('kf.f.hinweis'), note],
    [t('kf.f.empfehlung'), f.Recommendation],
    [t('kf.f.was'), e.Was], [t('kf.f.warum'), e.Warum], [t('kf.f.harmlos'), e.Harmlos],
    [t('kf.f.einschaetzung'), kiStufen(f.Benefit, f.Effort, f.Risk)],
    // Ein „KI fragen“ je Befund (#107): Die Anpassungen samt Befehl stehen deshalb hier mit drin
    [t('kf.f.anpassungen'), actionsFor(f).map(a => [a.titel, a.erklaerung].filter(Boolean).join(': '))],
    [t('kf.f.befehl'), actionsFor(f).length === 1 ? runCmdText(actionsFor(f)[0], S.variant[actionsFor(f)[0].id] || ((actionsFor(f)[0].varianten || [])[0])) : null]]);
}
function kiAktion(a, variante) {
  const z = a.zustand || {}, hasVar = a.varianten && a.varianten.length;
  const v = hasVar ? (variante || S.variant[a.id] || a.varianten[0]) : null;
  const ohnePunkt = a.ohneWiederherstellungspunkt || a.id === 'system.wiederherstellung';
  return kiPrompt(t('kf.thema.aktion'), [t('kf.aktion.1'), t('kf.aktion.2'), t('kf.aktion.3'), t('kf.aktion.4'), t('kf.aktion.5')], [
    [t('kf.f.anpassung'), a.titel],
    [t('kf.f.erklaerung'), a.erklaerung],
    [t('kf.f.einschaetzung'), kiStufen(a.nutzen, a.aufwand, a.risiko)],
    [t('kf.f.neustart'), jaNein(a.neustart)],
    [t('kf.f.zustand'), z.wert != null && z.wert !== '' ? plainVal(z.wert) : t('karte.zustandUnbekannt')],
    [t('kf.f.varianten'), hasVar ? a.varianten.map(x => varName(a, x)) : null],
    [t('kf.f.befehl'), runCmdText(a, v)],
    [t('kf.f.rueckgaengig'), a.befehle && a.befehle.rueckgaengig],
    [t('kf.f.sicherung'), ohnePunkt ? t('kf.sicherungNein') : t('kf.sicherungJa')]]);
}
/** Funktion oder Werkzeug: titel, Beschreibung und weitere Felder ([Bezeichnung, Wert]). */
function kiWerkzeug(titel, erkl, felder) {
  return kiPrompt(t('kf.thema.werkzeug'), [t('kf.werkzeug.1'), t('kf.werkzeug.2'), t('kf.werkzeug.3'), t('kf.werkzeug.4'), t('kf.werkzeug.5')],
    [[t('kf.f.funktion'), titel], [t('kf.f.erklaerung'), erkl]].concat(felder || []));
}
function kiWartung(w, lw) {
  const hp = S.help && (S.help.Wartung || S.help.wartung), help = (hp && hp[w.id]) || {};
  return kiWerkzeug(w.titel, w.erklaerung, [
    [t('kf.f.art'), (WT_KLASSE[w.klasse] || [])[1]],
    [t('kf.f.was'), help.Was], [t('kf.f.wann'), help.Wann], [t('kf.f.hinweis'), [help.Hinweis, w.hinweis].filter(Boolean).join(' ')],
    [t('kf.f.dauer'), w.dauer], [t('kf.f.internet'), w.internet ? t('allg.ja') : null],
    [t('kf.f.befehl'), wtBefehl(w, lw)]]);
}
/** Kleiner Knopf „KI fragen“; build liefert den Prompt erst beim Klick (aktueller Zustand, Variante, Laufwerk). */
function kiBtn(titel, build) {
  if (!kiOn()) return null;
  return h('button', { type: 'button', class: 'sm ghost ki-ask', title: t('kf.titel'), 'aria-label': t('kf.aria', titel), text: t('kf.knopf'),
    onclick: e => { const b = e.currentTarget; let p = ''; try { p = build(); } catch (x) { toast(x.message); return; } copyText(p, b, t('kf.toast')); } });
}
/** Kartenüberschrift mit Knopf „KI fragen“ rechts (Werkzeuge). */
function kiHead(titel, build) {
  const b = kiBtn(titel, build);
  return b ? h('div', { class: 'ki-head' }, h('h2', { text: titel }), b) : h('h2', { text: titel });
}

// ---------------------------------------------------------------- Ansicht: Checkliste
V.checkliste = () => {
  if (!S.report) return h('section', null, h('h1', { text: t('check.titel') }), noReport());
  const created = S.report.Meta.Erstellt;
  const groups = { open: [], fixed: [], pending: [], later: [] };
  Object.keys(S.checklist).forEach(c => {
    const m = S.checklist[c], f = findingByCheck(c), still = f ? isOpen(f) : false;
    const g = m.state === 'later' ? (still ? 'later' : 'fixed') : (!still ? 'fixed' : (m.report === created ? 'pending' : 'open'));
    groups[g].push({ c, f, d: m.date });
  });
  const titles = { open: t('check.gOpen'), fixed: t('check.gFixed'), pending: t('check.gPending'), later: t('check.gLater') };
  const body = ['open', 'fixed', 'pending', 'later'].filter(g => groups[g].length).map(g => h('div', null,
    h('h3', { class: g === 'open' ? 'rem' : (g === 'fixed' ? 'add' : ''), text: titles[g] }),
    h('ul', { class: 'checklist' }, groups[g].map(x => h('li', null,
      x.f ? h('a', { href: '#/' + viewOf(x.f), text: chkName(x.f), onclick: e => { e.preventDefault(); reveal(x.c); } }) : x.c,
      h('span', { class: 'muted', text: t('check.markiertAm', x.d) }))))));
  const any = body.length;
  return h('section', null, h('h1', { text: t('check.titel') }), h('p', { class: 'sub', text: t('check.sub') }), reportBar(),
    h('div', { class: 'card' }, any ? body : h('p', { class: 'muted', text: t('check.nichts') })),
    any ? h('button', { type: 'button', class: 'danger', text: t('check.loeschen'), onclick: () => dlgOpen(t('check.loeschen'), h('p', { text: t('check.loeschenFrage') }), [{ label: t('btn.abbrechen'), onClick: dlgClose },
      { label: t('btn.loeschen'), danger: true, onClick: () => { S.checklist = {}; api('/api/checklist', { method: 'POST', body: {} }).catch(e => toast(e.message)); dlgClose(); refreshView(); } }]) }) : null);
};

// ---------------------------------------------------------------- Ansicht: Änderungen
const jstat = s => ({ begonnen: t('jr.s.begonnen'), erledigt: t('jr.s.erledigt'), fehlgeschlagen: t('jr.s.fehlgeschlagen'), 'fehlgeschlagen-zurueckgesetzt': t('jr.s.zurueckgesetzt'), zurueckgenommen: t('jr.s.zurueckgenommen') })[s];
/** Protokoll-Eintrag einer Wartung bzw. eines Programm-Updates (Abschnitt 18.8): kein Rückgängig, kein „vorher → nachher“. */
function journalWartung(e) {
  const st = e.status, failed = String(st).startsWith('fehl');
  const color = failed ? 'var(--red)' : (st === 'erledigt' ? 'var(--cyan)' : (st === 'begonnen' ? 'var(--yellow)' : 'var(--grey)'));
  const chip = st === 'erledigt' ? h('span', { class: 'chip OK', text: t('jr.s.erledigt') })
    : failed ? h('span', { class: 'chip CRIT', text: t('jr.s.fehlgeschlagen') })
      : st === 'abgebrochen' ? h('span', { class: 'chip INFO', text: t('jr.abgebrochen') })
        : st === 'begonnen' ? h('span', { class: 'chip WARN', text: t('jr.begonnenUnterbr') })
          : h('span', { class: 'chip INFO', text: String(st || '') });
  const meta = [];
  if (e.dauerSek != null) meta.push(t('jr.dauer', fmtDur(e.dauerSek)));
  if (e.exitCode != null) meta.push(t('jr.exit', e.exitCode));
  return h('div', { class: 'ev', style: `--c:${color}` },
    h('div', { class: 'h' }, h('b', { text: e.titel || e.aktion }), h('span', { class: 'chip INFO', text: t('jr.protokoll') }), h('span', { class: 'chip INFO', text: t('jr.keinRueck') }), chip,
      h('span', { class: 'when', title: fmtDate(e.zeit), text: fmtWhen(e.zeit) })),
    h('div', { class: 'm' },
      e.befehl ? h('div', null, h('code', { text: e.befehl })) : null,
      meta.length ? h('div', { text: meta.join(' · ') }) : null,
      e.ohnePunkt ? h('div', null, h('span', { class: 'chip WARN', text: t('jr.ohnePunkt') }))
        : (e.wiederherstellungspunkt && e.wiederherstellungspunkt.seq != null ? h('div', null, tn('jr.punktNr', h('code', { text: '#' + e.wiederherstellungspunkt.seq }))) : null),
      e.meldung ? h('div', { class: 'note', text: e.meldung }) : null));
}
function journalEvent(e) {
  if (e.art === 'wartung' || e.art === 'update') return journalWartung(e);
  const undone = e.status === 'zurueckgenommen', failed = String(e.status).startsWith('fehl'), isUndo = e.art === 'rueckgaengig';
  const color = failed ? 'var(--red)' : undone ? 'var(--grey)' : isUndo ? 'var(--green)' : 'var(--cyan)';
  const chip = failed ? h('span', { class: 'chip CRIT', text: jstat(e.status) || e.status })
    : undone ? h('span', { class: 'chip INFO', text: t('jr.s.zurueckgenommen') })
      : isUndo ? h('span', { class: 'chip ACK', text: t('jr.ruecknahme') })
        : h('span', { class: 'chip ' + (e.status === 'erledigt' ? 'OK' : 'WARN'), text: e.status === 'erledigt' ? t('jr.aktiv') : (jstat(e.status) || e.status) });
  const canUndo = e.status === 'erledigt' && !isUndo;
  return h('div', { class: 'ev', style: `--c:${color}` },
    h('div', { class: 'h' }, h('b', { style: undone ? 'color:var(--fg)' : null, text: isUndo ? t('jr.rueckTitel', e.titel || e.aktion) : (e.titel || e.aktion) }), chip,
      h('span', { class: 'when', title: fmtDate(e.zeit), text: fmtWhen(e.zeit) }),
      canUndo ? h('button', { type: 'button', class: 'sm', disabled: readOnly(), title: readOnly() ? lockTitle() : null, onclick: () => openUndoDialog(e) }, icon('undo'), t('jr.rueckKnopf')) : null),
    h('div', { class: 'm' }, `${fmtState(e.vorher)} → ${fmtState(e.nachher)}`, e.variante ? ` (${e.variante})` : '',
      e.wiederherstellungspunkt && e.wiederherstellungspunkt.seq != null ? tn('jr.punktNrMit', h('code', { text: '#' + e.wiederherstellungspunkt.seq })) : null,
      e.meldung ? h('div', { class: 'note', text: e.meldung }) : null));
}
V.aenderungen = () => {
  const jbox = h('div', { class: 'card' }, h('h2', { text: t('jr.verlauf') }), h('p', { class: 'muted', text: t('laedt') }));
  const rbox = h('div', { class: 'card' }, h('h2', { text: t('jr.punkte') }), h('p', { class: 'muted', text: t('laedt') }));
  const token = S.rv;
  api('/api/journal').then(list => {
    if (token !== S.rv) return;
    S.journal = list || [];
    renderStatusReport();
    jbox.replaceChildren(h('h2', { text: t('jr.verlauf') }), ...(S.journal.length
      ? [h('div', { class: 'tl' }, S.journal.slice(0, 100).map(journalEvent)), S.journal.length > 100 ? h('p', { class: 'note', text: t('jr.aeltere', S.journal.length - 100) }) : null]
      : [h('p', { class: 'muted', text: t('jr.keine') })]).filter(Boolean));
  }).catch(e => jbox.replaceChildren(h('h2', { text: t('jr.verlauf') }), h('p', { class: 'rem', text: e.message })));
  api('/api/restorepoints').then(list => {
    if (token !== S.rv) return;
    S.points = list || [];
    renderStatusReport();
    rbox.replaceChildren(h('h2', { text: t('jr.punkte') }), ...(list && list.length
      ? [h('div', { class: 'list' }, list.map(p => h('div', { class: 'row rp' }, h('code', { text: '#' + p.seq }),
        h('div', null, h('div', { class: 't', style: 'font-weight:500', text: p.beschreibung }), h('div', { class: 'd', text: `${fmtWhen(p.zeit)}${p.typ ? ' · ' + tk('rp.typ.' + p.typ, p.typ) : ''}` }))))),
      h('p', { class: 'note' }, tn('jr.rstrui', h('code', { text: 'rstrui.exe' })))]
      : [h('p', { class: 'muted', text: t('jr.keinePunkte') })]));
  }).catch(e => rbox.replaceChildren(h('h2', { text: t('jr.punkte') }), h('p', { class: 'rem', text: e.message })));
  return h('section', null, h('h1', { text: t('menu.aenderungen') }), h('p', { class: 'sub', text: t('jr.sub') }),
    safetyBanner(), dOrdHinweis(), h('div', { class: 'grid g-hero' }, jbox, rbox));
};

// ---------------------------------------------------------------- Ansicht: Berichte
/** Adresse des Original-Berichts mit einmaliger Lesemarke (nie mit Token: das Script im Bericht kann seine Adresse lesen). */
async function origSrc(name) {
  if (typeof window.PCCHECK_REPORT_SRC === 'function') return window.PCCHECK_REPORT_SRC(name);
  const r = await api('/api/report-ticket', { method: 'POST', body: { name: name + '.html' } });
  return `/report/${name}.html?k=${encodeURIComponent(r.ticket)}`;
}
V.berichte = () => {
  const cmpBox = h('div'), origBox = h('div');
  const cmpBtn = h('button', { type: 'button', class: 'primary', text: t('rb.vergleichen'), onclick: doCompare });
  function sync() { cmpBtn.disabled = S.cmp.length !== 2; }
  async function doCompare() {
    cmpBox.replaceChildren(h('p', { class: 'muted', text: t('laedt') }));
    try {
      const names = S.cmp.slice().sort(); // Dateiname enthält das Datum: A = älter
      const [A, B] = await Promise.all(names.map(loadReportJson));
      const map = r => { const o = new Map(); (r.Findings || []).forEach(f => o.set(`${norm(f.Category)}|${norm(f.Check)}`, f)); return o; };
      const a = map(A), b = map(B), rows = [];
      new Set([...a.keys(), ...b.keys()]).forEach(k => { const x = a.get(k), y = b.get(k); if (!x || !y || x.Status !== y.Status) rows.push({ k, x, y }); });
      rows.sort((p, q) => RANK[(p.y || p.x).Status] - RANK[(q.y || q.x).Status]);
      const bd = f => f ? h('span', { class: 'chip ' + f.Status, text: STATUS_NAME[f.Status] }) : h('span', { class: 'muted', text: '–' });
      cmpBox.replaceChildren(h('div', { class: 'card' }, h('h3', { text: t('rb.vergleichTitel', fmtDate(A.Meta.Erstellt), fmtDate(B.Meta.Erstellt)) }),
        rows.length ? h('div', { class: 'tablewrap' }, h('table', null, h('thead', null, h('tr', null, [t('rb.pruefung'), t('rb.statusA'), t('rb.statusB')].map(x => h('th', { text: x })))),
          h('tbody', null, rows.map(r => h('tr', null, h('td', null, chkName(r.y || r.x), h('div', { class: 'cat-hint', text: catName(r.y || r.x) })), h('td', null, bd(r.x)), h('td', null, bd(r.y))))))) : h('p', { text: t('rb.keineUnterschiede') })));
    } catch (e) { cmpBox.replaceChildren(h('p', { class: 'rem', text: e.message })); }
  }
  function showOrig(name) {
    if (S.origName === name) { S.origName = null; origBox.replaceChildren(); return; }
    S.origName = name;
    // sandbox ohne allow-same-origin und ohne allow-popups: der Bericht kann weder die API noch Fenster öffnen
    const frame = h('iframe', { sandbox: 'allow-scripts', title: t('rb.originalHtml'), style: 'width:100%;height:78vh;border:1px solid var(--line);border-radius:6px;background:#fff' });
    origBox.replaceChildren(h('div', { class: 'card' }, h('div', { class: 'toolbar' }, h('b', { text: t('rb.originalHtml') }), h('button', { type: 'button', text: t('btn.schliessen'), onclick: () => showOrig(name) })), frame));
    origSrc(name).then(src => { frame.src = src; }, e => origBox.replaceChildren(h('p', { class: 'rem', text: e.message })));
  }
  const rows = S.reports.map(r => {
    const c = r.counts || {};
    const cb = h('input', { type: 'checkbox', checked: S.cmp.includes(r.name), 'aria-label': t('rb.zumVergleich'),
      onchange: e => { if (e.target.checked) { S.cmp.push(r.name); if (S.cmp.length > 2) S.cmp.shift(); } else S.cmp = S.cmp.filter(x => x !== r.name); refreshChecks(); sync(); } });
    return { r, cb, tr: h('tr', null, h('td', null, cb), h('td', { text: fmtDate(r.created) + (r.name === S.cur ? t('rb.angezeigt') : '') }), h('td', { text: r.version || '' }), h('td', { text: jaNein(r.admin) }), h('td', { text: r.profil || '' }),
      h('td', { text: String(c.CRIT || 0) }), h('td', { text: String(c.WARN || 0) }), h('td', { text: String(c.TIPP || 0) }),
      h('td', null, h('button', { type: 'button', text: t('rb.anzeigen'), onclick: async () => { try { await showReport(r.name); location.hash = '#/uebersicht'; if (S.view === 'uebersicht') refreshView(); } catch (e) { toast(e.message); } } }), ' ',
        h('button', { type: 'button', text: t('rb.originalKnopf'), onclick: () => showOrig(r.name) }))) };
  });
  function refreshChecks() { rows.forEach(x => { x.cb.checked = S.cmp.includes(x.r.name); }); }
  sync();
  return h('section', null, h('h1', { text: t('menu.berichte') }), h('p', { class: 'sub', text: t('rb.sub', S.reports.length) }), reportBar(),
    h('div', { class: 'toolbar' }, cmpBtn, h('span', { class: 'note', text: t('rb.hinweis') })),
    S.reports.length ? h('div', { class: 'card' }, h('div', { class: 'tablewrap' }, h('table', null,
      h('thead', null, h('tr', null, ['', t('rb.hDatum'), t('rb.hVersion'), t('rb.hAdmin'), t('rb.hProfil'), t('rb.hKrit'), t('rb.hWarn'), t('rb.hTipps'), ''].map(x => h('th', { text: x })))),
      h('tbody', null, rows.map(x => x.tr))))) : noReport(),
    cmpBox, origBox);
};

// ---------------------------------------------------------------- Ansicht: Scan
V.scan = () => {
  const sc = S.scan;
  const profil = h('select', { id: 'sc-profil', 'aria-label': t('scan.profilAria') }, [['Auto', t('scan.profilAuto')], ['Gaming', 'Gaming'], ['Office', 'Office'], ['Laptop', 'Laptop']].map(([v, l]) => h('option', { value: v, text: l })));
  const days = h('select', { id: 'sc-days', 'aria-label': t('scan.zeitraumAria') }, [7, 14, 30, 60, 90].map(d => h('option', { value: String(d), selected: d === 14, text: t('scan.tage', d) })));
  const upd = h('input', { type: 'checkbox', checked: true }), wg = h('input', { type: 'checkbox', checked: true }), nsp = h('input', { type: 'checkbox' }), nsi = h('input', { type: 'checkbox' });
  const log = h('pre', { class: 'log scanlog', id: 'scanlog', 'aria-live': 'polite', text: sc ? sc.lines.join('\n') : t('scan.bereit') });
  const btn = h('button', { type: 'button', class: 'btn brand', text: t('scan.starten'), disabled: !!(sc && sc.running) || readOnly(), title: readOnly() ? lockTitle() : null, onclick: startScan });
  const msg = h('div', { id: 'scanmsg' });
  function startScan() {
    const d = parseInt(days.value, 10);
    if (!(d >= 1 && d <= 90)) return;
    S.scan = { running: true, lines: [], done: false };
    log.textContent = ''; btn.disabled = true; msg.replaceChildren();
    runScan({ profil: profil.value, eventDays: d, skipWinget: !wg.checked, skipUpdateSearch: !upd.checked, skipSpeicher: nsp.checked, skipSysinternals: nsi.checked });
  }
  S.scanUi = { log, btn, msg };
  if (sc && sc.msg) msg.replaceChildren(sc.msg);
  log.scrollTop = log.scrollHeight;
  return h('section', { class: 'noaccent' }, h('h1', { text: t('menu.scan') }), h('p', { class: 'sub', text: t('scan.sub') }),
    h('div', { class: 'card' }, h('div', { class: 'toolbar' },
      h('label', null, t('scan.lblProfil') + ' ', profil), h('label', null, t('scan.lblZeitraum') + ' ', days),
      h('label', null, upd, ' ' + t('scan.optUpdate')), h('label', null, wg, ' ' + t('scan.optWinget')), h('label', null, nsp, ' ' + t('scan.optSpeicher')), h('label', null, nsi, ' ' + t('scan.optSysinternals')), btn), log, msg));
};
async function runScan(body) {
  const ui = () => { const u = S.scanUi; return u && u.log.isConnected ? u : null; };
  const out = lines => { S.scan.lines.push(...lines); const u = ui(); if (u) { u.log.textContent = S.scan.lines.join('\n'); u.log.scrollTop = u.log.scrollHeight; } };
  try {
    const r = await api('/api/scan', { method: 'POST', body });
    const job = await followJob(r.jobId, out);
    S.scan.running = false;
    if (job.status === 'done') {
      await loadReports();
      if (S.reports.length) await showReport(S.reports[0].name);
      await loadSpeicher();
      S.scan.msg = banner('info', 'doc', h('b', { text: t('scan.fertig') }), t('scan.neuerBericht'), h('a', { href: '#/uebersicht', text: t('scan.zurUebersicht') }));
      toast(t('scan.toastFertig'));
      // Zustände der Anpassungen passend zum neuen Bericht neu lesen; sonst zeigt eine Karte z. B. „aus“, obwohl der Scan „an“ meldet
      refreshActionStates();
    } else S.scan.msg = h('p', { class: 'rem', text: (job.ergebnis && job.ergebnis.error) || t('scan.fehlgeschlagen') });
  } catch (e) { S.scan.running = false; S.scan.msg = h('p', { class: 'rem', text: e.message }); }
  const u = ui();
  if (u) { u.btn.disabled = false; u.msg.replaceChildren(S.scan.msg); }
  renderNav();
  if (S.view !== 'scan' && !$('#modal').classList.contains('on')) refreshView();
}

// ---------------------------------------------------------------- Ansicht: Rohdaten, Einstellungen
/** Titel der Detailtabellen, die beim Scan in dieser Prüfung entstanden sind (DataChecks ab v2.1). */
function tablesFor(check) {
  const dc = (S.report && S.report.DataChecks) || {};
  return Object.keys(dc).filter(tb => dc[tb] === check && S.report.Data && S.report.Data[tb] && S.report.Data[tb].length);
}
/** Springt in den Anhang und klappt die genannten Tabellen auf. */
function openRaw(titles) {
  S.ui.rawOpen = titles;
  if (location.hash === '#/rohdaten') refreshView(); else location.hash = '#/rohdaten';
}
V.rohdaten = () => {
  if (!S.report) return h('section', null, h('h1', { text: t('menu.rohdaten') }), noReport());
  const D = S.report.Data || {}, want = S.ui.rawOpen || [], dc = S.report.DataChecks || {};
  S.ui.rawOpen = null;
  let first = null;
  const checkLabel = id => { const f = findingByCheck(norm(id)); return f ? chkName(f) : id; };
  const sec = h('section', null, h('h1', { text: t('menu.rohdaten') }), h('p', { class: 'sub', text: t('raw.sub') }), reportBar(),
    Object.keys(D).map(id => {
      const rows = D[id] || [], body = h('div');
      const d = h('details', { class: 'raw' }, h('summary', null, tblName(id), h('span', { class: 'muted', text: ` (${rows.length})` }),
        dc[id] ? h('span', { class: 'muted', text: t('raw.pruefung', checkLabel(dc[id])) }) : null), body);
      d.addEventListener('toggle', () => { if (d.open && !body.firstChild) body.append(tableFrom(rows, 300, id)); });
      if (want.includes(id)) { d.open = true; body.append(tableFrom(rows, 300, id)); d.classList.add('flash'); if (!first) first = d; }
      return d;
    }));
  if (first) setTimeout(() => first.scrollIntoView({ block: 'start', behavior: 'smooth' }), 50);
  return sec;
};
/** Darstellung (2.7, #100): Farbpalette und Modus; wirkt sofort über palette.js (Attribute auf <html>), gespeichert dort in localStorage. */
function darstellungKarte() {
  const MP = window.MorpheusPalette;
  if (!MP) return null;
  const akt = MP.get();
  const dunkelNachSystem = () => { try { return matchMedia('(prefers-color-scheme: dark)').matches; } catch { return true; } };
  const musterModus = theme => theme === 'system' ? (dunkelNachSystem() ? 'dark' : 'light') : theme;
  const muster = [];
  const swatch = p => { const s = h('span', { class: 'pal-swatch', 'data-pal': p, 'data-mode': musterModus(akt.theme), 'aria-hidden': 'true' }, h('i'), h('i'), h('i'), h('i'), h('i')); muster.push(s); return s; };
  const gruppe = (name, legende, werte, aktuell, label, vorne, wahl) => h('fieldset', { class: 'pal-group' }, h('legend', { text: legende }),
    h('div', { class: 'pal-opts' }, ...werte.map(v => h('label', { class: 'pal-opt' },
      h('input', { type: 'radio', name, value: v, checked: v === aktuell, onchange: () => wahl(v) }), vorne ? vorne(v) : null, h('span', { text: label(v) })))));
  return h('div', { class: 'card pal-card' },
    h('p', { class: 'muted', text: t('set.darstellungSub') }),
    gruppe('mo-palette', t('set.palette'), MP.PALETTEN, akt.palette, v => ({ solarized: t('set.pal.solarized'), gruvbox: t('set.pal.gruvbox'), oblivion: t('set.pal.oblivion'), sandstone: t('set.pal.sandstone') })[v] || v, swatch, v => MP.set(v, null)),
    gruppe('mo-modus', t('set.modus'), MP.MODI, akt.theme, v => t({ dark: 'set.dunkel', light: 'set.hell', system: 'set.system' }[v]), null,
      v => { const a = MP.set(null, v); muster.forEach(s => s.setAttribute('data-mode', musterModus(a.theme))); }));
}
V.einstellungen = () => {
  const m = (S.report && S.report.Meta) || {}, s = safety();
  const acc = S.findings.filter(f => f.Status === 'ACK');
  const akzBody = h('div'); loadAkzeptanz(akzBody);
  return h('section', null, h('h1', { text: t('menu.einstellungen') }), h('p', { class: 'sub', text: t('set.sub') }),
    h('div', { class: 'card' }, h('table', null, h('tbody', null,
      h('tr', null, h('td', { text: t('set.profil') }), h('td', { text: m.Profil || '–' })),
      h('tr', null, h('td', { text: t('set.zeitraum') }), h('td', { text: m.EventDays != null ? t('scan.tage', m.EventDays) : '–' })),
      h('tr', null, h('td', { text: t('set.schutz') }), h('td', null, s.schutzAn === false ? h('span', { class: 'rem', text: t('set.aus') }) : h('span', { class: 'ok', text: t('set.an') + (s.laufwerk ? ' (' + s.laufwerk + ')' : '') }), t('set.sperre24'), s.sperre24h ? h('span', { class: 'warn', text: t('set.aktiv') }) : h('span', { class: 'ok', text: t('set.aus') }))),
      h('tr', null, h('td', { text: t('set.letzterPunkt') }), h('td', { text: s.letzterPunkt ? fmtDate(s.letzterPunkt) : '–' })),
      h('tr', null, h('td', { text: t('set.version') }), h('td', { text: (S.session && S.session.version) || '' })),
      // „KI fragen“ ein-/ausblenden (2.7, #101); nur eine Anzeige-Vorliebe dieses Fensters, darum localStorage
      h('tr', null, h('td', { text: t('kf.set') }), h('td', null,
        h('label', null, h('input', { type: 'checkbox', checked: kiOn(), onchange: e => { try { localStorage.setItem(KI_KEY, e.target.checked ? '1' : '0'); } catch { /* ohne Speicher weiter */ } refreshView(); } }), ' ' + t('kf.setText')),
        h('div', { class: 'note', text: t('kf.setNote') })))))),
    h('h2', { text: t('set.darstellung') }), darstellungKarte(),
    h('h2', { text: t('set.akzListe') }), dOrdHinweis(),
    h('div', { class: 'card' }, akzBody),
    h('h2', { text: t('set.akzAbw', acc.length) }),
    h('div', { class: 'card' }, acc.length ? acc.map(f => findingRow(f, { hint: true })) : h('p', { class: 'muted', text: t('set.keineAkz') })));
};

// ---------------------------------------------------------------- Akzeptanzliste (Vertrag 16.4/16.5)
const akzErr = e => e.status === 403 ? t('akz.abgelehnt') : (e.message || t('dord.nichtGeklappt'));
function loadAkzeptanz(box) {
  box.replaceChildren(h('p', { class: 'muted', text: t('akz.lade') }));
  api('/api/akzeptanz').then(d => { if (box.isConnected) box.replaceChildren(akzTable(d || {}, box)); },
    e => { if (box.isConnected) box.replaceChildren(h('p', { class: 'rem', text: t('akz.ladenFehler', e.message) })); });
}
function akzTable(d, box) {
  const regeln = d.regeln || [], ro = readOnly() || d.bearbeitbar === false;
  const intro = h('p', { class: 'muted', text: t('akz.intro') });
  if (!regeln.length) return h('div', null, intro, h('p', { class: 'muted', text: t('akz.keine') }));
  const rows = regeln.map(r => h('tr', null,
    h('td', { text: r.check || '' }),
    h('td', { class: 'mono', text: r.datei || String(r.match || '').replace(/^\^(.*)\$$/, '$1') }),
    h('td', { text: r.reason || '' }),
    h('td', null, r.until || t('akz.unbegrenzt'), r.abgelaufen ? [' ', h('span', { class: 'chip WARN', text: t('akz.abgelaufen') })] : null),
    h('td', { text: r.quelle === 'gui' ? 'GUI' : t('akz.vonHand') }),
    h('td', null, h('button', { type: 'button', class: 'sm', disabled: ro, title: ro ? lockTitle() : null, text: t('akz.entfKnopfPunkte'), onclick: () => akzEntfernen(r, box) }))));
  return h('div', null, intro, h('div', { class: 'tbl-scroll' }, h('table', null,
    h('thead', null, h('tr', null, [t('rb.pruefung'), t('akz.hDatei'), t('akz.hBegruendung'), t('akz.hGiltBis'), t('akz.hQuelle'), ''].map(x => h('th', { text: x })))),
    h('tbody', null, rows))));
}
function akzEntfernen(r, box) {
  dlgOpen(t('akz.entfTitel'), [
    h('p', null, tn('akz.entfFrage', h('b', { text: r.check || '' }))),
    r.datei ? h('p', { class: 'mono', text: r.datei }) : null,
    h('p', { class: 'muted', text: t('akz.begruendung', r.reason || '') }),
    h('div', { class: 'note', text: t('akz.entfNote') })],
  [{ label: t('btn.abbrechen'), onClick: dlgClose }, { label: t('akz.entfKnopf'), danger: true, onClick: async () => {
    dlgOpen(t('akz.entfTitel'), [h('p', { text: t('win.bestaetigen') })], [{ label: t('btn.laeuft'), disabled: true }], { lock: true });
    try {
      await api('/api/akzeptanz/' + encodeURIComponent(r.id) + '/entfernen', { method: 'POST', body: {} });
      dlgClose(); toast(t('akz.zurueckgenommen')); if (box.isConnected) loadAkzeptanz(box);
    } catch (e) {
      dlgOpen(t('akz.entfTitel'), [h('p', { class: 'rem', text: akzErr(e) })], [{ label: t('btn.schliessen'), primary: true, onClick: dlgClose }]);
    }
  } }]);
}
const pad2 = n => String(n).padStart(2, '0');
const ymd = d => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;   // lokales Datum
/** Akzeptieren-Dialog. tg = { art:'befund', check } oder { art:'datei', pfad, sha256, onDone } (nur für den angezeigten Bericht). */
function openAkzeptieren(tg) {
  const datei = tg.art === 'datei';
  const today = new Date(), maxD = new Date(today.getFullYear() + 5, today.getMonth(), today.getDate());
  const minS = ymd(today), maxS = ymd(maxD);
  const reason = h('textarea', { id: 'akz-begr', rows: 3, maxlength: 300, 'aria-label': t('akz.begrAria'), 'aria-describedby': 'akz-msg', placeholder: t('akz.warum'), style: 'width:100%' });
  const count = h('span', { class: 'muted', text: '0 / 300' });
  const bis = h('input', { type: 'date', 'aria-label': t('akz.giltBisAria'), min: minS, max: maxS });
  const msg = h('p', { id: 'akz-msg', role: 'alert' });
  const send = h('button', { type: 'button', class: 'primary', text: t('akz.knopf') });
  const close = h('button', { type: 'button', text: t('btn.abbrechen'), onclick: dlgClose });
  const clean = () => reason.value.replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ').trim();
  reason.addEventListener('input', () => { reason.removeAttribute('aria-invalid'); count.textContent = `${clean().length} / 300`; });
  const fail = text => { msg.className = 'rem'; msg.textContent = text; };
  send.onclick = async () => {
    if (Dlg.running) return;
    const begruendung = clean();
    if (begruendung.length < 3 || begruendung.length > 300) { fail(t('akz.errBegr')); reason.setAttribute('aria-invalid', 'true'); reason.focus(); return; }
    if (bis.value && (!/^\d{4}-\d{2}-\d{2}$/.test(bis.value) || bis.value < minS || bis.value > maxS)) { fail(t('akz.errBis')); bis.focus(); return; }
    const body = datei ? { art: 'datei', bericht: S.cur + '.json', pfad: tg.pfad, begruendung } : { art: 'befund', bericht: S.cur + '.json', check: tg.check, begruendung };
    if (bis.value) body.bis = bis.value;
    Dlg.running = true; send.disabled = true; close.disabled = true; reason.disabled = true; bis.disabled = true; send.textContent = t('akz.warteWindows');
    msg.className = 'note'; msg.textContent = t('win.bestaetigen');
    try {
      await api('/api/akzeptanz', { method: 'POST', body });
      Dlg.running = false;
      if (tg.onDone) tg.onDone();
      dlgOpen(t('akz.okTitel'), [h('p', { class: 'ok', text: t('akz.gespeichert') }), h('p', { text: t('akz.wirktAb') })],
        [{ label: t('dord.spaeter'), onClick: dlgClose }, { label: t('menu.scan'), primary: true, onClick: () => { dlgClose(); location.hash = '#/scan'; } }]);
    } catch (e) {
      Dlg.running = false;
      fail(akzErr(e)); send.disabled = false; close.disabled = false; reason.disabled = false; bis.disabled = false; send.textContent = t('akz.knopf');
    }
  };
  const fnd = datei ? null : findingByCheck(norm(tg.check));
  dlgOpen(datei ? t('akz.titelDatei') : t('akz.titelBefund'), [
    h('p', null, (datei ? t('akz.lblDatei') : t('akz.lblPruefung')) + ' ', h('b', { class: datei ? 'mono' : null, text: datei ? tg.pfad : (fnd ? chkName(fnd) : tg.check) })),
    h('p', { class: 'muted', text: datei ? t('akz.gilltDatei', tg.sha256 || t('akz.unbekannt')) : t('akz.gilltBefund') }),
    datei ? null : h('p', { class: 'muted', text: t('akz.zahlenHinweis') }),
    h('label', null, t('akz.lblBegr') + ' ', count, h('br'), reason),
    h('label', null, t('akz.lblBis') + ' ', bis),
    msg, h('div', { class: 'note', text: t('akz.windowsFragtDanach') })],
  []);
  $('#dlg-buttons').replaceChildren(close, send); reason.focus();
}
// Defender-Einzelscan einer Datei aus der Sigcheck-Tabelle
function startDefenderDatei(pfad) {
  const title = t('defd.titel');
  dlgOpen(title, [
    h('p', null, t('defd.text')), h('p', { class: 'mono', text: pfad }),
    h('div', { class: 'note', text: t('defd.note') })],
  [{ label: t('btn.abbrechen'), onClick: dlgClose }, { label: t('btn.starten'), primary: true, onClick: () => runDefenderDatei(pfad, title) }]);
}
async function runDefenderDatei(pfad, title) {
  const jv = jobView([[t('def.step.win'), re(t('def.re.win'))], [t('def.step.pruefenDatei'), re(t('def.re.pruefenDatei'))], [t('def.step.funde'), re(t('def.re.fundeDatei'))]]);
  dlgOpen(title, jv.nodes, [{ label: t('btn.laeuft'), disabled: true }], { lock: true });
  let job = null, err = null;
  try {
    jv.lines([t('win.bestaetigen')]);
    const r = await api('/api/defender/datei', { method: 'POST', body: { bericht: S.cur + '.json', pfad } });
    job = await followJob(r.jobId, jv.lines);
  } catch (e) { err = e; }
  const ok = !err && !!job && job.status === 'done', res = job && job.ergebnis;
  jv.finish(ok);
  const body = [...jv.nodes];
  if (err) body.push(h('p', { class: 'rem', text: err.message }));
  else if (!ok) body.push(h('p', { class: 'rem', text: (res && res.error) || t('run.fehlgeschlagen') }));
  else {
    const funde = [].concat((res && res.funde) || []).filter(Boolean);
    body.push(h('h3', { text: t('run.ergebnis') }), h('p', { class: 'mono', text: pfad }),
      funde.length ? h('ul', { class: 'result' }, funde.map(f => h('li', null, h('b', { text: f.name || t('defd.unbekannt') }), ' ', h('span', { class: 'muted', text: f.zeit ? fmtDate(f.zeit) : '' }), ' ', h('span', { class: f.erfolg === false ? 'rem' : 'warn', text: f.aktion || '' }), f.frueher ? [' ', h('span', { class: 'chip INFO', text: t('defd.frueher') })] : null, f.dateien ? h('div', { class: 'note', text: f.dateien }) : null)))
        : h('p', { class: 'ok', text: t('def.keineFunde') }),
      res && res.meldung ? h('p', { text: res.meldung }) : null);
  }
  dlgOpen(title, body, [{ label: t('btn.fertig'), primary: true, onClick: dlgClose }]);
  Dlg.running = false;
}

// ---------------------------------------------------------------- Ansicht: Werkzeuge (Microsoft Defender)
const ageText = n => n == null || isNaN(n) ? '' : (Number(n) === 0 ? t('zeit.alterHeute') : Number(n) === 1 ? t('zeit.vorTag') : t('zeit.vorTagen', n));
const fmtDur = s => s == null || isNaN(s) ? '' : (s < 60 ? `${s} s` : `${Math.floor(s / 60)} min ${s % 60} s`);
const onOff = v => v === true || /^(true|an|ein|on)$/i.test(String(v)) ? [t('set.an'), 'ok'] : (v === false || /^(false|aus|off)$/i.test(String(v)) ? [t('set.aus'), 'rem'] : [t('allg.unbekannt'), 'muted']);
function defBody(d) {
  const st = d.stand || {}, running = !!d.laufend, lock = readOnly(), dis = lock || running;
  const tt = lock ? lockTitle() : (running ? t('def.laeuftSchon') : null);
  const [rtText, rtCls] = onOff(st.echtzeit);
  const row = (label, ...kids) => h('tr', null, h('td', { class: 'muted', text: label }), h('td', null, ...kids));
  const info = st.fehler ? h('p', { class: 'rem', text: t('def.nichtLesbar', st.fehler) })
    : h('div', { class: 'tablewrap' }, h('table', null, h('tbody', null,
      row(t('def.lblSignaturen'), st.signaturen ? fmtDate(st.signaturen) : '–', st.signaturVersion ? t('def.version', st.signaturVersion) : '', st.signaturAlterTage != null ? h('span', { class: Number(st.signaturAlterTage) > 3 ? 'warn' : 'muted', text: ' · ' + ageText(st.signaturAlterTage) }) : null),
      row(t('def.lblSchnellscan'), st.schnellscan ? fmtDate(st.schnellscan) : t('def.nochNie'), st.schnellscan && st.schnellscanAlterTage != null ? h('span', { class: 'muted', text: ' · ' + ageText(st.schnellscanAlterTage) }) : null),
      row(t('def.lblEchtzeit'), h('span', { class: rtCls, text: rtText })),
      st.modus ? row(t('def.lblModus'), String(st.modus)) : null)));
  return [info,
    running ? h('p', { class: 'warn', text: t('def.laeuftWarte') }) : null,
    h('div', { class: 'toolbar' },
      h('button', { type: 'button', class: 'primary', disabled: dis, title: tt, text: t('def.signaturenAkt'), onclick: () => startDefender('signaturen') }),
      h('button', { type: 'button', class: '', disabled: dis, title: tt, text: t('def.schnellscanStart'), onclick: () => startDefender('schnellscan') }),
      h('button', { type: 'button', class: 'danger', disabled: dis, title: tt, text: t('def.offline'), onclick: startOffline }),
      running ? h('button', { type: 'button', class: 'sm ghost', text: t('btn.anzeigeAkt'), onclick: refreshView }) : null),
    h('p', { class: 'note', text: t('def.funde') })];
}
V.werkzeuge = () => {
  const body = h('div', null, h('p', { class: 'muted', text: t('laedt') }));
  const token = S.rv;
  let defD = null;
  const defKi = () => {
    const st = (defD && defD.stand) || {};
    return kiWerkzeug(t('menu.unter.defender'), t('def.funde'), [
      [t('kf.f.funktionen'), [t('def.signaturenAkt'), t('def.schnellscanStart'), t('def.offline')]],
      [t('kf.f.stand'), st.fehler ? null : [
        t('def.lblSignaturen') + ' ' + (st.signaturAlterTage != null ? ageText(st.signaturAlterTage) : '–'),
        t('def.lblSchnellscan') + ' ' + (st.schnellscan ? (st.schnellscanAlterTage != null ? ageText(st.schnellscanAlterTage) : fmtDate(st.schnellscan)) : t('def.nochNie')),
        t('def.lblEchtzeit') + ' ' + onOff(st.echtzeit)[0]]]]);
  };
  api('/api/defender').then(d => {
    if (token !== S.rv) return;
    defD = d || {};
    body.replaceChildren(...defBody(d || {}).filter(Boolean));
    const o = d && d.offline;
    if (o && o.status === 'countdown' && !$('#modal').classList.contains('on')) openCountdown(o);
  }, e => { if (token === S.rv) body.replaceChildren(h('p', { class: 'rem', text: t('def.ladenFehler', e.message) })); });
  const defCard = h('div', { class: 'card', id: 'def-card' }, kiHead(t('menu.unter.defender'), defKi), body);
  // Einfacher Modus (#103): nur Virenscan und Programm-Updates
  if (S.einfach) return h('section', null, h('h1', { text: t('menu.werkzeuge') }), h('p', { class: 'sub', text: t('modus.wzSub') }),
    readOnly() ? safetyBanner() : null, defCard, updCard(), einfachHinweis());
  return h('section', null, h('h1', { text: t('menu.werkzeuge') }), h('p', { class: 'sub', text: t('wz.sub') }),
    readOnly() ? safetyBanner() : null,
    // Reihenfolge nach Wunsch (2.4): Wartung & Reparatur zuerst
    wartungCard(),
    defCard,
    updCard(),
    sysCard(),
    spOrdnerCard());
};

// Eigene Spiele-Ordner (Abschnitt 14.8). Entwurf in S.spOrdner: [{ plattform, pfad }], bleibt beim Neuzeichnen erhalten.
const SP_PLATT = ['Steam', 'Epic', 'GOG', 'EA', 'Ubisoft', 'Xbox', 'Andere'];
function gotoSpOrdner() {
  closeSpPop(false);
  S.ui.focusSpOrdner = true;
  if (location.hash === '#/werkzeuge') renderView(true); else location.hash = '#/werkzeuge';
}
function spOrdnerCard() {
  const ro = readOnly(), tt = ro ? lockTitle() : null;
  const card = h('div', { class: 'card', id: 'spo-card' });
  const token = S.rv;
  const draw = () => {
    if (token !== S.rv) return;
    const busy = !!S.spoJob, dis = ro || busy;
    const list = S.spOrdner;
    const kids = [kiHead(t('spo.titel'), () => kiWerkzeug(t('spo.titel'), t('spo.note'), [])),
      h('p', { class: 'note', text: t('spo.note') })];
    if (!list) {
      kids.push(S.spoMsg && S.spoMsg.err ? h('p', { class: 'rem', text: S.spoMsg.err }) : h('p', { class: 'muted', text: t('laedt') }));
    } else {
      list.forEach((e, i) => {
        kids.push(h('div', { class: 'spo-row' },
          h('select', { 'aria-label': t('spo.plattformAria'), disabled: dis, title: tt, onchange: ev => { e.plattform = ev.target.value; } },
            SP_PLATT.map(p => h('option', { value: p, text: tk('spo.platt.' + p, p), selected: p === e.plattform }))),
          h('input', { type: 'text', 'aria-label': t('spo.pfadAria'), placeholder: t('spo.platzhalter'), spellcheck: 'false', autocomplete: 'off', maxlength: '260', value: e.pfad || '', disabled: dis, title: tt, oninput: ev => { e.pfad = ev.target.value; } }),
          h('button', { type: 'button', class: 'sm', disabled: dis, title: tt, text: t('btn.entfernen'), onclick: () => { list.splice(i, 1); draw(); } })));
      });
      if (!list.length) kids.push(h('p', { class: 'muted', text: t('spo.keine') }));
      kids.push(h('div', { class: 'toolbar' },
        h('button', { type: 'button', class: '', disabled: dis || list.length >= 50, title: tt, text: t('spo.hinzu'), onclick: () => { list.push({ plattform: 'Andere', pfad: '' }); draw(); } }),
        h('button', { type: 'button', class: 'primary', disabled: dis, title: tt, text: t('btn.speichern'), onclick: save })));
      const m = S.spoMsg;
      if (m && m.err) kids.push(h('p', { class: 'rem', role: 'alert', text: m.err }));
      if (m && m.saved) kids.push(h('div', { class: 'toolbar' },
        h('span', { class: 'note', text: t('spo.gespeichert') }),
        h('button', { type: 'button', class: 'sm', disabled: dis, title: tt, text: t('spo.neuBerechnen'), onclick: recalc })));
      if (busy) kids.push(h('div', { class: 'note', 'aria-live': 'polite', text: S.spoJob.line }));
    }
    card.replaceChildren(...kids);
  };
  const save = async () => {
    if (ro || S.spoJob) return;
    const eintraege = S.spOrdner.map(e => ({ plattform: e.plattform, pfad: String(e.pfad || '').trim() })).filter(e => e.pfad);
    try {
      const r = await api('/api/spielordner', { method: 'POST', body: { eintraege } });
      S.spOrdner = Array.isArray(r) ? r.map(e => ({ plattform: e.plattform, pfad: e.pfad })) : eintraege;
      S.spoMsg = { saved: true };
    } catch (e) { S.spoMsg = { err: e.message }; }
    draw();
  };
  const recalc = async () => {
    if (ro || S.spoJob || S.spJob) return;
    S.spoJob = { line: t('spo.startet') }; draw();
    try {
      await startSpeicherRefresh(l => { if (S.spoJob) { S.spoJob.line = l; draw(); } });
      toast(t('spo.toastNeu'));
    } catch (e) { toast(e.message); }
    S.spoJob = null; draw();
  };
  if (S.spOrdner) draw();
  else {
    S.spoMsg = null; draw();
    api('/api/spielordner').then(d => {
      S.spOrdner = (Array.isArray(d) ? d : []).map(e => ({ plattform: e.plattform, pfad: e.pfad }));
      draw();
    }, e => { S.spoMsg = { err: t('spo.ladenFehler', e.message) }; draw(); });
  }
  if (S.ui.focusSpOrdner) {
    S.ui.focusSpOrdner = false;
    setTimeout(() => { if (card.isConnected) card.scrollIntoView({ block: 'start', behavior: 'smooth' }); }, 50);
  }
  return card;
}

// ---------------------------------------------------------------- Sysinternals (Abschnitt 15)
function sysCard() {
  const body = h('div', null, h('p', { class: 'muted', text: t('laedt') }));
  const token = S.rv;
  const load = () => api('/api/sysinternals').then(d => {
    if (token !== S.rv) return;
    S.sys = d || {};
    const prog = h('p', { class: 'note', 'aria-live': 'polite' });
    body.replaceChildren(...sysBody(S.sys, prog).filter(Boolean));
    if (S.sys.laufend && !S.sys.fehler) {
      followJob(S.sys.laufend, l => { if (token === S.rv && l.length) prog.textContent = l[l.length - 1]; }).then(() => { if (token === S.rv) load(); }, () => { /* Anzeige bleibt */ });
    }
  }, e => { if (token === S.rv) body.replaceChildren(h('p', { class: 'rem', text: t('sys.ladenFehler', e.message) })); });
  load();
  const sysKi = () => kiWerkzeug(t('sys.titel'), t('sys.kostenlos'), [
    [t('kf.f.funktionen'), ((S.sys && Array.isArray(S.sys.werkzeuge)) ? S.sys.werkzeuge : []).map(w => [w.titel || w.name, tk('sys.info.' + w.name, '')].filter(Boolean).join(': '))],
    [t('kf.f.hinweis'), t('sys.ergebnisse')]]);
  return h('div', { class: 'card', id: 'sys-card' }, kiHead(t('sys.titel'), sysKi), body);
}
function sysBody(d, prog) {
  if (d.fehler) return [h('p', { class: 'rem', text: t('sys.nichtLesbar', d.fehler) })];
  const ro = readOnly(), running = !!d.laufend, dis = ro || running;
  const tt = ro ? lockTitle() : (running ? t('sys.laeuftSchon') : null);
  const ws = Array.isArray(d.werkzeuge) ? d.werkzeuge : [];
  const da = ws.some(w => w.vorhanden);
  const z = d.zustimmung || {};
  const state = w => {
    if (w.vorhanden && w.geprueft) return h('span', { class: 'ok', text: t('sys.signiertVon', w.signierer || 'Microsoft Corporation', w.version ? t('sys.version', w.version) : '', w.geladen ? t('sys.geladenAm', fmtDate(w.geladen)) : '') });
    if (w.vorhanden) return h('span', { class: 'rem', text: '✗ ' + (w.grund || t('sys.pruefungFehl')) });
    return h('span', { class: 'muted', text: t('sys.nichtEingerichtet') });
  };
  const row = w => h('tr', null,
    h('td', null, h('b', { text: w.titel || w.name }), h('div', { class: 'note', text: tk('sys.info.' + w.name, '') })),
    h('td', null, state(w)));
  return [
    h('p', { class: 'note', text: t('sys.kostenlos') }),
    ws.length ? h('div', { class: 'tablewrap' }, h('table', null, h('tbody', null, ws.map(row)))) : h('p', { class: 'muted', text: t('sys.keineAngaben') }),
    h('p', { class: z.akzeptiert ? 'note' : 'muted', text: z.akzeptiert ? t('sys.lizenzAngenommen', z.zeit ? fmtDate(z.zeit) : '?', z.benutzer ? ' (' + z.benutzer + ')' : '') : t('sys.lizenzNein') }),
    running ? h('p', { class: 'warn', text: t('sys.laeuftWarte') }) : null,
    running ? prog : null,
    ro ? h('p', { class: 'note', text: lockTitle() }) : null,
    h('div', { class: 'toolbar' },
      h('button', { type: 'button', class: 'primary', disabled: dis, title: tt, text: da ? t('sys.neuLaden') : t('sys.laden'), onclick: () => sysInstallDlg(d) }),
      da ? h('button', { type: 'button', class: '', text: t('sys.lizenztext'), onclick: () => sysEulaDlg(ws) }) : null,
      (da || z.akzeptiert) ? h('button', { type: 'button', class: 'danger', disabled: dis, title: tt, text: da ? t('sys.entfernen') : t('sys.zustimmungZurueck'), onclick: () => sysRemoveDlg() }) : null,
      running ? h('button', { type: 'button', class: 'sm ghost', text: t('btn.anzeigeAkt'), onclick: refreshView }) : null),
    h('p', { class: 'note', text: t('sys.ergebnisse') })];
}
/** Fehlertext für 403/409 verständlich machen. */
function sysErr(e) {
  if (e && e.status === 403) return t('err.abgelehnt', e.message);
  if (e && e.status === 409) return t('sys.err409', e.message);
  return (e && e.message) || t('run.fehlgeschlagen');
}
function sysInstallDlg(d) {
  const url = /^https:\/\//.test(String(d.lizenzUrl || '')) ? d.lizenzUrl : 'https://learn.microsoft.com/sysinternals/license-terms';
  const ordner = d.ordner || 'C:\\ProgramData\\Morpheus\\tools';
  const da = (d.werkzeuge || []).some(w => w.vorhanden);
  const title = da ? t('sys.dlTitelNeu') : t('sys.dlTitel');
  let wb = null;
  const chk = h('input', { type: 'checkbox', id: 'sys-ok', onchange: () => { if (wb) wb.disabled = !chk.checked; } });
  dlgOpen(title, [
    h('p', { text: t('sys.dlText') }),
    h('ul', null,
      h('li', { text: t('sys.dlL1') }),
      h('li', { text: t('sys.dlL2', ordner) }),
      h('li', { text: t('sys.dlL3') }),
      h('li', { text: t('sys.dlL4') })),
    h('h3', { text: t('sys.lizKurz') }),
    h('p', { text: t('sys.lizText') }),
    h('p', null, h('a', { href: url, target: '_blank', rel: 'noopener noreferrer', text: t('sys.lizLesen') })),
    h('label', { class: 'chk' }, chk, t('sys.lizChk')),
    h('div', { class: 'note', text: t('akz.windowsFragtDanach') })],
  [{ label: t('btn.abbrechen'), onClick: dlgClose }, { label: t('sys.dlKnopf'), primary: true, disabled: true, onClick: () => runSysInstall(title) }]);
  wb = $('#dlg-buttons').lastElementChild;
}
async function runSysInstall(title) {
  const jv = jobView([[t('def.step.win'), re(t('def.re.win'))], [t('sys.step.autoruns'), /autoruns/i], [t('sys.step.sigcheck'), /sigcheck/i]]);
  dlgOpen(title, jv.nodes, [{ label: t('btn.laeuft'), disabled: true }], { lock: true });
  let job = null, err = null;
  try {
    jv.lines([t('win.bestaetigen')]);
    const r = await api('/api/sysinternals/install', { method: 'POST', body: { eulaAkzeptiert: true } });
    job = await followJob(r.jobId, jv.lines);
  } catch (e) { err = e; }
  const ok = !err && !!job && job.status === 'done', res = job && job.ergebnis;
  jv.finish(ok);
  const body = [...jv.nodes];
  if (err) body.push(h('p', { class: 'rem', text: sysErr(err) }));
  else if (!ok) body.push(h('p', { class: 'rem', text: (res && res.error) || (job && job.error) || t('run.fehlgeschlagen') }));
  else if (res) body.push(sysResult(res));
  dlgOpen(title, body, [{ label: t('btn.fertig'), primary: true, onClick: dlgClose }]);
  Dlg.running = false;
  if (S.view === 'werkzeuge') refreshView();
}
function sysResult(res) {
  const ws = [].concat(res.werkzeuge || []).filter(Boolean);
  return h('div', null, h('h3', { text: t('run.ergebnis') }),
    ws.length ? h('ul', { class: 'result' }, ws.map(w => h('li', null, h('b', { text: w.titel || w.name }), ' ',
      w.vorhanden && w.geprueft ? h('span', { class: 'ok', text: t('sys.signiertKurz', w.signierer || 'Microsoft Corporation', w.version ? t('sys.version', w.version) : '') }) : h('span', { class: 'rem', text: w.grund || t('sys.nichtEingerichtet') })))) : null,
    res.meldung ? h('p', { text: res.meldung }) : null);
}
async function sysEulaDlg(ws) {
  const names = ws.map(w => ({ name: w.name, titel: w.titel || w.name })).filter(w => w.name);
  const pre = h('pre', { class: 'log eula', tabindex: '0', 'aria-live': 'polite', text: t('laedt') });
  const tabs = h('div', { class: 'toolbar' });
  const show = async n => {
    [...tabs.children].forEach((b, i) => b.classList.toggle('primary', names[i].name === n.name));
    pre.textContent = t('laedt');
    try {
      const r = await api('/api/sysinternals/eula?name=' + encodeURIComponent(n.name));
      pre.textContent = r && typeof r.text === 'string' && r.text ? r.text : t('sys.eulaFehlt');
    } catch (e) { pre.textContent = e.message; }
  };
  names.forEach(n => tabs.append(h('button', { type: 'button', class: 'sm', text: n.titel, onclick: () => show(n) })));
  dlgOpen(t('sys.eulaTitel'), [tabs, pre], [{ label: t('btn.schliessen'), primary: true, onClick: dlgClose }]);
  if (names.length) show(names[0]); else pre.textContent = t('sys.eulaFehlt');
}
function sysRemoveDlg() {
  dlgOpen(t('sys.rmTitel'), [
    h('p', { text: t('sys.rmText') }),
    h('div', { class: 'note', text: t('sys.rmNote') })],
  [{ label: t('btn.abbrechen'), onClick: dlgClose }, { label: t('btn.entfernen'), danger: true, onClick: goSysRemove }]);
}
async function goSysRemove() {
  const title = t('sys.rmTitel');
  dlgOpen(title, [h('p', { text: t('win.bestaetigen') })], [{ label: t('btn.wartet'), disabled: true }], { lock: true });
  try {
    await api('/api/sysinternals/entfernen', { method: 'POST' });
    dlgOpen(title, [h('p', { class: 'ok', text: t('sys.rmFertig') })], [{ label: t('btn.fertig'), primary: true, onClick: dlgClose }]);
  } catch (e) {
    dlgOpen(title, [h('p', { class: 'rem', text: sysErr(e) })], [{ label: t('btn.schliessen'), primary: true, onClick: dlgClose }]);
  }
  Dlg.running = false;
  if (S.view === 'werkzeuge') refreshView();
}

// Defender-Aufgabe (Signaturen, Schnellscan): Bestätigung in der GUI, dann Windows-Bestätigung, dann Job
function startDefender(art) {
  const sig = art === 'signaturen', title = sig ? t('def.signaturenAkt') : t('def.schnellscanStart');
  dlgOpen(title, [
    h('p', { text: sig ? t('def.dlgSig') : t('def.dlgScan') }),
    h('div', { class: 'note', text: t('def.dlgNote') })],
  [{ label: t('btn.abbrechen'), onClick: dlgClose }, { label: t('btn.starten'), primary: true, onClick: () => runDefender(art, title) }]);
}
async function runDefender(art, title) {
  const jv = jobView([[t('def.step.win'), re(t('def.re.win'))], [t('def.step.standLesen'), re(t('def.re.standVorher'))], [art === 'signaturen' ? t('def.signaturenAkt') : t('def.step.schnellscan'), re(t('def.re.laeuft'))], [t('def.step.standPruefen'), re(t('def.re.standNachher'))], [t('def.step.funde'), re(t('def.re.fundeSeit'))]]);
  dlgOpen(title, jv.nodes, [{ label: t('btn.laeuft'), disabled: true }], { lock: true });
  let job = null, err = null;
  try {
    jv.lines([t('win.bestaetigen')]);
    const r = await api('/api/defender/run', { method: 'POST', body: { art } });
    job = await followJob(r.jobId, jv.lines);
  } catch (e) { err = e; }
  const ok = !err && !!job && job.status === 'done', res = job && job.ergebnis;
  jv.finish(ok);
  const body = [...jv.nodes];
  if (err) body.push(h('p', { class: 'rem', text: err.message }));
  else if (!ok) body.push(h('p', { class: 'rem', text: (res && res.error) || t('run.fehlgeschlagen') }));
  else if (res) body.push(defResult(res));
  dlgOpen(title, body, [{ label: t('btn.fertig'), primary: true, onClick: dlgClose }]);
  Dlg.running = false;
  if (S.view === 'werkzeuge') refreshView();
}
function defResult(res) {
  const v = res.vorher || {}, n = res.nachher || {}, funde = [].concat(res.funde || []).filter(Boolean);
  const cell = (st, k) => st.fehler ? t('def.nichtLesbarZelle') : (k === 'signaturVersion' ? (st[k] || '–') : (st[k] ? fmtDate(st[k]) : (k === 'schnellscan' ? t('def.nochNie') : '–')));
  const row = (label, k) => h('tr', null, h('td', { text: label }), h('td', { text: cell(v, k) }), h('td', { text: cell(n, k) }));
  return h('div', null, h('h3', { text: t('run.ergebnis') }),
    h('div', { class: 'tablewrap' }, h('table', null, h('thead', null, h('tr', null, ['', t('def.hVorher'), t('def.hNachher')].map(x => h('th', { text: x })))),
      h('tbody', null, row(t('def.lblSignaturenVom'), 'signaturen'), row(t('def.lblSigVersion'), 'signaturVersion'), row(t('def.lblSchnellscan'), 'schnellscan')))),
    h('h3', { text: t('def.fundeTitel') }),
    funde.length ? h('ul', { class: 'result' }, funde.map(f => h('li', null, h('b', { text: f.name || t('defd.unbekannt') }), ' ', h('span', { class: 'muted', text: f.zeit ? fmtDate(f.zeit) : '' }), ' ', h('span', { class: f.erfolg === false ? 'rem' : 'warn', text: f.aktion || '' }),
      f.dateien ? h('div', { class: 'note', text: f.dateien }) : null))) : h('p', { class: 'ok', text: t('def.keineFunde') }),
    res.meldung ? h('p', { text: res.meldung }) : null,
    res.dauerSek != null ? h('div', { class: 'note', text: t('def.dauer', fmtDur(res.dauerSek)) }) : null);
}

// Offline-Scan: Warnung mit Häkchen, Windows-Bestätigung, dann Countdown (läuft im Server; die GUI zeigt nur an und meldet sich jede Sekunde)
function startOffline() {
  let wb = null;
  const chk = h('input', { type: 'checkbox', id: 'off-ok', onchange: () => { if (wb) wb.disabled = !chk.checked; } });
  dlgOpen(t('off.titel'), [
    h('p', { class: 'warn', text: t('off.warn') }),
    h('label', { class: 'chk' }, chk, t('off.chk'))],
  [{ label: t('btn.abbrechen'), onClick: dlgClose }, { label: t('btn.weiter'), danger: true, disabled: true, onClick: goOffline }]);
  wb = $('#dlg-buttons').lastElementChild;
}
async function goOffline() {
  const title = t('off.titel');
  dlgOpen(title, [h('p', { text: t('win.bestaetigen') })], [{ label: t('btn.wartet'), disabled: true }], { lock: true });
  try {
    const st = await api('/api/defender/offline', { method: 'POST', body: { bestaetigt: true } });
    openCountdown(st);
  } catch (e) {
    dlgOpen(title, [h('p', { class: 'rem', text: e.message })], [{ label: t('btn.schliessen'), primary: true, onClick: dlgClose }]);
  }
}
function openCountdown(st0) {
  const title = t('off.titel');
  const ctl = { alive: true, done: false, busy: false, fails: 0 };
  const num = h('div', { class: 'cd-num', 'aria-hidden': 'true' }), txt = h('p', { class: 'cd-txt', role: 'timer', 'aria-live': 'off' }), msg = h('p', { class: 'note' });
  const setRest = r => { const n = Math.max(0, Math.round(Number(r) || 0)); num.textContent = String(n); txt.textContent = n === 1 ? t('off.restEins', n) : t('off.restN', n); };
  const btns = () => [...$('#dlg-buttons').children];
  const finish = s => {
    if (ctl.done) return; ctl.done = ctl.alive = false;
    const started = s.status === 'gestartet';
    dlgOpen(title, [h('p', { class: s.status === 'fehler' ? 'rem' : (started ? 'warn' : ''), text: started ? t('off.startetJetzt') : (s.meldung || (s.status === 'abgebrochen' ? t('off.abgebrochen') : t('off.beendet'))) }), started && s.meldung ? h('p', { class: 'note', text: s.meldung }) : null],
      [{ label: t('btn.schliessen'), primary: true, onClick: dlgClose }]);
  };
  const act = async path => {
    if (ctl.busy || ctl.done) return;
    ctl.busy = true; btns().forEach(b => { b.disabled = true; });
    try {
      const s = await api('/api/defender/offline/' + path, { method: 'POST' });
      if (s.status === 'countdown') { setRest(s.rest); msg.textContent = ''; btns().forEach(b => { b.disabled = false; }); } else finish(s);
    } catch (e) { msg.textContent = e.message; btns().forEach(b => { b.disabled = false; }); }
    ctl.busy = false;
  };
  const cancel = () => act('abbrechen'), now = () => act('jetzt');
  setRest(st0.rest);
  dlgOpen(title, [h('p', { class: 'warn', text: t('off.speichere') }), num, txt, msg],
    [{ label: t('btn.abbrechen'), primary: true, onClick: cancel }, { label: t('off.jetzt'), danger: true, onClick: now }], { onEsc: cancel, onClose: () => { ctl.alive = false; } });
  (async () => {   // genau eine Abfrage pro Sekunde, nie überlappend
    while (ctl.alive) {
      const t0 = Date.now();
      try {
        const s = await api('/api/defender/offline');
        if (!ctl.alive) break;
        ctl.fails = 0;
        if (s.status === 'countdown') { if (!ctl.busy) msg.textContent = ''; setRest(s.rest); } else { finish(s); break; }
      } catch (e) {
        if (e.status === 401) break;
        if (++ctl.fails >= 2 && !ctl.busy) msg.textContent = t('off.keineVerbindung');
      }
      await sleep(Math.max(0, 1000 - (Date.now() - t0)));
    }
  })();
}

// ---------------------------------------------------------------- Wartung & Reparatur, Programme aktualisieren (Abschnitt 18)
let WT_KLASSE = {}, WT_ERG = {}, WT_STATUS = {}, WT_PAKET = {};   // [Status-Farbe, Anzeigetext]; gefüllt von buildTexts()
const UPD_KAT = { 'Programm': 'upd.kat.programm', 'Id gekürzt': 'upd.kat.idGekuerzt', 'Spiel/Launcher': 'upd.kat.spielLauncher', 'aktualisiert sich selbst': 'upd.kat.selbst' };   // winget-Kategorien (Kennung -> Textschlüssel)
const WT_GRUPPEN_OHNE = ['Wiederherstellung', 'Programme'];
const WT_PUNKT_ID = 'wiederherstellung.punkt', WT_WINGET_ID = 'winget.upgrade';
const WT = new Map();          // jobId -> Verfolger eines laufenden Wartungs- bzw. Update-Jobs (bleibt auch ohne Dialog aktiv)
const WT_SEARCH = new Map();   // jobId -> Verfolger einer Update-Suche
S.wt = { tools: [], sel: new Set(), report: null, scrollReport: false };

const klasseChip = k => { const c = WT_KLASSE[k] || ['INFO', String(k || '')]; return h('span', { class: 'chip ' + c[0], text: c[1] }); };
const wtChip = (tab, key, fallback) => { const c = tab[key]; return h('span', { class: 'chip ' + (c ? c[0] : 'INFO'), text: c ? c[1] : (fallback || String(key || '')) }); };
const wtErr = e => e && e.status === 403 ? t('err.abgelehnt', e.message) : ((e && e.message) || t('run.fehlgeschlagen'));
/** Werkzeug aus dem zuletzt geladenen Katalog (mit Rückfall für winget und den Wiederherstellungspunkt). */
function wtTool(id) {
  const w = (S.wt.tools || []).find(x => x.id === id);
  if (w) return w;
  if (id === WT_WINGET_ID) return { id, titel: t('wt.winget.titel'), klasse: 'reparatur', punkt: true, abbruch: 'nach-paket', befehl: 'winget upgrade --id <Paket-Id> --exact --source winget --silent' };
  if (id === WT_PUNKT_ID) return { id, titel: t('wt.punkt.titel'), erklaerung: t('wt.punkt.erkl'), klasse: 'wartung', punkt: false, abbruch: 'nein', dauer: t('wt.punkt.dauer'), befehl: "Checkpoint-Computer -Description 'Morpheus: von Hand angelegt' -RestorePointType MODIFY_SETTINGS" };
  return { id, titel: String(id || t('wt.fallbackTitel')), klasse: 'wartung', punkt: false, abbruch: 'nein' };
}
function wtCfg(id, abbruch) {
  const w = wtTool(id), winget = id === WT_WINGET_ID;
  return { w, title: winget ? t('menu.unter.updates') : w.titel, winget, punkt: !!w.punkt || winget || id === WT_PUNKT_ID, abbruch: abbruch || w.abbruch || 'nein' };
}
function wtSteps(cfg) {
  const st = [[t('def.step.win'), re(t('def.re.win'))]];
  if (cfg.punkt) st.push([t('wt.step.punkt'), re(t('wt.re.punkt'))]);
  if (cfg.w.id !== WT_PUNKT_ID) st.push([cfg.winget ? t('wt.step.winget') : t('wt.step.laeuft'), new RegExp(t('wt.re.start'))]);
  // winget: nur die Abschlusszeile „<ok> von <n> Programmen erledigt …“ (jedes Paket meldet auch „Ergebnis: <Name>: …“)
  st.push([t('wt.step.ergebnis'), new RegExp(cfg.winget ? t('wt.re.ergebnisWinget') : t('wt.re.ergebnis'))]);
  return st;
}
const wtBefehl = (w, lw) => String(w.befehl || '').replace(/<LW>/g, lw || '<LW>');

/** Verfolger für einen Job anlegen (oder den vorhandenen liefern). Läuft bis zum Ende, auch wenn kein Dialog offen ist. */
function wtCtl(jobId, cfg) {
  let c = WT.get(jobId);
  if (c) return c;
  c = { jobId, cfg, jv: jobView(wtSteps(cfg)), bg: true, done: false, cancelling: false, job: null, err: null };
  c.jv.lines([t('wt.erteilt')]);
  WT.set(jobId, c);
  followJob(jobId, c.jv.lines).then(j => { c.job = j; }, e => { c.err = e; }).then(() => wtDone(c));
  return c;
}
function wtShow(c) {
  c.bg = false;
  if (c.done) { wtResultDlg(c); return; }
  const btns = [];
  if (c.cfg.abbruch !== 'nein') btns.push({ label: c.cancelling ? t('wt.abbruchAngefordert') : (c.cfg.winget ? t('wt.nachAktuellem') : t('btn.abbrechen')), disabled: c.cancelling, onClick: ev => wtCancel(c, ev.currentTarget) });
  btns.push({ label: t('wt.hintergrund'), onClick: () => wtBackground(c) });
  dlgOpen(c.cfg.title, [...c.jv.nodes, c.cfg.abbruch === 'nein' ? h('div', { class: 'note', text: t('wt.nichtAbbrechbar') }) : null], btns, { lock: true });
}
function wtBackground(c) {
  c.bg = true; dlgClose();
  if (S.view === 'werkzeuge') refreshView();
}
async function wtCancel(c, btn) {
  if (c.cancelling) return;
  c.cancelling = true; btn.disabled = true; btn.textContent = t('wt.abbruchAngefordert');
  try {
    const r = await api('/api/wartung/abbrechen', { method: 'POST', body: { jobId: c.jobId } });
    if (r && r.meldung) toast(r.meldung);
  } catch (e) { c.cancelling = false; btn.disabled = false; btn.textContent = c.cfg.winget ? t('wt.nachAktuellem') : t('btn.abbrechen'); toast(e.message); }
}
function wtDone(c) {
  c.done = true; WT.delete(c.jobId);
  loadSession().catch(() => {});
  if (c.cfg.winget) S.wt.sel.clear();
  const res = c.job && c.job.ergebnis;
  // Ids des gescheiterten winget-Laufs merken: ohne Punkt verlangt der Server genau diese Menge
  if (c.cfg.winget) {
    if (res && res.status === 'punkt-fehlt') S.wt.punktIds = c.cfg.ids || [].concat(res.pakete || []).filter(Boolean).map(p => p.id).filter(Boolean);
    else if (res && res.status) S.wt.punktIds = null;
  }
  if (c.bg) {
    const pf = res && res.status === 'punkt-fehlt';
    const st = c.err ? c.err.message : (res && res.status ? (WT_STATUS[res.status] || (pf ? t('wt.punktFehltToast') : res.status)) : (c.job && c.job.status === 'failed' ? t('jr.s.fehlgeschlagen') : t('wt.fertig')));
    toast(t('wt.toast', c.cfg.title, st));
  } else wtResultDlg(c);
  if (S.view === 'werkzeuge') refreshView();
}

/** Start: Windows-Bestätigung abwarten, dann dem Job im Dialog folgen. post(ohnePunkt) liefert { jobId }. */
async function wtRun(cfg, post, ohnePunkt) {
  dlgOpen(cfg.title, [h('p', { text: t('win.bestaetigen') }), h('div', { class: 'note', text: t('wt.danachArbeit') })], [{ label: t('btn.wartet'), disabled: true }], { lock: true });
  let r;
  try { r = await post(!!ohnePunkt); }
  catch (e) {
    dlgOpen(cfg.title, [h('p', { class: 'rem', text: wtErr(e) })], [{ label: t('btn.schliessen'), primary: true, onClick: dlgClose }]);
    if (S.view === 'werkzeuge') refreshView();
    return;
  }
  // Ohne Wiederherstellungspunkt gibt es den Schritt nicht; er soll nicht als erledigt erscheinen
  const c = wtCtl(r.jobId, ohnePunkt ? { ...cfg, punkt: false } : cfg);
  c.cfg.post = post;
  wtShow(c);
  if (S.view === 'werkzeuge') refreshView();
}
const wtPostWinget = ids => ohne => api('/api/updates/installieren', { method: 'POST', body: { ids, ...(ohne ? { ohnePunkt: true } : {}) } });
const wtPostStart = (w, lw) => ohne => api('/api/wartung/start', { method: 'POST', body: { werkzeug: w.id, ...(lw ? { laufwerk: lw } : {}), ...(ohne ? { ohnePunkt: true } : {}) } });

function wtStartDlg(w, lw) {
  const cfg = wtCfg(w.id), cmd = wtBefehl(w, lw);
  const body = [
    w.erklaerung ? h('p', { text: w.erklaerung }) : null,
    h('p', null, klasseChip(w.klasse), w.dauer ? [' ', h('span', { class: 'wt-dur', text: t('wt.dauer', w.dauer) })] : null, lw ? [' ', h('span', { class: 'wt-dur', text: t('wt.laufwerk', lw) })] : null),
    cmdBlock(cmd, true, /^Checkpoint-Computer/.test(cmd) ? t('cmd.psAdmin') : t('cmd.cmdAdmin')),
    w.klasse === 'reparatur' ? h('div', { class: 'wt-box', role: 'note' }, h('b', { text: t('wt.nichtUmkehrbar') }), t('wt.nichtUmkehrbarText')) : null,
    w.internet ? h('p', { class: 'note', text: t('wt.internetNote') }) : null,
    w.hinweis ? h('p', { class: 'note', text: w.hinweis }) : null,
    h('div', { class: 'note', text: t('win.fragtVorher') })];
  dlgOpen(w.titel, body, [{ label: t('btn.abbrechen'), onClick: dlgClose }, { label: t('btn.starten'), primary: true, onClick: () => wtRun(cfg, wtPostStart(w, lw)) }]);
}

function wtResultNodes(res, cfg) {
  const z = res.zusammenfassung || {}, kids = [h('h3', { text: t('run.ergebnis') })];
  kids.push(h('p', { class: 'wt-res' }, h('b', { text: WT_STATUS[res.status] || res.status || '' }), z.ergebnis ? [' ', wtChip(WT_ERG, z.ergebnis)] : null,
    res.ohnePunkt ? [' ', h('span', { class: 'chip WARN', text: t('jr.ohnePunkt') })] : null));
  if (z.text) kids.push(h('p', { text: z.text }));
  if (z.empfehlung) kids.push(h('p', null, h('b', { text: t('wt.empfehlung') }), z.empfehlung));
  const det = [].concat(z.details || []).filter(Boolean);
  if (det.length) kids.push(h('ul', { class: 'explain' }, det.map(x => h('li', { text: String(x) }))));
  const pk = [].concat(res.pakete || []).filter(Boolean);
  if (pk.length) kids.push(h('div', { class: 'tbl-scroll wt-upd' }, h('table', null,
    h('thead', null, h('tr', null, [t('wt.hProgramm'), t('wt.hVon'), t('wt.hAuf'), t('run.ergebnis')].map(x => h('th', { text: x })))),
    h('tbody', null, pk.map(p => h('tr', null, h('td', { text: p.name || p.id }), h('td', { text: p.von || '' }), h('td', { text: p.auf || '' }),
      h('td', null, wtChip(WT_PAKET, p.status), p.text ? h('div', { class: 'note', text: p.text }) : null)))))));
  const meta = [];
  if (res.dauerSek != null) meta.push(t('jr.dauer', fmtDur(res.dauerSek)));
  if (res.exitCode != null) meta.push(t('jr.exit', res.exitCode));
  if (meta.length) kids.push(h('p', { class: 'note', text: meta.join(' · ') }));
  if (res.punkt && res.punkt.seq != null) kids.push(h('p', { class: 'note' }, tn('jr.punktNr', h('code', { text: '#' + res.punkt.seq })), res.punkt.zeit ? ` (${fmtDate(res.punkt.zeit)})` : ''));
  if (res.meldung) kids.push(h('p', { class: 'note wt-msg', text: res.meldung }));
  if (res.status !== 'punkt-fehlt') kids.push(h('p', { class: 'note', text: t('wt.imProtokoll') }));
  return kids;
}
function wtResultDlg(c) {
  const job = c.job, err = c.err, res = job && job.ergebnis, cfg = c.cfg;
  if (res && res.status === 'punkt-fehlt') { c.jv.finish(false); wtPunktFehlt(c, res); return; }
  const ok = !err && !!res && !res.error && res.status === 'erledigt';
  c.jv.finish(ok);
  const body = [...c.jv.nodes];
  if (err) body.push(h('p', { class: 'rem', text: err.message }));
  else if (!res || res.error || !res.status) body.push(h('p', { class: 'rem', text: (res && res.error) || t('run.fehlgeschlagen') }));
  else body.push(...wtResultNodes(res, cfg));
  // 2.5 (#67, G3): winget lief ohne Adminrechte
  if (res && res.benutzerkontext) body.push(h('p', null, h('span', { class: 'chip OK', text: t('wt.ohneAdmin') }), ' ' + t('wt.benutzerkontext')));
  const btns = [];
  if (res && res.bericht) btns.push({ label: t('wt.berichtOeffnen'), onClick: () => wtOpenReport(res.bericht) });
  if (cfg.winget) btns.push({ label: t('wt.erneutSuchen'), onClick: () => { dlgClose(); updSuchen(); } });
  btns.push({ label: t('btn.fertig'), primary: true, onClick: dlgClose });
  dlgOpen(cfg.title, body, btns);
  Dlg.running = false;
}
function wtPunktFehlt(c, res) {
  const cfg = c.cfg;
  let wb = null;
  const chk = h('input', { type: 'checkbox', onchange: () => { if (wb) wb.disabled = !chk.checked; } });
  const ids = cfg.ids || S.wt.punktIds;
  const post = cfg.post || (cfg.winget ? (ids && ids.length ? wtPostWinget(ids) : null) : wtPostStart(cfg.w, null));
  dlgOpen(cfg.title, [
    h('p', { class: 'rem', text: t('wt.pf.nichts') }),
    h('p', { class: 'wt-msg', text: res.meldung || '' }),
    post ? h('label', { class: 'chk' }, chk, t('wt.pf.chk')) : null],
  [{ label: t('btn.schliessen'), primary: true, onClick: dlgClose }, post ? { label: t('wt.pf.knopf'), danger: true, disabled: true, onClick: () => wtRun(cfg, post, true) } : null].filter(Boolean));
  wb = $('#dlg-buttons').lastElementChild;
  if (!post || wb.textContent !== t('wt.pf.knopf')) wb = null;
}

// ---- Berichte (Energie, Akku, Schlafstudie)
function wtReportSrc(name) {
  if (typeof window.PCCHECK_REPORT_SRC === 'function') return Promise.resolve(window.PCCHECK_REPORT_SRC(name));
  return api('/api/report-ticket', { method: 'POST', body: { name } }).then(r => `/report/${name}?k=${encodeURIComponent(r.ticket)}`);
}
function wtViewer(box, list) {
  box.replaceChildren();
  const name = S.wt.report;
  if (!name) return;
  const b = list.find(x => x.name === name), titel = b ? b.titel : name;
  // sandbox ohne allow-same-origin und ohne allow-popups: der Bericht erreicht weder die API noch öffnet er Fenster
  const frame = h('iframe', { class: 'wt-frame', sandbox: 'allow-scripts', title: t('wt.berichtTitel', titel) });
  box.append(h('div', { class: 'wt-report', id: 'wt-report' }, h('div', { class: 'toolbar' }, h('b', { text: titel }),
    h('button', { type: 'button', text: t('btn.schliessen'), onclick: () => { S.wt.report = null; wtViewer(box, list); } })), frame));
  wtReportSrc(name).then(src => { frame.src = src; }, e => { if (frame.isConnected) frame.replaceWith(h('p', { class: 'rem', text: e.message })); });
}
function wtOpenReport(name) {
  S.wt.report = name; S.wt.scrollReport = true;
  dlgClose();
  if (S.view === 'werkzeuge') refreshView(); else location.hash = '#/werkzeuge';
}

// ---- Karte „Wartung & Reparatur“
function wtRow(w, d, dis, tt) {
  const laufw = Array.isArray(d.laufwerke) ? d.laufwerke : [];
  const hp = S.help && (S.help.Wartung || S.help.wartung), help = hp && hp[w.id];
  let sel = null, noLw = null;
  if (w.parameter === 'laufwerk' || w.parameter === 'ssd') {
    const opts = laufw.filter(l => w.parameter === 'laufwerk' || l.ssd === true);
    if (opts.length) sel = h('select', { 'aria-label': t('wt.laufwerkFuer', w.titel) }, opts.map(l => h('option', { value: l.laufwerk, text: l.bezeichnung ? `${l.laufwerk} ${l.bezeichnung}` : l.laufwerk })));
    else noLw = w.parameter === 'ssd' ? t('wt.keineSsd') : t('wt.keineLw');
  }
  const off = dis || !!noLw;
  const step = w.gruppe === 'Systemdateien' && w.schritt ? `${w.schritt}. ` : '';
  let cb = cmdBlock(wtBefehl(w, sel ? sel.value : null), true, t('cmd.cmdAdmin'));
  if (sel) sel.addEventListener('change', () => { const n = cmdBlock(wtBefehl(w, sel.value), true, t('cmd.cmdAdmin')); cb.replaceWith(n); cb = n; });
  const meta = [w.dauer ? t('wt.dauer', w.dauer) : null, w.internet ? t('wt.brauchtInternet') : null].filter(Boolean).join(' · ');
  return h('div', { class: 'wt-row', 'data-id': w.id },
    h('div', { class: 'wt-head' }, h('b', { class: 'wt-title', text: step + w.titel }), klasseChip(w.klasse)),
    w.erklaerung ? h('p', { class: 'wt-expl', text: w.erklaerung }) : null,
    meta ? h('p', { class: 'wt-meta', text: meta }) : null,
    w.hinweis ? h('p', { class: 'wt-meta', text: w.hinweis }) : null,
    noLw ? h('p', { class: 'wt-meta', text: noLw }) : null,
    (d.punktFehlt || []).includes(w.id) ? h('p', { class: 'wt-meta', text: t('wt.pf.letzter') }) : null,
    (d.punktFehlt || []).includes(w.id) && !dis ? h('div', { class: 'wt-acts' }, h('button', { type: 'button', class: 'sm', text: t('wt.pf.knopfPunkte'),
      onclick: () => wtPunktFehlt({ cfg: { ...wtCfg(w.id), post: wtPostStart(w, sel ? sel.value : null) } }, { meldung: t('wt.pf.meldung') }) })) : null,
    help ? h('details', { class: 'cmd' }, h('summary', { text: t('wt.mehr') }),
      h('div', { class: 'wt-help' }, help.Was ? h('p', null, h('b', { text: t('wt.h.was') }), help.Was) : null, help.Wann ? h('p', null, h('b', { text: t('wt.h.wann') }), help.Wann) : null, help.Hinweis ? h('p', null, h('b', { text: t('wt.h.hinweis') }), help.Hinweis) : null)) : null,
    h('details', { class: 'cmd' }, h('summary', { text: t('wt.befehlZeigen') }), cb),
    h('div', { class: 'wt-acts' }, sel, h('button', { type: 'button', class: 'sm' + (w.klasse === 'reparatur' ? '' : ' primary'), disabled: off, title: off ? (noLw && !dis ? noLw : tt) : null, text: t('wt.startenPunkte'), onclick: () => wtStartDlg(w, sel ? sel.value : null) }),
      kiBtn(w.titel, () => kiWartung(w, sel ? sel.value : null))));
}
function wtRestore(d, dis, tt) {
  const sf = d.safety || safety(), w = wtTool(WT_PUNKT_ID);
  const off = dis || sf.schutzAn === false;
  const state = h('div', { class: 'wt-state' },
    h('span', null, t('wt.r.schutz') + ' ', sf.schutzAn === false ? h('span', { class: 'chip CRIT', text: t('set.aus') }) : (sf.schutzAn === true ? h('span', { class: 'chip OK', text: t('set.an') }) : h('span', { class: 'chip INFO', text: t('allg.unbekannt') }))),
    h('span', null, t('wt.r.sperre') + ' ', sf.sperre24h ? h('span', { class: 'chip WARN', text: t('set.aktiv') }) : h('span', { class: 'chip OK', text: t('allg.nein') })),
    sf.speicherKlein ? h('span', null, t('wt.r.speicher') + ' ', h('span', { class: 'chip WARN', text: t('wt.r.zuKlein') }), sf.speicherMax ? t('wt.r.erlaubt', sf.speicherMax) : '') : null,
    h('span', null, t('wt.r.letzter') + ' ', h('b', { text: sf.letzterPunkt ? fmtDate(sf.letzterPunkt) : '–' })));
  return h('div', { class: 'wt-group', id: 'wt-punkt' }, h('h3', { text: t('menu.werkzeug.punkt') }),
    h('p', { class: 'wt-expl', text: t('wt.r.expl') }),
    state,
    sf.schutzAn === false ? h('div', null, h('p', { class: 'wt-meta', text: t('wt.r.schutzAus') }), sf.befehlSchutz ? cmdBlock(sf.befehlSchutz) : null) : null,
    sf.sperre24h ? h('div', null, h('p', { class: 'wt-meta', text: t('wt.r.sperreText') }), sf.befehl ? h('details', { class: 'cmd' }, h('summary', { text: t('sb.sperre24Befehl') }), cmdBlock(sf.befehl)) : null,
      h('p', { class: 'wt-meta', text: t('wt.r.mehr') })) : null,
    h('div', { class: 'wt-acts' }, h('button', { type: 'button', class: 'sm primary', disabled: off, title: off ? (dis ? tt : t('wt.r.btnTitel')) : null, text: t('wt.r.anlegen'), onclick: () => wtStartDlg(w, null) }),
      kiBtn(t('menu.werkzeug.punkt'), () => kiWerkzeug(t('menu.werkzeug.punkt'), t('wt.r.expl'), [
        [t('kf.f.stand'), [t('wt.r.schutz') + ' ' + (sf.schutzAn === false ? t('set.aus') : (sf.schutzAn === true ? t('set.an') : t('allg.unbekannt'))),
          t('wt.r.sperre') + ' ' + (sf.sperre24h ? t('set.aktiv') : t('allg.nein'))]],
        [t('kf.f.befehl'), w.befehl]]))));
}
function wtBody(d, upd) {
  S.wt.tools = Array.isArray(d.werkzeuge) ? d.werkzeuge : [];
  const ro = readOnly(), run = d.laufend || null, suche = !!(upd && upd.suche);
  const dis = ro || !!run || suche;
  const cfgRun = run ? wtCfg(run.werkzeug, run.abbruch) : null;
  const tt = ro ? lockTitle() : (run ? t('wt.tt.laeuft', cfgRun.title) : (suche ? t('wt.tt.suche') : null));
  const kids = [h('p', { class: 'wt-expl', text: t('wt.expl') }),
    h('div', { class: 'wt-legend', role: 'list', 'aria-label': t('wt.legende') },
      h('span', { role: 'listitem' }, klasseChip('diagnose'), ' ' + t('wt.leg.diagnose')), h('span', { role: 'listitem' }, klasseChip('wartung'), ' ' + t('wt.leg.wartung')), h('span', { role: 'listitem' }, klasseChip('reparatur'), ' ' + t('wt.leg.reparatur')))];
  if (ro) kids.push(h('p', { class: 'wt-meta', text: lockTitle() }));
  if (run) {
    const c = wtCtl(run.jobId, cfgRun);
    kids.push(h('div', { class: 'wt-run', role: 'status' }, h('span', { text: t('wt.laeuftTitel', cfgRun.title) }), h('button', { type: 'button', class: 'sm', text: t('rb.anzeigen'), onclick: () => wtShow(c) })));
  }
  kids.push(wtRestore(d, dis, tt));
  const groups = [];
  S.wt.tools.filter(w => !WT_GRUPPEN_OHNE.includes(w.gruppe) && w.id !== WT_PUNKT_ID && w.id !== 'perfmon.rel').forEach(w => { let g = groups.find(x => x.name === w.gruppe); if (!g) groups.push(g = { name: w.gruppe, list: [] }); g.list.push(w); });
  const berichte = Array.isArray(d.berichte) ? d.berichte : [];
  const viewer = h('div'), repBtns = [];
  groups.forEach(g => {
    g.list.sort((a, b) => (a.schritt || 0) - (b.schritt || 0));
    const gk = [h('h3', { text: tk('wt.gruppe.' + g.name, g.name) })];
    if (g.name === 'Systemdateien') gk.push(h('p', { class: 'wt-expl', text: t('wt.g.systemdateien') }));
    if (g.name === 'Komponentenspeicher') gk.push(h('p', { class: 'wt-expl', text: t('wt.g.komponentenspeicher') }));
    gk.push(h('div', { class: 'wt-list' }, g.list.map(w => wtRow(w, d, dis, tt))));
    if (g.name === 'Diagnose') gk.push(h('div', { class: 'wt-row', 'data-id': 'perfmon.rel' },
      h('div', { class: 'wt-head' }, h('b', { class: 'wt-title', text: t('menu.werkzeug.zuverlaessigkeit') }), klasseChip('diagnose')),
      h('p', { class: 'wt-expl', text: t('wt.rel.expl') }),
      h('p', { class: 'wt-meta', text: t('wt.rel.meta') }),
      h('div', { class: 'wt-acts' }, h('button', { type: 'button', class: 'sm primary', text: t('wt.rel.oeffnen'), onclick: wtZuverlaessigkeit }),
        kiBtn(t('menu.werkzeug.zuverlaessigkeit'), () => kiWerkzeug(t('menu.werkzeug.zuverlaessigkeit'), t('wt.rel.expl'), [[t('kf.f.hinweis'), t('wt.rel.meta')]])))));
    if (g.name === 'Energieberichte') {
      gk.push(h('h3', { class: 'wt-sub', text: t('wt.berichte') }));
      gk.push(berichte.length ? h('div', { class: 'wt-reps' }, berichte.map(b => {
        const btn = h('button', { type: 'button', class: 'sm', onclick: () => {
          S.wt.report = S.wt.report === b.name ? null : b.name; S.wt.scrollReport = !!S.wt.report;
          wtViewer(viewer, berichte); repBtns.forEach(x => x()); wtScrollReport();
        } });
        const upd = () => { btn.textContent = S.wt.report === b.name ? t('btn.schliessen') : t('wt.oeffnen'); };
        upd(); repBtns.push(upd);
        return h('div', { class: 'wt-rep' }, h('b', { text: b.titel || b.name }), h('span', { class: 'wt-meta', text: b.zeit ? fmtDate(b.zeit) : '' }), btn);
      })) : h('p', { class: 'wt-meta', text: t('wt.keineBerichte') }));
      gk.push(viewer);
    }
    kids.push(h('div', { class: 'wt-group' }, gk));
  });
  if (!groups.length) kids.push(h('p', { class: 'muted', text: t('wt.keineWerkzeuge') }));
  wtViewer(viewer, berichte);
  wtScrollReport();
  return kids;
}
function wtScrollReport() {
  if (!S.wt.scrollReport || !S.wt.report) return;
  S.wt.scrollReport = false;
  setTimeout(() => { const el = $('#wt-report'); if (el) el.scrollIntoView({ block: 'start', behavior: 'smooth' }); }, 80);
}
async function wtZuverlaessigkeit() {
  try {
    const r = await api('/api/wartung/zuverlaessigkeit', { method: 'POST' });
    toast((r && r.meldung) || (r && r.ok === false ? t('wt.rel.fehl') : t('wt.rel.wirdGeoeffnet')));
  } catch (e) { toast(t('wt.rel.alternativ', e.message)); }
}
function wartungCard() {
  const body = h('div', null, h('p', { class: 'muted', text: t('laedt') }));
  const token = S.rv;
  Promise.all([api('/api/wartung'), api('/api/updates').catch(() => null)]).then(([d, upd]) => {
    if (token !== S.rv) return;
    body.replaceChildren(...wtBody(d || {}, upd).filter(Boolean));
  }, e => { if (token === S.rv) body.replaceChildren(h('p', { class: 'rem', text: t('wt.ladenFehler', e.message) })); });
  return h('div', { class: 'card', id: 'wartung-card' }, h('h2', { text: t('menu.unter.wartung') }), body);
}

// ---- Karte „Programme aktualisieren (winget)“
function updSuchen() {
  api('/api/updates/suchen', { method: 'POST' }).then(r => updShowSearch(updFollowSearch(r.jobId, false)), e => toast(wtErr(e)));
}
function updFollowSearch(jobId, bg) {
  let c = WT_SEARCH.get(jobId);
  if (c) return c;
  const title = t('upd.suchTitel');
  c = { jobId, bg, log: h('pre', { class: 'log', 'aria-live': 'polite', text: '' }) };
  WT_SEARCH.set(jobId, c);
  followJob(jobId, l => { c.log.append(document.createTextNode(l.join('\n') + '\n')); c.log.scrollTop = c.log.scrollHeight; })
    .then(j => ({ j }), e => ({ e }))
    .then(r => {
      WT_SEARCH.delete(jobId);
      const msg = r.e ? r.e.message : (r.j && r.j.status === 'failed' ? ((r.j.ergebnis && r.j.ergebnis.error) || t('upd.suchFehl')) : null);
      if (c.bg) toast(msg || t('upd.toastFertig'));
      else if (msg) dlgOpen(title, [c.log, h('p', { class: 'rem', text: msg })], [{ label: t('btn.schliessen'), primary: true, onClick: dlgClose }]);
      else dlgClose();
      if (S.view === 'werkzeuge') refreshView();
    });
  return c;
}
function updShowSearch(c) {
  c.bg = false;
  dlgOpen(t('upd.suchTitel'), [h('p', { class: 'note', text: t('upd.suchNote') }), c.log],
    [{ label: t('wt.hintergrund'), onClick: () => { c.bg = true; dlgClose(); if (S.view === 'werkzeuge') refreshView(); } }], { lock: true });
}
function updInstallDlg(items) {
  const ids = items.map(x => x.id);
  const cfg = { ...wtCfg(WT_WINGET_ID), ids };
  const body = [
    h('p', { text: items.length === 1 ? t('upd.dlg1') : t('upd.dlgN', items.length) }),
    h('ul', { class: 'wt-pk' }, items.map(x => h('li', null, h('b', { text: x.name || x.id }), h('span', { class: 'muted', text: ` ${x.installiert || '?'} → ${x.verfuegbar || '?'}` })))),
    h('p', null, h('span', { class: 'chip WARN', text: t('wt.k.reparatur') })),
    h('p', { text: t('upd.dlgNicht') }),
    h('p', { text: t('upd.dlgSchliessen') }),
    h('p', { class: 'note', text: t('upd.dlgLizenz') }),
    h('div', { class: 'note', text: t('win.fragtVorher') })];
  const post = wtPostWinget(ids);
  dlgOpen(t('menu.unter.updates'), body, [{ label: t('btn.abbrechen'), onClick: dlgClose }, { label: t('upd.knopf'), primary: true, onClick: () => wtRun(cfg, post) }]);
}
function updBody(d) {
  const ro = readOnly(), run = d.laufend || null, search = d.suche || null;
  const fremd = d.wartungLaeuft && d.wartungLaeuft !== WT_WINGET_ID;
  const dis = ro || !!run || !!search || !!fremd;
  const tt = ro ? lockTitle() : (fremd ? t('upd.tt.fremd') : (run ? t('upd.tt.laeuft') : (search ? t('upd.tt.suche') : null)));
  if (d.punktFehlt === false) S.wt.punktIds = null;
  const pIds = d.punktFehlt === true && Array.isArray(S.wt.punktIds) && S.wt.punktIds.length ? S.wt.punktIds : null;
  const liste = Array.isArray(d.liste) ? d.liste : [];
  const prog = liste.filter(x => x.kategorie === 'Programm');
  const sel = S.wt.sel;
  [...sel].forEach(id => { if (!prog.some(x => x.id === id)) sel.delete(id); });
  const kids = [h('p', { class: 'wt-expl', text: t('upd.expl') })];
  kids.push(h('p', { class: 'wt-meta', text: d.stand ? t('upd.stand', fmtDate(d.stand)) : t('upd.nochNicht') }));
  if (d.fehler) kids.push(h('p', { class: 'rem', text: String(d.fehler) }));
  if (ro) kids.push(h('p', { class: 'wt-meta', text: lockTitle() }));
  if (run) { const c = wtCtl(run, wtCfg(WT_WINGET_ID)); kids.push(h('div', { class: 'wt-run', role: 'status' }, h('span', { text: t('upd.laeuft') }), h('button', { type: 'button', class: 'sm', text: t('rb.anzeigen'), onclick: () => wtShow(c) }))); }
  if (search) { const c = updFollowSearch(search, true); kids.push(h('div', { class: 'wt-run', role: 'status' }, h('span', { text: t('upd.sucheLaeuft') }), h('button', { type: 'button', class: 'sm', text: t('rb.anzeigen'), onclick: () => updShowSearch(c) }))); }
  const punktBtn = pIds ? h('button', { type: 'button', class: 'sm', text: t('wt.pf.knopfPunkte'), disabled: dis, title: dis ? tt : null,
    onclick: () => wtPunktFehlt({ cfg: { ...wtCfg(WT_WINGET_ID), ids: pIds } }, { meldung: t('wt.pf.meldung') }) }) : null;
  if (d.punktFehlt === true) kids.push(h('div', { class: 'wt-meta' }, h('span', { class: 'chip WARN', text: t('upd.punktFehlte') }),
    ' ' + t('upd.punktText') + ' ', pIds ? punktBtn : t('upd.waehleGleiche')));
  const goBtn = h('button', { type: 'button', class: 'sm primary', disabled: true, text: t('upd.goKnopf'), onclick: () => { if (sel.size > 30) { toast(t('upd.max30')); return; } updInstallDlg(prog.filter(x => sel.has(x.id))); } });
  const boxes = [];
  const all = h('input', { type: 'checkbox', id: 'upd-all', disabled: dis || !prog.length, 'aria-label': t('upd.alleAria'), onchange: e => { prog.forEach(x => { if (e.target.checked) sel.add(x.id); else sel.delete(x.id); }); boxes.forEach(b => { b.checked = e.target.checked; }); sync(); } });
  function sync() {
    goBtn.disabled = dis || !sel.size;
    goBtn.title = dis ? tt : null;
    goBtn.textContent = sel.size ? t('upd.goKnopfN', sel.size) : t('upd.goKnopf');
    all.checked = prog.length > 0 && sel.size === prog.length;
  }
  kids.push(h('div', { class: 'toolbar' },
    h('button', { type: 'button', class: 'primary', disabled: dis, title: tt, text: d.stand ? t('wt.erneutSuchen') : t('upd.suchen'), onclick: updSuchen }),
    prog.length ? h('label', null, all, ' ' + t('upd.alle')) : null, prog.length ? goBtn : null));
  if (liste.length) {
    kids.push(h('div', { class: 'tbl-scroll wt-upd' }, h('table', null,
      h('thead', null, h('tr', null, [h('th', { text: '' }), ...[t('upd.hName'), t('upd.hInst'), t('upd.hVerf'), t('upd.hKat')].map(x => h('th', { text: x }))])),
      h('tbody', null, liste.map(x => {
        const can = x.kategorie === 'Programm';
        const gekuerzt = x.kategorie === 'Id gekürzt', hint = gekuerzt ? t('upd.idGekuerzt') : null;
        const katName = x.kategorie ? tk(UPD_KAT[x.kategorie], x.kategorie) : '';
        const cb = h('input', { type: 'checkbox', checked: can && sel.has(x.id), disabled: !can || dis, title: can ? null : (hint || t('upd.nichtAuswaehlbar', katName || t('upd.unbekanntKat'))), 'aria-label': t('karte.auswaehlen', x.name || x.id),
          onchange: e => { if (e.target.checked) sel.add(x.id); else sel.delete(x.id); sync(); } });
        if (can) boxes.push(cb);
        return h('tr', { class: can ? null : 'dim' }, h('td', null, cb), h('td', null, x.name || x.id, h('div', { class: 'note', text: x.id })), h('td', { text: x.installiert || '' }), h('td', { text: x.verfuegbar || '' }), h('td', null, katName, hint ? h('div', { class: 'note', text: hint }) : null));
      })))));
    kids.push(h('p', { class: 'wt-meta', text: t('upd.grau') }));
  } else if (d.stand && !d.fehler) kids.push(h('p', { class: 'ok', text: t('upd.keine') }));
  sync();
  return kids;
}
function updCard() {
  const body = h('div', null, h('p', { class: 'muted', text: t('laedt') }));
  const token = S.rv;
  api('/api/updates').then(d => {
    if (token !== S.rv) return;
    body.replaceChildren(...updBody(d || {}).filter(Boolean));
  }, e => { if (token === S.rv) body.replaceChildren(h('p', { class: 'rem', text: t('upd.ladenFehler', e.message) })); });
  return h('div', { class: 'card', id: 'upd-card' }, kiHead(t('upd.titel'), () => kiWerkzeug(t('upd.titel'), t('upd.expl'), [[t('kf.f.befehl'), wtTool(WT_WINGET_ID).befehl]])), body);
}

// ---------------------------------------------------------------- Rechte Statusleiste
const sbVisible = () => S.sbOn && !S.einfach && window.matchMedia('(min-width:1400px)').matches;
const clampPct = v => Math.max(0, Math.min(100, Number(v) || 0));
const TONE_OF = { OK: 'green', ACK: 'green', INFO: 'yellow', TIPP: 'yellow', WARN: 'orange', CRIT: 'red', SKIP: 'grey' };
const toneOf = f => (f && TONE_OF[f.Status]) || 'grey';
function scCard(title, src, isLive, ...kids) {
  return h('section', { class: 'sc' }, h('div', { class: 'sc-h' }, h('h3', { text: title }), h('span', { class: 'src' + (isLive ? ' live' : ''), text: src })), ...kids);
}
function sparkNode(vals, w = 74, hh = 20) {
  const s = svg('svg', { class: 'sp', viewBox: `0 0 ${w} ${hh}`, 'aria-hidden': 'true' });
  const v = (vals || []).filter(x => x != null && !isNaN(x)).map(Number).slice(-30);
  if (v.length >= 2) s.append(svg('polyline', { points: v.map((x, i) => `${(i * (w - 2) / (v.length - 1) + 1).toFixed(1)},${(hh - 2 - clampPct(x) / 100 * (hh - 4)).toFixed(1)}`).join(' ') }));
  return s;
}
const loadTone = v => v == null ? 'grey' : v >= 90 ? 'red' : v >= 75 ? 'yellow' : 'cyan';
function mrow(label, v, hist, sub) {
  return h('div', { class: 'mrow g-' + loadTone(v) },
    h('span', { class: 'lbl', text: label }), h('div', { class: 'meter' }, h('i', { style: `width:${clampPct(v)}%` })), h('span', { class: 'val', text: v == null ? '–' : dec(v, 0) + ' %' }),
    h('span', { class: 'sub2' }, sub), sparkNode(hist));
}
function fmtRate(kbs) { if (kbs == null || isNaN(kbs)) return '–'; return kbs < 1024 ? `${dec(kbs, 0)} KB/s` : `${dec(kbs / 1024, 1)} MB/s`; }
function fmtLink(m) { if (m == null || isNaN(m)) return '–'; return m >= 1000 ? `${dec(m / 1000, m % 1000 ? 1 : 0)} Gbit/s` : `${dec(m, 0)} Mbit/s`; }

function renderStatusLive() {
  const box = $('#st-live'); if (!box) return;
  const L = S.live;
  if (L.state === 'unsupported') { box.replaceChildren(); return; }
  const d = L.data;
  if (!d || d.stand == null) {
    box.replaceChildren(h('div', { class: 'st-sec', text: t('st.live') }),
      scCard(t('st.cpuRamGpu'), L.state === 'error' ? t('st.nichtErreichbar') : t('st.liveKlein'), L.state !== 'error', h('p', { class: 'wait', text: L.state === 'error' ? t('st.messwerteNicht') : t('st.gemessen') })));
    return;
  }
  const src = L.state === 'error' ? t('st.veraltet') : t('st.liveKlein'), isLive = L.state !== 'error', v = d.verlauf || {};
  const cards = [h('div', { class: 'st-sec', text: t('st.live') })];
  // 1. CPU · RAM · GPU
  const g = d.gpu, ram = d.ram || {};
  const temp = g && g.temp != null ? h('span', { class: 'chip ' + (g.temp >= 88 ? 'CRIT' : g.temp >= 80 ? 'Y' : ''), title: t('st.gpuTemp'), text: `${dec(g.temp, 0)} °C` }) : null;
  cards.push(scCard(t('st.cpuRamGpu'), src, isLive,
    mrow('CPU', d.cpu, v.cpu, null),
    mrow('RAM', ram.usedPct, v.ram, ram.usedGB != null && ram.totalGB != null ? t('st.ramVon', dec(ram.usedGB, 1), dec(ram.totalGB, 0)) : null),
    mrow('GPU', g ? g.util : null, v.gpu, g ? [g.name || 'GPU', g.memUsedPct != null ? t('st.vram', dec(g.memUsedPct, 0)) : '', ' ', temp] : t('st.keineGpu'))));
  // 2. Laufwerke
  const drives = (d.drives || []).filter(Boolean);
  if (drives.length) {
    cards.push(scCard(t('st.laufwerke'), src, isLive, drives.map(x => {
      const free = x.freePct != null ? Number(x.freePct) : (x.sizeGB ? x.freeGB / x.sizeGB * 100 : null);
      const tone = free == null ? 'grey' : free < 10 ? 'red' : free < 20 ? 'yellow' : 'green';
      const letter = spLetter(x.letter);
      return h('div', { class: 'drow g-' + tone, 'data-letter': letter, tabindex: '0', role: 'button', 'aria-haspopup': 'dialog', 'aria-expanded': S.spPop && S.spPop.letter === letter ? 'true' : 'false', title: t('st.spTitel'),
        onmouseenter: () => spHover(letter), onmouseleave: spLeave, onclick: () => spClick(letter, false),
        onkeydown: e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); spClick(letter, true); } } },
        h('div', { class: 'l1' }, h('i', { class: 'adot' }), h('b', { text: x.letter || '?' }), x.label ? h('span', { class: 'lab', text: x.label }) : null, x.type ? h('span', { class: 'chip type', text: x.type }) : null,
          h('span', { class: 'pct', text: free == null ? '–' : t('st.belegt', dec(100 - free, 0)) })),
        h('div', { class: 'meter' }, h('i', { style: `width:${free == null ? 0 : clampPct(100 - free)}%` })),
        h('div', { class: 'l2', text: x.freeGB != null && x.sizeGB != null ? t('st.freiVon', dec(x.freeGB, 0), dec(x.sizeGB, 0)) : t('st.groesseUnbekannt') }));
    })));
  }
  // 3. Netzwerk
  const n = d.net;
  cards.push(scCard(t('st.netzwerk'), src, isLive, n
    ? [h('div', { class: 'kv' }, h('span', { class: 'muted', text: t('st.adapter') }), h('b', { text: n.adapter || '–' })), h('div', { class: 'kv' }, h('span', { class: 'muted', text: t('st.link') }), h('b', { text: fmtLink(n.linkMbps) })),
      h('div', { class: 'kv' }, h('span', { class: 'muted', text: t('st.empfang') }), h('b', { text: fmtRate(n.rxKBs) })), h('div', { class: 'kv' }, h('span', { class: 'muted', text: t('st.senden') }), h('b', { text: fmtRate(n.txKBs) }))]
    : h('p', { class: 'wait', text: t('st.keineVerbindung') })));
  // 4. Top-Prozesse
  const top = (d.top || []).filter(Boolean).slice(0, 3);
  cards.push(scCard(t('st.topProzesse'), src, isLive, top.length
    ? top.map(p => h('div', { class: 'pr' }, h('span', { class: 'nm', title: p.name, text: p.name }), h('b', { text: p.cpu == null ? '–' : dec(p.cpu, 1) + ' %' })))
    : h('p', { class: 'wait', text: t('st.keineDaten') })));
  box.replaceChildren(...cards);
  if (S.spPop) { syncSpRows(); placeSpPop(); }   // das offene Speicher-Fenster liegt außerhalb dieser Karten und bleibt stehen
}

// Schutz-Ampeln: Name der Anzeige und Erkennung über die feste Prüfungskennung
const PROT = () => [
  [t('st.prot.defender'), f => /^(Microsoft )?Defender: Status$/.test(f.Check)],
  [t('st.prot.firewall'), f => /^Firewall/.test(f.Check) && /Profile|Status/.test(f.Check)],
  [t('st.prot.windowsUpdate'), f => f.Check === 'Windows Update: ausstehend'],
  [t('st.prot.secureBoot'), f => f.Check === 'Secure Boot'],
  [t('st.prot.tpm'), f => f.Check === 'TPM'],
  [t('st.prot.bitlocker'), f => f.Check === 'BitLocker'],
  [t('st.prot.kernisolierung'), f => /^Kernisolierung/.test(f.Check)],
];
const RISKY_PORTS = new Set([3389, 445, 139, 5985, 5986, 22, 23]);
const SYS_PROCS = new Set(['system', 'svchost', 'lsass', 'wininit', 'services', 'spoolsv', 'smss', 'csrss', 'winlogon', 'lsm', 'dns', 'wuauserv', 'dwm', 'fontdrvhost', 'idle']);
const dataTable = name => { const D = (S.report && S.report.Data) || {}, k = Object.keys(D).find(x => norm(x) === name); return k ? (D[k] || []) : null; };
const findBy = pred => S.findings.find(pred);
function portCard(src) {
  const rows = dataTable('Offene Netzwerkports (nicht nur lokal)');
  if (!rows) return scCard(t('st.offenePorts'), src, false, h('p', { class: 'wait', text: t('st.keinePortdaten') }));
  const seen = new Map();
  rows.filter(Boolean).forEach(r => {
    const port = Number(r.Port), key = `${r.Protokoll}/${port}`;
    if (isNaN(port) || seen.has(key)) return;
    const proc = String(r.Prozess || '').replace(/\.exe$/i, '');
    seen.set(key, { port, proto: r.Protokoll, proc, tone: RISKY_PORTS.has(port) ? 'red' : (!proc || SYS_PROCS.has(proc.toLowerCase()) ? 'green' : 'yellow') });
  });
  const list = [...seen.values()], ord = { red: 0, yellow: 1, green: 2 };
  list.sort((a, b) => ord[a.tone] - ord[b.tone] || a.port - b.port);
  const cnt = tn_ => list.filter(x => x.tone === tn_).length;
  return scCard(t('st.offenePorts'), src, false,
    h('div', { class: 'kv' }, h('span', { class: 'muted', text: t('st.vonAussen') }), h('b', { text: String(list.length) })),
    list.length ? [h('div', { class: 'kv' }, h('span', { class: 'muted', text: t('st.riskantFremd') }), h('b', { text: `${cnt('red')} · ${cnt('yellow')} · ${cnt('green')}` })),
      list.slice(0, 5).map(p => h('div', { class: 'port g-' + p.tone }, h('i', { class: 'adot' }), h('code', { text: String(p.port) }), h('span', { class: 'nm', title: `${p.proto} · ${p.proc || t('st.system')}`, text: `${p.proc || t('st.system')} · ${p.proto}` }))),
      list.length > 5 ? h('div', { class: 'note', text: t('st.undWeitere', list.length - 5) }) : null] : h('p', { class: 'wait', text: t('st.keinePorts') }));
}
function stabilityCard(src) {
  const tile = (label, tone, valNode, f) => h(f ? 'button' : 'div', { type: f ? 'button' : null, class: 'tile g-' + tone, onclick: f ? () => reveal(f.Check) : null, title: f ? t('st.zumBefund') : null },
    h('div', { class: 'tl2' }, h('i', { class: 'adot' }), label), h('b', null, valNode));
  const fRel = findBy(f => f.Check === 'Zuverlässigkeitsindex'), fCrash = findBy(f => f.Check === 'Abstürze und unerwartete Neustarts');
  const fApp = findBy(f => f.Check === 'Programmabstürze'), fBoot = findBy(f => f.Check === 'Startdauer');
  const reBs = /(\d+)\s*(?:Bluescreens?|blue ?screens?|BSODs?)/i, reKeine = /^(?:Keine|No)\b/i;
  const rel = fRel && /([\d.,]+)\s*(?:von|of)\s*(\d+)/.exec(fRel.Value || ''), relN = rel ? Number(rel[1].replace(',', '.')) : null;
  const bs = fCrash && (reBs.exec(fCrash.Value || '') ? Number(reBs.exec(fCrash.Value)[1]) : (reKeine.test(fCrash.Value || '') ? 0 : null));
  const am = fApp && (/^(\d+)/.exec(fApp.Value || '') ? Number(/^(\d+)/.exec(fApp.Value)[1]) : (reKeine.test(fApp.Value || '') ? 0 : null));
  const bootRows = (dataTable('Startdauer (letzte Messungen)') || []).filter(Boolean).map(x => Number(x.HauptpfadSek)).filter(x => !isNaN(x));
  const boot = bootRows.length ? bootRows.reduce((a, b) => a + b, 0) / bootRows.length : null;
  const dash = h('span', { class: 'muted', text: '–' });
  return scCard(t('menu.stabilitaet'), src, false, h('div', { class: 'tiles' },
    tile(t('st.t.zuverlaessigkeit'), relN == null ? 'grey' : relN >= 8 ? 'green' : relN >= 6 ? 'yellow' : 'orange', relN == null ? dash : [dec(relN, relN % 1 ? 1 : 0), h('small', { text: ` / ${rel[2]}` })], fRel),
    tile(t('st.t.bluescreens'), bs == null ? 'grey' : bs === 0 ? 'green' : 'red', bs == null ? dash : String(bs), fCrash),
    tile(t('st.t.appAbstuerze'), am == null ? 'grey' : am === 0 ? 'green' : am <= 5 ? 'yellow' : 'orange', am == null ? dash : String(am), fApp),
    tile(t('st.t.startdauer'), boot == null ? 'grey' : boot <= 30 ? 'green' : boot <= 60 ? 'yellow' : 'orange', boot == null ? dash : [dec(boot, 0), h('small', { text: ' s' })], fBoot)));
}
function safetyCard() {
  const s = safety(), sess = !!S.session;
  const pt = S.points && S.points[0] ? S.points[0].zeit : s.letzterPunkt;
  const undoable = S.journal ? S.journal.filter(e => e.status === 'erledigt' && e.art !== 'rueckgaengig').length : null;
  const row = (tone, label, val) => h('div', { class: 'pr g-' + tone }, h('i', { class: 'adot' }), h('span', { class: 'nm', text: label }), h('b', { text: val }));
  return scCard(t('st.absicherung'), t('st.sitzung'), false,
    row(!sess || s.schutzAn == null ? 'grey' : s.schutzAn ? 'green' : 'red', t('set.schutz'), !sess || s.schutzAn == null ? '–' : s.schutzAn ? t('set.an') + (s.laufwerk ? ' (' + s.laufwerk + ')' : '') : t('set.aus')),
    row(s.sperre24h == null ? 'grey' : s.sperre24h ? 'yellow' : 'green', t('st.sperre24'), s.sperre24h == null ? '–' : s.sperre24h ? t('set.aktiv') : t('set.aus')),
    row(pt ? 'green' : 'grey', t('st.letzterPunkt'), pt ? fmtAgo(pt) : '–'),
    row(undoable == null ? 'grey' : 'cyan', t('st.ruecknehmbar'), undoable == null ? '–' : (undoable === 1 ? t('st.aenderung1', undoable) : t('st.aenderungN', undoable))),
    h('a', { class: 'more-link', href: '#/aenderungen', text: t('st.zuAenderungen') }));
}
function renderStatusReport() {
  const box = $('#st-report'); if (!box) return;
  const nodes = [];
  if (S.report) {
    const src = t('kopf.berichtVom') + fmtDate(S.report.Meta.Erstellt);
    nodes.push(h('div', { class: 'st-sec', text: t('st.ausBericht') }));
    // 5. Schutz-Ampeln
    nodes.push(scCard(t('st.ampeln'), src, false, PROT().map(([name, pred]) => {
      const f = findBy(pred), tone = toneOf(f);
      return h('button', { type: 'button', class: 'srow g-' + tone, disabled: !f, title: f ? `${chkName(f)}: ${f.Value || ''}` : t('st.nichtImBericht'), onclick: f ? () => reveal(f.Check) : null },
        h('i', { class: 'adot' }), name, h('span', { class: 'sv', text: f ? (STATUS_NAME[f.Status] || f.Status) : t('st.fehlt') }));
    })));
    nodes.push(portCard(src), stabilityCard(src));
  }
  nodes.push(h('div', { class: 'st-sec', text: t('st.absicherung') }), safetyCard());
  box.replaceChildren(...nodes);
}

// Abfrage von /api/live alle 5 s; Pause bei verstecktem Tab oder ausgeblendeter Leiste
let liveTimer = null, liveBusy = false;
function liveStop() { if (liveTimer) { clearTimeout(liveTimer); liveTimer = null; } }
async function livePoll() {
  liveTimer = null;
  if (!sbVisible() || S.live.state === 'unsupported' || document.hidden || liveBusy) return;
  liveBusy = true;
  let again = true;
  try {
    const d = await api('/api/live');
    S.live = { state: 'ok', data: d || {} };
  } catch (e) {
    if (e.status === 404 || e.status === 501) { S.live = { state: 'unsupported', data: null }; again = false; }
    else if (e.status === 401) again = false;
    else S.live = { state: 'error', data: S.live.data };
  } finally { liveBusy = false; }
  renderStatusLive();
  if (again) liveTimer = setTimeout(livePoll, LIVE_MS);
}
function liveEnsure() { if (sbVisible() && S.live.state !== 'unsupported' && !document.hidden && !liveTimer && !liveBusy) livePoll(); }
function applySb() {
  $('#app').classList.toggle('st-off', !S.sbOn || S.einfach);   // im einfachen Modus ohne Statusleiste (#103)
  $('#st-toggle').setAttribute('aria-pressed', S.sbOn ? 'true' : 'false');
  renderStatusLive(); renderStatusReport();
  if (sbVisible()) liveEnsure(); else { liveStop(); closeSpPop(false); }
}
function initStatusbar() {
  try { S.sbOn = localStorage.getItem(SB_KEY) !== '0'; } catch { S.sbOn = true; }
  $('#st-toggle').addEventListener('click', () => {
    S.sbOn = !S.sbOn;
    try { localStorage.setItem(SB_KEY, S.sbOn ? '1' : '0'); } catch { /* ohne Speicher weiter */ }
    applySb();
  });
  window.matchMedia('(min-width:1400px)').addEventListener('change', () => { if (sbVisible()) liveEnsure(); else { liveStop(); closeSpPop(false); } });
  document.addEventListener('visibilitychange', () => { if (document.hidden) liveStop(); else liveEnsure(); });
  applySb();
}
// ---------------------------------------------------------------- Ansichtsmodus Einfach/Experte (2.7, #103)
function modusAnwenden() {
  document.documentElement.dataset.modus = S.einfach ? 'einfach' : 'experte';
  document.querySelectorAll('#modus button').forEach(b => b.setAttribute('aria-pressed', String((b.dataset.modus === 'einfach') === S.einfach)));
}
function setModus(einfach) {
  if (S.einfach === einfach) return;
  S.einfach = einfach;
  try { localStorage.setItem(MODUS_KEY, einfach ? 'einfach' : 'experte'); } catch { /* ohne Speicher weiter */ }
  modusAnwenden();
  applySb();
  if (einfach) { S.sel.clear(); S.rest = {}; }
  if (einfach && NUR_EXPERTE_ZU.includes(S.view)) location.hash = '#/uebersicht'; else refreshView();
}
function initModus() {
  try { S.einfach = localStorage.getItem(MODUS_KEY) !== 'experte'; } catch { S.einfach = true; }
  modusAnwenden();
  const sw = $('#modus'); if (!sw) return;
  sw.addEventListener('click', e => { const b = e.target.closest('button[data-modus]'); if (b) setModus(b.dataset.modus === 'einfach'); });
}
const einfachHinweis = () => h('p', { class: 'einfach-hinweis' }, t('modus.hinweis'),
  h('button', { type: 'button', class: 'btn link', text: t('modus.zuExperte'), onclick: () => setModus(false) }));
async function loadExtra() {
  const [j, p] = await Promise.all([api('/api/journal').catch(() => null), api('/api/restorepoints').catch(() => null)]);
  if (j) S.journal = j;
  if (p) S.points = p;
  renderStatusReport();
}

// ---------------------------------------------------------------- Speicher-Fenster an der Laufwerkskarte
// Datenquelle: das jüngere von Bericht (Speicher) und GET /api/speicher. Hover, Klick und Neuzeichnen laden und rechnen nichts.
async function loadSpeicher() {
  try { S.spApi = await api('/api/speicher'); } catch { S.spApi = null; }
  pickSpeicher();
}
function pickSpeicher() {
  const rep = S.report && S.report.Speicher && S.report.Speicher.stand ? S.report.Speicher : null;
  const apiD = S.spApi && S.spApi.stand ? S.spApi : null;
  const ts = x => { const n = new Date(x.stand).getTime(); return isNaN(n) ? 0 : n; };
  if (rep && (!apiD || ts(rep) >= ts(apiD))) { S.speicher = rep; S.spSrcKey = 'aus'; }
  else if (apiD) { S.speicher = apiD; S.spSrcKey = 'neu'; }
  else { S.speicher = null; S.spSrcKey = ''; }
  if (S.spPop) renderSpPop();
}
const spSrcText = () => S.spSrcKey === 'aus' ? t('sp.ausBericht') : (S.spSrcKey === 'neu' ? t('sp.neuBerechnet') : '');
function fmtBytes(b) {
  b = Number(b); if (b == null || isNaN(b)) return '–';
  const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0;
  while (b >= 1024 && i < 4) { b /= 1024; i++; }
  return `${dec(b, i >= 4 ? 2 : (i === 3 ? 1 : 0))} ${u[i]}`;
}
const spLetter = l => String(l || '').replace(/[:\\\/]+$/, '').toUpperCase() + ':';
const spRow = letter => [...document.querySelectorAll('.drow')].find(r => r.dataset.letter === letter) || null;
const spTimer = { open: null, close: null };
function spClear() { clearTimeout(spTimer.open); clearTimeout(spTimer.close); spTimer.open = spTimer.close = null; }
function spEl() {
  let p = $('#sp-pop');
  if (!p) {
    p = h('div', { id: 'sp-pop', class: 'sp-pop hide', role: 'dialog', tabindex: '-1' });
    p.addEventListener('mouseenter', () => clearTimeout(spTimer.close));
    p.addEventListener('mouseleave', () => spLeave());
    p.addEventListener('keydown', e => {
      if (e.key !== 'Tab') return;
      const f = [...p.querySelectorAll('button:not(:disabled)')];
      if (!f.length) return;
      if (e.shiftKey && document.activeElement === f[0]) { e.preventDefault(); f[f.length - 1].focus(); }
      else if (!e.shiftKey && document.activeElement === f[f.length - 1]) { e.preventDefault(); f[0].focus(); }
    });
    document.body.append(p);
  }
  return p;
}
function syncSpRows() {
  document.querySelectorAll('.drow').forEach(r => r.setAttribute('aria-expanded', S.spPop && S.spPop.letter === r.dataset.letter ? 'true' : 'false'));
}
function placeSpPop() {
  const pop = $('#sp-pop'), P = S.spPop; if (!pop || !P) return;
  const st = $('#status').getBoundingClientRect(), row = spRow(P.letter), vh = window.innerHeight;
  const w = Math.max(260, Math.min(500, st.left - 24));
  pop.style.width = w + 'px'; pop.style.maxHeight = (vh - 24) + 'px';
  pop.style.left = Math.max(8, st.left - 8 - w) + 'px';
  const top = row ? row.getBoundingClientRect().top - 8 : 12;
  pop.style.top = Math.max(12, Math.min(top, vh - pop.offsetHeight - 12)) + 'px';
}
function openSpPop(letter, pinned, focusIn) {
  spClear();
  if (!sbVisible()) return;
  const same = S.spPop && S.spPop.letter === letter;
  S.spPop = { letter, pinned: !!pinned || !!(same && S.spPop.pinned) };
  renderSpPop(); syncSpRows();
  if (focusIn) { const c = $('#sp-pop [data-f="close"]'); if (c) c.focus(); }
}
function closeSpPop(restore) {
  spClear();
  const P = S.spPop; S.spPop = null;
  const pop = $('#sp-pop'); if (pop) { pop.classList.add('hide'); pop.replaceChildren(); }
  syncSpRows();
  if (restore && P) { const r = spRow(P.letter); if (r) r.focus(); }
}
function spHover(letter) {
  clearTimeout(spTimer.close);
  if (S.spPop && (S.spPop.pinned ? S.spPop.letter !== letter : false)) return;
  if (S.spPop && S.spPop.letter === letter) return;
  clearTimeout(spTimer.open);
  spTimer.open = setTimeout(() => openSpPop(letter, false), 300);
}
function spLeave() {
  clearTimeout(spTimer.open);
  if (!S.spPop || S.spPop.pinned) return;
  clearTimeout(spTimer.close);
  spTimer.close = setTimeout(() => { if (S.spPop && !S.spPop.pinned) closeSpPop(false); }, 250);
}
function spClick(letter, viaKey) {
  spClear();
  if (S.spPop && S.spPop.pinned && S.spPop.letter === letter) { closeSpPop(viaKey); return; }
  openSpPop(letter, true, viaKey);
}
document.addEventListener('mousedown', e => {
  if (!S.spPop) return;
  if (e.target.closest && (e.target.closest('#sp-pop') || e.target.closest('.drow'))) return;
  closeSpPop(false);
});
document.addEventListener('keydown', e => {
  if (e.key !== 'Escape' || !S.spPop || $('#modal').classList.contains('on')) return;
  e.preventDefault(); closeSpPop(true);
});
window.addEventListener('resize', () => { if (S.spPop) { if (sbVisible()) placeSpPop(); else closeSpPop(false); } });

async function copyPath(p) {
  try { await navigator.clipboard.writeText(p); toast(t('sp.pfadKopiert')); } catch { toast(t('kopieren.toastNein')); }
}
function spItem(label, path, bytes, max, extra, sub) {
  const pct = max > 0 ? Math.max(1, Math.round(Number(bytes) / max * 100)) : 0;
  return h('button', { type: 'button', class: 'sp-item', title: path + '\n' + t('sp.klickKopiert'), onclick: () => copyPath(path) },
    h('span', { class: 'sp-top' }, h('span', { class: 'sp-name', text: label }), extra, h('span', { class: 'sp-size', text: fmtBytes(bytes) })),
    h('span', { class: 'sp-bar' }, h('i', { style: `width:${Math.min(100, pct)}%` })),
    sub ? h('span', { class: 'sp-sub' }, sub) : null);
}
function spSection(title, list, empty, build) {
  const max = list.reduce((m, x) => Math.max(m, Number(x.bytes) || 0), 0);
  return h('div', { class: 'sp-sec' }, h('h3', { text: title }), list.length ? list.map(x => build(x, max)) : h('p', { class: 'note', text: empty }));
}
function renderSpPop() {
  const P = S.spPop, pop = spEl();
  if (!P) { pop.classList.add('hide'); pop.replaceChildren(); return; }
  const had = pop.contains(document.activeElement) && document.activeElement !== pop ? document.activeElement.dataset.f : null;
  const sp = S.speicher, lw = sp && (sp.laufwerke || []).find(x => spLetter(x.laufwerk) === P.letter);
  const drive = ((S.live.data && S.live.data.drives) || []).find(x => spLetter(x.letter) === P.letter);
  const bez = (lw && lw.bezeichnung) || (drive && drive.label) || '';
  const kids = [h('div', { class: 'sp-head' }, h('b', { text: t('sp.kopf', `${P.letter}${bez ? ' ' + bez : ''}`) }),
    h('button', { type: 'button', class: 'sm ghost', 'data-f': 'close', 'aria-label': t('btn.schliessen'), title: t('sp.schliessenEsc'), text: '✕', onclick: () => closeSpPop(true) }))];
  const refresh = h('button', { type: 'button', class: 'sm', 'data-f': 'refresh', disabled: readOnly() || !!S.spJob, title: readOnly() ? lockTitle() : null, text: S.spJob ? t('sp.wirdBerechnet') : (lw ? t('sp.neuBerechnenKnopf') : t('sp.jetztBerechnen')), onclick: spRefresh });
  const prog = h('div', { class: 'note', id: 'sp-prog', 'aria-live': 'polite', text: S.spJob ? S.spJob.line : '' });
  if (!sp || !sp.stand || !lw) {
    kids.push(h('p', { text: t('sp.keineAuswertung', P.letter) }), h('div', { class: 'sp-foot' }, refresh), prog);
  } else {
    kids.push(h('div', { class: 'note', text: t('sp.stand', fmtDate(sp.stand), spSrcText(), lw.uebersprungen ? t('sp.uebersprungen', lw.uebersprungen) : '') }));
    if (lw.fehler) kids.push(h('p', { class: 'rem', text: String(lw.fehler) }));
    const folders = (lw.ordner || []).slice(0, 10), files = (lw.dateien || []).slice(0, 10);
    const games = (sp.spiele || []).filter(g => spLetter(g.laufwerk) === P.letter).sort((a, b) => (Number(b.bytes) || 0) - (Number(a.bytes) || 0)).slice(0, 10);
    kids.push(
      spSection(t('sp.ordner'), folders, t('sp.keineOrdner'), (x, max) => spItem(x.pfad, x.pfad, x.bytes, max)),
      spSection(t('sp.dateien'), files, t('sp.keineDateien'), (x, max) => spItem(x.pfad, x.pfad, x.bytes, max, x.windows ? h('span', { class: 'chip type', text: t('sp.windowsChip') }) : null)),
      files.some(x => x.windows) ? h('p', { class: 'note', text: t('sp.windowsHinweis') }) : null,
      spSection(t('sp.spieleAuf', P.letter), games, t('sp.keineSpiele', P.letter), (x, max) => spItem(x.name || x.pfad, x.pfad, x.bytes, max, x.plattform ? h('span', { class: 'chip type', text: x.plattform }) : null,
        [t('sp.zuletzt', x.zuletztGespielt ? fmtShort(x.zuletztGespielt) : '–'), x.groesseUnsicher ? t('sp.groesseEingeschraenkt') : ''])));
    const hasGames = (dataTable('Installierte Spiele') || []).length > 0;
    kids.push(h('div', { class: 'sp-foot' }, refresh, hasGames ? h('button', { type: 'button', class: 'link', 'data-f': 'games', text: t('sp.alleSpiele'), onclick: () => { closeSpPop(false); openRaw(['Installierte Spiele']); } }) : null,
      h('button', { type: 'button', class: 'link', 'data-f': 'spordner', text: t('sp.ordnerFestlegen'), onclick: gotoSpOrdner })), prog,
      h('p', { class: 'note', text: t('sp.deinstallieren') }));
  }
  pop.setAttribute('aria-label', t('sp.aria', P.letter));
  pop.replaceChildren(...kids.filter(k => k != null && k !== false));
  pop.classList.remove('hide');
  placeSpPop();
  if (had) { const b = pop.querySelector(`[data-f="${had}"]:not(:disabled)`); (b || pop).focus({ preventScroll: true }); }
}
// Gemeinsamer Speicher-Job (Speicher-Fenster und Karte „Spiele-Ordner“); onLine bekommt jede neue letzte Fortschrittszeile
async function startSpeicherRefresh(onLine) {
  const r = await api('/api/speicher/refresh', { method: 'POST' });
  const job = await followJob(r.jobId, lines => { const l = lines[lines.length - 1]; if (l && onLine) onLine(l); });
  if (job.status === 'failed') throw new Error((job.ergebnis && job.ergebnis.error) || t('sp.berechnungFehl'));
  await loadSpeicher();
}
async function spRefresh() {
  if (S.spJob || S.spoJob || readOnly()) return;
  S.spJob = { line: t('spo.startet') }; renderSpPop();
  try {
    await startSpeicherRefresh(l => { if (S.spJob) { S.spJob.line = l; const p = $('#sp-prog'); if (p) p.textContent = l; } });
    toast(t('spo.toastNeu'));
  } catch (e) { toast(e.message); }
  S.spJob = null; renderSpPop();
}

// ---------------------------------------------------------------- Routing
function reveal(check) {
  const f = findingByCheck(check); if (!f) return;
  S.ui.reveal = check;
  const v = viewOf(f);
  S.ui.f[v] = { mode: 'all', term: '' };
  if (S.einfach && !isOpen(f)) S.rest[v] = true;   // im einfachen Modus ist ein erledigter Befund sonst zugeklappt (#103)
  if (location.hash === '#/' + v) refreshView(); else location.hash = '#/' + v;
}
function doReveal() {
  const c = S.ui.reveal; if (!c) return;
  const el = [...document.querySelectorAll('.finding')].find(x => x.dataset.check === c);
  if (!el) return;
  S.ui.reveal = null;
  el.scrollIntoView({ block: 'center' });
  el.classList.remove('flash'); void el.offsetWidth; el.classList.add('flash');
}
function renderView(keepScroll) {
  S.rv++;
  const y = window.scrollY;
  const view = V[S.view] || V.uebersicht;
  let node;
  try { node = view(); } catch (e) { console.error(e); node = banner('err', 'warn', h('b', { text: t('anzeigefehler') }), e.message); }
  dOrdBannerEinsetzen(node);
  if (!keepScroll) node.classList.add('view-in');
  // Beim Neuzeichnen laden Karten (z. B. Werkzeuge) ihren Inhalt nachträglich; bis dahin ist die Seite kürzer und
  // scrollTo würde nach oben gekappt. Die alte Höhe bleibt deshalb kurz als Mindesthöhe stehen (2.5.0, Test C).
  const vw = $('#view');
  // Fokus im Inhalt merken; nach dem Neuzeichnen auf das gleiche Element bzw. die gleiche Karte (2.7, #95)
  const fk = keepScroll ? focusKey(document.activeElement) : null;
  clearTimeout(S.ui.minHT);
  vw.style.minHeight = keepScroll ? vw.offsetHeight + 'px' : '';
  if (keepScroll) S.ui.minHT = setTimeout(() => { vw.style.minHeight = ''; }, 3000);
  vw.replaceChildren(node);
  renderNav();
  if (keepScroll) window.scrollTo(0, y); else if (!S.ui.reveal) window.scrollTo(0, 0);
  if (fk && !focusRestore(fk)) vw.focus({ preventScroll: true });
  if (S.ui.reveal) doReveal();
  if (S.ui.navZiel && !keepScroll) navZielZeigen();
}
function refreshView() { renderView(true); }
function route() {
  const m = location.hash.match(/^#\/(\w+)/);
  const v = m && V[m[1]] ? m[1] : 'uebersicht';
  // Ein Unterpunkt bleibt nur markiert, wenn der Wechsel von ihm kam
  if (S.ui.navSubNeu) S.ui.navSubNeu = false; else { S.ui.navSub = null; S.ui.navZiel = null; }
  S.view = v;
  closeTips();
  renderView(false);
}

// ---------------------------------------------------------------- Sprechblasen (ⓘ)
function closeTips(except) {
  document.querySelectorAll('.tip.open').forEach(tp => { if (tp !== except) { tp.classList.remove('open'); if (tp.previousElementSibling) tp.previousElementSibling.setAttribute('aria-expanded', 'false'); } });
}
document.addEventListener('click', e => {
  const btn = e.target.closest ? e.target.closest('button.info') : null;
  if (e.target.closest && e.target.closest('.tip')) return;
  if (!btn) { closeTips(null); return; }
  const tip = btn.nextElementSibling, open = !tip.classList.contains('open');
  closeTips(tip); tip.classList.toggle('open', open); btn.setAttribute('aria-expanded', open ? 'true' : 'false');
});
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeTips(null); });

// ---------------------------------------------------------------- Sprache umschalten (2.6, #66)
const re = s => new RegExp(s, 'i');   // Muster aus gui.psd1 (Logzeilen der Schritte), Groß-/Kleinschreibung egal
/** Alle von der Sprache abhängigen Tabellen und Listen neu aufbauen (nach dem Laden der Texte). */
function buildTexts() {
  STATUS_NAME = { CRIT: t('status.crit'), WARN: t('status.warn'), TIPP: t('status.tipp'), ACK: t('status.ack'), INFO: t('status.info'), OK: t('status.ok'), SKIP: t('status.skip') };
  MENU_TEXTE = {
    gruppen: { bereiche: t('menu.gruppe.bereiche'), verwalten: t('menu.gruppe.verwalten') },
    punkte: { uebersicht: t('menu.uebersicht'), sicherheit: t('menu.sicherheit'), leistung: t('menu.leistung'), gaming: t('menu.gaming'), stabilitaet: t('menu.stabilitaet'), alle: t('menu.alle'),
      checkliste: t('menu.checkliste'), aenderungen: t('menu.aenderungen'), werkzeuge: t('menu.werkzeuge'), berichte: t('menu.berichte'), scan: t('menu.scan'), rohdaten: t('menu.rohdaten'), einstellungen: t('menu.einstellungen') },
    unter: { gamingCheck: t('menu.unter.gamingCheck'), wartung: t('menu.unter.wartung'), defender: t('menu.unter.defender'), updates: t('menu.unter.updates'),
      sysinternals: t('menu.unter.sysinternals'), spieleOrdner: t('menu.unter.spieleOrdner'), keinBericht: t('menu.unter.keinBericht') },
    filter: { problem: t('menu.filter.problem'), CRIT: t('menu.filter.crit'), WARN: t('menu.filter.warn'), TIPP: t('menu.filter.tipp'), ACK: t('menu.filter.ack'), SKIP: t('menu.filter.skip') },
    // Reihenfolge wie in der Karte „Wartung & Reparatur“
    werkzeuge: [['wiederherstellung.punkt', t('menu.werkzeug.punkt')], ['dism.checkhealth', t('menu.werkzeug.dismCheck')], ['dism.scanhealth', t('menu.werkzeug.dismScan')],
      ['dism.restorehealth', t('menu.werkzeug.dismRestore')], ['sfc.scannow', t('menu.werkzeug.sfc')], ['dism.analyze', t('menu.werkzeug.winsxsAnalyse')], ['dism.cleanup', t('menu.werkzeug.winsxsCleanup')],
      ['chkdsk.scan', t('menu.werkzeug.chkdsk')], ['perfmon.rel', t('menu.werkzeug.zuverlaessigkeit')], ['dns.flush', t('menu.werkzeug.dns')], ['trim', t('menu.werkzeug.trim')],
      ['zeit.resync', t('menu.werkzeug.zeit')], ['powercfg.energy', t('menu.werkzeug.energie')], ['powercfg.akku', t('menu.werkzeug.akku')], ['powercfg.schlaf', t('menu.werkzeug.schlaf')]],
    aria: { nav: t('menu.aria.nav'), auf: t('menu.aria.auf'), zu: t('menu.aria.zu') },
  };
  const MT = MENU_TEXTE.punkte;
  NAV = [
    { id: 'uebersicht', label: MT.uebersicht, icon: 'home' }, { group: MENU_TEXTE.gruppen.bereiche },
    { id: 'sicherheit', label: MT.sicherheit, icon: 'shield', badge: true, kinder: 'kategorien' }, { id: 'leistung', label: MT.leistung, icon: 'gauge', badge: true, kinder: 'kategorien' },
    { id: 'gaming', label: MT.gaming, icon: 'pad', badge: true, kinder: 'kategorien' }, { id: 'stabilitaet', label: MT.stabilitaet, icon: 'pulse', badge: true, kinder: 'kategorien' },
    { id: 'alle', label: MT.alle, icon: 'list', kinder: 'filter' }, { group: MENU_TEXTE.gruppen.verwalten },
    { id: 'checkliste', label: MT.checkliste, icon: 'check' }, { id: 'aenderungen', label: MT.aenderungen, icon: 'undo' }, { id: 'werkzeuge', label: MT.werkzeuge, icon: 'tool', kinder: 'werkzeuge' },
    { id: 'berichte', label: MT.berichte, icon: 'doc' }, { id: 'scan', label: MT.scan, icon: 'scan' },
    { id: 'rohdaten', label: MT.rohdaten, icon: 'db' }, { id: 'einstellungen', label: MT.einstellungen, icon: 'gear' },
    { sprache: true },
  ];
  RUN_STEPS = [
    [t('run.step.lesen'), re(t('run.re.lesen'))],
    [t('run.step.punktAnlegen'), re(t('run.re.punktAnlegen'))],
    [t('run.step.punktPruefen'), re(t('run.re.punktPruefen'))],
    [t('run.step.journal'), re(t('run.re.journal'))],
    [t('run.step.aendern'), re(t('run.re.aendern'))],
    [t('run.step.ergebnis'), re(t('run.re.ergebnis'))],
  ];
  RESULT_TEXT = { erledigt: t('run.res.erledigt'), fehlgeschlagen: t('run.res.fehlgeschlagen'), 'fehlgeschlagen-zurueckgesetzt': t('run.res.zurueckgesetzt'), zurueckgenommen: t('run.res.zurueckgenommen'),
    uebersprungen: t('run.res.uebersprungen'), 'übersprungen': t('run.res.uebersprungen'), 'uebersprungen-erreicht': t('run.res.schonErledigt'), 'uebersprungen-voraussetzung': t('run.res.voraussetzung') };
  WT_KLASSE = { diagnose: ['INFO', t('wt.k.diagnose')], wartung: ['OK', t('wt.k.wartung')], reparatur: ['WARN', t('wt.k.reparatur')] };
  WT_ERG = { ok: ['OK', t('wt.e.ok')], repariert: ['OK', t('wt.e.repariert')], reparierbar: ['WARN', t('wt.e.reparierbar')], problem: ['WARN', t('wt.e.problem')], fehler: ['CRIT', t('wt.e.fehler')], unbekannt: ['INFO', t('wt.e.unbekannt')] };
  WT_STATUS = { erledigt: t('run.res.erledigt'), fehlgeschlagen: t('run.res.fehlgeschlagen'), abgebrochen: t('wt.s.abgebrochen'), zeitueberschreitung: t('wt.s.zeit') };
  WT_PAKET = { aktualisiert: ['OK', t('wt.p.aktualisiert')], 'kein-update': ['OK', t('wt.p.keinUpdate')], neustart: ['WARN', t('karte.neustartNoetig')], 'laeuft-noch': ['WARN', t('wt.p.laeuftNoch')], fehlgeschlagen: ['CRIT', t('jr.s.fehlgeschlagen')], abgebrochen: ['INFO', t('jr.abgebrochen')] };
}
/** Statische Texte der index.html setzen: data-t = Text, data-t-title / -aria-label / -placeholder / -alt = Attribute */
function applyStatic() {
  document.documentElement.lang = LANG;
  document.querySelectorAll('[data-t]').forEach(e => { e.textContent = t(e.getAttribute('data-t')); });
  ['title', 'aria-label', 'placeholder', 'alt'].forEach(a => {
    document.querySelectorAll('[data-t-' + a + ']').forEach(e => e.setAttribute(a, t(e.getAttribute('data-t-' + a))));
  });
}
/** Texte der Oberfläche vom Server holen (liefert { sprache, texte }); bei einem Fehler bleiben die vorhandenen Texte */
async function loadTexte() {
  try {
    const r = await api('/api/texte');
    if (r && r.texte && typeof r.texte === 'object') { TX = r.texte; LANG = r.sprache === 'en' ? 'en' : 'de'; }
  } catch (e) { if (e.status === 401) throw e; }
  buildTexts(); applyStatic();
}
/** Klick auf den Sprachknopf im Menü: Sprache beim Server umstellen, Texte, Hilfe und Aktionen neu laden, alles neu zeichnen */
async function switchLang() {
  const neu = LANG === 'de' ? 'en' : 'de';
  try {
    const r = await api('/api/sprache', { method: 'POST', body: { sprache: neu } });
    await loadTexte();
    await Promise.all([loadHelp(), loadActions()]);
    closeSpPop(false);
    renderView(true); renderStatusLive(); renderStatusReport();
    if (r && r.gespeichert === false) toast(t('menu.sprache.nurFenster'));
  } catch (e) { toast(e.message); }
}

// ---------------------------------------------------------------- Start
async function init() {
  initModus();   // vor dem Laden, damit Kopfleiste und Statusleiste nicht kurz im falschen Modus erscheinen
  try { await initToken(); } catch (e) { fatal(e.message); return; }
  if (!S.token) { fatal(t('api.keinToken')); return; }
  try {
    await loadTexte();
    await loadAll();
  } catch (e) {
    if (e.status !== 401) fatal(t('api.ladenFehler', e.message));
    return;
  }
  startHeartbeat();
  initTopbar(); initStatusbar(); initNav();
  $('#skip').addEventListener('click', () => $('#view').focus());   // Sprunglink zum Inhalt (2.7, #92)
  window.addEventListener('hashchange', route);
  route();
  loadExtra();
  refreshActionStates();   // Zustände aller Aktionen beim Start lesen (dauert einige Sekunden)
}
init();
})();
