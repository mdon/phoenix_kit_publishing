# PR #12 — Fix smart-fallback URL hijack + drop hand-rolled migrations + Phase 2 cleanup

**Author:** mdon
**State:** merged (post-merge review)
**URL:** https://github.com/BeamLabEU/phoenix_kit_publishing/pull/12
**Scope:** 3 squashed-but-separate concerns (`b0fcc8d` + `601c4b5` + `508bcc1`), 252 / -599 LoC

Reviewed against the elixir-thinking, phoenix-thinking, and ecto-thinking skills.

---

## TL;DR

Strong PR. The smart-fallback bug fix is the load-bearing change and it is the right fix at the right layer; the migration cleanup deletes ~500 lines of code that were genuinely dead (no real "without core" path); the Phase 2 cleanup tightens lazy disjunctive test matchers and removes unused audit-metadata plumbing.

Recommendation: **approve.** Two small follow-ups worth filing (one nit, one perf), called out below — neither blocks the merge that already happened.

---

## 1. Smart-fallback URL hijacking — `b0fcc8d`

### Bug analysis

The old `Fallback.handle_fallback_case(:group_not_found, _, _)` clauses called `fallback_to_default_group/1`, which read `Publishing.list_groups()` and returned the path of *whichever group happens to be first*. That's fine when publishing owns its URL prefix (`/blog/*`), but the package supports `url_prefix: ""`/`"/"` so the catch-all `/:group/*path` then sits at the host's absolute root. Every URL the host's own routes don't claim earlier (`/about`, `/contact`, …) flows into this controller and silently 302s to an unrelated publishing page. That's a serious silent-failure mode — a host integrator gets functioning routes that *look* fine until they remove the prefix in production.

The fix cleanly splits the two cases (`controller/fallback.ex:79-105`):

- **Group exists, post/version/translation/time missing** → in-group fallback chain (other lang → other time → group listing) with the existing `"Showing closest match"` flash. Behaviour unchanged.
- **Group doesn't exist** → `:no_fallback` → 404 from the caller. No more "redirect to the first group in the DB."

Removing `Listing.default_group_listing/1` along with the only call site (`fallback_to_default_group/1`) is the right cleanup — there is no longer any meaningful "default group" concept in the request path, so keeping the helper would be a footgun for whoever wires the next fallback branch.

The doc rewrite at the top of `Fallback` (`controller/fallback.ex:2-29`) is excellent — it states the policy *and the reason* (URL-prefix mode), which is exactly the kind of comment that earns its keep because the reason isn't recoverable from the code alone.

### Side fixes uncovered along the way

Two additional bugs surfaced during debugging and got bundled in:

**(a) `conn.params` rewrite after `Language.detect_*` (`controller.ex:55-68, 83-93, 113-117`).**
The localized route `/:language/:group` greedily binds `language=<group>, group=<missing-post>` when a user types `/<group>/<missing>`; `Language.detect_language_or_group/2` then *interprets* the segments, but the controller wasn't propagating that interpretation back into `conn.params`. Downstream (`Fallback`) then reads the raw `conn.params["group"]`, which is the missing post slug — wrong group, wrong fallback. The bug only stayed hidden because the *previous* "redirect to first group" fallback masked it (the wrong group fed to the fallback got rewritten to "first group" anyway, which by coincidence was usually correct in dev/staging).

The fix is cosmetically small but mechanically correct — the helper:

```elixir
defp rewrite_params_after_shift(conn, original_params, original_params), do: conn

defp rewrite_params_after_shift(conn, _original_params, adjusted_params) do
  %{conn | params: Map.merge(conn.params, adjusted_params)}
end
```

uses Elixir's same-binding pattern match (both args bound to `original_params` ⇒ identity check) to short-circuit the no-shift case. That is idiomatic and matches the elixir-thinking skill's "pattern matching first" rule. **Nit:** that trick is uncommon enough that one extra line above the head — `# heads match when adjusted_params is identical to original_params (no shift happened)` — would save a future reader from staring at it. Not blocking.

One subtle observation: `Map.merge(conn.params, adjusted_params)` *only writes the keys present in `adjusted_params`*. So when `Language.detect_language_or_group/2` returns adjusted params with only `"group"`/`"path"`, the original `"language"` key in `conn.params` is left untouched (now stale — it holds the value that was reinterpreted as a group slug). Today that doesn't break anything because no downstream code reads `conn.params["language"]` after this point (locale is held in `conn.assigns.current_language`). Worth a one-line comment so a future reader doesn't stumble. Could also be `Map.put`s if you'd rather be explicit about exactly which keys are intended to be rewritten.

**(b) `constraints: %{...}` removed from `routes.ex:38-71`.** This is just a correctness cleanup — Phoenix.Router has no per-segment regex constraint mechanism, so those maps were no-ops. The phoenix-thinking skill confirms this is the right read of the framework. The replacement comment (`routes.ex:36-44`) and the AGENTS.md edit explaining what *actually* discriminates `/admin/*` from `/:group/*` (route declaration order + `Language.detect_language_or_group/2` at the controller) is the kind of doc fix that prevents the next person from re-adding the dead `constraints:` map "just to be safe."

### Tests pin the contract

`fallback_test.exs` had pre-existing matchers like:

```elixir
assert match?({:redirect_with_flash, _, _}, result) or match?({:render_404}, result)
```

— a disjunctive that would have happily passed *both* the buggy "redirect to first group" outcome *and* the correct 404 for the same input. The PR tightens every one of those to exact (`{:redirect_with_flash, path, _}`) plus a `path =~ "/" <> slug` location-header assertion. That's the right discipline. **Bonus**: the new `public_routes_test.exs` "smart fallback contract" describe block exercises the full router — including the localized-route rebinding case — and asserts the `Location` header is the *requested* group, not whichever group happens to be first. That last test (`/<group>/<missing-post>` via localized route) is the one that pins the side-fix in (a) and would have caught the regression. Excellent.

---

## 2. Migration cleanup — `601c4b5`

Replaces 178 lines of inline `CREATE TABLE` DDL in `test/test_helper.exs` (publishing tables + 7 support tables + manual `uuid-ossp` extension and `uuid_generate_v7()` function) with one line:

```elixir
Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], :up, all: true, log: false)
```

— the same call the host app makes in production. Also deletes `lib/phoenix_kit_publishing/migrations/publishing_tables.ex` (311 lines).

This is the right call:

1. **Schema drift becomes structurally impossible.** Test fixtures used to maintain a hand-rolled mirror of core's V20/V27/V59/V90/V95 — every time core changed a column type or added a column, this file was a silent footgun. Delegating to `PhoenixKit.Migration` means the test schema is exactly the production schema by construction. The ecto-thinking skill's "Runtime Migrations Use List API" form is exactly this idiom; nice.
2. **The deleted migration module had no real consumer.** The PR description says every consumer pulls in `{:phoenix_kit, "~> 1.7"}` as a hard dep — I verified the only call site was the test_helper wrapper just removed; production loads from core's V59. The "consolidated migration for fresh installs without core" framing in the README/AGENTS was aspirational and never matched reality.
3. **README + AGENTS updates match.** The lib-tree diagrams no longer reference `migrations/`, and the database-setup paragraph is rewritten to point at `mix phoenix_kit.install`. The Phase 2 cleanup commit (next section) catches the one place in README that still listed `migrations/`.

**Backwards-compatibility note for the changelog:** removing `PhoenixKit.Modules.Publishing.Migrations.PublishingTables.up/1` is technically a public-API removal. The 0.1.5 version bump (commit `19f2320`) covers this since this is still pre-1.0, but a one-line CHANGELOG entry like *"removed `PhoenixKit.Modules.Publishing.Migrations.PublishingTables` — was always intended to be a no-op when core was loaded; use `mix phoenix_kit.install`"* would help any external integrator who'd vendored a call to it. Worth a follow-up commit if a CHANGELOG exists; not blocking the merge.

---

## 3. Phase 2 re-validation cleanup — `508bcc1`

Four-item triage batch. All four are right calls:

### 3a. README lib-tree references deleted `migrations/`

Mechanical drift fix from #2. Nothing to say.

### 3b. Audit-metadata email plumbing removed (`shared.ex:48-72`, `posts.ex:1073-1085`)

The diff strips `created_by_email` / `updated_by_email` from `Shared.audit_metadata/2` and from `Posts.maybe_sync_datetime_and_audit/3`. The argument the PR makes is correct: `PublishingPost.changeset/2` casts only `:created_by_uuid` / `:updated_by_uuid`, so the email keys were silently dropped by the cast filter. They were copy-paste residue from core's pre-extraction blogging module whose `apply_creation_audit_metadata` consumer was a different code path that didn't come along.

This is a real cleanup, not just cosmetic — *dead public-API surface that looks live* is a recurring source of integrator confusion (someone reading `audit_metadata/2`'s output would reasonably assume the `*_email` keys reach the database). Removing them eliminates that misread. The new tests in `shared_test.exs:189-225` pin the post-cleanup shape explicitly:

```elixir
assert Shared.audit_metadata(scope, :create) == %{
         created_by_uuid: uuid,
         updated_by_uuid: uuid
       }

assert Shared.audit_metadata(scope, :update) == %{updated_by_uuid: uuid}
```

— and the comment in the first test ("prevents accidental future PII landing if someone adds the column without a separate review") is exactly the kind of *why* a future maintainer needs.

### 3c. `gettext("Back to %{group}", group: @group_name)` (`html.ex:361`, `preview.ex:301`, `controller.ex:240/270/301`)

`String.capitalize(@group_slug)` → `"Date12"` is a real UX paper-cut on programmatic slugs. Switching to a new `:group_name` assign sourced from `Publishing.group_name(slug) || slug` is the right shape — it falls back to the slug when the group has no display name configured, so the template never breaks.

**Perf nit (worth a follow-up, not blocking):** `Publishing.group_name/1` calls `DBStorage.get_group_by_slug/1` (`groups.ex:366`), which is a separate `Repo` round-trip. The three controller branches (`handle_post`, `handle_versioned_post`, `handle_date_only_url`) all already went through `PostRendering.render_post/4`, which itself loads the group (e.g. `post_rendering.ex:159-170`, `:361-362`). Adding `Publishing.group_name(...)` here is a redundant query per page render.

The clean fix is to have `PostRendering.render_post` (and the other two) thread `group_name` through `assigns` alongside `group_slug`, and the controller just consumes `assigns.group_name`. That's a one-line addition in each of the post-rendering helpers and a one-line removal in each of the three controller branches. Not in scope for this PR — the user-visible bug ("Date12") is fixed and the test suite is green — but worth filing as a follow-up. Mark as `(perf nit, ~5 LoC)` in the issue tracker.

### 3d. `fallback_test.exs` tightened from disjunctive to exact

Already covered in §1 — same point, same approval.

---

## Skill-aligned observations

Running the changes through the three thinking skills, nothing trips a red flag:

| Skill | Relevant rule | Compliance |
|------|----------------|------------|
| elixir-thinking | "No process without a runtime reason" | N/A — no processes added/changed. |
| elixir-thinking | "Pattern matching first" | `rewrite_params_after_shift/3` heads use the same-binding match for the identity case. Idiomatic. |
| elixir-thinking | "Test behaviour, not implementation"; pattern-match assertions | The fallback tests move from disjunctive `match?` to exact pattern matches — exactly the skill's recommendation. |
| phoenix-thinking | Phoenix Router has no per-segment regex constraints | `constraints: %{...}` removed; AGENTS.md updated to record this so it isn't re-added. |
| phoenix-thinking | "No DB queries in mount" | N/A — controller, not LiveView. |
| ecto-thinking | "Runtime migrations use list API" | `Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], :up, ...)` — correct shape. |
| ecto-thinking | Sandbox doesn't share with external processes | N/A here, but the test_helper now stops hand-rolling a `phoenix_kit_activities` table that ActivityLogAssertions queries — confirm in a future debug session that the sandbox-coupled flake mentioned in the PR description (1/15) isn't worse post-cleanup. |

---

## Follow-ups to consider (none blocking)

1. **Comment the same-binding match trick** in `rewrite_params_after_shift/3` (`controller.ex:113`). One line.
2. **CHANGELOG entry** for the removal of `PhoenixKit.Modules.Publishing.Migrations.PublishingTables`. One line, if a CHANGELOG file exists.
3. **Thread `group_name` through `assigns`** from `PostRendering.render_post*` so the three `Publishing.group_name(slug)` calls in `controller.ex:240/270/301` collapse into a single load done where the group is already fetched. ~5 LoC, eliminates one redundant `Repo` round-trip per public page render.
4. **Optional:** the `Map.merge(conn.params, adjusted_params)` in `rewrite_params_after_shift/3` leaves a stale `"language"` key in `conn.params` when the first segment turns out to be a group, not a locale. No current reader cares, but if the controller ever reads `conn.params["language"]` again, this becomes a sneaky bug. Either drop the stale key or comment that it's intentionally retained.

## Verdict

Clean, well-motivated, well-tested. The bug fix targets the right layer (controller-level fallback policy, not router-level constraint hacks); the migration cleanup is structurally correct; the Phase 2 sweep removes real dead code rather than just cosmetic noise. **Approve.**
