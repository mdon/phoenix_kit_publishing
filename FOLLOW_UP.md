# Follow-up — adversarial full-module audit

After-action report for the audit-driven work on `phoenix_kit_publishing`. All work is
local commits on top of `5e4582a`; nothing pushed. Suite (integration tier running):
**1132 tests, 0 failures**; `mix format`, `mix credo --strict`, `mix dialyzer` clean.

> The integration tier (`:integration`, ~520 tests) only runs when the Postgres test DB
> exists — it does here, so every fix below was exercised against the DB tier.

## Fixed (with regression tests unless noted)

**High:** H1 supervise the render cache · H2 write `previous_url_slugs` (301s) ·
H3 router host-route-hijack + method gate · H4/H5 two infinite-redirect loops ·
H6 spectator write guards · H8 version dropdown (mapper field) · H9 reload version-pinning.

**Medium:** M1 timestamp-collision retry (constraint-name match) · M2 trashed-slot
availability · M3 transactional post update · M4 atomic publish + StaleFixer demotion
heal · M5 remove dead per-post SEO/OG scaffolding · M6 cross-group UUID access ·
M7 cross-node cache invalidation (clustering) · M8 supervised lock-table + crash-proof
guard · M9 trash-not-delete + featured-image emptiness + ActivityLog · M10/M11/M12 code-
region integrity / multi-line `<Image>` / consistent escaping · M13 incumbent-wins
collisions + previous-slug containment + explain-and-link conflict modal · M14 remote-pid-
safe presence (clustering) · M15 stale translation lock · M16 admin-insight cache flip.

**Low + nits:** L1 switch_version crash · L2 preview save-failure · L3 unpublish pre-lock
read · L4 transactional blank-version · L6 group-rename cache invalidation · L8 double-
backtick code spans · L9 preserve unresolved `{{placeholder}}` · L11 narrowed update
rescue · title `phx-debounce` · canonical/302 query-string preservation · reserved route
words on post/group slugs.

**H7 (boss-approved):** removed `<Hero>`/`<Page>` — they resolved to core modules deleted
with the Pages module (core 0fc3de09).

**Docs:** unique-index TODO in this `AGENTS.md`; signed file-URL hardening note in core
`AGENTS.md`.

## Surfaced — NOT changed (your call)

- **L5 — timestamp timezone inconsistency.** Creation stamps UTC, but editing
  `published_at` (a `datetime-local` input) appends `:00Z`, treating the browser's local
  wall-clock as UTC (`forms.ex` ~159). Created vs edited posts can disagree about which
  day they live under. The correct fix needs the browser's TZ offset (or sending UTC from
  the client) — a real design decision, and a rushed timezone change risks making it
  worse. Recommend we decide the canonical behavior together.
- **L7 — re-enabling the memory cache can serve pre-disable data.** While disabled, reads
  already return `:cache_miss` (no stale serve); the gap is the brief window after
  re-enabling before regeneration, since old `:persistent_term` entries were never erased.
  Fixing it well means erasing across all groups on toggle (not trivially enumerable) —
  worth a small dedicated change, not a tail-of-session patch.
- **L10 — stale-lock takeover can be undone by a slow original holder.** The lock's
  `after: :ets.delete` is unconditional, so a slow original holder can delete the
  taker's lock → a brief *duplicate* regeneration (the reviewer confirmed: not
  corruption). Fixing it cleanly needs a per-acquisition lock token.
- **L12 — `:persistent_term` write churn.** Every save rebuilds the listing term + writes
  two always-changing timestamp terms, and each `:persistent_term.put` triggers a global
  GC pass — recurring whole-VM pause pressure with large listings + autosave traffic. The
  cheap win is folding the timestamps into the posts term; it's a perf refactor that only
  bites at scale.
- **M13 inline cross-post slug edit** — the conflict modal names + links the other post;
  editing *its* slug from inside the modal (cross-post mutation: its version, its previous-
  slug recording, its cache, concurrent-edit handling) is a tracked follow-up.
- **M13 #1 / core signed-URLs** — documented as TODOs (publishing + core `AGENTS.md`),
  both needing a migration / core changes.

Each of the four Lows above is a deliberate "surface, don't rush" — say the word on any
and I'll do it as a focused change with its own tests.
