class AnsiParser {
  // A simple regex to strip basic ANSI escape codes.
  // Note: For a true native UI, you would parse these codes and emit 
  // TextSpans with colors, bolding, or custom widgets for loading spinners.
  static final RegExp _ansiRegex = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');

  static String stripAnsiCodes(String input) {
    return input.replaceAll(_ansiRegex, '');
  }
}
