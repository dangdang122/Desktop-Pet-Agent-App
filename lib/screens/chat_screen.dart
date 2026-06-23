import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import '../services/api_service.dart';
import '../services/permission_service.dart';
import 'dart:async';
import 'dart:convert';
import 'login_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class AgentStepLog {
  final String nodeName;
  String details;
  bool isCompleted;

  AgentStepLog({
    required this.nodeName,
    required this.details,
    this.isCompleted = false,
  });
}

class ChatMessage {
  String text;
  final bool isUser;
  final bool isError;
  final bool isSystem;
  final List<String> imageUrls;
  final List<AgentStepLog> logs;
  bool isLogsCollapsed;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.isError = false,
    this.isSystem = false,
    this.imageUrls = const [],
    List<AgentStepLog>? logs,
    this.isLogsCollapsed = false,
  }) : logs = logs ?? [];
}

class ChatSession {
  final String id;
  String deviceId; // 각 세션이 소속된 기기 고유 ID
  String title;
  List<ChatMessage> messages;
  String currentNode; // 각 세션별 실행 노드 추적

  ChatSession({
    required this.id,
    required this.deviceId,
    this.title = "새 대화",
    List<ChatMessage>? messages,
    this.currentNode = "",
  }) : messages = messages ?? [];
}

class _ChatScreenState extends State<ChatScreen> {
  final ApiService api = ApiService();

  final TextEditingController controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // 다중 세션 지원 구조
  Map<String, ChatSession> sessions = {};
  String? currentSessionId;
  String? selectedDeviceId;
  bool _hasSelectedDevice = false;

  // 승인 요청 상세 상태
  String? pendingToolName;
  dynamic pendingToolArgs;
  String? pendingMessage;

  List<ChatMessage> get messages {
    if (currentSessionId == null || !sessions.containsKey(currentSessionId)) {
      return [];
    }
    return sessions[currentSessionId!]!.messages;
  }

  String? pendingToolId;
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;


  String _searchQuery = ""; // 세션 검색용 상태

  final ImagePicker _picker = ImagePicker();
  final List<String> _uploadedImageUrls = [];
  bool _isPickerActive = false;
  bool _isUploading = false;

  List<Map<String, dynamic>> devices = [];
  bool _isLoadingDevices = false;

  List<Map<String, dynamic>> get filteredDevices {
    return devices.where((device) {
      final name = device["device_name"] ?? "";
      return name.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _messageSubscription = api.messages.listen((response) {
      String? sessionId = response["session_id"];
      String? status = response["status"];
      String? message = response["message"];

      // Handle agent status (busy/ready) to toggle Stop button
      if (status == "agent_status") {
        final String agentStatus = response["agent_status"] ?? "ready";
        setState(() {
          if (currentSessionId != null && sessions.containsKey(currentSessionId)) {
            if (agentStatus == "busy") {
              sessions[currentSessionId!]!.currentNode = "busy";
            } else {
              sessions[currentSessionId!]!.currentNode = "";
            }
          }
        });
        return;
      }

      // Handle session_sync event
      if (status == "session_sync") {
        final List<dynamic> rawSessions = response["sessions"] ?? [];
        setState(() {
          for (var item in rawSessions) {
            String? sid;
            String? devId;
            String? title;

            if (item is String) {
              sid = item;
            } else if (item is Map) {
              sid = item["session_id"]?.toString() ?? item["id"]?.toString();
              devId = item["device_id"]?.toString() ?? item["deviceId"]?.toString();
              title = item["title"]?.toString();
            }

            if (sid != null) {
              String actualDevId = devId ?? "";
              if (actualDevId.isEmpty || actualDevId == "null") {
                actualDevId = devices.isNotEmpty ? devices.first["device_id"] ?? "" : "";
              }
              if (!sessions.containsKey(sid)) {
                sessions[sid] = ChatSession(
                  id: sid,
                  deviceId: actualDevId,
                  title: title ?? "새 대화",
                );
              } else {
                if (title != null) {
                  sessions[sid]!.title = title;
                }
                sessions[sid]!.deviceId = actualDevId;
              }
            }
          }
        });
        return;
      }

      // Handle session_created event
      if (status == "session_created") {
        final String? sid = response["session_id"]?.toString() ?? response["id"]?.toString();
        final String? devId = response["device_id"]?.toString() ?? response["deviceId"]?.toString();
        final String? title = response["title"]?.toString();
        if (sid != null) {
          String actualDevId = devId ?? "";
          if (actualDevId.isEmpty || actualDevId == "null") {
            actualDevId = devices.isNotEmpty ? devices.first["device_id"] ?? "" : "";
          }
          setState(() {
            if (!sessions.containsKey(sid)) {
              sessions[sid] = ChatSession(
                id: sid,
                deviceId: actualDevId,
                title: title ?? "새 대화",
              );
            }
          });
        }
        return;
      }

      // Handle session_deleted event
      if (status == "session_deleted") {
        final String? sid = response["session_id"]?.toString() ?? response["id"]?.toString();
        if (sid != null) {
          setState(() {
            sessions.remove(sid);
            if (currentSessionId == sid) {
              currentSessionId = null;
            }
          });
        }
        return;
      }

      // Handle session_update event
      if (status == "session_update") {
        final String? sid = response["session_id"]?.toString() ?? response["id"]?.toString();
        final String? title = response["title"]?.toString();
        if (sid != null && title != null) {
          setState(() {
            if (sessions.containsKey(sid)) {
              sessions[sid]!.title = title;
            }
          });
        }
        return;
      }

      if (sessionId == null) return;

      // 응답된 sessionId가 있고, 아직 세션 맵에 없다면 세션 구조에 반영
      if (!sessions.containsKey(sessionId)) {
        setState(() {
          sessions[sessionId] = ChatSession(
            id: sessionId,
            deviceId: response["device_id"] ?? "",
          );
        });
      }
      
      // 만약 현재 세션이 없으면 응답된 sessionId로 설정
      if (currentSessionId == null) {
        setState(() {
          currentSessionId = sessionId;
          if (sessions.containsKey(sessionId)) {
            selectedDeviceId = sessions[sessionId]!.deviceId;
          }
        });
      }

      final ChatSession targetSession = sessions[sessionId]!;
      final List<ChatMessage> targetMessages = targetSession.messages;

      if (status == "chat_message") {
        setState(() {
          targetMessages.add(
            ChatMessage(
              text: message ?? "",
              isUser: true,
              imageUrls: List<String>.from(response["images"] ?? []),
            ),
          );
        });
      } else if (status == "approval_required") {
        setState(() {
          targetMessages.add(
            ChatMessage(
              text: "⚠️ 승인 대기 중 → $message",
              isUser: false,
              isSystem: true,
            ),
          );
          pendingToolId = response["tool_call_id"];
          pendingToolName = response["tool_name"];
          pendingToolArgs = response["tool_args"];
          pendingMessage = response["message"];
        });
      } else if (status == "error") {
        setState(() {
          targetMessages.add(
            ChatMessage(text: "오류: $message", isUser: false, isError: true),
          );
          pendingToolId = null;
          targetSession.currentNode = "";
        });
      } else if (status == "tool_start") {
        final String toolName = response["tool_name"] ?? "";
        final dynamic toolInput = response["tool_input"];
        setState(() {
          if (targetMessages.isEmpty ||
              targetMessages.last.isUser ||
              targetMessages.last.isSystem ||
              targetMessages.last.isError) {
            targetMessages.add(
              ChatMessage(text: "", isUser: false),
            );
          }
          final lastMsg = targetMessages.last;
          if (lastMsg.logs.isNotEmpty) {
            lastMsg.logs.last.isCompleted = true;
          }
          String detailsText = "🛠 도구 실행: $toolName";
          if (toolInput != null) {
            final inputStr = toolInput is String ? toolInput : const JsonEncoder().convert(toolInput);
            detailsText += "\n인자: $inputStr";
          }
          lastMsg.logs.add(AgentStepLog(
            nodeName: "tool",
            details: detailsText,
            isCompleted: false,
          ));
        });
      } else if (status == "stream_chunk") {
        // Planner, Worker 등의 중간 노드에서 발생하는 JSON 스트리밍 청크는 무시
        final node = targetSession.currentNode.toLowerCase();
        if (node == "planner" || node == "worker") {
          return;
        }

        String chunk = response["chunk"] ?? "";
        setState(() {
          if (targetMessages.isEmpty ||
              targetMessages.last.isUser ||
              targetMessages.last.isSystem ||
              targetMessages.last.isError) {
            targetMessages.add(ChatMessage(text: chunk, isUser: false));
          } else {
            for (var log in targetMessages.last.logs) {
              log.isCompleted = true;
            }
            targetMessages.last.text += chunk;
          }
        });
      } else if (status == "stream_end") {
        setState(() {
          targetSession.currentNode = "";
        });
      } else if (status == "node_start") {
        final String node = response["node"] ?? "";
        setState(() {
          targetSession.currentNode = node;
        });

        if (node.isNotEmpty && node.toLowerCase() != "aggregator") {
          setState(() {
            if (targetMessages.isEmpty ||
                targetMessages.last.isUser ||
                targetMessages.last.isSystem ||
                targetMessages.last.isError) {
              targetMessages.add(ChatMessage(text: "", isUser: false));
            }
            final lastMsg = targetMessages.last;
            if (lastMsg.logs.isEmpty || lastMsg.logs.last.nodeName != node) {
              if (lastMsg.logs.isNotEmpty) {
                lastMsg.logs.last.isCompleted = true;
              }
              lastMsg.logs.add(AgentStepLog(
                nodeName: node,
                details: "${_getNodeFriendlyName(node)} 동작 중...",
                isCompleted: false,
              ));
            }
          });
        }
      } else {
        if (message != null && message.isNotEmpty) {
          setState(() {
            targetMessages.add(ChatMessage(text: message, isUser: false));
            pendingToolId = null;
          });
        }
      }

      if (sessionId == currentSessionId) {
        Future.delayed(const Duration(milliseconds: 50), _scrollToEnd);
      }
    });


    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await requestPermissions();
      await _loadDevices();
      api.connect();
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

  Future<void> _loadDevices() async {
    if (_isLoadingDevices) return;
    if (mounted) {
      setState(() {
        _isLoadingDevices = true;
      });
    }
    try {
      final fetchedDevices = await api.getDevices();
      final filteredList = fetchedDevices
          .where((d) => d["device_type"]?.toString().toLowerCase() == "pc")
          .toList();
      
      setState(() {
        devices = filteredList;
        if (devices.isNotEmpty) {
          final String firstDevId = devices.first["device_id"] ?? "";
          for (var session in sessions.values) {
            if (session.deviceId.isEmpty || session.deviceId == "null") {
              session.deviceId = firstDevId;
            }
          }
          if (selectedDeviceId == null || !devices.any((d) => d["device_id"] == selectedDeviceId)) {
            if (currentSessionId != null && sessions.containsKey(currentSessionId) && sessions[currentSessionId]!.deviceId.isNotEmpty) {
              selectedDeviceId = sessions[currentSessionId]!.deviceId;
            } else {
              selectedDeviceId = firstDevId;
            }
          }
        } else {
          selectedDeviceId = null;
        }
      });

      if (currentSessionId != null) {
        final currentSession = sessions[currentSessionId];
        if (currentSession != null) {
          final sessionDeviceExists = devices.any((d) => d["device_id"] == currentSession.deviceId);
          if (!sessionDeviceExists) {
            setState(() {
              currentSessionId = null;
              selectedDeviceId = devices.isNotEmpty ? devices.first["device_id"] : null;
            });
          }
        }
      }
    } catch (e) {
      debugPrint("Failed to load devices: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingDevices = false;
        });
      }
    }
  }

  void _selectSession(String sessionId, String deviceId) async {
    setState(() {
      currentSessionId = sessionId;
      selectedDeviceId = deviceId;
      if (!sessions.containsKey(sessionId)) {
        sessions[sessionId] = ChatSession(id: sessionId, deviceId: deviceId);
      }
    });

    try {
      final historyData = await api.getHistoryHttp(sessionId, deviceId: deviceId);
      final List<dynamic> historyList = historyData["history"] ?? [];
      
      setState(() {
        sessions[sessionId]!.messages = historyList.map((item) {
          final isUser = item["role"] == "user";
          return ChatMessage(
            text: item["message"] ?? "",
            isUser: isUser,
            imageUrls: List<String>.from(item["images"] ?? []),
          );
        }).toList();
      });
    } catch (e) {
      debugPrint("Failed to load history for session $sessionId: $e");
    }

    Future.delayed(const Duration(milliseconds: 50), _scrollToEnd);
  }

  void _createNewSessionForDevice(String deviceId) {
    final newSessionId = api.generateUuidV4();
    api.createSession(newSessionId, deviceId: deviceId);
    setState(() {
      sessions[newSessionId] = ChatSession(id: newSessionId, deviceId: deviceId, title: "새 대화");
      currentSessionId = newSessionId;
      selectedDeviceId = deviceId;
    });
  }

  void _selectDeviceAndGo(String deviceId) async {
    setState(() {
      selectedDeviceId = deviceId;
      _hasSelectedDevice = true;
    });

    // 해당 기기의 대화방을 찾음
    final deviceSessions = sessions.values
        .where((s) => s.deviceId == deviceId)
        .toList();

    if (deviceSessions.isNotEmpty) {
      // 가장 첫 번째 세션을 선택하여 이동
      _selectSession(deviceSessions.first.id, deviceId);
    } else {
      // 세션이 없으면 새로 생성해서 이동
      _createNewSessionForDevice(deviceId);
    }
  }

  void _deleteSession(String sessionId, String deviceId) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("대화 세션 삭제"),
          content: const Text("정말 이 대화 세션을 삭제하시겠습니까?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("취소"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () {
                api.deleteSession(sessionId, deviceId: deviceId);
                Navigator.pop(dialogContext);
              },
              child: const Text("삭제", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _renameSession(String sessionId, String deviceId, String currentTitle) {
    TextEditingController editController = TextEditingController(text: currentTitle);
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("대화 세션 이름 수정"),
          content: TextField(
            controller: editController,
            decoration: const InputDecoration(hintText: "새로운 세션 이름 입력"),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("취소"),
            ),
            ElevatedButton(
              onPressed: () {
                final newTitle = editController.text.trim();
                if (newTitle.isNotEmpty) {
                  api.updateSessionTitle(sessionId, newTitle, deviceId: deviceId);
                  setState(() {
                    if (sessions.containsKey(sessionId)) {
                      sessions[sessionId]!.title = newTitle;
                    }
                  });
                }
                Navigator.pop(dialogContext);
              },
              child: const Text("저장"),
            ),
          ],
        );
      },
    );
  }

  void _editDeviceName(String deviceId, String currentName) {
    TextEditingController editController = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("기기 이름 수정"),
          content: TextField(
            controller: editController,
            decoration: const InputDecoration(hintText: "새로운 기기 이름 입력"),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("취소"),
            ),
            ElevatedButton(
              onPressed: () async {
                final newName = editController.text.trim();
                if (newName.isNotEmpty) {
                  try {
                    await api.updateDeviceName(deviceId, newName);
                    if (!dialogContext.mounted) return;
                    Navigator.pop(dialogContext);
                    _loadDevices();
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("기기 이름 수정 실패: $e")),
                    );
                  }
                }
              },
              child: const Text("저장"),
            ),
          ],
        );
      },
    );
  }

  void _removeDevice(String deviceId) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("기기 등록 해제"),
          content: const Text("정말 이 기기를 계정에서 제거하시겠습니까?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("취소"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async {
                try {
                  await api.deleteDevice(deviceId);
                  if (!dialogContext.mounted) return;
                  Navigator.pop(dialogContext);
                  _loadDevices();
                  setState(() {
                    sessions.remove(deviceId);
                    if (currentSessionId == deviceId) {
                      currentSessionId = null;
                    }
                  });
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("기기 제거 실패: $e")),
                  );
                }
              },
              child: const Text("제거", style: TextStyle(color: Colors.white)),
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

  String _getNodeFriendlyName(String node) {
    switch (node.toLowerCase()) {
      case "planner":
        return "⚙️ Planner (작업 계획 수립)";
      case "master_router":
        return "🧠 Router (작업 라우팅)";
      case "general_mcp_worker":
        return "🛠 General Worker (도구 처리)";
      case "vision_worker":
        return "👁 Vision Worker (이미지 분석)";
      default:
        return "⚙️ $node";
    }
  }

  void _handleApprove(bool approve) {
    if (pendingToolId == null) return;

    api.approveTool(approve, pendingToolId!, sessionId: currentSessionId);
    setState(() {
      pendingToolId = null;
      pendingToolName = null;
      pendingToolArgs = null;
      pendingMessage = null;
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
            if (message.imageUrls.isNotEmpty && (message.text.isNotEmpty || message.logs.isNotEmpty))
              const SizedBox(height: 8),
            if (!message.isUser && message.logs.isNotEmpty) ...[
              StatefulBuilder(
                builder: (context, setBubbleState) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade900,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            setBubbleState(() {
                              message.isLogsCollapsed = !message.isLogsCollapsed;
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Row(
                                  children: [
                                    Icon(Icons.terminal_rounded, color: Colors.greenAccent, size: 18),
                                    SizedBox(width: 8),
                                    Text(
                                      "에이전트 추론 로그",
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                Icon(
                                  message.isLogsCollapsed
                                      ? Icons.keyboard_arrow_down_rounded
                                      : Icons.keyboard_arrow_up_rounded,
                                  color: Colors.white70,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (!message.isLogsCollapsed) ...[
                          const Divider(color: Colors.white12, height: 1),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: message.logs.map((log) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (!log.isCompleted) ...[
                                        const SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.5,
                                            valueColor: AlwaysStoppedAnimation<Color>(Colors.greenAccent),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                      ] else ...[
                                        const Icon(Icons.check_circle_outline_rounded, color: Colors.greenAccent, size: 14),
                                        const SizedBox(width: 6),
                                      ],
                                      Expanded(
                                        child: Text(
                                          log.details,
                                          style: const TextStyle(
                                            color: Colors.greenAccent,
                                            fontFamily: 'monospace',
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }
              ),
            ],
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

  Widget _buildDrawer(List<Map<String, dynamic>> filteredDevices) {
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
                    "기기 목록",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: '새로고침',
                    onPressed: _loadDevices,
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
                "Devices",
                style: TextStyle(
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: _isLoadingDevices
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: filteredDevices.length,
                      itemBuilder: (context, index) {
                        final device = filteredDevices[index];
                        final deviceId = device["device_id"] ?? "";
                        final deviceName = device["device_name"] ?? "Unknown Device";
                        final isOnline = device["is_online"] ?? false;
                        final isSelected = deviceId == selectedDeviceId;

                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.blueAccent.withValues(alpha: 0.1)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: isSelected
                                ? Border.all(color: Colors.blueAccent, width: 1)
                                : Border.all(color: Colors.transparent),
                          ),
                          child: ListTile(
                            leading: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isOnline ? Colors.green : Colors.grey,
                              ),
                            ),
                            title: Text(
                              deviceName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                color: isSelected ? Colors.blueAccent : Colors.black87,
                              ),
                            ),
                            subtitle: Text(
                              device["device_type"] ?? "pc",
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                            onTap: () {
                              setState(() {
                                selectedDeviceId = deviceId;
                              });
                            },
                            trailing: PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert),
                              onSelected: (value) {
                                if (value == 'rename') {
                                  _editDeviceName(deviceId, deviceName);
                                } else if (value == 'delete') {
                                  _removeDevice(deviceId);
                                }
                              },
                              itemBuilder: (BuildContext context) =>
                                  <PopupMenuEntry<String>>[
                                    const PopupMenuItem<String>(
                                      value: 'rename',
                                      child: Text('기기 이름 수정'),
                                    ),
                                    const PopupMenuItem<String>(
                                      value: 'delete',
                                      child: Text(
                                        '기기 제거',
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      selectedDeviceId != null
                          ? "'${filteredDevices.firstWhere((d) => d["device_id"] == selectedDeviceId, orElse: () => {"device_name": "선택된 기기"})["device_name"]}' 대화방"
                          : "대화방 목록",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  if (selectedDeviceId != null)
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline, color: Colors.blueAccent, size: 22),
                      tooltip: "새 대화 시작",
                      onPressed: () => _createNewSessionForDevice(selectedDeviceId!),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Builder(
                builder: (context) {
                  if (selectedDeviceId == null) {
                    return const Center(
                      child: Text(
                        "선택된 기기가 없습니다.",
                        style: TextStyle(color: Colors.grey),
                      ),
                    );
                  }

                  final deviceSessions = sessions.values
                      .where((s) => s.deviceId == selectedDeviceId)
                      .toList();

                  if (deviceSessions.isEmpty) {
                    return const Center(
                      child: Text(
                        "생성된 대화방이 없습니다.",
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    );
                  }

                  return ListView.builder(
                    itemCount: deviceSessions.length,
                    itemBuilder: (context, index) {
                      final session = deviceSessions[index];
                      final isSelected = session.id == currentSessionId;
                      return Container(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Colors.blueAccent.withValues(alpha: 0.1)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListTile(
                          dense: true,
                          title: Text(
                            session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: isSelected ? Colors.blueAccent : Colors.black87,
                            ),
                          ),
                          onTap: () {
                            _selectSession(session.id, selectedDeviceId!);
                            Navigator.of(context).pop();
                          },
                          trailing: PopupMenuButton<String>(
                            icon: const Icon(Icons.more_horiz, size: 18),
                            onSelected: (value) {
                              if (value == 'rename') {
                                _renameSession(session.id, selectedDeviceId!, session.title);
                              } else if (value == 'delete') {
                                _deleteSession(session.id, selectedDeviceId!);
                              }
                            },
                            itemBuilder: (BuildContext context) =>
                                <PopupMenuEntry<String>>[
                                  const PopupMenuItem<String>(
                                    value: 'rename',
                                    child: Text('대화 이름 수정'),
                                  ),
                                  const PopupMenuItem<String>(
                                    value: 'delete',
                                    child: Text(
                                      '대화 삭제',
                                      style: TextStyle(color: Colors.red),
                                    ),
                                  ),
                                ],
                          ),
                        ),
                      );
                    },
                  );
                }
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.grey.shade300,
                child: const Icon(Icons.person, color: Colors.white),
              ),
              title: Text(
                api.email ?? "",
                style: const TextStyle(fontSize: 14),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.logout, color: Colors.redAccent),
                tooltip: '로그아웃',
                onPressed: () async {
                  await api.logout();
                  if (mounted) {
                    setState(() {
                      _hasSelectedDevice = false;
                    });
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                      (route) => false,
                    );
                  }
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildIntroScreen() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Colors.blueAccent, Colors.purpleAccent.shade100],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blueAccent.withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: const Icon(
                Icons.smart_toy_outlined,
                size: 54,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              "AI Desktop Pet Agent",
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.5,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "스마트한 에이전트와 함께 데스크톱 업무를 자동화하고\n자유롭게 대화를 나누어 보세요.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey.shade600,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 40),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "연결 가능한 데스크톱 기기",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black54,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _isLoadingDevices
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24.0),
                    child: CircularProgressIndicator(),
                  )
                : filteredDevices.isEmpty
                    ? Column(
                        children: [
                          const Text(
                            "등록된 PC 기기가 없습니다.",
                            style: TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 12),
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            onPressed: _loadDevices,
                          ),
                        ],
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: filteredDevices.length,
                        itemBuilder: (context, index) {
                          final device = filteredDevices[index];
                          final deviceId = device["device_id"] ?? "";
                          final deviceName = device["device_name"] ?? "Unknown Device";
                          final isOnline = device["is_online"] ?? false;

                          return Container(
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey.shade200),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.03),
                                  blurRadius: 6,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: ListTile(
                              leading: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: isOnline
                                      ? Colors.green.shade50
                                      : Colors.grey.shade100,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.desktop_windows_rounded,
                                  color: isOnline ? Colors.green : Colors.grey,
                                ),
                              ),
                              title: Text(
                                deviceName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black87,
                                ),
                              ),
                              subtitle: Text(
                                isOnline ? "온라인" : "오프라인",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isOnline ? Colors.green.shade700 : Colors.grey,
                                ),
                              ),
                              trailing: const Icon(
                                Icons.chevron_right_rounded,
                                color: Colors.grey,
                              ),
                              onTap: () => _selectDeviceAndGo(deviceId),
                            ),
                          );
                        },
                      ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyChatScreen() {
    final deviceName = selectedDeviceId != null
        ? (devices.firstWhere(
            (d) => d["device_id"] == selectedDeviceId,
            orElse: () => {"device_name": "선택된 기기"},
          )["device_name"] ?? "선택된 기기")
        : "선택된 기기";

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
        margin: const EdgeInsets.all(24.0),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.blueAccent.withValues(alpha: 0.08),
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
          ],
          border: Border.all(color: Colors.grey.shade100),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    Colors.blueAccent.withValues(alpha: 0.2),
                    Colors.purpleAccent.withValues(alpha: 0.1)
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: const Icon(
                Icons.chat_bubble_outline_rounded,
                size: 48,
                color: Colors.blueAccent,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              "새 채팅을 시작해보세요!",
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "연결된 기기: $deviceName\n새로운 대화를 만들어 에이전트와 이야기를 시작해 보세요.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 32),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                  colors: [Colors.blueAccent, Colors.purpleAccent],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blueAccent.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.add, size: 20),
                label: const Text(
                  "새 대화 시작하기",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: selectedDeviceId != null
                    ? () => _createNewSessionForDevice(selectedDeviceId!)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }



  @override
  Widget build(BuildContext context) {
    String titleText = "AI Agent";
    if (currentSessionId != null && sessions.containsKey(currentSessionId)) {
      titleText = sessions[currentSessionId!]!.title;
    } else if (_hasSelectedDevice && selectedDeviceId != null) {
      final deviceName = devices.firstWhere(
        (d) => d["device_id"] == selectedDeviceId,
        orElse: () => {"device_name": ""},
      )["device_name"] ?? "";
      titleText = deviceName.isNotEmpty ? "$deviceName 대화방" : "새 대화";
    }
    final showDrawer = _hasSelectedDevice;
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(titleText),
        automaticallyImplyLeading: showDrawer,
      ),
      drawer: showDrawer ? _buildDrawer(filteredDevices) : null,
      body: SafeArea(
        child: currentSessionId == null
            ? (_hasSelectedDevice ? _buildEmptyChatScreen() : _buildIntroScreen())
            : Column(
                children: [
                  if (pendingToolId != null)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.amber.shade300, width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.gpp_maybe_rounded, color: Colors.amber.shade800, size: 28),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      "⚠️ 위험 작업 실행 승인 요청",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                        color: Colors.amber.shade900,
                                      ),
                                    ),
                                    if (pendingToolName != null) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        "도구: $pendingToolName",
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                          color: Colors.black87,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (pendingMessage != null && pendingMessage!.isNotEmpty) ...[
                            Text(
                              pendingMessage!,
                              style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.4),
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (pendingToolArgs != null) ...[
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.amber.shade100),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    "전달 파라미터 (Arguments):",
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    pendingToolArgs is String
                                        ? pendingToolArgs
                                        : const JsonEncoder.withIndent('  ').convert(pendingToolArgs),
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      color: Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.redAccent,
                                  side: const BorderSide(color: Colors.redAccent, width: 1.5),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                ),
                                onPressed: () => _handleApprove(false),
                                child: const Text(
                                  "거절 (Reject)",
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                              const SizedBox(width: 12),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.amber.shade800,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                  elevation: 2,
                                ),
                                onPressed: () => _handleApprove(true),
                                child: const Text(
                                  "허용 (Approve)",
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
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
                                  horizontal: 16, vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (currentSessionId != null &&
                            sessions[currentSessionId!]?.currentNode.isNotEmpty == true) ...[
                          CircleAvatar(
                            radius: 24,
                            backgroundColor: Colors.redAccent,
                            child: IconButton(
                              color: Colors.white,
                              icon: const Icon(Icons.stop),
                              onPressed: () {
                                api.sendStop(currentSessionId!);
                                setState(() {
                                  sessions[currentSessionId!]!.currentNode = "";
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
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
