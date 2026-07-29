/* ── API client ───────────────────────────────────────────────────────── */
const API = {
  async _get(url) {
    const res = await fetch(url, { headers: { 'Accept': 'application/json' } });
    if (!res.ok) {
      const err = await res.json().catch(() => ({ message: res.statusText }));
      throw new Error(err.message ?? `HTTP ${res.status}`);
    }
    return res.json();
  },

  // State-changing calls need POST + the portal header; see Invoke-RequestRouter.ps1.
  async _post(url) {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Accept': 'application/json', 'X-EntraTimeline': '1' }
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({ message: res.statusText }));
      throw new Error(err.message ?? `HTTP ${res.status}`);
    }
    return res.json();
  },

  searchUsers(q) {
    return this._get(`/api/users/search?q=${encodeURIComponent(q)}`);
  },

  getUser(userId) {
    return this._get(`/api/users/${userId}`);
  },

  exportUrl(userId, days, format, nonInteractive = false) {
    let url = `/api/export/${userId}?days=${days}&format=${format}`;
    if (nonInteractive) url += '&nonInteractive=true';
    return url;
  },

  getTimeline(userId, days = 30, { refresh = false, nonInteractive = false, categories = null } = {}) {
    let url = `/api/timeline/${userId}?days=${days}`;
    if (categories && categories.length) url += `&categories=${categories.join(',')}`;
    if (refresh) url += '&refresh=true';
    if (nonInteractive) url += '&nonInteractive=true';
    return this._get(url);
  },

  getCAPolicies() {
    return this._get('/api/ca-policies');
  },

  clearCache(userId = null) {
    const url = userId ? `/api/cache/clear?userId=${encodeURIComponent(userId)}` : '/api/cache/clear';
    return this._post(url);
  },

  getStatus() {
    return this._get('/api/status');
  },

  shutdown() {
    return this._post('/api/shutdown').catch(() => {});
  }
};
