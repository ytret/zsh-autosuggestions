# AI Problems: Histdb Fish-Like Autosuggestion Strategy

## 1. CRITICAL: `LIMIT` applied before scoring/ordering

**File:** `src/strategies/histdb_fish_like.zsh:59`

The `LIMIT ${max_rows}` is in the **innermost** subquery, before any scoring or `ORDER BY`. The query groups by `command_id` and arbitrarily limits to 500 rows. Since `ORDER BY score DESC` only happens in the **middle** subquery (line 61), the candidates that get scored are an arbitrary, non-deterministic subset. If there are 5000+ distinct commands matching a prefix, the truly best candidate may never be scored.

**Current structure (simplified):**

```
FROM (  -- middle: scores but sees only 500 arbitrary rows
    SELECT command_id, (...) AS score
    FROM (  -- inner: LIMIT 500 with no ORDER BY
        SELECT command_id, ...
        GROUP BY command_id
        LIMIT 500    ← BUG
    )
    ORDER BY score DESC
    LIMIT 1
)
```

**Fix:** Move the `LIMIT` to the middle subquery (after scoring and `ORDER BY`), or remove it from the inner query and add an `ORDER BY max_start DESC LIMIT 500` to the inner query to at least consider the most recent candidates.

---

## 2. MEDIUM: No guard for `sql_escape` function

**File:** `src/strategies/histdb_fish_like.zsh:21`

`sql_escape` is called unconditionally on lines 21-23, but only `_histdb_query` is guarded on line 18. If the user has a different or older version of `zsh-histdb` that doesn't export `sql_escape`, the strategy will produce an error message instead of silently returning.

**Fix:** Add a guard check for `sql_escape`:

```zsh
(( ${+functions[sql_escape]} )) || return
```

---

## 3. MEDIUM: Multiple correlated subqueries per row

**File:** `src/strategies/histdb_fish_like.zsh:51-53`

The inner query runs **3 correlated subqueries** (`last_status`, `cwd_match`, `parent_match`) for every grouped row. For 500 groups, that's 1500 subqueries per keystroke. The `SELECT 1 ... LIMIT 1` pattern for `cwd_match`/`parent_match` is better than `COUNT(*) > 0`, but still correlated.

The AI_CONTEXT.md already notes this: "Correlated subqueries for `cwd_match` and `parent_dir_match` may be slow on very large histories (>100k rows)."

**Potential fix:** Rewrite as `LEFT JOIN` with `EXISTS` or use CTEs with pre-computed lookups, though this may complicate the query significantly.

---

## 4. LOW: `parent_dir_match` LIKE pattern is too broad

**File:** `src/strategies/histdb_fish_like.zsh:53`

The parent dir match uses `p4.dir LIKE '${escaped_parent_dir}/%'`. Example:

| `$PWD` | `PWD:h` | LIKE pattern |
|---|---|---|
| `/home/user/projects/foo` | `/home/user/projects` | `/home/user/projects/%` |

This matches sibling directories like `/home/user/projects/bar` and all their descendants, not just the current directory's subtree. Commands run in unrelated sibling projects may get an undeserved +50 score boost.

---

## 5. LOW: `suggestion` not explicitly unset on failure path

**File:** `src/strategies/histdb_fish_like.zsh:70-76`

When the query fails or the result doesn't match the prefix, the function returns without setting `suggestion`. The caller in `fetch.zsh:22` checks `[[ "$suggestion" != "$1"* ]] && unset suggestion`, which handles this in practice — but only because `suggestion` is either unset or was already set by this strategy's `typeset -g` on the previous call. The interaction is subtle and fragile compared to explicitly `typeset -g suggestion=""` on failures.

**Fix:** Add `typeset -g suggestion=""` before every `return` that indicates no result.

---

## 6. LOW: Empty prefix can trigger full table scan

When `$prefix` is empty, the WHERE becomes `commands.argv LIKE '%'` which matches everything. Combined with the LIMIT-in-wrong-place bug (issue #1), this could return an arbitrary command as a suggestion. While `zsh-autosuggestions` typically doesn't call strategies with empty buffers, there's no explicit guard against it.

---

## 7. LOW: No filesystem validation

Per the AI_PLAN.md (line 246), filesystem validation was explicitly scoped out. However, the NEW_STRATEGY.md spec (lines 196-238) called for it as a key Fish-shell behavior: "Avoid suggesting commands containing invalid paths." A candidate like `vim src/main_old_backup_unused.c` will be suggested even if that file no longer exists, as long as the command was previously used in the same directory. This is a design decision, not a bug, but it deviates from the original spec's vision.
