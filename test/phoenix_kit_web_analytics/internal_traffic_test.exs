defmodule PhoenixKitWebAnalytics.InternalTrafficTest do
  use PhoenixKitWebAnalytics.DataCase, async: false

  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Roles
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.InternalTraffic

  @topic "phoenix_kit_web_analytics:admin_networks"

  setup do
    previous = Application.get_env(:phoenix_kit_web_analytics, :internal_networks)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_web_analytics, :internal_networks, previous),
        else: Application.delete_env(:phoenix_kit_web_analytics, :internal_networks)
    end)

    :ok
  end

  defp networks(list),
    do: Application.put_env(:phoenix_kit_web_analytics, :internal_networks, list)

  defp config(overrides \\ %{}) do
    Map.merge(
      %{internal_roles: ["Owner", "Admin"], admin_network_hours: 24, excluded_flags: 7},
      overrides
    )
  end

  describe "parse_cidr/1" do
    test "reads IPv4 and IPv6 networks and a bare address as one host" do
      assert [{32, _, 24}] = InternalTraffic.parse_cidr("203.0.113.0/24")
      assert [{128, _, 48}] = InternalTraffic.parse_cidr("2001:db8::/48")
      assert [{32, _, 32}] = InternalTraffic.parse_cidr("198.51.100.7")
    end

    test "skips what isn't a network" do
      for bad <- ["", "nope", "203.0.113.0/33", "2001:db8::/129", "203.0.113.0/x", "1.2.3/8"] do
        assert InternalTraffic.parse_cidr(bad) == [], bad
      end
    end

    test "invalid configured entries are counted and warned about, never quoted" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          networks(["203.0.113.0/24", "198.51.100.300/24", "nope", 42])
          assert InternalTraffic.network_counts() == %{valid: 1, invalid: 3}
        end)

      assert log =~ "3 invalid entries skipped"
      refute log =~ "198.51.100"
      refute log =~ "nope"
    end

    test "one invalid entry is warned about in the singular" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          networks(["203.0.113.0/24", :not_a_string])
          assert InternalTraffic.network_counts() == %{valid: 1, invalid: 1}
        end)

      assert log =~ "1 invalid entry skipped"
    end
  end

  describe "internal_network?/1" do
    test "matches addresses inside a configured network, and nothing else" do
      networks(["203.0.113.0/24", "2001:db8:aa::/48"])

      assert InternalTraffic.internal_network?({203, 0, 113, 200})
      refute InternalTraffic.internal_network?({203, 0, 114, 1})
      assert InternalTraffic.internal_network?({0x2001, 0xDB8, 0xAA, 1, 0, 0, 0, 9})
      refute InternalTraffic.internal_network?({0x2001, 0xDB8, 0xAB, 1, 0, 0, 0, 9})
    end

    test "is a boolean even for a tuple that is no address" do
      networks(["203.0.113.0/24"])
      assert InternalTraffic.internal_network?({1, 2, 3}) == false
    end

    test "an IPv4-mapped IPv6 address is matched as its IPv4" do
      networks(["203.0.113.0/24"])

      assert InternalTraffic.internal_network?({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7105})
    end

    test "follows a config change, and is false with none configured" do
      networks(["203.0.113.0/24"])
      assert InternalTraffic.internal_network?({203, 0, 113, 1})

      networks([])
      refute InternalTraffic.internal_network?({203, 0, 113, 1})
      refute InternalTraffic.internal_network?(nil)
    end
  end

  describe "staff networks" do
    setup do
      start_supervised!(InternalTraffic)
      :ok
    end

    test "a noted public address flags its network for the configured hours" do
      refute InternalTraffic.admin_network?({198, 51, 100, 7}, config())

      InternalTraffic.note_admin_network({198, 51, 100, 7}, config())

      assert InternalTraffic.admin_network?({198, 51, 100, 7}, config())
      refute InternalTraffic.admin_network?({198, 51, 100, 8}, config())
      # Switched off, it flags nothing.
      refute InternalTraffic.admin_network?({198, 51, 100, 7}, config(%{admin_network_hours: 0}))
    end

    test "an IPv6 address flags its whole /64" do
      InternalTraffic.note_admin_network("2001:db8:1:2:aaaa::1", config())

      assert InternalTraffic.admin_network?({0x2001, 0xDB8, 1, 2, 0xBBBB, 0, 0, 7}, config())
      refute InternalTraffic.admin_network?({0x2001, 0xDB8, 1, 3, 0, 0, 0, 1}, config())
    end

    test "private, loopback and unreadable addresses are never taken" do
      for ip <- [
            {10, 1, 2, 3},
            {172, 18, 0, 8},
            {192, 168, 1, 10},
            {127, 0, 0, 1},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            "unknown",
            "172.18.0.8",
            nil
          ] do
        InternalTraffic.note_admin_network(ip, config())
      end

      assert :ets.select_count(:phoenix_kit_web_analytics_internal_traffic, [
               {{{:net, :_}, :_}, [], [true]}
             ]) == 0

      refute InternalTraffic.admin_network?({172, 18, 0, 8}, config())
    end

    test "a network counts for the hours set now, from its last sighting" do
      seen = System.system_time(:millisecond) - :timer.hours(3)
      send(InternalTraffic, {:admin_network, "198.51.100.9", seen})
      :sys.get_state(InternalTraffic)

      assert InternalTraffic.admin_network?({198, 51, 100, 9}, config())
      # Shortened, the hours apply to networks already learnt.
      refute InternalTraffic.admin_network?({198, 51, 100, 9}, config(%{admin_network_hours: 2}))
      assert InternalTraffic.admin_network?({198, 51, 100, 9}, config(%{admin_network_hours: 4}))
    end

    test "a network past the hours set now is forgotten, all of them at 0" do
      enable_tracking()
      now = System.system_time(:millisecond)
      send(InternalTraffic, {:admin_network, "198.51.100.11", now - :timer.hours(25)})
      send(InternalTraffic, {:admin_network, "198.51.100.12", now - :timer.hours(1)})

      InternalTraffic.forget_expired()
      :sys.get_state(InternalTraffic)
      assert nets() == ["198.51.100.12"]

      PhoenixKitWebAnalytics.Admin.save_settings(%{"admin_network_hours" => "0"})
      clear_settings_cache()
      :sys.get_state(InternalTraffic)
      assert nets() == []
    end

    test "a settings read that fails (tracking reads as off) forgets nothing" do
      enable_tracking(%{"web_analytics_admin_network_hours" => "72"})
      seen = System.system_time(:millisecond) - :timer.hours(30)
      send(InternalTraffic, {:admin_network, "198.51.100.13", seen})
      :sys.get_state(InternalTraffic)

      # What a failed read gives: tracking off, default hours (24 < 30).
      Repo.query!("DELETE FROM phoenix_kit_settings WHERE key LIKE 'web_analytics_%'")
      clear_settings_cache()
      refute Config.collection_config().enabled?
      InternalTraffic.forget_expired()
      :sys.get_state(InternalTraffic)

      # Back: the network still counts by the 72 hours.
      enable_tracking(%{"web_analytics_admin_network_hours" => "72"})
      assert InternalTraffic.admin_network?({198, 51, 100, 13}, Config.collection_config())
    end

    test "a sighting dated in the future counts as now" do
      later = System.system_time(:millisecond) + :timer.hours(100)
      send(InternalTraffic, {:admin_network, "198.51.100.10", later})
      :sys.get_state(InternalTraffic)

      [{_, seen}] =
        :ets.lookup(:phoenix_kit_web_analytics_internal_traffic, {:net, "198.51.100.10"})

      assert seen <= System.system_time(:millisecond)
    end

    test "is told to the other nodes when new, not on every request" do
      Manager.subscribe(@topic)

      InternalTraffic.note_admin_network({198, 51, 100, 7}, config())
      assert_receive {:admin_network, "198.51.100.7", seen}
      assert_in_delta seen, System.system_time(:millisecond), 5_000

      InternalTraffic.note_admin_network({198, 51, 100, 7}, config())
      refute_receive {:admin_network, _, _}, 50
    end

    test "is told again once past half its time" do
      Manager.subscribe(@topic)
      long_ago = System.system_time(:millisecond) - :timer.hours(13)
      send(InternalTraffic, {:admin_network, "198.51.100.7", long_ago})
      :sys.get_state(InternalTraffic)
      # The test's own subscription sees what was just sent to the server only
      # by the server; drain anything else.
      refute_receive {:admin_network, _, _}, 10

      InternalTraffic.note_admin_network({198, 51, 100, 7}, config())
      assert_receive {:admin_network, "198.51.100.7", _}
    end

    test "recent local activity renews the network without broadcasting every request" do
      Manager.subscribe(@topic)
      ip = {198, 51, 100, 7}
      seen = System.system_time(:millisecond) - :timer.hours(3)
      send(InternalTraffic, {:admin_network, "198.51.100.7", seen})
      :sys.get_state(InternalTraffic)

      InternalTraffic.note_admin_network(ip, config())

      # Still within the broadcast interval, but the local last sighting is
      # now: shortening the timeout must not discard an active network.
      refute_receive {:admin_network, _, _}, 50
      assert InternalTraffic.admin_network?(ip, config(%{admin_network_hours: 1}))
    end

    test "frequent local activity does not postpone the next broadcast indefinitely" do
      Manager.subscribe(@topic)
      table = :phoenix_kit_web_analytics_internal_traffic
      ip = {198, 51, 100, 7}
      InternalTraffic.note_admin_network(ip, config())
      assert_receive {:admin_network, "198.51.100.7", _}
      :sys.get_state(InternalTraffic)

      # The local sighting is fresh but other nodes last heard 13 hours ago.
      :ets.insert(
        table,
        {{:shared, "198.51.100.7"}, System.system_time(:millisecond) - :timer.hours(13)}
      )

      InternalTraffic.note_admin_network(ip, config())
      assert_receive {:admin_network, "198.51.100.7", _}
    end

    test "a note from another node is taken" do
      Manager.broadcast(
        @topic,
        {:admin_network, "198.51.100.44", System.system_time(:millisecond)}
      )

      :sys.get_state(InternalTraffic)

      assert InternalTraffic.admin_network?({198, 51, 100, 44}, config())
    end
  end

  describe "the admin flag" do
    setup do
      start_supervised!(InternalTraffic)
      enable_tracking()
      :ok
    end

    test "comes from the roles a hit carries" do
      assert InternalTraffic.flags(%{roles: ["Admin", "User"]}, config()) == 2
      assert InternalTraffic.flags(%{roles: ["User"]}, config()) == 0

      assert InternalTraffic.flags(%{roles: ["Editor"]}, config(%{internal_roles: ["Editor"]})) ==
               2
    end

    test "a hit with only a user's UUID uses the roles remembered for them" do
      uuid = Ecto.UUID.generate()
      InternalTraffic.flags(%{user_uuid: uuid, roles: ["Owner"]}, config())

      assert InternalTraffic.flags(%{user_uuid: uuid}, config()) == 2
    end

    test "a looked-up staff member's address is a staff network, though their hit missed" do
      user = staff_user()

      assert InternalTraffic.flags(%{user_uuid: user.uuid, ip: {198, 51, 100, 30}}, config()) == 0
      assert InternalTraffic.admin_network?({198, 51, 100, 30}, config())
    end

    test "a looked-up ordinary user's address is not" do
      user = plain_user()

      InternalTraffic.flags(%{user_uuid: user.uuid, ip: {198, 51, 100, 31}}, config())
      refute InternalTraffic.admin_network?({198, 51, 100, 31}, config())
    end

    test "an unknown user is looked up off the hit; the next hit has the answer" do
      user = staff_user()

      assert InternalTraffic.flags(%{user_uuid: user.uuid}, config()) == 0
      assert InternalTraffic.flags(%{user_uuid: user.uuid}, config()) == 2
    end
  end

  describe "a staff sign-in" do
    setup do
      start_supervised!(InternalTraffic)
      enable_tracking()
      :ok
    end

    test "marks the network the session token was issued to" do
      user = staff_user()

      Auth.generate_user_session_token(user,
        fingerprint: %{ip_address: "198.51.100.23", user_agent_hash: "test"}
      )

      :sys.get_state(InternalTraffic)

      assert InternalTraffic.admin_network?({198, 51, 100, 23}, Config.collection_config())
    end

    test "remembers the user's roles, so a hit with only their UUID is flagged at once" do
      user = staff_user()

      Auth.generate_user_session_token(user,
        fingerprint: %{ip_address: "198.51.100.26", user_agent_hash: "test"}
      )

      :sys.get_state(InternalTraffic)

      assert InternalTraffic.flags(%{user_uuid: user.uuid}, Config.collection_config()) == 2
    end

    test "a token with no address (fingerprinting off) is not read again" do
      Application.put_env(:phoenix_kit_web_analytics, :admin_token_retry_ms, 10)
      on_exit(fn -> Application.delete_env(:phoenix_kit_web_analytics, :admin_token_retry_ms) end)

      user = staff_user()
      token_uuid = UUIDv7.generate()
      insert_token(user, token_uuid, nil)
      :erlang.trace(Process.whereis(InternalTraffic), true, [:receive])

      send(InternalTraffic, {:session_created, user, %{token_uuid: token_uuid}})
      :sys.get_state(InternalTraffic)

      refute_receive {:trace, _, :receive, {:retry_token, _, _}}, 100
    end

    test "while tracking is off, a sign-in is ignored" do
      Repo.query!("DELETE FROM phoenix_kit_settings WHERE key = 'web_analytics_enabled'")
      clear_settings_cache()
      user = staff_user()

      Auth.generate_user_session_token(user,
        fingerprint: %{ip_address: "198.51.100.27", user_agent_hash: "test"}
      )

      :sys.get_state(InternalTraffic)

      assert :ets.lookup(:phoenix_kit_web_analytics_internal_traffic, {:roles, user.uuid}) == []
    end

    test "a non-staff sign-in marks nothing" do
      _owner = staff_user()
      user = plain_user()

      Auth.generate_user_session_token(user,
        fingerprint: %{ip_address: "198.51.100.24", user_agent_hash: "test"}
      )

      :sys.get_state(InternalTraffic)

      refute InternalTraffic.admin_network?({198, 51, 100, 24}, Config.collection_config())
    end

    test "a token not readable yet is read once more" do
      Application.put_env(:phoenix_kit_web_analytics, :admin_token_retry_ms, 10)
      on_exit(fn -> Application.delete_env(:phoenix_kit_web_analytics, :admin_token_retry_ms) end)

      user = staff_user()
      token_uuid = UUIDv7.generate()

      send(InternalTraffic, {:session_created, user, %{token_uuid: token_uuid}})
      :sys.get_state(InternalTraffic)
      refute InternalTraffic.admin_network?({198, 51, 100, 25}, Config.collection_config())

      insert_token(user, token_uuid, "198.51.100.25")
      Process.sleep(30)
      :sys.get_state(InternalTraffic)

      assert InternalTraffic.admin_network?({198, 51, 100, 25}, Config.collection_config())
    end
  end

  defp nets do
    :phoenix_kit_web_analytics_internal_traffic
    |> :ets.select([{{{:net, :"$1"}, :_}, [], [:"$1"]}])
    |> Enum.sort()
  end

  defp staff_user, do: user_with_role("Admin")
  defp plain_user, do: user_with_role("User")

  # Straight into core's tables: registration goes through core's rate
  # limiter, which isn't running here.
  defp user_with_role(role) do
    user =
      Repo.insert!(%User{
        email: "test-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "not-a-real-hash"
      })

    {:ok, _} = Roles.assign_role(user, role)
    user
  end

  defp insert_token(user, token_uuid, ip) do
    Repo.insert!(%UserToken{
      uuid: token_uuid,
      token: :crypto.strong_rand_bytes(32),
      context: "session",
      user_uuid: user.uuid,
      ip_address: ip
    })
  end
end
