import 'dart:convert';
import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

class ApiService {
  final String baseUrl = "http://192.168.24.206:8001";
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

  void sendChat(String message, {List<String>? imageUrls, String? sessionId}) {
    if (_channel == null) connect();

    final Map<String, dynamic> requestBody = {
      "action": "chat",
      "message": message,
    };
    if (imageUrls != null && imageUrls.isNotEmpty) {
      requestBody["images"] = imageUrls;
    }
    
    final targetSessionId = sessionId ?? this.sessionId;
    if (targetSessionId != null) {
      requestBody["session_id"] = targetSessionId;
    }

    _channel?.sink.add(jsonEncode(requestBody));
  }

  Future<List<String>> uploadImages(List<XFile> files) async {
    if (files.isEmpty) return [];

    var request = http.MultipartRequest('POST', Uri.parse("$baseUrl/upload"));
    
    for (var file in files) {
      request.files.add(await http.MultipartFile.fromPath(
        'file', // 백엔드가 받는 필드명 ('file[]' 형태이므로 'file' 사용)
        file.path,
      ));
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

    final Map<String, dynamic> requestBody = {
      "action": "approve",
      "approve": approve,
    };
    
    final targetSessionId = sessionId ?? this.sessionId;
    if (targetSessionId != null) {
      requestBody["session_id"] = targetSessionId;
    }

    _channel?.sink.add(jsonEncode(requestBody));
  }
}
