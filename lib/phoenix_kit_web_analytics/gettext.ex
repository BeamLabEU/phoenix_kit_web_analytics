defmodule PhoenixKitWebAnalytics.Gettext do
  @moduledoc """
  Gettext backend for phoenix_kit_web_analytics — every string the module
  shows: admin pages, tab labels, notification text.

  Catalogues live in `priv/gettext` (en, et, ru). After changing strings:

      mix gettext.extract --merge
  """
  use Gettext.Backend, otp_app: :phoenix_kit_web_analytics
end
