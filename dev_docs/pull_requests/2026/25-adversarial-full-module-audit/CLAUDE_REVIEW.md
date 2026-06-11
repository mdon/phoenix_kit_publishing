# CLAUDE_REVIEW — PR #25 (Adversarial full-module audit)

Reviewed the merged diff (`gh pr diff 25`, 64 files, +2113/−583) across five subsystem
clusters (caching/concurrency, posts/versions/publishing, routing/controller/slug,
editor LiveView, rendering/page-builder). The audit is overall solid — H6 read-only
guards are comprehensive, the M1–M4/M6/L1–L4/L11 fixes are correct, and lock
acquire/release stays balanced. The findings below are what's left to fix.

---

## High

### H-A · `:cache_changed` handler is a self-sustaining broadcast storm (M7 regression) — ✅ FIXED
> Fixed in follow-up (see **Follow-up fixes** at the bottom for the full implementation).
> The listing handler now **invalidates** (erases) the node-local term instead of
> regenerating; mutation sites are the only `:cache_changed` announcers; read-miss paths
> repopulate silently. Two regression tests in `listing_live_test.exs` pin the contract.

`web/listing.ex:331` — the `handle_info({:cache_changed, group_slug}, …)` handler calls
`ListingCache.regenerate/1`. That goes `do_regenerate → do_regenerate_existing_group`,
which **unconditionally re-broadcasts** at `listing_cache.ex:200`
(`PublishingPubSub.broadcast_cache_changed/1`). The Listing LiveView is itself subscribed
to `cache_topic(group_slug)` (`listing.ex:631`), and `Manager.broadcast` is plain
`Phoenix.PubSub.broadcast/3`, which delivers to the sender. So:

```
mutation → :cache_changed → handler → regenerate/1 → broadcast :cache_changed → handler → … (∞)
```

Each iteration runs a full `DBStorage.list_posts_for_listing/1` query + two
`:persistent_term.put`s (each a global GC pass) + a cluster-wide broadcast. With N admin
Listing views mounted for the group (across all nodes), every round fans out to all N,
each of which re-broadcasts → multiplicative storm. This pegs CPU/DB and directly defeats
the L12 "cut persistent_term churn" goal.

**Why the suite is green:** the regression test `listing_live_test.exs:195` does
`send(view.pid, {:cache_changed, slug})` then `render(view)`. FIFO mailbox order means the
`render` reply is delivered before the first *re-broadcast* `:cache_changed` is processed,
so the assertion passes — then the view loops forever in the background until test teardown
kills it. The test only ever proves one render round-trip; it cannot observe the loop.

**The obvious fix is insufficient.** Swapping to `regenerate_if_not_in_progress/1` does
**not** break the loop — that path also re-broadcasts (`load_into_memory_from_db`,
`listing_cache.ex:392`). The ETS lock only dedupes *concurrent* regens on one node; the
loop here is *sequential* (release lock → next queued `:cache_changed` re-acquires → re-broadcast).

**Fix:** regeneration triggered by *receiving* `:cache_changed` must not re-announce
`:cache_changed`. Concretely, one of:
- Add a non-broadcasting path — `regenerate(group_slug, broadcast: false)` (or a private
  `regenerate_local/1`) — and call it from the handler; or
- In the handler, **erase** the stale local term (`:persistent_term.erase`) and
  `refresh_posts/1` (which reads the DB directly), letting the next *public* read lazily
  regenerate once. No re-broadcast from the handler ⇒ no loop.

Root-cause note: broadcasting `:cache_changed` from inside *regeneration* conflates "data
mutated" with "a node refreshed its local copy." Only mutation sites should emit
`:cache_changed`; regeneration should be silent.

### H-B · M7 cross-node invalidation is incomplete for nodes without a mounted admin view
Even setting H-A aside, the **only** subscriber that refreshes a node's node-local
`:persistent_term` on `:cache_changed` is the admin Listing LiveView. The public read path
(`ListingCache.read/1`) only regenerates on a **miss** — a stale-but-present term is a
*hit* and is served as-is. There is no TTL / `generated_at` max-age check in `read/1`.

So on a 2+ node cluster, a mutation on node A leaves node B's term stale, and unless node B
happens to have an admin Listing page open for that group, **public reads on node B serve
stale listing data indefinitely.** "M7 cross-node cache invalidation" only holds for nodes
that happen to have the admin listing mounted.

**Fix:** make invalidation independent of a mounted LiveView — e.g. a lightweight always-on
per-node subscriber (in the supervision tree) that *erases* the local term on
`:cache_changed`, and/or add a max-age check against `cache_generated_at/1` in `read/1`.
(Pairs naturally with H-A: the subscriber erases, never re-broadcasts.)

---

## Medium

### M-A · Multi-line single-backtick code span renders a component LIVE (XSS-class, M11/M12)
`renderer.ex:55` — `@code_region_regex`'s single-backtick branch is `` `[^`\n]*` ``, which
excludes newlines, so it does **not** match an inline code span that wraps a line break.
CommonMark/Earmark *do* treat such a span as code, but `escape_code_regions/1` leaves it
un-escaped, then `@component_block_regex` matches it and renders the component live.
Verified end-to-end:

```elixir
Renderer.render_markdown(~s|`<CTA action="/evil">\nClick</CTA>`|)
# => …<div class="unknown-component">Click</div>…   # executed, not shown as code
```

This is exactly the bug class M10–M12 set out to close. The mask regex and Earmark's code
detection must agree or a component slips through.
**Fix:** allow a newline in the single-backtick branch (e.g. `` `[^`]*` `` with `/s`), or
explicitly route multi-line spans through fences and add a test for this case.

---

## Low

- **`renderer.ex:382` — code spans double-escape author entities.** `escape_code_regions/1`
  does an unconditional `String.replace("&", "&amp;")`, so `` `a &amp; b` `` renders as
  `a &amp; b` (literal) instead of `a & b`. Guard the ampersand: `~r/&(?!#?\w+;)/`.

- **`web/controller.ex:363` (listing branch) — duplicated `page` query param on 301.**
  The listing `canonical_url` already embeds pagination (`/blog?page=2`); routing it through
  `redirect_301/2` → `with_query_string/2` then re-appends the whole `conn.query_string`,
  emitting `/blog?page=2&page=2`. Not a loop (language gate stops the 2nd hop), but a
  malformed canonical. Drop keys already present in the target URL, or pass the
  already-canonical listing URL straight to `redirect(to:)` without re-appending.

- **`web/editor.ex:629` — `regenerate_slug` lacks the `readonly?` guard.** Every sibling
  mutating event short-circuits on `readonly?`; this one doesn't. It can't escalate to a
  write (save/autosave/preview each re-check `readonly?`), so impact is only a dirty local
  buffer for a spectator — but add the guard for consistency with the H6 pattern.

- **`web/editor/forms.ex:313` / `editor.ex` `update_meta` — truncation warning still
  droppable.** The slug-truncation warning is only re-asserted when `update_meta` params
  carry a `"title"` key; since `update_meta` `clear_flash`es up front, an `update_meta`
  whose params omit `title` wipes the warning while the title is still over-cap — the very
  failure the new comment claims fixed. Situational (title is usually in the same
  `phx-change` form). Re-assert from current form state regardless of which field fired.

- **`web/editor.ex:223` — `reset_translation_state` drops the lock mid-translation on
  version switch.** It unconditionally clears `translation_locked?`/`ai_translation_progress`
  on every `handle_params` but leaves `ai_translation_total`/`status` stale. Switching away
  from and back to a version while AI is writing it drops the lock (lost-update window) and
  leaves `maybe_finalize_translation` unable to finalize cleanly. Narrow edge case; a
  per-version in-progress check on `handle_params` is the clean fix.

- **`posts.ex` `record_previous_url_slug` — explicit nil `url_slug` clears the slug while
  recording it as "previous."** If `params` carries `"url_slug" => nil` (key present, value
  nil), `resolved_url_slug` becomes nil, the old slug is recorded as previous, and the
  content row's `url_slug` is blanked. Unreachable from the form today (always a string), but
  the writer should treat nil/blank incoming `url_slug` as "keep existing," not "clear."

- **`publishing.ex:188` `clear_translation` defdelegate — trailing-default signature trap.**
  `TranslationManager.clear_translation/5` now has `version \\ nil, opts \\ []`. An old
  4-arg call `clear_translation(g, u, l, [actor_uuid: x])` would silently bind the keyword
  list to `version` and no-op the clear. No current caller does this (verified), but
  consider making `opts` keyword-only or guarding `is_integer(version) or is_nil(version)`.

- **Stale doc comments after L12.** `listing_cache.ex:433` and `web/settings.ex:133` still
  say "all three prefixes"; L12 left two. Change "three" → "two."

---

## Verified correct (no action)

- **H1** render cache + **M8** `LockTableOwner` both supervised in `Publishing.children/0`.
- **M8** crash-proof guard: `regenerate_if_not_in_progress/1` rescues `ArgumentError`,
  recreates the table, returns `:already_in_progress` (a vanished table can't 500 a read).
- **L10** token-scoped release: `:ets.select_delete` on `{group, {:_, token}}` is a correct
  no-op once superseded; `take_over_stale_lock/4` compare-and-deletes the exact `{ts, token}`.
- **M14** remote-pid presence: `meta_alive?/1` short-circuits `node(pid) != node()` before
  `Process.alive?/1`, dodging the `ArgumentError` on remote pids.
- **L7** `erase_all/0` snapshots `:persistent_term.get()` before erasing; wired to the toggle.
- **M1** retry matches by constraint *name* (`idx_publishing_posts_group_date_time_unique`),
  correctly excluding the slug-uniqueness violation; convergence bounded (60 in-tx + 5 whole-tx).
- **M2** `timestamp_slot_taken?/3` drops the `is_nil(trashed_at)` filter so trashed rows in
  the unique index are seen — fixes the non-convergence loop.
- **M3/L4** post-update and blank-version writes are single transactions with rollback.
- **M4** `deferred_publish_status/1` drops `"published"`; status is only set inside
  `publish_version`'s locked tx — closes the "admin published / public 404" split.
- **M6** cross-group UUID access rejected (`post[:group] == group_slug`).
- **L1** `switch_version` parses defensively (no crash on junk).
- **L3** unpublish pre-lock re-read fetches the fresh active version (no preload → refetch).
- **L11** `db_exception?/1` whitelists real DB exceptions; everything else re-raised.
- **H3** host-route-hijack: `localized_locale?/0` tightens segment-0 to enabled languages;
  the `method not in ["GET","HEAD"]` gate passes POST/PUT through; precedence + rescue/exit
  fallbacks correct.
- **H4/H5** redirect loops: `canonical_redirect?/4` language gate goes false after the first
  hop, so the appended query string can't re-trigger; future-dated timestamp guard prevents
  the two-language 302 ping-pong; `:module_disabled` short-circuits before the catch-all.
- **M13** incumbent-wins (`asc: p.uuid`) + `claims_other_posts_previous_slug?` (fails open,
  advisory) vs `url_slug_exists?` (fails closed); reserved route words now on both slug paths.
- **H6** all mutating editor `handle_event`/`handle_info` paths guard `readonly?` (save,
  update_meta/content, clear_translation, clear_featured_image, media_selected, autosave,
  translate_*, confirm_translation, create_version_from_source, toggle_version_access, …) —
  except `regenerate_slug` (Low above).
- **L9** unresolved `{{placeholder}}` preserved; **L6** group-rename invalidates the *old*
  slug's term; **H7** `<Hero>`/`<Page>` resolver clauses + scaffolding removed cleanly (no
  dangling refs); **humanize_field** acronyms ("URL slug", "SEO title", "OG image") correct.

---

## Suggested priority
1. **H-A** — production infinite loop / cluster broadcast storm. Fix before any release;
   add a test that asserts the view does **not** re-emit `:cache_changed` (e.g. subscribe a
   probe to `cache_topic` and assert no second message after handling one).
2. **H-B** — clustering correctness; fold the per-node invalidator in with H-A's fix.
3. **M-A** — XSS-class component execution via multi-line code span.
4. Low items as cleanup.

---

# Follow-up fixes (committed)

H-A was fixed in a follow-up, then hardened after a high-effort recall review of the fix
itself. **Note:** the H-A fix also resolves **H-B** — the listing cache is now invalidated
on every node from a cluster-wide signal, independent of whether an admin LiveView is mounted
(any node's stale term is erased and the next public read rebuilds it fresh). The chain of
reasoning matters, so it's recorded here.

## Iteration 1 — the obvious fix, and why it was insufficient

First attempt: thread a `:broadcast` option through `regenerate/2` /
`regenerate_if_not_in_progress/2` and have the `:cache_changed` handler call
`regenerate_if_not_in_progress(slug, broadcast: false)` — regenerate locally, don't re-announce.

This breaks the loop, but a self-review surfaced that it was still wrong in three ways:

- **Stale-hit window (correctness).** `regenerate_if_not_in_progress/2` can return
  `:already_in_progress` and *skip* the rebuild. `read/1` serves a stale-but-present term as a
  **hit** (it only regenerates on `:not_found`), so under a concurrent read-miss + mutation the
  node-local cache could stay stale with no self-heal until the next mutation. The old
  unconditional `regenerate/1` never had this window.
- **Double DB read (efficiency).** The handler regenerated the term (one DB read) *and* called
  `refresh_posts/1`, which reads the DB again — and the admin view renders from the DB, never
  from the term, so the regenerate served only the public cache.
- **Spurious announce (altitude).** The read-miss repopulation path still broadcast
  `:cache_changed`, i.e. a cold cache (nothing changed) announced "data changed" cluster-wide.

## Iteration 2 — the right-depth fix (committed)

The unifying insight: **regeneration should never announce; only data mutations should.** A
consumer reacting to `:cache_changed` should *invalidate*, not regenerate.

| Change | File | Resolves |
|---|---|---|
| Handler calls `ListingCache.invalidate/1` (cheap erase) instead of regenerating. Next public read-miss rebuilds fresh, silently. | `web/listing.ex` | stale-hit + double-read + storm |
| Read-miss repopulation goes silent (`broadcast: false`). | `listing_cache.ex` (`read/1` miss), `web/controller/post_fetching.ex` | spurious announce; **required** so invalidate-on-handler doesn't thrash against a read-miss broadcast |
| `regenerate/2` keeps the `:broadcast` option; mutation sites use the default (`true`) and are now the **only** announcers. | `listing_cache.ex` | makes the announce contract explicit |
| Dead `load_into_memory_from_db/1` (unguarded, uncapped, unconditional-broadcast footgun) collapsed into a thin alias over `regenerate/2`. | `listing_cache.ex` | latent re-entry of the same storm + the unknown-slug `:persistent_term` leak |

Resulting steady state:
`mutation → regenerate + announce → every node's listing view invalidates its term → next
public read on each node misses → rebuilds fresh, once, silently.` No storm, no stale-hit
window, no thrash, no redundant reads — and stale terms are erased cluster-wide regardless of
whether a node has an admin view open (**H-B**).

Why `invalidate` beats either regenerate variant in the handler:
- vs unconditional `regenerate(broadcast: false)` — that rebuilds in every mounted admin view
  (N DB reads + N global `:persistent_term` GC passes per event); `invalidate` is O(1) and
  idempotent across views.
- vs lock-deduped `regenerate_if_not_in_progress(broadcast: false)` — that can skip and leave a
  stale hit; a missing term always rebuilds.

## Self-review findings & disposition

A high-effort, recall-biased review (7 finder angles → verify) of iteration 1 produced these;
all were addressed except one deliberate skip.

| # | Finding | Status |
|---|---|---|
| 1 | Lock-deduped path can skip → `read/1` serves a stale hit with no self-heal | ✅ Fixed — handler invalidates |
| 2 | Read-miss path announces `:cache_changed` spuriously (cold cache ≠ data change) | ✅ Fixed — read-miss paths `broadcast: false`; only mutation sites announce |
| 3 | Dead `load_into_memory_from_db` re-opens the storm + unknown-slug term leak | ✅ Fixed — aliased to `regenerate/2` |
| 4 | Handler does two DB reads per `:cache_changed` | ✅ Fixed — `invalidate` is O(1), no DB read |
| 5 | `opts` threaded through 5 lock helpers for one boolean | ⏭️ Skipped — keyword threading is conventional/extensible; current form is fine |
| 6 | Announce-test `assert_receive {:cache_changed, _}` wildcard could match a stray echo | ✅ Fixed — pinned to `^slug` |
| 7 | Doc drift: `regenerate/1` → `regenerate/2` | ✅ Fixed |

## Tests

Two regression tests in `test/.../web/listing_live_test.exs`:
- **handler stays silent** — subscribe the test process to the group's cache topic, send
  `:cache_changed` to a connected view, `refute_receive {:cache_changed, _}`. (The pre-existing
  smoke test missed the loop: `render(view)`'s reply lands before the first echo is processed,
  so it only proved one render round-trip while the real loop ran post-assertion until teardown.)
- **mutation announces** — `regenerate/2` default emits `{:cache_changed, ^slug}`
  (`assert_receive`); `broadcast: false` stays silent (`refute_receive`).

Verified: `mix compile --warnings-as-errors`, `mix format`, `mix credo --strict` all clean;
test files compile (suite itself needs Postgres, unavailable in this environment).

## Still open from the original review
- **M-A** — multi-line single-backtick code span renders a component live (XSS-class).
- Low items (double-escaped `&` in code spans, duplicated `page=` on listing 301s,
  `regenerate_slug` missing `readonly?` guard, truncation-warning droppable, lock dropped
  mid-translation, nil `url_slug` edge, `clear_translation/5` trailing-default trap).
