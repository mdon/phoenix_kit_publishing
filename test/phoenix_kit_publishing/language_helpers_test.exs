defmodule PhoenixKit.Modules.Publishing.LanguageHelpersTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.LanguageHelpers

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
end
