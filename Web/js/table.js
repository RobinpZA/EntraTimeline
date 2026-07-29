/* ── Table view ───────────────────────────────────────────────────────────
   The timeline answers "when did this happen and what surrounds it". It does
   not answer "show me every failure, newest first" — at 1,200+ events most of
   the lane is clusters. This view renders the same filtered set as a sortable
   list, so triage and scanning have somewhere to happen.                    */
const EventTable = (() => {

  let container  = null;
  let onSelectCb = null;
  let sortKey    = 'timestamp';
  let sortDir    = -1;          // -1 newest first
  let rendered   = [];

  // Rows are capped because a 5,000-row table is slow to build and useless to
  // read; the count line says what is being held back.
  const MAX_ROWS = 500;

  const COLUMNS = [
    { key: 'timestamp',   label: 'Time (UTC)', width: '150px' },
    { key: 'category',    label: 'Category',   width: '120px' },
    { key: 'title',       label: 'Event',      width: 'auto'  },
    { key: 'status',      label: 'Status',     width: '110px' },
    { key: 'summary',     label: 'Detail',     width: 'auto'  },
  ];

  function init(el, onSelect) {
    container  = el;
    onSelectCb = onSelect;

    container.addEventListener('click', e => {
      const th = e.target.closest('th[data-key]');
      if (th) { toggleSort(th.dataset.key); return; }

      const tr = e.target.closest('tr[data-id]');
      if (tr && onSelectCb) {
        const ev = rendered.find(x => x.id === tr.dataset.id);
        if (ev) {
          container.querySelectorAll('tr.row-selected').forEach(r => r.classList.remove('row-selected'));
          tr.classList.add('row-selected');
          onSelectCb(ev);
        }
      }
    });

    // Rows are focusable, so Enter should open one just like a click.
    container.addEventListener('keydown', e => {
      if (e.key !== 'Enter') return;
      const tr = e.target.closest('tr[data-id]');
      if (tr) tr.click();
    });
  }

  function toggleSort(key) {
    if (sortKey === key) { sortDir = -sortDir; }
    else { sortKey = key; sortDir = key === 'timestamp' ? -1 : 1; }
    render();
  }

  function compare(a, b) {
    let av = a[sortKey] ?? '';
    let bv = b[sortKey] ?? '';
    if (sortKey === 'timestamp') { av = new Date(av).getTime() || 0; bv = new Date(bv).getTime() || 0; }
    else { av = String(av).toLowerCase(); bv = String(bv).toLowerCase(); }
    if (av < bv) return -sortDir;
    if (av > bv) return sortDir;
    return 0;
  }

  function render() {
    if (!container) return;

    const all = Timeline.visibleEvents().slice().sort(compare);
    rendered  = all.slice(0, MAX_ROWS);

    if (all.length === 0) {
      container.innerHTML = `<div class="detail-placeholder">No events match the current filters.</div>`;
      return;
    }

    const head = COLUMNS.map(c => {
      const active = sortKey === c.key;
      const arrow  = active ? (sortDir === 1 ? 'bi-caret-up-fill' : 'bi-caret-down-fill') : 'bi-dash';
      return `<th data-key="${c.key}" style="width:${c.width}"
                  scope="col" tabindex="0"
                  aria-sort="${active ? (sortDir === 1 ? 'ascending' : 'descending') : 'none'}">
                ${esc(c.label)} <i class="bi ${arrow} sort-icon"></i>
              </th>`;
    }).join('');

    const body = rendered.map(e => `
      <tr data-id="${esc(e.id)}" tabindex="0">
        <td class="mono nowrap">${esc(formatDateShort(e.timestamp))}</td>
        <td><span class="cat-chip cat-chip-${esc(e.category)}">${esc(e.category)}</span></td>
        <td class="cell-title"><i class="bi ${esc(e.icon)}" style="color:${esc(e.color)}"></i> ${esc(e.title)}</td>
        <td>${statusBadge(e.status)}</td>
        <td class="cell-summary">${esc(e.summary ?? '')}</td>
      </tr>`).join('');

    const capped = all.length > MAX_ROWS
      ? `<div class="table-note">Showing the first ${MAX_ROWS} of ${all.length} matching events — narrow the filter to see the rest.</div>`
      : `<div class="table-note">${all.length} event${all.length === 1 ? '' : 's'}</div>`;

    container.innerHTML = `
      ${capped}
      <div class="table-scroll">
        <table class="event-table">
          <thead><tr>${head}</tr></thead>
          <tbody>${body}</tbody>
        </table>
      </div>`;
  }

  function clear() {
    rendered = [];
    if (container) container.innerHTML = '';
  }

  return { init, render, clear };
})();
