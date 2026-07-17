defmodule PhoenixKit.Modules.Publishing.GroupSettingsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.GroupSettings
  alias PhoenixKit.Modules.Publishing.PublishingGroup

  describe "schema/0" do
    test "every entry carries the required fields with sane types" do
      for s <- GroupSettings.schema() do
        assert is_binary(s.key)
        assert s.type in [:enum, :boolean]
        assert is_list(s.allowed)
        assert s.scope in [:listing, :post, :appearance]
        assert is_binary(s.label)
        assert is_binary(s.description)
        assert is_nil(s.depends_on) or is_binary(s.depends_on)
        # The default must itself be a valid value.
        assert s.default in s.allowed
      end
    end

    test "covers exactly the keys update_group/3 persists to group data" do
      # Mirror of Groups.merge_group_config/2's key list — if a setting is added
      # to one and not the other, this fails.
      expected =
        ~w(listing_sort show_post_count featured_enabled featured_layout
           scroll_timeline_enabled scroll_timeline_granularity post_width
           post_date_position show_breadcrumbs show_featured_image show_reading_time
           show_tags scroll_progress_enabled scroll_headings_enabled scrollbar_style)

      assert Enum.sort(GroupSettings.keys()) == Enum.sort(expected)
    end

    test "any dependency references a real setting key" do
      keys = MapSet.new(GroupSettings.keys())

      for %{depends_on: dep} <- GroupSettings.schema(), not is_nil(dep) do
        assert MapSet.member?(keys, dep), "depends_on #{inspect(dep)} is not a known setting"
      end
    end
  end

  describe "default_config/0" do
    test "matches the schema accessors' defaults on an empty group (no drift)" do
      empty = %PublishingGroup{data: %{}}
      defaults = GroupSettings.default_config()

      assert defaults["featured_enabled"] == PublishingGroup.featured_enabled?(empty)
      assert defaults["featured_layout"] == PublishingGroup.featured_layout(empty)
      assert defaults["scrollbar_style"] == PublishingGroup.scrollbar_style(empty)

      assert defaults["scroll_progress_enabled"] ==
               PublishingGroup.scroll_progress_enabled?(empty)

      assert defaults["scroll_headings_enabled"] ==
               PublishingGroup.scroll_headings_enabled?(empty)

      assert defaults["scroll_timeline_enabled"] ==
               PublishingGroup.scroll_timeline_enabled?(empty)

      assert defaults["scroll_timeline_granularity"] ==
               PublishingGroup.scroll_timeline_granularity(empty)

      assert defaults["listing_sort"] == PublishingGroup.listing_sort(empty)
      assert defaults["show_breadcrumbs"] == PublishingGroup.show_breadcrumbs?(empty)
      assert defaults["post_date_position"] == PublishingGroup.post_date_position(empty)
      assert defaults["post_width"] == PublishingGroup.post_width(empty)
      assert defaults["show_featured_image"] == PublishingGroup.show_featured_image?(empty)
      assert defaults["show_reading_time"] == PublishingGroup.show_reading_time?(empty)
      assert defaults["show_tags"] == PublishingGroup.show_tags?(empty)
    end
  end

  describe "validate_params/1" do
    test "normalizes booleans and enums and preserves unknown keys" do
      params = %{
        "post_width" => "wide",
        "show_tags" => "true",
        "featured_enabled" => false,
        # not governed by this module — must pass through untouched
        "name" => "My Blog"
      }

      assert {:ok, out} = GroupSettings.validate_params(params)
      assert out["post_width"] == "wide"
      assert out["show_tags"] == true
      assert out["featured_enabled"] == false
      assert out["name"] == "My Blog"
    end

    test "accepts on/off and true/false string forms for booleans" do
      assert {:ok, %{"show_tags" => true}} = GroupSettings.validate_params(%{"show_tags" => "on"})

      assert {:ok, %{"show_tags" => false}} =
               GroupSettings.validate_params(%{"show_tags" => "off"})
    end

    test "rejects an out-of-range enum value with a helpful reason" do
      assert {:error, [%{key: "post_width", reason: reason}]} =
               GroupSettings.validate_params(%{"post_width" => "gigantic"})

      assert reason =~ "narrow"
    end

    test "rejects a non-boolean value for a boolean setting" do
      assert {:error, [%{key: "show_tags", reason: reason}]} =
               GroupSettings.validate_params(%{"show_tags" => "maybe"})

      assert reason =~ "boolean"
    end

    test "reports every invalid key at once" do
      assert {:error, errors} =
               GroupSettings.validate_params(%{
                 "post_width" => "gigantic",
                 "listing_sort" => "sideways"
               })

      assert length(errors) == 2
      assert Enum.map(errors, & &1.key) |> Enum.sort() == ["listing_sort", "post_width"]
    end
  end
end
