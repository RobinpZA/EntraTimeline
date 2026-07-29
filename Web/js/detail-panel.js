/* ── Detail panel renderer ────────────────────────────────────────────── */
const DetailPanel = (() => {

  let currentEvent = null;
  let activeTab    = 'details';

  // A sign-in only records id / displayName / result / enforced controls for each policy
  // it evaluated. The tenant's full definitions come from /api/ca-policies, which lets the
  // panel show whether a policy is actually enabled or merely report-only — the difference
  // between "this blocked them" and "this would have blocked them".
  const caPolicyIndex = new Map();

  function init() {
    document.querySelectorAll('.detail-tab').forEach(tab => {
      tab.addEventListener('click', () => switchTab(tab.dataset.tab));
    });

    // Optional enrichment: the panel renders fine without it.
    API.getCAPolicies()
      .then(r => (r.policies ?? []).forEach(p => { if (p.id) caPolicyIndex.set(p.id, p); }))
      .catch(() => {});
  }

  function show(ev) {
    currentEvent = ev;
    const panel = document.getElementById('detail-panel');
    const title = document.getElementById('detail-title');

    title.innerHTML = `<i class="bi ${esc(ev.icon)}" style="color:${esc(ev.color)}"></i> ${esc(ev.title)}`;
    panel.classList.remove('hidden');

    // Show how many related events exist before the tab is opened — otherwise the
    // only way to find out there are none is to go and look.
    const badge = document.getElementById('related-count');
    const n     = relatedEvents(ev).length;
    badge.textContent = n;
    badge.classList.toggle('hidden', n === 0);

    switchTab('details');
  }

  function hide() {
    document.getElementById('detail-panel').classList.add('hidden');
    currentEvent = null;
  }

  function switchTab(tab) {
    activeTab = tab;
    document.querySelectorAll('.detail-tab').forEach(t =>
      t.classList.toggle('active', t.dataset.tab === tab));
    renderBody();
  }

  function renderBody() {
    const body = document.getElementById('detail-body');
    if (!currentEvent) { body.innerHTML = ''; return; }

    if (activeTab === 'raw')     { renderRaw(body, currentEvent);     return; }
    if (activeTab === 'related') { renderRelated(body, currentEvent); return; }

    switch (currentEvent.category) {
      case 'SignIn':  body.innerHTML = renderSignIn(currentEvent);  break;
      case 'Audit':   body.innerHTML = renderAudit(currentEvent);   break;
      case 'Risk':    body.innerHTML = renderRisk(currentEvent);    break;
      case 'CA':      body.innerHTML = renderCA(currentEvent);      break;
      default:        body.innerHTML = renderGeneric(currentEvent); break;
    }
  }

  /* ── Shared row builders ────────────────────────────────────────────── */
  // Escaped value (default — safe for arbitrary data)
  function row(label, value) {
    return `<div class="detail-row">
      <span class="detail-row-label">${esc(label)}</span>
      <span class="detail-row-value">${displayVal(value)}</span>
    </div>`;
  }

  // Trusted HTML value (status badges etc.) — NOT escaped
  function rowRaw(label, htmlValue) {
    return `<div class="detail-row">
      <span class="detail-row-label">${esc(label)}</span>
      <span class="detail-row-value">${htmlValue}</span>
    </div>`;
  }

  function section(title, content) {
    return `<div class="detail-section">
      <div class="detail-section-title">${esc(title)}</div>
      ${content}
    </div>`;
  }

  /* ── Sign-In ────────────────────────────────────────────────────────── */
  function renderSignIn(ev) {
    const d = ev.detail ?? {};
    const loc = d.location ?? {};
    const dev = d.device ?? {};

    const basicRows = [
      row('Application',   d.app),
      row('Time (UTC)',    formatDate(ev.timestamp)),
      rowRaw('Status',     statusBadge(ev.status, d.failureReason || ev.status)),
      row('Interactive',   d.isInteractive),
      row('IP Address',    d.ipAddress),
      row('Location',      [loc.city, loc.state, loc.countryOrRegion].filter(Boolean).join(', ')),
      row('Client App',    d.clientAppUsed),
      row('Browser',       dev.browser),
      row('OS',            dev.operatingSystem),
      row('Device',        dev.displayName),
      row('Compliant',     dev.isCompliant),
      row('Managed',       dev.isManaged),
      row('Risk Level',    d.riskLevelDuringSignIn),
      row('Risk State',    d.riskState),
      row('MFA Method',    d.mfaDetail?.authMethod),
      row('Resource',      d.resourceDisplayName),
      row('Correlation',   d.correlationId),
    ].join('');

    let html = section('Sign-In Details', basicRows);

    // CA policies applied during this sign-in
    const caPolicies = d.appliedConditionalAccessPolicies ?? [];
    if (caPolicies.length > 0) {
      html += section('Conditional Access Policies', `<div class="ca-policy-list">${caPolicyItems(caPolicies)}</div>`);
    }

    return html;
  }

  /* ── Audit ──────────────────────────────────────────────────────────── */
  function renderAudit(ev) {
    const d = ev.detail ?? {};
    const init = d.initiatedBy ?? {};
    const initiatorName = d.initiatorName ?? init?.user?.displayName ?? init?.app?.displayName ?? 'System';

    const basicRows = [
      row('Activity',      d.activity),
      row('Time (UTC)',    formatDate(ev.timestamp)),
      row('Category',      d.category),
      rowRaw('Result',     statusBadge(ev.status, d.result)),
      row('Result Reason', d.resultReason),
      row('Service',       d.loggedByService),
      row('Initiated By',  initiatorName),
      row('Correlation',   d.correlationId),
    ].join('');

    let html = section('Directory Change', basicRows);

    // Modified properties table
    const props = d.modifiedProperties ?? [];
    if (props.length > 0) {
      const rows = props.map(p => `
        <tr>
          <td>${esc(p.property ?? '?')}</td>
          <td class="prop-old">${esc(p.oldValue ?? '—')}</td>
          <td class="prop-new">${esc(p.newValue ?? '—')}</td>
        </tr>`).join('');
      html += section('Modified Properties', `
        <table class="modified-props-table">
          <thead><tr><th>Property</th><th>Old Value</th><th>New Value</th></tr></thead>
          <tbody>${rows}</tbody>
        </table>`);
    }

    // Target resources
    const targets = d.targetResources ?? [];
    if (targets.length > 0) {
      const targetRows = targets.map(t =>
        row(t.type ?? 'Object', `${t.displayName ?? ''} (${t.id ?? ''})`)).join('');
      html += section('Target Resources', targetRows);
    }

    return html;
  }

  /* ── Risk ───────────────────────────────────────────────────────────── */
  function renderRisk(ev) {
    const d   = ev.detail ?? {};
    const loc = d.location ?? {};

    const rows = [
      row('Risk Type',     d.riskEventType),
      rowRaw('Risk Level', statusBadge(ev.status, d.riskLevel)),
      row('Risk State',    d.riskState),
      row('Detection',     d.detectionTimingType),
      row('Time (UTC)',    formatDate(ev.timestamp)),
      row('IP Address',    d.ipAddress),
      row('Location',      [loc.city, loc.state, loc.countryOrRegion].filter(Boolean).join(', ')),
      row('User',          d.userDisplayName),
      row('UPN',           d.userPrincipalName),
      row('Correlation',   d.correlationId),
      row('Request ID',    d.requestId),
    ].join('');

    return section('Risk Detection', rows);
  }

  /* ── CA summary event (one per sign-in) ────────────────────────────── */
  function renderCA(ev) {
    const d = ev.detail ?? {};

    const headerRows = [
      row('Application',    d.signInApp),
      row('Time (UTC)',     formatDate(ev.timestamp)),
      rowRaw('CA Status',   statusBadge(ev.status, d.conditionalAccessStatus)),
      row('Parent Sign-In', d.parentSignInId),
    ].join('');

    let html = section('Conditional Access Summary', headerRows);

    const policies = d.policies ?? [];
    if (policies.length > 0) {
      html += section('Policies Evaluated', `<div class="ca-policy-list">${caPolicyItems(policies)}</div>`);
    }

    return html;
  }

  /* ── Shared: CA policy item list ────────────────────────────────────── */
  function caPolicyItems(policies) {
    return policies.map(p => {
      const result = (p.result ?? '').toLowerCase();
      const grants = Array.isArray(p.enforcedGrantControls)   ? p.enforcedGrantControls.join(', ')  : (p.enforcedGrantControls ?? '');
      const sess   = Array.isArray(p.enforcedSessionControls) ? p.enforcedSessionControls.join(', ') : (p.enforcedSessionControls ?? '');

      const full  = caPolicyIndex.get(p.id);
      const state = full?.state ?? '';
      const stateBadge = state
        ? `<span class="ca-state ca-state-${esc(state)}">${esc(stateLabel(state))}</span>`
        : '';

      return `<div class="ca-policy-item result-${esc(result)}">
        <div class="ca-name">${esc(p.displayName ?? p.id)}${stateBadge}</div>
        <div class="ca-meta">
          Result: <b>${esc(p.result ?? '—')}</b>
          ${grants ? `· Grant: ${esc(grants)}` : ''}
          ${sess   ? `· Session: ${esc(sess)}`  : ''}
        </div>
      </div>`;
    }).join('');
  }

  function stateLabel(state) {
    return { enabled: 'Enabled',
             disabled: 'Disabled',
             enabledForReportingButNotEnforced: 'Report-only' }[state] ?? state;
  }

  /* ── Generic fallback ───────────────────────────────────────────────── */
  function renderGeneric(ev) {
    const rows = [
      row('Category',    ev.category),
      row('Subcategory', ev.subcategory),
      row('Time (UTC)',  formatDate(ev.timestamp)),
      rowRaw('Status',   statusBadge(ev.status)),
      row('Summary',     ev.summary),
    ].join('');
    return section('Event Details', rows);
  }

  /* ── Raw Data tab ───────────────────────────────────────────────────── */
  function renderRaw(body, ev) {
    // _blob is a client-side search index added by Timeline; it is not event data.
    const { _blob, ...clean } = ev;
    const json = JSON.stringify(clean, null, 2);

    body.innerHTML = section('Raw Event JSON', `
      <button class="btn btn-ghost copy-json-btn" type="button">
        <i class="bi bi-clipboard"></i> Copy JSON
      </button>
      <pre class="raw-json">${esc(json)}</pre>`);

    // Pasting an event into a ticket is a core investigation step; select-and-drag
    // inside a scroll box is not a reasonable way to do it.
    const btn = body.querySelector('.copy-json-btn');
    btn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(json);
        btn.innerHTML = '<i class="bi bi-clipboard-check"></i> Copied';
        setTimeout(() => { btn.innerHTML = '<i class="bi bi-clipboard"></i> Copy JSON'; }, 1500);
      } catch {
        showToast('Copy failed — clipboard unavailable.', 'error');
      }
    });
  }

  /* ── Related tab ────────────────────────────────────────────────────── */
  function relatedEvents(ev) {
    const all = (typeof Timeline !== 'undefined' && Timeline.getEvents) ? Timeline.getEvents() : [];
    const corr = ev.detail?.correlationId;
    return all.filter(e => {
      if (e.id === ev.id) return false;
      if (e.parentId && e.parentId === ev.id) return true;        // children of this event
      if (ev.parentId && e.id === ev.parentId) return true;       // this event's parent
      if (ev.parentId && e.parentId === ev.parentId) return true; // siblings
      if (corr && e.detail?.correlationId === corr) return true;  // same correlation id
      return false;
    });
  }

  function renderRelated(body, ev) {
    const related = relatedEvents(ev);
    if (related.length === 0) {
      body.innerHTML = `<div class="detail-placeholder">No related events found.<br><span style="font-size:11px">Linked by correlation ID or parent sign-in.</span></div>`;
      return;
    }
    const items = related.map(e => `
      <div class="related-item" data-id="${esc(e.id)}">
        <i class="bi ${esc(e.icon)} related-icon" style="color:${esc(e.color)}"></i>
        <div class="related-text">
          <div class="related-title">${esc(e.title)}</div>
          <div class="related-time">${esc(formatDateShort(e.timestamp))} · ${esc(e.category)}</div>
        </div>
      </div>`).join('');
    body.innerHTML = section(`Related Events (${related.length})`, `<div class="related-list">${items}</div>`);

    body.querySelectorAll('.related-item').forEach(el => {
      el.addEventListener('click', () => {
        const id = el.dataset.id;
        if (typeof Timeline !== 'undefined' && Timeline.focus) {
          Timeline.focus(id, e => show(e));
        }
      });
    });
  }

  return { init, show, hide };
})();
