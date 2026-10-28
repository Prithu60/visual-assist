import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'screens/home_screen.dart';

late List<CameraDescription> _cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Permission.camera.request();
  try {
    _cameras = await availableCameras();
  } catch (_) {
    _cameras = <CameraDescription>[];
  }
  runApp(const VisualAssistApp());
}

class VisualAssistApp extends StatelessWidget {
  const VisualAssistApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Visual Assist',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: ThemeMode.dark,
      home: HomeScreen(cameras: _cameras),
      debugShowCheckedModeBanner: false,
    );
  }
}