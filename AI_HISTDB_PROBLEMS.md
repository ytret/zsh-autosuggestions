# AI Problems: Histdb Fish-Like Autosuggestion Strategy

## 1. MEDIUM: Multiple correlated subqueries per row

**File:** `src/strategies/histdb_fish_like.zsh:53-55`

The inner query runs **3 correlated subqueries** (`last_status`, `cwd_match`, `parent_match`) for every grouped row. For 500 groups, that's 1500 subqueries per keystroke. The `SELECT 1 ... LIMIT 1` pattern for `cwd_match`/`parent_match` is better than `COUNT(*) > 0`, but still correlated.

The AI_CONTEXT.md already notes this: "Correlated subqueries for `cwd_match` and `parent_dir_match` may be slow on very large histories (>100k rows)."

**Potential fix:** Rewrite as `LEFT JOIN` with `EXISTS` or use CTEs with pre-computed lookups, though this may complicate the query significantly.

---

## 2. LOW: No filesystem validation

Filesystem validation was explicitly scoped out during implementation. However, the original spec called for it as a key Fish-shell behavior: "Avoid suggesting commands containing invalid paths." A candidate like `vim src/main_old_backup_unused.c` will be suggested even if that file no longer exists, as long as the command was previously used in the same directory. This is a design decision, not a bug, but it deviates from the original spec's vision.
