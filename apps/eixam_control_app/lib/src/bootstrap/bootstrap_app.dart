import 'package:flutter/material.dart';

import 'sdk_bootstrap_screen.dart';

class BootstrapApp extends StatelessWidget {
  const BootstrapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SdkBootstrapScreen(),
    );
  }
}
