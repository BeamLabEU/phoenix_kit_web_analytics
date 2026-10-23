defmodule PhoenixKitWebAnalytics.GettextTest do
  use ExUnit.Case, async: true

  @backend PhoenixKitWebAnalytics.Gettext

  test "every shipped language is a known locale" do
    for locale <- ~w(en et ru uk) do
      assert locale in Gettext.known_locales(@backend)
    end
  end

  test "Ukrainian has the three plural forms of its Plural-Forms header" do
    forms =
      Gettext.with_locale(@backend, "uk", fn ->
        for n <- [1, 2, 5, 11, 21, 22, 111] do
          {n, Gettext.ngettext(@backend, "%{count} day", "%{count} days", n)}
        end
      end)

    assert forms == [
             {1, "1 день"},
             {2, "2 дні"},
             {5, "5 днів"},
             {11, "11 днів"},
             {21, "21 день"},
             {22, "22 дні"},
             {111, "111 днів"}
           ]
  end
end
