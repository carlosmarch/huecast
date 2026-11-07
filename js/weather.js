/* Data sources - all free, HTTPS and keyless:
 *  - Open-Meteo forecast   https://open-meteo.com
 *  - Open-Meteo geocoding  (city search)
 *  - BigDataCloud          (reverse geocoding: coords -> city name)
 */

const FORECAST_URL = 'https://api.open-meteo.com/v1/forecast';
const SEARCH_URL = 'https://geocoding-api.open-meteo.com/v1/search';
const REVERSE_URL = 'https://api.bigdatacloud.net/data/reverse-geocode-client';

export async function getForecast(lat, lon) {
  const params = new URLSearchParams({
    latitude: lat,
    longitude: lon,
    current: 'temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m',
    hourly: 'temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m,wind_gusts_10m,rain,showers,snowfall,visibility,' +
      'cloud_cover,cloud_cover_low,cloud_cover_mid',
    daily: 'sunrise,sunset,temperature_2m_min,temperature_2m_max,weather_code',
    forecast_days: 7,
    timezone: 'auto',
    timeformat: 'unixtime',
  });
  const data = await getJSON(`${FORECAST_URL}?${params}`);
  const offset = data.utc_offset_seconds || 0;
  const c = data.current;

  // Amounts that drive the intensity steps (rain mm/h, snow cm/h,
  // visibility m, gusts km/h, cloud %); missing values stay undefined
  const h = data.hourly;
  const at = (key, i) => (h[key] && typeof h[key][i] === 'number' ? h[key][i] : undefined);
  const amounts = i => {
    const rain = at('rain', i), showers = at('showers', i);
    return {
      rain: rain === undefined && showers === undefined ? undefined : (rain || 0) + (showers || 0),
      snow: at('snowfall', i),
      vis: at('visibility', i),
      gust: at('wind_gusts_10m', i),
      cloud: at('cloud_cover', i),
      lowCloud: thick(at('cloud_cover_low', i), at('cloud_cover_mid', i)),
    };
  };
  // the hourly row covering "now" gives the current amounts
  const nowRow = h.time.findIndex(t => t <= c.time && c.time < t + 3600);

  const now = {
    time: c.time,
    temp: c.temperature_2m,
    feels: c.apparent_temperature,
    code: c.weather_code,
    isDay: !!c.is_day,
    wind: c.wind_speed_10m,
    data: nowRow >= 0 ? amounts(nowRow) : {},
  };

  const hour = i => ({
    time: h.time[i],
    temp: h.temperature_2m[i],
    feels: at('apparent_temperature', i),
    code: h.weather_code[i],
    isDay: !!h.is_day[i],
    wind: h.wind_speed_10m[i],
    data: amounts(i),
  });

  // Next 24 hours, starting with the current conditions
  const hours = [{ ...now, isNow: true }];
  for (let i = 0; i < h.time.length && hours.length < 25; i++) {
    if (h.time[i] > c.time) hours.push(hour(i));
  }

  return { offset, hours, days: days(data.daily, h, offset, hour), daylight: daylight(data.daily) };
}

/* The coming days after today, each with its 24 local hours (00-23):
   [{ time, min, max, code, hours[] }]. Days missing hours are left out
   (clock changes give 23 or 25) */
function days(d, h, offset, hour) {
  if (!d || !Array.isArray(d.time)) return [];
  const dayOf = t => Math.floor((t + offset) / 86400);
  const byDay = new Map();
  h.time.forEach((t, i) => {
    const k = dayOf(t);
    if (!byDay.has(k)) byDay.set(k, []);
    byDay.get(k).push(hour(i));
  });
  return d.time.slice(1).map((t, j) => ({
    time: t,
    min: d.temperature_2m_min?.[j + 1],
    max: d.temperature_2m_max?.[j + 1],
    code: d.weather_code?.[j + 1],
    hours: byDay.get(dayOf(t)) || [],
  })).filter(day => day.hours.length >= 23);
}

/* Low and mid cloud: the layers that grey the sky (high cloud is thin) */
function thick(low, mid) {
  if (typeof low !== 'number' && typeof mid !== 'number') return undefined;
  return Math.max(low || 0, mid || 0);
}

/* [[sunrise, sunset], ...] in unix seconds, one pair per local day */
function daylight(d) {
  if (!d || !Array.isArray(d.sunrise) || !Array.isArray(d.sunset)) return undefined;
  return d.sunrise.map((r, i) => [r, d.sunset[i]]);
}

/* Current weather for many places (Explore), in batches of 100 so URLs
   stay short. Returns one { offset, now, daylight } per place, in the same order;
   null for places whose batch failed */
export async function getNowMany(places, signal) {
  const batches = [];
  for (let i = 0; i < places.length; i += 100) batches.push(getNowBatch(places.slice(i, i + 100), signal));
  const results = await Promise.allSettled(batches);
  if (results.every(r => r.status === 'rejected')) throw results[0].reason;
  return results.flatMap((r, i) => (r.status === 'fulfilled' ? r.value : places.slice(i * 100, i * 100 + 100).map(() => null)));
}

async function getNowBatch(places, signal) {
  const params = new URLSearchParams({
    latitude: places.map(p => p.lat).join(','),
    longitude: places.map(p => p.lon).join(','),
    current: 'temperature_2m,weather_code,is_day,wind_speed_10m,wind_gusts_10m,rain,showers,snowfall,visibility,' +
      'cloud_cover,cloud_cover_low,cloud_cover_mid',
    daily: 'sunrise,sunset',
    forecast_days: 1,
    timezone: places.map(() => 'auto').join(','),
    timeformat: 'unixtime',
  });
  const data = await getJSON(`${FORECAST_URL}?${params}`, signal);
  // a single place comes back as an object, several as an array
  return (Array.isArray(data) ? data : [data]).map(d => {
    const c = d.current || {};
    const rain = c.rain, showers = c.showers;
    return {
      offset: d.utc_offset_seconds || 0,
      daylight: daylight(d.daily),
      now: {
        time: c.time,
        temp: c.temperature_2m,
        code: c.weather_code,
        isDay: !!c.is_day,
        wind: c.wind_speed_10m,
        isNow: true,
        data: {
          rain: rain === undefined && showers === undefined ? undefined : (rain || 0) + (showers || 0),
          snow: c.snowfall,
          vis: c.visibility,
          gust: c.wind_gusts_10m,
          cloud: c.cloud_cover,
          lowCloud: thick(c.cloud_cover_low, c.cloud_cover_mid),
        },
      },
    };
  });
}

export async function reverseGeocode(lat, lon) {
  try {
    const params = new URLSearchParams({ latitude: lat, longitude: lon, localityLanguage: 'en' });
    const d = await getJSON(`${REVERSE_URL}?${params}`);
    const city = d.city || d.locality || d.principalSubdivision;
    return [city, d.countryCode || d.countryName].filter(Boolean).join(', ');
  } catch {
    return '';
  }
}

export async function searchCity(query, signal) {
  const params = new URLSearchParams({ name: query, count: 6, language: 'en', format: 'json' });
  const d = await getJSON(`${SEARCH_URL}?${params}`, signal);
  return (d.results || []).map(r => ({
    name: r.name,
    region: [r.admin1, r.country].filter(Boolean).join(', '),
    label: `${r.name}, ${r.country_code || r.country || ''}`.replace(/, $/, ''),
    lat: r.latitude,
    lon: r.longitude,
  }));
}

export function getPosition() {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) return reject(new Error('Geolocation not supported'));
    navigator.geolocation.getCurrentPosition(
      p => resolve({ lat: p.coords.latitude, lon: p.coords.longitude }),
      reject,
      { enableHighAccuracy: false, timeout: 8000, maximumAge: 10 * 60 * 1000 }
    );
  });
}

async function getJSON(url, signal) {
  const res = await fetch(url, { signal });
  if (!res.ok) {
    // Open-Meteo explains bad requests: {"error": true, "reason": "..."}
    let reason = '';
    try { reason = (await res.json()).reason || ''; } catch {}
    throw new Error(`HTTP ${res.status}${reason ? ` · ${reason}` : ''}`);
  }
  return res.json();
}
