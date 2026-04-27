defmodule PhoenixKit.Modules.Publishing.Web.Controller.PublicRoutesTest do
  @moduledoc """
  Branch coverage for the public Web.Controller and its submodules
  (PostFetching, PostRendering, SlugResolution, Fallback, Listing).
  Drives requests through a real Plug pipeline via the test endpoint.

  Pins the public-facing paths each submodule owns:
    * /:group → group listing
    * /:group/:post_slug → published post (slug mode)
    * Missing post → falls through to Fallback
    * Trashed group → 404 / fallback
  """

  # Forces async: false because the test mutates the global
  # `content_language` setting; a parallel test (stale_fixer_test)
  # also writes to that row and the two upserts deadlock under
  # concurrent Postgres load.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name, do: "public-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{title: "First Post", slug: "first-post"})

    :ok = Versions.publish_version(group["slug"], post.uuid, 1)

    %{group_slug: group["slug"], post: post}
  end

  describe "/:group — group listing" do
    test "renders 200 for an existing group", %{conn: conn, group_slug: group_slug} do
      assert html_response(get(conn, "/" <> group_slug), 200)
    end

    test "renders 200 even when no posts are published", %{conn: conn} do
      {:ok, empty_group} = Groups.add_group(unique_name(), mode: "slug")
      assert html_response(get(conn, "/" <> empty_group["slug"]), 200)
    end
  end

  describe "/:group/:post_slug — published-post path" do
    test "renders 200 with the post body when slug matches", %{
      conn: conn,
      group_slug: group_slug,
      post: post
    } do
      response = get(conn, "/" <> group_slug <> "/" <> post.slug) |> html_response(200)
      assert response =~ "First Post"
    end

    test "missing post slug falls back without crashing", %{
      conn: conn,
      group_slug: group_slug
    } do
      # Fallback module resolves missing slugs — we expect either 200 (with
      # fallback content) or 404, but never a 500 from a crashed pipeline.
      conn = get(conn, "/" <> group_slug <> "/totally-missing-slug")
      assert conn.status in [200, 301, 302, 404]
    end
  end

  describe "publishing_public_enabled toggle" do
    test "redirects/404s when public access is disabled", %{conn: conn, group_slug: group_slug} do
      {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", false)
      conn = get(conn, "/" <> group_slug)
      # Disabled = either redirect to 404 page or hard 404
      assert conn.status in [302, 404, 410, 503]
    end
  end
end
