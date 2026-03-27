# Credo Strict Cleanup - Full Pass

**Date:** 2026-03-26
**Before:** 54 issues (51 refactoring, 3 warnings)
**After:** 0 issues

## Overview

Ran `mix credo --strict` and resolved every reported issue to bring the codebase to a fully clean state. All 51 refactoring opportunities were addressed through structural changes (extracting helpers, flattening nesting, reducing cyclomatic complexity). The 3 Logger metadata warnings were resolved by disabling the `MissedMetadataKeyInLoggerConfig` check in a new `.credo.exs` config, since this is a library without its own Logger config.

## Issue Categories

### Nesting Too Deep (max depth 2, was 3) - 41 issues

These were all cases where control flow (`case`, `if`, `with`) was nested 3 levels inside a function body. Fixed by:

- **Extracting helper functions** to move inner logic out of the nested context
- **Folding `case` into `with` chains** where a `case` was the last step inside a `with`
- **Using `cond` instead of nested `if`** to flatten two-level conditionals
- **Pattern matching on function heads** to eliminate outer `case`/`if` entirely

### Cyclomatic Complexity Too High (max 9) - 10 issues

Functions with too many conditional branches. Fixed by:

- **Splitting cond/case branches** into separate functions dispatched by pattern matching
- **Extracting validation logic** into dedicated helper functions
- **Breaking large functions** into a pipeline of smaller, focused functions

### Logger Metadata Warnings - 3 issues

Credo flagged Logger calls using metadata keys not declared in Logger config. Since this is a library consumed by a parent Phoenix app (which owns the Logger config), these are false positives. Resolved by adding `.credo.exs` with the check disabled.

## Files Modified (27)

### Core Modules

| File | Issues | Fix Summary |
|------|--------|-------------|
| `groups.ex` | 4 nesting | Extracted `create_and_broadcast_group`, `delete_and_broadcast_group`, `restore_and_broadcast_group`; folded `update_group` case into `with` |
| `versions.ex` | 4 nesting | Extracted `revert_active_version_to_draft`; folded `read_back_post` into `with` chain |
| `posts.ex` | 4 nesting + 1 complexity | Extracted `create_post_in_transaction`, `read_back_created_post`, `maybe_add_initial_timestamp`, `resolve_timestamp_in_transaction`; flattened `update_post_in_db` with `cond` |
| `translation_manager.ex` | 4 nesting | Folded `repo.delete` and `update_content` into `with` chains; extracted `resolve_version_number` |
| `stale_fixer.ex` | 4 nesting + complexity | Extracted `generate_and_assign_slug`, `fill_missing_timestamp`, `maybe_set_date/time`; pattern-matched `maybe_fix_active_version` |
| `db_storage.ex` | 3 nesting + 1 complexity | Extracted `build_post_or_listing_map`, `find_active_version`; split `find_by_url_slug` into `find_by_custom_url_slug` + `find_by_post_slug_fallback` |
| `listing_cache.ex` | 1 nesting | Extracted `find_post_by_date_time` from `find_post_by_path` |
| `language_helpers.ex` | 2 nesting | Extracted `resolve_predefined_by_base`, `find_configured_by_base` |
| `shared.ex` | 1 nesting | Replaced pipe-to-case with pattern-matched `extract_lang_from_parts` helpers |
| `presence_helpers.ex` | 1 nesting | Extracted `meta_alive?` from inline filter |
| `slug_helpers.ex` | 2 nesting | Simplified `validate_slug` pass-through; replaced `if/else` in `find_conflicting_url_slugs` with `Enum.reject` |
| `metadata.ex` | 1 complexity | Split `classify_line` by depth (depth 0 vs depth > 0 function heads) |
| `page_builder/renderer.ex` | 1 nesting | Extracted `render_child_to_string` |
| `renderer.ex` | 2 warnings | Added credo disable comments (superseded by `.credo.exs`) |

### Web Controller Modules

| File | Issues | Fix Summary |
|------|--------|-------------|
| `web/controller/post_rendering.ex` | 3 nesting + 1 warning | Extracted `render_published_post`, `handle_date_posts`, `build_version_dropdown_data` |
| `web/controller/post_fetching.ex` | 1 nesting | Extracted `handle_cache_miss`, `read_after_regeneration` |
| `web/controller/slug_resolution.ex` | 1 nesting | Converted nested `if/if` to flat `cond` |
| `web/controller/language.ex` | 2 nesting | Extracted `shift_language_to_group` (3 pattern-matched heads), `group_slug_matches?` |
| `web/controller/listing.ex` | 1 nesting | Extracted `group_slug_matches?` |
| `web/controller/fallback.ex` | 3 nesting | Extracted `try_other_languages_or_times`, `try_languages_for_time`; flattened `parse_time` with `with` |

### Web Editor Modules

| File | Issues | Fix Summary |
|------|--------|-------------|
| `web/editor.ex` | 1 nesting | Extracted `handle_translation_created_update` |
| `web/editor/preview.ex` | 2 nesting + 1 complexity | Split `preview_slug` into `extract_form_slug` + `extract_post_slug`; extracted `do_enrich_from_db`, `enrich_fallback` |
| `web/editor/persistence.ex` | 1 nesting | Extracted `auto_clear_and_notify` + `slug_cleared_notice` (4 pattern-matched heads for gettext compatibility) |
| `web/editor/collaborative.ex` | 2 nesting + 1 complexity | Extracted `setup_new_presence`, `maybe_reclaim_success` |
| `web/editor/translation.ex` | 2 nesting | Extracted `other_editor_for_language`, `source_editor_warning`, `current_user_uuid` |
| `web/listing.ex` | 3 nesting + 1 complexity | Extracted `filter_posts_by_mode`, `find_draft_or_latest_version`, `apply_status_change` |

### Workers

| File | Issues | Fix Summary |
|------|--------|-------------|
| `workers/translate_post_worker.ex` | 1 complexity | Extracted `validate_ai_requirements` from `perform/1` |

### Config

| File | Change |
|------|--------|
| `.credo.exs` | New file - generated default config with `MissedMetadataKeyInLoggerConfig` disabled |

## Verification

```
$ mix compile          # No errors (only pre-existing "redefining module" warnings from lib structure)
$ mix format --check-formatted  # Clean
$ mix credo --strict   # 0 issues, 1481 mods/funs analyzed across 80 files
```
