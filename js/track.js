/* Usage analytics: page views plus a few named events, cookieless.
 *
 * Provider: Umami (https://umami.is). Set WEBSITE_ID to the site's id from
 * the Umami dashboard; while it's empty nothing loads and track() does
 * nothing. Only the live domain is counted: localhost, previews, the
 * landing page's embedded app and ?demo never send anything.
 *
 * Privacy: the query string is not recorded (shared links carry
 * coordinates), and events never include coordinates or place names.
 *
 * To switch provider, change load() and send() below; callers only use
 * track(name, props).
 */
const WEBSITE_ID = '';
const SCRIPT = 'https://cloud.umami.is/script.js';
const DOMAIN = 'huecast.app';

const queue = [];
const once = new Set();

const enabled = (() => {
  try {
    return !!WEBSITE_ID
      && location.hostname === DOMAIN
      && window.top === window
      && !new URLSearchParams(location.search).has('demo');
  } catch {
    return false;
  }
})();

function load() {
  const s = document.createElement('script');
  s.defer = true;
  s.src = SCRIPT;
  s.dataset.websiteId = WEBSITE_ID;
  s.dataset.domains = DOMAIN;
  s.dataset.excludeSearch = 'true';
  s.dataset.excludeHash = 'true';
  s.onload = flush;
  document.head.append(s);
}

function send(name, props) {
  window.umami.track(name, props);
}

function flush() {
  if (!window.umami) return;
  while (queue.length) {
    const [name, props] = queue.shift();
    try { send(name, props); } catch {}
  }
}

/* Record an event. Props: a few short strings, numbers or booleans */
export function track(name, props) {
  if (!enabled) return;
  queue.push([name, props]);
  flush();
}

/* The same, at most once per page load (e.g. the first timeline scrub) */
export function trackOnce(name, props) {
  if (once.has(name)) return;
  once.add(name);
  track(name, props);
}

if (enabled) {
  load();
  // the installed app: how many people add it to the home screen / dock
  addEventListener('appinstalled', () => track('install'));
}
