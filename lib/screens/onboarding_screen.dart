import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/routes.dart';
import '../core/theme.dart';
import '../core/username.dart';
import '../data/api.dart';
import '../state/app_state.dart';
import '../widgets/ui.dart';
import 'privacy_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final FocusNode _usernameFocus = FocusNode();

  bool _creating = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _usernameFocus.dispose();
    super.dispose();
  }

  void _openCreate() {
    setState(() {
      _creating = true;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _usernameFocus.requestFocus();
    });
  }

  void _closeCreate() {
    FocusScope.of(context).unfocus();
    setState(() {
      _creating = false;
      _error = null;
    });
  }

  void _onUsernameChanged(String value) {
    final normalized = normalizeUsername(value);
    if (normalized != value) {
      _usernameController.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
    }
    setState(() => _error = null);
  }

  Future<void> _create() async {
    if (_busy) return;
    final username = normalizeUsername(_usernameController.text);
    if (!usernameLooksValid(username)) {
      setState(() => _error = usernameError(username) ?? 'Choose a username.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().createProfile(username);
      HapticFeedback.mediumImpact();
      // AuthGate replaces this screen when the profile is ready.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException
            ? e.message
            : 'The username could not be claimed. Try again.';
        _busy = false;
      });
    }
  }

  void _openPrivacy() {
    Navigator.of(
      context,
    ).push(appPageRoute<void>(const PrivacyScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 420),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            final slide = Tween<Offset>(
              begin: const Offset(.055, 0),
              end: Offset.zero,
            ).animate(animation);
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(position: slide, child: child),
            );
          },
          child: _creating ? _buildCreate() : _buildWelcome(),
        ),
      ),
    );
  }

  Widget _buildWelcome() {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      key: const ValueKey('welcome'),
      children: [
        Positioned(
          top: -180,
          left: -120,
          child: Container(
            width: 420,
            height: 420,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  kAccent.withValues(alpha: .14),
                  kAccent.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(26, 22, 26, 28),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const AppLogo(size: 38),
                          const SizedBox(width: 10),
                          const Text(
                            'Provisional',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.5,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: kAccent.withValues(alpha: .09),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: kAccent.withValues(alpha: .13),
                              ),
                            ),
                            child: const Text(
                              'PRIVATE BY DESIGN',
                              style: TextStyle(
                                fontSize: 8.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: .8,
                                color: kAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 48),
                      const AppLogo(size: 82),
                      const SizedBox(height: 27),
                      Text(
                        'Say what you need.\nThen let it disappear.',
                        style: TextStyle(
                          fontSize: 34,
                          height: 1.08,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.35,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Anonymous, expiring conversations. No phone number, '
                        'email, or password. Choose a username and talk.',
                        style: TextStyle(
                          fontSize: 14.5,
                          height: 1.52,
                          color: scheme.onSurface.withValues(alpha: .55),
                        ),
                      ),
                      const SizedBox(height: 32),
                      SectionCard(
                        padding: const EdgeInsets.fromLTRB(17, 18, 17, 6),
                        child: Column(
                          children: [
                            const FeatureRow(
                              icon: Icons.person_outline_rounded,
                              title: 'No personal details',
                              body:
                                  'A username is the whole account. Nothing to '
                                  'verify, nothing to recover.',
                            ),
                            Divider(
                              height: 22,
                              color: scheme.onSurface.withValues(alpha: .06),
                            ),
                            const FeatureRow(
                              icon: Icons.timer_outlined,
                              title: 'Every chat expires',
                              body:
                                  'Pick a timer when the conversation starts. '
                                  'Messages never extend it.',
                            ),
                            Divider(
                              height: 22,
                              color: scheme.onSurface.withValues(alpha: .06),
                            ),
                            const FeatureRow(
                              icon: Icons.local_fire_department_outlined,
                              title: 'Burn it in one tap',
                              body:
                                  'Either person can delete the entire '
                                  'conversation for both sides, at any time.',
                            ),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                      const SizedBox(height: 30),
                      PrimaryButton(
                        label: 'Choose a username',
                        icon: Icons.arrow_forward_rounded,
                        onPressed: _openCreate,
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: TextButton.icon(
                          onPressed: _openPrivacy,
                          icon: const Icon(
                            Icons.shield_outlined,
                            size: 16,
                            color: kAccent,
                          ),
                          label: const Text(
                            'How your data is handled',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Center(
                        child: Text(
                          'No account recovery. Access lives on this device.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurface.withValues(alpha: .35),
                          ),
                        ),
                      ),
                      SizedBox(height: constraints.maxHeight > 760 ? 12 : 0),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildCreate() {
    final scheme = Theme.of(context).colorScheme;
    final username = _usernameController.text;
    final validation = usernameError(username);
    final valid = usernameLooksValid(username);

    return SingleChildScrollView(
      key: const ValueKey('create'),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 30),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: _busy ? null : _closeCreate,
                    style: IconButton.styleFrom(
                      backgroundColor: scheme.onSurface.withValues(alpha: .05),
                    ),
                    icon: const Icon(Icons.arrow_back_rounded, size: 20),
                  ),
                  const Spacer(),
                  Text(
                    'ONE LAST STEP',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                      color: scheme.onSurface.withValues(alpha: .38),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 34),
              Center(
                child: Avatar(
                  username: username.isEmpty ? '?' : username,
                  accent: 0,
                  size: 86,
                ),
              ),
              const SizedBox(height: 26),
              const Center(
                child: Text(
                  'Claim a username',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 31,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1,
                  ),
                ),
              ),
              const SizedBox(height: 9),
              Center(
                child: Text(
                  'This is how people find you. It is unique and public to '
                  'anyone who searches it. It is removed if unused for 48 hours, '
                  'then anyone can claim it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.5,
                    color: scheme.onSurface.withValues(alpha: .53),
                  ),
                ),
              ),
              const SizedBox(height: 30),
              const InlineFieldLabel('Username'),
              TextField(
                controller: _usernameController,
                focusNode: _usernameFocus,
                enabled: !_busy,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: _onUsernameChanged,
                onSubmitted: (_) => _create(),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
                  LengthLimitingTextInputFormatter(24),
                ],
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.2,
                ),
                decoration: const InputDecoration(
                  prefixText: '@',
                  prefixStyle: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: kAccent,
                  ),
                  hintText: 'your_name',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 16,
                  ),
                ),
              ),
              const SizedBox(height: 9),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: validation != null
                    ? _Hint(
                        key: const ValueKey('invalid'),
                        icon: Icons.error_outline_rounded,
                        color: kDanger,
                        text: validation,
                      )
                    : valid
                    ? const _Hint(
                        key: ValueKey('valid'),
                        icon: Icons.check_circle_outline_rounded,
                        color: kOnlineGreen,
                        text: 'Looks good. Usernames are unique.',
                      )
                    : _Hint(
                        key: const ValueKey('idle'),
                        icon: Icons.info_outline_rounded,
                        color: scheme.onSurface.withValues(alpha: .36),
                        text:
                            '3–24 characters. Lowercase letters, numbers, or '
                            'underscore.',
                      ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                ErrorNotice(message: _error!),
              ],
              const SizedBox(height: 22),
              PrimaryButton(
                label: username.isEmpty ? 'Claim username' : 'Claim @$username',
                loading: _busy,
                onPressed: valid ? _create : null,
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: .03),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: scheme.onSurface.withValues(alpha: .06),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 17,
                      color: scheme.onSurface.withValues(alpha: .42),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'No password. Your session is tied to this device. '
                        'If you clear app data or lose it, the username cannot '
                        'be recovered. Burn it any time, or leave it unused for '
                        '48 hours to release it.',
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: scheme.onSurface.withValues(alpha: .46),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: _busy ? null : _openPrivacy,
                  child: const Text(
                    'Read the privacy limits',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 11.5, height: 1.35, color: color),
          ),
        ),
      ],
    );
  }
}
