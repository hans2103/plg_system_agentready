# Markdown for Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Joomla system plugin `plg_system_agentready` (in `pkg_agentready`) that answers `Accept: text/markdown` with a Markdown version of the page.

**Architecture:** Pure, Joomla-free classes under `src/` (negotiation, selector, extraction, rendering, headers) with plain-PHP unit tests; one thin `Extension\AgentReady` subscriber glues them to `onAfterRender`, `onPageCacheGetKey`. HTML → Markdown via bundled `league/html-to-markdown`.

**Tech Stack:** PHP 8.3+, Joomla 5.3+/6, DOMDocument, league/html-to-markdown ^5.2, bash tooling from `hkweb_adventcalendar/bin`.

**Spec:** `docs/superpowers/specs/2026-11-07-agent-ready-design.md`

## Global Constraints

- Joomla 5.3.3+ and 6.x; PHP 8.3.0 minimum; `declare(strict_types=1);` in every class file.
- Namespace `HKweb\Plugin\System\AgentReady`; plugin group `system`, element `agentready`.
- New code: `@since __DEPLOY_VERSION__`. Calendar versioning `YY.WW.PATCH`, source of truth `package.xml`.
- `bin/` byte-identical to `hkweb_adventcalendar/bin`; differences only in `scripts.conf`.
- Commits Dutch, conventional, `#1`; no Co-Authored-By.
- Language strings in en-GB and nl-NL.

## Review Focus

- Accept with `text/html` higher q than markdown (`text/markdown;q=0.5, text/html`) → HTML.
- `text/markdown;q=0` → HTML.
- Page without `<main>` → falls back to `body`; empty result → HTML stays.
- Non-ASCII content (é, —, emoji) survives without mojibake.
- Existing `Vary: Accept-Encoding` header → becomes `Accept-Encoding, Accept`, not duplicated.

Each is a test in the task that owns the code (Tasks 2, 4, 5, 6).

---

### Task 1: Repo scaffolding

**Files:** `bin/` (copy), `scripts.conf`, `package.xml`, `package_script.php`, `package.sh`, `.deployignore`, `cliff.toml`, `updates.xml`, `.githooks/commit-msg`, `.github/workflows/{validate,release}.yml`, `.gitignore`, `.editorconfig`, `LICENSE.txt`, `Src/language/{en-GB,nl-NL}/pkg_agentready.sys.ini`, plugin manifest + `services/provider.php` + empty extension class + language files, `composer.json` + `vendor/`, `tests/shell/` (bin tests minus the repo-specific package test, plus an own `test_package_sh.sh`).

- [ ] Copy `bin/` and the generic `tests/shell/` files verbatim; `diff -r` shows no difference.
- [ ] `scripts.conf`: PROJECT_NAME=agentready, PACKAGE_ELEMENT=pkg_agentready, ENV_PREFIX=AGENTREADY, GITHUB_REPO=hans2103/plg_system_agentready, DEV_LINKS for the plugin, UPDATE_DOWNLOAD_BASE=https://updates.hkweb.nl/agentready, AIDOCS_FLAVOUR=structure, LENGTH_LIMIT_SEVERITY=ERROR.
- [ ] `composer install` in the plugin folder (league/html-to-markdown ^5.2, platform php 8.3.0, classmap-authoritative).
- [ ] Verify: `bash package.sh` produces `packages/<v>/pkg_agentready-<v>.zip` containing `plg_system_agentready.zip`; `bash bin/preflight.sh --all` has no ERROR; `bash tests/shell/run-all.sh` passes.
- [ ] Commit `chore(repo): #1 repo opgezet volgens de HKweb-structuur`.

### Task 2: Accept negotiation

**Files:** Create `src/Negotiation/AcceptHeader.php`; Test `tests/unit/AcceptHeaderTest.php`.

**Produces:** `AcceptHeader::prefersMarkdown(?string $accept): bool` (static).

- [ ] Tests: `null`/`''` → false; `text/markdown` → true; `text/markdown, text/html` → true; `text/html, text/markdown;q=0.9` → false; `text/markdown;q=0.5, text/html` → false; `text/markdown;q=0` → false; `*/*` → false; `text/*` → false; `text/markdown;q=0.8, */*;q=0.1` → true; case-insensitive `Text/Markdown` → true.
- [ ] Implement: parse comma list, `q` param default 1, HTML q = most specific of `text/html` → `text/*` → `*/*` (0 if none); true when md q > 0 and md q >= html q.
- [ ] Run `php tests/unit/AcceptHeaderTest.php` → all ok. Commit.

### Task 3: CSS selector → XPath

**Files:** Create `src/Html/Selector.php`; Test `tests/unit/SelectorTest.php`.

**Produces:** `Selector::toXPath(string $selectorList): ?string` — union of XPaths, `null` when nothing valid.

- [ ] Tests via a DOMDocument fixture: `main`, `#content`, `.a.b`, `div.x`, `[role=main]`, `[aria-hidden="true"]`, `[hidden]`, `nav a` (descendant), `ul > li` (child), `main, body` (list order irrelevant for XPath), invalid `div::foo` skipped → other parts still match, all invalid → null.
- [ ] Implement with a small tokenizer; class match `contains(concat(' ', normalize-space(@class), ' '), ' x ')`.
- [ ] Run test, commit.

### Task 4: Document extraction

**Files:** Create `src/Html/PageExtractor.php`, `src/Html/ExtractedPage.php`; Test `tests/unit/PageExtractorTest.php`.

**Consumes:** `Selector::toXPath`. **Produces:** `PageExtractor::extract(string $html, string $contentSelectors, string $removeSelectors, string $baseUrl): ?ExtractedPage`; `ExtractedPage` readonly: `array $meta` (keys title/description/image, only non-empty), `string $contentHtml`, `list<string> $jsonLd`.

- [ ] Tests: meta priority (name over og; `<title>` fallback); JSON-LD collected from head and body, trimmed; content from first matching selector in list order (`main` before `body` even when body listed first? no — list order wins: first selector in the list that matches); removal of script/style/`[hidden]`/nav inside main; relative `href="/x"` and `src="img.png"` made absolute against `https://example.com/a/b`, `#frag`/`mailto:`/absolute untouched; no main → body; UTF-8 `é — 🎄` intact; empty/invalid HTML → null.
- [ ] Implement with `DOMDocument::loadHTML('<?xml encoding="UTF-8">' . $html, LIBXML_NOERROR|LIBXML_NOWARNING|LIBXML_NONET)`, query in list order per selector part.
- [ ] Run test, commit.

### Task 5: Markdown rendering

**Files:** Create `src/Markdown/MarkdownRenderer.php`; Test `tests/unit/MarkdownRendererTest.php`.

**Consumes:** `ExtractedPage`. **Produces:** `MarkdownRenderer::render(ExtractedPage $page, bool $frontmatter, bool $jsonLd): string`; `MarkdownRenderer::estimateTokens(string $markdown): int` (`(int) ceil(mb_strlen / 4)`).

- [ ] Tests: frontmatter `---\ntitle: "T"\ndescription: "D"\n---\n\n` (JSON-quoted, unicode unescaped), omitted when meta empty or disabled; `<h1>` → `# `, `<ul><li>` → `- `, table → pipe table; JSON-LD block ```` ```json ```` at the end, multiple entries one per line, omitted when none/disabled; output ends with a single `\n`; empty content → `''`; tokens of `'abcde'` = 2.
- [ ] Implement with `HtmlConverter(['header_style' => 'atx', 'strip_tags' => true, 'remove_nodes' => 'script style', 'hard_break' => true, 'list_item_style' => '-'])` + `TableConverter`.
- [ ] Run test, commit.

### Task 6: Response headers

**Files:** Create `src/Http/VaryHeader.php`; Test `tests/unit/VaryHeaderTest.php`.

**Produces:** `VaryHeader::merge(array $existing, string $add = 'Accept'): string`.

- [ ] Tests: `[]` → `Accept`; `['Accept-Encoding']` → `Accept-Encoding, Accept`; `['accept']` → `accept`; `['Cookie, Accept']` → unchanged; `['*']` → `*`.
- [ ] Implement, run, commit.

### Task 7: Plugin wiring, settings, languages

**Files:** Modify `src/Extension/AgentReady.php`, manifest `<config>`, four language files; Test `tests/unit/PluginContractTest.php` (manifest fields ↔ language keys en/nl, subscribed events, default selectors).

- [ ] Settings: `content_selector` (default `main, [role=main], article, body`), `remove_selectors` (textarea, default `script, style, noscript, template, svg, canvas, iframe, object, embed, form, button, input, select, textarea, nav, dialog, [hidden], [aria-hidden=true]`), `skip_logged_in` (1), `skip_noindex` (1), `vary_html` (1), `frontmatter` (1), `jsonld` (1), `content_signal` (text, '').
- [ ] Events: `onAfterRender` (Priority::MIN), `onPageCacheGetKey` (adds `agentready:markdown`). Guards: site, GET/HEAD, html document, status 200, guest/noindex per setting. On convert: setBody, `Content-Type: text/markdown; charset=utf-8` (replace), Vary merge, `x-markdown-tokens`, optional `Content-Signal`, drop `ETag`/`Content-Length`; `$app->mimeType = 'text/markdown'`. Errors → `Log::add(..., Log::WARNING, 'agentready')`, HTML stays. Vendor autoload required lazily.
- [ ] Contract test passes; preflight clean. Commit.

### Task 8: Docs, build, DDEV verification

- [ ] README (EN: what, install, settings, caching incl. Cloudflare Cache Everything note), CLAUDE.md, AIdocs `_index.md`, `pkg_agentready.md`, `plg_system_agentready.md`, `docs/Ontwikkelworkflow.md`, `docs/Release en deployment procedure.md` (NL).
- [ ] `bash package.sh`; install zip on momentsuntil DDEV (`ddev exec php cli/joomla.php extension:install --path=…`).
- [ ] `curl -sk -H 'Accept: text/markdown' https://momentsuntil.ddev.site:<port>/` → `content-type: text/markdown; charset=utf-8`, `vary` contains Accept, `x-markdown-tokens`, Markdown body with frontmatter and JSON-LD; plain curl → HTML with `Vary: Accept`; with page cache on: both variants correct on the second request.
- [ ] Commit docs.
