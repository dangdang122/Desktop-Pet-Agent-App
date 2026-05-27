import 'dart:convert';
import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() async {
  final String userId = "00000000-0000-0000-0000-000000000000";
  final String wsUrl = "wss://petagent.aikopo.net/ws/$userId";

  print("Test: Connecting and registering as app with client_id...");
  final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
  var isClosed = false;
  channel.stream.listen(
    (data) => print("[Recv] $data"),
    onError: (err) => print("[Error] $err"),
    onDone: () {
      print("[Closed]");
      isClosed = true;
    },
  );
  
  final regMessage = {
    "type": "register",
    "payload": {
      "role": "app",
      "client_id": "test_app_1"
    }
  };
  print("Sending reg message...");
  channel.sink.add(jsonEncode(regMessage));
  
  await Future.delayed(Duration(seconds: 4));
  if (!isClosed) {
    print("Success! Connection stayed open!");
    channel.sink.close();
  }
}
