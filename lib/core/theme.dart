import 'package:flutter/material.dart';

// -----------------------------------------------------------------------------
// Palette — one calm sea-green accent over warm neutrals. Flat surfaces,
// hairline borders, soft shadows. No neon gradients, no glow orbs.
// -----------------------------------------------------------------------------

const kAccent = Color(0xFF3D8B7D);
const kAccentDeep = Color(0xFF2F7264);
const kDanger = Color(0xFFD96A6A);
const kRecordingRed = Color(0xFFE06B61);
const kOnlineGreen = Color(0xFF5FB98C);

const kBgLight = Color(0xFFF5F6F3);
const kCardLight = Color(0xFFFFFFFF);
const kFillLight = Color(0xFFF0F2EE);
const kBgDark = Color(0xFF101513);
const kCardDark = Color(0xFF1A211E);
const kFillDark = Color(0xFF222A26);

const kAvatarColors = <Color>[
  Color(0xFF8F7BB8),
  Color(0xFF5E9AA0),
  Color(0xFFC98F6E),
  Color(0xFF7C93B8),
  Color(0xFF5FA98C),
  Color(0xFFC97B6E),
];

Color avatarColorFor(int accent, [String? username]) {
  if (accent >= 0 && accent < kAvatarColors.length) {
    return kAvatarColors[accent];
  }
  final hash = (username ?? '').codeUnits.fold<int>(0, (a, b) => a + b);
  return kAvatarColors[hash % kAvatarColors.length];
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: kAccent,
    brightness: brightness,
    surface: dark ? kCardDark : kCardLight,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? kBgDark : kBgLight,
    fontFamily: 'SF Pro Display',
    fontFamilyFallback: const ['SF Pro Text', 'Segoe UI', 'Roboto'],
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -.4,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? kFillDark : kFillLight,
      hintStyle: TextStyle(color: scheme.onSurface.withValues(alpha: .4)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: kAccent, width: 1.2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: kDanger, width: 1.1),
      ),
    ),
    dividerColor: scheme.onSurface.withValues(alpha: .08),
    dividerTheme: DividerThemeData(
      color: scheme.onSurface.withValues(alpha: .08),
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF252D29) : const Color(0xFF22302C),
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? kCardDark : kCardLight,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: dark ? kCardDark : kCardLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? kCardDark : kCardLight,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? Colors.white : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? kAccent : null,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: kAccent),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: kAccent),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.onSurface.withValues(alpha: .12)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    ),
  );
}
