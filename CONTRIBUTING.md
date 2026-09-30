# Contributing to ClodKeyProxy

Thanks for your interest! ClodKeyProxy is deliberately small: **one PowerShell
file for the UI, one dependency-free `.mjs` file for the bridge, zero console
windows**. The rules below keep it that way.

## Ground rules (the GOLD invariants)

These are not style preferences - each one was paid for by a real bug:

1. **`.ps1` source is ASCII-only.** All human-readable strings live in
   `app-next/strings.json` (UTF-8, four locales: ru/en/zh/es). OEM
   codepage turns Cyrillic in BOM-less `.ps1` into a parser explosion.
2. **`.bat` is ASCII + CRLF.** Same reason, `cmd.exe` side.
3. **No silent defaults.** Unknown values stay unknown: log a warning and
   show empty - never substitute a guess.
4. **Every tray action has a CLI twin.** If you add a button, add the
   matching assertion to `-SelfTest`. Clicks are untestable; commands are.
5. **State never lives inside a release.** `data\` and `logs\` stay one
   level above `app-next\`/`live\` so deploy/rollback moves only code.
6. **GUI writes nothing to stdout.** File log only (`logs\clodkey.log`).
7. **`Application::Run()` without a form argument**, no `detached` for the
   GUI process, `FreeConsole()` at startup - the zero-window guarantee
   (gate `check-g22.ps1`).
8. **Layout is measured, not hardcoded.** Positions come from
   `Do-Layout` (TextRenderer.MeasureText). Fixed pixel coordinates broke
   at DPI ≠ 100%.
9. **Two contours stay apart.** The Claude CLI contour writes only
   `~/.claude/settings.json`; the bridge contour writes only
   `app-next/bridge/.env`. No handler may cross the line (see `SPEC.md`).

## Dev loop

```powershell
# edit app-next\*, then:
powershell -NoProfile -STA -File app-next\ClodKeyProxy.ps1 -Smoke      # UI builds, DPAPI ok
powershell -NoProfile -STA -File app-next\ClodKeyProxy.ps1 -SelfTest   # behavior asserts
powershell -NoProfile -STA -File app-next\ClodKeyProxy.ps1 -Shot       # logs\shot.png evidence
powershell -NoProfile -File parse-check.ps1                            # syntax + brace balance, line numbers
powershell -NoProfile -File check-locales.ps1                          # every T 'key' exists in all 4 locales
powershell -File deploy.ps1                                            # next -> live + relaunch
powershell -File check-g22.ps1                                         # zero console windows
powershell -File verify-ui.ps1                                         # smoke + selftest + shot + log tail
```

Bridge side:

```powershell
cd app-next\bridge
node --check server.mjs
node tools\unit-transforms.mjs
```

Regression suite (runs on a throwaway tree under `%TEMP%`, never touches the
real install):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\deploy-lock.tests.ps1
```

Debug launch with a visible console: `set CK_NO_DETACH=1` then run
`app-next\start-clodkey.bat`.

## Adding a language

1. Add a full locale block to `app-next/strings.json` (copy `en`).
2. Add the code to `$script:Langs` in `ClodKeyProxy.ps1` and one icon button
   (`New-IconButton`) in the header row.
3. `check-locales.ps1` must pass (no key skew between locales).
4. `-SelfTest` must assert the switch renames the system profile.

## Secrets - never commit

These are gitignored **on purpose**; do not "fix" the `.gitignore`:

- `data/secrets.json` - DPAPI ciphertext (user-scoped).
- `app-next/bridge/.env` - the real `UPSTREAM_API_KEY` in plaintext.
- `app-next/bridge/diag/` - full upstream request bodies captured on rejection.
- `app-next/bridge/*.log`, `logs/`, `live/`, `live.prev-*/`, `backups/`.

If you need to change configuration, edit `app-next/bridge/.env.example`, never
`.env`.

## Pull requests

- One behavior change per PR; fill the PR template checklist.
- CI (`.github/workflows/ci.yml`) runs the ASCII / parse / bridge / locales /
  smoke / selftest / deploy-lock gates on every push - keep it green.
- UI changes: attach before/after `-Shot` renders.

## Code of conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
