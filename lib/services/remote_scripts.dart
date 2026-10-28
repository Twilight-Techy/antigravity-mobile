import 'dart:convert';

/// What the server does when a run ends: post to ntfy (if [ntfyUrl] is set)
/// and ask the push relay to notify every registered device (FCM). [link]
/// opens the conversation in the app. Only the workspace name and outcome are sent,
/// never prompt or reply content.
class RunNotify {
  const RunNotify({required this.workspaceName, required this.link, this.ntfyUrl});
  final String workspaceName;
  final String link;
  final String? ntfyUrl;

  String get doneMessage => 'Agent finished in $workspaceName';
  String get failedMessage => 'Agent stopped with an error in $workspaceName';
}

/// Marker the run-follow script writes to stderr once the agent exits.
const exitMarker = '__AGM_EXIT__';

enum RemoteOs { linux, macos, windows, other }

/// Builds the exact command strings sent over SSH. There is one dialect for
/// POSIX `sh` (Linux, macOS, BSD) and one for PowerShell (Windows OpenSSH).
abstract class RemoteScripts {
  const RemoteScripts();

  bool get isWindows;

  /// Command that prints `key=value` facts about the host; works before we
  /// know which dialect applies because detection runs it per dialect.
  String probe();

  String quote(String s);

  String joinPath(String dir, String name);

  String parentOf(String path);

  bool isRoot(String path);

  /// Streams installer output; exit code reflects success.
  String installAgy();

  String installTmux();

  /// Runs `agy models` non-interactively, used as the "signed in?" check.
  String listModels();

  String readAgySettings();

  /// Stores the text sent on stdin as the Gemini API key in a file only the
  /// user can read, so it never appears in a command line.
  String saveApiKey();

  String clearApiKey();

  /// Adds (or removes) the `relayUrl<TAB>pushKey` line sent on stdin to the
  /// server's list of devices to notify. Push keys stay off command lines.
  String pushRegister();

  String pushUnregister();

  String writeAgySettings(String json);

  /// Lists [path]: first line is the resolved absolute path, then one
  /// `type\tsize\tname` line per entry (`type` is `d`, `f` or `l`).
  String listDir(String path);

  /// Prints `size` on the first line, then the base64 of up to [maxBytes].
  String readFile(String path, int maxBytes);

  String makeDir(String path);

  /// Lists `size\tpath` for text files in folders under ~/.gemini named
  /// after agy conversation [conversationId] (where agy keeps artifacts).
  String findArtifacts(String conversationId);

  String git(String cwd, List<String> args);

  /// Diff for an untracked file against an empty file.
  String gitDiffUntracked(String cwd, String path);

  /// Starts a headless agy run. On POSIX it is detached and its output goes
  /// to files under `~/.antigravity-mobile/runs`, so the stream can be
  /// resumed with [followRun] after the connection drops. On Windows the
  /// command itself streams the output.
  String startRun({
    required String runId,
    required String cwd,
    required String prompt,
    required List<String> agyArgs,
    RunNotify? notify,
  });

  /// Follows a detached run from byte [offset]; stdout carries the agent
  /// output and stderr ends with `$exitMarker<code>`. POSIX only.
  String followRun(String runId, int offset);

  String cancelRun(String runId);

  /// Command for the interactive terminal tab.
  String terminal({
    required String cwd,
    required bool runAgy,
    required List<String> agyArgs,
    String? tmuxSession,
  });

  static String b64(String s) => base64.encode(utf8.encode(s));
}

class PosixScripts extends RemoteScripts {
  const PosixScripts();

  static const _runDir = r'$HOME/.antigravity-mobile/runs';

  @override
  bool get isWindows => false;

  @override
  String quote(String s) => "'${s.replaceAll("'", r"'\''")}'";

  /// Wraps a script so it runs under `sh` whatever the login shell is.
  String wrap(String script) => 'sh -c ${quote(script)}';

  String _env() => [
        r'export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"',
        r'[ -f "$HOME/.antigravity-mobile/env" ] && . "$HOME/.antigravity-mobile/env"',
      ].join('\n');

  /// Expands a leading `~` the way a shell would, but keeps the rest quoted.
  String _path(String path) {
    if (path == '~') return r'"$HOME"';
    if (path.startsWith('~/')) return '"\$HOME"/${quote(path.substring(2))}';
    return quote(path);
  }

  static const _b64d = 'b64d() { base64 -d 2>/dev/null || base64 -D; }';

  @override
  String probe() => wrap('''
${_env()}
echo "os=\$(uname -s 2>/dev/null)"
echo "arch=\$(uname -m 2>/dev/null)"
echo "home=\$HOME"
echo "shell=\$SHELL"
echo "agy=\$(command -v agy 2>/dev/null)"
echo "version=\$(agy --version 2>/dev/null | head -n 1)"
echo "tmux=\$(command -v tmux 2>/dev/null)"
echo "git=\$(command -v git 2>/dev/null)"
echo "curl=\$(command -v curl 2>/dev/null)"
echo "wget=\$(command -v wget 2>/dev/null)"
echo "bash=\$(command -v bash 2>/dev/null)"
echo "uid=\$(id -u 2>/dev/null)"
if [ "\$(id -u 2>/dev/null)" = 0 ] || sudo -n true 2>/dev/null; then echo "sudo=1"; else echo "sudo=0"; fi
''');

  @override
  String joinPath(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  @override
  String parentOf(String path) {
    if (path == '/' || path.isEmpty) return '/';
    final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final i = trimmed.lastIndexOf('/');
    return i <= 0 ? '/' : trimmed.substring(0, i);
  }

  @override
  bool isRoot(String path) => path == '/';

  @override
  String installAgy() => wrap('''
${_env()}
set -e
if ! command -v bash >/dev/null 2>&1; then echo "bash is required to run the Antigravity installer." >&2; exit 20; fi
if command -v curl >/dev/null 2>&1; then
  curl -fsSL https://antigravity.google/cli/install.sh | bash
elif command -v wget >/dev/null 2>&1; then
  wget -qO- https://antigravity.google/cli/install.sh | bash
else
  echo "Neither curl nor wget is installed." >&2; exit 21
fi
echo "Installed: \$(agy --version 2>/dev/null | head -n 1)"
''');

  @override
  String installTmux() => wrap('''
if command -v tmux >/dev/null 2>&1; then echo "tmux is already installed."; exit 0; fi
SUDO=""
if [ "\$(id -u)" != 0 ]; then
  if sudo -n true 2>/dev/null; then SUDO="sudo -n"; else echo "Installing tmux needs root or passwordless sudo." >&2; exit 10; fi
fi
if command -v apt-get >/dev/null 2>&1; then
  \$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y tmux || { \$SUDO apt-get update && \$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y tmux; }
elif command -v dnf >/dev/null 2>&1; then \$SUDO dnf install -y tmux
elif command -v yum >/dev/null 2>&1; then \$SUDO yum install -y tmux
elif command -v apk >/dev/null 2>&1; then \$SUDO apk add tmux
elif command -v pacman >/dev/null 2>&1; then \$SUDO pacman -S --noconfirm tmux
elif command -v zypper >/dev/null 2>&1; then \$SUDO zypper --non-interactive install tmux
elif command -v brew >/dev/null 2>&1; then brew install tmux
else echo "No supported package manager found." >&2; exit 11
fi
''');

  @override
  String listModels() => wrap('''
${_env()}
agy models < /dev/null 2>&1
''');

  @override
  String readAgySettings() =>
      wrap(r'cat "$HOME/.gemini/antigravity-cli/settings.json" 2>/dev/null || true');

  @override
  String saveApiKey() => wrap(r'''
umask 077
mkdir -p "$HOME/.antigravity-mobile"
K=$(cat)
printf "export GEMINI_API_KEY='%s'\n" "$K" > "$HOME/.antigravity-mobile/env"
chmod 600 "$HOME/.antigravity-mobile/env"
''');

  @override
  String clearApiKey() => wrap(r'rm -f "$HOME/.antigravity-mobile/env"');

  @override
  String writeAgySettings(String json) => wrap('''
$_b64d
mkdir -p "\$HOME/.gemini/antigravity-cli"
printf %s ${quote(RemoteScripts.b64(json))} | b64d > "\$HOME/.gemini/antigravity-cli/settings.json"
''');

  @override
  String listDir(String path) => wrap('''
cd -- ${_path(path)} 2>/dev/null || { echo "Cannot open directory" >&2; exit 2; }
pwd
if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
  find . -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%f\\n' 2>/dev/null | head -n 3000
else
  for f in .* *; do
    [ "\$f" = . ] || [ "\$f" = .. ] && continue
    [ -e "\$f" ] || [ -L "\$f" ] || continue
    if [ -d "\$f" ]; then t=d; elif [ -L "\$f" ]; then t=l; else t=f; fi
    printf '%s\\t0\\t%s\\n' "\$t" "\$f"
  done
fi
''');

  @override
  String readFile(String path, int maxBytes) => wrap('''
F=${_path(path)}
[ -f "\$F" ] || { echo "Not a regular file" >&2; exit 2; }
wc -c < "\$F" | tr -d ' '
head -c $maxBytes -- "\$F" | base64
''');

  @override
  String makeDir(String path) => wrap('mkdir -p -- ${_path(path)} && cd -- ${_path(path)} && pwd');

  @override
  String findArtifacts(String conversationId) => wrap('''
find "\$HOME/.gemini" -maxdepth 6 -type d -name ${quote(conversationId)} 2>/dev/null | head -n 5 | while IFS= read -r d; do
  find "\$d" -maxdepth 3 -type f \\( -name '*.md' -o -name '*.markdown' -o -name '*.txt' -o -name '*.json' -o -name '*.html' \\) 2>/dev/null
done | head -n 200 | while IFS= read -r f; do
  printf '%s\\t%s\\n' "\$(wc -c < "\$f" | tr -d ' ')" "\$f"
done
''');

  @override
  String git(String cwd, List<String> args) =>
      wrap('git -C ${_path(cwd)} ${args.map(quote).join(' ')}');

  @override
  String gitDiffUntracked(String cwd, String path) => wrap(
      'cd -- ${_path(cwd)} && git diff --no-color --no-index -- /dev/null ${quote(path)}; true');

  @override
  String startRun({
    required String runId,
    required String cwd,
    required String prompt,
    required List<String> agyArgs,
    RunNotify? notify,
  }) {
    final f = '$_runDir/$runId';
    final args = agyArgs.map(quote).join(' ');
    final ping = notify == null ? '' : _afterRun(notify);
    final inner = '''
agy -p "\$(cat "$f.prompt")" --output-format stream-json $args < /dev/null > "$f.out" 2> "$f.err" &
A=\$!
echo \$A > "$f.pid"
wait \$A
C=\$?
echo \$C > "$f.exit"
$ping''';
    return wrap('''
${_env()}
$_b64d
mkdir -p "$_runDir"
find "$_runDir" -type f -mtime +7 -exec rm -f {} + 2>/dev/null
cd -- ${_path(cwd)} || { echo "Workspace not found: $cwd" >&2; exit 3; }
command -v agy >/dev/null 2>&1 || { echo "agy is not installed or not on PATH" >&2; exit 127; }
printf %s ${quote(RemoteScripts.b64(prompt))} | b64d > "$f.prompt"
: > "$f.out"
nohup sh -c ${quote(inner)} > /dev/null 2>&1 < /dev/null &
echo "started=$runId"
''');
  }

  static const _pushFile = r'$HOME/.antigravity-mobile/push';

  String _afterRun(RunNotify n) {
    final out = StringBuffer(
        'if [ "\$C" = 0 ]; then M=${quote(n.doneMessage)}; else M=${quote(n.failedMessage)}; fi\n');
    final url = n.ntfyUrl;
    if (url != null && url.isNotEmpty) {
      final click = quote('Click: ${n.link}');
      out.write('''
if command -v curl >/dev/null 2>&1; then curl -fsS -m 15 -H "Title: Antigravity" -H "Tags: robot" -H $click -d "\$M" ${quote(url)} >/dev/null 2>&1
elif command -v wget >/dev/null 2>&1; then wget -q -T 15 -O /dev/null --header="Title: Antigravity" --header=$click --post-data="\$M" ${quote(url)}
fi
''');
    }
    // Push relay: one `url<TAB>key` line per registered phone. The JSON is
    // built here; only the URL-safe key is substituted on the server.
    String body(String title) => jsonEncode(
        {'key': '__KEY__', 'title': title, 'body': 'Tap to see the reply.', 'link': n.link});
    out.write('''
if [ "\$C" = 0 ]; then J=${quote(body(n.doneMessage))}; else J=${quote(body(n.failedMessage))}; fi
if [ -s "$_pushFile" ] && command -v curl >/dev/null 2>&1; then
  while IFS="\$(printf '\\t')" read -r U K; do
    case "\$K" in ''|*[!A-Za-z0-9._-]*) continue;; esac
    printf '%s' "\$J" | sed "s/__KEY__/\$K/" | curl -fsS -m 15 -H "Content-Type: application/json" --data-binary @- "\$U/send" >/dev/null 2>&1
  done < "$_pushFile"
fi
''');
    return out.toString();
  }

  @override
  String pushRegister() => wrap('''
umask 077
mkdir -p "\$HOME/.antigravity-mobile"
L=\$(cat)
[ -n "\$L" ] || exit 2
touch "$_pushFile"
K=\$(printf '%s' "\$L" | cut -f2)
{ grep -vF "\$K" "$_pushFile"; printf '%s\\n' "\$L"; } | tail -n 10 > "$_pushFile.new"
mv "$_pushFile.new" "$_pushFile"
chmod 600 "$_pushFile"
''');

  @override
  String pushUnregister() => wrap('''
umask 077
L=\$(cat)
[ -f "$_pushFile" ] || exit 0
K=\$(printf '%s' "\$L" | cut -f2)
grep -vF "\$K" "$_pushFile" > "$_pushFile.new"
mv "$_pushFile.new" "$_pushFile"
chmod 600 "$_pushFile"
''');

  @override
  String followRun(String runId, int offset) {
    final f = '$_runDir/$runId';
    return wrap('''
F="$f"
[ -f "\$F.out" ] || { echo "${exitMarker}255" >&2; echo "Run output not found on the server." >&2; exit 0; }
i=0
while [ ! -f "\$F.pid" ] && [ ! -f "\$F.exit" ] && [ \$i -lt 50 ]; do sleep 0.2; i=\$((i+1)); done
tail -c +${offset + 1} -f "\$F.out" &
T=\$!
while [ ! -f "\$F.exit" ]; do
  P=\$(cat "\$F.pid" 2>/dev/null)
  if [ -z "\$P" ] || ! kill -0 "\$P" 2>/dev/null; then
    sleep 1
    [ -f "\$F.exit" ] || echo 255 > "\$F.exit"
  fi
  sleep 0.4
done
sleep 0.6
kill \$T 2>/dev/null
wait \$T 2>/dev/null
tail -n 40 "\$F.err" >&2 2>/dev/null
echo "$exitMarker\$(cat "\$F.exit")" >&2
''');
  }

  @override
  String cancelRun(String runId) {
    final f = '$_runDir/$runId';
    return wrap('''
P=\$(cat "$f.pid" 2>/dev/null)
[ -n "\$P" ] || exit 0
kill -INT "\$P" 2>/dev/null
i=0
while kill -0 "\$P" 2>/dev/null && [ \$i -lt 15 ]; do sleep 0.2; i=\$((i+1)); done
kill -TERM "\$P" 2>/dev/null
i=0
while kill -0 "\$P" 2>/dev/null && [ \$i -lt 10 ]; do sleep 0.2; i=\$((i+1)); done
kill -KILL "\$P" 2>/dev/null
true
''');
  }

  @override
  String terminal({
    required String cwd,
    required bool runAgy,
    required List<String> agyArgs,
    String? tmuxSession,
  }) {
    final program = runAgy
        ? 'agy ${agyArgs.map(quote).join(' ')}'
        : r'exec "${SHELL:-/bin/sh}" -l';
    final inner = '${_env()}\ncd -- ${_path(cwd)} 2>/dev/null\n$program';
    if (tmuxSession == null) {
      return wrap('${_env()}\nexport TERM=xterm-256color\n$inner');
    }
    return wrap('''
${_env()}
export TERM=xterm-256color
if command -v tmux >/dev/null 2>&1; then
  exec tmux new-session -A -s ${quote(tmuxSession)} sh -c ${quote(inner)} \\; set-option status off \\; set-option mouse on
else
  $inner
fi
''');
  }
}

class PowerShellScripts extends RemoteScripts {
  const PowerShellScripts();

  static const _runDir = r'$env:USERPROFILE\.antigravity-mobile\runs';

  @override
  bool get isWindows => true;

  @override
  String quote(String s) => "'${s.replaceAll("'", "''")}'";

  /// PowerShell accepts a base64 UTF-16LE script, which sidesteps quoting
  /// through cmd.exe or whichever shell sshd is configured to use.
  String wrap(String script) {
    final full = '\$ProgressPreference="SilentlyContinue"\n'
        '[Console]::OutputEncoding=[Text.Encoding]::UTF8\n$script';
    final units = <int>[];
    for (final c in full.codeUnits) {
      units
        ..add(c & 0xff)
        ..add(c >> 8);
    }
    return 'powershell -NoLogo -NoProfile -NonInteractive '
        '-ExecutionPolicy Bypass -EncodedCommand ${base64.encode(units)}';
  }

  String _env() => [
        r'$env:Path = [Environment]::GetEnvironmentVariable("Path","User") + ";" + [Environment]::GetEnvironmentVariable("Path","Machine") + ";$env:USERPROFILE\.local\bin"',
        r'$agmKey = "$env:USERPROFILE\.antigravity-mobile\gemini_api_key"',
        r'if (Test-Path -LiteralPath $agmKey) { $env:GEMINI_API_KEY = (Get-Content -Raw -LiteralPath $agmKey).Trim() }',
      ].join('\n');

  String _path(String path) {
    if (path == '~') return r'$env:USERPROFILE';
    if (path.startsWith('~/') || path.startsWith(r'~\')) {
      return '(Join-Path \$env:USERPROFILE ${quote(path.substring(2))})';
    }
    return quote(path);
  }

  /// Windows PowerShell 5.1 passes native arguments without escaping
  /// embedded quotes, so apply the MSVC argv rules ourselves.
  static String msvcEscape(String arg) {
    final sb = StringBuffer();
    var backslashes = 0;
    for (final ch in arg.split('')) {
      if (ch == r'\') {
        backslashes++;
      } else if (ch == '"') {
        sb.write(r'\' * (backslashes * 2 + 1));
        sb.write('"');
        backslashes = 0;
      } else {
        sb.write(r'\' * backslashes);
        sb.write(ch);
        backslashes = 0;
      }
    }
    sb.write(r'\' * (backslashes * 2));
    return sb.toString();
  }

  String _decode(String value) =>
      '[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(${quote(RemoteScripts.b64(value))}))';

  @override
  String probe() => wrap('''
${_env()}
"os=Windows"
"arch=\$env:PROCESSOR_ARCHITECTURE"
"home=\$env:USERPROFILE"
"shell=powershell"
\$a = Get-Command agy -ErrorAction SilentlyContinue
"agy=\$(\$a.Source)"
if (\$a) { "version=\$((& agy --version 2>\$null | Select-Object -First 1))" } else { "version=" }
"tmux="
"git=\$((Get-Command git -ErrorAction SilentlyContinue).Source)"
"curl=yes"
"sudo=0"
''');

  @override
  String joinPath(String dir, String name) =>
      dir.endsWith(r'\') || dir.endsWith('/') ? '$dir$name' : '$dir\\$name';

  @override
  String parentOf(String path) {
    var p = path.replaceAll('/', r'\');
    if (p.endsWith(r'\') && p.length > 3) p = p.substring(0, p.length - 1);
    final i = p.lastIndexOf(r'\');
    if (i <= 2) return p.length >= 2 ? '${p.substring(0, 2)}\\' : p;
    return p.substring(0, i);
  }

  @override
  bool isRoot(String path) => RegExp(r'^[A-Za-z]:\\?$').hasMatch(path);

  @override
  String installAgy() => wrap('''
${_env()}
\$ErrorActionPreference = "Stop"
irm https://antigravity.google/cli/install.ps1 | iex
${_env()}
"Installed: \$((& agy --version 2>\$null | Select-Object -First 1))"
''');

  @override
  String installTmux() => wrap(
      '[Console]::Error.WriteLine("tmux is not available on Windows. Terminal sessions will not persist across disconnects."); exit 12');

  @override
  String listModels() => wrap('''
${_env()}
& agy models 2>&1 | ForEach-Object { "\$_" }
exit \$LASTEXITCODE
''');

  @override
  String saveApiKey() => wrap(r'''
$d = "$env:USERPROFILE\.antigravity-mobile"
New-Item -ItemType Directory -Force -Path $d | Out-Null
$k = [Console]::In.ReadToEnd().Trim()
[IO.File]::WriteAllText("$d\gemini_api_key", $k)
''');

  @override
  String clearApiKey() =>
      wrap(r'Remove-Item -Force -ErrorAction SilentlyContinue "$env:USERPROFILE\.antigravity-mobile\gemini_api_key"');

  @override
  String readAgySettings() => wrap(
      r'$f = "$env:USERPROFILE\.gemini\antigravity-cli\settings.json"; if (Test-Path $f) { Get-Content -Raw -LiteralPath $f }');

  @override
  String writeAgySettings(String json) => wrap('''
\$d = "\$env:USERPROFILE\\.gemini\\antigravity-cli"
New-Item -ItemType Directory -Force -Path \$d | Out-Null
[IO.File]::WriteAllText("\$d\\settings.json", ${_decode(json)})
''');

  @override
  String listDir(String path) => wrap('''
\$p = ${_path(path)}
if (-not (Test-Path -LiteralPath \$p -PathType Container)) { [Console]::Error.WriteLine("Cannot open directory"); exit 2 }
(Resolve-Path -LiteralPath \$p).ProviderPath
Get-ChildItem -Force -LiteralPath \$p | Select-Object -First 3000 | ForEach-Object {
  \$t = if (\$_.PSIsContainer) { "d" } else { "f" }
  \$s = if (\$_.PSIsContainer) { 0 } else { \$_.Length }
  "\$t`t\$s`t\$(\$_.Name)"
}
''');

  @override
  String readFile(String path, int maxBytes) => wrap('''
\$p = ${_path(path)}
if (-not (Test-Path -LiteralPath \$p -PathType Leaf)) { [Console]::Error.WriteLine("Not a regular file"); exit 2 }
\$fs = [IO.File]::OpenRead((Resolve-Path -LiteralPath \$p).ProviderPath)
try {
  \$fs.Length
  \$n = [Math]::Min(\$fs.Length, $maxBytes)
  \$buf = New-Object byte[] \$n
  [void]\$fs.Read(\$buf, 0, \$n)
  [Convert]::ToBase64String(\$buf)
} finally { \$fs.Dispose() }
''');

  @override
  String makeDir(String path) => wrap(
      '(New-Item -ItemType Directory -Force -Path ${_path(path)}).FullName');

  @override
  String findArtifacts(String conversationId) => wrap('''
\$root = "\$env:USERPROFILE\\.gemini"
if (-not (Test-Path -LiteralPath \$root)) { exit 0 }
Get-ChildItem -LiteralPath \$root -Recurse -Depth 6 -Directory -Filter ${quote(conversationId)} -ErrorAction SilentlyContinue |
  Select-Object -First 5 |
  ForEach-Object { Get-ChildItem -LiteralPath \$_.FullName -Recurse -Depth 3 -File -Include *.md,*.markdown,*.txt,*.json,*.html -ErrorAction SilentlyContinue } |
  Select-Object -First 200 |
  ForEach-Object { "\$(\$_.Length)`t\$(\$_.FullName)" }
''');

  @override
  String git(String cwd, List<String> args) => wrap('''
& git -C ${_path(cwd)} ${args.map(quote).join(' ')} 2>&1 | ForEach-Object { "\$_" }
exit \$LASTEXITCODE
''');

  @override
  String gitDiffUntracked(String cwd, String path) => wrap('''
Set-Location -LiteralPath ${_path(cwd)}
& git diff --no-color --no-index -- NUL ${quote(path)} 2>&1 | ForEach-Object { "\$_" }
exit 0
''');

  @override
  String startRun({
    required String runId,
    required String cwd,
    required String prompt,
    required List<String> agyArgs,
    RunNotify? notify,
  }) =>
      wrap('''
${_env()}
\$d = "$_runDir"
New-Item -ItemType Directory -Force -Path \$d | Out-Null
Set-Content -LiteralPath "\$d\\$runId.pid" -Value \$PID
if (-not (Test-Path -LiteralPath ${_path(cwd)})) { [Console]::Error.WriteLine("Workspace not found: $cwd"); [Console]::Error.WriteLine("${exitMarker}3"); exit 3 }
Set-Location -LiteralPath ${_path(cwd)}
if (-not (Get-Command agy -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine("agy is not installed or not on PATH"); [Console]::Error.WriteLine("${exitMarker}127"); exit 127 }
if (Get-Variable PSNativeCommandArgumentPassing -ErrorAction SilentlyContinue) { \$PSNativeCommandArgumentPassing = "Legacy" }
\$prompt = ${_decode(msvcEscape(prompt))}
& agy -p \$prompt --output-format stream-json ${agyArgs.map(quote).join(' ')}
\$code = \$LASTEXITCODE
${notify == null ? '' : _afterRun(notify)}
[Console]::Error.WriteLine("$exitMarker\$code")
exit \$code
''');

  static const _pushFile = r'$env:USERPROFILE\.antigravity-mobile\push';

  String _afterRun(RunNotify n) {
    final out = StringBuffer('''
\$m = if (\$code -eq 0) { ${quote(n.doneMessage)} } else { ${quote(n.failedMessage)} }
''');
    final url = n.ntfyUrl;
    if (url != null && url.isNotEmpty) {
      out.write('''
try { Invoke-RestMethod -Method Post -Uri ${quote(url)} -Headers @{ Title = "Antigravity"; Tags = "robot"; Click = ${quote(n.link)} } -Body \$m -TimeoutSec 15 | Out-Null } catch {}
''');
    }
    out.write('''
\$pf = "$_pushFile"
if (Test-Path -LiteralPath \$pf) {
  foreach (\$line in Get-Content -LiteralPath \$pf) {
    \$parts = \$line -split "`t"
    if (\$parts.Length -lt 2) { continue }
    \$payload = @{ key = \$parts[1]; title = \$m; body = "Tap to see the reply."; link = ${quote(n.link)} } | ConvertTo-Json -Compress
    try { Invoke-RestMethod -Method Post -Uri "\$(\$parts[0])/send" -ContentType "application/json" -Body \$payload -TimeoutSec 15 | Out-Null } catch {}
  }
}
''');
    return out.toString();
  }

  @override
  String pushRegister() => wrap('''
\$l = [Console]::In.ReadToEnd().Trim()
if (-not \$l) { exit 2 }
\$d = "\$env:USERPROFILE\\.antigravity-mobile"
New-Item -ItemType Directory -Force -Path \$d | Out-Null
\$k = (\$l -split "`t")[1]
\$lines = @()
if (Test-Path -LiteralPath "$_pushFile") { \$lines = @(Get-Content -LiteralPath "$_pushFile" | Where-Object { \$_ -and -not \$_.Contains(\$k) }) }
\$lines = @(\$lines + \$l) | Select-Object -Last 10
Set-Content -LiteralPath "$_pushFile" -Value \$lines
''');

  @override
  String pushUnregister() => wrap('''
\$l = [Console]::In.ReadToEnd().Trim()
if (-not (Test-Path -LiteralPath "$_pushFile")) { exit 0 }
\$k = (\$l -split "`t")[1]
Set-Content -LiteralPath "$_pushFile" -Value @(Get-Content -LiteralPath "$_pushFile" | Where-Object { \$_ -and -not \$_.Contains(\$k) })
''');

  @override
  String followRun(String runId, int offset) =>
      throw UnsupportedError('Detached runs are not supported on Windows.');

  @override
  String cancelRun(String runId) => wrap('''
\$f = "$_runDir\\$runId.pid"
if (-not (Test-Path \$f)) { exit 0 }
\$root = [int](Get-Content \$f | Select-Object -First 1)
function Stop-Tree([int]\$id) {
  Get-CimInstance Win32_Process -Filter "ParentProcessId=\$id" | ForEach-Object { Stop-Tree \$_.ProcessId }
  if (\$id -ne \$root) { Stop-Process -Id \$id -Force -ErrorAction SilentlyContinue }
}
Stop-Tree \$root
''');

  @override
  String terminal({
    required String cwd,
    required bool runAgy,
    required List<String> agyArgs,
    String? tmuxSession,
  }) {
    final body = '''
${_env()}
Set-Location -LiteralPath ${_path(cwd)} -ErrorAction SilentlyContinue
${runAgy ? '& agy ${agyArgs.map(quote).join(' ')}' : ''}
''';
    final units = <int>[];
    for (final c in body.codeUnits) {
      units
        ..add(c & 0xff)
        ..add(c >> 8);
    }
    return 'powershell -NoLogo -ExecutionPolicy Bypass ${runAgy ? '' : '-NoExit '}'
        '-EncodedCommand ${base64.encode(units)}';
  }
}

/// Parses the `key=value` output of [RemoteScripts.probe].
Map<String, String> parseProbe(String output) {
  final map = <String, String>{};
  for (final line in const LineSplitter().convert(output)) {
    final i = line.indexOf('=');
    if (i <= 0) continue;
    map[line.substring(0, i).trim()] = line.substring(i + 1).trim();
  }
  return map;
}
