# PR #24 — Claude review (post-merge follow-up)

Independent review of the merged PR #24 surface — a five-commit sweep over the
publishing editor + public rendering (inline `<Image>` components, legacy
signed-file URL healing, in-page OpenGraph, descriptive error flashes, slug-cap
safety). Reviewed with the Phoenix/Ecto thinking skills. Scope: find issues we
can fix ourselves.

Overall a high-quality PR — well-scoped commits, ~30 tests, careful security
hygiene (HEEx escaping tested, heal regex bounded against external URLs, the
client-side `eval()` removed). Refactors are clean: no dangling
`get_file_url` / `phx:exec-js` / `URLSigner`-in-helpers references, and it
compiles. One real bug found and fixed; a few minor notes left for later.

## Findings

### 1. `safe_to_string/1` rescue too narrow — list-valued Ecto opts crash the flash (bug — MEDIUM, fixed)

`lib/phoenix_kit_publishing/errors.ex`. The new `%Ecto.Changeset{}` clause
humanizes field errors for the flash, and `safe_to_string/1` exists so that
"building the flash must never crash." It rescued only `Protocol.UndefinedError`
— which covers tuple opts like `{:array, :string}` (there's a test for exactly
that) — but a **list** opt value raises `ArgumentError`, not
`Protocol.UndefinedError`, so it sailed through the rescue and crashed the
LiveView event.

This is reachable: the changeset clause is wired into many sinks (e.g.
`persistence.ex` calls `Errors.message(changeset)` directly on post-creation
errors), and `validate_inclusion` / `validate_subset` or any
`add_error(cs, f, "… %{allowed}", allowed: [...])` puts a list in the opts.
Reproduced against the compiled module:

```
# changeset error opt: allowed: [:draft, :published]
# before: CRASHED: ArgumentError - cannot convert the given list to a string.
# after:  RESULT: "Tags must be one of [:draft, :published]"
```

So a changeset reaching the UI with a list-valued error opt crashed the exact
path this code was written to make crash-proof.

**Fix:** broaden the rescue to `rescue _ -> inspect(value)`, matching the stated
intent (`to_string/1` rejects → fall back to `inspect/1`). Regression test added
in `errors_test.exs` alongside the existing `{:array, :string}` case.

## Not changed (noted, lower priority)

- **`humanize_field/1` lowercases acronyms** (`errors.ex`).
  `String.capitalize("url slug")` → `"Url slug"`, `"seo title"` →
  `"Seo title"`. Cosmetic, but user-facing. Capitalizing only the first
  character would preserve `URL` / `SEO`.

- **In-page OpenGraph defaults on → duplicate tags for hosts that already
  render `:og` in `<head>`** (commit #4). The `module_assigns` pass-along is
  unchanged and the in-page copy defaults to `true`, so a host that *does*
  render the forwarded `:og` emits duplicate og/twitter tags until an admin
  flips the new `publishing_render_og_tags` toggle. Default-on is the right call
  for the "zero host setup" goal; the duplicate-for-existing-hosts case is
  silent but documented in `AGENTS.md`.

- **Slug-truncation warning cleared by the next unrelated keystroke**
  (`forms.ex` + `editor.ex`). `update_meta` now `clear_flash`es up front; if the
  title is still over-cap but the user edits another field,
  `maybe_warn_slug_truncated` sees `already? == true` and no-ops, so the warning
  disappears even though the slug is still truncated. Non-blocking/informational,
  so acceptable.

- **Brittle test assertion** (`editor_live_test.exs`):
  `assert html =~ "does not exist"` couples the test to PostgreSQL's FK error
  wording. The neighbouring `refute html =~ "Failed to save post"` and
  `"save this post."` assertions already prove the behaviour.

## Verified correct (checked, no change needed)

- **Heal regex matches `URLSigner`'s real output** — tokens are exactly 4
  lowercase hex chars (`String.slice(0..3)` of an MD5), so `[0-9a-fA-F]{4}"` is
  right. No ReDoS: segments are `/`-delimited and `/` isn't in the char class,
  so no ambiguous backtracking. External / protocol-relative / query-string
  URLs correctly excluded (tested).
- **Render cache key** now folds in `url_prefix_marker` + `signer_marker` (both
  rescued), so a prefix change or `secret_key_base` rotation invalidates stale
  image URLs; the `v3` bump drops old entries.
- **`clear_flash` relocation** is safe: `assign_meta_updates` has exactly one
  caller (`update_meta`), which now clears at the top of the handler.
- **XSS** — og values and image `alt` text are escaped/sanitized, both tested.
