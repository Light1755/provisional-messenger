import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
/// Saves a downloaded attachment somewhere the user can keep it.
///
/// This is intentionally outside the burn model: once the user saves a copy to
/// their device, the app can no longer delete it.
class AttachmentSaver {
  AttachmentSaver._();

  static Future<String> save({
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async {
    final safeMime = mime.trim().isEmpty ? 'application/octet-stream' : mime;
    final safeName = _safeBaseName(name);
    final extension = _extensionOf(name, safeMime);

    if (!kIsWeb &&
        safeMime.startsWith('image/') &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      try {
        await FileSaver.instance.saveToGallery(
          name: safeName,
          bytes: bytes,
          fileExtension: extension,
          mimeType: MimeType.custom,
          customMimeType: safeMime,
        );
        return 'Saved to your photos';
      } catch (_) {
        // Fall back to the regular file saver below (older Android versions,
        // missing gallery permission, unsupported image type, ...).
      }
    }

    await FileSaver.instance.saveFile(
      name: safeName,
      bytes: bytes,
      fileExtension: extension,
      mimeType: MimeType.custom,
      customMimeType: safeMime,
    );

    if (kIsWeb) return 'Downloaded';
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return 'Saved to this app’s Documents folder';
    }
    return 'Saved';
  }

  static String _safeBaseName(String name) {
    var base = name.trim();
    final slash = base.lastIndexOf(RegExp(r'[/\\]'));
    if (slash >= 0) base = base.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    if (base.isEmpty) base = 'attachment';
    base = base.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    if (base.length > 80) base = base.substring(0, 80);
    return base;
  }

  static String _extensionOf(String name, String mime) {
    final dot = name.lastIndexOf('.');
    if (dot > 0 && dot < name.length - 1 && name.length - dot <= 12) {
      return name.substring(dot + 1).toLowerCase();
    }
    switch (mime) {
      case 'image/jpeg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/webp':
        return 'webp';
      case 'image/gif':
        return 'gif';
      case 'audio/mp4':
        return 'm4a';
      case 'audio/wav':
        return 'wav';
      case 'audio/webm':
        return 'webm';
      case 'application/pdf':
        return 'pdf';
      case 'text/plain':
        return 'txt';
      default:
        return '';
    }
  }
}
