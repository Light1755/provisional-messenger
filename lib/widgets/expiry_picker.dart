import 'package:flutter/material.dart';

import '../core/env.dart';
import '../core/format.dart';
import '../core/theme.dart';
import 'ui.dart';

Future<int?> showExpiryPicker(
  BuildContext context, {
  required int selectedSeconds,
  required String title,
  required String description,
  required String confirmLabel,
  bool highlightDefault = false,
}) {
  return showAppSheet<int>(
    context,
    child: _ExpirySheet(
      selectedSeconds: selectedSeconds,
      title: title,
      description: description,
      confirmLabel: confirmLabel,
      highlightDefault: highlightDefault,
    ),
  );
}

class _ExpirySheet extends StatefulWidget {
  const _ExpirySheet({
    required this.selectedSeconds,
    required this.title,
    required this.description,
    required this.confirmLabel,
    required this.highlightDefault,
  });

  final int selectedSeconds;
  final String title;
  final String description;
  final String confirmLabel;
  final bool highlightDefault;

  @override
  State<_ExpirySheet> createState() => _ExpirySheetState();
}

class _ExpirySheetState extends State<_ExpirySheet> {
  late int _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.selectedSeconds;
  }

  List<int> get _options {
    final values = <int>{...Env.expiryOptions};
    if (_selected >= 300 && _selected <= 2592000) values.add(_selected);
    final sorted = values.toList()..sort();
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SoftIcon(
                icon: Icons.timer_outlined,
                size: 42,
                iconSize: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.description,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: scheme.onSurface.withValues(alpha: .55),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          ..._options.map((seconds) {
            final selected = seconds == _selected;
            final isDefault = seconds == Env.defaultExpirySeconds;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => setState(() => _selected = seconds),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? kAccent.withValues(alpha: .09)
                          : scheme.onSurface.withValues(alpha: .025),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: selected
                            ? kAccent.withValues(alpha: .38)
                            : scheme.onSurface.withValues(alpha: .06),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          selected
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: selected
                              ? kAccent
                              : scheme.onSurface.withValues(alpha: .22),
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            expiryLabel(seconds),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              letterSpacing: -.2,
                            ),
                          ),
                        ),
                        if (isDefault && widget.highlightDefault)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: kAccent.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text(
                              'Default',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: kAccent,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 10),
          PrimaryButton(
            label: widget.confirmLabel,
            onPressed: () => Navigator.of(context).pop(_selected),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              'The countdown is fixed. New messages do not extend it.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                color: scheme.onSurface.withValues(alpha: .4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
