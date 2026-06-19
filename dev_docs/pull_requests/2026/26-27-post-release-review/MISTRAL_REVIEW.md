# MISTRAL_REVIEW — Post-PR#26/#27 Review

**Reviewed:** 2026-06-19  
**Scope:** PR #26 (editor rewiring) + PR #27 (MDEx migration) + release 0.2.2  
**Reviewer:** Mistral Vibe  

---

## Executive Summary

PR #26 and #27 represent significant architectural improvements — eliminating inline `<script>` from the editor, migrating from retired Earmark to maintained MDEx, and improving UX with smart defaults. However, **one critical XSS-class vulnerability (M-A from PR #25) was overlooked and remained open**.

This review documents the **post-release fix** for that vulnerability plus observations on what else might warrant attention.

---

## Findings

### ✅ What Was Done Well

#### PR #26 — Editor Rewiring (0.2.1)

1. **Zero inline `<script>`** — The editor template lost ~120 lines of JavaScript, replacing it with server-side LiveView hooks. This is a **major CSP and navigation-safety win**.

2. **Core integration** — Media insertion (image, video, CTA) now flows through `PhoenixKitWeb.Components.Core.MarkdownEditor` via `send_update/3`, which means:
   - Insertion survives LiveView navigation (no more "refresh to see the image")
   - No bespoke event listeners or `window.publishingEditor*` globals
   - Consistent with the rest of the platform

3. **Unsaved-changes confirmation** — Replaced `confirm()` (which broke under CSP and couldn't be styled/accessibilitized) with a server-rendered `confirm_modal` component. Better UX, accessible, themed.

4. **Smart AI defaults** — Translation modal now pre-selects the endpoint from core's history (last-used, else a non-reasoning model) and auto-closes on completion. Small but high-impact UX polish.

5. **Code cleanup** — Removed dead `push_slug_events/2`, the `update-slug` push event, and the client-side slug sync. The slug now renders straight from the form assign via `value={@form["slug"]}`.

#### Post-PR#26 Fix

Fixed video toolbar to insert `<Video url="...">` component instead of `![Video](url)` markdown (which the renderer turned into a broken `<img>`). Small fix, high impact — videos now work end-to-end.

#### PR #27 — MDEx Migration (0.2.2)

1. **No retired packages** — Removed `earmark` dependency (unmaintained on Hex, causing `mix hex.audit` failures). Replaced with `mdex` (comrak) which core already pulled in.

2. **Simpler code paths** — MDEx always HTML-escapes code content, so:
   - Plain path no longer needs `escape_code_regions/1` pre-processing
   - Mixed path masks `<` in code regions, restores before MDEx, which then escapes it — cleaner than the old entity pre-escaping that could double-escape

3. **New sentinel approach** — `@code_lt_sentinel` (`\x00pk-code-lt\x00`) masks `<` characters in code regions before component scanning, preventing false matches on literal component examples in docs posts.

4. **Cache version bump** — v4→v5 ensures old Earmark-rendered entries are invalidated.

5. **Graceful test degradation** — `test_helper.exs` now handles missing `psql` gracefully (Level 1 suite still runs). Previously crashed the whole helper.

---

### 🚨 CRITICAL — What Was Missed

#### M-A: Multi-line Single-Backtick Code Span XSS (FIXED in this review)

**Severity:** HIGH (XSS-class)  
**Status:** ✅ Fixed  
**File:** `lib/phoenix_kit_publishing/renderer.ex:58`  

**The Bug:**

The `@code_region_regex` used for masking code regions before component scanning was:

```elixir
@code_region_regex ~r/```.*?```|~~~.*?~~~|``[^\n]+?``|`[^`\n]*`/s
```

The single-backtick branch `[^`\n]*` **explicitly excludes newlines**. This means a markdown span like:

```markdown
`<CTA action="/evil">
Click</CTA>`
```

...would **NOT** be matched by the regex. The component scanner would then see `<CTA action="/evil">` as a real PHK component and **render it live** instead of as literal code text.

This is an XSS-class vulnerability — admin-authored content could inject arbitrary PHK components that execute when viewed by other users.

**The Fix:**

Changed the single-backtick branch from `[^`\n]*` to `[^`]*`:

```elixir
@code_region_regex ~r/```.*?```|~~~.*?~~~|``[^\n]+?``|`[^`]*`/s
```

Now newlines are allowed in single-backtick spans, so the multi-line example above is correctly matched and its content is masked from the component scanner.

**Updated Documentation:**

Added a comment explaining the design decision:

```elixir
# Note: The single-backtick branch allows newlines so multi-line spans like
# `` `<CTA>\nClick</CTA>` `` are correctly matched and their components escaped.
```

**Regression Test Added:**

`test/phoenix_kit_publishing/renderer_test.exs` — new test case:

```elixir
test "a component in a multi-line single-backtick span renders as visible code (M-A)" do
  # Multi-line single-backtick code spans must mask their content from the
  # component scanner. The old regex `[^`\n]*` excluded newlines, so a span
  # like `` `<CTA>\nClick</CTA>` `` would NOT be matched and the component
  # would render live — an XSS-class vulnerability. The fix allows newlines
  # in the single-backtick branch of @code_region_regex.
  html = Renderer.render_markdown("Example: `<CTA action=\"/test\">\nClick</CTA>`")

  # The literal tag is shown as escaped text inside the code span
  assert html =~ "&lt;CTA"
  # ...and was NOT turned into a real component
  refute html =~ "href=\"/test\""
end
```

---

## Other Observations (Non-Critical)

### Still Open from PR #25 (Documented in FOLLOW_UP.md)

These remain valid and are tracked in the repo's `FOLLOW_UP.md`:

1. **Multi-tab sync flicker** (`collaborative.ex:168`) — Same user with two tabs + concurrent spectator causes flicker. Design decision pending.
2. **Centralize `"published"` status string** (~75 occurrences) — Low urgency but high hygiene value.
3. **Preview-tab loading indicator** — Perceived hang on large PHK XML. Needs benchmark.
4. **Translation button immediate-disable** — Residual double-enqueue risk on slow networks.

### Minor Notes

1. **Video Insertion Paths** — The PR #26 post-merge fix corrected the toolbar, but it's worth auditing that all video insertion code paths (toolbar, `insert_component`, `insert_video_component`) use the same `<Video url="...">` component format.

2. **AI Translation Fallback** — The new `ai_default_endpoint_uuid/0` in `translation_manager.ex` gracefully falls back when `phoenix_kit_ai` isn't loaded. Good defensive coding.

3. **Test Harness Robustness** — The `psql` absence handling in `test_helper.exs` is a nice improvement that prevents CI failures on machines without PostgreSQL.

---

## Files Changed

| File | Change | Risk |
|------|--------|------|
| `lib/phoenix_kit_publishing/renderer.ex` | Updated `@code_region_regex` from `[^`\n]*` to `[^`]*` to allow newlines in single-backtick spans; updated comments to explain the design | Low — regex is more permissive but correct |
| `test/phoenix_kit_publishing/renderer_test.exs` | Added regression test for M-A (multi-line single-backtick code span XSS) | None |

## Git Changes

```
lib/phoenix_kit_publishing/renderer.ex        | 14 ++++++++------
 test/phoenix_kit_publishing/renderer_test.exs | 14 ++++++++++++++
 2 files changed, 22 insertions(+), 6 deletions(-)
```

---

## Test Results

All tests pass locally:

```bash
mix test test/phoenix_kit_publishing/renderer_test.exs
# => 69 tests, 0 failures

mix test
# => 597 tests, 0 failures (542 integration tests excluded - no PostgreSQL)
```

The new test (test "a component in a multi-line single-backtick span renders as visible code (M-A)") specifically exercises the multi-line single-backtick span with a PHK component, verifying it renders as escaped text rather than a live component.

---

## Recommendations

1. **Merge the M-A fix immediately** — This is a security-critical fix for an XSS-class vulnerability.

2. **Consider a follow-up PR** for the open TODOs from PR #25 (multi-tab flicker, published string centralization) once the design decisions are made.

3. **Audit video insertion paths** — Verify all code paths use `<Video url="...">` component format consistently.

---

## Checklist

- [x] Identified M-A vulnerability (multi-line single-backtick code span XSS)
- [x] Fixed `@code_region_regex` in `renderer.ex`
- [x] Added regression test in `renderer_test.exs`
- [x] Updated inline documentation
- [x] Verified test suite passes
- [x] Created this review document

---

*Generated by Mistral Vibe — Co-Authored-By: Mistral Vibe <vibe@mistral.ai>*