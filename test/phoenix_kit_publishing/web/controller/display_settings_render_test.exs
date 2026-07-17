defmodule PhoenixKit.Modules.Publishing.Web.Controller.DisplaySettingsRenderTest do
  @moduledoc """
  Pins every per-group display setting to its public-render effect: OFF (the
  default) leaves the page unchanged, ON renders the feature. Guards the
  settings surface end-to-end — group `data` JSONB → controller assigns →
  `Web.HTML` — so a broken assign chain can't ship while the unit tests on the
  accessors stay green.
  """

  # async: false — mutates the global publishing/language settings rows, same
  # deadlock risk public_routes_test.exs documents.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name, do: "display-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{
        title: "Display Post",
        slug: "display-post",
        content: "Hello world content for the display settings tests."
      })

    :ok = Versions.publish_version(group["slug"], post.uuid, 1)

    %{group_slug: group["slug"], post: post}
  end

  defp set!(slug, params) do
    {:ok, updated} = Groups.update_group(slug, params)
    updated
  end

  defp listing_html(conn, slug), do: get(conn, "/" <> slug) |> html_response(200)

  defp post_html(conn, slug, post_slug),
    do: get(conn, "/#{slug}/#{post_slug}") |> html_response(200)

  # ==========================================================================
  # Listing page
  # ==========================================================================

  describe "listing: show_post_count" do
    test "hidden by default, shown when enabled", %{conn: conn, group_slug: slug} do
      refute listing_html(conn, slug) =~ "1 post"

      set!(slug, %{"show_post_count" => "true"})
      assert listing_html(conn, slug) =~ "1 post"
    end
  end

  describe "listing: scroll_timeline_enabled" do
    test "off by default, config element with granularity + localized months when on", %{
      conn: conn,
      group_slug: slug
    } do
      refute listing_html(conn, slug) =~ "pk-timeline-config"

      set!(slug, %{
        "scroll_timeline_enabled" => "true",
        "scroll_timeline_granularity" => "month"
      })

      html = listing_html(conn, slug)
      assert html =~ "pk-timeline-config"
      assert html =~ ~s(data-granularity="month")
      # The rail's month labels ride the config element so they localize —
      # regression pin for the hardcoded-English MONTHS array.
      assert html =~ "data-months="
      assert html =~ "data-label="
    end
  end

  describe "listing: scrollbar_style" do
    test "native bar by default, styled when branded", %{conn: conn, group_slug: slug} do
      refute listing_html(conn, slug) =~ "::-webkit-scrollbar"

      set!(slug, %{"scrollbar_style" => "branded"})
      assert listing_html(conn, slug) =~ "::-webkit-scrollbar"
    end
  end

  describe "listing: show_breadcrumbs" do
    test "hidden by default, shown when enabled", %{conn: conn, group_slug: slug} do
      refute listing_html(conn, slug) =~ ~s(class="breadcrumbs)

      set!(slug, %{"show_breadcrumbs" => "true"})
      assert listing_html(conn, slug) =~ ~s(class="breadcrumbs)
    end
  end

  describe "listing: featured posts" do
    test "a featured post renders in the Featured band with a data-post-date", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      {:ok, _} = Posts.update_post(slug, post, %{"featured" => "true"}, %{})

      html = listing_html(conn, slug)
      assert html =~ "Featured"
      # The rail bins cards by data-post-date — featured cards must carry it
      # too, or a featured-only page never builds a timeline (regression pin).
      assert html =~ "data-post-date="
    end

    test "featured_enabled=false renders the post in the plain grid", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      {:ok, _} = Posts.update_post(slug, post, %{"featured" => "true"}, %{})
      set!(slug, %{"featured_enabled" => "false"})

      html = listing_html(conn, slug)
      refute html =~ "badge-primary badge-sm"
      assert html =~ "Display Post"
    end
  end

  describe "listing: listing_sort" do
    test "newest first by default, oldest first when configured", %{
      conn: conn,
      group_slug: slug
    } do
      {:ok, second} =
        Posts.create_post(slug, %{
          title: "Second Post",
          slug: "second-post",
          content: "Newer content."
        })

      :ok = Versions.publish_version(slug, second.uuid, 1)

      # Same-second publishes would tie the ISO-8601 sort keys — pin explicit
      # effective dates so the ordering assertion is deterministic.
      {:ok, _} =
        Posts.update_post(slug, second, %{"published_at" => "2031-06-01T00:00:00Z"}, %{})

      html = listing_html(conn, slug)
      {first_pos, _} = :binary.match(html, "Display Post")
      {second_pos, _} = :binary.match(html, "Second Post")
      assert second_pos < first_pos, "newest-first should render the newer post first"

      set!(slug, %{"listing_sort" => "oldest"})
      html = listing_html(conn, slug)
      {first_pos, _} = :binary.match(html, "Display Post")
      {second_pos, _} = :binary.match(html, "Second Post")
      assert first_pos < second_pos, "oldest-first should render the older post first"
    end
  end

  # ==========================================================================
  # Post page
  # ==========================================================================

  describe "post page: show_reading_time" do
    test "hidden by default, shown when enabled", %{conn: conn, group_slug: slug, post: post} do
      refute post_html(conn, slug, post.slug) =~ "min read"

      set!(slug, %{"show_reading_time" => "true"})
      assert post_html(conn, slug, post.slug) =~ "min read"
    end
  end

  describe "post page: post_width" do
    test "normal by default, narrow/wide map to their classes", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      assert post_html(conn, slug, post.slug) =~ "max-w-4xl"

      set!(slug, %{"post_width" => "narrow"})
      assert post_html(conn, slug, post.slug) =~ "max-w-2xl"

      set!(slug, %{"post_width" => "wide"})
      assert post_html(conn, slug, post.slug) =~ "max-w-6xl"
    end
  end

  describe "post page: post_date_position" do
    test "date renders by default and disappears when hidden", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      assert post_html(conn, slug, post.slug) =~ "<time"

      set!(slug, %{"post_date_position" => "hidden"})
      refute post_html(conn, slug, post.slug) =~ "<time"
    end
  end

  describe "post page: scroll_progress_enabled" do
    test "off by default, progress bar markup when on", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      refute post_html(conn, slug, post.slug) =~ "pk-reading-progress"

      set!(slug, %{"scroll_progress_enabled" => "true"})
      assert post_html(conn, slug, post.slug) =~ "pk-reading-progress"
    end
  end

  describe "post page: scroll_headings_enabled" do
    test "off by default, config element with localized label when on", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      refute post_html(conn, slug, post.slug) =~ "pk-headings-config"

      set!(slug, %{"scroll_headings_enabled" => "true"})
      html = post_html(conn, slug, post.slug)
      assert html =~ "pk-headings-config"
      assert html =~ "data-label="
    end
  end

  describe "post page: show_breadcrumbs" do
    test "hidden by default, shown when enabled", %{conn: conn, group_slug: slug, post: post} do
      refute post_html(conn, slug, post.slug) =~ ~s(class="breadcrumbs)

      set!(slug, %{"show_breadcrumbs" => "true"})
      assert post_html(conn, slug, post.slug) =~ ~s(class="breadcrumbs)
    end
  end

  # ==========================================================================
  # Translated group name — every public surface resolves through
  # translated_group_name/2 (listing h1/title/OG, post breadcrumb + back link)
  # ==========================================================================

  describe "translated group name reach" do
    test "listing h1 and og:title use the resolved name", %{conn: conn, group_slug: slug} do
      set!(slug, %{"name_i18n" => %{"en" => "Overridden Name"}})

      html = listing_html(conn, slug)
      assert html =~ "Overridden Name"
      assert html =~ ~s(property="og:title" content="Overridden Name")
    end

    test "post page breadcrumb and back link use the resolved name", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      set!(slug, %{"name_i18n" => %{"en" => "Overridden Name"}, "show_breadcrumbs" => "true"})

      html = post_html(conn, slug, post.slug)
      # Breadcrumb label + the "Back to <group>" footer.
      assert html =~ "Overridden Name"
      refute html =~ ~r/Back to [^<]*#{Regex.escape(slug)}/
    end
  end
end
