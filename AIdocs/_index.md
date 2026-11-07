# AIdocs — plg_system_agentready

Verified documentation for AI assistants. Read this index first, then the page for the code you are about to change. `CLAUDE.md` in the repo root holds the working rules; these pages hold the facts about the code.

## Pages

| Page | Covers |
|---|---|
| [pkg_agentready](pkg_agentready.md) | The Joomla package around the plugin: `package.xml`, `package_script.php` (minimum versions, enable on first install), the package language and the `package.sh` build. |
| [plg_system_agentready](plg_system_agentready.md) | The system plugin: Accept negotiation, page extraction and Markdown rendering, the Vary and Link headers, page cache and gzip handling, settings and language files. |

## Keeping the pages true

- Every content page (all except this `_index.md`) starts with `History`, `Last updated`, `Verified against` (the commit whose code you read) and `Covers:` (the paths it documents; a path ending in `/` covers the whole folder).
- When you change a file a page covers, update that page in the same change: `Last updated`, `Verified against` and a `History` line.
- `bash bin/preflight.sh` checks the rules: check 14 (headers, `Covers:` paths, index, coverage of changed files) and check 7 (at most 200 lines per page).

## Not documented here

`vendor/` (bundled league/html-to-markdown), the `language/` folders, `bin/` (shared HKweb tooling, see `hkweb_adventcalendar`), `tests/`, `.github/` and the Dutch workflow docs in `docs/`.
