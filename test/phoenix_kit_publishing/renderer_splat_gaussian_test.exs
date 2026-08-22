defmodule PhoenixKit.Modules.Publishing.RendererSplatGaussianTest do
  @moduledoc """
  `<SplatGaussian />` — an interactive teaching demo (one gaussian, with
  sliders), the first component whose behaviour lives in the module's JS
  bundle rather than in CSS or the server.

  The constraint that shaped it: public post pages are DEAD views. A
  phx-hook alone would never mount there, so the bundle boots the demo off a
  `data-pk-splat-gaussian` DOM scan, and everything the demo needs travels
  as data attributes on one container. These tests pin the container
  contract, because the JS side can only be as correct as what the renderer
  hands it.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Renderer

  defp render(body), do: Renderer.render_markdown(body, cache: false)

  describe "the container contract" do
    test "renders the boot marker, the hook, and phx-update ignore" do
      html = render("<SplatGaussian />")

      assert html =~ "data-pk-splat-gaussian"
      assert html =~ ~s(phx-hook="PubSplatGaussian")
      # Without this, any live-context patch would replace the canvas the
      # bundle built inside the container.
      assert html =~ ~s(phx-update="ignore")
    end

    test "defaults travel as data attributes" do
      html = render("<SplatGaussian />")

      assert html =~ ~s(data-sx="1.0")
      assert html =~ ~s(data-sy="0.45")
      assert html =~ ~s(data-sz="0.7")
      assert html =~ ~s(data-hue="24.0")
    end

    test "declared attributes override the defaults" do
      html = render(~s(<SplatGaussian sx="1.6" hue="200" />))

      assert html =~ ~s(data-sx="1.6")
      assert html =~ ~s(data-hue="200.0")
      assert html =~ ~s(data-sy="0.45")
    end

    test "two demos on one page get distinct ids" do
      html = render("<SplatGaussian />\n\nsome prose\n\n<SplatGaussian />")

      ids = Regex.scan(~r/id="(pk-splatg-\d+)"/, html) |> Enum.map(fn [_, id] -> id end)

      assert length(ids) == 2
      assert length(Enum.uniq(ids)) == 2
    end

    test "degrades to a caption that says what would have been here" do
      html = render("<SplatGaussian />")

      assert html =~ "needs JavaScript"
    end
  end

  describe "attribute values are numbers or nothing" do
    # An attribute is author-supplied markup, and "author" includes anyone
    # with editor access. The values land in data attributes, so anything
    # that is not purely a number falls back to the default.
    test "a non-numeric value falls back to the default" do
      html = render(~s(<SplatGaussian sx="huge" />))

      assert html =~ ~s(data-sx="1.0")
    end

    test "a numeric prefix with a payload behind it is rejected whole" do
      # ~s{} rather than ~s() — sigil delimiters do not nest, so the paren
      # in alert(1) would end a paren-delimited sigil early.
      html = render(~s{<SplatGaussian sx="1&quot; onload=&quot;alert(1)" />})

      refute html =~ "onload"
      assert html =~ ~s(data-sx="1.0")
    end
  end

  describe "the rest of the pipeline" do
    # The editor hands @component_tags to the WYSIWYG surface as
    # preserve_tags; a tag missing from that list does not survive the HTML
    # round trip — open a post, touch anything, and the autosave writes the
    # component back as flattened paragraphs. Silent data loss, so this is
    # the assertion that matters most.
    test "the tag is preserved against the editor round trip" do
      assert "SplatGaussian" in Renderer.component_tags()
    end

    test "a demo inside a code fence renders as text, not as a component" do
      html = render("```\n<SplatGaussian />\n```\n")

      refute html =~ "data-pk-splat-gaussian"
      assert html =~ "SplatGaussian"
    end
  end
end
