defmodule PhoenixKitWebAnalytics.Web.CSPInlineTagsTest do
  @moduledoc """
  The module's markup works under a host Content-Security-Policy that allows inline code by
  nonce only (`script-src 'self' 'nonce-…'`, see core's `guides/content-security-policy.md`):

    * every inline `<script>` or `<style>` in `lib/` carries the host's nonce, read through
      `PhoenixKitWebAnalytics.Web.CSP.nonce/1,2` (feature-detected: core releases before the
      nonce support have no `PhoenixKitWeb.CSP`). Today that is one tag, `<.beacon />`;
    * no inline event handler (`onclick="…"`) and no `javascript:` URL, in `lib/` or in the
      module's JS: no nonce can be put on an attribute. Use a hook or a delegated listener in
      `priv/static/assets/phoenix_kit_web_analytics.js`, or a `phx-` binding;
    * the module's JS creates no `<style>` or `<script>` element.

  Modelled on core's `test/phoenix_kit_web/csp_inline_tags_test.exs`.
  """
  use ExUnit.Case, async: true

  @bundle "priv/static/assets/phoenix_kit_web_analytics.js"
  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  # Files that handle `<script>` / `<style>` as text, not as markup they render. None today.
  @tags_as_data []

  @tag_opening ~r/<(script|style)\b[^>]*>/s

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces around `=` for the
  # events a browser knows (a bare `on\w+ =` would also match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  # `online={@online}` is an attribute of this module's own components (`top_row`, the page
  # header: visitors online now), not an event handler.
  @handler Regex.compile!(
             "\\son(?!line=)[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]"
           )
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          path not in @tags_as_data,
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          not (opening =~ "CSP.nonce(" or opening =~ "CSP.attr("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without the host's nonce:\n" <> Enum.join(offenders, "\n")
  end

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a hook or a delegated listener " <>
             "in #{@bundle}, or a `phx-` binding):\n" <> Enum.join(offenders, "\n")
  end

  test "the module's JS builds no markup with an inline handler and no <style> or <script>" do
    offenders =
      for {line, number} <- @bundle |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not (line =~ ~r{^\s*(//|\*)}),
          line =~ ~r/\son[a-z]+=\\?["']/ or line =~ ~r/createElement\(["'](?:style|script)["']\)/ or
            line =~ ~r/["'`]<(?:style|script)\b/,
          do: "#{@bundle}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  test "the scans see what they are for" do
    assert ~s|<input oninput="this.nextElementSibling.value = this.value" />| =~ @handler
    assert ~s|<button onclick={go()}>| =~ @handler
    assert ~s|<a href="javascript:void(0)">| =~ @js_url
    refute ~s|<button phx-click="go" data-analytics="signup">| =~ @handler
    refute ~s|<.top_row online={@online} />| =~ @handler
    assert ~s|<body onload="go()">| =~ @handler
    assert Regex.match?(@tag_opening, "<style>\n.a{}")
  end

  test "the beacon is the one inline tag, and it takes the nonce" do
    openings =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {opening, _number} <- tag_openings(path),
          do: {path, opening}

    assert [{"lib/phoenix_kit_web_analytics/web/beacon.ex", opening}] = openings
    assert opening =~ "nonce={CSP.nonce(:script, @nonce)}"
  end

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  # Lines of the file with `@moduledoc`/`@doc` heredocs and HEEx comments blanked: a tag there
  # is an example, not markup.
  defp code_lines(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
