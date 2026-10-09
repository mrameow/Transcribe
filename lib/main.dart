import 'package:flutter/material.dart';

import 'ui/home_page.dart';

void main() {
  runApp(const TranscribeApp());
}

class TranscribeApp extends StatelessWidget {
  const TranscribeApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF5B45E6);
    return MaterialApp(
      title: 'Transcribe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
