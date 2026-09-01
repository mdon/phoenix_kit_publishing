defmodule PhoenixKit.Modules.Publishing.DBStorage.MapperTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.DBStorage.Mapper
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion

  # ============================================================================
  # Test Data Builders
  # ============================================================================

  defp build_group(attrs \\ %{}) do
    %PublishingGroup{
      uuid: UUIDv7.generate(),
      name: "Blog",
      slug: "blog",
      mode: "slug",
      position: 0,
      data: %{}
    }
    |> Map.merge(attrs)
  end

  defp build_post(group, attrs \\ %{}) do
    %PublishingPost{
      uuid: UUIDv7.generate(),
      group_uuid: group.uuid,
      group: group,
      slug: "hello-world",
      active_version_uuid: nil,
      mode: "slug",
      post_date: nil,
      post_time: nil
    }
    |> Map.merge(attrs)
  end

  defp build_version(post, attrs \\ %{}) do
    %PublishingVersion{
      uuid: UUIDv7.generate(),
      post_uuid: post.uuid,
      version_number: 1,
      status: "published",
      published_at: ~U[2025-06-15 14:30:00Z],
      data: %{},
      inserted_at: ~U[2025-06-15 14:30:00Z]
    }
    |> Map.merge(attrs)
  end

  defp build_content(version, attrs \\ %{}) do
    %PublishingContent{
      uuid: UUIDv7.generate(),
      version_uuid: version.uuid,
      language: "en",
      title: "Hello World",
      content: "# Hello World\n\nThis is the content.",
      status: "published",
      url_slug: nil,
      data: %{}
    }
    |> Map.merge(attrs)
  end

  # ============================================================================
  # to_post_map/5
  # ============================================================================

  describe "to_post_map/5" do
    test "converts DB records to post map format" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version)

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.uuid == post.uuid
      assert result.group == "blog"
      assert result.slug == "hello-world"
      assert result.mode == :slug
      assert result.language == "en"
      assert result.version == 1
      assert result.content == content.content
    end

    test "builds available_languages from all contents" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      en_content = build_content(version, %{language: "en", status: "published"})
      es_content = build_content(version, %{language: "es", status: "draft"})

      result =
        Mapper.to_post_map(post, version, en_content, [en_content, es_content], [version])

      assert result.available_languages == ["en", "es"]
      # Status is version-level — all languages share the version's derived status
      assert result.language_statuses == %{"en" => "published", "es" => "published"}
    end

    test "builds version_statuses from all versions" do
      group = build_group()
      post = build_post(group)
      v1 = build_version(post, %{version_number: 1, status: "archived"})
      v2 = build_version(post, %{version_number: 2, status: "published"})
      content = build_content(v2)

      result = Mapper.to_post_map(post, v2, content, [content], [v1, v2])

      assert result.available_versions == [1, 2]
      assert result.version_statuses == %{1 => "archived", 2 => "published"}
    end

    test "includes date/time for timestamp-mode post" do
      group = build_group()

      post =
        build_post(group, %{
          mode: "timestamp",
          post_date: ~D[2025-06-15],
          post_time: ~T[14:30:00]
        })

      version = build_version(post)
      content = build_content(version)

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.mode == :timestamp
      assert result.date == ~D[2025-06-15]
      assert result.time == ~T[14:30:00]
    end

    test "url_slug falls back to post slug when nil" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version, %{url_slug: nil})

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.url_slug == "hello-world"
    end

    test "url_slug uses content url_slug when set" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version, %{url_slug: "custom-url"})

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.url_slug == "custom-url"
    end

    test "metadata includes expected fields" do
      group = build_group()
      post = build_post(group)

      version =
        build_version(post, %{
          data: %{
            "description" => "A test post",
            "featured_image_uuid" => "img-123"
          }
        })

      content =
        build_content(version, %{
          data: %{
            "previous_url_slugs" => ["old-url"]
          }
        })

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.metadata.title == "Hello World"
      assert result.metadata.description == "A test post"
      assert result.metadata.status == "published"
      assert result.metadata.slug == "hello-world"
      assert result.metadata.version == 1
      assert result.metadata.featured_image_uuid == "img-123"
      assert result.metadata.previous_url_slugs == ["old-url"]
      assert result.metadata.published_at == "2025-06-15T14:30:00Z"
      # Defaults to false when version.data carries no "featured" key.
      assert result.metadata.featured == false
    end

    test "metadata surfaces the featured flag from version.data" do
      group = build_group()
      post = build_post(group)
      version = build_version(post, %{data: %{"featured" => true}})
      content = build_content(version)

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.metadata.featured == true
    end

    test "builds language_slugs map" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      en = build_content(version, %{language: "en", url_slug: "hello"})
      es = build_content(version, %{language: "es", url_slug: "hola"})

      result = Mapper.to_post_map(post, version, en, [en, es], [version])

      assert result.language_slugs == %{"en" => "hello", "es" => "hola"}
    end

    test "builds version_dates from all versions" do
      group = build_group()
      post = build_post(group)
      v1 = build_version(post, %{version_number: 1, inserted_at: ~U[2025-06-10 10:00:00Z]})
      v2 = build_version(post, %{version_number: 2, inserted_at: ~U[2025-06-15 14:30:00Z]})
      content = build_content(v2)

      result = Mapper.to_post_map(post, v2, content, [content], [v1, v2])

      assert result.version_dates == %{
               1 => "2025-06-10T10:00:00Z",
               2 => "2025-06-15T14:30:00Z"
             }
    end

    test "builds language_previous_slugs from all contents" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      en =
        build_content(version, %{
          language: "en",
          data: %{"previous_url_slugs" => ["old-hello"]}
        })

      es = build_content(version, %{language: "es", data: %{}})

      result = Mapper.to_post_map(post, version, en, [en, es], [version])

      assert result.language_previous_slugs["en"] == ["old-hello"]
      assert result.language_previous_slugs["es"] == []
    end

    test "merges published_language_statuses via opts" do
      group = build_group()
      post = build_post(group)
      # Use a draft version so derive_status returns "draft"
      version = build_version(post, %{status: "draft"})
      en = build_content(version, %{language: "en"})
      es = build_content(version, %{language: "es"})

      result =
        Mapper.to_post_map(post, version, en, [en, es], [version],
          published_language_statuses: %{"en" => "published"}
        )

      # The merge overrides en's "draft" with "published" from the older published version
      assert result.language_statuses["en"] == "published"
      # es stays at the version's derived status ("draft")
      assert result.language_statuses["es"] == "draft"
    end

    test "group slug is nil when group is not preloaded" do
      group = build_group()

      post =
        build_post(group, %{
          group: %Ecto.Association.NotLoaded{
            __field__: :group,
            __cardinality__: :one,
            __owner__: PublishingPost
          }
        })

      version = build_version(post)
      content = build_content(version)

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.group == nil
    end

    test "url_slug falls back to post slug when empty string" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version, %{url_slug: ""})

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.url_slug == "hello-world"
    end
  end

  # ============================================================================
  # to_listing_map/4
  # ============================================================================

  describe "to_listing_map/4" do
    test "converts post to listing format" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version)

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.uuid == post.uuid
      assert result.group == "blog"
      assert result.slug == "hello-world"
      assert result.mode == :slug
    end

    test "uses site default language content for listing" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      en = build_content(version, %{language: "en", title: "English Title"})
      es = build_content(version, %{language: "es", title: "Titulo"})

      result = Mapper.to_listing_map(post, version, [en, es], [version])

      assert result.metadata.title == "English Title"
      assert result.language == "en"
    end

    test "extracts excerpt from content" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      content =
        build_content(version, %{
          content: "First paragraph here.\n\n## Section\n\nMore content."
        })

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.content == "First paragraph here."
    end

    # The regression that mattered: the editor's excerpt field writes to
    # version.data, the card read only content.data — the one excerpt
    # anything actually wrote was read by nothing.
    test "a version-level excerpt reaches the card" do
      group = build_group()
      post = build_post(group)
      version = build_version(post, %{data: %{"excerpt" => "The version's excerpt"}})
      content = build_content(version, %{content: "First paragraph."})

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.content == "The version's excerpt"
    end

    test "a content-level excerpt outranks the version's" do
      group = build_group()
      post = build_post(group)
      version = build_version(post, %{data: %{"excerpt" => "Version default"}})

      content =
        build_content(version, %{
          content: "First paragraph.",
          data: %{"excerpt" => "This language's own excerpt"}
        })

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.content == "This language's own excerpt"
    end

    # The article that found this opened with a splat-viewer <div> followed
    # by an italic caption — the listing card showed 300 chars of escaped
    # tag soup; the first fix then showed the caption. The preview is the
    # post's opening PROSE.
    test "a leading raw-HTML block and its caption are not the first paragraph" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      content =
        build_content(version, %{
          content:
            ~s(<div id="d1" data-splat-viewer data-src="/scans/x.sog">\n) <>
              ~s(<div data-splat-status>Loading…</div>\n</div>\n\n) <>
              "*A caption under the embed.*\n\nProse begins here."
        })

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.content == "Prose begins here."
    end

    test "inline markdown is stripped from the card preview" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      content =
        build_content(version, %{
          content:
            "The technique is called **3D Gaussian Splatting** — see " <>
              "[the paper](https://example.org) and `this code`."
        })

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.content ==
               "The technique is called 3D Gaussian Splatting — see the paper and this code."
    end

    test "truncation backs up to a whole word and says so" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      words = String.duplicate("indivisible ", 40) <> "final"
      content = build_content(version, %{content: words})

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert String.ends_with?(result.content, "indivisible…")
      refute result.content =~ ~r/indivisib…/
      assert String.length(result.content) <= 301
    end

    test "uses custom excerpt from data when available" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      content =
        build_content(version, %{
          content: "Full content here",
          data: %{"excerpt" => "Custom excerpt text"}
        })

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.content == "Custom excerpt text"
    end

    test "handles nil content gracefully" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      result = Mapper.to_listing_map(post, version, [], [version])

      assert result.metadata.title == nil
      assert result.content == nil
    end

    test "listing metadata carries allow_version_access (public version dropdown)" do
      group = build_group()
      post = build_post(group)

      # Regression: the cached listing map dropped this field, so the public
      # version dropdown only appeared on a cache miss. It must mirror the full
      # post map and reflect the version's setting.
      on_version = build_version(post, %{data: %{"allow_version_access" => true}})
      off_version = build_version(post, %{data: %{}})

      on_result =
        Mapper.to_listing_map(post, on_version, [build_content(on_version)], [on_version])

      off_result =
        Mapper.to_listing_map(post, off_version, [build_content(off_version)], [off_version])

      assert on_result.metadata.allow_version_access == true
      assert off_result.metadata.allow_version_access == false
    end

    test "listing metadata carries the featured flag (drives the hero band / pinning)" do
      group = build_group()
      post = build_post(group)

      # The public listing partitions on metadata.featured, and the listing map
      # is what the ListingCache stores — so the flag must ride into it here.
      featured_version = build_version(post, %{data: %{"featured" => true}})
      plain_version = build_version(post, %{data: %{}})

      featured_result =
        Mapper.to_listing_map(post, featured_version, [build_content(featured_version)], [
          featured_version
        ])

      plain_result =
        Mapper.to_listing_map(post, plain_version, [build_content(plain_version)], [plain_version])

      assert featured_result.metadata.featured == true
      assert plain_result.metadata.featured == false
    end

    test "falls back to first content when site default language not found" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      es = build_content(version, %{language: "es", title: "Titulo Espanol"})

      result = Mapper.to_listing_map(post, version, [es], [version])

      assert result.metadata.title == "Titulo Espanol"
    end

    test "uses description as excerpt fallback when no custom excerpt" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      content =
        build_content(version, %{
          content: "Full content here",
          data: %{"description" => "A meta description"}
        })

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.content == "A meta description"
    end

    test "builds language_titles and language_excerpts" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      en =
        build_content(version, %{
          language: "en",
          title: "Hello",
          data: %{"excerpt" => "EN excerpt"}
        })

      es =
        build_content(version, %{
          language: "es",
          title: "Hola",
          data: %{"excerpt" => "ES excerpt"}
        })

      result = Mapper.to_listing_map(post, version, [en, es], [version])

      assert result.language_titles == %{"en" => "Hello", "es" => "Hola"}
      assert result.language_excerpts == %{"en" => "EN excerpt", "es" => "ES excerpt"}
    end

    test "builds version_dates from all versions" do
      group = build_group()
      post = build_post(group)
      v1 = build_version(post, %{version_number: 1, inserted_at: ~U[2025-06-10 10:00:00Z]})
      v2 = build_version(post, %{version_number: 2, inserted_at: ~U[2025-06-15 14:30:00Z]})
      content = build_content(v2)

      result = Mapper.to_listing_map(post, v2, [content], [v1, v2])

      assert result.version_dates == %{
               1 => "2025-06-10T10:00:00Z",
               2 => "2025-06-15T14:30:00Z"
             }
    end

    test "url_slug falls back to post slug when content url_slug is nil" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version, %{url_slug: nil})

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.url_slug == "hello-world"
    end

    test "merges published_language_statuses via opts" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      en = build_content(version, %{language: "en", status: "draft"})

      result =
        Mapper.to_listing_map(post, version, [en], [version],
          published_language_statuses: %{"en" => "published"}
        )

      assert result.language_statuses["en"] == "published"
    end

    test "version defaults to 1 when version is nil" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version)

      result = Mapper.to_listing_map(post, nil, [content], [version])

      assert result.version == 1
    end

    test "builds available_versions and version_statuses" do
      group = build_group()
      post = build_post(group)
      v1 = build_version(post, %{version_number: 1, status: "archived"})
      v2 = build_version(post, %{version_number: 2, status: "published"})
      content = build_content(v2)

      result = Mapper.to_listing_map(post, v2, [content], [v1, v2])

      assert result.available_versions == [1, 2]
      assert result.version_statuses == %{1 => "archived", 2 => "published"}
    end

    test "extracts first non-heading paragraph when no excerpt or description" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      content =
        build_content(version, %{
          content: "## Heading\n\nActual paragraph here.\n\nMore content.",
          data: %{}
        })

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.content == "Actual paragraph here."
    end
  end
end
