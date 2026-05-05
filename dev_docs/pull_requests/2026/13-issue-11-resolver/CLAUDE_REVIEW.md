# PR #13 — Fix issue #11: editor opens blank for `?lang=<base>` when only a non-default dialect is enabled

**Author:** mdon
**State:** merged (post-merge review)
**URL:** https://github.com/BeamLabEU/phoenix_kit_publishing/pull/13
**Scope:** load-bearing two-layer bug fix (`79c1587`) + 12-test pinning sweep (`9f93dff`) + PR-12 close-out (`ba3cd3f`) + two precommit nits (`2ef55fa`, `826ae53`). +541 / −17 LoC across 10 files.

Reviewed against the elixir-thinking and phoenix-thinking skills.

---

## TL;DR

Solid fix. The bug is correctly diagnosed as needing repair at two independent layers (resolver + editor membership check), and the chosen fix at each layer is the cheapest change that closes the actual gap without widening the API surface. The 12 new tests pin every reachable branch including the genuinely-new-translation regression guard. Stability and lint are clean.

Recommendation: **approve.** Two small follow-ups worth filing — both are codebase-shape observations, neither blocks the merge that already happened.

---

## 1. The bug — `?lang=en` against `["en-GB", "ru"]`

The Listing builds the editor's default click-through URL using the primary language *base* (`?lang=en` when `get_primary_language` is `"en-GB"`). That base then flows through two independent code paths:

1. **`Posts.resolve_language_to_dialect/1`** mapped `"en"` → `DialectMapper.base_to_dialect("en")` → hard-coded `"en-US"`. `"en-US"` isn't enabled, so `DBStorage.resolve_content/2` fell back to the site default (`"en-GB"`) and the read path *worked* — the post object came back populated.
2. **`Editor.handle_uuid_post_params/3`** then ran a raw `language not in post.available_languages` check — `"en" not in ["en-GB", "ru"]` is `true` — and routed into `handle_new_translation_params/6`, which empties title and content for a blank new-translation form.

So the read returned the right post but the LV branched into "user is creating a new translation," which empties the form. Two layers, two independent bugs, one user-visible symptom. The PR description correctly notes that fixing only the resolver is insufficient, and the test `editor_live_test.exs:545` ("loads existing en-GB content...") is a true regression guard for the editor-side fix specifically.

---

## 2. Resolver fix — `Posts.resolve_language_to_dialect/1`

`lib/phoenix_kit_publishing/posts.ex:728-769`

The old shape was a nested `if`:

```elixir
if language in enabled do
  language
else
  base = DialectMapper.extract_base(language)
  if base == language do
    DialectMapper.base_to_dialect(language)
  else
    language
  end
end
```

The rewrite uses a documented 4-case `cond` plus a small `enabled_dialect_for_base/2` helper that does the new "prefer an enabled dialect for this base" lookup with a tie-break to `LanguageHelpers.get_primary_language/0` when several dialects share the base. Resolution order matches the doc-comment block-for-block.

**What I checked:**

- The `cond` is decomposable into pattern-match heads, but the second arm (`extract_base(language) == language`) is itself a runtime predicate, so a flat `cond` is the right shape — no rewrite buys anything. Plain functions, no process introduced (✓ Iron Law).
- `enabled_dialect_for_base/2` collapses cleanly: `[]` → `nil`, `[single]` → that, `multiple` → primary or `List.first/1`. `Enum.filter` is appropriate over `Enum.find` because we need the multi-dialect tie-break case.
- The defensive `nil` clause stays as `defp resolve_language_to_dialect(nil), do: nil` — good. `nil` is exercised in test `resolve_language_to_dialect_test.exs:148`.
- Doc-comment is slightly ahead of the code (mentions a hot path used by every `read_post*` entry point). I grepped — the four read entry points (`read_post_by_uuid`, `read_post_by_slug`, `read_post_by_datetime`, plus the path/version permutations) all pipe through this single resolver. Doc-comment is accurate.

**Subtle observation worth filing as a follow-up (not blocking):** there are now three functions doing similar base→dialect resolution, with subtly different tie-break behavior:

| Function | Scope | Multi-dialect tie-break |
|----------|-------|-------------------------|
| `Posts.enabled_dialect_for_base/2` (new in this PR) | enabled languages | primary, then declaration order |
| `Web.Controller.Language.find_dialect_for_base/2` | arbitrary list | `Enum.find` first match |
| `Web.Controller.Language.resolve_language_for_post/2` | post's `available_languages` | first match (no primary) |

For the tie-break LV test (`?lang=en` with `["en-GB", "en-US"]`, primary `"en-US"`):

- `Editor.new_translation_request?/2` calls `resolve_language_for_post` → finds `"en-GB"` first → `"en-GB" in available` → returns `false` → routes to existing-post branch.
- `Publishing.read_post_by_uuid("en", …)` calls `Posts.resolve_language_to_dialect` → primary tie-break → returns `"en-US"`.

Both arrive at correct behavior in this test, but they answer the same question with different algorithms. No bug here, but the next refactor that touches either should know the divergence exists.

---

## 3. Editor fix — `new_translation_request?/2`

`lib/phoenix_kit_publishing/web/editor.ex:218, 273, 372-379`

Two call sites (UUID-mode at `:218` and path-mode at `:273`) each swap `language not in post.available_languages` for a guarded call to the new private predicate:

```elixir
defp new_translation_request?(language, %{available_languages: available}) do
  ControllerLanguage.resolve_language_for_post(language, available) not in available
end
```

This is the right minimal fix. `ControllerLanguage.resolve_language_for_post/2` already implements "resolve a base to a dialect within this list, fall back to `DialectMapper`," and the editor reuses it instead of inlining. The contract is "resolved code lands in `available_languages` ⇒ existing translation; otherwise ⇒ new." The doc-comment at `:372-376` is precise about the example case (`?lang=en` against `["en-GB", "ru"]`).

**What I checked:**

- The pattern match `%{available_languages: available}` is clean — destructure-on-entry rather than `post.available_languages` later. ✓ elixir-thinking guidance.
- The guard `if language && new_translation_request?(...)` short-circuits on `nil`. `""` (empty string) is truthy and would enter — `resolve_language_for_post("", available)` would fall through `base_code?` (false) → `extract_base("")` → `"en"` → may find a dialect. This is a pre-existing oddity in `resolve_language_for_post`, not introduced here. Not exercised by any URL the listing builds. Out of scope.
- The `not in available` semantic implicitly trusts the resolver's fallback. If `resolve_language_for_post` returns the raw input unchanged (the "full dialect not enabled, no base match" branch), the predicate returns `true` — i.e. open the new-translation form. Consistent with the existing `?lang=fr` regression test.
- The PR description acknowledges one defensive path-mode branch is unreachable. I did not verify reachability claim independently — would require tracing every Listing URL builder. Trusting the C11 delta audit on this one.

---

## 4. Test sweep — `9f93dff`

12 new tests across two files. These are the kind of tests that pay back during the next refactor because they pin observable behavior, not implementation.

**`resolve_language_to_dialect_test.exs`** (new, +220) covers:
- single enabled dialect for the base — the literal issue #11 case
- multi-dialect with primary tie-break
- multi-dialect without primary tie-break (falls to first)
- `DialectMapper` fallback when no enabled dialect matches
- direct match (full code in enabled)
- full-code passthrough when not enabled
- `nil` clause

Asserts use pattern matching (`assert {:ok, fetched} = ...; assert fetched.language == ...`) rather than imperative length-then-`Enum.at`. Each test sets up an isolated language config and group, which makes them slow but readable. `async: false` is correct here — every test mutates the global `languages_config` setting and `content_language` (ETS-cached singletons); per the elixir-thinking testing skill that's a coupling smell, but the global state IS the production code path, so the workaround would be a much larger architectural change. Acceptable as-is.

**`editor_live_test.exs`** (+178) exercises four URL forms (`?lang=en`, `?lang=en-GB`, `?lang=en-US`, `?lang=fr`) plus the multi-dialect tie-break. The `?lang=fr` test is the genuinely-new-translation regression guard — without it, a future refactor that over-collapses base→dialect could route every unknown language onto an existing post. That's the right guard to have.

The tests reach into LiveView assigns via `:sys.get_state(view.pid) |> get_in([Access.key(:socket), Access.key(:assigns), :is_new_translation])`. This is the standard "I need to assert non-rendered state" escape hatch. It's ugly but legitimate — the alternative would be threading an extra DOM marker just for tests, which would over-couple. Acceptable.

---

## 5. Folded-in close-outs

These are the trailing items from the PR-12 cleanup that didn't make the previous merge. None are load-bearing for issue #11; they're hygiene.

- **`ba3cd3f` PR-12 follow-up close-out** — fixes the stale `build_breadcrumbs/3` call in `post_rendering_helpers_test.exs:74` that the `7f547b5` arity bump (`/3 → /4`) missed, and adds `dev_docs/pull_requests/2026/12-smart-fallback-fix/FOLLOW_UP.md` recording the resolution of the four PR-12 review findings (3 in `7f547b5`, 1 here). Also closes that folder per the project's PR-doc convention.
- **`2ef55fa` `StaleFixerTest` async flake** — switches `use PhoenixKit.DataCase, async: true` → `async: false` because every test mutates `content_language` (ETS-cached singleton). Reported as 1-in-15 flake. The fix is correct and the comment block above `use` documents *why* future-you can't flip it back. The deeper issue is that publishing's `content_language` setting is process-global, but that's a project-wide pattern, not this PR's scope.
- **`826ae53` `preview.ex` formatting** — splits a single-line `breadcrumbs = PostRendering.build_breadcrumbs(...)` over two lines to satisfy `mix format --check-formatted` after the `/3 → /4` arity bump pushed it past 98 chars. Trivial, pre-existing drift.

---

## 6. `test_helper.exs` migration switch

`test/test_helper.exs:52`

Swaps `Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], :up, all: true, log: false)` for `PhoenixKit.Migration.ensure_current(TestRepo, log: false)`. The comment block explains the staleness mechanism: the version-`0` pattern silently stops re-applying once `0` is recorded in `schema_migrations`, so newly-shipped V*xxx* migrations don't run on subsequent boots. `ensure_current/2` (core 1.7.105+, `phoenix_kit#515`) re-applies via fresh wall-clock versions.

Coincides with recent `e49af29` merge / `199dfca` "Swap test_helper to PhoenixKit.Migration.ensure_current/2". Aligns the test bootstrap with how the production migration story actually works. ✓

---

## What I'd file as follow-ups

Neither blocks merge.

1. **Unify base→dialect resolution.** Three near-identical helpers (`Posts.enabled_dialect_for_base/2`, `Web.Controller.Language.find_dialect_for_base/2`, `Web.Controller.Language.resolve_language_for_post/2`) each answer "given a base and a list, pick a dialect," with subtly different tie-break behavior. A single `Languages.resolve_in/3` with an explicit `:tie_break` opt would prevent the next divergence. Worth ~1 hour when next touching either layer.

2. **Document the editor's two-stage resolution contract in `AGENTS.md`.** The PR adds a Critical Conventions bullet for "Base→enabled-dialect resolution," which is good. The bullet is dense; a small ASCII flow ("URL `?lang=` → `new_translation_request?/2` → `resolve_language_for_post/2` against `post.available_languages`; then `read_post_by_uuid` → `resolve_language_to_dialect/1` against enabled languages") would help the next contributor avoid the same trap. Minor.

---

## Verification claimed in the PR

- `mix format --check-formatted` ✓
- `mix credo --strict` — 0 issues
- `mix dialyzer` — 0 errors
- `mix test` — 1000 / 0
- 10× stability sweep — 10/10 clean
- Browser verification (Playwright MCP) — issue reproduced pre-fix, gone post-fix
- Regression guard verified by temporary revert

Not independently re-run for this review. The numbers are consistent with the test additions (`+12 tests` lands on a base of ~988).

---

## Recommendation

**Approve.** The fix is correct at both layers, the test coverage pins the four resolver branches plus all four URL-form editor branches plus the regression guard, and the folded-in close-outs are appropriately scoped. Two follow-ups are codebase-shape observations, not blockers.
