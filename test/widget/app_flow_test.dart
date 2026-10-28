import 'dart:async';
import 'dart:convert';

import 'package:antigravity_mobile/main.dart';
import 'package:antigravity_mobile/models/conversation.dart';
import 'package:antigravity_mobile/models/server_profile.dart';
import 'package:antigravity_mobile/services/notifier.dart';
import 'package:antigravity_mobile/services/push_service.dart';
import 'package:antigravity_mobile/services/remote_host.dart';
import 'package:antigravity_mobile/services/ssh_host.dart';
import 'package:antigravity_mobile/services/storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../support/fake_host.dart';

Future<void> settle(WidgetTester tester, [int frames = 20]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> tapSave(WidgetTester tester) async {
  await tester.scrollUntilVisible(find.text('Save and connect'), 300,
      scrollable: find.byType(Scrollable).first);
  await tester.tap(find.text('Save and connect'));
}

void main() {
  late FakeHost host;
  late StorageService storage;
  String? lastFingerprint;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    storage = StorageService(secrets: MemorySecretStore());
    host = FakeHost();
  });

  Future<RemoteHost> connector(ServerProfile p, ServerSecrets s, HostKeyVerifier verify) async {
    lastFingerprint = 'SHA256:abc123';
    final ok = await verify('ssh-ed25519', lastFingerprint!);
    if (!ok) throw SshConnectException('Host key was rejected.');
    return host;
  }

  Future<void> addServerAndConnect(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(AntigravityMobileApp(storage: storage, connector: connector));
    await settle(tester);
    expect(find.text('Connect your first VPS'), findsOneWidget);

    await tester.tap(find.text('Add server'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Host'), '203.0.113.10');
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'dev');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'secret');
    await tapSave(tester);
    await settle(tester);

    // First connection asks to trust the host key.
    expect(find.text('Trust this server?'), findsOneWidget);
    expect(find.text('SHA256:abc123'), findsOneWidget);
    await tester.tap(find.text('Trust'));
    await settle(tester, 30);
  }

  testWidgets('add a server, pick a workspace, chat, review changes', (tester) async {
    await addServerAndConnect(tester);

    // agy is installed and signed in, so setup is skipped.
    expect(find.text('Open a workspace'), findsOneWidget);
    expect(find.text('project'), findsOneWidget);
    expect(find.text('.cache'), findsNothing, reason: 'hidden folders are hidden by default');
    await tester.tap(find.text('project'));
    await settle(tester);
    await tester.tap(find.text('Open project'));
    await settle(tester, 30);

    expect(find.text('What should we build in project?'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'What is this project?');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settle(tester, 40);

    expect(find.text('What is this project?'), findsOneWidget);
    expect(find.textContaining('Sure! Looking at the project.'), findsOneWidget);
    expect(find.textContaining('run command'), findsOneWidget);
    expect(find.textContaining('Flutter'), findsWidgets);

    // The prompt went out via the detached-run script with agy's flags.
    final start = host.commands.firstWhere((c) => c.contains('started='));
    expect(start, contains('--output-format stream-json'));
    expect(start, contains('accept-edits'));

    // Follow-up continues the same agy conversation.
    await tester.enterText(find.byType(TextField).last, 'And the tests?');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settle(tester, 40);
    final second = host.commands.lastWhere((c) => c.contains('started='));
    expect(second, contains('--conversation'));
    expect(second, contains('conv-1'));

    // Changes tab shows git status.
    await tester.tap(find.text('Changes'));
    await settle(tester, 20);
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('notes.md'), findsOneWidget);
    await tester.tap(find.text('main.dart'));
    await settle(tester, 20);
    expect(find.text('+new'), findsOneWidget);
    await tester.pageBack();
    await settle(tester);

    // Files tab lists the workspace and opens a file.
    await tester.tap(find.text('Files'));
    await settle(tester, 20);
    expect(find.text('pubspec.yaml'), findsOneWidget);

    // Back from the workspace returns to the picker, still connected.
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('Open a workspace'), findsOneWidget);
    expect(host.isClosed, isFalse);
  });

  testWidgets('setup installs agy and offers sign-in when signed out', (tester) async {
    host = FakeHost(agyInstalled: false, signedIn: false);
    await addServerAndConnect(tester);

    expect(find.text('Install the Antigravity CLI'), findsOneWidget);
    await tester.tap(find.text('Install'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester, 10);
    }

    expect(find.text('Antigravity CLI installed'), findsOneWidget);
    expect(find.text('Sign in to Antigravity'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('API key'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Continue anyway'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Continue anyway'));
    await settle(tester);
    expect(find.text('Open a workspace'), findsOneWidget);
  });

  testWidgets('a reply that was streaming when the app closed resumes from its offset', (tester) async {
    final profile = ServerProfile(id: 'p1', name: 'VPS', host: 'h', username: 'dev', recentWorkspaces: ['/home/dev/project']);
    await storage.saveProfiles([profile]);
    await storage.saveSecrets('p1', const ServerSecrets(password: 'x'));
    await storage.trustHostKey('h:22', 'SHA256:abc123');
    await storage.saveConversation(Conversation(
      id: 'c1',
      serverId: 'p1',
      workspace: '/home/dev/project',
      title: 'Earlier',
      createdAt: DateTime(2026),
      messages: [
        ChatMessage(id: 'u', role: MessageRole.user, createdAt: DateTime(2026),
            parts: [MessagePart(kind: PartKind.text, text: 'Refactor it')]),
        ChatMessage(id: 'a', role: MessageRole.agent, createdAt: DateTime(2026),
            status: MessageStatus.streaming, runId: 'run-9', runOffset: 120,
            parts: [MessagePart(kind: PartKind.text, text: 'Starting the refactor.')]),
      ],
    ));
    host.agentOutput = (_) => [
          jsonEncode({'type': 'text_delta', 'delta': 'Refactor finished.'}),
          jsonEncode({'type': 'result', 'status': 'SUCCESS', 'conversation_id': 'conv-9'}),
        ];

    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AntigravityMobileApp(storage: storage, connector: connector));
    await settle(tester);
    await tester.tap(find.text('VPS'));
    await settle(tester, 30);
    await tester.tap(find.text('project'));
    await settle(tester, 40);

    final follow = host.commands.firstWhere((c) => c.contains('tail -c'));
    expect(follow, contains('run-9'));
    expect(follow, contains('tail -c +121'));
    expect(find.textContaining('Starting the refactor.'), findsOneWidget);
    expect(find.textContaining('Refactor finished.'), findsOneWidget);
    final saved = await storage.loadConversation('c1');
    expect(saved!.messages.last.status, MessageStatus.done);
    expect(saved.agyConversationId, 'conv-9');
  });

  testWidgets('notifies when the agent finishes while the app is in the background', (tester) async {
    final notifier = SilentNotifier();
    final profile = ServerProfile(id: 'p1', name: 'VPS', host: 'h', username: 'dev', recentWorkspaces: ['/home/dev/project']);
    await storage.saveProfiles([profile]);
    await storage.saveSecrets('p1', const ServerSecrets(password: 'x'));
    await storage.trustHostKey('h:22', 'SHA256:abc123');

    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AntigravityMobileApp(storage: storage, connector: connector, notifier: notifier));
    await settle(tester);
    await tester.tap(find.text('VPS'));
    await settle(tester, 30);
    await tester.tap(find.text('project'));
    await settle(tester, 30);

    await tester.enterText(find.byType(TextField).last, 'Fix the build');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(notifier.permissionRequests, 1);

    // The user switches away while the agent is working.
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    expect(notifier.keptAlive, isTrue);
    await settle(tester, 40);

    expect(notifier.shown, hasLength(1));
    final (title, body, link) = notifier.shown.single;
    expect(link, startsWith('antigravity://open?server=p1&conversation='));
    expect(title, 'Agent finished in project');
    expect(body, contains('Flutter app'));
    expect(notifier.keptAlive, isFalse);

    // Tapping the notification opens that conversation.
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.tap(find.byIcon(Icons.add_comment_outlined));
    await settle(tester);
    expect(find.text('Fix the build'), findsNothing);
    notifier.tap(link);
    await settle(tester);
    expect(find.text('Fix the build'), findsOneWidget);

    // No notification while the app is in the foreground.
    await tester.enterText(find.byType(TextField).last, 'Again');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settle(tester, 40);
    expect(notifier.shown, hasLength(1));
  });

  testWidgets('an antigravity:// link opens the server and conversation', (tester) async {
    final profile = ServerProfile(id: 'p1', name: 'VPS', host: 'h', username: 'dev', recentWorkspaces: ['/home/dev/project']);
    await storage.saveProfiles([profile]);
    await storage.saveSecrets('p1', const ServerSecrets(password: 'x'));
    await storage.trustHostKey('h:22', 'SHA256:abc123');
    for (final (id, title) in [('old', 'Older chat'), ('new', 'Newer chat')]) {
      await storage.saveConversation(Conversation(
        id: id,
        serverId: 'p1',
        workspace: '/home/dev/project',
        title: title,
        createdAt: DateTime(2026),
        updatedAt: id == 'new' ? DateTime(2026, 2) : DateTime(2026, 1),
        messages: [
          ChatMessage(id: 'u$id', role: MessageRole.user, createdAt: DateTime(2026),
              parts: [MessagePart(kind: PartKind.text, text: 'Prompt of $title')]),
        ],
      ));
    }
    final links = StreamController<Uri>();
    addTearDown(links.close);

    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AntigravityMobileApp(storage: storage, connector: connector, deepLinks: links.stream));
    await settle(tester);
    expect(find.text('VPS'), findsOneWidget);

    // Cold: from the server list straight into the older conversation.
    links.add(Uri.parse('antigravity://open?server=p1&conversation=old'));
    await settle(tester, 40);
    expect(find.text('Prompt of Older chat'), findsOneWidget);

    // Warm: the open session switches conversation without reconnecting.
    final connects = host.commands.where((c) => c.contains('echo "os=')).length;
    links.add(Uri.parse('antigravity://open?server=p1&conversation=new'));
    await settle(tester, 20);
    expect(find.text('Prompt of Newer chat'), findsOneWidget);
    expect(host.commands.where((c) => c.contains('echo "os=')).length, connects);

    // Unknown server or junk links are ignored.
    links.add(Uri.parse('antigravity://open?server=nope&conversation=old'));
    links.add(Uri.parse('https://example.com'));
    await settle(tester, 10);
    expect(find.text('Prompt of Newer chat'), findsOneWidget);
  });

  testWidgets('registers for relay pushes and skips duplicate local notifications', (tester) async {
    final notifier = SilentNotifier();
    final push = NoPushService(fakeRegistration: const PushRegistration('https://relay.example.dev', 'k-123'));
    final profile = ServerProfile(id: 'p1', name: 'VPS', host: 'h', username: 'dev', recentWorkspaces: ['/home/dev/project'], ntfyUrl: 'https://ntfy.sh/agm-topic');
    await storage.saveProfiles([profile]);
    await storage.saveSecrets('p1', const ServerSecrets(password: 'x'));
    await storage.trustHostKey('h:22', 'SHA256:abc123');

    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AntigravityMobileApp(storage: storage, connector: connector, notifier: notifier, push: push));
    await settle(tester);
    await tester.tap(find.text('VPS'));
    await settle(tester, 30);

    final register = host.stdinFor.entries.firstWhere((e) => e.key.contains('push.new'));
    expect(register.value, 'https://relay.example.dev\tk-123');

    await tester.tap(find.text('project'));
    await settle(tester, 30);
    await tester.enterText(find.byType(TextField).last, 'Fix the build');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await settle(tester, 40);
    expect(notifier.shown, isEmpty, reason: 'the server pushes through the relay instead');
    final start = host.commands.lastWhere((c) => c.contains('started='));
    expect(start, contains('/send'));
    expect(start, contains('antigravity://open?server=p1'));
    expect(start, isNot(contains('ntfy.sh')), reason: 'no second notification via ntfy');
  });

  testWidgets('rejecting the host key does not connect', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AntigravityMobileApp(storage: storage, connector: connector));
    await settle(tester);
    await tester.tap(find.text('Add server'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Host'), 'h');
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'u');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'p');
    await tapSave(tester);
    await settle(tester);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(find.textContaining("Couldn't connect"), findsOneWidget);
    expect(find.textContaining('Host key was rejected'), findsOneWidget);
  });
}
