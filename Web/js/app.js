/* ── App entry point ──────────────────────────────────────────────────── */
(function () {
  'use strict';

  const ALL_CATEGORIES = ['SignIn', 'Audit', 'CA', 'Risk', 'Provisioning'];

  /* ── State ────────────────────────────────────────────────────────────*/
  let selectedUser     = null;
  let currentEvents    = [];
  let activeCategories = [...ALL_CATEGORIES];
  let failuresOnly     = false;
  let nonInteractive   = false;
  let textFilter       = '';
  let view             = 'timeline';
  let searchIndex      = -1;      // highlighted row in the user-search dropdown
  let searchUsers      = [];
  let status           = {};      // last /api/status payload (tenant, signed-in user)

  const DETAIL_W_KEY = 'entratimeline.detailWidth';
  const DETAIL_MIN   = 320;
  const DETAIL_MAX   = 900;

  /* ── DOM refs ─────────────────────────────────────────────────────────*/
  const $ = id => document.getElementById(id);

  const searchInput    = $('search-input');
  const searchResults  = $('search-results');
  const daysSelect     = $('days-select');
  const refreshBtn     = $('refresh-btn');
  const failuresToggle = $('failures-toggle');
  const nonIntToggle   = $('noninteractive-toggle');
  const exportCsvBtn   = $('export-csv-btn');
  const exportHtmlBtn  = $('export-html-btn');
  const exportJsonBtn  = $('export-json-btn');
  const clearCacheBtn  = $('clear-cache-btn');
  const shutdownBtn    = $('shutdown-btn');
  const tenantPill     = $('tenant-pill');
  const tenantName     = $('tenant-name');
  const workspace      = $('workspace');
  const emptyState     = $('empty-state');
  const dataSource     = $('data-source');
  const detailClose    = $('detail-close');
  const copyIdBtn      = $('copy-id-btn');
  const statCards      = $('stat-cards');
  const eventFilter    = $('event-filter');
  const filterClear    = $('filter-clear');
  const resetFilters   = $('reset-filters');
  const timelineWrap   = $('timeline-wrap');
  const tableWrap      = $('table-wrap');
  const viewTimeline   = $('view-timeline-btn');
  const viewTable      = $('view-table-btn');
  const shortcutsBtn   = $('shortcuts-btn');
  const shortcutsModal = $('shortcuts-modal');
  const shortcutsClose = $('shortcuts-close');
  const emptyActions   = $('empty-actions');
  const detailResize   = $('detail-resize');
  const printMeta      = $('print-meta');

  const profileAvatar = $('profile-avatar');
  const profileName   = $('profile-name');
  const profileUpn    = $('profile-upn');
  const profileId     = $('profile-id');
  const profileBadges = $('profile-badges');

  /* ── Init ─────────────────────────────────────────────────────────────*/
  function init() {
    Timeline.init($('timeline-container'), $('density-strip'), $('minimap'));
    EventTable.init(tableWrap, ev => DetailPanel.show(ev));
    DetailPanel.init();
    restoreDetailWidth();
    bindEvents();

    // The catch here must cover the REQUEST failing and nothing else. Wrapping the
    // rendering in it too meant any downstream error — a stale utils.js missing a
    // function, say — reported the server as disconnected, which sends you looking
    // in entirely the wrong place.
    API.getStatus().then(s => {
      status = s ?? {};
      updateTenantPill(s);
      if (!s.connected) showToast('Not connected to Microsoft Graph. Run Connect-EntraTimeline in PowerShell.', 'warning', 6000);

      try {
        renderEmptyActions();
      } catch (err) {
        console.error('Empty-state actions failed to render', err);
      }
    }).catch(err => {
      console.error('Status request failed', err);
      updateTenantPill({ connected: false });
      showToast(`Could not reach the local server: ${err.message}`, 'error', 6000);
    });

    restoreFromHash();
  }

  /* ── Empty state ──────────────────────────────────────────────────────────
     "Search for a user" with nothing to click is a dead end on first run. Offer
     the signed-in account and whoever was looked at recently.                */
  function renderEmptyActions() {
    const tenant  = status.tenantId ?? 'unknown';
    const recents = readRecents(tenant).filter(u => u.id !== status.me?.id);
    const chips   = [];

    if (status.me?.id) {
      chips.push(`<button class="empty-chip chip-primary" data-id="${esc(status.me.id)}">
          <i class="bi bi-person-badge"></i>
          <span>${esc(status.me.displayName || status.me.userPrincipalName)}</span>
          <span class="chip-tag">you</span>
        </button>`);
    }

    recents.forEach(u => {
      chips.push(`<button class="empty-chip" data-id="${esc(u.id)}">
          <i class="bi bi-clock-history"></i>
          <span>${esc(u.displayName || u.userPrincipalName)}</span>
        </button>`);
    });

    if (chips.length === 0) { emptyActions.innerHTML = ''; return; }

    emptyActions.innerHTML =
      `<div class="empty-actions-label">Jump straight to</div>
       <div class="empty-chips">${chips.join('')}</div>`;

    emptyActions.querySelectorAll('.empty-chip').forEach(btn => {
      btn.addEventListener('click', async () => {
        try {
          const r = await API.getUser(btn.dataset.id);
          if (r.user) onUserSelected(r.user);
        } catch {
          showToast('That user could not be loaded.', 'error');
        }
      });
    });
  }

  /* ── Detail panel resize ──────────────────────────────────────────────── */
  function setDetailWidth(px) {
    const w = Math.min(DETAIL_MAX, Math.max(DETAIL_MIN, Math.round(px)));
    document.documentElement.style.setProperty('--detail-w', `${w}px`);
    return w;
  }

  function restoreDetailWidth() {
    try {
      const saved = parseInt(window.localStorage.getItem(DETAIL_W_KEY), 10);
      if (saved) setDetailWidth(saved);
    } catch { /* storage unavailable */ }
  }

  function persistDetailWidth(w) {
    try { window.localStorage.setItem(DETAIL_W_KEY, String(w)); } catch { /* ignore */ }
  }

  function bindDetailResize() {
    let dragging = false;

    detailResize.addEventListener('pointerdown', e => {
      dragging = true;
      detailResize.setPointerCapture(e.pointerId);
      document.body.classList.add('resizing');
      e.preventDefault();
    });

    detailResize.addEventListener('pointermove', e => {
      if (!dragging) return;
      setDetailWidth(window.innerWidth - e.clientX);
    });

    const end = e => {
      if (!dragging) return;
      dragging = false;
      try { detailResize.releasePointerCapture(e.pointerId); } catch { /* already released */ }
      document.body.classList.remove('resizing');
      persistDetailWidth(parseInt(getComputedStyle(document.documentElement).getPropertyValue('--detail-w'), 10));
      Timeline.redraw();   // vis measured itself against the old width
    };
    detailResize.addEventListener('pointerup', end);
    detailResize.addEventListener('pointercancel', end);

    // Keyboard resize. stopPropagation keeps the arrows from also stepping through
    // events via the global handler.
    detailResize.addEventListener('keydown', e => {
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
      e.preventDefault();
      e.stopPropagation();
      const current = parseInt(getComputedStyle(document.documentElement).getPropertyValue('--detail-w'), 10);
      const next = setDetailWidth(current + (e.key === 'ArrowLeft' ? 24 : -24));
      persistDetailWidth(next);
      Timeline.redraw();
    });
  }

  /* ── Print ────────────────────────────────────────────────────────────────
     Printing renders the CURRENT filtered set as a table — that is the thing
     on screen, and a canvas timeline does not survive a printer. The HTML
     export remains the route to a standalone saved report.                  */
  function bindPrint() {
    window.addEventListener('beforeprint', () => {
      if (selectedUser) EventTable.render();
      const days = daysSelect.value;
      const bits = [];
      if (selectedUser) {
        bits.push(`${selectedUser.displayName ?? ''} <${selectedUser.userPrincipalName ?? ''}>`);
      }
      bits.push(`Last ${days} day${days === '1' ? '' : 's'}`);
      if (status.tenantDomain) bits.push(status.tenantDomain);
      if (nonInteractive) bits.push('including non-interactive sign-ins');
      bits.push(`Generated ${formatDate(new Date().toISOString())} UTC`);
      printMeta.textContent = bits.join(' · ');
    });
  }

  /* ── Deep links (#/user/<id>?days=N&ni=1) ─────────────────────────────*/
  function parseHash() {
    const m = location.hash.match(/^#\/user\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:\?(.*))?$/i);
    if (!m) return null;
    const q = new URLSearchParams(m[2] ?? '');
    return {
      id:   m[1],
      days: q.has('days') ? parseInt(q.get('days'), 10) : null,
      ni:   q.get('ni') === '1'
    };
  }

  function updateHash() {
    if (!selectedUser) return;
    let h = `#/user/${selectedUser.id}?days=${daysSelect.value}`;
    if (nonInteractive) h += '&ni=1';
    if (location.hash !== h) history.replaceState(null, '', h);
  }

  async function restoreFromHash() {
    const p = parseHash();
    if (!p) return;

    if (p.days) {
      if ([...daysSelect.options].some(o => o.value === String(p.days))) {
        daysSelect.value = String(p.days);
      } else {
        showToast(`This link asks for ${p.days} days; Entra only retains 30. Showing 30.`, 'warning', 6000);
        daysSelect.value = '30';
      }
    }

    nonInteractive = p.ni;
    nonIntToggle.classList.toggle('active', nonInteractive);
    nonIntToggle.setAttribute('aria-pressed', String(nonInteractive));

    try {
      const r = await API.getUser(p.id);
      if (r.user) onUserSelected(r.user);
    } catch {
      showToast('Could not restore the user from this link.', 'warning');
    }
  }

  /* ── Tenant pill ──────────────────────────────────────────────────────*/
  function updateTenantPill(s) {
    if (s && s.connected) {
      tenantName.textContent = s.tenantDomain || s.account || 'Connected';
      tenantPill.title = `${s.account ?? ''}${s.tenantId ? ` · ${s.tenantId}` : ''}`.trim();
      tenantPill.classList.remove('disconnected');
    } else {
      tenantName.textContent = 'Not connected';
      tenantPill.classList.add('disconnected');
    }
  }

  /* ── Event binding ────────────────────────────────────────────────────*/
  function bindEvents() {
    searchInput.addEventListener('input', debounce(onSearchInput, 280));
    searchInput.addEventListener('keydown', onSearchKeydown);
    searchInput.addEventListener('focus', () => searchInput.select());

    document.addEventListener('click', e => {
      if (!e.target.closest('.search-wrap')) closeSearch();
    });

    refreshBtn.addEventListener('click', () => { if (selectedUser) loadTimeline(true); });
    daysSelect.addEventListener('change', () => {
      if (selectedUser) { updateHash(); loadTimeline(false); }
    });

    failuresToggle.addEventListener('click', toggleFailures);

    nonIntToggle.addEventListener('click', () => {
      nonInteractive = !nonInteractive;
      nonIntToggle.classList.toggle('active', nonInteractive);
      nonIntToggle.setAttribute('aria-pressed', String(nonInteractive));
      updateHash();
      if (selectedUser) loadTimeline(false);
    });

    /* Free-text filter over the loaded set */
    eventFilter.addEventListener('input', debounce(() => {
      textFilter = eventFilter.value;
      filterClear.classList.toggle('hidden', textFilter === '');
      Timeline.setTextFilter(textFilter);
      if (view === 'table') EventTable.render();
      updateFilterState();
    }, 180));

    filterClear.addEventListener('click', () => {
      eventFilter.value = '';
      textFilter = '';
      filterClear.classList.add('hidden');
      Timeline.setTextFilter('');
      if (view === 'table') EventTable.render();
      updateFilterState();
      eventFilter.focus();
    });

    resetFilters.addEventListener('click', clearAllFilters);

    viewTimeline.addEventListener('click', () => setView('timeline'));
    viewTable.addEventListener('click', () => setView('table'));

    exportCsvBtn.addEventListener('click', () => startExport('csv'));
    exportHtmlBtn.addEventListener('click', () => startExport('html'));
    exportJsonBtn.addEventListener('click', () => startExport('json'));

    window.addEventListener('hashchange', () => {
      const p = parseHash();
      if (p && p.id !== selectedUser?.id) restoreFromHash();
    });

    clearCacheBtn.addEventListener('click', async () => {
      if (!selectedUser) { showToast('Select a user first.', 'info'); return; }
      if (!confirm('Clear the cached activity for this user and reload from Graph?')) return;
      try {
        const r = await API.clearCache(selectedUser.id);
        // Recent users are tenant data too — clearing the cache clears them.
        clearRecents();
        renderEmptyActions();
        showToast(`Cache cleared (${r.cleared ?? 0} entries)`, 'info');
        loadTimeline(true);
      } catch (err) {
        showToast(`Clear cache failed: ${err.message}`, 'error');
      }
    });

    shutdownBtn.addEventListener('click', () => {
      if (confirm('Stop the EntraTimeline server?')) {
        API.shutdown();
        showToast('Server stopping…', 'info');
        setTimeout(() => { shutdownBtn.disabled = true; }, 1000);
      }
    });

    copyIdBtn.addEventListener('click', async () => {
      if (!selectedUser) return;
      try {
        await navigator.clipboard.writeText(selectedUser.id);
        copyIdBtn.innerHTML = '<i class="bi bi-clipboard-check"></i>';
        copyIdBtn.classList.add('copied');
        setTimeout(() => {
          copyIdBtn.innerHTML = '<i class="bi bi-clipboard"></i>';
          copyIdBtn.classList.remove('copied');
        }, 1500);
      } catch {
        showToast('Copy failed — clipboard unavailable.', 'error');
      }
    });

    /* Stat cards: click solos a category, shift-click adds/removes it. With five
       lanes, isolating one used to take four clicks. */
    statCards.addEventListener('click', e => {
      const card = e.target.closest('.stat-card');
      if (!card || card.classList.contains('no-data')) return;
      const cat = card.dataset.cat;

      if (e.shiftKey) {
        if (activeCategories.includes(cat)) {
          if (activeCategories.length === 1) return;   // never filter everything out
          activeCategories = activeCategories.filter(c => c !== cat);
        } else {
          activeCategories.push(cat);
        }
      } else {
        const isSolo = activeCategories.length === 1 && activeCategories[0] === cat;
        activeCategories = isSolo ? [...ALL_CATEGORIES] : [cat];
      }

      applyCategoryFilter();
    });

    detailClose.addEventListener('click', () => DetailPanel.hide());

    shortcutsBtn.addEventListener('click', () => toggleShortcuts(true));
    shortcutsClose.addEventListener('click', () => toggleShortcuts(false));
    shortcutsModal.addEventListener('click', e => {
      if (e.target === shortcutsModal) toggleShortcuts(false);
    });

    bindDetailResize();
    bindPrint();

    document.addEventListener('keydown', onGlobalKeydown);
  }

  /* ── Keyboard ─────────────────────────────────────────────────────────*/
  function isTyping() {
    const el = document.activeElement;
    return el && ['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName);
  }

  function onGlobalKeydown(e) {
    if (e.key === 'Escape') {
      if (!shortcutsModal.classList.contains('hidden')) { toggleShortcuts(false); return; }
      DetailPanel.hide();
      return;
    }

    // Shortcuts that need the search box do their own focus handling.
    if (e.key === '/' && !isTyping()) {
      e.preventDefault();
      searchInput.focus();
      return;
    }
    if (e.key === '?' && !isTyping()) { e.preventDefault(); toggleShortcuts(true); return; }

    if (isTyping() || e.ctrlKey || e.metaKey || e.altKey) return;

    switch (e.key) {
      case 'e':
        e.preventDefault();
        eventFilter.focus();
        break;
      case 'f':
        if (selectedUser) { e.preventDefault(); toggleFailures(); }
        break;
      case 't':
        if (selectedUser) { e.preventDefault(); setView(view === 'timeline' ? 'table' : 'timeline'); }
        break;
      case 'r':
        if (selectedUser) { e.preventDefault(); loadTimeline(true); }
        break;
      case 'ArrowLeft':
      case 'ArrowRight':
        if (selectedUser && view === 'timeline') {
          e.preventDefault();
          Timeline.selectOffset(e.key === 'ArrowRight' ? 1 : -1, ev => DetailPanel.show(ev));
        }
        break;
    }
  }

  function toggleShortcuts(open) {
    shortcutsModal.classList.toggle('hidden', !open);
    if (open) shortcutsClose.focus();
  }

  /* ── Filters ──────────────────────────────────────────────────────────*/
  function toggleFailures() {
    failuresOnly = !failuresOnly;
    failuresToggle.classList.toggle('active', failuresOnly);
    failuresToggle.setAttribute('aria-pressed', String(failuresOnly));
    Timeline.setStatusFilter(failuresOnly ? ['failure'] : null);
    if (view === 'table') EventTable.render();
    updateFilterState();
  }

  function applyCategoryFilter() {
    statCards.querySelectorAll('.stat-card').forEach(c => {
      const on = activeCategories.includes(c.dataset.cat);
      c.classList.toggle('active', on && !c.classList.contains('no-data'));
      c.classList.toggle('inactive', !on && !c.classList.contains('no-data'));
      c.setAttribute('aria-pressed', String(on));
    });
    Timeline.filterByCategories(activeCategories);
    if (view === 'table') EventTable.render();
    updateFilterState();
  }

  function clearAllFilters() {
    activeCategories = [...ALL_CATEGORIES];
    failuresOnly = false;
    textFilter = '';
    eventFilter.value = '';
    filterClear.classList.add('hidden');
    failuresToggle.classList.remove('active');
    failuresToggle.setAttribute('aria-pressed', 'false');
    Timeline.setStatusFilter(null);
    Timeline.setTextFilter('');
    applyCategoryFilter();
  }

  function updateFilterState() {
    const filtered = failuresOnly || textFilter !== '' ||
                     activeCategories.length !== ALL_CATEGORIES.length;
    resetFilters.classList.toggle('hidden', !filtered);
  }

  /* ── View switch ──────────────────────────────────────────────────────*/
  function setView(next) {
    view = next;
    const isTable = view === 'table';

    timelineWrap.classList.toggle('hidden', isTable);
    tableWrap.classList.toggle('hidden', !isTable);

    viewTimeline.classList.toggle('active', !isTable);
    viewTable.classList.toggle('active', isTable);
    viewTimeline.setAttribute('aria-pressed', String(!isTable));
    viewTable.setAttribute('aria-pressed', String(isTable));

    if (isTable) EventTable.render();
    else Timeline.redraw();   // vis mis-measures while hidden
  }

  /* ── User search ──────────────────────────────────────────────────────*/
  async function onSearchInput() {
    const q = searchInput.value.trim();
    if (q.length < 2) { closeSearch(); return; }
    try {
      const res = await API.searchUsers(q);
      renderSearchResults(res.users ?? []);
    } catch (err) {
      showToast(`Search error: ${err.message}`, 'error');
    }
  }

  function onSearchKeydown(e) {
    const open = !searchResults.classList.contains('hidden');

    if (e.key === 'Escape') { closeSearch(); searchInput.blur(); return; }
    if (!open || searchUsers.length === 0) return;

    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      const delta = e.key === 'ArrowDown' ? 1 : -1;
      searchIndex = (searchIndex + delta + searchUsers.length) % searchUsers.length;
      highlightSearch();
    } else if (e.key === 'Enter') {
      e.preventDefault();
      const pick = searchUsers[searchIndex >= 0 ? searchIndex : 0];
      if (pick) onUserSelected(pick);
    }
  }

  function highlightSearch() {
    const rows = [...searchResults.querySelectorAll('.search-result-item')];
    rows.forEach((r, i) => {
      const on = i === searchIndex;
      r.classList.toggle('highlighted', on);
      r.setAttribute('aria-selected', String(on));
      if (on) r.scrollIntoView({ block: 'nearest' });
    });
  }

  function renderSearchResults(users) {
    searchUsers = users;
    searchIndex = users.length ? 0 : -1;
    searchResults.innerHTML = '';

    if (!users.length) {
      searchResults.innerHTML = '<div class="search-empty">No users found</div>';
    } else {
      users.forEach((u, i) => {
        const item = document.createElement('div');
        item.className = 'search-result-item' + (i === 0 ? ' highlighted' : '');
        item.setAttribute('role', 'option');
        item.setAttribute('aria-selected', String(i === 0));
        item.innerHTML = `
          <div>
            <div class="user-name">${esc(u.displayName)}</div>
            <div class="user-upn">${esc(u.userPrincipalName)}</div>
            ${u.jobTitle ? `<div class="user-meta">${esc(u.jobTitle)}${u.department ? ` · ${esc(u.department)}` : ''}</div>` : ''}
          </div>
          ${!u.accountEnabled ? '<span class="disabled-badge">Disabled</span>' : ''}`;
        item.addEventListener('click', () => onUserSelected(u));
        item.addEventListener('mouseenter', () => { searchIndex = i; highlightSearch(); });
        searchResults.appendChild(item);
      });
    }
    searchResults.classList.remove('hidden');
    searchInput.setAttribute('aria-expanded', 'true');
  }

  function closeSearch() {
    searchResults.classList.add('hidden');
    searchResults.innerHTML = '';
    searchInput.setAttribute('aria-expanded', 'false');
    searchUsers = [];
    searchIndex = -1;
  }

  /* ── Export ───────────────────────────────────────────────────────────*/
  function startExport(format) {
    if (!selectedUser) { showToast('Select a user first.', 'info'); return; }
    const days = parseInt(daysSelect.value, 10) || 30;
    const a = document.createElement('a');
    a.href = API.exportUrl(selectedUser.id, days, format, nonInteractive);
    a.download = '';
    document.body.appendChild(a);
    a.click();
    a.remove();
    showToast(`Exporting ${format.toUpperCase()} — also saved to ${status.outputPath ?? 'Output/AuditLogs'}.`, 'info');
  }

  /* ── User selected ────────────────────────────────────────────────────*/
  function onUserSelected(user) {
    selectedUser = user;
    closeSearch();
    searchInput.value = `${user.displayName} (${user.userPrincipalName})`;
    searchInput.blur();

    profileAvatar.textContent = initials(user.displayName);
    profileName.textContent   = user.displayName ?? '—';
    profileUpn.textContent    = user.userPrincipalName ?? '—';
    profileId.textContent     = user.id ?? '—';

    const badges = [];
    if (user.jobTitle) badges.push(`<span class="status-badge badge-info">${esc(user.jobTitle)}</span>`);
    if (!user.accountEnabled) badges.push('<span class="status-badge badge-failure">Account Disabled</span>');
    profileBadges.innerHTML = badges.join('');

    workspace.classList.remove('hidden');
    emptyState.classList.add('hidden');

    // Retrigger the staggered reveal on every selection, not just the first —
    // force a reflow so removing+re-adding the class restarts the animation.
    workspace.classList.remove('workspace-reveal');
    void workspace.offsetWidth;
    workspace.classList.add('workspace-reveal');

    pushRecent(status.tenantId ?? 'unknown', user);
    renderEmptyActions();

    DetailPanel.hide();
    updateHash();
    loadTimeline(false);
  }

  /* ── Load timeline ────────────────────────────────────────────────────*/
  async function loadTimeline(forceRefresh) {
    if (!selectedUser) return;
    const days = parseInt(daysSelect.value, 10) || 30;

    // A refresh of the same view keeps the operator's zoom; a new user or range
    // does not, because the old window would be meaningless.
    const preserveWindow = forceRefresh && currentEvents.length > 0;

    // Skeleton shimmer only when there's nothing on screen yet to protect — a
    // refresh of an already-loaded user stays fully visible throughout (see the
    // .loading-inline design note in styles.css).
    const showSkeleton = currentEvents.length === 0;
    if (showSkeleton) {
      statCards.classList.add('skeleton-loading');
      timelineWrap.classList.add('skeleton-loading');
      tableWrap.classList.add('skeleton-loading');
    }

    hideBanner();
    showLoading(nonInteractive
      ? 'Fetching activity including non-interactive sign-ins…'
      : 'Fetching activity from Microsoft Graph…');

    try {
      const res = await API.getTimeline(selectedUser.id, days, {
        refresh: forceRefresh,
        nonInteractive
      });
      currentEvents = res.events ?? [];

      clearAllFilters();
      updateStatCards(currentEvents);
      updateDataSource(res);

      // Incomplete or truncated collections stay on screen as a banner rather than
      // as toasts that vanish before they are read. Collected into one banner so an
      // empty result and a collector warning do not overwrite each other.
      const notes = [...(res.warnings ?? [])];

      if (currentEvents.length === 0) {
        Timeline.clear();
        EventTable.clear();
        notes.unshift('No events found for this user in the selected period.');
      } else {
        Timeline.load(currentEvents, ev => DetailPanel.show(ev), { preserveWindow });
        if (view === 'table') EventTable.render();
      }

      if (notes.length) showBanner(notes, res.complete === false ? 'error' : 'warning');
    } catch (err) {
      showBanner(`Failed to load timeline: ${err.message}`, 'error');
    } finally {
      hideLoading();
      statCards.classList.remove('skeleton-loading');
      timelineWrap.classList.remove('skeleton-loading');
      tableWrap.classList.remove('skeleton-loading');
    }
  }

  /* ── Stat cards ───────────────────────────────────────────────────────*/
  function updateStatCards(events) {
    const counts = {};
    events.forEach(e => { counts[e.category] = (counts[e.category] ?? 0) + 1; });

    statCards.querySelectorAll('.stat-card').forEach(card => {
      const cat = card.dataset.cat;
      const n   = counts[cat] ?? 0;
      card.querySelector('[data-count]').textContent = n;
      const hasData = n > 0;
      card.classList.toggle('no-data', !hasData);
      card.classList.toggle('active',   hasData && activeCategories.includes(cat));
      card.classList.toggle('inactive', hasData && !activeCategories.includes(cat));
      card.setAttribute('aria-pressed', String(activeCategories.includes(cat)));
      card.setAttribute('aria-label', `${cat}: ${n} events`);
    });
  }

  /* ── Data-source caption ──────────────────────────────────────────────*/
  function updateDataSource(res) {
    const range = dateRangeLabel(res.events ?? []);
    const parts = [];

    parts.push(res.cached
      ? '<i class="bi bi-database-check" style="color:var(--success)"></i> Cached'
      : '<i class="bi bi-cloud-download" style="color:var(--accent)"></i> Live');

    if (range) parts.push(esc(range));
    if (res.truncated) {
      parts.push(`<span style="color:var(--warning)">showing ${res.count} of ${res.totalCount}</span>`);
    }
    if (res.complete === false) {
      parts.push('<span style="color:var(--error)"><i class="bi bi-exclamation-triangle"></i> partial</span>');
    }
    if (res.retrieved) parts.push(`loaded ${esc(formatTime(res.retrieved))}`);

    dataSource.innerHTML = parts.join(' · ');
    // The caption ellipsizes when the row is tight, so the full text has to
    // stay reachable on hover.
    dataSource.title = dataSource.textContent;
  }

  /* ── Helpers ──────────────────────────────────────────────────────────*/
  function initials(name) {
    if (!name) return '?';
    const parts = name.trim().split(/\s+/).filter(Boolean);
    if (parts.length === 0) return '?';
    if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
    return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
  }

  /* ── Boot ─────────────────────────────────────────────────────────────*/
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
