import 'package:flutter/material.dart';
import 'screens/chat_screen.dart';

void main() {
  runApp(const AgentApp());
}

class AgentApp extends StatelessWidget {
  const AgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Agent',
      home: ChatScreen(),
    );
  }
} 