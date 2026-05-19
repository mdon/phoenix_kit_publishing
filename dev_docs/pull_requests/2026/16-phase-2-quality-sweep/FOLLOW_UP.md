# FOLLOW_UP — PR #16 (Phase 2 quality sweep)

Triaged 2026-05-19 against the post-merge state.

`CLAUDE_REVIEW.md` verdict was APPROVE. Two quality-blocking findings
(1 and 3) plus a `/simplify` cleanup and a `mix precommit` warning were
fixed in post-merge passes; the rest are non-blocking observations.

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

## Deferred (with rationale)

- **`module_assigns` undefined-attribute warnings** (`html.ex` ×3).
  PR #16's Batch D (`f63311b`) deliberately switched to a generic
  `:module_assigns` attr that "pairs with phoenix_kit core commit
  `b17b96b7`". The latest *published* `phoenix_kit 1.7.113` does not
  carry that commit — its `app_layout/1` declares a fixed attr list
  with no `module_assigns`. Not fixable in the publishing repo alone.
  **Maintainer decision: wait for the next `phoenix_kit` release** that
  includes `b17b96b7`; the warnings then clear with no publishing-side
  change. Until then `mix precommit` fails on these three (plain
  `mix compile` passes — warnings only).

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_publishing/versions.ex` | Lock unpublish transaction; extract `lock_post!/2` shared by both publish + unpublish |
| `lib/phoenix_kit_publishing/db_storage.ex` | `find_by_previous_url_slug/3` scoped to active version; `@doc` rewrite |
| `lib/phoenix_kit_publishing/web/editor.ex` | Moved `clear_translation_unguarded/1` out of the `handle_event/3` clause group |
| `test/phoenix_kit_publishing/integration/db_storage_url_slug_lookup_test.exs` | Regression test for unpublished-post previous-slug lookup |
| `dev_docs/.../16-phase-2-quality-sweep/CLAUDE_REVIEW.md` | Review record |

## Verification

- `mix compile` clean for all post-merge edits.
- `mix precommit` — `handle_event/3` warning resolved; three
  `module_assigns` warnings remain (deferred, see above).
- Test suite not executed in the review environment (no PostgreSQL);
  existing `find_by_previous_url_slug/3` tests all publish before
  lookup, so the Finding 3 tightening keeps them green. The PR's own
  run reports `mix test` green.

## Open

- **`module_assigns` warnings** — blocked on a `phoenix_kit` release
  carrying core commit `b17b96b7`. Re-run `mix precommit` after the
  next dependency bump; no code change expected.
- **`maybe_rewrite/2` host adoption** — non-root workspace-prefix
  routing is inert until the host app calls the new `/2` arity.
- **`Web.Settings.terminate/2` missing `@impl true`** — one-line
  consistency nit vs. `Index`/`PostShow`.
- **Read-path write in `find_by_url_slug/3`** — documented best-effort
  collision self-healing; will raise on a read-only replica connection.
