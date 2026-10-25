/* pc-check GUI (v2.0): Oberfläche in Vanilla JS.
   Kein Inline-Script, kein eval. Alle Texte aus Berichtsdaten werden per textContent eingesetzt (siehe h()). */
'use strict';
(() => {

// ---------------------------------------------------------------- Konstanten
const STATUS = ['CRIT', 'WARN', 'TIPP', 'ACK', 'INFO', 'OK', 'SKIP'];
const STATUS_NAME = { CRIT: 'Kritisch', WARN: 'Warnung', TIPP: 'Tipp', ACK: 'Akzeptiert', INFO: 'Hinweis', OK: 'OK', SKIP: 'Nicht geprüft' };
const STATUS_COLOR = { CRIT: 'var(--red)', WARN: 'var(--orange)', TIPP: 'var(--magenta)', ACK: 'var(--violet)', INFO: 'var(--blue)', OK: 'var(--green)', SKIP: 'var(--b01)' };
const RANK = { CRIT: 0, WARN: 1, TIPP: 2, INFO: 3, ACK: 4, SKIP: 5, OK: 6 };
const LEVEL = { gering: 1, mittel: 2, hoch: 3 };
const GAMING_CHECKS = ['Bildschirme und Bildwiederholrate', 'Grafikkarte und Treiber', 'Resizable BAR und PCIe-Anbindung', 'Arbeitsspeicher', 'Prozessor-Energieeinstellungen', 'Energieplan',
  'Spielebibliotheken', 'Spielmodus', 'Hardwarebeschleunigte GPU-Planung (HAGS)', 'Hintergrundaufzeichnung (Game DVR)', 'Optimierungen für Spiele im Fenstermodus',
  'Overlays und Hintergrund-Tools', 'Mausbeschleunigung', 'Netzwerkverbindung', 'Netzwerkkarte: Energiesparfunktionen', 'Virtualisierung und Spieleleistung'];
const REPORT_RE = /^pc-check_\d{4}-\d{2}-\d{2}_\d{4}$/;
const NAV = [
  { id: 'uebersicht', label: 'Übersicht', icon: 'home' }, { group: 'Bereiche' },
  { id: 'sicherheit', label: 'Sicherheit', icon: 'shield', badge: true }, { id: 'leistung', label: 'Leistung', icon: 'gauge', badge: true },
  { id: 'gaming', label: 'Gaming', icon: 'pad', badge: true }, { id: 'stabilitaet', label: 'Stabilität', icon: 'pulse', badge: true },
  { id: 'alle', label: 'Alle Prüfungen', icon: 'list' }, { group: 'Werkzeuge' },
  { id: 'checkliste', label: 'Checkliste', icon: 'check' }, { id: 'aenderungen', label: 'Änderungen', icon: 'undo' },
  { id: 'berichte', label: 'Berichte', icon: 'doc' }, { id: 'scan', label: 'Neuer Scan', icon: 'scan' },
  { id: 'rohdaten', label: 'Rohdaten', icon: 'db' }, { id: 'einstellungen', label: 'Einstellungen', icon: 'gear' },
];
const CAT_VIEWS = ['sicherheit', 'leistung', 'gaming', 'stabilitaet', 'alle'];
const LIVE_MS = 5000;
const SB_KEY = 'pcCheckStatusbar';

// ---------------------------------------------------------------- Zustand
const S = {
  token: null, session: null, reports: [], cur: null, report: null, findings: [], cache: {},
  actions: [], help: null, checklist: {}, journal: null, view: 'uebersicht', rv: 0,
  ui: { f: {}, reveal: null }, sel: new Set(), variant: {}, cmp: [], origName: null, scan: null, multiBtns: [],
  points: null, live: { state: 'idle', data: null }, sbOn: true,
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
  if (tag === 'button' && attrs && !attrs['data-mark'] && !attrs['data-filter'] && !/(btn|info|kpi|pill|srow|tile)/.test(attrs.class || '')) {
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
  return `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
function fmtWhen(s) {   // „heute 14:25“, „gestern 11:40“, sonst „24.10. 19:02“
  const d = new Date(s); if (isNaN(d)) return s || '';
  const t = `${pad(d.getHours())}:${pad(d.getMinutes())}`, now = new Date();
  const day = x => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((day(now) - day(d)) / 86400000);
  if (diff === 0) return 'heute ' + t;
  if (diff === 1) return 'gestern ' + t;
  return `${pad(d.getDate())}.${pad(d.getMonth() + 1)}. ${t}`;
}
function fmtAgo(s) {
  const d = new Date(s); if (isNaN(d)) return '–';
  const m = Math.round((Date.now() - d.getTime()) / 60000);
  if (m < 2) return 'gerade eben';
  if (m < 60) return `vor ${m} min`;
  if (m < 60 * 36) return `vor ${Math.round(m / 60)} h`;
  const t = Math.round(m / 1440);
  return t === 1 ? 'vor 1 Tag' : `vor ${t} Tagen`;
}
const dec = (v, d = 0) => (v == null || isNaN(v)) ? '–' : Number(v).toFixed(d).replace('.', ',');
function fmtShort(s) { const d = new Date(s); return isNaN(d) ? '' : `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${String(d.getFullYear()).slice(2)}`; }
function fmtState(v) {
  if (v == null) return 'nicht gesetzt';
  if (typeof v === 'object') { let t = JSON.stringify(v); if (t.length > 120) t = t.slice(0, 117) + '…'; return t; }
  return String(v);
}
function toast(msg) {
  const t = h('div', { class: 'toast', role: 'status', text: msg });
  document.body.append(t);
  setTimeout(() => t.remove(), 3500);
}
async function copyText(text, btn) {
  const label = btn ? btn.textContent : '';
  const done = ok => { if (btn) { btn.textContent = ok ? '✔ Kopiert' : 'Nicht möglich'; setTimeout(() => { btn.textContent = label; }, 2000); } else toast(ok ? 'Kopiert' : 'Kopieren nicht möglich'); };
  try { await navigator.clipboard.writeText(text); done(true); return; } catch { /* Rückfall */ }
  const ta = h('textarea', { style: 'position:fixed;left:-9999px', 'aria-hidden': 'true' });
  ta.value = text; document.body.append(ta); ta.select();
  let ok = false; try { ok = document.execCommand('copy'); } catch { ok = false; }
  ta.remove(); done(ok);
}
function levelsNode(n, a, r) {
  const parts = [['Nutzen', n, 'n'], ['Aufwand', a, 'a'], ['Risiko', r, 'r']].filter(x => x[1]);
  if (!parts.length) return null;
  return h('span', { class: 'lv' }, parts.map(x => h('span', { class: `${x[2]}-${x[1]}`, text: `${x[0]} ${x[1]}` })));
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
function cmdBlock(text, withCopy = true, label = 'PowerShell · Administrator') {
  const btn = withCopy ? h('button', { type: 'button', class: 'btn sm ghost', text: 'Kopieren', onclick: e => copyText(text, e.currentTarget) }) : null;
  const pre = h('pre'); fillCmd(pre, text);
  return h('div', { class: 'code' }, h('div', { class: 'ch' }, h('span', { text: label }), btn), pre);
}
const norm = s => (s || '').normalize('NFC');

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
  try { r = await fetch(path, opt); } catch { throw new ApiError('Keine Verbindung zur GUI. Läuft sie noch?', 0); }
  if (r.status === 401) { fatal('Sitzung abgelaufen, GUI neu starten.'); throw new ApiError('Sitzung abgelaufen, GUI neu starten.', 401); }
  const txt = await r.text();
  let data = null;
  try { data = txt ? JSON.parse(txt) : null; } catch { data = null; }
  if (!r.ok) throw new ApiError((data && data.error) || `Fehler ${r.status}`, r.status);
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
    if (!r.ok || !data || !data.token) throw new Error((data && data.error) || 'Der Startcode wurde abgelehnt. Bitte die GUI neu starten.');
    S.token = data.token;
    try { sessionStorage.setItem('pcCheckToken', S.token); } catch { /* ohne Speicher weiter */ }
  } else {
    try { S.token = sessionStorage.getItem('pcCheckToken'); } catch { S.token = null; }
  }
}
let hbFail = 0;
function startHeartbeat() {
  const beat = () => api('/api/heartbeat', { method: 'POST' }).then(() => { hbFail = 0; }, e => { if (e.status === 401) return; if (++hbFail >= 3) fatal('Verbindung zur GUI verloren. Das Fenster kann geschlossen werden.'); });
  setInterval(beat, 10000);
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
  if (!REPORT_RE.test(name)) throw new ApiError('Ungültiger Berichtsname', 400);
  if (!S.cache[name]) S.cache[name] = await api(`/api/reports/${name}.json`);
  return S.cache[name];
}
async function showReport(name) {
  const r = await loadReportJson(name);
  S.cur = name; S.report = r; S.findings = (r.Findings || []).map(f => ({ ...f, Category: norm(f.Category), Check: norm(f.Check) }));
}
async function loadReports() {
  const list = await api('/api/reports');
  S.reports = (list || []).map(r => ({ ...r, name: normName(r.name) })).filter(r => REPORT_RE.test(r.name));
}
async function loadActions() { try { S.actions = (await api('/api/actions')) || []; } catch (e) { if (e.status === 401) throw e; S.actions = []; } }
async function loadSession() { S.session = await api('/api/session'); }
async function loadAll() {
  await Promise.all([loadSession(), loadReports()]);
  await Promise.all([
    loadActions(),
    api('/api/help').then(x => { S.help = x; }, () => { S.help = null; }),
    api('/api/checklist').then(x => { S.checklist = x || {}; }, () => { S.checklist = {}; }),
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
// Nur-Lesen-Modus: der Codeordner ist nicht gesichert (oder keine Adminrechte); der Server antwortet bei Änderungen mit 403
const readOnly = () => !!(S.session && S.session.readOnly);
const locked = () => safety().schutzAn === false || readOnly();
const lockTitle = () => readOnly() ? 'Nur-Lesen-Modus: Morpheus läuft nicht aus einem gesicherten Ordner, deshalb wird nichts geändert.' : 'Computerschutz ist aus: ohne Wiederherstellungspunkt wird nichts geändert.';
function uiF(view) { return S.ui.f[view] || (S.ui.f[view] = { mode: 'all', term: '' }); }

// ---------------------------------------------------------------- Dialog
const Dlg = { prev: null, running: false };
function dlgOpen(title, body, buttons, opts = {}) {
  Dlg.running = !!opts.lock;
  if (!$('#modal').classList.contains('on')) Dlg.prev = document.activeElement;
  $('#dlg-title').textContent = title;
  $('#dlg-body').replaceChildren(...[].concat(body).filter(Boolean));
  const bx = $('#dlg-buttons'); bx.replaceChildren();
  buttons.forEach(b => bx.append(h('button', { type: 'button', class: b.primary ? 'primary' : (b.danger ? 'danger' : ''), disabled: !!b.disabled, onclick: b.onClick, text: b.label })));
  const m = $('#modal'); m.classList.add('on'); m.setAttribute('aria-hidden', 'false');
  const first = bx.querySelector('button.primary:not(:disabled)') || bx.querySelector('button:not(:disabled)');
  if (first) first.focus();
}
function dlgClose() {
  const m = $('#modal'); m.classList.remove('on'); m.setAttribute('aria-hidden', 'true'); Dlg.running = false;
  if (Dlg.prev && Dlg.prev.isConnected) Dlg.prev.focus();
}
document.addEventListener('keydown', e => {
  const m = $('#modal');
  if (!m.classList.contains('on')) return;
  if (e.key === 'Escape' && !Dlg.running) { e.preventDefault(); dlgClose(); }
  if (e.key === 'Tab') {
    const f = [...$('#dlg').querySelectorAll('button:not(:disabled),a[href],input,select,textarea,summary')].filter(x => x.offsetParent !== null);
    if (!f.length) return;
    const first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    else if (!$('#dlg').contains(document.activeElement)) { e.preventDefault(); first.focus(); }
  }
});

// ---------------------------------------------------------------- Aktionen ausführen
const RUN_STEPS = [
  ['Aktuellen Zustand lesen', /lese|zustand|vorher/i],
  ['Wiederherstellungspunkt anlegen', /wiederherstellungspunkt|checkpoint/i],
  ['Wiederherstellungspunkt prüfen', /geprüft|prüfe|vorhanden|bestätigt/i],
  ['Journal-Eintrag schreiben', /journal/i],
  ['Änderung ausführen', /ausführ|führe|setze|schalte|ändere/i],
  ['Ergebnis prüfen', /ergebnis|nachher|erledigt|kontroll/i],
];
const RESULT_TEXT = { erledigt: 'Erledigt', fehlgeschlagen: 'Fehlgeschlagen', 'fehlgeschlagen-zurueckgesetzt': 'Fehlgeschlagen, wieder zurückgesetzt', zurueckgenommen: 'Zurückgenommen', uebersprungen: 'Übersprungen', 'übersprungen': 'Übersprungen', 'uebersprungen-erreicht': 'Schon erledigt, nichts geändert', 'uebersprungen-voraussetzung': 'Nicht ausgeführt (Voraussetzung fehlt)' };
const FORCE_RE = /zustand.*ge[äa]ndert|ge[äa]ndert.*zustand/i;

/** Gemeinsame Anzeige eines laufenden Jobs im Dialog: Schritte, Live-Log, Ergebnis. */
function jobView(steps) {
  const ul = h('ul', { class: 'steps', 'aria-label': 'Ablauf' }, steps.map(s => h('li', null, h('span', { class: 's' }), s[0])));
  const log = h('pre', { class: 'log', 'aria-live': 'polite', text: '' });
  let cur = -1;
  const setLi = (li, cls) => { li.className = cls; li.firstChild.textContent = cls === 'done' ? '✓' : (cls === 'fail' ? '✕' : ''); };
  const mark = (idx, cls) => { [...ul.children].forEach((li, i) => setLi(li, i < idx ? 'done' : (i === idx ? cls : ''))); };
  return {
    nodes: [ul, log], ul, log,
    lines(arr) {
      for (const l of arr) {
        log.append(document.createTextNode(l + '\n'));
        const i = steps.findIndex((s, k) => k >= cur && s[1].test(l));
        if (i >= 0 && i >= cur) { cur = i; mark(i, 'run'); }
      }
      log.scrollTop = log.scrollHeight;
    },
    finish(ok) { if (ok) [...ul.children].forEach(li => setLi(li, 'done')); else mark(Math.max(cur, 0), 'fail'); },
  };
}
function resultList(items) {
  const arr = [].concat(items || []).filter(Boolean);
  if (!arr.length) return null;
  return h('ul', { class: 'result' }, arr.map(r => {
    const a = S.actions.find(x => x.id === r.id);
    const okc = r.status === 'erledigt' ? 'ok' : (String(r.status).startsWith('fehl') ? 'rem' : 'warn');
    return h('li', null,
      h('b', { text: a ? a.titel : (r.id || 'Aktion') }), ' ',
      h('span', { class: okc, text: RESULT_TEXT[r.status] || r.status || '' }),
      r.meldung ? h('div', { class: 'note', text: r.meldung }) : null,
      r.status === 'erledigt' && r.neustart ? h('div', { class: 'warn', text: '⟳ Für diese Änderung ist ein Neustart nötig. Er wird nicht automatisch ausgelöst.' }) : null);
  }));
}
async function afterChange() {
  await Promise.all([loadSession().catch(() => {}), loadActions()]);
  S.sel.clear(); refreshView(); loadExtra();
}
function runCmdText(a, variante) { return (a.befehle && a.befehle.ausfuehren || '').replace(/<variante>/g, variante || '<variante>'); }

function openRunDialog(actions, variante) {
  if (!actions.length) return;
  const title = actions.length > 1 ? `${actions.length} Änderungen ausführen` : actions[0].titel;
  const body = [];
  actions.forEach(a => {
    const v = a.varianten && a.varianten.length ? (variante || S.variant[a.id] || a.varianten[0]) : null;
    body.push(h('div', null, actions.length > 1 ? h('b', { text: a.titel }) : null, v ? h('div', { class: 'note', text: `Variante: ${v}` }) : null, cmdBlock(runCmdText(a, v), false)));
  });
  const noRp = actions.some(a => a.ohneWiederherstellungspunkt || a.id === 'system.wiederherstellung');
  body.push(h('div', { class: 'note', text: noRp ? 'Achtung: Diese Aktion schaltet die Wiederherstellungspunkte erst ein und kann deshalb vorher keinen anlegen.' : 'Vorher wird ein Wiederherstellungspunkt angelegt und geprüft. Fehlt er, wird nichts geändert. Jede Änderung erscheint danach unter „Änderungen“ und lässt sich einzeln zurücknehmen.' }));
  if (actions.some(a => a.neustart)) body.push(h('div', { class: 'warn', style: 'margin-top:6px', text: '⟳ Mindestens eine Änderung wirkt erst nach einem Neustart. Neu gestartet wird nicht automatisch.' }));
  dlgOpen(title, body, [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Ausführen', primary: true, onClick: () => startRun(actions, title, variante) }]);
}
async function startRun(actions, title, variante) {
  const jv = jobView(RUN_STEPS);
  const single = actions.length === 1 && actions[0].varianten && actions[0].varianten.length;
  const v = single ? (variante || S.variant[actions[0].id] || actions[0].varianten[0]) : null;
  dlgOpen(title, jv.nodes, [{ label: 'Läuft …', disabled: true }], { lock: true });
  let job = null, err = null;
  try {
    const body = { ids: actions.map(a => a.id) };
    if (v) body.variante = v;
    jv.lines(['Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …']);
    const r = await api('/api/actions/run', { method: 'POST', body });
    job = await followJob(r.jobId, jv.lines);
  } catch (e) { err = e; }
  finishJob(title, jv, job, err, 'Fertig');
}
function finishJob(title, jv, job, err, doneLabel) {
  const ok = !err && job && job.status === 'done';
  jv.finish(ok);
  const body = [...jv.nodes];
  const res = job && job.ergebnis;
  if (err) body.push(h('p', { class: 'rem', text: err.message }));
  else if (job && job.status === 'failed') body.push(h('p', { class: 'rem', text: (res && res.error) || 'Der Vorgang ist fehlgeschlagen.' }));
  const list = res && !res.error ? resultList(res) : null;
  if (list) body.push(h('h3', { text: 'Ergebnis' }), list);
  dlgOpen(title, body, [{ label: doneLabel, primary: true, onClick: dlgClose }]);
  Dlg.running = false;
  afterChange();
}

// ---------------------------------------------------------------- Rückgängig
function openUndoDialog(e) {
  const body = [
    h('p', { text: `„${e.titel || e.aktion}“ wird auf den früheren Zustand zurückgesetzt: ${fmtState(e.nachher)} → ${fmtState(e.vorher)}.` }),
    h('div', { class: 'note', text: 'Auch das Zurücknehmen ist eine Änderung: Vorher wird ein neuer Wiederherstellungspunkt angelegt und geprüft.' }),
  ];
  dlgOpen('Änderung rückgängig machen', body, [{ label: 'Abbrechen', onClick: dlgClose }, { label: '↶ Rückgängig', primary: true, onClick: () => startUndo(e, false) }]);
}
async function startUndo(e, force) {
  const title = 'Rückgängig: ' + (e.titel || e.aktion);
  const jv = jobView(RUN_STEPS);
  dlgOpen(title, jv.nodes, [{ label: 'Läuft …', disabled: true }], { lock: true });
  let job = null, err = null;
  try {
    jv.lines(['Bitte im Windows-Fenster „Morpheus – Änderung bestätigen“ mit „Ja“ bestätigen …']);
    const r = await api(`/api/journal/${encodeURIComponent(e.id)}/undo`, { method: 'POST', body: force ? { force: true } : {} });
    job = await followJob(r.jobId, jv.lines);
  } catch (x) { err = x; }
  const msg = err ? err.message : (job && job.status === 'failed' && job.ergebnis && job.ergebnis.error) || '';
  if (!force && FORCE_RE.test(msg)) {
    Dlg.running = false;
    dlgOpen(title, [h('p', { class: 'warn', text: msg }), h('p', { text: 'Der Zustand hat sich seit der Änderung geändert. Trotzdem auf den früheren Wert zurücksetzen?' })],
      [{ label: 'Abbrechen', onClick: dlgClose }, { label: 'Trotzdem zurücksetzen', danger: true, onClick: () => startUndo(e, true) }]);
    return;
  }
  finishJob(title, jv, job, err, 'Fertig');
}

// ---------------------------------------------------------------- Bausteine
function infoTip(check, cat) {
  const hp = S.help; if (!hp) return null;
  const P = hp.Pruefungen || hp.pruefungen || {}, K = hp.Kategorien || hp.kategorien || {};
  const e = P[check];
  let tip = null;
  if (e) tip = h('span', { class: 'tip', role: 'tooltip' }, h('b', { text: 'Was wird geprüft? ' }), e.Was, h('br'), h('b', { text: 'Warum wichtig? ' }), e.Warum, h('br'), h('b', { text: 'Wann ist eine Warnung harmlos? ' }), e.Harmlos);
  else if (K[cat]) tip = h('span', { class: 'tip', role: 'tooltip', text: K[cat] });
  if (!tip) return null;
  return [h('button', { type: 'button', class: 'info', 'aria-label': 'Erklärung', 'aria-expanded': 'false', text: 'i' }), tip];
}
function howTo(f) {
  const steps = f.Steps || [];
  if (!steps.length && !f.Command) return null;
  return h('details', { class: 'how' }, h('summary', { text: 'So geht\'s' }),
    steps.length ? h('ol', null, steps.map(s => h('li', { text: s }))) : null,
    f.Command ? cmdBlock(f.Command) : null);
}
function actionCard(a) {
  const z = a.zustand || {};
  const done = z.aktiv === true, lock = locked();
  const hasVar = a.varianten && a.varianten.length;
  const stateNode = h('span', { class: 'state ' + (z.aktiv === true ? 'on' : (z.aktiv === false ? 'off' : 'unk')), title: z.stand ? `Gelesen: ${fmtDate(z.stand)}` : null },
    h('i'), z.wert != null && z.wert !== '' ? `Zustand: ${z.wert}${done ? ' ✓' : ''}` : 'Zustand unbekannt');
  let sel = null, curCmd = runCmdText(a, hasVar ? (S.variant[a.id] || a.varianten[0]) : null);
  const cmdPre = h('pre'); fillCmd(cmdPre, curCmd);
  if (hasVar) {
    sel = h('select', { 'aria-label': 'Variante', onchange: e => { S.variant[a.id] = e.target.value; curCmd = runCmdText(a, e.target.value); fillCmd(cmdPre, curCmd); } },
      a.varianten.map(v => h('option', { value: v, selected: (S.variant[a.id] || a.varianten[0]) === v, text: v })));
  }
  const chk = (!hasVar && !done && !lock)
    ? h('input', { type: 'checkbox', checked: S.sel.has(a.id), 'aria-label': `${a.titel} auswählen`, onchange: e => { if (e.target.checked) S.sel.add(a.id); else S.sel.delete(a.id); updateMulti(); } })
    : null;
  const btn = done ? h('button', { type: 'button', class: 'sm', disabled: true, text: 'Bereits erledigt' })
    : lock ? h('button', { type: 'button', class: 'sm', disabled: true, title: lockTitle(), text: 'Gesperrt' })
      : h('button', { type: 'button', class: 'sm primary', text: 'Ausführen', onclick: () => openRunDialog([a], sel ? sel.value : null) });
  const expl = (a.befehle && a.befehle.erklaerung) || [];
  const copyBtn = h('button', { type: 'button', class: 'copy', text: 'Kopieren', onclick: e => copyText(curCmd, e.currentTarget) });
  return h('div', { class: 'action' + (done ? ' quiet' : ''), 'data-id': a.id },
    h('div', { class: 'ah' }, chk, h('span', { class: 'at', text: a.titel }), levelsNode(a.nutzen, a.aufwand, a.risiko),
      a.neustart ? h('span', { class: 'lv' }, h('span', { class: 'restart', text: 'Neustart nötig' })) : null,
      h('div', { class: 'acts' }, sel, stateNode, btn)),
    a.erklaerung ? h('p', { class: 'ae', text: a.erklaerung }) : null,
    h('details', { class: 'cmd' }, h('summary', { text: 'Befehl zeigen und erklären' }),
      h('div', { class: 'code' }, h('div', { class: 'ch' }, h('span', { text: 'PowerShell · Administrator' }), copyBtn), cmdPre),
      expl.length ? h('ul', { class: 'explain' }, expl.map(x => h('li', { text: x }))) : null,
      a.befehle && a.befehle.rueckgaengig ? h('div', { class: 'note' }, 'Rückgängig: ', h('code', { text: a.befehle.rueckgaengig }), ' (der vorherige Wert wird im Journal gespeichert)') : null));
}
function updateMulti() {
  const n = S.sel.size;
  S.multiBtns.forEach(b => { b.disabled = !n || locked(); b.textContent = `Ausgewählte ausführen (${n})`; });
}
function findingRow(f, opts = {}) {
  const m = S.checklist[f.Check];
  const acts = actionsFor(f);
  const note = f.Status === 'ACK' ? `Ursprünglich: ${STATUS_NAME[f.OriginalStatus] || f.OriginalStatus || ''} · ${f.Note || ''}` : f.Note;
  const todo = isOpen(f) ? h('div', { class: 'todo' },
    h('button', { type: 'button', class: m && m.state === 'done' ? 'on' : '', 'data-mark': 'done', title: 'Als erledigt markieren; der nächste Lauf zeigt, ob es wirklich behoben ist', text: '✔ erledigt', onclick: () => toggleMark(f.Check, 'done') }),
    h('button', { type: 'button', class: m && m.state === 'later' ? 'on' : '', 'data-mark': 'later', title: 'Für später vormerken', text: '⏱ später', onclick: () => toggleMark(f.Check, 'later') })) : null;
  const lvl = levelsNode(f.Benefit, f.Effort, f.Risk);
  const tbls = tablesFor(f.Check);
  const dataBtn = tbls.length ? h('button', { type: 'button', class: 'btn sm ghost data-link', title: 'Die Detailtabelle(n) zu dieser Prüfung im Anhang (Rohdaten) öffnen', text: `📋 Daten ansehen${tbls.length > 1 ? ` (${tbls.length})` : ''}`, onclick: () => openRaw(tbls) }) : null;
  return h('div', { class: 'card finding' + (m && m.state === 'done' ? ' m-done' : ''), 'data-check': f.Check, 'data-status': f.Status },
    h('div', { class: 'fhead' },
      h('span', { class: 'chip ' + f.Status, text: STATUS_NAME[f.Status] || f.Status }),
      h('span', { class: 'fname' }, f.Check, infoTip(f.Check, f.Category)),
      opts.hint ? h('span', { class: 'cat-hint', text: `${f.Area} · ${f.Category}` }) : null,
      dataBtn, todo),
    h('p', { class: 'fval', text: f.Value }),
    note ? h('div', { class: 'fnote', text: note }) : null,
    f.Recommendation ? h('div', { class: 'frec', text: f.Recommendation }) : null,
    lvl ? h('div', { class: 'lvwrap' }, lvl) : null,
    howTo(f),
    acts.map(actionCard));
}
function toggleMark(check, state) {
  const m = S.checklist[check];
  if (m && m.state === state) delete S.checklist[check];
  else S.checklist[check] = { state, date: new Date().toLocaleDateString('de-DE'), report: S.report.Meta.Erstellt };
  api('/api/checklist', { method: 'POST', body: S.checklist }).catch(e => toast('Checkliste nicht gespeichert: ' + e.message));
  refreshView();
}
function banner(kind, iconId, ...kids) { return h('div', { class: 'banner' + (kind ? ' b-' + kind : '') }, icon(iconId), h('div', null, ...kids)); }
function reportBar() {
  if (!S.reports.length || S.cur === S.reports[0].name) return null;
  return banner('info', 'doc', h('b', { text: 'Du siehst den Bericht vom ' + fmtDate(S.report.Meta.Erstellt) + '. ' }), 'Es gibt einen neueren. ',
    h('button', { type: 'button', class: 'link', text: 'Zum neuesten Bericht', onclick: async () => { try { await showReport(S.reports[0].name); refreshView(); } catch (e) { toast(e.message); } } }));
}
function safetyBanner() {
  const s = safety();
  if (readOnly()) {
    return banner('err', 'warn', h('b', { text: 'Nur-Lesen-Modus: ' }), (S.session.readOnlyReason || 'Morpheus läuft nicht aus einem gesicherten Ordner.') + ' Änderungen, „Rückgängig“ und Scans sind gesperrt. Starte Morpheus über das Startmenü bzw. ',
      h('code', { text: 'C:\\Program Files\\Morpheus\\pc-check-gui.cmd' }), '.');
  }
  if (s.schutzAn === false) {
    const cmd = `Enable-ComputerRestore -Drive '${(s.laufwerk || 'C:').replace(/\\$/, '')}\\'`;
    return banner('err', 'warn', h('b', { text: 'Computerschutz ist aus: ' }), 'Ohne Wiederherstellungspunkt führt die GUI keine Änderungen aus. Alle Ausführen-Buttons sind gesperrt.',
      h('details', { class: 'cmd' }, h('summary', { text: 'Befehl zum Einschalten (Administrator-PowerShell)' }), cmdBlock(cmd),
        h('ul', { class: 'explain' }, h('li', { text: 'Schaltet den Computerschutz (Systemwiederherstellung) für das Laufwerk ein. Danach die GUI-Seite neu laden.' }))));
  }
  if (s.sperre24h) {
    return banner('', 'warn', h('b', { text: '24-Stunden-Sperre aktiv. ' }), 'Windows legt höchstens einen Wiederherstellungspunkt pro 24 Stunden an. Solange das so ist, kann die GUI heute eventuell keine weitere Änderung absichern und führt sie dann nicht aus.',
      h('details', { class: 'cmd' }, h('summary', { text: 'Befehl zum Aufheben der Sperre (einmalig, Administrator-PowerShell)' }), cmdBlock(s.befehl || ''),
        h('ul', { class: 'explain' }, h('li', { text: 'Setzt den Mindestabstand zwischen zwei Wiederherstellungspunkten auf 0 Minuten.' }), h('li', null, 'Rückgängig: den Wert wieder löschen (', h('code', { text: 'Remove-ItemProperty … -Name SystemRestorePointCreationFrequency' }), ').'))));
  }
  return null;
}
function tableFrom(rows, max = 300) {
  rows = (rows || []).filter(r => r != null);
  if (!rows.length) return h('p', { class: 'muted', text: 'Keine Einträge.' });
  const cols = Object.keys(rows[0]);
  const t = h('div', { class: 'tablewrap' }, h('table', null,
    h('thead', null, h('tr', null, cols.map(c => h('th', { text: c })))),
    h('tbody', null, rows.slice(0, max).map(r => h('tr', null, cols.map(c => h('td', { text: r[c] == null ? '' : (typeof r[c] === 'object' ? JSON.stringify(r[c]) : r[c]) })))))));
  return rows.length > max ? h('div', null, t, h('p', { class: 'muted', text: `… ${rows.length - max} weitere Einträge im JSON-Bericht.` })) : t;
}
function noReport() {
  return h('div', { class: 'card' }, h('h2', { text: 'Noch kein Bericht vorhanden' }), h('p', null, 'Starte unter ', h('a', { href: '#/scan', text: 'Neuer Scan' }), ' die erste Prüfung.'));
}

// ---------------------------------------------------------------- Navigation und Kopfleiste
function badgeFor(id) {
  if (!S.report) return null;
  const list = S.findings.filter(f => viewOf(f) === id);
  const c = counts(list), n = c.CRIT + c.WARN + c.TIPP;
  if (!n) return null;
  return h('span', { class: 'cnt ' + (c.CRIT ? 'c' : c.WARN ? 'w' : 't'), title: `${c.CRIT} kritisch, ${c.WARN} Warnungen, ${c.TIPP} Tipps`, text: String(n) });
}
function renderNav() {
  const sess = S.session || {};
  $('#nav').replaceChildren(h('div', { class: 'navgroup' }, NAV.map(n => {
    if (n.group) return h('div', { class: 'navh', text: n.group });
    let b = null;
    if (n.badge) b = badgeFor(n.id);
    else if (n.id === 'berichte') b = S.reports.length ? h('span', { class: 'cnt n', text: String(S.reports.length) }) : null;
    else if (n.id === 'checkliste') { const k = Object.keys(S.checklist).length; b = k ? h('span', { class: 'cnt i', text: String(k) }) : null; }
    return h('a', { href: '#/' + n.id, class: S.view === n.id ? 'on' : '', 'aria-current': S.view === n.id ? 'page' : null }, icon(n.icon), n.label, b);
  })));
  $('#side-foot').replaceChildren(h('span', { class: 'dot' }), `${sess.pc || ''}${sess.version ? ' · v' + sess.version : ''}${sess.admin ? ' · Admin' : ''}`);
  updateChrome();
}
function updateChrome() {
  const m = S.report && S.report.Meta;
  $('#crumb').replaceChildren(...(m ? ['Bericht vom ', h('b', { text: fmtDate(m.Erstellt) }), ` · Profil ${m.Profil || '–'}`] : ['Noch kein Bericht vorhanden']));
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
    if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey || $('#modal').classList.contains('on')) return;
    const t = e.target, tag = t && t.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || (t && t.isContentEditable)) return;
    e.preventDefault(); gs.focus(); gs.select();
  });
  $('#ki-btn').addEventListener('click', e => { if (S.report) copyText(buildKi(), $('#ki-btn span')); });
}

// ---------------------------------------------------------------- Ansicht: Kategorien
const FILTERS = [['all', 'Alle'], ['problem', 'Probleme'], ['CRIT', 'Kritisch'], ['WARN', 'Warnungen'], ['TIPP', 'Tipps'], ['INFO', 'Hinweise'], ['ACK', 'Akzeptiert'], ['OK', 'OK'], ['SKIP', 'Nicht geprüft']];
function passes(f, st) {
  let ok = st.mode === 'all' || (st.mode === 'problem' ? isProblem(f) : f.Status === st.mode);
  if (ok && st.term) ok = `${f.Check} ${f.Value} ${f.Recommendation} ${f.Category}`.toLowerCase().includes(st.term);
  return ok;
}
function miniChips(list) {
  const c = counts(list);
  return [...STATUS.filter(s => c[s] && s !== 'OK'), ...(c.OK ? ['OK'] : [])].map(s => h('span', { class: 'chip ' + s, text: `${c[s]} ${STATUS_NAME[s]}` }));
}
function catView(id, title, sub, pred, extra) {
  const fs = S.findings.filter(pred), st = uiF(id);
  const box = h('div');
  const filtBtns = FILTERS.map(([m, l]) => h('button', { type: 'button', 'data-filter': m, class: st.mode === m ? 'active' : '', text: l, onclick: () => { st.mode = m; build(); } }));
  const multi = h('button', { type: 'button', class: 'primary', text: 'Ausgewählte ausführen (0)', disabled: true, onclick: () => openRunDialog(S.actions.filter(a => S.sel.has(a.id))) });
  const hasActions = S.actions.length > 0;
  const bar = h('div', { class: 'toolbar sticky' }, h('div', { class: 'filters', role: 'group', 'aria-label': 'Filter nach Status' }, filtBtns), hasActions ? h('div', { class: 'tools' }, multi) : null);
  if (hasActions) { S.multiBtns = [multi]; }
  const mine = S.actions.filter(a => actionView(a) === id && !findingByCheck(norm(a.pruefung)));
  function build() {
    filtBtns.forEach(b => b.classList.toggle('active', b.dataset.filter === st.mode));
    const groups = [];
    fs.forEach(f => { let g = groups.find(x => x.cat === f.Category); if (!g) groups.push(g = { cat: f.Category, all: [], vis: [] }); g.all.push(f); if (passes(f, st)) g.vis.push(f); });
    const nodes = [];
    groups.forEach(g => {
      if (!g.vis.length) return;
      nodes.push(h('div', { class: 'section-title' }, h('h3', null, g.cat, infoTip('', g.cat)), miniChips(g.all), h('span', { class: 'bar' })));
      g.vis.forEach(f => nodes.push(findingRow(f)));
    });
    if (!nodes.length && fs.length) nodes.push(h('div', { class: 'card muted', text: 'Keine Prüfung passt zu Filter und Suche.' }));
    if (!fs.length && !mine.length) nodes.push(h('div', { class: 'card muted', text: 'Keine Prüfungen in diesem Bereich.' }));
    if (mine.length && st.mode === 'all' && !st.term) nodes.push(h('div', { class: 'more' }, h('div', { class: 'section-title' }, h('h3', { text: 'Weitere Anpassungen' }), h('span', { class: 'bar' })), h('div', { class: 'card' }, mine.map(actionCard))));
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
  return h('div', null, h('div', { class: 'section-title' }, h('h3', { text: 'Gaming-Check' }), h('span', { class: 'bar' })), h('div', { class: 'card' }, h('div', { class: 'gaming' }, rows.map(f =>
    h('div', { class: 'g-item', style: `--c:${STATUS_COLOR[f.Status]}` },
      h('span', { class: 'chip ' + f.Status, text: STATUS_NAME[f.Status] }),
      h('a', { href: '#/gaming', text: f.Check, onclick: e => { e.preventDefault(); reveal(f.Check); } }),
      h('div', { class: 'v', text: f.Value }))))));
}
const V = {};
V.sicherheit = () => catView('sicherheit', 'Sicherheit', 'Kategorien 1–10 des Berichts · Anpassungen mit Button lassen sich direkt und abgesichert umsetzen.', f => viewOf(f) === 'sicherheit');
V.leistung = () => catView('leistung', 'Leistung', 'Hardware · Laufwerke & Speicherplatz · Energie · Auslastung', f => viewOf(f) === 'leistung');
V.gaming = () => catView('gaming', 'Gaming', 'Gaming & Grafik und die spielerelevanten Prüfungen', f => viewOf(f) === 'gaming', gamingGrid);
V.stabilitaet = () => catView('stabilitaet', 'Stabilität', 'Abstürze, Bluescreens, Treiberfehler und Startdauer', f => viewOf(f) === 'stabilitaet');
V.alle = () => catView('alle', 'Alle Prüfungen', 'Alle Bereiche, gefiltert nach Status oder Suchbegriff', () => true);

// ---------------------------------------------------------------- Ansicht: Übersicht
/** Zustandswert: 100 − 20·Kritisch − 5·Warnung − 1·Tipp (mindestens 0). */
const scoreOf = c => Math.max(0, 100 - 20 * (c.CRIT || 0) - 5 * (c.WARN || 0) - (c.TIPP || 0));
function scoreInfo(v) {
  if (v >= 85) return { title: 'Gut in Form', c1: '#2aa198', c2: '#859900' };
  if (v >= 60) return { title: 'Einige Punkte prüfen', c1: '#b58900', c2: '#e0b23a' };
  return { title: 'Handlungsbedarf', c1: '#cb4b16', c2: '#dc322f' };
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
  const s = svg('svg', { viewBox: `0 0 ${w} ${hh}`, preserveAspectRatio: 'none', role: 'img', 'aria-label': title });
  const line = xy.map(p => `${p.x},${p.y}`).join(' ');
  const gid = 'ga' + Math.random().toString(36).slice(2, 8);
  const defs = svg('defs'), lg = svg('linearGradient', { id: gid, x1: '0', y1: '0', x2: '0', y2: '1' });
  lg.append(svg('stop', { offset: '0', 'stop-color': color || '#2aa198', 'stop-opacity': '.35' }), svg('stop', { offset: '1', 'stop-color': color || '#2aa198', 'stop-opacity': '0' }));
  defs.append(lg); s.append(defs);
  s.append(svg('path', { class: 'area', d: `M${xy[0].x},${hh} L${line.replace(/ /g, ' L')} L${xy[xy.length - 1].x},${hh}Z`, fill: `url(#${gid})` }));
  s.append(svg('polyline', { points: line }));
  xy.forEach(p => { const c = svg('circle', { cx: p.x, cy: p.y, r: 3 }); const t = svg('title'); t.textContent = `${p.d}: ${p.v} ${unit}`; c.append(t); s.append(c); });
  return h('div', { class: 'chart', style: color ? `--c:${color}` : null },
    h('div', { class: 'chart-head' }, h('span', { text: title }), h('span', { class: trend === 'gleich' ? 'muted' : (trend === 'besser' ? 'trend up' : 'trend down'), text: trend })),
    h('div', { class: 'n', text: `${last}${unit ? ' ' + unit : ''}` }),
    s, h('div', { class: 'chart-foot' }, h('span', { text: xy[0].d }), h('span', { text: xy[xy.length - 1].d })));
}
function historyPoint(r, created) {
  const F = r.Findings || [], D = r.Data || {};
  const boot = (D['Startdauer (letzte Messungen)'] || []).filter(Boolean).map(x => Number(x.HauptpfadSek)).filter(x => !isNaN(x));
  const rel = F.find(f => norm(f.Check) === 'Zuverlässigkeitsindex');
  const mm = rel && /^([\d.,]+) von/.exec(rel.Value || '');
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
    const nodes = [chartNode('Zustandswert', pts, 'zustand', 'von 100', 'high', '#2aa198'), chartNode('Probleme (Kritisch + Warnung)', pts, 'probleme', '', 'low', '#cb4b16'), chartNode('Startdauer bis Desktop', pts, 'startSek', 's', 'low', '#268bd2'),
      chartNode('Zuverlässigkeitsindex', pts, 'index', 'von 10', 'high', '#6c71c4'), chartNode('Freier Platz auf C:', pts, 'freiC', '%', 'high', '#859900')].filter(Boolean);
    box.replaceChildren(...(nodes.length ? nodes : [h('p', { class: 'muted', text: 'Für einen Verlauf braucht es mindestens zwei Berichte.' })]));
  };
  draw(quick);
  if (list.length < 2) return;
  const full = await Promise.all(list.map(async (r, i) => { try { return historyPoint(await loadReportJson(r.name), r.created); } catch { return quick[i]; } }));
  draw(full);
}
function plural(n, one, many) { return `${n} ${n === 1 ? one : many}`; }
function heroText(c) {
  const parts = [c.CRIT && plural(c.CRIT, 'kritischer Punkt', 'kritische Punkte'), c.WARN && plural(c.WARN, 'Warnung', 'Warnungen'), c.TIPP && plural(c.TIPP, 'lohnender Tipp', 'lohnende Tipps')].filter(Boolean);
  if (!parts.length) return 'Keine offenen Punkte.';
  const n = (c.CRIT || 0) + (c.WARN || 0) + (c.TIPP || 0);
  return `${c.CRIT ? '' : 'Nichts Kritisches. '}${parts.length > 1 ? parts.slice(0, -1).join(', ') + ' und ' + parts[parts.length - 1] : parts[0]} ${n === 1 ? 'wartet' : 'warten'} auf dich.`;
}
function ringNode(score) {
  const C = 351.86, si = scoreInfo(score);
  const s = svg('svg', { viewBox: '0 0 132 132', 'aria-hidden': 'true' });
  const defs = svg('defs'), g = svg('linearGradient', { id: 'gr', x1: '0', y1: '0', x2: '1', y2: '1' });
  g.append(svg('stop', { offset: '0', 'stop-color': si.c1 }), svg('stop', { offset: '1', 'stop-color': si.c2 }));
  defs.append(g);
  const val = svg('circle', { class: 'val', cx: 66, cy: 66, r: 56, stroke: 'url(#gr)', 'stroke-width': 12, fill: 'none', 'stroke-linecap': 'round', 'stroke-dasharray': C, 'stroke-dashoffset': C });
  s.append(defs, svg('circle', { cx: 66, cy: 66, r: 56, stroke: '#ffffff12', 'stroke-width': 12, fill: 'none' }), val);
  requestAnimationFrame(() => requestAnimationFrame(() => val.setAttribute('stroke-dashoffset', String(+(C * (1 - score / 100)).toFixed(1)))));
  return h('div', { class: 'ring', role: 'img', 'aria-label': `Zustandswert ${score} von 100` }, s, h('div', { class: 'v' }, h('div', null, h('b', { text: String(score) }), h('span', { text: 'von 100' }))));
}
/** Zeile in „Nächste Schritte“ / „Lohnende Tipps“. */
function stepRow(f, showLevels) {
  const open = actionsFor(f).filter(a => !(a.zustand && a.zustand.aktiv === true) && !(a.varianten && a.varianten.length));
  const go = e => { e.preventDefault(); reveal(f.Check); };
  let btn;
  if (open.length === 1 && !locked()) btn = h('button', { type: 'button', class: 'sm primary', text: 'Ausführen', onclick: () => openRunDialog([open[0]]) });
  else btn = h('button', { type: 'button', class: 'sm', text: (f.Steps && f.Steps.length) || f.Command ? 'So geht\'s' : 'Ansehen', onclick: go });
  return h('div', { class: 'row' }, h('span', { class: 'chip ' + f.Status, text: STATUS_NAME[f.Status] }),
    h('div', null, h('div', { class: 't' }, h('a', { href: '#/' + viewOf(f), text: f.Check, onclick: go }), showLevels ? levelsNode(f.Benefit, f.Effort, f.Risk) : null),
      h('div', { class: 'd', text: f.Recommendation || f.Value })), btn);
}
V.uebersicht = () => {
  if (!S.report) return h('section', null, h('h1', { text: 'Übersicht' }), noReport());
  const m = S.report.Meta, c = counts(S.findings), score = scoreOf(c), si = scoreInfo(score);
  const todo = S.findings.filter(isProblem).sort((a, b) => RANK[a.Status] - RANK[b.Status] || (a.Area === 'Sicherheit' ? 0 : 1) - (b.Area === 'Sicherheit' ? 0 : 1) || a.Category.localeCompare(b.Category, 'de'));
  const tips = S.findings.filter(f => f.Status === 'TIPP').sort((a, b) => tipScore(b) - tipScore(a) || a.Area.localeCompare(b.Area, 'de') || a.Category.localeCompare(b.Category, 'de'));
  const charts = h('div', { class: 'charts' }, h('p', { class: 'muted', text: 'Lädt …' }));
  const hp = S.help && (S.help.Status || S.help.status);
  const ch = S.report.Changes;
  const token = S.rv;
  const toFilter = s => () => { S.ui.f.alle = { mode: s, term: '' }; if (location.hash === '#/alle') refreshView(); else location.hash = '#/alle'; };
  const pill = (s, label, color) => h('button', { type: 'button', class: 'pill', style: `--c:${color}`, title: hp && hp[s] ? hp[s] : 'Nur diese anzeigen', onclick: toFilter(s) }, h('i'), `${c[s]} ${label}`);
  const kpi = (s, label) => h('button', { type: 'button', class: 'kpi', style: `--c:${STATUS_COLOR[s]}`, title: hp && hp[s] ? hp[s] : 'Nur diese anzeigen', onclick: toFilter(s) }, h('b', { text: String(c[s]) }), h('span', null, h('i'), label));
  const root = h('section', null,
    h('h1', { text: 'Übersicht' }),
    h('p', { class: 'sub', text: `Was auf deinem PC gut läuft und was sich noch lohnt. · Bericht vom ${fmtDate(m.Erstellt)} · Adminrechte ${m.Admin ? 'ja' : 'nein'}${m.DauerSek != null ? ' · Dauer ' + m.DauerSek + ' s' : ''} · ${m.Computer || ''}` }),
    reportBar(), safetyBanner(),
    h('div', { class: 'grid g-hero' },
      h('div', { class: 'card hero' }, ringNode(score),
        h('div', null, h('h3', { text: si.title }), h('p', { text: heroText(c) }),
          h('div', { class: 'pills' }, pill('OK', 'OK', 'var(--green)'), pill('ACK', c.ACK === 1 ? 'akzeptiert' : 'akzeptiert', 'var(--cyan)'), pill('INFO', c.INFO === 1 ? 'Hinweis' : 'Hinweise', 'var(--blue)')),
          h('div', { class: 'formula', text: 'Zustandswert = 100 − 20 · Kritisch − 5 · Warnung − 1 · Tipp' }))),
      h('div', { class: 'card' }, h('h2', { text: 'Auf einen Blick' }),
        h('div', { class: 'kpis' }, kpi('CRIT', 'Kritisch'), kpi('WARN', 'Warnungen'), kpi('TIPP', 'Tipps'), kpi('SKIP', 'Nicht geprüft')))),
    h('div', { class: 'grid g-2' },
      h('div', { class: 'card' }, h('h2', null, 'Nächste Schritte', h('span', { class: 'hint', text: 'Kritisch und Warnungen' })),
        todo.length ? [h('div', { class: 'list' }, todo.slice(0, 3).map(f => stepRow(f, false))), todo.length > 3 ? h('p', { class: 'note' }, `Insgesamt ${todo.length} Punkte mit Handlungsbedarf. `, h('a', { href: '#/alle', text: 'Alle anzeigen', onclick: () => { S.ui.f.alle = { mode: 'problem', term: '' }; } })) : null]
          : h('p', { text: 'Kein Handlungsbedarf. 🎉' })),
      h('div', { class: 'card' }, h('h2', null, 'Lohnende Tipps', h('span', { class: 'hint', text: 'sortiert nach Nutzen' })),
        tips.length ? [h('div', { class: 'list' }, tips.slice(0, 5).map(f => stepRow(f, true))),
          tips.length > 5 ? h('p', { class: 'note' }, `Insgesamt ${tips.length} Tipps. `, h('a', { href: '#/alle', text: 'Alle anzeigen', onclick: () => { S.ui.f.alle = { mode: 'TIPP', term: '' }; } })) : null]
          : h('p', { class: 'muted', text: 'Keine Tipps.' }))),
    h('div', { class: 'card' }, h('h2', null, 'Verlauf', h('span', { class: 'hint', text: 'letzte bis zu 12 Berichte · Punkte berühren für Datum und Wert' })), charts),
    ch ? changesCard(ch) : null,
    hp ? h('details', { class: 'card' }, h('summary', { text: 'So liest du die Statuswerte' }), h('ul', null, STATUS.map(s => h('li', null, h('span', { class: 'chip ' + s, text: STATUS_NAME[s] }), ' ', hp[s] || '')))) : null);
  fillCharts(charts, token);
  return root;
};
function changesCard(ch) {
  const status = ch.Status || [], bestand = ch.Bestand || {};
  let prev = ch.Erstellt ? fmtDate(ch.Erstellt) : '';
  return h('details', { class: 'card' }, h('summary', { text: 'Änderungen seit dem letzten Lauf' }),
    h('p', { class: 'muted', text: `Verglichen mit dem Bericht vom ${prev}.${ch.AdminVorher === false ? ' Achtung: Der vorige Lauf hatte keine Adminrechte, ein Teil der Unterschiede kann daher stammen.' : ''}` }),
    status.length ? [h('h3', { text: 'Geänderte Prüfergebnisse' }), tableFrom(status)] : null,
    Object.keys(bestand).map(t => h('div', null, h('h3', { text: t }), h('ul', { class: 'chg' },
      (bestand[t].Neu || []).map(x => h('li', { class: 'add', text: '➕ ' + x })), (bestand[t].Entfernt || []).map(x => h('li', { class: 'rem', text: '➖ ' + x }))))),
    !status.length && !Object.keys(bestand).length ? h('p', { text: 'Keine Änderungen.' }) : null);
}

// ---------------------------------------------------------------- KI-Kopie (Anonymisierung wie Protect-Text in pc-check.ps1)
const reEsc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
function protect(text, ctx) {
  if (!text) return '';
  let t = String(text);
  if (ctx.pc) t = t.replace(new RegExp(reEsc(ctx.pc), 'gi'), '<PC>');
  if (ctx.user && ctx.user.length >= 3) t = t.replace(new RegExp(reEsc(ctx.user), 'gi'), '<Benutzer>');
  t = t.replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, '<E-Mail>')
    .replace(/S-1-5-21-[\d-]+/gi, '<SID>')
    .replace(/\b([0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b/gi, '<MAC>')
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '<IP>')
    .replace(/\bfe80:[0-9a-f:%]*|\b[0-9a-f]{4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f:]+/gi, '<IPv6>')
    .replace(/(\\Users\\)[^\\\s"']+/gi, '$1<Benutzer>'); // zusätzlich zur PS-Fassung: Profilordner
  return t;
}
function buildKi() {
  const m = S.report.Meta, sys = ((S.report.Data || {}).System || [])[0] || {};
  const ctx = { pc: m.Computer || (S.session && S.session.pc) || '', user: (S.session && (S.session.benutzer || S.session.user)) || ((S.journal || [])[0] || {}).benutzer || '' };
  const c = counts(S.findings), L = [];
  L.push('Ich habe meinen Windows-PC mit dem Prüfscript Morpheus (pc-check) untersucht. Bitte erkläre mir die folgenden Befunde verständlich,');
  L.push('bewerte, wie dringend sie sind, und sag mir Schritt für Schritt, was ich tun sollte. Frag nach, wenn dir Angaben fehlen.', '');
  L.push(`System: ${sys.Edition || 'Windows'}, Version ${sys.Version || ''}; Morpheus ${m.Version || ''}; Adminrechte: ${m.Admin ? 'ja' : 'nein'}`);
  L.push(`Nutzung: ${m.Profil || ''}`);
  L.push(`Übersicht: ${c.CRIT} kritisch, ${c.WARN} Warnungen, ${c.TIPP} Tipps, ${c.ACK} akzeptiert, ${c.INFO} Hinweise, ${c.OK} OK`);
  ['CRIT', 'WARN', 'TIPP', 'ACK', 'INFO'].forEach(s => {
    const list = S.findings.filter(f => f.Status === s);
    if (!list.length) return;
    L.push('', `== ${STATUS_NAME[s]} ==`);
    list.forEach(f => {
      L.push(`- [${f.Area} / ${f.Category}] ${f.Check}: ${protect(f.Value, ctx)}`);
      if (f.Recommendation) L.push(`  Empfehlung des Scripts: ${protect(f.Recommendation, ctx)}`);
      if (s === 'ACK') L.push(`  Von mir bewusst akzeptiert: ${protect(f.Note, ctx)}`);
    });
  });
  return L.join('\n');
}

// ---------------------------------------------------------------- Ansicht: Checkliste
V.checkliste = () => {
  if (!S.report) return h('section', null, h('h1', { text: 'Meine Checkliste' }), noReport());
  const created = S.report.Meta.Erstellt;
  const groups = { open: [], fixed: [], pending: [], later: [] };
  Object.keys(S.checklist).forEach(c => {
    const m = S.checklist[c], f = findingByCheck(c), still = f ? isOpen(f) : false;
    const g = m.state === 'later' ? (still ? 'later' : 'fixed') : (!still ? 'fixed' : (m.report === created ? 'pending' : 'open'));
    groups[g].push({ c, f, d: m.date });
  });
  const titles = { open: 'Als erledigt markiert, aber weiterhin gemeldet', fixed: 'Behoben (bestätigt durch diesen Bericht)', pending: 'Als erledigt markiert (der nächste Lauf bestätigt es)', later: 'Für später vorgemerkt' };
  const body = ['open', 'fixed', 'pending', 'later'].filter(g => groups[g].length).map(g => h('div', null,
    h('h3', { class: g === 'open' ? 'rem' : (g === 'fixed' ? 'add' : ''), text: titles[g] }),
    h('ul', { class: 'checklist' }, groups[g].map(x => h('li', null,
      x.f ? h('a', { href: '#/' + viewOf(x.f), text: x.c, onclick: e => { e.preventDefault(); reveal(x.c); } }) : x.c,
      h('span', { class: 'muted', text: ` – markiert am ${x.d}` }))))));
  const any = body.length;
  return h('section', null, h('h1', { text: 'Meine Checkliste' }), h('p', { class: 'sub', text: 'Bei Warnungen und Tipps kannst du „✔ erledigt“ oder „⏱ später“ anklicken. Der nächste Bericht zeigt, was wirklich behoben ist.' }), reportBar(),
    h('div', { class: 'card' }, any ? body : h('p', { class: 'muted', text: 'Noch nichts markiert.' })),
    any ? h('button', { type: 'button', class: 'danger', text: 'Markierungen löschen', onclick: () => dlgOpen('Markierungen löschen', h('p', { text: 'Alle Markierungen für diesen PC löschen?' }), [{ label: 'Abbrechen', onClick: dlgClose },
      { label: 'Löschen', danger: true, onClick: () => { S.checklist = {}; api('/api/checklist', { method: 'POST', body: {} }).catch(e => toast(e.message)); dlgClose(); refreshView(); } }]) }) : null);
};

// ---------------------------------------------------------------- Ansicht: Änderungen
const JSTAT = { begonnen: 'begonnen', erledigt: 'erledigt', fehlgeschlagen: 'fehlgeschlagen', 'fehlgeschlagen-zurueckgesetzt': 'fehlgeschlagen, zurückgesetzt', zurueckgenommen: 'zurückgenommen' };
function journalEvent(e) {
  const undone = e.status === 'zurueckgenommen', failed = String(e.status).startsWith('fehl'), isUndo = e.art === 'rueckgaengig';
  const color = failed ? 'var(--red)' : undone ? 'var(--b01)' : isUndo ? 'var(--green)' : 'var(--cyan)';
  const chip = failed ? h('span', { class: 'chip CRIT', text: JSTAT[e.status] || e.status })
    : undone ? h('span', { class: 'chip INFO', text: 'zurückgenommen' })
      : isUndo ? h('span', { class: 'chip ACK', text: 'Rücknahme' })
        : h('span', { class: 'chip ' + (e.status === 'erledigt' ? 'OK' : 'WARN'), text: e.status === 'erledigt' ? 'aktiv' : (JSTAT[e.status] || e.status) });
  const canUndo = e.status === 'erledigt' && !isUndo;
  return h('div', { class: 'ev', style: `--c:${color}` },
    h('div', { class: 'h' }, h('b', { style: undone ? 'color:var(--b1)' : null, text: (isUndo ? 'Rückgängig: ' : '') + (e.titel || e.aktion) }), chip,
      h('span', { class: 'when', title: fmtDate(e.zeit), text: fmtWhen(e.zeit) }),
      canUndo ? h('button', { type: 'button', class: 'sm', disabled: readOnly(), title: readOnly() ? lockTitle() : null, onclick: () => openUndoDialog(e) }, icon('undo'), 'Rückgängig') : null),
    h('div', { class: 'm' }, `${fmtState(e.vorher)} → ${fmtState(e.nachher)}`, e.variante ? ` (${e.variante})` : '',
      e.wiederherstellungspunkt && e.wiederherstellungspunkt.seq != null ? [' · Wiederherstellungspunkt ', h('code', { text: '#' + e.wiederherstellungspunkt.seq })] : null,
      e.meldung ? h('div', { class: 'note', text: e.meldung }) : null));
}
V.aenderungen = () => {
  const jbox = h('div', { class: 'card' }, h('h2', { text: 'Verlauf deiner Änderungen' }), h('p', { class: 'muted', text: 'Lädt …' }));
  const rbox = h('div', { class: 'card' }, h('h2', { text: 'Wiederherstellungspunkte' }), h('p', { class: 'muted', text: 'Lädt …' }));
  const token = S.rv;
  api('/api/journal').then(list => {
    if (token !== S.rv) return;
    S.journal = list || [];
    renderStatusReport();
    jbox.replaceChildren(h('h2', { text: 'Verlauf deiner Änderungen' }), ...(S.journal.length
      ? [h('div', { class: 'tl' }, S.journal.slice(0, 100).map(journalEvent)), S.journal.length > 100 ? h('p', { class: 'note', text: `… ${S.journal.length - 100} ältere Einträge nicht angezeigt.` }) : null]
      : [h('p', { class: 'muted', text: 'Noch keine Änderungen durchgeführt.' })]).filter(Boolean));
  }).catch(e => jbox.replaceChildren(h('h2', { text: 'Verlauf deiner Änderungen' }), h('p', { class: 'rem', text: e.message })));
  api('/api/restorepoints').then(list => {
    if (token !== S.rv) return;
    S.points = list || [];
    renderStatusReport();
    rbox.replaceChildren(h('h2', { text: 'Wiederherstellungspunkte' }), ...(list && list.length
      ? [h('div', { class: 'list' }, list.map(p => h('div', { class: 'row rp' }, h('code', { text: '#' + p.seq }),
        h('div', null, h('div', { class: 't', style: 'font-weight:500', text: p.beschreibung }), h('div', { class: 'd', text: `${fmtWhen(p.zeit)}${p.typ ? ' · ' + p.typ : ''}` }))))),
      h('p', { class: 'note' }, 'Alles zurück auf einen Punkt: ', h('code', { text: 'rstrui.exe' }), ' starten (Start → Ausführen). Das setzt auch Programme und Treiber zurück, die danach installiert wurden.')]
      : [h('p', { class: 'muted', text: 'Keine Wiederherstellungspunkte gefunden.' })]));
  }).catch(e => rbox.replaceChildren(h('h2', { text: 'Wiederherstellungspunkte' }), h('p', { class: 'rem', text: e.message })));
  return h('section', null, h('h1', { text: 'Änderungen' }), h('p', { class: 'sub', text: 'Jede Änderung lässt sich einzeln zurücknehmen. Wiederherstellungspunkte sind das Netz darunter.' }),
    safetyBanner(), h('div', { class: 'grid g-hero' }, jbox, rbox));
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
  const cmpBtn = h('button', { type: 'button', class: 'primary', text: 'Vergleichen', onclick: doCompare });
  function sync() { cmpBtn.disabled = S.cmp.length !== 2; }
  async function doCompare() {
    cmpBox.replaceChildren(h('p', { class: 'muted', text: 'Lädt …' }));
    try {
      const names = S.cmp.slice().sort(); // Dateiname enthält das Datum: A = älter
      const [A, B] = await Promise.all(names.map(loadReportJson));
      const map = r => { const o = new Map(); (r.Findings || []).forEach(f => o.set(`${norm(f.Category)}|${norm(f.Check)}`, f)); return o; };
      const a = map(A), b = map(B), rows = [];
      new Set([...a.keys(), ...b.keys()]).forEach(k => { const x = a.get(k), y = b.get(k); if (!x || !y || x.Status !== y.Status) rows.push({ k, x, y }); });
      rows.sort((p, q) => RANK[(p.y || p.x).Status] - RANK[(q.y || q.x).Status]);
      const bd = f => f ? h('span', { class: 'chip ' + f.Status, text: STATUS_NAME[f.Status] }) : h('span', { class: 'muted', text: '–' });
      cmpBox.replaceChildren(h('div', { class: 'card' }, h('h3', { text: `Vergleich: ${fmtDate(A.Meta.Erstellt)} (A) und ${fmtDate(B.Meta.Erstellt)} (B)` }),
        rows.length ? h('div', { class: 'tablewrap' }, h('table', null, h('thead', null, h('tr', null, ['Prüfung', 'Status A', 'Status B'].map(x => h('th', { text: x })))),
          h('tbody', null, rows.map(r => h('tr', null, h('td', null, (r.y || r.x).Check, h('div', { class: 'cat-hint', text: (r.y || r.x).Category })), h('td', null, bd(r.x)), h('td', null, bd(r.y))))))) : h('p', { text: 'Keine Unterschiede im Status.' })));
    } catch (e) { cmpBox.replaceChildren(h('p', { class: 'rem', text: e.message })); }
  }
  function showOrig(name) {
    if (S.origName === name) { S.origName = null; origBox.replaceChildren(); return; }
    S.origName = name;
    // sandbox ohne allow-same-origin und ohne allow-popups: der Bericht kann weder die API noch Fenster öffnen
    const frame = h('iframe', { sandbox: 'allow-scripts', title: 'Original-HTML-Bericht', style: 'width:100%;height:78vh;border:1px solid var(--line);border-radius:6px;background:#fff' });
    origBox.replaceChildren(h('div', { class: 'card' }, h('div', { class: 'toolbar' }, h('b', { text: 'Original-HTML-Bericht' }), h('button', { type: 'button', text: 'Schließen', onclick: () => showOrig(name) })), frame));
    origSrc(name).then(src => { frame.src = src; }, e => origBox.replaceChildren(h('p', { class: 'rem', text: e.message })));
  }
  const rows = S.reports.map(r => {
    const c = r.counts || {};
    const cb = h('input', { type: 'checkbox', checked: S.cmp.includes(r.name), 'aria-label': 'Zum Vergleich auswählen',
      onchange: e => { if (e.target.checked) { S.cmp.push(r.name); if (S.cmp.length > 2) S.cmp.shift(); } else S.cmp = S.cmp.filter(x => x !== r.name); refreshChecks(); sync(); } });
    return { r, cb, tr: h('tr', null, h('td', null, cb), h('td', { text: fmtDate(r.created) + (r.name === S.cur ? ' (angezeigt)' : '') }), h('td', { text: r.version || '' }), h('td', { text: r.admin ? 'ja' : 'nein' }), h('td', { text: r.profil || '' }),
      h('td', { text: String(c.CRIT || 0) }), h('td', { text: String(c.WARN || 0) }), h('td', { text: String(c.TIPP || 0) }),
      h('td', null, h('button', { type: 'button', text: 'Anzeigen', onclick: async () => { try { await showReport(r.name); location.hash = '#/uebersicht'; if (S.view === 'uebersicht') refreshView(); } catch (e) { toast(e.message); } } }), ' ',
        h('button', { type: 'button', text: 'Original-HTML', onclick: () => showOrig(r.name) }))) };
  });
  function refreshChecks() { rows.forEach(x => { x.cb.checked = S.cmp.includes(x.r.name); }); }
  sync();
  return h('section', null, h('h1', { text: 'Berichte' }), h('p', { class: 'sub', text: `${S.reports.length} Berichte · zwei beliebige lassen sich vergleichen` }), reportBar(),
    h('div', { class: 'toolbar' }, cmpBtn, h('span', { class: 'note', text: 'Zwei Berichte ankreuzen, dann „Vergleichen“.' })),
    S.reports.length ? h('div', { class: 'card' }, h('div', { class: 'tablewrap' }, h('table', null,
      h('thead', null, h('tr', null, ['', 'Datum', 'Version', 'Admin', 'Profil', 'Krit.', 'Warn.', 'Tipps', ''].map(x => h('th', { text: x })))),
      h('tbody', null, rows.map(x => x.tr))))) : noReport(),
    cmpBox, origBox);
};

// ---------------------------------------------------------------- Ansicht: Scan
V.scan = () => {
  const sc = S.scan;
  const profil = h('select', { id: 'sc-profil', 'aria-label': 'Profil' }, [['Auto', 'Automatisch'], ['Gaming', 'Gaming'], ['Office', 'Office'], ['Laptop', 'Laptop']].map(([v, l]) => h('option', { value: v, text: l })));
  const days = h('select', { id: 'sc-days', 'aria-label': 'Zeitraum' }, [7, 14, 30, 60, 90].map(d => h('option', { value: String(d), selected: d === 14, text: `${d} Tage` })));
  const upd = h('input', { type: 'checkbox', checked: true }), wg = h('input', { type: 'checkbox', checked: true });
  const log = h('pre', { class: 'log', id: 'scanlog', style: 'height:260px;max-height:none', 'aria-live': 'polite', text: sc ? sc.lines.join('\n') : 'Bereit. Der Scan ändert nichts am System (ca. 2–5 Minuten).' });
  const btn = h('button', { type: 'button', class: 'primary', text: 'Scan starten', disabled: !!(sc && sc.running) || readOnly(), title: readOnly() ? lockTitle() : null, onclick: startScan });
  const msg = h('div', { id: 'scanmsg' });
  function startScan() {
    const d = parseInt(days.value, 10);
    if (!(d >= 1 && d <= 90)) return;
    S.scan = { running: true, lines: [], done: false };
    log.textContent = ''; btn.disabled = true; msg.replaceChildren();
    runScan({ profil: profil.value, eventDays: d, skipWinget: !wg.checked, skipUpdateSearch: !upd.checked });
  }
  S.scanUi = { log, btn, msg };
  if (sc && sc.msg) msg.replaceChildren(sc.msg);
  log.scrollTop = log.scrollHeight;
  return h('section', null, h('h1', { text: 'Neuer Scan' }), h('p', { class: 'sub', text: 'Der Scan ist rein lesend. Danach erscheint der neue Bericht automatisch als aktueller Bericht.' }),
    h('div', { class: 'card' }, h('div', { class: 'toolbar' },
      h('label', null, 'Profil ', profil), h('label', null, 'Zeitraum ', days),
      h('label', null, upd, ' Windows-Update-Suche'), h('label', null, wg, ' winget-Prüfung'), btn), log, msg));
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
      S.scan.msg = banner('info', 'doc', h('b', { text: 'Scan fertig. ' }), 'Der neue Bericht wird jetzt angezeigt. ', h('a', { href: '#/uebersicht', text: 'Zur Übersicht →' }));
      toast('Scan fertig: neuer Bericht geladen');
    } else S.scan.msg = h('p', { class: 'rem', text: (job.ergebnis && job.ergebnis.error) || 'Der Scan ist fehlgeschlagen.' });
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
  return Object.keys(dc).filter(t => dc[t] === check && S.report.Data && S.report.Data[t] && S.report.Data[t].length);
}
/** Springt in den Anhang und klappt die genannten Tabellen auf. */
function openRaw(titles) {
  S.ui.rawOpen = titles;
  if (location.hash === '#/rohdaten') refreshView(); else location.hash = '#/rohdaten';
}
V.rohdaten = () => {
  if (!S.report) return h('section', null, h('h1', { text: 'Rohdaten' }), noReport());
  const D = S.report.Data || {}, want = S.ui.rawOpen || [], dc = S.report.DataChecks || {};
  S.ui.rawOpen = null;
  let first = null;
  const sec = h('section', null, h('h1', { text: 'Rohdaten' }), h('p', { class: 'sub', text: 'Die Detailtabellen hinter den Prüfungen. Zum Aufklappen anklicken.' }), reportBar(),
    Object.keys(D).map(t => {
      const rows = D[t] || [], body = h('div');
      const d = h('details', { class: 'raw' }, h('summary', null, t, h('span', { class: 'muted', text: ` (${rows.length})` }),
        dc[t] ? h('span', { class: 'muted', text: ` · Prüfung „${dc[t]}“` }) : null), body);
      d.addEventListener('toggle', () => { if (d.open && !body.firstChild) body.append(tableFrom(rows)); });
      if (want.includes(t)) { d.open = true; body.append(tableFrom(rows)); d.classList.add('flash'); if (!first) first = d; }
      return d;
    }));
  if (first) setTimeout(() => first.scrollIntoView({ block: 'start', behavior: 'smooth' }), 50);
  return sec;
};
V.einstellungen = () => {
  const m = (S.report && S.report.Meta) || {}, s = safety();
  const acc = S.findings.filter(f => f.Status === 'ACK');
  return h('section', null, h('h1', { text: 'Einstellungen' }), h('p', { class: 'sub', text: 'Erst nur zur Ansicht. Profil und Zeitraum wählst du beim Scan.' }),
    h('div', { class: 'card' }, h('table', null, h('tbody', null,
      h('tr', null, h('td', { text: 'Profil (letzter Bericht)' }), h('td', { text: m.Profil || '–' })),
      h('tr', null, h('td', { text: 'Zeitraum Ereignisse' }), h('td', { text: m.EventDays != null ? `${m.EventDays} Tage` : '–' })),
      h('tr', null, h('td', { text: 'Computerschutz' }), h('td', null, s.schutzAn === false ? h('span', { class: 'rem', text: 'aus' }) : h('span', { class: 'ok', text: `an${s.laufwerk ? ' (' + s.laufwerk + ')' : ''}` }), ' · 24-h-Sperre ', s.sperre24h ? h('span', { class: 'warn', text: 'aktiv' }) : h('span', { class: 'ok', text: 'aus' }))),
      h('tr', null, h('td', { text: 'Letzter Wiederherstellungspunkt' }), h('td', { text: s.letzterPunkt ? fmtDate(s.letzterPunkt) : '–' })),
      h('tr', null, h('td', { text: 'Morpheus-Version' }), h('td', { text: (S.session && S.session.version) || '' }))))),
    h('h2', { text: `Akzeptierte Abweichungen (${acc.length})` }),
    h('div', { class: 'card' }, acc.length ? acc.map(f => findingRow(f, { hint: true })) : h('p', { class: 'muted', text: 'Keine. Einträge stehen in accepted.psd1 (Vorlage: accepted.example.psd1).' })));
};

// ---------------------------------------------------------------- Rechte Statusleiste
const sbVisible = () => S.sbOn && window.matchMedia('(min-width:1400px)').matches;
const clampPct = v => Math.max(0, Math.min(100, Number(v) || 0));
const TONE_OF = { OK: 'green', ACK: 'green', INFO: 'yellow', TIPP: 'yellow', WARN: 'orange', CRIT: 'red', SKIP: 'grey' };
const toneOf = f => (f && TONE_OF[f.Status]) || 'grey';
function scCard(title, src, isLive, ...kids) {
  return h('section', { class: 'sc' }, h('div', { class: 'sc-h' }, h('h4', { text: title }), h('span', { class: 'src' + (isLive ? ' live' : ''), text: src })), ...kids);
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
    box.replaceChildren(h('div', { class: 'st-sec', text: 'Live' }),
      scCard('CPU · RAM · GPU', L.state === 'error' ? 'nicht erreichbar' : 'live', L.state !== 'error', h('p', { class: 'wait', text: L.state === 'error' ? 'Messwerte sind gerade nicht erreichbar.' : 'wird gemessen …' })));
    return;
  }
  const src = L.state === 'error' ? 'veraltet' : 'live', isLive = L.state !== 'error', v = d.verlauf || {};
  const cards = [h('div', { class: 'st-sec', text: 'Live' })];
  // 1. CPU · RAM · GPU
  const g = d.gpu, ram = d.ram || {};
  const temp = g && g.temp != null ? h('span', { class: 'chip ' + (g.temp >= 88 ? 'CRIT' : g.temp >= 80 ? 'Y' : ''), title: 'GPU-Temperatur', text: `${dec(g.temp, 0)} °C` }) : null;
  cards.push(scCard('CPU · RAM · GPU', src, isLive,
    mrow('CPU', d.cpu, v.cpu, null),
    mrow('RAM', ram.usedPct, v.ram, ram.usedGB != null && ram.totalGB != null ? `${dec(ram.usedGB, 1)} von ${dec(ram.totalGB, 0)} GB` : null),
    mrow('GPU', g ? g.util : null, v.gpu, g ? [g.name || 'GPU', g.memUsedPct != null ? ` · VRAM ${dec(g.memUsedPct, 0)} %` : '', ' ', temp] : 'keine GPU erkannt')));
  // 2. Laufwerke
  const drives = (d.drives || []).filter(Boolean);
  if (drives.length) {
    cards.push(scCard('Laufwerke', src, isLive, drives.map(x => {
      const free = x.freePct != null ? Number(x.freePct) : (x.sizeGB ? x.freeGB / x.sizeGB * 100 : null);
      const tone = free == null ? 'grey' : free < 10 ? 'red' : free < 20 ? 'yellow' : 'green';
      return h('div', { class: 'drow g-' + tone },
        h('div', { class: 'l1' }, h('i', { class: 'adot' }), h('b', { text: x.letter || '?' }), x.label ? h('span', { class: 'lab', text: x.label }) : null, x.type ? h('span', { class: 'chip type', text: x.type }) : null,
          h('span', { class: 'pct', text: free == null ? '–' : `${dec(100 - free, 0)} % belegt` })),
        h('div', { class: 'meter' }, h('i', { style: `width:${free == null ? 0 : clampPct(100 - free)}%` })),
        h('div', { class: 'l2', text: x.freeGB != null && x.sizeGB != null ? `${dec(x.freeGB, 0)} GB frei von ${dec(x.sizeGB, 0)} GB` : 'Größe unbekannt' }));
    })));
  }
  // 3. Netzwerk
  const n = d.net;
  cards.push(scCard('Netzwerk', src, isLive, n
    ? [h('div', { class: 'kv' }, h('span', { class: 'muted', text: 'Adapter' }), h('b', { text: n.adapter || '–' })), h('div', { class: 'kv' }, h('span', { class: 'muted', text: 'Link' }), h('b', { text: fmtLink(n.linkMbps) })),
      h('div', { class: 'kv' }, h('span', { class: 'muted', text: '↓ Empfang' }), h('b', { text: fmtRate(n.rxKBs) })), h('div', { class: 'kv' }, h('span', { class: 'muted', text: '↑ Senden' }), h('b', { text: fmtRate(n.txKBs) }))]
    : h('p', { class: 'wait', text: 'Keine aktive Verbindung.' })));
  // 4. Top-Prozesse
  const top = (d.top || []).filter(Boolean).slice(0, 3);
  cards.push(scCard('Top-Prozesse', src, isLive, top.length
    ? top.map(p => h('div', { class: 'pr' }, h('span', { class: 'nm', title: p.name, text: p.name }), h('b', { text: p.cpu == null ? '–' : dec(p.cpu, 1) + ' %' })))
    : h('p', { class: 'wait', text: 'Keine Daten.' })));
  box.replaceChildren(...cards);
}

const PROT = [
  ['Defender', f => /^(Microsoft )?Defender: Status$/.test(f.Check)],
  ['Firewall', f => /^Firewall/.test(f.Check) && /Profile|Status/.test(f.Check)],
  ['Windows Update', f => f.Check === 'Windows Update: ausstehend'],
  ['Secure Boot', f => f.Check === 'Secure Boot'],
  ['TPM', f => f.Check === 'TPM'],
  ['BitLocker', f => f.Check === 'BitLocker'],
  ['Kernisolierung', f => /^Kernisolierung/.test(f.Check)],
];
const RISKY_PORTS = new Set([3389, 445, 139, 5985, 5986, 22, 23]);
const SYS_PROCS = new Set(['system', 'svchost', 'lsass', 'wininit', 'services', 'spoolsv', 'smss', 'csrss', 'winlogon', 'lsm', 'dns', 'wuauserv', 'dwm', 'fontdrvhost', 'idle']);
const dataTable = name => { const D = (S.report && S.report.Data) || {}, k = Object.keys(D).find(x => norm(x) === name); return k ? (D[k] || []) : null; };
const findBy = pred => S.findings.find(pred);
function portCard(src) {
  const rows = dataTable('Offene Netzwerkports (nicht nur lokal)');
  if (!rows) return scCard('Offene Ports', src, false, h('p', { class: 'wait', text: 'Keine Portdaten im Bericht.' }));
  const seen = new Map();
  rows.filter(Boolean).forEach(r => {
    const port = Number(r.Port), key = `${r.Protokoll}/${port}`;
    if (isNaN(port) || seen.has(key)) return;
    const proc = String(r.Prozess || '').replace(/\.exe$/i, '');
    seen.set(key, { port, proto: r.Protokoll, proc, tone: RISKY_PORTS.has(port) ? 'red' : (!proc || SYS_PROCS.has(proc.toLowerCase()) ? 'green' : 'yellow') });
  });
  const list = [...seen.values()], ord = { red: 0, yellow: 1, green: 2 };
  list.sort((a, b) => ord[a.tone] - ord[b.tone] || a.port - b.port);
  const cnt = t => list.filter(x => x.tone === t).length;
  return scCard('Offene Ports', src, false,
    h('div', { class: 'kv' }, h('span', { class: 'muted', text: 'von außen erreichbar' }), h('b', { text: String(list.length) })),
    list.length ? [h('div', { class: 'kv' }, h('span', { class: 'muted', text: 'riskant · fremd · System' }), h('b', { text: `${cnt('red')} · ${cnt('yellow')} · ${cnt('green')}` })),
      list.slice(0, 5).map(p => h('div', { class: 'port g-' + p.tone }, h('i', { class: 'adot' }), h('code', { text: String(p.port) }), h('span', { class: 'nm', title: `${p.proto} · ${p.proc || 'System'}`, text: `${p.proc || 'System'} · ${p.proto}` }))),
      list.length > 5 ? h('div', { class: 'note', text: `… und ${list.length - 5} weitere` }) : null] : h('p', { class: 'wait', text: 'Keine offenen Ports gefunden.' }));
}
function stabilityCard(src) {
  const tile = (label, tone, valNode, f) => h(f ? 'button' : 'div', { type: f ? 'button' : null, class: 'tile g-' + tone, onclick: f ? () => reveal(f.Check) : null, title: f ? 'Zum Befund' : null },
    h('div', { class: 'tl2' }, h('i', { class: 'adot' }), label), h('b', null, valNode));
  const fRel = findBy(f => f.Check === 'Zuverlässigkeitsindex'), fCrash = findBy(f => f.Check === 'Abstürze und unerwartete Neustarts');
  const fApp = findBy(f => f.Check === 'Programmabstürze'), fBoot = findBy(f => f.Check === 'Startdauer');
  const rel = fRel && /([\d.,]+)\s*von\s*(\d+)/.exec(fRel.Value || ''), relN = rel ? Number(rel[1].replace(',', '.')) : null;
  const bs = fCrash && (/(\d+)\s*Bluescreens?/i.exec(fCrash.Value || '') ? Number(/(\d+)\s*Bluescreens?/i.exec(fCrash.Value)[1]) : (/^Keine/i.test(fCrash.Value || '') ? 0 : null));
  const am = fApp && (/^(\d+)/.exec(fApp.Value || '') ? Number(/^(\d+)/.exec(fApp.Value)[1]) : (/^Keine/i.test(fApp.Value || '') ? 0 : null));
  const bootRows = (dataTable('Startdauer (letzte Messungen)') || []).filter(Boolean).map(x => Number(x.HauptpfadSek)).filter(x => !isNaN(x));
  const boot = bootRows.length ? bootRows.reduce((a, b) => a + b, 0) / bootRows.length : null;
  const dash = h('span', { class: 'muted', text: '–' });
  return scCard('Stabilität', src, false, h('div', { class: 'tiles' },
    tile('Zuverlässigkeit', relN == null ? 'grey' : relN >= 8 ? 'green' : relN >= 6 ? 'yellow' : 'orange', relN == null ? dash : [dec(relN, relN % 1 ? 1 : 0), h('small', { text: ` / ${rel[2]}` })], fRel),
    tile('Bluescreens', bs == null ? 'grey' : bs === 0 ? 'green' : 'red', bs == null ? dash : String(bs), fCrash),
    tile('App-Abstürze', am == null ? 'grey' : am === 0 ? 'green' : am <= 5 ? 'yellow' : 'orange', am == null ? dash : String(am), fApp),
    tile('Startdauer', boot == null ? 'grey' : boot <= 30 ? 'green' : boot <= 60 ? 'yellow' : 'orange', boot == null ? dash : [dec(boot, 0), h('small', { text: ' s' })], fBoot)));
}
function safetyCard() {
  const s = safety(), sess = !!S.session;
  const pt = S.points && S.points[0] ? S.points[0].zeit : s.letzterPunkt;
  const undoable = S.journal ? S.journal.filter(e => e.status === 'erledigt' && e.art !== 'rueckgaengig').length : null;
  const row = (tone, label, val) => h('div', { class: 'pr g-' + tone }, h('i', { class: 'adot' }), h('span', { class: 'nm', text: label }), h('b', { text: val }));
  return scCard('Absicherung', 'Sitzung', false,
    row(!sess || s.schutzAn == null ? 'grey' : s.schutzAn ? 'green' : 'red', 'Computerschutz', !sess || s.schutzAn == null ? '–' : s.schutzAn ? `an${s.laufwerk ? ' (' + s.laufwerk + ')' : ''}` : 'aus'),
    row(s.sperre24h == null ? 'grey' : s.sperre24h ? 'yellow' : 'green', '24-h-Sperre', s.sperre24h == null ? '–' : s.sperre24h ? 'aktiv' : 'aus'),
    row(pt ? 'green' : 'grey', 'Letzter Punkt', pt ? fmtAgo(pt) : '–'),
    row(undoable == null ? 'grey' : 'cyan', 'Rücknehmbar', undoable == null ? '–' : plural(undoable, 'Änderung', 'Änderungen')),
    h('a', { class: 'more-link', href: '#/aenderungen', text: 'Zu den Änderungen →' }));
}
function renderStatusReport() {
  const box = $('#st-report'); if (!box) return;
  const nodes = [];
  if (S.report) {
    const src = 'Bericht vom ' + fmtDate(S.report.Meta.Erstellt);
    nodes.push(h('div', { class: 'st-sec', text: 'Aus dem Bericht' }));
    // 5. Schutz-Ampeln
    nodes.push(scCard('Schutz-Ampeln', src, false, PROT.map(([name, pred]) => {
      const f = findBy(pred), tone = toneOf(f);
      return h('button', { type: 'button', class: 'srow g-' + tone, disabled: !f, title: f ? `${f.Check}: ${f.Value || ''}` : 'Nicht im Bericht', onclick: f ? () => reveal(f.Check) : null },
        h('i', { class: 'adot' }), name, h('span', { class: 'sv', text: f ? (STATUS_NAME[f.Status] || f.Status) : 'fehlt' }));
    })));
    nodes.push(portCard(src), stabilityCard(src));
  }
  nodes.push(h('div', { class: 'st-sec', text: 'Absicherung' }), safetyCard());
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
  $('#app').classList.toggle('st-off', !S.sbOn);
  $('#st-toggle').setAttribute('aria-pressed', S.sbOn ? 'true' : 'false');
  renderStatusLive(); renderStatusReport();
  if (sbVisible()) liveEnsure(); else liveStop();
}
function initStatusbar() {
  try { S.sbOn = localStorage.getItem(SB_KEY) !== '0'; } catch { S.sbOn = true; }
  $('#st-toggle').addEventListener('click', () => {
    S.sbOn = !S.sbOn;
    try { localStorage.setItem(SB_KEY, S.sbOn ? '1' : '0'); } catch { /* ohne Speicher weiter */ }
    applySb();
  });
  window.matchMedia('(min-width:1400px)').addEventListener('change', () => { if (sbVisible()) liveEnsure(); else liveStop(); });
  document.addEventListener('visibilitychange', () => { if (document.hidden) liveStop(); else liveEnsure(); });
  applySb();
}
async function loadExtra() {
  const [j, p] = await Promise.all([api('/api/journal').catch(() => null), api('/api/restorepoints').catch(() => null)]);
  if (j) S.journal = j;
  if (p) S.points = p;
  renderStatusReport();
}

// ---------------------------------------------------------------- Routing
function reveal(check) {
  const f = findingByCheck(check); if (!f) return;
  S.ui.reveal = check;
  const v = viewOf(f);
  S.ui.f[v] = { mode: 'all', term: '' };
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
  try { node = view(); } catch (e) { console.error(e); node = banner('err', 'warn', h('b', { text: 'Anzeigefehler: ' }), e.message); }
  if (!keepScroll) node.classList.add('view-in');
  $('#view').replaceChildren(node);
  renderNav();
  if (keepScroll) window.scrollTo(0, y); else if (!S.ui.reveal) window.scrollTo(0, 0);
  if (S.ui.reveal) doReveal();
}
function refreshView() { renderView(true); }
function route() {
  const m = location.hash.match(/^#\/(\w+)/);
  const v = m && V[m[1]] ? m[1] : 'uebersicht';
  S.view = v;
  closeTips();
  renderView(false);
}

// ---------------------------------------------------------------- Sprechblasen (ⓘ)
function closeTips(except) {
  document.querySelectorAll('.tip.open').forEach(t => { if (t !== except) { t.classList.remove('open'); if (t.previousElementSibling) t.previousElementSibling.setAttribute('aria-expanded', 'false'); } });
}
document.addEventListener('click', e => {
  const btn = e.target.closest ? e.target.closest('button.info') : null;
  if (e.target.closest && e.target.closest('.tip')) return;
  if (!btn) { closeTips(null); return; }
  const tip = btn.nextElementSibling, open = !tip.classList.contains('open');
  closeTips(tip); tip.classList.toggle('open', open); btn.setAttribute('aria-expanded', open ? 'true' : 'false');
});
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeTips(null); });

// ---------------------------------------------------------------- Start
async function init() {
  try { await initToken(); } catch (e) { fatal(e.message); return; }
  if (!S.token) { fatal('Kein Zugriffstoken. Bitte die GUI über pc-check-gui starten.'); return; }
  try {
    await loadAll();
  } catch (e) {
    if (e.status !== 401) fatal('Die GUI konnte nicht geladen werden: ' + e.message);
    return;
  }
  startHeartbeat();
  initTopbar(); initStatusbar();
  window.addEventListener('hashchange', route);
  route();
  loadExtra();
}
init();
})();
