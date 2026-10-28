// A stand-in for agy, compiled to a native executable for the local script
// tests (test/integration/local_scripts_test.dart), so they also run on
// Windows: `dart compile exe tool/fake_agy.dart -o <dir>/agy[.exe]`.
//
// It answers `-p` like agy 1.4.9 (stream-json with each payload under its
// event name). Next to the executable, `fake_sleep` holds seconds to pause
// mid-reply, and `fake_last_args` receives the arguments as JSON.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final dir = File(Platform.resolvedExecutable).parent.path;
  if (args.isNotEmpty && args.first == '--version') {
    stdout.writeln('1.4.9');
    return;
  }
  if (args.isNotEmpty && args.first == 'models') {
    stdout.writeln('Fetching available models...');
    stdout.writeln('gemini-3-pro\tGemini 3 Pro');
    return;
  }
  String? prompt;
  String? conversation;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-p':
        prompt = args[++i];
      case '--conversation':
        conversation = args[++i];
      case '--output-format' || '--print-timeout' || '--mode' || '--model' || '--effort' || '--agent' || '--add-dir':
        i++;
    }
  }
  if (prompt == null) {
    // Interactive: echo each line until "exit".
    stdout.writeln('interactive fake agy');
    while (true) {
      final line = stdin.readLineSync();
      if (line == null || line.trim() == 'exit') return;
      stdout.writeln('got ${line.trim()}');
    }
  }
  File('$dir${Platform.pathSeparator}fake_last_args').writeAsStringSync(jsonEncode(args));
  final id = conversation ?? 'conv-123';
  void emit(String event, Map<String, Object?> payload) =>
      stdout.writeln(jsonEncode({'event': event, event: payload}));
  void step(int index, String state, String type, [String? delta]) => emit('step_update', {
        'conversation_id': id,
        'step_index': index,
        'state': state,
        'step_type': type,
        if (delta != null) 'text_delta': delta,
      });

  emit('init', {'cwd': Directory.current.path, 'tools': ['run_command'], 'permission_mode': 'request-review'});
  step(0, 'DONE', 'user_input');
  step(1, 'ACTIVE', 'agent_response', 'You said: ');
  await stdout.flush();
  final pause = File('$dir${Platform.pathSeparator}fake_sleep');
  final seconds = pause.existsSync() ? double.tryParse(pause.readAsStringSync().trim()) ?? 0 : 0.3;
  await Future<void>.delayed(Duration(milliseconds: (seconds * 1000).round()));
  step(1, 'DONE', 'agent_response', prompt);
  emit('result', {
    'conversation_id': id,
    'status': 'SUCCESS',
    'response': 'You said: $prompt',
    'num_turns': 1,
    'usage': {'input_tokens': 1200, 'output_tokens': 34, 'total_tokens': 1234},
  });
  await stdout.flush();
}
