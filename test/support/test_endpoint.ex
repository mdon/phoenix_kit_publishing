defmodule PhoenixKitPublishing.Test.Endpoint do
  @moduledoc """
  Minimal Phoenix.Endpoint used by controller integration tests.

  `phoenix_kit_publishing` has no endpoint of its own in production —
  the host app provides one. This test endpoint only exists so
  `Phoenix.ConnTest.get/2` can drive `Web.Controller.show/2` through a
  real Plug pipeline (session → router → controller → layout).
  """

  use Phoenix.Endpoint, otp_app: :phoenix_kit_publishing

  @session_options [
    store: :cookie,
    key: "_phoenix_kit_publishing_test_key",
    signing_salt: "publishing-test-salt",
    same_site: "Lax"
  ]

  plug(Plug.Session, @session_options)
  plug(PhoenixKitPublishing.Test.Router)
end
