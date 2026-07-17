# PR #32 — Multi-AI quorum review (2026-07-17)

Panel: **Codex** (OpenAI gpt-5.5), **Kimi** (Moonshot), **Grok** (xAI), **ZAI**
(GLM-5.2), **Vibe** (Mistral Devstral) — each given the full `b9442f8..c9c7d54`
unified diff with the same bugs/security/quality brief. Gemini (agy) was
quota-exhausted for the day; MiniMax (m2) remains 402-broken. In parallel,
four Explore triage agents ran the quality-sweep playbook lenses (security +
async UX / i18n + activity + tests / cleanliness + API / host-integration
boundaries) against the working tree.

Verdicts: Codex REQUEST CHANGES · Kimi request changes · Grok "solid but
incomplete i18n + API bug" · ZAI mergeable-with-quality-items · Vibe no
findings.

## Confirmed findings (fixed in the follow-up commits)

| # | Severity | Finding | Found by | Verified |
|---|----------|---------|----------|----------|
| 1 | MED | Translated group name only reached the listing h1/title/breadcrumb — post-page breadcrumb + "Back to …" footer (`fetch_group_name/1` → raw `name`), listing `og:title` (controller.ex:251), and the all-groups overview cards all showed the primary-language name | Grok, Codex, Kimi + 2 triage agents | ✔ file:line |
| 2 | MED | `GroupSettings.validate_params/1` normalized atom-keyed settings but kept the atom key — `update_group/3` (string-keyed) then silently persisted nothing on the documented AI/script path | Grok, Codex, Kimi | ✔ repro reasoning |
| 3 | MED | `merge_name_i18n/2` called `to_string/1` on override values — a nested map (crafted `group[name_i18n][en][x]=y` params or programmatic caller) raised `Protocol.UndefinedError`, crashing the edit LV (outside its narrowed rescue) | security triage agent | ✔ code path |
| 4 | MED | Featured hero/card articles carried no `data-post-date`, so the timeline rail was blind to them (a featured-only page built no rail); grid cards preferred `metadata.published_at` over the effective `post.date`, so rail bins could disagree with the visible/sorted date | Grok, Codex | ✔ grep |
| 5 | MED | Editor featured checkbox: hidden `featured=false` input stayed enabled while the checkbox disabled — a still-enabled sibling control (status select) would serialize `featured=false` and clobber the flag. **Latent**, not live: `viewing_older_version?/3` currently always returns false and `readonly?` is server-guarded (ZAI correctly called "no live trigger"); fixed as defense-in-depth with the merge semantics pinned by test | Codex, Kimi (disputed by ZAI) | ✔ markup + handler audit |
| 6 | LOW | `name_i18n` overrides bypassed the 255-char primary-name limit | Codex | ✔ |
| 7 | LOW | `reading_time_label/1` used `gettext` with `%{count}` — not pluralizable (`ngettext` now) | i18n triage agent, Kimi | ✔ |
| 8 | LOW | Timeline-rail month labels + both rails' aria-labels hardcoded English inside the static JS on fully-localized public pages | i18n triage agent (+ own review) | ✔ |
| 9 | LOW | `assign_scroll_config/2` re-fetched the group (post pages fetched twice per request) and re-declared setting defaults as literals instead of `Constants` (lone drift exception) | Codex, ZAI | ✔ |
| 10 | MED | Spec-parity test compared `GroupSettings.keys()` against a hardcoded `~w()` copy, not the real write path — drift-blind | cleanliness triage agent | ✔ |
| 11 | LOW | `default_config/0` accessor-parity test omitted `show_post_count` | Grok, cleanliness agent | ✔ |
| 12 | MED | Featured vs grid card markup near-duplicated in html.ex (excerpt + date/read-more blocks verbatim ×2) | cleanliness agent | ✔ |
| 13 | LOW | `all_groups/1` rendered `Publishing` / "Explore our published content" unwrapped (pre-existing, in-scope per module-wide brief) | i18n agent | ✔ |
| 14 | LOW | Group save double-broadcast: `Groups.update_group/3` AND the edit LV both fired `broadcast_group_updated` (pre-existing) | cleanliness agent | ✔ |
| 15 | LOW | `translated_group_name/2` missing `@spec`; `GroupSettings.cast_value` enum branch crashed on non-String.Chars input | cleanliness + own | ✔ |
| 16 | — | 57 admin/public strings per locale never extracted (server env couldn't run gettext); catalogs merged + translated (en identity, et/fr/it/ru filled) | i18n agent | ✔ |
| 17 | MED (tests) | No public-render coverage for ANY setting toggle; sort/partition, settings + name_i18n persistence, edit-LV switch_language/save paths untested | i18n/tests agent | ✔ |

## Rejected / skipped findings (with rationale)

- **Breadcrumbs + post count default-off changes existing pages** (Grok MED):
  deliberate per the commit messages ("off by default" was the design goal);
  the PR body's "pages look unchanged" claim was corrected instead, and
  AGENTS.md documents it as a default-off migration.
- **`featured_enabled` default true vs "all off/neutral" docs** (Grok/Kimi
  LOW): kept — inert until a post is flagged, i.e. visually neutral; AGENTS.md
  wording now states the nuance explicitly.
- **Inline `<script>`/`<style>` vs strict-CSP hosts** (ZAI MED, security
  agent LOW): kept inline by design — public pages are dead views (full page
  loads, no LiveView nav issue), the blocks are static with zero interpolation,
  and moving them into core's hook bundle would trade the CSP edge case for a
  hard dependency on host installer wiring. Documented as a host contract in
  AGENTS.md. Revisit if a real strict-CSP host adopts the module.
- **Window-must-own-scroll assumption** (boundary agent MED): inherent to the
  document-level design; documented as host contract in AGENTS.md.
- **`update_group` lenient vs `validate_group_settings` strict** (Grok/Codex
  LOW): by design — the admin-form path must not fail on settings; programmatic
  callers validate first. Documented in AGENTS.md.
- **"oldest" sort over the 5,000-post listing-cache cap** (Codex LOW):
  documented limitation, not fixed — the cache bound predates the PR.
- **`listing_sort_key` timestamp-mode key lacks a tz suffix vs slug-mode's
  `Z`** (cleanliness agent LOW): groups are single-mode by design; the two key
  shapes never sort against each other.
- **`PublishingGroup.translated_name/2` has no internal callers** (cleanliness
  agent LOW): kept — documented public API for struct-holding hosts; the map
  variant is the internal path.
- **Warm ListingCache rows lack the `featured` key until rebuilt** (boundary
  agent LOW): transient deploy-time state, self-heals on next cache write —
  mirrors the existing `allow_version_access` warm-cache note in mapper.ex.
- **Featured-flag normalization exists in three layers** (Kimi LOW): the three
  sites have genuinely different semantics (nil-preserving version write vs
  checkbox idiom vs settings bool) — unifying would couple layers for no
  behavior change.
