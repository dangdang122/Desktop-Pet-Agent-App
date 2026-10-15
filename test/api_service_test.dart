import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestApi backend;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = TestApi();
  });
  tearDown(() => backend.dispose());

  test('JWT expires at its exp boundary, including fractional seconds', () {
    final now = DateTime.utc(2026, 10, 15);
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    backend.api.token = jwt({'exp': seconds + 1});
    expect(backend.api.isTokenExpired(now: now), isFalse);
    backend.api.token = jwt({'exp': seconds});
    expect(backend.api.isTokenExpired(now: now), isTrue);
    backend.api.token = jwt({'exp': seconds - 1});
    expect(backend.api.isTokenExpired(now: now), isTrue);
    backend.api.token = jwt({'exp': seconds + 0.5});
    expect(backend.api.isTokenExpired(now: now), isFalse);
    expect(
      backend.api.isTokenExpired(
        now: now.add(const Duration(milliseconds: 500)),
      ),
      isTrue,
    );
  });

  test('missing, malformed and nonnumeric JWT claims require login', () {
    for (final token in <String?>[
      null, '', 'not-a-jwt', 'header.%%%.signature',
      'header.W10.signature', // A JSON array instead of an object.
      jwt({}), jwt({'exp': '9999999999'}), jwt({'exp': null}),
      jwt({'exp': true}), '${jwt({'exp': 9999999999})}.extra',
    ]) {
      backend.api.token = token;
      expect(backend.api.isTokenExpired(), isTrue, reason: '$token');
    }
  });

  test('valid saved credentials survive an application restart', () async {
    final token = validJwt();
    SharedPreferences.setMockInitialValues({
      'auth_token': token,
      'user_email': 'user@example.com',
      'user_id': 'test-user',
    });
    await backend.api.loadCredentials();
    expect(backend.api.token, token);
    expect(backend.api.email, 'user@example.com');
    expect(backend.api.userId, 'test-user');
    expect(backend.api.isTokenExpired(), isFalse);
    expect(backend.requests, isEmpty);
  });

  test(
    'invalid saved credentials are removed without a remote logout',
    () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': jwt({'exp': 0}),
        'user_email': 'old@example.com',
        'user_id': 'old-user',
        'device_id': 'keep-this-device',
      });
      await backend.api.loadCredentials();
      expect(backend.api.token, isNull);
      expect(backend.api.email, isNull);
      expect(backend.api.userId, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token'), isNull);
      expect(prefs.getString('user_email'), isNull);
      expect(prefs.getString('user_id'), isNull);
      expect(prefs.getString('device_id'), 'keep-this-device');
      expect(backend.requests, isEmpty);
    },
  );

  test('loading empty storage clears stale in-memory credentials', () async {
    backend.api.token = validJwt();
    backend.api.userId = 'stale';
    backend.api.email = 'stale@example.com';
    await backend.api.loadCredentials();
    expect(backend.api.token, isNull);
    expect(backend.api.userId, isEmpty);
    expect(backend.api.email, isNull);
  });

  test(
    'done carries authoritative text instead of an extra chunk or node',
    () async {
      final events = <Map<String, dynamic>>[];
      final subscription = backend.api.messages.listen(events.add);
      addTearDown(subscription.cancel);
      backend.api.connect();
      backend.socket.receive('token', {'session_id': 's1', 'chunk': 'Hello'});
      backend.socket.receive('done', {
        'session_id': 's1',
        'final_message': 'Hello world',
      });
      await Future<void>.delayed(Duration.zero);
      expect(events.map((event) => event['status']), [
        'stream_chunk',
        'stream_end',
      ]);
      expect(events.last['final_message'], 'Hello world');
    },
  );

  test(
    'logout clears storage, session state and the old socket listener',
    () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': validJwt(),
        'user_email': 'user@example.com',
        'user_id': 'test-user',
        'device_id': 'keep-this-device',
      });
      await backend.api.loadCredentials();
      backend.api.connect();
      backend.api.sendChat('A message', sessionId: 'old-session');
      final sent = jsonDecode(backend.socket.sent.last as String);
      final events = <Map<String, dynamic>>[];
      final subscription = backend.api.messages.listen(events.add);
      addTearDown(subscription.cancel);
      await Future.wait([backend.api.logout(), backend.api.logout()]);
      expect(backend.api.token, isNull);
      expect(backend.api.email, isNull);
      expect(backend.api.userId, isEmpty);
      expect(backend.api.sessionId, isNull);
      expect(backend.socket.sink.closed, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token'), isNull);
      expect(prefs.getString('user_email'), isNull);
      expect(prefs.getString('user_id'), isNull);
      expect(prefs.getString('device_id'), 'keep-this-device');
      expect(
        backend.requests.where((r) => r.url.path == '/api/logout'),
        hasLength(1),
      );
      backend.socket.receive('chat', {
        'session_id': 'old-session',
        'message': 'late',
      });
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);

      // A new connection must not suppress message IDs from the old account.
      backend.api.connect();
      backend.sockets.last.receive('chat', {
        'session_id': 'new-session',
        'message_id': sent['payload']['message_id'],
        'message': 'New account message',
      });
      await Future<void>.delayed(Duration.zero);
      expect(events.single['message'], 'New account message');
    },
  );

  test('local agent failure does not prevent local logout', () async {
    await backend.dispose();
    backend = TestApi(
      handleRequest: (_) async => throw http.ClientException('offline'),
    );
    backend.api.token = validJwt();
    await backend.api.logout();
    expect(backend.api.token, isNull);
    expect(backend.api.sessionId, isNull);
  });

  test(
    'login refuses a successful HTTP response without a valid token',
    () async {
      await backend.dispose();
      backend = TestApi(handleRequest: (_) async => http.Response('{}', 200));
      await expectLater(
        backend.api.login(
          email: 'user@example.com',
          password: 'password',
          deviceId: 'device',
          deviceType: 'mobile',
          deviceName: 'Test phone',
        ),
        throwsException,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token'), isNull);
      expect(backend.api.token, isNull);
    },
  );
}
