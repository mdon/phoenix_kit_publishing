defmodule PhoenixKit.Modules.Publishing.SlugHelpersTest do
  @moduledoc """
  Pure-function tests for SlugHelpers.validate_slug/1 and valid_slug?/1.
  The DB-coupled functions (`slug_exists?`, `validate_url_slug` reaching
  ListingCache) are exercised by integration tests; below covers the
  format/regex paths only.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.SlugHelpers

  describe "validate_slug/1" do
    test "accepts a simple lowercase slug" do
      assert {:ok, "hello-world"} = SlugHelpers.validate_slug("hello-world")
    end

    test "accepts numbers and hyphens" do
      assert {:ok, "post-2026-q4"} = SlugHelpers.validate_slug("post-2026-q4")
    end

    test "accepts a single word" do
      assert {:ok, "tutorial"} = SlugHelpers.validate_slug("tutorial")
    end

    test "rejects uppercase letters" do
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("Hello-World")
    end

    test "rejects spaces" do
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("hello world")
    end

    test "rejects special characters" do
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("hello!")
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("foo/bar")
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("foo.bar")
    end

    test "rejects leading/trailing hyphens" do
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("-hello")
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("hello-")
    end

    test "rejects double hyphens" do
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("hello--world")
    end

    test "rejects an empty string" do
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("")
    end
  end

  describe "valid_slug?/1" do
    test "returns true for a valid slug" do
      assert SlugHelpers.valid_slug?("hello-world")
    end

    test "returns false for invalid format" do
      refute SlugHelpers.valid_slug?("Bad Slug")
    end

    test "returns false for empty string" do
      refute SlugHelpers.valid_slug?("")
    end
  end
end
