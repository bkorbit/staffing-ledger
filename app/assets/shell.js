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

// Monthly bars: two stacked meanings on one axis — past (invoiced) and forward
// (planned GP) — drawn as one bar per month in its own colour.
export function barChart(el, labels, series) {
  const W = 940, H = 220, P = { l: 68, r: 10, t: 14, b: 26 };
  const totals = labels.map((_, i) => series.reduce((s, sr) => s + (sr.values[i] || 0), 0));
  const max = Math.max(...totals, 1);
  const bw = (W - P.l - P.r) / labels.length;
  const y = v => P.t + (H - P.t - P.b) * (1 - v / max);
  const ticks = 4;
  const grid = Array.from({ length: ticks + 1 }, (_, i) => {
    const v = max * i / ticks;
    return `<line x1="${P.l}" y1="${y(v)}" x2="${W - P.r}" y2="${y(v)}" stroke="var(--line)"/>
      <text x="${P.l - 6}" y="${y(v) + 4}" fill="#67706d" font-size="10" font-family="IBM Plex Mono" text-anchor="end">${fmt$(v)}</text>`;
  }).join('');
  const bars = labels.map((_, i) => {
    let acc = 0;
    return series.map(sr => {
      const v = sr.values[i] || 0; if (!v) return '';
      const y1 = y(acc + v), h = y(acc) - y(acc + v); acc += v;
      return `<rect x="${P.l + i * bw + bw * 0.15}" y="${y1}" width="${bw * 0.7}" height="${h}" fill="${sr.color}"/>`;
    }).join('');
  }).join('');
  const xl = labels.map((l, i) => i % 2 ? '' :
    `<text x="${P.l + i * bw + bw / 2}" y="${H - 8}" fill="#67706d" font-size="10" font-family="IBM Plex Mono" text-anchor="middle">${l}</text>`).join('');
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
export function donutChart(el, slices, size = 176) {
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
