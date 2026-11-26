import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../data/models.dart';
import 'platform_bytes.dart';

class VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();

  bool _recording = false;
  DateTime? _startedAt;
  String? _path;
  String _name = 'voice.m4a';
  String _mime = 'audio/mp4';
  String _extension = 'm4a';

  bool get isRecording => _recording;

  Future<bool> start() async {
    if (_recording) return true;

    final permitted = await _recorder.hasPermission();
    if (!permitted) return false;

    // WAV on the web plays everywhere, including iOS. Native records AAC in an
    // MP4 container, which web browsers and Android can also play.
    AudioEncoder encoder = kIsWeb ? AudioEncoder.wav : AudioEncoder.aacLc;
    if (!await _recorder.isEncoderSupported(encoder)) {
      encoder = kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc;
    }
    if (!await _recorder.isEncoderSupported(encoder)) {
      encoder = AudioEncoder.aacLc;
    }

    if (encoder == AudioEncoder.wav) {
      _name = 'voice.wav';
      _mime = 'audio/wav';
      _extension = 'wav';
    } else if (encoder == AudioEncoder.opus) {
      _name = 'voice.webm';
      _mime = 'audio/webm';
      _extension = 'webm';
    } else {
      _name = 'voice.m4a';
      _mime = 'audio/mp4';
      _extension = 'm4a';
    }

    final config = RecordConfig(
      encoder: encoder,
      bitRate: encoder == AudioEncoder.wav ? 256000 : 64000,
      sampleRate: encoder == AudioEncoder.wav ? 16000 : 44100,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
    );

    final path = await tempRecordingPath(_extension);
    await _recorder.start(config, path: path);
    _path = path;
    _startedAt = DateTime.now();
    _recording = true;
    return true;
  }

  Future<RecordedClip?> stop({bool cancel = false}) async {
    if (!_recording) return null;
    _recording = false;
    final startedAt = _startedAt;
    _startedAt = null;

    if (cancel) {
      try {
        await _recorder.cancel();
      } catch (_) {}
      final path = _path;
      _path = null;
      if (path != null) await cleanupLocation(path);
      return null;
    }

    String? location;
    try {
      location = await _recorder.stop();
    } catch (_) {
      location = null;
    }
    final path = location ?? _path;
    _path = null;

    if (path == null) return null;

    try {
      final bytes = await readBytesFromLocation(path);
      if (bytes.isEmpty) return null;
      final elapsed = DateTime.now().difference(startedAt ?? DateTime.now());
      return RecordedClip(
        name: _name,
        mimeType: _mime,
        bytes: bytes,
        durationMs: elapsed.inMilliseconds.clamp(500, 600000),
      );
    } finally {
      await cleanupLocation(path);
    }
  }

  Future<void> dispose() async {
    if (_recording) {
      _recording = false;
      try {
        await _recorder.cancel();
      } catch (_) {
        // The recorder may already have stopped with the app.
      }
    }
    final path = _path;
    _path = null;
    if (path != null) await cleanupLocation(path);
    await _recorder.dispose();
  }
}
