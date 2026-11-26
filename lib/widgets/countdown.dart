import 'dart:async';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/theme.dart';

/// Rebuilds its child every second with the time left until [expiresAt].
class CountdownBuilder extends StatefulWidget {
  const CountdownBuilder({
    super.key,
    required this.expiresAt,
    required this.builder,
    this.onExpired,
  });

  final DateTime expiresAt;
  final Widget Function(BuildContext context, Duration remaining) builder;
  final VoidCallback? onExpired;

  @override
  State<CountdownBuilder> createState() => _CountdownBuilderState();
}

class _CountdownBuilderState extends State<CountdownBuilder> {
  Timer? _timer;
  bool _reportedExpired = false;

  @override
  void initState() {
    super.initState();
    _start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkExpired());
  }

  @override
  void didUpdateWidget(covariant CountdownBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expiresAt != widget.expiresAt) {
      _reportedExpired = false;
      _start();
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkExpired());
    }
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      _checkExpired();
    });
  }

  void _checkExpired() {
    if (!mounted || _reportedExpired) return;
    if (!DateTime.now().isBefore(widget.expiresAt)) {
      _reportedExpired = true;
      widget.onExpired?.call();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.expiresAt.difference(DateTime.now());
    return widget.builder(
      context,
      remaining.isNegative ? Duration.zero : remaining,
    );
  }
}

class ExpiryBadge extends StatelessWidget {
  const ExpiryBadge({
    super.key,
    required this.expiresAt,
    this.compact = false,
  });

  final DateTime expiresAt;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return CountdownBuilder(
      expiresAt: expiresAt,
      builder: (context, remaining) {
        final expired = remaining.inSeconds <= 0;
        final urgent = remaining.inMinutes < 5;
        final soon = remaining.inMinutes < 60;
        final color = expired || urgent
            ? kDanger
            : soon
            ? const Color(0xFFC08243)
            : kAccent;
        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 7 : 9,
            vertical: compact ? 3 : 4,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.timer_outlined, size: compact ? 11 : 12, color: color),
              const SizedBox(width: 4),
              Text(
                expired ? 'Expired' : formatRemaining(remaining),
                style: TextStyle(
                  color: color,
                  fontSize: compact ? 10 : 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.1,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ExpiryStrip extends StatelessWidget {
  const ExpiryStrip({
    super.key,
    required this.expiresAt,
    required this.expirySeconds,
    required this.onChange,
    this.onExpired,
    this.changing = false,
  });

  final DateTime expiresAt;
  final int expirySeconds;
  final VoidCallback onChange;
  final VoidCallback? onExpired;
  final bool changing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CountdownBuilder(
      expiresAt: expiresAt,
      onExpired: onExpired,
      builder: (context, remaining) {
        final ratio = expirySeconds <= 0
            ? 0.0
            : (remaining.inMilliseconds / (expirySeconds * 1000)).clamp(0.0, 1.0);
        final color = remaining.inMinutes < 5
            ? kDanger
            : remaining.inMinutes < 60
            ? const Color(0xFFC08243)
            : kAccent;
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .075),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: .12)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
                child: Row(
                  children: [
                    Icon(Icons.timer_outlined, size: 15, color: color),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        remaining.inSeconds <= 0
                            ? 'This conversation has expired'
                            : 'Disappears in ${formatRemaining(remaining)}',
                        style: TextStyle(
                          color: scheme.onSurface.withValues(alpha: .72),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.1,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: changing ? null : onChange,
                      style: TextButton.styleFrom(
                        foregroundColor: color,
                        minimumSize: const Size(0, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: changing
                          ? SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.8,
                                color: color,
                              ),
                            )
                          : const Text(
                              'Change',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: ratio, end: ratio),
                duration: const Duration(milliseconds: 500),
                builder: (_, value, __) => LinearProgressIndicator(
                  value: value,
                  minHeight: 2.5,
                  backgroundColor: color.withValues(alpha: .10),
                  color: color,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
