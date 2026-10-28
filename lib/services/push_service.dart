import 'dart:async';
import 'dart:convert';
import 'dart:io' show ContentType, HttpClient, Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// A phone registered with the push relay: the VPS posts to
/// `$relayUrl/send` with [key], which can only notify this one device.
class PushRegistration {
  const PushRegistration(this.relayUrl, this.key);
  final String relayUrl;
  final String key;
}

/// Firebase Cloud Messaging on Android, via the app owner's push relay
/// (see `relay/`). Users set nothing up: the app swaps its FCM token for a
/// push key at the relay and stores that key on the VPS.
abstract class PushService {
  bool get available;
  Future<void> init();
  Future<String?> token();
  Stream<String> get tokenRefresh;

  /// `antigravity://` links from tapped pushes.
  Stream<String> get openedLinks;

  /// Registers this phone with the relay; null when push is unavailable.
  Future<PushRegistration?> register();
}

/// Firebase options and the relay URL are supplied at build time:
/// `--dart-define=FIREBASE_API_KEY=… --dart-define=FIREBASE_APP_ID=…
///  --dart-define=FIREBASE_PROJECT_ID=… --dart-define=FIREBASE_SENDER_ID=…
///  --dart-define=PUSH_RELAY_URL=https://….workers.dev`.
/// Without them FCM is simply off.
class FcmPushService implements PushService {
  static const _relayUrl = String.fromEnvironment('PUSH_RELAY_URL');
  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _senderId = String.fromEnvironment('FIREBASE_SENDER_ID');

  /// The Firebase project the app was built for, if any.
  static String? get projectId => _projectId.isEmpty ? null : _projectId;

  static bool get configured =>
      _apiKey.isNotEmpty &&
      _appId.isNotEmpty &&
      _projectId.isNotEmpty &&
      _senderId.isNotEmpty &&
      _relayUrl.isNotEmpty;

  final _opened = StreamController<String>.broadcast();
  bool _ready = false;

  @override
  bool get available => _ready;

  @override
  Future<void> init() async {
    if (_ready || kIsWeb || !Platform.isAndroid || !configured) return;
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: _apiKey,
          appId: _appId,
          messagingSenderId: _senderId,
          projectId: _projectId,
        ),
      );
      FirebaseMessaging.onMessageOpenedApp.listen(_emit);
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) scheduleMicrotask(() => _emit(initial));
      _ready = true;
    } catch (e) {
      debugPrint('FCM unavailable: $e');
    }
  }

  void _emit(RemoteMessage m) {
    final link = m.data['link'];
    if (link is String && link.isNotEmpty) _opened.add(link);
  }

  @override
  Future<String?> token() async {
    if (!_ready) return null;
    try {
      // The classic registration token: the documented HTTP v1 send target.
      // ignore: deprecated_member_use
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('FCM token unavailable: $e');
      return null;
    }
  }

  @override
  Stream<String> get tokenRefresh =>
      // ignore: deprecated_member_use
      _ready ? FirebaseMessaging.instance.onTokenRefresh : const Stream.empty();

  @override
  Stream<String> get openedLinks => _opened.stream;

  @override
  Future<PushRegistration?> register() async {
    final t = await token();
    if (t == null) return null;
    final base = _relayUrl.replaceAll(RegExp(r'/+$'), '');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(Uri.parse('$base/register'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'token': t}));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        debugPrint('Push relay refused registration (${res.statusCode}): $body');
        return null;
      }
      final key = (jsonDecode(body) as Map)['key'];
      return key is String && key.isNotEmpty ? PushRegistration(base, key) : null;
    } catch (e) {
      debugPrint('Push relay unreachable: $e');
      return null;
    } finally {
      client.close();
    }
  }
}

class NoPushService implements PushService {
  NoPushService({this.fakeToken, this.fakeRegistration});

  /// Lets tests exercise registration without Firebase.
  final String? fakeToken;
  final PushRegistration? fakeRegistration;
  final _opened = StreamController<String>.broadcast();

  void open(String link) => _opened.add(link);

  @override
  bool get available => fakeRegistration != null;

  @override
  Future<void> init() async {}

  @override
  Future<String?> token() async => fakeToken;

  @override
  Stream<String> get tokenRefresh => const Stream.empty();

  @override
  Stream<String> get openedLinks => _opened.stream;

  @override
  Future<PushRegistration?> register() async => fakeRegistration;
}
