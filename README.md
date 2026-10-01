<div align="center">

# ☕ ClodKey

**Tray key manager for Claude CLI + a format relay for Zoo Code / Roo Code**

No installer · no console windows · no dependencies

[![CI](https://github.com/Apex4Coder/ClodKey/actions/workflows/ci.yml/badge.svg)](https://github.com/Apex4Coder/ClodKey/actions/workflows/ci.yml)
[![platform](assets/badges/platform.svg)](#-quick-start)
[![runtime](assets/badges/runtime.svg)](#-quick-start)
[![bridge](assets/badges/bridge.svg)](#-zoo-bridge)
[![license](assets/badges/license.svg)](LICENSE)
[![UI](assets/badges/ui.svg)](#-features)
[![Fueled by LINUX SB](assets/badges/linuxsb.svg)](https://linux.sb)

![light](assets/screenshots/panel-light.png#gh-light-mode-only)![dark](assets/screenshots/panel-dark.png#gh-dark-mode-only)

</div>

## 🔁 What problem it solves

Some API stations, for example [agentrouter.org](https://agentrouter.org), accept requests **only in the Claude CLI format**.
Out of the box such a key works only in Claude CLI or in tools that speak the same format.

ClodKey's **Zoo Bridge** is a local relay that translates the format:

```
Zoo Code / Roo Code  ⇄  Zoo Bridge 127.0.0.1:33110  ⇄  Claude CLI-format station
 (OpenAI-compatible)        (format relay)              (e.g. agentrouter.org)
```

A key that was usable only from Claude CLI becomes a regular provider in **Zoo Code (Roo Code)**.

| Client | Status |
| --- | --- |
| Claude CLI (`claude`) | ✅ tested |
| Zoo Code / Roo Code | ✅ tested (through Zoo Bridge) |
| Cline, Kilo Code, Continue, Cursor, other coding tools | ⚠️ **not tested**, no guarantees |

### 🟣 Opus watch

agentrouter.org switches the **Claude Opus family on and off on a schedule**.
ClodKey's built-in **model check** (⟳ next to the model list) shows which models the station serves *right now*,
so you see the moment Opus goes live instead of burning requests on a model that is off.

> ClodKey is an independent tool, not affiliated with Anthropic or agentrouter.org.

## ✨ Features

- 🔑 **Key profiles** — name, Base URL, API key (masked, 👁 to reveal), auth mode (`API_KEY` / `AUTH_TOKEN` / both). The **System** profile is always first and locked; add / edit / delete your own.
- 🚀 **One-click apply** to `~/.claude/settings.json` (with a backup). Restart `claude` — done.
- 🧪 **Model check** — list the station's models and test each one (OK / error).
- 🌉 **Zoo Bridge window** — Start / Stop / Restart, load the current profile, live mini-log.
- 🛡 **Keys encrypted** with Windows DPAPI — the file is useless on another PC or user.
- 🫥 **Lives in the tray**, never shows a console window.
- 🌗 Light / dark theme · **English by default** · ru / zh / es.
- ☕ Coffee window with QR code and one-click address copy.

## 🚀 Quick start

1. [Download ZIP](https://github.com/Apex4Coder/ClodKey/archive/refs/heads/main.zip) and unpack it.
2. Double-click `app-next\run-hidden.vbs` — the ClodKey icon appears in the tray.
3. Click the icon, pick or create a profile, press **Apply to Claude CLI**.

Requirements: Windows 10 / 11 (PowerShell 5.1 is built in). Node.js ≥ 18 only for Zoo Bridge.

## 🌉 Zoo Bridge

```powershell
cd app-next\bridge
copy .env.example .env      # put your UPSTREAM_API_KEY into .env
node server.mjs             # 127.0.0.1:33110
```

Or start it from the Bridge window in the app. In Zoo Code / Roo Code choose an **OpenAI-compatible** provider
with base URL `http://127.0.0.1:33110/v1`.

## ❓ FAQ

**Where are my keys?** Claude CLI keys — in `data\secrets.json`, DPAPI-encrypted for your Windows user.
The bridge key — in `app-next\bridge\.env` (local, never committed).

**Tray icon is hidden under the arrow?** Settings → Personalization → Taskbar → Other system tray icons → ClodKey on.

**Two instances?** No — the second one exits silently.

## ☕ Support

<div align="center">

<a href="https://etherscan.io/address/0x50153B5CC3eae905291d62602226C80896Aa64f2"><img src="assets/coffee.svg" width="100%" alt="Buy me a coffee — Ethereum (ERC20)"/></a>

```
0x50153B5CC3eae905291d62602226C80896Aa64f2
```

<sub>Ethereum (ERC20) only. Other networks = lost funds.</sub>

</div>

## 🤝 Contributing · 📄 License

Bugs & ideas — [issues](../../issues/new/choose). Security — [SECURITY.md](SECURITY.md). License — [MIT](LICENSE).
