import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../models/agent_options.dart';
import '../models/conversation.dart';
import '../services/agent_stream_parser.dart';
import '../services/agy_service.dart';
import '../services/message_builder.dart';
import '../services/storage_service.dart';
import 'session_state.dart';

/// Drives the chat for the session's current workspace: conversations,
/// sending prompts as headless agy runs, streaming and resuming replies.
class ChatController extends ChangeNotifier {
  ChatController(this.session) {
    _lastGeneration = session.generation;
    session.addListener(_onSessionChanged);
  }

  final SessionState session;
  StorageService get storage => session.storage;

  static const _uuid = Uuid();

  final draft = TextEditingController();

  List<ConversationSummary> _conversations = [];
  List<ConversationSummary> get conversations => _conversations;

  Conversation? _current;
  Conversation? get current => _current;

  String? _loadedWorkspace;

  AgentRun? _run;
  MessageBuilder? _builder;
  final _parser = AgentStreamParser();
  Timer? _notifyTimer;
  Timer? _saveTimer;
  int _lastGeneration = 0;
  bool _disposed = false;

  /// Bumped when an agent run finishes, so other views (e.g. Changes) can
  /// refresh.
  int completedRuns = 0;

  bool get busy => _run != null;

  AgentOptions get options => session.profile.agentOptions;

  Future<void> setOptions(AgentOptions options) async {
    await session.servers.setAgentOptions(session.profile, options);
    _notify();
  }

  ChatMessage? get activeMessage {
    final c = _current;
    if (c == null) return null;
    for (final m in c.messages.reversed) {
      if (m.role == MessageRole.agent && m.isActive) return m;
    }
    return null;
  }

  /// Loads conversations for the session's workspace.
  Future<void> loadForWorkspace() async {
    final ws = session.workspace;
    if (ws == null || ws == _loadedWorkspace) return;
    _loadedWorkspace = ws;
    await _refreshIndex();
    if (_conversations.isNotEmpty) {
      await open(_conversations.first.id);
    } else {
      newConversation();
    }
  }

  Future<void> _refreshIndex() async {
    final all = await storage.loadConversationIndex();
    _conversations = all
        .where((c) =>
            c.serverId == session.profile.id && c.workspace == session.workspace)
        .toList();
    _notify();
  }

  void newConversation() {
    if (busy) return;
    _current = Conversation(
      id: _uuid.v4(),
      serverId: session.profile.id,
      workspace: session.workspace ?? '',
      title: 'New conversation',
      createdAt: DateTime.now(),
    );
    _notify();
  }

  Future<void> open(String id) async {
    if (busy) return;
    final c = await storage.loadConversation(id);
    if (c == null) return;
    _current = c;
    _notify();
    unawaited(resumePending());
  }

  Future<void> delete(String id) async {
    if (busy && _current?.id == id) return;
    await storage.deleteConversation(id);
    if (_current?.id == id) newConversation();
    await _refreshIndex();
  }

  Future<void> rename(String id, String title) async {
    final c = _current?.id == id ? _current : await storage.loadConversation(id);
    if (c == null) return;
    c.title = title.trim().isEmpty ? c.title : title.trim();
    await storage.saveConversation(c);
    await _refreshIndex();
  }

  /// Sends [text] as a prompt. Returns false if it could not be sent.
  Future<bool> send(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty || busy) return false;
    if (prompt == '/clear' || prompt == '/new') {
      newConversation();
      return true;
    }
    final agy = session.agy;
    final convo = _current;
    if (agy == null || convo == null || !session.isConnected) return false;

    final now = DateTime.now();
    convo.messages.add(ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      createdAt: now,
      parts: [MessagePart(kind: PartKind.text, text: prompt)],
    ));
    if (convo.messages.where((m) => m.role == MessageRole.user).length == 1) {
      final oneLine = prompt.replaceAll(RegExp(r'\s+'), ' ');
      convo.title = oneLine.length > 48 ? '${oneLine.substring(0, 48)}…' : oneLine;
    }
    final reply = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.agent,
      createdAt: now,
      status: MessageStatus.pending,
      runId: '${now.millisecondsSinceEpoch}-${_uuid.v4().substring(0, 8)}',
    );
    convo.messages.add(reply);
    convo.updatedAt = now;
    _notify();
    await _save();

    final args = [
      ...options.toArgs(),
      if (convo.agyConversationId != null) ...['--conversation', convo.agyConversationId!],
    ];
    final run = agy.createRun(
      runId: reply.runId!,
      cwd: convo.workspace,
      prompt: prompt,
      agyArgs: args,
    );
    _attach(run, reply);
    unawaited(run.start());
    return true;
  }

  Future<void> cancel() async {
    final run = _run;
    final msg = activeMessage;
    if (run == null) {
      // A reply that was interrupted while disconnected.
      if (msg != null) {
        msg.status = MessageStatus.cancelled;
        _notify();
        await _save();
      }
      return;
    }
    await run.cancel();
  }

  /// Picks up replies that were still running when the connection dropped or
  /// the app was closed.
  Future<void> resumePending() async {
    if (busy || !session.isConnected) return;
    final convo = _current;
    final agy = session.agy;
    if (convo == null || agy == null) return;
    ChatMessage? pending;
    for (final m in convo.messages.reversed) {
      if (m.role == MessageRole.agent &&
          (m.isActive || m.status == MessageStatus.interrupted) &&
          m.runId != null) {
        pending = m;
        break;
      }
    }
    if (pending == null) return;
    final run = agy.createRun(
      runId: pending.runId!,
      cwd: convo.workspace,
      prompt: '',
      agyArgs: const [],
    );
    if (!run.resumable) {
      pending.status = MessageStatus.interrupted;
      _notify();
      return;
    }
    pending.status = MessageStatus.streaming;
    _attach(run, pending, resuming: true);
    unawaited(run.resume(pending.runOffset));
  }

  void _attach(AgentRun run, ChatMessage reply, {bool resuming = false}) {
    _run = run;
    if (resuming) {
      // Rebuild from scratch only if we never received anything.
      _builder = MessageBuilder(reply)..conversationId = _current?.agyConversationId;
    } else {
      _builder = MessageBuilder(reply);
    }
    final builder = _builder!;
    run.events.listen((event) {
      switch (event) {
        case RunLine(:final line, :final offset):
          reply.runOffset = offset;
          reply.addRaw(line);
          if (reply.status == MessageStatus.pending) {
            reply.status = MessageStatus.streaming;
          }
          for (final e in _parser.parseLine(line)) {
            builder.apply(e);
          }
          _scheduleNotify();
          _scheduleSave();
        case RunExit(:final code, :final stderr):
          final success = code == 0;
          builder.finish(success: success);
          if (!success) {
            if (code == 130 || code == 143 || code == 137) {
              reply.status = MessageStatus.cancelled;
            } else {
              reply.status = MessageStatus.error;
              if (!reply.parts.any((p) => p.kind == PartKind.error)) {
                final detail = stderr.trim();
                reply.parts.add(MessagePart(
                  kind: PartKind.error,
                  text: detail.isEmpty ? 'agy exited with code $code.' : detail,
                ));
              }
            }
          } else {
            reply.status = reply.parts.any((p) => p.kind == PartKind.error) &&
                    !reply.parts.any((p) => p.kind == PartKind.text)
                ? MessageStatus.error
                : MessageStatus.done;
          }
          _complete(builder);
        case RunLost(:final reason, :final resumable):
          reply.status = MessageStatus.interrupted;
          if (!resumable) {
            reply.parts.add(MessagePart(kind: PartKind.notice, text: reason));
          }
          _run = null;
          _builder = null;
          _notify();
          unawaited(_save());
      }
    });
  }

  void _complete(MessageBuilder builder) {
    final convo = _current;
    if (convo != null && builder.conversationId != null) {
      convo.agyConversationId = builder.conversationId;
    }
    _run = null;
    _builder = null;
    completedRuns++;
    _notifyTimer?.cancel();
    _notify();
    unawaited(_save());
  }

  void _onSessionChanged() {
    if (session.generation != _lastGeneration) {
      _lastGeneration = session.generation;
      // A new connection: re-attach to replies that were streaming.
      final run = _run;
      if (run != null) {
        run.detach();
      }
      Future.delayed(const Duration(milliseconds: 300), resumePending);
    }
    if (session.workspace != null && session.workspace != _loadedWorkspace) {
      unawaited(loadForWorkspace());
    }
  }

  void _scheduleNotify() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 60), _notify);
  }

  void _scheduleSave() {
    if (_saveTimer?.isActive ?? false) return;
    _saveTimer = Timer(const Duration(seconds: 2), () => unawaited(_save()));
  }

  Future<void> _save() async {
    final c = _current;
    if (c == null || c.messages.isEmpty) return;
    c.updatedAt = DateTime.now();
    await storage.saveConversation(c);
    await _refreshIndex();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_onSessionChanged);
    _notifyTimer?.cancel();
    _saveTimer?.cancel();
    _run?.detach();
    draft.dispose();
    super.dispose();
  }
}
