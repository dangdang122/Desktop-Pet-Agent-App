import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  final String baseUrl = "http://192.168.24.202:8001";

  
  Future<Map<String, dynamic>> sendChat(String message) async {
    final response = await http.post(
      Uri.parse("$baseUrl/chat"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "message": message,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception("서버 응답 오류: ${response.statusCode}");
    }

    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> approveTool(
      bool approve, String toolCallId) async {
    final response = await http.post(
      Uri.parse("$baseUrl/approve"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "approve": approve,
        "tool_call_id": toolCallId,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception("서버 응답 오류: ${response.statusCode}");
    }

    return jsonDecode(response.body);
  }
}