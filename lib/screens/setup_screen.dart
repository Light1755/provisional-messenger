import 'package:flutter/material.dart';

import '../core/supabase_key.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../widgets/ui.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.onConnect,
    this.initialUrl = '',
    this.initialKey = '',
  });

  final Future<void> Function(String url, String key) onConnect;
  final String initialUrl;
  final String initialKey;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _urlController;
  late final TextEditingController _keyController;
  bool _obscureKey = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.initialUrl);
    _keyController = TextEditingController(text: widget.initialKey);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    final url = _normalizeUrl(_urlController.text);
    final key = _keyController.text.trim();

    String? problem;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty) {
      problem = 'Enter the full Project URL, like https://abcde.supabase.co';
    } else if (key.length < 20) {
      problem = 'Paste the anon public key from Supabase.';
    } else if (isServerOnlySupabaseKey(key)) {
      problem =
          'That is a server-only key (service_role or sb_secret_). Anyone can '
          'extract it from an app, and it bypasses every database rule. Use '
          'the anon public key or an sb_publishable_ key instead.';
    }

    if (problem != null) {
      setState(() => _error = problem);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _urlController.text = url;
    });

    try {
      await Api.testConnection(url, key);
      await widget.onConnect(url, key);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException
            ? e.message
            : 'Could not connect. Check the URL, key, and your network.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _normalizeUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return value;
    if (!value.contains('://')) value = 'https://$value';
    value = value.replaceAll(RegExp(r'/+$'), '');
    value = value.replaceAll(RegExp(r'/rest/v1$'), '');
    return value;
  }

  void _showHelp() {
    showAppSheet<void>(
      context,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Connect Supabase',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w800,
                letterSpacing: -.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'The free tier is enough for a small private messenger.',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.45,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .55),
              ),
            ),
            const SizedBox(height: 18),
            const _SetupStep(
              number: '1',
              title: 'Create a Supabase project',
              body: 'supabase.com → New project. Wait for the database to finish.',
            ),
            const _SetupStep(
              number: '2',
              title: 'Run supabase/setup.sql',
              body:
                  'Open SQL Editor in Supabase, paste the whole file from this '
                  'project, and run it once.',
            ),
            const _SetupStep(
              number: '3',
              title: 'Enable anonymous sign-ins',
              body:
                  'Authentication → Providers → Anonymous → Enable. Usernames '
                  'need no password.',
            ),
            const _SetupStep(
              number: '4',
              title: 'Copy the URL and anon key',
              body:
                  'Project Settings → API. Use the Project URL and the anon '
                  'public key, never the service_role key.',
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: kAccent.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kAccent.withValues(alpha: .16)),
              ),
              child: const Text(
                'For a shareable build, bake the values in with '
                '--dart-define=SUPABASE_URL=... and '
                '--dart-define=SUPABASE_ANON_KEY=... so people never see this '
                'screen.',
                style: TextStyle(fontSize: 12, height: 1.45, color: kAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Stack(
        children: [
          Positioned(
            top: -160,
            right: -120,
            child: Container(
              width: 360,
              height: 360,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    kAccent.withValues(alpha: .13),
                    kAccent.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const AppLogo(size: 44),
                          const SizedBox(width: 12),
                          const Text(
                            'Provisional',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.5,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: _showHelp,
                            child: const Text('Setup guide'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 42),
                      const Text(
                        'Connect your server',
                        style: TextStyle(
                          fontSize: 33,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.1,
                          height: 1.05,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'This one-time step links the app to your own free '
                        'Supabase project. The values are stored on this '
                        'device only.',
                        style: TextStyle(
                          fontSize: 14.5,
                          height: 1.5,
                          color: scheme.onSurface.withValues(alpha: .55),
                        ),
                      ),
                      const SizedBox(height: 26),
                      SectionCard(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const InlineFieldLabel('Project URL'),
                            TextField(
                              controller: _urlController,
                              enabled: !_busy,
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                hintText: 'https://your-project.supabase.co',
                              ),
                            ),
                            const SizedBox(height: 16),
                            InlineFieldLabel(
                              'Anon public key',
                              trailing: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: kAccent.withValues(alpha: .1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text(
                                  'safe for apps',
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: kAccent,
                                  ),
                                ),
                              ),
                            ),
                            TextField(
                              controller: _keyController,
                              enabled: !_busy,
                              obscureText: _obscureKey,
                              autocorrect: false,
                              enableSuggestions: false,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _submit(),
                              decoration: InputDecoration(
                                hintText: 'eyJhbGciOi… or sb_publishable_…',
                                suffixIcon: IconButton(
                                  onPressed: () => setState(
                                    () => _obscureKey = !_obscureKey,
                                  ),
                                  icon: Icon(
                                    _obscureKey
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    size: 19,
                                  ),
                                ),
                              ),
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 14),
                              ErrorNotice(message: _error!),
                            ],
                            const SizedBox(height: 18),
                            PrimaryButton(
                              label: 'Test & continue',
                              icon: Icons.arrow_forward_rounded,
                              loading: _busy,
                              onPressed: _submit,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 15,
                            color: scheme.onSurface.withValues(alpha: .38),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              'Only paste the anon public key. A service_role '
                              'key would give anyone full database access.',
                              style: TextStyle(
                                fontSize: 11.5,
                                height: 1.4,
                                color: scheme.onSurface.withValues(alpha: .4),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupStep extends StatelessWidget {
  const _SetupStep({
    required this.number,
    required this.title,
    required this.body,
  });

  final String number;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 25,
            height: 25,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: .11),
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: kAccent,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: scheme.onSurface.withValues(alpha: .53),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StartupErrorScreen extends StatelessWidget {
  const StartupErrorScreen({
    super.key,
    required this.message,
    required this.onRetry,
    this.onReset,
    this.bakedConfig = false,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onReset;
  final bool bakedConfig;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(26),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SoftIcon(
                    icon: Icons.cloud_off_rounded,
                    color: kDanger,
                    size: 72,
                    iconSize: 32,
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Can’t reach the server',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.8,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: scheme.onSurface.withValues(alpha: .58),
                    ),
                  ),
                  const SizedBox(height: 24),
                  PrimaryButton(
                    label: 'Try again',
                    icon: Icons.refresh_rounded,
                    onPressed: onRetry,
                  ),
                  if (onReset != null) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: OutlinedButton(
                        onPressed: onReset,
                        child: const Text('Change server settings'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    bakedConfig
                        ? 'This build’s server address is compiled in. Rebuild '
                              'with valid SUPABASE_URL and SUPABASE_ANON_KEY '
                              'values.'
                        : 'Check that the Supabase project is running, anonymous '
                              'sign-ins are enabled, and supabase/setup.sql has '
                              'been run.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      color: scheme.onSurface.withValues(alpha: .38),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
