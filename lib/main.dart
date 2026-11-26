import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/env.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  const baked = Env.supabaseUrl;
  const bakedKey = Env.supabaseAnonKey;
  final hasBakedConfig = baked.trim().isNotEmpty && bakedKey.trim().isNotEmpty;

  final url = hasBakedConfig
      ? baked.trim()
      : (prefs.getString('supabase_url') ?? '').trim();
  final key = hasBakedConfig
      ? bakedKey.trim()
      : (prefs.getString('supabase_anon_key') ?? '').trim();

  runApp(
    ProvisionalApp(
      prefs: prefs,
      initialUrl: url,
      initialKey: key,
      bakedConfig: hasBakedConfig,
    ),
  );
}
