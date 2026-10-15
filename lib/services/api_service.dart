import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../screens/login_screen.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal()
    : _httpClient = http.Client(),
      _connectChannel = WebSocketChannel.connect;

  @visibleForTesting
  ApiService.forTesting({
    required http.Client httpClient,
    required WebSocketChannel Function(Uri) connectChannel,
  }) : _httpClient = httpClient,
       _connectChannel = connectChannel;

  final http.Client _httpClient;
  final WebSocketChannel Function(Uri) _connectChannel;

  // ==========================================
  // [설정 값] 게이트웨이 및 에이전트 연동 정보
  // ==========================================
  // TODO: 개발 환경에 따라 아래의 설정을 알맞게 수정해주세요.
  final String gatewayHost = "https://petagent.aikopo.net"; // 게이트웨이 서버 IP 및 포트
  String userId = ""; // 사용자 고유 ID (로그인 시 동적 업데이트)
  final String targetAgentId =
      "DESKTOP-H3K9F8J-1"; // 제어 대상 Agent의 고유 ID (PC이름-1)

  final String baseUrl = "https://petagent.aikopo.net"; // 기존 이미지 업로드 API 서버 주소
  String? token;
  String? email;

  // 호스트 PC의 사설 IP 주소를 이용해 에뮬레이터 및 실기기 모두에서 PC 로컬 에이전트와 동기화합니다.
  String get localAgentUrl => "http://192.168.24.206:8001";

  String get wsUrl {
    final host = gatewayHost.trim();
    final urlBase = host.startsWith("http://")
        ? host.replaceFirst("http://", "ws://")
        : host.startsWith("https://")
        ? host.replaceFirst("https://", "wss://")
        : host.startsWith("ws://") || host.startsWith("wss://")
        ? host
        : "ws://$host";
    return "$urlBase/ws?token=${token ?? ''}";
  }

  String? sessionId;
  WebSocketChannel? _channel;
  final Set<String> _sentMessageIds = {};
  StreamSubscription<dynamic>? _socketSubscription;
  Future<void>? _logoutFuture;
  bool _handlingAuthError = false;

  // Stream to broadcast incoming messages from the server
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  // UUID v4 생성 유틸리티 (외부 패키지 없이 순수 Dart 구현)
  String generateUuidV4() {
    final random = Random.secure();
    String hexDigit(int value) => value.toRadixString(16);

    final buffer = StringBuffer();
    for (var i = 0; i < 36; i++) {
      if (i == 8 || i == 13 || i == 18 || i == 23) {
        buffer.write('-');
      } else if (i == 14) {
        buffer.write('4');
      } else if (i == 19) {
        buffer.write(hexDigit((random.nextInt(4) + 8)));
      } else {
        buffer.write(hexDigit(random.nextInt(16)));
      }
    }
    return buffer.toString();
  }

  void connect() {
    if (_channel != null) return;

    _channel = _connectChannel(Uri.parse(wsUrl));

    // 연결 직후 App 클라이언트 등록 메시지 전송
    final regMessage = {
      "type": "register",
      "payload": {
        "role": "app",
        "client_id": "flutter_app_${generateUuidV4()}",
        "timestamp": DateTime.now().toUtc().toIso8601String(),
        if (token != null) "token": token,
      },
    };
    _channel!.sink.add(jsonEncode(regMessage));

    _socketSubscription = _channel!.stream.listen(
      (data) {
        try {
          final decoded = jsonDecode(data);
          final String? type = decoded["type"];
          final Map<String, dynamic> rawPayload = decoded["payload"] ?? {};
          final String? payloadSessionId = rawPayload["session_id"];

          if (payloadSessionId != null) {
            sessionId = payloadSessionId;
          }

          // Heartbeat 처리 (Ping 수신 시 Pong 자동 응답)
          if (type == "ping") {
            final pongMessage = {
              "type": "pong",
              "payload": {
                "timestamp": DateTime.now().toUtc().toIso8601String(),
              },
            };
            _channel?.sink.add(jsonEncode(pongMessage));
            return;
          }

          // 기존 ChatScreen의 UI 로직과 호환되도록 구 버전 이벤트 포맷으로 매핑
          Map<String, dynamic> mappedData = {
            "session_id": payloadSessionId ?? sessionId,
          };

          if (type == "token") {
            mappedData["status"] = "stream_chunk";
            mappedData["chunk"] = rawPayload["chunk"] ?? "";
          } else if (type == "log") {
            final String? logStatus = rawPayload["status"];
            if (logStatus == "node_start") {
              mappedData["status"] = "node_start";
              mappedData["node"] = rawPayload["node"] ?? "";
            } else if (logStatus == "tool_start") {
              mappedData["status"] = "tool_start";
              mappedData["tool_name"] = rawPayload["tool_name"] ?? "";
              mappedData["tool_input"] = rawPayload["tool_input"];
            } else if (logStatus == "error") {
              mappedData["status"] = "error";
              mappedData["message"] = rawPayload["message"] ?? "에러 발생";
            } else {
              // 기타 디버그용 info 로그는 무시
              return;
            }
          } else if (type == "approval_request") {
            mappedData["status"] = "approval_required";
            mappedData["message"] = rawPayload["message"] ?? "";
            mappedData["tool_call_id"] = rawPayload["tool_call_id"];
            mappedData["tool_name"] = rawPayload["tool_name"] ?? "";
            mappedData["tool_args"] = rawPayload["tool_args"];
          } else if (type == "done") {
            // 최종 전문은 청크로 덧붙이지 않고 UI에서 기존 응답을 확정한다.
            mappedData["status"] = "stream_end";
            mappedData["final_message"] = rawPayload["final_message"];
          } else if (type == "error") {
            mappedData["status"] = "error";
            mappedData["message"] = rawPayload["message"] ?? "서버 오류";
          } else if (type == "chat") {
            final String? msgId = rawPayload["message_id"];
            if (_sentMessageIds.contains(msgId)) {
              return;
            }
            mappedData["status"] = "chat_message";
            mappedData["message"] = rawPayload["message"] ?? "";
            mappedData["images"] = List<String>.from(
              rawPayload["images"] ?? [],
            );
          } else if (type == "session_sync") {
            mappedData["status"] = "session_sync";
            mappedData["sessions"] = rawPayload["sessions"];
          } else if (type == "session_deleted") {
            mappedData["status"] = "session_deleted";
            mappedData["session_id"] = rawPayload["session_id"];
            mappedData["device_id"] = rawPayload["device_id"];
          } else if (type == "session_created") {
            mappedData["status"] = "session_created";
            mappedData["session_id"] = rawPayload["session_id"];
            mappedData["device_id"] = rawPayload["device_id"];
            mappedData["title"] = rawPayload["title"];
          } else if (type == "session_update") {
            mappedData["status"] = "session_update";
            mappedData["session_id"] = rawPayload["session_id"];
            mappedData["device_id"] = rawPayload["device_id"];
            mappedData["title"] = rawPayload["title"];
          } else if (type == "status") {
            mappedData["status"] = "agent_status";
            mappedData["agent_status"] =
                rawPayload["status"]; // "busy" or "ready"
          } else {
            // 그 외 처리되지 않은 타입은 스킵
            return;
          }

          _messageController.add(mappedData);
        } catch (e) {
          _messageController.add({
            "status": "error",
            "message": "JSON 파싱/처리 오류: $e",
          });
        }
      },
      onError: (error) {
        _messageController.add({
          "status": "error",
          "message": "WebSocket 오류: $error",
        });
        disconnect();
      },
      onDone: () {
        disconnect();
      },
    );
  }

  void disconnect() {
    final channel = _channel;
    _channel = null;
    _socketSubscription?.cancel();
    _socketSubscription = null;
    channel?.sink.close();
  }

  void sendChat(String message, {List<String>? imageUrls, String? sessionId}) {
    if (_channel == null) connect();

    final targetSessionId = sessionId ?? this.sessionId ?? generateUuidV4();
    this.sessionId = targetSessionId;

    final targetMessageId = generateUuidV4();
    _sentMessageIds.add(targetMessageId);

    // WsMessage 규격에 맞게 메시지 포맷핑
    final Map<String, dynamic> chatMessage = {
      "type": "chat",
      "payload": {
        "message_id": targetMessageId,
        "session_id": targetSessionId,
        "message": message,
        "images": imageUrls ?? [],
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      },
    };

    _channel?.sink.add(jsonEncode(chatMessage));
  }

  Future<List<String>> uploadImages(List<XFile> files) async {
    if (files.isEmpty) return [];

    var request = http.MultipartRequest(
      'POST',
      Uri.parse("$baseUrl/api/upload"),
    );

    for (var file in files) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'file', // 백엔드가 받는 필드명 ('file[]' 형태이므로 'file' 사용)
          file.path,
        ),
      );
    }

    var streamedResponse = await _httpClient.send(request);
    var response = await http.Response.fromStream(streamedResponse);
    await _checkAuthError(response.statusCode);
    if (response.statusCode == 200) {
      var decoded = jsonDecode(response.body);
      if (decoded is List) {
        return List<String>.from(decoded);
      } else if (decoded is Map && decoded['urls'] != null) {
        return List<String>.from(decoded['urls']);
      } else {
        throw Exception("알 수 없는 응답 형식: ${response.body}");
      }
    } else {
      throw Exception("상태 코드 ${response.statusCode}, 내용: ${response.body}");
    }
  }

  void approveTool(bool approve, String toolCallId, {String? sessionId}) {
    if (_channel == null) connect();

    final targetSessionId = sessionId ?? this.sessionId;
    if (targetSessionId == null) return;

    // WsMessage 규격에 맞게 승인 응답 메시지 포맷핑
    final Map<String, dynamic> approveMessage = {
      "type": "approval_response",
      "payload": {
        "message_id": generateUuidV4(),
        "session_id": targetSessionId,
        "approve": approve,
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      },
    };

    _channel?.sink.add(jsonEncode(approveMessage));
  }

  void getHistory(String sessionId, {String? deviceId}) {
    if (_channel == null) connect();

    final Map<String, dynamic> msg = {
      "type": "get_history",
      "payload": {
        "session_id": sessionId,
        "device_id": ?deviceId,
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      },
    };
    _channel?.sink.add(jsonEncode(msg));
  }

  void createSession(String sessionId, {String? deviceId}) {
    if (_channel == null) connect();

    final Map<String, dynamic> msg = {
      "type": "session_created",
      "payload": {
        "session_id": sessionId,
        "device_id": ?deviceId,
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      },
    };
    _channel?.sink.add(jsonEncode(msg));
  }

  void deleteSession(String sessionId, {String? deviceId}) {
    if (_channel == null) connect();

    final Map<String, dynamic> msg = {
      "type": "session_deleted",
      "payload": {
        "session_id": sessionId,
        "device_id": ?deviceId,
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      },
    };
    _channel?.sink.add(jsonEncode(msg));
  }

  void updateSessionTitle(String sessionId, String title, {String? deviceId}) {
    if (_channel == null) connect();

    final Map<String, dynamic> msg = {
      "type": "session_update",
      "payload": {
        "session_id": sessionId,
        "title": title,
        "message_id": generateUuidV4(),
        "device_id": ?deviceId,
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      },
    };
    _channel?.sink.add(jsonEncode(msg));
  }

  // ==========================================
  // [인증 관련 HTTP API 추가]
  // ==========================================

  Map<String, dynamic> _decodeJwt(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3 || parts.any((part) => part.isEmpty)) {
        throw Exception('Invalid JWT format');
      }
      final payload = parts[1];
      var normalized = base64Url.normalize(payload);
      final decodedBytes = base64Url.decode(normalized);
      final decodedString = utf8.decode(decodedBytes);
      return jsonDecode(decodedString);
    } catch (e) {
      throw Exception('Failed to decode authentication token: $e');
    }
  }

  // 화면 라우팅용 만료 검사이며, 토큰 서명/권한 검증은 서버가 수행한다.
  bool isTokenExpired({String? authToken, DateTime? now}) {
    final currentToken = authToken ?? token;
    if (currentToken == null || currentToken.isEmpty) return true;

    try {
      final expiry = _decodeJwt(currentToken)["exp"];
      if (expiry is! num || !expiry.isFinite) return true;
      final seconds =
          (now ?? DateTime.now()).microsecondsSinceEpoch /
          Duration.microsecondsPerSecond;
      return seconds >= expiry;
    } catch (_) {
      return true;
    }
  }

  Future<void> _saveCredentials(String? receivedToken, String userEmail) async {
    if (receivedToken == null || isTokenExpired(authToken: receivedToken)) {
      throw Exception('유효한 로그인 토큰을 받지 못했습니다. 다시 로그인해주세요.');
    }
    final decoded = _decodeJwt(receivedToken);
    final decodedUserId =
        (decoded["user_id"] ?? decoded["sub"] ?? decoded["id"])?.toString() ??
        "";
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("auth_token", receivedToken);
    await prefs.setString("user_email", userEmail);
    await prefs.setString("user_id", decodedUserId);
    token = receivedToken;
    email = userEmail;
    userId = decodedUserId;
  }

  Future<Map<String, dynamic>> signUp({
    required String name,
    required String email,
    required String password,
    required String deviceId,
    required String deviceType,
    required String deviceName,
  }) async {
    final response = await _httpClient.post(
      Uri.parse("$baseUrl/api/auth/signup"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "name": name,
        "email": email,
        "password": password,
        "device_id": deviceId,
        "device_type": deviceType.toLowerCase(), // 기본값 "pc", 소문자로 통일
        "device_name": deviceName,
      }),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(response.body);
      final String? receivedToken = data["access_token"];
      await _saveCredentials(receivedToken, email);

      // Sync signup with local python agent
      try {
        await _httpClient
            .post(
              Uri.parse("$localAgentUrl/api/signup"),
              headers: {"Content-Type": "application/json"},
              body: jsonEncode({
                "email": email,
                "password": password,
                "name": name,
              }),
            )
            .timeout(const Duration(seconds: 2));
      } catch (e) {
        debugPrint("Failed to sync signup with local agent: $e");
      }

      return data;
    } else {
      final responseBody = jsonDecode(response.body);
      throw Exception(responseBody["detail"] ?? "회원가입에 실패했습니다.");
    }
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    required String deviceId,
    required String deviceType,
    required String deviceName,
  }) async {
    final response = await _httpClient.post(
      Uri.parse("$baseUrl/api/auth/login"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "email": email,
        "password": password,
        "device_id": deviceId,
        "device_type": deviceType.toLowerCase(),
        "device_name": deviceName,
      }),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(response.body);
      final String? receivedToken = data["access_token"];

      await _saveCredentials(receivedToken, email);

      // Sync login with local python agent
      try {
        await _httpClient
            .post(
              Uri.parse("$localAgentUrl/api/login"),
              headers: {"Content-Type": "application/json"},
              body: jsonEncode({"email": email, "password": password}),
            )
            .timeout(const Duration(seconds: 2));
      } catch (e) {
        debugPrint("Failed to sync login with local agent: $e");
      }

      return data;
    } else {
      final responseBody = jsonDecode(response.body);
      throw Exception(responseBody["detail"] ?? "로그인에 실패했습니다.");
    }
  }

  Future<void> loadCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    userId = prefs.getString("user_id") ?? "";
    token = prefs.getString("auth_token");
    email = prefs.getString("user_email");
    if (isTokenExpired()) {
      await _clearCredentials();
    }
  }

  Future<void> _clearCredentials() async {
    disconnect();
    token = null;
    email = null;
    userId = "";
    sessionId = null;
    _sentMessageIds.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("user_id");
    await prefs.remove("auth_token");
    await prefs.remove("user_email");
  }

  Future<void> logout() {
    return _logoutFuture ??= _performLogout().whenComplete(() {
      _logoutFuture = null;
    });
  }

  Future<void> _performLogout() async {
    await _clearCredentials();

    // Sync logout with local python agent
    try {
      await _httpClient
          .post(Uri.parse("$localAgentUrl/api/logout"))
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint("Failed to sync logout with local agent: $e");
    }
  }

  // ==========================================
  // [기기 제어 & 세션 관련 신규 HTTP & WS API]
  // ==========================================

  Future<List<Map<String, dynamic>>> getDevices() async {
    final response = await _httpClient.get(
      Uri.parse("$baseUrl/api/devices"),
      headers: {
        "Authorization": "Bearer $token",
        "Content-Type": "application/json",
      },
    );
    await _checkAuthError(response.statusCode);
    if (response.statusCode == 200) {
      final dynamic data = jsonDecode(response.body);
      if (data is List) {
        return List<Map<String, dynamic>>.from(data);
      }
      return [];
    } else {
      final responseBody = jsonDecode(response.body);
      throw Exception(responseBody["detail"] ?? "기기 목록을 불러오는데 실패했습니다.");
    }
  }

  Future<void> updateDeviceName(String deviceId, String newName) async {
    final response = await _httpClient.patch(
      Uri.parse("$baseUrl/api/devices/$deviceId"),
      headers: {
        "Authorization": "Bearer $token",
        "Content-Type": "application/json",
      },
      body: jsonEncode({"device_name": newName}),
    );
    await _checkAuthError(response.statusCode);
    if (response.statusCode != 200 && response.statusCode != 204) {
      final responseBody = jsonDecode(response.body);
      throw Exception(responseBody["detail"] ?? "기기 이름 변경에 실패했습니다.");
    }
  }

  Future<void> deleteDevice(String deviceId) async {
    final response = await _httpClient.delete(
      Uri.parse("$baseUrl/api/devices/$deviceId"),
      headers: {
        "Authorization": "Bearer $token",
        "Content-Type": "application/json",
      },
    );
    await _checkAuthError(response.statusCode);
    if (response.statusCode != 200 && response.statusCode != 204) {
      final responseBody = jsonDecode(response.body);
      throw Exception(responseBody["detail"] ?? "기기 제거에 실패했습니다.");
    }
  }

  Future<Map<String, dynamic>> getHistoryHttp(
    String sessionId, {
    String? deviceId,
  }) async {
    var url = "$baseUrl/api/history/$sessionId";
    if (deviceId != null) {
      url += "?device_id=$deviceId";
    }
    final response = await _httpClient.get(
      Uri.parse(url),
      headers: {
        "Authorization": "Bearer $token",
        "Content-Type": "application/json",
      },
    );
    await _checkAuthError(response.statusCode);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      final responseBody = jsonDecode(response.body);
      throw Exception(responseBody["detail"] ?? "대화 이력을 불러오는데 실패했습니다.");
    }
  }

  void sendStop(String sessionId) {
    if (_channel == null) connect();
    final Map<String, dynamic> stopMsg = {
      "type": "stop",
      "payload": {"session_id": sessionId},
    };
    _channel?.sink.add(jsonEncode(stopMsg));
  }

  Future<void> _checkAuthError(int statusCode) async {
    if (statusCode == 401 || statusCode == 403) {
      if (_handlingAuthError) throw Exception("Authentication expired");
      _handlingAuthError = true;
      try {
        await logout();
        final context = navigatorKey.currentContext;
        if (context != null && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("인증 토큰이 만료되었습니다. 다시 로그인해주세요."),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => LoginScreen(api: this)),
          (route) => false,
        );
      } finally {
        _handlingAuthError = false;
      }
      throw Exception("Authentication expired");
    }
  }
}
