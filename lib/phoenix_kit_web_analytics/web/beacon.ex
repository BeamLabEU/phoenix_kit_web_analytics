defmodule PhoenixKitWebAnalytics.Web.Beacon do
  @moduledoc """
  The optional client-side snippet — around 300 bytes, inline, no file to load.

  Most sites need none of this. `PhoenixKitWebAnalytics.Plug` already counts
  every HTML response server-side, and `PhoenixKitWebAnalytics.LiveHook` covers
  LiveView navigation. Reach for the beacon only when you want **custom
  events** from the browser (a signup completing, a video finishing) or when
  pages are served from a full-page cache that bypasses Elixir entirely.

  Both components require `web_analytics_beacon_enabled` to be on; the
  endpoints ignore hits otherwise.

  ## Custom events

  Put `<.beacon />` in the layout, then call the global from anywhere:

      <.beacon />

      <button onclick="phoenixKitAnalytics('signup', {plan: 'pro'})">Sign up</button>

  What ships to the client is one function assigned to `window`. There is no
  bundle, no framework, no cookie written, nothing fetched on load, and no
  network request until an event actually fires — the point of this module is
  that adding analytics doesn't change what a page costs to load. `sendBeacon`
  queues the request outside the page lifecycle, so an event fired during
  navigation still arrives and doesn't hold anything up.

  ## Cached pages

  For pages a CDN serves without hitting the app, `<.pixel />` renders a
  hidden 1×1 image that works with or without JavaScript:

      <.pixel cache_buster={@request_id} />

  ## SPA / client-routed page views

      <.beacon auto_pageview={true} />

  adds a `pushState`/`popstate` listener that reports a page view on
  client-side route changes. Only use it for a JS-routed front end — with
  server-rendered or LiveView pages it double-counts, since those are already
  tracked.

  ## Why the configuration is in data attributes

  HEEx doesn't interpolate inside `<script>` bodies, and building a script
  string by concatenation is how an escaping bug gets shipped. The endpoint URL
  and flags ride on `data-` attributes (properly escaped by HEEx) and the
  snippet reads them off `document.currentScript` — which also keeps the script
  body a static string, so a strict CSP can hash it.
  """

  use Phoenix.Component

  alias PhoenixKitWebAnalytics.Paths

  @doc """
  Renders the inline tracking snippet.

  ## Attributes

    * `:auto_pageview` — also report client-side route changes (default
      `false`; leave it off unless a JS router owns navigation)
    * `:nonce` — CSP nonce for the `<script>` tag, if the host sets one
  """
  attr :auto_pageview, :boolean, default: false
  attr :nonce, :string, default: nil

  def beacon(assigns) do
    assigns = assign(assigns, :endpoint, Paths.beacon_endpoint())

    ~H"""
    <script
      nonce={@nonce}
      data-phoenix-kit-analytics={@endpoint}
      data-auto-pageview={to_string(@auto_pageview)}
    >
      (function () {
        var el = document.currentScript;
        var url = el.getAttribute("data-phoenix-kit-analytics");

        window.phoenixKitAnalytics = function (name, props) {
          try {
            navigator.sendBeacon(url, JSON.stringify({
              n: name || null,
              e: name ? "event" : "pageview",
              p: location.pathname + location.search,
              t: document.title,
              r: document.referrer,
              props: props || {}
            }));
          } catch (e) {}
        };

        if (el.getAttribute("data-auto-pageview") === "true") {
          var report = function () { window.phoenixKitAnalytics(null, null); };
          var push = history.pushState;
          history.pushState = function () { push.apply(history, arguments); report(); };
          addEventListener("popstate", report);
        }
      })();
    </script>
    """
  end

  @doc """
  Renders a 1×1 tracking pixel for pages the plug never sees.

  Pass `cache_buster` — any value that changes per response — when the page
  itself is cached, or the browser serves the pixel from its own cache and the
  view is never recorded.
  """
  attr :cache_buster, :string, default: nil

  def pixel(assigns) do
    assigns = assign(assigns, :src, Paths.pixel_endpoint(assigns.cache_buster))

    ~H"""
    <img src={@src} alt="" width="1" height="1" style="position:absolute;left:-9999px" />
    """
  end
end
