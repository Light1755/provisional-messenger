# Deployment

This guide covers a Supabase project, a GitHub Pages web build, an Android APK, and the keep-alive job that stops a free Supabase project from pausing.

## Before you start

- Flutter 3.50.1 or newer on the build machine.
- A Supabase account and one project.
- A GitHub repository. GitHub Pages on a private repository needs a paid plan; a public repository works on the free plan.
- The anon public key or `sb_publishable_` key. Never use a `service_role` key, an `sb_secret_` key, or a personal access token in a client build.

## 1. Supabase

1. Create a project and wait for the database to become ready.
2. Open SQL Editor, paste [`../supabase/setup.sql`](../supabase/setup.sql), and run it.
3. Open Authentication, Providers, Anonymous, and enable anonymous sign-ins.
4. Open Database, Extensions. Install `pg_cron` if it is not present, then run `supabase/setup.sql` again so the cleanup job is created.
5. Run these checks in SQL Editor:

```sql
select jobname, schedule, active
from cron.job
where jobname = 'provisional-purge-expired';

select public.health_check();
```

The job should be active on `* * * * *`. The health check should return `"ok": true`, `"cron_ok": true`, and `"schema_version": 4`. The keep-alive workflow fails on any mismatch.

6. Open Project Settings, API. Copy the Project URL and the anon public key.

If you change the schema later, edit `supabase/setup.sql` and copy it over `supabase/migrations/20261124000000_init.sql`; those two files must stay byte-identical. For an already installed project, add an idempotent migration that re-runs the installer, like `supabase/migrations/20261126000000_fixes.sql`, and apply it in the SQL Editor.

## 2. Web on GitHub Pages

The workflow is [`.github/workflows/deploy-web.yml`](../.github/workflows/deploy-web.yml).

1. Push the repository to GitHub with `main` as the default branch.
2. In the repository, open Settings, Pages. Set Build and deployment to GitHub Actions.
3. Open Settings, Secrets and variables, Actions, Variables. Add:
   - `SUPABASE_URL`: the Project URL.
   - `SUPABASE_ANON_KEY`: the anon public key or `sb_publishable_` key.
   - `PAGES_BASE_HREF` (optional): override the path the site is served from, with a leading and trailing slash. Leave it unset; the workflow derives `/<repo>/` for project pages and `/` for a `<user>.github.io` repository. For this repository the value is `/provisional-messenger/`.
4. Open Actions, select Deploy web, and run the workflow. A push to `main` also triggers it.
5. The site is published at `https://<user>.github.io/<repo>/` unless a custom domain is configured.

The workflow reads variables first and falls back to repository secrets with the same names. The anon key is public by design: it ships in the JavaScript bundle and is protected by row-level security. Variables are the better place for it because the value is not a secret.

If the variables are missing, the workflow stops before building. This prevents a public site from showing the setup screen to visitors.

The build and the Pages upload use one computed `--base-href` (`/provisional-messenger/` for this repository). This app registers no custom service worker beyond Flutter's default: after a deploy, hard reload (Ctrl/Cmd+Shift+R) to pick up the new build. No routing library is used, so no 404 fallback is needed.

### Custom domain

1. Add the domain in Settings, Pages.
2. Create the DNS records GitHub shows.
3. Set the `PAGES_BASE_HREF` variable to `/` if the app is served from the domain root. If it is served from a subpath, use that path with slashes on both ends.
4. Re-run the deploy workflow.

## 3. Android APK

### Build an installable APK

```bash
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_OR_PUBLISHABLE_KEY
```

Version 1.0.3 has `versionCode = 4` and `versionName = "1.0.3"`, pinned in `android/app/build.gradle.kts` and matching `pubspec.yaml` (`1.0.3+4`). The APK lands at `build/app/outputs/flutter-apk/app-release.apk`; copy it to `provisional-messenger-v1.0.3.apk` for upload. Release builds use the signing config described below and fail with a clear Gradle error when it is missing; they never fall back to debug signing. Debug builds work with no keystore. The application id is `com.light1755.provisionalmessenger`; keep this id and the same signing key for all future updates.

### Create a release keystore

Run once and keep the file and passwords outside the repository:

```powershell
keytool -genkey -v `
  -keystore "$env:USERPROFILE\provisional-release.jks" `
  -keyalg RSA -keysize 2048 -validity 10000 `
  -alias provisional
```

Create `android/key.properties`:

```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=provisional
storeFile=C:/Users/YOU/provisional-release.jks
```

Use forward slashes in `storeFile`. Java properties treat backslashes as escapes.

`android/app/build.gradle.kts` reads those four values from `android/key.properties`, or from the environment in CI: `KEYSTORE_FILE`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, and `KEY_PASSWORD`. Release tasks (`assembleRelease`, `bundleRelease`) stop with a clear Gradle error if any value is missing or the store file does not exist; debug builds are unaffected. No Gradle edit is needed to add signing.

For CI, store the keystore as base64 in the secret `ANDROID_KEYSTORE_BASE64` and add `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD`. The Android job decodes it into the runner's temporary directory and exports the four runtime variables for that step only. Signing material is never committed or logged.

`android/key.properties`, `*.jks`, and `*.keystore` are already in `.gitignore`. Keep the keystore outside directories that may be cleaned automatically. Local release uploads must use the configured keystore.

The `applicationId` and `namespace` are already set to `com.light1755.provisionalmessenger`. Do not change them after release: a different id installs as a separate app.

Build the store bundle with:

```bash
flutter build appbundle --release \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_OR_PUBLISHABLE_KEY
```

Copy the bundle to `provisional-messenger-v1.0.3.aab` for upload. CI checks that both outputs exist, are non-trivial in size, and logs their SHA-256 digests.

### Publish the APK

1. Open the repository's Releases page in an authenticated browser session, or use a fine-grained PAT with `Contents` and `Releases` write access for API/CLI publishing. Create a tag such as `v1.0.3`.
2. Attach `provisional-messenger-v1.0.3.apk` (and the `.aab` if you distribute through a store).
3. Include the signing certificate fingerprint and the supported Android version in the release notes. Read the fingerprint with:
   ```bash
   keytool -list -v -keystore /path/to/provisional-release.jks -alias provisional | grep SHA-256
   ```
4. Tell users that installing an APK from outside a store requires allowing installs from that source, and that updates must use the same signing key.

## 4. Supabase keep-alive

Free projects pause after roughly a week without activity. The workflow is [`.github/workflows/supabase-keepalive.yml`](../.github/workflows/supabase-keepalive.yml).

1. Add the same `SUPABASE_URL` and `SUPABASE_ANON_KEY` variables or secrets used by the web deploy. If unset, the workflow falls back to this project's public URL and publishable key.
2. Open Actions, select Supabase keep-alive, and run it once. The log prints only `ok`, `cron_ok`, `schema_version`, and `app`.
3. Leave the schedule in place. It runs every three days and can also be started manually. The step fails if `ok` or `cron_ok` is not `true`, or `schema_version` is not `4`.

The job calls `/rest/v1/rpc/health_check` with the publishable/anon key. The function is executable by `anon`, reads no user data, and reports table presence, cron status, and schema version.

GitHub can delay scheduled jobs, and it disables schedules after 60 days without repository activity. A push or a manual run re-enables them. If the repository will be dormant, point a free cron service such as cron-job.org at the same URL with the same two headers.

## 5. Release checklist

- `flutter analyze --fatal-infos` reports no issues and `flutter test` passes.
- The web and signed Android CI build jobs pass; artifact SHA-256 digests are recorded.
- `pubspec.yaml` is `1.0.3+4`, `Env.appVersion` is `1.0.3`, and the Gradle version is `4` / `1.0.3`.
- Two devices or two browser profiles can create profiles, chat, send every message type, read receipts, change the timer, burn a chat, and burn a profile.
- After a profile is created, the device has no logout or start-over control; only a successful profile burn returns it to username creation.
- Expiry is tested by moving `expires_at` forward, not only by waiting.
- The production build uses the anon or publishable key, never a server key; CI rejects empty or wrong values before building.
- The web workflow completed, the site loads from `/provisional-messenger/`, and a hard reload picked up the new build (no app-specific service worker).
- `provisional-messenger-v1.0.3.apk` and `provisional-messenger-v1.0.3.aab` are signed with the key you intend to keep using, and the signing fingerprint is in the release notes.
- GitHub publishing uses browser auth or a fine-grained PAT with `Contents` and `Releases`.
- `PRIVACY.md` is published and matches the deployment. The person operating the deployment is responsible for the notice and for any contact details it requires.
- The Supabase keep-alive run succeeded with `ok: true`, `cron_ok: true`, and `schema_version: 4`.
