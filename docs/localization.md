# Localization

The mod ships English, Spanish, Brazilian Portuguese, German, French, Italian, Polish,
Russian, Korean, Japanese, Simplified Chinese, and Traditional Chinese.
Each player sees mission text in their own game language: every client installs the mod
(`all_clients_require_mod`), so the client translates locally instead of trusting text
produced by the server.

## How it works

- Mission and emergency text is authored in **English** in `missions.lua` and
  `emergencies.lua`. UI/chat text authored in code lives in
  [`strings.lua`](../scripts/guidedmissions/strings.lua).
- The server writes that **source text** into the tracker netvars (`title`, `subtext`,
  `rows`, `hint`, and the terminal card). It never translates them.
- The client translates each string when it renders the card, using its own locale.
- The server translates only its **own chat and log lines**, using the server's locale.
  That is why completion announcements follow the server language while the HUD follows
  each player's client language.
- **Steam's in-game language menu only offers English, Simplified Chinese, and
  Traditional Chinese.** Every other language is a Workshop "language pack" mod. Those
  packs call `LanguageTranslator:LoadPOFile(path, code)`, which does not change the
  game's language setting — so `LOC.GetLocaleCode()` still says `en`. The mod therefore
  also reads `LanguageTranslator.defaultlang`, which is the pack's code and the
  language the game actually renders. See
  [`docs/dst-api.md`](dst-api.md#translation-and-locale).
- DST has no automatic mod-translation loader in this build, and
  `LanguageTranslator:LoadPOFile` would replace the global per-language table (breaking
  other mods), so the mod keeps its own Lua tables.

### Translation keys are the English sentences

There are no generated string ids. A locale table maps the authored English string to
its translation:

```lua
["Collect flint"] = "Sammle Feuerstein",
```

This keeps mission data readable and lets a future mission pack ship translations
without inventing keys. The cost: **editing an English string orphans its
translations** until every locale file is updated. The l10n harness fails until they
are, and the runtime always falls back to English rather than showing a blank.

## Locale files

```
scripts/guidedmissions/languages/
    en.lua   -- GENERATED identity manifest; do not hand-edit
    es.lua   -- Spanish; Latin American wording (mex shares it)
    pt.lua   -- Brazilian Portuguese (DST's `pt`, not `pt-br`)
    de.lua   -- German
    fr.lua   -- French
    it.lua   -- Italian
    pl.lua   -- Polish
    ru.lua   -- Russian
    ko.lua   -- Korean
    ja.lua   -- Japanese (dormant; see the codes table)
    zh.lua   -- Simplified Chinese (WeGame `zhr` shares it)
    zht.lua  -- Traditional Chinese
```

- **`en.lua` is generated** by `tools/gen_l10n.lua` from the mission data, emergencies,
  and `strings.lua`. It is the translator template and the coverage baseline. Run
  `lua tools/gen_l10n.lua` after changing any source text; `verify` fails if it is
  stale or hand-edited.
- The other files are handwritten. Copy `en.lua`, translate **values only**, and keep
  the keys byte-for-byte.
- One entry per line, UTF-8 without BOM, LF line endings. No duplicate keys (Lua would
  silently keep the last one) and no empty values; the harness checks all of this.

### Locale codes and aliases

`LOC.GetLocaleCode()` returns lowercase codes. The mod ships:

| Code | Audience |
|---|---|
| `en` | English (fallback for every unknown locale) |
| `es` | Spanish; `mex` (Latin American Spanish) shares it. When Spain and LatAm differ, use the Latin American term from vanilla's `spanish_mex.po` |
| `pt` | Brazilian Portuguese |
| `de` | German |
| `fr` | French |
| `it` | Italian |
| `pl` | Polish |
| `ru` | Russian |
| `ko` | Korean |
| `ja` | Japanese — **dormant**: DST's `loc.lua` has the `ja` entry commented out, so no client resolves to it until Klei enables the locale |
| `zh` | Simplified Chinese; `zhr` (WeGame) is aliased to it |
| `zht` | Traditional Chinese |

Other DST locales (`tr`, `nl`, `fi`, `sv`, `da`, `no`) have no table and fall back to
English. To add one, copy `en.lua`, translate the values, and register the file in
`l10n.lua`.

## Module API

[`scripts/guidedmissions/l10n.lua`](../scripts/guidedmissions/l10n.lua) is a normal
`require()`d module, safe on both server and client.

```lua
L10n.L(source)                          -- translated string, else English, else source
L10n.Lfmt(source, ...)                  -- L() then string.format, safe fallback
L10n.GetLocale()                        -- normalized/aliased current code
L10n.SetLocale(code)                    -- test/tool override; nil clears the cache
L10n.RegisterLocale(code, table, prio)  -- future mission-pack seam
L10n.DisplayWidth(text)                 -- weighted width used by the tests
```

- The current locale is resolved lazily in this order:
  1. `LanguageTranslator.defaultlang`, when it names a shipped locale. This is the
     Workshop language-pack path, where `LOC` still reports `en`.
  2. `LOC.GetLocaleCode()` (a **dot call**; it has no `self`). This is the native
     English / Simplified / Traditional Chinese menu path.
  3. English. Without `LOC` — tests, tooling, early boot — it returns `en` without
     caching, so a later call can still resolve the real locale.
- Pack codes are normalised: ISO-style variants such as `pt-br`, `zh_CN`, `ja-jp`, and
  the community Brazilian pack's `br` all map onto a shipped table. An unrecognised
  pack code falls back to `LOC`, then English.
- Lookup order: requested locale table → English table → the source string. A missing
  locale file, missing key, or non-string value falls through; a bad translation can
  never blank the HUD or crash.
- Locale tables load lazily with `pcall(require, ...)`. A missing or broken file is an
  empty layer.
- `Lfmt` formats the translation inside `pcall`; if a translation has broken
  placeholders it formats the English source instead.
- Never call `L()` on a value that is written to a netvar, and never call `L()` inside
  `Log`/`Announce` — translation happens once, while composing chat text.

## Netvar row contract

`rows` is still `label|prefab|counter|done|optional`, rows joined by `;`. Labels and
counters are **source text**. A `survive` row appends three fields:

```
label|prefab|counter|done|optional|day|current|target
```

The client formats that counter with its own locale (`Tag 1/3`, `第1/3天`). Every other
counter (`0/3`, `40/75%`) is numeric and rendered as-is. Older clients ignore fields
6–8; newer clients fall back to the preformatted `counter` when an older server omits
them.

## Width budgets

The card has a fixed width. Instead of growing the layout for longer translations, the
l10n harness enforces a budget per field, measured in weighted columns (Lua 5.1 has no
UTF-8 library, so the estimator decodes codepoints itself):

- ASCII and accented Latin count **1**. They are drawn by the mod's condensed primary
  fonts.
- Cyrillic and Greek count **2**. They fall through to DST's fallback outline font,
  whose glyphs advance ~1.8–2.1× an average Latin glyph at the same size.
- East-Asian wide/fullwidth codepoints count **3**. They use the full CJK fallback,
  whose glyphs advance ~2.8–2.9× an average Latin glyph.
- Combining marks and zero-width characters count 0.

| Field | Budget (columns) | Rough CJK limit |
|---|---|---|
| `title` | 27 | ~9 glyphs |
| `subtext` | 52 | ~17 glyphs |
| objective `label` | 28 | ~9 glyphs |
| `hint` | 80 | ~26 glyphs |
| `Optional` heading | 24 | — (full-width band; English is 8) |
| day-counter format | 15 | — (column measured at runtime) |

If a translation does not fit, **reword it**; do not raise the budget without checking
the preview and an in-game run first. Chat/log format strings have a generous
anti-bloat cap only, plus a placeholder-parity check: every `%s`/`%d` must appear in
the same order as the source (`%%` is literal).

## Authoring text

- `title`, `subtext`, `hint`, `resolved_subtext`, and objective `label` are translation
  keys. Keep them single-line and free of `|`, `;`, quotes, CR, and LF. (A source `|`
  would be sanitised before the client sees it and the translation would silently
  miss.)
- Labels carry no count; the tracker renders the counter separately. Do not bake the
  target into a label except where the wording needs it (the emergency goal rows).
- After changing any source text, run:

  ```bash
  lua tools/gen_l10n.lua     # rewrites languages/en.lua
  .\verify                   # fails until every locale covers the new key
  ```

Then translate the new/changed keys in `es.lua`, `pt.lua`, `de.lua`, `zh.lua`, and
`ru.lua`.

## Adding a language

1. Copy `scripts/guidedmissions/languages/en.lua` to `<code>.lua`.
2. Translate every value; keep keys byte-for-byte and stay within the width budgets.
3. Add the code to `L10n.BUILTIN_LOCALES` in `l10n.lua`.
4. Add the code to `SHIPPED` in `tests/l10n_test.lua`.
5. Run `.\verify`. The harness reports missing/stale keys, placeholder mismatches,
   encoding problems, and over-budget strings.
6. Preview it. The offline renderer loads the game's fallback outline fonts, so
   Cyrillic and CJK render there too. Fallback glyph rendering is approximate (packed
   BMFont channels); confirm the final look in game.

## Mission packs (future)

`L10n.RegisterLocale(code, table, priority)` is the seam for server-owned content:

```lua
local L10n = require("guidedmissions/l10n")
L10n.RegisterLocale("fr", require("mypack/languages/fr"), 10)
```

Higher priority wins per key; at equal priority the later registration wins. Core
tables are priority 0, so a pack can override or extend translations without editing
the core locale files or depending on load order. No pack loader exists yet.

## Limitations

- Chat and log lines are composed server-side, so they use the **server's** language.
  Per-player chat would require each client to render its own line, which
  `TheNet:Announce` does not support.
- A client language is detected through `LOC` or the language pack's
  `LanguageTranslator.defaultlang`. A mod that translates colours/strings through
  direct `STRINGS` overrides without calling `LoadPOFile` is not detected.
- The locale is cached per session. Changing the game language at runtime may need a
  relog or UI reload before the card updates.
- The offline preview draws non-Latin text through DST's fallback fonts, but its
  packed-channel glyph composition is approximate; the in-game render is authoritative.
- Japanese is shipped but dormant: DST has no active `ja` locale, so the table is only
  reachable through `L10n.SetLocale`/`L10n.RegisterLocale`. Unshipped locales fall back
  to English.
- `modinfo.lua` configuration labels and the admin console commands (`c_resetmissions`,
  `c_setmission`) remain English. The mod-info environment has its own translation hook;
  this change does not use it.
- Machine-drafted translations (es/pt/de/fr/it/pl/ru/ko/ja/zh/zht) are shipped in this
  repository and should be reviewed by native speakers over time.
