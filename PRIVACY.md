# Privacy notice

Effective 25 November 2026

Provisional Messenger is a two-person messenger where conversations expire or are burned. This notice describes the data handled by the app and by the services it uses. It applies to the self-hosted code in this repository. Whoever deploys a copy is responsible for that deployment and should publish their own contact details.

## Short version

- A username is the only account detail. There is no email, phone number, password, contact upload, analytics SDK, or advertising SDK.
- Messages and attachments are stored in Supabase until the chat timer ends or either person burns the chat.
- The app is not end-to-end encrypted. The hosting provider can technically process stored content.
- Deletion removes rows from the live database. Provider backups, logs, and temporary storage may retain copies until they rotate.
- Screenshots, screen recordings, and files saved by the other person are outside the app's control.
- There is no account recovery. The session is tied to one device.

## What is stored

When you create a profile:

- a random Supabase anonymous user ID;
- your username and avatar color;
- the profile creation time.

When you start a conversation:

- the two member IDs;
- the creation time, last update time, expiry duration, and expiry time;
- each member's last-read time.

When you send a message:

- the sender ID and conversation ID;
- the message type (text, file, or voice);
- the text body, for text messages;
- the file name, MIME type, size, and voice duration, for attachments;
- a client-generated idempotency ID;
- the send time.

When you send a file, photo, or voice note, the bytes are stored in a separate `message_attachments` row. The bytes are deleted when the message or conversation is deleted.

The app does not store a local message history. It keeps the server URL, anon key, theme choice, and Supabase session token on the device. The session token is what lets the device act as your anonymous account.

## Who can read content

Through the app, only the two members of a conversation can read its messages and attachments. Postgres row-level security enforces membership, and direct table writes are revoked. Reads go through database functions that check membership.

Supabase processes the database, authentication, and Realtime traffic. Its staff and systems can technically access stored data as part of operating the service. This app does not claim end-to-end encryption, zero-knowledge storage, or that the server cannot read content.

Anyone who knows your username can find the profile and start a conversation with you while the profile exists. The search screen does not expose your conversation list or messages.

## Deletion

Burning a conversation deletes its row immediately. Foreign-key cascades delete the two membership rows, every message, and every attachment. Both people lose access as soon as their client learns about the deletion, usually through Realtime, a broadcast, or the next poll.

When a timer reaches zero, the app blocks access at `expires_at`. A database job deletes expired conversations every minute. The small gap between the timer and the job is why the app says "within about a minute."

Burning a profile deletes every conversation you belong to, then your profile row. It then attempts to delete the underlying anonymous auth user. If the database role cannot delete that auth row, an opaque user ID with no username, profile, messages, or attachments may remain. It cannot be used to sign back into the burned profile.

Deletion is not a forensic erasure guarantee. Supabase backups, write-ahead logs, request logs, and temporary storage may keep copies until those systems rotate or are overwritten. The app cannot delete copies that another person already saved, screenshots, notification previews, or operating-system backups.

## Infrastructure and metadata

A deployed copy uses these providers:

- Supabase for Postgres, anonymous authentication, and Realtime. Supabase receives request metadata such as IP address, request time, and API key, and handles it under its own terms and privacy policy.
- GitHub Pages if the web build is hosted there. GitHub receives web request metadata under its own terms and privacy policy.
- The user's browser or operating system, which may keep DNS caches, browser history, downloads, and device backups.

The app does not put message content in URLs or application logs. It does not include an analytics or crash-reporting SDK. Supabase and the hosting provider may still log connection metadata and errors as part of normal operation.

## Security

Traffic between the app and Supabase uses TLS. Supabase encrypts stored data at rest. Row-level security and `security definer` functions restrict access to conversation members. The anon key is public by design and is protected by those database rules, not by secrecy.

Anonymous auth has no password. Anyone with access to an unlocked device, or to a copied session token, can act as that profile until the profile is burned or the session is revoked. Clearing app data or losing the device removes the only copy of the session.

## Children

The app is not directed at children under 13, or under the higher minimum age in their country. A self-hosted operator should set and enforce its own age policy. The app cannot verify age because it collects no identity information.

## Changes

If this notice changes, the effective date at the top will change. A deployed copy should publish the version that matches the code it runs.

## Contact

For a deployed copy, contact the person or group operating that deployment. For the source project, use the issue tracker of the repository where you obtained it.
