defmodule PhoenixKitPublishing.RouterDispatch do
  @moduledoc """
  Routing strategy that lets publishing's catch-all coexist with host
  routes shaped `/:locale/something/...` declared after `phoenix_kit_routes()`.

  ## Why this exists

  Publishing's public URLs are dynamic — `/:language/:group/*path` where
  `:group` is any DB row. Phoenix.Router has no per-segment regex
  constraint, so the catch-all matches every two-or-more-segment URL.
  Phoenix matches in declaration order with no fall-through, which means
  any host route declared after `phoenix_kit_routes()` and shaped
  `/:locale/<literal>/...` is silently shadowed: publishing's controller
  matches first, doesn't find the group, returns 404.

  ## How this works

  Instead of registering the catch-all directly under `/`, publishing
  registers it under an internal prefix (`/__phoenix_kit_publishing_dispatch`).
  The host router's `call/2` is overridden (via Phoenix.Router's documented
  `defoverridable init: 1, call: 2`) to:

    1. Check if the request's first non-locale path segment is a known
       publishing group via `maybe_rewrite/1`.
    2. If yes — rewrite `conn.path_info` and `conn.request_path` to
       prepend the internal prefix; `super(conn, opts)` then matches the
       internal-prefix route and runs the full Phoenix pipeline normally.
    3. If no — pass through unchanged; Phoenix matches host routes.

  After the route matches, `restore_path/2` (a pipeline plug) un-mutates
  `request_path` and `path_info` so controllers reading `conn.request_path`
  for canonical URL generation see the URL the client sent, not the
  internal prefix.

  Phoenix's pipelines run via the internal-prefix scope's `pipe_through`,
  so `:browser` (sessions, CSRF, layout), `:phoenix_kit_*` (auth, locale),
  and any host-defined plugs are applied via the standard mechanism — no
  manual replication, no telemetry gap.

  ## Trade-offs

  * `mix phx.routes` shows the routes under the internal prefix. Devs
    debugging "where does `/blog/post` go?" need to know to look for
    `__phoenix_kit_publishing_dispatch`. Documented in core AGENTS.md.
  * Per-request cost: one DB lookup on each request. ETS/`:persistent_term`
    caching is a future optimization (the DB read is small + indexed).
  """

  alias PhoenixKit.Modules.Publishing.Groups

  @internal_prefix "__phoenix_kit_publishing_dispatch"
  @localized_segment "localized"
  @root_segment "root"

  @doc "Internal prefix segment used in path rewriting."
  @spec internal_prefix() :: String.t()
  def internal_prefix, do: @internal_prefix

  @doc """
  Discriminator segment for URLs that have a leading locale (i.e. the
  group slug is at `path_info[1]`). Phoenix routes inside this sub-scope
  bind `:language` + `:group` per publishing's localized form.
  """
  @spec localized_segment() :: String.t()
  def localized_segment, do: @localized_segment

  @doc """
  Discriminator segment for URLs that have NO leading locale (i.e. the
  group slug is at `path_info[0]`). Phoenix routes inside this sub-scope
  bind `:group` only per publishing's non-localized form.
  """
  @spec root_segment() :: String.t()
  def root_segment, do: @root_segment

  @doc """
  Decide whether `conn` is bound for publishing.

  Returns `{:rewrite, conn}` with `conn.path_info` and `conn.request_path`
  prepended with the internal prefix + a discriminator segment that
  picks publishing's localized vs non-localized route shape:

    * If `path_info[1]` is a known group → rewrite under
      `__phoenix_kit_publishing_dispatch/localized/...` so Phoenix matches
      `/:language/:group(/*path)` (the URL has a leading locale).
    * Else if `path_info[0]` is a known group → rewrite under
      `__phoenix_kit_publishing_dispatch/root/...` so Phoenix matches
      `/:group(/*path)` (no leading locale).

  Returns `:pass` if neither resolves to a known group. The dual
  discriminator is load-bearing — without it, both `/:language/:group`
  and `/:group/*path` would match a 2-segment internal path, and
  Phoenix's first-match-wins picks the localized form even when the
  URL had no locale prefix. That sends the request to the controller
  with `language=<group-slug>, group=<post-slug>` and the lookup fails.

  The DB lookup is small and indexed; a future optimization would
  cache the slug set in `:persistent_term`.
  """
  @spec maybe_rewrite(Plug.Conn.t()) :: {:rewrite, Plug.Conn.t()} | :pass
  def maybe_rewrite(%Plug.Conn{path_info: path_info} = conn) do
    cond do
      candidate_at(path_info, 1) |> known_group?() ->
        {:rewrite, rewrite(conn, @localized_segment)}

      candidate_at(path_info, 0) |> known_group?() ->
        {:rewrite, rewrite(conn, @root_segment)}

      true ->
        :pass
    end
  end

  @doc """
  Pipeline plug — restores `conn.request_path` and `conn.path_info` to
  the un-rewritten form once Phoenix has extracted route bindings into
  `conn.params`.

  Without this, controllers that compute canonical URLs from
  `conn.request_path` (publishing's `default_language_no_prefix` redirect
  is one) include the internal prefix in their `Location` header,
  causing a redirect loop on the next request.
  """
  @spec restore_path(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def restore_path(%Plug.Conn{private: %{phoenix_kit_publishing_internal: true}} = conn, _opts) do
    %{
      conn
      | request_path: conn.private[:phoenix_kit_publishing_original_path] || conn.request_path,
        path_info: conn.private[:phoenix_kit_publishing_original_path_info] || conn.path_info
    }
  end

  def restore_path(conn, _opts), do: conn

  # Plug interface so the module can be `plug ...`-ed from a pipeline.
  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, :restore_path), do: restore_path(conn, [])
  def call(conn, _opts), do: conn

  @spec candidate_at([String.t()], non_neg_integer()) :: String.t() | nil
  defp candidate_at(path_info, idx) when is_list(path_info) do
    case Enum.at(path_info, idx) do
      seg when is_binary(seg) -> seg
      _ -> nil
    end
  end

  @spec known_group?(String.t() | nil) :: boolean()
  defp known_group?(nil), do: false

  defp known_group?(slug) when is_binary(slug) do
    case Groups.get_group(slug) do
      {:ok, _group} -> true
      _ -> false
    end
  rescue
    # DB unavailable, table missing during install, etc. — better to
    # pass through so host routes still work than to crash the request.
    _ -> false
  catch
    # Sandbox shutdown mid-test fires an :exit signal that `rescue` doesn't
    # catch. The dispatch override runs on every request, including during
    # tests that share the sandbox; matches the canonical `enabled?/0`
    # pattern (see phoenix_kit_hello_world commit c1c2674).
    :exit, _reason -> false
  end

  @spec rewrite(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp rewrite(
         %Plug.Conn{path_info: path_info, request_path: request_path} = conn,
         discriminator
       ) do
    %{
      conn
      | path_info: [@internal_prefix, discriminator | path_info],
        request_path: "/" <> @internal_prefix <> "/" <> discriminator <> request_path,
        private:
          conn.private
          |> Map.put(:phoenix_kit_publishing_internal, true)
          |> Map.put(:phoenix_kit_publishing_original_path, request_path)
          |> Map.put(:phoenix_kit_publishing_original_path_info, path_info)
    }
  end
end
