# Observed `run_bash(...)` literals — Gemma 4 E2B

Every shell command Gemma 4 E2B-it-Q4_K_M wrote in our open-ended
survey, with frequency, allow-list status, and the originating task.
Use this to decide which utilities to add to the `dart_wasm_sandbox`
allow-list next.

- **Model**: gemma-4-E2B-it-Q4_K_M, temp=1.0, top_p=0.95
- **Survey harness**: `example/eval/bash/bash_knowledge_survey.dart`
- **Survey date**: 2026-05-09 (after VFS unification under `/tmp/llama-test/`)
- **VFS**: `/tmp/llama-test/fixtures/{notes,greeting,numbers}.txt`,
  `/tmp/llama-test/state/app.log`
- **Allow-list at survey time**: `pwd / cd / ls / cat / find / echo`
  (6 commands; `&&` chaining; persistent cwd)

Two data sources combined: the survey above (15 open-ended tasks,
prompt does NOT enumerate the allow-list — model writes what it
naturally reaches for), and an earlier survey on pre-unification
paths. Numbers per command are merged across both.

---

## Argv0 frequency (allowed vs denied)

| argv0 | attempts | allowed | denied | tasks |
|---|---:|---:|---:|---|
| `wc`   | 6 | 0 | 6 | T04 count-lines, T05 count-chars, T11 word-count |
| `cat`  | 5 | 5 | 0 | T09 sort, T12 pipe-chain, T13 unique |
| `grep` | 4 | 0 | 4 | T01 search-text, T08 grep-inverse |
| `find` | 3 | 3 | 0 | T06 files-by-ext, T07 recursive-listing |
| `head` | 2 | 0 | 2 | T02 first-line |
| `tail` | 2 | 0 | 2 | T03 last-line |
| `diff` | 2 | 0 | 2 | T15 diff |
| `sed`  | 1 | 0 | 1 | T10 replace-text |
| `awk`  | 1 | 0 | 1 | T14 sum-column |
| `sort` | 1 | 0 | 1 | T13 unique |
| `ls`   | 1 | 1 | 0 | T06 files-by-ext |

Note: `cat … | head` and `cat … | sort` show up under `cat` in the
argv0 stats but the model is reaching for **pipes**. Pipes are
currently unsupported. See "Pipes" section below.

---

## Every literal observed (verbatim)

Each line is exactly what the model wrote inside a `run_bash(...)`
call. Grouped by argv0.

### `wc` (denied — 3 distinct literals)

```python
run_bash('wc -l /tmp/llama-test/fixtures/numbers.txt')   # T04 count-lines
run_bash('wc -c /tmp/llama-test/fixtures/greeting.txt')  # T05 count-chars
run_bash('wc -w /tmp/llama-test/fixtures/greeting.txt')  # T11 word-count
```

`-l`, `-c`, `-w` cover lines / bytes / words — the canonical use
cases. Implementation in Dart is ~10 lines: read bytes, count `\n`,
count `len(bytes)`, count whitespace-separated runs.

### `grep` (denied — 2 distinct literals)

```python
run_bash('grep "ERROR" /tmp/llama-test/state/app.log')      # T01 search-text
run_bash('grep -v "INFO" /tmp/llama-test/state/app.log')    # T08 grep-inverse
```

Just literal substring + `-v` (invert). No `-r` recursion observed.
No regex flags observed (`-E`, `-F`, `-i`).

### `head` / `tail` (denied — 2 literals)

```python
run_bash('head -n 1 /tmp/llama-test/fixtures/numbers.txt')  # T02 first-line
run_bash('tail -n 1 /tmp/llama-test/fixtures/numbers.txt')  # T03 last-line
```

Both used with `-n N` only. No `-c BYTES`, no streaming.

### `sed` (denied — 1 literal)

```python
run_bash('sed "s/INFO/info/g" /tmp/llama-test/state/app.log')  # T10 replace-text
```

Single substitution, global. No address ranges. Cheapest possible
sed surface.

### `awk` (denied — 1 literal, escapes nested quotes)

```python
run_bash('awk \'{sum += $1} END {print sum}\' /tmp/llama-test/fixtures/numbers.txt')  # T14 sum-column
```

Sum-a-column. Not trivial to emulate generally — full awk is a
language. **Recommendation:** punt awk; surface `wc -l` + `cut` and
let Python sum.

### `diff` (denied — 1 literal)

```python
run_bash('diff /tmp/llama-test/fixtures/greeting.txt /tmp/llama-test/fixtures/greeting.txt')  # T15 diff
```

File-vs-file diff. Useful but lower priority — Python's `difflib`
is one fence away.

### `sort` (denied — 1 literal)

```python
run_bash('sort -u /notes.txt')  # T13 unique
```

`-u` for unique. Low priority — Python `sorted(set(lines))` is one
fence away.

### `cat` (allowed — 5 literals, 2 reach for pipes)

```python
run_bash('cat /tmp/llama-test/fixtures/numbers.txt | head -n 2')   # T12 pipe-chain
run_bash('cat /tmp/llama-test/fixtures/numbers.txt | sort -n')     # T09 sort
run_bash('cat /notes.txt | sort -u')                               # T13 unique
run_bash('cat /tmp/llama-test/fixtures/notes.txt')                 # baseline
run_bash('cat /tmp/llama-test/fixtures/greeting.txt')              # baseline
```

The pipe forms run as a single shell line and our allow-list
currently rejects the pipe character. **Pipes were attempted in
3/15 tasks** — meaningful signal.

### `find` / `ls` (allowed — 3 literals)

```python
run_bash('find / -type f')                       # T07 recursive-listing
run_bash('find / -type f -name "*.txt"')         # T06 files-by-ext
run_bash('ls *.txt')                             # T06 files-by-ext (alt)
```

`find` is heavily used; `-name "*.txt"` is the only flag pattern
observed. The model also tried bare `ls *.txt` once — glob expansion
in `ls` is not currently implemented.

---

## Pipes (across argv0s)

3 of 15 tasks reached for pipes:

```python
run_bash('cat /tmp/llama-test/fixtures/numbers.txt | head -n 2')
run_bash('cat /tmp/llama-test/fixtures/numbers.txt | sort -n')
run_bash('cat /notes.txt | sort -u')
```

Both ends of every pipe in our trace are between cat / head / sort
/ unique — i.e. once `head`, `tail`, and `sort` are added, pipes
become the next obvious gap.

---

## Recommended priority order

Ranked by want × cheap-to-implement × covers-most-tasks:

| Rank | Cmd | Why | Surface |
|---|---|---|---|
| 1 | `wc` | 6 attempts, dead simple to emulate | `-l`, `-c`, `-w` |
| 2 | `grep` | 4 attempts, common idiom | substring + `-v` |
| 3 | `head` / `tail` | 4 attempts combined, trivial | `-n N` |
| 4 | (pipes) | 3 attempts; unlocks chains | `\|` between allow-listed cmds |
| 5 | `sed` | 1 attempt, but useful for replace | `s/x/y/g` only |
| 6 | `sort` | 1 attempt, low priority | `-n`, `-u` |
| 7 | `awk` | 1 attempt, expensive surface | skip |
| 8 | `diff` | 1 attempt, low priority | skip |

Adding 1–4 (wc / grep / head / tail / pipes) covers every observed
task except T14 (awk) and T10 (sed). That's ~13/15 of the survey's
natural usage from <50 LOC of Dart per command + a basic pipe lexer.

---

## How this was generated

```bash
dart run example/eval/bash/bash_knowledge_survey.dart \
  > /tmp/bash_survey_fresh.log 2>&1

# Extract literals:
grep "run_bash(" /tmp/bash_survey_fresh.log | sort -u
```

Survey source: `example/eval/bash/bash_knowledge_survey.dart`. The
prompt deliberately does NOT list the allow-list — we want what
the model reaches for unprompted. Each task gets a fresh wasm
session + VFS reload so command attempts are independent.
