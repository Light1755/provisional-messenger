import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mime/mime.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/env.dart';
import '../core/format.dart';
import '../core/routes.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../services/attachment_saver.dart';
import '../services/platform_bytes.dart';
import '../services/voice_recorder.dart';
import '../state/app_state.dart';
import '../widgets/countdown.dart';
import '../widgets/expiry_picker.dart';
import '../widgets/message_bubble.dart';
import '../widgets/ui.dart';
import 'image_viewer.dart';

enum _ChatMenuAction { settings, burn }

enum _EndReason { expired, burned, closed }

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversationId,
    this.partnerUsername,
    this.partnerAccent = 0,
  });

  final String conversationId;
  final String? partnerUsername;
  final int partnerAccent;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen>
    with WidgetsBindingObserver {
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _scroll = ScrollController();
  final _player = AudioPlayer();
  final _recorder = VoiceRecorder();
  final _uuid = const Uuid();

  ConversationDetail? _detail;
  List<ChatMessage> _messages = const [];
  bool _loading = true;
  String? _loadError;
  bool _ended = false;
  _EndReason? _endReason;
  bool _burning = false;
  bool _changingExpiry = false;
  bool _pickingAttachment = false;
  bool _showJump = false;
  bool _hasMore = false;
  bool _loadingEarlier = false;

  String? _playingId;
  String? _loadingAudioId;
  String? _savingId;
  String? _openingImageId;
  Duration _position = Duration.zero;
  Uri? _audioUri;

  bool _recording = false;
  DateTime? _recordStartedAt;
  Duration _recordElapsed = Duration.zero;
  Timer? _recordTimer;

  RealtimeChannel? _channel;
  Timer? _pollTimer;
  Timer? _readDebounce;
  Timer? _syncDebounce;
  bool _polling = false;
  int _messageRequest = 0;
  DateTime? _lastReadThrough;
  bool _pendingRead = false;
  bool _readInFlight = false;

  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    _playerStateSub = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed) {
        unawaited(_stopPlayback());
      }
    });
    _positionSub = _player.positionStream.listen((position) {
      if (!mounted || _playingId == null) return;
      setState(() => _position = position);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_ended && mounted) {
      unawaited(_poll());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cleanupLive();
    _recordTimer?.cancel();
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _composerFocus.dispose();
    _composer.dispose();
    final uri = _audioUri;
    _audioUri = null;
    unawaited(cleanupAudio(uri));
    unawaited(_player.dispose());
    unawaited(_recorder.dispose());
    super.dispose();
  }

  AppState get _app => context.read<AppState>();

  String get _conversationId => widget.conversationId;

  String get _partnerName =>
      _detail?.partnerUsername ?? widget.partnerUsername ?? 'Conversation';

  int get _partnerAccent =>
      _detail?.partnerAccent ?? widget.partnerAccent;

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      final detail = await _app.api.getConversation(_conversationId);
      if (!mounted) return;
      if (detail == null) {
        _loading = false;
        _end(_EndReason.closed);
        return;
      }
      if (detail.isExpired) {
        _loading = false;
        _end(_EndReason.expired);
        return;
      }
      setState(() {
        _detail = detail;
        _loading = false;
      });
      _startLive();
      await _fetchMessages(initial: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = _messageFor(e);
      });
    }
  }

  void _startLive() {
    if (_ended || _channel != null) return;
    final myId = _app.me?.id;
    final channel = _app.client.channel('conversation:$_conversationId');
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: _conversationId,
          ),
          callback: (payload) => _onIncomingMessage(payload.newRecord),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'conversations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: _conversationId,
          ),
          callback: (payload) => _onConversationRecord(payload.newRecord),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'conversations',
          callback: (payload) {
            // Delete events can arrive for any conversation this user can see.
            // The old record usually carries only the primary key, which is
            // enough to tell whether this screen's chat is the one deleted.
            final deletedId = payload.oldRecord['id'] as String?;
            if (deletedId == null) {
              unawaited(_poll());
            } else if (deletedId == _conversationId) {
              _handleConversationGone();
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'conversation_deletions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: _conversationId,
          ),
          callback: (payload) {
            // Tombstones survive the member cascade, so the DELETE event's old
            // row can no longer pass RLS. Each notice names its former members.
            final ids = payload.newRecord['member_ids'];
            if (ids is List && myId != null && ids.contains(myId)) {
              _handleConversationGone();
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'conversation_members',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: _conversationId,
          ),
          callback: (payload) {
            // Our own read receipt write must not trigger a sync, otherwise
            // two open clients can bounce reads back and forth forever.
            if (payload.newRecord['user_id'] != myId) {
              _scheduleMessageSync();
            }
          },
        )
        .onBroadcast(
          event: 'burned',
          callback: (_) => _end(_EndReason.burned),
        )
        .subscribe();
    _channel = channel;
    _pollTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_poll());
    });
  }

  void _cleanupLive() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _readDebounce?.cancel();
    _readDebounce = null;
    _syncDebounce?.cancel();
    _syncDebounce = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) unawaited(channel.unsubscribe());
  }

  Future<void> _poll() async {
    if (!mounted || _ended || _polling || _detail == null) return;
    _polling = true;
    try {
      final detail = await _app.api.getConversation(_conversationId);
      if (!mounted || _ended) return;
      if (detail == null) {
        final known = _detail;
        _end(
          known != null && !known.expiresAt.isAfter(DateTime.now())
              ? _EndReason.expired
              : _EndReason.closed,
        );
        return;
      }
      if (detail.isExpired) {
        _end(_EndReason.expired);
        return;
      }
      if (_detail?.expiresAt != detail.expiresAt) {
        setState(() => _detail = detail);
      }
      await _fetchMessages();
    } catch (_) {
      // Realtime and the next poll retry quietly. The current view stays.
    } finally {
      _polling = false;
    }
  }

  Future<void> _fetchMessages({bool initial = false}) async {
    final started = DateTime.now();
    final request = ++_messageRequest;
    try {
      final list = await _app.api.getMessages(_conversationId);
      if (!mounted || _ended || request != _messageRequest) return;

      final cached = <String, Uint8List>{
        for (final message in _messages)
          if (message.localBytes != null) message.id: message.localBytes!,
      };
      final merged = list
          .map(
            (message) => message.localBytes == null &&
                    cached.containsKey(message.id)
                ? message.copyWith(localBytes: cached[message.id])
                : message,
          )
          .toList(growable: true);

      // Keep optimistic sends that the server does not know about yet.
      for (final pending in _messages) {
        if (pending.status == MessageStatus.sent) continue;
        if (merged.any((message) => message.clientId == pending.clientId)) {
          continue;
        }
        merged.add(pending);
      }

      // Keep anything Realtime delivered while this request was in flight, and
      // keep pages of older messages the user loaded explicitly.
      final oldestFetched = list.isEmpty ? null : list.first.createdAt;
      for (final current in _messages) {
        if (merged.any((message) => message.id == current.id)) continue;
        if (current.clientId.isNotEmpty &&
            merged.any((message) => message.clientId == current.clientId)) {
          continue;
        }
        final recent = current.createdAt.isAfter(
          started.subtract(const Duration(seconds: 3)),
        );
        final olderPage =
            current.status == MessageStatus.sent &&
            oldestFetched != null &&
            current.createdAt.isBefore(oldestFetched);
        if (current.status != MessageStatus.sent || recent || olderPage) {
          merged.add(current);
        }
      }

      _sortMessages(merged);
      setState(() {
        _messages = merged;
        _loading = false;
        _loadError = null;
        if (initial) _hasMore = list.length >= 100;
      });
      if (initial) {
        _scrollToBottom(animate: false);
      } else if (_isNearBottom) {
        _scrollToBottom();
      }

      ChatMessage? latestPartner;
      for (final message in merged) {
        if (message.isMine || message.status != MessageStatus.sent) continue;
        if (latestPartner == null ||
            message.createdAt.isAfter(latestPartner.createdAt)) {
          latestPartner = message;
        }
      }
      if (latestPartner != null) {
        _requestRead(latestPartner.createdAt);
      }
      if (_pendingRead) _markReadSoon();
    } catch (e) {
      if (!mounted || request != _messageRequest) return;
      if (initial) {
        setState(() {
          _loading = false;
          _loadError = _messageFor(e);
        });
      }
    }
  }

  void _sortMessages(List<ChatMessage> messages) {
    messages.sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      if (byTime != 0) return byTime;
      return a.id.compareTo(b.id);
    });
  }

  Future<void> _loadEarlier() async {
    if (_loadingEarlier || _ended || !_hasMore) return;

    ChatMessage? oldest;
    for (final message in _messages) {
      if (message.status != MessageStatus.sent) continue;
      if (oldest == null || message.createdAt.isBefore(oldest.createdAt)) {
        oldest = message;
      }
    }
    if (oldest == null) {
      setState(() => _hasMore = false);
      return;
    }

    // Keep the reader at the same place when older messages are prepended.
    final anchor = _scroll.hasClients
        ? _scroll.position.maxScrollExtent - _scroll.position.pixels
        : 0.0;

    setState(() => _loadingEarlier = true);
    try {
      final older = await _app.api.getMessages(
        _conversationId,
        before: oldest.createdAt,
        beforeId: oldest.id,
      );
      if (!mounted || _ended) return;

      final ids = {for (final message in _messages) message.id};
      final clients = {
        for (final message in _messages)
          if (message.clientId.isNotEmpty) message.clientId,
      };
      final additions = older
          .where(
            (message) =>
                !ids.contains(message.id) &&
                !clients.contains(message.clientId),
          )
          .toList(growable: false);

      final merged = [...additions, ..._messages];
      _sortMessages(merged);
      setState(() {
        _messages = merged;
        _hasMore = older.length >= 100;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final target = (_scroll.position.maxScrollExtent - anchor)
            .clamp(
              _scroll.position.minScrollExtent,
              _scroll.position.maxScrollExtent,
            )
            .toDouble();
        _scroll.jumpTo(target);
      });
    } catch (e) {
      if (mounted) showAppSnack(context, _messageFor(e), error: true);
    } finally {
      if (mounted) setState(() => _loadingEarlier = false);
    }
  }

  void _onIncomingMessage(Map<String, dynamic> record) {
    if (!mounted || _ended) return;
    final me = _app.me;
    if (me == null) return;

    final senderId = record['sender_id'] as String?;
    if (senderId == null) return;
    // Our own inserts are reconciled by the send RPC, which keeps local
    // attachment bytes for display. Realtime only needs to add partner rows.
    if (senderId == me.id) return;

    final message = ChatMessage.fromRecord(
      record,
      myId: me.id,
      myUsername: me.username,
      myAccent: me.accent,
      partnerUsername: _partnerName,
      partnerAccent: _partnerAccent,
    );
    if (_messages.any((existing) => existing.id == message.id)) return;

    final nearBottom = _isNearBottom;
    setState(() {
      _messages = [..._messages, message];
      _sortMessages(_messages);
    });
    if (nearBottom) _scrollToBottom();
    _requestRead(message.createdAt);
    _markReadSoon();
    HapticFeedback.lightImpact();
  }

  void _onConversationRecord(Map<String, dynamic> record) {
    if (!mounted || _ended) return;
    final expiresRaw = record['expires_at'];
    if (expiresRaw == null) return;
    final expiresAt = DateTime.tryParse(expiresRaw.toString())?.toLocal();
    if (expiresAt == null) return;
    if (!expiresAt.isAfter(DateTime.now())) {
      _end(_EndReason.expired);
      return;
    }
    final seconds = (record['expiry_seconds'] as num?)?.toInt();
    setState(() {
      _detail = _detail?.copyWith(
        expiresAt: expiresAt,
        expirySeconds: seconds,
      );
    });
  }

  void _scheduleMessageSync() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted && !_ended) unawaited(_fetchMessages());
    });
  }

  void _handleConversationGone() {
    if (!mounted || _ended) return;
    final detail = _detail;
    if (detail != null && !detail.expiresAt.isAfter(DateTime.now())) {
      _end(_EndReason.expired);
    } else {
      _end(_EndReason.closed);
    }
  }

  void _end(_EndReason reason) {
    if (!mounted || _ended) return;
    _ended = true;
    _endReason = reason;
    _cleanupLive();
    // A recording can auto-send when its timer completes. Cancel it before
    // leaving a burned or expired chat so no note is sent into a deleted row.
    _recordTimer?.cancel();
    _recordTimer = null;
    if (_recording) {
      _recording = false;
      _recordStartedAt = null;
      _recordElapsed = Duration.zero;
      unawaited(_recorder.stop(cancel: true));
    }
    _pendingRead = false;
    unawaited(_stopPlayback());
    _app.removeConversation(_conversationId);
    unawaited(_app.refreshConversations(silent: true));
    HapticFeedback.mediumImpact();
    setState(() {});
  }

  void _requestRead(DateTime through) {
    if (_lastReadThrough == null || through.isAfter(_lastReadThrough!)) {
      _lastReadThrough = through;
    }
    // Keep the flag set until the server confirms the receipt.
    _pendingRead = true;
  }

  void _markReadSoon({Duration delay = const Duration(milliseconds: 350)}) {
    _readDebounce?.cancel();
    _readDebounce = Timer(delay, () {
      if (mounted && !_ended && _pendingRead) unawaited(_flushRead());
    });
  }

  Future<void> _flushRead() async {
    if (_readInFlight || !_pendingRead || _ended) return;
    _readInFlight = true;
    try {
      final confirmed = await _app.markRead(_conversationId);
      if (!mounted || _ended) return;
      if (confirmed) {
        _pendingRead = false;
      } else {
        _markReadSoon(delay: const Duration(seconds: 3));
      }
    } finally {
      _readInFlight = false;
    }
  }

  bool get _isNearBottom {
    if (!_scroll.hasClients) return true;
    return _scroll.position.maxScrollExtent - _scroll.position.pixels < 180;
  }

  void _onScroll() {
    final show =
        _scroll.hasClients &&
        _scroll.position.maxScrollExtent - _scroll.position.pixels > 280;
    if (show != _showJump) setState(() => _showJump = show);
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        unawaited(
          _scroll.animateTo(
            target,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          ),
        );
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  Future<void> _sendText() async {
    if (_ended) return;
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    if (text.length > 4000) {
      showAppSnack(
        context,
        'Messages are limited to 4,000 characters.',
        error: true,
      );
      return;
    }
    final me = _app.me;
    if (me == null) return;

    final clientId = _uuid.v4();
    final optimistic = ChatMessage(
      id: 'local-$clientId',
      conversationId: _conversationId,
      senderId: me.id,
      senderUsername: me.username,
      senderAccent: me.accent,
      kind: MessageKind.text,
      body: text,
      clientId: clientId,
      createdAt: DateTime.now(),
      isMine: true,
      status: MessageStatus.sending,
    );

    _composer.clear();
    setState(() {
      _messages = [..._messages, optimistic];
      _sortMessages(_messages);
    });
    _scrollToBottom();
    await _deliver(optimistic);
  }

  Future<void> _deliver(ChatMessage message) async {
    final me = _app.me;
    if (me == null) return;
    try {
      ChatMessage sent;
      if (message.kind == MessageKind.text) {
        sent = await _app.api.sendText(
          conversationId: _conversationId,
          clientId: message.clientId,
          body: message.body ?? '',
          me: me,
        );
      } else {
        final bytes = message.localBytes;
        if (bytes == null) {
          _markFailed(message.clientId);
          if (mounted) {
            showAppSnack(
              context,
              'That attachment is no longer in memory. Pick it again.',
              error: true,
            );
          }
          return;
        }
        sent = await _app.api.sendAttachment(
          conversationId: _conversationId,
          clientId: message.clientId,
          kind: message.kind,
          fileName: message.attachmentName ?? message.displayName,
          mimeType: message.attachmentMime ?? 'application/octet-stream',
          bytes: bytes,
          durationMs: message.durationMs,
          me: me,
        );
      }

      _replaceOptimistic(
        message.clientId,
        message.localBytes == null
            ? sent
            : sent.copyWith(localBytes: message.localBytes),
      );
    } catch (e) {
      _markFailed(message.clientId);
      if (mounted) showAppSnack(context, _messageFor(e), error: true);
    }
  }

  void _replaceOptimistic(String clientId, ChatMessage sent) {
    if (!mounted) return;
    setState(() {
      final updated = <ChatMessage>[];
      var inserted = false;
      for (final existing in _messages) {
        if (existing.id == sent.id) {
          if (!inserted) {
            updated.add(sent);
            inserted = true;
          }
          continue;
        }
        if (existing.clientId == clientId &&
            existing.id.startsWith('local-')) {
          if (!inserted) {
            updated.add(sent);
            inserted = true;
          }
          continue;
        }
        updated.add(existing);
      }
      if (!inserted) updated.add(sent);
      _sortMessages(updated);
      _messages = updated;
    });
    _scrollToBottom();
  }

  void _markFailed(String clientId) {
    if (!mounted) return;
    setState(() {
      final index = _messages.indexWhere(
        (message) => message.clientId == clientId,
      );
      if (index >= 0) {
        _messages = [..._messages]
          ..[index] = _messages[index].copyWith(status: MessageStatus.failed);
      }
    });
  }

  void _retry(ChatMessage message) {
    if (_ended || message.status != MessageStatus.failed) return;
    final retry = message.copyWith(status: MessageStatus.sending);
    setState(() {
      final index = _messages.indexWhere(
        (item) => item.clientId == message.clientId,
      );
      if (index >= 0) {
        _messages = [..._messages]..[index] = retry;
      }
    });
    unawaited(_deliver(retry));
  }

  Future<void> _queueAttachment({
    required MessageKind kind,
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
    int? durationMs,
  }) async {
    if (bytes.isEmpty) {
      if (mounted) {
        showAppSnack(context, 'That file is empty.', error: true);
      }
      return;
    }
    if (bytes.length > Env.maxAttachmentBytes) {
      if (mounted) {
        showAppSnack(
          context,
          'Files must be ${Env.maxAttachmentBytes ~/ (1024 * 1024)} MB or '
          'smaller.',
          error: true,
        );
      }
      return;
    }
    final me = _app.me;
    if (me == null || !mounted) return;

    final clientId = _uuid.v4();
    final optimistic = ChatMessage(
      id: 'local-$clientId',
      conversationId: _conversationId,
      senderId: me.id,
      senderUsername: me.username,
      senderAccent: me.accent,
      kind: kind,
      attachmentName: fileName,
      attachmentMime: mimeType,
      attachmentSize: bytes.length,
      durationMs: durationMs,
      clientId: clientId,
      createdAt: DateTime.now(),
      isMine: true,
      status: MessageStatus.sending,
      localBytes: bytes,
    );
    setState(() {
      _messages = [..._messages, optimistic];
      _sortMessages(_messages);
    });
    _scrollToBottom();
    await _deliver(optimistic);
  }

  Future<void> _showAttachmentOptions() async {
    if (_ended || _pickingAttachment) return;
    final choice = await showAppSheet<String>(
      context,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add to the conversation',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: -.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Attachments disappear with the chat timer or when either '
              'person burns it.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .55),
              ),
            ),
            const SizedBox(height: 16),
            _AttachmentChoice(
              icon: Icons.photo_outlined,
              title: 'Photo',
              subtitle: 'Pick from your photo library',
              onTap: () => Navigator.of(context).pop('photo'),
            ),
            const SizedBox(height: 8),
            _AttachmentChoice(
              icon: Icons.insert_drive_file_outlined,
              title: 'File',
              subtitle: 'Any file up to ${Env.maxAttachmentBytes ~/ (1024 * 1024)} MB',
              onTap: () => Navigator.of(context).pop('file'),
            ),
            const SizedBox(height: 14),
            Center(
              child: Text(
                'Files are sent as-is. The app does not scan them.',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: .38),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'photo') {
      unawaited(_pickPhoto());
    } else if (choice == 'file') {
      unawaited(_pickFile());
    }
  }

  Future<void> _pickPhoto() async {
    if (_pickingAttachment || _ended) return;
    setState(() => _pickingAttachment = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 84,
        requestFullMetadata: false,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final rawName = picked.name.trim().isEmpty ? 'photo.jpg' : picked.name;
      final header = bytes.length > 32 ? bytes.sublist(0, 32) : bytes;
      var mime =
          lookupMimeType(rawName, headerBytes: header) ??
          picked.mimeType ??
          'image/jpeg';
      if (!mime.startsWith('image/')) mime = 'image/jpeg';
      await _queueAttachment(
        kind: MessageKind.file,
        fileName: _safeFileName(rawName),
        mimeType: mime,
        bytes: bytes,
      );
    } catch (e) {
      if (mounted) {
        showAppSnack(
          context,
          'That photo could not be read. Try another one.',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _pickingAttachment = false);
    }
  }

  Future<void> _pickFile() async {
    if (_pickingAttachment || _ended) return;
    setState(() => _pickingAttachment = true);
    try {
      final picked = await FilePicker.pickFile(dialogTitle: 'Choose a file');
      if (picked == null) return;
      final length = await picked.length();
      if (length != null && length > Env.maxAttachmentBytes) {
        if (mounted) {
          showAppSnack(
            context,
            'Files must be ${Env.maxAttachmentBytes ~/ (1024 * 1024)} MB or '
            'smaller.',
            error: true,
          );
        }
        return;
      }
      final bytes = await picked.readAsBytes();
      final header = bytes.length > 32 ? bytes.sublist(0, 32) : bytes;
      final mime =
          lookupMimeType(picked.name, headerBytes: header) ??
          'application/octet-stream';
      await _queueAttachment(
        kind: MessageKind.file,
        fileName: _safeFileName(picked.name),
        mimeType: mime,
        bytes: bytes,
      );
    } catch (e) {
      if (mounted) {
        showAppSnack(
          context,
          'That file could not be read. Try another one.',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _pickingAttachment = false);
    }
  }

  String _safeFileName(String raw) {
    var name = raw.trim().replaceAll(
      RegExp(r'[\\/:*?"<>|\x00-\x1F]'),
      '_',
    );
    if (name.isEmpty) name = 'file';
    if (name.length > 180) {
      final extension = extensionOf(name);
      final base = withoutExtension(name);
      final room = 180 - (extension.isEmpty ? 0 : extension.length + 1);
      name =
          '${base.substring(0, base.length > room ? room : base.length)}'
          '${extension.isEmpty ? '' : '.$extension'}';
    }
    return name;
  }

  Duration get _maxRecordingLength =>
      kIsWeb ? const Duration(minutes: 2, seconds: 15) : const Duration(minutes: 10);

  Future<void> _startRecording() async {
    if (_recording || _ended || _pickingAttachment) return;
    FocusScope.of(context).unfocus();
    final started = await _recorder.start();
    if (!mounted) return;
    if (!started) {
      showAppSnack(
        context,
        'Microphone access is needed for voice notes. Allow it in your '
        'browser or device settings, then try again.',
        error: true,
      );
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _recording = true;
      _recordStartedAt = DateTime.now();
      _recordElapsed = Duration.zero;
    });
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || !_recording) return;
      final start = _recordStartedAt;
      if (start == null) return;
      final elapsed = DateTime.now().difference(start);
      setState(() => _recordElapsed = elapsed);
      if (elapsed >= _maxRecordingLength) {
        unawaited(_stopRecording(send: true));
      }
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    if (!_recording) return;
    _recordTimer?.cancel();
    _recordTimer = null;
    setState(() => _recording = false);
    final clip = await _recorder.stop(cancel: !send);
    if (!mounted || !send || _ended) return;
    if (clip == null) {
      showAppSnack(
        context,
        'The voice note was too short. Hold on a little longer.',
        error: true,
      );
      return;
    }
    await _queueAttachment(
      kind: MessageKind.voice,
      fileName: clip.name,
      mimeType: clip.mimeType,
      bytes: clip.bytes,
      durationMs: clip.durationMs,
    );
  }

  Future<void> _toggleVoice(ChatMessage message) async {
    if (_ended) return;
    if (_playingId == message.id) {
      await _stopPlayback();
      return;
    }
    if (_loadingAudioId != null) return;
    await _stopPlayback();
    setState(() {
      _loadingAudioId = message.id;
      _position = Duration.zero;
    });

    try {
      final local = message.localBytes;
      final AttachmentPayload payload;
      if (local != null) {
        payload = AttachmentPayload(
          name: message.attachmentName ?? 'voice.m4a',
          mimeType: message.attachmentMime ?? 'audio/mp4',
          bytes: local,
        );
      } else {
        payload = await _app.api.getAttachment(message.id);
      }
      if (!mounted || _ended) return;

      final mime = payload.mimeType.isEmpty
          ? (message.attachmentMime ?? 'audio/mp4')
          : payload.mimeType;
      var extension = extensionOf(payload.name);
      if (extension.isEmpty) {
        extension = mime == 'audio/wav'
            ? 'wav'
            : mime == 'audio/webm'
            ? 'webm'
            : 'm4a';
      }
      final uri = await prepareAudio(payload.bytes, mime, extension);
      if (!mounted || _ended) {
        await cleanupAudio(uri);
        return;
      }
      _audioUri = uri;
      await _player.setUrl(uri.toString());
      if (!mounted || _ended) {
        await _stopPlayback();
        return;
      }
      setState(() {
        _loadingAudioId = null;
        _playingId = message.id;
      });
      await _player.play();
      if (_ended) unawaited(_stopPlayback());
    } catch (e) {
      final uri = _audioUri;
      _audioUri = null;
      await cleanupAudio(uri);
      if (!mounted) return;
      setState(() {
        _loadingAudioId = null;
        _playingId = null;
        _position = Duration.zero;
      });
      showAppSnack(
        context,
        'That voice note could not be played.',
        error: true,
      );
    }
  }

  Future<void> _stopPlayback() async {
    final uri = _audioUri;
    _audioUri = null;
    if (mounted) {
      setState(() {
        _playingId = null;
        _loadingAudioId = null;
        _position = Duration.zero;
      });
    }
    try {
      await _player.stop();
    } catch (_) {
      // The player may already be stopped or disposed.
    }
    await cleanupAudio(uri);
  }

  Future<void> _openImage(ChatMessage message) async {
    if (_ended || _openingImageId != null) return;
    final local = message.localBytes;
    if (local != null) {
      await _pushImage(
        local,
        message.attachmentName ?? message.displayName,
        message.attachmentMime ?? 'image/jpeg',
      );
      return;
    }

    setState(() => _openingImageId = message.id);
    try {
      final payload = await _app.api.getAttachment(message.id);
      if (!mounted || _ended) return;
      setState(() {
        _messages = [
          for (final item in _messages)
            item.id == message.id
                ? item.copyWith(localBytes: payload.bytes)
                : item,
        ];
        _openingImageId = null;
      });
      await _pushImage(payload.bytes, payload.name, payload.mimeType);
    } catch (e) {
      if (!mounted) return;
      setState(() => _openingImageId = null);
      showAppSnack(context, _messageFor(e), error: true);
    }
  }

  Future<void> _pushImage(
    Uint8List bytes,
    String name,
    String mime,
  ) async {
    if (!mounted || _ended) return;
    await Navigator.of(context).push(
      appPageRoute<void>(
        ImageViewerScreen(bytes: bytes, name: name, mimeType: mime),
      ),
    );
  }

  Future<void> _saveAttachment(ChatMessage message) async {
    if (_savingId != null || _ended) return;
    setState(() => _savingId = message.id);
    try {
      final local = message.localBytes;
      final AttachmentPayload payload;
      if (local != null) {
        payload = AttachmentPayload(
          name: message.attachmentName ?? message.displayName,
          mimeType: message.attachmentMime ?? 'application/octet-stream',
          bytes: local,
        );
      } else {
        payload = await _app.api.getAttachment(message.id);
      }
      if (!mounted || _ended) return;
      final result = await AttachmentSaver.save(
        name: payload.name,
        mime: payload.mimeType,
        bytes: payload.bytes,
      );
      if (!mounted || _ended) return;
      showAppSnack(context, result);
    } catch (e) {
      if (!mounted) return;
      showAppSnack(
        context,
        e is ApiException
            ? e.message
            : 'The file could not be saved. Try again.',
        error: true,
      );
    } finally {
      if (mounted && !_ended) setState(() => _savingId = null);
    }
  }

  Future<void> _showChatSettings() async {
    if (_ended) return;
    final detail = _detail;
    if (detail == null) return;
    final action = await showAppSheet<_ChatMenuAction>(
      context,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Avatar(
                  username: _partnerName,
                  accent: _partnerAccent,
                  size: 48,
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _partnerName,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.4,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Private conversation',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: .45),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kAccent.withValues(alpha: .07),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: kAccent.withValues(alpha: .13)),
              ),
              child: Row(
                children: [
                  const SoftIcon(
                    icon: Icons.timer_outlined,
                    size: 38,
                    iconSize: 18,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Expires ${formatExpiryDate(detail.expiresAt)}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${expiryLabel(detail.expirySeconds)} timer · '
                          'messages do not extend it',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: .5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pop(_ChatMenuAction.settings),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Change',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _AttachmentChoice(
              icon: Icons.local_fire_department_outlined,
              title: 'Burn conversation',
              subtitle:
                  'Deletes everything for both people immediately. No undo.',
              danger: true,
              onTap: () => Navigator.of(context).pop(_ChatMenuAction.burn),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                'There is no archive or restore in this app.',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: .38),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;
    switch (action) {
      case _ChatMenuAction.settings:
        await _changeExpiry();
        break;
      case _ChatMenuAction.burn:
        await _burnConversation();
        break;
    }
  }

  Future<void> _changeExpiry() async {
    if (_detail == null || _ended || _changingExpiry) return;
    final seconds = await showExpiryPicker(
      context,
      selectedSeconds: _detail!.expirySeconds,
      title: 'Chat timer',
      description:
          'Changing the timer restarts the countdown from now. It applies to '
          'both people.',
      confirmLabel: 'Update timer',
    );
    if (seconds == null || !mounted) return;

    setState(() => _changingExpiry = true);
    try {
      final expiresAt = await _app.changeExpiry(_conversationId, seconds);
      if (!mounted) return;
      setState(() {
        _detail = _detail?.copyWith(
          expiresAt: expiresAt,
          expirySeconds: seconds,
        );
      });
      unawaited(_app.refreshConversations(silent: true));
      showAppSnack(
        context,
        'This conversation now expires in ${expiryLabel(seconds)}.',
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnack(context, _messageFor(e), error: true);
    } finally {
      if (mounted) setState(() => _changingExpiry = false);
    }
  }

  Future<void> _burnConversation() async {
    if (_burning || _ended) return;
    setState(() => _burning = true);
    final channel = _channel;
    try {
      await _app.burnConversation(_conversationId);
      if (channel != null) {
        // Keep the channel alive long enough to tell the other device. The
        // delete event and polling are fallbacks, but the broadcast makes the
        // burn feel immediate on both screens.
        try {
          await channel
              .sendBroadcastMessage(
                event: 'burned',
                payload: {'conversation_id': _conversationId},
              )
              .timeout(const Duration(seconds: 2));
        } catch (_) {
          // Polling on the other device also detects the deletion.
        }
      }
      if (!mounted) return;
      _cleanupLive();
      HapticFeedback.mediumImpact();
      showAppSnack(context, 'Conversation burned for both people.');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _burning = false);
      showAppSnack(context, _messageFor(e), error: true);
    }
  }

  String _messageFor(Object error) {
    if (error is ApiException) return error.message;
    return 'Something went wrong. Check your connection and try again.';
  }

  @override
  Widget build(BuildContext context) {
    final ended = _ended;
    return Scaffold(
      appBar: _buildAppBar(context, ended),
      body: ended
          ? _EndedView(
              reason: _endReason ?? _EndReason.closed,
              partnerName: _partnerName,
              onBack: () => Navigator.of(context).pop(),
            )
          : _buildChat(context),
    );
  }

  AppBar _buildAppBar(BuildContext context, bool ended) {
    final scheme = Theme.of(context).colorScheme;
    return AppBar(
      toolbarHeight: 64,
      leadingWidth: 58,
      leading: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          style: IconButton.styleFrom(
            backgroundColor: scheme.onSurface.withValues(alpha: .05),
          ),
          icon: const Icon(Icons.arrow_back_rounded, size: 21),
        ),
      ),
      titleSpacing: 10,
      title: InkWell(
        onTap: ended ? null : _showChatSettings,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Avatar(
                username: _partnerName,
                accent: _partnerAccent,
                size: 38,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _partnerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.3,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      ended
                          ? 'Conversation ended'
                          : 'Private · tap for chat settings',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurface.withValues(alpha: .43),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (_burning)
          const Padding(
            padding: EdgeInsets.only(right: 18),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          PopupMenuButton<_ChatMenuAction>(
            enabled: !ended,
            tooltip: 'Chat options',
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (action) {
              switch (action) {
                case _ChatMenuAction.settings:
                  unawaited(_showChatSettings());
                  break;
                case _ChatMenuAction.burn:
                  unawaited(_burnConversation());
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _ChatMenuAction.settings,
                child: Row(
                  children: [
                    Icon(Icons.tune_rounded, size: 19),
                    SizedBox(width: 11),
                    Text('Chat settings'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: _ChatMenuAction.burn,
                child: Row(
                  children: [
                    Icon(
                      Icons.local_fire_department_outlined,
                      size: 19,
                      color: kDanger,
                    ),
                    SizedBox(width: 11),
                    Text('Burn conversation', style: TextStyle(color: kDanger)),
                  ],
                ),
              ),
            ],
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildChat(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_detail == null) {
      if (_loadError != null) {
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ErrorNotice(message: _loadError!, onRetry: _load),
                  const SizedBox(height: 14),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Back to chats'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return const _ChatSkeleton();
    }

    return Column(
      children: [
        ExpiryStrip(
          expiresAt: _detail!.expiresAt,
          expirySeconds: _detail!.expirySeconds,
          changing: _changingExpiry,
          onChange: () => unawaited(_changeExpiry()),
          onExpired: () => _end(_EndReason.expired),
        ),
        Expanded(
          child: Stack(
            children: [
              if (_loading && _messages.isEmpty)
                const _ChatSkeleton()
              else if (_messages.isEmpty)
                ListView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(top: 30),
                  children: const [
                    EmptyState(
                      compact: true,
                      icon: Icons.waving_hand_outlined,
                      title: 'Start the conversation',
                      body:
                          'Say hello. This chat stays until its timer ends or '
                          'one of you burns it. There is no history after that.',
                    ),
                  ],
                )
              else
                ListView.builder(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
                  itemCount: _messages.length + (_hasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (_hasMore && index == 0) {
                      return _LoadEarlier(
                        loading: _loadingEarlier,
                        onTap: _loadingEarlier
                            ? null
                            : () => unawaited(_loadEarlier()),
                      );
                    }
                    final messageIndex = _hasMore ? index - 1 : index;
                    final message = _messages[messageIndex];
                    final previous = messageIndex > 0
                        ? _messages[messageIndex - 1]
                        : null;
                    final showDate =
                        previous == null ||
                        !_sameDay(previous.createdAt, message.createdAt);
                    final showAvatar =
                        !message.isMine &&
                        (previous == null ||
                            previous.senderId != message.senderId ||
                            showDate);
                    final failed = message.status == MessageStatus.failed;
                    final settled = message.status == MessageStatus.sent;

                    return Column(
                      children: [
                        if (showDate) _DateHeader(date: message.createdAt),
                        MessageBubble(
                          message: message,
                          showAvatar: showAvatar,
                          showReadReceipt: message.isMine,
                          isPlaying: _playingId == message.id,
                          audioLoading: _loadingAudioId == message.id,
                          playbackPosition: _playingId == message.id
                              ? _position
                              : Duration.zero,
                          downloading:
                              _openingImageId == message.id ||
                              _savingId == message.id,
                          onRetry: failed ? () => _retry(message) : null,
                          onPlayVoice:
                              message.kind == MessageKind.voice && settled
                              ? () => unawaited(_toggleVoice(message))
                              : null,
                          onOpenImage: message.isImage && settled
                              ? () => unawaited(_openImage(message))
                              : null,
                          onSaveAttachment:
                              message.kind == MessageKind.file &&
                                  !message.isImage &&
                                  settled
                              ? () => unawaited(_saveAttachment(message))
                              : null,
                        ),
                      ],
                    );
                  },
                ),
              Positioned(
                right: 16,
                bottom: 12,
                child: AnimatedScale(
                  scale: _showJump ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutBack,
                  child: _showJump
                      ? Material(
                          color: scheme.surface,
                          shape: const CircleBorder(),
                          elevation: 3,
                          shadowColor: Colors.black.withValues(alpha: .14),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => _scrollToBottom(),
                            child: const SizedBox(
                              width: 40,
                              height: 40,
                              child: Icon(
                                Icons.arrow_downward_rounded,
                                size: 19,
                                color: kAccent,
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: _recording
              ? _buildRecordingBar(context)
              : _buildComposer(context),
        ),
      ],
    );
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _buildComposer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canType = !_burning;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.onSurface.withValues(alpha: .06)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _RoundAction(
              tooltip: 'Add a photo or file',
              onPressed: canType ? _showAttachmentOptions : null,
              child: _pickingAttachment
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onSurface.withValues(alpha: .45),
                      ),
                    )
                  : Icon(
                      Icons.add_rounded,
                      size: 24,
                      color: scheme.onSurface.withValues(alpha: .62),
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: .045),
                  borderRadius: BorderRadius.circular(22),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: TextField(
                  controller: _composer,
                  focusNode: _composerFocus,
                  enabled: canType,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 4000,
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(fontSize: 15.5, height: 1.35),
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    counterText: '',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _composer,
              builder: (context, value, _) {
                final hasText = value.text.trim().isNotEmpty;
                if (!hasText) {
                  return _RoundAction(
                    tooltip: 'Record a voice note',
                    filled: true,
                    onPressed: canType ? _startRecording : null,
                    child: const Icon(
                      Icons.mic_none_rounded,
                      size: 22,
                      color: Colors.white,
                    ),
                  );
                }
                return _RoundAction(
                  tooltip: 'Send message',
                  filled: true,
                  onPressed: canType ? _sendText : null,
                  child: const Icon(
                    Icons.arrow_upward_rounded,
                    size: 22,
                    color: Colors.white,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: kRecordingRed.withValues(alpha: .2)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Cancel recording',
              onPressed: () => unawaited(_stopRecording(send: false)),
              style: IconButton.styleFrom(
                backgroundColor: scheme.onSurface.withValues(alpha: .05),
              ),
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
            const SizedBox(width: 12),
            const _RecordingPulse(),
            const SizedBox(width: 9),
            Text(
              formatDuration(_recordElapsed.inMilliseconds),
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
                letterSpacing: -.3,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Recording · tap the check to send',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurface.withValues(alpha: .45),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Send voice note',
              onPressed: () => unawaited(_stopRecording(send: true)),
              style: IconButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.check_rounded, size: 22),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentChoice extends StatelessWidget {
  const _AttachmentChoice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = danger ? kDanger : scheme.onSurface;
    return Material(
      color: danger
          ? kDanger.withValues(alpha: .06)
          : scheme.onSurface.withValues(alpha: .025),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
          child: Row(
            children: [
              SoftIcon(
                icon: icon,
                size: 40,
                iconSize: 19,
                color: danger ? kDanger : kAccent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: color,
                        letterSpacing: -.15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.35,
                        color: danger
                            ? kDanger.withValues(alpha: .66)
                            : scheme.onSurface.withValues(alpha: .45),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: danger
                    ? kDanger.withValues(alpha: .55)
                    : scheme.onSurface.withValues(alpha: .22),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.child,
    required this.tooltip,
    this.onPressed,
    this.filled = false,
  });

  final Widget child;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 42,
        height: 42,
        child: Material(
          color: filled
              ? (onPressed == null
                    ? kAccent.withValues(alpha: .45)
                    : kAccent)
              : scheme.onSurface.withValues(alpha: .05),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _RecordingPulse extends StatefulWidget {
  const _RecordingPulse();

  @override
  State<_RecordingPulse> createState() => _RecordingPulseState();
}

class _RecordingPulseState extends State<_RecordingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    lowerBound: .35,
    upperBound: 1,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 11,
        height: 11,
        decoration: const BoxDecoration(
          color: kRecordingRed,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _LoadEarlier extends StatelessWidget {
  const _LoadEarlier({required this.loading, required this.onTap});

  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Center(
        child: TextButton.icon(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: scheme.onSurface.withValues(alpha: .55),
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: loading
              ? SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: scheme.onSurface.withValues(alpha: .45),
                  ),
                )
              : Icon(
                  Icons.expand_less_rounded,
                  size: 17,
                  color: scheme.onSurface.withValues(alpha: .4),
                ),
          label: Text(
            loading ? 'Loading earlier messages' : 'Load earlier messages',
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _DateHeader extends StatelessWidget {
  const _DateHeader({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: .045),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            formatDateHeader(date),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface.withValues(alpha: .45),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatSkeleton extends StatelessWidget {
  const _ChatSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.onSurface.withValues(alpha: .055);
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        _SkeletonBubble(width: 210, height: 46, alignRight: false, fill: fill),
        _SkeletonBubble(width: 260, height: 62, alignRight: true, fill: fill),
        _SkeletonBubble(width: 160, height: 46, alignRight: false, fill: fill),
        _SkeletonBubble(width: 230, height: 88, alignRight: true, fill: fill),
        _SkeletonBubble(width: 190, height: 46, alignRight: false, fill: fill),
      ],
    );
  }
}

class _SkeletonBubble extends StatelessWidget {
  const _SkeletonBubble({
    required this.width,
    required this.height,
    required this.alignRight,
    required this.fill,
  });

  final double width;
  final double height;
  final bool alignRight;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: width,
        height: height,
        margin: const EdgeInsets.only(bottom: 12, left: 32, right: 32),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(19),
            topRight: const Radius.circular(19),
            bottomLeft: Radius.circular(alignRight ? 19 : 6),
            bottomRight: Radius.circular(alignRight ? 6 : 19),
          ),
        ),
      ),
    );
  }
}

class _EndedView extends StatelessWidget {
  const _EndedView({
    required this.reason,
    required this.partnerName,
    required this.onBack,
  });

  final _EndReason reason;
  final String partnerName;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final expired = reason == _EndReason.expired;
    final burned = reason == _EndReason.burned;
    final icon = burned
        ? Icons.local_fire_department_outlined
        : expired
        ? Icons.timer_off_outlined
        : Icons.link_off_rounded;
    final title = burned
        ? 'Conversation burned'
        : expired
        ? 'Timer reached zero'
        : 'Conversation ended';
    final body = burned
        ? 'This chat was burned. Messages, photos, files, and voice notes are '
              'gone for both people.'
        : expired
        ? 'The timer ended, so this conversation and everything in it were '
              'deleted for both people.'
        : 'This conversation was burned or reached its timer. Everything in '
              'it was deleted for both people.';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SoftIcon(
                icon: icon,
                color: burned ? kDanger : kAccent,
                size: 76,
                iconSize: 34,
              ),
              const SizedBox(height: 24),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.9,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.55,
                  color: scheme.onSurface.withValues(alpha: .55),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                partnerName == 'Conversation' ? '' : 'Chat with $partnerName',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurface.withValues(alpha: .34),
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: 220,
                child: PrimaryButton(
                  label: 'Back to chats',
                  icon: Icons.arrow_back_rounded,
                  onPressed: onBack,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'No archive. No restore.',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface.withValues(alpha: .3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
