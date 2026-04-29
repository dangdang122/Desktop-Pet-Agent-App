import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import '../services/api_service.dart';
import '../services/permission_service.dart';
import 'dart:async';

class ChatScreen extends StatefulWidget {
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class ChatMessage {
  String text;
  final bool isUser;
  final bool isError;
  final bool isSystem;
  final List<String> imageUrls;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.isError = false,
    this.isSystem = false,
    this.imageUrls = const [],
  });
}

class ChatSession {
  final String id;
  String title;
  List<ChatMessage> messages;

  ChatSession({
    required this.id,
    this.title = "새 대화",
    List<ChatMessage>? messages,
  }) : messages = messages ?? [];
}

class _ChatScreenState extends State<ChatScreen> {
  final ApiService api = ApiService();

  final TextEditingController controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // 다중 세션 지원 구조
  Map<String, ChatSession> sessions = {};
  String? currentSessionId;

  List<ChatMessage> get messages {
    if (currentSessionId == null || !sessions.containsKey(currentSessionId)) {
      return [];
    }
    return sessions[currentSessionId!]!.messages;
  }

  String? pendingToolId;
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;

  String _currentNode = ""; // 현재 실행 중인 노드 추적
  String _searchQuery = ""; // 세션 검색용 상태

  final ImagePicker _picker = ImagePicker();
  List<String> _uploadedImageUrls = [];
  bool _isUploading = false;
  bool _isPickerActive = false;

  @override
  void initState() {
    super.initState();
    _createNewSession();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      requestPermissions();
    });

    api.connect();
    _messageSubscription = api.messages.listen((response) {
      String? sessionId = response["session_id"];
      String? status = response["status"];
      String? message = response["message"];

      // 응답된 sessionId가 있고, 아직 세션 맵에 없다면 세션 구조에 반영
      if (sessionId != null) {
        if (!sessions.containsKey(sessionId)) {
          setState(() {
            sessions[sessionId] = ChatSession(id: sessionId);
          });
        }
        // 만약 현재 세션이 없으면 응답된 sessionId로 설정
        if (currentSessionId == null) {
          setState(() {
            currentSessionId = sessionId;
          });
        }
      }

      if (status == "approval_required") {
        setState(() {
          messages.add(
            ChatMessage(
              text: "승인 필요 → $message",
              isUser: false,
              isSystem: true,
            ),
          );
          pendingToolId = response["tool_call_id"];
        });
      } else if (status == "error") {
        setState(() {
          messages.add(
            ChatMessage(text: "오류: $message", isUser: false, isError: true),
          );
          pendingToolId = null;
        });
      } else if (status == "tool_start") {
        String toolName = response["tool_name"] ?? "";
        setState(() {
          if (messages.isEmpty ||
              messages.last.isUser ||
              messages.last.isSystem ||
              messages.last.isError) {
            messages.add(
              ChatMessage(text: "🛠 도구 사용 중: $toolName\n", isUser: false),
            );
          } else {
            if (messages.last.text.isNotEmpty &&
                !messages.last.text.endsWith("\n")) {
              messages.last.text += "\n";
            }
            messages.last.text += "🛠 도구 사용 중: $toolName\n";
          }
        });
      } else if (status == "stream_chunk") {
        // Planner, Worker 등의 중간 노드에서 발생하는 JSON 스트리밍 청크는 무시
        if (_currentNode.toLowerCase() == "planner" ||
            _currentNode.toLowerCase() == "worker") {
          return;
        }

        String chunk = response["chunk"] ?? "";
        setState(() {
          if (messages.isEmpty ||
              messages.last.isUser ||
              messages.last.isSystem ||
              messages.last.isError) {
            messages.add(ChatMessage(text: chunk, isUser: false));
          } else {
            messages.last.text += chunk;
          }
        });
      } else if (status == "stream_end") {
        // 스트림 종료 시 노드 초기화
        _currentNode = "";
      } else if (status == "node_start") {
        // 실행 중인 노드명 업데이트
        _currentNode = response["node"] ?? "";
      } else {
        // 기존 대비 (status가 없을 때 등)
        if (message != null && message.isNotEmpty) {
          setState(() {
            messages.add(ChatMessage(text: message, isUser: false));
            pendingToolId = null;
          });
        }
      }

      Future.delayed(const Duration(milliseconds: 50), _scrollToEnd);
    });
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    api.disconnect();
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

  void sendMessage() {
    if (controller.text.isEmpty && _uploadedImageUrls.isEmpty) return;

    String userMessage = controller.text;
    controller.clear();

    List<String> currentUrls = List.from(_uploadedImageUrls);
    setState(() {
      messages.add(
        ChatMessage(text: userMessage, isUser: true, imageUrls: currentUrls),
      );
      _uploadedImageUrls.clear();

      // 세션 제목이 기본값이면 첫 번째 사용자 메시지로 자동 지정
      if (currentSessionId != null &&
          sessions[currentSessionId!]!.title == "새 대화") {
        sessions[currentSessionId!]!.title = userMessage.length > 20
            ? "${userMessage.substring(0, 20)}..."
            : userMessage;
      }
    });

    Future.delayed(const Duration(milliseconds: 50), _scrollToEnd);

    api.sendChat(
      userMessage,
      imageUrls: currentUrls,
      sessionId: currentSessionId,
    );
  }

  void _createNewSession() {
    String newId = "session_${DateTime.now().millisecondsSinceEpoch}";
    setState(() {
      sessions[newId] = ChatSession(id: newId);
      currentSessionId = newId;
    });
  }

  void _switchToSession(String sessionId) {
    setState(() {
      currentSessionId = sessionId;
    });
    // 대화창 하단으로 스크롤 이동
    Future.delayed(const Duration(milliseconds: 50), _scrollToEnd);
  }

  void _renameSession(String sessionId) {
    TextEditingController renameController = TextEditingController(
      text: sessions[sessionId]?.title ?? "",
    );
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("이름 바꾸기"),
          content: TextField(
            controller: renameController,
            decoration: const InputDecoration(hintText: "새로운 채팅방 이름 입력"),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("취소"),
            ),
            ElevatedButton(
              onPressed: () {
                if (renameController.text.trim().isNotEmpty) {
                  setState(() {
                    sessions[sessionId]!.title = renameController.text.trim();
                  });
                }
                Navigator.pop(context);
              },
              child: const Text("저장"),
            ),
          ],
        );
      },
    );
  }

  void _deleteSession(String sessionId) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("세션 삭제"),
          content: const Text("정말 삭제하시겠습니까?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("취소"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () {
                setState(() {
                  sessions.remove(sessionId);
                });
                if (currentSessionId == sessionId) {
                  if (sessions.isNotEmpty) {
                    setState(() {
                      currentSessionId = sessions.keys.last;
                    });
                  } else {
                    _createNewSession();
                  }
                }
                Navigator.pop(context);
              },
              child: const Text("삭제", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickImage() async {
    if (_isPickerActive) return;

    if (_uploadedImageUrls.length >= 3) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("최대 3장까지만 업로드할 수 있습니다.")));
      }
      return;
    }

    setState(() {
      _isPickerActive = true;
    });

    List<XFile> images = [];
    try {
      images = await _picker.pickMultiImage();
    } catch (e) {
      debugPrint("Image picker error: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isPickerActive = false;
        });
      }
    }

    if (images.isEmpty) return;

    List<XFile> validImages = [];
    for (var img in images) {
      final bytes = await img.length();
      if (bytes > 5 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("${img.name}은(는) 5MB를 초과하여 제외되었습니다.")),
          );
        }
      } else {
        validImages.add(img);
      }
    }

    if (validImages.isEmpty) return;

    int remaining = 3 - _uploadedImageUrls.length;
    if (validImages.length > remaining) {
      validImages = validImages.sublist(0, remaining);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("최대 3장까지만 업로드되어 일부 이미지는 제외되었습니다.")),
        );
      }
    }

    setState(() {
      _isUploading = true;
    });

    try {
      List<String> urls = await api.uploadImages(validImages);
      if (mounted) {
        setState(() {
          _uploadedImageUrls.addAll(urls);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("이미지 업로드 실패: $e")));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  void _handleApprove(bool approve) {
    if (pendingToolId == null) return;

    api.approveTool(approve, pendingToolId!, sessionId: currentSessionId);
    setState(() {
      pendingToolId = null;
    });
  }

  Widget _buildBubble(ChatMessage message) {
    final backgroundColor = message.isUser
        ? Colors.blueAccent
        : (message.isError
              ? Colors.red.shade100
              : (message.isSystem
                    ? Colors.orange.shade100
                    : Colors.grey.shade200));
    final textColor = message.isUser ? Colors.white : Colors.black87;

    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
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
        child: Column(
          crossAxisAlignment: message.isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (message.imageUrls.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: message.imageUrls.map((url) {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      url,
                      width: 120,
                      height: 120,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 120,
                        height: 120,
                        color: Colors.grey.shade300,
                        child: const Icon(Icons.broken_image),
                      ),
                    ),
                  );
                }).toList(),
              ),
            if (message.imageUrls.isNotEmpty && message.text.isNotEmpty)
              const SizedBox(height: 8),
            if (message.text.isNotEmpty)
              message.isUser
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
          ],
        ),
      ),
    );
  }

  Widget _buildDrawer(List<ChatSession> reversedSessions) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 12.0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "채팅 목록",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () {
                      _createNewSession();
                      Navigator.of(context).pop();
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 8.0,
              ),
              child: TextField(
                decoration: InputDecoration(
                  hintText: "Search",
                  suffixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.grey.shade200,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 0,
                  ),
                ),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value;
                  });
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Text(
                "Chats",
                style: TextStyle(
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: reversedSessions.length,
                itemBuilder: (context, index) {
                  final session = reversedSessions[index];
                  final isSelected = session.id == currentSessionId;
                  return Container(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? Colors.grey.shade200
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListTile(
                      title: Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        _switchToSession(session.id);
                        Navigator.of(context).pop();
                      },
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert),
                        onSelected: (value) {
                          if (value == 'rename') {
                            _renameSession(session.id);
                          } else if (value == 'delete') {
                            _deleteSession(session.id);
                          }
                        },
                        itemBuilder: (BuildContext context) =>
                            <PopupMenuEntry<String>>[
                              const PopupMenuItem<String>(
                                value: 'rename',
                                child: Text('이름 바꾸기'),
                              ),
                              const PopupMenuItem<String>(
                                value: 'delete',
                                child: Text(
                                  '삭제',
                                  style: TextStyle(color: Colors.red),
                                ),
                              ),
                            ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.grey.shade300,
                child: const Icon(Icons.person, color: Colors.white),
              ),
              title: const Text(
                "polytech@kopo.ac.kr",
                style: TextStyle(fontSize: 14),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredSessions = sessions.values.where((s) {
      return s.title.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();
    final reversedSessions = filteredSessions.reversed.toList();

    return Scaffold(
      appBar: AppBar(title: const Text("AI Agent")),
      drawer: _buildDrawer(reversedSessions),
      body: SafeArea(
        child: Column(
          children: [
            if (pendingToolId != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
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
            if (_uploadedImageUrls.isNotEmpty || _isUploading)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    ..._uploadedImageUrls.map(
                      (url) => Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            margin: const EdgeInsets.only(right: 8),
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              image: DecorationImage(
                                image: NetworkImage(url),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          Positioned(
                            right: 4,
                            top: -4,
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _uploadedImageUrls.remove(url);
                                });
                              },
                              child: const CircleAvatar(
                                radius: 10,
                                backgroundColor: Colors.black54,
                                child: Icon(
                                  Icons.close,
                                  size: 12,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_isUploading)
                      Container(
                        margin: const EdgeInsets.only(right: 8),
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.image),
                    onPressed:
                        _isUploading ||
                            _isPickerActive ||
                            _uploadedImageUrls.length >= 3
                        ? null
                        : _pickImage,
                  ),
                  const SizedBox(width: 4),
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
