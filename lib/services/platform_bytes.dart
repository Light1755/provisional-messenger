import 'dart:typed_data';

import 'platform_bytes_io.dart'
    if (dart.library.js_interop) 'platform_bytes_web.dart' as impl;

/// Reads bytes from a temporary recording path (file path on native, blob URL
/// on web).
Future<Uint8List> readBytesFromLocation(String location) =>
    impl.readBytesFromLocation(location);

/// Creates a temporary path for a new recording. Ignored by the web recorder,
/// which returns a blob URL from stop().
Future<String> tempRecordingPath(String extension) =>
    impl.tempRecordingPath(extension);

/// Deletes a temporary recording or revokes a web blob URL.
Future<void> cleanupLocation(String location) =>
    impl.cleanupLocation(location);

/// Writes audio bytes to a temp file (native) or returns a data URI (web).
Future<Uri> prepareAudio(Uint8List bytes, String mime, String extension) =>
    impl.prepareAudio(bytes, mime, extension);

/// Deletes the temp file created by [prepareAudio], if any.
Future<void> cleanupAudio(Uri? uri) => impl.cleanupAudio(uri);
