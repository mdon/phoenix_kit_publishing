defmodule PhoenixKit.Integration.Publishing.DBStorageUrlSlugLookupTest do
  @moduledoc """
  Integration tests for the URL-slug lookup queries in `DBStorage`:

    * `find_by_url_slug/3` (custom slug → post slug fallback)
    * `find_by_previous_url_slug/3` (JSONB previous-slug match for 301 redirects)

  The original failure mode that motivated this file: posts that
  accumulated many versions sharing identical content fields crashed
  `repo().one()` with `Ecto.MultipleResultsError`. The test corpus
  before this file only ever exercised single-version posts, so the
  multi-version data shape was a fixture-coverage gap.

  Async: false because the `content_language` setting is a shared
  ETS-cached singleton, mirroring `stale_fixer_test.exs`.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name, do: "url-lookup-group-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English (United States)",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          },
          %{
            "code" => "de-DE",
            "name" => "German (Germany)",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 1
          }
        ]
      })

    {:ok, _} = Settings.update_setting("content_language", "en-US")
    :ok
  end

  # ============================================================================
  # find_by_url_slug — happy path + edge cases
  # ============================================================================

  describe "find_by_url_slug/3" do
    test "finds a published single-version post by its custom URL slug" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Custom Slug Post", slug: "custom-slug-post"})

      [version] = DBStorage.list_versions(post.uuid)
      [content] = DBStorage.list_contents(version.uuid)
      {:ok, _} = DBStorage.update_content(content, %{url_slug: "shiny-public-slug"})

      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      found = DBStorage.find_by_url_slug(group["slug"], "en-US", "shiny-public-slug")
      assert found != nil
      assert found.url_slug == "shiny-public-slug"
      assert found.version.post.slug == "custom-slug-post"
    end

    test "falls back to post-slug match when content's url_slug is empty" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Slug Fallback", slug: "slug-fallback"})

      [version] = DBStorage.list_versions(post.uuid)
      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      # No url_slug on the content row — lookup should resolve via the post slug.
      found = DBStorage.find_by_url_slug(group["slug"], "en-US", "slug-fallback")
      assert found != nil
      assert found.version.post.slug == "slug-fallback"
    end

    test "trashed posts do not resolve" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Will Be Trashed", slug: "will-be-trashed"})

      [version] = DBStorage.list_versions(post.uuid)
      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      {:ok, _} = Posts.trash_post(group["slug"], post.uuid)

      assert DBStorage.find_by_url_slug(group["slug"], "en-US", "will-be-trashed") == nil
    end

    test "returns nil for a different language than what's stored" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "English Only", slug: "english-only"})

      [version] = DBStorage.list_versions(post.uuid)
      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      # No de-DE content row — should NOT find anything.
      assert DBStorage.find_by_url_slug(group["slug"], "de-DE", "english-only") == nil
    end

    test "returns nil for a different group than what's stored" do
      {:ok, group_a} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, group_b} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group_a["slug"], %{title: "Group A Post", slug: "group-a-post"})

      [version] = DBStorage.list_versions(post.uuid)
      :ok = Versions.publish_version(group_a["slug"], post.uuid, version.version_number)

      assert DBStorage.find_by_url_slug(group_b["slug"], "en-US", "group-a-post") == nil
    end

    test "returns nil when nothing matches the slug at all" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      assert DBStorage.find_by_url_slug(group["slug"], "en-US", "never-existed") == nil
    end
  end

  # ============================================================================
  # Multi-version regression — the bug that motivated this file
  # ============================================================================

  describe "find_by_url_slug/3 — multi-version regression" do
    test "post with 14 versions sharing an empty url_slug resolves to a single row" do
      # This is the data shape that crashed Hello! in production. Fourteen
      # consecutive version rows, all with `language = en-US` and `url_slug = ""`.
      # Pre-fix the join returned 14 hits → `repo().one()` → MultipleResultsError.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Hello Multi", slug: "hello-multi"})

      # Create 13 more versions on top of the auto-generated v1.
      for n <- 2..14 do
        {:ok, version} =
          DBStorage.create_version(%{
            post_uuid: post.uuid,
            version_number: n,
            status: "draft"
          })

        {:ok, _} =
          DBStorage.create_content(%{
            version_uuid: version.uuid,
            language: "en-US",
            title: "Hello Multi v#{n}",
            content: "v#{n} body",
            status: "draft",
            url_slug: ""
          })
      end

      # Publish the latest version so the lookup has a clear target.
      :ok = Versions.publish_version(group["slug"], post.uuid, 14)

      # Pre-fix this raised `Ecto.MultipleResultsError`.
      found = DBStorage.find_by_url_slug(group["slug"], "en-US", "hello-multi")

      assert found != nil
      assert found.version.post.slug == "hello-multi"
      # Resolution must pick the ACTIVE version, not any of the 13 drafts.
      assert found.version.version_number == 14
    end

    test "post with many versions, only one of which has the queried custom url_slug" do
      # Active version's content has the queried slug; drafts share a stale one.
      # Pre-fix: if drafts ever shared the same slug, multiple hits crashed
      # repo().one(). The active-version scope makes that deterministic.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Slug Drift", slug: "slug-drift"})

      [v1] = DBStorage.list_versions(post.uuid)
      [v1_content] = DBStorage.list_contents(v1.uuid)
      {:ok, _} = DBStorage.update_content(v1_content, %{url_slug: "stale-slug"})

      # Three more draft versions with the same stale slug
      for n <- 2..4 do
        {:ok, version} =
          DBStorage.create_version(%{post_uuid: post.uuid, version_number: n, status: "draft"})

        {:ok, _} =
          DBStorage.create_content(%{
            version_uuid: version.uuid,
            language: "en-US",
            title: "Slug Drift v#{n}",
            content: "v#{n}",
            status: "draft",
            url_slug: "stale-slug"
          })
      end

      # Active version has a different (current) slug
      {:ok, v5} =
        DBStorage.create_version(%{post_uuid: post.uuid, version_number: 5, status: "draft"})

      {:ok, _} =
        DBStorage.create_content(%{
          version_uuid: v5.uuid,
          language: "en-US",
          title: "Slug Drift v5",
          content: "v5",
          status: "draft",
          url_slug: "current-slug"
        })

      :ok = Versions.publish_version(group["slug"], post.uuid, 5)

      # Querying the current slug returns the active version's content.
      current = DBStorage.find_by_url_slug(group["slug"], "en-US", "current-slug")
      assert current != nil
      assert current.url_slug == "current-slug"
      assert current.version.version_number == 5

      # Querying the stale slug returns nil — only the active version is reachable.
      assert DBStorage.find_by_url_slug(group["slug"], "en-US", "stale-slug") == nil
    end

    test "unpublished post with many versions resolves to its latest draft" do
      # The stale-language self-healing path exercises drafts. Posts whose
      # `active_version_uuid` is nil must still be findable so that the
      # repair flow can normalize their content. The query picks the LATEST
      # version when no active one exists.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Draft Multi", slug: "draft-multi"})

      [v1] = DBStorage.list_versions(post.uuid)
      [v1_content] = DBStorage.list_contents(v1.uuid)
      {:ok, _} = DBStorage.update_content(v1_content, %{url_slug: ""})

      for n <- 2..5 do
        {:ok, version} =
          DBStorage.create_version(%{post_uuid: post.uuid, version_number: n, status: "draft"})

        {:ok, _} =
          DBStorage.create_content(%{
            version_uuid: version.uuid,
            language: "en-US",
            title: "Draft Multi v#{n}",
            content: "v#{n}",
            status: "draft",
            url_slug: ""
          })
      end

      # Never published — active_version_uuid stays nil.
      found = DBStorage.find_by_url_slug(group["slug"], "en-US", "draft-multi")
      assert found != nil
      # Resolution must pick the LATEST draft.
      assert found.version.version_number == 5
    end
  end

  # ============================================================================
  # find_by_previous_url_slug — 301 redirect support
  # ============================================================================

  describe "find_by_previous_url_slug/3" do
    test "finds a post by a slug previously assigned to its content" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Renamed Post", slug: "renamed-post"})

      [version] = DBStorage.list_versions(post.uuid)
      [content] = DBStorage.list_contents(version.uuid)

      # Simulate a content row that used to live at "old-slug" before being renamed.
      {:ok, _} =
        DBStorage.update_content(content, %{
          url_slug: "new-slug",
          data: %{"previous_url_slugs" => ["old-slug"]}
        })

      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      found = DBStorage.find_by_previous_url_slug(group["slug"], "en-US", "old-slug")
      assert found != nil
      assert found.url_slug == "new-slug"
      assert found.version.post.slug == "renamed-post"
    end

    test "returns nil when no content's previous_url_slugs match" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      assert DBStorage.find_by_previous_url_slug(group["slug"], "en-US", "never") == nil
    end

    test "returns nil for trashed posts even if previous_url_slugs matches" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Trashed Renamed", slug: "trashed-renamed"})

      [version] = DBStorage.list_versions(post.uuid)
      [content] = DBStorage.list_contents(version.uuid)

      {:ok, _} =
        DBStorage.update_content(content, %{
          data: %{"previous_url_slugs" => ["was-here"]}
        })

      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)
      {:ok, _} = Posts.trash_post(group["slug"], post.uuid)

      assert DBStorage.find_by_previous_url_slug(group["slug"], "en-US", "was-here") == nil
    end

    test "returns nil for a different language than the row that holds the previous slug" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Lang Scoped", slug: "lang-scoped"})

      [version] = DBStorage.list_versions(post.uuid)
      [content] = DBStorage.list_contents(version.uuid)

      {:ok, _} =
        DBStorage.update_content(content, %{
          data: %{"previous_url_slugs" => ["english-only-old"]}
        })

      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      # The previous-slug entry only exists on the en-US row.
      assert DBStorage.find_by_previous_url_slug(group["slug"], "de-DE", "english-only-old") == nil
    end

    test "post with many versions sharing a previous slug resolves to a single row" do
      # Same regression class as `find_by_url_slug`: previously the join
      # spanned every version, so a post with several historical versions
      # carrying `previous_url_slugs: ["old-slug"]` in their JSONB would
      # crash `repo().one()`.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Prev Slug Multi", slug: "prev-slug-multi"})

      [v1] = DBStorage.list_versions(post.uuid)
      [v1_content] = DBStorage.list_contents(v1.uuid)

      {:ok, _} =
        DBStorage.update_content(v1_content, %{
          data: %{"previous_url_slugs" => ["old-prev"]}
        })

      for n <- 2..5 do
        {:ok, version} =
          DBStorage.create_version(%{post_uuid: post.uuid, version_number: n, status: "draft"})

        {:ok, _} =
          DBStorage.create_content(%{
            version_uuid: version.uuid,
            language: "en-US",
            title: "Prev Multi v#{n}",
            content: "v#{n}",
            status: "draft",
            data: %{"previous_url_slugs" => ["old-prev"]}
          })
      end

      :ok = Versions.publish_version(group["slug"], post.uuid, 5)

      found = DBStorage.find_by_previous_url_slug(group["slug"], "en-US", "old-prev")
      assert found != nil
      assert found.version.version_number == 5
    end
  end

  # ============================================================================
  # find_by_url_slug — round-trip via `Posts.find_by_url_slug`
  # ============================================================================

  describe "Posts.find_by_url_slug/3 — controller-facing wrapper" do
    test "wraps DBStorage hit in {:ok, post_map}" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Wrapped", slug: "wrapped"})

      [version] = DBStorage.list_versions(post.uuid)
      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      assert {:ok, post_map} = Posts.find_by_url_slug(group["slug"], "en-US", "wrapped")
      assert post_map.slug == "wrapped"
      assert post_map.language == "en-US"
    end

    test "wraps DBStorage miss in {:error, :not_found}" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      assert {:error, :not_found} =
               Posts.find_by_url_slug(group["slug"], "en-US", "definitely-not-here")
    end

    test "controller-facing wrapper survives the 14-version regression case end-to-end" do
      # Mirror the regression test above but at the `Posts.find_by_url_slug`
      # level — proves the wrapper, not just `DBStorage`, doesn't blow up.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Wrapper Multi", slug: "wrapper-multi"})

      for n <- 2..14 do
        {:ok, version} =
          DBStorage.create_version(%{post_uuid: post.uuid, version_number: n, status: "draft"})

        {:ok, _} =
          DBStorage.create_content(%{
            version_uuid: version.uuid,
            language: "en-US",
            title: "Wrapper Multi v#{n}",
            content: "v#{n}",
            status: "draft",
            url_slug: ""
          })
      end

      :ok = Versions.publish_version(group["slug"], post.uuid, 14)

      assert {:ok, post_map} = Posts.find_by_url_slug(group["slug"], "en-US", "wrapper-multi")
      assert post_map.slug == "wrapper-multi"
    end
  end
end
