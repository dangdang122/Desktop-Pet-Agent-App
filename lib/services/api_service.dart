import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

class ApiService {
  // ==========================================
  // [설정 값] 게이트웨이 및 에이전트 연동 정보
  // ==========================================
  // TODO: 개발 환경에 따라 아래의 설정을 알맞게 수정해주세요.
  final String gatewayHost = "https://petagent.aikopo.net"; // 게이트웨이 서버 IP 및 포트
  final String userId = "00000000-0000-0000-0000-000000000000"; // 사용자 고유 ID (Agent의 USER_ID와 일치해야 함)
  final String targetAgentId = "DESKTOP-NMCL2T9-1"; // 제어 대상 Agent의 고유 ID (PC이름-1)

  final String baseUrl = "https://petagent.aikopo.net"; // 기존 이미지 업로드 API 서버 주소
  
  String get wsUrl {
    final host = gatewayHost.trim();
    if (host.startsWith("http://")) {
      return "${host.replaceFirst("http://", "ws://")}/ws/$userId";
    } else if (host.startsWith("https://")) {
      return "${host.replaceFirst("https://", "wss://")}/ws/$userId";
    } else if (host.startsWith("ws://") || host.startsWith("wss://")) {
      return "$host/ws/$userId";
    } else {
      return "ws://$host/ws/$userId";
    }
  }
  
  String? sessionId;
  WebSocketChannel? _channel;
  final Set<String> _sentMessageIds = {};

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

    _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

    // 연결 직후 App 클라이언트 등록 메시지 전송
    final regMessage = {
      "type": "register",
      "payload": {
        "role": "app",
        "client_id": "flutter_app_${generateUuidV4()}",
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      }
    };
    _channel!.sink.add(jsonEncode(regMessage));

    _channel!.stream.listen(
      (data) {
        // 웹소켓 수신 데이터 로그 출력 (디버깅용)
        print("[WebSocket Recv] $data");

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
              }
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
          } else if (type == "done") {
            // Planner나 Worker 노드 필터링 때문에 메시지가 생략되는 것을 방지하기 위해 노드 초기화
            _messageController.add({
              "session_id": payloadSessionId ?? sessionId,
              "status": "node_start",
              "node": "aggregator",
            });

            // 최종 답변 메시지가 들어있을 경우 UI에 전달 (스트림 청크 형태로)
            final String? finalMsg = rawPayload["final_message"];
            if (finalMsg != null && finalMsg.isNotEmpty) {
              _messageController.add({
                "session_id": payloadSessionId ?? sessionId,
                "status": "stream_chunk",
                "chunk": finalMsg,
              });
            }
            mappedData["status"] = "stream_end";
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
            mappedData["images"] = List<String>.from(rawPayload["images"] ?? []);
          } else if (type == "session_deleted") {
            mappedData["status"] = "session_deleted";
          } else if (type == "session_created") {
            mappedData["status"] = "session_created";
          } else {
            // 그 외 처리되지 않은 타입은 스킵
            return;
          }

          print("[Mapped Output] $mappedData");
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
    _channel?.sink.close();
    _channel = null;
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
      }
    };

    _channel?.sink.add(jsonEncode(chatMessage));
  }

  Future<List<String>> uploadImages(List<XFile> files) async {
    if (files.isEmpty) return [];

    var request = http.MultipartRequest('POST', Uri.parse("$baseUrl/upload"));

    for (var file in files) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'file', // 백엔드가 받는 필드명 ('file[]' 형태이므로 'file' 사용)
          file.path,
        ),
      );
    }

    var streamedResponse = await request.send();
    var response = await http.Response.fromStream(streamedResponse);

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
      }
    };

    _channel?.sink.add(jsonEncode(approveMessage));
  }

  void getHistory(String sessionId) {
    if (_channel == null) connect();

    final Map<String, dynamic> msg = {
      "type": "get_history",
      "payload": {
        "session_id": sessionId,
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      }
    };
    _channel?.sink.add(jsonEncode(msg));
  }

  void createSession(String sessionId) {
    if (_channel == null) connect();

    final Map<String, dynamic> msg = {
      "type": "session_created",
      "payload": {
        "session_id": sessionId,
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      }
    };
    _channel?.sink.add(jsonEncode(msg));
  }

  void deleteSession(String sessionId) {
    if (_channel == null) connect();

    final Map<String, dynamic> msg = {
      "type": "session_deleted",
      "payload": {
        "session_id": sessionId,
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      }
    };
    _channel?.sink.add(jsonEncode(msg));
  }
}
