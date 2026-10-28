import 'dart:convert';

import 'package:antigravity_mobile/models/agent_options.dart';
import 'package:antigravity_mobile/models/conversation.dart';
import 'package:antigravity_mobile/models/server_profile.dart';
import 'package:antigravity_mobile/services/agy_service.dart';
import 'package:antigravity_mobile/services/remote_scripts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PosixScripts', () {
    const s = PosixScripts();

    test('quotes single quotes safely', () {
      expect(s.quote("it's"), r"'it'\''s'");
    });

    test('path helpers', () {
      expect(s.parentOf('/home/me/project'), '/home/me');
      expect(s.parentOf('/home'), '/');
      expect(s.parentOf('/'), '/');
      expect(s.joinPath('/a', 'b'), '/a/b');
      expect(s.joinPath('/', 'b'), '/b');
      expect(s.isRoot('/'), isTrue);
    });

    test('scripts are wrapped for sh', () {
      expect(s.probe(), startsWith("sh -c '"));
      expect(s.listDir('~/x'), contains(r'"$HOME"/'));
    });
  });

  group('PowerShellScripts', () {
    const s = PowerShellScripts();

    test('encodes commands as UTF-16LE base64', () {
      final cmd = s.readAgySettings();
      expect(cmd, startsWith('powershell '));
      final b64 = cmd.split(' ').last;
      final bytes = base64.decode(b64);
      final units = [for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8)];
      expect(String.fromCharCodes(units), contains('settings.json'));
    });

    test('path helpers', () {
      expect(s.parentOf(r'C:\Users\me\proj'), r'C:\Users\me');
      expect(s.parentOf(r'C:\Users'), r'C:\');
      expect(s.isRoot(r'C:\'), isTrue);
      expect(s.joinPath(r'C:\a', 'b'), r'C:\a\b');
    });

    test('escapes arguments for the MSVC argv rules', () {
      expect(PowerShellScripts.msvcEscape('say "hi"'), r'say \"hi\"');
      expect(PowerShellScripts.msvcEscape(r'a\"b'), r'a\\\"b');
      expect(PowerShellScripts.msvcEscape(r'ends\'), r'ends\\');
      expect(PowerShellScripts.msvcEscape('plain'), 'plain');
    });
  });

  test('parseProbe reads key=value lines', () {
    final info = HostInfo.fromProbe(parseProbe('os=Linux\narch=x86_64\nhome=/root\nagy=/root/.local/bin/agy\nversion=agy 1.2\ntmux=\nsudo=1\n'));
    expect(info.os, RemoteOs.linux);
    expect(info.agyInstalled, isTrue);
    expect(info.hasTmux, isFalse);
    expect(info.canSudo, isTrue);
  });

  test('parseModels handles lists and tables', () {
    expect(AgyService.parseModels('Available models:\n  * gemini-3-pro (default)\n  * gemini-3-flash\n'),
        ['gemini-3-pro', 'gemini-3-flash']);
    expect(
        AgyService.parseModels('┌──────┐\n│ Name │ Context │\n├──────┤\n│ Gemini 3.7 Flash (Low) │ 1M │\n└──────┘'),
        ['Gemini 3.7 Flash (Low)']);
  });

  test('GitStatus.parse', () {
    final s = GitStatus.parse('## main...origin/main [ahead 2, behind 1]\n M lib/a.dart\nA  b.txt\n?? new file.txt\nR  old.dart -> new.dart\n D gone.md\nUU c.txt\n');
    expect(s.branch, 'main');
    expect(s.ahead, 2);
    expect(s.behind, 1);
    expect(s.files.map((f) => f.change).toList(), [
      GitChange.modified,
      GitChange.added,
      GitChange.untracked,
      GitChange.renamed,
      GitChange.deleted,
      GitChange.conflicted,
    ]);
    expect(s.files[3].path, 'new.dart');
    expect(s.files[1].staged, isTrue);
    expect(GitStatus.parse('## No commits yet on main\n').branch, 'main');
  });

  test('AgentOptions maps to agy flags', () {
    expect(const AgentOptions(permissionMode: PermissionMode.ask).toArgs(), isEmpty);
    expect(
        const AgentOptions(model: 'gemini-3-pro', effort: Effort.high, permissionMode: PermissionMode.fullAuto, sandbox: true).toArgs(),
        ['--model', 'gemini-3-pro', '--effort', 'high', '--sandbox', '--dangerously-skip-permissions']);
    expect(const AgentOptions(permissionMode: PermissionMode.plan).toArgs(), ['--mode', 'plan']);
    final round = AgentOptions.fromJson(const AgentOptions(model: 'm', effort: Effort.low).toJson());
    expect(round.model, 'm');
    expect(round.effort, Effort.low);
  });

  test('profiles and conversations round-trip through JSON', () {
    final p = ServerProfile(id: '1', name: 'vps', host: 'h', port: 2200, username: 'u', authMethod: AuthMethod.privateKey)
      ..touchWorkspace('/a')
      ..touchWorkspace('/b')
      ..touchWorkspace('/a');
    final p2 = ServerProfile.fromJson(jsonDecode(jsonEncode(p.toJson())));
    expect(p2.recentWorkspaces, ['/a', '/b']);
    expect(p2.authMethod, AuthMethod.privateKey);
    expect(p2.displayAddress, 'u@h:2200');

    final c = Conversation(id: 'c', serverId: '1', project: '/a', title: 't', createdAt: DateTime(2026), agyConversationId: 'x')
      ..messages.add(ChatMessage(
        id: 'm',
        role: MessageRole.agent,
        createdAt: DateTime(2026),
        status: MessageStatus.interrupted,
        runId: 'r',
        runOffset: 42,
        parts: [MessagePart(kind: PartKind.tool, toolName: 'x', toolStatus: ToolStatus.failed)],
      ));
    final c2 = Conversation.fromJson(jsonDecode(jsonEncode(c.toJson())));
    expect(c2.agyConversationId, 'x');
    expect(c2.messages.single.runOffset, 42);
    expect(c2.messages.single.status, MessageStatus.interrupted);
    expect(c2.messages.single.parts.single.toolStatus, ToolStatus.failed);
  });
}
