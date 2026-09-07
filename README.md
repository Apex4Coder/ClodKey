<div align="center">

# ☕ ClodKey

**Tray flyout key manager for Anthropic · Claude CLI**

Zero-install · zero-console-windows · zero dependencies

[![CI](https://github.com/Apex4Coder/ClodKey/actions/workflows/ci.yml/badge.svg)](https://github.com/Apex4Coder/ClodKey/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Apex4Coder/ClodKey?include_prereleases&label=release)](https://github.com/Apex4Coder/ClodKey/releases/latest)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-lightgrey)](#-quick-start)
[![Runtime](https://img.shields.io/badge/runtime-PowerShell%205.1%20%2B%20WinForms-blue)](#-why-this-stack)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Locales](https://img.shields.io/badge/UI-ru%20·%20en%20·%20zh%20·%20es-orange)](app-next/strings.json)

*One `.ps1` file. Ships with Windows. Lives in your tray.*

![light](assets/screenshots/panel-light.png#gh-light-mode-only)![dark](assets/screenshots/panel-dark.png#gh-dark-mode-only)

</div>

---

## ✨ What it does

- 🫥 **Starts invisible.** Launched via WMI `CREATE_NO_WINDOW` + `FreeConsole()` —
  no console window ever exists (visible *or* hidden). Gate-tested: `check-g22.ps1`.
- 🎛 **Flyout from the tray.** Click the icon — a mini neumorphic panel slides up
  from the tray corner (eased slide + fade). Click again — it hides. `✕` = hide, never quit.
- 🔑 **Profiles of keys.** Base URL + API key (masked, 👁 reveal), auth mode
  (`ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / both).
- 🛡 **DPAPI at rest.** Keys encrypted with Windows DPAPI (CurrentUser) + entropy salt.
  The file is useless on another machine or under another user.
- 📥 **System import.** On startup it discovers existing `ANTHROPIC_*` env vars and
  `~/.claude/settings.json` and offers them as the "System" profile.
- 🚀 **One-click apply.** Writes the profile into the `env` block of
  `~/.claude/settings.json` (with `.clodkey.bak` backup). Restart `claude` — done.
- 🌗 **Light / dark themes, 4 languages** — micro icon buttons in the header
  (`Я A 文 Ñ` · `☀/☾` · `☕` · `✕`), persisted across restarts.
- 🎨 **Soft neumorphism** — tokens from canonical
  [themesberg/neumorphism-ui-bootstrap](https://github.com/themesberg/neumorphism-ui-bootstrap):
  raised = two soft offset shadows, pressed/input = inset. No borders, no gradients.

## 🚀 Quick start

```powershell
# 1. clone or download
git clone https://github.com/Apex4Coder/ClodKey
cd ClodKey

# 2. run (double-click works too) - no console, no window, just a tray icon
powershell -ExecutionPolicy Bypass -File deploy.ps1   # installs live\ and launches it
```

Or skip deploy: double-click `app-next\run-hidden.vbs`.

| File | What |
| --- | --- |
| `app-next\run-hidden.vbs` | launch with zero windows (WMI `CREATE_NO_WINDOW`) |
| `deploy-next.bat` | copy `app-next` → `live`, backup old, relaunch, verify alive |
| `check-g22.ps1` | gate: assert zero console windows owned by the app |

## 🧰 Why this stack

| Constraint | Choice |
| --- | --- |
| runs on *any* Windows machine | PowerShell 5.1 + WinForms — part of the OS, nothing to install |
| AV-safe, auditable | zero binary deps, single readable `.ps1` |
| no console flash ever | WMI `CREATE_NO_WINDOW` + `FreeConsole()` (DETACHED_PROCESS kills powershell on Win11 — measured) |
| secrets | DPAPI CurrentUser + entropy; ciphertext in `data\secrets.json` |
| state survives deploys | `data\` and `logs\` live **outside** the release (GOLD §1.2) |

## 🏗 Architecture

```
ClodKey/
├── app-next/            # the app (source of truth)
│   ├── ClodKey.ps1      # UI + DPAPI + apply + selftest + shot
│   ├── strings.json     # ru / en / zh / es (UI text = data, not code)
│   ├── run-hidden.vbs   # WMI hidden launch
│   └── start-clodkey.bat
├── deploy.ps1           # next -> live: stop own -> backup -> copy -> launch -> verify
├── check-g22.ps1        # zero-console-window gate
├── make-shots.ps1       # render light/dark evidence
└── .github/             # CI, issue forms, PR template, security policy
```

Every tray action has a **CLI twin** (GOLD principle — clicks are untestable, commands are):

```powershell
powershell -STA -File app-next\ClodKey.ps1 -Smoke      # UI builds, DPAPI roundtrip
powershell -STA -File app-next\ClodKey.ps1 -SelfTest   # save/apply/import/lang/theme/layout asserts
powershell -STA -File app-next\ClodKey.ps1 -Shot       # renders logs\shot.png
```

## 🧪 Invariants (each paid for by a real bug)

- `.ps1`/`.bat`/`.vbs` are **ASCII-only** (OEM codepage turns Cyrillic in code into garbage);
  UI text lives in UTF-8 `strings.json`.
- `Application::Run()` without a form argument; GUI process never `detached`.
- No silent defaults: unknown DPAPI format → empty + log, never a guess.
- Layout is **measured** (`Do-Layout`), not hardcoded pixels — fixed coords broke at DPI ≠ 100%.
- CI enforces all of the above on every push.

## ❓ FAQ

**Why is there no installer?** There is nothing to install. The app is one script
the OS already has a runtime for.

**Where are my keys?** `data\secrets.json`, DPAPI-encrypted for *your* Windows user.
Copy it to another machine and it is unreadable.

**Can I run two instances?** No — single-instance mutex; the second one exits silently.

**The tray icon is hidden under the chevron?** Windows does that to all new icons.
Settings → Personalization → Taskbar → Other system tray icons → show ClodKey.

## 🤝 Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) — the GOLD invariants are the contract.
Bugs & ideas: [issue forms](../../issues/new/choose). Security: [SECURITY.md](SECURITY.md).

## 📄 License

[MIT](LICENSE)
