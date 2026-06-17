import 'dart:io';
import 'dart:math';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeviceService {
  static const String _keyDeviceId = 'device_id';
  static const String _keyDeviceType = 'device_type';
  static const String _keyDeviceName = 'device_name';

  static final DeviceService _instance = DeviceService._internal();
  factory DeviceService() => _instance;
  DeviceService._internal();

  String? _deviceId;
  String? _deviceType;
  String? _deviceName;

  String get deviceId => _deviceId ?? 'unknown-device-id';
  String get deviceType => _deviceType ?? 'Phone';
  String get deviceName => _deviceName ?? 'Unknown Device';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Get or Create device_id (UUID)
    _deviceId = prefs.getString(_keyDeviceId);
    if (_deviceId == null) {
      _deviceId = _generateUuidV4();
      await prefs.setString(_keyDeviceId, _deviceId!);
    }

    // 2. Get device_type
    if (Platform.isAndroid || Platform.isIOS) {
      _deviceType = 'Phone';
    } else {
      _deviceType = 'PC';
    }
    await prefs.setString(_keyDeviceType, _deviceType!);

    // 3. Get device_name
    _deviceName = prefs.getString(_keyDeviceName);
    if (_deviceName == null) {
      _deviceName = await _fetchDeviceName();
      await prefs.setString(_keyDeviceName, _deviceName!);
    }
  }

  Future<String> _fetchDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        return androidInfo.model; // e.g. "SM-G991N"
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        return iosInfo.name; // e.g. "iPhone 14"
      } else if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        return windowsInfo.computerName;
      } else if (Platform.isMacOS) {
        final macosInfo = await deviceInfo.macOsInfo;
        return macosInfo.computerName;
      } else if (Platform.isLinux) {
        final linuxInfo = await deviceInfo.linuxInfo;
        return linuxInfo.name;
      }
    } catch (e) {
      // ignore
    }
    return 'Unknown Device';
  }

  String _generateUuidV4() {
    final random = Random.secure();
    String hexDigit(int value) => value.toRadixString(16);
    
    final buffer = StringBuffer();
    for (var i = 0; i < 36; i++) {
      if (i == 8 || i == 13 || i == 18 || i == 23) {
        buffer.write('-');
      } else if (i == 14) {
        buffer.write('4');
      } else if (i == 19) {
        buffer.write(hexDigit((random.nextInt(4) + 8)));
      } else {
        buffer.write(hexDigit(random.nextInt(16)));
      }
    }
    return buffer.toString();
  }
}
