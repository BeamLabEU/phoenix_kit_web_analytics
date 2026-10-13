defmodule PhoenixKitWebAnalytics.ConsentLegalSourceTest do
  @moduledoc """
  The Legal module as the source of answers. Legal is an optional package
  this suite does not depend on, so two stand-ins carrying its module names
  are compiled for the length of each test and unloaded after it: core's
  layouts look for `PhoenixKit.Modules.Legal` by name, and a stand-in left
  loaded would change what every other test renders.
  """

  # Not async: the stand-ins are loaded into the whole VM.
  use ExUnit.Case, async: false

  alias PhoenixKitWebAnalytics.Consent

  @flags {__MODULE__, :legal}
  @warned {Consent, :source_failed_warned}
  @stand_ins [PhoenixKit.Modules.Legal, PhoenixKit.Modules.Legal.Consent]

  setup do
    for module <- @stand_ins do
      refute Code.ensure_loaded?(module),
             "#{inspect(module)} is really installed; this test would replace it"
    end

    Application.delete_env(:phoenix_kit_web_analytics, :consent_source)
    :persistent_term.erase(@warned)
    legal(enabled?: true, banner?: true, status: :unknown)

    Code.compile_string("""
    defmodule PhoenixKit.Modules.Legal do
      def enabled?, do: flag(:enabled?)
      def consent_widget_enabled?, do: flag(:banner?)
      def flag(name), do: :persistent_term.get(#{inspect(@flags)})[name]
    end

    defmodule PhoenixKit.Modules.Legal.Consent do
      def status(_conn, category) do
        case PhoenixKit.Modules.Legal.flag(:status) do
          :raise -> raise "the consent cookie could not be read"
          :by_category -> if category == "marketing", do: :granted, else: :denied
          status -> status
        end
      end
    end
    """)

    on_exit(fn ->
      for module <- @stand_ins do
        :code.purge(module)
        :code.delete(module)
      end

      :persistent_term.erase(@flags)
      :persistent_term.erase(@warned)
    end)

    :ok
  end

  defp legal(flags), do: :persistent_term.put(@flags, flags)
  defp conn, do: Plug.Test.conn(:get, "/")

  test "is the source while the module is enabled and its banner is on" do
    assert Consent.source() == :legal

    legal(enabled?: true, banner?: true, status: :granted)
    assert Consent.status(conn(), "analytics") == :granted

    legal(enabled?: true, banner?: true, status: :denied)
    assert Consent.status(conn(), "analytics") == :denied

    legal(enabled?: true, banner?: true, status: :unknown)
    assert Consent.status(conn(), "analytics") == :unknown
  end

  test "is asked about the category the rules are set under" do
    legal(enabled?: true, banner?: true, status: :by_category)

    assert Consent.status(conn(), "marketing") == :granted
    assert Consent.status(conn(), "analytics") == :denied
  end

  test "is not the source with its banner off, or the module disabled" do
    legal(enabled?: true, banner?: false, status: :granted)
    assert Consent.source() == :none
    assert Consent.status(conn(), "analytics") == :unknown

    legal(enabled?: false, banner?: true, status: :granted)
    assert Consent.source() == :none
  end

  test "the host's own consent tool is asked instead, when one is configured" do
    Application.put_env(:phoenix_kit_web_analytics, :consent_source, {__MODULE__, :host_status})
    on_exit(fn -> Application.delete_env(:phoenix_kit_web_analytics, :consent_source) end)
    legal(enabled?: true, banner?: true, status: :granted)

    assert Consent.source() == {:host, {__MODULE__, :host_status}}
    assert Consent.status(conn(), "analytics") == :denied
  end

  test "a cookie that cannot be read is a refusal, logged by the source's name" do
    legal(enabled?: true, banner?: true, status: :raise)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Consent.status(conn(), "analytics") == :denied
      end)

    assert log =~ "PhoenixKit.Modules.Legal.Consent.status/2"
    refute log =~ "could not be read"
  end

  @doc false
  def host_status(_conn, _category), do: :denied
end
