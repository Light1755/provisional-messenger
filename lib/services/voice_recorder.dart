import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../data/models.dart';
import 'platform_bytes.dart';

class VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();

  bool _recording = false;
  bool _disposed = false;
  bool _cancelRequested = false;
  Completer<void>? _startCompleter;
  DateTime? _startedAt;
  String? _path;
  String _name = 'voice.m4a';
  String _mime = 'audio/mp4';
  String _extension = 'm4a';

  bool get isRecording => _recording;
  bool get isStarting => _startCompleter != null;

  /// Serializes start requests. A cancel or dispose that arrives while
  /// permission is being requested is honoured before the recorder starts.
  Future<bool> start() async {
    if (_disposed) return false;
    if (_recording) return true;

    final pending = _startCompleter;
    if (pending != null) {
      await pending.future;
      return _recording && !_cancelRequested;
    }

    final completer = Completer<void>();
    _startCompleter = completer;
    _cancelRequested = false;
    try {
      final permitted = await _recorder.hasPermission();
      if (!permitted || _cancelRequested || _disposed) return false;

      // WAV on the web plays everywhere, including iOS. Native records AAC in
      // an MP4 container, which web browsers and Android can also play.
      AudioEncoder encoder = kIsWeb ? AudioEncoder.wav : AudioEncoder.aacLc;
      if (!await _recorder.isEncoderSupported(encoder)) {
        encoder = kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc;
      }
      if (!await _recorder.isEncoderSupported(encoder)) {
        encoder = AudioEncoder.aacLc;
      }
      if (_cancelRequested || _disposed) return false;

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
      if (_cancelRequested || _disposed) {
        await cleanupLocation(path);
        return false;
      }
      await _recorder.start(config, path: path);
      if (_cancelRequested || _disposed) {
        try {
          await _recorder.cancel();
        } catch (_) {}
        await cleanupLocation(path);
        return false;
      }

      _path = path;
      _startedAt = DateTime.now();
      _recording = true;
      return true;
    } finally {
      _startCompleter = null;
      if (!completer.isCompleted) completer.complete();
    }
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

  /// Cancels an active recording or an in-flight start, then releases the
  /// temporary file. Safe to call more than once.
  Future<void> cancel() async {
    _cancelRequested = true;
    final pending = _startCompleter;
    if (pending != null) await pending.future;

    if (_recording) {
      await stop(cancel: true);
    } else {
      try {
        await _recorder.cancel();
      } catch (_) {}
      final path = _path;
      _path = null;
      if (path != null) await cleanupLocation(path);
    }
    _cancelRequested = false;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cancel();
    await _recorder.dispose();
  }
}
