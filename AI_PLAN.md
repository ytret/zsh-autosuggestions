# Implementation Plan: Fish-Like Histdb Autosuggestion Strategy

## Goal

Implement a new `zsh-autosuggestions` strategy named `histdb_fish_like` that leverages the existing `zsh-histdb` SQLite database (already forked at `../zsh-histdb`) to provide contextual, directory-aware, ranked autosuggestions similar to Fish shell.

This file will be saved as `src/strategies/histdb_fish_like.zsh`.

---

## Architecture Overview

```
Typed prefix → SQL query with scoring → Return best match via typeset -g suggestion
```

The strategy is a single function `_zsh_autosuggest_strategy_histdb_fish_like` that receives the current buffer as `$1` and returns a suggestion via `typeset -g suggestion`.

All scoring and ranking happens inside SQLite for speed.

---

## Dependencies

- `zsh-histdb` must be loaded before this strategy runs. It provides:
  - `$HISTDB_FILE` — path to the SQLite database
  - `_histdb_query` — helper to run SQLite queries
  - `_histdb_addhistory` / `_histdb_update_outcome` — hooks already tracking commands

- `zsh-autosuggestions` plugin must be installed and loaded.

---

## Configurable Variables

Define these with sensible defaults. Use `(( ! ${+VAR} )) && typeset -g VAR=value` pattern:

| Variable | Type | Default | Description |
|---|---|---|---|
| `ZSH_AUTOSUGGEST_HISTDB_CWD_WEIGHT` | integer | 100 | Boost for commands used in exact current directory |
| `ZSH_AUTOSUGGEST_HISTDB_PARENT_WEIGHT` | integer | 50 | Boost for commands used in parent directories |
| `ZSH_AUTOSUGGEST_HISTDB_RECENCY_WEIGHT` | integer | 30 | Weight for recency (time since last use) |
| `ZSH_AUTOSUGGEST_HISTDB_FREQUENCY_WEIGHT` | integer | 20 | Weight for how often command is used |
| `ZSH_AUTOSUGGEST_HISTDB_SUCCESS_WEIGHT` | integer | 10 | Boost for commands with exit_status = 0 |
| `ZSH_AUTOSUGGEST_HISTDB_FAILURE_PENALTY` | integer | 15 | Penalty for commands with exit_status != 0 |
| `ZSH_AUTOSUGGEST_HISTDB_MIN_SCORE` | integer | 10 | Minimum score threshold; suppress suggestions below this |
| `ZSH_AUTOSUGGEST_HISTDB_MAX_ROWS` | integer | 500 | Maximum rows to consider (query LIMIT for performance) |
| `ZSH_AUTOSUGGEST_HISTDB_RECENCY_HALFLIFE` | integer | 604800 | Seconds (1 week). Recency score decays over this period |

---

## Scoring Formula (SQL)

For each candidate command matching `prefix%`:

```
score =
    (cwd_exact_match ? ZSH_AUTOSUGGEST_HISTDB_CWD_WEIGHT : 0)
  + (cwd_parent_match ? ZSH_AUTOSUGGEST_HISTDB_PARENT_WEIGHT : 0)
  + (frequency * ZSH_AUTOSUGGEST_HISTDB_FREQUENCY_WEIGHT)
  + (recency_decay * ZSH_AUTOSUGGEST_HISTDB_RECENCY_WEIGHT)
  + (exit_status == 0 ? ZSH_AUTOSUGGEST_HISTDB_SUCCESS_WEIGHT : 0)
  - (exit_status != 0 ? ZSH_AUTOSUGGEST_HISTDB_FAILURE_PENALTY : 0)

recency_decay = exp(-ln(2) * seconds_since / ZSH_AUTOSUGGEST_HISTDB_RECENCY_HALFLIFE)
```

Recency decay uses exponential half-life. In SQLite, approximate with `exp()` or compute a simpler linear decay if `exp()` is unavailable in the sqlite3 build. A pragmatic fallback:

```sql
MAX(0.0, 1.0 - (strftime('%s','now') - max_start_time) / halflife)
```

---

## SQL Query Design

```sql
SELECT commands.argv,
       (
           CASE WHEN current_dir_match THEN {cwd_weight} ELSE 0 END
         + CASE WHEN parent_dir_match THEN {parent_weight} ELSE 0 END
         + {frequency_weight} * command_count
         + MAX(0.0, 1.0 - (strftime('%s','now') - max_start_time) / {halflife}) * {recency_weight}
         + CASE WHEN last_exit_status = 0 THEN {success_weight} ELSE 0 END
         - CASE WHEN last_exit_status IS NOT NULL AND last_exit_status != 0 THEN {failure_penalty} ELSE 0 END
       ) AS score
FROM (
    SELECT
        history.command_id,
        MAX(history.start_time) AS max_start_time,
        COUNT(*) AS command_count,
        (
            SELECT exit_status FROM history AS h2
            WHERE h2.command_id = history.command_id
            ORDER BY h2.start_time DESC LIMIT 1
        ) AS last_exit_status,
        (
            SELECT COUNT(*) > 0 FROM history AS h3
            JOIN places AS p3 ON h3.place_id = p3.id
            WHERE h3.command_id = history.command_id
              AND p3.dir = '{escaped_pwd}'
        ) AS current_dir_match,
        (
            SELECT COUNT(*) > 0 FROM history AS h4
            JOIN places AS p4 ON h4.place_id = p4.id
            WHERE h4.command_id = history.command_id
              AND p4.dir LIKE '{escaped_parent_dir}/%'
        ) AS parent_dir_match
    FROM history
    JOIN commands ON history.command_id = commands.id
    JOIN places ON history.place_id = places.id
    WHERE commands.argv LIKE '{escaped_prefix}%'
    GROUP BY history.command_id
    ORDER BY score DESC
    LIMIT {max_rows}
) AS scored
JOIN commands ON scored.command_id = commands.id
WHERE score >= {min_score}
ORDER BY score DESC
LIMIT 1
```

**Notes:**
- `{escaped_...}` values must be SQL-escaped using zsh-histdb's `sql_escape` function.
- The inner query limits rows for performance.
- The outer query filters by `min_score` and picks the top 1.
- `last_exit_status` is the exit status of the most recent invocation of that command.

---

## Conservative Suppression Rules

Suppress (return empty suggestion) if ANY of these are true:

1. Query returns no rows.
2. Top candidate's `score < ZSH_AUTOSUGGEST_HISTDB_MIN_SCORE`.
3. Candidate does not actually start with the prefix (defense-in-depth after SQL).
4. `ZSH_AUTOSUGGEST_HISTORY_IGNORE` is set and candidate matches it. Reuse the existing ignore logic from `history` strategy.

---

## Implementation Steps

### Step 1: Define configuration defaults

At the top of the file, set default values for all configurable variables using the zsh-autosuggestions pattern:

```zsh
(( ! ${+ZSH_AUTOSUGGEST_HISTDB_CWD_WEIGHT} )) && typeset -gi ZSH_AUTOSUGGEST_HISTDB_CWD_WEIGHT=100
# ... etc for all variables
```

### Step 2: Define the strategy function

```zsh
_zsh_autosuggest_strategy_histdb_fish_like() {
    emulate -L zsh
    setopt EXTENDED_GLOB

    local prefix="$1"

    # Defensive: bail if histdb is not loaded
    (( ${+functions[_histdb_query]} )) || return
    [[ -n "${HISTDB_FILE}" ]] || return

    # Escape inputs for SQL
    local escaped_prefix="$(sql_escape "$prefix")"
    local escaped_pwd="$(sql_escape "$PWD")"
    local escaped_parent="$(sql_escape "${PWD:h}")"

    # Build and run the query
    local query="..."
    local result
    result="$(_histdb_query "$query")"

    # Defensive: ensure result starts with prefix
    if [[ "$result" == "$prefix"* ]]; then
        typeset -g suggestion="$result"
    else
        typeset -g suggestion=""
    fi
}
```

### Step 3: Handle the ignore pattern

If `ZSH_AUTOSUGGEST_HISTORY_IGNORE` is set, omit candidates matching that pattern. Two options:

- **Option A (simpler):** Post-filter the result in zsh after the query.
- **Option B (preferred):** Add a `NOT LIKE` or `NOT GLOB` clause to the SQL `WHERE`.

Prefer **Option A** for simplicity, since there's only 1 result. If the result matches the ignore pattern, return empty.

### Step 4: Handle empty prefix

When `$prefix` is empty, the LIKE clause becomes `LIKE '%'` which returns all history. This is expected behavior — zsh-autosuggestions usually doesn't call the strategy when the buffer is empty, but if it does, the query should handle it gracefully. SQLite can optimize `LIKE '%'` using indexes if the query structure allows.

---

## Performance Considerations

- SQLite in WAL mode with existing indexes should handle this query fast (< 10ms) on typical history sizes (< 100k rows).
- Limit inner query to `ZSH_AUTOSUGGEST_HISTDB_MAX_ROWS` (default 500) to cap worst-case work.
- The correlated subqueries for `current_dir_match` and `parent_dir_match` may be slow on very large histories. If profiling shows slowness, rewrite them as JOINs or use `EXISTS` instead of `COUNT(*) > 0`.

---

## Error Handling

- If `_histdb_query` fails (returns nothing or error string), return empty suggestion silently.
- If `sqlite3` is not available, return empty suggestion.
- Never block the UI. The query is synchronous but should be fast.

---

## Usage

After placing the file at `src/strategies/histdb_fish_like.zsh`, the user configures:

```zsh
# In .zshrc, after loading zsh-histdb and zsh-autosuggestions:
ZSH_AUTOSUGGEST_STRATEGY=(histdb_fish_like history)
```

The `history` fallback ensures basic prefix matching works if histdb is unavailable.

---

## Testing Checklist

- [ ] Typing `git ch` in a repo suggests `git checkout main` if used frequently there.
- [ ] Typing `make ru` in `~/kernel` suggests `make run-qemu` if used there before.
- [ ] Typing a command with exit_status != 0 is less likely to be suggested.
- [ ] Very old commands have lower scores than recent ones.
- [ ] Commands used in current directory rank higher than global ones.
- [ ] Empty or weak matches return no suggestion (conservative).
- [ ] Latency feels instantaneous (< 50ms perceived).

---

## Out of Scope (Explicitly Removed)

- **Completion integration**: Do NOT integrate zsh completion engine.
- **Git awareness**: Do NOT track git repository or branch context.
- **Filesystem validation**: Do NOT check `[[ -e path ]]` for candidate paths.
- **Custom storage layer**: Reuse zsh-histdb SQLite fully.

---

## File to Create

```
src/strategies/histdb_fish_like.zsh
```

## Approximate Size

50–80 lines of zsh script.
