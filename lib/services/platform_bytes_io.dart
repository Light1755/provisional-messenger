import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<Uint8List> readBytesFromLocation(String location) =>
    File(location).readAsBytes();

Future<String> tempRecordingPath(String extension) async {
  final dir = await getTemporaryDirectory();
  return '${dir.path}${Platform.pathSeparator}'
      'pm_${DateTime.now().microsecondsSinceEpoch}.$extension';
}

Future<void> cleanupLocation(String location) async {
  try {
    final file = File(location);
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best effort. The OS will eventually clear the temp directory.
  }
}

Future<Uri> prepareAudio(
  Uint8List bytes,
  String mime,
  String extension,
) async {
  final dir = await getTemporaryDirectory();
  final file = File(
    '${dir.path}${Platform.pathSeparator}'
    'pm_play_${DateTime.now().microsecondsSinceEpoch}.$extension',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file.uri;
}

Future<void> cleanupAudio(Uri? uri) async {
  if (uri == null || uri.scheme != 'file') return;
  try {
    final file = File(uri.toFilePath());
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best effort.
  }
}
