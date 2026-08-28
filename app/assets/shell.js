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

// One tab per module, old-app style. `soon` renders the tab with a soon tag; the
// page behind it is an honest placeholder, so the map stays truthful.
const TABS = [
  { id: 'home',      label: 'Home',            href: './index.html' },
  { id: 'forecast',  label: 'Forecast',        href: './forecast.html' },
  { id: 'cashflow',  label: 'Cashflow',        href: './cashflow.html' },
  { id: 'sales',     label: 'Sales Forecast',  href: './sales.html' },
  { id: 'deals',     label: 'Deals',           href: './deals.html' },
  { id: 'scoping',   label: 'Scoping',         href: './scoping.html', soon: true },
  { id: 'hourplan',  label: 'Hour Planning',   href: './hour-planning.html', soon: true },
  { id: 'hourrep',   label: 'Hours Reporting', href: './hours-reporting.html', soon: true },
  { id: 'depts',     label: 'Departments',     href: './departments.html', soon: true },
  { id: 'people',    label: 'People',          href: './people.html', soon: true },
  { id: 'clients',   label: 'Clients',         href: './clients.html' },
  { id: 'settings',  label: 'Settings',        href: './settings.html' },
];

function renderShell(current) {
  document.body.innerHTML = `
    <div class="app">
      <header class="top">
        <div>
          <div class="eyebrow">STAFFING &amp; PROFITABILITY</div>
          <h1>EMG Ledger</h1>
        </div>
        <div class="header-actions">
          <span class="who">${esc(window.__email || '')}</span>
          <button class="ghost" id="signout">Sign out</button>
        </div>
      </header>
      <nav class="tab-bar">
        ${TABS.map(t => `<a class="tab-btn ${t.id === current ? 'active' : ''}" href="${t.href}">
            ${t.label}${t.soon ? '<span class="tab-soon">SOON</span>' : ''}</a>`).join('')}
      </nav>
      <main id="content"></main>
    </div>`;
  document.getElementById('signout').onclick = async () => {
    await supa.auth.signOut(); location.reload();
  };
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

// A light-theme SVG band chart. bands = [{name,color,values}].
export function bandChart(el, labels, bands) {
  const W = 940, H = 240, P = { l: 68, r: 10, t: 14, b: 24 };
  const all = bands.flatMap(b => b.values);
  const min = Math.min(...all, 0), max = Math.max(...all, 0);
  const x = i => P.l + (W - P.l - P.r) * (labels.length === 1 ? 0.5 : i / (labels.length - 1));
  const y = v => P.t + (H - P.t - P.b) * (1 - (v - min) / ((max - min) || 1));
  const ticks = 4;
  const grid = Array.from({ length: ticks + 1 }, (_, i) => {
    const v = min + (max - min) * i / ticks;
    return `<line x1="${P.l}" y1="${y(v)}" x2="${W - P.r}" y2="${y(v)}" stroke="#e2e2e2"/>
      <text x="${P.l - 6}" y="${y(v) + 4}" fill="#67706d" font-size="10" font-family="DM Mono" text-anchor="end">${fmt$(v)}</text>`;
  }).join('');
  const zero = (min < 0 && max > 0)
    ? `<line x1="${P.l}" y1="${y(0)}" x2="${W - P.r}" y2="${y(0)}" stroke="#d1453b" stroke-dasharray="4 3"/>` : '';
  const lines = bands.map(b =>
    `<polyline fill="none" stroke="${b.color}" stroke-width="2"
       points="${b.values.map((v, i) => x(i) + ',' + y(v)).join(' ')}"/>`).join('');
  const xlabels = labels.map((l, i) => i % 2 ? '' :
    `<text x="${x(i)}" y="${H - 6}" fill="#67706d" font-size="10" font-family="DM Mono" text-anchor="middle">${l}</text>`).join('');
  const legend = bands.map((b, i) =>
    `<rect x="${P.l + i * 200}" y="0" width="10" height="10" fill="${b.color}"/>
     <text x="${P.l + i * 200 + 14}" y="9" fill="#67706d" font-size="11" font-family="DM Mono">${b.name}</text>`).join('');
  el.innerHTML = `<svg class="chart" viewBox="0 0 ${W} ${H + 16}">
    <g transform="translate(0,14)">${grid}${zero}${lines}${xlabels}</g>${legend}</svg>`;
}
