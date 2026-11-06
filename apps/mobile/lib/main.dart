import 'dart:async';

import 'package:flutter/material.dart';

import 'services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final services = SousServices();
  unawaited(services.auth.restore());
  runApp(MainApp(services: services));
}

class MainApp extends StatelessWidget {
  const MainApp({super.key, required this.services});

  final SousServices services;

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(body: Center(child: Text('Hello World!'))),
    );
  }
}
