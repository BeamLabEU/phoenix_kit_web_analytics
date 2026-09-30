defmodule PhoenixKitWebAnalytics.AlertsTest do
  @moduledoc """
  `PhoenixKitWebAnalytics.Alerts`: the notification type it registers, how its
  settings parse, which visitors pass the filters, who receives alerts, and
  that each alert is one activity entry per recipient.

  Recipients are real users: in an empty sandbox the first registered user
  becomes the Owner (core's `ensure_first_user_is_owner/1`).
  """

  use PhoenixKitWebAnalytics.DataCase, async: false

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKitWebAnalytics.Alerts
  alias PhoenixKitWebAnalytics.Schemas.Event

  @alerts_table :phoenix_kit_web_analytics_alerts

  # ── notification type ─────────────────────────────────────────────────────

  describe "notification_types/0" do
    test "registers one web_analytics type with three sub-types and their actions" do
      assert [type] = Alerts.notification_types()
      assert type.key == "web_analytics"

      actions = Map.new(type.sub_types, &{&1.key, &1.actions})

      assert actions == %{
               "visitors" => ["web_analytics.visitor_arrived"],
               "signups" => ["web_analytics.user_registered"],
               "events" => ["web_analytics.event_alert"]
             }
    end

    test "no type or sub-type key contains a dot" do
      [type] = Alerts.notification_types()

      for key <- [type.key | Enum.map(type.sub_types, & &1.key)] do
        refute key =~ ".", "#{inspect(key)} contains a dot"
      end
    end
  end

  # ── config ────────────────────────────────────────────────────────────────

  describe "config/0" do
    test "defaults when nothing is set" do
      config = Alerts.config()

      assert config.visitors? == false
      assert config.signups? == true
      assert Enum.sort(config.channels) == Enum.sort(Alerts.channels())
      assert config.paths == []
      assert config.skip_users? == true
      assert config.max_per_hour == 20
      assert config.events == []
    end

    test "channels \"-\" is an explicit empty choice" do
      enable_tracking(%{"web_analytics_alert_channels" => "-"})
      assert Alerts.config().channels == []
    end

    test "unknown channels are dropped and known ones kept" do
      enable_tracking(%{"web_analytics_alert_channels" => "email, organic, carrier-pigeon"})
      assert Enum.sort(Alerts.config().channels) == ["email", "organic"]
    end

    test "the rest of the settings parse" do
      enable_tracking(%{
        "web_analytics_alert_visitors" => "true",
        "web_analytics_alert_signups" => "false",
        "web_analytics_alert_skip_users" => "false",
        "web_analytics_alert_max_per_hour" => "5",
        "web_analytics_alert_paths" => "/pricing, /blog*",
        "web_analytics_alert_events" => "order.placed\ncontact"
      })

      config = Alerts.config()
      assert config.visitors?
      refute config.signups?
      refute config.skip_users?
      assert config.max_per_hour == 5
      assert config.paths == ["/pricing", "/blog*"]
      assert config.events == ["order.placed", "contact"]
    end

    test "a negative or non-numeric hourly cap falls back to the default" do
      enable_tracking(%{"web_analytics_alert_max_per_hour" => "-3"})
      assert Alerts.config().max_per_hour == 20

      enable_tracking(%{"web_analytics_alert_max_per_hour" => "lots"})
      assert Alerts.config().max_per_hour == 20
    end
  end

  # ── visitor filter ────────────────────────────────────────────────────────

  describe "visitor_alert?/2" do
    @base_config %{
      visitors?: true,
      signups?: true,
      channels: ~w(none organic social referral email paid),
      paths: [],
      skip_users?: true,
      max_per_hour: 20,
      events: []
    }

    defp visitor(attrs \\ %{}) do
      struct(%Event{event_type: "pageview", path: "/pricing", referrer_medium: "organic"}, attrs)
    end

    test "passes an anonymous visitor with every filter open" do
      assert Alerts.visitor_alert?(visitor(), @base_config)
    end

    test "visitor alerts switched off → never" do
      refute Alerts.visitor_alert?(visitor(), %{@base_config | visitors?: false})
    end

    test "a signed-in user is skipped only while skip_users? is on" do
      signed_in = visitor(%{user_uuid: UUIDv7.generate()})

      refute Alerts.visitor_alert?(signed_in, @base_config)
      assert Alerts.visitor_alert?(signed_in, %{@base_config | skip_users?: false})
    end

    test "the channel filter, with a missing medium counted as direct (none)" do
      config = %{@base_config | channels: ["organic"]}

      assert Alerts.visitor_alert?(visitor(%{referrer_medium: "organic"}), config)
      refute Alerts.visitor_alert?(visitor(%{referrer_medium: "social"}), config)
      refute Alerts.visitor_alert?(visitor(%{referrer_medium: nil}), config)

      assert Alerts.visitor_alert?(visitor(%{referrer_medium: nil}), %{
               @base_config
               | channels: ["none"]
             })

      refute Alerts.visitor_alert?(visitor(), %{@base_config | channels: []})
    end

    test "landing path patterns, literal and * prefix" do
      config = %{@base_config | paths: ["/pricing", "/blog*"]}

      assert Alerts.visitor_alert?(visitor(%{path: "/pricing"}), config)
      assert Alerts.visitor_alert?(visitor(%{path: "/blog/hello"}), config)
      refute Alerts.visitor_alert?(visitor(%{path: "/pricing/enterprise"}), config)
      refute Alerts.visitor_alert?(visitor(%{path: "/about"}), config)
    end
  end

  # ── recipients ────────────────────────────────────────────────────────────

  describe "recipients/0" do
    test "includes an active Owner and drops them once inactive" do
      owner = user_fixture()
      assert owner.uuid in Alerts.recipients()

      deactivate(owner)
      refute owner.uuid in Alerts.recipients()
    end

    test "a plain user is not a recipient" do
      owner = user_fixture()
      plain = user_fixture()

      recipients = Alerts.recipients()
      assert owner.uuid in recipients
      refute plain.uuid in recipients
    end
  end

  # ── event_recorded/2 ──────────────────────────────────────────────────────

  describe "event_recorded/2 — visitors" do
    setup do
      owner = user_fixture()
      enable_tracking(%{"web_analytics_alert_visitors" => "true"})
      {:ok, owner: owner}
    end

    test "a new session's first page view alerts every recipient", %{owner: owner} do
      event = pageview()

      assert Alerts.event_recorded(event, true) == :ok

      row =
        assert_activity_logged("web_analytics.visitor_arrived",
          target_uuid: owner.uuid,
          resource_uuid: event.session_id
        )

      assert is_binary(row.metadata["notification_text"])
      assert row.metadata["notification_text"] =~ "/pricing"
      assert row.metadata["notification_link"] =~ event.session_id
    end

    test "a page view in an existing session alerts nobody" do
      assert Alerts.event_recorded(pageview(), false) == :ok
      refute_activity_logged("web_analytics.visitor_arrived")
    end

    test "nothing while tracking itself is off" do
      PhoenixKit.Settings.update_boolean_setting_with_module(
        "web_analytics_enabled",
        false,
        "web_analytics"
      )

      clear_settings_cache()
      PhoenixKit.Cache.put(:settings, "web_analytics_enabled", "false")
      PhoenixKit.Cache.put(:settings, "web_analytics_alert_visitors", "true")

      Alerts.event_recorded(pageview(), true)
      refute_activity_logged("web_analytics.visitor_arrived")
    end

    test "the hourly cap holds visitor alerts back" do
      enable_tracking(%{"web_analytics_alert_max_per_hour" => "2"})
      start_supervised!(Alerts)

      for _ <- 1..3, do: Alerts.event_recorded(pageview(), true)

      assert length(activities("web_analytics.visitor_arrived")) == 2
    end

    test "the first alert after a held-back spell says how many were not shown" do
      start_supervised!(Alerts)
      # The hour can't be moved in a test; the held-back counter it keeps can.
      :ets.insert(@alerts_table, {:held_back, 1})

      Alerts.event_recorded(pageview(), true)
      Alerts.event_recorded(pageview(), true)

      texts =
        "web_analytics.visitor_arrived"
        |> activities()
        |> Enum.map(& &1.metadata["notification_text"])

      assert Enum.count(texts, &(&1 =~ "(+1 more not shown)")) == 1
      assert length(texts) == 2
    end
  end

  describe "event_recorded/2 — tracked events" do
    setup do
      owner = user_fixture()
      enable_tracking(%{"web_analytics_alert_events" => "order.placed, contact*"})
      {:ok, owner: owner}
    end

    test "a listed custom event alerts", %{owner: owner} do
      event = %Event{
        event_type: "event",
        event_name: "order.placed",
        path: "/checkout",
        session_id: UUIDv7.generate()
      }

      Alerts.event_recorded(event, false)

      row = assert_activity_logged("web_analytics.event_alert", target_uuid: owner.uuid)
      assert row.metadata["event"] == "order.placed"
      assert row.metadata["notification_link"] =~ event.session_id
    end

    test "a listed interaction (prefix pattern) alerts; an unlisted one doesn't" do
      Alerts.event_recorded(
        %Event{
          event_type: "interaction",
          event_name: "contact_submit",
          path: "/",
          session_id: UUIDv7.generate()
        },
        false
      )

      Alerts.event_recorded(
        %Event{
          event_type: "event",
          event_name: "newsletter",
          path: "/",
          session_id: UUIDv7.generate()
        },
        false
      )

      assert [row] = activities("web_analytics.event_alert")
      assert row.metadata["event"] == "contact_submit"
    end

    test "never raises, even on an event it can't format" do
      # A path that can't be interpolated into the alert text makes the
      # formatting raise inside event_recorded; it must stay :ok.
      event = %Event{
        event_type: "event",
        event_name: "order.placed",
        path: %{not: "a string"},
        session_id: UUIDv7.generate()
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Alerts.event_recorded(event, true) == :ok
        end)

      assert log =~ "alert failed"
      refute_activity_logged("web_analytics.event_alert")
    end
  end

  # ── user_registered/1 ─────────────────────────────────────────────────────

  describe "user_registered/1" do
    setup do
      owner = user_fixture()
      enable_tracking()
      {:ok, owner: owner}
    end

    test "sends one sign-up alert, without the email", %{owner: owner} do
      user = user_fixture()

      assert Alerts.user_registered(user) == :ok

      row =
        assert_activity_logged("web_analytics.user_registered",
          target_uuid: owner.uuid,
          resource_uuid: user.uuid
        )

      refute row.metadata["notification_text"] =~ user.email
      refute inspect(row.metadata) =~ user.email
    end

    test "a second call for the same user sends nothing more (cross-node dedupe)" do
      user = user_fixture()

      Alerts.user_registered(user)
      Alerts.user_registered(user)

      assert [_one] = activities("web_analytics.user_registered")
    end

    test "sign-up alerts switched off → none" do
      enable_tracking(%{"web_analytics_alert_signups" => "false"})
      Alerts.user_registered(user_fixture())

      refute_activity_logged("web_analytics.user_registered")
    end

    test "a map without a uuid is ignored" do
      assert Alerts.user_registered(%{email: "x@example.com"}) == :ok
      refute_activity_logged("web_analytics.user_registered")
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp pageview do
    %Event{
      event_type: "pageview",
      path: "/pricing",
      referrer_medium: "organic",
      referrer_source: "Google",
      browser: "Firefox",
      session_id: UUIDv7.generate()
    }
  end

  # `PhoenixKit.Test.Fixtures.user_fixture/1` goes through the registration
  # rate limiter, whose Hammer backend this suite doesn't start. This is the
  # same insert + role assignment without it: the first user in the sandbox
  # becomes the Owner, later ones plain users.
  defp user_fixture do
    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "email" => "user#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })
      |> Repo.insert()

    {:ok, _role} = Roles.ensure_first_user_is_owner(user)
    Repo.get!(User, user.uuid)
  end

  defp activities(action) do
    Enum.filter(list_activities(), &(&1.action == action))
  end

  defp deactivate(user) do
    Repo.update_all(from(u in User, where: u.uuid == ^user.uuid), set: [is_active: false])
  end
end
