import 'dart:convert';

import 'package:antigravity_mobile/models/conversation.dart';
import 'package:antigravity_mobile/services/storage_service.dart';
import 'package:antigravity_mobile/state/chat_groups.dart';
import 'package:flutter_test/flutter_test.dart';

ConversationSummary chat(String id, String? project, int day) => ConversationSummary(
      id: id,
      serverId: 's',
      project: project,
      title: id,
      updatedAt: DateTime(2026, 1, day),
    );

void main() {
  test('groups chats by project, most recent activity first', () {
    final g = groupChats([
      chat('a1', '/p/a', 1),
      chat('b1', '/p/b', 5),
      chat('a2', '/p/a', 3),
      chat('o1', null, 4),
      chat('o2', null, 6),
    ], ['/p/a', '/p/c', '/p/b']);

    expect(g.projects.map((p) => p.path), ['/p/b', '/p/a', '/p/c']);
    expect(g.projects[1].chats.map((c) => c.id), ['a2', 'a1']);
    expect(g.projects[2].chats, isEmpty, reason: 'recent project without chats');
    expect(g.others.map((c) => c.id), ['o2', 'o1']);
  });

  test('empty when there is nothing', () {
    expect(groupChats(const [], const []).isEmpty, isTrue);
  });

  test('older chats saved with a folder keep it as their project', () {
    final c = Conversation.fromJson(jsonDecode(
        '{"id":"x","serverId":"s","workspace":"/p/a","title":"t","createdAt":"2026-01-01T00:00:00.000"}'));
    expect(c.project, '/p/a');
    final none = Conversation.fromJson(jsonDecode(
        '{"id":"y","serverId":"s","workspace":"","title":"t","createdAt":"2026-01-01T00:00:00.000"}'));
    expect(none.project, isNull);
    expect(jsonDecode(jsonEncode(none.toJson())).containsKey('workspace'), isFalse);
  });
}
