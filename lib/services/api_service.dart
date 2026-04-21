import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  final String baseUrl = "http://10.0.2.2:8001";
  String? sessionId;

  Future<Map<String, dynamic>> sendChat(String message) async {
    final Map<String, dynamic> requestBody = {"message": message};
    if (sessionId != null) {
      requestBody["session_id"] = sessionId;
    }

    final response = await http.post(
      Uri.parse("$baseUrl/chat"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(requestBody),
    );

    if (response.statusCode != 200) {
      throw Exception("서버 응답 오류: ${response.statusCode}");
    }

    final data = jsonDecode(response.body);
    if (data["session_id"] != null) {
      sessionId = data["session_id"];
    }
    return data;
  }

  Future<Map<String, dynamic>> approveTool(
    bool approve,
    String toolCallId,
  ) async {
    final Map<String, dynamic> requestBody = {
      "approve": approve,
      "tool_call_id": toolCallId,
    };
    if (sessionId != null) {
      requestBody["session_id"] = sessionId;
    }

    final response = await http.post(
      Uri.parse("$baseUrl/approve"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(requestBody),
    );

    if (response.statusCode != 200) {
      throw Exception("서버 응답 오류: ${response.statusCode}");
    }

    final data = jsonDecode(response.body);
    if (data["session_id"] != null) {
      sessionId = data["session_id"];
    }
    return data;
  }
}
