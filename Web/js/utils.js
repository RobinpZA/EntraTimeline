/* ── Date / time ──────────────────────────────────────────────────────────
   Every timestamp in this portal is rendered in UTC — the timeline axis, the
   tooltips, the detail panel and the captions. Graph returns UTC, and an
   investigation that mixes zones invites wrong conclusions: previously the
   tooltip showed local time while the detail panel showed UTC, so the same
   event appeared to happen twice, hours apart. The header carries a UTC badge
   so the convention is stated rather than assumed.                          */

const UTC_OPTS = { timeZone: 'UTC', hour12: false };

function formatDate(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('en-ZA', {
    ...UTC_OPTS,
    year: 'numeric', month: 'short', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit'
  });
}

function formatDateShort(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('en-ZA', {
    ...UTC_OPTS,
    month: 'short', day: '2-digit',
    hour: '2-digit', minute: '2-digit'
  });
}

function formatTime(iso) {
  if (!iso) return '';
  return new Date(iso).toLocaleTimeString('en-ZA', {
    ...UTC_OPTS,
    hour: '2-digit', minute: '2-digit', second: '2-digit'
  });
}

function dateRangeLabel(events) {
  if (!events || events.length === 0) return '';
  const ts = events.map(e => new Date(e.timestamp)).filter(d => !isNaN(d));
  if (ts.length === 0) return '';
  const min = new Date(Math.min(...ts));
  const max = new Date(Math.max(...ts));
  return `${formatDateShort(min.toISOString())} – ${formatDateShort(max.toISOString())}`;
}

/* ── Status badge ─────────────────────────────────────────────────────── */
function statusBadge(status, text) {
  const label = text ?? status;
  const cls   = { success: 'badge-success', failure: 'badge-failure',
                  warning: 'badge-warning',  info:    'badge-info' }[status] ?? 'badge-info';
  const icon  = { success: 'bi-check-circle', failure: 'bi-x-circle',
                  warning: 'bi-exclamation-circle', info: 'bi-info-circle' }[status] ?? 'bi-circle';
  return `<span class="status-badge ${cls}"><i class="bi ${icon}"></i>${esc(label)}</span>`;
}

/* ── Escape HTML ──────────────────────────────────────────────────────── */
function esc(str) {
  if (str === null || str === undefined) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/* ── Debounce ─────────────────────────────────────────────────────────── */
function debounce(fn, delay) {
  let timer;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), delay);
  };
}

/* ── Toasts ───────────────────────────────────────────────────────────────
   For transient actions only. Anything describing the state of the loaded
   data (partial, truncated, nothing found) belongs in the banner instead —
   three stacked 8-second toasts is not a status report.                    */
function showToast(message, type = 'info', duration = 3700) {
  const container = document.getElementById('toast-container');
  const icons = { success: 'bi-check-circle', error: 'bi-x-circle',
                  warning: 'bi-exclamation-triangle', info: 'bi-info-circle' };
  const toast = document.createElement('div');
  toast.className = `toast toast-${type}`;
  toast.setAttribute('role', 'status');
  toast.innerHTML = `<i class="bi ${icons[type] ?? 'bi-info-circle'}"></i>${esc(message)}`;
  container.appendChild(toast);
  setTimeout(() => {
    toast.classList.add('fade-out');
    setTimeout(() => toast.remove(), 350);
  }, duration);
}

/* ── Data-state banner ────────────────────────────────────────────────── */
function showBanner(messages, level = 'warning') {
  const banner = document.getElementById('data-banner');
  const list   = Array.isArray(messages) ? messages : [messages];
  if (list.length === 0) { hideBanner(); return; }

  const icon = level === 'error' ? 'bi-exclamation-octagon' : 'bi-exclamation-triangle';
  banner.className = `data-banner banner-${level}`;
  banner.innerHTML = `
    <i class="bi ${icon}"></i>
    <div class="banner-text">${list.map(m => `<div>${esc(m)}</div>`).join('')}</div>
    <button class="btn-icon banner-close" aria-label="Dismiss message"><i class="bi bi-x-lg"></i></button>`;
  banner.querySelector('.banner-close').addEventListener('click', hideBanner);
}

function hideBanner() {
  const banner = document.getElementById('data-banner');
  banner.classList.add('hidden');
  banner.innerHTML = '';
}

/* ── Loading indicator ────────────────────────────────────────────────────
   Non-blocking: the previous timeline stays readable while a refresh runs.
   A 30-day pull with non-interactive sign-ins can take the better part of a
   minute, so the elapsed counter distinguishes "working" from "hung".      */
let loadingTimer = null;

function showLoading(msg = 'Loading…') {
  const bar     = document.getElementById('loading-bar');
  const label   = document.getElementById('loading-msg');
  const started = Date.now();

  label.textContent = msg;
  bar.classList.remove('hidden');
  document.getElementById('loading-elapsed').textContent = '0s';

  clearInterval(loadingTimer);
  loadingTimer = setInterval(() => {
    const secs = Math.round((Date.now() - started) / 1000);
    document.getElementById('loading-elapsed').textContent = `${secs}s`;
  }, 1000);
}

function hideLoading() {
  clearInterval(loadingTimer);
  loadingTimer = null;
  document.getElementById('loading-bar').classList.add('hidden');
}

/* ── Recent users ─────────────────────────────────────────────────────────
   Keyed by tenant so a partner switching tenants never sees another client's
   names, and capped short. This puts user names and UPNs in the browser's
   localStorage — less than Cache/ already holds on disk, but it is tenant data,
   so "Clear cache" wipes it too.                                            */
const RECENTS_KEY = 'entratimeline.recents';
const RECENTS_MAX = 5;

function readRecents(tenantId, store) {
  const s = store ?? window.localStorage;
  try {
    const all = JSON.parse(s.getItem(RECENTS_KEY) ?? '{}');
    return Array.isArray(all[tenantId]) ? all[tenantId] : [];
  } catch {
    return [];
  }
}

function pushRecent(tenantId, user, store) {
  const s = store ?? window.localStorage;
  if (!tenantId || !user || !user.id) return readRecents(tenantId, s);
  try {
    const all  = JSON.parse(s.getItem(RECENTS_KEY) ?? '{}');
    const list = Array.isArray(all[tenantId]) ? all[tenantId] : [];
    const entry = {
      id: user.id,
      displayName: user.displayName ?? '',
      userPrincipalName: user.userPrincipalName ?? ''
    };
    const next = [entry, ...list.filter(u => u.id !== user.id)].slice(0, RECENTS_MAX);
    all[tenantId] = next;
    s.setItem(RECENTS_KEY, JSON.stringify(all));
    return next;
  } catch {
    return readRecents(tenantId, s);
  }
}

function clearRecents(store) {
  const s = store ?? window.localStorage;
  try { s.removeItem(RECENTS_KEY); } catch { /* storage unavailable */ }
}

/* ── Value display ────────────────────────────────────────────────────── */
function displayVal(v) {
  if (v === null || v === undefined || v === '') return '<span class="val-empty">—</span>';
  if (typeof v === 'boolean') return v
    ? '<span class="val-yes">Yes</span>'
    : '<span class="val-no">No</span>';
  if (Array.isArray(v)) return v.length ? esc(v.join(', ')) : '<span class="val-empty">—</span>';
  return `<span class="mono">${esc(String(v))}</span>`;
}
