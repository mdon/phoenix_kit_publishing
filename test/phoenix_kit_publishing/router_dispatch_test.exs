defmodule PhoenixKitPublishing.RouterDispatchTest do
  @moduledoc """
  Unit + integration tests for the publishing router-dispatch strategy.

  Pure-function tests (`internal_prefix/0`, `restore_path/2` no-ops, the
  Plug interface) run without the database. The `maybe_rewrite/1` cases
  that exercise known-group lookup require the test DB and are tagged
  `:integration` — DataCase auto-excludes them when no DB is available.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitPublishing.RouterDispatch

  describe "internal_prefix/0" do
    test "returns the documented constant string" do
      # Pinned because the Plug.Conn rewrite, the AGENTS.md docs, and the
      # core macro's scope path all hardcode this value. Any change has to
      # land in all three places at once.
      assert RouterDispatch.internal_prefix() == "__phoenix_kit_publishing_dispatch"
    end
  end

  describe "Plug interface" do
    test "init/1 returns its argument unchanged" do
      assert RouterDispatch.init(:restore_path) == :restore_path
      assert RouterDispatch.init(:anything_else) == :anything_else
      assert RouterDispatch.init([]) == []
    end

    test "call/2 with :restore_path delegates to restore_path/2" do
      conn = %Plug.Conn{request_path: "/x", path_info: ["x"], private: %{}}
      assert RouterDispatch.call(conn, :restore_path) == conn
    end

    test "call/2 with any other opt is a no-op pass-through" do
      conn = %Plug.Conn{request_path: "/y", path_info: ["y"], private: %{}}
      assert RouterDispatch.call(conn, :unknown_opt) == conn
      assert RouterDispatch.call(conn, []) == conn
    end
  end

  describe "restore_path/2 (without rewrite marker)" do
    test "passes the conn through unchanged when the rewrite flag is absent" do
      conn = %Plug.Conn{
        request_path: "/some/path",
        path_info: ["some", "path"],
        private: %{}
      }

      assert RouterDispatch.restore_path(conn, []) == conn
    end

    test "passes the conn through unchanged when the rewrite flag is false" do
      conn = %Plug.Conn{
        request_path: "/some/path",
        path_info: ["some", "path"],
        private: %{phoenix_kit_publishing_internal: false}
      }

      assert RouterDispatch.restore_path(conn, []) == conn
    end
  end

  describe "restore_path/2 (with rewrite marker)" do
    test "restores request_path + path_info from the stashed originals" do
      conn = %Plug.Conn{
        request_path: "/__phoenix_kit_publishing_dispatch/en/blog/hello",
        path_info: ["__phoenix_kit_publishing_dispatch", "en", "blog", "hello"],
        private: %{
          phoenix_kit_publishing_internal: true,
          phoenix_kit_publishing_original_path: "/en/blog/hello",
          phoenix_kit_publishing_original_path_info: ["en", "blog", "hello"]
        }
      }

      restored = RouterDispatch.restore_path(conn, [])

      assert restored.request_path == "/en/blog/hello"
      assert restored.path_info == ["en", "blog", "hello"]
      # private is preserved (the marker stays — downstream code may rely on it)
      assert restored.private[:phoenix_kit_publishing_internal] == true
    end

    test "leaves request_path/path_info as-is if originals weren't stashed" do
      # Defensive — should never happen in practice (rewrite always stashes),
      # but a misuse shouldn't crash.
      conn = %Plug.Conn{
        request_path: "/x",
        path_info: ["x"],
        private: %{phoenix_kit_publishing_internal: true}
      }

      assert RouterDispatch.restore_path(conn, []).request_path == "/x"
    end
  end

  describe "maybe_rewrite/1 (no DB)" do
    test "passes through an empty path_info" do
      conn = %Plug.Conn{path_info: [], request_path: "/", private: %{}}
      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end

    test "passes through when no segment matches a group (DB unavailable)" do
      # `known_group?` rescues DB errors and returns false, so even without a
      # DB we should fall through cleanly rather than 500-ing.
      conn = %Plug.Conn{
        path_info: ["definitely-not-a-group", "anything"],
        request_path: "/definitely-not-a-group/anything",
        private: %{}
      }

      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end
  end
end

defmodule PhoenixKitPublishing.RouterDispatchIntegrationTest do
  @moduledoc """
  Integration tests for `RouterDispatch.maybe_rewrite/1` — exercise the
  DB-backed `known_group?/1` path against real publishing groups.
  """
  use PhoenixKitPublishing.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKitPublishing.RouterDispatch

  defp unique_name, do: "Dispatch Test #{System.unique_integer([:positive])}"

  describe "maybe_rewrite/1 — known group at path_info[0] (non-localized)" do
    test "rewrites the conn with the internal prefix" do
      {:ok, group} = Groups.add_group(unique_name())
      slug = group["slug"]

      conn = %Plug.Conn{
        path_info: [slug, "some-post"],
        request_path: "/" <> slug <> "/some-post",
        private: %{}
      }

      assert {:rewrite, rewritten} = RouterDispatch.maybe_rewrite(conn)
      assert rewritten.path_info == ["__phoenix_kit_publishing_dispatch", slug, "some-post"]

      assert rewritten.request_path ==
               "/__phoenix_kit_publishing_dispatch/" <> slug <> "/some-post"
    end

    test "stashes original request_path + path_info in conn.private for restore_path" do
      {:ok, group} = Groups.add_group(unique_name())
      slug = group["slug"]

      conn = %Plug.Conn{
        path_info: [slug, "post"],
        request_path: "/" <> slug <> "/post",
        private: %{}
      }

      assert {:rewrite, rewritten} = RouterDispatch.maybe_rewrite(conn)
      assert rewritten.private[:phoenix_kit_publishing_internal] == true
      assert rewritten.private[:phoenix_kit_publishing_original_path] == "/" <> slug <> "/post"
      assert rewritten.private[:phoenix_kit_publishing_original_path_info] == [slug, "post"]
    end

    test "restore_path/2 round-trips the rewrite cleanly" do
      {:ok, group} = Groups.add_group(unique_name())
      slug = group["slug"]
      original_request_path = "/" <> slug <> "/post"
      original_path_info = [slug, "post"]

      conn = %Plug.Conn{
        path_info: original_path_info,
        request_path: original_request_path,
        private: %{}
      }

      {:rewrite, rewritten} = RouterDispatch.maybe_rewrite(conn)
      restored = RouterDispatch.restore_path(rewritten, [])

      assert restored.path_info == original_path_info
      assert restored.request_path == original_request_path
    end
  end

  describe "maybe_rewrite/1 — known group at path_info[1] (localized form)" do
    test "rewrites when the second segment matches a group, even if the first doesn't" do
      {:ok, group} = Groups.add_group(unique_name())
      slug = group["slug"]

      conn = %Plug.Conn{
        path_info: ["en", slug, "post-slug"],
        request_path: "/en/" <> slug <> "/post-slug",
        private: %{}
      }

      assert {:rewrite, rewritten} = RouterDispatch.maybe_rewrite(conn)
      assert rewritten.path_info == ["__phoenix_kit_publishing_dispatch", "en", slug, "post-slug"]
    end

    test "checks path_info[1] only after path_info[0] doesn't match (branch sequencing)" do
      # Pin the cond ordering — guards against a future refactor that flips
      # the checks and makes a host route shaped `/group-name/<literal>` get
      # treated as `language=group-name, group=<literal>` instead of
      # `group=group-name, path=[<literal>]`.
      {:ok, real_group} = Groups.add_group(unique_name())
      refute_group_named("not-a-group")

      conn = %Plug.Conn{
        path_info: ["not-a-group", real_group["slug"], "post"],
        request_path: "/not-a-group/" <> real_group["slug"] <> "/post",
        private: %{}
      }

      # path_info[0]="not-a-group" must fail known_group?/1 first, then
      # path_info[1]=real slug succeeds and triggers rewrite.
      assert {:rewrite, _rewritten} = RouterDispatch.maybe_rewrite(conn)
    end
  end

  describe "maybe_rewrite/1 — neither segment is a known group" do
    test "passes through unchanged so host routes get a fair shot" do
      # The bug this whole change exists to fix: `/fr/services/view/foo` —
      # neither `fr` nor `services` is a publishing group, so we MUST pass
      # through and let the host's `/:locale/services/view/:slug` route win.
      conn = %Plug.Conn{
        path_info: ["fr", "services", "view", "foo"],
        request_path: "/fr/services/view/foo",
        private: %{}
      }

      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end

    test "passes through a single-segment path that isn't a group" do
      conn = %Plug.Conn{
        path_info: ["about"],
        request_path: "/about",
        private: %{}
      }

      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end
  end

  describe "maybe_rewrite/1 — bug-replication assertion" do
    test "the canonical collision URL passes through when no group is named 'services'" do
      # Pinning test for the headline bug. If this passes but a regression
      # makes path_info[0]='fr' or path_info[1]='services' resolve to a
      # group lookup that returns true, this fails.
      refute_group_named("services")
      refute_group_named("fr")

      conn = %Plug.Conn{
        path_info: ["fr", "services", "view", "nos-services"],
        request_path: "/fr/services/view/nos-services",
        private: %{}
      }

      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end
  end

  defp refute_group_named(slug) do
    case Groups.get_group(slug) do
      {:ok, _} -> flunk("Test fixture leak: a group named #{inspect(slug)} exists in the test DB")
      _ -> :ok
    end
  end
end
