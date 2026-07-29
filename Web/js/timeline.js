/* ── Timeline module ──────────────────────────────────────────────────── */
const Timeline = (() => {
  let tl        = null;
  let items     = null;
  let groups    = null;
  let allEvents = [];
  let onSelectCb = null;

  // Density strip and overview elements. All optional — the module works without
  // them, which is what the headless UI checks rely on.
  let densityEl = null;
  let plotEl    = null;
  let peakEl    = null;
  let lastBuckets = [];

  let miniEl    = null;
  let miniTrack = null;
  let miniBars  = null;
  let miniWin   = null;
  let miniRange = null;   // { start, end } of the whole loaded set

  // id → event, for the cluster decorator's per-redraw lookups.
  let eventById = new Map();

  // Filters are held together so one visibleEvents() drives the timeline, the
  // table and keyboard navigation. Category used to be applied by hiding vis
  // groups instead, which meant the three views disagreed about what was shown.
  let statusFilter = null;   // null = all, or ['failure']
  let textFilter   = '';     // lower-cased free text
  let activeCats   = null;   // null = all

  let clusterHintShown = false;

  const DAY           = 24 * 60 * 60 * 1000;
  const SHADE_PREFIX  = 'shade-';
  const SHADE_STEP    = 30 * 60 * 1000;   // resolution of the off-hours scan
  const NIGHT_MAX_SPAN = 10 * DAY;        // above this, nightly bands are noise

  const SESSION_PREFIX = 'session-';
  const SESSION_MAX    = 250;             // guard against a pathological feed

  // Ranked worst-first so a mixed cluster or session takes its colour from the
  // most serious thing inside it.
  const STATUS_RANK = { failure: 3, warning: 2, success: 1, info: 0 };

  const GROUP_DEF = [
    { id: 'SignIn',       icon: 'bi-box-arrow-in-right', name: 'Sign-Ins',           order: 1 },
    { id: 'Audit',        icon: 'bi-pencil-square',      name: 'Directory Changes',  order: 2 },
    { id: 'CA',           icon: 'bi-shield-check',       name: 'Conditional Access', order: 3 },
    { id: 'Risk',         icon: 'bi-exclamation-triangle', name: 'Risk Events',      order: 4 },
    { id: 'Provisioning', icon: 'bi-arrow-repeat',       name: 'Provisioning',       order: 5 },
  ];

  const OPTIONS = {
    stack:           true,
    showCurrentTime: true,
    zoomMin:         1000 * 60 * 60,            // 1 hour
    zoomMax:         1000 * 60 * 60 * 24 * 35,  // ~35 days: the range cap is 30
    orientation:     'top',
    groupOrder:      'order',
    tooltip:         { followMouse: true, overflowMethod: 'cap' },
    maxHeight:       '100%',
    groupHeightMode: 'fixed',
    // Render the axis in UTC so it agrees with every other timestamp shown.
    moment:          date => vis.moment(date).utc(),
    cluster: {
      maxItems:        8,
      // Background items (the off-hours bands) share an internal group and would
      // otherwise cluster with each other into count bubbles — vis clusters
      // everything the criteria accepts, not just foreground items.
      clusterCriteria: (a, b) =>
        a.type !== 'background' && b.type !== 'background' && a.group === b.group,
      titleTemplate:   '{count} events — click to zoom in',
      fitOnDoubleClick: true,
    },
  };

  function laneLabel(def, count) {
    return `<div class="lane-label" data-cat="${def.id}">
      <i class="bi ${def.icon} lane-icon"></i>
      <span class="lane-name">${def.name}</span>
      <span class="lane-count">${count}</span>
    </div>`;
  }

  function buildItemContent(ev) {
    return `<i class="bi ${ev.icon}" style="color:${ev.color}"></i>`;
  }

  function buildTooltip(ev) {
    return `<b>${esc(ev.title)}</b><br>${esc(formatDateShort(ev.timestamp))} UTC<br>${esc(ev.summary ?? '')}`;
  }

  /* ── Severity ─────────────────────────────────────────────────────────────
     Colour already carries status, and doubling up on it adds nothing. Size is
     a free channel, so it carries severity: how much this event should pull the
     eye. A high-risk detection and a blocked sign-in are the two things worth
     spotting from across the room, so both land in 'high'.                   */
  function worstStatus(statuses) {
    return statuses.reduce(
      (worst, s) => ((STATUS_RANK[s] ?? 0) > (STATUS_RANK[worst] ?? 0) ? s : worst),
      'info');
  }

  function computeSeverity(ev) {
    const d    = ev.detail ?? {};
    const risk = String(d.riskLevel ?? d.riskLevelDuringSignIn ?? '').toLowerCase();

    if (risk === 'high') return 'high';
    if (ev.status === 'failure' && (ev.category === 'Risk' || ev.category === 'CA')) return 'high';
    if (risk === 'medium' || ev.status === 'failure' || ev.status === 'warning') return 'med';
    return 'low';
  }

  /* ── Sign-in sessions ─────────────────────────────────────────────────────
     Sign-in records sharing a correlationId are one authentication flow across
     several resources. As bare points they read as an unexplained scatter; as a
     span they read as a session, which is the unit an investigation reasons in.

     Drawn as a background item inside the Sign-Ins lane so the points stay
     exactly where they were, clickable, on top of their own session bar.    */
  function computeSessions(events, { max = SESSION_MAX } = {}) {
    const byCorrelation = new Map();

    events.forEach(ev => {
      if (ev.category !== 'SignIn') return;
      const cid = ev.detail?.correlationId;
      if (!cid) return;
      const t = new Date(ev.timestamp).getTime();
      if (isNaN(t)) return;

      let s = byCorrelation.get(cid);
      if (!s) {
        s = { correlationId: cid, start: t, end: t, count: 0, statuses: [] };
        byCorrelation.set(cid, s);
      }
      s.start = Math.min(s.start, t);
      s.end   = Math.max(s.end, t);
      s.count++;
      s.statuses.push(ev.status);
    });

    return [...byCorrelation.values()]
      // A single record, or several stamped at the same instant, has no span to
      // draw — the dot already says everything a zero-width bar could.
      .filter(s => s.count > 1 && s.end > s.start)
      .sort((a, b) => a.start - b.start)
      .slice(0, max)
      .map(s => ({
        correlationId: s.correlationId,
        start:  s.start,
        end:    s.end,
        count:  s.count,
        status: worstStatus(s.statuses),
      }));
  }

  // Precomputed once per load so typing in the filter box does not re-stringify
  // every event's detail on each keystroke.
  function searchBlob(ev) {
    let detail = '';
    try { detail = JSON.stringify(ev.detail ?? {}).slice(0, 2000); } catch { detail = ''; }
    return [ev.title, ev.summary, ev.category, ev.subcategory, ev.status, detail]
      .filter(Boolean).join(' ').toLowerCase();
  }

  /* ── Off-hours shading ────────────────────────────────────────────────────
     Weekends and 18:00–06:00 are shaded behind the lanes so an out-of-hours
     event reads as unusual without the reader doing arithmetic on the axis.
     Everything here is UTC, matching every other timestamp in the portal.

     Returned as maximal contiguous runs rather than one band per night: a
     Friday evening through Monday morning is a single stretch of off-hours, and
     emitting it as one item avoids seams and overlapping translucent fills. */
  function isOffHours(ms, showNights) {
    const d   = new Date(ms);
    const day = d.getUTCDay();
    if (day === 0 || day === 6) return true;          // Sunday / Saturday
    if (!showNights) return false;
    const h = d.getUTCHours();
    return h < 6 || h >= 18;
  }

  function computeOffHours(fromMs, toMs, showNights) {
    const runs = [];
    let open = null;
    for (let t = fromMs; t < toMs; t += SHADE_STEP) {
      if (isOffHours(t, showNights)) {
        if (open === null) open = t;
      } else if (open !== null) {
        runs.push({ start: open, end: t });
        open = null;
      }
    }
    if (open !== null) runs.push({ start: open, end: toMs });
    return runs;
  }

  let shadeIds = [];
  let shadeSig = '';
  let shading  = false;

  function applyShading() {
    // Writing to the DataSet triggers a redraw, which can re-enter through
    // rangechanged — the signature check makes the common case a no-op and the
    // flag covers the rest.
    if (!tl || !items || shading) return;

    const w          = tl.getWindow();
    const showNights = (w.end - w.start) <= NIGHT_MAX_SPAN;

    // Pad by a day and snap to whole days so ordinary panning does not rebuild
    // the bands, and so no unshaded edge scrolls into view.
    const from = Math.floor((w.start.getTime() - DAY) / DAY) * DAY;
    const to   = Math.ceil((w.end.getTime() + DAY) / DAY) * DAY;
    const sig  = `${from}|${to}|${showNights}`;
    if (sig === shadeSig) return;
    shadeSig = sig;

    shading = true;
    try {
      if (shadeIds.length) items.remove(shadeIds);
      const rows = computeOffHours(from, to, showNights).map((r, i) => ({
        id:        `${SHADE_PREFIX}${i}`,
        start:     new Date(r.start),
        end:       new Date(r.end),
        type:      'background',
        className: 'shade-offhours',
      }));
      shadeIds = rows.map(r => r.id);
      if (rows.length) items.add(rows);
    } finally {
      shading = false;
    }
  }

  /* ── Density strip ────────────────────────────────────────────────────────
     Buckets whatever is currently visible across the current window. Bucketing
     against the window rather than the whole range means the strip stays
     informative at every zoom level, and at 30 days it shows the bursts that
     the lanes can only render as clusters. */
  function computeBuckets(events, startMs, endMs, count) {
    const span = endMs - startMs;
    if (!(span > 0) || count < 1) return [];

    const width   = span / count;
    const buckets = Array.from({ length: count }, (_, i) => ({
      start: startMs + i * width,
      end:   startMs + (i + 1) * width,
      total: 0,
      failures: 0,
    }));

    events.forEach(ev => {
      const t = new Date(ev.timestamp).getTime();
      if (isNaN(t) || t < startMs || t >= endMs) return;
      const b = buckets[Math.min(count - 1, Math.floor((t - startMs) / width))];
      b.total++;
      if (ev.status === 'failure') b.failures++;
    });

    return buckets;
  }

  function renderDensity() {
    if (!tl || !plotEl || typeof plotEl.getBoundingClientRect !== 'function') return;

    // Measure the timeline's own centre panel rather than trying to match its
    // label-column width by configuration — measurement keeps the two aligned
    // through detail-panel drags and window resizes alike.
    const centre = document.querySelector('#timeline-container .vis-panel.vis-center');
    if (!centre) return;

    const host = densityEl.getBoundingClientRect();
    const rect = centre.getBoundingClientRect();
    if (rect.width < 40) return;

    plotEl.style.left  = `${rect.left - host.left}px`;
    plotEl.style.width = `${rect.width}px`;

    const w       = tl.getWindow();
    const count   = Math.max(12, Math.min(180, Math.round(rect.width / 7)));
    const buckets = computeBuckets(visibleEvents(), w.start.getTime(), w.end.getTime(), count);
    const peak    = buckets.reduce((m, b) => Math.max(m, b.total), 0);
    lastBuckets   = buckets;

    if (peak === 0) {
      plotEl.innerHTML = '<span class="density-empty">No events in this window</span>';
      if (peakEl) peakEl.textContent = '0 in view';
      densityEl.setAttribute('aria-label', 'Activity density: no events in the visible time range');
      return;
    }

    const shown  = buckets.reduce((n, b) => n + b.total, 0);
    const failed = buckets.reduce((n, b) => n + b.failures, 0);
    const pct    = 100 / count;

    plotEl.innerHTML = buckets.map((b, i) => {
      if (b.total === 0) return '';
      // A one-event bucket still has to be visible, hence the floor.
      const h    = Math.max(8, Math.round((b.total / peak) * 100));
      const fail = Math.round((b.failures / b.total) * 100);
      const tip  = `${b.total} event${b.total === 1 ? '' : 's'}`
                 + (b.failures ? ` · ${b.failures} failed` : '')
                 + ` · ${formatDateShort(new Date(b.start).toISOString())} UTC`;
      return `<button type="button" class="dens-bar" data-i="${i}" tabindex="-1"
                      title="${esc(tip)}" aria-hidden="true"
                      style="left:${i * pct}%;width:${pct}%;height:${h}%">${
                b.failures ? `<span class="dens-fail" style="height:${fail}%"></span>` : ''
              }</button>`;
    }).join('');

    if (peakEl) peakEl.textContent = `${shown} in view · peak ${peak}`;
    densityEl.setAttribute('aria-label',
      `Activity density: ${shown} events in the visible range, ${failed} failed, busiest bucket ${peak}`);
  }

  /* ── Cluster decoration ───────────────────────────────────────────────────
     vis hard-codes a cluster's content to the bare count — titleTemplate only
     reaches the tooltip — so a bubble holding nine routine sign-ins looks
     exactly like one holding ninety with a block among them. There is no
     supported hook, so this reads the pinned vendor build's cluster objects and
     writes classes and a width onto their boxes after each redraw.

     Read-only against vis, wrapped, and feature-detected: if a future vis
     changes shape, clusters simply go back to looking the way they did.     */
  function decorateClusters() {
    let clusters;
    try { clusters = tl && tl.itemSet && tl.itemSet.clusters; } catch { return; }
    if (!Array.isArray(clusters)) return;

    clusters.forEach(c => {
      const box = c && c.dom && c.dom.box;
      if (!box || !box.classList) return;

      const uiItems  = (c.data && c.data.uiItems) || [];
      const count    = uiItems.length;
      const statuses = uiItems
        .map(u => eventById.get(u && u.data ? u.data.id : u && u.id))
        .filter(Boolean)
        .map(e => e.status);

      const worst = statuses.length ? worstStatus(statuses) : 'info';

      // vis rebuilds className on every redraw, so these are re-applied rather
      // than toggled. Idempotent either way.
      box.classList.add('cluster-decorated', `cluster-${worst}`);

      // Weight rides on an outer ring, NOT on the box's size: vis measures the
      // box during redraw and positions it with an inline transform, so a box
      // that grows afterwards ends up off-centre until the next redraw. A
      // box-shadow costs no layout, so nothing moves.
      //
      // Log scale — 8 events and 800 are both "a lot", and a linear map would
      // leave the small end invisible and the large end absurd.
      const ring = Math.min(6, Math.round(Math.log2(Math.max(count, 1))));
      box.style.boxShadow = ring > 0 ? `0 0 0 ${ring}px var(--cluster-ring)` : 'none';

      const inner = box.querySelector ? box.querySelector('[title]') : null;
      if (inner && statuses.length) {
        inner.title = `${count} events · worst: ${worst} — click to zoom in`;
      }
    });
  }

  /* ── Overview minimap ─────────────────────────────────────────────────────
     Clustering keeps a dense lane readable but destroys the sense of where you
     are once zoomed in. The minimap holds the whole loaded range still — the
     extent comes from every event, not the filtered set, so it does not move
     underfoot when a filter changes — and shows the current window as a brush
     you can drag.                                                           */
  function fullRange() {
    const ts = allEvents
      .map(e => new Date(e.timestamp).getTime())
      .filter(t => !isNaN(t));
    if (ts.length === 0) return null;

    const start = Math.min(...ts);
    const end   = Math.max(...ts);
    // A single event, or several at one instant, still needs a range to map on.
    return end > start ? { start, end } : { start: start - DAY / 2, end: end + DAY / 2 };
  }

  function renderMinimap() {
    if (!miniEl || !miniBars || typeof miniBars.getBoundingClientRect !== 'function') return;

    miniRange = fullRange();
    if (!miniRange) {
      miniEl.classList.add('hidden');
      return;
    }
    miniEl.classList.remove('hidden');

    // Share the density strip's alignment: both are measured against the
    // timeline's centre panel, so all three x-axes line up.
    const centre = document.querySelector('#timeline-container .vis-panel.vis-center');
    if (!centre || !miniTrack) return;

    const host = miniEl.getBoundingClientRect();
    const rect = centre.getBoundingClientRect();
    if (rect.width < 40) return;

    miniTrack.style.left  = `${rect.left - host.left}px`;
    miniTrack.style.width = `${rect.width}px`;

    const count   = Math.max(24, Math.min(320, Math.round(rect.width / 4)));
    const buckets = computeBuckets(visibleEvents(), miniRange.start, miniRange.end, count);
    const peak    = buckets.reduce((m, b) => Math.max(m, b.total), 0);
    const pct     = 100 / count;

    miniBars.innerHTML = peak === 0 ? '' : buckets.map((b, i) => {
      if (b.total === 0) return '';
      const h = Math.max(12, Math.round((b.total / peak) * 100));
      return `<span class="mini-bar${b.failures ? ' mini-bar-fail' : ''}"
                    style="left:${i * pct}%;width:${pct}%;height:${h}%"></span>`;
    }).join('');

    updateMinimapWindow();
  }

  function updateMinimapWindow() {
    if (!miniWin || !miniRange || !tl) return;

    const span = miniRange.end - miniRange.start;
    if (!(span > 0)) return;

    const w    = tl.getWindow();
    const from = Math.max(0, Math.min(1, (w.start.getTime() - miniRange.start) / span));
    const to   = Math.max(0, Math.min(1, (w.end.getTime()   - miniRange.start) / span));

    miniWin.style.left  = `${from * 100}%`;
    // Always leave something grabbable, however far in the window is zoomed.
    miniWin.style.width = `${Math.max(1.5, (to - from) * 100)}%`;

    if (miniTrack && miniTrack.setAttribute) {
      miniTrack.setAttribute('aria-valuenow', String(Math.round(((from + to) / 2) * 100)));
      miniTrack.setAttribute('aria-valuetext',
        `${formatDateShort(w.start.toISOString())} to ${formatDateShort(w.end.toISOString())} UTC`);
    }
  }

  // Where the window's centre sits in the full range, 0–1.
  function minimapCentreFraction() {
    if (!miniRange || !tl) return 0;
    const full = miniRange.end - miniRange.start;
    if (!(full > 0)) return 0;
    const w = tl.getWindow();
    return ((w.start.getTime() + w.end.getTime()) / 2 - miniRange.start) / full;
  }

  // Centre the current window on a fraction of the full range, keeping its span.
  function panMinimapTo(fraction) {
    if (!miniRange || !tl) return;

    const w      = tl.getWindow();
    const span   = w.end - w.start;
    const full   = miniRange.end - miniRange.start;
    const centre = miniRange.start + Math.max(0, Math.min(1, fraction)) * full;

    tl.setWindow(new Date(centre - span / 2), new Date(centre + span / 2), { animation: false });
    updateMinimapWindow();
  }

  function bindMinimap() {
    if (!miniTrack || !miniTrack.addEventListener) return;

    let dragging = false;

    const fractionAt = clientX => {
      const r = miniTrack.getBoundingClientRect();
      return r.width > 0 ? (clientX - r.left) / r.width : 0;
    };

    miniTrack.addEventListener('pointerdown', e => {
      dragging = true;
      try { miniTrack.setPointerCapture(e.pointerId); } catch { /* not captureable */ }
      panMinimapTo(fractionAt(e.clientX));
      e.preventDefault();
    });

    miniTrack.addEventListener('pointermove', e => {
      if (dragging) panMinimapTo(fractionAt(e.clientX));
    });

    const end = e => {
      if (!dragging) return;
      dragging = false;
      try { miniTrack.releasePointerCapture(e.pointerId); } catch { /* already released */ }
      // The drag suppressed vis's own rangechanged work; catch the strip up.
      renderDensity();
    };
    miniTrack.addEventListener('pointerup', end);
    miniTrack.addEventListener('pointercancel', end);

    // stopPropagation keeps the arrows from also stepping through events via the
    // global handler, matching how the detail-panel resizer behaves.
    miniTrack.addEventListener('keydown', e => {
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
      e.preventDefault();
      e.stopPropagation();
      panMinimapTo(minimapCentreFraction() + (e.key === 'ArrowLeft' ? -0.05 : 0.05));
      renderDensity();
    });
  }

  function init(container, density, overview) {
    items  = new vis.DataSet();
    groups = new vis.DataSet(GROUP_DEF.map(g => ({ id: g.id, order: g.order, content: laneLabel(g, 0) })));
    tl     = new vis.Timeline(container, items, groups, OPTIONS);

    if (density) {
      densityEl = density;
      plotEl    = document.getElementById('density-plot');
      peakEl    = document.getElementById('density-peak');

      // Clicking a bar zooms to that bucket — the strip is the fastest way to
      // get from "something happened around here" to the events themselves.
      if (plotEl && plotEl.addEventListener) {
        plotEl.addEventListener('click', e => {
          const bar = e.target.closest ? e.target.closest('.dens-bar') : null;
          if (!bar) return;
          const b = lastBuckets[Number(bar.dataset.i)];
          if (b) tl.setWindow(new Date(b.start), new Date(b.end), { animation: true });
        });
      }
    }

    if (overview) {
      miniEl    = overview;
      miniTrack = document.getElementById('minimap-track');
      miniBars  = document.getElementById('minimap-bars');
      miniWin   = document.getElementById('minimap-window');
      bindMinimap();
    }

    tl.on('rangechanged', () => {
      applyShading();
      renderDensity();
      updateMinimapWindow();
    });

    // Clusters are rebuilt during redraw; 'changed' is the first point at which
    // their boxes exist in their final form.
    tl.on('changed', decorateClusters);

    if (typeof window !== 'undefined' && window.addEventListener) {
      window.addEventListener('resize', debounce(() => {
        renderDensity();
        renderMinimap();
      }, 120));
    }

    tl.on('select', props => {
      if (props.items.length === 0) return;
      const ev = allEvents.find(e => e.id === props.items[0]);
      if (ev && onSelectCb) onSelectCb(ev);
    });

    // A cluster is not in allEvents, so the select handler above ignores it. Without
    // this, clicking one of the dense clusters that dominate a busy lane did nothing
    // at all — the app looked broken. Zoom in around the click instead.
    tl.on('click', props => {
      if (!props.item || !props.time) return;
      const hit = String(props.item);
      // Background decoration, not something to drill into.
      if (hit.startsWith(SHADE_PREFIX) || hit.startsWith(SESSION_PREFIX)) return;
      if (allEvents.some(e => e.id === props.item)) return;    // a real event
      zoomAround(props.time);
      if (!clusterHintShown) {
        clusterHintShown = true;
        showToast('Grouped events — zooming in. Keep clicking to drill down.', 'info', 3000);
      }
    });
  }

  function zoomAround(time) {
    const w    = tl.getWindow();
    const span = (w.end - w.start) / 4;    // quarter of the current span
    const at   = time.getTime();
    tl.setWindow(new Date(at - span / 2), new Date(at + span / 2), { animation: true });
  }

  // Everything currently passing all three filters, oldest first.
  function visibleEvents() {
    return allEvents
      .filter(e => !statusFilter || statusFilter.includes(e.status))
      .filter(e => !activeCats   || activeCats.includes(e.category))
      .filter(e => !textFilter   || (e._blob && e._blob.includes(textFilter)))
      .slice()
      .sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));
  }

  function applyItems() {
    const visible = visibleEvents();

    // vis.DataSet throws on a duplicate id and would abort the whole load, so guard
    // against a repeated Graph record rather than trusting the feed.
    const seen = new Set();
    const rows = [];
    visible.forEach(ev => {
      if (seen.has(ev.id)) return;
      seen.add(ev.id);
      rows.push({
        id:        ev.id,
        group:     ev.category,
        content:   buildItemContent(ev),
        start:     new Date(ev.timestamp),
        type:      'point',
        className: `event-${ev.status} cat-${ev.category} sev-${computeSeverity(ev)}`,
        title:     buildTooltip(ev),
      });
    });

    // Session bands go in with the points: they are background items in the
    // Sign-Ins lane, so they sit behind the dots rather than displacing them.
    computeSessions(visible).forEach((s, i) => {
      rows.push({
        id:        `${SESSION_PREFIX}${i}`,
        group:     'SignIn',
        start:     new Date(s.start),
        end:       new Date(s.end),
        type:      'background',
        className: `session-band session-${s.status}`,
      });
    });

    // clear() takes the shading with it, so the bands are rebuilt from scratch
    // rather than left as orphaned ids.
    items.clear();
    shadeIds = [];
    shadeSig = '';
    items.add(rows);

    eventById = new Map(visible.map(e => [e.id, e]));

    updateLaneLabels(visible);
    applyShading();
    renderDensity();
    renderMinimap();
    return visible;
  }

  function updateLaneLabels(visible) {
    const shown = {};
    visible.forEach(e => { shown[e.category] = (shown[e.category] ?? 0) + 1; });
    const present = new Set(allEvents.map(e => e.category));

    GROUP_DEF.forEach(g => {
      groups.update({
        id:      g.id,
        content: laneLabel(g, shown[g.id] ?? 0),
        visible: present.has(g.id) && (!activeCats || activeCats.includes(g.id))
      });
    });
  }

  function load(events, onSelect, { preserveWindow = false } = {}) {
    if (!tl) return;

    const previous = preserveWindow ? tl.getWindow() : null;

    allEvents = events;
    allEvents.forEach(e => { e._blob = searchBlob(e); });
    if (onSelect) onSelectCb = onSelect;

    applyItems();

    if (previous) {
      tl.setWindow(previous.start, previous.end, { animation: false });
    } else {
      tl.fit({ animation: { duration: 500, easingFunction: 'easeInOutQuad' } });
    }
  }

  function setStatusFilter(statuses) { if (tl) { statusFilter = statuses; applyItems(); } }
  function setTextFilter(text)       { if (tl) { textFilter = (text ?? '').trim().toLowerCase(); applyItems(); } }
  function filterByCategories(active) { if (tl) { activeCats = active; applyItems(); } }

  function clear() {
    if (items) items.clear();
    allEvents    = [];
    statusFilter = null;
    textFilter   = '';
    activeCats   = null;
    shadeIds     = [];
    shadeSig     = '';
    lastBuckets  = [];
    miniRange    = null;
    eventById    = new Map();
    if (plotEl)   plotEl.innerHTML = '';
    if (peakEl)   peakEl.textContent = '—';
    if (miniBars) miniBars.innerHTML = '';
    if (miniEl && miniEl.classList) miniEl.classList.add('hidden');
  }

  function focus(id, onSelect) {
    if (!tl) return;
    tl.setSelection([id], { focus: true, animation: true });
    const ev = allEvents.find(e => e.id === id);
    if (ev && onSelect) onSelect(ev);
  }

  // Step to the neighbouring visible event. delta -1 = older, +1 = newer.
  function selectOffset(delta, onSelect) {
    if (!tl) return;
    const ordered = visibleEvents();
    if (ordered.length === 0) return;

    const current = tl.getSelection();
    let index;
    if (current.length === 0) {
      index = ordered.length - 1;
    } else {
      const at = ordered.findIndex(e => e.id === current[0]);
      index = at === -1 ? ordered.length - 1
                        : Math.min(ordered.length - 1, Math.max(0, at + delta));
    }
    focus(ordered[index].id, onSelect);
  }

  function fit() { if (tl) tl.fit({ animation: true }); }
  function redraw() {
    if (!tl) return;
    tl.redraw();
    applyShading();
    renderDensity();
    renderMinimap();
  }
  function getEvents() { return allEvents; }

  return {
    init, load, clear, fit, redraw, focus, selectOffset, getEvents,
    setStatusFilter, setTextFilter, filterByCategories, visibleEvents,
    // Exposed for the headless UI checks — pure, no DOM.
    computeBuckets, computeOffHours, computeSessions, computeSeverity, worstStatus
  };
})();
