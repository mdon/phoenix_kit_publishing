defmodule PhoenixKitPublishing.Gettext do
  @moduledoc """
  Gettext backend for phoenix_kit_publishing.

  Owns the translation catalogues under `priv/gettext/`. Locale is set
  per-request by the parent application (or, for public content routes,
  by this module's own `Web.Controller.set_gettext_locale/1`); this module
  is only responsible for looking msgids up against the active locale.

  See `guides/per-module-i18n.md` in `phoenix_kit` core for the full setup
  and conventions.
  """
  use Gettext.Backend, otp_app: :phoenix_kit_publishing
end
