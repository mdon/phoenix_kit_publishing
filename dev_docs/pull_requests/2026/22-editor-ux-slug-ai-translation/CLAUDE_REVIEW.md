# PR #22 — Claude review (post-merge follow-up)

Independent review of the merged PR #22 surface (editor UX, configurable slug
style, parallel AI translation) using the Elixir thinking/ecto skills. Scope:
find issues we can fix ourselves. Three actionable findings, all fixed; one
pre-existing Dialyzer error surfaced by `mix precommit` and fixed.

## Findings & fixes

### 1. `source_content_blank?/1` still sourced from the *viewed* language (bug — MEDIUM)

`web/editor/translation.ex`. Residual of the exact class of bug the Phase-2
sweep fixed. The sweep made translation always source from the **primary**
language in `do_enqueue_translation/2` and the editor-lock warnings, but
`source_content_blank?/1` — which feeds the *"source content is empty"*
confirmation warning — still computed `source_language = current_language ||
primary`.

On a non-primary editor page the warning then reflected the wrong language:

- primary has content, viewed translation empty → false "source is empty" warning;
- primary empty, viewed translation has content → **no** warning, yet the real
  source (primary) is blank → silently produces empty translations.

**Fix:** use `source_language_for_translation/1` (always primary), matching the
rest of the path.

### 2. `url_slug` input `pattern` hardcoded ASCII even in `:unicode` slug mode (bug — LOW)

`web/editor.ex`. The new slug-style feature lets an admin pick **Unicode**
slugs (`привет-мир`), accepted server-side by `validate_url_slug/4`, but the
input carried `pattern="[a-z0-9]+(-[a-z0-9]+)*"`, so the browser's HTML5
validation rejected a slug the server accepts.

**Fix:** added `SlugHelpers.html_input_pattern/0` (style-aware: ASCII for
`:transliterate`/`:ascii`, `\p{L}\p{N}` for `:unicode`) and wired the input's
`pattern` to it. Keeps client- and server-side validation in lockstep.
Test added in `slug_helpers_test.exs`.

### 3. Hardcoded worker-module string in the in-flight Oban query (maintainability — LOW)

`web/editor/translation.ex`. `in_flight_translation_languages/1` matched
`j.worker == "PhoenixKit.Modules.AI.TranslateWorker"`. A core rename would
silently return `[]` (the in-progress banner stops restoring on refresh) with
no signal. Core exposes no public "list in-flight by resource" API (only a
private `job_in_flight?`), so the hand-rolled query stays — but the literal is
now `^inspect(@translate_worker)` against a `@translate_worker` module
attribute, so the name can't drift and the coupling is greppable.

### 4. Dead `|| %{}` guard on `post.metadata` (pre-existing — fixed to unblock precommit)

`ai_translatable.ex:188` (not PR #22-introduced; present before this review).
`mix precommit` runs Dialyzer (the PR's own verification ran only
format/credo/compile), which flagged `Map.get(post.metadata || %{}, …)` as an
impossible guard — `build_metadata/4` always returns a map and `renderer.ex:80`
already treats `post.metadata` as non-nil. Dropped the dead `|| %{}`.

## Not changed (noted, lower priority)

- **Repeated `Settings` reads in slug validation** — `validate_url_slug/4`
  resolves `slug_style/0` several times per call via `slug_pattern/0`. Cheap if
  Settings is cached; resolving once per call would avoid the repeat. Left as-is.
- **`AITranslatable.fetch/2` relies on `read_post_by_uuid` returning a non-nil
  `:version`** — a `nil` would re-introduce the read/write version mismatch the
  sweep fixed. Worth a multi-version regression fixture (already on the sweep's
  "Skipped/future" list).

## Verification

- `mix format` clean.
- `mix precommit` (`compile --warnings-as-errors` + `deps.unlock --check-unused`
  + `format --check` + `credo --strict` + `dialyzer`): **0 errors, passed.**
- `mix test` not runnable in this sandbox (`test_helper.exs` shells out to
  `psql`, absent here — `:enoent`). New `html_input_pattern/0` test mirrors the
  existing setting-driven `slug_style/0` test in the same module; run against a
  real DB to confirm.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_publishing/web/editor/translation.ex` | source = primary in `source_content_blank?/1`; `@translate_worker` module ref |
| `lib/phoenix_kit_publishing/slug_helpers.ex` | new `html_input_pattern/0` |
| `lib/phoenix_kit_publishing/web/editor.ex` | `pattern` wired to `html_input_pattern/0`; `SlugHelpers` alias |
| `lib/phoenix_kit_publishing/ai_translatable.ex` | dropped dead `|| %{}` (pre-existing Dialyzer fix) |
| `test/phoenix_kit_publishing/slug_helpers_test.exs` | +`html_input_pattern/0` test |
