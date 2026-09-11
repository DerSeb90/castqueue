import 'package:flutter/material.dart';

/// Warm amber accent on near-black surfaces.
const kAccent = Color(0xFFF5A524);

ThemeData buildDarkTheme() {
  const surface = Color(0xFF0E0E10);
  const surfaceHigh = Color(0xFF1A1A1E);
  final scheme = ColorScheme.fromSeed(
    seedColor: kAccent,
    brightness: Brightness.dark,
    primary: kAccent,
    onPrimary: const Color(0xFF1B1200),
    secondary: const Color(0xFFFFC66D),
    surface: surface,
    onSurface: const Color(0xFFECECEE),
    surfaceContainerLowest: const Color(0xFF09090B),
    surfaceContainerLow: const Color(0xFF131316),
    surfaceContainer: surfaceHigh,
    surfaceContainerHigh: const Color(0xFF212126),
    surfaceContainerHighest: const Color(0xFF2A2A30),
    outlineVariant: const Color(0xFF2E2E34),
    error: const Color(0xFFFF6B6B),
  );
  return _base(scheme).copyWith(
    scaffoldBackgroundColor: surface,
    canvasColor: surface,
  );
}

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kAccent,
    brightness: Brightness.light,
    primary: const Color(0xFFB86E00),
    surface: const Color(0xFFFAF8F4),
  );
  return _base(scheme);
}

ThemeData _base(ColorScheme scheme) {
  final isDark = scheme.brightness == Brightness.dark;
  final text = Typography.material2021(platform: TargetPlatform.windows).black.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: scheme.brightness,
    fontFamily: 'Segoe UI',
    textTheme: text.copyWith(
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.3),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.7),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: isDark ? 0.6 : 1)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      iconColor: scheme.onSurfaceVariant,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      indicatorColor: scheme.primary.withValues(alpha: 0.18),
      selectedIconTheme: IconThemeData(color: scheme.primary),
      selectedLabelTextStyle: text.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
      unselectedLabelTextStyle: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
      labelType: NavigationRailLabelType.all,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      indicatorColor: scheme.primary.withValues(alpha: 0.18),
      surfaceTintColor: Colors.transparent,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => text.labelSmall?.copyWith(
          letterSpacing: 0.2,
          color: s.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide(color: scheme.outlineVariant),
      backgroundColor: scheme.surfaceContainer,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      showDragHandle: true,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      backgroundColor: scheme.surfaceContainerHighest,
      contentTextStyle: TextStyle(color: scheme.onSurface),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      thumbColor: scheme.primary,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.6), space: 1),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? scheme.onPrimary : null,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
  );
}
