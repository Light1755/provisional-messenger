import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../core/server_clock.dart';
import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.code, this.raw});

  final String message;
  final String? code;
  final String? raw;

  @override
  String toString() => message;
}

class Api {
  Api(this.client);

  final SupabaseClient client;

  SupabaseClient get _c => client;

  // Supabase's HTTP client has no default deadline. Without these, a dropped
  // connection can leave a screen waiting forever. Sends are idempotent through
  // client_id, so a timeout followed by retry is safe.
  static const _readTimeout = Duration(seconds: 20);
  static const _writeTimeout = Duration(seconds: 30);
  static const _attachmentTimeout = Duration(seconds: 60);

  Future<Profile?> getMyProfile() => _guard(() async {
        final res = await _c.rpc('get_my_profile').timeout(_readTimeout);
        final map = _firstMap(res);
        // Some PostgREST versions serialize a missing composite as a row of
        // nulls instead of null. Treat that as no profile.
        if (map == null || map['id'] is! String) return null;
        return Profile.fromJson(map);
      });

  Future<Profile> createProfile(String username) => _guard(() async {
        final res = await _c.rpc('create_profile',
            params: {'p_username': username}).timeout(_writeTimeout);
        final map = _firstMap(res);
        if (map == null) {
          throw ApiException('Your username could not be created. Try again.');
        }
        return Profile.fromJson(map);
      });

  Future<void> burnProfile() => _guard(() async {
        final res = await _c.rpc('burn_profile').timeout(_writeTimeout);
        if (!burnResultSucceeded(res)) {
          throw ApiException(
            'The profile could not be burned. Try again.',
            code: 'burn_incomplete',
          );
        }
      });

  Future<List<SearchResult>> searchProfiles(String query) => _guard(() async {
        final res = await _c.rpc('search_profiles',
            params: {'p_query': query}).timeout(_readTimeout);
        return _rows(res).map(SearchResult.fromJson).toList(growable: false);
      });

  Future<List<ConversationSummary>> listConversations() => _guard(() async {
        final res = await _c.rpc('list_conversations').timeout(_readTimeout);
        final rows = _rows(res);
        _observeServerTime(rows);
        return rows
            .map(ConversationSummary.fromJson)
            .toList(growable: false);
      });

  Future<ConversationDetail?> getConversation(String conversationId) =>
      _guard(() async {
        final res = await _c.rpc(
          'get_conversation',
          params: {'p_conversation_id': conversationId},
        ).timeout(_readTimeout);
        final map = _firstMap(res);
        if (map != null) _observeServerTime([map]);
        return map == null ? null : ConversationDetail.fromJson(map);
      });

  Future<String> startConversation(
    String otherUserId, {
    int expirySeconds = Env.defaultExpirySeconds,
  }) =>
      _guard(() async {
        final res = await _c.rpc(
          'start_conversation',
          params: {
            'p_other_user_id': otherUserId,
            'p_expiry_seconds': expirySeconds,
          },
        ).timeout(_writeTimeout);
        if (res is String) return res;
        if (res is List && res.isNotEmpty) {
          final first = res.first;
          if (first is String) return first;
          if (first is Map && first.values.isNotEmpty) {
            final value = first.values.first;
            if (value is String) return value;
          }
        }
        if (res is Map && res.values.isNotEmpty) {
          final value = res.values.first;
          if (value is String) return value;
        }
        throw ApiException('The conversation could not be started.');
      });

  Future<DateTime> setConversationExpiry(
    String conversationId,
    int expirySeconds,
  ) =>
      _guard(() async {
        final res = await _c.rpc(
          'set_conversation_expiry',
          params: {
            'p_conversation_id': conversationId,
            'p_expiry_seconds': expirySeconds,
          },
        ).timeout(_writeTimeout);
        final raw = res is String ? res : res?.toString();
        if (raw == null) throw ApiException('The timer could not be changed.');
        return DateTime.parse(raw).toLocal();
      });

  Future<void> markConversationRead(String conversationId) => _guard(() async {
        await _c.rpc(
          'mark_conversation_read',
          params: {'p_conversation_id': conversationId},
        ).timeout(_readTimeout);
      });

  Future<void> burnConversation(String conversationId) => _guard(() async {
        await _c.rpc(
          'burn_conversation',
          params: {'p_conversation_id': conversationId},
        ).timeout(_writeTimeout);
      });

  Future<List<ChatMessage>> getMessages(
    String conversationId, {
    DateTime? before,
    String? beforeId,
    int limit = 100,
  }) =>
      _guard(() async {
        final res = await _c.rpc(
          'get_messages',
          params: {
            'p_conversation_id': conversationId,
            'p_before': before?.toUtc().toIso8601String(),
            'p_before_id': beforeId,
            'p_limit': limit,
          },
        ).timeout(_readTimeout);
        return _rows(res).map(ChatMessage.fromJson).toList(growable: false);
      });

  Future<ChatMessage> sendText({
    required String conversationId,
    required String clientId,
    required String body,
    required Profile me,
    String? replyToId,
  }) =>
      _guard(() async {
        final params = <String, dynamic>{
          'p_conversation_id': conversationId,
          'p_client_id': clientId,
          'p_body': body,
        };
        // Omit the key when there is no quote: older servers do not know the
        // parameter, and passing an empty id is never a valid reply target.
        if (replyToId != null && replyToId.isNotEmpty) {
          params['p_reply_to_id'] = replyToId;
        }
        final res = await _c.rpc(
          'send_text_message',
          params: params,
        ).timeout(_writeTimeout);
        final map = _firstMap(res);
        if (map == null) throw ApiException('The message could not be sent.');
        return _messageFromRecord(
          map,
          me: me,
          conversationId: conversationId,
        );
      });

  Future<ChatMessage> sendAttachment({
    required String conversationId,
    required String clientId,
    required MessageKind kind,
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
    int? durationMs,
    required Profile me,
    String? replyToId,
  }) =>
      _guard(() async {
        if (bytes.length > Env.maxAttachmentBytes) {
          throw ApiException(
            'Files must be ${Env.maxAttachmentBytes ~/ (1024 * 1024)} MB or smaller.',
          );
        }
        final params = <String, dynamic>{
          'p_conversation_id': conversationId,
          'p_client_id': clientId,
          'p_kind': kind.dbValue,
          'p_file_name': fileName,
          'p_mime': mimeType,
          'p_duration_ms': durationMs,
          'p_data_base64': base64Encode(bytes),
        };
        if (replyToId != null && replyToId.isNotEmpty) {
          params['p_reply_to_id'] = replyToId;
        }
        final res = await _c.rpc(
          'send_attachment_message',
          params: params,
        ).timeout(_attachmentTimeout);
        final map = _firstMap(res);
        if (map == null) {
          throw ApiException('The attachment could not be sent.');
        }
        return _messageFromRecord(
          map,
          me: me,
          conversationId: conversationId,
        );
      });

  /// Postgres `encode(data, 'base64')` inserts a newline every 76 characters.
  /// Dart's strict base64 decoder rejects those line breaks.
  static Uint8List decodeAttachmentBase64(String raw) =>
      base64Decode(raw.replaceAll(RegExp(r'\s+'), ''));

  Future<AttachmentPayload> getAttachment(String messageId) => _guard(() async {
        final res = await _c.rpc('get_attachment',
            params: {'p_message_id': messageId}).timeout(_attachmentTimeout);
        final rows = _rows(res);
        if (rows.isEmpty) {
          throw ApiException('That attachment is no longer available.');
        }
        final row = rows.first;
        final raw = row['data_base64'];
        if (raw is! String) {
          throw ApiException('That attachment is no longer available.');
        }
        final Uint8List bytes;
        try {
          bytes = decodeAttachmentBase64(raw);
        } on FormatException {
          throw ApiException(
            'That attachment could not be read. Ask the sender to try again.',
          );
        }
        return AttachmentPayload(
          name: row['file_name'] as String? ?? 'attachment',
          mimeType: row['mime_type'] as String? ?? 'application/octet-stream',
          bytes: bytes,
        );
      });

  /// Edits one of my messages. Only the body is sent; the returned server row
  /// carries `edited_at`, which the UI can merge into the local bubble.
  /// [me] may be supplied to avoid a second profile lookup.
  Future<ChatMessage> editMessage(
    String messageId,
    String body, {
    Profile? me,
  }) =>
      _guard(() async {
        final profile = me ?? await getMyProfile();
        final res = await _c.rpc(
          'edit_message',
          params: {'p_message_id': messageId, 'p_body': body},
        ).timeout(_writeTimeout);
        final map = _firstMap(res);
        if (map == null) throw ApiException('The message could not be edited.');
        return _messageFromRecord(map, me: profile);
      });

  /// Server keeps a tombstone; callers should replace the bubble in place.
  Future<void> deleteMessage(String messageId) => _guard(() async {
        await _c.rpc(
          'delete_message',
          params: {'p_message_id': messageId},
        ).timeout(_writeTimeout);
      });

  Future<void> addReaction(String messageId, String emoji) => _guard(() async {
        await _c.rpc(
          'add_reaction',
          params: {'p_message_id': messageId, 'p_emoji': emoji},
        ).timeout(_writeTimeout);
      });

  Future<void> removeReaction(String messageId, String emoji) =>
      _guard(() async {
        await _c.rpc(
          'remove_reaction',
          params: {'p_message_id': messageId, 'p_emoji': emoji},
        ).timeout(_writeTimeout);
      });

  /// Updates this device's presence row and returns the server's timestamp.
  Future<DateTime> touchPresence() => _guard(() async {
        final res = await _c.rpc('touch_presence').timeout(_writeTimeout);
        final parsed = _parseDate(res) ?? serverClock.now();
        serverClock.observe(parsed);
        return parsed;
      });

  /// Last-known presence of the other participant, or null if not available.
  Future<PartnerPresence?> getPartnerPresence(String conversationId) =>
      _guard(() async {
        final res = await _c.rpc(
          'get_partner_presence',
          params: {'p_conversation_id': conversationId},
        ).timeout(_readTimeout);
        final map = _firstMap(res);
        if (map == null || map['user_id'] == null) return null;
        return PartnerPresence.fromJson(map);
      });

  static Future<void> testConnection(String url, String anonKey) async {
    final probe = SupabaseClient(url, anonKey);
    try {
      final res =
          await probe.rpc('health_check').timeout(const Duration(seconds: 18));
      final map = _firstMap(res);
      if (map == null || map['ok'] != true) {
        throw ApiException(
          'Supabase answered, but the Provisional Messenger tables were not '
          'found. Run supabase/setup.sql in the SQL Editor.',
        );
      }
      if (map['cron_ok'] != true) {
        throw ApiException(
          'Supabase is reachable, but the minute expiry cleanup is not active. '
          'Enable pg_cron under Database → Extensions, then run '
          'supabase/setup.sql again.',
        );
      }
      final serverNow = DateTime.tryParse(map['server_now']?.toString() ?? '');
      if (serverNow != null) serverClock.observe(serverNow);
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202' ||
          e.message.toLowerCase().contains('health_check')) {
        throw ApiException(
          'Supabase is reachable, but the database setup is missing. Run '
          'supabase/setup.sql in the SQL Editor, then try again.',
        );
      }
      if (e.code == '401' || e.code == '403') {
        throw ApiException(
          'The anon key was rejected. Copy the Project URL and anon public '
          'key from Supabase → Project Settings → API.',
        );
      }
      throw ApiException(e.message);
    } on TimeoutException {
      throw ApiException(
        'The connection timed out. Check the Project URL and your network.',
      );
    } on FormatException {
      throw ApiException(
        'That does not look like a valid Supabase Project URL.',
      );
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException(
        'Could not reach Supabase. Check the URL, anon key, and network. '
        '(${_shortError(e)})',
      );
    } finally {
      try {
        await probe.dispose();
      } catch (_) {
        // A probe client is short-lived; disposal errors do not matter here.
      }
    }
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ApiException {
      rethrow;
    } on PostgrestException catch (e) {
      throw _mapPostgrest(e);
    } on AuthException catch (e) {
      throw _mapAuth(e);
    } on TimeoutException {
      throw ApiException(
        'The request took too long. Check your connection and try again.',
      );
    } catch (e) {
      throw ApiException(
        'Something went wrong. ${_shortError(e)}',
      );
    }
  }

  /// Parses a raw `messages` row returned by a send/edit RPC. These rows do
  /// not contain the joins or reactions that `get_messages` adds, so reactions
  /// stay empty and are filled by the next fetch/realtime refresh.
  ChatMessage _messageFromRecord(
    Map<String, dynamic> map, {
    Profile? me,
    String? conversationId,
  }) {
    final createdAt = _parseDate(map['created_at']) ?? DateTime.now();
    return ChatMessage(
      id: map['id'] as String,
      conversationId:
          (map['conversation_id'] as String?) ?? conversationId ?? '',
      senderId: (map['sender_id'] as String?) ?? me?.id ?? '',
      senderUsername: me?.username ?? (map['sender_username'] as String?) ?? '',
      senderAccent: me?.accent ?? (map['sender_accent'] as num?)?.toInt() ?? 0,
      kind: MessageKind.fromDb(map['kind'] as String? ?? 'text'),
      body: map['body'] as String?,
      attachmentName: map['attachment_name'] as String?,
      attachmentMime: map['attachment_mime'] as String?,
      attachmentSize: (map['attachment_size'] as num?)?.toInt(),
      durationMs: (map['duration_ms'] as num?)?.toInt(),
      clientId: map['client_id'] as String? ?? '',
      createdAt: createdAt,
      isMine: true,
      replyToId: map['reply_to_id'] as String?,
      replyToBody: map['reply_to_body'] as String?,
      replyToKind: map['reply_to_kind'] as String?,
      replyToSenderId: map['reply_to_sender_id'] as String?,
      replyToSenderUsername: map['reply_to_sender_username'] as String?,
      editedAt: _parseDate(map['edited_at']),
      deletedAt: _parseDate(map['deleted_at']),
      deliveredAt: _parseDate(map['delivered_at']),
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value.toLocal();
    if (value is Map && value.isNotEmpty) return _parseDate(value.values.first);
    if (value is List && value.isNotEmpty) return _parseDate(value.first);
    return DateTime.tryParse(value.toString())?.toLocal();
  }

  @visibleForTesting
  static ApiException mapPostgrest(PostgrestException e) => _mapPostgrest(e);

  @visibleForTesting
  static ApiException mapAuth(AuthException e) => _mapAuth(e);

  static ApiException _mapPostgrest(PostgrestException e) {
    final raw = e.message;
    final lower = raw.toLowerCase();
    // A local session can outlive its anonymous auth user (for example after
    // server-side cleanup). The insert then fails on profiles -> auth.users.
    // Treat it as a recoverable session problem, not a username problem.
    if (lower.contains('profiles_id_fkey') ||
        (e.code == '23503' && lower.contains('profiles'))) {
      return ApiException(
        'This session is no longer valid. Reconnecting…',
        code: 'orphan_session',
        raw: raw,
      );
    }
    if (lower.contains('username_taken')) {
      return ApiException(
        'That username is already taken. Try another one.',
        raw: raw,
        code: e.code,
      );
    }
    if (lower.contains('reserved_username')) {
      return ApiException(
        'That username is reserved. Choose a different one.',
        raw: raw,
        code: e.code,
      );
    }
    if (lower.contains('invalid_username')) {
      return ApiException(
        'Use 3–24 characters: lowercase letters, numbers, or underscore.',
        raw: raw,
        code: e.code,
      );
    }
    if (lower.contains('profile_exists')) {
      return ApiException(
        'This device already has a profile.',
        raw: raw,
        code: e.code,
      );
    }
    if (lower.contains('profile_not_found')) {
      return ApiException(
        'There is no profile for this session. Create a username to continue.',
        raw: raw,
        code: 'profile_not_found',
      );
    }
    if (lower.contains('orphan_session')) {
      return ApiException(
        'This session is no longer valid. Reconnecting…',
        raw: raw,
        code: 'orphan_session',
      );
    }
    if (lower.contains('not_authenticated')) {
      return ApiException(
        'Your session ended. Tap Retry to reconnect.',
        raw: raw,
        code: 'session_expired',
      );
    }
    if (lower.contains('conversation_not_found')) {
      return ApiException(
        'This conversation has ended or was burned.',
        raw: raw,
        code: e.code,
      );
    }
    if (lower.contains('recipient_not_found')) {
      return ApiException(
        'That username no longer exists.',
        raw: raw,
        code: e.code,
      );
    }
    if (lower.contains('attachment_too_large')) {
      return ApiException(
        'Files must be ${Env.maxAttachmentBytes ~/ (1024 * 1024)} MB or smaller.',
        raw: raw,
        code: e.code,
      );
    }
    if (lower.contains('invalid_attachment') ||
        lower.contains('missing_attachment')) {
      return ApiException(
        'That file could not be read. Try a different file.',
        raw: raw,
        code: e.code,
      );
    }
    if (lower.contains('invalid_voice')) {
      return ApiException(
        'That voice note could not be sent. Record it again.',
        raw: raw,
        code: e.code,
      );
    }
    if (lower.contains('message_too_long')) {
      return ApiException(
        'Messages are limited to 4,000 characters.',
        raw: raw,
        code: e.code,
      );
    }
    if (lower.contains('message_not_found')) {
      return ApiException(
        'That message is no longer available.',
        raw: raw,
        code: 'message_not_found',
      );
    }
    if (lower.contains('cannot_edit')) {
      return ApiException(
        'This message can no longer be edited.',
        raw: raw,
        code: 'cannot_edit',
      );
    }
    if (lower.contains('cannot_delete')) {
      return ApiException(
        'This message can no longer be deleted.',
        raw: raw,
        code: 'cannot_delete',
      );
    }
    if (lower.contains('invalid_reaction')) {
      return ApiException(
        'That reaction is not supported.',
        raw: raw,
        code: 'invalid_reaction',
      );
    }
    if (lower.contains('already_reacted')) {
      return ApiException(
        'You already added that reaction.',
        raw: raw,
        code: 'already_reacted',
      );
    }
    if (lower.contains('reaction_not_found')) {
      return ApiException(
        'That reaction was already removed.',
        raw: raw,
        code: 'reaction_not_found',
      );
    }
    if (lower.contains('conversation_full') ||
        lower.contains('conversation_storage_full')) {
      return ApiException(
        'This chat has reached its message or storage limit. '
        'Start a new conversation.',
        raw: raw,
        code: 'conversation_full',
      );
    }
    if (lower.contains('empty_message')) {
      return ApiException('Type a message first.');
    }
    if (lower.contains('invalid_expiry')) {
      return ApiException('Choose an expiry between 5 minutes and 30 days.');
    }
    if (e.code == 'PGRST301' || e.code == '401') {
      return ApiException(
        'Your session is no longer valid. Tap Retry to reconnect.',
        raw: raw,
        code: 'session_expired',
      );
    }
    return ApiException(
      raw.isEmpty ? 'The server rejected the request.' : raw,
      raw: raw,
      code: e.code,
    );
  }

  static ApiException _mapAuth(AuthException e) {
    final lower = e.message.toLowerCase();
    if (lower.contains('anonymous') && lower.contains('disabled')) {
      return ApiException(
        'Anonymous sign-ins are disabled. In Supabase open Authentication → '
        'Providers → Anonymous and enable it, then try again.',
        code: e.code,
        raw: e.message,
      );
    }
    if (lower.contains('rate limit') || lower.contains('too many')) {
      return ApiException(
        'Too many attempts. Wait a minute and try again.',
        code: e.code,
        raw: e.message,
      );
    }
    if (lower.contains('user not found') ||
        lower.contains('user_not_found') ||
        lower.contains('session not found') ||
        lower.contains('session_not_found') ||
        lower.contains('auth session missing') ||
        lower.contains('refresh token')) {
      return ApiException(
        'Your session ended. Tap Retry to reconnect.',
        code: 'session_expired',
        raw: e.message,
      );
    }
    return ApiException(
      e.message.isEmpty ? 'Authentication failed.' : e.message,
      code: e.code,
      raw: e.message,
    );
  }

  @visibleForTesting
  static Map<String, dynamic>? firstMap(dynamic value) => _firstMap(value);

  @visibleForTesting
  static List<Map<String, dynamic>> rows(dynamic value) => _rows(value);

  /// Older servers returned void; a null/absent result is still a successful
  /// burn. An explicit `content_deleted: false` is the only failure result.
  @visibleForTesting
  static bool burnResultSucceeded(dynamic value) {
    final map = _firstMap(value);
    return map == null || map['content_deleted'] != false;
  }

  /// Definite session failures only. Network timeouts, permission errors, and
  /// generic `not_authenticated` responses must not cause a valid local session
  /// (and its profile) to be discarded during a transient refresh failure.
  static bool isDefiniteSessionError(ApiException e) {
    const codes = {'orphan_session', '401', 'PGRST301'};
    if (codes.contains(e.code)) return true;
    final raw = e.raw?.toLowerCase() ?? '';
    const signatures = [
      'user_not_found',
      'user not found',
      'session_not_found',
      'session not found',
      'auth session missing',
      'jwt expired',
      'refresh token',
    ];
    return signatures.any(raw.contains);
  }

  static void _observeServerTime(Iterable<Map<String, dynamic>> rows) {
    for (final row in rows) {
      final raw = row['server_now'];
      if (raw == null) continue;
      final parsed = raw is DateTime ? raw : DateTime.tryParse(raw.toString());
      if (parsed != null) {
        serverClock.observe(parsed);
        return;
      }
    }
  }

  static Map<String, dynamic>? _firstMap(dynamic value) {
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is List && value.isNotEmpty) return _firstMap(value.first);
    return null;
  }

  static List<Map<String, dynamic>> _rows(dynamic value) {
    if (value == null) return const [];
    if (value is List) {
      return value
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    }
    if (value is Map) {
      return [Map<String, dynamic>.from(value)];
    }
    return const [];
  }

  static String _shortError(Object e) {
    final text = e.toString().replaceAll('\n', ' ');
    return text.length > 180 ? '${text.substring(0, 180)}…' : text;
  }
}
