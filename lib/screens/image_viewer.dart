import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/attachment_saver.dart';
import '../widgets/ui.dart';

/// Full-screen photo view with pinch-to-zoom and an explicit save action.
///
/// Saving is the one point where a copy leaves the burn model, so the screen
/// says so plainly.
class ImageViewerScreen extends StatefulWidget {
  const ImageViewerScreen({
    super.key,
    required this.bytes,
    required this.name,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String name;
  final String mimeType;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final message = await AttachmentSaver.save(
        name: widget.name,
        mime: widget.mimeType,
        bytes: widget.bytes,
      );
      if (!mounted) return;
      showAppSnack(context, message);
    } catch (_) {
      if (!mounted) return;
      showAppSnack(
        context,
        'The photo could not be saved. Try again.',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
        title: Text(
          widget.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Save photo',
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(
                child: Image.memory(
                  widget.bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const _BrokenImage(),
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: SafeArea(
              top: false,
              child: Text(
                'Screenshots and saved copies are outside the burn control.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: .55),
                  fontSize: 11.5,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrokenImage extends StatelessWidget {
  const _BrokenImage();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.broken_image_outlined,
          size: 54,
          color: Colors.white.withValues(alpha: .55),
        ),
        const SizedBox(height: 14),
        Text(
          'This photo could not be displayed.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: .65),
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}
