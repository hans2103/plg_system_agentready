# System plugin: agentready

### History
- 2026-11-07: page created with the first version: Markdown for Agents merged with the agent discovery Link headers of the gehandicaptenvalkenswaard.nl plugin (issue #1)
- 2026-11-07: `tidy()` leaves one space after the `#` of a heading (issue #1)
- 2026-11-07: closer to Cloudflare: `MarkdownHeaders` (strip list, 6 MiB limit, site `Content-Signal` wins), site header/footer landmarks removed (issue #3)

Last updated: 2026-11-07
Verified against: 29fab20
Covers:
- Src/plugins/system/agentready/

## Purpose

A Joomla system plugin (group `system`, element `agentready`, namespace `HKweb\Plugin\System\AgentReady`) that makes a site readable for AI agents:

1. **Markdown for Agents**: a request with `Accept: text/markdown` gets a Markdown version of the page, in the layout of Cloudflare's Markdown for Agents (frontmatter, body, JSON-LD).
2. **Link headers** (RFC 8288) on HTML pages to `llms.txt`, the agent skills index, the sitemap and the Markdown alternate.

Design and reasoning: `docs/superpowers/specs/2026-11-07-agent-ready-design.md`.

## Files

| File | Role |
|---|---|
| `agentready.xml` | Manifest: `<files>` services, src, vendor, language (no `<languages>` block: language files stay in the plugin folder); settings in three fieldsets |
| `services/provider.php` | DI: creates `AgentReady` with the dispatcher and the plugin row, sets the application |
| `src/Extension/AgentReady.php` | The only class that touches Joomla: events, conditions, settings, headers |
| `src/Negotiation/AcceptHeader.php` | `prefersMarkdown(?string): bool` |
| `src/Html/Selector.php` | CSS subset → XPath: `toXPaths(string): list<string>` (list order), `toXPath(string): ?string` (union) |
| `src/Html/PageExtractor.php` | `extract(html, contentSelectors, removeSelectors, pageUrl): ?ExtractedPage` |
| `src/Html/ExtractedPage.php` | readonly: `meta` (title/description/image, only non-empty), `contentHtml`, `jsonLd` |
| `src/Html/UrlResolver.php` | `resolve(base, reference)`: RFC 3986 relative resolution |
| `src/Markdown/MarkdownRenderer.php` | `render(page, frontmatter, jsonLd)`, `tidy(markdown)`, `estimateTokens(markdown)` |
| `src/Http/VaryHeader.php` | `merge(existing, add = 'Accept')` |
| `src/Http/LinkHeader.php` | `link(uri, rel, type)`, `merge(existing, links)` |
| `src/Http/MarkdownHeaders.php` | `STRIP` (headers removed), `MAX_HTML_BYTES` (6 MiB), `fits(html)`, `contentSignal(existing, setting): ?string` |
| `composer.json`, `composer.lock`, `vendor/` | Bundled `league/html-to-markdown` 5.2 (MIT), platform PHP 8.3.0, classmap-authoritative; committed |

## Events

| Event | Priority | What |
|---|---|---|
| `onAfterRoute` | `HIGH` (before `plg_system_cache` serves a cached page) | Front end, Joomla gzip on, Markdown on, format html: switches Joomla's gzip off when `vary_html` is on or the request asks for Markdown. Reason: Joomla's `compress()` adds `Vary: Accept-Encoding` as a second value and `sendHeaders()` sends every value with `header(…, replace: true)`, so only the last value per name reaches the client. |
| `onPageCacheGetKey` | normal | Front end, Markdown on, request prefers Markdown: adds `agentready:markdown` to the page cache key. The HTML key is unchanged. `plg_system_cache` stores headers too, so a cache hit has the right `Content-Type`. |
| `onAfterRender` | `MIN` (after every plugin that changes the body) | See below. |

### onAfterRender

Stops unless: front end, `GET` or `HEAD`, document type `html`, status 200 (no `Status` header other than 200, response status 200).

With Markdown on (`markdown`):
1. If `AcceptHeader::prefersMarkdown()` and `mayConvert()` (guest when `skip_logged_in`; no `noindex`/`none` in the robots meta or `X-Robots-Tag` when `skip_noindex`) and `convert()` succeeds: done, no Link headers.
2. Else, with `vary_html`: `Vary` gets `Accept` merged in (and Joomla gzip off).

With `link_headers`: `addLinks()`.

### convert()

Stops (HTML) when the body is larger than `MarkdownHeaders::MAX_HTML_BYTES`. Loads `vendor/autoload.php` lazily, runs `PageExtractor::extract()` on the body with `content_selector` (empty falls back to the default), `remove_selectors` and the current URL, then `MarkdownRenderer::render()` with `frontmatter` and `jsonld`. A `Throwable` is logged (`Log::WARNING`, category `agentready`) and leaves the HTML. An empty result leaves the HTML.

On success: body = Markdown; `mimeType` `text/markdown`, `charSet` utf-8; headers `Content-Type: text/markdown; charset=utf-8`, `x-markdown-tokens`, `Vary` with `Accept`, `Content-Signal` from `content_signal` unless the response already has one (`MarkdownHeaders::contentSignal`, no default); every `MarkdownHeaders::STRIP` header removed from the response; `modifiedDate` cleared so `respond()` adds no `Last-Modified` to a cacheable page (an uncachable page still gets Joomla's response-time `Last-Modified`, set after the plugin runs).

Deliberate differences from Cloudflare: `<title>` fallback for the frontmatter title, `x-markdown-tokens`, no default `Content-Signal`.

### addLinks()

One `Link` header (`setHeader(…, true)`), merged with existing `Link` values by `LinkHeader::merge()` (same URI + rel once):
- `<{root}llms.txt>; rel="describedby"; type="text/markdown"`: `link_llms` and `JPATH_ROOT/llms.txt` exists;
- `<{root}.well-known/agent-skills/index.json>; rel="describedby"; type="application/json"`: `link_agent_skills` and the file exists;
- `<{sitemap}>; rel="sitemap"; type="application/xml"`: `sitemap_url` set (relative → `Uri::root()` before it);
- `<{page URL}>; rel="alternate"; type="text/markdown"`: Markdown on and `link_markdown`.

## Negotiation

`AcceptHeader::prefersMarkdown()`: parses ranges and `q` (invalid q = 0, a repeated range keeps its highest q). Markdown when `text/markdown` is listed with q > 0 and q ≥ the q of `text/html`, else `text/*`, else `*/*` (0 when none). Wildcards never ask for Markdown; ties go to Markdown.

## Extraction

`PageExtractor::extract()` parses with `DOMDocument::loadHTML` (UTF-8 via the `<?xml encoding>` prefix, libxml errors suppressed), then:
- **meta**: title = `meta[name=title]` → `og:title` → `<title>`; description = `meta[name=description]` → `og:description`; image = `og:image`; whitespace collapsed.
- **JSON-LD**: every `script[type=application/ld+json]` in the document (case-insensitive type), trimmed.
- **content**: the first match of the content selectors in list order (not document order); null when none matches.
- **removeNodes**: comments, the site landmarks (`SITE_LANDMARKS`: `header`/`footer` without an `article`, `aside`, `main`, `nav` or `section` ancestor, and `[role=banner]`/`[role=contentinfo]`, as the HTML spec defines banner and contentinfo) and every match of the remove selectors inside the content.
- **tidy**: removes `img[alt=""]`; unwraps links to `#…` and `javascript:`; a link around block elements (clickable card) becomes a link around its texts joined with spaces; two sibling elements with nothing between them get a space text node (name and job title in separate spans).
- **absolutize**: `href` and `src` resolved against `<base href>` (itself resolved) or the page URL.

`Selector` supports `tag`, `*`, `#id`, `.class` (whole word), `[attr]`, `[attr=value]` (bare or quoted), compounds, descendant and `>` combinators, comma lists; a part with other syntax is skipped.

## Rendering

`MarkdownRenderer::render()`: league `HtmlConverter` with `header_style` atx, `strip_tags`, `remove_nodes` script/style/noscript/template, `strip_placeholder_links`, `hard_break` false (a `<br>` becomes two spaces + newline), `list_item_style` `-`, plus `TableConverter`. Then `tidy()` outside fenced code: whitespace-only lines emptied, 1–3 leading spaces, extra spaces after a heading's `#` and trailing spaces removed (two trailing spaces after text kept), runs of blank lines collapsed, HTML entities decoded except `&lt;`/`&gt;`. Empty body → `''`.

Layout: `---` frontmatter with JSON-encoded values (valid YAML), body, then ```` ```json ```` with each JSON-LD block on its own line; parts separated by a blank line, one trailing newline. `estimateTokens()` = ceil(characters / 4).

## Settings

| Fieldset | Name | Default |
|---|---|---|
| basic (Markdown) | `markdown`, `content_selector`, `remove_selectors`, `frontmatter`, `jsonld` | 1, `main, [role=main], article, body`, `AgentReady::DEFAULT_REMOVE_SELECTORS`, 1, 1 |
| links | `link_headers`, `link_llms`, `link_agent_skills`, `sitemap_url`, `link_markdown` | 1, 1, 1, '', 1 |
| advanced | `skip_logged_in`, `skip_noindex`, `vary_html`, `content_signal` | 1, 1, 1, '' |

The defaults of `content_selector` and `remove_selectors` exist twice (manifest and class constants); `PluginContractTest` keeps them equal.

## Tests

`tests/unit/`: `AcceptHeaderTest`, `SelectorTest`, `UrlResolverTest`, `PageExtractorTest`, `MarkdownRendererTest`, `VaryHeaderTest`, `LinkHeaderTest`, `MarkdownHeadersTest`, `ConversionCasesTest` (end-to-end cases from gehandicaptenvalkenswaard.nl and momentsuntil.com) and `PluginContractTest` (manifest ↔ class settings ↔ en-GB/nl-NL strings, subscribed events, package version). `AgentReady` itself has no unit test (it needs Joomla); test it on a DDEV site (`docs/Ontwikkelworkflow.md`).

## See also

- [pkg_agentready](pkg_agentready.md)
