# Dialyzer warnings to ignore (matched by dialyxir).
[
  # `PhoenixKitOg` is an optional plugin, not a dependency of this repo.
  # Every call site is guarded by `Code.ensure_loaded?/1` +
  # `function_exported?/3` at runtime and the compiler is told not to warn
  # via `@compile {:no_warn_undefined, PhoenixKitOg}`, but Dialyzer doesn't
  # understand that directive — it still resolves the remote call against
  # the PLT and reports it as calling a nonexistent function.
  {"lib/phoenix_kit_publishing/web/editor.ex", :unknown_function}
]
