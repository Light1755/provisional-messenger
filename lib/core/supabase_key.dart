import 'dart:convert';

/// Supabase has two classes of API keys:
///
/// * client keys (`anon` JWT or `sb_publishable_...`), which are safe to ship
///   because database rules decide what they can do;
/// * server keys (`service_role` JWT or `sb_secret_...`), which bypass those
///   rules and must never be put in an app.
///
/// Anyone can extract a key from a built app, so a server key in a build is a
/// full database compromise. These checks reject the known secret formats
/// before the key is ever used.
bool isServerOnlySupabaseKey(String key) {
  final value = key.trim();
  if (value.isEmpty) return false;

  final lower = value.toLowerCase();
  if (lower.startsWith('sb_secret_')) return true;
  // Supabase personal access tokens can manage the whole account.
  if (lower.startsWith('sbp_')) return true;

  return _jwtRole(value) == 'service_role';
}

String? _jwtRole(String key) {
  final parts = key.split('.');
  if (parts.length != 3) return null;
  try {
    var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
    payload = payload.padRight((payload.length + 3) ~/ 4 * 4, '=');
    final decoded = jsonDecode(utf8.decode(base64Decode(payload)));
    if (decoded is Map && decoded['role'] is String) {
      return decoded['role'] as String;
    }
  } catch (_) {
    // Not a decodable JWT. The connection test will report the real problem.
  }
  return null;
}
