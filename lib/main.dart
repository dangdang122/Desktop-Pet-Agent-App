import 'package:flutter/material.dart';
import 'screens/login_screen.dart';
import 'screens/chat_screen.dart';
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
  const AgentApp({super.key, this.api});

  final ApiService? api;

  @override
  Widget build(BuildContext context) {
    final apiService = api ?? ApiService();
    final bool isLoggedIn = !apiService.isTokenExpired();

    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'AI Agent',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          primary: Colors.blue,
          secondary: Colors.blue,
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: const CardThemeData(surfaceTintColor: Colors.transparent),
        drawerTheme: const DrawerThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: isLoggedIn
          ? ChatScreen(api: apiService)
          : LoginScreen(api: apiService),
    );
  }
}
