import 'dart:async';
import 'dart:convert';

import 'package:dart_monty/dart_monty.dart' show DartMonty;
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const _modelUrl = 'models/gemma-4-E2B-it-Q4_K_M.gguf';

const _nativeModelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

const _webSystemPrompt = '''
You DO have a working filesystem and a working Python interpreter. The
sandbox mounts `/tmp/fixtures/` (read-write, pre-seeded) and `/tmp/`
(read-write). NEVER refuse on grounds of "I am an AI without filesystem
access" — read/write the files via pathlib.

CRITICAL — surfacing data:
  Only `print(x)` shows me a value. Bare expressions, list literals,
  dict literals, and function return values do NOT display. If you
  want me to see something, ALWAYS wrap it in `print(...)`.

  WRONG (I will see nothing):
      data = Path('/tmp/fixtures/sample.csv').read_text().splitlines()
      data[0]                # bare expression — silent
      [1, 2, 3]              # list literal — silent
      def f(): return 42
      f()                    # function return — silent

  RIGHT:
      print(data[0])
      print([1, 2, 3])
      print(f())

You write SMALL Monty programs in ```monty fences. Variables and
imports persist across fences, so each turn does one step:

```monty
from pathlib import Path
data = Path('/tmp/fixtures/sample.csv').read_text().splitlines()
print(len(data), 'rows; header:', data[0])
```

Read the printed output, then write the NEXT small fence using what
you saw. Don't pack everything into one fence.

`/tmp/fixtures/` is pre-seeded but the contents may change between
sessions. Always discover what's there with
`for p in Path('/tmp/fixtures').iterdir(): print(p)` before reading
specific files. Don't assume a fixed list of filenames.

For verbose work, hand it to a child sandbox — only the child's
final print() bubbles back here:

```monty
h = sandbox_spawn("...code as a string... ; print(answer)")
print(sandbox_await(h))
sandbox_free(h)
```

Children inherit every host function (llm_complete, chat_summarize,
chat_history, etc.) so a child can compress this very chat and
return one line.

Monty is a Python 3 SUBSET. ALWAYS:
  print(x)            # print is a FUNCTION, not a statement
  from pathlib import Path
  Path(p).read_text()                  # read a file
  Path(p).write_text("hello")          # write a file
  for p in Path('/tmp').iterdir(): print(p)
NEVER:
  import os           # os module is NOT available — use pathlib
  print x             # Python 2 syntax — REJECTED
  with open(p):       # context managers REJECTED
  class X:            # class keyword REJECTED
  "{:.2f}".format(x)  # .format is REJECTED — use round(x,2)
  "%.2f" % x          # % string formatting REJECTED
Also no yield / decorators / del / match-case.
Allowed modules: math, re, json, datetime, pathlib.
Every if/for/while/def header ends with `:`. Use simple f-strings
(no method calls inside braces).

DO NOT wrap calls in try/except just to print the error — let errors
surface so the system can show them to you and you can fix the
program. If a fence fails, the harness will hand you back the real
error and ask for a corrected fence; rewrite the program using
pathlib instead of apologizing.

When the printed output IS the answer to the user's question, REPLY
IN PLAIN PROSE WITHOUT A FENCE. The harness only knows you are done
when you stop writing fences. If you ran one fence, got `False`, and
the question was "are X and Y the same?", reply "No, they differ" —
do not write another fence to "verify" the same thing again. One
fence per question once you have the answer.

GROUNDING RULE: when you write your final prose answer, copy the
EXACT numbers, filenames, and headers from the printed tool output.
NEVER invent data — if the output said `6 rows; header: a,b,c`, do
not summarise it as `3 rows; header: name,age,city`. Quote the real
values. If you didn't actually receive the value from a tool call,
do not report it.

For tasks that genuinely need multiple separate steps (each step
depends on the previous step's output, or the steps are too big for
a single fence), you MAY write a checklist to `/tmp/state/PLAN.md`
to track progress, flipping `- [ ]` → `- [x]` after each step. Don't
do this for simple tasks — one fence is fine when the answer fits.
''';

// ---------------------------------------------------------------------------
// Seed fixtures (writable on both web MemFS and macOS /tmp)
// ---------------------------------------------------------------------------

const _fixtureWelcome = '''
# llama_monty — welcome

This is a tiny in-memory filesystem mounted at `/tmp/fixtures/`. The model can
list, read, and write here just like a real disk. Everything lives in this
browser tab — refresh and it's gone.

Try asking the assistant:
- "List the files under /tmp/fixtures and read welcome.md"
- "Compute the average of column2 in /tmp/fixtures/sample.csv"
- "Append a TODO to /tmp/fixtures/notes.txt"
''';

const _fixtureSampleCsv = '''
name,quantity,price
apples,12,0.45
bananas,5,0.20
cherries,30,0.10
dates,8,1.20
elderberries,3,2.50
''';

const _fixtureNotes = '''
- bridge: tool-call grammar still drops on web
- chat shell plugin: chat_summarize / chat_reset wired
- next: streaming + drag-drop fixtures
''';

/// Plants three small files in `/tmp/fixtures/` via Monty's `Path.*` ops so the
/// LLM has something to read on first launch. Runs the same Python in any
/// runtime; pass each runtime that needs the fixtures (the agent and the
/// REPL share the same MemoryFileSystem instance via [defaultOsHandler]).
Future<void> _seedFixtures(MontyRuntime runtime) async {
  final script = StringBuffer()
    ..writeln('from pathlib import Path')
    ..writeln("Path('/tmp/fixtures').mkdir(parents=True, exist_ok=True)")
    ..writeln(_writeFile('/tmp/fixtures/welcome.md', _fixtureWelcome))
    ..writeln(_writeFile('/tmp/fixtures/sample.csv', _fixtureSampleCsv))
    ..writeln(_writeFile('/tmp/fixtures/notes.txt', _fixtureNotes));
  final result = await runtime.execute(script.toString()).result;
  if (result.error != null) {
    // ignore: avoid_print
    print('[app] seed fixtures failed: ${result.error!.message}');
  }
}

/// Renders a `Path('...').write_text("""...""")` line with the content
/// safely escaped for triple-quoted Python.
String _writeFile(String path, String content) {
  final escaped = content.replaceAll(r'\', r'\\').replaceAll('"""', r'\"\"\"');
  return "Path('$path').write_text('''$escaped''')";
}

// ---------------------------------------------------------------------------
// Logger
// ---------------------------------------------------------------------------

class _ConsoleBridgeLogger implements BridgeLogger {
  const _ConsoleBridgeLogger([this._prefix = 'monty']);
  final String _prefix;

  @override
  void trace(String msg, {Map<String, Object?>? attributes}) {}

  @override
  void debug(String msg, {Map<String, Object?>? attributes}) =>
      // ignore: avoid_print
      print('[$_prefix:DEBUG] $msg');

  @override
  void info(String msg, {Map<String, Object?>? attributes}) =>
      // ignore: avoid_print
      print('[$_prefix:INFO] $msg');

  @override
  void warning(
    String msg, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) =>
      // ignore: avoid_print
      print('[$_prefix:WARN] $msg${error != null ? ' — $error' : ''}');

  @override
  void error(
    String msg, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) =>
      // ignore: avoid_print
      print(
        '[$_prefix:ERROR] $msg${error != null ? ' — $error' : ''}'
        '${stackTrace != null ? '\n$stackTrace' : ''}',
      );

  @override
  BridgeLogger child(String name) => _ConsoleBridgeLogger('$_prefix.$name');

  @override
  void close() {}
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DartMonty.ensureInitialized();
  runApp(const LlamaMontyWebApp());
}

class LlamaMontyWebApp extends StatelessWidget {
  const LlamaMontyWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'llama_monty',
      theme: ThemeData.dark(useMaterial3: true),
      home: const ChatPage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Chat page
// ---------------------------------------------------------------------------

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  // Chat
  final _inputCtrl = TextEditingController();
  final _modelPathCtrl = TextEditingController(text: _nativeModelPath);
  final _systemPromptCtrl =
      // Both backends use the same prompt: it explicitly lists pathlib
      // as the filesystem API and forbids `import os` / `with open` /
      // Python-2 print, which is what Gemma 4 needs to avoid the
      // try/except-swallowed-error spiral. Keeping a separate weaker
      // prompt for FFI was a leftover from the SmolLM2 era.
      TextEditingController(text: _webSystemPrompt);
  final _inputFocus = FocusNode();
  final _chatLog = <({String kind, String text})>[];
  final _scrollCtrl = ScrollController();

  // REPL
  final _replInputCtrl = TextEditingController();
  final _replScrollCtrl = ScrollController();
  final _replLog = <({String kind, String text})>[];
  bool _replBusy = false;

  // Engine / sessions
  LlamaEngine? _engine;
  LlamaEngineRef? _engineRef;
  ChatSession? _chatSession;
  // Chat-format detected from the loaded model's metadata. Used by the
  // tool-call fallback parser (mirrors how llamadart's chat_app handles
  // Gemma 4's special-token tool format that whereType<LlamaToolCallContent>
  // sometimes misses).
  ChatFormat? _detectedChatFormat;
  MontyRuntime? _agentSession; // used by run_python tool in chat
  MontyRuntime? _replRuntime; // used by Python REPL; has LlamaMontyPlugin
  ToolDefinition? _runPythonTool;

  double? _loadProgress;
  String _status = 'idle';
  bool _busy = false;
  int _contextTokens = 0;
  int _selectedExperiment = 0;

  // Files panel state — populated by _refreshFiles, viewed in _filesPanel.
  List<_FsEntry> _filesEntries = const [];
  bool _filesBusy = false;
  String? _filesViewPath;
  String? _filesViewContent;

  @override
  void initState() {
    super.initState();
    _autoRun();
  }

  static const _experiments = <({String name, String description, List<String> prompts})>[
    (
      name: 'Context Cliff',
      description:
          'Many short tasks — finds the token count where model stops calling tools',
      prompts: [
        'Compute 17 * 23 * 41 in Python and print the result',
        'Print the sum of all odd numbers from 1 to 99',
        'Print the 10th Fibonacci number (0-indexed)',
        'Print all prime numbers below 50',
        'Compute 2 ** 32 and print it',
        'Print the factorial of 12',
        'Sum the digits of 9876543210 and print the result',
        'Print the count of divisors of 720',
        'Compute the GCD of 1071 and 462 using the Euclidean algorithm — print each step and the result',
        'Print the sum of all multiples of 3 or 5 below 200',
        'Count integers from 1 to 100 where number mod 7 equals number mod 11 — print the count',
        'Compute 13 ** 7 mod 1000000007 and print it',
        'Print the 15th triangular number and the 10th square number',
        'Find the smallest number greater than 1000 that is divisible by both 17 and 23',
        'Print the binary representation of 255, 128, and 64',
      ],
    ),
    (
      name: 'Logic Gauntlet',
      description:
          'Complex multi-step problems — tests how sophisticated the reasoning gets',
      prompts: [
        'Implement bubble sort. Sort [64,34,25,12,22,11,90] and count the exact number of swaps made',
        'Find all Pythagorean triples (a,b,c) where a<b<c and a+b+c<=120 — print each triple and the total count',
        'Find the starting number from 1–100 with the longest Collatz sequence — print the number and its sequence length',
        'Find all 3-digit Armstrong numbers (sum of cubes of digits equals the number) — print each one',
        'Implement run-length encoding: encode "AAABBBCCDDDDEEEE", then decode back and verify round-trip',
        'Find all perfect numbers below 10000 (equal to sum of proper divisors) — print each and verify',
        'Calculate compound interest: 1000 at 7% annual compounded monthly for 30 years — print balance at each 5-year mark',
        'Find all emirp primes below 500 (prime, reverse is also prime, but different) — print them',
        'Sort [531,274,816,93,647,382,759,428,165,930] with insertion sort and count comparisons',
        'Find all integers from 1 to 200 divisible by their digit sum — print them',
      ],
    ),
    (
      name: 'Wild Card',
      description:
          'Fun & surprising — simulations, patterns, recreational math',
      prompts: [
        'Simulate the Monty Hall problem 10000 times — print win rates for "always switch" vs "never switch"',
        'Find all happy numbers between 1 and 100 (sum squares of digits repeatedly until 1 or cycle) — print them',
        'Print a diamond of * characters with height 9',
        'Apply the Kaprekar routine to 1234: sort digits descending minus ascending, repeat until 6174 — print each step',
        'Print the first 20 terms of the Recaman sequence: a[0]=0, a[n]=a[n-1]-n if positive and unseen, else a[n-1]+n',
        'Compute pi using the Leibniz formula with 500000 terms — print result vs math.pi',
        'Find all 4-digit perfect squares that are also palindromes — print them',
        'Simulate flipping a coin 10000 times — print heads count, tails count, and longest heads streak',
        'Find all numbers from 1 to 200 where the number equals the sum of factorials of its digits',
        'Find all 3-digit numbers that equal the sum of their digits raised to the power of the digit count',
      ],
    ),
    (
      name: 'Sandbox Workout',
      description:
          'Exercises files, datetime, json, and multi-step Python — '
          'shows the LLM USING the sandbox environment, not just '
          'computing numbers.',
      prompts: [
        // ---- files ------------------------------------------------------
        'List the files under /tmp/fixtures and print each filename + its size in bytes.',
        'Read /tmp/fixtures/welcome.md and print only the lines that start with a "-" (the bullet items), with leading "-" stripped.',
        'Read /tmp/fixtures/sample.csv. Header is "name,quantity,price". Compute and print the average price across all data rows, rounded to 2 decimal places. Do NOT import csv.',
        'Read /tmp/fixtures/sample.csv and compute total revenue = sum(quantity * price) across all rows. Print the total rounded to 2 decimals.',
        'Find the most-expensive item in /tmp/fixtures/sample.csv and print "name → price".',
        'Append the string "audit: reviewed by assistant" as a NEW line at the end of /tmp/fixtures/notes.txt, then print the full updated file.',
        'Write a JSON file to /tmp/llama_monty_files/summary.json containing {"file_count": N, "total_bytes": M} where N and M describe the contents of /tmp/fixtures. Then read it back and pretty-print with json.dumps(indent=2).',

        // ---- datetime ---------------------------------------------------
        'Print today\'s date in ISO format (YYYY-MM-DD).',
        'Print the current UTC time formatted as "HH:MM:SS UTC". Use datetime.now and strftime if available; otherwise build the string manually.',
        'Compute and print the number of days between 2026-01-01 and today.',
        'Print what day-of-week (Monday/Tuesday/etc.) the date 2026-12-25 falls on.',

        // ---- multi-step combining files + datetime + json ---------------
        'Build a dict {"generated_at": <ISO timestamp>, "fixtures": [<list of filenames under /tmp/fixtures>]} and print it as JSON.',
        'Read /tmp/fixtures/sample.csv and write a new file /tmp/llama_monty_files/sorted_by_price.csv with the same header but rows sorted by price descending. Then print the contents of the new file.',
        'Compute SHA-like checksum of /tmp/fixtures/welcome.md by summing the integer values of all its characters mod 1000000007. Print the result.',
        'Read /tmp/fixtures/notes.txt, count word occurrences across the whole file (case-insensitive, ignore punctuation), and print the 5 most common words with their counts.',
      ],
    ),
  ];

  Future<void> _autoRun() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _loadModel();
    // Auto-running an experiment on every page load was getting in the
    // way. Loading the model is enough — the user picks an experiment
    // from the dropdown and clicks Run, or types a slash command, or
    // just chats. Press Run if you want the Context Cliff sweep.
  }

  Future<void> _runExperiment() async {
    if (_chatSession == null || _busy) return;
    final exp = _experiments[_selectedExperiment];
    _appendChatLog('sys', '--- ${exp.name}: ${exp.description} ---');
    for (var idx = 0; idx < exp.prompts.length; idx++) {
      _inputCtrl.text = exp.prompts[idx];
      // ignore: avoid_print
      print(
        '[experiment:${exp.name}] prompt ${idx + 1}/${exp.prompts.length}: ${exp.prompts[idx]}',
      );
      await _send();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    _appendChatLog('sys', '--- ${exp.name} complete ---');
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _modelPathCtrl.dispose();
    _systemPromptCtrl.dispose();
    _replInputCtrl.dispose();
    _inputFocus.dispose();
    _scrollCtrl.dispose();
    _replScrollCtrl.dispose();
    unawaited(_agentSession?.dispose());
    unawaited(_replRuntime?.dispose());
    unawaited(_engine?.dispose());
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Load model
  // -------------------------------------------------------------------------

  Future<void> _loadModel() async {
    setState(() {
      _status = 'loading model…';
      _loadProgress = kIsWeb ? 0 : null;
      _busy = true;
    });

    final engine = LlamaEngine(LlamaBackend());
    try {
      if (kIsWeb) {
        await engine.loadModelFromUrl(
          _modelUrl,
          onProgress: (p) => setState(() => _loadProgress = p),
        );
      } else {
        await engine.loadModel(
          _modelPathCtrl.text.trim(),
          modelParams: ModelParams(contextSize: 32768),
        );
      }
    } catch (e) {
      setState(() {
        _status = 'load failed: $e';
        _busy = false;
        _loadProgress = null;
      });
      await engine.dispose();
      return;
    }

    // Detect the model's chat format from its metadata. Used by the
    // tool-call fallback parser below. Mirrors what llamadart's chat_app
    // does to handle Gemma 4's special-token tool format.
    try {
      final metadata = await engine.getMetadata();
      final toolTpl = metadata['tokenizer.chat_template.tool_use'];
      final defaultTpl = metadata['tokenizer.chat_template'];
      final eff = (toolTpl != null && toolTpl.trim().isNotEmpty)
          ? toolTpl
          : defaultTpl;
      if (eff != null && eff.trim().isNotEmpty) {
        _detectedChatFormat = ChatTemplateEngine.detectFormat(eff);
        // ignore: avoid_print
        print('[app] detected chat format: $_detectedChatFormat');
      }
    } catch (_) {
      /* best-effort */
    }

    // Engine ref serialises concurrent LLM calls from chat + REPL +
    // recursive llm_complete invocations from inside run_python.
    final engineRef = LlamaEngineRef(engine);

    // Agent runtime — Python sandbox for the LLM's run_python tool. We wire:
    //  - LlamaMontyPlugin: llm_complete / llm_chat / llm_chat_reset
    //  - ChatShellPlugin: chat_history / chat_summarize / chat_reset
    // so the Python the LLM writes can introspect, summarize, and reset its
    // own outer chat shell when context is getting long.
    final chatShellPlugin = ChatShellPlugin(
      engineRef: engineRef,
      shell: () => _chatSession!,
    );
    // Wire the platform-aware OS handler so Python code from the LLM can
    // access pathlib (Path.read_text / iterdir / write_text), datetime, and
    // (on native) os.environ. Without this, even `datetime.now()` resolves
    // to PermissionError.
    //
    // We build ONE OsCallHandler and share it across both runtimes so the
    // chat agent and the REPL see the same filesystem — files the LLM
    // writes via run_python show up immediately in the REPL, and vice
    // versa.
    //
    // - Native: LocalFileSystem (full disk access) + host env + clock.
    // - Web:    MemoryFileSystem (in-page) + clock; no env.
    final sharedOs = defaultOsHandler();

    final agentSession = MontyRuntime(
      os: sharedOs,
      logger: const _ConsoleBridgeLogger(),
      extensions: [
        LlamaMontyPlugin(engineRef),
        chatShellPlugin,
        // platformFactory uses createPlatformMonty (FFI on native, WASM
        // on web) so children inherit the same backend the parent runs.
        SandboxExtension(
          platformFactory: () async => createPlatformMonty(),
          // Children share the parent's Path. handler so /tmp/fixtures/ and
          // anything else the parent has mounted is visible to the
          // subagent. Otherwise the default 'isolated' strategy gives
          // children a fresh empty MemoryFileSystem.
          childVfsStrategy: ChildVfsStrategy.shared,
        ),
      ],
    );

    // REPL runtime — same surface for ad-hoc tinkering.
    final replRuntime = MontyRuntime(
      os: sharedOs,
      logger: const _ConsoleBridgeLogger('repl'),
      extensions: [
        LlamaMontyPlugin(engineRef),
        chatShellPlugin,
        // platformFactory uses createPlatformMonty (FFI on native, WASM
        // on web) so children inherit the same backend the parent runs.
        SandboxExtension(
          platformFactory: () async => createPlatformMonty(),
          // Children share the parent's Path. handler so /tmp/fixtures/ and
          // anything else the parent has mounted is visible to the
          // subagent. Otherwise the default 'isolated' strategy gives
          // children a fresh empty MemoryFileSystem.
          childVfsStrategy: ChildVfsStrategy.shared,
        ),
      ],
    );

    // Seed a tiny fixtures directory at /tmp/fixtures/ so the LLM has
    // something concrete to read on first launch. /tmp is writable on
    // both platforms (web's MemoryFileSystem and macOS's real disk).
    // The two runtimes share the same OS handler so seeding once is
    // enough.
    await _seedFixtures(agentSession);

    final runPythonTool = ToolDefinition(
      name: 'run_python',
      description:
          'Execute Python code in the Monty runtime. '
          'State (variables, imports) persists across calls.',
      parameters: [
        ToolParam.string(
          'code',
          description: 'Python code to execute',
          required: true,
        ),
      ],
      handler: (params) async {
        final code = params.getRequiredString('code');
        _appendChatLog('code', code);

        // Pre-flight: catch patterns Monty would otherwise let through
        // at parse time but fail at runtime (`import os` parses fine,
        // every `os.*` access AttributeErrors). Weak models wrap such
        // calls in try/except, swallow the failure, then apologize and
        // give up. Reject hard up-front so the retry nudge fires with a
        // pointed rewrite hint.
        final preflight = _preflightForbidden(code);
        if (preflight != null) {
          _appendChatLog('error', preflight);
          return 'Error: $preflight';
        }

        final result = await agentSession.execute(code).result;

        if (result.error != null) {
          final err = result.error!.message;
          _appendChatLog('error', err);
          return 'Error: $err';
        }

        // INTENTIONALLY drop result.value: Monty's MontyInt(42),
        // MontyList(N items), MontyDict(N entries) wrapper-debug
        // strings leak through .toString() and confuse the LLM, which
        // either copies them literally ("MontyList(3 items)") or
        // hallucinates real-looking data instead. The system prompt
        // tells the model that ONLY print() surfaces data — this
        // handler enforces it.
        final out = result.printOutput?.trim() ?? '';
        // The model often writes `try: os.listdir(p) except: print('an
        // error occurred:', e)`. Monty reports success (no exception
        // bubbled), but the print output IS the error. Treat it as a
        // failure so the harness's retry nudge fires instead of the LLM
        // seeing "OK output: An error occurred…" and giving up.
        if (out.isNotEmpty && _looksLikeSwallowedError(out)) {
          _appendChatLog('error', out);
          return 'Error (swallowed by try/except): $out';
        }
        final display = out.isEmpty ? '(no output)' : out;
        _appendChatLog('output', display);
        // Append a decision directive so the model sees the
        // stop-or-continue rule right at the moment it picks its
        // next response. Without this, weak models (Gemma 4 E2B)
        // tend to default to "write another fence" even when the
        // output already answers the question. The "USE THE EXACT
        // VALUES" line is the anti-hallucination guardrail — Gemma
        // 4 E2B otherwise tends to fabricate plausible CSV headers
        // and row counts from training data instead of reading the
        // real output above.
        return '$display\n\n'
            '[harness] If the above output answers the user\'s question, '
            'reply in plain prose USING THE EXACT VALUES (numbers, '
            'filenames, headers) from the output above. Do NOT invent '
            'or substitute different data. If the output is insufficient, '
            'write the next fence.';
      },
    );

    final chatSession = ChatSession(
      engine,
      systemPrompt: _systemPromptCtrl.text,
    );

    // ignore: avoid_print
    print('[app] model loaded — starting chat + REPL sessions');

    setState(() {
      _engine = engine;
      _engineRef = engineRef;
      _chatSession = chatSession;
      _agentSession = agentSession;
      _replRuntime = replRuntime;
      _runPythonTool = runPythonTool;
      _status = 'ready';
      _loadProgress = null;
      _busy = false;
    });

    _appendChatLog(
      'sys',
      'Model loaded. Python runtime ready.\n'
          'The LLM can execute Python via run_python — state persists across calls.\n\n'
          'Slash commands:  /help  /summarize  /compress  /reset  /history  /files',
    );

    // Also show what's in the seeded /tmp/fixtures/ directory so the user
    // knows files are mounted and ready to read.
    if (kIsWeb) {
      try {
        final ls = await agentSession.execute('''
from pathlib import Path
root = Path('/tmp/fixtures')
if root.exists():
  out = []
  for p in root.iterdir():
    txt = p.read_text() if p.is_file() else ''
    out.append(p.name + ' (' + str(len(txt)) + ' bytes)')
  print('\\n'.join(sorted(out)))
else:
  print('(none)')
''').result;
        final listing = (ls.printOutput ?? '').trim();
        if (listing.isNotEmpty && listing != '(none)') {
          _appendChatLog(
            'sys',
            '/tmp/fixtures contents:\n$listing\n\n'
                'Try: "read welcome.md", "what\'s the average price in '
                'sample.csv", or "summarize notes.txt".',
          );
        }
      } catch (_) {
        /* fixture listing is best-effort */
      }
    }

    _appendReplLog(
      'sys',
      'LLM functions available in this REPL:\n'
          '  llm_complete(prompt, system_prompt=None) → str\n'
          '  llm_chat(message, system_prompt=None) → str\n'
          '  llm_chat_reset(keep_system_prompt=True) → None\n\n'
          'State persists across runs.',
    );
  }

  // -------------------------------------------------------------------------
  // Send message — agentic loop
  // -------------------------------------------------------------------------

  Future<void> _send() async {
    final msg = _inputCtrl.text.trim();
    if (msg.isEmpty || _chatSession == null || _busy) return;

    _inputCtrl.clear();
    _appendChatLog('user', msg);
    setState(() {
      _status = 'thinking…';
      _busy = true;
    });

    // Slash commands short-circuit the LLM round-trip and call host
    // functions directly through the agent runtime. Built-in:
    //   /help        — list slash commands
    //   /summarize   — run chat_summarize_v2 and print the result
    //   /compress    — chat_summarize_v2 + chat_reset(seed=summary)
    //   /reset       — chat_reset (clears history, keeps system prompt)
    if (msg.startsWith('/')) {
      try {
        await _handleSlash(msg);
      } finally {
        unawaited(_updateContextTokens());
        setState(() {
          _status = 'ready';
          _busy = false;
        });
        _inputFocus.requestFocus();
      }
      return;
    }

    try {
      var parts = <LlamaContentPart>[LlamaTextContent(msg)];
      // Iterative-decomposition cap: the LLM writes a fence, host runs
      // it, result is fed back, LLM writes the next fence, etc. We stop
      // when the LLM emits no fence (just prose) OR when the
      // accumulated context-token budget exceeds [maxContextTokens]. A
      // hard turn cap guards against an infinite loop on a confused
      // model.
      const maxContextTokens = 6000;
      const hardTurnCap = 12;
      var fenceTurns = 0;
      var toolRetries = 0;
      const maxToolRetries = 3;
      var errorNudgeCount = 0;
      const maxErrorNudges = 4;
      var lastRoundHadError = false;
      // Captured on every fence/tool failure so the retry nudge can
      // refer to the EXACT bad code and error when we reset history.
      String? lastFailedCode;
      String? lastFailedError;
      // Loop-spin detection: if the model submits the SAME code two
      // turns in a row, it's stuck regenerating instead of responding
      // to its own tool output. Break the loop with a system note.
      String? lastSubmittedCode;

      while (true) {
        String? finishReason;
        final rawContentBuffer = StringBuffer();

        // Plant a streaming placeholder bubble that we'll update as
        // chunks arrive. Index it so we can rewrite that exact entry
        // every chunk, instead of appending fresh entries each tick.
        _appendChatLog('assistant', '');
        final streamIdx = _chatLog.length - 1;
        var lastFlush = DateTime.now();

        // On web the WebGPU bridge's grammar sampler aborts when constraining
        // tool-call JSON — we drop tools entirely there and rely on the
        // ```python fence the system prompt asks for. On native FFI the
        // grammar sampler is fine, so keep structured tool calls.
        await for (final chunk in _chatSession!.create(
          parts,
          tools: kIsWeb ? null : [_runPythonTool!],
        )) {
          final choice = chunk.choices.firstOrNull;
          if (choice?.finishReason != null) finishReason = choice!.finishReason;
          final content = choice?.delta.content;
          if (content != null) rawContentBuffer.write(content);
          // Throttle UI updates to ~30Hz so we don't repaint on every
          // single token (which can choke on very fast streams).
          final now = DateTime.now();
          if (now.difference(lastFlush).inMilliseconds >= 33) {
            lastFlush = now;
            if (streamIdx < _chatLog.length) {
              setState(() {
                _chatLog[streamIdx] = (
                  kind: 'assistant',
                  text: rawContentBuffer.toString(),
                );
              });
            }
          }
        }
        // Drop the streaming placeholder unconditionally — the
        // downstream paths below (fence-extraction, tool-call,
        // prose-only) each render the final message in their own
        // shape (e.g., split into prose + code + output bubbles).
        // Visual effect: live tokens stream in, then on completion
        // the bubble is replaced by the proper final rendering.
        if (streamIdx < _chatLog.length) {
          setState(() {
            _chatLog.removeAt(streamIdx);
          });
        }

        final rawContent = rawContentBuffer.toString();

        final lastMsg = _chatSession!.history.lastOrNull;
        var toolCallParts =
            lastMsg?.parts.whereType<LlamaToolCallContent>().toList() ?? [];

        // Fallback: if the standard whereType extraction came up empty
        // but the finishReason says tool_calls, re-parse the raw streamed
        // content with ChatTemplateEngine. This catches Gemma 4's special-
        // token format `<|tool_call>call:NAME{KEY:<|"|>VAL<|"|>}<tool_call|>`
        // that the standard path sometimes misses (mirrors llamadart's
        // chat_app AssistantOutputService.parseToolCallsForDisplay).
        if (toolCallParts.isEmpty &&
            finishReason == 'tool_calls' &&
            _detectedChatFormat != null &&
            rawContent.isNotEmpty) {
          try {
            final parsed = ChatTemplateEngine.parse(
              _detectedChatFormat!.index,
              rawContent,
              parseToolCalls: true,
            );
            if (parsed.hasToolCalls) {
              toolCallParts = parsed.toolCalls
                  .where((tc) => (tc.function?.name?.trim() ?? '').isNotEmpty)
                  .map((tc) {
                    Map<String, Object?> args = const {};
                    final raw = tc.function?.arguments;
                    if (raw != null && raw.trim().isNotEmpty) {
                      try {
                        final decoded = jsonDecode(raw);
                        if (decoded is Map<String, Object?>) args = decoded;
                      } catch (_) {
                        /* leave empty */
                      }
                    }
                    return LlamaToolCallContent(
                      id: tc.id,
                      name: tc.function!.name!.trim(),
                      arguments: args,
                      rawJson: jsonEncode(<String, Object?>{
                        'name': tc.function!.name!.trim(),
                        'arguments': args,
                      }),
                    );
                  })
                  .toList();
              // ignore: avoid_print
              print(
                '[app] fallback parser recovered '
                '${toolCallParts.length} tool call(s)',
              );
            }
          } catch (_) {
            /* parse failures fall through */
          }
        }

        // ignore: avoid_print
        print(
          '[app] finishReason=$finishReason toolCalls=${toolCallParts.length}',
        );

        if (finishReason == 'tool_calls' && toolCallParts.isNotEmpty) {
          if (toolRetries >= maxToolRetries) {
            _appendChatLog(
              'sys',
              'Max tool retries ($maxToolRetries) reached — stopping.',
            );
            break;
          }

          lastRoundHadError = false;
          for (final tc in toolCallParts) {
            String resultStr;
            final effectiveArgs = tc.arguments.isNotEmpty
                ? tc.arguments
                : _extractGemma4SingleStringArg(rawContent, tc.name, 'code');

            if (effectiveArgs.isEmpty) {
              toolRetries++;
              lastRoundHadError = true;
              // ignore: avoid_print
              print('[app] PARSE FAIL rawContent=\n$rawContent\n---');
              resultStr =
                  'Error: tool call for "${tc.name}" was received with no '
                  'arguments. Please call ${tc.name} again and include all '
                  'required parameters (e.g. the "code" string).';
              _appendChatLog(
                'sys',
                'tool=${tc.name} args missing — retry $toolRetries/$maxToolRetries',
              );
            } else {
              toolRetries = 0;
              // Show a distinct "tool call" entry so it's easy to spot.
              _appendChatLog('tool', tc.name);
              final submittedCode = effectiveArgs['code']?.toString() ?? '';
              if (submittedCode.isNotEmpty &&
                  submittedCode == lastSubmittedCode) {
                _appendChatLog(
                  'sys',
                  'Loop-spin detected: identical code two turns in a row. '
                  'Stopping. Type a follow-up to continue.',
                );
                break;
              }
              lastSubmittedCode = submittedCode;
              try {
                resultStr =
                    await _runPythonTool!.invoke(effectiveArgs) as String? ??
                    '(no output)';
              } catch (e) {
                resultStr = 'Error: $e';
                _appendChatLog('error', resultStr);
              }
              if (resultStr.startsWith('Error:')) {
                lastRoundHadError = true;
                lastFailedCode = effectiveArgs['code']?.toString() ?? '';
                lastFailedError = resultStr;
              }
            }

            _chatSession!.addMessage(
              LlamaChatMessage.withContent(
                role: LlamaChatRole.tool,
                content: [
                  LlamaToolResultContent(
                    name: tc.name,
                    result: resultStr,
                    id: tc.id,
                  ),
                ],
              ),
            );
          }
          parts = [];
        } else {
          if (lastRoundHadError && errorNudgeCount < maxErrorNudges) {
            errorNudgeCount++;
            lastRoundHadError = false;
            _appendChatLog(
              'sys',
              'LLM skipped retry after error — resetting context and nudging '
              '($errorNudgeCount/$maxErrorNudges)',
            );
            // ignore: avoid_print
            print(
              '[app] context-reset retry after error '
              '($errorNudgeCount/$maxErrorNudges)',
            );
            _resetChatWithPointedRetry(
              originalPrompt: msg,
              code: lastFailedCode ?? '',
              error: lastFailedError ?? 'unknown error',
            );
            parts = [];
            continue;
          }

          var text =
              lastMsg?.parts
                  .whereType<LlamaTextContent>()
                  .map((p) => p.text)
                  .join() ??
              '';
          text = text
              .replaceAll(RegExp(r'<\|channel\>[\s\S]*?<channel\|>'), '')
              .replaceAll('<eos>', '')
              .replaceAll('<end_of_turn>', '')
              .replaceAll('<start_of_turn>', '')
              .trim();

          // Fence fallback: when the model emits ```monty / ```python
          // markdown instead of a structured tool call (always on web,
          // sometimes on FFI when the system prompt heavily nudges
          // toward fences), extract the code and run it through the
          // same run_python tool.
          final fenceCode = _extractPythonFence(text);
          if (fenceCode != null && fenceCode.trim().isNotEmpty) {
            if (fenceCode == lastSubmittedCode) {
              _appendChatLog(
                'sys',
                'Loop-spin detected: identical fence two turns in a row. '
                'Stopping. Type a follow-up to continue.',
              );
              break;
            }
            lastSubmittedCode = fenceCode;
            final prose = _stripPythonFence(text).trim();
            if (prose.isNotEmpty) _appendChatLog('assistant', prose);
            _appendChatLog('tool', 'run_python (from fence)');
            String resultStr;
            try {
              resultStr =
                  await _runPythonTool!.invoke({'code': fenceCode})
                      as String? ??
                  '(no output)';
            } catch (e) {
              resultStr = 'Error: $e';
              _appendChatLog('error', resultStr);
            }
            // Hard failure: tool returned `Error: ...`.
            // Soft failure: program "succeeded" but its print output looks
            // like a swallowed exception (e.g. `try: ... except: print('an
            // error occurred:', e)`). Treat both as failures so the retry
            // nudge fires and the LLM gets a pointed rewrite hint.
            final fenceFailed =
                resultStr.startsWith('Error:') ||
                _looksLikeSwallowedError(resultStr);
            // Feed the tool result back so the model can react.
            _chatSession!.addMessage(
              LlamaChatMessage.withContent(
                role: LlamaChatRole.tool,
                content: [
                  LlamaToolResultContent(name: 'run_python', result: resultStr),
                ],
              ),
            );
            // On error: reset chat history so the bad fence isn't in the
            // model's KV cache anchoring the next attempt, then replay the
            // ORIGINAL user prompt with a pointed corrective hint as one
            // consolidated user turn. This is what actually breaks the
            // "model keeps regenerating the same broken code" loop.
            if (fenceFailed && errorNudgeCount < maxErrorNudges) {
              errorNudgeCount++;
              lastFailedCode = fenceCode;
              lastFailedError = resultStr;
              _appendChatLog(
                'sys',
                'Code failed — resetting context, replaying prompt with hint '
                '($errorNudgeCount/$maxErrorNudges)',
              );
              _resetChatWithPointedRetry(
                originalPrompt: msg,
                code: fenceCode,
                error: resultStr,
              );
              parts = [];
              continue;
            }
            // Success: keep looping so the LLM can react to the output
            // and decompose the task into the next small step. Stops
            // when the LLM emits no fence (just prose) OR when the
            // context-token budget is exhausted.
            fenceTurns++;
            await _updateContextTokens();
            if (_contextTokens >= maxContextTokens) {
              _appendChatLog(
                'sys',
                'Stopping iteration: context at $_contextTokens '
                    'tokens (cap $maxContextTokens). Type something to '
                    'continue, or /compress to summarize and reset.',
              );
              break;
            }
            if (fenceTurns >= hardTurnCap) {
              _appendChatLog(
                'sys',
                'Stopping iteration: hit hard $hardTurnCap-step cap. '
                    'Type "continue" to keep going.',
              );
              break;
            }
            parts = [];
            continue;
          }

          if (text.isNotEmpty) _appendChatLog('assistant', text);
          break;
        }
      }
    } catch (e, st) {
      _appendChatLog('error', '$e\n$st');
    } finally {
      unawaited(_updateContextTokens());
      setState(() {
        _status = 'ready';
        _busy = false;
      });
      _inputFocus.requestFocus();
      _scrollToBottom();
    }
  }

  // -------------------------------------------------------------------------
  // Slash commands — invoke ChatShellPlugin host functions directly.
  // -------------------------------------------------------------------------

  Future<void> _handleSlash(String raw) async {
    final cmd = raw.split(RegExp(r'\s+')).first.toLowerCase();
    final argText = raw.substring(cmd.length).trim();
    final agent = _agentSession;
    if (agent == null) {
      _appendChatLog('sys', 'agent runtime not ready');
      return;
    }

    // Subscribe to the runtime's broadcast event stream so any
    // BridgeFunctionEmit from a host function (e.g. the summarize
    // pipeline) becomes a visible 'sys' line in the chat. Wired up
    // BEFORE the execute call below; cancelled in finally.
    final emitSub = agent.events.listen((event) {
      if (event is BridgeFunctionEmit && event.text.isNotEmpty) {
        _appendChatLog('sys', event.text);
      }
    });

    try {
      switch (cmd) {
        case '/help':
          _appendChatLog(
            'sys',
            'Slash commands:\n'
                '  /summarize           run chat_summarize_v2 and print the result\n'
                '  /compress            summarize_v2 then chat_reset with the summary as seed\n'
                '  /reset [seed text]   chat_reset (wipe history; optional seed)\n'
                '  /history             dump the current chat_history()\n'
                '  /files [path]        list files under /tmp/fixtures (or any path)\n'
                '  /help                this list',
          );
        case '/summarize':
          _appendChatLog('tool', 'chat_summarize_v2 (multi-step pipeline)');
          final r = await agent.execute('print(chat_summarize_v2())').result;
          if (r.error != null) {
            _appendChatLog('error', r.error!.message);
          } else {
            _appendChatLog('assistant', (r.printOutput ?? '').trim());
          }
        case '/compress':
          _appendChatLog('tool', 'chat_summarize_v2 → chat_reset(seed=…)');
          final script = '''
summary = chat_summarize_v2()
print('--- summary ---')
print(summary)
chat_reset(keep_system_prompt=True, seed='Earlier in this conversation: ' + summary)
print('--- chat reset, seeded with summary ---')
''';
          final r = await agent.execute(script).result;
          if (r.error != null) {
            _appendChatLog('error', r.error!.message);
          } else {
            _appendChatLog('output', (r.printOutput ?? '').trim());
            // Also force the chat session to re-pick-up the new state by
            // reloading the field — chat_reset operates on _chatSession
            // directly via the ChatShellPlugin, so no further wiring needed.
            setState(() {});
          }
        case '/reset':
          // Optional argument is a seed string (everything after /reset).
          final seedArg = argText.isEmpty
              ? 'None'
              : "'''${argText.replaceAll(r'\', r'\\').replaceAll("'''", r"\'\'\'")}'''";
          _appendChatLog('tool', 'chat_reset(seed=$seedArg)');
          final r = await agent
              .execute(
                'chat_reset(keep_system_prompt=True, seed=$seedArg)\n'
                "print('chat reset')",
              )
              .result;
          if (r.error != null) {
            _appendChatLog('error', r.error!.message);
          } else {
            _appendChatLog('sys', (r.printOutput ?? 'reset').trim());
            setState(() {});
          }
        case '/history':
          _appendChatLog('tool', 'chat_history()');
          final r = await agent.execute('print(chat_history())').result;
          if (r.error != null) {
            _appendChatLog('error', r.error!.message);
          } else {
            _appendChatLog('output', (r.printOutput ?? '').trim());
          }
        case '/files':
          // List anything under /tmp/fixtures/ — the seed dir on web. Argument
          // (if any) is treated as a different root.
          final root = argText.isEmpty ? '/tmp/fixtures' : argText;
          _appendChatLog('tool', "list($root)");
          final r = await agent.execute('''
from pathlib import Path
p = Path('$root')
if not p.exists():
  print('(does not exist)')
else:
  for entry in sorted(p.iterdir(), key=lambda q: q.name):
    if entry.is_file():
      print(entry.name, '(' + str(len(entry.read_text())) + ' bytes)')
    else:
      print(entry.name + '/')
''').result;
          if (r.error != null) {
            _appendChatLog('error', r.error!.message);
          } else {
            _appendChatLog('output', (r.printOutput ?? '(empty)').trim());
          }
        default:
          _appendChatLog('sys', 'unknown slash command: $cmd (try /help)');
      }
    } finally {
      await emitSub.cancel();
    }
  }

  // -------------------------------------------------------------------------
  // Python REPL
  // -------------------------------------------------------------------------

  Future<void> _runRepl() async {
    final code = _replInputCtrl.text.trim();
    if (code.isEmpty || _replRuntime == null || _replBusy) return;

    setState(() => _replBusy = true);
    _appendReplLog('code', code);

    try {
      final result = await _replRuntime!.execute(code).result;

      if (result.error != null) {
        _appendReplLog('error', result.error!.message);
      } else {
        final parts = <String>[
          if (result.printOutput case final o? when o.isNotEmpty) o.trim(),
          if (result.value case final v? when v is! MontyNone) v.toString(),
        ];
        final out = parts.join('\n').trim();
        _appendReplLog('output', out.isEmpty ? '(no output)' : out);
      }
    } catch (e) {
      _appendReplLog('error', e.toString());
    } finally {
      setState(() => _replBusy = false);
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Extracts a single string argument from a Gemma-4 raw tool-call stream.
  Map<String, dynamic> _extractGemma4SingleStringArg(
    String content,
    String toolName,
    String paramName,
  ) {
    final cleaned = content.replaceAll(
      RegExp(r'<\|channel\>[\s\S]*?<channel\|>'),
      '',
    );

    final result = _extractCustomTokenArg(cleaned, toolName, paramName);
    if (result.isNotEmpty) return result;

    final jsonResult = _extractJsonStringArg(cleaned, toolName, paramName);
    if (jsonResult.isNotEmpty) return jsonResult;

    if (cleaned.contains('\\"')) {
      final unescaped = _preUnescapeJson(cleaned);
      return _extractJsonStringArg(unescaped, toolName, paramName);
    }

    return {};
  }

  /// Extract Monty/Python code from a model response. Tries:
  ///  1. ```monty fenced block (preferred — cues the restricted subset)
  ///  2. ```python or bare ``` fenced block (legacy / fallback)
  ///  3. Raw Python heuristic (text starts with print(/def /import / etc.)
  String? _extractPythonFence(String text) {
    final fenced = RegExp(
      r'```(?:monty|python|py)?\s*\n?([\s\S]*?)```',
    ).firstMatch(text);
    if (fenced != null) {
      final code = fenced.group(1)?.trim();
      if (code != null && code.isNotEmpty) {
        // ignore: avoid_print
        print('[app] fence.match=fenced len=${code.length}');
        return code;
      }
    }
    // Raw Python heuristic: if the model just emits code (no fences),
    // treat the whole response as code when it looks Python-shaped.
    final cleaned = text.trim();
    if (cleaned.isEmpty) return null;
    final looksPython = RegExp(
      r'(^|\n)\s*(print\s*\(|def\s+\w|import\s+\w|from\s+\w|for\s+\w|while\s+|if\s+|return\s+|[a-zA-Z_]\w*\s*=)',
    ).hasMatch(cleaned);
    if (looksPython) {
      // ignore: avoid_print
      print('[app] fence.match=raw-heuristic len=${cleaned.length}');
      return cleaned;
    }
    // ignore: avoid_print
    print(
      '[app] fence.match=none firstChars=${cleaned.substring(0, cleaned.length > 80 ? 80 : cleaned.length)}',
    );
    return null;
  }

  /// Wipes the LLM chat history (keeping the system prompt) and replays
  /// the user's original task as a single consolidated user turn that
  /// includes a pointed corrective hint. The model never sees its own
  /// previous bad reply in context, so it isn't anchored on the broken
  /// code in the KV cache. Without this, weak models (like Gemma 4 E2B)
  /// regenerate the same `import os` / `with open` over and over even
  /// when we feed them an explicit "use pathlib" nudge.
  void _resetChatWithPointedRetry({
    required String originalPrompt,
    required String code,
    required String error,
  }) {
    final hint = _pointedNudge(code: code, error: error);
    final consolidated = StringBuffer()
      ..writeln(originalPrompt)
      ..writeln()
      ..writeln('NOTE: a previous attempt at this exact task failed. '
          'Read the correction below and rewrite the program from scratch.')
      ..writeln()
      ..writeln(hint);
    _chatSession!.reset();
    _chatSession!.addMessage(
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: consolidated.toString(),
      ),
    );
  }

  /// Pre-flight gate for `run_python`: returns a non-null error message
  /// if [code] contains a pattern Monty cannot run. Some of these
  /// (notably `import os`) are accepted by the parser but blow up at
  /// runtime in ways the model will then catch and silently print —
  /// hard-failing here forces the retry nudge to fire.
  String? _preflightForbidden(String code) {
    if (RegExp(r'(^|\n)\s*import\s+os\b').hasMatch(code) ||
        RegExp(r'(^|\n)\s*from\s+os\b').hasMatch(code)) {
      return 'The `os` module is not available in Monty. Use `pathlib`: '
          '`from pathlib import Path`, then `Path(p).iterdir()` to list '
          'a directory, `Path(p).read_text()` to read a file, '
          '`Path(p).write_text(s)` to write a file.';
    }
    if (RegExp(r'\bwith\s+open\b').hasMatch(code)) {
      return 'Context managers (`with`) are not supported. Replace '
          '`with open(p) as f: data = f.read()` with '
          '`data = Path(p).read_text()`. Replace '
          '`with open(p, "w") as f: f.write(s)` with '
          '`Path(p).write_text(s)`.';
    }
    if (RegExp(r'(^|\n)\s*print\s+(?!\()').hasMatch(code)) {
      return 'Use `print(x)` (a function call with parentheses), NOT '
          '`print x`. Python 2 syntax is rejected.';
    }
    if (RegExp(r'(^|\n)\s*class\s+\w').hasMatch(code)) {
      return 'The `class` keyword is not supported. Use plain functions '
          'and dicts instead.';
    }
    return null;
  }

  /// True if [output] looks like a try/except-swallowed Python error
  /// (the program ran "successfully" but printed its own caught
  /// exception). Lets the retry nudge fire so the LLM rewrites its
  /// program instead of treating its own swallowed error as a
  /// sandbox limitation.
  bool _looksLikeSwallowedError(String output) {
    final lower = output.toLowerCase();
    final patterns = [
      RegExp(r'\ban error occurred\b'),
      RegExp(r'\btraceback\b'),
      RegExp(r'^\s*error\s*:', multiLine: true),
      RegExp(
        r'\b(attribute|name|type|value|key|index|module|import|os|file)error\b',
      ),
      RegExp(r"\bmodule '[^']+' has no attribute\b"),
      RegExp(r'\bis not defined\b'),
      RegExp(r'\bno module named\b'),
      RegExp(r"\bcan't access\b"),
      RegExp(r'\bpermission denied\b'),
    ];
    return patterns.any((p) => p.hasMatch(lower));
  }

  /// Builds a retry message that calls out the specific forbidden
  /// patterns found in [code]. Weaker models (SmolLM2-1.7B) ignore the
  /// generic "produced an error" prompt and re-emit the same `import os`
  /// / `with open(...)` / `.format()` repeatedly; a pointed rewrite hint
  /// helps them evolve the program.
  String _pointedNudge({required String code, required String error}) {
    final hints = <String>[];
    if (code.contains('import os')) {
      hints.add(
        'Remove `import os` — that module is NOT available. Use `pathlib`: '
        '`from pathlib import Path`, then `Path(p).read_text()`, '
        '`Path(p).write_text(s)`, `Path(d).iterdir()`.',
      );
    }
    if (RegExp(r'\bwith\s+open\b').hasMatch(code)) {
      hints.add(
        'Replace `with open(p) as f: data = f.read()` with '
        '`data = Path(p).read_text()`. Replace '
        '`with open(p, "w") as f: f.write(s)` with `Path(p).write_text(s)`. '
        'Context managers (`with`) are NOT supported.',
      );
    }
    if (RegExp(r'^\s*print\s+(?!\()', multiLine: true).hasMatch(code)) {
      hints.add(
        'Use `print(x)` (a function call with parentheses), NOT `print x`. '
        'Python 2 syntax is rejected.',
      );
    }
    if (code.contains('.format(')) {
      hints.add(
        'Replace `"{:.2f}".format(x)` with `round(x, 2)` or an f-string. '
        '`.format()` is rejected.',
      );
    }
    if (RegExp(r'"[^"]*"\s*%\s+\w').hasMatch(code) ||
        RegExp(r"'[^']*'\s*%\s+\w").hasMatch(code)) {
      hints.add(
        'Replace `"%.2f" % x` with `round(x, 2)` or an f-string. '
        '`%` string formatting is rejected.',
      );
    }
    if (RegExp(r'^\s*class\s+\w', multiLine: true).hasMatch(code)) {
      hints.add(
        'Remove the `class` definition — classes are rejected. Use plain '
        'functions and dicts instead.',
      );
    }
    final buf = StringBuffer(
      'Your last Monty program produced an error: $error\n',
    );
    if (hints.isNotEmpty) {
      buf.writeln('Specific fixes for THIS code:');
      for (final h in hints) {
        buf.writeln('  • $h');
      }
    }
    buf.write(
      'Write a CORRECTED program in a ```monty fence. Do not give the '
      'answer in prose.',
    );
    return buf.toString();
  }

  /// Removes the first monty/python fence (and surrounding blank lines)
  /// from [text]. Used to display non-code prose as the assistant
  /// message when code is extracted via [_extractPythonFence].
  String _stripPythonFence(String text) {
    final stripped = text.replaceFirst(
      RegExp(r'```(?:monty|python|py)?\s*\n?[\s\S]*?```\s*'),
      '',
    );
    // If no fence existed (raw-heuristic match), there's no prose to keep.
    if (stripped == text) return '';
    return stripped;
  }

  String _preUnescapeJson(String content) {
    final sb = StringBuffer();
    var i = 0;
    while (i < content.length) {
      if (content[i] == '\\' && i + 1 < content.length) {
        final next = content[i + 1];
        switch (next) {
          case '"':
            sb.write('"');
          case '\\':
            sb.write('\\');
          case 'n':
            sb.write('\n');
          case 'r':
            sb.write('\r');
          case 't':
            sb.write('\t');
          default:
            sb.write('\\');
            sb.write(next);
        }
        i += 2;
      } else {
        sb.write(content[i]);
        i++;
      }
    }
    return sb.toString();
  }

  Map<String, dynamic> _extractCustomTokenArg(
    String content,
    String toolName,
    String paramName,
  ) {
    final fullPrefix = '<|tool_call>call:$toolName{$paramName:';
    final jsonPrefix = '{$paramName:';
    final prefixToTry = content.contains(fullPrefix) ? fullPrefix : jsonPrefix;
    final start = content.indexOf(prefixToTry);
    if (start == -1) return {};

    var i = start + prefixToTry.length;

    const quotes = ['<|\\"|>', '<|"|>'];
    String? openedWith;
    for (final q in quotes) {
      if (content.startsWith(q, i)) {
        openedWith = q;
        i += q.length;
        break;
      }
    }
    if (openedWith == null) return {};

    final valueStart = i;
    while (i < content.length) {
      for (final q in quotes) {
        if (content.startsWith(q, i)) {
          final afterQ = i + q.length;
          if (afterQ < content.length && content[afterQ] == '}') {
            return {paramName: content.substring(valueStart, i)};
          }
          break;
        }
      }
      i++;
    }
    return {};
  }

  Map<String, dynamic> _extractJsonStringArg(
    String content,
    String toolName,
    String paramName,
  ) {
    final quotedKey = '"$paramName"';
    final unquotedKey = paramName;
    int keyPos = content.indexOf(quotedKey);
    if (keyPos == -1) keyPos = content.indexOf(unquotedKey);
    if (keyPos == -1) return {};

    var i =
        keyPos +
        (content.contains(quotedKey) ? quotedKey.length : unquotedKey.length);
    while (i < content.length && content[i] != ':') i++;
    i++;
    while (i < content.length && (content[i] == ' ' || content[i] == '\t')) i++;
    if (i >= content.length || content[i] != '"') return {};
    i++;

    final value = StringBuffer();
    while (i < content.length) {
      final ch = content[i];
      if (ch == '\\' && i + 1 < content.length) {
        final next = content[i + 1];
        switch (next) {
          case 'n':
            value.write('\n');
          case 'r':
            value.write('\r');
          case 't':
            value.write('\t');
          case '"':
            value.write('"');
          case '\\':
            value.write('\\');
          default:
            value.write(next);
        }
        i += 2;
        continue;
      }
      if (ch == '"') break;
      value.write(ch);
      i++;
    }

    final extracted = value.toString();
    return extracted.isEmpty ? {} : {paramName: extracted};
  }

  void _showSystemPromptDialog() {
    final tmp = TextEditingController(text: _systemPromptCtrl.text);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('System prompt'),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: tmp,
            maxLines: 8,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              _systemPromptCtrl.text = tmp.text;
              if (_engine != null) {
                setState(() {
                  _chatSession = ChatSession(
                    _engine!,
                    systemPrompt: _systemPromptCtrl.text,
                  );
                  _chatLog.clear();
                });
                _appendChatLog('sys', 'System prompt updated. Chat reset.');
              }
              Navigator.pop(ctx);
              _inputFocus.requestFocus();
            },
            child: const Text('Apply & reset chat'),
          ),
        ],
      ),
    );
  }

  Future<void> _updateContextTokens() async {
    if (_engine == null || _chatSession == null) return;
    final history = _chatSession!.history;
    if (history.isEmpty) return;
    final allText = history
        .map((msg) {
          return msg.parts
              .map((p) {
                if (p is LlamaTextContent) return p.text;
                if (p is LlamaToolCallContent) return p.arguments.toString();
                if (p is LlamaToolResultContent)
                  return p.result?.toString() ?? '';
                return '';
              })
              .join(' ');
        })
        .join(' ');
    try {
      final tokens = await _engine!.tokenize(allText, addSpecial: false);
      setState(() => _contextTokens = tokens.length);
      // ignore: avoid_print
      print('[app] context tokens: $_contextTokens');
    } catch (_) {}
  }

  void _appendChatLog(String kind, String text) {
    setState(() => _chatLog.add((kind: kind, text: text)));
    _scrollToBottom();
  }

  void _appendReplLog(String kind, String text) {
    setState(() => _replLog.add((kind: kind, text: text)));
    _scrollReplToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _scrollReplToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_replScrollCtrl.hasClients) {
        _replScrollCtrl.animateTo(
          _replScrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final loaded = _chatSession != null;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.settings),
          tooltip: 'Edit system prompt',
          onPressed: _busy ? null : _showSystemPromptDialog,
        ),
        title: const Text('llama_monty — LLM + Python'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_status, style: const TextStyle(fontSize: 12)),
                if (_contextTokens > 0) ...[
                  const SizedBox(width: 16),
                  Text(
                    '$_contextTokens ctx tokens',
                    style: TextStyle(
                      fontSize: 12,
                      color: _contextTokens > 6000
                          ? Colors.orange
                          : Colors.grey,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (_loadProgress != null)
            LinearProgressIndicator(value: _loadProgress),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Chat panel ─────────────────────────────────────────────
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView.builder(
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.all(12),
                          itemCount: _chatLog.length,
                          itemBuilder: (ctx, i) =>
                              _LogEntry(entry: _chatLog[i], cs: cs),
                        ),
                      ),
                      const Divider(height: 1),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: loaded ? _chatPanel() : _loadPanel(),
                        ),
                      ),
                    ],
                  ),
                ),
                // ── REPL / Files tabs ──────────────────────────────────────
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  flex: 1,
                  child: DefaultTabController(
                    length: 2,
                    child: Column(
                      children: [
                        Container(
                          color: cs.surfaceContainerHigh,
                          child: TabBar(
                            tabs: const [
                              Tab(
                                height: 32,
                                icon: Icon(Icons.terminal, size: 14),
                                iconMargin: EdgeInsets.zero,
                              ),
                              Tab(
                                height: 32,
                                icon: Icon(Icons.folder, size: 14),
                                iconMargin: EdgeInsets.zero,
                              ),
                            ],
                            labelColor: cs.primary,
                            unselectedLabelColor: cs.onSurfaceVariant,
                            indicatorColor: cs.primary,
                            indicatorWeight: 2,
                            onTap: (i) {
                              // Refresh files when the user opens that tab.
                              if (i == 1) unawaited(_refreshFiles());
                            },
                          ),
                        ),
                        Expanded(
                          child: TabBarView(
                            physics: const NeverScrollableScrollPhysics(),
                            children: [_replPanel(cs), _filesPanel(cs)],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _loadPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!kIsWeb)
          TextField(
            controller: _modelPathCtrl,
            decoration: const InputDecoration(
              labelText: 'Model path',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        if (!kIsWeb) const SizedBox(height: 8),
        ElevatedButton.icon(
          onPressed: _busy ? null : _loadModel,
          icon: const Icon(Icons.download),
          label: Text(
            kIsWeb
                ? 'Load Gemma-4-E2B from HuggingFace (~1.5 GB)'
                : 'Load model',
          ),
        ),
      ],
    );
  }

  Widget _chatPanel() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _inputCtrl,
            focusNode: _inputFocus,
            enabled: !_busy,
            decoration: const InputDecoration(
              hintText: 'Ask something…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _send(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _busy ? null : _send,
          child: const Text('Send'),
        ),
        const SizedBox(width: 4),
        DropdownButton<int>(
          value: _selectedExperiment,
          isDense: true,
          underline: const SizedBox(),
          items: List.generate(
            _experiments.length,
            (i) => DropdownMenuItem(
              value: i,
              child: Text(
                _experiments[i].name,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
          onChanged: _busy
              ? null
              : (v) => setState(() => _selectedExperiment = v!),
        ),
        const SizedBox(width: 4),
        OutlinedButton(
          onPressed: _busy ? null : _runExperiment,
          child: const Text('Run'),
        ),
        const SizedBox(width: 4),
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _chatLog.clear();
                  _contextTokens = 0;
                  if (_engine != null) {
                    _chatSession = ChatSession(
                      _engine!,
                      systemPrompt: _systemPromptCtrl.text,
                    );
                  }
                }),
          child: const Text('Clear'),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Files panel — visualises the in-memory filesystem the LLM operates on.
  // -------------------------------------------------------------------------

  /// Walks well-known roots (`/tmp/fixtures`, `/tmp/llama_monty*`) via Monty
  /// pathlib and updates [_filesEntries]. Best-effort: silently no-ops if
  /// the runtime isn't ready yet.
  Future<void> _refreshFiles() async {
    final agent = _agentSession;
    if (agent == null) return;
    setState(() => _filesBusy = true);
    const script = '''
import json
from pathlib import Path

out = []

def _safe_size(p):
    try:
        return len(p.read_text())
    except Exception:
        return -1

def walk(root):
    p = Path(root)
    if not p.exists():
        return
    if p.is_file():
        out.append({'path': str(p), 'is_file': True, 'size': _safe_size(p)})
        return
    out.append({'path': str(p), 'is_file': False, 'size': 0})
    for entry in sorted(p.iterdir(), key=lambda q: q.name):
        if entry.is_file():
            out.append({'path': str(entry), 'is_file': True, 'size': _safe_size(entry)})
        else:
            walk(str(entry))

for root in ['/tmp/fixtures', '/tmp/llama_monty', '/tmp/llama_monty_files']:
    walk(root)

print(json.dumps(out))
''';
    try {
      final r = await agent.execute(script).result;
      final raw = (r.printOutput ?? '').trim();
      if (raw.isEmpty || r.error != null) {
        setState(() {
          _filesEntries = const [];
          _filesBusy = false;
        });
        return;
      }
      final list = (jsonDecode(raw) as List).cast<dynamic>();
      final entries = list.map((m) {
        final mm = m as Map<String, dynamic>;
        return _FsEntry(
          path: mm['path'] as String,
          isFile: mm['is_file'] as bool,
          size: (mm['size'] as num).toInt(),
        );
      }).toList();
      setState(() {
        _filesEntries = entries;
        _filesBusy = false;
      });
    } catch (_) {
      setState(() => _filesBusy = false);
    }
  }

  /// Writes [content] to `/tmp/fixtures/<filename>` via Monty's pathlib.
  /// Used by both the file-picker upload and the drop-target. Refreshes
  /// the panel after the write so the new file shows up immediately.
  Future<bool> _addFileBytes({
    required String filename,
    required String content,
  }) async {
    final agent = _agentSession;
    if (agent == null) return false;
    final safeName = filename
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final target = '/tmp/fixtures/${safeName.isEmpty ? "file.txt" : safeName}';
    final escaped = jsonEncode(content);
    final r = await agent.execute('''
from pathlib import Path
Path('/tmp/fixtures').mkdir(parents=True, exist_ok=True)
Path(${jsonEncode(target)}).write_text($escaped)
print('wrote', ${jsonEncode(target)}, len(${jsonEncode(content)}), 'bytes')
''').result;
    if (r.error != null) {
      _appendChatLog('error', 'Add file failed: ${r.error!.message}');
      return false;
    }
    _appendChatLog('sys', (r.printOutput ?? '').trim());
    await _refreshFiles();
    // Auto-open the file we just added.
    await _viewFile(target);
    return true;
  }

  /// Opens the OS file picker, reads each selected file as text, and
  /// writes them into `/tmp/fixtures/`. Binary files are silently skipped
  /// (they'd come through as non-UTF8 strings and Monty's text writer
  /// would reject them).
  Future<void> _pickAndAddFiles() async {
    if (_filesBusy) return;
    setState(() => _filesBusy = true);
    try {
      final files = await openFiles();
      if (files.isEmpty) return;
      var added = 0;
      for (final f in files) {
        try {
          // Read as bytes then decode as UTF-8 — file_selector's
          // .readAsString() doesn't work on web for some types.
          final bytes = await f.readAsBytes();
          final text = utf8.decode(bytes, allowMalformed: false);
          final ok = await _addFileBytes(filename: f.name, content: text);
          if (ok) added++;
        } catch (_) {
          _appendChatLog('error', 'Skipped non-text file: ${f.name}');
        }
      }
      if (added > 0) {
        _appendChatLog('sys', 'Added $added file(s) to /tmp/fixtures/');
      }
    } finally {
      setState(() => _filesBusy = false);
    }
  }

  /// Reads [path] via Monty and stores the result so the panel can render
  /// it inline. Caller is responsible for the active-tab UX.
  Future<void> _viewFile(String path) async {
    final agent = _agentSession;
    if (agent == null) return;
    final escaped = jsonEncode(path);
    final r = await agent
        .execute('from pathlib import Path\nprint(Path($escaped).read_text())')
        .result;
    setState(() {
      _filesViewPath = path;
      _filesViewContent = r.error != null
          ? '(error: ${r.error!.message})'
          : (r.printOutput ?? '').trimRight();
    });
  }

  Widget _filesPanel(ColorScheme cs) {
    final ready = _agentSession != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: cs.surfaceContainerHigh,
          child: Row(
            children: [
              const Icon(Icons.folder, size: 14),
              const SizedBox(width: 6),
              const Text(
                'Files',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 6),
              Text(
                '(${_filesEntries.where((e) => e.isFile).length} files)',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              const Spacer(),
              if (_filesBusy)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: ready && !_filesBusy ? _pickAndAddFiles : null,
                icon: const Icon(Icons.upload_file, size: 14),
                label: const Text('Add', style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(50, 24),
                ),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: ready && !_filesBusy ? _refreshFiles : null,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(50, 24),
                ),
                child: const Text('Refresh', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        Expanded(
          child: _filesEntries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      ready
                          ? 'No files yet. Click Refresh, or ask the LLM to write one.'
                          : 'Load model to enable.',
                      style: TextStyle(
                        color: cs.onSurface.withAlpha(120),
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _filesEntries.length,
                  itemBuilder: (ctx, i) {
                    final e = _filesEntries[i];
                    final selected = e.path == _filesViewPath;
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      selected: selected,
                      leading: Icon(
                        e.isFile ? Icons.description : Icons.folder,
                        size: 16,
                        color: e.isFile ? cs.primary : cs.tertiary,
                      ),
                      title: Text(
                        e.path,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: e.isFile
                          ? Text(
                              e.size < 0
                                  ? '(binary or unreadable)'
                                  : '${e.size} bytes',
                              style: TextStyle(
                                fontSize: 10,
                                color: cs.onSurfaceVariant,
                              ),
                            )
                          : null,
                      onTap: e.isFile && !_filesBusy
                          ? () => _viewFile(e.path)
                          : null,
                    );
                  },
                ),
        ),
        if (_filesViewPath != null)
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              border: Border(top: BorderSide(color: cs.outlineVariant)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _filesViewPath!,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 14),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                        onPressed: () => setState(() {
                          _filesViewPath = null;
                          _filesViewContent = null;
                        }),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      _filesViewContent ?? '',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _replPanel(ColorScheme cs) {
    final loaded = _replRuntime != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: cs.surfaceContainerHigh,
          child: Row(
            children: [
              const Icon(Icons.terminal, size: 14),
              const SizedBox(width: 6),
              const Text(
                'Python REPL',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (_replBusy)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _replLog.clear()),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(40, 24),
                ),
                child: const Text('Clear', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        // Output
        Expanded(
          child: !loaded
              ? Center(
                  child: Text(
                    'Load model to enable REPL',
                    style: TextStyle(color: cs.onSurface.withAlpha(100)),
                  ),
                )
              : _replLog.isEmpty
              ? Center(
                  child: Text(
                    'Run some Python…',
                    style: TextStyle(color: cs.onSurface.withAlpha(60)),
                  ),
                )
              : ListView.builder(
                  controller: _replScrollCtrl,
                  padding: const EdgeInsets.all(8),
                  itemCount: _replLog.length,
                  itemBuilder: (ctx, i) =>
                      _LogEntry(entry: _replLog[i], cs: cs),
                ),
        ),
        const Divider(height: 1),
        // Input
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _replInputCtrl,
                  enabled: loaded && !_replBusy,
                  maxLines: 4,
                  minLines: 2,
                  decoration: const InputDecoration(
                    hintText:
                        'Python code…  (llm_complete / llm_chat available)',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.all(8),
                  ),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: (loaded && !_replBusy) ? _runRepl : null,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        minimumSize: const Size(0, 32),
                      ),
                      child: const Text('Run', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Files panel data
// ---------------------------------------------------------------------------

class _FsEntry {
  const _FsEntry({
    required this.path,
    required this.isFile,
    required this.size,
  });
  final String path;
  final bool isFile;
  final int size;
}

// ---------------------------------------------------------------------------
// Log entry widget
// ---------------------------------------------------------------------------

class _LogEntry extends StatelessWidget {
  const _LogEntry({required this.entry, required this.cs});
  final ({String kind, String text}) entry;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    final (label, color, bg) = switch (entry.kind) {
      'user' => ('YOU', cs.primary, cs.primaryContainer),
      'assistant' => ('LLM', cs.secondary, cs.secondaryContainer),
      'tool' => (
        'CALL',
        Colors.amber.shade300,
        Colors.amber.shade900.withAlpha(80),
      ),
      'code' => ('PY ', cs.tertiary, cs.tertiaryContainer),
      'output' => ('OUT', cs.tertiary, cs.tertiaryContainer.withAlpha(180)),
      'error' => ('ERR', cs.error, cs.errorContainer),
      _ => ('SYS', cs.outline, cs.surfaceContainerHigh),
    };

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            padding: const EdgeInsets.symmetric(vertical: 8),
            alignment: Alignment.topCenter,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: color,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: SelectableText(
                entry.text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
