defmodule PhoenixKit.Modules.Publishing.Web.Controller.OgRefineCrashTest do
  @moduledoc """
  PR #33: `maybe_refine_og_with_module/4` gained a `rescue` so a raising
  `phoenix_kit_og` plugin can't crash a public post-page render. Exercises the
  crash path end-to-end against the `PhoenixKitOG` test stub
  (`test/support/phoenix_kit_og_stub.ex`), whose `refine_og/4` always raises.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} =
      Groups.add_group("og-crash-#{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{
        title: "OG Crash Guard Post",
        slug: "og-crash-guard-post",
        content: "Body content."
      })

    :ok = Versions.publish_version(group["slug"], post.uuid, 1)

    %{group_slug: group["slug"]}
  end

  test "a raising phoenix_kit_og plugin doesn't crash the post page; OG falls back to the default",
       %{conn: conn, group_slug: group_slug} do
    html = get(conn, "/#{group_slug}/og-crash-guard-post") |> html_response(200)

    assert html =~ ~s(<meta property="og:title" content="OG Crash Guard Post">)
  end
end
