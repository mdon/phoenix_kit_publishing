defmodule PhoenixKit.Modules.Publishing.RendererSplatTrainerTest do
  @moduledoc """
  `<SplatTrainer />` — the red-dot trainer: a real gradient-descent fit of
  one gaussian, run in the reader's browser by the module's JS bundle.

  Same dead-view constraint as SplatGaussian: public post pages have no
  LiveSocket, so the bundle boots off a `data-pk-splat-trainer` DOM scan
  and everything the demo needs travels as data attributes. These tests pin
  the container contract; the optimizer's behavioural claims are verified
  separately, headless, against the shipped bundle itself.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Renderer

  defp render(body), do: Renderer.render_markdown(body, cache: false)

  describe "the container contract" do
    test "renders the boot marker, the hook, and phx-update ignore" do
      html = render("<SplatTrainer />")

      assert html =~ "data-pk-splat-trainer"
      assert html =~ ~s(phx-hook="PubSplatTrainer")
      # Without this, any live-context patch would replace the panels the
      # bundle built inside the container.
      assert html =~ ~s(phx-update="ignore")
    end

    test "defaults travel as data attributes" do
      html = render("<SplatTrainer />")

      assert html =~ ~s(data-cameras="1")
      assert html =~ ~s(data-mode="count")
    end

    test "declared attributes override the defaults" do
      html = render(~s(<SplatTrainer cameras="3" mode="rig" />))

      assert html =~ ~s(data-cameras="3")
      assert html =~ ~s(data-mode="rig")
    end

    test "both demos can share a page with distinct ids" do
      html = render("<SplatGaussian />\n\nprose\n\n<SplatTrainer />")

      assert html =~ "data-pk-splat-gaussian"
      assert html =~ "data-pk-splat-trainer"
      assert html =~ ~r/id="pk-splatg-\d+"/
      assert html =~ ~r/id="pk-splatt-\d+"/
    end

    test "degrades to a caption that says what would have been here" do
      html = render("<SplatTrainer />")

      assert html =~ "needs JavaScript"
    end
  end

  describe "attribute values are allowlisted or nothing" do
    # An attribute is author-supplied markup, and "author" includes anyone
    # with editor access. Both attributes land in data attributes, so
    # anything not on the allowlist falls back to the default.
    test "an off-list camera count falls back to the default" do
      html = render(~s(<SplatTrainer cameras="7" />))

      assert html =~ ~s(data-cameras="1")
    end

    test "an off-list mode falls back to the default" do
      html = render(~s(<SplatTrainer mode="chaos" />))

      assert html =~ ~s(data-mode="count")
    end

    test "a payload riding an attribute is rejected whole" do
      # ~s{} rather than ~s() — sigil delimiters do not nest, so the paren
      # in alert(1) would end a paren-delimited sigil early.
      html = render(~s{<SplatTrainer mode="rig&quot; onload=&quot;alert(1)" />})

      refute html =~ "onload"
      assert html =~ ~s(data-mode="count")
    end
  end

  describe "the rest of the pipeline" do
    # The editor hands @component_tags to the WYSIWYG surface as
    # preserve_tags; a tag missing from that list does not survive the HTML
    # round trip — silent data loss on autosave.
    test "the tag is preserved against the editor round trip" do
      assert "SplatTrainer" in Renderer.component_tags()
    end

    test "a demo inside a code fence renders as text, not as a component" do
      html = render("```\n<SplatTrainer />\n```\n")

      refute html =~ "data-pk-splat-trainer"
      assert html =~ "SplatTrainer"
    end
  end
end
