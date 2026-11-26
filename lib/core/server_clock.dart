/// Wall clock corrected by timestamps returned from the server.
///
/// Device clocks can be wrong by hours or days. Expiry must follow the server,
/// so every RPC that returns `server_now` feeds this clock. Between responses,
/// the device's monotonic progress is used on top of the last known offset.
class ServerClock {
  ServerClock({DateTime Function()? localNow})
      : _localNow = localNow ?? DateTime.now;

  final DateTime Function() _localNow;
  Duration _offset = Duration.zero;
  bool _hasSample = false;

  DateTime nowUtc() => _localNow().toUtc().add(_offset);

  DateTime now() => nowUtc().toLocal();

  /// Adopts the server's current time. Out-of-order responses are harmless:
  /// each sample is a fresh observation, not an accumulated adjustment.
  void observe(DateTime serverNow) {
    final sample = serverNow.toUtc().difference(_localNow().toUtc());
    _offset = sample;
    _hasSample = true;
  }

  void reset() {
    _offset = Duration.zero;
    _hasSample = false;
  }

  bool get hasSample => _hasSample;
}

/// Shared clock used by the app UI and models.
final ServerClock serverClock = ServerClock();
