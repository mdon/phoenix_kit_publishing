# PR #20 — Follow-up

PR is merged into `main` (merge commit `b68b68f`, version bump landed
in `6cc6511` → 0.1.13). Companion `CLAUDE_REVIEW.md` + `README.md`
in this folder.

## Fixed (post-merge, on `main`)

- **NITPICK — idiomatic `nil` head.** `describe_type(v) when is_nil(v)`
  → literal head `describe_type(nil)`. `nil` is still matched before
  the `is_atom/1` clause, same as before — pure style cleanup.
  (commit `29dbeb7`)
- **IMPROVEMENT — coverage gap on non-byte-aligned bitstring.** Added
  `describe_type(v) when is_bitstring(v), do: "bitstring"`. The
  public `parse_translated_response/1` clause already handles
  `is_binary/1` (a byte-aligned bitstring), so only a non-aligned
  bitstring like `<<1::3>>` can reach the fallback. Previously
  reported as `"unknown"`. Test extended with the matching assertion.
  (commit `29dbeb7`)

## Skipped — recorded for team decision

- **Fail-closed (blank row) vs. fail-loud (error tuple).** When the
  AI provider returns `"content": null`, `AI.extract_content/1`
  produces `{:ok, nil}` and the fallback fires in production —
  persisting a blank translation row with only a `Logger.warning`
  as signal. The "AI extract pipeline always feeds us strings"
  comment in the worker is slightly optimistic.

  - **Argument to keep fail-closed (current):** a non-binary is a
    *type* error, not a transient failure, so an Oban retry wouldn't
    help; the warning preserves observability without losing the
    rest of the batch.
  - **Argument to fail loud:** a persisted blank row is a
    data-quality problem that may go unnoticed despite the log line;
    overwrites and duplicates are harder to detect after the fact
    than a failed job.

  Surfaced to Max as a behavior/product call rather than a
  correctness bug. No code change in this pass; documented here so
  the next maintainer touching the worker doesn't re-derive the
  question.

## Files touched

| File | Change |
| --- | --- |
| `lib/phoenix_kit_publishing/workers/translate_post_worker.ex` | `nil` literal head; `+is_bitstring/1` clause |
| `test/phoenix_kit_publishing/translate_post_worker_test.exs` | `+1` bitstring assertion in the fallback log test |
| `dev_docs/pull_requests/2026/20-parse-response-non-binary-fallback/CLAUDE_REVIEW.md` | Post-merge review |
| `dev_docs/pull_requests/2026/20-parse-response-non-binary-fallback/README.md` | PR overview |

## Verification

- `mix compile --warnings-as-errors` — clean
- `mix format --check-formatted` — clean
- `mix dialyzer` — 0 errors
- `mix test test/phoenix_kit_publishing/translate_post_worker_test.exs` — 41/41 pass
  (post-merge run; the test file is pure unit tests on
  `parse_translated_response/1` and needs no DB)

## Open

None. The fail-closed-vs-fail-loud item is a decision surfaced to
Max, not an unfixed finding.
