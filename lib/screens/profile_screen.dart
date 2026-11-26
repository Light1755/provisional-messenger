import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/env.dart';
import '../core/routes.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../state/app_state.dart';
import '../widgets/ui.dart';
import 'privacy_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _burning = false;

  Future<void> _confirmBurn() async {
    final app = context.read<AppState>();
    final confirmed = await showAppSheet<bool>(
      context,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SoftIcon(
                  icon: Icons.local_fire_department_outlined,
                  color: kDanger,
                  size: 46,
                  iconSize: 22,
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(
                    'Burn everything?',
                    style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.6,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'This deletes your username, your profile, and every '
              'conversation you are in. Messages, photos, files, and voice '
              'notes are removed for you and for the other person in each '
              'chat.',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.55,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .62),
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: kDanger.withValues(alpha: .07),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: kDanger.withValues(alpha: .16)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _BurnLine('Your username becomes available to others.'),
                  _BurnLine('There is no archive, restore, or undo.'),
                  _BurnLine(
                    'Supabase backups and logs may retain copies until they '
                    'rotate. Files or screenshots already saved on another '
                    'device are out of reach.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            PrimaryButton(
              label: 'Burn profile and all data',
              danger: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Keep my profile'),
              ),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;
    setState(() => _burning = true);
    try {
      await app.burnProfile();
      HapticFeedback.mediumImpact();
      // AuthGate switches to onboarding when the new anonymous session is
      // ready, so this screen is removed by the app shell.
    } catch (e) {
      if (!mounted) return;
      setState(() => _burning = false);
      showAppSnack(
        context,
        e is ApiException
            ? e.message
            : 'The profile could not be burned. Try again.',
        error: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final me = app.me;
    if (me == null) return const SizedBox.shrink();

    final active = app.conversations
        .where((conversation) => !conversation.isExpired)
        .length;
    final unread = app.unreadTotal;

    return SafeArea(
      bottom: false,
      child: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
            children: [
              const Text(
                'Profile',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.2,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                'One username. No personal details.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurface.withValues(alpha: .45),
                ),
              ),
              const SizedBox(height: 20),
              SectionCard(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                child: Column(
                  children: [
                    Avatar(
                      username: me.username,
                      accent: me.accent,
                      size: 78,
                      showBorder: true,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '@${me.username}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.6,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Joined ${me.createdAt.year} · session on this device',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurface.withValues(alpha: .42),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      decoration: BoxDecoration(
                        color: scheme.onSurface.withValues(alpha: .03),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: scheme.onSurface.withValues(alpha: .055),
                        ),
                      ),
                      child: Row(
                        children: [
                          _Stat(value: '$active', label: 'Active chats'),
                          _StatDivider(),
                          _Stat(value: '$unread', label: 'Unread'),
                          _StatDivider(),
                          const _Stat(
                            value: '24h',
                            label: 'Default timer',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const SectionLabel('Appearance', padding: EdgeInsets.only(left: 4, bottom: 8)),
              SectionCard(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    _ThemeChoice(
                      icon: Icons.brightness_auto_rounded,
                      label: 'System',
                      selected: app.themeMode.value == ThemeMode.system,
                      onTap: () => _setTheme(app, ThemeMode.system),
                    ),
                    _ThemeChoice(
                      icon: Icons.light_mode_outlined,
                      label: 'Light',
                      selected: app.themeMode.value == ThemeMode.light,
                      onTap: () => _setTheme(app, ThemeMode.light),
                    ),
                    _ThemeChoice(
                      icon: Icons.dark_mode_outlined,
                      label: 'Dark',
                      selected: app.themeMode.value == ThemeMode.dark,
                      onTap: () => _setTheme(app, ThemeMode.dark),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const SectionLabel('Privacy', padding: EdgeInsets.only(left: 4, bottom: 8)),
              SectionCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _ProfileTile(
                      icon: Icons.shield_outlined,
                      title: 'Privacy & limits',
                      subtitle: 'What is stored, deleted, and out of reach',
                      onTap: () => Navigator.of(
                        context,
                      ).push(appPageRoute<void>(const PrivacyScreen())),
                    ),
                    Divider(
                      height: 1,
                      indent: 66,
                      color: scheme.onSurface.withValues(alpha: .06),
                    ),
                    const _ProfileTile(
                      icon: Icons.timer_outlined,
                      title: 'Every chat is on a timer',
                      subtitle:
                          '1 hour to 7 days. New messages do not extend it.',
                    ),
                    Divider(
                      height: 1,
                      indent: 66,
                      color: scheme.onSurface.withValues(alpha: .06),
                    ),
                    const _ProfileTile(
                      icon: Icons.local_fire_department_outlined,
                      title: 'Burn is immediate',
                      subtitle:
                          'No confirmation and no undo for conversations.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const SectionLabel('Danger zone', padding: EdgeInsets.only(left: 4, bottom: 8)),
              SectionCard(
                borderColor: kDanger.withValues(alpha: .16),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const SoftIcon(
                          icon: Icons.local_fire_department_outlined,
                          color: kDanger,
                          size: 42,
                          iconSize: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Burn profile',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.3,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Deletes your username, profile, and every conversation '
                      'you are part of — including all messages, photos, '
                      'files, and voice notes. Your username is no longer '
                      'searchable. There is no recovery.',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: scheme.onSurface.withValues(alpha: .55),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: _burning ? null : _confirmBurn,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: kDanger,
                          side: BorderSide(
                            color: kDanger.withValues(alpha: .3),
                          ),
                        ),
                        icon: const Icon(
                          Icons.local_fire_department_outlined,
                          size: 18,
                        ),
                        label: const Text(
                          'Burn profile and all data',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: Text(
                  '${Env.appName} ${Env.appVersion}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface.withValues(alpha: .32),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  'No analytics · no ad SDK',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: scheme.onSurface.withValues(alpha: .28),
                  ),
                ),
              ),
            ],
          ),
          if (_burning)
            Positioned.fill(
              child: ColoredBox(
                color: scheme.surface.withValues(alpha: .94),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'Burning everything',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Removing your chats, files, and profile…',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface.withValues(alpha: .5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _setTheme(AppState app, ThemeMode mode) {
    if (app.themeMode.value == mode) return;
    HapticFeedback.selectionClick();
    unawaited(app.setThemeMode(mode));
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface.withValues(alpha: .42),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 28,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .07),
    );
  }
}

class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? kAccent.withValues(alpha: .1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? kAccent.withValues(alpha: .3)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected
                    ? kAccent
                    : scheme.onSurface.withValues(alpha: .45),
              ),
              const SizedBox(height: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? kAccent
                      : scheme.onSurface.withValues(alpha: .55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
      child: Row(
        children: [
          SoftIcon(icon: icon, size: 38, iconSize: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: scheme.onSurface.withValues(alpha: .44),
                  ),
                ),
              ],
            ),
          ),
          if (onTap != null)
            Icon(
              Icons.chevron_right_rounded,
              size: 19,
              color: scheme.onSurface.withValues(alpha: .25),
            ),
        ],
      ),
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: content),
    );
  }
}

class _BurnLine extends StatelessWidget {
  const _BurnLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.remove_rounded, size: 12, color: kDanger),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .54),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
