defmodule PhoenixKitWebAnalytics.PlugTest do
  @moduledoc """
  The plug's decision logic — which requests it will and won't consider.

  These run without a database: with tracking off (or settings unreachable) the
  plug must be a no-op, which is exactly the property worth pinning down. The
  storage side is covered by
  `PhoenixKitWebAnalytics.CollectorTest`.
  """

  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2, conn: 3]

  alias PhoenixKitWebAnalytics.Plug, as: TrackingPlug

  defp registered_callbacks(conn), do: conn.private[:before_send] || []

  describe "init/1" do
    test "normalizes the exclude option to a list" do
      assert TrackingPlug.init([])[:exclude] == []
      assert TrackingPlug.init(exclude: "/healthz")[:exclude] == ["/healthz"]
      assert TrackingPlug.init(exclude: ["/a", "/b"])[:exclude] == ["/a", "/b"]
    end
  end

  describe "skip/1" do
    test "marks a request as not-to-be-tracked" do
      conn = conn(:get, "/preview")

      refute TrackingPlug.skipped?(conn)
      assert conn |> TrackingPlug.skip() |> TrackingPlug.skipped?()
    end

    test "a skipped request never registers a callback" do
      conn =
        conn(:get, "/preview")
        |> TrackingPlug.skip()
        |> TrackingPlug.call(TrackingPlug.init([]))

      assert registered_callbacks(conn) == []
    end
  end

  describe "call/2" do
    test "ignores non-GET requests without reading settings" do
      for method <- [:post, :put, :patch, :delete, :head] do
        conn = conn(method, "/") |> TrackingPlug.call(TrackingPlug.init([]))

        assert registered_callbacks(conn) == []
      end
    end

    test "registers nothing while tracking is off" do
      conn = conn(:get, "/") |> TrackingPlug.call(TrackingPlug.init([]))

      assert registered_callbacks(conn) == []
    end

    test "passes the connection through unchanged" do
      original = conn(:get, "/pricing?utm_source=hn")
      result = TrackingPlug.call(original, TrackingPlug.init([]))

      assert result.request_path == original.request_path
      assert result.status == original.status
      assert result.state == original.state
    end
  end
end
