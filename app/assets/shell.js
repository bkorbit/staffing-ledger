// The platform shell. Every page imports boot() and hands it a main(supa) to run
// once a session exists. The shell owns the things no page should reimplement:
// the Supabase client, the login gate, the navigation, and the formatting helpers.

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

export const supa = createClient(
  'https://zytmlowigbfchfqcilrr.supabase.co',
  'sb_publishable_0kcl48Yn5YsoTB0zrK-Rsg_c76JTGvR'
);

export const fmt$ = c => '$' + (c / 100).toLocaleString(undefined, { maximumFractionDigits: 0 });
export const esc = s => String(s ?? '').replace(/[&<>"']/g,
  c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));

// Navigation is data, so adding a module is one line. `soon` renders a placeholder
// badge; `ext` links out to the standalone pages until they are folded in.
const NAV = [
  { sect: 'Overview' },
  { id: 'home',      label: 'Home',            href: './index.html' },
  { id: 'forecast',  label: 'Forecast',        href: './forecast.html' },
  { id: 'cashflow',  label: 'Cashflow',        href: './cashflow.html' },
  { sect: 'Revenue' },
  { id: 'sales',     label: 'Sales Forecast',  href: './sales.html' },
  { id: 'deals',     label: 'Deals',           href: '../deals-shaping.html', ext: true },
  { id: 'scoping',   label: 'Scoping',         href: './scoping.html', soon: true },
  { sect: 'Delivery' },
  { id: 'hourplan',  label: 'Hour Planning',   href: './hour-planning.html', soon: true },
  { id: 'hourrep',   label: 'Hours Reporting', href: './hours-reporting.html', soon: true },
  { id: 'depts',     label: 'Departments',     href: './departments.html', soon: true },
  { id: 'people',    label: 'People',          href: './people.html', soon: true },
  { sect: 'Setup' },
  { id: 'clients',   label: 'Client Matching', href: '../settings-clients.html', ext: true },
  { id: 'settings',  label: 'Settings',        href: './settings.html' },
];

function renderShell(current) {
  document.body.innerHTML = `
    <div class="layout">
      <nav class="side">
        <div class="brand">EMG Ledger</div>
        ${NAV.map(n => n.sect
          ? `<div class="sect">${n.sect}</div>`
          : `<a class="item ${n.id === current ? 'current' : ''}" href="${n.href}">
               <span>${n.label}</span>
               ${n.soon ? '<span class="soon">soon</span>' : n.ext ? '<span class="ext">↗</span>' : ''}
             </a>`).join('')}
      </nav>
      <main class="content" id="content"></main>
    </div>`;
}

function renderLogin(onDone) {
  document.body.innerHTML = `
    <div id="login" class="card">
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
      `<div class="card err">${esc(e.message || e)}</div>`;
  }
}

// A three-band SVG line chart, sized to its data. bands = [{name,color,values}],
// labels = x labels. No library: this is forty lines and it is ours.
export function bandChart(el, labels, bands) {
  const W = 940, H = 230, P = { l: 64, r: 10, t: 12, b: 24 };
  const all = bands.flatMap(b => b.values);
  const min = Math.min(...all, 0), max = Math.max(...all, 0);
  const x = i => P.l + (W - P.l - P.r) * (labels.length === 1 ? 0.5 : i / (labels.length - 1));
  const y = v => P.t + (H - P.t - P.b) * (1 - (v - min) / ((max - min) || 1));
  const ticks = 4;
  const grid = Array.from({ length: ticks + 1 }, (_, i) => {
    const v = min + (max - min) * i / ticks;
    return `<line x1="${P.l}" y1="${y(v)}" x2="${W - P.r}" y2="${y(v)}" stroke="#2a2f3a" stroke-width="1"/>
      <text x="${P.l - 6}" y="${y(v) + 4}" fill="#8b93a3" font-size="10" text-anchor="end">${fmt$(v)}</text>`;
  }).join('');
  const zero = (min < 0 && max > 0)
    ? `<line x1="${P.l}" y1="${y(0)}" x2="${W - P.r}" y2="${y(0)}" stroke="#d1453b" stroke-dasharray="4 3"/>` : '';
  const lines = bands.map(b =>
    `<polyline fill="none" stroke="${b.color}" stroke-width="2"
       points="${b.values.map((v, i) => x(i) + ',' + y(v)).join(' ')}"/>`).join('');
  const xlabels = labels.map((l, i) => i % 2 ? '' :
    `<text x="${x(i)}" y="${H - 6}" fill="#8b93a3" font-size="10" text-anchor="middle">${l}</text>`).join('');
  const legend = bands.map((b, i) =>
    `<rect x="${P.l + i * 190}" y="0" width="10" height="10" fill="${b.color}"/>
     <text x="${P.l + i * 190 + 14}" y="9" fill="#8b93a3" font-size="11">${b.name}</text>`).join('');
  el.innerHTML = `<svg class="chart" viewBox="0 0 ${W} ${H + 16}">
    <g transform="translate(0,14)">${grid}${zero}${lines}${xlabels}</g>${legend}</svg>`;
}
