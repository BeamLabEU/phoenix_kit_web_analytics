defmodule PhoenixKitWebAnalytics.Web.CSP do
  @moduledoc false
  # The host's Content-Security-Policy nonce for an inline `<script>` or `<style>` this module
  # renders, read from core's `PhoenixKitWeb.CSP` (a host with a policy like
  # `script-src 'self' 'nonce-…'` names its assign in `config :phoenix_kit,
  # csp_nonce_assign_key:`). Core releases before the nonce support have no such module, so it
  # is looked up at runtime: there, and on a host that set no nonce, the answer is `nil` and
  # `nonce={nil}` renders no attribute.

  @type kind :: :script | :style

  @doc """
  The nonce of the page being rendered for `kind`, or `nil`.
  """
  @spec nonce(kind) :: String.t() | nil
  def nonce(kind) when kind in [:script, :style] do
    # Named at runtime, so the call compiles (and passes dialyzer) against a core without it.
    core = Module.concat(PhoenixKitWeb, CSP)

    if Code.ensure_loaded?(core) and function_exported?(core, :nonce, 1) do
      case core.nonce(kind) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end
  end

  @doc """
  The same, for a component that also takes the nonce as an attribute: a string the caller
  passed wins, `false` means "no nonce on this tag" and `nil` reads the page's.
  """
  @spec nonce(kind, String.t() | false | nil) :: String.t() | nil
  def nonce(_kind, explicit) when is_binary(explicit) and explicit != "", do: explicit
  def nonce(_kind, false), do: nil
  def nonce(kind, _unset), do: nonce(kind)
end
