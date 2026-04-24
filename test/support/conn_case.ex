defmodule PhoenixKitPublishing.ConnCase do
  @moduledoc """
  Test case for controller integration tests that drive
  `Web.Controller.show/2` through a real Plug pipeline.

  Wires up `PhoenixKitPublishing.Test.Endpoint`, imports `Phoenix.ConnTest`,
  and sets up an Ecto SQL sandbox connection. Tagged `:integration` so
  it's excluded automatically when the test DB is unavailable.

  ## Example

      defmodule PhoenixKit.Modules.Publishing.Web.Controller.ShowTest do
        use PhoenixKitPublishing.ConnCase

        test "renders layout with scope", %{conn: conn} do
          with_scope(%{user: %{id: 1, roles: ["admin"]}})
          conn = get(conn, "/blog")
          assert html_response(conn, 200) =~ "..."
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitPublishing.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import PhoenixKitPublishing.ConnCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn ->
      Process.delete(:test_phoenix_kit_current_scope)
      Sandbox.stop_owner(pid)
    end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Sets the test scope that `PhoenixKitPublishing.Test.Router`'s
  `:assign_test_scope` plug will forward onto `conn.assigns`. Mirrors
  what parent apps do via `fetch_phoenix_kit_current_scope`.
  """
  def with_scope(scope) do
    Process.put(:test_phoenix_kit_current_scope, scope)
    :ok
  end
end
