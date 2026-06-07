defmodule PhoenixKitPublishing.AITranslatable do
  @moduledoc """
  `PhoenixKit.Modules.AI.Translatable` adapter for publishing posts — the
  per-module hook into core's generic AI-translation pipeline
  (`PhoenixKit.Modules.AI.{Translations,TranslateWorker}`).

  Replaces the bespoke `Workers.TranslatePostWorker`, which translated every
  language **sequentially in a single Oban job**. `Translations.enqueue_all_missing/2`
  dispatches **one job per target language**, so they run in parallel (bounded
  by the Oban queue) — wall-clock drops from the sum of all languages to ~the
  slowest single one.

  ## Resource identity

  `resource_type` is `"publishing_post"`; `resource_uuid` is the post's uuid
  (core validates it as a real UUID). Translations target the post's **active
  version** — the version the editor normally works on.

  ## Fields

  `source_fields/2` returns `%{"Title", "Content"}` read in the source
  language — capitalized to match the `{{Title}}`/`{{Content}}` placeholders in
  the publishing translation prompt (core's variable substitution is
  case-sensitive). `put_translation/4` creates the target-language content row (via
  `add_language_to_post` when absent) and writes the translated title/content,
  **generating the per-language `url_slug` locally** from the translated title
  via `SlugHelpers.slugify/1`. That honors the configured slug style and avoids
  trusting an AI-returned slug (which a reasoning model can mangle).

  ## Concurrency

  Each target language is a distinct `phoenix_kit_publishing_contents` row
  (unique on `version_uuid + language`), so concurrent per-language jobs never
  touch the same row — no merge/lock dance is needed (unlike JSONB-on-one-row
  consumers).

  ## Events

  `pubsub_topics/1` returns the post's translations topic, so core's
  `{:ai_translation, …}` lifecycle events reach the editor LiveView (already
  subscribed to that topic). Per-language content creation also emits
  publishing's own `:translation_created` via `add_language_to_post`.
  """

  @behaviour PhoenixKit.Modules.AI.Translatable

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.SlugHelpers
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @resource_type "publishing_post"

  defstruct [:post_uuid, :group_slug, :post_slug, :version]

  @type t :: %__MODULE__{
          post_uuid: String.t(),
          group_slug: String.t(),
          post_slug: String.t() | nil,
          version: pos_integer() | nil
        }

  @impl true
  def fetch(@resource_type, post_uuid) when is_binary(post_uuid) do
    case Publishing.read_post_by_uuid(post_uuid, LanguageHelpers.get_primary_language()) do
      {:ok, post} ->
        # Pin the version we resolved here and thread it through both the read
        # (source_fields) and the write (ensure_language_row), so a published
        # post with a newer draft can't read one version and write another.
        {:ok,
         %__MODULE__{
           post_uuid: post_uuid,
           group_slug: post.group,
           post_slug: post.slug,
           version: Map.get(post, :version)
         }}

      _ ->
        {:error, :resource_not_found}
    end
  end

  def fetch(other, _uuid), do: {:error, {:unknown_resource_type, other}}

  @impl true
  def source_fields(%__MODULE__{} = resource, source_lang) do
    case Publishing.read_post_by_uuid(resource.post_uuid, source_lang, resource.version) do
      {:ok, post} ->
        # Keys are capitalized ("Title"/"Content") to match the placeholders in
        # the publishing translation prompt ({{Title}}/{{Content}}). Core's
        # prompt-variable substitution is case-SENSITIVE
        # (PhoenixKitAI.Prompt.get_variable_value), and the same field keys
        # drive response parsing (markers are upcased either way), so the casing
        # must line up with the prompt or {{Title}}/{{Content}} render literally
        # and the model hallucinates instead of translating.
        %{}
        |> put_nonempty("Title", extract_title(post))
        |> put_nonempty("Content", post.content || "")

      _ ->
        %{}
    end
  end

  @impl true
  def put_translation(%__MODULE__{} = resource, target_lang, fields, opts) do
    scope = build_scope(Keyword.get(opts, :actor_uuid))

    with {:ok, post} <- ensure_language_row(resource, target_lang) do
      Publishing.update_post(
        resource.group_slug,
        post,
        build_params(fields, resource, target_lang),
        %{scope: scope}
      )
    end
  end

  @impl true
  def pubsub_topics(%__MODULE__{} = resource) do
    [PublishingPubSub.post_translations_topic(resource.group_slug, resource.post_uuid)]
  end

  @doc "The resource_type string this adapter serves."
  @spec resource_type() :: String.t()
  def resource_type, do: @resource_type

  # Returns the post struct for `target_lang`, adding the language row first
  # when it doesn't exist yet (mirrors the legacy worker's create/update split).
  defp ensure_language_row(resource, target_lang) do
    case Publishing.read_post_by_uuid(resource.post_uuid, target_lang, resource.version) do
      {:ok, post} ->
        if post.language == target_lang and not Map.get(post, :is_new_translation, false) do
          {:ok, post}
        else
          Publishing.add_language_to_post(
            resource.group_slug,
            resource.post_uuid,
            target_lang,
            resource.version
          )
        end

      _ ->
        Publishing.add_language_to_post(
          resource.group_slug,
          resource.post_uuid,
          target_lang,
          resource.version
        )
    end
  end

  defp build_params(fields, resource, target_lang) do
    # `fields` comes back from core's parser keyed by the SAME names
    # source_fields/2 emitted ("Title"/"Content"); the DB params are the
    # lowercase content-schema fields.
    title = Map.get(fields, "Title")

    %{}
    |> maybe_put("title", title)
    |> maybe_put("content", Map.get(fields, "Content"))
    |> maybe_put_slug(title, resource, target_lang)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Per-language url_slug generated locally from the translated title (honors
  # the configured slug style; never trusts an AI-returned slug). Only set when
  # the slug is free in this group+language — otherwise omit it so the content
  # row falls back to the post's (unique) default slug. Read-time collision
  # resolution remains the backstop for the rare concurrent race.
  defp maybe_put_slug(map, title, resource, target_lang) when is_binary(title) and title != "" do
    with slug when slug != "" <- SlugHelpers.slugify(title),
         {:ok, _} <-
           SlugHelpers.validate_url_slug(
             resource.group_slug,
             slug,
             target_lang,
             resource.post_slug
           ) do
      Map.put(map, "url_slug", slug)
    else
      _ -> map
    end
  end

  defp maybe_put_slug(map, _title, _resource, _target_lang), do: map

  # Title is the first `# heading` in the body, else the stored metadata title.
  defp extract_title(post) do
    content = post.content || ""

    case Regex.run(~r/^#\s+(.+)$/m, content) do
      [_, title] -> String.trim(title)
      nil -> Map.get(post.metadata, :title, Constants.default_title())
    end
  end

  defp put_nonempty(map, key, value) when is_binary(value) do
    if String.trim(value) == "", do: map, else: Map.put(map, key, value)
  end

  defp put_nonempty(map, _key, _value), do: map

  defp build_scope(nil), do: nil

  defp build_scope(user_uuid) do
    case Auth.get_user(user_uuid) do
      nil -> nil
      user -> Scope.for_user(user)
    end
  end
end
