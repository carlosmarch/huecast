/* "How it works" page: every demo is drawn with the app's own code
   (palette, conditions, scene), so it always matches the app. */

import { colorByCelsius, colorByHour, skyColors, mix, luminance, sunIntensity, starsByHour, isDayHour, SUN_STEPS, token } from './palette.js';
import { getCondition, weatherMarks, iceHalo, STEPS, CALM_WIND } from './conditions.js';
import { createScene } from './scene.js';
import { rollText } from './roll.js';

const $ = sel => document.querySelector(sel);
const pad = n => String(n).padStart(2, '0');

/* Back: return to the exact app screen when we came from it */
$('#back').addEventListener('click', e => {
  if (document.referrer && new URL(document.referrer).origin === location.origin && history.length > 1) {
    e.preventDefault();
    history.back();
  }
});

/* Same recipe as the app's skyFor() */
function sky(hour, temp, code = 0, wind = 10, data = {}, isDay = isDayHour(hour)) {
  const cond = getCondition(code, wind, data);
  const { timeColor, tempColor } = skyColors({ hour, temp, isDay, fx: cond.fx });
  const ink = luminance(mix(timeColor, tempColor)) > 0.55 ? token('--ink-dark') : token('--ink-light');
  return { cond, isDay, timeColor, tempColor, ink, halo: iceHalo(temp, cond.levels) };
}

function gradient(el, angle, from, to) {
  el.style.background = `linear-gradient(${angle}, ${from}, ${to})`;
  el.style.background = `linear-gradient(${angle} in oklch, ${from}, ${to})`;
}

/* mini sun or moon, drawn like the app's */
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

/* Live scenes only animate while on screen */
const visible = new IntersectionObserver(entries => {
  for (const e of entries) e.target.scene?.[e.isIntersecting ? 'resume' : 'pause']();
}, { rootMargin: '80px' });

/* A small sky; live = with weather particles */
function tile({ hour, temp, code = 0, wind = 10, data = {}, title, sub, live = false }) {
  const s = sky(hour, temp, code, wind, data);
  const t = document.createElement('div');
  t.className = 'tile';
  gradient(t, '-65deg', s.timeColor, s.tempColor);
  t.style.setProperty('--tile-ink', s.ink);
  if (s.cond.fx.darken) {
    const v = document.createElement('div');
    v.className = 'tile__veil';
    v.style.opacity = s.cond.fx.darken;
    t.append(v);
  }
  if (s.halo) {
    const ring = document.createElement('div');
    ring.className = 'tile__halo';
    ring.style.opacity = s.halo;
    t.append(ring);
  }
  t.append(orb(s, temp));
  const c = document.createElement('div');
  c.className = 'tile__caption';
  c.innerHTML = `${title}${sub ? `<small>${sub}</small>` : ''}`;
  t.append(c);

  if (live) {
    const canvas = document.createElement('canvas');
    t.prepend(canvas);
    requestAnimationFrame(() => {
      const scene = createScene(canvas, () => ({ top: canvas.clientHeight * 0.28, bottom: canvas.clientHeight * 0.52 }));
      // lighter than full screen, same proportions between steps
      const fx = { ...s.cond.fx };
      for (const k of ['rain', 'snow', 'wind']) if (fx[k]) fx[k] = Math.ceil(fx[k] / 2);
      if (fx.clouds) fx.clouds = Math.ceil(fx.clouds / 2);
      scene.pause();
      // same stars as the app's render()
      const stars = s.isDay ? 0 : starsByHour(hour) || 40;
      scene.set({ fx, stars: s.cond.fx.clouds > 10 ? stars / 4 : stars, timeColor: s.timeColor });
      t.scene = scene;
      visible.observe(t);
    });
  }
  return t;
}

/* rain ticks / snow dots, like the timeline */
function markEl(kind, n) {
  const m = document.createElement('span');
  m.className = 'mk';
  m.dataset.kind = kind;
  m.innerHTML = '<i></i>'.repeat(n);
  return m;
}

/* the mark a step gets in the timeline, in the tile's corner */
function withMark(tileEl, kind, level) {
  const marks = weatherMarks(kind === 'rain' ? { rain: level, snow: 0 } : { rain: 0, snow: level });
  const corner = document.createElement('span');
  corner.className = 'tile__mark';
  corner.title = `${marks.count} ${kind === 'rain' ? 'tick' : 'dot'}${marks.count > 1 ? 's' : ''} in the timeline`;
  corner.append(markEl(kind, marks.count));
  tileEl.append(corner);
  return tileEl;
}

/* "0.5–2.5" style ranges from the step limits */
const fmt = v => (v >= 10 || Number.isInteger(v) ? String(Math.round(v)) : String(v));
function range(steps, i, floor) {
  const lo = i === 0 ? floor : steps[i - 1].max;
  const hi = steps[i].max;
  if (hi === Infinity) return `${fmt(lo)}+`;
  return i === 0 && !floor ? `< ${fmt(hi)}` : `${fmt(lo)}–${fmt(hi)}`;
}

/* 01 · The circle: every sun step, then clouds and night */
const sunTiles = [...SUN_STEPS].reverse().map(st => {
  const temp = st.min === -Infinity ? 12 : st.min + 2;
  const title = st.min === -Infinity ? 'Under 15°' : `${st.min}° +`;
  const name = st.name.toLowerCase();
  const sub = st.pulses ? `${name} · ${st.pulses} pulse${st.pulses > 1 ? 's' : ''}` : name;
  return tile({ hour: 13, temp, title, sub });
});
$('#demo-circles').append(
  ...sunTiles,
  tile({ hour: 12, temp: 16, code: 3, title: 'Clouds', sub: 'veiled sun' }),
  tile({ hour: 23, temp: 14, title: 'Night', sub: 'moon, stars', live: true }),
  tile({ hour: 23, temp: -15, title: 'Below −5°', sub: 'ice halo', live: true }),
);

/* 02 · The sky: the two scales, then examples */
const timeStops = Array.from({ length: 25 }, (_, h) => `${colorByHour(h)} ${(h / 24 * 100).toFixed(1)}%`);
$('#strip-time').style.background = `linear-gradient(90deg, ${timeStops.join(', ')})`;
const temps = Array.from({ length: 25 }, (_, i) => -20 + i * 2.5); // -20° .. 40°
const tempStops = temps.map((t, i) => `${colorByCelsius(t)} ${(i / (temps.length - 1) * 100).toFixed(1)}%`);
$('#strip-temp').style.background = `linear-gradient(90deg, ${tempStops.join(', ')})`;

/* 03 · The weather: every step of each kind, live */
const RAIN_AT = [0.3, 1.5, 5, 12, 35, 70];
$('#demo-rain').append(...STEPS.rain.steps.map((st, i) => withMark(tile({
  hour: 15, temp: 14, code: 63, data: { rain: RAIN_AT[i], snow: 0, vis: 20000 },
  title: st.name, sub: range(STEPS.rain.steps, i), live: true,
}), 'rain', i + 1)));

const SNOW_AT = [0.1, 0.6, 1.8, 3.5, 7];
$('#demo-snow').append(...STEPS.snow.steps.map((st, i) => withMark(tile({
  hour: 11, temp: -2, code: 73, data: { snow: SNOW_AT[i], rain: 0, vis: 20000 },
  title: st.name, sub: range(STEPS.snow.steps, i), live: true,
}), 'snow', i + 1)));

/* everything else: one tile per kind, its heaviest-but-one step */
$('#demo-other').append(
  tile({ hour: 13, temp: 20, code: 2, data: { cloud: 50, lowCloud: 50 }, title: 'Clouds', sub: 'bands, by cover', live: true }),
  tile({ hour: 12, temp: 12, code: 3, data: { cloud: 100, lowCloud: 100 }, title: 'Overcast', sub: 'veiled sun', live: true }),
  tile({ hour: 8, temp: 9, code: 45, data: { vis: 300, rain: 0, snow: 0 }, title: STEPS.fog.steps[1].name, sub: '300 m visibility', live: true }),
  tile({ hour: 18, temp: 24, code: 95, data: { rain: 5, vis: 20000 }, title: 'Storm', sub: 'lightning', live: true }),
  tile({ hour: 14, temp: 18, code: 2, wind: 62, data: { rain: 0, snow: 0, vis: 20000 }, title: 'Wind', sub: `streaks from ${CALM_WIND} km/h`, live: true }),
);

/* 04 · The timeline: a sample day you can scrub */
const day = [
  [13, 0, 31], [14, 0, 31], [15, 1, 30], [16, 2, 28], [17, 3, 26], [18, 61, 23], [19, 63, 21], [20, 95, 20],
  [21, 63, 19], [22, 3, 18], [23, 0, 17], [0, 0, 16], [1, 0, 16], [2, 0, 15], [3, 0, 15], [4, 0, 15],
  [5, 0, 15], [6, 45, 16], [7, 45, 17], [8, 1, 20], [9, 0, 23], [10, 0, 25], [11, 0, 27], [12, 0, 29],
];
const track = $('#demo-timeline-track');
const tlow = Math.min(...day.map(d => d[2])), thigh = Math.max(...day.map(d => d[2]));
const n = day.length;
const nightStops = [];
day.forEach(([hour, code, temp], i) => {
  const isDay = isDayHour(hour);
  const s = sky(hour, temp, code, 10, {}, isDay);
  const bar = document.createElement('div');
  bar.className = 'bar';
  bar.style.height = `${18 + ((temp - tlow) / (thigh - tlow)) * 82}%`;
  gradient(bar, 'to top', s.timeColor, s.tempColor);
  const marks = weatherMarks(s.cond.levels);
  if (marks) {
    const wx = document.createElement('span');
    wx.className = 'bar__wx' + (marks.snow ? ' is-snow' : '');
    wx.innerHTML = '<i></i>'.repeat(marks.count);
    bar.append(wx);
  }
  track.append(bar);
  nightStops.push(`${isDay ? 'transparent' : token('--ink-faint')} ${(i / n * 100).toFixed(2)}% ${((i + 1) / n * 100).toFixed(2)}%`);
  const prevDay = i === 0 ? true : isDayHour(day[i - 1][0]);
  if (!isDay && prevDay) mark('moon', i);
  if (isDay && i > 0 && !prevDay) mark('sun', i);
});
track.style.setProperty('--night', `linear-gradient(90deg, ${nightStops.join(', ')})`);

function mark(kind, i) {
  const m = document.createElement('i');
  m.className = `night-mark night-mark--${kind}`;
  m.style.left = `${(i / n * 100).toFixed(2)}%`;
  $('#demo-timeline-night').append(m);
}

let current = -1;
function selectBar(i) {
  i = Math.max(0, Math.min(n - 1, i));
  if (i === current) return;
  const dir = current < 0 ? 0 : Math.sign(i - current);
  current = i;
  [...track.children].forEach((b, j) => b.classList.toggle('is-selected', j === i));
  const [hour, code, temp] = day[i];
  rollText($('#demo-timeline-label'), `${i === 0 ? 'Now' : `${pad(hour)}:00`} · ${temp}° · ${getCondition(code).label}`, dir);
}
const indexAt = e => Math.floor(((e.clientX - track.getBoundingClientRect().left) / track.clientWidth) * n);
let dragging = false;
track.addEventListener('pointerdown', e => { dragging = true; track.setPointerCapture(e.pointerId); selectBar(indexAt(e)); });
track.addEventListener('pointermove', e => { if (dragging || e.pointerType === 'mouse') selectBar(indexAt(e)); });
track.addEventListener('pointerup', () => { dragging = false; });
track.addEventListener('pointercancel', () => { dragging = false; });
selectBar(0);

document.querySelectorAll('.legend .mk[data-n]').forEach(m => { m.innerHTML = '<i></i>'.repeat(+m.dataset.n); });
