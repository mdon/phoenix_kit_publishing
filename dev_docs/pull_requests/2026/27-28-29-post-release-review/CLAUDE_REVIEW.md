# CLAUDE_REVIEW — PR #27, #28, #29

**Reviewed:** 2026-07-03
**Scope:** Full diff of all three merge commits (`a97d607`, `324a3cd`, `abe3d1b`).
**Verdict:** #28 and #29 clean. #27 had three latent bugs + one stale test,
all fixed below with regression coverage.

---

## PR #28 — `:url_path` plug

Clean. `assign_url_path/2` only sets the assign when absent (mirrors the
`phoenix_kit` on_mount hook's non-clobbering semantics — correctly noted in
the PR that `Plug.Conn` has no `assign_new/3`), and the module `plug` runs
ahead of every branch in `show/2`, including the 404 fallback, so there's no
render path that skips it. No issues found.

## PR #29 — Reserved route prefixes

Independently re-verified (not just re-reading the prior review):

- `PhoenixKit.ModuleRegistry.all_reserved_route_prefixes/0` exists in the
  currently-vendored `phoenix_kit` (confirmed by reading
  `phoenix_kit/lib/phoenix_kit/module_registry.ex`), and `mix.lock` already
  pins `phoenix_kit` to `1.7.171` — satisfying the `~> 1.7.170` floor the PR
  bumped `mix.exs` to. The dependency-sequencing risk the PR's own review
  flagged is resolved; nothing left to do here.
- `not reserved_by_other_module?(slug) and case ... end` — confirmed `and`
  short-circuits on the reserved case, so the DB lookup is skipped exactly
  when the docs claim.
- The `function_exported?/3` guard degrades to "nothing reserved" (not a
  crash swallowed by the outer `rescue`) on an older core, which is the
  correct narrowing of the original "total public-routing outage" failure
  mode.

No further issues found.

## PR #27 — phoenix_kit_og integration + slug cap

### BUG — MEDIUM — `og_resolve/2` always returns `nil` for 3 of 8 declared variables → fixed

`og_variables/0` advertises `post_url`, `post_group_name`, and
`post_group_slug` as available OG-template variables. Their `og_resolve/2`
clauses read metadata keys that don't exist on the post map the mapper
actually builds (`db_storage/mapper.ex:build_metadata/4` — verified by
reading it directly):

- `post_url` read `og_get_meta(post, :url)` — the mapper never puts a `:url`
  key anywhere (URL building needs request-time scheme/host, which isn't
  available in the pure DB→map mapper). Always `nil`.
- `post_group_name` read `og_get_meta(post, :group_name)` — the mapper only
  exposes the group's **slug**, under the key `:group` (`group: group_slug`
  in `to_post_map/6`). There's no group-name field anywhere on the post map.
  Always `nil`.
- `post_group_slug` read `og_get_meta(post, :group_slug)` — same map, wrong
  key name; the real key is `:group`. Always `nil`.

Confirmed against the actual consumer contract too: the sibling
`phoenix_kit_open_graph` checkout in this workspace documents `context` as
`%{module_key: "publishing", resource: post_map, conn: conn, language: ...}`
(`phoenix_kit_og/variables.ex` moduledoc) — `conn` is available to
`og_resolve/2` and was simply never used.

Not reachable today — `phoenix_kit_og` isn't a dependency of this repo yet,
so nothing currently calls `og_resolve/2` — but it would have shipped
silently broken (rendering blank slots forever, with no error and no test
to catch it) the moment that plugin is wired up. Fixed:

- `post_group_slug` now reads `og_get_meta(post, :group)` — the real key.
- `post_group_name` now resolves the slug through `Groups.group_name/1`
  (the same helper the editor already uses for display: see
  `editor.ex`'s `Publishing.group_name(group_slug) || group_slug` at mount).
- `post_url` now pattern-matches `conn` out of `context` and builds the
  canonical URL via `PublishingHTML.build_post_url(group_slug, post,
  language)` + a local `absolute_post_url/2` (scheme/host/port), the same
  two-step `build_post_url` → absolutize pattern `Web.Controller.build_og_data/4`
  already uses for the live `og:url` tag. Returns `nil` when no `conn` is in
  context (can't build an absolute URL) rather than crashing on the
  non-matching function clause.

Added 4 tests in `test/phoenix_kit_publishing/integration/og_override_test.exs`
("`Publishing.og_resolve/2`" describe block) pinning all three fixes plus
the no-conn case.

### BUG — LOW — new code fails the project's own `credo --strict` gate → fixed

`Web.Controller.fetch_variant/2` (added by this PR) calls
`PhoenixKit.Modules.Storage.get_file_instance_by_name/2` by its fully
qualified name instead of aliasing it, which credo's `--strict` "nested
module could be aliased" check flags. `mix precommit` (the project's
documented pre-merge gate) would have failed on this. Fixed by adding
`alias PhoenixKit.Modules.Storage` and using `Storage.get_file_instance_by_name/2`.

### BUG — LOW — `mix dialyzer` fails outright on this branch → fixed

`mix precommit` / `mix quality` / `mix quality.ci` all run `dialyzer`
unconditionally, and it exits non-zero on unresolved warnings. Ran it (first
run on this checkout — no cached PLT, ~25 min to build) and found 5 errors,
none pre-existing on `main` before these PRs:

1. **`editor.ex:91`/`:104` — `unknown_function` for `PhoenixKitOg.enabled?/0`
   and `.preview_og_image_url/3`.** `@compile {:no_warn_undefined,
   PhoenixKitOg}` silences the *compiler* (which is why `mix compile
   --warnings-as-errors` was clean) but Dialyzer doesn't understand that
   directive and still resolves the remote call against the PLT, where the
   module doesn't exist (`phoenix_kit_og` isn't a dependency of this repo).
   This exact "optional module guarded by `Code.ensure_loaded?/1`" pattern
   already has an established fix elsewhere in this workspace — `phoenix_kit`
   core's own `.dialyzer_ignore.exs` has an identical entry for
   `sitemap/sources/publishing.ex` (publishing is optional from core's
   point of view, same shape as `phoenix_kit_og` from this repo's). Added
   `phoenix_kit_publishing`'s own `.dialyzer_ignore.exs` (this repo didn't
   have one yet) with the matching entry, wired via
   `dialyzer: [ignore_warnings: ".dialyzer_ignore.exs"]` in `mix.exs` — the
   same two-line wiring every other `phoenix_kit_*` sibling with an ignore
   file uses.
2. **`controller.ex:449`/`:456` — `guard_fail`.** `image_meta_for_uuid/1`
   always returns a map (`%{url: ...}` at minimum, even from its own
   `rescue`), so the `|| %{url: nil}` fallback at both call sites in
   `og_image_meta/2` was dead code that Dialyzer's success typing correctly
   flagged as unreachable. Removed both fallbacks; also corrected the
   function's stale comment, which claimed it "returns nil" (it never did —
   `url` is always populated internally via `featured_image_url/2`).
3. **`publishing.ex:436` — `pattern_match_cov`.** My own `post_url` fix
   (above) initially defined `absolute_post_url/2` with a catch-all
   `(_conn, _path) -> nil` clause for defensiveness. Dialyzer proved it
   unreachable — the only call site always supplies `%Plug.Conn{}` +
   a binary from `build_post_url/3`. Removed the dead clause.

Re-ran `mix dialyzer` after all three fixes: **passed successfully** (the
two now-ignored `PhoenixKitOg` warnings show as "Skipped" in the summary,
everything else clean).

### IMPROVEMENT — LOW — stale test assertion after the slug-cap change → fixed

`slug_helpers_test.exs`'s `"caps length at 200 on a hyphen boundary"` test
still asserted `String.length(slug) <= 200` after `@seo_slug_length` dropped
from 200 to 60 in this same PR. The assertion still passed (60 ≤ 200 is
trivially true) so it wasn't caught by CI, but it no longer verifies the cap
this PR actually shipped — a regression back up to, say, 150 chars would
sail through unnoticed. Renamed the test and tightened the assertion to
`<= 60` to match the real cap.

### What's fine as shipped (no change needed)

- **The OG override precedence chain** (`build_og_data/4`: module → per-post
  override → derived default) is implemented correctly — verified the
  per-field `||` fallbacks resolve in the documented order and that
  `og_override/2` correctly reads the string-keyed map the mapper produces
  (`PublishingContent.get_og/1` returns `data["og"]`, JSONB-backed, string
  keys throughout — `Forms.og_field/2` and `build_og_data/4` both read it
  consistently).
- **Media-selector target routing** (`media_selector_target` assign,
  `open_media_selector`/`clear_og_image`/`handle_media_selected`) correctly
  threads which form field (`featured_image_uuid` vs `og_image_uuid`) a
  picked file writes to, and resets to the default after every selector
  close path (success, insert-component branch, and the `true ->` no-op
  branch). No stale-target leak between the two pickers.
- **`image_meta_for_uuid/1`'s synthetic post map**
  (`%{metadata: %{featured_image_uuid: uuid}}` passed to
  `PublishingHTML.featured_image_url/2`) — checked `featured_image_url/2`'s
  actual field access and confirmed it only ever reads
  `post.metadata.featured_image_uuid`, so the synthetic map can't crash it.
- **Slug cap layering** — `effective_max_slug_length/0` is
  `min(@seo_slug_length, Constants.max_slug_length())` = `min(60, 500)` =
  `60`; a human-typed manual slug is validated against the changeset's
  500-char column limit, not the 60-char SEO cap, so this doesn't
  retroactively invalidate longer manually-set slugs. (The editor's
  `url-slug-input` HTML `maxlength="200"` — from PR #22, untouched here — is
  a separate, pre-existing minor inconsistency with the 500-char save limit;
  out of scope for this PR.)
- **`og_preview_url/2` double-invocation** in the editor template (called
  once in the `:if` guard, once for `src=`) — genuine minor duplicate work,
  but gated behind `@og_module_active? and ...` which short-circuits to
  `false` today (no `phoenix_kit_og` dependency installed anywhere in this
  repo), so it's dead weight, not a live perf issue. Left as a note rather
  than fixed — not worth the code-shape churn for a path nothing exercises
  yet; revisit when `phoenix_kit_og` actually becomes a dependency.

## Gate

- `mix format --check-formatted` — clean
- `mix compile --warnings-as-errors` — clean
- `mix credo --strict` — clean (after the fix above)
- `mix test` — 600 tests, 0 failures (552 excluded — no local Postgres, same
  pre-existing environment limitation noted in PR #29's own review; the new
  `og_resolve/2` tests live in the DB-backed integration file and are
  excluded here for the same reason, not because they fail)
- `mix dialyzer` — passed successfully after the fixes above (was failing
  with 5 errors before)

## Files Changed (this review)

| File | Change |
|------|--------|
| `lib/phoenix_kit_publishing/publishing.ex` | Fixed `post_url` / `post_group_name` / `post_group_slug` `og_resolve/2` clauses; added `Groups`/`PublishingHTML` aliases + `absolute_post_url/2`; dropped its unreachable catch-all clause (dialyzer) |
| `lib/phoenix_kit_publishing/web/controller.ex` | Aliased `PhoenixKit.Modules.Storage` (credo); removed dead `\|\| %{url: nil}` fallback + fixed stale comment (dialyzer) |
| `.dialyzer_ignore.exs` | New — ignores the two `PhoenixKitOg` `unknown_function` warnings, matching the established pattern for optional-module integrations elsewhere in the `phoenix_kit_*` workspace |
| `mix.exs` | Wired `ignore_warnings: ".dialyzer_ignore.exs"` into the `:dialyzer` config; version bump (see CHANGELOG) |
| `test/phoenix_kit_publishing/integration/og_override_test.exs` | Added `Publishing.og_resolve/2` describe block (4 tests) |
| `test/phoenix_kit_publishing/slug_helpers_test.exs` | Fixed stale `200` → `60` assertion + test name |
