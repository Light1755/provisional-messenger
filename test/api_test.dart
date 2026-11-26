import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:provisional_messenger/data/api.dart';
import 'package:provisional_messenger/data/models.dart';
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
      expect(
        Api.mapPostgrest(dbError('conversation_storage_full', '22023')).message,
        contains('storage limit'),
      );
    });

    test('maps message edit, delete, and reaction errors', () {
      final notFound = Api.mapPostgrest(dbError('message_not_found', 'P0001'));
      expect(notFound.code, 'message_not_found');
      expect(notFound.message, contains('no longer available'));

      final cannotEdit = Api.mapPostgrest(dbError('cannot_edit', 'P0001'));
      expect(cannotEdit.code, 'cannot_edit');
      expect(cannotEdit.message, contains('edited'));

      final cannotDelete = Api.mapPostgrest(dbError('cannot_delete', 'P0001'));
      expect(cannotDelete.code, 'cannot_delete');
      expect(cannotDelete.message, contains('deleted'));

      final invalid = Api.mapPostgrest(dbError('invalid_reaction', '22023'));
      expect(invalid.code, 'invalid_reaction');
      expect(invalid.message, contains('not supported'));

      final duplicate = Api.mapPostgrest(dbError('already_reacted', 'P0001'));
      expect(duplicate.code, 'already_reacted');
      expect(duplicate.message, contains('already'));

      final missing = Api.mapPostgrest(dbError('reaction_not_found', 'P0001'));
      expect(missing.code, 'reaction_not_found');
      expect(missing.message, contains('already removed'));
    });

    test('keeps unexpected messages intact', () {
      final error = Api.mapPostgrest(dbError('something unexpected'));
      expect(error.message, 'something unexpected');
    });
  });

  group('message parsing', () {
    test('parses reply, delivery, tombstone, and reaction fields', () {
      final row = <String, dynamic>{
        'message_id': 'm-1',
        'conversation_id': 'c-1',
        'sender_id': 'u-1',
        'sender_username': 'alice',
        'sender_accent': 12,
        'kind': 'text',
        'body': null,
        'client_id': 'cl-1',
        'created_at': '2026-01-01T10:00:00Z',
        'is_mine': false,
        'is_read': true,
        'reply_to_id': 'm-0',
        'reply_to_body': '  original   text  ',
        'reply_to_kind': 'text',
        'reply_to_sender_id': 'u-2',
        'reply_to_sender_username': 'bob',
        'edited_at': null,
        'deleted_at': '2026-01-01T10:05:00Z',
        'delivered_at': '2026-01-01T10:01:00Z',
        'reactions': [
          {'emoji': '👍', 'user_id': 'u-2', 'username': 'bob', 'accent': 7},
          {'emoji': '❤️', 'user_id': 'u-3', 'username': 'carol', 'accent': 9},
        ],
      };

      final message = ChatMessage.fromJson(Api.rows([row]).single);

      expect(message.replyToId, 'm-0');
      expect(message.replyToBody, '  original   text  ');
      expect(message.replyToKind, 'text');
      expect(message.replyToSenderId, 'u-2');
      expect(message.replyToSenderUsername, 'bob');
      expect(message.isReply, isTrue);
      expect(message.replyPreview, 'original text');
      expect(message.deletedAt, isNotNull);
      expect(message.isDeleted, isTrue);
      expect(message.deliveredAt, isNotNull);
      expect(message.editedAt, isNull);
      expect(message.hasReactions, isTrue);
      expect(message.reactions, hasLength(2));
      expect(message.reactions.first.messageId, 'm-1');
      expect(message.reactions.first.emoji, '👍');
      expect(message.reactions.first.userId, 'u-2');
      expect(message.reactions.first.username, 'bob');
      expect(message.reactions.first.accent, 7);
      // Parsed rows keep the legacy settled status for existing UI logic.
      expect(message.status, MessageStatus.sent);
    });

    test('realtime rows tolerate missing fields and copyWith updates them', () {
      final message = ChatMessage.fromRecord(
        {
          'id': 'm-2',
          'conversation_id': 'c-1',
          'sender_id': 'u-2',
          'kind': 'file',
          'attachment_name': 'notes.txt',
          'client_id': 'cl-2',
          'created_at': '2026-01-01T10:00:00Z',
        },
        myId: 'u-1',
        myUsername: 'alice',
        myAccent: 3,
        partnerUsername: 'bob',
        partnerAccent: 4,
      );

      expect(message.replyToId, isNull);
      expect(message.editedAt, isNull);
      expect(message.deletedAt, isNull);
      expect(message.deliveredAt, isNull);
      expect(message.reactions, isEmpty);
      expect(message.hasReactions, isFalse);
      expect(message.isDeleted, isFalse);
      expect(message.replyPreview, '');

      final edited = message.copyWith(
        body: 'new body',
        status: MessageStatus.delivered,
        editedAt: DateTime.utc(2026, 1, 1, 10, 10),
        deliveredAt: DateTime.utc(2026, 1, 1, 10, 2),
        replyToId: 'm-1',
        replyToBody: 'quoted',
        replyToKind: 'voice',
        replyToSenderId: 'u-1',
        replyToSenderUsername: 'alice',
        reactions: const [
          MessageReaction(emoji: '👍', userId: 'u-1', username: 'alice'),
        ],
      );

      expect(edited.body, 'new body');
      expect(edited.status, MessageStatus.delivered);
      expect(edited.editedAt, isNotNull);
      expect(edited.deliveredAt, isNotNull);
      expect(edited.isReply, isTrue);
      expect(edited.replyPreview, 'Voice note');
      expect(edited.hasReactions, isTrue);
      expect(edited.reactions.single.emoji, '👍');
      expect(message.body, isNull);
      expect(message.reactions, isEmpty);
    });

    test('parses reactions encoded as a JSON string', () {
      final message = ChatMessage.fromJson({
        'message_id': 'm-3',
        'conversation_id': 'c-1',
        'sender_id': 'u-1',
        'client_id': 'cl-3',
        'created_at': '2026-01-01T10:00:00Z',
        'reactions': jsonEncode([
          {'emoji': '🎉', 'user_id': 'u-2', 'username': 'bob'},
        ]),
      });
      expect(message.reactions.single.messageId, 'm-3');
      expect(message.reactions.single.emoji, '🎉');
    });

    test('parses partner presence rows', () {
      final presence = PartnerPresence.fromJson({
        'user_id': 'u-2',
        'last_seen': '2026-01-01T10:00:00Z',
        'is_online': true,
      });
      expect(presence.userId, 'u-2');
      expect(presence.lastSeen, isNotNull);
      expect(presence.isOnline, isTrue);
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

  group('session classification', () {
    test('recognizes definite session failures only', () {
      expect(
        Api.isDefiniteSessionError(
          Api.mapAuth(const AuthException('User not found')),
        ),
        isTrue,
      );
      expect(
        Api.isDefiniteSessionError(ApiException('expired', code: '401')),
        isTrue,
      );
      expect(
        Api.isDefiniteSessionError(
          Api.mapPostgrest(dbError('something about a timeout')),
        ),
        isFalse,
      );
      expect(
        Api.isDefiniteSessionError(
          ApiException('The conversation has ended'),
        ),
        isFalse,
      );
      expect(
        Api.isDefiniteSessionError(
          Api.mapPostgrest(dbError('not_authenticated', '42501')),
        ),
        isFalse,
      );
      expect(
        Api.isDefiniteSessionError(ApiException('Forbidden', code: '403')),
        isFalse,
      );
    });

    test('maps ended auth sessions to a retryable message', () {
      final error = Api.mapAuth(
        const AuthException('Auth session missing', code: 'session_not_found'),
      );
      expect(error.code, 'session_expired');
      expect(error.message, contains('Tap Retry'));
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

    test('reads burn results from old and new servers', () {
      expect(Api.burnResultSucceeded(null), isTrue);
      expect(Api.burnResultSucceeded({'content_deleted': true}), isTrue);
      expect(
        Api.burnResultSucceeded([
          {'content_deleted': true, 'auth_deleted': false},
        ]),
        isTrue,
      );
      expect(Api.burnResultSucceeded({'content_deleted': false}), isFalse);
    });

    test('attachment decoding ignores Postgres base64 line breaks', () {
      final original = List<int>.generate(240, (i) => i);
      final encoded = base64Encode(original);
      final wrapped = encoded.replaceAllMapped(
        RegExp(r'.{1,76}'),
        (match) => '${match.group(0)}\n',
      );
      expect(Api.decodeAttachmentBase64(wrapped), original);
    });
  });
}
