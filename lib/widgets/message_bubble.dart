import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../data/models.dart';
import 'ui.dart';

const _waveHeights = <double>[
  .28, .52, .38, .74, .46, .9, .58, .34, .68, .48, .82, .4,
  .62, .94, .5, .72, .36, .6, .88, .44, .7, .32, .56, .78,
];

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.showAvatar,
    required this.showReadReceipt,
    required this.isPlaying,
    required this.audioLoading,
    required this.playbackPosition,
    this.downloading = false,
    this.onRetry,
    this.onPlayVoice,
    this.onOpenImage,
    this.onSaveAttachment,
  });

  final ChatMessage message;
  final bool showAvatar;
  final bool showReadReceipt;
  final bool isPlaying;
  final bool audioLoading;
  final Duration playbackPosition;
  final bool downloading;
  final VoidCallback? onRetry;
  final VoidCallback? onPlayVoice;
  final VoidCallback? onOpenImage;
  final VoidCallback? onSaveAttachment;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.isMine;
    final failed = message.status == MessageStatus.failed;
    final foreground = mine ? Colors.white : scheme.onSurface;
    final muted = mine
        ? Colors.white.withValues(alpha: .62)
        : scheme.onSurface.withValues(alpha: .42);

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: math.min(MediaQuery.sizeOf(context).width * .78, 380.0),
      ),
      decoration: BoxDecoration(
        gradient: mine
            ? const LinearGradient(
                colors: [kAccent, kAccentDeep],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: mine ? null : scheme.surface,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(19),
          topRight: const Radius.circular(19),
          bottomLeft: Radius.circular(mine ? 19 : 6),
          bottomRight: Radius.circular(mine ? 6 : 19),
        ),
        border: mine
            ? null
            : Border.all(color: scheme.onSurface.withValues(alpha: .065)),
        boxShadow: [
          BoxShadow(
            color: mine
                ? kAccent.withValues(alpha: .16)
                : Colors.black.withValues(alpha: .035),
            blurRadius: mine ? 14 : 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: message.isImage && message.localBytes != null
          ? const EdgeInsets.all(4)
          : const EdgeInsets.fromLTRB(13, 9, 13, 7),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _content(context, foreground, muted),
          SizedBox(height: message.isImage && message.localBytes != null ? 5 : 3),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: message.isImage && message.localBytes != null ? 6 : 0,
            ),
            child: _statusRow(context, muted, failed),
          ),
        ],
      ),
    );

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: showAvatar ? 7 : 2,
        bottom: 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!mine) ...[
            SizedBox(
              width: 28,
              height: 28,
              child: showAvatar
                  ? Avatar(
                      username: message.senderUsername,
                      accent: message.senderAccent,
                      size: 28,
                    )
                  : null,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: GestureDetector(
              onTap: failed ? onRetry : null,
              child: AnimatedOpacity(
                opacity: message.status == MessageStatus.sending ? .92 : 1,
                duration: const Duration(milliseconds: 180),
                child: bubble,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, Color foreground, Color muted) {
    switch (message.kind) {
      case MessageKind.text:
        return Text(
          message.body ?? '',
          style: TextStyle(
            color: foreground,
            fontSize: 15.5,
            height: 1.34,
            letterSpacing: -.1,
          ),
        );
      case MessageKind.voice:
        return _voiceContent(context, foreground, muted);
      case MessageKind.file:
        return message.isImage
            ? _imageContent(context, foreground, muted)
            : _fileContent(context, foreground, muted);
    }
  }

  Widget _voiceContent(BuildContext context, Color foreground, Color muted) {
    final total = message.durationMs ?? 0;
    final positionMs = isPlaying
        ? playbackPosition.inMilliseconds
              .clamp(0, total <= 0 ? 1 : total)
              .toInt()
        : 0;
    final progress = total <= 0 ? 0.0 : positionMs / total;

    return InkWell(
      onTap: onPlayVoice,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: foreground.withValues(alpha: .14),
                shape: BoxShape.circle,
              ),
              child: audioLoading
                  ? Padding(
                      padding: const EdgeInsets.all(11),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: foreground,
                      ),
                    )
                  : Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: foreground,
                      size: 24,
                    ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 118,
              height: 25,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: List.generate(_waveHeights.length, (index) {
                  final active = index / _waveHeights.length <= progress;
                  return Container(
                    width: 2.4,
                    height: 25 * _waveHeights[index],
                    decoration: BoxDecoration(
                      color: active
                          ? foreground
                          : foreground.withValues(alpha: .28),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatDuration(
                    isPlaying
                        ? positionMs
                        : total.clamp(0, 3599999).toInt(),
                  ),
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Voice',
                  style: TextStyle(
                    color: muted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _imageContent(BuildContext context, Color foreground, Color muted) {
    final bytes = message.localBytes;
    return GestureDetector(
      onTap: downloading ? null : onOpenImage,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Stack(
          children: [
            if (bytes != null)
              Image.memory(
                bytes,
                width: 220,
                height: 160,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) =>
                    _imagePlaceholder(foreground, muted, 220, 160),
              )
            else
              _imagePlaceholder(foreground, muted, 220, 138),
            if (downloading)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: .35),
                  child: const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              right: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .35),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.zoom_out_map_rounded,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imagePlaceholder(
    Color foreground,
    Color muted,
    double width,
    double height,
  ) {
    return Container(
      width: width,
      height: height,
      color: foreground.withValues(alpha: .10),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.photo_outlined,
            color: foreground.withValues(alpha: .85),
            size: 34,
          ),
          const SizedBox(height: 7),
          Text(
            message.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: foreground,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (message.attachmentSize != null) ...[
            const SizedBox(height: 2),
            Text(
              formatBytes(message.attachmentSize!),
              style: TextStyle(color: muted, fontSize: 10.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _fileContent(BuildContext context, Color foreground, Color muted) {
    final name = message.attachmentName ?? 'Attachment';
    final type = humanFileType(message.attachmentMime ?? '', name);
    return GestureDetector(
      onTap: downloading ? null : onSaveAttachment,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: foreground.withValues(alpha: .13),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              _fileIcon(message.attachmentMime ?? ''),
              color: foreground,
              size: 21,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    type,
                    if (message.attachmentSize != null)
                      formatBytes(message.attachmentSize!),
                  ].join(' · '),
                  style: TextStyle(color: muted, fontSize: 10.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 28,
            height: 28,
            child: downloading
                ? Padding(
                    padding: const EdgeInsets.all(6),
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: foreground,
                    ),
                  )
                : Icon(
                    Icons.download_rounded,
                    color: foreground.withValues(alpha: .8),
                    size: 19,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _statusRow(BuildContext context, Color muted, bool failed) {
    final sending = message.status == MessageStatus.sending;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          formatMessageTime(message.createdAt),
          style: TextStyle(
            color: failed ? const Color(0xFFFFC4BC) : muted,
            fontSize: 10,
            fontWeight: FontWeight.w500,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (message.isMine) ...[
          const SizedBox(width: 4),
          if (sending)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.4,
                color: muted,
              ),
            )
          else if (failed)
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 12,
                  color: Color(0xFFFFC4BC),
                ),
                SizedBox(width: 3),
                Text(
                  'Tap to retry',
                  style: TextStyle(
                    color: Color(0xFFFFC4BC),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            )
          else if (showReadReceipt)
            Icon(
              message.isRead ? Icons.done_all_rounded : Icons.done_rounded,
              size: 13,
              color: message.isRead
                  ? const Color(0xFFB7F2DB)
                  : Colors.white.withValues(alpha: .7),
            ),
        ],
      ],
    );
  }

  IconData _fileIcon(String mime) {
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_rounded;
    if (mime.startsWith('text/')) return Icons.description_outlined;
    if (mime.contains('zip') || mime.contains('compressed')) {
      return Icons.folder_zip_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}
