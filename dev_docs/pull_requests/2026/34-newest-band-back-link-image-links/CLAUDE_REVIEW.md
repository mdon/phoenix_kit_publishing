# PR #34 — Claude review (post-merge)

Review of merged PR #34 — "Add Latest post band, top back link, and clickable
card images to the public side" (merge `cd06cef`, squashing `51271b8` "Add
Latest post band, top back link, and clickable card images to the public
side" and `d701c98` "Address quorum review: group-wide date counts and
image-link a11y" — the second commit is itself a fix-up from an earlier
quorum review, already folded into the merged PR). Reviewed with the
`phoenix-thinking` and `ecto-thinking` skills (controller/LiveView listing +
display-settings JSONB accessors; no LiveView `mount` queries or Ecto schema
migrations involved — settings live in the existing `data` JSONB, no new
migration).

Three additive features, all gated behind new per-group `data` JSONB keys
(`newest_enabled`/`newest_layout`, `show_top_back_link`, `listing_image_links`)
following the module's existing display-settings pattern:
`Constants` → `GroupSettings` schema entry → `Groups` bool/enum key list +
`merge_group_config/2` default → `PublishingGroup` accessor → `edit.ex` form
→ `controller.ex`/`listing.ex`/`html.ex` render path.

## Findings

No BUG or IMPROVEMENT-level findings. Traced every new setting through the
full write→read→render chain and didn't find a break:

- **`newest_enabled`/`newest_layout`** (`Constants`, `GroupSettings`,
  `Groups.@bool_setting_keys`/`@enum_settings`/`merge_group_config/2`,
  `PublishingGroup.newest_enabled?/1`/`newest_layout/1`) are all present and
  consistent with the existing `featured_enabled`/`featured_layout` pattern
  they mirror. `group_settings_test.exs`'s "covers exactly the keys
  `update_group/3` persists" test (`GroupSettings.keys()` vs
  `Groups.config_setting_keys()`) and the "matches the schema accessors'
  defaults" test both cover the two new keys, so drift between the spec and
  the write path would fail CI, not just this review.
- **`Listing.split_newest/2`** (`web/controller/listing.ex:249-260`) runs
  *after* `partition_featured/2` on the already-featured-filtered
  `grid_posts`, so a post that is both newest and featured stays in the
  Featured band and Latest takes the next-newest — matches the AGENTS.md
  claim and is pinned by
  `display_settings_render_test.exs` ("a featured newest post stays in the
  Featured band; Latest takes the next-newest"). `Enum.max_by/2` picks by
  `listing_sort_key/1`, the same ISO-8601-ish string every post already sorts
  by, so the pick is correct regardless of the group's `listing_sort`
  direction (asc/desc) — verified `listing_sort_key/1`'s three clauses
  (timestamp-mode date+time, slug-mode `published_at`, unpublished fallback)
  produce zero-padded, lexically-comparable strings.
- **Group-wide `date_counts`** (`listing.ex:196`,
  `PublishingHTML.build_date_counts(all_posts)`) is computed once over the
  *full* `all_posts` list (before pagination/featured/newest partitioning),
  not just the visible page — this is the fix from the "quorum review"
  follow-up commit and is exactly what's needed: a page-2 render's
  `grid_posts` slice alone would undercount a date shared with a post pinned
  into the Featured/Latest band or sitting on a different page, which would
  wrongly disambiguate a URL down to a bare date when a time segment was
  required. `display_settings_render_test.exs`'s "a page-2 same-day sibling
  of the pinned newest post keeps its time-segment URL" test pins this
  exact regression.
- **`assign_group_display_config/2`'s `||` → `case`/`nil` rewrite**
  (`controller.ex:579-584`) is a real bug fix bundled into this PR: the old
  `Map.get(group, key) || default` flips a stored `false` back to `default`
  for any default-`true` setting. `show_top_back_link` (default `true`) is
  the first post-scope setting that can be explicitly `false`, so the old
  code would have made the "hide top back link" toggle inert. The rewrite
  (`nil` → default, anything else including `false` → passthrough) is
  correct and is exercised by `display_settings_render_test.exs`'s
  "renders top + footer back links by default, footer only when disabled"
  test.
- **`image_links` gating** (`html.ex:718`,
  `(assigns[:group] && @group["listing_image_links"]) != false`) correctly
  defaults to `true` when the group is absent or the key is unset (`nil !=
  false`), and only suppresses the link when the stored value is exactly
  `false`. The wrapping `<.link>` around the card image uses
  `tabindex="-1" aria-hidden="true"` since the title link right below is
  already the accessible route to the same destination — this a11y guard is
  the other half of the "quorum review" follow-up commit.
- `newest_layout_options/0` in `edit.ex` deliberately reuses
  `featured_layout_options/0` (same `["hero", "card"]` vocabulary) rather
  than duplicating the label list — correct, and commented as intentional.
- Compiled `.po`/`.pot` diffs are mechanical `mix gettext.extract` output
  (new English `msgid`/`msgstr` pairs match; other locales get the new
  `msgid` with empty `msgstr`, same shape as every prior string addition).

## Verified correct (checked, no change needed)

- `post_display_defaults/0` gained `show_top_back_link: true`; `listing.ex`'s
  featured/newest defaults (`Map.get(ctx.group, "featured_layout", "hero")`
  etc.) match `Constants.default_newest_layout/0`. No default drifted
  between the constant, the settings spec, and the inline fallback.
- The `handle_group_listing/3` conn-assign chain in `controller.ex` always
  receives `newest_posts`/`newest_layout`/`date_counts` from
  `Listing.render_group_listing/4`'s single return path — no code path
  produces an assigns map missing those keys, so the `assign(:newest_posts,
  assigns.newest_posts)`-style direct field access can't raise `KeyError`.
- `@group_name` (used by the new top-back-link `nav`) is assigned on every
  controller code path that renders `Web.HTML.show/1`
  (`controller.ex:290,319,351`), so the new markup can't hit a missing assign.

## Gate

`mix precommit` (compile --warnings-as-errors + format + credo --strict +
dialyzer) — clean. `mix test` — 626 tests, 0 failures, 585 excluded
(`:integration`-tagged DB tests, including the new
`display_settings_render_test.exs` cases and `schema_test.exs`/
`group_settings_test.exs` assertions covering the new settings — **not
verified against a live database in this sandbox**, no PostgreSQL server is
reachable here). Read the new/changed test bodies directly instead and
traced them against the implementation by hand (see Findings above); they
match the code's actual behavior. Should be confirmed green in CI before
treating as fully proven.

## Verdict

No fixes applied — nothing found that needed one. The PR's own second commit
already closed the two real gaps a first pass would have flagged
(group-wide date counts, image-link a11y), and the settings plumbing follows
the existing pattern closely enough that the key-parity tests would have
caught drift.
