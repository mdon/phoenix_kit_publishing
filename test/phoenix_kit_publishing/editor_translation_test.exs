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

  describe "source_blank_state/1" do
    # {title_blank?, content_blank?} drives the precise translation-modal warning.

    test "reports both blank on an empty primary buffer with no title", %{post: post} do
      s =
        socket(%{
          post: post,
          current_language: "en-US",
          current_version: nil,
          content: "",
          form: %{"title" => ""}
        })

      assert Translation.source_blank_state(s) == {true, true}
    end

    test "title-only: a typed title with empty content is not 'both blank'", %{post: post} do
      # The case the user flagged: only a title is filled. The title still
      # translates, so the warning must say "only the title" — not "empty".
      s =
        socket(%{
          post: post,
          current_language: "en-US",
          current_version: nil,
          content: "",
          form: %{"title" => "My Title"}
        })

      assert Translation.source_blank_state(s) == {false, true}
    end

    test "content-only: body text with no title/heading reports title blank", %{post: post} do
      s =
        socket(%{
          post: post,
          current_language: "en-US",
          current_version: nil,
          content: "Just some body text, no heading.",
          form: %{"title" => ""}
        })

      assert Translation.source_blank_state(s) == {true, false}
    end

    test "a `# heading` counts as a title even with a blank title field", %{post: post} do
      s =
        socket(%{
          post: post,
          current_language: "en-US",
          current_version: nil,
          content: "# Real Heading\n\nBody.",
          form: %{"title" => ""}
        })

      assert Translation.source_blank_state(s) == {false, false}
    end

    test "the default \"Untitled\" title does not count as a title", %{post: post} do
      s =
        socket(%{
          post: post,
          current_language: "en-US",
          current_version: nil,
          content: "",
          form: %{"title" => "Untitled"}
        })

      assert Translation.source_blank_state(s) == {true, true}
    end
  end

  describe "prompt/adapter variable contract" do
    test "shipped prompt placeholders exactly match the adapter's source_fields keys",
         %{post: post} do
      # The 2026-06-07 regression: source_fields/2 returned lowercase keys while
      # the prompt used {{Title}}/{{Content}}. Core's substitution is
      # case-sensitive, so the placeholders rendered literally and the model
      # hallucinated. Pin the invariant: every {{Placeholder}} in the shipped
      # prompt (minus the core-provided language slots) must be a key the
      # adapter actually binds — same string, same casing.
      {:ok, resource} = AITranslatable.fetch("publishing_post", post.uuid)

      bound_keys =
        resource
        |> AITranslatable.source_fields("en-US")
        |> Map.keys()
        |> MapSet.new()

      placeholders =
        ~r/\{\{(\w+)\}\}/
        |> Regex.scan(Translation.default_prompt_content())
        |> Enum.map(fn [_, name] -> name end)
        |> Enum.reject(&(&1 in ["SourceLanguage", "TargetLanguage"]))
        |> MapSet.new()

      assert placeholders == bound_keys,
             """
             Prompt placeholders and adapter source_fields keys have drifted.
             Prompt {{...}} (minus language slots): #{inspect(MapSet.to_list(placeholders))}
             source_fields/2 keys:                  #{inspect(MapSet.to_list(bound_keys))}
             They must match byte-for-byte (core substitution is case-sensitive).
             """
    end
  end
end
