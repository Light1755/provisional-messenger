import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:provisional_messenger/core/format.dart';
import 'package:provisional_messenger/core/supabase_key.dart';
import 'package:provisional_messenger/core/username.dart';

String _fakeJwt(Map<String, dynamic> payload) {
  String part(Object value) => base64Url
      .encode(utf8.encode(jsonEncode(value)))
      .replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(payload)}.signature';
}

void main() {
  group('supabase keys', () {
    test('rejects service-role JWTs', () {
      expect(
        isServerOnlySupabaseKey(_fakeJwt({'role': 'service_role'})),
        isTrue,
      );
    });

    test('rejects sb_secret_ and personal access tokens', () {
      expect(isServerOnlySupabaseKey('sb_secret_abc123'), isTrue);
      expect(isServerOnlySupabaseKey('sbp_abc123'), isTrue);
    });

    test('allows anon and publishable keys', () {
      expect(isServerOnlySupabaseKey(_fakeJwt({'role': 'anon'})), isFalse);
      expect(isServerOnlySupabaseKey('sb_publishable_abc123'), isFalse);
      expect(isServerOnlySupabaseKey(''), isFalse);
      expect(isServerOnlySupabaseKey('not-a-jwt'), isFalse);
    });
  });

  group('usernames', () {
    test('normalizes case and punctuation', () {
      expect(normalizeUsername('  Maya_01! '), 'maya_01');
    });

    test('accepts 3 to 24 letters, numbers, and underscores', () {
      expect(usernameLooksValid('maya_01'), isTrue);
      expect(usernameLooksValid('ab'), isFalse);
      expect(usernameLooksValid('has space'), isFalse);
      expect(usernameLooksValid('admin'), isFalse);
    });
  });

  group('formatting', () {
    test('formats voice durations', () {
      expect(formatDuration(0), '0:00');
      expect(formatDuration(9500), '0:10');
      expect(formatDuration(61000), '1:01');
      expect(formatDuration(3661000), '1:01:01');
    });

    test('labels expiry choices', () {
      expect(expiryLabel(86400), '24 hours');
      expect(expiryLabel(604800), '7 days');
      expect(expiryLabel(5400), '2 hours');
    });

    test('formats remaining time compactly', () {
      expect(formatRemaining(const Duration(seconds: 30)), '30s');
      expect(formatRemaining(const Duration(minutes: 5, seconds: 12)), '5m 12s');
      expect(formatRemaining(const Duration(hours: 3, minutes: 4)), '3h 4m');
    });
  });
}
