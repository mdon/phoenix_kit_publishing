# PR #20 — Defensive fallback for non-binary input to `parse_translated_response/1`

**Status:** Merged
**Branch:** `followup-parse-response-non-binary-fallback`

## Goal

After PR #19 refactored `TranslatePostWorker.parse_translated_response/1` to
delegate to core's `Translation.parse_response/2`, the function became
binary-input-only — `parse_response/2` carries an `is_binary/1` guard and
raises `FunctionClauseError` on `nil` / atom / number input.

Because `parse_translated_response/1` is `def` (public for testing), a test
or external caller can still hand it anything. This PR restores the
pre-refactor defensive posture.

## Changes

- Split the public function into a `when is_binary(response)` clause and a
  catch-all `other` clause that **fails closed** — returns the empty-tuple
  shape `{"", nil, ""}` instead of crashing.
- The fallback emits a `Logger.warning` so a production occurrence is
  operator-visible (it would otherwise persist a blank translation row).
- Added `describe_type/1`, a **log-safe** shape descriptor that reports a
  value's *type/shape only* — never its contents — to avoid leaking PII /
  API keys from pathological inputs.
- Added `proper_list?/1` so `describe_type/1` doesn't itself crash on
  improper lists (`length/1` raises `ArgumentError` on `[:a | :b]`).

## Related PRs

- Previous: [#19](/dev_docs/pull_requests/2026) (delegated parsing to core `Translation.parse_response/2`)
