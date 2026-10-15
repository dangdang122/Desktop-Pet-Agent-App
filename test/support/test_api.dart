import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pet_agent/services/api_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

String jwt(Map<String, dynamic> payload) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode(payload)}.signature';
}

String validJwt() => jwt({
  'exp':
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000,
  'sub': 'test-user',
});

class TestSocket extends Fake implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final sent = <dynamic>[];

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  late final TestSocketSink sink = TestSocketSink(sent);

  @override
  Future<void> get ready => Future<void>.value();

  void receive(String type, Map<String, dynamic> payload) {
    incoming.add(jsonEncode({'type': type, 'payload': payload}));
  }
}

class TestSocketSink extends Fake implements WebSocketSink {
  TestSocketSink(this.sent);
  final List<dynamic> sent;
  bool closed = false;

  @override
  void add(dynamic event) => sent.add(event);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
  }
}

class TestApi {
  TestApi({Future<http.Response> Function(http.Request)? handleRequest}) {
    client = MockClient((request) async {
      requests.add(request);
      if (handleRequest != null) return handleRequest(request);
      if (request.url.path == '/api/devices') {
        return http.Response('[]', 200);
      }
      return http.Response('{}', 200);
    });
    api = ApiService.forTesting(
      httpClient: client,
      connectChannel: (_) {
        final socket = TestSocket();
        sockets.add(socket);
        return socket;
      },
    );
  }

  final requests = <http.Request>[];
  final sockets = <TestSocket>[];
  late final MockClient client;
  late final ApiService api;
  TestSocket get socket => sockets.single;

  Future<void> dispose() async {
    api.disconnect();
    for (final socket in sockets) {
      await socket.incoming.close();
    }
    client.close();
  }
}
