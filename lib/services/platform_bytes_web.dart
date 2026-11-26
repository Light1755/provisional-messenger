import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

Future<Uint8List> readBytesFromLocation(String location) async {
  if (location.startsWith('data:')) {
    final comma = location.indexOf(',');
    if (comma < 0) throw const FormatException('Invalid data URL');
    return base64Decode(location.substring(comma + 1));
  }
  final response = await http.get(Uri.parse(location));
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError('Recording download failed (${response.statusCode}).');
  }
  return response.bodyBytes;
}

Future<String> tempRecordingPath(String extension) async => 'voice.$extension';

Future<void> cleanupLocation(String location) async {
  if (location.startsWith('blob:')) {
    web.URL.revokeObjectURL(location);
  }
}

Future<Uri> prepareAudio(
  Uint8List bytes,
  String mime,
  String extension,
) async {
  // Blob URLs avoid the size and memory overhead of a large data URI and are
  // supported by the browser audio element, including iOS Safari.
  final blob = web.Blob(
    <web.BlobPart>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: mime),
  );
  return Uri.parse(web.URL.createObjectURL(blob));
}

Future<void> cleanupAudio(Uri? uri) async {
  if (uri != null && uri.toString().startsWith('blob:')) {
    web.URL.revokeObjectURL(uri.toString());
  }
}
