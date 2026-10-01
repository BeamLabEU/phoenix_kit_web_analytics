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
 *     visible;
 *   - when session recording is switched on (off by default), how the
 *     pointer moved, what was clicked and hovered, and how the page scrolled
 *     — coordinates and short element selectors only, never text, keystrokes
 *     or form values. The server says per page whether to record.
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

  // Core sets the prefix on every page; its own default if a layout doesn't.
  var prefix = typeof window.PHOENIX_KIT_PREFIX === "string" ? window.PHOENIX_KIT_PREFIX : "/phoenix_kit";
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

  // ── automation ────────────────────────────────────────────────────────────

  // Selenium, Puppeteer and Playwright set navigator.webdriver; a browser a
  // person uses doesn't. Reported once per page; the server flags the visit.
  if (navigator.webdriver === true) send({ e: "automation" });

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

  // ── session recording (only when the server asks for it) ─────────────────

  var base = (prefix === "/" ? "" : prefix.replace(/\/$/, "")) + "/phoenix-kit/analytics/recording";
  var MOVE_MS = 100;
  var FLUSH_MS = 10000;
  var MAX_FRAMES = 500;
  var MAX_SEQ = 400;
  var HOVER_MS = 400;
  var INTERESTING = "a, button, input, select, textarea, label, summary, img, video, [role], [data-analytics], [phx-click]";

  var rec = null;

  function pageKey() {
    var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var out = "";
    var bytes = window.crypto && window.crypto.getRandomValues ? window.crypto.getRandomValues(new Uint8Array(20)) : null;
    for (var i = 0; i < 20; i++) out += chars[(bytes ? bytes[i] : Math.floor(Math.random() * 256)) % chars.length];
    return out;
  }

  // A short path to the element — tag, id or two classes, position among
  // same-tag siblings — never its text.
  function selector(el) {
    var parts = [];
    for (var depth = 0; el && el.nodeType === 1 && depth < 4; depth++, el = el.parentElement) {
      var tag = el.tagName.toLowerCase();
      if (tag === "html" || tag === "body") break;
      if (el.id && !/\d{3,}|^phx-/.test(el.id)) {
        parts.unshift(tag + "#" + el.id);
        break;
      }
      var part = tag;
      var classes = typeof el.className === "string" ? el.className.trim().split(/\s+/).filter(function (c) {
        // Tailwind variants and LiveView's state classes (phx-connected…)
        // don't describe the element and change under it.
        return c && c.indexOf(":") === -1 && c.indexOf("[") === -1 && c.indexOf("phx-") !== 0;
      }) : [];
      if (classes.length) part += "." + classes.slice(0, 2).join(".");
      var parent = el.parentElement;
      if (parent) {
        var same = Array.prototype.filter.call(parent.children, function (c) {
          return c.tagName === el.tagName;
        });
        if (same.length > 1) part += ":nth-of-type(" + (same.indexOf(el) + 1) + ")";
      }
      parts.unshift(part);
    }
    return parts.join(" > ").slice(0, 200);
  }

  function frame(f) {
    if (!rec || !rec.on) return;
    f.unshift(Math.round(performance.now() - rec.t0));
    rec.frames.push(f);
    if (rec.frames.length >= MAX_FRAMES) flush();
  }

  function flush() {
    if (!rec || !rec.on || rec.frames.length === 0) return;
    if (rec.seq > MAX_SEQ) {
      rec.on = false;
      return;
    }
    var payload = { k: rec.key, s: rec.seq++, p: rec.path, w: rec.w, h: rec.h, f: rec.frames };
    rec.frames = [];
    try {
      navigator.sendBeacon(base, JSON.stringify(payload));
    } catch (_e) {}
  }

  function startRecording(path) {
    if (rec) flush();
    rec = { key: pageKey(), seq: 0, path: path, t0: performance.now(), frames: [], on: false, w: window.innerWidth, h: window.innerHeight, x: -1, y: -1, lastMove: 0 };
    var mine = rec;
    if (typeof fetch !== "function") return;
    fetch(base + "?p=" + encodeURIComponent(path), { credentials: "same-origin" })
      .then(function (r) {
        return r.ok ? r.json() : { record: false };
      })
      .then(function (answer) {
        if (mine !== rec || !answer || answer.record !== true) return;
        rec.on = true;
        frame(["s", Math.round(window.scrollX), Math.round(window.scrollY)]);
      })
      .catch(function () {});
  }

  document.addEventListener(
    "pointermove",
    function (ev) {
      if (!rec || !rec.on) return;
      var now = performance.now();
      if (now - rec.lastMove < MOVE_MS) return;
      var x = Math.round(ev.clientX);
      var y = Math.round(ev.clientY);
      if (x === rec.x && y === rec.y) return;
      rec.lastMove = now;
      rec.x = x;
      rec.y = y;
      frame(["m", x, y]);
    },
    { passive: true, capture: true }
  );

  document.addEventListener(
    "click",
    function (ev) {
      if (!rec || !rec.on || !ev.target) return;
      frame(["c", Math.round(ev.clientX), Math.round(ev.clientY), selector(ev.target)]);
    },
    true
  );

  var hoverTimer = null;
  var hovered = null;
  document.addEventListener(
    "pointerover",
    function (ev) {
      if (!rec || !rec.on || !ev.target || !ev.target.closest) return;
      var el = ev.target.closest(INTERESTING);
      if (!el || el === hovered) return;
      hovered = el;
      clearTimeout(hoverTimer);
      hoverTimer = setTimeout(function () {
        if (hovered === el) frame(["h", selector(el)]);
      }, HOVER_MS);
    },
    { passive: true, capture: true }
  );

  var scrollQueued = false;
  window.addEventListener(
    "scroll",
    function () {
      if (!rec || !rec.on || scrollQueued) return;
      scrollQueued = true;
      setTimeout(function () {
        scrollQueued = false;
        frame(["s", Math.round(window.scrollX), Math.round(window.scrollY)]);
      }, 150);
    },
    { passive: true }
  );

  var resizeTimer = null;
  window.addEventListener("resize", function () {
    if (!rec || !rec.on) return;
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () {
      frame(["r", window.innerWidth, window.innerHeight]);
    }, 300);
  });

  document.addEventListener("visibilitychange", function () {
    var shown = document.visibilityState === "visible";
    frame(["v", shown ? 1 : 0]);
    if (!shown) flush();
  });

  window.addEventListener("pagehide", flush);
  setInterval(flush, FLUSH_MS);

  // A LiveView navigation is a new page view: its own recording.
  var recordedPath = location.pathname;
  window.addEventListener("phx:navigate", function () {
    if (location.pathname !== recordedPath) {
      recordedPath = location.pathname;
      startRecording(recordedPath);
    }
  });

  window.addEventListener("pageshow", function (ev) {
    if (ev.persisted) startRecording(location.pathname);
  });

  startRecording(location.pathname);

  measureScroll();
})();

/*
 * Session-recording player — a LiveView hook for the admin visit page.
 *
 * Asks the page for the recording ("replay_data"), loads each recorded page
 * in a sandboxed frame (no scripts) at the recorded viewport size, and plays
 * the pointer, clicks, hovers and scrolling over it. Pages the server won't
 * vouch for are played over a blank stage. Long idle gaps are skipped.
 */
window.PhoenixKitWebAnalyticsHooks.PhoenixKitWebAnalyticsReplay = {
  mounted: function () {
    var self = this;
    this.el.innerHTML = '<p class="text-sm text-base-content/60">…</p>';
    this.pushEvent("replay_data", {}, function (reply) {
      self.pages = (reply && reply.pages) || [];
      if (self.pages.length) self.build();
      else self.el.innerHTML = "";
    });
  },

  destroyed: function () {
    this.stop();
  },

  build: function () {
    var self = this;
    var el = this.el;
    el.innerHTML = "";

    var bar = document.createElement("div");
    bar.className = "mb-3 flex flex-wrap items-center gap-2";
    el.appendChild(bar);

    this.pageSelect = document.createElement("select");
    this.pageSelect.className = "select select-sm max-w-xs";
    this.pages.forEach(function (page, i) {
      var option = document.createElement("option");
      option.value = String(i);
      option.textContent = i + 1 + ". " + page.path;
      self.pageSelect.appendChild(option);
    });
    this.pageSelect.addEventListener("change", function () {
      self.load(Number(self.pageSelect.value));
    });
    var label = document.createElement("label");
    label.className = "select select-sm";
    label.appendChild(this.pageSelect);
    this.pageSelect.className = "";
    bar.appendChild(label);

    this.playButton = document.createElement("button");
    this.playButton.type = "button";
    this.playButton.className = "btn btn-sm btn-primary";
    this.playButton.addEventListener("click", function () {
      if (self.playing) self.stop();
      else self.play();
    });
    bar.appendChild(this.playButton);

    this.speed = document.createElement("select");
    [1, 2, 4].forEach(function (n) {
      var option = document.createElement("option");
      option.value = String(n);
      option.textContent = n + "×";
      self.speed.appendChild(option);
    });
    var speedLabel = document.createElement("label");
    speedLabel.className = "select select-sm w-20";
    speedLabel.appendChild(this.speed);
    bar.appendChild(speedLabel);

    this.scrubber = document.createElement("input");
    this.scrubber.type = "range";
    this.scrubber.min = "0";
    this.scrubber.className = "range range-xs min-w-0 flex-1";
    this.scrubber.addEventListener("input", function () {
      self.seek(Number(self.scrubber.value));
    });
    bar.appendChild(this.scrubber);

    this.clock = document.createElement("span");
    this.clock.className = "w-24 text-right text-xs tabular-nums text-base-content/60";
    bar.appendChild(this.clock);

    this.note = document.createElement("p");
    this.note.className = "mb-2 hidden text-xs text-base-content/60";
    this.note.textContent = el.dataset.unavailable;
    el.appendChild(this.note);

    this.viewport = document.createElement("div");
    this.viewport.className = "relative w-full overflow-hidden rounded-lg border border-base-300 bg-base-200";
    el.appendChild(this.viewport);

    this.stage = document.createElement("div");
    this.stage.style.cssText = "position:absolute;left:0;top:0;transform-origin:0 0;";
    this.viewport.appendChild(this.stage);

    this.frame = document.createElement("iframe");
    this.frame.setAttribute("sandbox", "allow-same-origin");
    this.frame.setAttribute("tabindex", "-1");
    this.frame.style.cssText = "border:0;width:100%;height:100%;pointer-events:none;background:#fff;";
    this.stage.appendChild(this.frame);

    this.hoverBox = document.createElement("div");
    this.hoverBox.style.cssText = "position:absolute;display:none;border:2px solid #3b82f6;border-radius:4px;background:rgba(59,130,246,.08);pointer-events:none;";
    this.stage.appendChild(this.hoverBox);

    this.cursor = document.createElement("div");
    this.cursor.innerHTML = '<svg width="18" height="24" viewBox="0 0 18 24"><path d="M1 1l0 19 5-5 4 8 3-1.5-4-8 7 0z" fill="#111" stroke="#fff" stroke-width="1.5"/></svg>';
    this.cursor.style.cssText = "position:absolute;left:0;top:0;display:none;pointer-events:none;z-index:3;transition:transform 90ms linear;";
    this.stage.appendChild(this.cursor);

    this.resizeObserver = new ResizeObserver(function () {
      self.fit();
    });
    this.resizeObserver.observe(this.viewport);

    this.load(0);
  },

  // Playback runs on "recording time"; gaps longer than this are skipped.
  IDLE_MS: 2000,

  load: function (index) {
    this.stop();
    var page = this.pages[index];
    this.page = page;
    this.frames = page.frames || [];
    this.duration = this.frames.length ? this.frames[this.frames.length - 1][0] : 0;
    this.scrubber.max = String(this.duration);
    this.size = { w: page.w || 1280, h: page.h || 800 };

    // Only ever this site's own pages, whatever the recording says.
    var url = null;
    try {
      url = page.url ? new URL(page.url, location.origin) : null;
    } catch (_e) {}
    if (url && url.origin === location.origin) {
      this.frame.src = url.href;
      this.frame.style.visibility = "visible";
      this.note.classList.add("hidden");
    } else {
      this.frame.removeAttribute("src");
      this.frame.style.visibility = "hidden";
      this.note.classList.remove("hidden");
    }

    this.fit();
    this.seek(0);
    this.label();
  },

  fit: function () {
    if (!this.size) return;
    var k = Math.min(1, this.viewport.clientWidth / this.size.w);
    this.scale = k;
    this.stage.style.width = this.size.w + "px";
    this.stage.style.height = this.size.h + "px";
    this.stage.style.transform = "scale(" + k + ")";
    this.viewport.style.height = Math.round(this.size.h * k) + "px";
  },

  // The state at time t: the last pointer position, scroll, size and hover,
  // and the clicks of the last moment.
  seek: function (t) {
    this.t = t;
    var pointer = null;
    var scroll = [0, 0];
    var hover = null;
    var size = { w: this.page.w || 1280, h: this.page.h || 800 };
    for (var i = 0; i < this.frames.length && this.frames[i][0] <= t; i++) {
      var f = this.frames[i];
      if (f[1] === "m" || f[1] === "c") pointer = [f[2], f[3]];
      else if (f[1] === "s") scroll = [f[2], f[3]];
      else if (f[1] === "h") hover = f[2];
      else if (f[1] === "r") size = { w: f[2], h: f[3] };
      if (f[1] === "c" && t - f[0] < 600) this.ripple(f[2], f[3], f[0]);
    }
    this.cursorAt = i;
    if (size.w !== this.size.w || size.h !== this.size.h) {
      this.size = size;
      this.fit();
    }
    this.scrollTo(scroll);
    this.hover(hover);
    if (pointer) {
      this.cursor.style.display = "block";
      this.cursor.style.transform = "translate(" + pointer[0] + "px," + pointer[1] + "px)";
    } else {
      this.cursor.style.display = "none";
    }
    this.scrubber.value = String(t);
    this.label();
  },

  scrollTo: function (scroll) {
    try {
      this.frame.contentWindow.scrollTo(scroll[0], scroll[1]);
    } catch (_e) {}
  },

  hover: function (selector) {
    var box = null;
    if (selector) {
      try {
        var target = this.frame.contentDocument && this.frame.contentDocument.querySelector(selector);
        if (target) box = target.getBoundingClientRect();
      } catch (_e) {}
    }
    if (!box) {
      this.hoverBox.style.display = "none";
      return;
    }
    this.hoverBox.style.display = "block";
    this.hoverBox.style.left = box.left - 2 + "px";
    this.hoverBox.style.top = box.top - 2 + "px";
    this.hoverBox.style.width = box.width + 4 + "px";
    this.hoverBox.style.height = box.height + 4 + "px";
  },

  ripple: function (x, y, at) {
    this.ripples = this.ripples || {};
    if (this.ripples[at]) return;
    this.ripples[at] = true;
    var dot = document.createElement("div");
    dot.style.cssText =
      "position:absolute;width:28px;height:28px;margin:-14px 0 0 -14px;border-radius:9999px;border:3px solid #ef4444;pointer-events:none;z-index:2;transition:transform .5s ease-out,opacity .5s ease-out;";
    dot.style.left = x + "px";
    dot.style.top = y + "px";
    this.stage.appendChild(dot);
    var ripples = this.ripples;
    requestAnimationFrame(function () {
      dot.style.transform = "scale(1.8)";
      dot.style.opacity = "0";
    });
    setTimeout(function () {
      dot.remove();
      delete ripples[at];
    }, 600);
  },

  play: function () {
    var self = this;
    if (this.t >= this.duration) this.seek(0);
    this.playing = true;
    this.label();
    var last = performance.now();
    var tick = function (now) {
      if (!self.playing) return;
      var step = (now - last) * Number(self.speed.value || 1);
      last = now;
      var next = self.t + step;
      // Skip idle stretches: jump to just before the next frame.
      var upcoming = self.frames[self.cursorAt];
      if (upcoming && upcoming[0] - self.t > self.IDLE_MS) next = upcoming[0] - 200;
      if (next >= self.duration) {
        self.seek(self.duration);
        self.stop();
        return;
      }
      self.seek(next);
      self.raf = requestAnimationFrame(tick);
    };
    this.raf = requestAnimationFrame(tick);
  },

  stop: function () {
    this.playing = false;
    if (this.raf) cancelAnimationFrame(this.raf);
    this.raf = null;
    this.label();
  },

  label: function () {
    if (!this.playButton) return;
    this.playButton.textContent = this.playing ? this.el.dataset.pause : this.el.dataset.play;
    var fmt = function (ms) {
      var s = Math.floor((ms || 0) / 1000);
      return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
    };
    this.clock.textContent = fmt(this.t) + " / " + fmt(this.duration);
  }
};
