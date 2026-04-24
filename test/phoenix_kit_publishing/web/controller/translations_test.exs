defmodule PhoenixKit.Modules.Publishing.Web.Controller.TranslationsTest do
  use PhoenixKitPublishing.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.Web.Controller.Translations
  alias PhoenixKit.Settings

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
            "code" => "en-GB",
            "name" => "English (United Kingdom)",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 1
          },
          %{
            "code" => "de-DE",
            "name" => "German (Germany)",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 2
          }
        ]
      })

    :ok
  end

  describe "build_listing_translations/3" do
    test "marks only the exact current display code as active" do
      posts = [
        %{
          available_languages: ["en-US", "en-GB"],
          language_statuses: %{"en-US" => "published", "en-GB" => "published"},
          language_titles: %{"en-US" => "US title", "en-GB" => "UK title"}
        }
      ]

      translations = Translations.build_listing_translations("blog", "en-US", posts)

      assert Enum.find(translations, &(&1.code == "en-US")).current
      refute Enum.find(translations, &(&1.code == "en-GB")).current
    end
  end

  describe "build_translation_links/4" do
    test "marks only the exact post language as current" do
      post = %{
        slug: "hello",
        mode: "slug",
        language: "en-US",
        available_languages: ["en-US", "en"],
        metadata: %{title: "Hello"},
        language_slugs: %{"en-US" => "hello-us", "en" => "hello"},
        version_statuses: %{}
      }

      translations = Translations.build_translation_links("blog", post, "en-US")

      assert Enum.find(translations, &(&1.code == "en-US")).current
      assert Enum.count(translations, & &1.current) == 1
    end

    test "collapses legacy base-language entries when they share a display code" do
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

      post = %{
        slug: "hello",
        mode: "slug",
        language: "en-US",
        available_languages: ["en-US", "en"],
        metadata: %{title: "Hello"},
        language_slugs: %{"en-US" => "hello-us", "en" => "hello"},
        version_statuses: %{}
      }

      translations = Translations.build_translation_links("blog", post, "en-US")

      assert length(translations) == 1
      assert Enum.at(translations, 0).code == "en"
    end

    test "removes bare base-language entries when dialects of the same base are enabled" do
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
            }
          ]
        })

      post = %{
        slug: "hello",
        mode: "slug",
        language: "en-US",
        available_languages: ["en", "en-US", "en-GB"],
        metadata: %{title: "Hello"},
        language_slugs: %{"en" => "hello", "en-US" => "hello-us", "en-GB" => "hello-uk"},
        version_statuses: %{}
      }

      translations = Translations.build_translation_links("blog", post, "en-US")

      refute Enum.any?(translations, &(&1.code == "en"))
      assert Enum.any?(translations, &(&1.code == "en-US"))
      assert Enum.any?(translations, &(&1.code == "en-GB"))
    end
  end
end
