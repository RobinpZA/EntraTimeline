/* ── Frontend behaviour checks ────────────────────────────────────────────
   Drives the real Web/js modules under a stubbed vis + DOM to verify the
   behaviours that matter: UTC formatting, the unified filter pipeline, table
   sorting, and the cluster-click guard.

   Node is used only to run these — nothing about the shipped portal changes,
   there is still no build step, and the app is served exactly as authored.
   Run directly, or via .\build.ps1 -Task UITest (skipped when node is absent).

     node Tests/ui-checks.js Web
                                                                            */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const WEB = process.argv[2] || path.join(__dirname, '..', 'Web');
const read = f => fs.readFileSync(path.join(WEB, f), 'utf8');

/* ── minimal DOM ── */
function makeEl(id) {
  const el = {
    id, innerHTML: '', textContent: '', value: '', tagName: 'DIV',
    dataset: {}, classList: {
      _s: new Set(),
      add(...c) { c.forEach(x => this._s.add(x)); },
      remove(...c) { c.forEach(x => this._s.delete(x)); },
      toggle(c, f) { f === undefined ? (this._s.has(c) ? this._s.delete(c) : this._s.add(c)) : (f ? this._s.add(c) : this._s.delete(c)); },
      contains(c) { return this._s.has(c); }
    },
    setAttribute() {}, getAttribute() { return null; }, focus() {}, blur() {}, select() {},
    addEventListener(t, fn) { (this._h ??= {})[t] = fn; },
    appendChild() {}, remove() {}, closest() { return null; },
    querySelector() { return makeEl('q'); }, querySelectorAll() { return []; },
    scrollIntoView() {}, click() {}
  };
  return el;
}
const els = {};
const document = {
  getElementById: id => (els[id] ??= makeEl(id)),
  createElement: () => makeEl('new'),
  addEventListener() {}, readyState: 'complete',
  querySelectorAll: () => [], activeElement: null, body: makeEl('body')
};

/* ── vis stub ── */
class DataSet {
  constructor(init = []) { this.rows = new Map(); this.add(init); }
  add(rows) { (Array.isArray(rows) ? rows : [rows]).forEach(r => {
    if (this.rows.has(r.id)) throw new Error('duplicate id ' + r.id);
    this.rows.set(r.id, r); }); }
  update(r) { this.rows.set(r.id, { ...(this.rows.get(r.id) || {}), ...r }); }
  remove(ids) { (Array.isArray(ids) ? ids : [ids]).forEach(id => this.rows.delete(id)); }
  getIds() { return [...this.rows.keys()]; }
  clear() { this.rows.clear(); }
  get() { return [...this.rows.values()]; }
}
const handlers = {};
let visOptions = null;
class TimelineStub {
  constructor(container, items, groups, options) {
    visOptions = options;
    this._win = { start: new Date('2026-07-01'), end: new Date('2026-07-31') };
    this._sel = [];
  }
  on(evt, fn) { handlers[evt] = fn; }
  off() {}
  fit() { this.fitted = true; }
  redraw() {}
  getWindow() { return this._win; }
  setWindow(s, e) { this._win = { start: s, end: e }; }
  getSelection() { return this._sel; }
  setSelection(ids) { this._sel = ids; }
}
const vis = { DataSet, Timeline: TimelineStub, moment: d => ({ utc: () => ({ _d: d }) }) };

/* ── run modules ── */
const ctx = vm.createContext({ document, window: {}, vis, console, setTimeout, clearTimeout,
                               setInterval: () => 0, clearInterval: () => {}, Date, JSON, Math, navigator: {}, location: { hash: '' } });
['js/utils.js', 'js/timeline.js', 'js/table.js'].forEach(f =>
  vm.runInContext(read(f), ctx, { filename: f }));

// const/let declarations live in the context's lexical scope, not on the sandbox
// object, so hand them out explicitly.
vm.runInContext(`globalThis.__api = { formatDate, formatDateShort, formatTime, Timeline, EventTable,
                                      readRecents, pushRecent, clearRecents };`, ctx);
const { formatDate, formatDateShort, formatTime, Timeline, EventTable,
        readRecents, pushRecent, clearRecents } = ctx.__api;

let pass = 0, fail = 0;
const check = (name, got, want) => {
  const ok = String(got) === String(want);
  ok ? pass++ : fail++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `\n          got:  ${got}\n          want: ${want}`}`);
};

/* ── 1. UTC formatting (the headline fix) ── */
console.log('\nUTC consistency — machine is UTC+2:');
const iso = '2026-07-28T18:00:00Z';
check('formatDate is 18:00 not 20:00',      /18:00/.test(formatDate(iso)), true);
check('formatDateShort is 18:00 not 20:00', /18:00/.test(formatDateShort(iso)), true);
check('formatTime is 18:00 not 20:00',      /18:00/.test(formatTime(iso)), true);
check('formatDate and formatDateShort agree',
  formatDate(iso).match(/\d\d:\d\d/)[0], formatDateShort(iso).match(/\d\d:\d\d/)[0]);

/* ── 2. Filter pipeline ── */
console.log('\nUnified filter pipeline:');
const events = [
  { id: 'a', timestamp: '2026-07-01T10:00:00Z', category: 'SignIn', status: 'success', title: 'Sign-in to Office 365', summary: 'From 10.0.0.1', detail: { app: 'Office 365', ipAddress: '10.0.0.1' } },
  { id: 'b', timestamp: '2026-07-02T10:00:00Z', category: 'SignIn', status: 'failure', title: 'Sign-in to SharePoint', summary: 'From 10.0.0.2', detail: { app: 'SharePoint', ipAddress: '10.0.0.2' } },
  { id: 'c', timestamp: '2026-07-03T10:00:00Z', category: 'Audit',  status: 'success', title: 'Update user',          summary: 'By: Admin',      detail: { activity: 'Update user' } },
  { id: 'd', timestamp: '2026-07-04T10:00:00Z', category: 'Risk',   status: 'failure', title: 'Risk: Unfamiliar',     summary: 'Level: high',    detail: { riskLevel: 'high' } },
];
Timeline.init(document.getElementById('tc'));
Timeline.load(events, () => {});
check('all events visible initially', Timeline.visibleEvents().length, 4);

Timeline.setStatusFilter(['failure']);
check('failures only', Timeline.visibleEvents().map(e => e.id).join(','), 'b,d');

Timeline.setStatusFilter(null);
Timeline.setTextFilter('sharepoint');
check('text filter matches title', Timeline.visibleEvents().map(e => e.id).join(','), 'b');

Timeline.setTextFilter('10.0.0.1');
check('text filter reaches into detail', Timeline.visibleEvents().map(e => e.id).join(','), 'a');

Timeline.setTextFilter('');
Timeline.filterByCategories(['SignIn']);
check('category filter', Timeline.visibleEvents().map(e => e.id).join(','), 'a,b');

Timeline.setStatusFilter(['failure']);
check('filters compose (SignIn + failure)', Timeline.visibleEvents().map(e => e.id).join(','), 'b');

Timeline.filterByCategories(['SignIn', 'Audit', 'CA', 'Risk', 'Provisioning']);
Timeline.setStatusFilter(null);
check('ordering is oldest-first', Timeline.visibleEvents().map(e => e.id).join(','), 'a,b,c,d');

/* ── 3. Duplicate-id guard ── */
console.log('\nRobustness:');
try {
  Timeline.load([...events, { ...events[0] }], () => {});
  check('duplicate ids do not throw', true, true);
} catch (e) { check('duplicate ids do not throw', `threw: ${e.message}`, true); }

/* ── 4. Cluster click guard ── */
Timeline.load(events, () => {});
let selected = null;
Timeline.load(events, ev => { selected = ev.id; });
handlers.select({ items: ['cluster-xyz'] });
check('cluster id does not open the detail panel', selected, 'null');
handlers.select({ items: ['b'] });
check('real event id opens the detail panel', selected, 'b');

/* ── 5. Keyboard navigation ── */
console.log('\nKeyboard navigation:');
let nav = null;
Timeline.load(events, () => {});
Timeline.selectOffset(-1, ev => { nav = ev.id; });
check('with nothing selected, starts at newest', nav, 'd');
Timeline.selectOffset(-1, ev => { nav = ev.id; });
check('left goes older', nav, 'c');
Timeline.selectOffset(1, ev => { nav = ev.id; });
check('right goes newer', nav, 'd');

/* ── 6. Table sorting ── */
console.log('\nTable view:');
const tableEl = document.getElementById('table-wrap');
EventTable.init(tableEl, () => {});
EventTable.render();
const html = tableEl.innerHTML;
check('renders a row per event', (html.match(/<tr data-id=/g) || []).length, 4);
check('newest first by default', html.indexOf('data-id="d"') < html.indexOf('data-id="a"'), true);
check('reports the count', /4 events/.test(html), true);
check('escapes into cells', !/<script/.test(html), true);

Timeline.setTextFilter('risk');
EventTable.render();
check('table honours the shared filter', (tableEl.innerHTML.match(/<tr data-id=/g) || []).length, 1);

/* ── 7. Density buckets ── */
console.log('\nDensity strip:');
const t0 = Date.UTC(2026, 6, 1, 0, 0, 0);   // 2026-07-01T00:00Z
const t1 = Date.UTC(2026, 6, 5, 0, 0, 0);   // four days later
const dens = [
  { timestamp: '2026-07-01T01:00:00Z', status: 'success' },
  { timestamp: '2026-07-01T02:00:00Z', status: 'failure' },
  { timestamp: '2026-07-01T03:00:00Z', status: 'failure' },
  { timestamp: '2026-07-03T12:00:00Z', status: 'success' },
  { timestamp: '2026-06-30T12:00:00Z', status: 'success' },   // before the window
  { timestamp: '2026-07-09T12:00:00Z', status: 'success' },   // after the window
  { timestamp: 'not a date',           status: 'success' },
];
const b4 = Timeline.computeBuckets(dens, t0, t1, 4);
check('one bucket per requested slot', b4.length, 4);
check('day 1 collects its three events', b4[0].total, 3);
check('failures counted separately',    b4[0].failures, 2);
check('day 3 collects one event',       b4[2].total, 1);
check('events outside the window are dropped', b4.reduce((n, b) => n + b.total, 0), 4);
check('buckets tile the window without gaps', b4[0].end, b4[1].start);
check('last bucket ends at the window end',   b4[3].end, t1);
check('degenerate window yields nothing', Timeline.computeBuckets(dens, t1, t0, 4).length, 0);

// An event landing exactly on the final boundary must not fall off the end.
const edge = Timeline.computeBuckets([{ timestamp: '2026-07-04T23:59:59Z', status: 'success' }], t0, t1, 4);
check('event at the trailing edge lands in the last bucket', edge[3].total, 1);

/* ── 8. Off-hours bands ── */
console.log('\nOff-hours shading:');
// Wed 2026-07-01 00:00Z → Thu 2026-07-02 00:00Z, nights on.
const night = Timeline.computeOffHours(Date.UTC(2026, 6, 1), Date.UTC(2026, 6, 2), true);
check('a midweek day yields two bands', night.length, 2);
check('first band starts at midnight',  new Date(night[0].start).toISOString(), '2026-07-01T00:00:00.000Z');
check('first band ends at 06:00',       new Date(night[0].end).toISOString(),   '2026-07-01T06:00:00.000Z');
check('second band starts at 18:00',    new Date(night[1].start).toISOString(), '2026-07-01T18:00:00.000Z');

// The same day with nights suppressed (the zoomed-out case) is all working hours.
check('nights off leaves a midweek day clear',
  Timeline.computeOffHours(Date.UTC(2026, 6, 1), Date.UTC(2026, 6, 2), false).length, 0);

// Fri 2026-07-03 18:00Z through Mon 2026-07-06 06:00Z is one continuous stretch.
const weekend = Timeline.computeOffHours(Date.UTC(2026, 6, 3, 12), Date.UTC(2026, 6, 6, 12), true);
check('weekend merges with the nights either side', weekend.length, 1);
check('run opens Friday 18:00',  new Date(weekend[0].start).toISOString(), '2026-07-03T18:00:00.000Z');
check('run closes Monday 06:00', new Date(weekend[0].end).toISOString(),   '2026-07-06T06:00:00.000Z');

// Zoomed out, only the weekend itself is shaded.
const wkOnly = Timeline.computeOffHours(Date.UTC(2026, 6, 3, 12), Date.UTC(2026, 6, 6, 12), false);
check('nights off still shades the weekend', wkOnly.length, 1);
check('weekend band runs Sat 00:00 to Mon 00:00',
  `${new Date(wkOnly[0].start).toISOString()}..${new Date(wkOnly[0].end).toISOString()}`,
  '2026-07-04T00:00:00.000Z..2026-07-06T00:00:00.000Z');

// Shading is drawn as background items, and vis clusters anything the criteria
// accepts — without the type guard the bands collapse into count bubbles.
const criteria = visOptions.cluster.clusterCriteria;
check('cluster criteria rejects background items',
  criteria({ type: 'background' }, { type: 'background' }), false);
check('cluster criteria rejects a background/foreground pair',
  criteria({ group: 'SignIn' }, { type: 'background' }), false);
check('cluster criteria still groups real items',
  criteria({ group: 'SignIn' }, { group: 'SignIn' }), true);
check('cluster criteria still separates lanes',
  criteria({ group: 'SignIn' }, { group: 'Audit' }), false);

/* ── 9. Severity ── */
console.log('\nSeverity sizing:');
const sev = ev => Timeline.computeSeverity(ev);
check('a high risk detection is high',
  sev({ category: 'Risk', status: 'failure', detail: { riskLevel: 'high' } }), 'high');
check('a blocked conditional access evaluation is high',
  sev({ category: 'CA', status: 'failure', detail: {} }), 'high');
check('any risk-category failure is high',
  sev({ category: 'Risk', status: 'failure', detail: { riskLevel: 'none' } }), 'high');
check('a risky sign-in reads riskLevelDuringSignIn',
  sev({ category: 'SignIn', status: 'success', detail: { riskLevelDuringSignIn: 'high' } }), 'high');
check('an ordinary failed sign-in is medium',
  sev({ category: 'SignIn', status: 'failure', detail: {} }), 'med');
check('an MFA-required sign-in is medium',
  sev({ category: 'SignIn', status: 'warning', detail: {} }), 'med');
check('medium risk is medium',
  sev({ category: 'SignIn', status: 'success', detail: { riskLevelDuringSignIn: 'medium' } }), 'med');
check('a routine success is low',
  sev({ category: 'SignIn', status: 'success', detail: {} }), 'low');
check('a missing detail does not throw',
  sev({ category: 'Audit', status: 'success' }), 'low');

check('worst status picks failure over success',
  Timeline.worstStatus(['success', 'failure', 'info']), 'failure');
check('worst status picks warning over success',
  Timeline.worstStatus(['success', 'warning']), 'warning');
check('worst status of nothing is info', Timeline.worstStatus([]), 'info');

/* ── 10. Sign-in sessions ── */
console.log('\nSign-in sessions:');
const sess = [
  { id: 's1', category: 'SignIn', status: 'success', timestamp: '2026-07-01T10:00:00Z', detail: { correlationId: 'c1' } },
  { id: 's2', category: 'SignIn', status: 'failure', timestamp: '2026-07-01T10:00:40Z', detail: { correlationId: 'c1' } },
  { id: 's3', category: 'SignIn', status: 'success', timestamp: '2026-07-01T10:01:10Z', detail: { correlationId: 'c1' } },
  { id: 's4', category: 'SignIn', status: 'success', timestamp: '2026-07-01T12:00:00Z', detail: { correlationId: 'c2' } },
  { id: 's5', category: 'SignIn', status: 'success', timestamp: '2026-07-01T13:00:00Z', detail: {} },
  { id: 'a1', category: 'Audit',  status: 'success', timestamp: '2026-07-01T10:00:20Z', detail: { correlationId: 'c1' } },
];
const sessions = Timeline.computeSessions(sess);
check('only multi-record correlations become sessions', sessions.length, 1);
check('the session spans first to last',
  `${new Date(sessions[0].start).toISOString()}..${new Date(sessions[0].end).toISOString()}`,
  '2026-07-01T10:00:00.000Z..2026-07-01T10:01:10.000Z');
check('the session counts its sign-ins', sessions[0].count, 3);
check('an audit sharing the id is not pulled into the session', sessions[0].count, 3);
check('the session takes the worst status inside it', sessions[0].status, 'failure');

check('a correlation with no span is skipped', Timeline.computeSessions([
  { id: 'z1', category: 'SignIn', status: 'success', timestamp: '2026-07-01T10:00:00Z', detail: { correlationId: 'z' } },
  { id: 'z2', category: 'SignIn', status: 'success', timestamp: '2026-07-01T10:00:00Z', detail: { correlationId: 'z' } },
]).length, 0);
check('an unparseable timestamp is ignored', Timeline.computeSessions([
  { id: 'y1', category: 'SignIn', status: 'success', timestamp: 'nonsense', detail: { correlationId: 'y' } },
  { id: 'y2', category: 'SignIn', status: 'success', timestamp: '2026-07-01T10:00:00Z', detail: { correlationId: 'y' } },
]).length, 0);
check('sessions come back oldest first', Timeline.computeSessions([
  { id: 'l1', category: 'SignIn', status: 'success', timestamp: '2026-07-02T10:00:00Z', detail: { correlationId: 'late' } },
  { id: 'l2', category: 'SignIn', status: 'success', timestamp: '2026-07-02T10:05:00Z', detail: { correlationId: 'late' } },
  { id: 'e1', category: 'SignIn', status: 'success', timestamp: '2026-07-01T10:00:00Z', detail: { correlationId: 'early' } },
  { id: 'e2', category: 'SignIn', status: 'success', timestamp: '2026-07-01T10:05:00Z', detail: { correlationId: 'early' } },
]).map(s => s.correlationId).join(','), 'early,late');

// The cap keeps a pathological feed from filling the DataSet with bands.
const many = [];
for (let i = 0; i < 40; i++) {
  many.push({ id: `m${i}a`, category: 'SignIn', status: 'success', timestamp: `2026-07-01T${String(i % 24).padStart(2, '0')}:00:00Z`, detail: { correlationId: `m${i}` } });
  many.push({ id: `m${i}b`, category: 'SignIn', status: 'success', timestamp: `2026-07-01T${String(i % 24).padStart(2, '0')}:30:00Z`, detail: { correlationId: `m${i}` } });
}
check('sessions are capped', Timeline.computeSessions(many, { max: 10 }).length, 10);

/* ── 11. Recent users ── */
console.log('\nRecent users:');
const mkStore = () => {
  const map = new Map();
  return { getItem: k => (map.has(k) ? map.get(k) : null),
           setItem: (k, v) => map.set(k, v),
           removeItem: k => map.delete(k) };
};

let store = mkStore();
check('empty to begin with', readRecents('t1', store).length, 0);

pushRecent('t1', { id: 'u1', displayName: 'Alice', userPrincipalName: 'a@x.com' }, store);
pushRecent('t1', { id: 'u2', displayName: 'Bob',   userPrincipalName: 'b@x.com' }, store);
check('most recent first', readRecents('t1', store).map(u => u.id).join(','), 'u2,u1');

pushRecent('t1', { id: 'u1', displayName: 'Alice', userPrincipalName: 'a@x.com' }, store);
check('re-selecting moves to front without duplicating',
  readRecents('t1', store).map(u => u.id).join(','), 'u1,u2');

for (let i = 0; i < 8; i++) pushRecent('t1', { id: `x${i}`, displayName: `X${i}` }, store);
check('capped at 5', readRecents('t1', store).length, 5);

pushRecent('t2', { id: 'other', displayName: 'Other tenant user' }, store);
check('tenants are isolated', readRecents('t2', store).map(u => u.id).join(','), 'other');
check('other tenant untouched', readRecents('t1', store).length, 5);

check('ignores a user with no id', pushRecent('t3', { displayName: 'no id' }, store).length, 0);

clearRecents(store);
check('clearing wipes every tenant',
  readRecents('t1', store).length + readRecents('t2', store).length, 0);

const broken = { getItem: () => '{ not json', setItem: () => {}, removeItem: () => {} };
check('survives corrupt storage', readRecents('t1', broken).length, 0);

const throwing = { getItem: () => { throw new Error('blocked'); },
                   setItem: () => { throw new Error('blocked'); },
                   removeItem: () => { throw new Error('blocked'); } };
check('survives storage being unavailable', readRecents('t1', throwing).length, 0);

console.log(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
