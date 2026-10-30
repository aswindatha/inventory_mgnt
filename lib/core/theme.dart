import 'package:flutter/material.dart';

/// Layout breakpoints for the web build, where the same app runs on a phone-
/// sized window and a desktop monitor.
class AppLayout {
  const AppLayout._();

  /// The widest the app column ever grows; beyond this it stays centered so
  /// forms and lists remain readable instead of stretching edge to edge.
  static const double maxContentWidth = 1024;

  /// Below this the shell keeps the mobile bottom NavigationBar; at or above
  /// it swaps to a side NavigationRail.
  static const double wideNavBreakpoint = 720;
}

/// Semantic status colors, resolved per brightness.
///
/// Material's ColorScheme has no "success/warning" roles, so these ride along
/// as a theme extension — one token name, tuned values for each mode. Dark
/// variants are lighter and more saturated so chips and badges stay readable
/// on dark surfaces.
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.primary,
    required this.success,
    required this.warning,
    required this.danger,
    required this.neutral,
  });

  final Color primary;
  final Color success;
  final Color warning;
  final Color danger;
  final Color neutral;

  static const light = AppColors(
    primary: AppTheme._seed,
    success: Color(0xFF15803D),
    warning: Color(0xFFB45309),
    danger: Color(0xFFB91C1C),
    neutral: Color(0xFF6B7280),
  );

  static const dark = AppColors(
    primary: Color(0xFF6E9CF8),
    success: Color(0xFF34C077),
    warning: Color(0xFFF59E0B),
    danger: Color(0xFFEF5B68),
    neutral: Color(0xFF9CA3AF),
  );

  @override
  AppColors copyWith({
    Color? primary,
    Color? success,
    Color? warning,
    Color? danger,
    Color? neutral,
  }) {
    return AppColors(
      primary: primary ?? this.primary,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      neutral: neutral ?? this.neutral,
    );
  }

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      primary: Color.lerp(primary, other.primary, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
    );
  }
}

/// `context.appColors.warning` reads the brightness-correct status color.
extension AppColorsX on BuildContext {
  AppColors get appColors => Theme.of(this).extension<AppColors>()!;
}

/// Single source of truth for the app's visual language.
class AppTheme {
  const AppTheme._();

  static const Color _seed = Color(0xFF1F6FEB);

  /// Light-palette status colors. Prefer `context.appColors` in widgets — it
  /// resolves the dark variant automatically. These constants remain for
  /// const contexts and tests.
  static const Color primary = _seed;
  static const Color warning = Color(0xFFB45309);
  static const Color danger = Color(0xFFB91C1C);
  static const Color success = Color(0xFF15803D);
  static const Color neutral = Color(0xFF6B7280);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    return _base(scheme, AppColors.light);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    return _base(scheme, AppColors.dark);
  }

  static ThemeData _base(ColorScheme scheme, AppColors colors) => ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    extensions: [colors],
    scaffoldBackgroundColor: scheme.surfaceContainerLowest,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 2,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
  );
}
