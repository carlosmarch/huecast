/* Huecast landing page. Every sky here is drawn with the app's own code
   (palette, conditions, scene), so the page always matches the app. */

import { colorByCelsius, colorByHour, skyColors, mix, luminance, sunIntensity, starsByHour, isDayHour, token } from '../js/palette.js';
import { getCondition, weatherMarks, iceHalo } from '../js/conditions.js';
import { createScene } from '../js/scene.js';
import { rollText } from '../js/roll.js';

const $ = sel => document.querySelector(sel);
const pad = n => String(n).padStart(2, '0');
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');

/* Same recipe as the app's skyFor() */
function skyFor({ hour, temp, code = 0, wind = 10, data = {}, isDay = isDayHour(hour) }) {
  const cond = getCondition(code, wind, data);
  const { timeColor, tempColor } = skyColors({ hour, temp, isDay, fx: cond.fx });
  const ink = luminance(mix(timeColor, tempColor)) > 0.55 ? token('--ink-dark') : token('--ink-light');
  return { cond, isDay, timeColor, tempColor, ink, halo: iceHalo(temp, cond.levels) };
}

/* the app's sun or moon */
function orb(s, temp) {
  const o = document.createElement('div');
  if (!s.isDay) {
    o.className = 'orb orb--moon';
    return o;
  }
  const veiled = s.cond.fx.veil;
  const { pulses = 0, big, shining, blazing, duration = 3 } = veiled ? {} : sunIntensity(temp);
  o.className = 'orb orb--sun' + (shining ? ' is-shining' : '') + (blazing ? ' is-blazing' : '') + (veiled ? ' is-veiled' : '');
  for (let i = 0; i < pulses; i++) {
    const p = document.createElement('i');
    if (big) p.className = 'big';
    p.style.animationDuration = `${duration}s`;
    p.style.animationDelay = `${(i * duration / pulses).toFixed(2)}s`;
    o.append(p);
  }
  return o;
}

/* Scenes only animate while on screen */
const visible = new IntersectionObserver(entries => {
  for (const e of entries) e.target.scene?.[e.isIntersecting ? 'resume' : 'pause']();
}, { rootMargin: '120px' });

/* A sky inside `el`: gradient, veil, halo, sun or moon, particles, caption.
   density < 1 thins the particles for small skies. */
function makeSky(el, { live = true, density = 1, caption = true } = {}) {
  const veil = Object.assign(document.createElement('div'), { className: 'sky__veil' });
  const halo = Object.assign(document.createElement('div'), { className: 'sky__halo' });
  const cap = caption ? Object.assign(document.createElement('div'), { className: 'sky__caption' }) : null;
  let orbEl = document.createElement('div');
  el.append(veil, halo, orbEl);
  if (cap) el.append(cap);

  let scene = null;
  let pending = null;
  if (live) {
    const canvas = document.createElement('canvas');
    el.prepend(canvas);
    requestAnimationFrame(() => {
      scene = createScene(canvas, () => ({ top: canvas.clientHeight * 0.2, bottom: canvas.clientHeight * 0.5 }));
      scene.pause();
      el.scene = scene;
      visible.observe(el);
      if (pending) scene.set(pending);
    });
  }

  return {
    show(opts) {
      const s = skyFor(opts);
      el.style.setProperty('--from', s.timeColor);
      el.style.setProperty('--to', s.tempColor);
      el.style.setProperty('--sky-ink', s.ink);
      veil.style.opacity = s.cond.fx.darken || 0;
      halo.style.opacity = s.halo;
      // keep the same sun or moon when it looks the same, so its pulses
      // and glow don't restart
      const next = orb(s, opts.temp);
      if (next.className !== orbEl.className || next.children.length !== orbEl.children.length) {
        orbEl.replaceWith(next);
        orbEl = next;
      }
      if (cap) {
        cap.innerHTML = '';
        const b = document.createElement('b');
        b.textContent = opts.title ?? s.cond.label;
        const small = document.createElement('small');
        small.textContent = opts.sub ?? '';
        cap.append(b, small);
      }
      if (live) {
        const fx = { ...s.cond.fx };
        if (density < 1) for (const k of ['rain', 'snow', 'wind', 'clouds']) if (fx[k]) fx[k] = Math.ceil(fx[k] * density);
        const stars = s.isDay ? 0 : (starsByHour(opts.hour) || 40) * density;
        pending = { fx, stars: s.cond.fx.clouds > 10 ? stars / 4 : stars, timeColor: s.timeColor };
        scene?.set(pending);
      }
      return s;
    },
  };
}

/* ======================================================================
   Hero: tilt the app window flat as it scrolls into view
   ====================================================================== */
const hero = $('#hero-window');
function tilt() {
  if (reduceMotion.matches) return;
  const r = hero.getBoundingClientRect();
  const t = clamp((r.top - 80) / (innerHeight * 0.6), 0, 1);
  hero.style.setProperty('--tilt', `${(t * 14).toFixed(2)}deg`);
}
addEventListener('scroll', tilt, { passive: true });
addEventListener('resize', tilt);
tilt();

/* ======================================================================
   1.x Trio
   ====================================================================== */
const trio = {
  sky: { hour: 18.5, temp: 26, code: 0, title: '' },
  circle: { hour: 13, temp: 33, code: 0, title: '' },
  weather: { hour: 15, temp: 12, code: 63, data: { rain: 6, vis: 20000 }, wind: 30, title: '' },
};
for (const fig of document.querySelectorAll('.trio__art')) {
  const k = fig.dataset.art;
  makeSky(fig, { live: k !== 'sky', density: 0.6, caption: false }).show(trio[k]);
  if (k === 'sky') fig.querySelector('.orb')?.remove();
}

/* ======================================================================
   2.0 Mix a sky: drag time of day and temperature
   ====================================================================== */
const timeStops = Array.from({ length: 25 }, (_, h) => `${colorByHour(h)} ${(h / 24 * 100).toFixed(1)}%`);
$('#scale-time').style.background = `linear-gradient(90deg, ${timeStops.join(', ')})`;
const temps = Array.from({ length: 25 }, (_, i) => -20 + i * 2.5);
const tempStops = temps.map((t, i) => `${colorByCelsius(t)} ${(i / (temps.length - 1) * 100).toFixed(1)}%`);
$('#scale-temp').style.background = `linear-gradient(90deg, ${tempStops.join(', ')})`;

const mixSky = makeSky($('#mix-stage'), { density: 0.8 });
const mixState = { hour: 8, temp: 6 };
function drawMix() {
  const { hour, temp } = mixState;
  const h = Math.floor(hour), m = Math.round((hour - h) * 60 / 15) * 15;
  const time = `${pad(h % 24)}:${pad(m % 60)}`;
  $('#scale-time-val').textContent = time;
  $('#scale-temp-val').textContent = `${Math.round(temp)}°`;
  $('#knob-time').style.left = `${(hour / 24) * 100}%`;
  $('#knob-temp').style.left = `${((temp + 20) / 60) * 100}%`;
  $('#scale-time').setAttribute('aria-valuenow', Math.round(hour));
  $('#scale-time').setAttribute('aria-valuetext', time);
  $('#scale-temp').setAttribute('aria-valuenow', Math.round(temp));
  mixSky.show({ hour, temp, code: 0, title: isDayHour(hour) ? 'Clear' : 'Clear night', sub: `${time} · ${Math.round(temp)}°` });
}

function slider(el, key, min, max, step, label) {
  Object.assign(el, { tabIndex: 0 });
  el.setAttribute('role', 'slider');
  el.setAttribute('aria-label', label);
  el.setAttribute('aria-valuemin', min);
  el.setAttribute('aria-valuemax', max);
  const set = v => { mixState[key] = clamp(v, min, max - (key === 'hour' ? 0.01 : 0)); drawMix(); };
  const at = e => {
    const r = el.getBoundingClientRect();
    set(min + clamp((e.clientX - r.left) / r.width, 0, 1) * (max - min));
  };
  let drag = false;
  el.addEventListener('pointerdown', e => { drag = true; el.setPointerCapture(e.pointerId); at(e); });
  el.addEventListener('pointermove', e => { if (drag) at(e); });
  el.addEventListener('pointerup', () => { drag = false; });
  el.addEventListener('pointercancel', () => { drag = false; });
  el.addEventListener('keydown', e => {
    const d = { ArrowRight: step, ArrowUp: step, ArrowLeft: -step, ArrowDown: -step }[e.key];
    if (d) { e.preventDefault(); set(mixState[key] + d); }
  });
}
slider($('#scale-time'), 'hour', 0, 24, 0.5, 'Time of day');
slider($('#scale-temp'), 'temp', -20, 40, 1, 'Temperature');
drawMix();

/* ======================================================================
   3.0 Weather tabs
   ====================================================================== */
const WEATHER = [
  { id: 'clear', name: 'Clear', hour: 13, temp: 31, code: 0, wind: 5, sub: '31° · hot, the sun pulses' },
  { id: 'clouds', name: 'Clouds', hour: 12, temp: 17, code: 2, wind: 8, data: { cloud: 60, lowCloud: 60 }, sub: '17° · 60% of the sky' },
  { id: 'rain', name: 'Rain', hour: 15, temp: 13, code: 63, wind: 14, data: { rain: 6, vis: 20000 }, sub: '13° · 6 mm per hour' },
  { id: 'snow', name: 'Snow', hour: 11, temp: -3, code: 73, wind: 8, data: { snow: 1.8, rain: 0, vis: 20000 }, sub: '−3° · 1.8 cm per hour' },
  { id: 'fog', name: 'Fog', hour: 8, temp: 8, code: 45, wind: 4, data: { vis: 300, rain: 0, snow: 0 }, sub: '8° · 300 m visibility' },
  { id: 'storm', name: 'Storm', hour: 18, temp: 24, code: 95, wind: 20, data: { rain: 6, vis: 20000 }, sub: '24° · thunder and lightning' },
  { id: 'wind', name: 'Wind', hour: 14, temp: 16, code: 2, wind: 62, data: { rain: 0, snow: 0, vis: 20000 }, sub: '16° · 62 km/h' },
  { id: 'night', name: 'Cold night', hour: 23, temp: -14, code: 0, wind: 4, sub: '−14° · stars and an ice halo' },
];
const wxSky = makeSky($('#wx-stage'));
const tabs = $('#wx-tabs');
let wxIndex = 0;
let wxAuto = !reduceMotion.matches;
WEATHER.forEach((w, i) => {
  const b = document.createElement('button');
  b.className = 'tab';
  b.type = 'button';
  b.role = 'tab';
  b.textContent = w.name;
  b.addEventListener('click', () => { wxAuto = false; showWeather(i); });
  tabs.append(b);
});
tabs.addEventListener('keydown', e => {
  const d = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
  if (!d) return;
  wxAuto = false;
  showWeather((wxIndex + d + WEATHER.length) % WEATHER.length);
  tabs.children[wxIndex].focus();
});
function showWeather(i) {
  wxIndex = i;
  [...tabs.children].forEach((b, j) => {
    b.setAttribute('aria-selected', String(j === i));
    b.tabIndex = j === i ? 0 : -1;
  });
  const w = WEATHER[i];
  const s = wxSky.show({ ...w, title: getCondition(w.code, w.wind, w.data || {}).label });
  $('#wx-stage').setAttribute('aria-label', `${s.cond.label}, ${w.sub}`);
}
showWeather(0);
// cycle through the kinds while the stage is on screen, until someone picks one
let wxOnScreen = false;
new IntersectionObserver(([e]) => { wxOnScreen = e.isIntersecting; }).observe($('#wx-stage'));
setInterval(() => {
  if (wxAuto && wxOnScreen && !document.hidden) showWeather((wxIndex + 1) % WEATHER.length);
}, 3800);

/* ======================================================================
   4.0 Timeline: a sample day to scrub
   ====================================================================== */
const day = [
  [16, 0, 28], [17, 1, 27], [18, 2, 25], [19, 3, 23], [20, 61, 21], [21, 63, 20], [22, 95, 19], [23, 63, 18],
  [0, 3, 17], [1, 0, 16], [2, 0, 15], [3, 0, 15], [4, 0, 14], [5, 0, 14], [6, 45, 15], [7, 45, 16],
  [8, 1, 18], [9, 0, 21], [10, 0, 23], [11, 0, 25], [12, 0, 27], [13, 0, 29], [14, 0, 30], [15, 0, 30],
];
const tlSky = makeSky($('#tl-stage'));
const track = $('#tl-track');
const tlow = Math.min(...day.map(d => d[2])), thigh = Math.max(...day.map(d => d[2]));
const n = day.length;
const nightStops = [];
day.forEach(([hour, code, temp], i) => {
  const s = skyFor({ hour, temp, code });
  const bar = document.createElement('div');
  bar.className = 'bar';
  bar.style.height = `${18 + ((temp - tlow) / (thigh - tlow)) * 82}%`;
  bar.style.background = `linear-gradient(to top, ${s.timeColor}, ${s.tempColor})`;
  const marks = weatherMarks(s.cond.levels);
  if (marks) {
    const wx = document.createElement('span');
    wx.className = 'bar__wx';
    wx.innerHTML = '<i></i>'.repeat(marks.count);
    bar.append(wx);
  }
  track.append(bar);
  nightStops.push(`${s.isDay ? 'transparent' : token('--ink-faint')} ${(i / n * 100).toFixed(2)}% ${((i + 1) / n * 100).toFixed(2)}%`);
  const prevDay = i === 0 ? true : isDayHour(day[i - 1][0]);
  if (!s.isDay && prevDay) nightMark('moon', i);
  if (s.isDay && i > 0 && !prevDay) nightMark('sun', i);
});
track.style.setProperty('--night', `linear-gradient(90deg, ${nightStops.join(', ')})`);

function nightMark(kind, i) {
  const m = document.createElement('i');
  m.className = `night-mark night-mark--${kind}`;
  m.style.left = `${(i / n * 100).toFixed(2)}%`;
  $('#tl-night').append(m);
}

let current = -1;
function selectBar(i) {
  i = clamp(i, 0, n - 1);
  if (i === current) return;
  const dir = current < 0 ? 0 : Math.sign(i - current);
  current = i;
  [...track.children].forEach((b, j) => b.classList.toggle('is-selected', j === i));
  const [hour, code, temp] = day[i];
  const label = getCondition(code).label;
  const when = i === 0 ? 'Now' : `${pad(hour)}:00`;
  rollText($('#tl-label'), `${when} · ${temp}° · ${label}`, dir);
  track.setAttribute('aria-valuenow', i);
  track.setAttribute('aria-valuetext', `${when}, ${temp}°, ${label}`);
  tlSky.show({ hour, temp, code, wind: 10, title: label, sub: `${when} · ${temp}°` });
}
const indexAt = e => Math.floor(((e.clientX - track.getBoundingClientRect().left) / track.clientWidth) * n);
let dragging = false;
track.addEventListener('pointerdown', e => { dragging = true; track.setPointerCapture(e.pointerId); selectBar(indexAt(e)); });
track.addEventListener('pointermove', e => { if (dragging || e.pointerType === 'mouse') selectBar(indexAt(e)); });
track.addEventListener('pointerup', () => { dragging = false; });
track.addEventListener('pointercancel', () => { dragging = false; });
track.addEventListener('keydown', e => {
  const d = { ArrowRight: 1, ArrowLeft: -1, Home: -n, End: n }[e.key];
  if (d) { e.preventDefault(); selectBar(current + d); }
});
selectBar(0);

/* ======================================================================
   5.0 Explore: one sample sky per kind of extreme
   ====================================================================== */
const EXTREMES = [
  { title: 'Coldest', hour: 12, temp: -32, code: 0, wind: 6, sub: '−32° · clear' },
  { title: 'Hottest', hour: 14, temp: 44, code: 0, wind: 6, sub: '44° · clear' },
  { title: 'Golden hour', hour: 19.6, temp: 21, code: 1, wind: 6, data: { cloud: 15, lowCloud: 10 }, sub: 'sunset · sun 1° up' },
  { title: 'Rain', hour: 16, temp: 15, code: 65, wind: 18, data: { rain: 14, vis: 20000 }, sub: '14 mm/h' },
  { title: 'Snowing', hour: 10, temp: -6, code: 75, wind: 12, data: { snow: 3.5, rain: 0, vis: 20000 }, sub: '3.5 cm/h' },
  { title: 'Storms', hour: 17, temp: 27, code: 95, wind: 25, data: { rain: 9, vis: 20000 }, sub: 'thunder' },
  { title: 'Fog', hour: 7.5, temp: 6, code: 45, wind: 3, data: { vis: 120, rain: 0, snow: 0 }, sub: '120 m visibility' },
  { title: 'Windiest', hour: 13, temp: 11, code: 2, wind: 90, data: { rain: 0, snow: 0, vis: 20000 }, sub: '90 km/h' },
];
for (const x of EXTREMES) {
  const el = document.createElement('div');
  el.className = 'extreme';
  el.setAttribute('role', 'img');
  el.setAttribute('aria-label', `${x.title}: ${x.sub}`);
  $('#extremes').append(el);
  makeSky(el, { density: 0.5 }).show(x);
}

/* ======================================================================
   Changelog swatches, cards, CTA
   ====================================================================== */
for (const sw of document.querySelectorAll('[data-sky]')) {
  const [hour, temp] = sw.dataset.sky.split(' ').map(Number);
  const s = skyFor({ hour, temp });
  sw.style.background = `linear-gradient(-65deg, ${s.timeColor}, ${s.tempColor})`;
}

/* CTA: a whole day on a loop. The sky colours follow the hour, the sun
   (by day) and the moon (by night) cross the sky from left to right on an
   arc, and the time and temperature roll as they change. */
const ctaStage = $('#cta-stage');
const ctaInner = document.querySelector('.cta__inner');
const ctaSky = makeSky(ctaStage, { caption: false });
const DAY_S = 36;                 // seconds for 24 hours
const STEP_H = 0.25;              // colours change every quarter hour, numbers every half
const SUNRISE = 7, SUNSET = 20;   // same clock day as the palette (isDayHour)
const tempAt = h => Math.round(15 + 8 * Math.sin(((h - 9) / 24) * Math.PI * 2));
const fmtHour = h => `${pad(Math.floor(h) % 24)}:${pad(Math.round((h % 1) * 60))}`;

/* 0..1 across the sun's arc by day, or the moon's by night */
function arc(h) {
  if (h >= SUNRISE && h < SUNSET) return (h - SUNRISE) / (SUNSET - SUNRISE);
  const night = 24 - SUNSET + SUNRISE;
  return ((h - SUNSET + 24) % 24) / night;
}
/* An orbit: the arc starts and ends below the horizon, so the sun sets
   on the right and fades out while the moon rises from below on the left */
const SPAN = 0.16; // how far past the horizon each end goes (x pi)
function placeOrb(h) {
  const a = (-SPAN + arc(h) * (1 + 2 * SPAN)) * Math.PI;
  const x = 50 - Math.cos(a) * 46;     // % from the left
  const y = 70 - Math.sin(a) * 56;     // % from the top: horizon at 70%
  const fade = clamp((y - 70) / 26, 0, 1);
  ctaStage.style.setProperty('--ox', `${x.toFixed(2)}%`);
  ctaStage.style.setProperty('--oy', `${y.toFixed(2)}%`);
  ctaStage.style.setProperty('--oo', (1 - fade * fade * (3 - 2 * fade)).toFixed(3));
}

let ctaStep = null, ctaShown = null;
function ctaShow(h, dir) {
  const step = Math.floor(h / STEP_H) * STEP_H;
  if (step === ctaStep) return;
  ctaStep = step;
  const temp = tempAt(step);
  const s = ctaSky.show({ hour: step, temp, code: 0, wind: 4 });
  ctaInner.style.setProperty('--cta-ink', s.ink);
  const shown = Math.floor(step * 2) / 2;
  if (shown === ctaShown) return;
  ctaShown = shown;
  rollText($('#cta-time'), fmtHour(shown), dir);
  rollText($('#cta-temp'), `${tempAt(shown)}°`, dir);
  rollText($('#cta-label'), s.isDay ? 'Clear' : 'Clear night', 0);
}

let ctaHour = 18.5, ctaLast = 0, ctaRaf = 0;
function ctaFrame(t) {
  const dt = ctaLast ? Math.min((t - ctaLast) / 1000, 0.1) : 0;
  ctaLast = t;
  ctaHour = (ctaHour + (dt * 24) / DAY_S) % 24;
  placeOrb(ctaHour);
  ctaShow(ctaHour, 1);
  ctaRaf = requestAnimationFrame(ctaFrame);
}
placeOrb(ctaHour);
ctaShow(ctaHour, 0);
if (!reduceMotion.matches) {
  new IntersectionObserver(([e]) => {
    cancelAnimationFrame(ctaRaf);
    ctaLast = 0;
    if (e.isIntersecting) ctaRaf = requestAnimationFrame(ctaFrame);
  }).observe(ctaStage);
}

/* ======================================================================
   Reveal sections as they scroll in
   ====================================================================== */
if (!reduceMotion.matches && 'IntersectionObserver' in window) {
  const els = document.querySelectorAll('.statement, .feature__head, .panel, .extremes, .subs, .changelog, .cards');
  const io = new IntersectionObserver(entries => {
    for (const e of entries) if (e.isIntersecting) { e.target.classList.add('is-in'); io.unobserve(e.target); }
  }, { rootMargin: '0px 0px -8% 0px' });
  els.forEach(el => { el.classList.add('reveal'); io.observe(el); });
}

/* Going to the app from here: remember it, so / opens the app next time
   instead of this page (see the check in ../index.html) */
document.addEventListener('click', e => {
  const a = e.target.closest('a[href]');
  if (!a || new URL(a.href).pathname !== new URL('../', location.href).pathname) return;
  try { localStorage.setItem('tc-seen', '1'); } catch {}
});
