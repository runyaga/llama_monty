import 'dart:async';

import 'package:dart_monty/dart_monty.dart' show DartMonty;
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const _modelUrl = 'models/SmolLM2-1.7B-Instruct-Q4_K_M.gguf';

const _nativeModelPath =
    '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

const _webSystemPrompt = '''
You are a helpful AI assistant. The host can execute Python code that you write. Whenever a question needs computation, ALWAYS answer by writing a Python program inside a markdown code fence:

```python
# your code here, must call print(...) for any output you want returned
```

Rules:
- ONE python fence per response. No explanation outside the fence is required.
- The host runs the fence and feeds you the printed output. Do not invent output you have not received yet.
- Python state persists across turns — variables defined in one fence are available in the next.

## Filesystem

You have a small in-memory filesystem. Use `pathlib`:

```python
from pathlib import Path
for p in Path('/fixtures').iterdir():
    print(p, p.read_text()[:80])
```

Pre-seeded files at `/fixtures/`:
- `welcome.md` — short intro to this environment.
- `sample.csv` — name,quantity,price (5 rows).
- `notes.txt` — a couple of bullet notes.

You can also write new files anywhere in the in-memory tree.

## Built-in host functions

Inside the fence you can call these:
- `llm_complete(prompt, system_prompt=None) -> str` — stateless LLM call.
- `llm_chat(message, system_prompt=None) -> str` — multi-turn LLM (separate
  history from the outer chat).
- `llm_chat_reset(keep_system_prompt=True)` — wipe llm_chat history.
- `chat_history() -> str` — markdown of the OUTER conversation (this UI).
- `chat_history_messages() -> list[dict]` — same, programmatic.
- `chat_summarize(style='bullets') -> str` — LLM-summarized outer history.
- `chat_reset(keep_system_prompt=True, seed=None)` — wipe the outer chat.
  Pass `seed` (e.g. the result of `chat_summarize()`) to plant context.

When the user asks you to "compress" or "reset" the conversation, write
Python that calls those.

## Monty Python sandbox — restrictions
The Python runs inside Monty, a restricted subset:
- NO class keyword — use dicts
- NO yield/generators — use for-loops and lists
- NO match/case, del, decorators
- NO hasattr/callable/format builtins
- NO collections, functools, itertools, numpy, pandas
- NO chained assignment (i = j = 0)
- NO tuple unpacking in for-loop headers: use indexing
- Supported modules: math, re, json, datetime
''';

const _systemPrompt = '''
You are a helpful AI assistant with access to a Python interpreter via the run_python tool. Use it whenever you need to compute, process data, or run code. Python state persists across calls — variables defined in one call are available in the next.

## Monty Python sandbox — key restrictions

run_python executes inside Monty, a restricted Python subset. Avoid these or your code will fail:

- NO class keyword — use dicts for structured data instead
- NO yield / generators — use for loops and lists
- NO match/case, del, or decorators (@property etc.)
- NO hasattr(), callable(), format() builtins
- NO collections, functools, itertools, numpy, pandas
- NO chained assignment: write i = 0; j = 0 instead of i = j = 0
- NO tuple unpacking in for-loop headers: instead of "for i, j in zip(a, b)" use indexing with a single loop variable

Simple tuple unpacking in assignments is fine: a, b = 1, 2

Supported modules: math, re, json, datetime

## Error handling — retry loop

If run_python returns an error:
1. Read the error message carefully to identify the unsupported feature
2. Rewrite the code to avoid it (e.g. replace tuple-unpacking for-loops with index loops)
3. Call run_python again with the corrected code

Never report output or results you did not actually receive from the tool.
''';

// ---------------------------------------------------------------------------
// Seed fixtures (web only — MemoryFileSystem starts empty)
// ---------------------------------------------------------------------------

const _fixtureWelcome = '''
# llama_monty — welcome

This is a tiny in-memory filesystem mounted at `/fixtures/`. The model can
list, read, and write here just like a real disk. Everything lives in this
browser tab — refresh and it's gone.

Try asking the assistant:
- "List the files under /fixtures and read welcome.md"
- "Compute the average of column2 in /fixtures/sample.csv"
- "Append a TODO to /fixtures/notes.txt"
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

/// Plants three small files in `/fixtures/` via Monty's `Path.*` ops so the
/// LLM has something to read on first launch. Runs the same Python in any
/// runtime; pass each runtime that needs the fixtures (the agent and the
/// REPL share the same MemoryFileSystem instance via [defaultOsHandler]).
Future<void> _seedWebFixtures(MontyRuntime runtime) async {
  final script = StringBuffer()
    ..writeln('from pathlib import Path')
    ..writeln("Path('/fixtures').mkdir(parents=True, exist_ok=True)")
    ..writeln(_writeFile('/fixtures/welcome.md', _fixtureWelcome))
    ..writeln(_writeFile('/fixtures/sample.csv', _fixtureSampleCsv))
    ..writeln(_writeFile('/fixtures/notes.txt', _fixtureNotes));
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
  void warning(String msg,
      {Object? error,
      StackTrace? stackTrace,
      Map<String, Object?>? attributes}) =>
      // ignore: avoid_print
      print('[$_prefix:WARN] $msg${error != null ? ' — $error' : ''}');

  @override
  void error(String msg,
      {Object? error,
      StackTrace? stackTrace,
      Map<String, Object?>? attributes}) =>
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
      TextEditingController(text: kIsWeb ? _webSystemPrompt : _systemPrompt);
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
  MontyRuntime? _agentSession;   // used by run_python tool in chat
  MontyRuntime? _replRuntime;    // used by Python REPL; has LlamaMontyPlugin
  ToolDefinition? _runPythonTool;

  double? _loadProgress;
  String _status = 'idle';
  bool _busy = false;
  int _contextTokens = 0;
  int _selectedExperiment = 0;

  @override
  void initState() {
    super.initState();
    _autoRun();
  }

  static const _experiments = <({String name, String description, List<String> prompts})>[
    (
      name: 'Context Cliff',
      description: 'Many short tasks — finds the token count where model stops calling tools',
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
      description: 'Complex multi-step problems — tests how sophisticated the reasoning gets',
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
      description: 'Fun & surprising — simulations, patterns, recreational math',
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
  ];

  Future<void> _autoRun() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _loadModel();
    await _runExperiment();
  }

  Future<void> _runExperiment() async {
    if (_chatSession == null || _busy) return;
    final exp = _experiments[_selectedExperiment];
    _appendChatLog('sys', '--- ${exp.name}: ${exp.description} ---');
    for (var idx = 0; idx < exp.prompts.length; idx++) {
      _inputCtrl.text = exp.prompts[idx];
      // ignore: avoid_print
      print('[experiment:${exp.name}] prompt ${idx + 1}/${exp.prompts.length}: ${exp.prompts[idx]}');
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
      extensions: [LlamaMontyPlugin(engineRef), chatShellPlugin],
    );

    // REPL runtime — same surface for ad-hoc tinkering.
    final replRuntime = MontyRuntime(
      os: sharedOs,
      logger: const _ConsoleBridgeLogger('repl'),
      extensions: [LlamaMontyPlugin(engineRef), chatShellPlugin],
    );

    // On web the fs is empty by default — seed a few fixtures so the LLM
    // has something to work with out of the box. On native skip seeding;
    // the user has their real disk available. Only seed once because the
    // two runtimes share the same OS handler and therefore the same fs.
    if (kIsWeb) {
      await _seedWebFixtures(agentSession);
    }

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

        final result = await agentSession.execute(code).result;

        if (result.error != null) {
          final err = result.error!.message;
          _appendChatLog('error', err);
          return 'Error: $err';
        }

        final parts = <String>[
          if (result.printOutput case final o? when o.isNotEmpty) o.trim(),
          if (result.value case final v? when v is! MontyNone) v.toString(),
        ];
        final out = parts.join('\n').trim();
        final display = out.isEmpty ? '(no output)' : out;
        _appendChatLog('output', display);
        return display;
      },
    );

    final chatSession = ChatSession(engine, systemPrompt: _systemPromptCtrl.text);

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
      'The LLM can execute Python via run_python — state persists across calls.',
    );

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

    try {
      var parts = <LlamaContentPart>[LlamaTextContent(msg)];
      var toolRetries = 0;
      const maxToolRetries = 3;
      var errorNudgeCount = 0;
      const maxErrorNudges = 2;
      var lastRoundHadError = false;

      while (true) {
        String? finishReason;
        final rawContentBuffer = StringBuffer();

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
        }

        final rawContent = rawContentBuffer.toString();

        final lastMsg = _chatSession!.history.lastOrNull;
        final toolCallParts =
            lastMsg?.parts.whereType<LlamaToolCallContent>().toList() ?? [];

        // ignore: avoid_print
        print('[app] finishReason=$finishReason toolCalls=${toolCallParts.length}');

        if (finishReason == 'tool_calls' && toolCallParts.isNotEmpty) {
          if (toolRetries >= maxToolRetries) {
            _appendChatLog('sys', 'Max tool retries ($maxToolRetries) reached — stopping.');
            break;
          }

          lastRoundHadError = false;
          for (final tc in toolCallParts) {
            String resultStr;
            final effectiveArgs = tc.arguments.isNotEmpty
                ? tc.arguments
                : _extractGemma4SingleStringArg(
                    rawContent,
                    tc.name,
                    'code',
                  );

            if (effectiveArgs.isEmpty) {
              toolRetries++;
              lastRoundHadError = true;
              // ignore: avoid_print
              print('[app] PARSE FAIL rawContent=\n$rawContent\n---');
              resultStr =
                  'Error: tool call for "${tc.name}" was received with no '
                  'arguments. Please call ${tc.name} again and include all '
                  'required parameters (e.g. the "code" string).';
              _appendChatLog('sys', 'tool=${tc.name} args missing — retry $toolRetries/$maxToolRetries');
            } else {
              toolRetries = 0;
              // Show a distinct "tool call" entry so it's easy to spot.
              _appendChatLog('tool', tc.name);
              try {
                resultStr =
                    await _runPythonTool!.invoke(effectiveArgs) as String? ??
                    '(no output)';
              } catch (e) {
                resultStr = 'Error: $e';
                _appendChatLog('error', resultStr);
              }
              if (resultStr.startsWith('Error:')) lastRoundHadError = true;
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
              'LLM skipped retry after error — nudging ($errorNudgeCount/$maxErrorNudges)',
            );
            // ignore: avoid_print
            print('[app] nudging LLM to retry after error ($errorNudgeCount/$maxErrorNudges)');
            parts = [
              LlamaTextContent(
                'You received a Python error from the tool. '
                'Do not answer yet — fix the code and call run_python again.',
              ),
            ];
            continue;
          }

          var text = lastMsg?.parts
                  .whereType<LlamaTextContent>()
                  .map((p) => p.text)
                  .join() ??
              '';
          text = text
              .replaceAll(RegExp(r'<\|channel\>[\s\S]*?<channel\|>'), '')
              .replaceAll('<eos>', '')
              .trim();

          // Web fallback: with grammar-constrained tool calling disabled in
          // the WebGPU bridge, the LLM emits ```python ... ``` markdown
          // instead of a structured tool_call. Extract the code and run it.
          final fenceCode = kIsWeb ? _extractPythonFence(text) : null;
          if (fenceCode != null && fenceCode.trim().isNotEmpty) {
            final prose = _stripPythonFence(text).trim();
            if (prose.isNotEmpty) _appendChatLog('assistant', prose);
            _appendChatLog('tool', 'run_python (from fence)');
            String resultStr;
            try {
              resultStr =
                  await _runPythonTool!.invoke({'code': fenceCode}) as String? ??
                      '(no output)';
            } catch (e) {
              resultStr = 'Error: $e';
              _appendChatLog('error', resultStr);
            }
            final fenceFailed = resultStr.startsWith('Error:');
            // Feed the tool result back so the model can react.
            _chatSession!.addMessage(
              LlamaChatMessage.withContent(
                role: LlamaChatRole.tool,
                content: [
                  LlamaToolResultContent(
                    name: 'run_python',
                    result: resultStr,
                  ),
                ],
              ),
            );
            // On error: nudge the model to fix the code and try again.
            if (fenceFailed && errorNudgeCount < maxErrorNudges) {
              errorNudgeCount++;
              _appendChatLog(
                'sys',
                'Code failed — asking LLM to fix and retry '
                '($errorNudgeCount/$maxErrorNudges)',
              );
              parts = [
                LlamaTextContent(
                  'The Python you wrote produced an error: $resultStr\n'
                  'Write a corrected program in a ```python fence. '
                  'Do not give the answer in prose.',
                ),
              ];
              continue;
            }
            break;
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

  /// Extract Python code from a model response. Tries:
  ///  1. ```python fenced block (markdown)
  ///  2. Raw Python heuristic (text contains print(/def /import / etc.)
  String? _extractPythonFence(String text) {
    final fenced = RegExp(r'```(?:python|py)?\s*\n?([\s\S]*?)```')
        .firstMatch(text);
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
    print('[app] fence.match=none firstChars=${cleaned.substring(0, cleaned.length > 80 ? 80 : cleaned.length)}');
    return null;
  }

  /// Removes the first python fence (and surrounding blank lines) from [text].
  /// Used to display non-code prose as the assistant message when code is
  /// extracted via [_extractPythonFence].
  String _stripPythonFence(String text) {
    final stripped = text.replaceFirst(
      RegExp(r'```(?:python|py)?\s*\n?[\s\S]*?```\s*'),
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

    var i = keyPos + (content.contains(quotedKey) ? quotedKey.length : unquotedKey.length);
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
          case 'n': value.write('\n');
          case 'r': value.write('\r');
          case 't': value.write('\t');
          case '"': value.write('"');
          case '\\': value.write('\\');
          default: value.write(next);
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
    final allText = history.map((msg) {
      return msg.parts.map((p) {
        if (p is LlamaTextContent) return p.text;
        if (p is LlamaToolCallContent) return p.arguments.toString();
        if (p is LlamaToolResultContent) return p.result?.toString() ?? '';
        return '';
      }).join(' ');
    }).join(' ');
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
                // ── REPL panel ─────────────────────────────────────────────
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  flex: 1,
                  child: _replPanel(cs),
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
          onChanged: _busy ? null : (v) => setState(() => _selectedExperiment = v!),
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
                    hintText: 'Python code…  (llm_complete / llm_chat available)',
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
// Log entry widget
// ---------------------------------------------------------------------------

class _LogEntry extends StatelessWidget {
  const _LogEntry({required this.entry, required this.cs});
  final ({String kind, String text}) entry;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    final (label, color, bg) = switch (entry.kind) {
      'user'      => ('YOU', cs.primary, cs.primaryContainer),
      'assistant' => ('LLM', cs.secondary, cs.secondaryContainer),
      'tool'      => ('CALL', Colors.amber.shade300, Colors.amber.shade900.withAlpha(80)),
      'code'      => ('PY ', cs.tertiary, cs.tertiaryContainer),
      'output'    => ('OUT', cs.tertiary, cs.tertiaryContainer.withAlpha(180)),
      'error'     => ('ERR', cs.error, cs.errorContainer),
      _           => ('SYS', cs.outline, cs.surfaceContainerHigh),
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
