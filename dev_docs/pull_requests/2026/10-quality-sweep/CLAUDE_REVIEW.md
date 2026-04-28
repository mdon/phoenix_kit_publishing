# PR #10 — Elixir/Phoenix-lens review
**Author:** Max Don (mdon)
**Reviewer:** Claude (elixir-thinking + phoenix-thinking + ecto-thinking)
**Date:** 2026-04-28
**Verdict:** ✅ APPROVE (post-merge review) — the production-code
deltas are sound; flagged items are follow-ups, not regressions.

**Update 2026-04-28:** two of the eight follow-ups landed in the
same review pass — see "Landed in this review pass" below.

PR #10 is a Phase 1 + Phase 2 quality sweep + 4 coverage-push batches:
+9324 / -334 across 105 files, 33.34% → 63.79% line coverage. Lib
churn is concentrated in 31 files (1604 / 301), the rest is tests
and dev-docs. This review is scoped to `lib/` deltas (production
behaviour), since the test deltas don't change runtime semantics.

---

## What the PR delivers

- **Errors atom dispatcher** (`errors.ex`, NEW) — 36 atoms + 4
  tagged-tuple shapes, gettext-backed user-facing strings,
  `truncate_for_log/2` cap on unbounded log payloads.
- **Activity logging** (`activity_log.ex`, NEW + 11 context-module
  call sites) — `log_manual/5` + `log_failed_mutation/5` thread an
  audit row through every user-driven CRUD path on
  `Posts`/`Groups`/`Versions`/`TranslationManager`. Failure path
  writes `db_pending: true`.
- **Race fixes** — `DBStorage.upsert_group/1` rewritten as atomic
  `ON CONFLICT DO UPDATE`; `StaleFixer.apply_stale_fix/3` retries
  once on `(group_uuid, slug)` unique-index conflict.
- **PubSub payload trim** — `broadcast_post_created/updated`,
  `broadcast_post_status_changed`, `broadcast_version_created` now
  emit `%{uuid:, slug:}` instead of the full post map.
- **PR #9 follow-ups closed** — `Web.Settings` mount→handle_params,
  three `rescue _` narrowed to `UndefinedFunctionError | ArgumentError`,
  `language_enabled_for_public?/2` renamed to
  `exact_enabled_for_public?/2`, `fix_all_stale_values/0` streams
  posts under `Repo.checkout/1`.
- **`@spec` backfill** across `db_storage`, `pubsub`, `posts`,
  `shared`, `versions`, `groups`, `errors`, `language_helpers`,
  `stale_fixer`, plus dialyzer-clean.
- **`phx-disable-with`** wired on every async / destructive button.

---

## Confirming the green flags

- **PR #9 follow-ups all landed.** Every item I called out in
  `9-fix-issues-6-7-8/CLAUDE_REVIEW.md` is closed:
  - `Web.Settings.mount/3` → `handle_params/3`
    (`web/settings.ex:21-67`) — DB reads moved out of mount,
    subscription stays. Iron-law clean.
  - `LanguageHelpers.reserved_language_code?/1`
    (`language_helpers.ex:170-183`),
    `LanguageHelpers.single_language_mode?/0` (`:191-198`),
    `Web.Controller.Language.valid_language?/1`
    (`web/controller/language.ex:128-133`) — all narrowed to
    `UndefinedFunctionError | ArgumentError`. Genuine bugs propagate.
  - `language_enabled_for_public?/2` →
    `exact_enabled_for_public?/2`
    (`web/controller/translations.ex:127, 164, 234`).
  - Slug-conflict recovery: `StaleFixer.retry_on_slug_conflict/4`
    (`stale_fixer.ex:367-381`) matches the constraint by
    `constraint_name: "idx_publishing_posts_group_slug"`, retries
    once with `post_uuid[0..8]` suffix.
  - `fix_all_stale_values/0` (`stale_fixer.ex:419-431`) wraps the
    per-group post traversal in `Repo.checkout/1` +
    `DBStorage.stream_posts/1`.

- **`upsert_group/1` TOCTOU is genuinely fixed.**
  `db_storage.ex:73-94` replaces the old check-then-act with
  `repo().insert(... on_conflict: {:replace, [...]}, conflict_target:
  :slug, returning: true)`. The replace list excludes `inserted_at`
  and `uuid` (preserved on conflict) and includes `:updated_at` —
  semantically correct. `slug` is the conflict target so it's not in
  the replace list. ✅

- **`ActivityLog.log/1` boundary discipline is right.**
  `activity_log.ex:17-51` distinguishes three classes of failure
  with intent:
  - `Postgrex.Error` (table missing) → silent (don't spam every
    mutation in unmigrated host apps).
  - `DBConnection.OwnershipError` (sandbox cross-process) → silent
    (primary write already succeeded).
  - `:exit` catch (sandbox connection dropped) → silent.
  - **anything else** → `Logger.warning` with `Map.take(attrs,
    [:action, :resource_type, :resource_uuid])` (PII-safe).
  Audit-failure-never-crashes-mutation invariant preserved.

- **PubSub `minimal_payload` is consistent with consumers.** I
  walked every `:post_created | :post_updated | :post_status_changed
  | :version_created` consumer in `lib/`:
  - `web/listing.ex:262-294` — only reads `[:slug] || ["slug"] ||
    [:uuid] || ["uuid"]`, then refetches via
    `Publishing.read_post/4`.
  - `web/index.ex:102-123` — `_post` ignored entirely.
  - `web/post_show.ex:79` — `_group_slug, _post_slug` ignored.
  No internal consumer destructures dropped fields. ✅

- **`maybe_sync_datetime_and_audit/3` consolidation**
  (`posts.ex:1075-1099`) merges what was two separate
  `DBStorage.update_post/2` calls (date sync + audit fields) into
  one. Halves the round-trips per save and keeps `updated_at`
  consistent. The refactor preserves the `nil`-published_at
  short-circuit via `add_datetime_sync_attrs/3`. Clean.

- **`slug_conflict?/1` inspects both keys**
  (`stale_fixer.ex:386-396`). The PublishingPost
  `unique_constraint([:group_uuid, :slug])` declaration puts the
  error on the FIRST key (`:group_uuid`); the helper checks both
  `:slug` and `:group_uuid` and *also* matches by
  `constraint_name`, so a real foreign-key error on `group_uuid`
  doesn't trip the retry path. Good attention to detail.

- **Earmark trust model is documented in code, not just elsewhere.**
  `renderer.ex:203-211` explicitly states `escape: false` is
  intentional, names the implicit precondition (admin-authored
  Markdown only), and points the reader at the next move
  (html_sanitize_ex if untrusted input enters). This is the right
  shape — the assumption travels with the code.

---

## Worth a second look (not blockers)

1. **Privates exposed as `def` `@doc false` for testing.**
   - `Workers.TranslatePostWorker.extract_title/1`,
     `parse_translated_response/1`, `parse_markdown_response/1`,
     `sanitize_slug/1` (`workers/translate_post_worker.ex:373-440`)
   - `StaleFixer.apply_stale_fix/3` (`stale_fixer.ex:325-329`)
   - `Posts.read_back_post/5`, `Posts.update_version_defaults/4`

   The pattern works but compounds — once a private becomes
   `@doc false def` for tests, the next refactor is harder because
   the test now depends on the implementation contract. Cleaner
   alternative: extract the pure transformations
   (`parse_translated_response`, `sanitize_slug`,
   `parse_markdown_response`, `extract_title`) into a small
   intentionally-public helper module (e.g.
   `Workers.TranslatePostWorker.Parsing`) and test that module's
   public API. Tracks as design debt, not a defect.

2. ~~**`Errors.truncate_for_log/2` mixes byte and grapheme units.**~~
   **Landed in this review pass.** `errors.ex` now uses byte_size
   for both the test and the slice, with `clip_to_utf8_boundary/2`
   walking back to the previous codepoint boundary so multibyte
   input can never produce an invalid binary. `@max_log_chars`
   renamed to `@max_log_bytes` to match the unit. Regression test
   added in `errors_test.exs` covering 3-byte UTF-8 input clipped
   on a sub-codepoint boundary.

3. **`collect_legacy_content_promotions/2` adds a query on every
   save.** `posts.ex:1003-1012` issues a `DBStorage.get_content/2`
   on the hot save path even for posts that already have all four
   keys promoted. The intent is one-time-per-row promotion, but
   the query keeps firing forever (it just returns `%{}`). Once
   the activity-log activity for
   `"publishing.content.metadata_promoted"` goes to zero across a
   measurement window, gate this behind a feature flag or an
   explicit one-shot backfill, then remove the path entirely. This
   isn't a regression (the query existed in the broader update
   flow before) — it's a path that will outlive its purpose.

4. ~~**`broadcast_post_*` payload contract is a public-API
   behaviour change.**~~ **Landed in this review pass.** Added a
   CHANGELOG `Unreleased` section with the payload-contract change
   called out under "Changed" and an explicit note that host apps
   subscribing to `PubSub.posts_topic/1` must update their pattern
   matches. A `:contract_v2` topic suffix or major-version bump
   would be the more rigorous move if downstream subscribers are
   known to exist; the CHANGELOG note is the minimum bar.

5. **`StaleFixer.apply_stale_fix/3` retry is bounded but not
   convergent.** `stale_fixer.ex:367-381` retries once with
   `slug-#{post_uuid[0..8]}`. Two genuinely concurrent stale-fixer
   passes on different posts that *both* end up needing the same
   suffix is theoretical (UUIDv7 8-char prefix collision is
   ~10^-19 at this scale) — but the retry doesn't bound *N>2*
   concurrent fixers on the *same* post racing the same suffix.
   The comment at `:194-201` says "second slug collision after the
   suffix — practically impossible with a UUIDv7 prefix" which is
   a stronger claim than the code makes (the suffix uses the
   *post_uuid*, so two passes on the same post DO derive the same
   suffix). In practice the second pass would observe the now-
   suffixed slug and skip on `attrs == %{}`, so the convergence
   argument holds — but it lives in *the rest of the system*, not
   in `retry_on_slug_conflict/4`. Worth a test that exercises the
   "two fixers, same post" path explicitly (it's currently only
   covered by the synthetic test at
   `stale_fixer_slug_retry_test.exs`).

6. **`Posts.actor_uuid_for_log/2` is transitional duplicate
   state.** `posts.ex:289-292`: actor preference is "explicit opts
   > scope-derived audit_meta". The comment explicitly tags this
   as awaiting a future C10 sweep that switches LV callers to opts.
   Worth tracking as a single ticket so the transitional path
   doesn't outlive its TODO.

7. ~~`list_groups/1` spec / impl mismatch.~~ **Retracted.** Re-read
   `db_storage.ex:57-68` — `list_groups/1` filters by exact
   `g.status == ^status` for any non-nil string and returns all
   groups for `nil`. The `String.t() | nil` spec is accurate and
   the docstring already says "Filters by status (default: active
   only)." I had conflated this with `list_posts/2`'s
   `filter_by_status/2`, which DOES have a 3-case + fallback shape
   (`"published" | "draft" | "trashed" | _`); that one is fine
   because the fallback explicitly means "non-trashed, any status"
   and the docstring documents it.

---

## Pre-existing, not introduced by this PR

- **Other LiveView mounts may still have residual DB work.** PR
  #9's review flagged `Web.Settings` specifically — that's now
  fixed. A wider sweep of `web/listing.ex`, `web/index.ex`,
  `web/post_show.ex`, `web/edit.ex`, `web/new.ex`, `web/preview.ex`
  for the same iron-law violation would close the chapter; this PR
  didn't take that on, and the call sites I sampled in `mount/3`
  during the review are subscription-only. Worth a confirming
  audit, not a defect call against this PR.

- **`PhoenixKit.Activity` coupling via `Code.ensure_loaded?/1` on
  every log call.** `activity_log.ex:18` re-runs the load probe per
  invocation. This is an existing pattern in the module and not
  worse than before; if the publishing module ever ships with the
  Activity context bundled (rather than optionally), the probe can
  be lifted to a module-level constant via
  `@activity_loaded Code.ensure_loaded?(PhoenixKit.Activity)`.

---

## On the coverage push

Batches 4–8 push 33.34% → 63.79% line coverage with 526 new
tests. The PR description's diminishing-returns table (Batch 5
+11.5pp / Batch 8 +0.6pp) is honest about hitting a no-deps
ceiling, and the "What's still uncovered" inventory correctly
identifies the genuinely external surfaces (Oban + AI HTTP, multi-
process collaborative paths, V1 legacy SQL bypass). Two
observations:

- **Stubbing Phoenix.Presence in `test_helper.exs`** for the
  PresenceHelpers tests (Batch 5) is the right call — the
  alternative is mocking, which the project's AGENTS.md forbids.
  The stub Storage tables for the editor mount are also
  proportionate.
- **`fake_scope/1` returning a real `%Scope{user: %User{}}` struct**
  rather than a stub map is a quietly important detail —
  `Scope.user_uuid/1` pattern-matches, so a stub would have
  silently coerced to nil and missed the actor-uuid threading
  paths. Good catch.

---

## Verdict

**APPROVE (post-merge).** The structural deltas are sound: the
`upsert_group` race is genuinely closed, the activity-log boundary
preserves the audit-never-crashes invariant, the PubSub payload
trim is internally consistent, and every PR #9 follow-up I'd
flagged is addressed. The flagged items are either design-debt
follow-ups (tests-via-implementation, transitional duplicate
state, query-after-purpose) or external-API CHANGELOG hygiene —
none of them are runtime correctness concerns.

The PR's headline claim of "same standard as the other completed
modules" reads true on the lib/ side. Coverage is honest about
its ceiling.

---

## Landed in this review pass

- [x] **`Errors.truncate_for_log/2` UTF-8 boundary fix** —
      `errors.ex` rewritten to use byte_size consistently with a
      `clip_to_utf8_boundary/2` walk-back; constant renamed to
      `@max_log_bytes`. Regression test in `errors_test.exs`.
- [x] **CHANGELOG `Unreleased` entry** — calls out the PubSub
      payload contract change for host-app subscribers, plus the
      rest of the PR's user-visible deltas.

## Suggested follow-up tickets (Max to handle)

- [ ] **Extract pure parse helpers from `TranslatePostWorker` into
      a `Parsing` submodule** (`extract_title`,
      `parse_translated_response`, `parse_markdown_response`,
      `sanitize_slug`) and revert the `@doc false def` exposure.
- [ ] **Sunset the legacy-content-promotion query** once the
      `publishing.content.metadata_promoted` activity goes to zero
      over a measurement window. Replace with a one-shot
      migration; remove `collect_legacy_content_promotions/2` and
      the merge in `update_version_defaults/4`.
- [ ] **Iron-law audit of remaining LiveView mounts** — confirm
      `web/listing.ex`, `web/index.ex`, `web/post_show.ex`,
      `web/edit.ex`, `web/new.ex`, `web/preview.ex` only do
      subscription work in `mount/3`. PR #9 covered settings; this
      closes the chapter.
- [ ] **Concurrent-fixer test for `apply_stale_fix/3`** —
      explicitly cover two fixers on the *same* post racing the
      same suffix, to pin the convergence argument that currently
      lives implicitly in "the rest of the system".
- [ ] **Converge `Posts.actor_uuid_for_log/2` on opts-only** once
      the C10 LV-caller sweep lands. Drop the `audit_meta` fallback
      then.
- [ ] **Lift `Code.ensure_loaded?(PhoenixKit.Activity)` to a
      module attribute** if the Activity context becomes a hard
      dependency — saves a dispatch per mutation.
