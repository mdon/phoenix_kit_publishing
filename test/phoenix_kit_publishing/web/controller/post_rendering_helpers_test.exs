defmodule PhoenixKit.Modules.Publishing.Web.Controller.PostRenderingHelpersTest do
  @moduledoc """
  Direct unit tests for the pure helpers exported by `PostRendering`:
  `build_version_url/4`, `build_timestamp_url/4`, `render_post_content/1`.
  Functions that touch DB / Plug.Conn are exercised through
  `public_routes_test.exs`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.Controller.PostRendering

  describe "build_version_url/4" do
    test "appends `/v/<version>` to the post URL" do
      post = %{slug: "my-post", mode: :slug, metadata: %{published_at: nil}}
      url = PostRendering.build_version_url("blog", post, "en", 2)
      assert url =~ "/v/2"
    end
  end

  describe "render_post_content/1" do
    test "returns rendered HTML for a draft post (no cache)" do
      post = %{
        content: "# Hello\n\nBody text.",
        metadata: %{title: "Hello", status: "draft"},
        slug: "hello",
        mode: :slug,
        group: "blog"
      }

      html = PostRendering.render_post_content(post)
      assert is_binary(html)
      assert html =~ "Hello"
    end

    test "returns rendered HTML for a published post (cache key path)" do
      post = %{
        content: "## Section",
        metadata: %{title: "Pub", status: "published"},
        slug: "pub",
        uuid: "post-uuid-123",
        language: "en",
        mode: :slug,
        group: "blog"
      }

      html = PostRendering.render_post_content(post)
      assert is_binary(html)
    end

    test "handles empty content gracefully" do
      post = %{
        content: "",
        metadata: %{title: "", status: "draft"},
        slug: "x",
        mode: :slug,
        group: "blog"
      }

      assert "" = PostRendering.render_post_content(post)
    end
  end
end
