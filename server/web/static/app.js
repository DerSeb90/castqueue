/* CastQueue web UI – management only (subscriptions, queue, progress); playback happens in the apps. */
(() => {
  'use strict';

  const $ = (sel, root = document) => root.querySelector(sel);
  const el = (tag, attrs = {}, ...children) => {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'class') n.className = v;
      else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
      else if (v !== undefined && v !== null) n.setAttribute(k, v);
    }
    for (const c of children.flat()) if (c !== null && c !== undefined) n.append(c.nodeType ? c : document.createTextNode(String(c)));
    return n;
  };
  const fmtTime = (ms) => {
    if (!ms || ms < 0) return '0:00';
    const s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(sec).padStart(2, '0');
  };
  const fmtDate = (iso) => {
    if (!iso) return '';
    const d = new Date(iso), now = new Date();
    const diff = (now - d) / 86400000;
    if (diff < 1 && d.getDate() === now.getDate()) return 'Heute';
    if (diff < 2) return 'Gestern';
    if (diff < 7) return Math.floor(diff) + ' Tage';
    return d.toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit', year: '2-digit' });
  };
  const stripHtml = (html) => { const d = document.createElement('div'); d.innerHTML = html || ''; return d.textContent || ''; };
  const sanitize = (html) => {
    const d = document.createElement('div'); d.innerHTML = html || '';
    d.querySelectorAll('script,style,iframe,object,embed,form,input').forEach(n => n.remove());
    d.querySelectorAll('*').forEach(n => { for (const a of [...n.attributes]) if (a.name.startsWith('on') || (a.name === 'href' && a.value.trim().toLowerCase().startsWith('javascript'))) n.removeAttribute(a.name); if (n.tagName === 'A') { n.target = '_blank'; n.rel = 'noopener'; } });
    return d.innerHTML;
  };

  let toastTimer;
  const toast = (msg, isErr) => {
    const t = $('#toast'); t.textContent = msg; t.classList.toggle('err', !!isErr); t.classList.remove('hidden');
    clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.add('hidden'), 3500);
  };

  // ---------- API ----------
  async function api(method, path, body, raw) {
    const opts = { method, headers: {}, credentials: 'same-origin' };
    if (body !== undefined) { opts.headers['Content-Type'] = raw ? 'text/xml' : 'application/json'; opts.body = raw ? body : JSON.stringify(body); }
    const res = await fetch(path, opts);
    if (res.status === 401) { showLogin(); throw new Error('Nicht angemeldet'); }
    if (res.status === 204) return null;
    const data = await res.json().catch(() => ({}));
    if (!res.ok) { const e = new Error(data.error || ('HTTP ' + res.status)); e.status = res.status; e.data = data; throw e; }
    return data;
  }

  // ---------- state ----------
  const S = { podcasts: [], queue: { version: 0, items: [] }, settings: {}, me: null, episodes: new Map() };
  const podcastById = (id) => S.podcasts.find(p => p.id === id);
  const rememberEpisodes = (eps) => { for (const e of eps) S.episodes.set(e.id, e); return eps; };

  async function loadCore() {
    const [podcasts, queue, settings, me] = await Promise.all([api('GET', '/api/podcasts'), api('GET', '/api/queue'), api('GET', '/api/settings'), api('GET', '/api/me')]);
    S.podcasts = podcasts; S.queue = queue; S.settings = settings; S.me = me; rememberEpisodes(queue.items);
    $('#queue-count').textContent = queue.items.length || '';
  }
  async function reloadQueue(q, { rerender = true } = {}) {
    S.queue = q || await api('GET', '/api/queue'); rememberEpisodes(S.queue.items);
    $('#queue-count').textContent = S.queue.items.length || '';
    if (rerender && route.name === 'queue') render();
  }

  // ---------- login ----------
  function showLogin() { $('#login').classList.remove('hidden'); $('#app').classList.add('hidden'); }
  function showApp() { $('#login').classList.add('hidden'); $('#app').classList.remove('hidden'); }
  $('#login-form').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const f = new FormData(ev.target);
    $('#login-error').textContent = '';
    try {
      await api('POST', '/api/auth/login', { username: f.get('username'), password: f.get('password'), device_name: 'Web (' + navigator.platform + ')' });
      await boot();
    } catch (e) { $('#login-error').textContent = e.message; }
  });
  $('#btn-logout').addEventListener('click', async () => { try { await api('POST', '/api/auth/logout'); } catch (_) {} location.reload(); });
  $('#btn-refresh').addEventListener('click', async (ev) => {
    ev.target.disabled = true;
    try { const r = await api('POST', '/api/podcasts/refresh'); toast(`${r.refreshed} Feeds aktualisiert${r.errors ? ', ' + r.errors + ' Fehler' : ''}`); await loadCore(); render(); }
    catch (e) { toast(e.message, true); } finally { ev.target.disabled = false; }
  });

  // ---------- episode actions ----------
  async function queueAdd(ep, position) {
    try { await reloadQueue(await api('POST', '/api/queue/items', { episode_id: ep.id, position }), { rerender: false }); ep.in_queue = true; toast('Zur Warteschlange hinzugefügt'); render(); } catch (e) { toast(e.message, true); }
  }
  async function queueRemove(ep) {
    try { await reloadQueue(await api('DELETE', `/api/queue/items/${ep.id}`), { rerender: false }); ep.in_queue = false; render(); } catch (e) { toast(e.message, true); }
  }
  async function markPlayed(ep, played) {
    try {
      const updated = await api('PUT', `/api/episodes/${ep.id}/progress`, { position_ms: played ? (ep.duration_ms || 0) : 0, played, updated_at: new Date().toISOString() });
      S.episodes.set(updated.id, updated); Object.assign(ep, updated);
      await reloadQueue(undefined, { rerender: false }); render();
    } catch (e) { toast(e.message, true); }
  }

  function episodeRow(ep, opts = {}) {
    const pct = ep.duration_ms ? Math.min(100, ep.position_ms / ep.duration_ms * 100) : 0;
    const pod = podcastById(ep.podcast_id);
    const actions = [];
    if (ep.in_queue) actions.push(el('button', { class: 'btn icon', title: 'Aus Warteschlange entfernen', onclick: () => queueRemove(ep) }, '✕'));
    else {
      actions.push(el('button', { class: 'btn icon', title: 'Als Nächstes', onclick: () => queueAdd(ep, 'front') }, '⤒'));
      actions.push(el('button', { class: 'btn icon', title: 'Ans Ende der Warteschlange', onclick: () => queueAdd(ep, 'back') }, '≡+'));
    }
    actions.push(el('button', { class: 'btn icon', title: ep.played ? 'Als ungehört markieren' : 'Als gehört markieren', onclick: () => markPlayed(ep, !ep.played) }, ep.played ? '↶' : '✓'));
    const meta = [fmtDate(ep.published_at)];
    if (ep.duration_ms) meta.push(ep.position_ms > 0 && !ep.played ? `noch ${fmtTime(ep.duration_ms - ep.position_ms)}` : fmtTime(ep.duration_ms));
    const row = el('div', { class: 'ep' + (ep.played ? ' played' : ''), 'data-id': ep.id },
      el('img', { class: 'ep-art', src: ep.image_url || ep.podcast_image_url || '', loading: 'lazy', alt: '' }),
      el('div', { class: 'ep-body' },
        el('div', { class: 'ep-title', onclick: () => go('#/episode/' + ep.id) }, ep.title),
        el('div', { class: 'ep-meta' },
          opts.showPodcast !== false ? el('span', { class: 'pod', onclick: () => go('#/podcast/' + ep.podcast_id) }, ep.podcast_title) : null,
          ...meta.map(m => el('span', {}, m)),
          ep.in_queue && !opts.inQueue ? el('span', { class: 'tag q' }, 'in Warteschlange') : null,
          pod && pod.has_auth ? el('span', { class: 'tag' }, 'Premium') : null),
        pct > 0 && !ep.played ? el('div', { class: 'progress' }, el('i', { style: `width:${pct}%` })) : null),
      el('div', { class: 'ep-actions' }, opts.handle ? el('span', { class: 'handle', title: 'Ziehen zum Sortieren' }, '⋮⋮') : null, ...actions));
    return row;
  }

  // ---------- views ----------
  const views = {};

  views.queue = async (main) => {
    await reloadQueue(undefined, { rerender: false });
    main.append(el('h1', {}, 'Warteschlange', el('span', { class: 'sub' }, `${S.queue.items.length} Folgen · ${fmtTime(S.queue.items.reduce((a, e) => a + Math.max(0, (e.duration_ms || 0) - (e.position_ms || 0)), 0))}`),
      el('span', { class: 'spacer' }),
      S.queue.items.length ? el('button', { class: 'btn small danger', onclick: async () => { if (confirm('Warteschlange leeren?')) await reloadQueue(await api('DELETE', '/api/queue')); } }, 'Leeren') : null));
    if (!S.queue.items.length) { main.append(el('div', { class: 'empty' }, 'Die Warteschlange ist leer. Füge Folgen aus deinen Abos oder unter „Neu“ hinzu.')); return; }
    const list = el('div', { class: 'ep-list' });
    for (const ep of S.queue.items) { const row = episodeRow(ep, { inQueue: true, handle: true }); row.draggable = true; list.append(row); }
    main.append(list);
    // drag & drop reorder
    let dragged = null;
    list.addEventListener('dragstart', (e) => { dragged = e.target.closest('.ep'); if (dragged) { dragged.classList.add('dragging'); e.dataTransfer.effectAllowed = 'move'; } });
    list.addEventListener('dragover', (e) => { e.preventDefault(); const over = e.target.closest('.ep'); list.querySelectorAll('.ep').forEach(r => r.classList.remove('drop-before', 'drop-after')); if (over && over !== dragged) { const rect = over.getBoundingClientRect(); over.classList.add(e.clientY < rect.top + rect.height / 2 ? 'drop-before' : 'drop-after'); } });
    list.addEventListener('drop', async (e) => {
      e.preventDefault();
      const over = e.target.closest('.ep');
      list.querySelectorAll('.ep').forEach(r => r.classList.remove('drop-before', 'drop-after'));
      if (!over || !dragged || over === dragged) return;
      const rect = over.getBoundingClientRect();
      if (e.clientY < rect.top + rect.height / 2) over.before(dragged); else over.after(dragged);
      const ids = [...list.querySelectorAll('.ep')].map(r => r.dataset.id);
      try { await reloadQueue(await api('PUT', '/api/queue', { version: S.queue.version, episode_ids: ids })); }
      catch (err) { if (err.status === 409) { toast('Warteschlange wurde woanders geändert – neu geladen', true); await reloadQueue(err.data); } else toast(err.message, true); }
    });
    list.addEventListener('dragend', () => { if (dragged) dragged.classList.remove('dragging'); dragged = null; });
  };

  views.inbox = async (main) => {
    main.append(el('h1', {}, 'Neue Folgen', el('span', { class: 'sub' }, 'letzte 14 Tage')));
    const eps = rememberEpisodes(await api('GET', '/api/episodes?limit=200'));
    if (!eps.length) { main.append(el('div', { class: 'empty' }, 'Keine neuen Folgen.')); return; }
    main.append(el('div', { class: 'ep-list' }, eps.map(ep => episodeRow(ep))));
  };

  views.podcasts = async (main) => {
    S.podcasts = await api('GET', '/api/podcasts');
    main.append(el('h1', {}, 'Abos', el('span', { class: 'sub' }, `${S.podcasts.length} Podcasts`), el('span', { class: 'spacer' }), el('a', { class: 'btn small', href: '#/add' }, '+ Hinzufügen')));
    if (!S.podcasts.length) { main.append(el('div', { class: 'empty' }, 'Noch keine Abos. Füge einen Podcast per URL oder Suche hinzu.')); return; }
    main.append(el('div', { class: 'grid' }, S.podcasts.map(p => el('div', { class: 'pod-card', onclick: () => go('#/podcast/' + p.id) },
      el('img', { src: p.image_url || '', loading: 'lazy', alt: '' }),
      el('div', { class: 't' }, p.title),
      el('div', { class: 's' + (p.last_error ? ' err' : '') }, p.last_error ? '⚠ ' + p.last_error : `${p.episode_count} Folgen${p.has_auth ? ' · Premium' : ''}`)))));
  };

  views.podcast = async (main, id) => {
    const p = await api('GET', `/api/podcasts/${id}`);
    const idx = S.podcasts.findIndex(x => x.id === id); if (idx >= 0) S.podcasts[idx] = p; else S.podcasts.push(p);
    const desc = el('div', { class: 'desc', onclick: (e) => e.currentTarget.classList.toggle('open') }, stripHtml(p.description));
    const autoToggle = el('label', { class: 'switch' }, el('input', { type: 'checkbox', onchange: async (e) => { try { await api('PATCH', `/api/podcasts/${id}`, { auto_enqueue: e.target.checked }); toast(e.target.checked ? 'Neue Folgen landen in der Warteschlange' : 'Automatisches Einreihen aus'); } catch (err) { toast(err.message, true); } } }), el('i'));
    autoToggle.querySelector('input').checked = p.auto_enqueue;
    main.append(el('div', { class: 'pod-head' },
      el('img', { src: p.image_url || '', alt: '' }),
      el('div', {},
        el('h1', { style: 'margin-bottom:2px' }, p.title),
        el('div', { class: 'muted' }, [p.author, `${p.episode_count} Folgen`, p.has_auth ? 'Premium (Login hinterlegt)' : null, p.last_refreshed_at ? 'aktualisiert ' + new Date(p.last_refreshed_at).toLocaleString('de-DE') : null].filter(Boolean).join(' · ')),
        p.last_error ? el('div', { class: 'error' }, '⚠ ' + p.last_error) : null,
        desc,
        el('div', { class: 'row' },
          el('label', { class: 'inline' }, autoToggle, 'Neue Folgen automatisch einreihen'),
          el('span', { class: 'spacer' }),
          el('button', { class: 'btn small', onclick: async (e) => { e.target.disabled = true; try { await api('POST', `/api/podcasts/${id}/refresh`); toast('Aktualisiert'); render(); } catch (err) { toast(err.message, true); e.target.disabled = false; } } }, '⟳ Aktualisieren'),
          el('button', { class: 'btn small', onclick: () => editAuth(p) }, p.has_auth ? 'Login ändern' : 'Login hinterlegen'),
          p.website ? el('a', { class: 'btn small ghost', href: p.website, target: '_blank', rel: 'noopener' }, 'Website ↗') : null,
          el('button', { class: 'btn small danger', onclick: async () => {
            if (!confirm(`„${p.title}“ deabonnieren? Alle Folgen werden auch aus der Warteschlange entfernt.`)) return;
            try { await api('DELETE', `/api/podcasts/${id}`); toast('Deabonniert'); await loadCore(); go('#/podcasts'); } catch (err) { toast(err.message, true); }
          } }, 'Deabonnieren')))));
    const list = el('div', { class: 'ep-list' });
    main.append(el('h2', {}, 'Folgen'), list);
    let offset = 0; const limit = 50;
    const more = el('button', { class: 'btn', style: 'margin-top:14px', onclick: () => loadMore() }, 'Mehr laden');
    async function loadMore() {
      const eps = rememberEpisodes(await api('GET', `/api/podcasts/${id}/episodes?limit=${limit}&offset=${offset}`));
      offset += eps.length;
      list.append(...eps.map(ep => episodeRow(ep, { showPodcast: false })));
      if (eps.length < limit) more.remove(); else main.append(more);
      if (!list.children.length) list.append(el('div', { class: 'empty' }, 'Keine Folgen gefunden.'));
    }
    await loadMore();
  };

  function editAuth(p) {
    const user = prompt('Benutzername für den Premium-Feed (leer = Login entfernen):', '');
    if (user === null) return;
    const pass = user ? prompt('Passwort:', '') : '';
    if (pass === null) return;
    api('PATCH', `/api/podcasts/${p.id}`, { auth_username: user, auth_password: pass }).then(() => { toast(user ? 'Login gespeichert' : 'Login entfernt'); render(); }).catch(e => toast(e.message, true));
  }

  views.episode = async (main, id) => {
    const ep = rememberEpisodes([await api('GET', `/api/episodes/${id}`)])[0];
    main.append(el('div', { class: 'row', style: 'margin-bottom:14px' }, el('a', { class: 'btn small ghost', href: '#/podcast/' + ep.podcast_id }, '← ' + ep.podcast_title)));
    main.append(el('h1', {}, ep.title));
    main.append(episodeRow(ep, { showPodcast: false }));
    const body = el('div', { class: 'card', style: 'margin-top:18px; line-height:1.6' });
    body.innerHTML = sanitize(ep.description) || '<span class="muted">Keine Shownotes.</span>';
    main.append(body);
    if (ep.link) main.append(el('p', {}, el('a', { class: 'btn small ghost', href: ep.link, target: '_blank', rel: 'noopener' }, 'Zur Folge im Web ↗')));
  };

  views.add = async (main) => {
    main.append(el('h1', {}, 'Podcast hinzufügen'));
    const urlIn = el('input', { type: 'url', placeholder: 'https://example.com/feed.xml', required: '' });
    const userIn = el('input', { type: 'text', placeholder: 'optional', autocomplete: 'off' });
    const passIn = el('input', { type: 'password', placeholder: 'optional', autocomplete: 'new-password' });
    const err = el('div', { class: 'error' });
    const form = el('form', { class: 'form card', onsubmit: async (e) => {
      e.preventDefault(); err.textContent = ''; const btn = e.target.querySelector('button'); btn.disabled = true;
      try { const p = await api('POST', '/api/podcasts', { feed_url: urlIn.value.trim(), auth_username: userIn.value, auth_password: passIn.value }); toast(`„${p.title}“ abonniert`); await loadCore(); go('#/podcast/' + p.id); }
      catch (ex) { err.textContent = ex.message; } finally { btn.disabled = false; }
    } },
      el('label', {}, 'Feed-URL', urlIn),
      el('div', { class: 'row' }, el('label', { style: 'flex:1' }, 'Benutzername (Premium-Feed)', userIn), el('label', { style: 'flex:1' }, 'Passwort', passIn)),
      el('div', { class: 'muted' }, 'Bei Premium-Feeds mit HTTP-Login werden die Zugangsdaten nur auf dem Server gespeichert; Audio läuft dann über den Server-Proxy, damit auch Sonos streamen kann.'),
      el('button', { class: 'btn primary', type: 'submit' }, 'Abonnieren'), err);
    main.append(form);

    main.append(el('h2', {}, 'Suchen'));
    const q = el('input', { type: 'text', placeholder: 'Podcast-Name …' });
    const results = el('div', { class: 'results' });
    let t;
    q.addEventListener('input', () => { clearTimeout(t); t = setTimeout(async () => {
      results.replaceChildren();
      if (q.value.trim().length < 2) return;
      try {
        const res = await api('GET', '/api/search?q=' + encodeURIComponent(q.value.trim()));
        if (!res.length) results.append(el('div', { class: 'muted' }, 'Nichts gefunden.'));
        for (const r of res) {
          const subscribed = S.podcasts.find(p => p.feed_url === r.feed_url);
          results.append(el('div', { class: 'result' }, el('img', { src: r.image_url, alt: '' }), el('div', {}, el('div', { class: 't' }, r.title), el('div', { class: 's' }, r.author), el('div', { class: 'muted', style: 'font-size:11px;word-break:break-all', title: r.feed_url }, r.feed_url)),
            subscribed ? el('a', { class: 'btn small', href: '#/podcast/' + subscribed.id }, 'Abonniert') :
              el('button', { class: 'btn small primary', onclick: async (e) => { e.target.disabled = true; try { const p = await api('POST', '/api/podcasts', { feed_url: r.feed_url }); toast(`„${p.title}“ abonniert`); await loadCore(); go('#/podcast/' + p.id); } catch (ex) { toast(ex.message, true); e.target.disabled = false; } } }, 'Abonnieren')));
        }
      } catch (ex) { results.append(el('div', { class: 'error' }, ex.message)); }
    }, 350); });
    main.append(q, results);

    main.append(el('h2', {}, 'OPML importieren'));
    const file = el('input', { type: 'file', accept: '.opml,.xml,text/xml' });
    file.addEventListener('change', async () => {
      const f = file.files[0]; if (!f) return;
      try { const r = await api('POST', '/api/opml', await f.text(), true); toast(`${r.added} hinzugefügt, ${r.skipped} bereits vorhanden${r.failed.length ? ', ' + r.failed.length + ' fehlgeschlagen' : ''}`); await loadCore(); go('#/podcasts'); }
      catch (ex) { toast(ex.message, true); }
    });
    main.append(el('div', { class: 'row' }, file));
  };

  views.settings = async (main) => {
    main.append(el('h1', {}, 'Einstellungen'));
    const st = S.settings = await api('GET', '/api/settings');
    const save = async (patch) => { try { S.settings = await api('PUT', '/api/settings', { ...S.settings, ...patch }); toast('Gespeichert'); } catch (e) { toast(e.message, true); } };
    const sw = (key, label) => { const inp = el('input', { type: 'checkbox', onchange: (e) => save({ [key]: e.target.checked }) }); inp.checked = !!st[key]; return el('label', { class: 'inline' }, el('span', { class: 'switch' }, inp, el('i')), label); };
    const interval = el('input', { type: 'text', value: st.refresh_interval_minutes, style: 'width:90px', onchange: (e) => save({ refresh_interval_minutes: Math.max(5, parseInt(e.target.value) || 30) }) });
    main.append(el('div', { class: 'card form' },
      sw('auto_remove_played', 'Gehörte Folgen automatisch aus der Warteschlange entfernen'),
      sw('auto_enqueue_default', 'Neue Abos: neue Folgen automatisch einreihen'),
      el('label', { class: 'inline' }, interval, 'Minuten zwischen Feed-Aktualisierungen')));

    main.append(el('h2', {}, 'Geräte'));
    const devs = await api('GET', '/api/devices');
    const table = el('table', {}, el('tr', {}, el('th', {}, 'Name'), el('th', {}, 'Zuletzt aktiv'), el('th', {}, 'Angelegt'), el('th')));
    for (const d of devs) table.append(el('tr', {}, el('td', {}, d.name, d.current ? ' ' : '', d.current ? el('span', { class: 'tag q' }, 'dieses') : null), el('td', {}, new Date(d.last_seen_at).toLocaleString('de-DE')), el('td', {}, new Date(d.created_at).toLocaleDateString('de-DE')),
      el('td', { style: 'text-align:right' }, d.current ? null : el('button', { class: 'btn small danger', onclick: async () => { if (confirm(`Gerät „${d.name}“ abmelden?`)) { await api('DELETE', `/api/devices/${d.id}`); render(); } } }, 'Abmelden'))));
    main.append(el('div', { class: 'card' }, table));

    main.append(el('h2', {}, 'Server'));
    main.append(el('div', { class: 'card form' },
      el('div', {}, el('span', { class: 'muted' }, 'Öffentliche URL: '), S.me.public_url),
      el('div', {}, el('span', { class: 'muted' }, 'Benutzer: '), S.me.username),
      el('div', { class: 'row' },
        el('a', { class: 'btn small', href: '/api/opml' }, 'OPML exportieren'),
        el('button', { class: 'btn small', onclick: async () => { if (confirm('Stream-Token erneuern? Alle bisherigen Premium-Stream-Links werden ungültig; Apps holen sich automatisch neue.')) { await api('POST', '/api/stream-token/rotate'); toast('Stream-Token erneuert'); } } }, 'Stream-Token erneuern'))));
  };

  // ---------- router ----------
  let route = { name: 'queue', arg: null };
  const go = (hash) => { location.hash = hash; };
  function parseRoute() {
    const h = location.hash.replace(/^#\/?/, '');
    const [name, arg] = h.split('/');
    route = { name: views[name] ? name : 'queue', arg: arg || null };
  }
  let renderSeq = 0;
  async function render() {
    parseRoute();
    document.querySelectorAll('.nav a').forEach(a => a.classList.toggle('active', a.dataset.route === route.name || (route.name === 'podcast' && a.dataset.route === 'podcasts')));
    const seq = ++renderSeq;
    const main = $('#main');
    const fresh = el('div');
    try { await views[route.name](fresh, route.arg); }
    catch (e) { if (e.message !== 'Nicht angemeldet') fresh.append(el('div', { class: 'error' }, e.message)); }
    if (seq !== renderSeq) return;
    main.replaceChildren(...fresh.childNodes);
    main.scrollTop = 0;
  }
  window.addEventListener('hashchange', render);

  // periodic queue refresh so changes from apps show up
  setInterval(() => { if (!$('#app').classList.contains('hidden') && document.visibilityState === 'visible') reloadQueue().catch(() => {}); }, 30000);

  async function boot() {
    try { await loadCore(); showApp(); if (!location.hash) location.hash = '#/queue'; else render(); }
    catch (e) { if (e.message !== 'Nicht angemeldet') toast(e.message, true); }
  }
  boot();
})();
