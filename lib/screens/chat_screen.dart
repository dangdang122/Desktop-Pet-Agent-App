import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../services/api_service.dart';
import '../services/permission_service.dart';

class ChatScreen extends StatefulWidget {
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class ChatMessage {
  final String text;
  final bool isUser;
  final bool isError;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.isError = false,
  });
}

class _ChatScreenState extends State<ChatScreen> {
  final ApiService api = ApiService();

  final TextEditingController controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<ChatMessage> messages = [];

  String? pendingToolId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      requestPermissions();
    });
  }

  @override
  void dispose() {
    controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void sendMessage() async {
    if (controller.text.isEmpty) return;

    String userMessage = controller.text;
    controller.clear();

    setState(() {
      messages.add(ChatMessage(text: userMessage, isUser: true));
    });

    await Future.delayed(const Duration(milliseconds: 50));
    _scrollToEnd();

    try {
      var response = await api.sendChat(userMessage);
      String status = response["status"];
      String message = response["message"];

      if (status == "approval_required") {
        setState(() {
          messages.add(ChatMessage(text: "승인 필요 → $message", isUser: false));
          pendingToolId = response["tool_call_id"];
        });
      } else {
        setState(() {
          messages.add(ChatMessage(text: message, isUser: false));
        });
      }
    } catch (e) {
      setState(() {
        messages.add(ChatMessage(
          text: "네트워크 오류: ${e.toString()}",
          isUser: false,
          isError: true,
        ));
      });
    }

    await Future.delayed(const Duration(milliseconds: 50));
    _scrollToEnd();
  }

  Future<void> _handleApprove(bool approve) async {
    if (pendingToolId == null) return;

    try {
      var res = await api.approveTool(approve, pendingToolId!);
      setState(() {
        messages.add(ChatMessage(text: res["message"], isUser: false));
        pendingToolId = null;
      });
    } catch (e) {
      setState(() {
        messages.add(ChatMessage(
          text: "승인 처리 오류: ${e.toString()}",
          isUser: false,
          isError: true,
        ));
        pendingToolId = null;
      });
    }

    await Future.delayed(const Duration(milliseconds: 50));
    _scrollToEnd();
  }

  Widget _buildBubble(ChatMessage message) {
    final backgroundColor = message.isUser
        ? Colors.blueAccent
        : (message.isError ? Colors.red.shade100 : Colors.grey.shade200);
    final textColor = message.isUser ? Colors.white : Colors.black87;

    return Align(
      alignment:
          message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(message.isUser ? 16 : 4),
            bottomRight: Radius.circular(message.isUser ? 4 : 16),
          ),
        ),
        child: message.isUser
            ? Text(
                message.text,
                style: TextStyle(color: textColor, fontSize: 16),
              )
            : MarkdownBody(
                data: message.text,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(color: textColor, fontSize: 16),
                  h1: TextStyle(color: textColor, fontSize: 20),
                  h2: TextStyle(color: textColor, fontSize: 18),
                  code: TextStyle(
                    color: textColor,
                    backgroundColor: Colors.black12,
                    fontFamily: 'monospace',
                  ),
                ),
                onTapLink: (text, href, title) {},
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("AI Agent"),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (pendingToolId != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: () => _handleApprove(true),
                      child: const Text("Approve"),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: () => _handleApprove(false),
                      child: const Text("Reject"),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: messages.length,
                padding: const EdgeInsets.only(top: 12, bottom: 12),
                itemBuilder: (context, index) {
                  return _buildBubble(messages[index]);
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      decoration: InputDecoration(
                        hintText: "메시지 입력",
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.send),
                      onPressed: sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
