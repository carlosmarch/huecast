/*!
 Name: Huecast v3
 Author: Carlos March - http://carlosmarch.es
 Created: 5 feb 2016 - Rebuilt: 2026
 Data: Open-Meteo, BigDataCloud
 Licensed under the MIT license
 */

import { getForecast, getNowMany, reverseGeocode, searchCity, getPosition } from './weather.js';
import { getCondition, weatherMarks, iceHalo, CODES } from './conditions.js';
import { skyColors, skyHour, sunIntensity, starsByHour, isDayHour, luminance, mix } from './palette.js';
import { createScene } from './scene.js';
import { rollText } from './roll.js';
import { renderPicture } from './picture.js';
import { cities } from './cities.js';
import { THEMES, EXPLORE_PLACES, rank } from './explore.js';

const REFRESH_MS = 15 * 60 * 1000;
// the loader is the app icon, its sun and two cloud bands (see index.html)
const LOADER = '<div class="loader"><b></b><b></b><i></i></div>';
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

const $ = sel => document.querySelector(sel);
const el = {
  root: document.documentElement,
  app: $('#app'),
  skyLayers: document.querySelectorAll('.sky__layer'),
  darken: $('.sky__darken'),
  condition: $('#condition'),
  icon: $('#icon'),
  temp: $('#temp'),
  city: $('#city'),
  date: $('#date'),
  timeline: $('#timeline'),
  track: $('#timeline-track'),
  label: $('#timeline-label'),
  low: $('#timeline-low'),
  night: $('#timeline-night'),
  high: $('#timeline-high'),
  retry: $('#retry'),
  menu: $('#menu'),
  sheet: $('#sheet'),
  menuBtn: $('#btn-menu'),
  search: $('#search'),
  searchForm: $('#search-form'),
  searchInput: $('#search-input'),
  searchResults: $('#search-results'),
  toast: $('#toast'),
  domlog: $('#domlog'),
  themeColor: $('meta[name="theme-color"]'),
};

const scene = createScene($('.scene'), () => {
  const r = el.icon.getBoundingClientRect();
  return { top: r.top, bottom: r.bottom };
});

const state = {
  place: null,     // { lat, lon, label }
  forecast: null,  // { offset, hours[] }
  selected: 0,
  unit: loadUnit(),
  skyIndex: 0,
  lastKey: '',
  iconKey: '',
  rollDir: 0,
  refreshTimer: 0,
  demo: null,
  wallpaper: null, // null, '' (sky only) or 'info' (clean view)
  retryTimer: 0,
};

/* ======================================================================
   BOOT
   ====================================================================== */
init();

/* Opening the app (not the landing page's preview of it) means / skips
   the landing page from now on - see the check in index.html */
function rememberVisit() {
  if (window.top !== window) return;
  try { localStorage.setItem('tc-seen', '1'); } catch {}
}

function init() {
  bindUI();
  fitScreen();
  registerServiceWorker();
  rememberVisit();

  const params = new URLSearchParams(location.search);
  const wallpaper = params.get('wallpaper');
  if (wallpaper !== null) setWallpaper(wallpaper === 'info' ? 'info' : '');
  if (params.has('demo')) return startDemo(params);

  const lat = parseFloat(params.get('lat'));
  const lon = parseFloat(params.get('lon'));
  if (Number.isFinite(lat) && Number.isFinite(lon)) {
    return loadPlace({ lat, lon, label: params.get('name') || '' }, { share: false });
  }
  if (params.get('city') === 'random') return loadRandomCity();

  locate({ initial: true });
}

async function locate({ initial = false } = {}) {
  const btn = $('#menu-locate');
  btn.classList.add('is-busy');
  // the menu closes on tap, so say it's working when the sky can't
  const locating = 'Locating…';
  if (!state.forecast) setStatus('locating');
  else toast(locating, 15000);
  try {
    const pos = await getPosition();
    clearShare();
    await loadPlace({ ...pos, label: '' }, { share: false, remember: true });
  } catch (err) {
    const saved = initial && loadSavedPlace();
    if (saved) {
      await loadPlace(saved, { share: false });
    } else {
      toast(initial ? 'No location · random city' : 'Location unavailable');
      if (initial) loadRandomCity();
    }
  } finally {
    btn.classList.remove('is-busy');
    if (el.toast.textContent === locating) { clearTimeout(toastTimer); el.toast.hidden = true; }
  }
}

function loadRandomCity() {
  let c;
  do {
    c = cities[Math.floor(Math.random() * cities.length)];
  } while (state.place && c[0] === state.place.label.split(',')[0]);
  return loadPlace({ lat: c[2], lon: c[3], label: cityLabel(c) });
}

async function loadPlace(place, { share = true, remember = false } = {}) {
  state.demo = null;
  document.body.classList.remove('is-demo');
  el.domlog.hidden = true;
  state.place = place;
  el.city.textContent = place.label || '';
  if (share) shareURL(place);
  setLoading(true);

  let forecast, label;
  try {
    [forecast, label] = await Promise.all([
      getForecast(place.lat, place.lon),
      place.label ? place.label : reverseGeocode(place.lat, place.lon),
    ]);
  } catch (err) {
    console.error(err);
    if (state.place !== place) return;
    return showError(navigator.onLine ? 'no signal' : 'offline', err);
  }
  if (state.place !== place) return; // a newer request won

  // Drawing errors are bugs, not connection problems: say so
  try {
    place.label = label || formatCoords(place);
    state.forecast = forecast;
    state.selected = 0;
    if (remember) savePlace(place);
    setLoading(false);
    state.lastKey = '';
    buildTimeline();
    render();
    scheduleRefresh();
  } catch (err) {
    console.error(err);
    showError('something broke', err);
  }
}

function scheduleRefresh() {
  clearInterval(state.refreshTimer);
  state.refreshTimer = setInterval(() => {
    if (document.hidden || !state.place) return;
    const place = state.place;
    getForecast(place.lat, place.lon).then(f => {
      if (state.place !== place) return;
      state.forecast = f;
      state.selected = Math.min(state.selected, f.hours.length - 1);
      buildTimeline();
      render();
    }).catch(() => {});
  }, REFRESH_MS);
}

// Re-render "now" every minute so the sky follows the clock
setInterval(() => {
  if (state.forecast && state.selected === 0 && !document.hidden) render();
}, 60 * 1000);

/* ======================================================================
   RENDER
   ====================================================================== */
function render() {
  const { hours, offset, daylight } = state.forecast;
  const h = hours[state.selected];
  const { local, hour, sky, cond, timeColor, tempColor } = skyFor(h, offset, daylight);
  const isDay = h.isDay;

  // Only rebuild the scene when what it shows actually changes
  const key = [h.code, Math.round(h.temp), isDay, Math.floor(sky), Math.round(h.wind / 10), cond.fx.clouds, cond.fx.veil].join('|');
  const changed = key !== state.lastKey;
  state.lastKey = key;

  // Text
  el.condition.classList.remove('is-status');
  setText(el.condition, cond.label, 'animate-down', changed);
  el.city.textContent = state.place.label;
  // numbers roll with the scrub direction (forward: up, back: down)
  const dir = state.rollDir;
  state.rollDir = 0;
  el.date.classList.remove('is-detail');
  rollText(el.date, `${DAYS[local.getUTCDay()]}, ${local.getUTCDate()} ${MONTHS[local.getUTCMonth()]}`, dir);
  renderTemp(h.temp, dir);
  // the temperature is the big number above; the bar shows what it feels like
  const feels = hasFeels(h) ? ` · ${toUnit(h.feels)}°` : '';
  rollText(el.label, `${h.isNow ? 'Now' : `${pad(local.getUTCHours())}:00`}${feels}`, dir);

  if (!changed) return;

  // Sky gradient: same recipe as the original (-65deg, time -> temperature)
  paintSky(timeColor, tempColor);
  el.darken.style.opacity = cond.fx.darken || 0;

  // Contrast: very pale skies get dark ink
  const mid = mix(timeColor, tempColor);
  const lum = luminance(mid);
  el.root.dataset.ink = lum > 0.55 ? 'dark' : 'light';
  el.root.style.setProperty('--text-shadow', lum > 0.3 && lum <= 0.55 ? '0 1px 14px var(--shadow-text)' : 'none');
  el.themeColor.content = timeColor;

  // Sun or moon
  const halo = iceHalo(h.temp, cond.levels);
  makeDayOrNight(isDay, h.temp, cond.fx.veil, halo);
  const sun = isDay && !cond.fx.veil ? sunIntensity(h.temp) : {};
  state.sky = { timeColor, tempColor, darken: cond.fx.darken || 0, inkDark: lum > 0.55, isDay,
    veiled: !!cond.fx.veil, shining: !!sun.shining, blazing: !!sun.blazing, halo, label: cond.label };

  // Environment particles
  const stars = isDay ? 0 : starsByHour(sky) || 40;
  scene.set({ fx: cond.fx, stars: cond.fx.clouds > 10 ? stars / 4 : stars, timeColor });

  if (state.demo === true) {
    el.domlog.hidden = false;
    el.domlog.textContent = `demo · hour ${pad(Math.floor(hour))} · ${Math.round(h.temp)}°C · code ${h.code} · ${cond.label} · wind ${Math.round(h.wind)} km/h`;
  }
}

/* Colours and condition for one forecast hour. Shared by the sky and
   the timeline bars, so each bar is a small copy of that hour's sky */
function skyFor(h, offset, daylight) {
  // Local time at the location, not on the device
  const ts = h.isNow ? Date.now() : h.time * 1000;
  const local = new Date(ts + offset * 1000);
  const hour = local.getUTCHours() + local.getUTCMinutes() / 60;
  // the colours follow the real sunrise and sunset, not the clock
  const sky = skyHour(hour, ts / 1000, daylight);

  const cond = getCondition(h.code, h.wind, h.data);
  // night darkens but keeps the colour; weather drains or (snow) lifts it
  const { timeColor, tempColor } = skyColors({ hour: sky, temp: h.temp, isDay: h.isDay, fx: cond.fx });
  return { local, hour, sky, cond, timeColor, tempColor };
}

function gradient(el, angle, from, to) {
  el.style.background = `linear-gradient(${angle}, ${from}, ${to})`;
  // perceptual blend where supported; ignored by older browsers
  el.style.background = `linear-gradient(${angle} in oklch, ${from}, ${to})`;
}

function paintSky(timeColor, tempColor) {
  const next = el.skyLayers[state.skyIndex ^ 1];
  const prev = el.skyLayers[state.skyIndex];
  gradient(next, '-65deg', timeColor, tempColor);
  // page background = colour along the bottom edge of the sky
  el.root.style.backgroundColor = mix(timeColor, tempColor, 0.3);
  next.classList.add('is-active');
  prev.classList.remove('is-active');
  state.skyIndex ^= 1;
}

function makeDayOrNight(isDay, celsius, veiled, halo = 0) {
  // a sun behind clouds or fog doesn't shine or pulse
  const { pulses = 0, big, shining, blazing, duration = 3 } = isDay && !veiled ? sunIntensity(celsius) : {};
  // keep the element (and its animations) when nothing visible changes
  const key = (isDay ? `sun|${veiled}|${pulses}|${big}|${shining}|${blazing}` : 'moon') + `|${halo.toFixed(1)}`;
  if (key === state.iconKey) return;
  state.iconKey = key;

  el.icon.textContent = '';
  // very cold: an ice halo ring around the sun or moon
  if (halo) {
    const ring = document.createElement('div');
    ring.className = 'halo';
    ring.style.setProperty('--halo', halo.toFixed(2));
    el.icon.append(ring);
  }
  const body = document.createElement('div');
  if (isDay) {
    body.className = 'sun' + (shining ? ' shining' : '') + (blazing ? ' is-blazing' : '') + (veiled ? ' is-veiled' : '');
    // pulses evenly spaced over one cycle
    for (let i = 0; i < pulses; i++) {
      const p = document.createElement('div');
      p.className = big ? 'sun-pulse2x' : 'sun-pulse';
      p.style.animationDuration = `${duration}s`;
      p.style.animationDelay = `${(i * duration / pulses).toFixed(2)}s`;
      body.append(p);
    }
  } else {
    body.className = 'moon';
  }
  el.icon.append(body);
}

function renderTemp(celsius, dir = 0) {
  el.temp.hidden = false;
  let num = el.temp.querySelector('.temp__num');
  if (!num) {
    el.temp.innerHTML = '<span class="temp__num"></span><sup>°</sup><small></small>';
    num = el.temp.querySelector('.temp__num');
  }
  rollText(num, String(toUnit(celsius)), dir);
  el.temp.querySelector('small').textContent = state.unit;
}

// demos and older saved scenes have no "feels like"
function hasFeels(h) {
  return typeof h.feels === 'number' && Number.isFinite(h.feels);
}

function toUnit(celsius) {
  return Math.round(state.unit === 'F' ? celsius * 9 / 5 + 32 : celsius);
}

function setText(node, text, anim, animate) {
  if (node.textContent === text && !animate) return;
  node.textContent = text;
  if (animate) {
    node.classList.remove(anim);
    void node.offsetWidth; // restart animation
    node.classList.add(anim);
  }
}

function setStatus(text) {
  el.condition.classList.remove('animate-down');
  el.condition.classList.add('is-status');
  el.condition.textContent = text;
}

function setLoading(on) {
  document.body.classList.toggle('is-loading', on);
  if (!on) return;
  el.retry.hidden = true;
  setStatus('loading');
  el.icon.innerHTML = LOADER;
  state.iconKey = '';
}


function showError(msg, err) {
  document.body.classList.remove('is-loading');
  el.icon.innerHTML = '<div class="icon-empty"></div>';
  state.iconKey = '';
  state.lastKey = '';
  el.condition.classList.remove('is-status');
  setText(el.condition, msg, 'animate-down', true);
  // the actual reason, small, so it can be reported
  rollText(el.date, err ? String(err.message || err).slice(0, 120) : '');
  el.date.classList.toggle('is-detail', !!err);
  el.timeline.hidden = true;
  el.temp.hidden = true;
  el.retry.hidden = false;
  // a wallpaper has no one to tap Retry, so try again on its own
  if (state.wallpaper !== null) {
    clearTimeout(state.retryTimer);
    state.retryTimer = setTimeout(() => el.retry.click(), 60 * 1000);
  }
}

/* ======================================================================
   TIMELINE
   ====================================================================== */
function buildTimeline() {
  const { hours, offset, daylight } = state.forecast;
  const temps = hours.map(h => h.temp);
  const min = Math.min(...temps), max = Math.max(...temps);
  const range = Math.max(max - min, 4);

  state.range = [min, max];
  renderRange();

  el.track.textContent = '';
  el.track.setAttribute('aria-valuemax', hours.length - 1);
  hours.forEach((h, i) => {
    const { local, cond, timeColor, tempColor } = skyFor(h, offset, daylight);
    const bar = document.createElement('div');
    bar.className = 'bar';
    bar.style.height = `${18 + ((h.temp - min) / range) * 82}%`;
    // each bar is that hour's sky: time colour at the bottom, temperature on top
    gradient(bar, 'to top', timeColor, tempColor);
    bar.dataset.from = timeColor;
    bar.dataset.to = tempColor;

    // precipitation marks: rain ticks / snow dots, more for heavier
    const marks = weatherMarks(cond.levels);
    if (marks) {
      const wx = document.createElement('span');
      wx.className = 'bar__wx' + (marks.snow ? ' is-snow' : '');
      wx.innerHTML = '<i></i>'.repeat(marks.count);
      bar.append(wx);
    }

    if (i > 0 && local.getUTCHours() % 6 === 0) {
      const tick = document.createElement('span');
      tick.className = 'bar__tick';
      tick.textContent = pad(local.getUTCHours());
      bar.append(tick);
    }
    el.track.append(bar);
  });
  // night hours: one straight line under the bars (drawn on the track so
  // it doesn't bend when the bars magnify)
  const n = hours.length;
  const stops = hours.map((h, i) => {
    const c = h.isDay ? 'transparent' : 'var(--ink-faint)';
    return `${c} ${(i / n * 100).toFixed(2)}% ${((i + 1) / n * 100).toFixed(2)}%`;
  });
  el.track.style.setProperty('--night', `linear-gradient(90deg, ${stops.join(', ')})`);

  // a small moon where each night starts and a sun where it ends,
  // drawn like the big ones: a ring and a dot
  el.night.textContent = '';
  const mark = (kind, i) => {
    const m = document.createElement('i');
    m.className = `night-mark night-mark--${kind}`;
    m.style.left = `${(i / n * 100).toFixed(2)}%`;
    el.night.append(m);
  };
  hours.forEach((h, i) => {
    const prevDay = i === 0 ? true : hours[i - 1].isDay;
    if (!h.isDay && prevDay) mark('moon', i);
    if (h.isDay && i > 0 && !prevDay) mark('sun', i);
  });

  el.timeline.hidden = false;
  markSelected();
}

function renderRange() {
  const [min, max] = state.range;
  el.low.textContent = `Low ${toUnit(min)}°`;
  el.high.textContent = `High ${toUnit(max)}°`;
}

function select(i) {
  const n = state.forecast.hours.length;
  i = Math.max(0, Math.min(n - 1, i));
  if (i === state.selected) return;
  state.rollDir = Math.sign(i - state.selected);
  state.selected = i;
  markSelected();
  render();
}

function markSelected() {
  [...el.track.children].forEach((b, i) => b.classList.toggle('is-selected', i === state.selected));
  el.track.setAttribute('aria-valuenow', state.selected);
  const h = state.forecast.hours[state.selected];
  const degrees = `${toUnit(h.temp)} degrees ${state.unit === 'F' ? 'Fahrenheit' : 'Celsius'}`;
  const feels = hasFeels(h) ? `, feels like ${toUnit(h.feels)}` : '';
  el.track.setAttribute('aria-valuetext', `${state.selected === 0 ? 'now' : `in ${state.selected} hours`}, ${degrees}${feels}, ${getCondition(h.code, h.wind, h.data).label}`);
}

/* Dock-style magnification: bars near the pointer grow taller and wider,
   pushing their neighbours aside. Measured on the un-magnified layout so
   the effect doesn't feed back into itself */
function magnify(e) {
  const bars = el.track.children;
  if (!e) {
    for (const b of bars) b.style.removeProperty('--mag'), b.style.removeProperty('--w');
    return;
  }
  const r = el.track.getBoundingClientRect();
  const pos = ((e.clientX - r.left) / r.width) * bars.length - 0.5;
  for (let i = 0; i < bars.length; i++) {
    const d = i - pos;
    const g = Math.exp(-(d * d) / 12.5); // ~2.5 bars either side feel it
    bars[i].style.setProperty('--mag', (1 + 0.55 * g).toFixed(3));
    bars[i].style.setProperty('--w', (1 + 1.4 * g).toFixed(3));
  }
}

/* The bar under the pointer, using the real (magnified) bar positions */
function indexFromPointer(e) {
  const bars = el.track.children;
  for (let i = 0; i < bars.length; i++) {
    const r = bars[i].getBoundingClientRect();
    if (e.clientX < r.right + 1.5) return i; // half the gap belongs to each side
  }
  return bars.length - 1;
}

/* ======================================================================
   UI EVENTS
   ====================================================================== */
function bindUI() {
  bindDice();
  $('#btn-search').addEventListener('click', openSearch);
  bindMenu();
  el.retry.addEventListener('click', () => {
    if (state.place) loadPlace({ ...state.place }, { share: false });
    else locate({ initial: true });
  });

  el.temp.addEventListener('click', () => setUnit(state.unit === 'C' ? 'F' : 'C'));

  // Timeline: tap or drag to scrub. While a finger is down (or a mouse
  // hovers) the timeline grows and the bars under the pointer swell
  let dragging = false;
  let shrinkTimer = 0;
  const grow = () => {
    clearTimeout(shrinkTimer);
    el.timeline.classList.add('is-active');
  };
  const shrink = (delay = 0) => {
    clearTimeout(shrinkTimer);
    shrinkTimer = setTimeout(() => {
      el.timeline.classList.remove('is-active');
      magnify(null);
    }, delay);
  };
  let settleTimer = 0;
  const scrub = e => {
    const i = indexFromPointer(e);
    if (i !== state.selected && e.pointerType === 'touch') navigator.vibrate?.(4);
    select(i);
    // bars keep sliding for a moment after magnifying: check again once
    // they settle so the selected hour is the one under the finger
    const { clientX, pointerType } = e;
    clearTimeout(settleTimer);
    settleTimer = setTimeout(() => dragging && scrub({ clientX, pointerType }), 200);
  };

  el.track.addEventListener('pointerdown', e => {
    if (!state.forecast) return;
    dragging = true;
    el.track.setPointerCapture(e.pointerId);
    grow();
    magnify(e);
    scrub(e);
  });
  el.track.addEventListener('pointermove', e => {
    if (!state.forecast) return;
    if (dragging) scrub(e);
    if (dragging || e.pointerType === 'mouse') magnify(e);
  });
  el.track.addEventListener('pointerenter', e => {
    if (state.forecast && e.pointerType === 'mouse') { grow(); magnify(e); }
  });
  el.track.addEventListener('pointerleave', e => {
    if (!dragging && e.pointerType === 'mouse') shrink();
  });
  const stop = e => {
    dragging = false;
    // touch: stay big for a moment so the result can be read
    if (e.pointerType !== 'mouse') shrink(700);
  };
  el.track.addEventListener('pointerup', stop);
  el.track.addEventListener('pointercancel', stop);

  el.track.addEventListener('keydown', e => {
    if (!state.forecast) return;
    const keys = { ArrowRight: 1, ArrowUp: 1, ArrowLeft: -1, ArrowDown: -1 };
    if (e.key in keys) select(state.selected + keys[e.key]);
    else if (e.key === 'Home') select(0);
    else if (e.key === 'End') select(state.forecast.hours.length - 1);
    else return;
    e.preventDefault();
  });

  // Tap the screen (not a control) to hide / show the top buttons and the
  // low · now · high row; a tap that closes the menu or search doesn't count
  let overlayOpen = false;
  const anyOpen = () => !el.menu.hidden || !el.search.hidden || !el.sheet.hidden;
  const controls = 'button, a, input, .timeline, .menu, .search, .sheet, .toast, .retry';
  el.app.addEventListener('pointerdown', () => { overlayOpen = anyOpen(); }, true);
  el.app.addEventListener('click', e => {
    if (held) { held = false; return; }
    if (overlayOpen || anyOpen()) return;
    if (e.target.closest(controls)) return;
    toggleClean();
  });

  // Long press the screen (not a control) to turn wallpaper mode on or off;
  // moving the finger or a second finger cancels it
  let pressTimer = 0, held = false, start = null;
  const cancel = () => { clearTimeout(pressTimer); start = null; };
  el.app.addEventListener('pointerdown', e => {
    held = false;
    cancel();
    if (e.button || !e.isPrimary || anyOpen() || e.target.closest(controls)) return;
    start = { x: e.clientX, y: e.clientY };
    pressTimer = setTimeout(() => {
      held = true;
      start = null;
      setWallpaper(state.wallpaper === '' ? null : '');
    }, 600);
  });
  el.app.addEventListener('pointermove', e => {
    if (start && Math.hypot(e.clientX - start.x, e.clientY - start.y) > 10) cancel();
  });
  for (const type of ['pointerup', 'pointercancel']) el.app.addEventListener(type, cancel);
  // touch browsers open a context menu on a long press
  el.app.addEventListener('contextmenu', e => {
    if (start || held) e.preventDefault();
  });

  // Global shortcuts
  document.addEventListener('keydown', e => {
    if (!el.search.hidden) {
      if (e.key === 'Escape') closeSearch();
      return;
    }
    if (!el.sheet.hidden) {
      if (e.key === 'Escape') { closeSheet(); $('#btn-random').focus({ preventScroll: true }); }
      return;
    }
    if (e.target.closest('input, [role="slider"]')) return;
    if (e.key === 'k' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); openSearch(); return; }
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const key = e.key.toLowerCase();
    if (key === '/') { e.preventDefault(); openSearch(); }
    else if (e.key === 'R') openSheet();
    else if (key === 'r') $('#btn-random').click();
    else if (key === '?') location.href = 'how.html';
    else if (key === 'h') toggleClean();
    else if (key === 'arrowright' && state.forecast) select(state.selected + 1);
    else if (key === 'arrowleft' && state.forecast) select(state.selected - 1);
    else if (Object.hasOwn(menuKeys, key)) menuKeys[key]();
  });

  // Search: suggestions and pinned places until something is typed
  let timer = 0, controller = null, results = null;
  el.searchInput.addEventListener('input', () => {
    clearTimeout(timer);
    const q = el.searchInput.value.trim();
    if (q.length < 2) { controller?.abort(); results = null; renderSearch(); return; }
    timer = setTimeout(async () => {
      controller?.abort();
      controller = new AbortController();
      try {
        results = await searchCity(q, controller.signal);
        renderSearch(results);
      } catch (err) {
        if (err.name !== 'AbortError') renderSearch([], 'Search unavailable');
      }
    }, 250);
  });
  el.searchForm.addEventListener('submit', e => {
    e.preventDefault();
    if (results?.[0]) pickPlace(results[0]);
  });
  el.searchResults.addEventListener('click', e => {
    const chip = e.target.closest('[data-theme]');
    if (chip) {
      explore.theme = chip.dataset.theme;
      renderSearch();
      el.searchResults.querySelector(`[data-theme="${explore.theme}"]`)?.focus();
      return;
    }
    const go = e.target.closest('[data-go]');
    const pin = e.target.closest('[data-pin]');
    if (pin) {
      const i = +pin.dataset.pin;
      togglePin(searchRows[i]);
      renderSearch(results);
      // keep keyboard focus on the same place's pin
      const same = [...el.searchResults.querySelectorAll('[data-pin]')]
        .find(b => samePlace(searchRows[+b.dataset.pin], pin.place));
      same?.focus({ preventScroll: true });
    } else if (go) {
      pickPlace(searchRows[+go.dataset.go]);
    }
  });
  $('#search-close').addEventListener('click', closeSearch);
  el.search.addEventListener('click', e => { if (e.target === el.search) closeSearch(); });
}

/* ======================================================================
   PLACES: suggestions and pins (pins are stored on this device only)
   ====================================================================== */
/* Explore: live extremes, fetched once per REFRESH_MS while search is used */
const explore = { theme: THEMES[0].id, now: null, time: 0, pending: null, failed: false };

function loadExplore() {
  if (explore.pending) return explore.pending;
  if (explore.now && Date.now() - explore.time < REFRESH_MS) return Promise.resolve();
  explore.failed = false;
  explore.pending = getNowMany(EXPLORE_PLACES)
    .then(now => { explore.now = now; explore.time = Date.now(); })
    .catch(() => { explore.failed = !explore.now; })
    .finally(() => {
      explore.pending = null;
      // still showing the start list: fill it in
      if (!el.search.hidden && el.searchInput.value.trim().length < 2) renderSearch();
    });
  return explore.pending;
}

/* Dice: a tap picks a random Explore theme; a long press (or right
   click, or Shift+R) opens a sheet to choose the theme */
function bindDice() {
  const btn = $('#btn-random');
  let timer = 0, held = false;
  btn.addEventListener('pointerdown', e => {
    held = false;
    clearTimeout(timer);
    if (e.button || state.demo) return;
    timer = setTimeout(() => { held = true; openSheet(); }, 500);
  });
  for (const type of ['pointerup', 'pointerleave', 'pointercancel']) btn.addEventListener(type, () => clearTimeout(timer));
  // touch browsers fire it on a long press too
  btn.addEventListener('contextmenu', e => {
    e.preventDefault();
    clearTimeout(timer);
    held = true;
    openSheet();
  });
  btn.addEventListener('click', e => {
    if (held && e.detail) { held = false; return; }
    state.demo ? randomDemo() : loadRandomExtreme();
  });

  el.sheet.addEventListener('click', e => {
    if (e.target.id === 'sheet-backdrop') return closeSheet();
    const opt = e.target.closest('[data-theme]');
    if (!opt) return;
    closeSheet();
    loadExtreme(THEMES.find(t => t.id === opt.dataset.theme));
  });
}

function openSheet() {
  if (state.demo || !el.sheet.hidden) return;
  closeMenu();
  renderSheet();
  el.sheet.hidden = false;
  el.sheet.querySelector('.sheet__option:not([disabled])')?.focus({ preventScroll: true });
  // fetch or refresh the live data, then grey out the themes with no place
  loadExplore().then(() => { if (!el.sheet.hidden) renderSheet(); });
}

function closeSheet() {
  el.sheet.hidden = true;
}

function renderSheet() {
  const focused = document.activeElement?.dataset.theme;
  $('#sheet-options').innerHTML = THEMES.map(t => {
    const none = explore.now && !extremesFor(t).length;
    return `<button type="button" class="sheet__option" data-theme="${t.id}"${none ? ' disabled' : ''}>${esc(t.name)}</button>`;
  }).join('');
  if (focused) $(`#sheet-options [data-theme="${focused}"]:not([disabled])`)?.focus({ preventScroll: true });
}

/* A theme's most extreme places right now, minus the one on screen */
function extremesFor(theme) {
  const here = state.place && placeKey(state.place);
  return rank(theme.id, explore.now, 3).filter(p => placeKey(p) !== here);
}

function goToExtreme(theme) {
  const list = extremesFor(theme);
  if (!list.length) return false;
  const p = list[Math.floor(Math.random() * list.length)];
  lastDiceTheme = theme.id;
  toast(`${theme.name} right now · ${p.name}`);
  loadPlace({ lat: p.lat, lon: p.lon, label: p.label });
  return true;
}

async function withDiceBusy(fn) {
  const btn = $('#btn-random');
  if (btn.classList.contains('is-busy')) return;
  btn.classList.add('is-busy');
  try { await loadExplore(); } finally { btn.classList.remove('is-busy'); }
  fn();
}

/* One of the chosen theme's most extreme places */
function loadExtreme(theme) {
  withDiceBusy(() => {
    if (!explore.now) toast('Explore unavailable');
    else if (!goToExtreme(theme)) toast(theme.empty || `No ${theme.name.toLowerCase()} right now`);
  });
}

/* A random Explore theme, then one of its most extreme places.
   Falls back to a random capital when the live data can't be fetched */
let lastDiceTheme = '';
function loadRandomExtreme() {
  withDiceBusy(() => {
    if (!explore.now) return loadRandomCity();
    const themes = THEMES.filter(t => t.id !== lastDiceTheme).sort(() => Math.random() - 0.5);
    if (!themes.some(goToExtreme)) loadRandomCity();
  });
}

function renderExplore(row) {
  const chips = THEMES.map(t =>
    `<button type="button" class="chip" data-theme="${t.id}" aria-pressed="${t.id === explore.theme}">${esc(t.name)}</button>`).join('');
  let html = `<li class="search__heading" role="presentation">Explore extremes, live</li>
    <li class="chips" role="presentation">${chips}</li>`;
  if (!explore.now) {
    const msg = explore.failed ? 'Explore unavailable' : 'Looking around the world…';
    return html + `<li class="search__empty">${msg}</li>`;
  }
  const theme = THEMES.find(t => t.id === explore.theme);
  const list = rank(theme.id, explore.now);
  if (!list.length) return html + `<li class="search__empty">${esc(theme.empty)}</li>`;
  return html + list.map(p => {
    const { timeColor, tempColor } = skyFor(p.now, p.offset, p.daylight);
    const cond = p.condition.charAt(0).toUpperCase() + p.condition.slice(1);
    const note = [`${toUnit(p.now.temp)}°${state.unit}`, cond, p.detail].filter(Boolean).join(' · ');
    return row({ name: p.name, region: p.region, note, label: p.label, lat: p.lat, lon: p.lon, from: timeColor, to: tempColor });
  }).join('');
}

const ICON_PIN = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 3.5h6l-1 6 3.5 3.5h-11L10 9.5z"/><path d="M12 13v7.5"/></svg>';

let searchRows = [];

function placeKey(p) {
  if (p.demo) return `scene:${p.demo}`;
  return `${(+p.lat).toFixed(2)},${(+p.lon).toFixed(2)}`;
}

function samePlace(a, b) {
  return !!a && !!b && placeKey(a) === placeKey(b);
}

function loadPins() {
  try { return JSON.parse(localStorage.getItem('tc-pins')) || []; } catch { return []; }
}

function togglePin(place) {
  const pins = loadPins();
  const i = pins.findIndex(p => samePlace(p, place));
  if (i >= 0) pins.splice(i, 1);
  else if (place.demo) {
    const { name, region, label, demo, from, to, forecast, selected, time, temp, cond } = place;
    pins.push({ name, region, label, demo, from, to, forecast, selected, time, temp, cond });
  }
  else pins.push({ name: place.name, region: place.region, label: place.label, lat: place.lat, lon: place.lon });
  try { localStorage.setItem('tc-pins', JSON.stringify(pins)); } catch {}
}

/* list = null: pinned places, saved scenes and Explore; otherwise search results */
function renderSearch(list = null, empty = 'No cities found') {
  const pins = loadPins();
  const rows = [];
  const heading = text => `<li class="search__heading" role="presentation">${text}</li>`;
  const row = place => {
    const i = rows.push(place) - 1;
    const pinned = pins.some(p => samePlace(p, place));
    // saved pictures show their sky
    const hex = c => (/^#[0-9a-f]{6}$/i.test(c || '') ? c : null);
    const sky = hex(place.from) && hex(place.to)
      ? `<i class="place__sky" style="background:linear-gradient(-65deg, ${hex(place.from)}, ${hex(place.to)})"></i>` : '';
    return `<li class="place">
      <button type="button" class="place__go" data-go="${i}">${sky}<span>${esc(place.name)}<small>${esc([place.note, place.region].filter(Boolean).join(' · '))}</small></span></button>
      <button type="button" class="place__pin" data-pin="${i}" aria-pressed="${pinned}" aria-label="${pinned ? 'Unpin' : 'Pin'} ${esc(place.name)}" title="${pinned ? 'Unpin' : 'Pin'}">${ICON_PIN}</button>
    </li>`;
  };

  let html = '';
  if (list === null) {
    const pinnedPlaces = pins.filter(p => !p.demo), scenes = pins.filter(p => p.demo).map(sceneRow);
    if (pinnedPlaces.length) html += heading('Pinned') + pinnedPlaces.map(row).join('');
    if (scenes.length) html += heading('Saved scenes') + scenes.map(row).join('');
    html += renderExplore(row);
  } else {
    html = list.length ? list.map(row).join('') : `<li class="search__empty">${empty}</li>`;
  }
  searchRows = rows;
  el.searchResults.innerHTML = html;
  // remember which place each pin button belongs to (for focus after re-render)
  el.searchResults.querySelectorAll('[data-pin]').forEach(b => { b.place = rows[+b.dataset.pin]; });
}

/* A saved scene's line in search, in the current unit (older scenes
   saved the text, in the unit of the day) */
function sceneRow(p) {
  if (typeof p.temp !== 'number') return p;
  return { ...p, region: `${p.time} · ${toUnit(p.temp)}°${state.unit} · ${p.cond}` };
}

function pickPlace(place) {
  closeSearch();
  if (place.demo) {
    writeURL(new URLSearchParams(`demo&${place.demo}`));
    if (place.forecast) return openScene(place);
    return startDemo(new URLSearchParams(place.demo));
  }
  loadPlace({ lat: place.lat, lon: place.lon, label: place.label });
}

/* ======================================================================
   OPTIONS MENU: location, save picture, share, pin, how it works, units
   ====================================================================== */
function bindMenu() {
  el.menuBtn.addEventListener('click', () => (el.menu.hidden ? openMenu() : closeMenu()));
  document.addEventListener('pointerdown', e => {
    if (!el.menu.hidden && !el.menu.contains(e.target) && !el.menuBtn.contains(e.target)) closeMenu();
  });
  el.menu.addEventListener('keydown', e => {
    if (e.key === 'Escape') { closeMenu(); el.menuBtn.focus(); }
  });
  $('#menu-locate').addEventListener('click', () => { closeMenu(); locate(); });
  $('#menu-save').addEventListener('click', () => { closeMenu(); savePicture(); });
  $('#menu-scene').addEventListener('click', () => { closeMenu(); saveScene(); });
  $('#menu-share').addEventListener('click', () => { closeMenu(); share(); });
  $('#menu-wallpaper').addEventListener('click', () => setWallpaper(''));
  $('#menu-pin').addEventListener('click', () => {
    const place = currentPlace();
    if (!place) return;
    togglePin(place);
    syncMenu();
    toast(isPinned(place) ? `Pinned ${place.name}` : `Unpinned ${place.name}`);
  });
  el.menu.querySelectorAll('[data-unit]').forEach(b => b.addEventListener('click', () => setUnit(b.dataset.unit)));
}

/* Clean view (?wallpaper=info): only the sky, the circle, the words and
   the bars. A tap turns it on or off, and leaves the sky-only view */
/* The options menu's keys, shown next to each item */
const menuKeys = {
  l: () => $('#menu-locate').click(),
  w: () => setWallpaper(state.wallpaper === '' ? null : ''),
  p: () => menuAction('#menu-pin'),
  s: () => menuAction('#menu-scene'),
  d: () => menuAction('#menu-save'),
  e: () => menuAction('#menu-share'),
  u: () => setUnit(state.unit === 'C' ? 'F' : 'C'),
};

/* Run a menu item without opening the menu: drop a picture drawn the
   last time it opened, it may show another hour or place */
function menuAction(sel) {
  syncMenu();
  state.picture = null;
  $(sel).click();
}

function toggleClean() {
  setWallpaper(state.wallpaper === null ? 'info' : null);
}

/* null: everything · 'info': clean view · '': only the sky and the circle,
   for desktop wallpaper apps. Kept in the URL so the view can be shared */
function setWallpaper(mode) {
  state.wallpaper = mode;
  document.body.classList.toggle('is-clean', mode !== null);
  document.body.classList.toggle('is-wallpaper', mode === '');
  if (mode !== null) closeMenu();
  else clearTimeout(state.retryTimer);
  writeURL(new URLSearchParams(location.search));
}

function openMenu() {
  syncMenu();
  // draw the picture now: the share sheet must open right after the tap
  state.picture = state.forecast ? pictureFile().catch(() => null) : null;
  el.menu.hidden = false;
  el.menuBtn.setAttribute('aria-expanded', 'true');
  el.menu.querySelector('.menu__item').focus({ preventScroll: true });
}

function closeMenu() {
  el.menu.hidden = true;
  el.menuBtn.setAttribute('aria-expanded', 'false');
}

function syncMenu() {
  const place = currentPlace();
  const pinned = !!place && isPinned(place);
  const pin = $('#menu-pin');
  pin.disabled = !place;
  pin.setAttribute('aria-checked', String(pinned));
  $('#menu-pin-label').textContent = !place ? 'Pin this place' : pinned ? `Unpin ${place.name}` : `Pin ${place.name}`;
  el.menu.querySelectorAll('[data-unit]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.unit === state.unit)));
  const ready = !!state.forecast;
  $('#menu-save').disabled = !ready;
  $('#menu-scene').disabled = !ready;
  $('#menu-share').disabled = !ready;
}

function setUnit(unit) {
  state.unit = unit;
  try { localStorage.setItem('tc-unit', unit); } catch {}
  if (state.forecast) { render(); renderRange(); markSelected(); }
  // saved scenes in the open search list show their temperature too
  if (!el.search.hidden && el.searchInput.value.trim().length < 2) renderSearch();
  syncMenu();
}

/* The place on screen as a pin-able place (not in demo mode) */
function currentPlace() {
  if (!state.place || state.demo || !state.forecast) return null;
  const [name, ...rest] = state.place.label.split(',');
  return { name: name.trim(), region: rest.join(',').trim(), label: state.place.label, lat: state.place.lat, lon: state.place.lon };
}

function isPinned(place) {
  return loadPins().some(p => samePlace(p, place));
}

function shareLink() {
  const p = state.place;
  const q = new URLSearchParams({ lat: p.lat.toFixed(3), lon: p.lon.toFixed(3), name: p.label || '' });
  return `${location.origin}${location.pathname}?${q}`;
}

function shareText() {
  const h = state.forecast.hours[state.selected];
  const cond = state.sky?.label || '';
  const when = h.isNow ? '' : ` at ${el.label.dataset.text?.split(' · ')[0] || ''}`;
  return `${cond.charAt(0).toUpperCase() + cond.slice(1)}, ${toUnit(h.temp)}°${state.unit} in ${state.place.label}${when}`;
}

async function pictureFile() {
  const blob = await renderPicture({ sky: state.sky, sceneCanvas: $('.scene'), root: el.app });
  const city = (state.place?.label || 'huecast').split(',')[0].toLowerCase().normalize('NFD').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  const local = new Date(Date.now() + (state.forecast?.offset || 0) * 1000);
  const stamp = `${local.getUTCFullYear()}-${pad(local.getUTCMonth() + 1)}-${pad(local.getUTCDate())}-${pad(local.getUTCHours())}${pad(local.getUTCMinutes())}`;
  return new File([blob], `huecast-${city}-${stamp}.png`, { type: 'image/png' });
}

/* Save as picture: a PNG of the screen. Downloads it; in the installed
   iOS app (no downloads) it opens the share sheet ("Save Image") */
async function savePicture() {
  try {
    const file = (await state.picture) || (await pictureFile());
    if (navigator.standalone && navigator.canShare?.({ files: [file] })) {
      await navigator.share({ files: [file] });
      return;
    }
    const url = URL.createObjectURL(file);
    const a = Object.assign(document.createElement('a'), { href: url, download: file.name });
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10000);
    toast('Picture saved');
  } catch (err) {
    if (err.name !== 'AbortError') toast('Could not save the picture');
  }
}

/* Save as scene: keep this scene (place, weather, hour, amounts) as a
   demo that can be reopened from the pins in search. The whole forecast
   goes with it so the timeline reopens as it was; the URL params are the
   fallback for older pins and shared links */
function saveScene() {
  const h = state.forecast.hours[state.selected];
  const { local, hour, cond, timeColor, tempColor } = skyFor(h, state.forecast.offset, state.forecast.daylight);
  const params = new URLSearchParams({
    code: h.code, temp: h.temp.toFixed(1), hour: hour.toFixed(2), wind: Math.round(h.wind || 0),
    day: h.isDay ? 1 : 0, name: state.place.label, saved: 1,
  });
  for (const k of ['rain', 'snow', 'vis', 'gust', 'cloud', 'lowCloud']) {
    const v = h.data?.[k];
    if (typeof v === 'number' && Number.isFinite(v)) params.set(k, +v.toFixed(2));
  }
  params.sort();
  const demo = params.toString();
  const city = state.place.label.split(',')[0].trim();
  const time = `${pad(local.getUTCHours())}:${pad(local.getUTCMinutes())}`;
  const scene = {
    name: city,
    time, temp: h.temp, cond: cond.label,
    label: state.place.label,
    demo, from: timeColor, to: tempColor,
    forecast: frozenForecast(), selected: state.selected,
  };
  if (isPinned(scene)) return toast('Already saved');
  togglePin(scene);
  toast('Scene saved · find it in search');
}

// The forecast as saved: "now" becomes the moment it was saved
function frozenForecast() {
  const saved = Math.floor(Date.now() / 1000);
  return { ...state.forecast, hours: state.forecast.hours.map(({ isNow, ...h }) => (isNow ? { ...h, time: saved } : h)) };
}

function openScene({ forecast, selected = 0, label }) {
  showScene({ forecast, selected: Math.min(selected, forecast.hours.length - 1), label, saved: true });
}

async function share() {
  const data = { title: 'Huecast', text: shareText(), url: shareLink() };
  try {
    if (navigator.share) {
      // with the picture where the platform supports sharing files
      const file = await (state.picture || pictureFile().catch(() => null));
      if (file && navigator.canShare?.({ ...data, files: [file] })) data.files = [file];
      await navigator.share(data);
      return;
    }
    await navigator.clipboard.writeText(`${data.text} ${data.url}`);
    toast('Link copied');
  } catch (err) {
    if (err.name !== 'AbortError') toast('Could not share');
  }
}

function openSearch() {
  el.search.hidden = false;
  el.searchInput.value = '';
  loadExplore();
  renderSearch();
  requestAnimationFrame(() => el.searchInput.focus());
}

function closeSearch() {
  el.search.hidden = true;
  $('#btn-search').focus({ preventScroll: true });
}

let toastTimer = 0;
function toast(msg, ms = 3500) {
  el.toast.textContent = msg;
  el.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.toast.hidden = true; }, ms);
}

/* ======================================================================
   DEMO MODE  (?demo  or  ?demo&code=95&temp=24&hour=22&wind=40)
   Fake data, no network - successor of the old initDevelopment()
   ====================================================================== */
function startDemo(params) {
  // a saved scene reopened from its link: use its forecast if it's pinned here
  if (params.get('saved') === '1') {
    const key = new URLSearchParams(params);
    key.delete('demo');
    key.delete('wallpaper');
    key.sort();
    const pin = loadPins().find(p => p.demo === key.toString());
    if (pin?.forecast) return openScene(pin);
  }
  const num = (k, d) => (params.has(k) ? parseFloat(params.get(k)) : d);
  const c = cities[Math.floor(Math.random() * cities.length)];
  buildDemo({
    code: num('code', CODES[Math.floor(Math.random() * CODES.length)]),
    temp: num('temp', Math.round(Math.random() * 45 - 8)),
    hour: num('hour', Math.random() * 24),
    wind: num('wind', Math.random() * 40),
    // optional measured amounts: &rain= mm/h, &snow= cm/h, &vis= m, &gust= km/h,
    // &cloud= % of the sky, &lowCloud= % of low and mid cloud
    data: { rain: num('rain'), snow: num('snow'), vis: num('vis'), gust: num('gust'),
            cloud: num('cloud'), lowCloud: num('lowCloud') },
    day: params.has('day') ? params.get('day') === '1' : undefined,
    saved: params.get('saved') === '1',
    label: params.get('name') || cityLabel(c),
  });
}

function randomDemo() {
  startDemo(new URLSearchParams());
}

function buildDemo({ code, temp, hour, wind, data = {}, day, saved = false, label }) {
  // Pretend the location's clock reads `hour` right now
  const nowUtc = Date.now();
  const d = new Date(nowUtc);
  const deviceHour = d.getUTCHours() + d.getUTCMinutes() / 60;
  const offset = Math.round((hour - deviceHour) * 3600);
  const startHour = Math.floor((nowUtc / 1000 + 3600) / 3600) * 3600;
  const isDayAt = t => isDayHour(new Date((t + offset) * 1000).getUTCHours());

  const hours = [{ time: Math.floor(nowUtc / 1000), temp, code, isDay: day ?? isDayAt(nowUtc / 1000), wind, data, isNow: true }];
  for (let i = 0; i < 24; i++) {
    const t = startHour + i * 3600;
    const lh = new Date((t + offset) * 1000).getUTCHours();
    hours.push({
      time: t,
      temp: temp + Math.sin(((lh - 9) / 24) * Math.PI * 2) * 4 - 2 + Math.random(),
      code: i < 6 ? code : CODES[Math.floor(Math.random() * CODES.length)],
      data: i < 6 ? data : {},
      isDay: isDayAt(t),
      wind,
    });
  }
  showScene({ forecast: { offset, hours }, selected: 0, label, saved });
}

function showScene({ forecast, selected, label, saved }) {
  // a scene is fixed: the live place's refresh must not replace it
  clearInterval(state.refreshTimer);
  state.demo = saved ? 'saved' : true;
  document.body.classList.toggle('is-demo', !saved);
  el.domlog.hidden = true;
  state.place = { lat: 0, lon: 0, label };
  state.forecast = forecast;
  state.selected = selected;
  state.lastKey = '';
  el.retry.hidden = true;
  buildTimeline();
  render();
}

/* ======================================================================
   UTILS
   ====================================================================== */
function shareURL(place) {
  writeURL(new URLSearchParams({ lat: place.lat.toFixed(3), lon: place.lon.toFixed(3), name: place.label || '' }));
}

function clearShare() {
  writeURL(new URLSearchParams());
}

// Replace the query with these params plus the wallpaper view; flags like
// demo and wallpaper stay bare (?demo&wallpaper, not ?demo=&wallpaper=)
function writeURL(params) {
  params.delete('wallpaper');
  if (state.wallpaper !== null) params.set('wallpaper', state.wallpaper);
  const q = [...params].map(([k, v]) => (v ? `${k}=${encodeURIComponent(v)}` : k)).join('&');
  history.replaceState(null, '', q ? `?${q}` : location.pathname);
}

function savePlace(place) {
  try { localStorage.setItem('tc-place', JSON.stringify(place)); } catch {}
}

function loadSavedPlace() {
  try { return JSON.parse(localStorage.getItem('tc-place')); } catch { return null; }
}

function loadUnit() {
  try {
    const saved = localStorage.getItem('tc-unit');
    if (saved) return saved;
  } catch {}
  return /^en-(US|LR|MM)$/.test(navigator.language) ? 'F' : 'C';
}

function formatCoords({ lat, lon }) {
  return `${Math.abs(lat).toFixed(2)}°${lat >= 0 ? 'N' : 'S'}, ${Math.abs(lon).toFixed(2)}°${lon >= 0 ? 'E' : 'W'}`;
}

function cityLabel([city, country, , , code]) {
  return `${city}, ${code || country}`;
}

function pad(n) {
  return String(n).padStart(2, '0');
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/* Size the app to the real screen. In the installed iOS app (translucent
   status bar) the reported viewport is short by the status bar's height,
   so use the screen height there; elsewhere the window height. */
function fitScreen() {
  const standalone = navigator.standalone === true;
  el.root.classList.toggle('is-standalone', standalone);
  // iOS 26 tints the top of the installed app with theme-color and fades it
  // into the page: a dark blurred band over the top buttons. The sky runs
  // under the translucent status bar anyway, so drop it there
  if (standalone) el.themeColor.remove();
  const measure = () => {
    let h = window.innerHeight;
    if (standalone) {
      const portrait = matchMedia('(orientation: portrait)').matches;
      h = Math.max(h, portrait ? Math.max(screen.width, screen.height) : Math.min(screen.width, screen.height));
    }
    el.root.style.setProperty('--app-h', `${h}px`);
    scene.resize();
  };
  measure();
  window.addEventListener('resize', measure);
  window.addEventListener('orientationchange', () => setTimeout(measure, 300));
  // the screen-tall page must never scroll by the hidden strip
  if (standalone) window.addEventListener('scroll', () => { if (window.scrollY) window.scrollTo(0, 0); }, { passive: true });

  // hidden check screen: tap the date 5 times
  let taps = 0, tapTimer = 0;
  el.date.addEventListener('click', () => {
    taps++;
    clearTimeout(tapTimer);
    tapTimer = setTimeout(() => { taps = 0; }, 1200);
    if (taps >= 5) { taps = 0; toggleDiagnostics(); }
  });
}

function toggleDiagnostics() {
  const old = document.getElementById('diag');
  if (old) { old.cleanup?.(); return old.remove(); }
  const probe = v => {
    const d = document.createElement('div');
    d.style.cssText = `position:absolute;visibility:hidden;height:${v}`;
    document.body.append(d);
    const px = d.getBoundingClientRect().height;
    d.remove();
    return Math.round(px);
  };
  const cs = getComputedStyle(el.root);
  const safe = side => probe(`env(safe-area-inset-${side})`);
  const rows = {
    standalone: navigator.standalone,
    screen: `${screen.width}x${screen.height}`,
    inner: `${innerWidth}x${innerHeight}`,
    visualVP: window.visualViewport ? Math.round(visualViewport.height) : '-',
    docClient: document.documentElement.clientHeight,
    '100vh': probe('100vh'), '100lvh': probe('100lvh'), '100dvh': probe('100dvh'), '100svh': probe('100svh'),
    'safe top/bottom': `${safe('top')}/${safe('bottom')}`,
    'app-h': cs.getPropertyValue('--app-h'),
    appRect: Math.round(el.app.getBoundingClientRect().bottom),
  };
  const d = document.createElement('div');
  d.id = 'diag';
  d.style.cssText = 'position:fixed;z-index:99;left:12px;top:90px;padding:10px 12px;border-radius:12px;background:rgba(0,0,0,.75);color:#fff;font:11px/1.6 ui-monospace,monospace;white-space:pre;user-select:text;-webkit-user-select:text';
  d.textContent = Object.entries(rows).map(([k, v]) => `${k}: ${v}`).join('\n') +
    '\n\nbottom markers:\nred = fixed bottom:0\ngreen = inside app\nblue = fixed 100vh\nyellow = page bottom\npage background = magenta';
  // markers at the bottom by three methods
  const mark = (css, color) => {
    const m = document.createElement('div');
    m.style.cssText = `position:fixed;z-index:98;height:6px;background:${color};${css}`;
    d.append(m);
  };
  mark('left:0;width:25%;bottom:0', '#f33');
  mark('left:50%;width:25%;top:calc(100vh - 6px)', '#39f');
  const inApp = document.createElement('div');
  inApp.style.cssText = 'position:absolute;z-index:98;left:25%;width:25%;bottom:0;height:6px;background:#3f3';
  const inPage = document.createElement('div');
  inPage.style.cssText = `position:absolute;z-index:98;left:75%;width:25%;top:calc(${cs.getPropertyValue('--app-h') || '100%'} - 6px);height:6px;background:#fd0`;
  el.app.append(inApp);
  document.body.append(d, inPage);
  const bg = el.root.style.backgroundColor;
  el.root.style.backgroundColor = '#f0f';
  d.cleanup = () => { inApp.remove(); inPage.remove(); el.root.style.backgroundColor = bg; };
}

function registerServiceWorker() {
  if (!('serviceWorker' in navigator) || location.protocol === 'file:') return;
  // a page served by an older worker reloads once when the new one takes
  // over, so a deploy never leaves old files on screen
  const hadController = !!navigator.serviceWorker.controller;
  let reloaded = false;
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (hadController && !reloaded) {
      reloaded = true;
      location.reload();
    }
  });
  navigator.serviceWorker.register('sw.js', { updateViaCache: 'none' }).catch(() => {});
}
