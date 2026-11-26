import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/env.dart';
import '../core/format.dart';
import '../core/routes.dart';
import '../core/theme.dart';
import '../core/username.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../widgets/expiry_picker.dart';
import '../widgets/ui.dart';
import 'conversation_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  Timer? _debounce;
  int _request = 0;
  String _query = '';
  List<SearchResult> _results = const [];
  bool _searching = false;
  bool _searched = false;
  String? _error;
  String? _busyId;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final normalized = normalizeUsername(value);
    if (normalized != value) {
      _controller.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
    }
    setState(() {
      _query = normalized;
      _error = null;
    });
    _debounce?.cancel();
    // Invalidate any search that is already in flight so an older prefix can
    // never overwrite results for what is now in the field.
    _request++;
    if (normalized.length < 3) {
      setState(() {
        _results = const [];
        _searching = false;
        _searched = false;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 340),
      () => unawaited(_search()),
    );
  }

  Future<void> _search() async {
    _debounce?.cancel();
    final query = normalizeUsername(_controller.text);
    if (query.length < 3) return;

    final app = context.read<AppState>();
    final request = ++_request;
    setState(() {
      _query = query;
      _searching = true;
      _error = null;
    });
    try {
      final results = await app.searchUsers(query);
      if (!mounted || request != _request) return;
      setState(() {
        _results = results;
        _searching = false;
        _searched = true;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _searching = false;
        _searched = true;
        _error = e is ApiException
            ? e.message
            : 'Search failed. Check your connection and try again.';
      });
    }
  }

  void _clear() {
    _debounce?.cancel();
    _request++;
    _controller.clear();
    setState(() {
      _query = '';
      _results = const [];
      _searching = false;
      _searched = false;
      _error = null;
    });
    _focus.requestFocus();
  }

  ConversationSummary? _existingWith(String userId) {
    final app = context.read<AppState>();
    for (final conversation in app.conversations) {
      if (conversation.partnerId == userId && !conversation.isExpired) {
        return conversation;
      }
    }
    return null;
  }

  Future<void> _choose(SearchResult result) async {
    if (_busyId != null) return;
    FocusScope.of(context).unfocus();
    final app = context.read<AppState>();
    final existing = _existingWith(result.id);

    if (existing != null) {
      await _openChat(existing.id, result.username, result.accent);
      return;
    }

    final seconds = await showExpiryPicker(
      context,
      selectedSeconds: Env.defaultExpirySeconds,
      title: 'How long should this chat last?',
      description:
          'Choose before the first message. Either person can change it later '
          'in chat settings. If you already have a live chat, that one opens '
          'instead.',
      confirmLabel: 'Start private chat',
      highlightDefault: true,
    );
    if (seconds == null || !mounted) return;

    setState(() => _busyId = result.id);
    try {
      final id = await app.startConversation(
        result.id,
        expirySeconds: seconds,
      );
      if (!mounted) return;
      unawaited(app.refreshConversations(silent: true));
      await _openChat(id, result.username, result.accent);
    } catch (e) {
      if (!mounted) return;
      showAppSnack(
        context,
        e is ApiException
            ? e.message
            : 'The conversation could not be started.',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _openChat(String id, String username, int accent) async {
    await Navigator.of(context).push(
      appPageRoute<void>(
        ConversationScreen(
          conversationId: id,
          partnerUsername: username,
          partnerAccent: accent,
        ),
      ),
    );
    if (!mounted) return;
    unawaited(context.read<AppState>().refreshConversations(silent: true));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Discover',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.2,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  'Find someone by username. Matches start with what you type.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurface.withValues(alpha: .45),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: scheme.onSurface.withValues(alpha: .07),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .03),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const SizedBox(width: 14),
                  Icon(
                    Icons.search_rounded,
                    size: 21,
                    color: scheme.onSurface.withValues(alpha: .4),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      textInputAction: TextInputAction.search,
                      autocorrect: false,
                      enableSuggestions: false,
                      textCapitalization: TextCapitalization.none,
                      onChanged: _onChanged,
                      onSubmitted: (_) => unawaited(_search()),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[a-zA-Z0-9_]'),
                        ),
                        LengthLimitingTextInputFormatter(24),
                      ],
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -.1,
                      ),
                      decoration: const InputDecoration(
                        hintText: 'Search username',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          vertical: 15,
                        ),
                      ),
                    ),
                  ),
                  if (_query.isNotEmpty)
                    IconButton(
                      tooltip: 'Clear search',
                      onPressed: _clear,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: scheme.onSurface.withValues(alpha: .38),
                      ),
                    )
                  else
                    const SizedBox(width: 12),
                ],
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _searching
                ? const LinearProgressIndicator(
                    key: ValueKey('searching'),
                    minHeight: 2,
                    color: kAccent,
                    backgroundColor: Colors.transparent,
                  )
                : const SizedBox(
                    key: ValueKey('idle'),
                    height: 2,
                  ),
          ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_query.length < 3) {
      return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 36),
        children: [
          EmptyState(
            icon: Icons.person_search_outlined,
            title: 'Search a username',
            body:
                'Type at least 3 characters. Matching usernames start with '
                'what you type, so a unique prefix is enough.',
            action: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: .035),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: scheme.onSurface.withValues(alpha: .06),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 15,
                    color: scheme.onSurface.withValues(alpha: .4),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      'No phone book, no contacts upload.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurface.withValues(alpha: .45),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (_searching && _results.isEmpty) {
      return ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: const [
          _ResultSkeleton(),
          SizedBox(height: 9),
          _ResultSkeleton(),
          SizedBox(height: 9),
          _ResultSkeleton(),
        ],
      );
    }

    if (_searched && _results.isEmpty && _error == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 36),
        children: [
          EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No one found',
            body:
                'No username starts with “$_query”. Check the spelling, or ask '
                'them to confirm their exact username.',
          ),
        ],
      );
    }

    final hasError = _error != null;
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 26),
      itemCount: _results.length + (hasError ? 1 : 0),
      separatorBuilder: (_, index) =>
          SizedBox(height: hasError && index == 0 ? 14 : 9),
      itemBuilder: (context, index) {
        if (hasError && index == 0) {
          return ErrorNotice(
            message: _error!,
            onRetry: () => unawaited(_search()),
          );
        }
        final result = _results[index - (hasError ? 1 : 0)];
        final existing = _existingWith(result.id);
        final busy = _busyId == result.id;
        return Material(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _busyId == null ? () => _choose(result) : null,
            child: Container(
              padding: const EdgeInsets.fromLTRB(13, 12, 14, 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: scheme.onSurface.withValues(alpha: .055),
                ),
              ),
              child: Row(
                children: [
                  Avatar(
                    username: result.username,
                    accent: result.accent,
                    size: 48,
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          result.username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.25,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Text(
                              '@${result.username}',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurface.withValues(alpha: .4),
                              ),
                            ),
                            if (existing != null) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: kAccent.withValues(alpha: .1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  'Open · ${formatRemaining(existing.remaining)}',
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: kAccent,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 34,
                    height: 34,
                    child: busy
                        ? const Padding(
                            padding: EdgeInsets.all(8),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Container(
                            decoration: BoxDecoration(
                              color: kAccent.withValues(alpha: .1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              existing != null
                                  ? Icons.arrow_forward_rounded
                                  : Icons.chat_bubble_outline_rounded,
                              size: 17,
                              color: kAccent,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ResultSkeleton extends StatelessWidget {
  const _ResultSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.onSurface.withValues(alpha: .055);
    return Container(
      height: 72,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.onSurface.withValues(alpha: .04)),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 110,
                  height: 10,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 78,
                  height: 8,
                  decoration: BoxDecoration(
                    color: fill.withValues(alpha: .7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
