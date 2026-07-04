defmodule PhoenixKitPublishing.I18nTest do
  @moduledoc """
  Smoke test for `PhoenixKitPublishing.Gettext` — the module's own backend
  (see `guides/per-module-i18n.md` in `phoenix_kit` core). Confirms the
  sidebar tab labels actually route through `Tab.localized_label/1` against
  our backend, and that gettext falls back to the raw msgid when a msgid or
  locale isn't translated.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.Publishing

  setup do
    original = Gettext.get_locale(PhoenixKitPublishing.Gettext)
    on_exit(fn -> Gettext.put_locale(PhoenixKitPublishing.Gettext, original) end)
    :ok
  end

  test "admin tab label is wired to this module's Gettext backend" do
    [tab | _] = Publishing.admin_tabs()
    assert tab.gettext_backend == PhoenixKitPublishing.Gettext

    Gettext.put_locale(PhoenixKitPublishing.Gettext, "ru")
    expected = Gettext.dgettext(PhoenixKitPublishing.Gettext, "default", tab.label)
    assert Tab.localized_label(tab) == expected
  end

  test "settings tab label is wired to this module's Gettext backend" do
    [tab | _] = Publishing.settings_tabs()
    assert tab.gettext_backend == PhoenixKitPublishing.Gettext
  end

  test "unknown locale falls back to the raw msgid" do
    [tab | _] = Publishing.admin_tabs()

    Gettext.put_locale(PhoenixKitPublishing.Gettext, "xx")
    assert Tab.localized_label(tab) == tab.label
  end
end
