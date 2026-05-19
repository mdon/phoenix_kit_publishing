defmodule PhoenixKit.Modules.Publishing.LanguageHelpersTest do
  use PhoenixKitPublishing.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-GB",
            "name" => "English (United Kingdom)",
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

    {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", false)
    :ok
  end

  describe "url_language_code/1" do
    test "shortens full locale codes to their base code for public URLs" do
      assert LanguageHelpers.url_language_code("en-GB") == "en"
      assert LanguageHelpers.url_language_code("de-DE") == "de"
      assert LanguageHelpers.url_language_code("pt-BR") == "pt"
    end

    test "keeps base language codes unchanged" do
      assert LanguageHelpers.url_language_code("en") == "en"
      assert LanguageHelpers.url_language_code("de") == "de"
    end

    test "allows nil for optional URL language inputs" do
      assert LanguageHelpers.url_language_code(nil) == nil
    end
  end

  describe "get_primary_language_base/0" do
    test "returns an unqualified base language code" do
      result = LanguageHelpers.get_primary_language_base()

      assert is_binary(result)
      refute String.contains?(result, "-")
    end
  end

  describe "enabled_language_codes/0" do
    test "drops bare base codes when a dialect of the same base is enabled" do
      {:ok, _} =
        Settings.update_json_setting("languages_config", %{
          "languages" => [
            %{
              "code" => "en",
              "name" => "English",
              "is_default" => false,
              "is_enabled" => true,
              "position" => 0
            },
            %{
              "code" => "en-US",
              "name" => "English (United States)",
              "is_default" => true,
              "is_enabled" => true,
              "position" => 1
            },
            %{
              "code" => "en-GB",
              "name" => "English (United Kingdom)",
              "is_default" => false,
              "is_enabled" => true,
              "position" => 2
            },
            %{
              "code" => "de-DE",
              "name" => "German (Germany)",
              "is_default" => false,
              "is_enabled" => true,
              "position" => 3
            }
          ]
        })

      assert LanguageHelpers.enabled_language_codes() == ["en-US", "en-GB", "de-DE"]
    end
  end

  describe "default_language_no_prefix?/0" do
    test "defaults to false" do
      refute LanguageHelpers.default_language_no_prefix?()
    end

    test "reads the stored setting" do
      {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", true)
      assert LanguageHelpers.default_language_no_prefix?()
    end
  end

  describe "use_language_prefix?/1" do
    test "keeps prefix for the default language when the setting is off" do
      assert LanguageHelpers.use_language_prefix?("en")
    end

    test "omits prefix for the default language when the setting is on" do
      {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", true)
      refute LanguageHelpers.use_language_prefix?("en")
    end

    test "keeps prefix for non-default languages when the setting is on" do
      {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", true)
      assert LanguageHelpers.use_language_prefix?("de")
    end
  end

  describe "language_enabled?/2" do
    test "returns true for an enabled language code" do
      assert LanguageHelpers.language_enabled?("en-GB", ["en-GB", "de-DE"])
    end

    test "returns false for a code not in the enabled list" do
      refute LanguageHelpers.language_enabled?("fr-FR", ["en-GB", "de-DE"])
    end

    test "matches base codes against enabled dialect codes" do
      assert LanguageHelpers.language_enabled?("en", ["en-GB", "de-DE"])
    end

    test "matches dialect codes against enabled base codes" do
      assert LanguageHelpers.language_enabled?("en-GB", ["en", "de"])
    end
  end

  describe "get_display_code/2" do
    test "returns base code when only one dialect is enabled for that base" do
      assert LanguageHelpers.get_display_code("en-GB", ["en-GB", "de-DE"]) == "en"
    end

    test "returns full dialect code when multiple dialects of the same base are enabled" do
      assert LanguageHelpers.get_display_code("en-GB", ["en-GB", "en-US", "de-DE"]) == "en-GB"
    end
  end

  describe "order_languages_for_display/3" do
    test "default language sorts to the front" do
      result =
        LanguageHelpers.order_languages_for_display(
          ["de-DE", "en-GB"],
          ["en-GB", "de-DE"],
          "en-GB"
        )

      assert hd(result) == "en-GB"
    end

    test "preserves order for non-default languages" do
      result =
        LanguageHelpers.order_languages_for_display(
          ["de-DE", "fr-FR", "en-GB"],
          ["en-GB", "fr-FR", "de-DE"],
          "en-GB"
        )

      assert hd(result) == "en-GB"
      assert "fr-FR" in result
      assert "de-DE" in result
    end
  end

  describe "reserved_language_code?/1" do
    test "false for an unrelated code" do
      refute LanguageHelpers.reserved_language_code?("zz-ZZ")
    end
  end

  describe "normalize_enabled_language_codes/1" do
    test "removes a base code if its dialect is also enabled" do
      assert LanguageHelpers.normalize_enabled_language_codes(["en", "en-GB"]) == ["en-GB"]
    end

    test "keeps a base code if no matching dialect is enabled" do
      assert LanguageHelpers.normalize_enabled_language_codes(["en"]) == ["en"]
    end

    test "returns empty list for non-list input" do
      assert LanguageHelpers.normalize_enabled_language_codes(nil) == []
      assert LanguageHelpers.normalize_enabled_language_codes("not-a-list") == []
    end
  end

  describe "base_language_code?/1" do
    test "true for short codes (no dialect suffix)" do
      assert LanguageHelpers.base_language_code?("en")
    end

    test "false for dialect codes with hyphen" do
      refute LanguageHelpers.base_language_code?("en-GB")
    end

    test "false for non-binary input" do
      refute LanguageHelpers.base_language_code?(nil)
      refute LanguageHelpers.base_language_code?(123)
    end
  end

  describe "resolve_dialect_for_base/3" do
    # Pure function — does not depend on the setup-block fixtures.

    test "returns nil when no candidate's base matches" do
      assert LanguageHelpers.resolve_dialect_for_base("xx", ["en", "fr"]) == nil
      assert LanguageHelpers.resolve_dialect_for_base("xx", []) == nil
    end

    test "returns the single match (no tie-break needed)" do
      assert LanguageHelpers.resolve_dialect_for_base("en", ["en-US", "fr-FR"]) == "en-US"
    end

    test "returns first match in candidate order when multiple share the base" do
      assert LanguageHelpers.resolve_dialect_for_base("en", ["en-GB", "en-US"]) == "en-GB"
      assert LanguageHelpers.resolve_dialect_for_base("en", ["en-US", "en-GB"]) == "en-US"
    end

    test "`:prefer` wins tie-break when prefer is among the matches" do
      assert LanguageHelpers.resolve_dialect_for_base("en", ["en-GB", "en-US"], prefer: "en-US") ==
               "en-US"
    end

    test "`:prefer` is ignored when not in candidates" do
      # Falls back to first-match order
      assert LanguageHelpers.resolve_dialect_for_base("en", ["en-GB", "en-US"], prefer: "fr-FR") ==
               "en-GB"
    end

    test "`:prefer` is ignored when no candidate matches the base at all" do
      assert LanguageHelpers.resolve_dialect_for_base("xx", ["en-GB"], prefer: "en-GB") == nil
    end

    test "`:exclude` drops a single code before matching" do
      assert LanguageHelpers.resolve_dialect_for_base("en", ["en", "en-US"], exclude: "en") ==
               "en-US"
    end

    test "`:exclude` drops a list of codes" do
      assert LanguageHelpers.resolve_dialect_for_base("en", ["en", "en-GB", "en-US"],
               exclude: ["en", "en-GB"]
             ) == "en-US"
    end

    test "`:exclude` + `:prefer` — prefer wins iff still in matches after exclude" do
      # `:prefer` is excluded, so falls back to first remaining match
      assert LanguageHelpers.resolve_dialect_for_base("en", ["en", "en-US"],
               prefer: "en",
               exclude: "en"
             ) == "en-US"

      # `:prefer` is NOT excluded, still wins
      assert LanguageHelpers.resolve_dialect_for_base("en", ["en", "en-US", "en-GB"],
               prefer: "en-US",
               exclude: "en"
             ) == "en-US"
    end

    test "case-insensitive base matching" do
      # Base codes are normalized to lowercase before comparison; candidates
      # passing through `DialectMapper.extract_base` are already lowercase.
      assert LanguageHelpers.resolve_dialect_for_base("EN", ["en-US"]) == "en-US"
    end
  end
end
