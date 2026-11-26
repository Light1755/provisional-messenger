import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/routes.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../widgets/countdown.dart';
import '../widgets/ui.dart';
import 'conversation_screen.dart';

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key, required this.onOpenDiscover});

  final VoidCallback onOpenDiscover;

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().refreshConversations(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _openConversation(ConversationSummary conversation) async {
    await Navigator.of(context).push(
      appPageRoute<void>(
        ConversationScreen(conversationId: conversation.id),
      ),
    );
    if (!mounted) return;
    context.read<AppState>().refreshConversations(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final active = app.conversations
        .where((c) => c.expiresAt.isAfter(DateTime.now()))
        .toList(growable: false);
    final unread = active.fold<int>(0, (sum, c) => sum + c.unreadCount);

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 12, 18, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Chats',
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.2,
                          height: 1.05,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        active.isEmpty
                            ? 'Private conversations, on a timer.'
                            : '${active.length} active'
                                  '${unread > 0 ? ' · $unread unread' : ' · everything expires'}',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurface.withValues(alpha: .45),
                        ),
                      ),
                    ],
                  ),
                ),
                Material(
                  color: kAccent,
                  shape: const CircleBorder(),
                  elevation: 0,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: widget.onOpenDiscover,
                    child: const SizedBox(
                      width: 46,
                      height: 46,
                      child: Icon(
                        Icons.add_comment_outlined,
                        color: Colors.white,
                        size: 21,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (app.conversationsError != null && active.isNotEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(20, 2, 20, 6),
              padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
              decoration: BoxDecoration(
                color: kDanger.withValues(alpha: .07),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.cloud_off_outlined,
                    size: 15,
                    color: kDanger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Offline. Showing the last known chats.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurface.withValues(alpha: .55),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => app.refreshConversations(),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Retry',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: app.loadingConversations && active.isEmpty
                ? const _ChatSkeleton()
                : RefreshIndicator(
                    onRefresh: () => app.refreshConversations(silent: true),
                    color: kAccent,
                    backgroundColor: scheme.surface,
                    child: active.isEmpty
                        ? (app.conversationsError != null
                              ? ListView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.only(top: 56),
                                  children: [
                                    EmptyState(
                                      icon: Icons.cloud_off_outlined,
                                      title: 'Could not load your chats',
                                      body:
                                          'Check your connection and try '
                                          'again. A failed refresh does not '
                                          'delete a chat.',
                                      action: SizedBox(
                                        width: 200,
                                        child: PrimaryButton(
                                          label: 'Try again',
                                          icon: Icons.refresh_rounded,
                                          onPressed: () => app
                                              .refreshConversations(),
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : ListView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.only(top: 56),
                                  children: [
                                    EmptyState(
                                      icon: Icons.chat_bubble_outline_rounded,
                                      title: 'No conversations yet',
                                      body:
                                          'Find someone by their username and '
                                          'start a private chat. Choose how long '
                                          'it lasts when it begins.',
                                      action: SizedBox(
                                        width: 220,
                                        child: PrimaryButton(
                                          label: 'Find someone',
                                          icon: Icons.search_rounded,
                                          onPressed: widget.onOpenDiscover,
                                        ),
                                      ),
                                    ),
                                  ],
                                ))
                        : ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 26),
                            itemCount: active.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 9),
                            itemBuilder: (context, index) {
                              final conversation = active[index];
                              return _ConversationTile(
                                key: ValueKey(conversation.id),
                                conversation: conversation,
                                myId: app.me?.id ?? '',
                                onTap: () => _openConversation(conversation),
                              );
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    super.key,
    required this.conversation,
    required this.myId,
    required this.onTap,
  });

  final ConversationSummary conversation;
  final String myId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = conversation.unreadCount > 0;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(21),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(13, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(21),
            border: Border.all(
              color: scheme.onSurface.withValues(alpha: .055),
            ),
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Avatar(
                    username: conversation.partnerUsername,
                    accent: conversation.partnerAccent,
                    size: 52,
                  ),
                  if (unread)
                    Positioned(
                      right: -3,
                      top: -3,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 19),
                        height: 19,
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          color: kAccent,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: scheme.surface, width: 2),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          conversation.unreadCount > 99
                              ? '99+'
                              : '${conversation.unreadCount}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conversation.partnerUsername,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.25,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      conversation.previewFor(myId),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                        color: unread
                            ? scheme.onSurface.withValues(alpha: .80)
                            : scheme.onSurface.withValues(alpha: .45),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    formatChatListTime(
                      conversation.lastMessageAt ?? conversation.createdAt,
                    ),
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                      color: unread
                          ? kAccent
                          : scheme.onSurface.withValues(alpha: .34),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ExpiryBadge(
                    expiresAt: conversation.expiresAt,
                    compact: true,
                  ),
                ],
              ),
            ],
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
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      itemCount: 4,
      separatorBuilder: (_, __) => const SizedBox(height: 9),
      itemBuilder: (context, index) => Container(
        height: 77,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: scheme.onSurface.withValues(alpha: .04)),
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
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
                  const SizedBox(height: 9),
                  Container(
                    width: double.infinity,
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
      ),
    );
  }
}
