defmodule PhoenixKit.Modules.Publishing.Web.Editor.TranslationTest do
  @moduledoc """
  Unit coverage for the editor's AI-translation source-language resolution.

  Regression guard: the translation **source** is always the primary language
  (the canonical content), never the language the editor happens to be viewing.
  A non-primary page with an empty buffer must NOT report the source as blank
  when the primary language has content.
  """
  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Web.Editor.Translation
  alias PhoenixKit.Settings

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

    {:ok, group} = Groups.add_group("Tr #{System.unique_integer([:positive])}", mode: "slug")
    {:ok, post} = Posts.create_post(group["slug"], %{title: "Hello World", slug: "hello-world"})

    {:ok, _} =
      Publishing.update_post(
        group["slug"],
        post,
        %{"title" => "Hello World", "content" => "# Hello World\n\nThe body."},
        %{}
      )

    %{post: post}
  end

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  describe "source_content_blank?/1" do
    test "reads the primary language as source on a non-primary page", %{post: post} do
      # Viewing the (empty) ru language. The source is en-US, which has content,
      # so this must NOT report the source as blank — otherwise the editor warns
      # "source is empty" and the user thinks the translation will be empty.
      s = socket(%{post: post, current_language: "ru", current_version: nil, content: ""})

      refute Translation.source_content_blank?(s)
    end

    test "uses the live buffer when viewing the primary language", %{post: post} do
      # On the primary language an empty buffer genuinely means an empty source.
      s = socket(%{post: post, current_language: "en-US", current_version: nil, content: ""})

      assert Translation.source_content_blank?(s)
    end
  end
end
