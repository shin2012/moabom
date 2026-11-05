'use strict';
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const AX = ['c1', 'c2', 'c3'];

let CATS = { axes: ['분류 1', '분류 2', '분류 3'], items: [], defaults: {} };
const state = {
  tab: 'library', items: [], total: 0, offset: 0, loading: false, seed: null,
  filter: { c1: '', c2: '', c3: '', source: '', kind: '', favorite: false, owner: '', sort: 'new' },
  selecting: false, selected: new Set(), viewerIdx: -1, viewerList: null,
  feed: [], feedOffset: 0, feedSeed: null, feedLoading: false, downloads: [],
};

// ───── api ─────
async function api(path, opts = {}) {
  const o = { credentials: 'same-origin', ...opts };
  if (o.body && typeof o.body !== 'string') { o.body = JSON.stringify(o.body); o.headers = { 'Content-Type': 'application/json', ...(o.headers || {}) }; }
  const r = await fetch(path, o);
  if (r.status === 401) { showLogin(); throw new Error('로그인이 필요합니다'); }
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.detail || `오류 (${r.status})`);
  return data;
}
let toastTimer;
function toast(msg, action) {
  const t = $('#toast');
  t.innerHTML = esc(msg) + (action ? ` <button>${esc(action.label)}</button>` : '');
  if (action) t.querySelector('button').onclick = () => { t.classList.remove('show'); action.run(); };
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), action ? 6000 : 2500);
}
const fail = e => toast(e.message || String(e));
const fmtBytes = b => { if (!b) return '0 B'; const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0; while (b >= 1024 && i < 4) { b /= 1024; i++; } return `${b.toFixed(i > 1 ? 1 : 0)} ${u[i]}`; };
const fmtDur = s => { if (!s) return ''; s = Math.round(s); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };
const fmtTime = iso => { if (!iso) return ''; const d = new Date(iso); return `${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`; };
const catName = id => CATS.items.find(c => c.id === id)?.name;
const catsOf = axis => CATS.items.filter(c => c.axis === axis);

// ───── auth ─────
function showLogin() { $('#login').classList.remove('hidden'); $('#app').classList.add('hidden'); }
async function doLogin() {
  try {
    await api('/api/auth/login', { method: 'POST', body: { username: $('#loginUser').value, password: $('#loginPass').value } });
    $('#login').classList.add('hidden');
    boot();
  } catch (e) { $('#loginErr').textContent = e.message; }
}
async function logout() { await api('/api/auth/logout', { method: 'POST' }).catch(() => {}); location.reload(); }

// ───── tabs ─────
function setTab(tab) {
  state.tab = tab;
  $$('#tabs button').forEach(b => b.classList.toggle('on', b.dataset.tab === tab));
  $$('.tab').forEach(s => s.classList.toggle('on', s.id === 'tab-' + tab));
  if (tab !== 'feed') $$('#feed video').forEach(v => v.pause());
  ({ library: () => state.items.length || reloadLibrary(), feed: () => state.feed.length || loadFeed(),
     downloads: loadDownloads, watch: loadWatch, settings: loadSettings, stats: loadStats }[tab] || (() => {}))();
  history.replaceState(null, '', '#' + tab);
}
$('#tabs').addEventListener('click', e => { const b = e.target.closest('button'); if (b) setTab(b.dataset.tab); });

// ───── categories ─────
async function loadCats() { CATS = await api('/api/categories'); }

// ───── library ─────
function renderFilters() {
  const f = state.filter;
  const sel = (key, axis) => `<select data-k="${key}"><option value="">${esc(CATS.axes[axis - 1])} 전체</option>
    <option value="none" ${f[key] === 'none' ? 'selected' : ''}>미분류</option>
    ${catsOf(axis).map(c => `<option value="${c.id}" ${String(f[key]) === String(c.id) ? 'selected' : ''}>${esc(c.name)} (${c.count})</option>`).join('')}</select>`;
  const chip = (k, v, label) => `<button class="chip ${f[k] === v ? 'on' : ''}" data-chip="${k}" data-v="${v}">${label}</button>`;
  $('#libFilters').innerHTML = sel('c1', 1) + sel('c2', 2) + sel('c3', 3) +
    chip('source', '', '전체') + chip('source', 'manual', '직접') + chip('source', 'watch', '감시') + chip('source', 'likes', '좋아요') +
    `<button class="chip ${f.favorite ? 'on' : ''}" data-fav>★</button>
     <select data-k="kind"><option value="">사진+영상</option><option value="video" ${f.kind === 'video' ? 'selected' : ''}>영상</option><option value="image" ${f.kind === 'image' ? 'selected' : ''}>사진</option></select>
     <select data-k="sort"><option value="new">최신순</option><option value="old" ${f.sort === 'old' ? 'selected' : ''}>오래된순</option><option value="random" ${f.sort === 'random' ? 'selected' : ''}>무작위</option></select>
     <button class="chip" onclick="enterSelect()">선택</button>`;
}
$('#libFilters').addEventListener('change', e => { const k = e.target.dataset.k; if (k) { state.filter[k] = e.target.value; reloadLibrary(); } });
$('#libFilters').addEventListener('click', e => {
  const c = e.target.closest('[data-chip]');
  if (c) { state.filter[c.dataset.chip] = c.dataset.v; reloadLibrary(); }
  if (e.target.closest('[data-fav]')) { state.filter.favorite = !state.filter.favorite; reloadLibrary(); }
});

function query(extra = {}) {
  const f = state.filter, p = new URLSearchParams();
  for (const k of ['c1', 'c2', 'c3', 'source', 'kind', 'owner', 'sort']) if (f[k]) p.set(k, f[k]);
  if (f.favorite) p.set('favorite', 'true');
  for (const [k, v] of Object.entries(extra)) if (v !== null && v !== undefined) p.set(k, v);
  return p.toString();
}
async function reloadLibrary() {
  state.items = []; state.offset = 0; state.seed = state.filter.sort === 'random' ? Math.floor(Math.random() * 1e9) : null;
  renderFilters();
  $('#grid').innerHTML = '';
  await loadMoreLibrary();
}
async function loadMoreLibrary() {
  if (state.loading) return;
  if (state.offset && state.offset >= state.total) return;
  state.loading = true;
  try {
    const d = await api('/api/media?' + query({ offset: state.offset, limit: 90, seed: state.seed }));
    state.total = d.total; state.offset += d.items.length;
    const start = state.items.length;
    state.items.push(...d.items);
    $('#grid').insertAdjacentHTML('beforeend', d.items.map((m, i) => cellHtml(m, start + i)).join(''));
    $('#libMore').textContent = state.items.length ? `${state.items.length} / ${d.total}` : '항목이 없습니다';
  } catch (e) { fail(e); } finally { state.loading = false; }
}
function cellHtml(m, idx) {
  return `<div class="cell ${state.selected.has(m.id) ? 'sel' : ''}" data-idx="${idx}" data-id="${m.id}">
    <img loading="lazy" src="/api/media/${m.id}/thumb?w=240" alt="">
    ${m.kind === 'video' ? `<span class="dur">${fmtDur(m.duration) || '▶'}</span>` : ''}${m.favorite ? '<span class="fav">★</span>' : ''}</div>`;
}
new IntersectionObserver(es => { if (es[0].isIntersecting && state.tab === 'library') loadMoreLibrary(); }, { rootMargin: '800px' }).observe($('#libMore'));

// long-press / right-click enters selection (works on iOS Safari)
let pressTimer = null, pressed = false;
$('#grid').addEventListener('touchstart', e => {
  const c = e.target.closest('.cell'); if (!c) return;
  pressed = false;
  pressTimer = setTimeout(() => { pressed = true; if (!state.selecting) enterSelect(); toggleSel(+c.dataset.id, c); navigator.vibrate?.(10); }, 450);
}, { passive: true });
['touchend', 'touchmove', 'touchcancel'].forEach(ev => $('#grid').addEventListener(ev, () => clearTimeout(pressTimer), { passive: true }));
$('#grid').addEventListener('contextmenu', e => { const c = e.target.closest('.cell'); if (!c) return; e.preventDefault(); if (pressed) return; if (!state.selecting) enterSelect(); toggleSel(+c.dataset.id, c); });
$('#grid').addEventListener('click', e => {
  const c = e.target.closest('.cell'); if (!c) return;
  if (pressed) { pressed = false; return; }
  if (state.selecting) toggleSel(+c.dataset.id, c); else openViewer(+c.dataset.idx, state.items);
});
function enterSelect() { state.selecting = true; $('#selBar').classList.remove('hidden'); updateSelBar(); }
function exitSelect() { state.selecting = false; state.selected.clear(); $$('.cell.sel').forEach(c => c.classList.remove('sel')); $('#selBar').classList.add('hidden'); }
function toggleSel(id, cell) { state.selected.has(id) ? state.selected.delete(id) : state.selected.add(id); cell.classList.toggle('sel', state.selected.has(id)); updateSelBar(); }
function selectAllVisible() { state.items.forEach(m => state.selected.add(m.id)); $$('.cell').forEach(c => c.classList.add('sel')); updateSelBar(); }
function updateSelBar() { $('#selCount').textContent = `${state.selected.size}개 선택`; }
const selectedIds = () => [...state.selected];

function patchItems(updated) {
  const map = new Map(updated.map(m => [m.id, m]));
  for (const list of [state.items, state.feed]) list.forEach((m, i) => { if (map.has(m.id)) list[i] = map.get(m.id); });
}
function dropItems(ids) {
  const s = new Set(ids);
  state.items = state.items.filter(m => !s.has(m.id));
  state.feed = state.feed.filter(m => !s.has(m.id));
  $$('.cell').forEach(c => { if (s.has(+c.dataset.id)) c.remove(); });
  $$('.cell').forEach((c, i) => c.dataset.idx = i);
  state.total -= ids.length; state.offset -= ids.length;
}

async function deleteIds(ids) {
  if (!ids.length) return;
  if (!confirm(`${ids.length}개를 NAS에서 완전히 삭제할까요?`)) return;
  try { await api('/api/media/delete', { method: 'POST', body: { ids } }); dropItems(ids); exitSelect(); toast(`${ids.length}개 삭제함`); loadCats(); }
  catch (e) { fail(e); }
}

// ───── classify sheet ─────
function chipsHtml(axis, current, allowKeep) {
  const key = 'c' + axis;
  const opts = [...(allowKeep ? [['keep', '유지']] : []), ['none', '미분류'], ...catsOf(axis).map(c => [String(c.id), c.name])];
  return `<div class="axis-label">${esc(CATS.axes[axis - 1])}</div><div class="chips" data-axis="${key}">` +
    opts.map(([v, l]) => `<button class="chip ${String(current) === v ? 'on' : ''}" data-v="${v}">${esc(l)}</button>`).join('') + '</div>';
}
function bindChips(root) {
  root.addEventListener('click', e => {
    const b = e.target.closest('.chip'); if (!b) return;
    $$('.chip', b.parentElement).forEach(x => x.classList.toggle('on', x === b));
  });
}
const pickedCats = root => Object.fromEntries($$('.chips', root).map(g => [g.dataset.axis, $('.chip.on', g)?.dataset.v ?? 'keep']));

function openClassify(ids) {
  if (!ids.length) return;
  const single = ids.length === 1 ? [...state.items, ...state.feed].find(m => m.id === ids[0]) : null;
  $('#sheetTitle').textContent = single ? '분류 변경' : `${ids.length}개 분류 변경`;
  const body = $('#sheetBody');
  body.innerHTML = `<div class="cat-pick">${[1, 2, 3].map(a => chipsHtml(a, single ? (single['c' + a] ?? 'none') : 'keep', !single)).join('')}</div>`;
  $('#sheet').classList.remove('hidden');
  $('#sheetOk').onclick = async () => {
    const picked = pickedCats(body), payload = { ids };
    for (const k of AX) if (picked[k] !== 'keep') payload[k] = picked[k] === 'none' ? null : +picked[k];
    if (Object.keys(payload).length === 1) return closeSheet();
    try {
      const r = await api('/api/media/classify', { method: 'POST', body: payload });
      closeSheet(); patchItems(r.items); exitSelect(); loadCats().then(renderFilters);
      if (state.viewerIdx >= 0) renderViewer();
      toast(`${r.moved}개 분류 변경`, { label: '되돌리기', run: () => undo(r.undo) });
    } catch (e) { fail(e); }
  };
}
async function undo(u) {
  try { const r = await api('/api/media/undo', { method: 'POST', body: { undo: u } }); patchItems(r.items); if (state.viewerIdx >= 0) renderViewer(); toast('되돌렸습니다'); loadCats(); }
  catch (e) { fail(e); }
}
function closeSheet() { $('#sheet').classList.add('hidden'); }

// ───── viewer ─────
function openViewer(idx, list) { state.viewerIdx = idx; state.viewerList = list; $('#viewer').classList.remove('hidden'); renderViewer(); }
function closeViewer() { $('#vBody').innerHTML = ''; $('#viewer').classList.add('hidden'); state.viewerIdx = -1; }
function stepViewer(d) {
  const n = state.viewerIdx + d, list = state.viewerList;
  if (n < 0 || n >= list.length) return;
  state.viewerIdx = n; renderViewer();
  if (list === state.items && n > list.length - 10) loadMoreLibrary();
}
function renderViewer() {
  const m = state.viewerList[state.viewerIdx]; if (!m) return closeViewer();
  const src = `/api/media/${m.id}/file`;
  $('#vBody').innerHTML = m.kind === 'video'
    ? `<video src="${src}" controls autoplay playsinline loop></video>` : `<img src="${src}" alt="">`;
  const cats = AX.map(k => catName(m[k])).filter(Boolean).join(' · ') || '미분류';
  $('#vInfo').innerHTML = `<div>${esc(m.owner ? '@' + m.owner : '')} ${esc(cats)} · ${fmtBytes(m.size)}</div>
    <div class="row"><button class="btn sm" onclick="openClassify([${m.id}])">분류</button>
    <button class="btn sm" onclick="toggleFav(${m.id})">${m.favorite ? '★ 즐겨찾기 해제' : '☆ 즐겨찾기'}</button>
    ${m.source_url ? `<a class="btn sm" href="${esc(m.source_url)}" target="_blank" rel="noopener">원본</a>` : ''}
    <button class="btn sm danger" onclick="deleteFromViewer(${m.id})">삭제</button></div>`;
}
async function toggleFav(id) {
  const m = [...state.items, ...state.feed].find(x => x.id === id); if (!m) return;
  await api('/api/media/favorite', { method: 'POST', body: { ids: [id], value: !m.favorite } }).catch(fail);
  patchItems([{ ...m, favorite: m.favorite ? 0 : 1 }]); renderViewer();
}
async function deleteFromViewer(id) {
  if (!confirm('NAS에서 완전히 삭제할까요?')) return;
  try { await api('/api/media/delete', { method: 'POST', body: { ids: [id] } }); dropItems([id]); toast('삭제함'); state.viewerList[state.viewerIdx] ? renderViewer() : closeViewer(); }
  catch (e) { fail(e); }
}
document.addEventListener('keydown', e => {
  if (state.viewerIdx < 0) return;
  if (e.key === 'ArrowRight') stepViewer(1); else if (e.key === 'ArrowLeft') stepViewer(-1); else if (e.key === 'Escape') closeViewer();
});
let touchX = null;
$('#viewer').addEventListener('touchstart', e => { touchX = e.touches[0].clientX; }, { passive: true });
$('#viewer').addEventListener('touchend', e => { if (touchX === null) return; const dx = e.changedTouches[0].clientX - touchX; if (Math.abs(dx) > 60) stepViewer(dx < 0 ? 1 : -1); touchX = null; }, { passive: true });

// ───── feed ─────
async function loadFeed() {
  if (state.feedLoading) return;
  state.feedLoading = true;
  if (!state.feedSeed) state.feedSeed = Math.floor(Math.random() * 1e9);
  try {
    const d = await api(`/api/media?sort=random&seed=${state.feedSeed}&offset=${state.feedOffset}&limit=12`);
    state.feedOffset += d.items.length;
    const start = state.feed.length;
    state.feed.push(...d.items);
    $('#feed').insertAdjacentHTML('beforeend', d.items.map((m, i) => `<div class="feed-item" data-idx="${start + i}">
      ${m.kind === 'video' ? `<video data-src="/api/media/${m.id}/file" poster="/api/media/${m.id}/thumb?w=960" playsinline loop muted preload="none"></video>`
        : `<img loading="lazy" src="/api/media/${m.id}/thumb?w=960">`}
      <div class="feed-actions"><button onclick="toggleMute(this)">🔇</button><button onclick="openClassify([${m.id}])">⇄</button>
      <button onclick="openViewer(${start + i}, state.feed)">⤢</button></div>
      <div class="feed-meta">${esc(m.owner ? '@' + m.owner : '')} ${esc(AX.map(k => catName(m[k])).filter(Boolean).join(' · '))}</div></div>`).join(''));
    $$('#feed .feed-item:not([data-obs])').forEach(el => { el.dataset.obs = 1; feedObs.observe(el); });
  } catch (e) { fail(e); } finally { state.feedLoading = false; }
}
let feedMuted = true;
function toggleMute(btn) { feedMuted = !feedMuted; $$('#feed video').forEach(v => v.muted = feedMuted); $$('#feed .feed-actions button:first-child').forEach(b => b.textContent = feedMuted ? '🔇' : '🔊'); }
const feedObs = new IntersectionObserver(es => es.forEach(e => {
  const v = $('video', e.target);
  if (e.isIntersecting) {
    if (v) { if (!v.src) v.src = v.dataset.src; v.muted = feedMuted; v.play().catch(() => {}); }
    if (+e.target.dataset.idx >= state.feed.length - 4) loadFeed();
  } else if (v) v.pause();
}), { threshold: 0.6 });

// ───── downloads ─────
function renderDlCats() {
  $('#dlCats').innerHTML = [1, 2, 3].map(a => chipsHtml(a, CATS.defaults?.['c' + a] ?? 'none', false)).join('');
}
bindChips($('#dlCats'));
bindChips($('#sheetBody'));
async function submitDownload() {
  const url = $('#urlInput').value.trim(); if (!url) return;
  const picked = pickedCats($('#dlCats')), body = { url, use_defaults: false };
  for (const k of AX) body[k] = picked[k] && picked[k] !== 'none' ? +picked[k] : null;
  try { await api('/api/download', { method: 'POST', body }); $('#urlInput').value = ''; toast('대기열에 추가함'); loadDownloads(); }
  catch (e) { fail(e); }
}
const STATUS = { queued: '대기', downloading: '받는 중', completed: '완료', failed: '실패', cancelled: '취소' };
async function loadDownloads() {
  try { state.downloads = (await api('/api/downloads?limit=150')).downloads; renderDownloads(); } catch (e) { fail(e); }
}
function renderDownloads() {
  $('#dlList').innerHTML = state.downloads.map(d => `<div class="item" data-dl="${d.id}">
    <div class="grow"><div class="title">${esc(d.title || d.url)}</div>
    <div class="meta">${esc(d.username ? '@' + d.username : '')} · ${fmtTime(d.created_at)} ${d.watched_by ? '· 감시' : ''} ${d.error ? '· ' + esc(d.error) : ''}</div>
    ${d.status === 'downloading' ? `<div class="bar"><i style="width:${d.progress || 0}%"></i></div>` : ''}</div>
    <span class="badge ${d.status === 'completed' ? 'ok' : d.status === 'failed' ? 'bad' : ''}">${STATUS[d.status] || d.status}</span>
    ${d.status === 'failed' || d.status === 'cancelled' ? `<button class="btn sm" onclick="dlAction(${d.id},'retry')">재시도</button>` : ''}
    ${d.status === 'queued' || d.status === 'downloading' ? `<button class="btn sm" onclick="dlAction(${d.id},'cancel')">취소</button>` : ''}
  </div>`).join('') || '<div class="hint">기록이 없습니다</div>';
}
async function dlAction(id, act) { try { await api(`/api/download/${id}/${act}`, { method: 'POST' }); loadDownloads(); } catch (e) { fail(e); } }
async function clearDownloads(s) { try { await api('/api/downloads/' + s, { method: 'DELETE' }); loadDownloads(); } catch (e) { fail(e); } }

// ───── watch ─────
async function loadWatch() {
  try {
    const [w, l] = await Promise.all([api('/api/watch'), api('/api/likes/status')]);
    $('#likesCard').innerHTML = `<div class="row"><div class="grow"><b>좋아요 감시</b>
      <div class="meta hint">${l.x_username ? '@' + esc(l.x_username) : '설정에서 X 계정 이름을 입력하세요'} ${l.last_checked ? '· 확인 ' + fmtTime(l.last_checked) : ''}</div></div>
      <button class="btn" onclick="likesToggle()">${l.enabled ? '끄기' : '켜기'}</button><button class="btn ghost" onclick="likesImport()">지금 가져오기</button></div>`;
    $('#watchList').innerHTML = w.watched.map(a => `<div class="item"><div class="grow">
      <div class="title">@${esc(a.username)} <span class="badge ${a.account_status === 'active' ? 'ok' : ['suspended', 'not_found', 'unavailable'].includes(a.account_status) ? 'bad' : ''}">${{ active: '정상', suspended: '정지됨', not_found: '없음', unavailable: '이용 불가' }[a.account_status] || '확인 전'}</span></div>
      <div class="meta">${a.media_count}개 · 마지막 받음 ${fmtTime(a.last_download_at) || '-'} · 확인 ${fmtTime(a.last_checked) || '-'}</div></div>
      <button class="btn sm" onclick="runWatch('${esc(a.username)}')">지금 확인</button>
      <button class="btn sm danger" onclick="removeWatch('${esc(a.username)}')">삭제</button></div>`).join('') || '<div class="hint">감시 중인 계정이 없습니다</div>';
  } catch (e) { fail(e); }
}
async function addWatch() { const u = $('#watchInput').value.trim(); if (!u) return; try { await api('/api/watch', { method: 'POST', body: { username: u } }); $('#watchInput').value = ''; loadWatch(); } catch (e) { fail(e); } }
async function runWatch(u) { toast('확인 중…'); try { const r = await api(`/api/watch/${u}/run`, { method: 'POST' }); toast(`새 항목 ${r.new_downloads}개`); loadWatch(); } catch (e) { fail(e); } }
async function removeWatch(u) { if (!confirm(`@${u} 감시를 멈출까요? (받은 파일은 남습니다)`)) return; try { await api('/api/watch/' + u, { method: 'DELETE' }); loadWatch(); } catch (e) { fail(e); } }
async function likesToggle() { try { await api('/api/likes/watch', { method: 'POST' }); loadWatch(); } catch (e) { fail(e); } }
async function likesImport() { toast('가져오는 중…'); try { const r = await api('/api/likes/import', { method: 'POST' }); toast(`${r.imported}개 추가`); } catch (e) { fail(e); } }

// ───── settings ─────
async function loadSettings() {
  try {
    await loadCats(); renderCatManager();
    const [s, d, l] = await Promise.all([api('/api/settings'), api('/api/auth/devices'), api('/api/logs?limit=40')]);
    $('#xStatus').innerHTML = `<p class="hint">${s.x_logged_in ? '✅ X 로그인됨 <button class="btn sm ghost" onclick="xLogout()">로그아웃</button>' : 'X 로그인 안 됨 — 일부 게시물은 받을 수 없습니다'}</p>`;
    $('#xUser').value = s.x_username || '';
    $('#devices').innerHTML = d.devices.map(x => `<div class="item"><div class="grow"><div class="title">${x.kind === 'app' ? '📱' : '🌐'} ${esc(x.name || '')}</div>
      <div class="meta">마지막 사용 ${fmtTime(x.last_used)}</div></div><button class="btn sm danger" onclick="revokeDevice('${x.id}')">로그아웃</button></div>`).join('');
    $('#logs').innerHTML = l.logs.map(x => `<div>${fmtTime(x.time)} · ${esc(x.action)} ${esc(x.detail)}</div>`).join('');
  } catch (e) { fail(e); }
}
function renderCatManager() {
  $('#catManager').innerHTML = [1, 2, 3].map(a => `<div class="cat-axis" data-axis="${a}">
    <div class="cat-axis-head"><input value="${esc(CATS.axes[a - 1])}" data-axisname="${a}" onchange="saveAxisNames()"><span class="hint">기본값: ${esc(catName(CATS.defaults?.['c' + a]) || '없음')}</span></div>
    <div class="cat-list">${catsOf(a).map(c => `<div class="cat-row" data-id="${c.id}"><span class="handle">≡</span><span class="name">${esc(c.name)}</span><span class="cnt">${c.count}</span>
      <button class="btn sm ghost" onclick="catDefault(${a},${c.id})">기본</button>
      <button class="btn sm ghost" onclick="catRename(${c.id})">이름</button>
      <button class="btn sm ghost" onclick="catMerge(${c.id})">합치기</button>
      <button class="btn sm ghost danger" onclick="catDelete(${c.id})">삭제</button></div>`).join('')}</div>
    <div class="row"><input placeholder="새 분류 이름" data-new="${a}" onkeydown="if(event.key==='Enter')catAdd(${a})"><button class="btn" onclick="catAdd(${a})">추가</button></div></div>`).join('');
  $$('.cat-list').forEach(enableDragSort);
}
async function catRefresh() { await loadCats(); renderCatManager(); renderDlCats(); renderFilters(); }
async function saveAxisNames() { try { await api('/api/categories/axes', { method: 'PUT', body: { names: [1, 2, 3].map(a => $(`[data-axisname="${a}"]`).value) } }); toast('저장함'); catRefresh(); } catch (e) { fail(e); } }
async function catAdd(a) { const i = $(`[data-new="${a}"]`); if (!i.value.trim()) return; try { await api('/api/categories', { method: 'POST', body: { axis: a, name: i.value.trim() } }); catRefresh(); } catch (e) { fail(e); } }
async function catRename(id) {
  const name = prompt('새 이름', catName(id)); if (!name || name === catName(id)) return;
  toast('폴더 이름을 바꾸는 중…');
  try { const r = await api('/api/categories/' + id, { method: 'PATCH', body: { name } }); toast(`바꿈 (${r.moved}개 이동)`); catRefresh(); } catch (e) { fail(e); }
}
async function catMerge(id) {
  const c = CATS.items.find(x => x.id === id), others = catsOf(c.axis).filter(x => x.id !== id);
  const pick = prompt(`'${c.name}'을(를) 어느 분류로 합칠까요?\n` + others.map((o, i) => `${i + 1}. ${o.name}`).join('\n') + '\n번호를 입력하세요');
  const target = others[+pick - 1]; if (!target) return;
  if (!confirm(`'${c.name}' ${c.count}개를 '${target.name}'(으)로 옮기고 '${c.name}'을(를) 없앨까요?`)) return;
  try { const r = await api(`/api/categories/${id}/merge`, { method: 'POST', body: { into: target.id } }); toast(`합침 (${r.moved}개 이동)`); catRefresh(); } catch (e) { fail(e); }
}
async function catDelete(id) {
  const c = CATS.items.find(x => x.id === id);
  if (!confirm(`'${c.name}' 분류를 삭제할까요? 파일 ${c.count}개는 지워지지 않고 미분류로 옮겨집니다.`)) return;
  try { const r = await api('/api/categories/' + id, { method: 'DELETE' }); toast(`삭제함 (${r.moved}개 이동)`); catRefresh(); } catch (e) { fail(e); }
}
async function catDefault(axis, id) {
  const d = { ...CATS.defaults }; d['c' + axis] = d['c' + axis] === id ? null : id;
  try { await api('/api/categories/defaults', { method: 'PUT', body: d }); catRefresh(); } catch (e) { fail(e); }
}
function enableDragSort(list) {
  let drag = null;
  list.addEventListener('pointerdown', e => {
    const h = e.target.closest('.handle'); if (!h) return;
    drag = h.closest('.cat-row'); drag.classList.add('dragging'); h.setPointerCapture(e.pointerId); e.preventDefault();
  });
  list.addEventListener('pointermove', e => {
    if (!drag) return;
    const over = document.elementFromPoint(e.clientX, e.clientY)?.closest('.cat-row');
    if (over && over !== drag && over.parentElement === list) {
      const r = over.getBoundingClientRect();
      list.insertBefore(drag, e.clientY > r.top + r.height / 2 ? over.nextSibling : over);
    }
  });
  const end = async () => {
    if (!drag) return; drag.classList.remove('dragging'); drag = null;
    const axis = +list.closest('.cat-axis').dataset.axis;
    await api('/api/categories/reorder', { method: 'POST', body: { axis, ids: $$('.cat-row', list).map(r => +r.dataset.id) } }).catch(fail);
    loadCats().then(() => { renderDlCats(); renderFilters(); });
  };
  list.addEventListener('pointerup', end); list.addEventListener('pointercancel', end);
}
async function saveXToken() { try { await api('/api/settings/x_login', { method: 'POST', body: { auth_token: $('#xToken').value, ct0: $('#xCt0').value || null } }); $('#xToken').value = $('#xCt0').value = ''; toast('X 로그인 성공'); loadSettings(); } catch (e) { fail(e); } }
async function xLogout() { await api('/api/settings/x_logout', { method: 'POST' }).catch(fail); loadSettings(); }
async function saveXUser() { try { await api('/api/settings/x_username', { method: 'PUT', body: { x_username: $('#xUser').value } }); toast('저장함'); } catch (e) { fail(e); } }
async function revokeDevice(id) { if (!confirm('이 기기를 로그아웃할까요?')) return; await api('/api/auth/devices/' + id, { method: 'DELETE' }).catch(fail); loadSettings(); }
async function rescan() { toast('다시 읽는 중…'); try { const r = await api('/api/library/rescan', { method: 'POST' }); toast(`추가 ${r.added} · 이동 ${r.moved} · 제거 ${r.removed}`); reloadLibrary(); } catch (e) { fail(e); } }

// ───── stats ─────
async function loadStats() {
  try {
    const s = await api('/api/stats');
    const bars = (rows, label = r => r.name) => { const max = Math.max(1, ...rows.map(r => r.size_bytes)); return rows.map(r => `<div class="hbar"><span>${esc(label(r))}</span><div class="b"><i style="width:${(r.size_bytes / max * 100).toFixed(1)}%"></i></div><span class="v">${r.count}개 · ${fmtBytes(r.size_bytes)}</span></div>`).join(''); };
    const src = { manual: '직접', watch: '감시', likes: '좋아요' };
    $('#stats').innerHTML = `<div class="stat-grid">
      <div class="stat"><span>전체</span><b>${s.total_files.toLocaleString()}개</b></div>
      <div class="stat"><span>용량</span><b>${fmtBytes(s.total_size_bytes)}</b></div>
      <div class="stat"><span>영상 / 사진</span><b>${s.videos} / ${s.images}</b></div>
      ${s.disk ? `<div class="stat"><span>NAS 남은 공간</span><b>${fmtBytes(s.disk.free)}</b></div>` : ''}</div>
      ${s.by_axis.map((rows, i) => `<div class="card"><h3>${esc(s.axes[i])}</h3>${bars(rows)}</div>`).join('')}
      <div class="card"><h3>출처</h3>${bars(s.by_source, r => src[r.source] || r.source)}</div>
      <div class="card"><h3>감시 계정</h3>${bars(s.by_watch, r => '@' + r.name)}</div>`;
  } catch (e) { fail(e); }
}

// ───── live updates ─────
function connectWS() {
  const ws = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
  ws.onmessage = ev => {
    const m = JSON.parse(ev.data);
    if (['queued', 'status', 'progress', 'metadata', 'deleted', 'cleared'].includes(m.type) && state.tab === 'downloads') {
      const d = state.downloads.find(x => x.id === m.id);
      if (d && m.type !== 'queued' && m.type !== 'deleted') { Object.assign(d, m.type === 'progress' ? { progress: m.progress } : m); renderDownloads(); }
      else loadDownloads();
    }
    if (m.type === 'categories') loadCats().then(() => { renderFilters(); renderDlCats(); });
  };
  ws.onclose = () => setTimeout(connectWS, 3000);
}

async function boot() {
  try { await loadCats(); } catch { return; }
  $('#app').classList.remove('hidden');
  renderDlCats();
  connectWS();
  const p = new URLSearchParams(location.search);
  if (p.get('url')) { $('#urlInput').value = p.get('url'); setTab('downloads'); return; }
  const tab = location.hash.slice(1);
  setTab(['library', 'feed', 'downloads', 'watch', 'settings', 'stats'].includes(tab) ? tab : 'library');
}
(async () => {
  const r = await fetch('/api/auth/check', { credentials: 'same-origin' }).then(r => r.json()).catch(() => ({}));
  r.authenticated ? boot() : showLogin();
})();
