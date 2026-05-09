# Bash literals observed across our tests (post-pipes)

Every shell command Gemma 4 E2B-it-Q4_K_M wrote during the
post-Phase-N1 (pipes) test runs. Use this as the raw evidence for
allow-list expansion decisions.

- **Model**: gemma-4-E2B-it-Q4_K_M, FFI, temp=1.0, top_p=0.95
- **dart_wasm_sandbox commit**: `3ae932d` (pipes shipped)
- **Date**: 2026-05-09
- **Source logs**:
  - `bench_verbose_post_n1_2026-05-09.log` (17-spec battery, full transcript)
  - `survey_post_n1_2026-05-09.log` (15-task open-ended survey)

---

## Bench (`run_bash_bench.dart`) — 17 specs

Specs prescribe the command. Useful for measuring whether the model
faithfully translates "use run_bash with X" into the right
`run_bash('X')` call.

| Spec | Result | Literal(s) the model wrote |
|---|---|---|
| `B01_echo_literal` | ✓ | `run_bash('echo hello')` |
| `B02_echo_multi_arg` | ✓ | `run_bash('echo foo bar baz')` |
| `B03_pwd_root` | ✓ | `run_bash('pwd')` |
| `B04_cat_notes` | ✓ | `run_bash('cat /tmp/llama-test/fixtures/notes.txt')` |
| `B05_cat_numbers` | ✓ | `run_bash('cat /tmp/llama-test/fixtures/numbers.txt')` |
| `B06_ls_data` | ✓ | `run_bash('ls /tmp/llama-test/fixtures')` |
| `B07_find_root` | ✓ | `run_bash('find /')` |
| `B08_cd_then_pwd` | ✓ | `run_bash('cd /tmp/llama-test/fixtures && pwd')` |
| `B09_cd_then_ls` | ✓ | `run_bash('cd /tmp/llama-test/fixtures && ls')` |
| `B10_cd_then_cat` | ✓ | `run_bash('cd /tmp/llama-test/fixtures && cat greeting.txt')` |
| `B11_multi_call_cwd_persists` | ✓ | `run_bash('cd /tmp/llama-test/fixtures')` <br> `run_bash('pwd')` |
| `B12_find_then_cat` | ✗ | `run_bash('find /tmp/llama-test/state -type f \| head -n 1 \| xargs cat 2>/dev/null \| grep -v "^\s*$" \| head -n 1')` |
| `C01_bash_then_python_sum` | ✓ | `run_bash('cat /tmp/llama-test/fixtures/numbers.txt')` |
| `C02_bash_find_then_python_count` | ✓ | `run_bash('find /')` |
| `C03_python_value_via_bash_echo` | ✗ | `run_bash('echo 7 * 8')` |
| `B13_disallowed_awk` | ✓ | `run_bash('awk \'{s+=$1} END {print s}\' /tmp/llama-test/fixtures/numbers.txt')` |
| `B14_pipe_works` | ✓ | `run_bash('cat /tmp/llama-test/fixtures/numbers.txt \| head -n 2')` |

### Failure analysis

**B12** (the most interesting failure). The model wrote a 4-stage
pipe with multiple unsupported features:

```python
run_bash('find /tmp/llama-test/state -type f | head -n 1 | xargs cat 2>/dev/null | grep -v "^\s*$" | head -n 1')
```

What broke:
- `xargs` — not on allow-list (rejects with `<host error -3>`)
- `2>/dev/null` — stderr redirect not implemented (treated as literal arg)
- 4-stage pipe with mid-chain rejection — chain returns empty

Pipes themselves are not the problem; the model is now reaching
beyond the allow-list because pipes give it a familiar syntax shape.
The prompt asked for two SEPARATE `run_bash` calls; the model
collapsed them into one chain with xargs.

**C03** wrote `echo 7 * 8` literally (model's "compute then echo"
pattern doesn't expand `*` — bash treats it as glob, returns the
literal). Pre-existing flake from before A1.

---

## Survey (`bash_knowledge_survey.dart`) — 15 open-ended tasks

Prompt does NOT enumerate the allow-list — these are what the model
writes when asked to do shell-y things in its own words. This is the
load-bearing dataset for "what does the model actually want?".

| Task | Status (post-N1) | Literal |
|---|---|---|
| T01 search-text | allowed | `run_bash('grep "ERROR" /tmp/llama-test/state/app.log')` |
| T02 first-line | allowed | `run_bash('head -n 1 /tmp/llama-test/fixtures/numbers.txt')` |
| T03 last-line | allowed | `run_bash('tail -1 /tmp/llama-test/fixtures/numbers.txt')` |
| T04 count-lines | allowed | `run_bash('wc -l /tmp/llama-test/fixtures/numbers.txt')` |
| T05 count-bytes | allowed | `run_bash('wc -c /tmp/llama-test/fixtures/greeting.txt')` |
| T06 files-by-ext | allowed | `run_bash('find / -type f -name "*.txt"')` |
| T07 recursive-list | allowed | `run_bash('find / -type f')` |
| T08 grep-inverse | allowed | `run_bash('grep -v "INFO" /tmp/llama-test/state/app.log')` |
| T09 sort | partial | `run_bash('cat /tmp/llama-test/fixtures/numbers.txt \| sort')` (pipe ok, sort denied) |
| T10 replace-text | **denied** | `run_bash('sed "s/INFO/info/g" /tmp/llama-test/state/app.log')` |
| T11 word-count | allowed | `run_bash('wc -w /tmp/llama-test/fixtures/greeting.txt')` |
| T12 pipe-chain | **NEW: allowed** | `run_bash('cat /tmp/llama-test/fixtures/numbers.txt \| head -n 2')` |
| T13 unique | **denied** | `run_bash('sort -u /notes.txt')` |
| T14 sum-column | **denied** | `run_bash('awk "{sum} += $1; END {print sum}" /tmp/llama-test/fixtures/numbers.txt')` |
| T15 diff | **denied** | `run_bash('diff /tmp/llama-test/fixtures/greeting.txt /tmp/llama-test/fixtures/greeting.txt')` |

---

## Cross-cutting observations

### Pipes used naturally

3 distinct pipe literals across both tests:

```python
run_bash('cat /tmp/llama-test/fixtures/numbers.txt | head -n 2')   # bench B14, survey T12 — works
run_bash('cat /tmp/llama-test/fixtures/numbers.txt | sort')        # survey T09 — sort denied
run_bash('find /tmp/llama-test/state -type f | head -n 1 | xargs cat | grep -v "^\s*$" | head -n 1')  # bench B12 — xargs denied
```

The model treats pipes as a first-class composition primitive once
it knows they work. Multi-stage chains (`| head | wc`, `| head |
xargs cat`) appear within one run.

### Quote / escape patterns

- `awk` always escapes inner quotes: `awk \'{s+=$1} END {print s}\'`
- `grep` uses double-quotes for the pattern: `grep "ERROR" file`
- `sed` uses double-quotes around the substitution: `sed "s/INFO/info/g"`
- `find -name` uses double-quotes for glob: `find / -name "*.txt"`
- `find -type f` flag observed; no `-mtime`, `-size`, `-exec`

### POSIX short forms reached for

- `tail -1` (without `-n`)
- `head -n 1` (with `-n`)
- `find / -type f -name "*.txt"` (combined flags)
- `wc -l|-c|-w|-m` (single-letter variants)

### Things model never tried in 32 task-trials

- Globs in non-`find` contexts (`ls *.txt` was tried *once* pre-A1 only)
- Redirects (`>`, `<`, `>>`)
- `||` or `;` as command separators (only `&&`)
- Backticks or `$(...)` command substitution
- Variable expansion (`$VAR`)
- Process substitution
- Subshells `(...)`

### Things model tried that aren't on allow-list

In rough frequency order (post-pipes survey + bench):

| Cmd | Attempts | Tasks |
|---|---:|---|
| `sed` | 1 | T10 replace-text |
| `awk` | 2 | T14 sum-column, B13 (deliberate) |
| `sort` | 2 | T09 sort, T13 unique |
| `diff` | 1 | T15 diff |
| `xargs` | 1 | B12 (model overshoot) |

The `xargs` attempt is new — only appears now that pipes give the
model a chain-syntax to put it in.

### `2>/dev/null` redirect

Observed once (B12). Also new — also driven by pipe usage.

---

## Files

```
example/eval/bash/BENCH_LITERALS.md                       (this doc)
example/eval/bash/bench_verbose_post_n1_2026-05-09.log    (full bench transcript)
example/eval/bash/survey_post_n1_2026-05-09.log           (full survey transcript)
example/eval/bash/observed_commands_raw_2026-05-09.log    (pre-A1 survey raw)
example/eval/bash/survey_post_a1_2026-05-09.log           (post-A1 survey)
```
