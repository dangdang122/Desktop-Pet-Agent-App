import 'package:flutter/material.dart';
import 'screens/login_screen.dart';
import 'services/api_service.dart';
import 'services/device_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 기기 정보 및 이전 로그인 세션 로드
  await DeviceService().init();
  await ApiService().loadCredentials();

  runApp(const AgentApp());
}

class AgentApp extends StatelessWidget {
  const AgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Agent',
      home: const LoginScreen(),
    );
  }
}