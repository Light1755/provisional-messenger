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

The job should be active on `* * * * *`. The health check should return `"ok": true`.

6. Open Project Settings, API. Copy the Project URL and the anon public key.

If you change the schema later, edit the migration in `supabase/migrations/` and copy it over `supabase/setup.sql`. The two files must stay identical.

## 2. Web on GitHub Pages

The workflow is [`.github/workflows/deploy-web.yml`](../.github/workflows/deploy-web.yml).

1. Push the repository to GitHub with `main` as the default branch.
2. In the repository, open Settings, Pages. Set Build and deployment to GitHub Actions.
3. Open Settings, Secrets and variables, Actions, Variables. Add:
   - `SUPABASE_URL`: the Project URL.
   - `SUPABASE_ANON_KEY`: the anon public key or `sb_publishable_` key.
   - `PAGES_BASE_HREF` (optional): the path the site is served from, with a leading and trailing slash. Leave it unset for a normal project page. The workflow computes `/<repo>/` for project pages and `/` for a `<user>.github.io` repository.
4. Open Actions, select Deploy web, and run the workflow. A push to `main` also triggers it.
5. The site is published at `https://<user>.github.io/<repo>/` unless a custom domain is configured.

The workflow reads variables first and falls back to repository secrets with the same names. The anon key is public by design: it ships in the JavaScript bundle and is protected by row-level security. Variables are the better place for it because the value is not a secret.

If the variables are missing, the workflow stops before building. This prevents a public site from showing the setup screen to visitors.

The build uses `--base-href`, so the same code works at the domain root or under a repository path. No routing library is used, so no 404 fallback is needed.

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

The file is at `build/app/outputs/flutter-apk/app-release.apk`. Release builds use the signing config from `android/key.properties` described below. The application id is `com.light1755.provisionalmessenger`; keep this id and the same signing key for all future updates.

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

Edit `android/app/build.gradle.kts`:

```kotlin
import java.io.FileInputStream
import java.util.Properties

val keystoreProperties = Properties()
val keystoreFile = rootProject.file("key.properties")
if (keystoreFile.exists()) {
    keystoreProperties.load(FileInputStream(keystoreFile))
}

android {
    // ...
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
```

`android/key.properties`, `*.jks`, and `*.keystore` are already in `.gitignore`.

The `applicationId` and `namespace` are already set to `com.light1755.provisionalmessenger`. Do not change them after release: a different id installs as a separate app.

Build the store bundle with:

```bash
flutter build appbundle --release \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_OR_PUBLISHABLE_KEY
```

### Publish the APK

1. Open the repository's Releases page and create a tag such as `v1.0.0`.
2. Attach `app-release.apk`.
3. Include the signing certificate fingerprint and the supported Android version in the release notes.
4. Tell users that installing an APK from outside a store requires allowing installs from that source, and that updates must use the same signing key.

## 4. Supabase keep-alive

Free projects pause after roughly a week without activity. The workflow is [`.github/workflows/supabase-keepalive.yml`](../.github/workflows/supabase-keepalive.yml).

1. Add the same `SUPABASE_URL` and `SUPABASE_ANON_KEY` variables or secrets used by the web deploy.
2. Open Actions, select Supabase keep-alive, and run it once. The log should show `{"ok": true, ...}`.
3. Leave the schedule in place. It runs every three days and can also be started manually.

The job calls `POST /rest/v1/rpc/health_check` with the anon key. The function is executable by `anon`, reads no user data, and returns whether the expected tables exist.

GitHub can delay scheduled jobs, and it disables schedules after 60 days without repository activity. A push or a manual run re-enables them. If the repository will be dormant, point a free cron service such as cron-job.org at the same URL with the same two headers.

## 5. Release checklist

- `flutter analyze` reports no issues.
- `flutter test` passes.
- Two devices or two browser profiles can create profiles, chat, send every message type, read receipts, change the timer, burn a chat, and burn a profile.
- Expiry is tested by moving `expires_at` forward, not only by waiting.
- The production build uses the anon or publishable key, never a server key.
- The web workflow completed and the site loads from the expected base path.
- The APK is signed with the key you intend to keep using.
- `PRIVACY.md` is published and matches the deployment. The person operating the deployment is responsible for the notice and for any contact details it requires.
- The Supabase keep-alive run succeeded.
