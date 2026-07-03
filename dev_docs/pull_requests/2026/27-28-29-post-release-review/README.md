# PR #27, #28, #29 — post-release review

**Status**: Merged (all three, before this review)
**Reviewer**: Claude
**Date**: 2026-07-03

Batched review of three PRs that landed back-to-back on `main`:

| PR | Author | Title |
|----|--------|-------|
| [#27](https://github.com/BeamLabEU/phoenix_kit_publishing/pull/27) | @mdon | Integrate phoenix_kit_og + cap auto-generated slugs at 60 chars |
| [#28](https://github.com/BeamLabEU/phoenix_kit_publishing/pull/28) | @timujinne | Fix missing `:url_path` assign on public controller renders |
| [#29](https://github.com/BeamLabEU/phoenix_kit_publishing/pull/29) | @timujinne | Respect other modules' reserved route prefixes in group dispatch |

## What Each PR Does

**#27** — Adds a `phoenix_kit_og` integration seam: `Publishing.og_variables/0` +
`og_resolve/2` expose post fields for a future OG-image template plugin to wire
into slots; a per-language `content.data["og"]` override
(title/description/image) is editable from the editor's new "Social /
OpenGraph" panel and layered into `build_og_data/4`'s existing
title/description/image resolution. Also lowers the **auto-generated** slug
cap from 200 to 60 chars (SEO guidance) — the save-time cap for a
human-typed slug is unaffected (`Constants.max_slug_length/0`, 500). Ships
alongside two unrelated dependency bumps (`mdex`/`mdex_native`, `rustler`
optional dep for the NIF source-build fallback).

**#28** — A module `plug :assign_url_path` on the public `Controller` sets
`conn.assigns.url_path` from `conn.request_path` when a host hasn't already
set it, so host root layouts building canonical/`og:url`/hreflang tags from
that assign don't fall back to `"/"` on every publishing-served page (this
broke `/legal/*` canonicals on hydroforce.ee — Search Console flagged the
pages as duplicates and dropped them from the index).

**#29** — `RouterDispatch.known_group?/1` now also checks
`PhoenixKit.ModuleRegistry.all_reserved_route_prefixes/0` so a group slug
that collides with another module's reserved top-level route (e.g.
`phoenix_kit_legal` reserving `"legal"` while also using Publishing's storage
APIs to create a same-named group) is never claimed by the group catch-all.
PR #29 already went through one review round on GitHub before merge — see
"Already fixed pre-merge" below — this doc covers the re-verification and
what an independent pass found on top.

## Review

Findings and verification are in [`CLAUDE_REVIEW.md`](./CLAUDE_REVIEW.md).

**Bottom line**: #28 and #29 are clean — no additional issues found. #27
shipped three latent bugs (a credo violation and two dead/broken
`og_resolve` clauses) that this review fixed, plus a stale test assertion.
None were reachable from currently-installed code (the `phoenix_kit_og`
plugin isn't a dependency of this repo yet), but they'd have shipped broken
the moment that plugin lands. All fixed and covered by tests; see the
review doc for detail.

## Already Fixed Pre-Merge (PR #29)

Per the PR's own review thread: a hard dependency on unreleased
`ModuleRegistry.all_reserved_route_prefixes/0` with no version floor bump
(silent full-outage failure mode via the broad `rescue`), a global-registry
test-isolation risk, and fragile fixed-slug test fixtures. All fixed in the
follow-up commit before merge; re-verified here (see review doc).
