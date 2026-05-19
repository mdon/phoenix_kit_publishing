# FOLLOW_UP — PR #16 (Phase 2 quality sweep)

Triaged 2026-05-19 against the post-merge state.

`CLAUDE_REVIEW.md` verdict was APPROVE. Two quality-blocking findings
(1 and 3), a `/simplify` cleanup, and the full `mix precommit` gate
(including fallout from the `phoenix_kit 1.7.114` upgrade) were fixed
in post-merge passes; the rest are non-blocking observations.

## Fixed (post-merge — 2026-05-19)

- **Finding 1 — `do_unpublish_post/3` missing the post-row lock.**
  `do_publish_version/4` took a `SELECT … FOR UPDATE` lock but the
  unpublish path did not, so a concurrent publish/unpublish could still
  interleave on `active_version_uuid`. Added the same lock to the
  unpublish transaction. Commit `de57ca4`.

- **Finding 3 — `find_by_previous_url_slug/3` surfaced unpublished
  posts.** The PR's `(v.uuid == p.active_version_uuid or
  is_nil(p.active_version_uuid))` filter let a public 301-redirect
  resolve onto a never-published post that then 404s. Tightened to
  active-version-only, rewrote the `@doc`, added a regression test
  ("returns nil for an unpublished post even if previous_url_slugs
  matches"). Commit `de57ca4`.

- **`/simplify` cleanup — `lock_post!/2` extraction.** Applying Finding 1
  left the `FOR UPDATE` block byte-identical in two places; a
  three-agent review pass flagged that the per-post serialization is
  only correct while both queries stay identical. Extracted a shared
  `defp lock_post!/2` helper so the invariant is structural, not
  comment-enforced. Commits `332c9fa`, `c7e754b`.

- **`mix precommit` — `handle_event/3` clause grouping.** The PR
  inserted `clear_translation_unguarded/1` between two `handle_event/3`
  clauses, tripping the "clauses should be grouped together" warning
  (fails `--warnings-as-errors`). Relocated the helper below the last
  `handle_event` clause. Commit `3f4d377`.

- **`module_assigns` undefined-attribute warnings** (`html.ex` ×3) —
  RESOLVED by the `phoenix_kit 1.7.114` upgrade. PR #16's Batch D
  (`f63311b`) switched to a generic `:module_assigns` attr that
  "pairs with phoenix_kit core commit `b17b96b7`"; `1.7.113` (then the
  latest) didn't carry it. `1.7.114` now declares `attr :module_assigns,
  :map` and flattens it into the host layout's assigns — the three
  `compile --warnings-as-errors` warnings clear with no publishing-side
  change. (Was previously deferred pending this release.)

- **`mix precommit` restoration after the `1.7.114` upgrade.** The
  bump pulled a newer Elixir / credo / dialyzer, which surfaced latent
  issues unrelated to the review findings:
  - *format* — the newer formatter rewraps long function heads/calls;
    `mix format` swept seven files (`posts.ex`, `listing.ex`,
    `publishing.ex`, `listing_cache.ex`, `mapper.ex`, `mix.exs`, the
    exposure test).
  - *credo --strict* — `create_post_with_timestamp_retry/9` (added by
    PR #16) tripped `FunctionArity` (max 8) and `CondStatements`. The
    eight inputs are invariant across the retry recursion — only
    `attempt` changes — so they were bundled into a single context
    map (arity 9 → 2) and the one-condition `cond` became an `if`.
  - *dialyzer* — two provably-dead `|| fallback` nil-branches that the
    tighter upstream type specs exposed: `current_language || ""` in
    `controller.ex` and `updated_post.language || …` in
    `persistence.ex`. Both left sides are always `binary()`; the dead
    fallbacks were dropped.
  Commit `6590d39`. `mix precommit` (compile, deps, format, credo,
  dialyzer) is fully green.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_publishing/versions.ex` | Lock unpublish transaction; extract `lock_post!/2` shared by both publish + unpublish |
| `lib/phoenix_kit_publishing/db_storage.ex` | `find_by_previous_url_slug/3` scoped to active version; `@doc` rewrite |
| `lib/phoenix_kit_publishing/web/editor.ex` | Moved `clear_translation_unguarded/1` out of the `handle_event/3` clause group |
| `lib/phoenix_kit_publishing/posts.ex` | `create_post_with_timestamp_retry` arity 9 → 2 (context map); `cond` → `if`; format |
| `lib/phoenix_kit_publishing/web/controller.ex` | Dropped dead `current_language || ""` fallback |
| `lib/phoenix_kit_publishing/web/editor/persistence.ex` | Dropped dead `updated_post.language || …` fallback |
| `mix.exs`, `listing.ex`, `publishing.ex`, `listing_cache.ex`, `mapper.ex`, exposure test | `mix format` sweep (newer formatter) |
| `test/phoenix_kit_publishing/integration/db_storage_url_slug_lookup_test.exs` | Regression test for unpublished-post previous-slug lookup |
| `dev_docs/.../16-phase-2-quality-sweep/CLAUDE_REVIEW.md` | Review record |

## Verification

- `mix precommit` fully green after the `phoenix_kit 1.7.114` upgrade —
  `compile --force --warnings-as-errors`, `deps.unlock --check-unused`,
  `format --check-formatted`, `credo --strict` (no issues), `dialyzer`
  (0 errors).
- Test suite not executed in the review environment (no PostgreSQL);
  existing `find_by_previous_url_slug/3` tests all publish before
  lookup, so the Finding 3 tightening keeps them green. The PR's own
  run reports `mix test` green.

## Open

- **`maybe_rewrite/2` host adoption** — non-root workspace-prefix
  routing is inert until the host app calls the new `/2` arity.
- **`Web.Settings.terminate/2` missing `@impl true`** — one-line
  consistency nit vs. `Index`/`PostShow`.
- **Read-path write in `find_by_url_slug/3`** — documented best-effort
  collision self-healing; will raise on a read-only replica connection.
