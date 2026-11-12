/* Background colours. Same palette as the 2016 version (then called Timecast), but
 * blended between stops instead of jumping from bucket to bucket.
 * Blending happens in OKLCH so in-between colours stay clean
 * (purple -> yellow passes through pink, not olive).
 */

// [celsius, colour token] - midpoints of the original temperature buckets
const TEMP_STOPS = [
  [-20,  '--temp-polar'],
  [-10,  '--temp-ice'],
  [-5,   '--temp-glacier'],
  [0,    '--temp-frost'],
  [4,    '--temp-chilly'],
  [8,    '--temp-cold'],
  [12.5, '--temp-warm'],
  [17.5, '--temp-hot'],
  [25,   '--temp-very-hot'],
  [35,   '--temp-damn-hot'],
];

// [sky hour, colour token] (cyclic). Sky hours put sunrise at 07:00 and
// sunset at 20:00 (see skyHour), so the stops are placed around the sun:
// dawn at sunrise, blue daylight held through the afternoon, a dusky
// rose at sunset, then a navy evening and night
const TIME_STOPS = [
  [3,    '--time-night'],
  [7,    '--time-dawn'],      // sunrise
  [9.5,  '--time-morning'],
  [13,   '--time-noon'],
  [17.5, '--time-noon'],      // afternoon stays bright
  [20,   '--time-dusk'],      // sunset
  [22,   '--time-evening'],
  [27,   '--time-night'],     // = 3h next day
];

/* Colour tokens live in css/tokens.css; read them once */
const cache = {};
export function token(name) {
  if (!(name in cache)) {
    cache[name] = getComputedStyle(document.documentElement).getPropertyValue(name).trim().toLowerCase();
  }
  return cache[name];
}

const resolve = stops => stops.map(([v, name]) => [v, token(name)]);

export function colorByCelsius(celsius) {
  return interpolate(resolve(TEMP_STOPS), celsius);
}

export function colorByHour(hour) {
  const h = hour < 3 ? hour + 24 : hour;
  return interpolate(resolve(TIME_STOPS), h);
}

export { TEMP_STOPS, TIME_STOPS };

/* Bad weather drains colour from the sky: sat 1 = untouched, 0 = grey */
export function desaturate(hex, sat) {
  if (sat >= 1) return hex;
  const [l, c, h] = hexToOklch(hex);
  return oklchToHex([l * (0.92 + 0.08 * sat), c * sat, h]);
}

/* Night: darken toward the night colour but keep most of the hue and
   colour, so a -10° night is a deep blue and a mild night stays warm */
export function nightShade(hex, night, t = 0.55) {
  const [l, c, h] = hexToOklch(hex);
  const [ln] = hexToOklch(night);
  return oklchToHex([l + (ln - l) * t, c * (1 - 0.45 * t), h]);
}

/* Lift toward white: snowy skies are bright, not grey */
export function lift(hex, amount) {
  if (!amount) return hex;
  const [l, c, h] = hexToOklch(hex);
  return oklchToHex([l + (1 - l) * amount, c * (1 - amount * 0.4), h]);
}

/* The two sky colours for an hour: time of day and temperature, adjusted
   for night and weather. Shared by the app, the picture and the info page */
const TEMP_TINT = 0.4;

export function skyColors({ hour, temp, isDay, fx }) {
  const hourColor = colorByHour(hour);
  let tempColor = colorByCelsius(temp);
  if (!isDay) tempColor = nightShade(tempColor, hourColor, 0.55);
  // the sky leads: temperature only tints it, so a screen keeps to one
  // colour family instead of two competing ones
  tempColor = mix(hourColor, tempColor, TEMP_TINT);
  const timeColor = desaturate(hourColor, fx.sat);
  tempColor = desaturate(tempColor, fx.sat);
  // snow brightens the sky (less so at night)
  const up = (fx.lift || 0) * (isDay ? 1 : 0.4);
  return { timeColor: lift(timeColor, up), tempColor: lift(tempColor, up) };
}

/* Sun intensity, from the original returnColorByCelsius side effects */
export const SUN_STEPS = [
  { min: 40, name: 'Scorching', pulses: 5, big: true, shining: true, blazing: true, duration: 2 },
  { min: 30, name: 'Very hot', pulses: 4, big: true, shining: true, duration: 2.5 },
  { min: 20, name: 'Hot', pulses: 2, big: true, shining: true, duration: 2.5 },
  { min: 15, name: 'Warm', pulses: 1, big: false, shining: false, duration: 3 },
  { min: -Infinity, name: 'Mild', pulses: 0, big: false, shining: false, duration: 3 },
];

export function sunIntensity(celsius) {
  return SUN_STEPS.find(s => celsius >= s.min);
}

/* The clock day the time-of-day colours were made for */
const SUNRISE_HOUR = 7;
const SUNSET_HOUR = 20;

/* Day or night from the clock alone, for skies without real sunrise
   and sunset (demo mode and the "How it works" page) */
export function isDayHour(hour) {
  return hour >= SUNRISE_HOUR && hour < SUNSET_HOUR;
}

/* The hour the colours are picked for: the real sunrise lands on 07:00
   and the real sunset on 20:00, with the hours between stretched to fit,
   so a short winter day or a long summer evening keeps its colours in
   step with the sun. t: unix seconds; daylight: [[sunrise, sunset], ...]
   in unix seconds, one pair per local day. Without it, or in polar day
   or night (no sunrise or sunset), the clock hour is used as is */
export function skyHour(hour, t, daylight) {
  const ok = ([r, s]) => s - r > 1800 && s - r < 86400 - 1800;
  if (!daylight?.length || !daylight.every(ok)) return hour;
  // sunset the day before, then each sunrise and sunset, then the next sunrise
  const events = [daylight[0][1] - 86400, ...daylight.flat(), daylight.at(-1)[0] + 86400];
  const i = events.findIndex(e => e > t);
  if (i < 1) return hour;
  const f = (t - events[i - 1]) / (events[i] - events[i - 1]);
  const isDay = i % 2 === 0; // after a sunrise (odd index), before a sunset
  return isDay
    ? SUNRISE_HOUR + f * (SUNSET_HOUR - SUNRISE_HOUR)
    : (SUNSET_HOUR + f * (24 - SUNSET_HOUR + SUNRISE_HOUR)) % 24;
}

/* Stars, from the original returnColorByCurrentTime side effects */
export function starsByHour(hour) {
  if (hour >= 19 || hour < 6) return 80;
  if (hour >= 16) return 50;
  return 0;
}

export function luminance(hex) {
  const [r, g, b] = hexToRgb(hex).map(v => toLinear(v / 255));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/* Perceptual mix in OKLCH (shortest way round the hue circle) */
export function mix(a, b, t = 0.5) {
  const [l1, c1, h1] = hexToOklch(a);
  const [l2, c2, h2] = hexToOklch(b);
  // a grey has no meaningful hue: borrow the other colour's
  const ha = c1 < 0.02 ? h2 : h1;
  const hb = c2 < 0.02 ? h1 : h2;
  let dh = hb - ha;
  if (dh > 180) dh -= 360;
  if (dh < -180) dh += 360;
  // far-apart hues (a blue sky and a warm temperature) would sweep a
  // rainbow, or pass through green: blend straight across (OKLab) instead,
  // through a soft haze, so a sky shows two colours, not five
  if (Math.min(c1, c2) >= 0.02 && (Math.abs(dh) > 90 || crossesGreen(ha, dh))) return mixLab([l1, c1, h1], [l2, c2, h2], t);
  return oklchToHex([l1 + (l2 - l1) * t, c1 + (c2 - c1) * t, ha + dh * t]);
}

function mixLab([l1, c1, h1], [l2, c2, h2], t) {
  const r = Math.PI / 180;
  const a = c1 * Math.cos(h1 * r) * (1 - t) + c2 * Math.cos(h2 * r) * t;
  const b = c1 * Math.sin(h1 * r) * (1 - t) + c2 * Math.sin(h2 * r) * t;
  return oklchToHex([l1 + (l2 - l1) * t, Math.hypot(a, b), (Math.atan2(b, a) / r + 360) % 360]);
}

const GREEN = [125, 195]; // OKLCH hues between yellow and sky blue
function crossesGreen(h, dh) {
  for (let i = 1; i < 8; i++) {
    const x = ((h + dh * i / 8) % 360 + 360) % 360;
    if (x > GREEN[0] && x < GREEN[1]) return true;
  }
  return false;
}

/* A CSS gradient between two sky colours, with the in-between stops
   worked out by mix() so every browser shows the same blend */
export function skyGradient(angle, from, to, steps = 6) {
  const stops = Array.from({ length: steps + 1 }, (_, i) => mix(from, to, i / steps));
  return `linear-gradient(${angle}, ${stops.join(', ')})`;
}

export function hexToRgb(hex) {
  const h = hex.replace('#', '');
  return [0, 2, 4].map(i => parseInt(h.slice(i, i + 2), 16));
}

function interpolate(stops, value) {
  if (value <= stops[0][0]) return stops[0][1];
  for (let i = 1; i < stops.length; i++) {
    const [v1, c1] = stops[i];
    if (value <= v1) {
      const [v0, c0] = stops[i - 1];
      // ease so most of each bucket keeps its original colour
      const t = smoothstep((value - v0) / (v1 - v0));
      return mix(c0, c1, t);
    }
  }
  return stops[stops.length - 1][1];
}

function smoothstep(t) {
  return t * t * (3 - 2 * t);
}

/* ---- sRGB <-> OKLCH (https://bottosson.github.io/posts/oklab/) ---- */

function hexToOklch(hex) {
  const [r, g, b] = hexToRgb(hex).map(v => toLinear(v / 255));
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  const L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
  const A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
  const B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
  return [L, Math.hypot(A, B), (Math.atan2(B, A) * 180 / Math.PI + 360) % 360];
}

function oklchToHex([L, C, H]) {
  const a = C * Math.cos(H * Math.PI / 180);
  const b = C * Math.sin(H * Math.PI / 180);
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3;
  const rgb = [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  ];
  return '#' + rgb.map(v => {
    const c = Math.round(Math.min(Math.max(toGamma(v), 0), 1) * 255);
    return c.toString(16).padStart(2, '0');
  }).join('');
}

function toLinear(v) {
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
}

function toGamma(v) {
  return v <= 0.0031308 ? 12.92 * v : 1.055 * Math.max(v, 0) ** (1 / 2.4) - 0.055;
}
