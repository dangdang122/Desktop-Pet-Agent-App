import 'package:flutter/material.dart';
import '../services/api_service.dart';

class ChatScreen extends StatefulWidget {
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {

  final ApiService api = ApiService();

  final TextEditingController controller = TextEditingController();
  List<String> messages = [];

  String? pendingToolId;

  void sendMessage() async {
    if (controller.text.isEmpty) return;

    String userMessage = controller.text;

    setState(() {
      messages.add("User: $userMessage");
    });

    controller.clear();

    var response = await api.sendChat(userMessage);

    String status = response["status"];
    String message = response["message"];

    if (status == "approval_required") {
      setState(() {
        messages.add("Agent: 승인 필요 → $message");
      });

      pendingToolId = response["tool_call_id"];
    } else {
      setState(() {
        messages.add("Agent: $message");
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("AI Agent"),
      ),
      body: Column(
        children: [

          if (pendingToolId != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: () async {
                    var res = await api.approveTool(true, pendingToolId!);
                    setState(() {
                      messages.add("Agent: ${res["message"]}");
                      pendingToolId = null;
                    });
                  },
                  child: const Text("Approve"),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: () async {
                    var res = await api.approveTool(false, pendingToolId!);
                    setState(() {
                      messages.add("Agent: ${res["message"]}");
                      pendingToolId = null;
                    });
                  },
                  child: const Text("Reject"),
                ),
              ],
            ),

          Expanded(
            child: ListView.builder(
              itemCount: messages.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(messages[index]),
                );
              },
            ),
          ),

          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: "메시지 입력",
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: sendMessage,
              )
            ],
          )

        ],
      ),
    );
  }
}