# Follow-up Items for PR #10

Tracks the original quality-sweep work plus the 2026-04-27 re-validation
pass that brought publishing forward to the post-Apr pipeline standard
(C12 triage agents + C12.5 deep dive + fix-everything close-out + coverage push).

## Phase 1 — PR catch-up (re-verified 2026-04-27)

All four prior PR FOLLOW_UPs (#2, #4, #5, #9) re-verified clean — every
fix listed is still in place on the branch:

- PR #2: 8 preload sites in `db_storage.ex`, 5 `filter_by_status` call
  sites, 2 `stream_posts` references, partial-index rename.
- PR #4: every `<select>` element wrapped in
  `<label class="select ...">`.
- PR #5: routing-anti-pattern pointer present in AGENTS.md.
- PR #9: `exact_enabled_for_public?/2` rename, narrowed rescues,
  Settings mount→handle_params migration, slug-conflict retry.

## Original quality sweep (Batch 1 — 2026-04-26)

Errors atom dispatcher (36 atoms + 4 tagged tuples), activity logging on
17 user-driven CRUD actions with actor_uuid threading via
`Shared.actor_uuid_from_socket/1`, phx-disable-with on every
async/destructive button, full test infra (Test.Endpoint / Router /
Layouts / LiveCase / Hooks / ActivityLogAssertions), @spec backfill on
db_storage / shared / pubsub modules. C12 catch-all `handle_info` clauses
on listing.ex + editor.ex; broadcast_post_created/updated trimmed to
minimal `{uuid, slug}` payload; upsert_group race condition fixed via
Ecto on_conflict. **Earmark `escape: false` trust model** documented in
renderer.ex as admin-trust boundary (admin authors can include inline
HTML / `<script>`; if untrusted input ever reaches `render_markdown/1`,
wire `html_sanitize_ex` in front of it).

451 → 493 tests, 5/5 stable runs.

## Re-validation — Batch 2 (2026-04-27)

Closed structural deltas the original sweep predates. C12 triage agents
+ C12.5 deep dive surfaced these — every finding closed (no deferrals).

### Async UX

- ~~**`phx-disable-with` missing on `clear_featured_image` buttons**~~ —
  `web/editor.ex:2421, 2443` (desktop + mobile copies). Both gained
  `phx-disable-with={gettext("Removing…")}`. Pinned by
  `editor_phx_disable_with_test.exs` source-level pairing assertion.

- ~~**Silent `handle_info` catch-alls / missing handle_info in 4 LVs**~~
  — `edit.ex` and `new.ex` had no `handle_info/2` at all (any future
  PubSub broadcast would crash with FunctionClauseError); `preview.ex`
  same; `post_show.ex` had a silent `def handle_info(_msg, socket), do:
  {:noreply, socket}`. All four now log via `Logger.debug` with the LV
  name and inspected message. Pinned by `send(view.pid, {:bogus, ...})`
  smoke tests in `edit_live_test.exs`, `new_live_test.exs`,
  `preview_live_test.exs`, `post_show_live_test.exs`,
  `listing_live_test.exs` (already had one — verified intact).
- ~~**`@impl true` annotations missing on Web.New / Web.Edit
  callbacks**~~ — once any `@impl true` was added, the compiler enforces
  it across the module. Backfilled across `mount`, `handle_params`,
  `handle_event`, `render` for both LVs.

### Translations

- ~~**Raw status string render in `post_show.ex:138, 178`**~~ —
  `{@post.metadata[:status] || "draft"}` and `{status}` displayed the
  programmatic atom verbatim. New `status_label/1` helper with literal
  gettext clauses for `published` / `draft` / `archived` / `trashed`
  (the extractor only sees literals — `gettext(status)` of a variable
  would be invisible). Pinned by `post_show_test.exs` per-status tests
  + `post_show_live_test.exs` smoke that the live page renders "Draft"
  not "draft".
- ~~**Hardcoded "Error rendering markdown" in renderer.ex:217**~~ —
  wrapped in `gettext()` via `Phoenix.HTML.html_escape` +
  `safe_to_string`; renderer now `use`s Gettext from
  `PhoenixKitWeb.Gettext` backend.

### PubSub

- ~~**`broadcast_post_status_changed` and `broadcast_version_created`
  passed full post records**~~ — `pubsub.ex:158, 166` previously sent
  the whole post map (title, body, version metadata). Both now route
  through the same `minimal_payload/1` helper as
  `broadcast_post_created`/`broadcast_post_updated` (uuid + slug only).
  Receivers re-fetch via `update_post_in_list` / `schedule_debounced_update`.
  Pinned by 4 tests in `pubsub_test.exs` "minimal payload broadcasts".

- ~~**Hardcoded topic prefix in `presence_helpers.ex:184`**~~ — extracted
  `@editing_topic_prefix "publishing_edit"` for grep-ability and
  consistency with the pattern in `pubsub.ex`. Pinned by
  `presence_helpers_test.exs`.

### Defense-in-depth

- ~~**`page_builder/renderer.ex:93` string-interpolated AST content
  into `<div>`**~~ — replaced with iolist via `Phoenix.HTML.raw([...,
  content, ...])`. Even under the admin-trust model, the wrapper
  element stays well-formed. Pinned by
  `page_builder/renderer_test.exs`.

### Documentation

- ~~**AGENTS.md missing "What This Module Does NOT Have" section**~~ —
  added with seven deliberate non-features (no HTML sanitiser, no
  outbound HTTP, no per-language Mailer, no AI retry layer, no editor
  merge UX, no client-side undo, no frontend bundle).

### Coverage harness

- ~~**mix.exs missing `test_coverage` filter**~~ — added
  `[ignore_modules: [...]]` so test-support modules don't drag down
  `mix test --cover` percentages.

## Re-validation — Batch 3 — fix-everything (2026-04-27)

Closed every remaining C12 finding. No deferrals (per the
"FIX EVERYTHING" directive overriding `feedback_quality_sweep_scope.md`).

### Activity logging — `:error`-branch coverage on 12 mutations

New `ActivityLog.log_failed_mutation/5` helper writes a
`db_pending: true` audit row whenever a user-driven mutation fails
before / instead of the primary DB write. Reason: a Drive outage /
not-found / FK violation should not erase admin clicks from the
activity feed.

- ~~`Posts.create_post`~~ — `:error` branch logs db_pending row.
- ~~`Posts.update_post`~~ — `case` rewritten from `with` so error
  branch can log; previously logged only on success.
- ~~`Posts.restore_post`~~ — both `:not_found` and `{:error, reason}`
  branches log.
- ~~`Posts.trash_post`~~ — both error branches log.
- ~~`Versions.publish_version`~~ — `:not_found` + `:post_trashed` +
  `do_publish_version` tx error branches all log.
- ~~`Versions.unpublish_post`~~ — `:not_found` + `:not_published` +
  `do_unpublish_post` tx error branches all log.
- ~~`Versions.delete_version`~~ — `:not_found` + `:cannot_delete_live`
  + `:last_version` + DB-level error branches all log with reason.
- ~~`Groups.add_group`~~ — 4 early-validation branches
  (`:invalid_name` / `:invalid_mode` / `:invalid_type` /
  `:invalid_slug`) plus `create_and_broadcast_group` error all log
  via new `log_failed_group_create/3` helper.
- ~~`Groups.remove_group`~~ — `:not_found` + `:has_posts` +
  `delete_and_broadcast_group` error all log.
- ~~`Groups.update_group`~~ — `:not_found` + with-chain error log via
  new `to_string_reason/1` helper.
- ~~`Groups.trash_group`~~ — `:not_found` + DB error log.
- ~~`Groups.restore_group`~~ — `:not_found` + `:slug_taken` + DB error
  log.

Pinned by 16 new tests in `activity_logging_test.exs` — every
`:error` shape asserts the audit row exists with `db_pending: true`
and the right `reason`.

### `@spec` backfill on 11 public functions

`posts.ex` (`count_posts_on_date`, `list_times_on_date`,
`read_post_by_uuid`, `extract_slug_version_and_language`,
`read_back_post`), `routes.ex` (`public_routes`,
`admin_locale_routes`, `admin_routes`), `renderer.ex`
(`clear_all_cache`), `groups.ex` (`remove_group/2`),
`translation_manager.ex` (`add_language_to_db`),
`language_helpers.ex` (`build_language_entry`), `listing_cache.ex`
(`find_post_by_mode`), `versions.ex` (`broadcast_version_created`),
`stale_fixer.ex` (`reconcile_post_status`).

Two `@spec` declarations were widened from initial-pass narrowness
to match dialyzer's success typing:
- `find_post_by_mode/2` — `map() | nil` →
  `{:ok, map()} | {:error, :cache_miss | :not_found}`.
- `reconcile_post_status/1` — `:ok` → `[any()]`.

### Code cleanliness

- ~~Dead clauses in `Groups.to_string_reason/1`~~ — dialyzer flagged
  binary + fallback as unreachable. Removed; only atom and
  changeset clauses remain.
- ~~`page_builder/renderer.ex:93` unsafe interpolation~~ (already
  in Batch 2, listed above).

## Re-validation — Batch 4 — coverage push (2026-04-27)

Pushed line coverage from baseline **33.34%** to **41.94%** using
only `mix test --cover` — no Mox, no excoveralls, no Bypass, no
external HTTP stubs.

### New test files (11)

- `presence_helpers_test.exs` (4) — topic constant.
- `page_builder_test.exs` (7) — render_content end-to-end.
- `page_builder/parser_test.exs` (10) — Saxy XML→AST.
- `slug_helpers_test.exs` (12) — slug regex.
- `web/editor/helpers_test.exs` (24) — URL builders, virtual posts.
- `web/html_helpers_test.exs` (36) — date/time/URL formatting.
- `listing_cache_test.exs` (15) — persistent_term key + read paths.
- `activity_log_test.exs` (13) — never-crash contract.
- `web/listing_live_test.exs` (6) — Listing LV mount/events.
- `web/preview_live_test.exs` (3) — Preview LV mount + back nav.
- `web/post_show_live_test.exs` (5) — PostShow LV smoke.

### Extended files (3)

- `pubsub_test.exs` — +20 broadcast/receive cycle tests.
- `renderer_test.exs` — +10 PHK detection / cache settings.
- `language_helpers_test.exs` — +15 enabled/display/order/normalize.

### Per-module uplifts

| Module | Before | After |
|--------|--------|-------|
| Web.HTML | 17.74% | ~41% |
| Web.Listing | 0% | ~42% |
| Web.Preview | 0% | ~57% |
| Web.PostShow | 16.47% | ~86% |
| Web.Editor.Helpers | 2.44% | ~56% |
| ListingCache | 28.48% | ~45% |
| LanguageHelpers | 34.78% | ~79% |
| PageBuilder | 0% | ~85% |
| PageBuilder.Parser | 0% | ~86% |
| PageBuilder.SaxHandler | 0% | ~91% |
| ActivityLog | 50% | ~88% |
| PubSub | 51.56% | ~62% |

### Test infra changes

- `test_helper.exs` starts `PhoenixKit.TaskSupervisor` so the
  Listing LV's background StaleFixer task doesn't crash with
  `:noproc` during smoke tests.

### What's still uncovered (intentional)

- **Web.Editor (~4000-line LV) and Web.Editor.{Collaborative,
  Persistence, Preview, Translation, Versions, Forms}** — mount imports
  MediaSelectorModal which queries Storage tables we don't own in this
  module's test DB. The full editor flow is exercised in the parent
  app's integration tests.
- **Workers.TranslatePostWorker (Oban worker)** — needs Oban running.
- **Migrations.PublishingTables** — pure migration code, runs once at
  test_helper boot via `Ecto.Migrator.up`.
- **PresenceHelpers role-resolution** — needs `Phoenix.Presence` server
  running with real subscribers.
- **Web.Controller submodules (PostFetching / PostRendering /
  SlugResolution / Fallback)** — branches require populated
  content+versions+translations fixtures across multiple languages.
  Public-route smoke is in `controller/show_layout_test.exs`.

These residuals are documented as deliberate; closing them would
either require external test deps (Mox) we explicitly don't add, or
massive cross-table fixtures that belong in integration tests.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_publishing/activity_log.ex` | New `log_failed_mutation/5` helper |
| `lib/phoenix_kit_publishing/posts.ex` | `:error`-branch logging on 4 mutations + 4 specs |
| `lib/phoenix_kit_publishing/versions.ex` | `:error`-branch logging on 3 mutations + 1 spec |
| `lib/phoenix_kit_publishing/groups.ex` | `:error`-branch logging on 5 mutations + helpers + 2 specs |
| `lib/phoenix_kit_publishing/pubsub.ex` | Minimal payload trim on status_changed + version_created |
| `lib/phoenix_kit_publishing/presence_helpers.ex` | `@editing_topic_prefix` constant |
| `lib/phoenix_kit_publishing/renderer.ex` | gettext on error fallback + `use Gettext` + spec |
| `lib/phoenix_kit_publishing/page_builder/renderer.ex` | iolist wrap of unknown component |
| `lib/phoenix_kit_publishing/listing_cache.ex` | spec widened on `find_post_by_mode/2` |
| `lib/phoenix_kit_publishing/stale_fixer.ex` | spec widened on `reconcile_post_status/1` |
| `lib/phoenix_kit_publishing/language_helpers.ex` | spec on `build_language_entry/4` |
| `lib/phoenix_kit_publishing/translation_manager.ex` | spec on `add_language_to_db/4` |
| `lib/phoenix_kit_publishing/routes.ex` | 3 specs on quoted-route helpers |
| `lib/phoenix_kit_publishing/publishing.ex` | spec widened on `valid_slug?/1` |
| `lib/phoenix_kit_publishing/web/editor.ex` | `phx-disable-with` on 2 buttons |
| `lib/phoenix_kit_publishing/web/edit.ex` | `handle_info` catch-all + `@impl` annotations |
| `lib/phoenix_kit_publishing/web/new.ex` | `handle_info` catch-all + `@impl` annotations |
| `lib/phoenix_kit_publishing/web/preview.ex` | `handle_info` catch-all |
| `lib/phoenix_kit_publishing/web/post_show.ex` | `status_label/1` helper + handle_info logger |
| `mix.exs` | `test_coverage [ignore_modules]` filter |
| `AGENTS.md` | "What This Module Does NOT Have" section |
| `test/test_helper.exs` | `PhoenixKit.TaskSupervisor` startup |
| 14 new + 4 extended test files | +216 tests pinning the deltas above |

## Verification

- `mix compile --warnings-as-errors` ✓
- `mix format` clean
- `mix credo --strict` clean (1667 mods/funs, 0 issues)
- `mix dialyzer` 0 errors
- `mix test`: 493 → 709 tests, 0 failures
- `mix test --cover` (production code only): 33.34% → 41.94%

## Open

None.
