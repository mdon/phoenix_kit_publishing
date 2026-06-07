defmodule PhoenixKitPublishing.TranslationManagerBulkTest do
  @moduledoc """
  Unit coverage for the programmatic bulk-translation entry point
  `TranslationManager.translate_post_to_all_languages/3`. We test the
  publishing-specific param assembly (`build_bulk_translation_params/2`) rather
  than the enqueue itself — the actual per-language fan-out lives in core's
  `Translations.enqueue_all_missing/2`, which core tests cover.

  Passing `:source_language` + `:target_languages` keeps these pure (no DB /
  Languages-config dependency): the default-resolution branch that reads
  `LanguageHelpers` only fires when those opts are omitted. An explicit
  `:resource_scope` likewise skips the active-version lookup (which rescues to
  `nil` without a DB connection).
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.TranslationManager

  @post "019cce93-0000-7000-8000-000000000000"
  @base_opts [endpoint_uuid: "ep-uuid", prompt_uuid: "pr-uuid", source_language: "en"]

  describe "build_bulk_translation_params/2" do
    test "assembles core generic-pipeline params from explicit opts" do
      {base, targets} =
        TranslationManager.build_bulk_translation_params(
          @post,
          @base_opts ++ [target_languages: ["es", "fr"], resource_scope: "1"]
        )

      assert base == %{
               resource_type: "publishing_post",
               resource_uuid: @post,
               endpoint_uuid: "ep-uuid",
               prompt_uuid: "pr-uuid",
               source_lang: "en",
               resource_scope: "1"
             }

      assert targets == ["es", "fr"]
    end

    test "includes actor_uuid only when a user_uuid is given" do
      opts = @base_opts ++ [target_languages: ["es"]]

      {without, _} = TranslationManager.build_bulk_translation_params(@post, opts)
      refute Map.has_key?(without, :actor_uuid)

      {with_actor, _} =
        TranslationManager.build_bulk_translation_params(@post, [{:user_uuid, "user-1"} | opts])

      assert with_actor.actor_uuid == "user-1"
    end
  end
end
