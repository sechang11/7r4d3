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
let dirty = new Map();          // date -> pending patch, flushed on blur
let shown = false;

const api = window.RMApi;       // shared fetch wrapper (token + error handling)

/** Auto fields are per-symbol only for now; index them for quick lookup. */
const autoFields = () => schema?.auto?.perSymbol ?? [];

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

  const per = schema.perSymbol ?? [];
  const syms = schema.symbols ?? [];
  const autos = autoFields();

  // ── two header rows: group spans, then field names ──
  const head = tbl.createTHead();
  const h1 = head.insertRow();
  h1.insertCell().outerHTML = '<th class="stick corner" colspan="2">Week</th>';
  for (const g of schema.groups ?? [])
    h1.insertCell().outerHTML = `<th colspan="${g.fields.length}" class="grp">${g.label}</th>`;
  for (const s of syms)
    h1.insertCell().outerHTML = `<th colspan="${per.length + autos.length}" class="grp sym">${s}</th>`;

  const h2 = head.insertRow();
  h2.insertCell().outerHTML = '<th class="stick">Wk</th><th class="stick2">Date</th>';
  for (const g of schema.groups ?? [])
    for (const f of g.fields) h2.insertCell().outerHTML = `<th>${f.label}</th>`;
  for (const _ of syms) {
    for (const f of per)   h2.insertCell().outerHTML = `<th title="${f.hint ?? ''}">${f.label}</th>`;
    for (const a of autos) h2.insertCell().outerHTML = `<th class="autoh" title="filled by the EA">${a.label}</th>`;
  }

  // ── one row per day, newest first ──
  const body = tbl.createTBody();
  const hideEmpty = $('jrnlHideEmpty').checked;
  let lastWeek = null;

  for (const r of rows) {
    if (hideEmpty && isEmptyRow(r)) continue;
    const d = new Date(r.date + 'T12:00:00');
    // ISO-ish week number, only used to group visually.
    const wk = Math.floor((d - new Date(d.getFullYear(), 0, 1)) / 604800000) + 1;
    const tr = body.insertRow();
    const weekend = r.dow === 0 || r.dow === 6;
    if (weekend) tr.className = 'wknd';

    const wkCell = tr.insertCell();
    wkCell.className = 'stick';
    if (wk !== lastWeek) { wkCell.textContent = 'W' + wk; lastWeek = wk; }

    const dCell = tr.insertCell();
    dCell.className = 'stick2';
    dCell.innerHTML = `${d.getMonth() + 1}/${d.getDate()}<span class="dow">${DOW[r.dow]}</span>`;

    for (const g of schema.groups ?? [])
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
    render();
    $('jrnlMsg').textContent = '';
  } catch (e) {
    $('jrnlMsg').textContent = `could not load: ${e.message}`;
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
