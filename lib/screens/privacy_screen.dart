import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../widgets/ui.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: IconButton(
            onPressed: () => Navigator.of(context).pop(),
            style: IconButton.styleFrom(
              backgroundColor: scheme.onSurface.withValues(alpha: .05),
            ),
            icon: const Icon(Icons.arrow_back_rounded, size: 20),
          ),
        ),
        title: const Text('Privacy & limits'),
      ),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Built to keep less.',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Provisional is for conversations you do not want to keep. '
                      'That does not make it untraceable or anonymous to the '
                      'infrastructure it runs on. Here is the honest version.',
                      style: TextStyle(
                        fontSize: 14.5,
                        height: 1.55,
                        color: scheme.onSurface.withValues(alpha: .58),
                      ),
                    ),
                    const SizedBox(height: 28),
                    const _PrivacySection(
                      icon: Icons.storage_rounded,
                      title: 'What is stored',
                      body:
                          'Your username, the two members of each conversation, '
                          'the expiry time, messages, read times, and any file, '
                          'photo, or voice note you send. File bytes live in the '
                          'database and disappear with their message. The app '
                          'does not keep a local message history.',
                    ),
                    const _PrivacySection(
                      icon: Icons.visibility_outlined,
                      title: 'Who can read it',
                      body:
                          'Only the two people in a conversation can read its '
                          'content through the app. Database rules enforce this. '
                          'Messages are encrypted in transit and at rest by the '
                          'hosting provider, but this is not end-to-end '
                          'encryption: the server can technically process '
                          'content.',
                    ),
                    const _PrivacySection(
                      icon: Icons.local_fire_department_outlined,
                      title: 'How deletion works',
                      body:
                          'Either person can burn a conversation immediately. '
                          'The chat, messages, files, photos, and voice notes '
                          'are deleted for both people. When the timer reaches '
                          'zero, the app blocks access and a database job '
                          'deletes the conversation within about a minute. '
                          'Burning your profile deletes every conversation you '
                          'are in, then your username and profile. There is no '
                          'archive, restore, or undo in the app.',
                    ),
                    const _PrivacySection(
                      icon: Icons.backup_outlined,
                      title: 'Backups and infrastructure',
                      body:
                          'A free Supabase project is still a hosted service. '
                          'Its short-lived backups, logs, and temporary storage '
                          'may retain copies after rows are deleted, until those '
                          'are rotated by the provider. This app cannot promise '
                          'instant forensic erasure from provider backups. It '
                          'does not claim to.',
                    ),
                    const _PrivacySection(
                      icon: Icons.phone_android_rounded,
                      title: 'What this app cannot stop',
                      body:
                          'Screenshots, screen recordings, and the other person '
                          'saving a file cannot be prevented. A saved copy is '
                          'outside the app and cannot be burned. Operating '
                          'system backups or notification previews on the other '
                          'device are outside the app too.',
                    ),
                    const _PrivacySection(
                      icon: Icons.notes_outlined,
                      title: 'Logs and retention',
                      body:
                          'The app does not write message content to logs or '
                          'URLs. Connection metadata such as IP addresses and '
                          'request times may be processed by the hosting '
                          'provider as part of normal operation. There is no '
                          'advertising SDK and no analytics tracker in the app.',
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: kAccent.withValues(alpha: .07),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: kAccent.withValues(alpha: .14),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.info_outline_rounded,
                            color: kAccent,
                            size: 19,
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Text(
                              'No account recovery. Your profile is tied to a '
                              'session on this device, not to an email address or '
                              'password. Clearing app data or losing the device '
                              'means losing access. Anyone who knows your '
                              'username can still start a new conversation with '
                              'you while your profile exists. A profile unused '
                              'for 48 hours is deleted and its username becomes '
                              'available again.',
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.5,
                                color: scheme.onSurface.withValues(alpha: .62),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    Center(
                      child: Text(
                        'Last updated November 2026',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurface.withValues(alpha: .35),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacySection extends StatelessWidget {
  const _PrivacySection({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SoftIcon(icon: icon, size: 40, iconSize: 19),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.2,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 13.2,
                    height: 1.55,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: .56),
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
