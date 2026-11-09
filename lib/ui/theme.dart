import 'package:flutter/material.dart';

/// FORScan Lite-style dark palette.
class AppColors {
  static const bg = Color(0xFF1E2026);
  static const tile = Color(0xFF2E3138);
  static const tileDanger = Color(0xFF4A2E2E);
  static const pane = Color(0xFF15161A);
  static const text = Color(0xFFE8E8E8);
  static const textDim = Color(0xFFAAAAAA);
  static const accent = Color(0xFF4A90D9);
  static const warn = Color(0xFFD94A4A);
  static const ok = Color(0xFF7ED37E);
  static const connect = Color(0xFF111111);
  static const disconnect = Color(0xFF555555);
  static const badge = Color(0xFFD9A54A);
}

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.accent,
      secondary: AppColors.accent,
      surface: AppColors.tile,
      error: AppColors.warn,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: AppColors.text,
      elevation: 0,
      centerTitle: true,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.tile,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      filled: true,
      fillColor: AppColors.pane,
    ),
  );
}

const TextStyle monoStyle = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Courier', 'monospace'],
  fontSize: 11.5,
  height: 1.35,
  color: AppColors.text,
);
