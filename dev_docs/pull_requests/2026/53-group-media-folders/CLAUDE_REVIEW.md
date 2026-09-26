# PR #53 Review — Group media folders: file post media into Publishing/<group>, opt-in per host

**Author:** Tymofii Shapovalov <timujeen@gmail.com>
**Reviewer:** Claude (Anthropic)
**Status:** Merged — post-merge review, fixes applied on `main`
**Commit:** `bfbb2b9`
**Date:** 2026-09-26

---

## Verdict

Sound, and carefully built. `MediaFolders` gives each group, and optionally
each post, a folder on core's `Storage.ResourceFolders` convention.
`MediaAdoption` and `mix phoenix_kit_publishing.media.adopt` file media that
existed before the opt-in. `MediaReorganizer` plugs the group folders into
core's `ResourceSource`, and the editor files every pick in a supervised
task. Nothing runs until the host sets `:attachments_parent_folder`. The
PR also fixes a real, older bug in `StaleFixer.fix_stale_group/1` (a stale
struct's whole `data` map overwrote keys written since).

The one defect I found is in the PR's own tests: two of them were
order-flaky and failed in my baseline run. They are fixed.

### What I checked against the source, not the PR description

1. **The post pointer survives a post save.** A post's pointer is
   `data["media_folder_uuid"]` on every version, written with a `jsonb_set`
   `update_all` under the post-row lock. `Posts.persist_post_update/2`
   takes that same lock and then re-reads the version
   (`get_version_by_uuid/1`) before it merges `data`, so a save that was
   loaded before the pick cannot wipe the pointer.
   `DBStorage.create_version_from/3` copies `source.data`, so a new version
   inherits the pointer. That path takes no post-row lock, so it can race a
   pointer write and create a version without the key. This is harmless:
   `post_pointer_query/1` skips versions with no pointer and takes the newest
   version that has one.
2. **Filing cannot pull a file across libraries.** `file_for_post/4` skips
   only system-managed files, but core's `Storage.attach_file_to_folder/2`
   refuses a folder in another library (`{:error, :other_library}`).
   `MediaFolders.rehome/3` moves only files homed in the group's own folder,
   which is in Media. A forged pick of a private-library file is therefore
   logged as "not filed" and changes nothing.
3. **Claims are race-safe as described.** Name locks are taken in sorted
   order, then the owner row is locked and the pointer re-read. `ensure/4`
   runs under a savepoint, so a name core refuses falls back to the
   deterministic name in the same transaction. A group or post deleted in
   the meantime rolls the new folder back (`{0, _}` → `:not_found`).
4. **The editor never blocks or crashes on filing.** `file_for_post/4` is
   wrapped in `guarded/1`, which rescues and catches exits. `start_filing/1`
   falls back to running the filing in place only on an `:exit` (no
   `PhoenixKit.TaskSupervisor`). Without the host hook, the cost is one
   config read.

## Findings

### BUG - MEDIUM — Two media tests were order-flaky — FIXED

Two tests failed in my first full-suite run:

- `media_reorganizer_test.exs` "a folder two trashed groups point at is
  reported once" (reported `Newer`, expected `Older`)
- `media_post_folders_test.exs` "adoption with post folders … the first post
  homing a shared file" (`first` got `link` instead of `adopt`)

Both assert "the older row wins" for two rows created back to back. The
production ordering is `inserted_at` (second precision) and then the uuid.
UUIDv7 is not monotonic within one millisecond, so the tie-break is a coin
flip. The production rule is fine: it is deterministic for a given database.
The tests just can't count on creation order.

**Fix.** A new `MediaFixtures.backdate!/1` moves a group's or post's
`inserted_at` an hour back. Both tests now backdate the row that has to be
older. I ran the four media test files 8 times in a row with no failures.

### NITPICK — `post_folder/1` queries once per version pointer — NOT FIXED

`Enum.find_value(&media_folder/1)` calls `ResourceFolders.live_folder/1`
once for each version that carries a pointer, and usually they all carry the
same uuid. Adding `Enum.uniq/1` before the lookup would make it one query.
It runs once per pick, off the LiveView process, so I left it alone.

### NITPICK — Editor filing logs a warning for another library's file — NOT FIXED

See point 2. Adoption classifies these files as `:other_library` and skips
them silently, while the editor path asks core and logs the refusal. The
picker offers Media files, so this only happens on a forged event. A log
line is the right amount of noise.

### NITPICK — Orphan joins cast every folder uuid — NOT FIXED

`pointer_orphans/1` and `post_orphans/1` join on
`lower(data->>'media_folder_uuid') = f.uuid::text`, which cannot use an
index. They run only from `mix phoenix_kit.media.reorganize`, a manual
maintenance task, so the full scan is acceptable.

## Validation

`mix precommit` is clean. `mix test` passes: 1801 tests, 0 failures. In a
20-run stability loop, 19 runs were clean and 1 run had a single failure
that I could not reproduce in the next 16 runs. The output of that run was
not captured, so I can't name the test. This matches the sandbox and
activity-log timing flake already documented in AGENTS.md.
