# One-click EA updater

Pulls the current EA source from the web bridge, installs it into a terminal's
`Experts` folder and compiles it — so you never have to download, copy-paste and
compile by hand after a change.

## Use

Double-click **`Update-EA.bat`**. For the MT4 build: `Update-EA.bat mq4`.

First run writes `updater.config.json` next to the script, auto-detecting
MetaEditor and listing every MetaTrader data folder it finds. Fill in your
token, confirm the paths, run it again.

```json
{
  "bridgeUrl":       "https://7r4d3-production.up.railway.app",
  "token":           "<your RM_TOKEN>",
  "metaEditorPath":  "C:\\Program Files\\MetaTrader 5\\MetaEditor64.exe",
  "terminalDataDir": "C:\\Users\\you\\AppData\\Roaming\\MetaQuotes\\Terminal\\<hash>"
}
```

`updater.config.json` is gitignored — it holds your token.

## What it does

1. Reads `/api/source` and compares the served sha256 against the last install.
   Unchanged ⇒ exits with *"Already up to date"*.
2. Warns if the EA currently has open positions, active matrices or an armed
   setup, and asks before continuing.
3. Backs up the existing `.mq5`/`.ex5` into `tools/backup/`.
4. Downloads, installs, compiles via MetaEditor CLI.
5. On failure: prints the compiler errors, **restores the backup and recompiles
   it**, and leaves the version marker untouched so the next run retries.
6. On success: records version + sha in `.installed.<platform>.json`.

## Chart template

`Update-EA.bat` also installs `default.tpl` into `MQL5\Profiles\Templates`,
backing up any existing one first. A fresh terminal gets the EA and the chart
setup in a single click.

### Re-sanitising the template

**Never commit a template straight out of MetaTrader.** MT5 bakes the attached
EA's *input values* into it, so a `.tpl` saved from a configured chart contains
your Discord webhook and bridge token. `.tpl` files are also **UTF-16**, so
`grep` silently finds nothing in them — a scan that looks clean may not be.

After changing your chart setup, export it and run:

```bash
node tools/sanitize-template.mjs "<path to your .tpl>" templates/default.tpl
```

It removes every `<object>` block (session junk — trade markers, EA drawings),
empties `<inputs>` so the EA falls back to its blank compiled defaults, and
**refuses to write the file at all** if the result still matches any credential
pattern. The real one went from 1,808,514 bytes / 4,508 objects to 3,040 bytes.

## Notes

- **`-Force`** reinstalls even when the sha matches.
- Compiling reloads the EA on the chart. On-chart state (armed lines, exit /
  partials / BE matrices, equity guards) now survives that — `OnDeinit` persists
  it across `REASON_RECOMPILE` and `REASON_PARAMETERS`, not just timeframe
  changes. Before that fix, any recompile silently deleted your matrices.
- MetaEditor writes its log as **UTF-16LE**. Reading it as UTF-8 gives garbage;
  the script uses `-Encoding Unicode`.
- `/include:` is passed explicitly. Without it MetaEditor can fail to resolve
  `<Trade\Trade.mqh>` on some broker builds.
- The script is ASCII-only and saved with a BOM. PowerShell 5.1 reads BOM-less
  files as ANSI, which mangles non-ASCII characters and can break parsing.

## Verified

| Scenario | Result |
|---|---|
| No config | writes template, auto-detects MetaEditor, lists all terminals |
| Fresh install | downloads, compiles `0 errors, 0 warnings`, writes marker |
| Unchanged source | *"Already up to date"*, no work done |
| **Broken build** | compile fails, errors shown, **previous version restored and recompiled**, marker not advanced |
