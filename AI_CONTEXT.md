# AI Context: Histdb Fish-Like Autosuggestion Strategy

## Summary

Implemented a new `zsh-autosuggestions` strategy called `histdb_fish_like` that queries the `zsh-histdb` SQLite database to provide contextual, directory-aware, ranked autosuggestions (similar to Fish shell).

## Files

| File | Description |
|------|-------------|
| `src/strategies/histdb_fish_like.zsh` | Strategy implementation (77 lines) |
| `zsh-autosuggestions.zsh` | Built plugin bundle (regenerated via `make`) |
| `AI_PLAN.md` | Original implementation plan (reference only) |

## Architecture

```
prefix → SQLite query with Fish-like scoring → best match via typeset -g suggestion
```

The strategy is a single function `_zsh_autosuggest_strategy_histdb_fish_like` that delegates all scoring to SQLite. It uses a three-level subquery:

1. **Inner**: Gets up to `max_rows` (default 500) candidate `command_id`s matching `prefix%`, with aggregates (count, max start_time) and correlated subqueries for cwd match, parent dir match, and last exit status
2. **Middle**: Computes a composite score for each candidate
3. **Outer**: Filters by `min_score`, joins to `commands` for argv, returns top 1

## Scoring Formula

```
score = cwd_weight * cwd_match
      + parent_weight * parent_match
      + freq_weight * frequency
      + recency_weight * MAX(0, 1 - elapsed/halflife)
      + success_weight * (exit == 0 ? 1 : 0)
      - failure_penalty * (exit != 0 ? 1 : 0)
```

## Configurable Variables

| Variable | Default | Description |
|---|---|---|
| `ZSH_AUTOSUGGEST_HISTDB_CWD_WEIGHT` | 100 | Boost for commands used in exact current directory |
| `ZSH_AUTOSUGGEST_HISTDB_PARENT_WEIGHT` | 50 | Boost for commands used in parent directories |
| `ZSH_AUTOSUGGEST_HISTDB_RECENCY_WEIGHT` | 30 | Weight for recency |
| `ZSH_AUTOSUGGEST_HISTDB_FREQUENCY_WEIGHT` | 20 | Weight for how often command is used |
| `ZSH_AUTOSUGGEST_HISTDB_SUCCESS_WEIGHT` | 10 | Boost for exit_status = 0 |
| `ZSH_AUTOSUGGEST_HISTDB_FAILURE_PENALTY` | 15 | Penalty for exit_status != 0 |
| `ZSH_AUTOSUGGEST_HISTDB_MIN_SCORE` | 10 | Minimum score threshold |
| `ZSH_AUTOSUGGEST_HISTDB_MAX_ROWS` | 500 | Max rows for inner query LIMIT |
| `ZSH_AUTOSUGGEST_HISTDB_RECENCY_HALFLIFE` | 604800 | Recency half-life in seconds (1 week) |

## Dependencies

- `zsh-histdb` plugin must be loaded **before** the strategy runs (provides `_histdb_query`, `sql_escape`, `HISTDB_FILE`)
- `zsh-autosuggestions` plugin must be loaded

## User Configuration

In `.zshrc`:

```zsh
plugins=(zsh-histdb zsh-autosuggestions ...)
ZSH_AUTOSUGGEST_STRATEGY=(histdb_fish_like history)
```

## Defensive Behaviors

- Silently returns empty if `_histdb_query` function is not defined
- Silently returns empty if `HISTDB_FILE` is not set
- Post-filters result to ensure it starts with the typed prefix
- Respects `ZSH_AUTOSUGGEST_HISTORY_IGNORE` glob pattern
- Score below `min_score` is filtered in SQL (outer WHERE clause)

## Out of Scope (per AI_PLAN.md)

- Completion integration
- Git/branch awareness
- Filesystem validation (`[[ -e path ]]`)
- Custom storage layer

## Known Issues / Future Work

- **Correlated subqueries** for `cwd_match` and `parent_dir_match` may be slow on very large histories (>100k rows). If so, rewrite them as JOINs or use `EXISTS` (already using `SELECT 1 ... LIMIT 1` which is equivalent).
- **Recency decay** uses a linear approximation (`MAX(0, 1 - elapsed/halflife)`) instead of true exponential decay. SQLite3 has `exp()` but it may not be available in all builds.
- **Empty prefix** is handled gracefully (LIKE `'%%'` matches everything) but zsh-autosuggestions typically doesn't call strategies with empty buffers.
