import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pet_agent/main.dart';
import 'package:pet_agent/screens/chat_screen.dart';
import 'package:pet_agent/screens/login_screen.dart';
import 'package:pet_agent/screens/signup_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  late TestApi backend;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = TestApi();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, (call) async {
          if (call.method == 'requestPermissions') {
            return {
              for (final permission in call.arguments as List) permission: 1,
            };
          }
          return 1;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, null);
    await backend.dispose();
  });

  Future<void> openChat(WidgetTester tester) async {
    backend.api.token = validJwt();
    await tester.pumpWidget(AgentApp(api: backend.api));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
  }

  Future<void> emit(
    WidgetTester tester,
    String type,
    Map<String, dynamic> payload,
  ) async {
    backend.socket.receive(type, {'session_id': 's1', ...payload});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  List<String> answers(WidgetTester tester) => tester
      .widgetList<MarkdownBody>(find.byType(MarkdownBody))
      .map((widget) => widget.data)
      .toList();

  testWidgets('missing token opens the white login screen', (tester) async {
    await tester.pumpWidget(AgentApp(api: backend.api));
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(ChatScreen), findsNothing);
    final context = tester.element(find.byType(LoginScreen));
    expect(Theme.of(context).scaffoldBackgroundColor, Colors.white);
    expect(Theme.of(context).colorScheme.primary, Colors.blue);
  });

  testWidgets('expired or malformed token opens login', (tester) async {
    for (final token in [
      jwt({'exp': 0}),
      'invalid',
    ]) {
      backend.api.token = token;
      await tester.pumpWidget(AgentApp(api: backend.api));
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
    }
  });

  testWidgets('signup screen renders after the background change', (
    tester,
  ) async {
    await tester.pumpWidget(AgentApp(api: backend.api));
    await tester.tap(find.text('회원가입'));
    await tester.pumpAndSettle();
    expect(find.byType(SignUpScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saved valid token opens chat and logout works before device selection',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'auth_token': validJwt(),
        'user_email': 'user@example.com',
        'user_id': 'test-user',
      });
      await backend.api.loadCredentials();
      await tester.pumpWidget(AgentApp(api: backend.api));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(Drawer), findsNothing);
      await tester.tap(find.byTooltip('로그아웃'));
      await tester.pump();
      // Allow stream cancellation and mocked HTTP work to finish on the real queue.
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
      expect(
        Navigator.of(tester.element(find.byType(LoginScreen))).canPop(),
        isFalse,
      );
      expect(backend.socket.sink.closed, isTrue);
      expect(backend.api.token, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token'), isNull);
      expect(prefs.getString('user_email'), isNull);
      expect(prefs.getString('user_id'), isNull);
    },
  );

  testWidgets('streamed answer is finalized once and logs close on done', (
    tester,
  ) async {
    await openChat(tester);
    await emit(tester, 'log', {'status': 'node_start', 'node': 'planner'});
    await emit(tester, 'log', {'status': 'node_start', 'node': 'aggregator'});
    await emit(tester, 'token', {'chunk': 'Hello '});
    await emit(tester, 'token', {'chunk': 'world'});
    expect(answers(tester), ['Hello world']);
    await tester.tap(find.text('에이전트 추론 로그'));
    await tester.pump();
    expect(find.text('⚙️ Planner (작업 계획 수립) 동작 중...'), findsOneWidget);
    await emit(tester, 'done', {'final_message': 'Hello world!'});
    expect(answers(tester), ['Hello world!']);
    expect(find.text('⚙️ Planner (작업 계획 수립) 동작 중...'), findsNothing);
    await emit(tester, 'done', {'final_message': 'Hello world!'});
    expect(answers(tester), ['Hello world!']);
    await tester.tap(find.text('에이전트 추론 로그'));
    await tester.pump();
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'intermediate tokens do not suppress final answer without aggregator',
    (tester) async {
      await openChat(tester);
      for (final node in ['planner', 'worker_1', 'router']) {
        await emit(tester, 'log', {'status': 'node_start', 'node': node});
        await emit(tester, 'token', {'chunk': '{"internal":true}'});
      }
      expect(answers(tester), isEmpty);
      await emit(tester, 'done', {'final_message': '최종 답변'});
      expect(answers(tester), ['최종 답변']);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('done-only and streaming-only responses are displayed', (
    tester,
  ) async {
    await openChat(tester);
    await emit(tester, 'done', {'final_message': '첫 답변'});
    expect(answers(tester), ['첫 답변']);
    await emit(tester, 'chat', {'message': '다음 질문'});
    await emit(tester, 'token', {'chunk': '둘째 답변'});
    await emit(tester, 'done', {});
    expect(answers(tester), ['첫 답변', '둘째 답변']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('server auth rejection clears credentials without reconnecting', (
    tester,
  ) async {
    await backend.dispose();
    backend = TestApi(
      handleRequest: (request) async {
        return request.url.path == '/api/devices'
            ? http.Response('{"detail":"expired"}', 401)
            : http.Response('{}', 200);
      },
    );
    backend.api.token = validJwt();
    await tester.pumpWidget(AgentApp(api: backend.api));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(backend.api.token, isNull);
    expect(backend.sockets, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
