import 'package:flutter_test/flutter_test.dart';
import 'package:provisional_messenger/data/api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

PostgrestException dbError(String message, [String? code]) =>
    PostgrestException(message: message, code: code);

void main() {
  group('database error mapping', () {
    test('recognizes an orphaned anonymous session', () {
      final error = Api.mapPostgrest(
        dbError(
          'insert or update on table "profiles" violates foreign key '
          'constraint "profiles_id_fkey"',
          '23503',
        ),
      );
      expect(error.code, 'orphan_session');
      expect(error.message, contains('Reconnecting'));
    });

    test('maps profile and username conflicts to actionable messages', () {
      expect(
        Api.mapPostgrest(dbError('username_taken', 'P0001')).message,
        contains('already taken'),
      );
      expect(
        Api.mapPostgrest(dbError('profile_exists', 'P0001')).raw,
        contains('profile_exists'),
      );
      expect(
        Api.mapPostgrest(dbError('profile_not_found', 'P0002')).code,
        'profile_not_found',
      );
    });

    test('maps ended conversations and attachment errors', () {
      expect(
        Api.mapPostgrest(dbError('conversation_not_found', 'P0001')).message,
        contains('ended'),
      );
      expect(
        Api.mapPostgrest(dbError('invalid_attachment', '22023')).message,
        contains('could not be read'),
      );
      expect(
        Api.mapPostgrest(dbError('message_too_long', '22023')).message,
        contains('4,000'),
      );
    });

    test('keeps unexpected messages intact', () {
      final error = Api.mapPostgrest(dbError('something unexpected'));
      expect(error.message, 'something unexpected');
    });
  });

  group('auth error mapping', () {
    test('explains disabled anonymous sign-ins', () {
      expect(
        Api.mapAuth(
          const AuthException(
            'Anonymous sign-ins are disabled',
            code: 'anonymous_provider_disabled',
          ),
        ).message,
        contains('Anonymous sign-ins'),
      );
    });

    test('explains rate limits', () {
      expect(
        Api.mapAuth(const AuthException('Too many requests')).message,
        contains('Wait a minute'),
      );
    });
  });

  group('RPC response parsing', () {
    test('reads the first row from maps and lists', () {
      expect(Api.firstMap({'id': 'a'})?['id'], 'a');
      expect(Api.firstMap([{'id': 'b'}])?['id'], 'b');
      expect(Api.firstMap(const []), isNull);
    });

    test('normalizes row-shaped responses', () {
      expect(Api.rows([{'id': 'a'}, {'id': 'b'}]).length, 2);
      expect(Api.rows({'id': 'a'}).single['id'], 'a');
      expect(Api.rows('not rows'), isEmpty);
    });
  });
}
