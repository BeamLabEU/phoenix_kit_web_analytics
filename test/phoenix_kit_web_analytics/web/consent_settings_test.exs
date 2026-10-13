defmodule PhoenixKitWebAnalytics.Web.ConsentSettingsTest do
  @moduledoc "The settings page's “When it is collected” section, and what the module declares from it."

  use PhoenixKitWebAnalytics.LiveCase, async: false

  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.DataCollection

  @settings "/en/admin/web-analytics/settings"

  defp selected(html, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(select[name="#{name}"] option[selected]))
    |> LazyHTML.attribute("value")
  end

  describe "the section" do
    test "shows every kind of collection as always, the default", %{conn: conn} do
      {:ok, _view, html} = live(conn, @settings)

      for purpose <- ~w(measurement profile device recording) do
        assert selected(html, "consent_#{purpose}") == ["always"]
      end

      assert selected(html, "without_consent") == ["drop"]
      assert selected(html, "consent_category") == ["analytics"]
    end

    test "says that nothing asks visitors, and warns only when something waits for a yes",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, @settings)

      assert html =~ "Nothing on this site asks visitors"
      refute html =~ "web-analytics-consent-unasked"

      enable_tracking(%{"web_analytics_consent_recording" => "consent"})
      {:ok, _view, html} = live(conn, @settings)

      assert html =~ "web-analytics-consent-unasked"
    end

    test "names the host's own consent tool when one is configured", %{conn: conn} do
      Application.put_env(:phoenix_kit_web_analytics, :consent_source, {String, :length})
      on_exit(fn -> Application.delete_env(:phoenix_kit_web_analytics, :consent_source) end)

      enable_tracking(%{"web_analytics_consent_recording" => "consent"})
      {:ok, _view, html} = live(conn, @settings)

      assert html =~ "String.length/2"
      refute html =~ "web-analytics-consent-unasked"
    end

    test "warns about fingerprinting without agreement, and stops once it waits for one",
         %{conn: conn} do
      enable_tracking(%{"web_analytics_store_signals" => "true"})
      {:ok, _view, html} = live(conn, @settings)
      assert html =~ "web-analytics-consent-device"

      enable_tracking(%{
        "web_analytics_store_signals" => "true",
        "web_analytics_consent_device" => "consent"
      })

      {:ok, _view, html} = live(conn, @settings)
      refute html =~ "web-analytics-consent-device"
    end
  end

  describe "a preset" do
    test "fills the four rules and saves nothing until the form is saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings)

      html = view |> element("button[phx-value-preset='count']") |> render_click()

      assert selected(html, "consent_measurement") == ["always"]
      assert selected(html, "consent_profile") == ["consent"]
      assert selected(html, "consent_device") == ["consent"]
      assert selected(html, "consent_recording") == ["consent"]
      assert html =~ "Not saved yet."

      clear_settings_cache()
      assert Config.collection_config().consent.profile == :always

      html = view |> element("form[phx-submit='save']") |> render_submit()
      assert html =~ "Settings saved."
      refute html =~ "Not saved yet."

      clear_settings_cache()

      assert Config.collection_config().consent ==
               %{measurement: :always, profile: :consent, device: :consent, recording: :consent}
    end

    test "each preset is the combination its name says", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings)

      for {preset, expected} <- [
            {"ask", "consent"},
            {"object", "unless_objected"},
            {"tell", "always"}
          ] do
        html = view |> element("button[phx-value-preset='#{preset}']") |> render_click()

        for purpose <- ~w(measurement profile device recording) do
          assert selected(html, "consent_#{purpose}") == [expected]
        end
      end
    end

    test "an unknown preset changes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings)
      html = render_hook(view, "consent_preset", %{"preset" => "everything"})

      refute html =~ "Not saved yet."
    end
  end

  describe "saving" do
    test "stores each rule, the category and what happens without an answer", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings)

      view
      |> element("form[phx-submit='save']")
      |> render_submit(%{
        "consent_measurement" => "unless_objected",
        "consent_device" => "consent",
        "consent_category" => "marketing",
        "without_consent" => "anonymous"
      })

      clear_settings_cache()
      config = Config.collection_config()

      assert config.consent.measurement == :unless_objected
      assert config.consent.device == :consent
      assert config.consent_category == "marketing"
      assert config.without_consent == :anonymous
    end

    test "a rule that is not one of the three saves nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings)

      html =
        view
        |> element("form[phx-submit='save']")
        |> render_submit(%{"consent_measurement" => "sometimes"})

      assert html =~ "Nothing was saved"
      assert html =~ "Counting visits"
    end
  end

  describe "a stored value the module does not know" do
    test "reads as the default rather than an invented one" do
      enable_tracking(%{
        "web_analytics_consent_measurement" => "sometimes",
        "web_analytics_consent_category" => "necessary",
        "web_analytics_without_consent" => "queue"
      })

      config = Config.collection_config()

      assert config.consent.measurement == :always
      assert config.consent_category == "analytics"
      assert config.without_consent == :drop
    end
  end

  describe "what the module declares" do
    defp entry(key), do: Enum.find(DataCollection.entries(), &(&1.key == key))

    test "nothing is active while tracking is off" do
      assert Enum.all?(DataCollection.entries(), &(&1.active == false))
    end

    test "counting visits is active with tracking, and nothing is put on the device" do
      enable_tracking()

      assert %{active: true, mode: :always, category: "analytics", retention: "365 days"} =
               entry("web_analytics.measurement")

      assert Enum.all?(DataCollection.entries(), &(&1.storage == []))
      assert PhoenixKitWebAnalytics.data_collection() == DataCollection.entries()
    end

    test "details are declared only while a setting keeps one, and name only those" do
      enable_tracking()
      assert %{active: false, data: []} = entry("web_analytics.profile")

      enable_tracking(%{"web_analytics_store_ip" => "truncated"})

      assert %{active: true, data: ["The network part of your IP address"]} =
               entry("web_analytics.profile")
    end

    test "device measurements need the client script and their setting" do
      enable_tracking(%{"web_analytics_store_signals" => "true"})
      refute entry("web_analytics.device").active

      enable_tracking(%{
        "web_analytics_store_signals" => "true",
        "web_analytics_client_script" => "true"
      })

      assert entry("web_analytics.device").active
    end

    test "each entry carries its own rule and the category they are asked under" do
      enable_tracking(%{
        "web_analytics_consent_recording" => "consent",
        "web_analytics_consent_device" => "unless_objected",
        "web_analytics_consent_category" => "marketing",
        "web_analytics_recording" => "true",
        "web_analytics_recording_retention_days" => "14"
      })

      assert %{mode: :consent, active: true, category: "marketing", retention: "14 days"} =
               entry("web_analytics.recording")

      assert entry("web_analytics.device").mode == :unless_objected
      assert entry("web_analytics.measurement").mode == :always
    end

    test "says how long a visitor number lasts" do
      enable_tracking(%{"web_analytics_visitor_rotation" => "monthly"})
      assert Enum.any?(entry("web_analytics.measurement").data, &(&1 =~ "replaced every month"))

      enable_tracking(%{"web_analytics_visitor_rotation" => "never"})

      assert Enum.any?(
               entry("web_analytics.measurement").data,
               &(&1 =~ "until one of them changes")
             )
    end
  end
end
