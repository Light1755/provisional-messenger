import 'dart:typed_data';

enum MessageKind {
  text,
  file,
  voice;

  static MessageKind fromDb(String value) {
    switch (value) {
      case 'file':
        return MessageKind.file;
      case 'voice':
        return MessageKind.voice;
      default:
        return MessageKind.text;
    }
  }

  String get dbValue => name;
}

class Profile {
  const Profile({
    required this.id,
    required this.username,
    required this.accent,
    required this.createdAt,
  });

  final String id;
  final String username;
  final int accent;
  final DateTime createdAt;

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    id: json['id'] as String,
    username: json['username'] as String,
    accent: (json['accent'] as num?)?.toInt() ?? 0,
    createdAt: _date(json['created_at']) ?? DateTime.now(),
  );
}

class SearchResult {
  const SearchResult({
    required this.id,
    required this.username,
    required this.accent,
  });

  final String id;
  final String username;
  final int accent;

  factory SearchResult.fromJson(Map<String, dynamic> json) => SearchResult(
    id: json['profile_id'] as String,
    username: json['profile_username'] as String,
    accent: (json['profile_accent'] as num?)?.toInt() ?? 0,
  );
}

class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.partnerId,
    required this.partnerUsername,
    required this.partnerAccent,
    required this.expiresAt,
    required this.expirySeconds,
    required this.createdAt,
    required this.lastMessageAt,
    required this.lastMessageKind,
    required this.lastMessageBody,
    required this.lastMessageAttachmentName,
    required this.lastMessageSenderId,
    required this.unreadCount,
    required this.partnerLastReadAt,
  });

  final String id;
  final String partnerId;
  final String partnerUsername;
  final int partnerAccent;
  final DateTime expiresAt;
  final int expirySeconds;
  final DateTime createdAt;
  final DateTime? lastMessageAt;
  final String? lastMessageKind;
  final String? lastMessageBody;
  final String? lastMessageAttachmentName;
  final String? lastMessageSenderId;
  final int unreadCount;
  final DateTime? partnerLastReadAt;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);

  Duration get remaining => expiresAt.difference(DateTime.now());

  DateTime get sortTime => lastMessageAt ?? createdAt;

  String previewFor(String myId) {
    final kind = lastMessageKind;
    if (kind == null) return 'Private conversation';
    final mine = lastMessageSenderId == myId;
    String text;
    switch (MessageKind.fromDb(kind)) {
      case MessageKind.text:
        text = lastMessageBody ?? '';
        break;
      case MessageKind.voice:
        text = 'Voice note';
        break;
      case MessageKind.file:
        final name = lastMessageAttachmentName;
        text = name == null ? 'File' : 'File · $name';
        break;
    }
    if (text.isEmpty) text = 'Private conversation';
    return mine ? 'You: $text' : text;
  }

  factory ConversationSummary.fromJson(Map<String, dynamic> json) =>
      ConversationSummary(
        id: json['conversation_id'] as String,
        partnerId: json['partner_id'] as String,
        partnerUsername: json['partner_username'] as String,
        partnerAccent: (json['partner_accent'] as num?)?.toInt() ?? 0,
        expiresAt: _date(json['expires_at']) ?? DateTime.now(),
        expirySeconds: (json['expiry_seconds'] as num?)?.toInt() ?? 86400,
        createdAt: _date(json['created_at']) ?? DateTime.now(),
        lastMessageAt: _date(json['last_message_at']),
        lastMessageKind: json['last_message_kind'] as String?,
        lastMessageBody: json['last_message_body'] as String?,
        lastMessageAttachmentName:
            json['last_message_attachment_name'] as String?,
        lastMessageSenderId: json['last_message_sender_id'] as String?,
        unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
        partnerLastReadAt: _date(json['partner_last_read_at']),
      );

  ConversationSummary copyWith({
    DateTime? expiresAt,
    int? expirySeconds,
    int? unreadCount,
    DateTime? partnerLastReadAt,
  }) => ConversationSummary(
    id: id,
    partnerId: partnerId,
    partnerUsername: partnerUsername,
    partnerAccent: partnerAccent,
    expiresAt: expiresAt ?? this.expiresAt,
    expirySeconds: expirySeconds ?? this.expirySeconds,
    createdAt: createdAt,
    lastMessageAt: lastMessageAt,
    lastMessageKind: lastMessageKind,
    lastMessageBody: lastMessageBody,
    lastMessageAttachmentName: lastMessageAttachmentName,
    lastMessageSenderId: lastMessageSenderId,
    unreadCount: unreadCount ?? this.unreadCount,
    partnerLastReadAt: partnerLastReadAt ?? this.partnerLastReadAt,
  );
}

class ConversationDetail {
  const ConversationDetail({
    required this.id,
    required this.partnerId,
    required this.partnerUsername,
    required this.partnerAccent,
    required this.expiresAt,
    required this.expirySeconds,
    required this.createdAt,
  });

  final String id;
  final String partnerId;
  final String partnerUsername;
  final int partnerAccent;
  final DateTime expiresAt;
  final int expirySeconds;
  final DateTime createdAt;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);

  Duration get remaining => expiresAt.difference(DateTime.now());

  factory ConversationDetail.fromJson(Map<String, dynamic> json) =>
      ConversationDetail(
        id: json['conversation_id'] as String,
        partnerId: json['partner_id'] as String,
        partnerUsername: json['partner_username'] as String,
        partnerAccent: (json['partner_accent'] as num?)?.toInt() ?? 0,
        expiresAt: _date(json['expires_at']) ?? DateTime.now(),
        expirySeconds: (json['expiry_seconds'] as num?)?.toInt() ?? 86400,
        createdAt: _date(json['created_at']) ?? DateTime.now(),
      );

  ConversationDetail copyWith({
    DateTime? expiresAt,
    int? expirySeconds,
  }) => ConversationDetail(
    id: id,
    partnerId: partnerId,
    partnerUsername: partnerUsername,
    partnerAccent: partnerAccent,
    expiresAt: expiresAt ?? this.expiresAt,
    expirySeconds: expirySeconds ?? this.expirySeconds,
    createdAt: createdAt,
  );
}

enum MessageStatus { sending, sent, failed }

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.senderUsername,
    required this.senderAccent,
    required this.kind,
    required this.clientId,
    required this.createdAt,
    required this.isMine,
    this.body,
    this.attachmentName,
    this.attachmentMime,
    this.attachmentSize,
    this.durationMs,
    this.isRead = false,
    this.status = MessageStatus.sent,
    this.localBytes,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String senderUsername;
  final int senderAccent;
  final MessageKind kind;
  final String? body;
  final String? attachmentName;
  final String? attachmentMime;
  final int? attachmentSize;
  final int? durationMs;
  final String clientId;
  final DateTime createdAt;
  final bool isMine;
  final Uint8List? localBytes;
  bool isRead;
  MessageStatus status;

  bool get isAttachment =>
      kind == MessageKind.file || kind == MessageKind.voice;

  bool get isImage => (attachmentMime ?? '').startsWith('image/');

  String get displayName {
    if (kind == MessageKind.voice) return 'Voice note';
    if (isImage) return 'Photo';
    return attachmentName ?? 'File';
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final isMine = json['is_mine'] as bool? ?? false;
    return ChatMessage(
      id: json['message_id'] as String,
      conversationId: json['conversation_id'] as String,
      senderId: json['sender_id'] as String,
      senderUsername: json['sender_username'] as String? ?? '',
      senderAccent: (json['sender_accent'] as num?)?.toInt() ?? 0,
      kind: MessageKind.fromDb(json['kind'] as String? ?? 'text'),
      body: json['body'] as String?,
      attachmentName: json['attachment_name'] as String?,
      attachmentMime: json['attachment_mime'] as String?,
      attachmentSize: (json['attachment_size'] as num?)?.toInt(),
      durationMs: (json['duration_ms'] as num?)?.toInt(),
      clientId: json['client_id'] as String,
      createdAt: _date(json['created_at']) ?? DateTime.now(),
      isMine: isMine,
      isRead: json['is_read'] as bool? ?? false,
    );
  }

  /// Builds a bubble from a Realtime `messages` row. Realtime payloads do not
  /// include joins, so the current user's and partner's display details are
  /// supplied by the chat screen.
  factory ChatMessage.fromRecord(
    Map<String, dynamic> record, {
    required String myId,
    required String myUsername,
    required int myAccent,
    required String partnerUsername,
    required int partnerAccent,
  }) {
    final senderId = record['sender_id'] as String;
    final mine = senderId == myId;
    return ChatMessage(
      id: record['id'] as String,
      conversationId: record['conversation_id'] as String,
      senderId: senderId,
      senderUsername: mine ? myUsername : partnerUsername,
      senderAccent: mine ? myAccent : partnerAccent,
      kind: MessageKind.fromDb(record['kind'] as String? ?? 'text'),
      body: record['body'] as String?,
      attachmentName: record['attachment_name'] as String?,
      attachmentMime: record['attachment_mime'] as String?,
      attachmentSize: (record['attachment_size'] as num?)?.toInt(),
      durationMs: (record['duration_ms'] as num?)?.toInt(),
      clientId: record['client_id'] as String,
      createdAt: _date(record['created_at']) ?? DateTime.now(),
      isMine: mine,
    );
  }

  ChatMessage copyWith({
    String? id,
    bool? isRead,
    MessageStatus? status,
    Uint8List? localBytes,
  }) => ChatMessage(
    id: id ?? this.id,
    conversationId: conversationId,
    senderId: senderId,
    senderUsername: senderUsername,
    senderAccent: senderAccent,
    kind: kind,
    body: body,
    attachmentName: attachmentName,
    attachmentMime: attachmentMime,
    attachmentSize: attachmentSize,
    durationMs: durationMs,
    clientId: clientId,
    createdAt: createdAt,
    isMine: isMine,
    isRead: isRead ?? this.isRead,
    status: status ?? this.status,
    localBytes: localBytes ?? this.localBytes,
  );
}

class AttachmentPayload {
  const AttachmentPayload({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

class RecordedClip {
  const RecordedClip({
    required this.name,
    required this.mimeType,
    required this.bytes,
    required this.durationMs,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
  final int durationMs;
}

DateTime? _date(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value.toLocal();
  return DateTime.parse(value.toString()).toLocal();
}
