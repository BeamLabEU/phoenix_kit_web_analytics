defmodule PhoenixKitWebAnalytics.AdminTest do
  use PhoenixKitWebAnalytics.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitWebAnalytics.Admin
  alias PhoenixKitWebAnalytics.Alerts
  alias PhoenixKitWebAnalytics.Schemas.DailyStat

  @exclude_key "web_analytics_exclude_paths"
  @retention_key "web_analytics_retention_days"
  @timeout_key "web_analytics_session_timeout_minutes"
  @dnt_key "web_analytics_respect_dnt"
  @bots_key "web_analytics_track_bots"
  @channels_key "web_analytics_alert_channels"
  @salt_key "web_analytics_hash_secret"

  setup do
    # activities.actor_uuid carries no foreign key, so any UUID identifies the
    # actor; a distinct one per test keeps the assertions honest.
    %{actor: UUIDv7.generate()}
  end

  defp read(key) do
    clear_settings_cache()
    Settings.get_setting(key, nil)
  end

  describe "save_settings/2" do
    test "writes each valid field and returns only the changed keys", %{actor: actor} do
      params = %{
        "exclude_paths" => "  /admin\n/health  ",
        "retention_days" => "90",
        "session_timeout" => "45"
      }

      assert {:ok, changed} = Admin.save_settings(params, actor_uuid: actor)

      assert Enum.sort(changed) == Enum.sort([@exclude_key, @retention_key, @timeout_key])
      # Text is trimmed before it is stored.
      assert read(@exclude_key) == "/admin\n/health"
      assert read(@retention_key) == "90"
      assert read(@timeout_key) == "45"
    end

    test "a value longer than a setting can hold is refused by name, and nothing is saved",
         %{actor: actor} do
      params = %{
        "exclude_paths" => String.duplicate("/a-very-long-path\n", 60),
        "retention_days" => "90"
      }

      assert {:error, [:exclude_paths]} = Admin.save_settings(params, actor_uuid: actor)
      assert read(@retention_key) == nil
      refute_activity_logged("settings.updated")
    end

    test "each setting's own history names the admin who changed it", %{actor: actor} do
      {:ok, _} = Admin.save_settings(%{"retention_days" => "90"}, actor_uuid: actor)

      assert_activity_logged("setting.changed",
        actor_uuid: actor,
        metadata_has: %{"key" => @retention_key, "source" => "settings"}
      )
    end

    test "a save drops cached reports, so the next read sees the new settings", %{actor: actor} do
      unless Process.whereis(PhoenixKitWebAnalytics.ReportCache),
        do: start_supervised!(PhoenixKitWebAnalytics.ReportCache)

      assert PhoenixKitWebAnalytics.ReportCache.fetch(:cached_report, fn -> :old end, 60_000) ==
               :old

      {:ok, _} = Admin.save_settings(%{"retention_days" => "90"}, actor_uuid: actor)

      assert PhoenixKitWebAnalytics.ReportCache.fetch(:cached_report, fn -> :new end, 60_000) ==
               :new
    end

    test "saving the same params twice changes nothing the second time", %{actor: actor} do
      params = %{"retention_days" => "120", "exclude_paths" => "/x"}

      assert {:ok, [_, _]} = Admin.save_settings(params, actor_uuid: actor)
      assert {:ok, []} = Admin.save_settings(params, actor_uuid: actor)

      # Exactly one row: the no-op save logged nothing.
      assert_activity_logged("settings.updated", actor_uuid: actor)
    end

    test "only the keys whose value changed are reported", %{actor: actor} do
      {:ok, _} = Admin.save_settings(%{"retention_days" => "120"}, actor_uuid: actor)

      assert {:ok, [@timeout_key]} =
               Admin.save_settings(
                 %{"retention_days" => "120", "session_timeout" => "10"},
                 actor_uuid: actor
               )
    end

    test "logs settings.updated with the actor and the changed keys", %{actor: actor} do
      assert {:ok, [@retention_key]} =
               Admin.save_settings(%{"retention_days" => "30"}, actor_uuid: actor)

      row =
        assert_activity_logged("settings.updated",
          actor_uuid: actor,
          metadata_has: %{"changed" => [@retention_key]}
        )

      assert row.module == "web_analytics"
      assert row.resource_type == "web_analytics_settings"
    end

    test "a blank text field over an unset key is not a change", %{actor: actor} do
      assert {:ok, []} = Admin.save_settings(%{"exclude_paths" => "   "}, actor_uuid: actor)
      assert read(@exclude_key) == nil
      refute_activity_logged("settings.updated")
    end

    for {field, value} <- [
          {"retention_days", "-5"},
          {"retention_days", "3651"},
          {"retention_days", "12abc"},
          {"retention_days", "1.5"},
          {"retention_days", ""},
          {"session_timeout", "0"},
          {"session_timeout", "1441"},
          {"alert_max_per_hour", "10001"}
        ] do
      test "#{field}=#{inspect(value)} is rejected and nothing is written", %{actor: actor} do
        field = unquote(field)

        assert {:error, [error]} =
                 Admin.save_settings(
                   %{field => unquote(value), "exclude_paths" => "/changed"},
                   actor_uuid: actor
                 )

        assert error == String.to_existing_atom(field)
        # The valid field alongside it is not saved either.
        assert read(@exclude_key) == nil
        refute_activity_logged("settings.updated")
      end
    end

    test "every invalid field is named", %{actor: actor} do
      assert {:error, errors} =
               Admin.save_settings(
                 %{"retention_days" => "-5", "session_timeout" => "0"},
                 actor_uuid: actor
               )

      assert Enum.sort(errors) == [:retention_days, :session_timeout]
      assert read(@retention_key) == nil
      assert read(@timeout_key) == nil
    end

    test "boundary integers are accepted" do
      assert {:ok, _} =
               Admin.save_settings(%{"retention_days" => "0", "session_timeout" => "1440"})

      assert read(@retention_key) == "0"
      assert read(@timeout_key) == "1440"
    end

    test "non-string values are rejected" do
      assert {:error, [:retention_days]} = Admin.save_settings(%{"retention_days" => 30})
      assert {:error, [:exclude_paths]} = Admin.save_settings(%{"exclude_paths" => ["/a"]})
      assert {:error, [:alert_channels]} = Admin.save_settings(%{"alert_channels" => "organic"})
    end

    test "with _form, an absent boolean is saved as false" do
      {:ok, _} = Admin.save_settings(%{"respect_dnt" => "true", "track_bots" => "on"})
      assert read(@dnt_key) == "true"
      assert read(@bots_key) == "true"

      assert {:ok, changed} = Admin.save_settings(%{"_form" => "settings", "track_bots" => "on"})

      assert @dnt_key in changed
      refute @bots_key in changed
      assert read(@dnt_key) == "false"
      assert read(@bots_key) == "true"
    end

    test "without _form, an absent boolean is left alone" do
      {:ok, _} = Admin.save_settings(%{"respect_dnt" => "true"})

      assert {:ok, [@exclude_key]} = Admin.save_settings(%{"exclude_paths" => "/x"})
      assert read(@dnt_key) == "true"
    end

    test "boolean values other than true/on are false" do
      {:ok, _} = Admin.save_settings(%{"respect_dnt" => "yes"})
      assert read(@dnt_key) == "false"
    end
  end

  describe "save_settings/2 recording and bot settings" do
    test "are saved, and out-of-range numbers refused by name" do
      assert {:ok, changed} =
               Admin.save_settings(%{
                 "_form" => "settings",
                 "recording" => "true",
                 "detect_bots" => "true",
                 "recording_sample" => "25",
                 "recording_retention_days" => "14"
               })

      assert "web_analytics_recording" in changed
      assert read("web_analytics_recording") == "true"
      assert read("web_analytics_recording_sample") == "25"
      assert read("web_analytics_recording_retention_days") == "14"

      assert {:error, fields} =
               Admin.save_settings(%{
                 "recording_sample" => "0",
                 "recording_retention_days" => "0"
               })

      assert Enum.sort(fields) == [:recording_retention_days, :recording_sample]
    end
  end

  describe "save_settings/2 alert channels" do
    test "a list is saved as a comma list of the known channels" do
      assert {:ok, [@channels_key]} =
               Admin.save_settings(%{"alert_channels" => ["organic", "bogus", "social"]})

      assert read(@channels_key) == "organic, social"
      clear_settings_cache()
      assert Alerts.config().channels == ["organic", "social"]
    end

    test "an empty selection on the form saves \"-\", meaning no channel" do
      assert {:ok, changed} = Admin.save_settings(%{"_form" => "alerts"})

      assert @channels_key in changed
      assert read(@channels_key) == "-"
      clear_settings_cache()
      assert Alerts.config().channels == []
    end

    test "a selection of only unknown channels is no channel" do
      assert {:ok, _} = Admin.save_settings(%{"alert_channels" => ["bogus", "none!"]})

      assert read(@channels_key) == "-"
      clear_settings_cache()
      assert Alerts.config().channels == []
    end

    test "without _form, absent channels are left alone (every channel)" do
      assert {:ok, []} = Admin.save_settings(%{})
      assert read(@channels_key) == nil
      clear_settings_cache()
      assert Alerts.config().channels == Alerts.channels()
    end
  end

  describe "set_tracking/2" do
    test "true enables tracking and logs tracking.enabled with the actor", %{actor: actor} do
      refute PhoenixKitWebAnalytics.enabled?()

      assert :ok = Admin.set_tracking(true, actor_uuid: actor)

      clear_settings_cache()
      assert PhoenixKitWebAnalytics.enabled?()
      assert_activity_logged("tracking.enabled", actor_uuid: actor)
      refute_activity_logged("tracking.disabled")
    end

    test "false disables tracking and logs tracking.disabled with the actor", %{actor: actor} do
      enable_tracking()
      assert PhoenixKitWebAnalytics.enabled?()

      assert :ok = Admin.set_tracking(false, actor_uuid: actor)

      clear_settings_cache()
      refute PhoenixKitWebAnalytics.enabled?()
      assert_activity_logged("tracking.disabled", actor_uuid: actor)
      refute_activity_logged("tracking.enabled")
    end

    test "enabling also provisions a visitor salt" do
      assert read(@salt_key) == nil
      :ok = Admin.set_tracking(true)
      assert is_binary(read(@salt_key))
    end
  end

  describe "run_retention/1" do
    test "returns the counts and logs them", %{actor: actor} do
      enable_tracking(%{@retention_key => "10"})
      insert_event(%{inserted_at: days_ago(20)})
      insert_event(%{inserted_at: days_ago(20)})
      insert_event(%{inserted_at: days_ago(2)})

      assert %{rolled_up: 2, pruned: 2} = Admin.run_retention(actor_uuid: actor)
      assert Repo.aggregate(DailyStat, :count) == 2

      assert_activity_logged("retention.run",
        actor_uuid: actor,
        metadata_has: %{"rolled_up" => 2, "pruned" => 2}
      )
    end

    test "logs a no-op run too, with zero counts", %{actor: actor} do
      assert %{rolled_up: 0, pruned: 0} = Admin.run_retention(actor_uuid: actor)

      assert_activity_logged("retention.run",
        actor_uuid: actor,
        metadata_has: %{"rolled_up" => 0, "pruned" => 0}
      )
    end
  end

  describe "rotate_salt/1" do
    test "replaces the stored salt and never logs it", %{actor: actor} do
      old = PhoenixKitWebAnalytics.Config.generate_salt()
      assert is_binary(old)

      assert :ok = Admin.rotate_salt(actor_uuid: actor)

      new = read(@salt_key)
      assert is_binary(new)
      assert byte_size(new) >= 16
      refute new == old

      row = assert_activity_logged("salt.rotated", actor_uuid: actor)
      logged = inspect(row)
      refute logged =~ new
      refute logged =~ old
      refute Map.has_key?(row.metadata || %{}, "db_pending")
    end

    test "no activity row, core's own setting history included, holds a salt", %{actor: actor} do
      old = PhoenixKitWebAnalytics.Config.generate_salt()
      assert :ok = Admin.rotate_salt(actor_uuid: actor)
      new = read(@salt_key)

      # Core writes a `setting.changed` row per setting write, and withholds
      # the value only for a key whose name marks it as a secret.
      assert Enum.any?(list_activities(), &(&1.action == "setting.changed"))
      logged = inspect(list_activities(), limit: :infinity, printable_limit: :infinity)
      refute logged =~ old
      refute logged =~ new
    end
  end
end
