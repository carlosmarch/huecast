/* Usage analytics: Google Analytics 4 page views and events on every page
 * (landing page, How it works, the app), so the whole path from the public
 * site into the app and to the Mac download can be followed.
 *
 * Set MEASUREMENT_ID to the GA4 web stream's id (G-XXXXXXXXXX); while it's
 * empty nothing loads and track() does nothing. Only the live domain is
 * counted: localhost, previews, the landing page's embedded app and ?demo
 * never send anything.
 *
 * Privacy: page URLs are sent without the query string (shared links carry
 * coordinates; only utm_ campaign tags are kept), and events never include
 * coordinates or place names.
 * Event names: letters, digits and underscores (GA4 rule).
 */
const MEASUREMENT_ID = 'G-HCMPQFEMSP';
const DOMAIN = 'huecast.app';

const once = new Set();

const enabled = (() => {
  try {
    return !!MEASUREMENT_ID
      && location.hostname === DOMAIN
      && window.top === window
      && !new URLSearchParams(location.search).has('demo');
  } catch {
    return false;
  }
})();

// a URL without its query (except utm_ campaign tags) or hash; other
// sites' referrers as they are
function clean(url) {
  try {
    const u = new URL(url);
    if (u.hostname !== DOMAIN) return url;
    const utm = [...u.searchParams].filter(([k]) => k.startsWith('utm_'));
    return u.origin + u.pathname + (utm.length ? `?${new URLSearchParams(utm)}` : '');
  } catch {
    return '';
  }
}

function load() {
  window.dataLayer = window.dataLayer || [];
  window.gtag = function gtag() { window.dataLayer.push(arguments); };
  gtag('js', new Date());
  gtag('config', MEASUREMENT_ID, {
    page_location: clean(location.href),
    page_referrer: clean(document.referrer),
  });
  const s = document.createElement('script');
  s.async = true;
  s.src = `https://www.googletagmanager.com/gtag/js?id=${MEASUREMENT_ID}`;
  document.head.append(s);
}

/* Record an event. Props: a few short strings or numbers */
export function track(name, props = {}) {
  if (!enabled) return;
  try { gtag('event', name, props); } catch {}
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
  addEventListener('appinstalled', () => track('app_install'));
}
