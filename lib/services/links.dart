import 'dart:async';

/// "Open this conversation on this server", from a notification tap, an
/// ntfy click or an FCM push.
class OpenRequest {
  const OpenRequest(this.serverId, this.conversationId);
  final String serverId;
  final String conversationId;

  /// `antigravity://open?server=…&conversation=…`
  Uri toUri() => Uri(
        scheme: linkScheme,
        host: 'open',
        queryParameters: {'server': serverId, 'conversation': conversationId},
      );

  static OpenRequest? parse(Object? link) {
    final uri = link is Uri ? link : Uri.tryParse('${link ?? ''}');
    if (uri == null || uri.scheme != linkScheme || uri.host != 'open') return null;
    final server = uri.queryParameters['server'];
    final conversation = uri.queryParameters['conversation'];
    if (server == null || server.isEmpty || conversation == null || conversation.isEmpty) {
      return null;
    }
    return OpenRequest(server, conversation);
  }

  @override
  bool operator ==(Object other) =>
      other is OpenRequest && other.serverId == serverId && other.conversationId == conversationId;

  @override
  int get hashCode => Object.hash(serverId, conversationId);
}

const linkScheme = 'antigravity';

/// Collects [OpenRequest]s from every source. The open session for the
/// request's server gets first refusal through [handler]; otherwise the app
/// router opens that server.
class OpenRequests {
  final _controller = StreamController<OpenRequest>.broadcast();
  OpenRequest? _pending;

  Stream<OpenRequest> get stream => _controller.stream;

  /// Set by the active session screen; returns true if it handled the
  /// request (same server).
  bool Function(OpenRequest request)? handler;

  void add(OpenRequest request) {
    if (handler?.call(request) == true) return;
    if (_controller.hasListener) {
      _controller.add(request);
    } else {
      _pending = request;
    }
  }

  void addLink(Object? link) {
    final r = OpenRequest.parse(link);
    if (r != null) add(r);
  }

  /// A request that arrived before anyone was listening (cold start).
  OpenRequest? takePending() {
    final p = _pending;
    _pending = null;
    return p;
  }
}
