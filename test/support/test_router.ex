defmodule PhoenixKitPublishing.Test.Router do
  @moduledoc """
  Minimal router for controller integration tests.

  Routes match the public URL shapes Publishing's
  `Web.Controller.show/2` action handles — both the prefixed
  (`/:language/:group`) and prefixless (`/:group`) variants.

  Tests that need to simulate an authenticated parent-app pipeline set
  `Process.put(:test_phoenix_kit_current_scope, scope)` before issuing
  the request; the `:assign_test_scope` plug forwards it onto
  `conn.assigns[:phoenix_kit_current_scope]` — the same assign the
  real parent populates via `fetch_phoenix_kit_current_scope`.
  """

  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_flash)
    plug(:put_root_layout, {PhoenixKitPublishing.Test.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:assign_test_scope)
  end

  scope "/" do
    pipe_through(:browser)

    get("/:language/:group", PhoenixKit.Modules.Publishing.Web.Controller, :show)
    get("/:language/:group/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show)
    get("/:group", PhoenixKit.Modules.Publishing.Web.Controller, :show)
    get("/:group/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show)
  end

  # Pulls a test-configured scope out of the calling test process's
  # dictionary and mirrors the parent app's `fetch_phoenix_kit_current_scope`.
  defp assign_test_scope(conn, _opts) do
    case Process.get(:test_phoenix_kit_current_scope) do
      nil -> conn
      scope -> assign(conn, :phoenix_kit_current_scope, scope)
    end
  end
end
