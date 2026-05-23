# Fish-Like Autosuggestion Strategy for Zsh

## Goal

Implement a custom suggestion strategy for `zsh-autosuggestions` that behaves similarly to Fish shell autosuggestions.

The primary objective is **contextual relevance**, not merely history prefix matching.

---

# Core Idea

Fish-style suggestions feel intelligent because they are:

* Context-aware
* Directory-aware
* Conservative
* Ranked by relevance
* Aware of filesystem validity
* Integrated with shell completion knowledge

The custom strategy should therefore:

1. Gather candidate suggestions
2. Score them using contextual heuristics
3. Select the highest-ranked candidate
4. Suppress weak/noisy suggestions

---

# High-Level Architecture

```text
Current BUFFER
    ↓
Collect candidate commands
    ↓
Tokenize and analyze
    ↓
Compute relevance scores
    ↓
Select best candidate
    ↓
Return autosuggestion
```

---

# Candidate Sources

## 1. History Matches

Primary source of suggestions.

Possible retrieval methods:

* `history`
* `fc -ln`
* `$history`

Matching methods:

* Prefix matching
* Token-prefix matching
* Fuzzy matching (optional)

Example:

```zsh
git ch
```

Possible candidates:

```zsh
git checkout main
git cherry-pick abc123
git checkout feature/foo
```

---

## 2. Completion System

Use Zsh completion engine as fallback or additional candidate source.

Examples:

* Git branches
* SSH hosts
* Cargo subcommands
* Make targets
* Package names

Potential integration points:

* `compadd`
* `_complete`
* completion widgets

---

## 3. Project-Local Metadata (Optional)

Maintain a custom database of:

```text
(command, cwd)
```

pairs.

This enables directory-aware ranking.

Example:

```text
~/kernel → make run-qemu
~/website → npm run dev
```

---

# Suggestion Ranking

Suggestions should be scored.

The candidate with the highest score becomes the autosuggestion.

---

# Recommended Scoring Signals

| Signal                          | Purpose                        | Suggested Weight |
| ------------------------------- | ------------------------------ | ---------------- |
| Prefix closeness                | Prefer exact/strong matches    | High             |
| Current working directory match | Prefer commands used here      | High             |
| Recency                         | Prefer recently used commands  | High             |
| Frequency                       | Prefer commonly used commands  | Medium           |
| Existing filesystem paths       | Avoid invalid suggestions      | Medium           |
| Git repository match            | Prefer commands from same repo | Medium           |
| Command length penalty          | Avoid giant suggestions        | Medium           |
| Previous command success        | Prefer successful commands     | Optional         |

---

# Directory-Aware Suggestions

## Motivation

Fish appears intelligent because commands used in the current directory are strongly preferred.

Example:

```zsh
cd ~/kernel
make ru
```

Desired suggestion:

```zsh
make run-qemu
```

instead of unrelated global history entries.

---

## Implementation Idea

Track:

```text
command
cwd
timestamp
exit status
```

using:

* `zshaddhistory`
* `precmd`
* `preexec`

Possible storage:

* SQLite
* JSON
* Flat file
* In-memory cache

---

# Filesystem Awareness

## Goal

Avoid suggesting commands containing invalid paths.

Example:

Typed:

```zsh
vim src/mai
```

Good suggestion:

```zsh
vim src/main.c
```

Bad suggestion:

```zsh
vim src/main_old_backup_unused.c
```

if the file no longer exists.

---

## Suggested Logic

1. Tokenize candidate
2. Detect path-like arguments
3. Check existence:

```zsh
[[ -e path ]]
```

4. Boost valid candidates
5. Penalize invalid candidates

---

# Tokenization

Use Zsh shell-aware tokenization.

Recommended:

```zsh
${(z)BUFFER}
```

This handles:

* Quotes
* Escapes
* Spaces
* Shell syntax

Avoid naive string splitting.

---

# Conservative Suggestion Policy

Fish avoids noisy suggestions.

This is important.

---

## Recommended Rules

Suppress suggestions if:

* Score below threshold
* Match quality is weak
* Candidate is extremely long
* Candidate was rarely used
* Candidate contains invalid paths
* Candidate differs too much semantically

---

# Recency vs Frequency

Both matter.

Example:

| Command         | Frequency | Recency |
| --------------- | --------- | ------- |
| `git status`    | Very high | Old     |
| `make run-qemu` | Medium    | Recent  |

Recent commands should usually win.

Recommended approach:

```text
score =
    prefix_score
  + cwd_score
  + recency_decay
  + frequency_weight
```

---

# Suggested Internal Data Model

```text
HistoryEntry:
    command
    cwd
    timestamp
    exit_status
    frequency
```

Optional:

```text
git_repo
session_id
hostname
project_type
```

---

# Completion Integration

## Hybrid Approach

Recommended pipeline:

1. History candidates
2. Completion candidates
3. Merge
4. Rank
5. Return best result

---

## Examples

### Git

Typed:

```zsh
git checkout f
```

Completion can provide:

```text
feature/parser
feature/vfs
fix/tty
```

History can provide:

```text
git checkout feature/vfs
```

The strategy merges both sources.

---

# Performance Requirements

Autosuggestions must feel instantaneous.

Target latency:

```text
< 10 ms
```

Prefer:

* Cached history
* Incremental indexes
* Pre-tokenized entries
* Lightweight scoring

Avoid:

* Full history scans on every keystroke
* Slow subprocesses
* Heavy filesystem traversal

---

# Recommended Hooks

Useful Zsh hooks:

| Hook            | Purpose                 |
| --------------- | ----------------------- |
| `zshaddhistory` | Track commands          |
| `preexec`       | Capture execution start |
| `precmd`        | Capture exit status     |
| `line-init`     | Session setup           |

---

# Useful Zsh Features

| Feature                  | Usage                    |
| ------------------------ | ------------------------ |
| `$BUFFER`                | Current command line     |
| `${(z)BUFFER}`           | Shell-aware tokenization |
| `$PWD`                   | Current directory        |
| `fc -ln`                 | History retrieval        |
| `compadd`                | Completion integration   |
| `zmodload zsh/parameter` | History access           |

---

# Optional Advanced Features

## Git-Aware Suggestions

Prefer suggestions from current repository.

Example:

```zsh
git push origin feature/vfs
```

should only appear inside that repository.

---

## Session Awareness

Prefer commands used recently in the current shell session.

---

## Command Success Tracking

Boost commands with successful exit codes.

Penalize failing commands.

---

## Semantic Command Grouping

Example:

Typed:

```zsh
cargo t
```

Prefer:

```zsh
cargo test
```

over unrelated matches.

---

# Suggested Development Stages

## Stage 1

Basic prefix history ranking.

---

## Stage 2

Add:

* Recency scoring
* Frequency scoring

---

## Stage 3

Add:

* Directory-aware ranking
* Project-local history

---

## Stage 4

Add:

* Filesystem validation
* Path-aware scoring

---

## Stage 5

Integrate completion engine.

---

## Stage 6

Add advanced heuristics:

* Git-awareness
* Success tracking
* Session relevance

---

# Important Insight

The “Fish feel” comes mostly from:

* Relevance ranking
* Local context
* Conservative confidence
* Low latency

—not from the visual appearance of inline suggestions.

---

# Final Recommendation

The single most impactful improvement is:

```text
Directory-aware recency-weighted ranking
```

Implement that first before adding more advanced heuristics.
