import 'dart:convert';
import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';

class ApiService {
  final String wsUrl = "ws://192.168.24.206:8001/ws";
  String? sessionId;
  WebSocketChannel? _channel;

  // Stream to broadcast incoming messages from the server
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  void connect() {
    if (_channel != null) return;

    _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
    _channel!.stream.listen(
      (data) {
        try {
          final decoded = jsonDecode(data);
          if (decoded["session_id"] != null) {
            sessionId = decoded["session_id"];
          }
          _messageController.add(decoded);
        } catch (e) {
          _messageController.add({
            "status": "error",
            "message": "JSON 파싱 오류: $e",
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

  void sendChat(String message) {
    if (_channel == null) connect();

    final Map<String, dynamic> requestBody = {
      "action": "chat",
      "message": message,
    };
    if (sessionId != null) {
      requestBody["session_id"] = sessionId;
    }

    _channel?.sink.add(jsonEncode(requestBody));
  }

  void approveTool(bool approve, String toolCallId) {
    if (_channel == null) connect();

    final Map<String, dynamic> requestBody = {
      "action": "approve",
      "approve": approve,
      // 백엔드는 session_id로 상태를 재개하므로 tool_call_id는 필수가 아닐 수 있으나
      // 일관성을 위해 포함하거나 제외해도 무방합니다.
    };
    if (sessionId != null) {
      requestBody["session_id"] = sessionId;
    }

    _channel?.sink.add(jsonEncode(requestBody));
  }
}
