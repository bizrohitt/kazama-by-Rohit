/// App theme (Task U3) — deliberately plain Material 3, no custom fonts.
///
/// The one design decision with a functional reason: a POS is used in daylight,
/// by someone standing, often with wet or gloved hands. So the base text size is
/// bumped and touch targets are large, and NOTHING relies on colour alone (a
/// "low stock" row is labelled, not just orange). Everything else — brand colour,
/// logo, animation — is Z1 work after every feature passes (R5).
library;

import 'package:flutter/material.dart';

import '../core/money/money.dart';

class KazamaTheme {
  KazamaTheme._();

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0F6A4F));
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.standard,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: const TextTheme(
        bodyLarge: TextStyle(fontSize: 17),
        bodyMedium: TextStyle(fontSize: 15),
        titleLarge: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
        labelLarge: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(96, 52),
          textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(88, 48)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        // A zero margin is the point: cards here are layout containers, not
        // shadows, and the default inset reads as "detached" on a POS grid.
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      listTileTheme: const ListTileThemeData(minVerticalPadding: 12),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarBehavior: SnackBarBehavior.floating,
    );
  }
}

/// Money on screen is always the same shape, and it is the number a customer
/// disputes — so it gets one helper instead of `toStringAsFixed(2)` at 40 sites.
String rupeesText(Money m) => '₹${m.toCompactString()}';

