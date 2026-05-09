# Phase N3 — outer-quote strip on argv tokens

Reply to `PHASE_N1.5_REPLY.md` §4. The `grep -c "INFO" file → 0`
silent-corruption bug is fixed.

- **commit**: `1b27039` (Phase Next N3: strip outer quotes from argv tokens)
- **date**: 2026-05-09
- **scope**: 1 fix, applies to all argv tokens (not just grep)

## What changed

Before the allow-list check, each whitespace-split argv token has a
single matched pair of leading/trailing ASCII quotes stripped:

- `"…"` and `'…'` are unwrapped
- mismatched / unpaired quotes pass through unchanged
- inner quotes are left alone (we don't try to do shell-level
  tokenisation across spaces)

Mirrored Rust (`strip_outer_quotes`) and Dart (`_stripOuterQuotes`),
called between `split_whitespace` and `strip_devnull_redirects`.

## Direct probe (matches your N1.5 reply table)

```
grep INFO /logs/app.log         → [INFO] booted          (was: ✓)
grep -c INFO /logs/app.log      → 1                      (was: ✓)
grep "INFO" /logs/app.log       → [INFO] booted          (was: ✗ empty)
grep -c "INFO" /logs/app.log    → 1                      (was: ✗ "0")
grep -c 'INFO' /logs/app.log    → 1                      (was: ✗ "0")
grep "INFO" /logs/app.log | wc -l → 1                    (was: ✗ "0")
cat "/logs/app.log"             → full file              (was: -4)
echo "hello"                    → hello                  (was: "hello")
```

## What this also fixes (latent, not just M02)

Any quoted argv token now behaves correctly. The data showed the
model writes quoted patterns 100% of the time it uses grep, and
it occasionally quotes paths too (`cat "/logs/foo"`). All those
forms now work.

## What did NOT change

- Quoted strings with embedded spaces still tokenise on the inner
  whitespace. `echo "hello world"` becomes `["echo", "\"hello",
  "world\""]`, then strip-outer-quotes gives `["echo", "\"hello",
  "world\""]` — neither token is a matched pair. So `echo "hello
  world"` prints `"hello world"` (with the quotes), not `hello
  world`. We can add a real shell tokeniser if data warrants;
  the model hasn't asked for it yet.
- No changes to the allow-list or any command semantics.
- No new commands; sed/awk/diff still rejected with `<host error -3>`.

## Tests

8 new cross-backend tests in `dart/test/quoted_args_test.dart`:

- `grep "INFO" file` matches like the bare form
- `grep -c "INFO" file` counts (the M02 case)
- `grep -c 'INFO' file` (single quotes) also counts
- `grep "INFO" file | wc -l` in a pipe
- quoted absolute path `cat "/logs/app.log"`
- quoted echo arg drops the quotes
- mismatched quotes pass through unchanged (regression guard)
- unquoted form still works

Tag: `commands`. Both backends (`-p vm` and `-p chrome`) green; 88
each. clippy / dart analyze / dcm clean.

## What to re-run

- M02 (`count_by_severity`) should flip from ✗ → ✓ now.
- Anywhere else the model used quoted grep patterns and got `0`,
  silently — those should also self-heal without prompt changes.
- The 22/24 baseline should now be 23/24, with B12 (the
  abs-path-from-find reasoning limit) the only remaining failure.

## Suggested signal for next round

If M02 passes and B12 still fails, the bash surface is at a clean
pause point again. Next data points worth surfacing:

- any new singletons in argv0 (sed/awk/diff cluster building?)
- any new redirect / chaining tokens beyond what's already covered
- whether quoted-with-spaces shows up (`echo "hello world"` form)
  — if so, we'll add a real tokeniser.

Otherwise, hold.

## Files

```
host/src/lib.rs                          (+strip_outer_quotes; wired in)
dart/lib/src/host_emulation.dart         (+_stripOuterQuotes; wired in)
dart/test/quoted_args_test.dart          (new; 8 tests)
```
