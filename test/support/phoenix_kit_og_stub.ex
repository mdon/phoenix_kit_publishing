defmodule PhoenixKitOG do
  @moduledoc """
  Test-only stand-in for the optional `phoenix_kit_og` plugin. Only compiled
  under `MIX_ENV=test` (see `elixirc_paths/1` in mix.exs) — the real plugin,
  when a host installs it, defines this same module name for
  `Web.Controller.maybe_refine_og_with_module/4` to dispatch to.

  `refine_og/4` raises only for a post titled "OG Crash Guard Post" so tests
  can prove the guarded seam (`Code.ensure_loaded?` + `function_exported?` +
  `rescue`) falls back to the unrefined OG map instead of crashing the public
  post-page render. It must NOT raise unconditionally: an always-raising
  clause gets inferred as returning `none()`, which makes the compiler flag
  `Web.Controller`'s `%{} = refined -> refined` / `_ -> og` handling of the
  call result as unreachable.
  """

  def refine_og(_og, _conn, %{metadata: %{title: "OG Crash Guard Post"}}, _language) do
    raise "boom: simulated phoenix_kit_og crash"
  end

  def refine_og(og, _conn, _post, _language), do: og
end
