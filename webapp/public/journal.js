// Daily journal table.
//
// Everything here is driven by journal-schema.json — the column groups, the
// per-symbol block, which fields are auto-filled. Nothing about ES/NQ/DXY or
// "T0:Type" is hardcoded, so redefining what you track is a schema edit rather
// than a rewrite.
//
// Layout mirrors the spreadsheet: a sticky Week/Date corner on the left, then
// Habits and Trade, then one block of identical columns per symbol. The whole
// thing scrolls sideways inside its own container so the page never does.
(() => {
const $ = (id) => document.getElementById(id);

const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

let schema = null;
let rows = [];
let login = 'default';
let shown = false;

const api = window.RMApi;       // shared fetch wrapper (token + error handling)

/** Auto fields are per-symbol only for now; index them for quick lookup. */
const autoFields = () => schema?.auto?.perSymbol ?? [];

// ── view state (persisted) ──────────────────────────────────────────
// Renaming the codes to plain English made columns wide; these controls win the
// density back — short codes, tighter cells, hidden groups, a symbol subset —
// without giving up the readable labels when you want them.
const VIEW_KEY = 'rm_jrnl_view';
const view = Object.assign(
  { compact: false, hiddenGroups: [], hiddenSyms: [] },
  (() => { try { return JSON.parse(localStorage.getItem(VIEW_KEY)) || {}; } catch { return {}; } })()
);
const saveView = () => localStorage.setItem(VIEW_KEY, JSON.stringify(view));

const groupHidden = (k) => view.hiddenGroups.includes(k);
const symHidden   = (s) => view.hiddenSyms.includes(s);

/** Short code for a per-symbol field ("T0:Type" -> "T0"), used in compact mode. */
const shortCode = (f) => (f.was ? f.was.replace(/:.*/, '').replace(/[^A-Za-z0-9]/g, '') : f.label);
/** Compact label for a group field — initials so Sleep/Fuel fit. */
const shortGroup = (f) => f.label.replace('?', '').slice(0, 3);
const headSym = (f)   => view.compact ? shortCode(f)  : f.label;
const headGrp = (f)   => view.compact ? shortGroup(f) : f.label;

const shownGroups = () => (schema?.groups ?? []).filter((g) => !groupHidden(g.key));
const shownSyms   = () => (schema?.symbols ?? []).filter((s) => !symHidden(s));

function cellInput(value, def, onCommit) {
  let el;
  if (def.type === 'enum') {
    el = document.createElement('select');
    el.appendChild(new Option('', ''));
    for (const o of def.options ?? []) el.appendChild(new Option(o, o));
  } else if (def.type === 'tf') {
    el = document.createElement('select');
    for (const [v, t] of [['', ''], ['t', 't'], ['f', 'f']]) el.appendChild(new Option(t, v));
  } else {
    el = document.createElement('input');
    el.type = (def.type === 'score' || def.type === 'number') ? 'number' : 'text';
    if (def.type === 'score') { el.min = 0; el.max = 10; }
    if (def.hint) el.title = def.hint;
  }
  el.className = 'jcell';
  el.value = value ?? '';
  if (def.width) el.style.width = def.width + 'px';
  // Commit on blur and on Enter, not on every keystroke — one PUT per edit.
  el.addEventListener('change', () => onCommit(el.value));
  el.addEventListener('keydown', (e) => { if (e.key === 'Enter') el.blur(); });
  return el;
}

async function commit(date, patch) {
  try {
    await api('/api/journal', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ login, date, patch }),
    });
    $('jrnlMsg').textContent = `saved ${date}`;
  } catch (e) {
    $('jrnlMsg').textContent = `save failed: ${e.message}`;
  }
}

function isEmptyRow(r) {
  for (const g of schema.groups ?? [])
    for (const f of g.fields) if (r[g.key]?.[f.key]) return false;
  for (const sym of schema.symbols ?? [])
    if (r[sym] && Object.values(r[sym]).some((v) => v !== '' && v != null)) return false;
  return true;
}

function render() {
  const tbl = $('jrnlTbl');
  tbl.replaceChildren();
  if (!schema) return;
  tbl.className = 'jtbl' + (view.compact ? ' compact' : '');

  const per = schema.perSymbol ?? [];
  const groups = shownGroups();
  const syms = shownSyms();
  const autos = autoFields();

  // ── two header rows: group spans, then field names ──
  const head = tbl.createTHead();
  const h1 = head.insertRow();
  h1.insertCell().outerHTML = '<th class="stick corner" colspan="2">Week</th>';
  for (const g of groups)
    h1.insertCell().outerHTML = `<th colspan="${g.fields.length}" class="grp">${g.label}</th>`;
  for (const s of syms)
    h1.insertCell().outerHTML = `<th colspan="${per.length + autos.length}" class="grp sym">${s}</th>`;

  const h2 = head.insertRow();
  h2.insertCell().outerHTML = '<th class="stick">Wk</th><th class="stick2">Date</th>';
  for (const g of groups)
    for (const f of g.fields) h2.insertCell().outerHTML = `<th title="${f.def ?? f.label}">${headGrp(f)}</th>`;
  for (const _ of syms) {
    for (const f of per)   h2.insertCell().outerHTML = `<th title="${(f.label + ' — ' + (f.def ?? '')).replace(/"/g, '&quot;')}">${headSym(f)}</th>`;
    for (const a of autos) h2.insertCell().outerHTML = `<th class="autoh" title="filled by the EA">${view.compact ? (a.label.length > 4 ? a.label.slice(0, 3) : a.label) : a.label}</th>`;
  }

  // ── one row per day, newest first ──
  const body = tbl.createTBody();
  const hideEmpty = $('jrnlHideEmpty').checked;
  let lastWeek = null, zebra = false;

  for (const r of rows) {
    if (hideEmpty && !r.future && isEmptyRow(r)) continue;   // keep future rows even if empty
    const d = new Date(r.date + 'T12:00:00');
    // ISO-ish week number, used to group visually and to zebra by week.
    const wk = Math.floor((d - new Date(d.getFullYear(), 0, 1)) / 604800000) + 1;
    if (wk !== lastWeek) zebra = !zebra;                     // flip shade each new week
    const tr = body.insertRow();
    const weekend = r.dow === 0 || r.dow === 6;
    tr.className = [zebra ? 'zebra' : '', weekend ? 'wknd' : '', r.future ? 'future' : '', r.mx ? 'mxrow' : '']
      .filter(Boolean).join(' ');

    const wkCell = tr.insertCell();
    wkCell.className = 'stick';
    if (wk !== lastWeek) { wkCell.textContent = 'W' + wk; lastWeek = wk; }

    const dCell = tr.insertCell();
    dCell.className = 'stick2';
    dCell.innerHTML = `${d.getMonth() + 1}/${d.getDate()}<span class="dow">${DOW[r.dow]}</span>` +
      (r.mx ? '<span class="mxtag">Mx</span>' : '');

    for (const g of groups)
      for (const f of g.fields) {
        const td = tr.insertCell();
        td.appendChild(cellInput(r[g.key]?.[f.key], f,
          (v) => commit(r.date, { [g.key]: { [f.key]: v } })));
      }

    for (const sym of syms) {
      // Weekends: only the symbols that actually trade then get inputs.
      const trades = !weekend || (schema.weekendSymbols ?? []).includes(sym);
      for (const f of per) {
        const td = tr.insertCell();
        if (!trades) { td.className = 'closed'; continue; }
        td.appendChild(cellInput(r[sym]?.[f.key], f,
          (v) => commit(r.date, { [sym]: { [f.key]: v } })));
      }
      for (const a of autos) {
        const td = tr.insertCell();
        td.className = 'auto';
        td.textContent = trades ? (r[sym]?.[a.key] ?? '') : '';
      }
    }
  }
}

async function load() {
  try {
    const j = await api(`/api/journal?login=${encodeURIComponent(login)}&days=70`).then((r) => r.json());
    schema = j.schema;
    rows = j.rows;
    buildViewBar();
    render();
    $('jrnlMsg').textContent = '';
  } catch (e) {
    $('jrnlMsg').textContent = `could not load: ${e.message}`;
  }
}

// ── view controls ───────────────────────────────────────────────────
// Built from the schema so they track whatever groups/symbols exist.
function buildViewBar() {
  const cBtn = $('jrnlCompact');
  cBtn.classList.toggle('sel', view.compact);
  cBtn.onclick = () => { view.compact = !view.compact; saveView(); cBtn.classList.toggle('sel', view.compact); render(); };

  const gHost = $('jrnlGroups');
  gHost.replaceChildren();
  for (const g of schema.groups ?? []) {
    const b = document.createElement('button');
    b.className = 'pbtn' + (groupHidden(g.key) ? '' : ' sel');
    b.textContent = g.label;
    b.title = `Show / hide the ${g.label} columns`;
    b.onclick = () => {
      view.hiddenGroups = groupHidden(g.key)
        ? view.hiddenGroups.filter((k) => k !== g.key) : [...view.hiddenGroups, g.key];
      saveView(); b.classList.toggle('sel'); render();
    };
    gHost.appendChild(b);
  }

  // A collapsible "Symbols" chooser — trade a subset to fit them wide.
  const sHost = $('jrnlSyms');
  sHost.replaceChildren();
  const label = document.createElement('span');
  label.className = 'desc';
  label.textContent = 'Symbols:';
  sHost.appendChild(label);
  for (const s of schema.symbols ?? []) {
    const b = document.createElement('button');
    b.className = 'pbtn sm' + (symHidden(s) ? '' : ' sel');
    b.textContent = s;
    b.onclick = () => {
      view.hiddenSyms = symHidden(s)
        ? view.hiddenSyms.filter((x) => x !== s) : [...view.hiddenSyms, s];
      saveView(); b.classList.toggle('sel'); render();
    };
    sHost.appendChild(b);
  }
}

$('jrnlToggle').onclick = () => {
  shown = !shown;
  $('jrnlWrap').hidden = !shown;
  $('jrnlToggle').textContent = shown ? 'Hide' : 'Show';
  if (shown) load();
};
$('jrnlHideEmpty').onchange = render;

// The account the journal belongs to follows whichever instance is selected,
// so switching client switches journal.
window.RMJournal = {
  setLogin(v) {
    const next = String(v ?? 'default');
    if (next === login) return;
    login = next;
    if (shown) load();
  },
  refresh() { if (shown) load(); },
};
})();
