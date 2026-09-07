## What does this PR do?

<!-- Link the issue it closes: "Closes #123". One PR = one behavior change. -->

## Type of change

- [ ] Bug fix (non-breaking, behavior preserved elsewhere)
- [ ] Feature (non-breaking, new behavior behind a clear entry point)
- [ ] Breaking change (fix/feature changing existing behavior)
- [ ] Docs / strings only (no code behavior change)

## GOLD invariants checklist

The project follows the GOLD spec. Confirm each box or explain:

- [ ] `.ps1` source stays **ASCII-only** (UI text goes to `strings.json`, all 4 locales)
- [ ] `.bat` stays **ASCII + CRLF**; `.ps1`/`.vbs` stay **ASCII** (no BOM)
- [ ] No new **silent defaults**: unknown values are typed (`"unknown"` / log + empty), never guessed
- [ ] Every new tray action has a **CLI twin** (`-SelfTest` case or a `-Smoke` assertion)
- [ ] State (`data\`, `logs\`) is **never** written inside `app-next\` or `live\`
- [ ] GUI path writes **nothing to stdout** (file log only)
- [ ] `Application::Run()` without a form argument; no `detached` for the GUI process

## Tests

Run locally (Windows runner) and paste results:

```
powershell -NoProfile -STA -File app-next\ClodKey.ps1 -Smoke
powershell -NoProfile -STA -File app-next\ClodKey.ps1 -SelfTest
```

- [ ] `-Smoke` exits 0
- [ ] `-SelfTest` prints `SELFTEST OK`
- [ ] Layout overlap assertions pass (if UI changed)
- [ ] DPAPI roundtrip passes (if store changed)

## Screenshots / GIFs

<!-- UI changes: attach before/after -Shot renders (logs\shot.png). -->

## Notes for reviewers
