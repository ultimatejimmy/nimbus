# Nimbus

**Zero-self-hosting, cloud-native ebook library, Whispersync progress, highlights, and reading statistics across KOReader, Calibre, and the Web.**

Nimbus uses your own cloud storage (**Google Drive**, **OneDrive**, **Dropbox**, or **WebDAV**) as the single source of truth — no VPS, no self-hosted database, and no third-party file servers.

## Monorepo Structure

- [`spec/`](spec/SCHEMA.md) — Shared Cloud Storage Layout, JSON Schemas (v1), `partial_md5` hashing spec, and cross-language golden merge fixtures.
- `koreader/nimbus.koplugin/` — Standalone KOReader plugin (Whispersync progress, highlights/notes, `statistics.sqlite3` sync, Cloud Library browser).
- `calibre/` — Calibre Companion Plugin (`NimbusCalibre.zip`) with Direct Cloud API push/pull to custom columns.
- `web/` — Serverless React + TypeScript + Tailwind PWA (`foliate-js` + `pdf.js` + IndexedDB offline cache).

## Supported Cloud Providers (100% Parity)

- **Google Drive** (via `drive.file` OAuth scope)
- **Microsoft OneDrive** (via Microsoft Graph)
- **Dropbox** (via Dropbox API v2)
- **WebDAV** (Nextcloud, Synology, Koofr, etc.)

## Documentation

Full user guides and sync architecture docs are available in the **[Nimbus Wiki](https://github.com/ultimatejimmy/nimbus/wiki)**:

- [Quick Start](https://github.com/ultimatejimmy/nimbus/wiki/Quick-Start) & [Cloud Providers](https://github.com/ultimatejimmy/nimbus/wiki/Cloud-Providers)
- Client Guides: [KOReader Plugin](https://github.com/ultimatejimmy/nimbus/wiki/KOReader-Plugin) · [Calibre Plugin](https://github.com/ultimatejimmy/nimbus/wiki/Calibre-Plugin) · [Web App (PWA)](https://github.com/ultimatejimmy/nimbus/wiki/Web-App)
- [How Sync Works](https://github.com/ultimatejimmy/nimbus/wiki/How-Sync-Works) & [FAQ / Troubleshooting](https://github.com/ultimatejimmy/nimbus/wiki/FAQ-and-Troubleshooting)
