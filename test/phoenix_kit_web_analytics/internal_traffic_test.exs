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

    test "skips what isn't a network, with a warning" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for bad <- ["", "nope", "203.0.113.0/33", "2001:db8::/129", "203.0.113.0/x", "1.2.3/8"] do
            assert InternalTraffic.parse_cidr(bad) == [], bad
          end
        end)

      assert log =~ "\"nope\" is not a network"
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

    test "a network's time runs out" do
      past = System.system_time(:millisecond) - 1
      send(InternalTraffic, {:admin_network, "198.51.100.9", past})
      :sys.get_state(InternalTraffic)

      refute InternalTraffic.admin_network?({198, 51, 100, 9}, config())
    end

    test "is told to the other nodes when new, not on every request" do
      Manager.subscribe(@topic)

      InternalTraffic.note_admin_network({198, 51, 100, 7}, config())
      assert_receive {:admin_network, "198.51.100.7", expires}
      assert expires > System.system_time(:millisecond) + 23 * 3_600_000

      InternalTraffic.note_admin_network({198, 51, 100, 7}, config())
      refute_receive {:admin_network, _, _}, 50
    end

    test "is told again once past half its time" do
      Manager.subscribe(@topic)
      soon = System.system_time(:millisecond) + :timer.hours(1)
      send(InternalTraffic, {:admin_network, "198.51.100.7", soon})
      :sys.get_state(InternalTraffic)
      # The test's own subscription sees what was just sent to the server only
      # by the server; drain anything else.
      refute_receive {:admin_network, _, _}, 10

      InternalTraffic.note_admin_network({198, 51, 100, 7}, config())
      assert_receive {:admin_network, "198.51.100.7", _}
    end

    test "a note from another node is taken" do
      later = System.system_time(:millisecond) + :timer.hours(2)
      Manager.broadcast(@topic, {:admin_network, "198.51.100.44", later})
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
