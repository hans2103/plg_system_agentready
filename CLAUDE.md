# CLAUDE.md

> **Document length monitoring:** check at the start of every session the number of lines with
> `wc -l $(git rev-parse --show-toplevel)/CLAUDE.md`. Report to the user when this is **longer than 200 lines**.

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Agent Ready is a Joomla package (`pkg_agentready`) with one system plugin, `plg_system_agentready`, that makes a site readable for AI agents:

- **Markdown for Agents**: `Accept: text/markdown` gets a Markdown version of the page (frontmatter, main content, JSON-LD), as Cloudflare's Markdown for Agents does on paid plans.
- **Link headers** (RFC 8288) on HTML pages to `llms.txt`, `.well-known/agent-skills/index.json`, `.well-known/mcp/server-card.json`, `.well-known/ai-catalog.json` (also as `<link rel="ai-catalog">` in the head), the sitemap and the Markdown alternate.

Public repo, reusable on any site. First user: momentsuntil.com (Cloudflare Free); also gehandicaptenvalkenswaard.nl.

**Requirements:** Joomla 5.3.3+ (Joomla 6 ready), PHP 8.3+.

Language convention: PHP docblocks in English; commit messages and the workflow docs in `docs/` in Dutch; `README.md` and this file in English.

## Repository Layout

```
Src/
├── plugins/system/agentready/        # the plugin (manifest agentready.xml in the folder)
│   ├── services/provider.php
│   ├── src/Extension/AgentReady.php  # event wiring, settings, headers
│   ├── src/Negotiation/              # AcceptHeader (q-values)
│   ├── src/Html/                     # Selector (CSS → XPath), PageExtractor, ExtractedPage, UrlResolver
│   ├── src/Markdown/                 # MarkdownRenderer (league/html-to-markdown, tidy, tokens)
│   ├── src/Http/                     # VaryHeader, LinkHeader
│   ├── language/{en-GB,nl-NL}/
│   └── composer.json + vendor/       # bundled league/html-to-markdown (committed)
└── language/{en-GB,nl-NL}/pkg_agentready.sys.ini
package.xml  package_script.php  package.sh  .deployignore  cliff.toml  updates.xml  scripts.conf
bin/  docs/  AIdocs/  tests/{unit,shell}/  .githooks/  .github/
```

Never edit `packages/` (build output) or `updates.xml` by hand: `bin/add-update-entry.php` appends the release entries.

## AIdocs

`AIdocs/` holds verified documentation for AI assistants. Read `AIdocs/_index.md` first, then the page for the code you are about to change.

- Every content page starts with `History`, `Last updated`, `Verified against` (a commit) and `Covers:`.
- When you change files a page covers, update that page in the same PR.
- `bash bin/preflight.sh` checks coverage and structure (check 14) and the 200-line limit (check 7, an ERROR here).

## Commands

```bash
bash package.sh [version]          # build packages/{version}/pkg_agentready-{version}.zip
bash bin/preflight.sh              # lint, manifests, versions, secrets, AIdocs, strict_types (read-only; --all: whole repo)
bash bin/run-release.sh            # full release: merge develop → main, build, commit, tag, push, wait for the release
bash bin/deploy-ddev.sh [-n] [-y]  # rsync the plugin (DEV_LINKS) into the local Joomla site
bash tests/shell/run-all.sh        # tests for bin/
for f in tests/unit/*.php; do php "$f" || echo "FAIL $f"; done   # plain-PHP unit tests, no PHPUnit
```

`bin/` is byte-identical in every HKweb Joomla repo (reference: `hkweb_adventcalendar`). Everything that differs per repo is a variable in `scripts.conf`; change a script in one repo and copy it to the others, never fork it.

Each unit test is a standalone script that includes `tests/bootstrap.php` (autoloader, `check()`, `finish()`) and exits non-zero on failure.

Updating the bundled library: `cd Src/plugins/system/agentready && composer update --no-dev && rm -rf vendor/bin`, run the tests, commit `vendor/` and `composer.lock`.

## Branch Strategy

- `main` — production; only receives tagged releases
- `develop` — integration branch; all feature PRs merge here first
- Feature branches: `feature/{issue}-{short-description}`
- Never commit directly to `main` or `develop`
- Full workflow: `docs/Ontwikkelworkflow.md`

## Committing

Commit messages in Dutch, conventional and with an issue number: `feat(markdown): #12 omschrijving` (`#000` when there is no issue). No `Co-Authored-By` line. Activate the hook once per clone: `git config core.hooksPath .githooks`.

## PR's

Do **not** add a 'Generated with Claude Code' line in a PR.

## Versioning & Release

Calendar versioning `YY.WW.PATCH` (e.g. `26.45.0`). The single source of truth is `<version>` in `package.xml`; `package.sh {version}` stamps it into the plugin manifest and replaces `__DEPLOY_VERSION__`.

- `bash bin/run-release.sh` runs the release. The tag `v{version}` triggers `.github/workflows/release.yml`: GitHub Release with git-cliff notes, then `updates.xml` on main. GitHub is the update server: `package.xml` points to `https://raw.githubusercontent.com/hans2103/plg_system_agentready/main/updates.xml` and the zip downloads from the GitHub Release (`UPDATE_DOWNLOAD_BASE` empty). No own server, no secrets.
- Public extension: no download key (`dlid`).
- Details: `docs/Release en deployment procedure.md`.

## Code Standards

- PSR-12 with Joomla's tabs; `declare(strict_types=1);` in every class file
- DocBlocks with `@since`; new code gets `@since __DEPLOY_VERSION__`
- Keep the classes under `src/Negotiation`, `src/Html`, `src/Markdown`, `src/Http` free of Joomla calls, so the unit tests run without Joomla; only `Extension\AgentReady` touches the application.
- New settings: manifest field + en-GB and nl-NL strings + `params->get()` in the class; `tests/unit/PluginContractTest.php` checks all three.

## Important Implementation Details

- `onAfterRender` runs at `Priority::MIN`, after every plugin that changes the body.
- `onAfterRoute` (`Priority::HIGH`, before `plg_system_cache` serves a page) switches Joomla's gzip off: Joomla's `compress()` adds a second `Vary` value and `sendHeaders()` keeps only the last one per name.
- `onPageCacheGetKey` adds `agentready:markdown` for Markdown requests; the HTML cache key is unchanged.
- Headers with several values go out as one merged header (`VaryHeader::merge`, `LinkHeader::merge`, `setHeader(…, true)`), for the same Joomla reason.
- The vendor autoloader is loaded only when a page is converted.
