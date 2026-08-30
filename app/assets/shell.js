// The platform shell, in the old tool's shape: one header, one tab bar, everything
// inside. Every page imports boot() and hands it a main(supa, el) to run once a
// session exists. The shell owns what no page should reimplement: the Supabase
// client, the login gate, the tabs, and the formatting helpers.

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

export const supa = createClient(
  'https://zytmlowigbfchfqcilrr.supabase.co',
  'sb_publishable_0kcl48Yn5YsoTB0zrK-Rsg_c76JTGvR'
);

export const fmt$ = c => '$' + (c / 100).toLocaleString(undefined, { maximumFractionDigits: 0 });
export const esc = s => String(s ?? '').replace(/[&<>"']/g,
  c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));

// Every page's "search…" box wires oninput straight to a function that
// rebuilds a container's whole innerHTML — including the input itself. The
// browser never carries focus over to a freshly created element, so typing
// a single character unfocused the box and every keystroke after it went
// nowhere. Capture the cursor position before the rebuild, find the new
// element by the same selector after, and put focus (and the cursor) back.
// onInput may return a value to await (a page whose re-render is itself
// async) or nothing (a plain synchronous render).
export function wireSearch(container, selector, onInput) {
  const input = container.querySelector(selector);
  input.oninput = async e => {
    const pos = e.target.selectionStart;
    await onInput(e.target.value);
    const fresh = container.querySelector(selector);
    if (!fresh) return;
    fresh.focus();
    fresh.setSelectionRange(pos, pos);
  };
}

// Supabase caps every response at 1000 rows SERVER-side — .limit() cannot exceed
// it. Anything that can outgrow a thousand rows must page. Pages arrive in
// parallel waves that double (4, then 8, then 16 …) rather than one at a time.
export async function fetchAll(build) {
  const page = 1000;
  const one = async i => build().range(i * page, (i + 1) * page - 1);
  const first = await one(0);
  if (first.error) return first;
  const out = [...(first.data || [])];
  if (out.length < page) return { data: out, error: null };
  for (let start = 1, wave = 4; ; start += wave, wave *= 2) {
    const results = await Promise.all(
      Array.from({ length: wave }, (_, k) => one(start + k)));
    let done = false;
    for (const r of results) {
      if (r.error) return { data: out, error: r.error };
      out.push(...(r.data || []));
      if ((r.data || []).length < page) { done = true; break; }
    }
    if (done) return { data: out, error: null };
  }
}

// This page's own cache-bust stamp (the ?v=<short-sha> on its shell.js import,
// per CLAUDE.md habit #5) — compared against the live repo's latest app/
// commit so a stale stamp (the thing that's bitten us before) is visible
// instead of silently serving an old cached shell/page.
const loadedVer = (() => {
  try { return new URL(import.meta.url).searchParams.get('v') || ''; }
  catch { return ''; }
})();

// Viewer's own local time zone (unlike scripts/stamp.mjs's UTC build id,
// which has to line up with UTC-timestamped CI logs) — this is a plain
// "when", read by whoever's looking at it, so it should read in their zone.
const fmtLocal = iso => {
  const d = new Date(iso);
  return `${d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' })} ` +
    d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit', timeZoneName: 'short' });
};

// Live-repo timestamp for the nav footer: the latest commit that touched
// app/ on main, fetched from the public GitHub API and cached for 5 minutes
// (60 unauthenticated requests/hour is easy to burn through across ~50 staff
// otherwise). Falls back to a stale cache, then hides itself, rather than
// ever blocking or erroring the shell.
const VER_CACHE_KEY = 'live_ver_cache';
const VER_CACHE_MS = 5 * 60 * 1000;

async function loadVerTag(el) {
  const render = (sha, date) => {
    // loadedVer empty (no ?v= on this import) means we can't tell either way —
    // stay neutral rather than claiming "fresh" without evidence.
    const known = !!loadedVer;
    const stale = known && !sha.startsWith(loadedVer);
    el.textContent = `live ${fmtLocal(date)}${stale ? ' · reload for latest' : ''}`;
    el.classList.toggle('stale', stale);
    el.classList.toggle('fresh', known && !stale);
    el.href = `https://github.com/bkorbit/staffing-ledger/commit/${sha}`;
  };
  const cached = JSON.parse(localStorage.getItem(VER_CACHE_KEY) || 'null');
  if (cached && Date.now() - cached.at < VER_CACHE_MS) { render(cached.sha, cached.date); return; }
  try {
    const res = await fetch('https://api.github.com/repos/bkorbit/staffing-ledger/commits?path=app&sha=main&per_page=1');
    if (!res.ok) throw new Error(String(res.status));
    const [commit] = await res.json();
    const sha = commit.sha, date = commit.commit.committer.date;
    localStorage.setItem(VER_CACHE_KEY, JSON.stringify({ sha, date, at: Date.now() }));
    render(sha, date);
  } catch {
    if (cached) render(cached.sha, cached.date);
    else el.remove();
  }
}

// Sidebar navigation, grouped by domain. `soon` marks honest placeholders.
const NAV = [
  { sect: 'Overview' },
  { id: 'home',      label: 'Home',            href: './index.html' },
  { id: 'forecast',  label: 'Forecast',        href: './forecast.html' },
  { id: 'cashflow',  label: 'Cashflow',        href: './cashflow.html' },
  { sect: 'Revenue' },
  { id: 'sales',     label: 'Sales Forecast',  href: './sales.html' },
  { id: 'scoping',   label: 'Scoping',         href: './scoping.html', soon: true },
  { sect: 'Delivery' },
  { id: 'hourplan',  label: 'Hour Planning',   href: './hour-planning.html', soon: true },
  { id: 'clientprofit', label: 'Client Profitability', href: './client-profitability.html' },
  { id: 'projhours', label: 'Project Hours',   href: './project-hours.html' },
  { id: 'teamhours', label: 'Team Hours',      href: './team-hours.html' },
  { sect: 'Setup' },
  { id: 'clients',   label: 'Clients',         href: './clients.html' },
  { id: 'team',      label: 'Team',            href: './team.html' },
  { id: 'settings',  label: 'Settings',        href: './settings.html' },
];

// One glyph per nav id, shown only in the collapsed rail (nav.side .icon is
// display:none until .layout.nav-collapsed) — the expanded rail reads by
// label text same as before. Plain stroke lines so currentColor picks up
// the item's own text colour (default / hover / current all keep working).
const NAV_ICON_ATTRS = 'viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"';
const NAV_ICONS = {
  home: `<path d="M3 9.5 10 3l7 6.5"/><path d="M5 8.5V17h10V8.5"/><path d="M8 17v-5h4v5"/>`,
  forecast: `<path d="M3 15 8 10l3 3 6-7"/><path d="M13 6h4v4"/>`,
  cashflow: `<path d="M8 3.5c0 1-.8 1.8-1.8 2.6C4.8 7.4 3.5 9.4 3.5 12a6.5 6.5 0 0 0 13 0c0-2.6-1.3-4.6-2.7-5.9C12.8 5.3 12 4.5 12 3.5"/><path d="M8 3.5h4"/><path d="M10 9v6M8.5 10.3c0-.7.7-1.3 1.5-1.3s1.5.5 1.5 1.1c0 1.6-3 1-3 2.6 0 .6.7 1.1 1.5 1.1s1.5-.5 1.5-1.1"/>`,
  sales: `<path d="M3.5 4h13l-5 6.5v4.5l-3 1.5v-6L3.5 4Z"/>`,
  scoping: `<rect x="4.6" y="4.6" width="3.6" height="6" rx="1.2"/><rect x="11.8" y="4.6" width="3.6" height="6" rx="1.2"/><path d="M8.2 6.3h3.6"/><circle cx="6.4" cy="13" r="3"/><circle cx="13.6" cy="13" r="3"/>`,
  hourplan: `<circle cx="10" cy="10.5" r="7"/><path d="M10 6.5V11l3 2"/><path d="M8 2.5h4"/>`,
  clientprofit: `<path d="M8.5 3.5c0 1-.7 1.7-1.6 2.4C5.3 7 4.2 8.8 4.2 11.2a5.8 5.8 0 0 0 11.6 0c0-2.4-1.1-4.2-2.7-5.3-.9-.7-1.6-1.4-1.6-2.4"/><path d="M8.5 3.5h3"/><path d="M1 8 3.6 9.6 1 11.2"/><path d="M19 8l-2.6 1.6L19 11.2"/>`,
  projhours: `<path d="M2.5 6a1 1 0 0 1 1-1h3.6l1.2 1.5H16a1 1 0 0 1 1 1V15a1 1 0 0 1-1 1H3.5a1 1 0 0 1-1-1V6Z"/><circle cx="13.3" cy="13" r="3.1"/><path d="M13.3 11.2v1.8l1.4 1.1"/>`,
  teamhours: `<circle cx="10" cy="6.5" r="3"/><path d="M4 17c0-3.3 2.7-5.5 6-5.5s6 2.2 6 5.5"/>`,
  clients: `<rect x="3" y="7" width="14" height="9" rx="1.5"/><path d="M7.5 7V5.5a1.5 1.5 0 0 1 1.5-1.5h2a1.5 1.5 0 0 1 1.5 1.5V7"/><path d="M3 11h14"/>`,
  team: `<circle cx="7" cy="6.5" r="2.3"/><circle cx="14" cy="7.5" r="2"/><path d="M2.5 16c0-2.8 2-4.7 4.5-4.7s4.5 1.9 4.5 4.7"/><path d="M12.5 12.2c2 .2 3.5 1.8 3.5 3.8"/>`,
  settings: `<circle cx="10" cy="10" r="3"/>${[0,45,90,135,180,225,270,315].map(a =>
    `<rect x="9.25" y="4.8" width="1.5" height="2.4" rx="0.3" fill="currentColor" stroke="none" transform="rotate(${a} 10 10)"/>`).join('')}`,
};

// Team Hours' opening range still costs a real round trip even after
// db/057-064 trimmed it down (~150ms warm). Hovering its nav link is a
// strong signal of an imminent click with real dwell time before the
// actual navigation — firing the same two calls then and handing the
// result to the fresh page via sessionStorage (survives the full page
// load a plain <a href> does; a JS variable would not) means the click
// that follows often finds its data already sitting there. A click that
// beats the prefetch there just falls through to team-hours.html's own
// normal fetch, no worse than today. Scoped to this one page rather than
// a generic per-page prefetch hook — nothing else has asked to be faster.
let teamHoursPrefetchStarted = false;
function prefetchTeamHours() {
  if (teamHoursPrefetchStarted) return;
  teamHoursPrefetchStarted = true;
  const todayIso = new Date().toISOString().slice(0, 10);
  const monthStart = todayIso.slice(0, 7) + '-01';
  const [y, m] = monthStart.slice(0, 7).split('-').map(Number);
  const monthEnd = new Date(Date.UTC(y, m, 0)).toISOString().slice(0, 10);
  Promise.all([
    supa.rpc('hours_page', { p_from: monthStart, p_to: monthEnd }),
    supa.rpc('rev_proj_page', { p_from: monthStart, p_to: monthStart }),
  ]).then(([hp, rp]) => {
    if (hp.error || rp.error) return;
    sessionStorage.setItem(`th-prefetch:${monthStart}|${monthStart}`,
      JSON.stringify({ H: hp.data, RP: rp.data, at: Date.now() }));
  }).catch(() => {});
}

function renderShell(current) {
  document.body.innerHTML = `
    <div class="layout ${localStorage.getItem('nav_collapsed')==='1'?'nav-collapsed':''}">
      <nav class="side">
        <div class="brand">
          <button class="navtoggle" id="navtoggle" title="collapse / expand">☰</button>
          <div class="brandwords">
            <div class="eyebrow">STAFFING &amp; PROFITABILITY</div>
            <div class="brand-name">EMG Ledger</div>
          </div>
        </div>
        ${NAV.map(n => n.sect
          ? `<div class="sect">${n.sect}</div>`
          : `<a class="item ${n.id === current ? 'current' : ''}" href="${n.href}">
               <span class="icon"><svg ${NAV_ICON_ATTRS}>${NAV_ICONS[n.id] || ''}</svg></span>
               <span class="lbl">${n.label}</span>${n.soon ? '<span class="soon">soon</span>' : ''}</a>`).join('')}
        <div class="side-foot">
          <div class="who">${esc(window.__email || '')}</div>
          <button class="ghost" id="signout">Sign out</button>
          <a class="ver-tag" id="ver-tag" href="https://github.com/bkorbit/staffing-ledger" target="_blank" rel="noopener">checking live version…</a>
        </div>
      </nav>
      <main class="content" id="content"></main>
    </div>`;
  document.getElementById('signout').onclick = async () => {
    await supa.auth.signOut(); location.reload();
  };
  document.getElementById('navtoggle').onclick = () => {
    const layout = document.querySelector('.layout');
    const now = layout.classList.toggle('nav-collapsed');
    localStorage.setItem('nav_collapsed', now ? '1' : '0');
  };
  if (current !== 'teamhours') {
    document.querySelector('a.item[href="./team-hours.html"]')
      ?.addEventListener('pointerenter', prefetchTeamHours, { once: true });
  }
  loadVerTag(document.getElementById('ver-tag'));
}

function renderLogin(onDone) {
  document.body.innerHTML = `
    <div id="login">
      <div class="eyebrow">STAFFING &amp; PROFITABILITY</div>
      <h1>EMG Ledger</h1>
      <p class="sub">Sign in.</p>
      <div class="col">
        <input id="email" type="email" placeholder="email" autocomplete="username">
        <input id="password" type="password" placeholder="password" autocomplete="current-password">
        <button id="signin" class="primary">Sign in</button>
        <div id="loginmsg" class="err"></div>
      </div>
    </div>`;
  document.getElementById('signin').onclick = async () => {
    const { error } = await supa.auth.signInWithPassword({
      email: document.getElementById('email').value.trim(),
      password: document.getElementById('password').value
    });
    if (error) { document.getElementById('loginmsg').textContent = error.message; return; }
    onDone();
  };
}

export async function boot(pageId, main) {
  const { data: { session } } = await supa.auth.getSession();
  if (!session) { renderLogin(() => boot(pageId, main)); return; }
  window.__email = session.user?.email || 'app';
  renderShell(pageId);
  try {
    await main(supa, document.getElementById('content'));
  } catch (e) {
    document.getElementById('content').innerHTML =
      `<div class="sc-panel err">${esc(e.message || e)}</div>`;
  }
}

// A single click-to-open popover (a lone .editpop instance per trigger,
// appended to document.body so a panel re-render never touches it) —
// originated on Home for its own range control and every copied panel's
// "Settings" button, promoted here once Client Profitability needed the
// exact same pattern rather than a second copy of it.
export function makePopover(trigger, innerHTML) {
  const pop = document.createElement('div');
  pop.className = 'editpop';
  pop.hidden = true;
  pop.innerHTML = innerHTML;
  document.body.appendChild(pop);
  const onOutsideClick = e => { if (!pop.contains(e.target) && e.target !== trigger) close(); };
  const onKey = e => { if (e.key === 'Escape') close(); };
  function close() {
    pop.hidden = true;
    document.removeEventListener('mousedown', onOutsideClick, true);
    document.removeEventListener('keydown', onKey, true);
    window.removeEventListener('scroll', close, true);
  }
  function open() {
    pop.hidden = false;
    const r = trigger.getBoundingClientRect();
    const top = Math.max(8, Math.min(r.bottom + 6, window.innerHeight - pop.offsetHeight - 8));
    // right-aligned to the trigger when the trigger sits on the right of its
    // row (every "Settings" button here) rather than left-aligned like a
    // dropdown, so the menu never overhangs the viewport's right edge
    const left = Math.max(8, Math.min(r.right - pop.offsetWidth, window.innerWidth - pop.offsetWidth - 8));
    pop.style.top = top + 'px'; pop.style.left = left + 'px';
    document.addEventListener('mousedown', onOutsideClick, true);
    document.addEventListener('keydown', onKey, true);
    window.addEventListener('scroll', close, true);
  }
  trigger.onclick = () => pop.hidden ? open() : close();
  return { pop, open, close };
}

// Monthly bars: two stacked meanings on one axis — past (invoiced) and forward
// (planned GP) — drawn as one bar per month in its own colour.
// opts lets a call site with many dense columns (Home's weekly-by-project
// chart) ask for narrower bars and a smaller axis label than the default —
// every other caller omits opts and renders exactly as before.
export function barChart(el, labels, series, opts) {
  // valueFmt lets a non-money bar chart (Home's hours-based charts) label
  // its own axis correctly — every caller before that one was money, so the
  // default keeps fmt$ rather than making every existing call site pass it.
  const { barWidth = 0.7, labelSize = 10, valueFmt = fmt$ } = opts || {};
  // H matches bandChart's own 940x240 exactly — every chart in the app now
  // shares one aspect ratio, so a row of equal-width panels renders at equal
  // heights instead of each chart's own ratio deciding its panel's height.
  const W = 940, H = 240, P = { l: 68, r: 10, t: 14, b: 26 };
  const totals = labels.map((_, i) => series.reduce((s, sr) => s + (sr.values[i] || 0), 0));
  const max = Math.max(...totals, 1);
  const bw = (W - P.l - P.r) / labels.length;
  const y = v => P.t + (H - P.t - P.b) * (1 - v / max);
  const ticks = 4;
  const grid = Array.from({ length: ticks + 1 }, (_, i) => {
    const v = max * i / ticks;
    return `<line x1="${P.l}" y1="${y(v)}" x2="${W - P.r}" y2="${y(v)}" stroke="var(--line)"/>
      <text x="${P.l - 6}" y="${y(v) + 4}" fill="#67706d" font-size="10" font-family="IBM Plex Mono" text-anchor="end">${valueFmt(v)}</text>`;
  }).join('');
  const bars = labels.map((_, i) => {
    let acc = 0;
    return series.map(sr => {
      const v = sr.values[i] || 0; if (!v) return '';
      const y1 = y(acc + v), h = y(acc) - y(acc + v); acc += v;
      return `<rect x="${P.l + i * bw + bw * (1 - barWidth) / 2}" y="${y1}" width="${bw * barWidth}" height="${h}" fill="${sr.color}"/>`;
    }).join('');
  }).join('');
  // skipping every other label only earns its keep once there are enough
  // columns to actually crowd each other (13 weeks did; 3-5 departments
  // never did — skipping there just silently dropped half the names)
  const skip = labels.length > 10;
  const xl = labels.map((l, i) => skip && i % 2 ? '' :
    `<text x="${P.l + i * bw + bw / 2}" y="${H - 8}" fill="#67706d" font-size="${labelSize}" font-family="IBM Plex Mono" text-anchor="middle">${l}</text>`).join('');
  // legend lives in the shared grey chart-legend footer below the SVG, not
  // drawn inline — the app-wide standard established on sales.html
  const legend = series.map(sr =>
    `<span class="lg-item"><i class="lg-dot" style="background:${sr.color}"></i>${esc(sr.name)}</span>`).join('');
  el.innerHTML = `<svg class="chart" viewBox="0 0 ${W} ${H}">${grid}${bars}${xl}</svg>
    <div class="chart-legend">${legend}</div>`;
}

// condensed money, for axis labels that don't have room to spell out the
// full number: $250,000 -> $250k, $1,750,000 -> $1.8MM.
const fmtCondensed = c => {
  const d = c / 100, a = Math.abs(d), sign = d < 0 ? '-' : '';
  if (a >= 1e6) return `${sign}$${(a / 1e6).toFixed(1)}MM`;
  if (a >= 1e3) return `${sign}$${Math.round(a / 1e3)}k`;
  return `${sign}$${Math.round(a)}`;
};

// A light-theme SVG band chart. bands = [{name,color,values}]. Hoverable: the
// nearest period's crosshair and a tooltip with every band's exact value.
// Each period is also its own tabindex="0" focus stop (mirroring forecast.html's
// combo chart), so the same breakdown is reachable by keyboard, not just
// mouse/touch.
export function bandChart(el, labels, bands) {
  const W = 940, H = 240, P = { l: 60, r: 10, t: 14, b: 24 };
  const all = bands.flatMap(b => b.values);
  // bounds snap to $250k, gridlines every $500k ($1M past 13 lines) — the same
  // axis rule the Forecast chart uses, values here are cents
  const SNAP = 25000000;
  const rawMin = Math.min(0, ...all), rawMax = Math.max(0, ...all);
  const min = Math.floor(rawMin / SNAP) * SNAP;
  const max = Math.max(Math.ceil(rawMax / SNAP) * SNAP, min + SNAP);
  const x = i => P.l + (W - P.l - P.r) * (labels.length === 1 ? 0.5 : i / (labels.length - 1));
  const y = v => P.t + (H - P.t - P.b) * (1 - (v - min) / ((max - min) || 1));
  let step = 50000000;
  if ((max - min) / step > 13) step = 100000000;
  let grid = '';
  // the `|| 0` guards against a -0 tick (e.g. Math.ceil(-0.5) is -0 in JS) —
  // without it a gridline that lands exactly on zero prints "$-0"
  for (let v = (Math.ceil(min / step) * step) || 0; v <= max; v += step) {
    grid += `<line x1="${P.l}" y1="${y(v)}" x2="${W - P.r}" y2="${y(v)}" stroke="var(--line)"/>
      <text x="${P.l - 6}" y="${y(v) + 4}" fill="var(--slate)" font-size="10" font-family="IBM Plex Mono" text-anchor="end">${fmtCondensed(v)}</text>`;
  }
  const zero = (min < 0 && max > 0)
    ? `<line x1="${P.l}" y1="${y(0)}" x2="${W - P.r}" y2="${y(0)}" stroke="var(--rust)" stroke-dasharray="4 3"/>` : '';
  // Catmull-Rom -> cubic Bezier: an interpolating spline that still passes
  // through every real data point, so the curve reads smoother without
  // bending what the numbers actually say.
  const smoothPath = pts => {
    if (pts.length < 2) return '';
    if (pts.length === 2) return `M${pts[0][0]},${pts[0][1]} L${pts[1][0]},${pts[1][1]}`;
    let d = `M${pts[0][0]},${pts[0][1]}`;
    for (let i = 0; i < pts.length - 1; i++) {
      const p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || p2;
      const c1x = p1[0] + (p2[0] - p0[0]) / 6, c1y = p1[1] + (p2[1] - p0[1]) / 6;
      const c2x = p2[0] - (p3[0] - p1[0]) / 6, c2y = p2[1] - (p3[1] - p1[1]) / 6;
      d += ` C${c1x},${c1y} ${c2x},${c2y} ${p2[0]},${p2[1]}`;
    }
    return d;
  };
  const lines = bands.map(b =>
    `<path fill="none" stroke="${b.color}" stroke-width="2"
       d="${smoothPath(b.values.map((v, i) => [x(i), y(v)]))}"/>`).join('');
  const xlabels = labels.map((l, i) => i % 2 ? '' :
    `<text x="${x(i)}" y="${H - 6}" fill="var(--slate)" font-size="10" font-family="IBM Plex Mono" text-anchor="middle">${l}</text>`).join('');
  // one plain-text summary per period, shared by the keyboard focus label
  // and the mouse/touch tooltip below — same pattern as the combo chart
  const periodSummary = idx => `${labels[idx]}: ` +
    bands.map(b => `${b.name} ${fmt$(b.values[idx])}`).join(', ');
  // an invisible full-height hit target per period — real focus stops, not
  // decorative, so Tab reaches every period in the same left-to-right order
  // a mouse sweep would
  const stepX = labels.length > 1 ? (W - P.l - P.r) / (labels.length - 1) : (W - P.l - P.r);
  const cols = labels.map((l, i) => {
    const left = Math.max(P.l, x(i) - stepX / 2), right = Math.min(W - P.r, x(i) + stepX / 2);
    return `<rect x="${left}" y="${P.t}" width="${right - left}" height="${H - P.t - P.b}"
      fill="transparent" tabindex="0" role="img" aria-label="${esc(periodSummary(i))}" class="bandcol" data-idx="${i}"/>`;
  }).join('');
  // legend lives in the shared grey chart-legend footer below the SVG, not
  // drawn inline — the app-wide standard established on sales.html
  const legend = bands.map(b =>
    `<span class="lg-item"><i class="lg-dot" style="background:${b.color}"></i>${esc(b.name)}</span>`).join('');
  const summary = `Line chart of ${bands.map(b => b.name).join(', ')} across ${labels.length} `
    + `periods, from ${labels[0]} to ${labels[labels.length - 1]}.`;
  el.style.position = 'relative';
  el.innerHTML = `<svg class="chart" role="img" aria-label="${esc(summary)}" viewBox="0 0 ${W} ${H}">
    <title>${esc(summary)}</title>
    ${grid}${zero}${lines}<g class="hoverlayer"></g>${xlabels}${cols}</svg>
    <div class="chart-tip"></div>
    <div class="chart-legend">${legend}</div>`;

  // ---- hover/focus: nearest-period crosshair, highlighted points, and a
  // tooltip with every band's exact value (the axis itself only has room to
  // condense). Mouse/touch look up the period from cursor position; keyboard
  // focus on a .bandcol already knows its own index.
  const svg = el.querySelector('svg'), hoverLayer = el.querySelector('.hoverlayer'), tip = el.querySelector('.chart-tip');
  const renderAt = idx => {
    const cx = x(idx);
    hoverLayer.innerHTML = `<line x1="${cx}" y1="${P.t}" x2="${cx}" y2="${H - P.b}" stroke="var(--slate)" stroke-dasharray="2 3"/>` +
      bands.map(b => `<circle cx="${cx}" cy="${y(b.values[idx])}" r="4" fill="${b.color}" stroke="var(--paper-raised)" stroke-width="1.5"/>`).join('');
    tip.innerHTML = `<div class="tip-label">${esc(labels[idx])}</div>` +
      bands.map(b => `<div class="tip-row"><span class="tip-dot" style="background:${b.color}"></span>${esc(b.name)} <b>${fmt$(b.values[idx])}</b></div>`).join('');
    tip.style.opacity = '1';
  };
  const positionNear = (clientX, clientY) => {
    const svgBox = el.getBoundingClientRect();
    tip.style.top = (clientY - svgBox.top - 10) + 'px';
    // clamp so the tooltip can't poke past the chart's own left/right edge
    const left = Math.min(svgBox.width - tip.offsetWidth, Math.max(0, clientX - svgBox.left + 12));
    tip.style.left = left + 'px';
  };
  const idxAtClientX = clientX => {
    const svgBox = el.getBoundingClientRect();
    const scale = W / svgBox.width;
    const vx = (clientX - svgBox.left) * scale;
    const step = labels.length > 1 ? (W - P.l - P.r) / (labels.length - 1) : 0;
    let idx = step ? Math.round((vx - P.l) / step) : 0;
    return Math.max(0, Math.min(labels.length - 1, idx));
  };
  const showAt = (clientX, clientY) => { renderAt(idxAtClientX(clientX)); positionNear(clientX, clientY); };
  const hide = () => { tip.style.opacity = '0'; hoverLayer.innerHTML = ''; };
  svg.onmousemove = e => showAt(e.clientX, e.clientY);
  svg.onmouseleave = hide;
  svg.ontouchstart = svg.ontouchmove = e => { if (e.touches[0]) showAt(e.touches[0].clientX, e.touches[0].clientY); };
  svg.ontouchend = hide;
  el.querySelectorAll('.bandcol').forEach(colEl => {
    const idx = +colEl.dataset.idx;
    colEl.onfocus = () => {
      renderAt(idx);
      const r = colEl.getBoundingClientRect();
      positionNear(r.left + r.width / 2, r.top);
    };
    colEl.onblur = hide;
  });
}

// A single flat ring for "what share of X is this" — slices = [{name,color,value}].
// Stroke-dasharray/-dashoffset rings, not wedge paths: flat by rule (no depth
// cue needed), and the segment math stays simple percentage-of-circumference
// arithmetic instead of trig for arc endpoints. Legend below carries the exact
// percentage per slice since the ring itself only has room for the biggest.
export function donutChart(el, slices, size = 208) {
  const cx = size / 2, cy = size / 2, r = size * 0.365, sw = size * 0.135;
  const circumference = 2 * Math.PI * r;
  const total = slices.reduce((s, x) => s + Math.max(x.value, 0), 0);
  const pct = v => total > 0 ? Math.round(v / total * 100) : 0;
  let acc = 0;
  const rings = total <= 0
    ? `<circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="var(--line)" stroke-width="${sw}"/>`
    : slices.filter(s => s.value > 0).map(s => {
        const dash = s.value / total * circumference;
        const el = `<circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="${s.color}" stroke-width="${sw}"
          stroke-dasharray="${dash} ${circumference - dash}" stroke-dashoffset="${-acc}"
          transform="rotate(-90 ${cx} ${cy})"><title>${esc(s.name)}: ${pct(s.value)}%</title></circle>`;
        acc += dash; return el;
      }).join('');
  const legend = slices.map(s =>
    `<span class="lg-item"><i class="lg-dot" style="background:${s.color}"></i>${esc(s.name)} <b>${pct(s.value)}%</b></span>`).join('');
  el.innerHTML = `<svg class="chart" viewBox="0 0 ${size} ${size}" style="max-width:${size}px;margin:0 auto;display:block">${rings}</svg>
    <div class="chart-legend" style="justify-content:center;border-top:none;background:none;padding:10px 0 0">${legend}</div>`;
}
