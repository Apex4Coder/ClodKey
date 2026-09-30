# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| latest  | ✅        |
| < latest| ❌        |

ClodKeyProxy is a single-file app; fixes ship in the next release.

## What this app protects

Two independent contours hold credentials:

- **Claude CLI profiles** - encrypted with **Windows DPAPI (CurrentUser scope)**
  plus a project entropy salt, stored in `data\secrets.json`.
- **Zoo Bridge upstream key** - stored in plaintext in `app-next\bridge\.env`
  because the bridge is a separate node process that must read it at startup.
  That file is **gitignored on purpose**: it is machine-local state, never a
  release artifact. The tracked template is `app-next\bridge\.env.example`.

Threat model:

- **Protected:** another Windows user on the same machine, keys copied to
  another machine/account (DPAPI ciphertext is useless outside your user
  profile), accidental sync of `data\` to cloud storage (ciphertext only).
- **Not protected:** a process running as *your* user (DPAPI is per-user,
  not per-app), keylogger/malware on your session, your own clipboard use
  (the "Copy" button puts the plaintext key on the clipboard by design),
  and anyone with read access to `app-next\bridge\.env`.

## Reporting a vulnerability

Do **not** open a public issue. Use
[private vulnerability reporting](https://github.com/Apex4Coder/ClodKey/security/advisories/new)
(GitHub Security Advisories). We aim to acknowledge within 72 hours and
ship a fix within 14 days for anything rated medium or higher.

## Hardening checklist for users

- Keep `data\` out of roaming/cloud-synced folders (it is ciphertext, but
  `logs\` contains profile names and base URLs).
- Keep `app-next\bridge\.env` out of any sync/share path; `diag\` may contain
  full upstream request bodies captured on rejection.
- `logs\clodkey.log` never contains plaintext keys (masked by design);
  still, treat logs as user-level sensitive.
- If a machine is shared, do not store keys; use per-session env vars
  instead (the app reads them via "Import system" but never writes them back).
