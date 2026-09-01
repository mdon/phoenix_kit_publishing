defmodule PhoenixKit.Modules.Publishing.RendererExternalLinksTest do
  @moduledoc """
  Body links open in a new tab — a link in article prose is a reference,
  not navigation, and the reader keeps their place. Three kinds must stay
  put: in-page `#fragment` refs (the notes system's footnote links navigate
  within the page), `mailto:` and `tel:`. A tag the author gave an explicit
  target or rel is left exactly as authored — `target="_self"` is the
  opt-out.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Renderer

  defp render(body), do: Renderer.render_markdown(body, cache: false)

  describe "links open in a new tab" do
    test "an external link" do
      html = render("read [the paper](https://example.org/ewa) first")

      assert html =~ ~s(href="https://example.org/ewa" target="_blank" rel="noopener noreferrer")
    end

    test "an internal link too — prose links are references, not navigation" do
      html = render("see [the archive](/learning/archive)")

      assert html =~ ~s(href="/learning/archive" target="_blank" rel="noopener noreferrer")
    end

    test "two links both get the treatment" do
      html = render("[a](https://a.example) and [b](/local)")

      assert html =~ ~s(href="https://a.example" target="_blank")
      assert html =~ ~s(href="/local" target="_blank")
    end
  end

  describe "links that must stay in this page" do
    test "an in-page fragment ref — footnotes navigate within the page" do
      html = render(~s(jump <a href="#note-3">down</a>))

      assert html =~ ~s(href="#note-3")
      refute html =~ "_blank"
    end

    test "a mailto link — a blank tab beside the mail client helps nobody" do
      html = render("write [to us](mailto:hi@example.org)")

      assert html =~ ~s(href="mailto:hi@example.org")
      refute html =~ "_blank"
    end

    test "a tel link" do
      html = render(~s(call <a href="tel:+3721234">us</a>))

      assert html =~ ~s(href="tel:+3721234")
      refute html =~ "_blank"
    end
  end

  describe "authored HTML is respected" do
    test "an explicit target is the opt-out" do
      html = render(~s(<a href="https://example.org" target="_self">stay</a>))

      assert html =~ ~s(target="_self")
      refute html =~ "_blank"
    end

    test "an explicit rel is not doubled into invalid HTML" do
      html = render(~s(<a href="https://example.org" rel="license">terms</a>))

      assert html =~ ~s(rel="license")
      refute html =~ "noopener"
    end
  end

  describe "the rest of the pipeline" do
    test "a link shown inside a code fence is untouched" do
      html = render("```\n<a href=\"https://example.org\">raw</a>\n```\n")

      refute html =~ "_blank"
      assert html =~ "example.org"
    end
  end
end
