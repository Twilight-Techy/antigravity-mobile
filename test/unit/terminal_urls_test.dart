import 'dart:convert';
import 'dart:io';

import 'package:antigravity_mobile/state/terminal_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("finds agy's whole sign-in link on a phone-width terminal", () {
    // Recorded from agy 1.4.9's sign-in screen at 50 columns: the visible
    // link is wrapped across lines; only the OSC 8 hyperlink has all of it.
    final raw = utf8.decode(File('test/fixtures/agy_1_4_9/signin_tui_50cols.raw').readAsBytesSync(),
        allowMalformed: true);
    final urls = TerminalSession.findUrls(raw);
    expect(urls, hasLength(1));
    expect(urls.single, startsWith('https://accounts.google.com/o/oauth2/auth?'));
    expect(urls.single, contains('redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback'));
    expect(urls.single, contains('&state='));
  });

  test('plain links and hyperlinks', () {
    expect(TerminalSession.findUrls('see https://example.com/a. ok'), ['https://example.com/a']);
    expect(
      TerminalSession.findUrls('\x1b]8;;https://example.com/full/path\x07click\x1b]8;;\x07 https://example.com/fu'),
      ['https://example.com/full/path'],
    );
  });
}
