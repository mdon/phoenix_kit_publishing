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
- `ai_translatable_test.exs` — added a slug-conflict test: when another post
  already owns the generated slug in the same group+language, the new
  translation's `url_slug` is omitted and falls back to the post's default slug
  (pins the Batch-1 uniqueness guard).

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
| `lib/phoenix_kit_publishing/ai_translatable.ex` | url_slug uniqueness guard; `:post_slug` on struct; `with` simplification |
| `lib/phoenix_kit_publishing/web/editor.ex` | `maxlength="200"` on url_slug input |
| `lib/phoenix_kit_publishing/web/editor/translation.ex` | source lang = primary (Batch 2) |
| `test/phoenix_kit_publishing/ai_translatable_test.exs` | new — 7 adapter tests (incl. slug-conflict) |
| `test/phoenix_kit_publishing/slug_helpers_test.exs` | +6 slug-engine / style tests |

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
