defmodule PhoenixKitWebAnalytics.Signals do
  @moduledoc """
  What the client script measures about a visitor's device, and the hash
  that names the device.

  A visitor ID changes when the address does. A device doesn't: the same
  machine draws the same canvas, reports the same graphics card, the same
  fonts and the same screen from any network. Hashing those gives a
  **device hash** that follows a scraper across the addresses it rotates
  through — and, equally, a person across theirs, which is why it is off
  until `web_analytics_store_signals` is switched on, and why that needs the
  client script.

  ## The measurements

  Sent by the script as a flat map of short keys; `clean/1` keeps the ones
  listed here, in the shape listed, and nothing else:

  | Key | What |
  |-----|------|
  | `tz`, `tzo` | time zone name, and its offset in minutes |
  | `lang`, `langs` | the browser's language, and its list of them |
  | `plat`, `ven` | `navigator.platform`, `navigator.vendor` |
  | `hc`, `dm` | processor threads, memory in GB (as the browser rounds it) |
  | `tp` | touch points |
  | `sw`, `sh`, `aw`, `ah` | screen size, and the part of it available |
  | `iw`, `ih`, `ow`, `oh` | the window's inner and outer size |
  | `cd`, `dpr` | colour depth, pixel ratio |
  | `ce`, `pdf`, `pl` | cookies on, built-in PDF viewer, number of plugins |
  | `wd` | `navigator.webdriver` |
  | `chr` | `window.chrome` exists |
  | `dark`, `rm`, `coarse` | prefers dark, prefers reduced motion, coarse pointer |
  | `gv`, `gr` | graphics vendor and renderer (WebGL) |
  | `cv` | a hash of a drawn canvas |
  | `au` | a number from a rendered audio buffer |
  | `fonts` | which of a fixed list of fonts are installed |
  | `uap`, `uapv`, `uaa`, `uam`, `uamob` | client hints: platform, its version, architecture, model, mobile |

  ## The hash

  `device_hash/2` covers the measurements that belong to the machine and
  stay put — graphics, canvas, audio, fonts, screen, processor, memory, time
  zone, languages — and none that change with the window or the moment. It
  needs at least one of the three strong ones (canvas, renderer, audio);
  without any, too many devices would share a hash, so there is none.

  It is salted with the module's hash salt: the same device has a different
  hash on another site, and rotating the salt starts every device afresh.
  """

  alias PhoenixKitWebAnalytics.Tracking

  @strings %{
    "tz" => 64,
    "lang" => 35,
    "plat" => 40,
    "ven" => 60,
    "gv" => 120,
    "gr" => 200,
    "cv" => 40,
    "au" => 40,
    "uap" => 40,
    "uapv" => 40,
    "uaa" => 20,
    "uam" => 60
  }
  # {min, max} — anything outside is a broken or hostile client.
  @integers %{
    "tzo" => {-900, 900},
    "hc" => {0, 1024},
    "tp" => {0, 100},
    "sw" => {0, 32_767},
    "sh" => {0, 32_767},
    "aw" => {0, 32_767},
    "ah" => {0, 32_767},
    "iw" => {0, 32_767},
    "ih" => {0, 32_767},
    "ow" => {0, 32_767},
    "oh" => {0, 32_767},
    "cd" => {0, 64},
    "pl" => {0, 500}
  }
  @numbers %{"dm" => {0, 1024}, "dpr" => {0, 16}}
  @booleans ~w(ce pdf wd chr dark rm coarse uamob)
  # {how many, how long each}
  @lists %{"langs" => {10, 35}, "fonts" => {40, 40}}

  @hashed ~w(tz langs plat ven hc dm tp sw sh cd dpr gv gr cv au fonts)
  @strong ~w(cv gr au)

  @doc """
  The measurements worth keeping out of what a client sent: known keys, of
  the expected type, within bounds. `nil` when nothing is left.

      iex> PhoenixKitWebAnalytics.Signals.clean(%{"hc" => 8, "tz" => "Europe/Tallinn", "x" => 1})
      %{"hc" => 8, "tz" => "Europe/Tallinn"}

      iex> PhoenixKitWebAnalytics.Signals.clean(%{"hc" => "eight"})
      nil
  """
  @spec clean(term()) :: map() | nil
  def clean(raw) when is_map(raw) do
    kept =
      for {key, value} <- raw, is_binary(key), cleaned = value(key, value), into: %{} do
        {key, unwrap(cleaned)}
      end

    if map_size(kept) > 0, do: kept
  end

  def clean(_raw), do: nil

  @doc """
  The device's hash: 32 hex characters, or `nil` when the measurements
  can't tell devices apart (none of canvas, renderer or audio).
  """
  @spec device_hash(map() | nil, String.t()) :: String.t() | nil
  def device_hash(signals, salt) when is_map(signals) and is_binary(salt) do
    if Enum.any?(@strong, &is_map_key(signals, &1)) do
      material = Enum.map_join(@hashed, "|", &"#{&1}=#{canonical(signals[&1])}")

      :crypto.hash(:sha256, [salt, "|device|", material])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)
    end
  end

  def device_hash(_signals, _salt), do: nil

  # ── internals ─────────────────────────────────────────────────────────────

  # A kept value is wrapped, so `false` and `0` survive the comprehension's
  # truthiness filter.
  defp unwrap({:ok, value}), do: value

  defp value(key, value) when is_map_key(@strings, key), do: string(value, @strings[key])

  defp value(key, value) when is_map_key(@integers, key) and is_integer(value),
    do: within(value, @integers[key])

  defp value(key, value) when is_map_key(@numbers, key) and is_number(value),
    do: within(value, @numbers[key])

  defp value(key, value) when key in @booleans and is_boolean(value), do: {:ok, value}

  defp value(key, values) when is_map_key(@lists, key) and is_list(values) do
    {count, length} = @lists[key]

    {:ok,
     for(
       item <- Enum.take(values, count),
       {:ok, text} <- [string(item, length)],
       do: text
     )}
  end

  defp value(_key, _value), do: nil

  defp within(value, {min, max}) when value >= min and value <= max, do: {:ok, value}
  defp within(_value, _range), do: nil

  defp string(value, max) when is_binary(value) do
    if String.valid?(value) do
      case value |> String.replace(<<0>>, "") |> String.trim() do
        "" -> nil
        trimmed -> {:ok, Tracking.truncate_utf8(trimmed, max)}
      end
    end
  end

  defp string(_value, _max), do: nil

  defp canonical(value) when is_list(value), do: Enum.join(value, ",")
  defp canonical(nil), do: ""
  defp canonical(value), do: to_string(value)
end
