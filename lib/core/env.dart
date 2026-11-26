/// Compile-time and runtime configuration.
///
/// The Supabase URL/key can be baked in at build time:
///   flutter build apk --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
///
/// If they are not baked in, the app shows a setup screen and stores the values
/// locally. This makes the first-run APK usable without rebuilding.
class Env {
  Env._();

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY');

  static const String appName = 'Provisional Messenger';
  static const String appVersion = '1.1.0';

  /// Hard cap for one file/voice note. The database enforces the same limit.
  static const int maxAttachmentBytes = 5 * 1024 * 1024;

  static const int defaultExpirySeconds = 24 * 60 * 60;

  /// 1 hour, 6 hours, 24 hours, 3 days, 7 days.
  static const List<int> expiryOptions = [
    60 * 60,
    6 * 60 * 60,
    24 * 60 * 60,
    3 * 24 * 60 * 60,
    7 * 24 * 60 * 60,
  ];

  static bool get hasBakedConfig =>
      supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;
}
