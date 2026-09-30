/*
 * PhoenixKit Web Analytics — optional client script.
 *
 * Shipped through the module's js_sources/0, so it rides in the host's
 * phoenix_kit_modules.js with no per-app setup. The server already records
 * page views (the plug), and on LiveView pages every click, submit, navigation
 * and exit (the LiveView hook). This script adds only what a server cannot
 * see:
 *
 *   - clicks that never reach the server: outbound links, downloads, plain
 *     buttons, and anything marked data-analytics="name";
 *   - how far a visitor scrolled;
 *   - when a visitor leaves a page that has no LiveView, and how long it was
 *     visible.
 *
 * Nothing is sent while the page loads, nothing is stored in the browser, no
 * cookie is written. Visitors sending Do Not Track or Global Privacy Control
 * are skipped here as well as on the server. The server drops everything this
 * script sends unless "Client script" is switched on in Web Analytics
 * settings.
 */
window.PhoenixKitWebAnalyticsHooks = window.PhoenixKitWebAnalyticsHooks || {};

(function () {
  "use strict";

  if (window.__phoenixKitWebAnalytics) return;
  window.__phoenixKitWebAnalytics = true;

  if (navigator.doNotTrack === "1" || navigator.globalPrivacyControl === true) return;
  if (typeof navigator.sendBeacon !== "function") return;

  var prefix = window.PHOENIX_KIT_PREFIX || "";
  var endpoint = (prefix === "/" ? "" : prefix.replace(/\/$/, "")) + "/phoenix-kit/analytics/event";
  var DOWNLOAD = /\.(pdf|zip|rar|7z|gz|tar|dmg|exe|msi|apk|docx?|xlsx?|pptx?|csv|odt|ods|mp3|mp4|mov|avi|epub)$/i;

  function send(payload) {
    try {
      navigator.sendBeacon(endpoint, JSON.stringify(payload));
    } catch (_e) {}
  }

  function here() {
    return location.pathname + location.search;
  }

  // A page with a connected LiveView is watched by the server, which records
  // its clicks, navigations and exit itself.
  function liveViewPage() {
    return !!document.querySelector("[data-phx-main]") && !!window.liveSocket;
  }

  // ── custom events (same API as the <.beacon /> snippet) ──────────────────

  if (typeof window.phoenixKitAnalytics !== "function") {
    window.phoenixKitAnalytics = function (name, props) {
      send({ e: name ? "event" : "pageview", n: name || null, p: here(), t: document.title, props: props || {} });
    };
  }

  // ── clicks ────────────────────────────────────────────────────────────────

  function label(el) {
    var text = (el.getAttribute("aria-label") || el.textContent || "").replace(/\s+/g, " ").trim();
    return text.slice(0, 80);
  }

  function describe(el) {
    var named = el.closest("[data-analytics]");
    if (named) return { k: "click", x: named.getAttribute("data-analytics").slice(0, 120) };

    var link = el.closest("a[href]");
    if (link) {
      // LiveView links navigate over the socket; the server records those.
      if (link.hasAttribute("data-phx-link")) return null;

      var url;
      try {
        url = new URL(link.href, location.href);
      } catch (_e) {
        return null;
      }
      if (url.protocol === "mailto:" || url.protocol === "tel:") return { k: "contact", x: url.protocol.slice(0, -1) };
      if (link.hasAttribute("download") || DOWNLOAD.test(url.pathname)) return { k: "download", x: url.pathname.split("/").pop() };
      if (url.host && url.host !== location.host) return { k: "outbound", x: url.host + url.pathname };
      // An internal link becomes a page view, which is already recorded.
      return null;
    }

    var button = el.closest("button, [role=button], input[type=submit], input[type=button]");
    if (button) {
      // phx-click / phx-submit reach the server as LiveView events.
      if (liveViewPage() && (button.closest("[phx-click]") || button.closest("form[phx-submit]"))) return null;
      return { k: "click", x: label(button) || button.getAttribute("name") || "button" };
    }

    return null;
  }

  document.addEventListener(
    "click",
    function (ev) {
      if (!ev.target || !ev.target.closest) return;
      var what = describe(ev.target);
      if (what && what.x) send({ e: "click", k: what.k, x: what.x, p: here() });
    },
    true
  );

  // ── scroll depth and visible time ─────────────────────────────────────────

  var maxScroll = 0;
  var visibleMs = 0;
  var visibleSince = document.visibilityState === "visible" ? Date.now() : null;
  var reported = false;
  var ticking = false;

  function measureScroll() {
    var doc = document.documentElement;
    var height = Math.max(doc.scrollHeight, document.body ? document.body.scrollHeight : 0);
    var seen = window.scrollY + window.innerHeight;
    var depth = height <= window.innerHeight ? 100 : Math.round((seen / height) * 100);
    if (depth > maxScroll) maxScroll = Math.min(depth, 100);
    ticking = false;
  }

  window.addEventListener(
    "scroll",
    function () {
      if (!ticking) {
        ticking = true;
        requestAnimationFrame(measureScroll);
      }
    },
    { passive: true }
  );

  function visibleTime() {
    return visibleMs + (visibleSince ? Date.now() - visibleSince : 0);
  }

  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "visible") {
      visibleSince = Date.now();
    } else {
      if (visibleSince) visibleMs += Date.now() - visibleSince;
      visibleSince = null;
      // Hidden is the last reliable moment on mobile (pagehide may never
      // come), so the page is reported now — once.
      report();
    }
  });

  function reset() {
    maxScroll = 0;
    visibleMs = 0;
    visibleSince = document.visibilityState === "visible" ? Date.now() : null;
    reported = false;
    measureScroll();
  }

  // On a LiveView page only the scroll depth is news (the server records the
  // exit); elsewhere this is the exit itself. Once per page view.
  function report(path) {
    if (reported) return;
    measureScroll();
    if (liveViewPage()) {
      if (maxScroll > 0) send({ e: "scroll", sd: maxScroll, p: path || here() });
    } else {
      send({ e: "leave", ms: visibleTime(), sd: maxScroll, p: path || here() });
    }
    reported = true;
  }

  window.addEventListener("pagehide", function () {
    report();
  });

  window.addEventListener("pageshow", function (ev) {
    // Restored from the back/forward cache: a new visit to the same page.
    if (ev.persisted) reset();
  });

  // LiveView navigation: report the page being left, then start over.
  var lastPath = here();
  window.addEventListener("phx:navigate", function () {
    var previous = lastPath;
    lastPath = here();
    if (previous !== lastPath) {
      report(previous);
      reset();
    }
  });

  measureScroll();
})();
