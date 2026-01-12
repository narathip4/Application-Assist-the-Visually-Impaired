import 'package:flutter/material.dart';
import 'app/app.dart';

void main() async {
  // Ensure Flutter engine is ready (camera / isolate / plugins)
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const App());
}
