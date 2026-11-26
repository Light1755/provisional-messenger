import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../core/env.dart';

enum AppStatus { starting, needsProfile, ready, error }

/// Holds the session, profile, chat list, theme, and live subscriptions.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({
    required this.client,
    required this.prefs,
    required this.themeMode,
  }) : api = Api(client) {
    WidgetsBinding.instance.addObserver(this);
  }

  static const _themeKey = 'theme_mode';

  final SupabaseClient client;
  final SharedPreferences prefs;
  final ValueNotifier<ThemeMode> themeMode;
  final Api api;

  AppStatus _status = AppStatus.starting;
  Profile? _me;
  String? _errorMessage;
  List<ConversationSummary> _conversations = const [];
  bool _loadingConversations = false;
  String? _conversationsError;
  bool _initializing = false;
  bool _disposed = false;
  bool _sessionUnusable = false;

  Timer? _pollTimer;
  Timer? _refreshDebounce;
  RealtimeChannel? _inboxChannel;
  int _conversationRequest = 0;

  AppStatus get status => _status;
  Profile? get me => _me;
  String? get errorMessage => _errorMessage;
  List<ConversationSummary> get conversations =>
      List.unmodifiable(_conversations);
  bool get loadingConversations => _loadingConversations;
  String? get conversationsError => _conversationsError;
  bool get isReady => _status == AppStatus.ready && _me != null;

  /// True only after an authenticated request failed in a way that suggests the
  /// anonymous session itself cannot be refreshed.
  bool get sessionUnusable => _sessionUnusable;

  int get unreadTotal => _conversations.fold<int>(
        0,
        (sum, c) => sum + (c.isExpired ? 0 : c.unreadCount),
      );

  ConversationSummary? conversationById(String id) {
    for (final conversation in _conversations) {
      if (conversation.id == id) return conversation;
    }
    return null;
  }

  Future<void> initialize() async {
    if (_disposed || _initializing) return;
    if (_status == AppStatus.ready && _me != null) {
      await refreshConversations(silent: true);
      return;
    }

    _initializing = true;
    _status = AppStatus.starting;
    _errorMessage = null;
    _sessionUnusable = false;
    _safeNotify();

    try {
      if (client.auth.currentSession == null) {
        await client.auth.signInAnonymously();
      } else {
        // A saved session can point at an auth user that no longer exists.
        // Only a definite session failure causes renewal. A timeout or other
        // network error must not throw away access to an existing profile.
        try {
          await client.auth.getUser();
        } catch (e) {
          if (_isSessionAuthFailure(e)) await _renewSession();
        }
      }
      if (_disposed) return;

      Profile? profile;
      try {
        profile = await api.getMyProfile();
      } on ApiException catch (e) {
        if (e.code != 'orphan_session' && !_looksLikeSessionError(e)) rethrow;
        _sessionUnusable = true;
        try {
          if (e.code == 'orphan_session') {
            await _renewSession();
          } else {
            await client.auth.refreshSession();
          }
        } catch (_) {
          // The next call reports the real error.
        }
        if (_disposed) return;
        try {
          profile = await api.getMyProfile();
          _sessionUnusable = false;
        } catch (retryError) {
          if (retryError is! ApiException ||
              (retryError.code != 'orphan_session' &&
                  !_looksLikeSessionError(retryError))) {
            _sessionUnusable = false;
          }
          rethrow;
        }
      }

      if (_disposed) return;
      _me = profile;
      if (profile == null) {
        _teardownLive();
        _status = AppStatus.needsProfile;
      } else {
        _status = AppStatus.ready;
        _startLive();
      }
    } catch (e) {
      _errorMessage = _messageFor(e);
      _status = AppStatus.error;
    } finally {
      _initializing = false;
      _safeNotify();
    }
  }

  Future<Profile> createProfile(String username) async {
    Profile profile;
    try {
      profile = await api.createProfile(username);
    } on ApiException catch (e) {
      final raw = e.raw?.toLowerCase() ?? '';
      if (e.code == 'orphan_session' || raw.contains('profiles_id_fkey')) {
        // The saved session outlived its anonymous auth user. Drop it and try
        // once with a fresh user so the user does not have to restart.
        if (!await _renewSession()) rethrow;
        if (_disposed) throw StateError('AppState disposed');
        profile = await api.createProfile(username);
      } else if (raw.contains('profile_exists')) {
        // The insert can commit even when its response is lost. If the retry is
        // told the profile already exists, adopt it instead of leaving onboarding
        // stuck on an error until an app restart.
        final existing = await api.getMyProfile();
        if (_disposed) throw StateError('AppState disposed');
        if (existing == null) rethrow;
        profile = existing;
      } else {
        rethrow;
      }
    }
    if (_disposed) throw StateError('AppState disposed');
    _me = profile;
    _status = AppStatus.ready;
    _errorMessage = null;
    _startLive();
    _safeNotify();
    return profile;
  }

  Future<List<SearchResult>> searchUsers(String query) =>
      api.searchProfiles(query);

  Future<String> startConversation(
    String otherUserId, {
    int expirySeconds = Env.defaultExpirySeconds,
  }) async {
    final id = await api.startConversation(
      otherUserId,
      expirySeconds: expirySeconds,
    );
    unawaited(refreshConversations(silent: true));
    return id;
  }

  Future<void> refreshConversations({bool silent = false}) async {
    if (_me == null || _disposed) return;
    final request = ++_conversationRequest;

    if (!silent) {
      _loadingConversations = true;
      _conversationsError = null;
      _safeNotify();
    }

    try {
      final list = await api.listConversations();
      _applyConversationList(list, request);
    } on ApiException catch (e) {
      if (_disposed || request != _conversationRequest) return;
      if (!_looksLikeSessionError(e)) {
        _conversationsError = e.message;
      } else {
        // A session can expire while the app is open. Try one clean renewal;
        // if that fails, show the recovery action instead of "Offline" forever.
        final renewed = await _renewSession();
        if (_disposed || request != _conversationRequest) return;
        if (renewed) {
          try {
            _applyConversationList(await api.listConversations(), request);
            return;
          } on ApiException catch (retryError) {
            if (_disposed || request != _conversationRequest) return;
            _conversationsError = retryError.message;
          }
        }
        _sessionUnusable = true;
        _status = AppStatus.error;
        _errorMessage = 'This session can no longer be used. Start a new '
            'session to continue. Your old profile cannot be recovered.';
      }
    } catch (e) {
      if (_disposed || request != _conversationRequest) return;
      _conversationsError = 'Could not refresh your conversations.';
    } finally {
      if (!_disposed && request == _conversationRequest) {
        _loadingConversations = false;
        _safeNotify();
      }
    }
  }

  void _applyConversationList(
    List<ConversationSummary> list,
    int request,
  ) {
    if (_disposed || request != _conversationRequest) return;
    _conversations = list.where((c) => !c.isExpired).toList()
      ..sort((a, b) => b.sortTime.compareTo(a.sortTime));
    _conversationsError = null;
  }

  Future<DateTime> changeExpiry(
    String conversationId,
    int expirySeconds,
  ) async {
    final expiresAt = await api.setConversationExpiry(
      conversationId,
      expirySeconds,
    );
    applyExpiry(conversationId, expiresAt, expirySeconds);
    return expiresAt;
  }

  void applyExpiry(String conversationId, DateTime expiresAt, int seconds) {
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index < 0) return;
    _conversations[index] = _conversations[index].copyWith(
      expiresAt: expiresAt,
      expirySeconds: seconds,
    );
    _safeNotify();
  }

  Future<void> burnConversation(String conversationId) async {
    await api.burnConversation(conversationId);
    removeConversation(conversationId);
  }

  void removeConversation(String conversationId) {
    _conversations = _conversations
        .where((c) => c.id != conversationId)
        .toList(growable: false);
    _safeNotify();
  }

  /// Marks a conversation read on the server before clearing the local badge.
  /// Returns false when the receipt failed so the chat can retry it later.
  Future<bool> markRead(String conversationId) async {
    try {
      await api.markConversationRead(conversationId);
    } catch (_) {
      return false;
    }
    if (_disposed) return false;
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index >= 0 && _conversations[index].unreadCount != 0) {
      _conversations[index] = _conversations[index].copyWith(unreadCount: 0);
      _safeNotify();
    }
    return true;
  }

  Future<void> burnProfile() async {
    if (_me == null) return;
    await api.burnProfile();

    _me = null;
    _conversations = const [];
    _teardownLive();
    _status = AppStatus.starting;
    _errorMessage = null;
    _safeNotify();

    try {
      await client.auth.signOut();
    } catch (_) {
      // The local session is removed before the network call.
    }

    try {
      await client.auth.signInAnonymously();
      _status = AppStatus.needsProfile;
      _errorMessage = null;
    } catch (e) {
      _status = AppStatus.error;
      _errorMessage =
          'Your profile and conversations were burned, but a new anonymous '
          'session could not be created. ${_messageFor(e)}';
    }
    _safeNotify();
  }

  /// Drops the local session and creates a new anonymous user.
  ///
  /// Used when the server reports that the saved session no longer has an
  /// auth user. The local sign-out clears storage even when the network call
  /// fails, which is why its error is ignored.
  Future<bool> _renewSession() async {
    if (_disposed) return false;
    try {
      await client.auth.signOut();
    } catch (_) {
      // The local session is removed before the network call.
    }
    try {
      await client.auth.signInAnonymously();
      return client.auth.currentSession != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    unawaited(prefs.setString(_themeKey, mode.name));
  }

  void _startLive() {
    if (_disposed || _me == null) return;
    _initInbox();
    _pollTimer ??= Timer.periodic(const Duration(seconds: 20), (_) {
      if (!_disposed) refreshConversations(silent: true);
    });
    unawaited(refreshConversations());
  }

  void _teardownLive() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _refreshDebounce?.cancel();
    _refreshDebounce = null;
    final channel = _inboxChannel;
    _inboxChannel = null;
    if (channel != null) unawaited(channel.unsubscribe());
  }

  void _initInbox() {
    final me = _me;
    if (_disposed || me == null) return;
    final previous = _inboxChannel;
    _inboxChannel = null;
    if (previous != null) unawaited(previous.unsubscribe());

    final channel = client.channel('inbox:${me.id}');
    channel.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'messages',
      callback: (_) => _scheduleRefresh(),
    );
    channel.onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'conversations',
      callback: (_) => _scheduleRefresh(),
    );
    channel.onPostgresChanges(
      event: PostgresChangeEvent.delete,
      schema: 'public',
      table: 'conversations',
      callback: (_) => _scheduleRefresh(),
    );
    // The DELETE row fails RLS once its members are cascaded away, so a
    // short-lived tombstone carries the member ids for a reliable refresh.
    channel.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'conversation_deletions',
      callback: (payload) {
        final ids = payload.newRecord['member_ids'];
        if (ids is List && ids.contains(me.id)) _scheduleRefresh();
      },
    );
    channel.onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'conversation_members',
      callback: (_) => _scheduleRefresh(),
    );
    channel.subscribe();
    _inboxChannel = channel;
  }

  void _scheduleRefresh([Duration delay = const Duration(milliseconds: 450)]) {
    if (_disposed) return;
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(delay, () {
      if (!_disposed) refreshConversations(silent: true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && isReady) {
      unawaited(refreshConversations(silent: true));
    }
  }

  /// True for definite auth failures. Network exceptions have no status and
  /// must leave a valid local session alone.
  bool _isSessionAuthFailure(Object e) {
    if (e is AuthRetryableFetchException) return false;
    if (e is! AuthException) return false;
    final status = e.statusCode;
    if (status == '401' || status == '403' || status == '404') return true;
    final lower = e.message.toLowerCase();
    return lower.contains('user not found') ||
        lower.contains('user_not_found') ||
        lower.contains('session not found') ||
        lower.contains('auth session missing');
  }

  bool _looksLikeSessionError(ApiException e) {
    final lower = e.message.toLowerCase();
    final raw = e.raw?.toLowerCase() ?? '';
    return e.code == 'orphan_session' ||
        e.code == '401' ||
        e.code == '403' ||
        e.code == 'PGRST301' ||
        lower.contains('session') ||
        lower.contains('jwt') ||
        raw.contains('user_not_found') ||
        raw.contains('user not found');
  }

  String _messageFor(Object error) {
    if (error is ApiException) return error.message;
    if (error is AuthException) return error.message;
    return 'Something went wrong. Check your connection and try again.';
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _teardownLive();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
