import 'package:flutter/material.dart';

import '../screens/loading_screen.dart';
import 'config.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    const iosBg = Color(0xFFF2F2F7);
    const iosSurface = Color(0xFFFFFFFF);
    const iosTextPrimary = Color(0xFF111111);
    const iosTextSecondary = Color(0xFF6D6D72);
    const iosOutline = Color(0xFFD1D1D6);

    final colorScheme = ColorScheme.fromSeed(
      seedColor: Colors.black,
      brightness: Brightness.light,
    ).copyWith(
      primary: Colors.black,
      secondary: Colors.black,
      surface: iosSurface,
      onSurface: iosTextPrimary,
      onSurfaceVariant: iosTextSecondary,
      outline: iosOutline,
      error: const Color(0xFFB00020),
    );

    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,

      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: iosBg,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: iosBg,
          foregroundColor: iosTextPrimary,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: iosSurface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: iosOutline),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.black,
            side: const BorderSide(color: iosOutline),
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return Colors.black;
            return Colors.white;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return Colors.black.withValues(alpha: 0.35);
            }
            return iosOutline;
          }),
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: Colors.black,
          thumbColor: Colors.black,
          inactiveTrackColor: iosOutline,
        ),
        dividerColor: iosOutline,
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 18, color: iosTextPrimary),
          bodyMedium: TextStyle(fontSize: 16, color: iosTextPrimary),
        ),
      ),

      // Initial boot screen
      home: const LoadingScreen(),
    );
  }
}
