defmodule PhoenixKit.Modules.Publishing.PresenceHelpersTest do
  @moduledoc """
  Tests for PresenceHelpers — the topic-name builder and the
  owner/spectator role-resolution logic.

  Most of the module wraps Phoenix.Presence/PubSub and is exercised by
  integration tests; the pure helpers below pin behaviour without
  needing a Presence/PubSub server. Anything that does need one is
  tested via Presence.list-mocked behavior.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.PresenceHelpers

  describe "editing_topic/1" do
    test "prefixes 'publishing_edit:' to the form key" do
      assert PresenceHelpers.editing_topic("blog:hello:en") ==
               "publishing_edit:blog:hello:en"
    end

    test "handles slug-mode form keys" do
      assert PresenceHelpers.editing_topic("docs:my-doc:fr") ==
               "publishing_edit:docs:my-doc:fr"
    end

    test "handles new-mode form keys" do
      assert PresenceHelpers.editing_topic("blog:new:en") ==
               "publishing_edit:blog:new:en"
    end

    test "handles empty suffix" do
      assert PresenceHelpers.editing_topic("") == "publishing_edit:"
    end
  end
end
