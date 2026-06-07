# PR #22 — Editor UX, configurable slug style, parallel AI translation

Quality-sweep record for the work bundled into PR #22 (editor UX, slug-style
engine, AI-translation migration to core's generic pipeline). Phases per
`dev_docs/quality_sweep.md`.

## Phase 1 — PR catch-up

No outstanding work. All ten existing PR folders under
`dev_docs/pull_requests/2026/` already carry a `FOLLOW_UP.md` (PRs #2, #4, #5,
#9, #10, #12, #13, #15, #16, #20). The merged PRs without a folder (#1, #3,
#14, #17, #18, #19, #21) have no `*_REVIEW.md` to triage. Nothing untriaged.

## Phase 2 — Quality sweep (re-validation, scoped to the PR #22 surface)

Publishing is an already-swept module (PRs #10 + #16). This pass re-ran the
four parallel `Explore` triage agents (security/error/UX · translations/
activity/tests · PubSub/cleanliness/API · host-integration boundaries) against
the new code. **No live critical/high bugs.** Agent claims were verified before
acting (several were false positives).

## Fixed (Batch — 2026-06-07)

- AI-translation adapter generated a per-language `url_slug` from the
  translated title but never checked it was free in the group+language. Added a
  uniqueness guard in `AITranslatable.maybe_put_slug/4`: validate via
  `SlugHelpers.validate_url_slug/4` and **omit on conflict** so the row falls
  back to the post's (unique) default slug. Never errors the job; read-time
  collision resolution remains the backstop for the concurrent race.
  (`lib/phoenix_kit_publishing/ai_translatable.ex`)
- `url-slug-input` had no `maxlength`; added `maxlength="200"` to match the
  server-side 200-char `SlugHelpers` cap.
  (`lib/phoenix_kit_publishing/web/editor.ex`)
- Simplified a redundant final `with` clause in `put_translation/4` flagged by
  `credo --strict`. (`lib/phoenix_kit_publishing/ai_translatable.ex`)

## Fixed (Batch 2 — Codex review, 2026-06-07)

Codex flagged two genuine HIGH bugs in the AI-translation path (both verified):

- **Translation source was the viewed language, not the primary.**
  `do_enqueue_translation/2` used `socket.assigns[:current_language]` as
  `source_lang`. On a non-primary editor page, "translate this language"
  enqueued `source_lang == target_lang` (translating a language into itself),
  and "translate all/missing" translated *from* a translation. Now uses
  `source_language_for_translation/1` (always the primary) — consistent with
  `build_translation_warnings/2`. (`web/editor/translation.ex`)
- **Read/write version mismatch.** `source_fields/2` read the version
  `read_post_by_uuid(…, nil)` resolves (active/inferred), but
  `ensure_language_row/2` → `add_language_to_post(…, nil)` wrote to
  `get_latest_version` — so on a published-v1 + draft-v2 post the translation
  landed on the wrong version (public readers wouldn't see it). The adapter now
  pins the resolved version in `fetch/2` and threads it through both the read
  and the write. (`lib/phoenix_kit_publishing/ai_translatable.ex`)

## Fixed (Batch 4 — live browser test, 2026-06-07)

Ran a real end-to-end AI translation in Chrome (dev server, parent app) instead
of trusting only the data-layer tests — opened a post on its **ru** (non-primary)
page and translated en-US → ru. This surfaced **two real bugs**, one of them a
regression introduced by this PR's migration. Both fixed and re-verified live.

### Bug 1 (HIGH, regression) — prompt variables not substituted

**Symptom:** translations came back as hallucinated/placeholder content (e.g. a
fluent-but-unrelated article, or literal `[… title]`), not a translation of the
source. **Root cause:** the publishing prompt template uses capitalized
placeholders `{{Title}}` / `{{Content}}`, but the new adapter's `source_fields/2`
returned lowercase `"title"` / `"content"` keys. Core feeds those keys straight
into `PhoenixKitAI.Prompt.render`, whose substitution is **case-sensitive**
(`get_variable_value` tries the string key then the atom key, nothing else;
unmatched `{{…}}` is left literal). So `{{Title}}`/`{{Content}}` never rendered,
the model received the template with empty/literal placeholders, and made
something up. The retired `TranslatePostWorker` fed capitalized `"Title"`/
`"Content"` (verified in git `a446178^`); the migration to the generic pipeline
dropped that casing — the keys now drive both substitution **and** response
parsing, so they must match the prompt.

**Fix (standardized to the ecosystem convention):** rather than match
publishing's bespoke capitalized prompt, we aligned publishing with the
catalogue/projects convention — **lowercase** field keys throughout.
`source_fields/2` emits `"title"`/`"content"`, `build_params/3` reads them back
(DB params were already lowercase), and the shipped default prompt
(`default_prompt_content/0`) now uses `{{title}}`/`{{content}}` plus the generic
*"skip a value that is still a literal `{{placeholder}}`"* instruction, so a
future binding mismatch **fails closed** (field skipped → clean missing-marker
error) instead of hallucinating. Verified live (lowercase path, fresh job): title
"Демонстрация рендеринга Markdown" (= "Markdown Rendering Demo"), body
translating the actual source, slug `demonstratsiya-renderinga-markdown`.
(`ai_translatable.ex`, `web/editor/translation.ex`)

**Existing installs:** a previously-generated "Translate Publishing Posts"
prompt still carries the old `{{Title}}`/`{{Content}}` placeholders and must be
regenerated (or its placeholders lowercased) to work with the standardized
adapter. The dev DB prompt was updated in place. **Surfaced to Max** — pre-release,
so no production installs are affected yet.

### Bug 2 (latent) — `source_content_blank?/1` checked the viewed language

On a non-primary page it read `socket.assigns[:current_language]` (e.g. an empty
`ru` buffer) instead of the primary, so the confirmation modal falsely warned
"The source content is empty" while the real source (en-US) had content. Same
`current_language`-as-source bug-class Codex flagged in `do_enqueue_translation`,
in a sibling warning helper the Batch-2 fix missed. Now uses
`source_language_for_translation/1` (the primary) consistently. Verified live:
the false warning is gone; only the legitimate "will overwrite" warning remains.
(`web/editor/translation.ex`)

### Also confirmed working in the same live run
- Enqueued job args: `source_lang=en-US` (the **primary**, not the viewed `ru`)
  — the Batch-2 source fix, end-to-end.
- `url_slug` generated **locally** as a Cyrillic→Latin transliteration via the
  slug engine, written to the correct version; editor LiveView live-updates via
  PubSub on completion.
- A misbehaving reasoning endpoint that dumped chain-of-thought into the title
  (>500 chars) was **discarded cleanly** by the content changeset — no
  partial/corrupt write.

## Codex re-review (Batch 4, 2026-06-07) — 3 findings, all verified

- **F3 (Low) — FIXED.** The programmatic bulk API (`build_bulk_translation_params/2`)
  resolved the prompt/endpoint with a bare `Settings.get_setting/1` and **no slug
  fallback**, while the editor used the richer `get_default_ai_prompt_uuid/0`
  (setting → slug). So with the setting unset but the default prompt present,
  the bulk API enqueued `prompt_uuid: nil` and failed. Fixed by moving the
  canonical resolvers (`default_endpoint_uuid/0`, `default_prompt_uuid/0`,
  `default_prompt_exists?/0`) **into `TranslationManager` (domain)** — the
  editor now delegates to them, so both paths share one source of truth and
  can't drift. (`translation_manager.ex`, `web/editor/translation.ex`)
- **F1 (Medium) — SURFACED (core-contract limitation).** The generic
  `Translatable.fetch/2` contract is `(resource_type, resource_uuid)` — there is
  **no version dimension**, so the editor's `current_version` cannot be threaded
  into the job. `fetch/2` re-resolves the active version; on a published-v1 +
  draft-v2 post, translating while viewing the draft targets v1. Read==write
  stays consistent (no corruption) — it just always targets the active version.
  Fixing this needs a core change (carry a version/opaque-key through the job to
  `fetch/2`). **For Max:** want the generic pipeline to support a version/scope
  dimension, or should publishing always translate the active version (and the
  editor reflect that)? Matches the documented v1/v2 residual below.
- **F2 (Medium) — SURFACED + dev fixed.** A "Translate Publishing Posts" prompt
  generated **before** the lowercase standardization still carries
  `{{Title}}/{{Content}}`; `default_prompt_exists?/0` only checks slug presence,
  so the UI hides "Generate Default Prompt" and the stale row keeps hallucinating
  (it predates the fail-closed instruction). The dev DB prompt was lowercased in
  place. **For Max:** pre-release, so no production installs — but if any prompt
  predates this, regenerate it. A guided "your prompt is stale, regenerate?"
  affordance would be the durable fix (deliberately not auto-rewriting a
  possibly-customized prompt).

## Decisions implemented (Batch 5, 2026-06-07) — F1 + F2

Both Codex re-review mediums were turned into decisions (planning-capper
quick-verify on F1) and implemented.

### F2 — regenerate affordance for stale prompts (publishing-only)
`Translation.default_translation_prompt_stale?/0` + `regenerate_default_translation_prompt/0`
(updates the row in place via `PhoenixKitAI.update_prompt/3`); editor shows a
"Regenerate Default Prompt" button when a stale (pre-lowercase) prompt exists.
Live-verified: re-staling the dev prompt surfaced the button; clicking it
repaired the row.

### F1 — version scope through the generic pipeline (CORE + publishing)
Chosen approach: thread an opaque `resource_scope` so a draft v2 translates
independently of the active v1 (was: always the active version). Cross-repo:

- **Core `phoenix_kit`** (commit on core `main`): optional `Translatable.fetch/3`;
  `Translations` normalizes `resource_scope` (JSON-safe string|nil) and keys the
  in-flight **dedup** on it; `TranslateWorker` threads it from args, dispatches
  `fetch/3` when exported (guarded `Code.ensure_loaded?/1`) else `fetch/2`, and
  adds it to lifecycle broadcast payloads. Backward-compatible — catalogue/projects
  keep `fetch/2`; legacy unscoped jobs still run.
- **Publishing**: `AITranslatable.fetch/3` (scope = version number; `fetch/2`
  delegates with nil = active version); editor enqueue passes
  `resource_scope = current_version`; the in-flight-restore query and the
  `{:ai_translation,…}` + `{:translation_started,…}` handlers filter by scope so
  a different-version editor ignores another version's progress/locks.

Per the planning-capper, scope was threaded through the **full** job-identity
surface (dedup + in-flight query + PubSub start payload + completion/fail
filtering), not just enqueue. Live-verified: enqueuing from the v1 editor
produced a job with `resource_scope="1"` that completed and wrote v1; the
adapter unit test pins scope "1"→v1 / "2"→v2 on a two-version post.

**Release gate (extends the existing one):** F1's publishing side needs core's
`fetch/3` — i.e. the **next** core release after 1.7.132. Until then publishing
CI stays red (same hold as the rest of this PR). Pin left at `~> 1.7.132`; Max
cuts the core release + the pin bump.

## Tests added (Batch — 2026-06-07)

- `test/phoenix_kit_publishing/ai_translatable_test.exs` (new) — the four
  `Translatable` callbacks: `fetch/2` (valid / unknown uuid / unknown type),
  `source_fields/2`, `put_translation/4` (pins the locally-generated
  transliterated slug `privet-mir`), `pubsub_topics/1` (pins the exact topic
  the editor subscribes to).
- `slug_helpers_test.exs` — `slugify/2` across all three styles
  (transliterate / unicode / ascii), the 200-char hyphen-boundary cap, blank
  input; `slug_style/0` + `matches_shape?/1` following the
  `publishing_slug_style` setting.
- `translation_manager_bulk_test.exs` (added earlier in the PR) — pins
  `build_bulk_translation_params/2`.
- `editor_translation_test.exs` (new, Batch 4) — `source_content_blank?/1`
  reads the primary language as source on a non-primary page (regression guard
  for Batch-4 Bug 2), and uses the live buffer when viewing the primary.
- `ai_translatable_test.exs` (Batch 4) — `source_fields/2` pins the exact key
  set `["content", "title"]` (lowercase, matching the standardized prompt), the
  regression guard for Batch-4 Bug 1: any casing drift leaves the prompt
  placeholders unrendered.
- `editor_translation_test.exs` (Batch 4) — a prompt↔adapter **contract test**:
  extracts every `{{placeholder}}` from `default_prompt_content/0` (minus the
  core-provided language slots) and asserts it equals the key set
  `source_fields/2` binds. This is the guard that fails the moment the prompt
  and adapter casing drift apart again.
- `ai_translatable_test.exs` — added a slug-conflict test: when another post
  already owns the generated slug in the same group+language, the new
  translation's `url_slug` is omitted and falls back to the post's default slug
  (pins the Batch-1 uniqueness guard).

## Fixed (Batch 3 — Claude post-merge review, 2026-06-07)

Independent Elixir-skill review of the merged surface (full write-up in
`CLAUDE_REVIEW.md`). Three findings + one pre-existing Dialyzer fix:

- **`source_content_blank?/1` still sourced from the viewed language** — residual
  of the Batch-2 "source is always primary" fix. The blank-content confirmation
  warning inspected `current_language || primary`, so on a non-primary page it
  warned about the wrong language (false "empty source" warning, or no warning
  while the real primary source was blank). Now uses
  `source_language_for_translation/1`. (`web/editor/translation.ex`)
- **`url_slug` input `pattern` was hardcoded ASCII** even under the new
  `:unicode` slug style, so the browser rejected a Unicode slug the server
  accepts. Added style-aware `SlugHelpers.html_input_pattern/0` and wired the
  input to it. (`slug_helpers.ex`, `web/editor.ex`)
- **Hardcoded worker-module string** in `in_flight_translation_languages/1`
  (`j.worker == "PhoenixKit.Modules.AI.TranslateWorker"`) → `^inspect(@translate_worker)`
  module attribute so a core rename can't silently break banner restore.
  (`web/editor/translation.ex`)
- **Pre-existing Dialyzer error** (not PR #22 code): dead `|| %{}` guard on the
  always-a-map `post.metadata` in `extract_title/1`, surfaced by `mix precommit`
  (which runs Dialyzer; the PR ran only format/credo/compile). Dropped.
  (`ai_translatable.ex:188`)

Tests: `slug_helpers_test.exs` — `html_input_pattern/0` tracks the
`publishing_slug_style` setting (unicode vs ascii/transliterate).

Verification: `mix precommit` (compile --warnings-as-errors, deps.unlock check,
format --check, credo --strict, **dialyzer**) — 0 errors. `mix test` not
runnable in the review sandbox (no `psql`); precommit was the gate.

## Skipped (with rationale)

- **`slug_style/0` broad `rescue _ ->`** — intentional fail-open to
  `:transliterate`. Narrowing risks letting a transient `Settings`/DB error
  propagate and crash slug generation (which would block post saves). The
  fail-open default is the safer behavior; kept.
- **`pubsub.ex` `post_translations_topic/2` param named `post_slug` but called
  with a uuid** — pre-existing cosmetic naming (not PR #22 code). Verified the
  events DO reach the editor (`broadcast_id == post.uuid`, producer + consumer
  line up). No rename to avoid touching unrelated code.
- **`@spec` on `Publishing.slugify/1`** — agent flagged it missing; it's
  already present (`publishing.ex:410`). No-op.
- **LiveView-level tests** for the new `{:ai_translation, …}` `handle_info`
  clauses and for the Batch-2 source-language fix (Codex suggested asserting
  `do_enqueue_translation` uses the primary as source on a non-primary page).
  These need a full editor mount + Oban; the fix itself is a one-line switch to
  the already-correct `source_language_for_translation/1`, and the adapter +
  bulk-params tests pin the data paths. Worth a future LiveView test; not
  blocking.
- **v1-published + v2-draft regression test** for the Batch-2 version fix
  (Codex suggested it). The fix threads one resolved version through read +
  write; the existing `put_translation` test exercises that path. The explicit
  two-version fixture is a worthwhile future add.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_publishing/ai_translatable.ex` | url_slug uniqueness guard; `:post_slug` on struct; `with` simplification; dead `\|\| %{}` drop; **`source_fields`/`build_params` field keys `Title`/`Content` to match the prompt placeholders (Batch 4 — substitution regression fix)** |
| `lib/phoenix_kit_publishing/web/editor.ex` | `maxlength="200"` on url_slug input; style-aware `pattern` (Batch 3) |
| `lib/phoenix_kit_publishing/web/editor/translation.ex` | source lang = primary (Batch 2 + Batch 3 `source_content_blank?`); `@translate_worker` ref (Batch 3) |
| `lib/phoenix_kit_publishing/slug_helpers.ex` | `html_input_pattern/0` (Batch 3) |
| `test/phoenix_kit_publishing/ai_translatable_test.exs` | new — 7 adapter tests (incl. slug-conflict); pins `source_fields` key casing `["Content","Title"]` (Batch 4) |
| `test/phoenix_kit_publishing/slug_helpers_test.exs` | +6 slug-engine / style tests; +`html_input_pattern/0` (Batch 3) |
| `test/phoenix_kit_publishing/editor_translation_test.exs` | new — `source_content_blank?/1` source-language regression (Batch 4) |

## Verification

- `mix test` (against local core 1.7.131 via temporary path dep, reverted to
  the `~> 1.7.131` Hex pin before commit): **1056 tests, 0 failures.**
- `mix format --check-formatted` clean; `mix credo --strict` clean on changed
  files; `mix compile --warnings-as-errors` clean.
- Codex review: see PR thread.
- Browser smoke: editor renders; `url-slug-input` present with `maxlength=200`.
- Pre-existing log noise (async languages-cache ownership errors, FK-constraint
  fixture warnings) is unrelated to this work.

## Open

None.
