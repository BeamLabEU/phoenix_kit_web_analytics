defmodule PhoenixKitWebAnalytics.DataCollection do
  @moduledoc """
  What the module collects right now, in words a visitor can read.

  Returned from `PhoenixKitWebAnalytics.data_collection/0`, which PhoenixKit's
  Legal module looks for by name: its cookie banner, its settings page and
  the cookie policy it generates all list what is declared here. The shape is
  documented there (`PhoenixKit.Modules.Legal.DataCollection`); this module
  has no dependency on it and declares the same thing whether or not anything
  is listening.

  Every entry follows the settings: what is switched off is declared
  inactive, what a `store_*` setting keeps is named only while it is kept,
  and each entry's `mode` is its `web_analytics_consent_*` mode. So a change
  on the settings page changes what visitors are told, with nothing to edit
  by hand.

  Nothing here is put on a visitor's device — the module writes no cookie
  and no storage — so every `storage` list is empty.
  """

  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  alias PhoenixKitWebAnalytics.Config

  @doc "The module's declarations, for the current settings and locale."
  @spec entries() :: [map()]
  def entries do
    config = Config.collection_config()
    events = retention(Config.retention_days())

    [
      %{
        key: "web_analytics.measurement",
        title: gettext("Visit statistics"),
        description:
          gettext(
            "Counts visits to our pages so we can see which are read, where visitors come from and what does not work."
          ),
        category: config.consent_category,
        mode: config.consent.measurement,
        active: config.enabled?,
        data: measurement_data(config),
        retention: events,
        storage: []
      },
      %{
        key: "web_analytics.profile",
        title: gettext("Details about your connection"),
        description:
          gettext(
            "Kept to tell people from automated traffic and to look into abuse of the site."
          ),
        category: config.consent_category,
        mode: config.consent.profile,
        active: config.enabled? and profile_data(config) != [],
        data: profile_data(config),
        retention: events,
        storage: []
      },
      %{
        key: "web_analytics.device",
        title: gettext("Device measurements"),
        description:
          gettext(
            "Measurements of your device that let us recognise it again when its address changes, used to tell people from automated traffic."
          ),
        category: config.consent_category,
        mode: config.consent.device,
        active: config.enabled? and config.client_script? and config.store_signals?,
        data: [
          gettext("Screen size, time zone and languages"),
          gettext("Processor, memory and graphics card"),
          gettext("Installed fonts"),
          gettext("How your browser draws an image and renders a sound"),
          gettext("A fingerprint worked out from these")
        ],
        retention: events,
        storage: []
      },
      %{
        key: "web_analytics.recording",
        title: gettext("Session recordings"),
        description:
          gettext(
            "Replays of how a page was used, so we can see where it confuses people. What you type is never recorded."
          ),
        category: config.consent_category,
        mode: config.consent.recording,
        active: config.enabled? and config.recording?,
        data: [
          gettext("Pointer movement, clicks and scrolling on a page"),
          gettext("The size of your browser window")
        ],
        retention: retention(Config.recording_retention_days()),
        storage: []
      }
    ]
  end

  defp measurement_data(config) do
    [
      gettext("The pages you view and when"),
      gettext("The site or campaign that brought you here"),
      gettext("Your country, and the region and city where they can be told"),
      gettext("Your browser, operating system, device type and language"),
      visitor_id_text(config.visitor_rotation),
      gettext("Your account, when you are signed in"),
      config.track_interactions? && gettext("The buttons and links you use on our pages"),
      config.client_script? &&
        gettext("Links you follow away from the site, and how far you scroll")
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp visitor_id_text(:never),
    do:
      gettext(
        "A visitor number worked out from your IP address and browser, which stays the same until one of them changes"
      )

  defp visitor_id_text(rotation) do
    gettext(
      "A visitor number worked out from your IP address and browser, replaced every %{period}",
      period: period(rotation)
    )
  end

  defp period(:weekly), do: gettext("week")
  defp period(:monthly), do: gettext("month")
  defp period(_daily), do: gettext("day")

  defp profile_data(config) do
    [
      config.store_ip == :full && gettext("Your IP address"),
      config.store_ip == :truncated && gettext("The network part of your IP address"),
      config.store_user_agent? && gettext("Your browser's full User-Agent"),
      config.store_headers? &&
        gettext("The technical headers your browser sent with its first request"),
      config.store_network? && gettext("Who runs the network you connect from")
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp retention(days) when is_integer(days) and days > 0,
    do: ngettext("%{count} day", "%{count} days", days, count: days)

  defp retention(_days), do: gettext("Until we delete it")
end
