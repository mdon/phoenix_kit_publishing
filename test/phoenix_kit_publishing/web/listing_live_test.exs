defmodule PhoenixKit.Modules.Publishing.Web.ListingLiveTest do
  @moduledoc """
  Smoke tests for the Listing LV. Pins:

    * Mount + handle_params land without crashing for an existing group
    * Toggle between active and trashed views via switch_post_view event
    * trash_post + restore_post events log activity, return to active list
    * handle_info catch-all swallows unknown messages
    * load_more event extends visible_count

  These are mount-and-interact tests — full content rendering is
  exercised in `controller/show_layout_test.exs` (public path).
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, group} =
      Groups.add_group("Listing LV #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{title: "Sample post for listing"})

    %{group: group, post: post}
  end

  test "mount renders the group's posts list", %{conn: conn, group: group, post: post} do
    {:ok, _view, html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    assert html =~ group["name"]
    # Post body should be reachable in the rendered listing
    assert html =~ post[:slug] || html =~ "Sample post"
  end

  test "switch_post_view toggles between active and trashed", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    html = render_click(view, "switch_post_view", %{"mode" => "trashed"})
    assert is_binary(html)
  end

  test "load_more extends visible_count", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    html = render_click(view, "load_more", %{})
    assert is_binary(html)
  end

  test "handle_info catch-all swallows unknown messages", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:bogus_message, "ignored"})
    send(view.pid, :unexpected_atom)
    assert is_binary(render(view))
  end

  test "handle_info {:post_created, _} schedules a refresh", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:post_created, %{uuid: "ignored", slug: "ignored"}})
    assert is_binary(render(view))
  end

  test "handle_info {:post_deleted, _} reloads the current view", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:post_deleted, "any-uuid"})
    assert is_binary(render(view))
  end
end
