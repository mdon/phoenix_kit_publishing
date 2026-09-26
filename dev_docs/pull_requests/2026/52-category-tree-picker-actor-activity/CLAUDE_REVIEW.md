# PR #52 Review — Category pickers on core's TreePicker; actor and activity through core

**Author:** Max Don <max@don.ee>
**Reviewer:** Claude (Anthropic)
**Status:** Merged — post-merge review, fixes applied on `main`
**Commit:** `8c311a2`
**Date:** 2026-09-26

---

## Verdict

Sound. The PR moves the actor lookup to `PhoenixKitWeb.Actor` and the
activity log's error handling to core's `Activity.log/1`. It replaces the
category parent selects with core's `TreePicker`, puts every admin page on
the core header trail (`page_section` / `page_crumbs` / `page_title`), and
raises the core floor to 2.38.0. I found one functional gap, in the editor's
header trail, and fixed it. The other findings are notes on residual
behaviour, recorded so nobody "fixes" them by accident.

### What I checked against the source, not the PR description

1. **`PhoenixKitWeb.Actor.uuid/1` covers every call site it replaces.** It
   takes a socket, a `Plug.Conn`, a `%Scope{}` or an assigns map. It reads
   the scope first, then the bare `:phoenix_kit_current_user`. The
   controller's comment gate (`is_nil(Actor.uuid(conn))`) is therefore no
   stricter than before. The editor's `Translation.current_user_uuid/1`,
   which crashed on a scope with a `nil` user, is gone.
2. **Core's `Activity.log/1` never raises.** In core 2.40.1 it rescues any
   exception and catches `:exit` / `:throw`. The local rescue ladder in
   `ActivityLog.log/1` was redundant. One behaviour change: core logs a
   `Logger.warning` where the old wrapper was silent on `Postgrex.Error` and
   `DBConnection.OwnershipError`. That is acceptable, because a host missing
   the activities table should see it.
3. **Category move/edit.** `confirm_move` and `save` read the server-side
   pick (`move.pick`, `parent_pick`), never the posted hidden input. A
   rename on a form opened before someone else moved the category does not
   re-file it, because an edit sends `parent_uuid` only when the picker
   changed. `move_category/3` asks for `"position" => :append`, and
   `update_category/3` resolves that under the group lock
   (`resolve_position/2`), so two concurrent moves under one parent cannot
   take the same slot. A non-uuid parent is refused in `validate_parent/3`
   and in `get_category/1` instead of raising `Ecto.Query.CastError`.
4. **The pickers' trees are built in memory.** `Tree.from_flat/2` and
   `Tree.prune/2` run over the category list the page already holds. This
   replaces a `subtree_uuids/2` query per dialog open, and the context still
   refuses a cycle.

## Findings

### IMPROVEMENT - MEDIUM — Editor post crumb kept the old title after a save — FIXED

`Editor.assign_page_trail/2` ran only in `handle_params` (new/existing
post). A save that stays on the same edit URL skips `handle_params`, because
`Persistence.maybe_patch_edit_url/2` does not patch an unchanged URL. So
after a rename the header read `Publishing / <group> / <old title> / Edit`
until the page was reloaded. A collaborator's save, reloaded through
`do_reload_post/1`, had the same problem.

**Fix.** `assign_page_trail/2` is now `@doc false def` and is re-derived
from the saved post on each post-save path in `Web.Editor.Persistence`:
`handle_post_update_result/4` (create, new translation, new version),
the in-place save and `do_reload_post/1`. **Test:** `header_trail_test.exs`
"a rename saved on the same URL re-titles the post crumb". It fails without
the fix. It uses a real user row, because a save stamps the
`updated_by_uuid` FK and `fake_scope/0`'s uuid does not exist.

### NITPICK — The Move dialog's tree is a snapshot — NOT FIXED

`open_move` builds `move.tree` once. If a category is added or moved while
the dialog is open, the picker does not show it. The context still validates
the target (existence, same group, no cycle), so the worst case is a
refusal flash. Refreshing it would mean re-pruning on every `reload_tree/1`,
which is not worth it for a modal that stays open a few seconds.

### NITPICK — Core's activity logger is louder than the old wrapper — NOT FIXED

See point 2 above. Test runs against a DB without `phoenix_kit_activities`
now print a warning per mutation, where the old wrapper was silent. This is
intentional in core, and nothing is done here.

## Validation

`mix precommit` is clean. `mix test` passes: 1801 tests, 0 failures. In a
20-run stability loop, 19 runs were clean and 1 run had a single failure
that I could not reproduce in the next 16 runs. The output of that run was
not captured, so I can't name the test. This matches the sandbox and
activity-log timing flake already documented in AGENTS.md.
