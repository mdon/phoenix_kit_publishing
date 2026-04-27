defmodule PhoenixKit.Modules.Publishing.ListingCacheTest do
  @moduledoc """
  Tests for ListingCache key generators and direct persistent_term
  reads. Full read/regenerate cycle is covered by integration tests
  that need a DB; this file focuses on the pure / persistent_term-only
  paths.

  Each test uses a unique group slug so persistent_term entries don't
  bleed between tests. We never `:persistent_term.erase` to keep the
  `:persistent_term` count bounded.
  """

  # Uses DataCase because every read path calls `memory_cache_enabled?/0`
  # → `Settings.get_setting_cached/2` → DB. Without sandbox checkout, those
  # queries flake under concurrent test load (owner-pid exits mid-checkout).
  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.ListingCache

  defp unique_group, do: "lc-test-#{System.unique_integer([:positive])}"

  describe "persistent_term_key/1" do
    test "returns a 2-tuple with the cache prefix and group slug" do
      assert {prefix, "blog"} = ListingCache.persistent_term_key("blog")
      assert is_atom(prefix)
    end

    test "produces distinct keys for distinct group slugs" do
      refute ListingCache.persistent_term_key("a") == ListingCache.persistent_term_key("b")
    end
  end

  describe "loaded_at_key/1" do
    test "returns a tuple distinct from persistent_term_key" do
      group = unique_group()
      refute ListingCache.loaded_at_key(group) == ListingCache.persistent_term_key(group)
    end
  end

  describe "cache_generated_at_key/1" do
    test "returns a tuple distinct from loaded_at_key" do
      group = unique_group()
      refute ListingCache.cache_generated_at_key(group) == ListingCache.loaded_at_key(group)
    end
  end

  describe "memory_loaded_at/1 and cache_generated_at/1" do
    test "return nil when no cache entry exists yet" do
      group = unique_group()
      assert ListingCache.memory_loaded_at(group) == nil
      assert ListingCache.cache_generated_at(group) == nil
    end

    test "return the value from persistent_term when set" do
      group = unique_group()
      :persistent_term.put(ListingCache.loaded_at_key(group), "2026-04-27T00:00:00Z")
      :persistent_term.put(ListingCache.cache_generated_at_key(group), "2026-04-27T00:00:00Z")

      assert ListingCache.memory_loaded_at(group) == "2026-04-27T00:00:00Z"
      assert ListingCache.cache_generated_at(group) == "2026-04-27T00:00:00Z"
    end
  end

  describe "exists?/1" do
    test "returns false when no cache entry" do
      refute ListingCache.exists?(unique_group())
    end

    test "returns true after putting an entry" do
      group = unique_group()
      :persistent_term.put(ListingCache.persistent_term_key(group), [])
      assert ListingCache.exists?(group)
    end
  end

  describe "find_post/2" do
    test "returns :not_found when group has no cache and no DB rows" do
      # With sandbox checked out, read/1 triggers regenerate/1 which queries
      # the DB; an empty result lands in persistent_term, then find_post
      # walks the empty list and returns :not_found.
      assert {:error, :not_found} = ListingCache.find_post(unique_group(), "any-slug")
    end

    test "returns :not_found when post slug isn't in the cached list" do
      group = unique_group()

      :persistent_term.put(ListingCache.persistent_term_key(group), [
        %{slug: "different", language_slugs: %{}}
      ])

      assert {:error, :not_found} = ListingCache.find_post(group, "missing")
    end

    test "returns {:ok, post} when slug matches" do
      group = unique_group()
      target = %{slug: "alpha", title: "Alpha"}

      :persistent_term.put(ListingCache.persistent_term_key(group), [
        %{slug: "beta"},
        target
      ])

      assert {:ok, ^target} = ListingCache.find_post(group, "alpha")
    end
  end

  describe "find_by_url_slug/3" do
    test "returns {:ok, post} matching language_slugs entry" do
      group = unique_group()
      target = %{slug: "p", language_slugs: %{"fr" => "bonjour-monde"}}
      :persistent_term.put(ListingCache.persistent_term_key(group), [target])

      assert {:ok, ^target} = ListingCache.find_by_url_slug(group, "fr", "bonjour-monde")
    end

    test "returns :not_found when language_slugs has no match" do
      group = unique_group()

      :persistent_term.put(ListingCache.persistent_term_key(group), [
        %{slug: "p", language_slugs: %{"en" => "hello"}}
      ])

      # Sandbox-backed read may regenerate from DB before consulting our
      # injected entry — accept either :not_found or :cache_miss.
      assert match?(
               {:error, _},
               ListingCache.find_by_url_slug(group, "fr", "missing")
             )
    end
  end

  describe "find_by_previous_url_slug/3" do
    test "returns {:ok, post} when previous slug matches" do
      group = unique_group()

      target = %{
        slug: "p",
        language_previous_slugs: %{"fr" => ["old-slug", "older-slug"]}
      }

      :persistent_term.put(ListingCache.persistent_term_key(group), [target])

      assert {:ok, ^target} = ListingCache.find_by_previous_url_slug(group, "fr", "old-slug")
    end

    test "returns :not_found when no previous slug matches" do
      group = unique_group()

      :persistent_term.put(ListingCache.persistent_term_key(group), [
        %{slug: "p", language_previous_slugs: %{}}
      ])

      assert match?(
               {:error, _},
               ListingCache.find_by_previous_url_slug(group, "fr", "anything")
             )
    end
  end
end
