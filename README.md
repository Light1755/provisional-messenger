# Provisional Messenger

Provisional is a two-person messenger built around deletion. You create a username, start a chat, choose a timer, and either person can burn the chat at any time. There is no email, phone number, password, demo account, or seeded conversation.

The client is Flutter. The server is Supabase: Postgres, anonymous auth, Realtime, and a scheduled cleanup job. `supabase/setup.sql` installs the whole server side in one run.

## Features

- Username-only onboarding. Usernames are unique, lowercase, 3 to 24 characters, and searchable by prefix.
- One live conversation per pair. Starting a chat with the same person opens the existing one.
- Text messages up to 4,000 characters.
- Photos, arbitrary files, and recorded voice notes. One attachment can be up to 5 MB.
- Realtime message delivery with a 15-second polling fallback.
- Read receipts that do not loop between two open clients.
- Optimistic sends and a retry action for failed messages.
- Expiry from 1 hour to 7 days, default 24 hours. Changing the timer restarts the countdown. New messages do not extend it.
- Conversation burn for both people. The database row is deleted in one call; the other open screen closes from a broadcast or its next 15-second poll. Expired conversations are also deleted by a database job every minute.
- Profile burn: username, profile, conversations, messages, photos, files, and voice notes.
- Light, dark, and system themes. Phone and desktop layouts.
- No analytics SDK, advertising SDK, or message-content logging.

## What it does not do

- It is not end-to-end encrypted. Only the two members can read content through the app, and database rules enforce that, but Supabase processes stored data at the infrastructure level.
- It cannot stop screenshots, screen recording, or the other person saving a file.
- It cannot recover an account. The anonymous session lives on one device. Clearing app data or losing the device loses access.
- It cannot promise instant deletion from provider backups, logs, or temporary storage.
- It does not hide metadata from the hosting provider. IP addresses and request times may be processed during normal operation.
- A free Supabase project pauses after about a week without activity. The keep-alive workflow in this repository prevents that if it is enabled.

Read [PRIVACY.md](PRIVACY.md) for the longer version.

## Stack

| Layer | What is used |
| --- | --- |
| Client | Flutter 3.50, Dart 3.14, Provider, shared_preferences |
| Auth | Supabase anonymous sessions |
| Database | Supabase Postgres with row-level security |
| Realtime | Supabase Realtime Postgres changes and one broadcast event |
| Cleanup | pg_cron, every minute |
| Files | `bytea` rows in `message_attachments`, deleted by foreign-key cascade |
| Web hosting | GitHub Pages, optional |
| Android | APK via GitHub Releases, optional |

## Server model

Five tables: `profiles`, `conversations`, `conversation_members`, `messages`, and `message_attachments`.

- All writes go through `security definer` RPCs. Direct table writes are revoked.
- Row-level security limits reads to the two members of a conversation.
- File bytes live beside message metadata, not inside it, so Realtime never broadcasts a file payload.
- A unique `(sender_id, client_id)` pair makes sends idempotent, so a retry cannot create a duplicate.
- `start_conversation` takes an advisory lock for the pair, so two simultaneous taps cannot create two live chats.
- `pg_cron` calls `purge_expired_conversations()` every minute.
- `health_check()` lets the setup screen verify the URL, key, and schema before creating an account.

## Setup

### 1. Create the database

1. Create a project at [supabase.com](https://supabase.com). The free plan is enough for small use.
2. Open SQL Editor, paste the contents of [`supabase/setup.sql`](supabase/setup.sql), and run it once.
3. Open Authentication, then Providers, then Anonymous, and enable anonymous sign-ins.
4. Open Database, then Extensions. If `pg_cron` is not installed, install it and run `supabase/setup.sql` again. The script prints a notice when it cannot enable the extension itself.
5. Confirm the cleanup job exists:

```sql
select jobname, schedule, active
from cron.job
where jobname = 'provisional-purge-expired';
```

6. Optional: run `select public.health_check();` in the SQL Editor. It should return `"ok": true`.

### 2. Run the client

```bash
flutter pub get
flutter run -d chrome \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_OR_PUBLISHABLE_KEY
```

You can also run the app without `--dart-define` and paste the same two values into the setup screen. They are stored in `shared_preferences` on that device. A build with baked-in values skips the setup screen and cannot be pointed at another server without rebuilding.

Use the anon public key or an `sb_publishable_...` key. The app rejects `service_role` JWTs, `sb_secret_...` keys, and `sbp_...` personal access tokens before connecting.

### 3. Test with two people

Use two devices, or one normal browser window plus a private window. A normal and a private window have separate local sessions; two tabs in the same profile share one session.

Check these paths:

1. Create a username on each side.
2. Search for the other username and start a chat.
3. Send text, a photo, a file, and a voice note.
4. Confirm the messages arrive in realtime and read receipts clear.
5. Change the timer and confirm the countdown restarts on both sides.
6. Burn the chat from one side and confirm the other side closes.
7. Burn a profile and confirm the username disappears from search and the other side loses the chat.
8. Test expiry without waiting an hour by moving one conversation's `expires_at`:

```sql
update public.conversations
set expires_at = now() + interval '1 minute'
where id = 'YOUR_CONVERSATION_ID';
```

Wait for the minute job, then refresh both clients.

## Build for sharing

Web build:

```bash
flutter build web --release \
  --base-href="/" \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_OR_PUBLISHABLE_KEY
```

Android APK:

```bash
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_OR_PUBLISHABLE_KEY
```

The Android release build currently uses the debug signing key. That is fine for local testing, but create a real keystore before publishing an APK. The application id is still `com.example.provisional_messenger`, which should also change before a store release.

[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) has the GitHub Pages setup, the APK signing steps, and the keep-alive details.

### Branding

The launcher icon is generated from `assets/branding/icon.png` (and the transparent `icon_foreground.png` for adaptive icons) with `flutter_launcher_icons`, configured in `pubspec.yaml`. After changing either source image, regenerate all platform icons and rebuild:

```bash
dart run flutter_launcher_icons
flutter build web --release
flutter build apk --release
```

The PWA manifest, favicon, and web boot splash live under `web/`.

## Project layout

```text
lib/
  core/        configuration, theme, formatting, route transitions, key checks
  data/        Supabase RPC wrapper and models
  screens/     setup, onboarding, chats, conversation, discover, profile, privacy
  services/    voice recording, audio/file loading, attachment saving
  state/       session, profile, chat list, realtime subscriptions
  widgets/     shared UI, message bubbles, countdown, expiry picker
supabase/
  setup.sql                         complete server installer
  migrations/20261124000000_init.sql the same schema as a migration
.github/workflows/                  CI, Pages deploy, Supabase keep-alive
```

`supabase/setup.sql` and the migration file are identical. Edit both when changing the database, or edit the migration and copy it to `setup.sql`.

## Limits

- Attachment size: 5 MB, enforced in the client and in Postgres.
- Message length: 4,000 characters.
- Voice recording: 2 minutes 15 seconds on web, 10 minutes on native builds.
- Message page: 100 at a time. Older pages load with the button at the top of a chat.
- Timer choices in the UI: 1 hour, 6 hours, 24 hours, 3 days, 7 days.
- The database accepts 5 minutes to 30 days, but the app does not expose those edges.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `Anonymous sign-ins are disabled` | Authentication, Providers, Anonymous, Enable |
| `database setup is missing` | Run `supabase/setup.sql` in the SQL Editor |
| `pg_cron could not be enabled` | Install pg_cron under Database, Extensions, then rerun the script |
| Messages send but do not arrive live | Check Realtime is enabled and the three tables are in the `supabase_realtime` publication |
| Setup screen rejects the key | Use the anon public key or `sb_publishable_` key, not a server key |
| Free project is paused | Restore it in the Supabase dashboard, then run the keep-alive workflow manually |
| Old web build keeps loading | Hard refresh, or clear the site data to remove the service worker cache |

## Tests

```bash
flutter analyze
flutter test
```

The unit tests cover username normalization, expiry labels, duration formatting, and server-key rejection. The server was also validated in two ways during development: a PGlite harness that runs `setup.sql` against a real Postgres engine, and a live API suite against a Supabase project (38 checks covering auth, profiles, search, conversations, messages, attachments, read receipts, expiry, burn, and profile burn). Realtime delivery and the file/voice recording UI still need two real clients on a deployed build; see the two-person checklist above.
