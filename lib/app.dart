import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/supabase_key.dart';
import 'core/theme.dart';
import 'data/api.dart';
import 'screens/main_shell.dart';
import 'screens/onboarding_screen.dart';
import 'screens/setup_screen.dart';
import 'state/app_state.dart';
import 'widgets/ui.dart';

const _urlKey = 'supabase_url';
const _keyKey = 'supabase_anon_key';

class ProvisionalApp extends StatefulWidget {
  const ProvisionalApp({
    super.key,
    required this.prefs,
    required this.initialUrl,
    required this.initialKey,
    required this.bakedConfig,
  });

  final SharedPreferences prefs;
  final String initialUrl;
  final String initialKey;
  final bool bakedConfig;

  @override
  State<ProvisionalApp> createState() => _ProvisionalAppState();
}

class _ProvisionalAppState extends State<ProvisionalApp> {
  late final ValueNotifier<ThemeMode> _themeMode;
  late String _url;
  late String _key;

  AppState? _app;
  bool _connecting = false;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    _themeMode = ValueNotifier(_readTheme(widget.prefs));
    _url = widget.initialUrl.trim();
    _key = widget.initialKey.trim();
    _connecting = _url.isNotEmpty && _key.isNotEmpty;
    if (_connecting) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connectBoot());
    }
  }

  ThemeMode _readTheme(SharedPreferences prefs) {
    switch (prefs.getString('theme_mode')) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> _disposeSupabase() async {
    if (Supabase.instance.isInitialized) {
      await Supabase.instance.dispose();
    }
  }

  Future<AppState> _openClient(String url, String key) async {
    if (isServerOnlySupabaseKey(key)) {
      throw ApiException(
        'This app was configured with a server-only Supabase key. That key '
        'bypasses every database rule and can be extracted from the app. '
        'Rebuild with the anon public key or an sb_publishable_ key.',
      );
    }
    try {
      // A failed initialize can leave the singleton half-initialized. Clear it
      // before retrying so Retry is a real retry instead of a dead end.
      await _disposeSupabase();
      await Supabase.initialize(
        url: url,
        publishableKey: key,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: true),
      );
      return AppState(
        client: Supabase.instance.client,
        prefs: widget.prefs,
        themeMode: _themeMode,
      );
    } catch (e) {
      try {
        await _disposeSupabase();
      } catch (_) {
        // Preserve the original connection error.
      }
      rethrow;
    }
  }

  Future<void> _connectBoot() async {
    if (!mounted || _app != null || _url.isEmpty || _key.isEmpty) return;
    setState(() {
      _connecting = true;
      _startupError = null;
    });
    try {
      final app = await _openClient(_url, _key);
      if (!mounted) {
        app.dispose();
        return;
      }
      setState(() {
        _app = app;
        _connecting = false;
      });
      unawaited(app.initialize());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _startupError = _connectionMessage(e);
      });
    }
  }

  Future<void> _connectFromSetup(String url, String key) async {
    setState(() {
      _url = url;
      _key = key;
      _connecting = true;
      _startupError = null;
    });
    try {
      final app = await _openClient(url, key);
      await widget.prefs.setString(_urlKey, url);
      await widget.prefs.setString(_keyKey, key);
      if (!mounted) {
        app.dispose();
        return;
      }
      setState(() {
        _app = app;
        _connecting = false;
      });
      unawaited(app.initialize());
    } catch (e) {
      if (!mounted) rethrow;
      setState(() {
        _connecting = false;
        _startupError = null;
      });
      rethrow;
    }
  }

  Future<void> _resetServer() async {
    if (widget.bakedConfig) return;

    // Dispose the state while its Supabase client is still alive so channels
    // can unsubscribe. Only change saved config after teardown succeeds.
    final oldApp = _app;
    if (mounted) {
      setState(() {
        _app = null;
        _connecting = false;
      });
    }
    oldApp?.dispose();

    try {
      if (Supabase.instance.isInitialized) {
        await Supabase.instance.dispose();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _startupError =
              'The old connection could not be closed. Restart the app, then '
              'try again. (${e.toString().length > 120 ? e.toString().substring(0, 120) : e})';
        });
      }
      return;
    }
    if (Supabase.instance.isInitialized) {
      if (mounted) {
        setState(() {
          _startupError =
              'The old connection is still active. Restart the app, then try '
              'again.';
        });
      }
      return;
    }

    await widget.prefs.remove(_urlKey);
    await widget.prefs.remove(_keyKey);
    if (!mounted) return;
    setState(() {
      _url = '';
      _key = '';
      _connecting = false;
      _startupError = null;
    });
  }

  String _connectionMessage(Object error) {
    if (error is ApiException) return error.message;
    if (error is AuthException) return error.message;
    return 'The app could not initialize the connection. Check the server '
        'settings and your network.';
  }

  @override
  void dispose() {
    _app?.dispose();
    _themeMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeMode,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'Provisional Messenger',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: themeMode,
          home: _home(),
        );
      },
    );
  }

  Widget _home() {
    if (_app != null) {
      return ChangeNotifierProvider<AppState>.value(
        value: _app!,
        child: AuthGate(
          onResetServer: widget.bakedConfig ? null : _resetServer,
          bakedConfig: widget.bakedConfig,
        ),
      );
    }
    if (_connecting) {
      return const SplashScreen(label: 'Connecting to your server…');
    }
    if (_startupError != null) {
      return StartupErrorScreen(
        message: _startupError!,
        bakedConfig: widget.bakedConfig,
        onRetry: _connectBoot,
        onReset: widget.bakedConfig ? null : _resetServer,
      );
    }
    return SetupScreen(
      initialUrl: _url,
      initialKey: _key,
      onConnect: _connectFromSetup,
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({
    super.key,
    this.onResetServer,
    this.bakedConfig = false,
  });

  final Future<void> Function()? onResetServer;
  final bool bakedConfig;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    Widget child;
    switch (app.status) {
      case AppStatus.starting:
        child = const SplashScreen(
          key: ValueKey('splash'),
          label: 'Opening your private session…',
        );
      case AppStatus.needsProfile:
        child = const OnboardingScreen(key: ValueKey('onboarding'));
      case AppStatus.ready:
        child = const MainShell(key: ValueKey('shell'));
      case AppStatus.error:
        child = StartupErrorScreen(
          key: const ValueKey('error'),
          message:
              app.errorMessage ??
              'The app could not start. Check your connection and try again.',
          bakedConfig: bakedConfig,
          onRetry: app.initialize,
          onReset: onResetServer,
        );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: child,
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: .88, end: 1),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutBack,
              builder: (context, value, child) =>
                  Transform.scale(scale: value, child: child),
              child: const AppLogo(size: 76),
            ),
            const SizedBox(height: 26),
            Text(
              'Provisional',
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w800,
                letterSpacing: -.7,
                color: scheme.onSurface,
              ),
            ),
            if (label != null) ...[
              const SizedBox(height: 10),
              Text(
                label!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurface.withValues(alpha: .42),
                ),
              ),
            ],
            const SizedBox(height: 28),
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: kAccent.withValues(alpha: .7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
