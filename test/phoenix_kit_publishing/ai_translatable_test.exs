defmodule PhoenixKitPublishing.AITranslatableTest do
  @moduledoc """
  Unit coverage for the `PhoenixKit.Modules.AI.Translatable` adapter that wires
  publishing posts into core's generic AI-translation pipeline. Covers the four
  callbacks (fetch / source_fields / put_translation / pubsub_topics) and the
  local url_slug generation. The actual AI call + fan-out live in core.
  """
  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Settings
  alias PhoenixKitPublishing.AITranslatable

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          },
          %{
            "code" => "ru",
            "name" => "Russian",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 1
          }
        ]
      })

    {:ok, _} = Settings.update_setting("publishing_slug_style", "transliterate")

    {:ok, group} = Groups.add_group("AT #{System.unique_integer([:positive])}", mode: "slug")
    {:ok, post} = Posts.create_post(group["slug"], %{title: "Hello World", slug: "hello-world"})

    {:ok, _} =
      Publishing.update_post(
        group["slug"],
        post,
        %{"title" => "Hello World", "content" => "# Hello World\n\nThe body."},
        %{}
      )

    %{group_slug: group["slug"], post_uuid: post.uuid}
  end

  describe "fetch/2" do
    test "loads a publishing_post by uuid", ctx do
      %{group_slug: group_slug, post_uuid: post_uuid} = ctx

      assert {:ok,
              %AITranslatable{
                post_uuid: ^post_uuid,
                group_slug: ^group_slug,
                post_slug: "hello-world"
              }} = AITranslatable.fetch("publishing_post", post_uuid)
    end

    test "returns :resource_not_found for an unknown uuid" do
      assert {:error, :resource_not_found} =
               AITranslatable.fetch("publishing_post", Ecto.UUID.generate())
    end

    test "rejects an unknown resource_type" do
      assert {:error, {:unknown_resource_type, "widget"}} =
               AITranslatable.fetch("widget", Ecto.UUID.generate())
    end
  end

  describe "source_fields/2" do
    test "extracts title + content in the source language", %{post_uuid: post_uuid} do
      {:ok, resource} = AITranslatable.fetch("publishing_post", post_uuid)
      fields = AITranslatable.source_fields(resource, "en-US")

      # Capitalized keys to match the prompt's {{Title}}/{{Content}} placeholders.
      # Core's prompt substitution is case-sensitive, so the exact key casing is
      # load-bearing — lowercase keys leave the placeholders unrendered and the
      # model hallucinates. Pin the key set, not just the values.
      assert Enum.sort(Map.keys(fields)) == ["Content", "Title"]
      assert fields["Title"] == "Hello World"
      assert fields["Content"] =~ "The body."
    end
  end

  describe "put_translation/4" do
    test "creates the target-language row with a locally-generated slug", %{post_uuid: post_uuid} do
      {:ok, resource} = AITranslatable.fetch("publishing_post", post_uuid)

      assert {:ok, _} =
               AITranslatable.put_translation(
                 resource,
                 "ru",
                 %{"Title" => "Привет мир", "Content" => "# Привет мир\n\nтекст"},
                 []
               )

      {:ok, ru} = Publishing.read_post_by_uuid(post_uuid, "ru")
      # Slug is transliterated locally from the translated title, not taken from AI.
      assert ru.url_slug == "privet-mir"
    end

    test "omits the slug (falls back to the post slug) when it's taken by another post",
         %{group_slug: group_slug, post_uuid: post_uuid} do
      # Another post claims "privet-mir" for ru first.
      {:ok, other} = Posts.create_post(group_slug, %{title: "Other", slug: "other-post"})
      {:ok, other_res} = AITranslatable.fetch("publishing_post", other.uuid)

      {:ok, _} =
        AITranslatable.put_translation(
          other_res,
          "ru",
          %{"Title" => "Привет мир", "Content" => "x"},
          []
        )

      {:ok, other_ru} = Publishing.read_post_by_uuid(other.uuid, "ru")
      assert other_ru.url_slug == "privet-mir"

      # Our post's ru title also slugifies to "privet-mir" → conflict → omit the
      # custom slug, falling back to our post's (unique) default slug.
      {:ok, resource} = AITranslatable.fetch("publishing_post", post_uuid)

      {:ok, _} =
        AITranslatable.put_translation(
          resource,
          "ru",
          %{"Title" => "Привет мир", "Content" => "y"},
          []
        )

      {:ok, ru} = Publishing.read_post_by_uuid(post_uuid, "ru")
      assert ru.url_slug == "hello-world"
    end
  end

  describe "pubsub_topics/1" do
    test "returns the post translations topic the editor subscribes to", ctx do
      %{group_slug: group_slug, post_uuid: post_uuid} = ctx
      {:ok, resource} = AITranslatable.fetch("publishing_post", post_uuid)

      assert AITranslatable.pubsub_topics(resource) ==
               [PublishingPubSub.post_translations_topic(group_slug, post_uuid)]
    end
  end
end
