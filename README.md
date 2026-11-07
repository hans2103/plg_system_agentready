# Agent Ready for Joomla

Make your Joomla site easy to read for AI agents, with a free plugin instead of a paid CDN feature.

AI agents and LLM-based tools read web pages too. A full HTML page is mostly menus, scripts and styling, which wastes their context and money. **Agent Ready** gives them a clean Markdown version of each page on request, and tells them where to find more about your site. Visitors with a browser see exactly the same site as before.

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Installation](#installation)
- [Check that it works](#check-that-it-works)
- [Settings](#settings)
- [How it works](#how-it-works)
- [Caching, CDNs and Cloudflare](#caching-cdns-and-cloudflare)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [License](#license)

## What it does

**1. Markdown for Agents.** When a request asks for Markdown (`Accept: text/markdown`), the plugin answers with a Markdown version of the page instead of HTML. It follows the format of [Cloudflare's Markdown for Agents](https://developers.cloudflare.com/fundamentals/reference/markdown-for-agents/):

- a YAML frontmatter block with the page's title, description and image;
- the main content of the page, without menus, scripts, styling, forms, the site header and footer;
- the page's structured data (JSON-LD) at the end, in one `json` code block.

**2. Link headers for agent discovery.** Every HTML page gets a `Link` header ([RFC 8288](https://www.rfc-editor.org/rfc/rfc8288)) that points agents to:

- your `llms.txt` (only when that file exists);
- your agent skills index, `.well-known/agent-skills/index.json` (only when that file exists);
- your Agentic Resource Discovery (ARD) manifest, `.well-known/ai-catalog.json` (only when that file exists); this one also goes into the HTML head as `<link rel="ai-catalog">`;
- your MCP Server Card, `.well-known/mcp/server-card.json` (only when that file exists);
- your XML sitemap (when you enter its URL);
- the Markdown version of the page.

Together these pass the *Markdown negotiation*, *Link headers* and *ARD* checks of [isitagentready.com](https://isitagentready.com/).

HTML always stays the default: browsers, search engines and anything else that does not ask for Markdown get the normal page.

## Requirements

- Joomla 5.3.3 or later, or Joomla 6
- PHP 8.3 or later

There is nothing else to install: the HTML-to-Markdown library is included in the package.

## Installation

1. Download `pkg_agentready-{version}.zip` from the [releases page](https://github.com/hans2103/plg_system_agentready/releases).
2. In the Joomla administrator, go to *System → Install → Extensions* and upload the zip.
3. Done. The plugin (*System - Agent Ready*) is enabled on a first install and works with its default settings.

Updates appear in Joomla's own update manager (*System → Update → Extensions*). The update list lives in this repository ([`updates.xml`](updates.xml)) and the downloads come from the GitHub releases.

## Check that it works

Ask for the Markdown version of your home page:

```bash
curl -i -H 'Accept: text/markdown' https://example.com/
```

You should see `content-type: text/markdown; charset=utf-8` and the Markdown below the headers. A shortened example:

```http
HTTP/2 200
content-type: text/markdown; charset=utf-8
vary: Accept
x-markdown-tokens: 793
```

~~~markdown
---
title: "Make their wait beautiful."
description: "A countdown calendar with a new window to open each day."
image: "https://example.com/images/cover.png"
---

# Make their *wait* beautiful.

A handmade countdown for any moment. [Start a calendar →](https://example.com/start)

```json
{"@context":"https://schema.org","@type":"WebPage", …}
```
~~~

Then check the Link header on the normal HTML page:

```bash
curl -sI https://example.com/ | grep -i '^link'
```

```http
link: <https://example.com/llms.txt>; rel="describedby"; type="text/markdown", <https://example.com/>; rel="alternate"; type="text/markdown"
```

Getting HTML back instead of Markdown? See [Troubleshooting](#troubleshooting).

## Settings

Open *System → Plugins → System - Agent Ready*. The defaults suit most sites.

### Markdown tab

| Setting | Default | What it does |
|---|---|---|
| Markdown version | On | Answer `Accept: text/markdown` requests with Markdown. |
| Main content | `main, [role=main], article, body` | CSS selectors for the element that holds the main content. The first selector that matches wins, so put the most specific one first. |
| Leave out | scripts, styles, `svg`, forms, buttons, `nav`, `dialog`, `[hidden]`, `[aria-hidden=true]` | CSS selectors for elements inside the main content that stay out of the Markdown. **Add your cookie banner here** if it sits inside the main content. |
| Frontmatter | On | Start the Markdown with the title, description and image. |
| JSON-LD | On | Add the page's structured data at the end. |

The selectors support `tag`, `#id`, `.class`, `[attr]`, `[attr=value]`, combinations such as `div.notice`, and the space and `>` combinators. Pseudo-classes such as `:hover` are not supported and are skipped.

### Link headers tab

| Setting | Default | What it does |
|---|---|---|
| Link headers | On | Send the `Link` header on HTML pages. Links set by other plugins are kept. |
| llms.txt | On | Link to `/llms.txt`, only when that file exists in the site root. |
| Agent skills index | On | Link to `/.well-known/agent-skills/index.json`, only when that file exists. |
| AI catalog (ARD) | On | Link to `/.well-known/ai-catalog.json` (`rel="ai-catalog"`), in the `Link` header and as `<link>` in the HTML head, only when that file exists. |
| MCP Server Card | On | Link to `/.well-known/mcp/server-card.json` (`rel="describedby"`), only when that file exists. |
| Sitemap URL | Empty | The URL of your XML sitemap, for example `/sitemap.xml`. Empty sends no sitemap link. |
| Markdown version | On | Link to the Markdown version of the page itself. |

The plugin only links to these files; it does not create them.

### Advanced tab

| Setting | Default | What it does |
|---|---|---|
| Not for logged-in users | On | Logged-in users always get HTML, so personal content never ends up in a Markdown answer. |
| Not for noindex pages | On | Pages with `noindex` in their robots meta tag or `X-Robots-Tag` header stay HTML. |
| Vary: Accept on HTML | On | Also send `Vary: Accept` on HTML pages, so caches keep the two versions apart. Leave this on. |
| Content-Signal header | Empty | An optional [Content-Signal](https://contentsignals.org/) header on the Markdown answer, for example `search=yes, ai-input=yes, ai-train=no`. Empty sends none. |

## How it works

### When a page is converted

The plugin answers with Markdown only when **all** of these are true:

- The request lists `text/markdown` with a quality (`q`) at least as high as HTML's. `Accept: */*` alone never gets Markdown.
- It is a front-end `GET` or `HEAD` request for an HTML page with status 200.
- The HTML is at most 6 MiB (Cloudflare's limit).
- The visitor is not logged in, and the page is not `noindex` (both settings, on by default).

In every other case the normal HTML goes out unchanged. If the conversion fails, the HTML goes out too, and a warning is logged in the `agentready` log category.

### What ends up in the Markdown

- **Content:** the first element that matches *Main content*, minus the *Leave out* elements, HTML comments and the site header and footer. The site header and footer are what the HTML spec calls them: a `header` or `footer` outside an `article`, `aside`, `main`, `nav` or `section`, and anything with `role="banner"` or `role="contentinfo"`. The header of an article, with its title, stays.
- **Links and images:** relative URLs become absolute. Links to `#anchors` or `javascript:` become plain text. Decorative images (`alt=""`) are left out.
- **Frontmatter:** `title` from `<meta name="title">`, then `og:title`, then `<title>`; `description` from `<meta name="description">`, then `og:description`; `image` from `og:image`. Empty fields are left out.
- **JSON-LD:** every `<script type="application/ld+json">` on the page, also those outside the main content.

### Response headers

- `Content-Type: text/markdown; charset=utf-8`
- `Vary: Accept`, added to any `Vary` values already there
- `x-markdown-tokens`: an estimate of the size in tokens (characters / 4)
- `Content-Signal`: a value your site already sends is kept; otherwise the one from the settings, or none
- Removed, because they describe the HTML and not the Markdown: `ETag`, `Last-Modified`, `Content-Length`, `Content-Encoding`, `Content-Range`, `Transfer-Encoding`. One exception: on pages Joomla marks as uncachable, Joomla itself adds `Last-Modified` with the current time after the plugin has run.
- Everything else stays, such as `Cache-Control`, `Expires`, CSP, HSTS and cookies.

### Differences from Cloudflare

Agent Ready follows Cloudflare's format, with three deliberate differences:

- The frontmatter `title` falls back to `<title>`, so pages without a title meta tag still get a title.
- It sends `x-markdown-tokens`.
- It sends no default `Content-Signal`. Cloudflare sends `ai-train=yes, search=yes, ai-input=yes` when the site sets none; what agents may do with your content is your call, so set it yourself if you want one.

## Caching, CDNs and Cloudflare

- **Joomla page cache** (*System - Page Cache*): works. The Markdown version gets its own cache entry, so a browser never gets cached Markdown and an agent never gets cached HTML.
- **Joomla's Gzip Page Compression setting:** the plugin switches Joomla's own gzip off for front-end HTML pages. Joomla's compression drops every `Vary` value except `Accept-Encoding` (a bug in Joomla's `sendHeaders()`), which would mix up the HTML and Markdown versions in caches. Your web server or CDN compresses the pages instead; most already do.
- **Cloudflare and other CDNs:** every HTML page carries `Vary: Accept`. On Cloudflare that is fine by default, because Cloudflare does not cache HTML. If you use a *Cache Everything* rule, Cloudflare ignores `Vary: Accept` and could serve the wrong version. Then add a cache rule that bypasses the cache when the request header `Accept` contains `text/markdown`.

## Troubleshooting

**I get HTML instead of Markdown.** Check, in this order:

1. Is the plugin enabled, with *Markdown version* on?
2. Are you logged in? Logged-in users always get HTML. `curl` is never logged in, so test with `curl` first.
3. Is the page `noindex`? Look for `noindex` in its robots meta tag.
4. Does your `Accept` header give HTML a higher `q` than Markdown? `text/markdown, text/html;q=0.9` gets Markdown; `text/html, text/markdown;q=0.5` gets HTML.
5. Is a CDN cache in between? Try the request against the origin, or see [Caching](#caching-cdns-and-cloudflare).
6. Look in the Joomla log (`administrator/logs/`) for warnings in the `agentready` category.

**The Markdown contains menus, a cookie banner or other clutter.** Add their selectors to *Leave out*, for example `#cookie-banner, .breadcrumbs`. If the wrong part of the page is used, put a more specific selector first in *Main content*.

**The Markdown is empty or misses content.** *Main content* may match the wrong element. Open the page source, find the element that holds the content, and put its selector first.

**There is no Link header.** Check that *Link headers* is on, and that `llms.txt` or the agent skills index actually exist in the site root. The Markdown alternate link needs *Markdown version* on.

## Development

Agent Ready is built and released with the HKweb Joomla tooling (`bin/`, `scripts.conf`, `package.sh`). Details: [`CLAUDE.md`](CLAUDE.md) and [`docs/`](docs/).

```bash
bash package.sh                                                  # build packages/{version}/pkg_agentready-{version}.zip
for f in tests/unit/*.php; do php "$f" || echo "FAIL $f"; done   # unit tests (plain PHP, no PHPUnit)
bash tests/shell/run-all.sh                                      # tests for the build and release scripts
bash bin/preflight.sh                                            # lint, manifests, versions, docs checks
```

HTML-to-Markdown conversion uses [league/html-to-markdown](https://github.com/thephpleague/html-to-markdown) (MIT licence), bundled in the plugin's `vendor/` folder.

Issues and pull requests are welcome on [GitHub](https://github.com/hans2103/plg_system_agentready).

## License

GNU General Public License version 2 or later; see [`LICENSE.txt`](LICENSE.txt).
