# Agent Ready for Joomla

A Joomla system plugin that makes a site readable for AI agents, without a paid CDN feature:

- **Markdown for Agents.** A request with `Accept: text/markdown` gets a Markdown version of the page, in the layout of [Cloudflare's Markdown for Agents](https://developers.cloudflare.com/fundamentals/reference/markdown-for-agents/): YAML frontmatter (title, description, image), the main content, and the page's JSON-LD in a `json` code block at the end. HTML stays the default.
- **Link headers** ([RFC 8288](https://www.rfc-editor.org/rfc/rfc8288)) on HTML pages that point agents to `llms.txt`, the agent skills index, the sitemap and the Markdown version of the page.

It passes the *Markdown negotiation* and *Link headers* checks of [isitagentready.com](https://isitagentready.com/).

Requirements: Joomla 5.3.3+ or 6.x, PHP 8.3+.

## Install

Download `pkg_agentready-{version}.zip` from the [releases](https://github.com/hans2103/plg_system_agentready/releases) and install it under *System → Install → Extensions*. The plugin is enabled on a first install. Updates come through Joomla's update manager (`https://updates.hkweb.nl/agentready/updates.xml`).

Try it:

```bash
curl -H 'Accept: text/markdown' https://example.com/
```

## What a Markdown answer looks like

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

`x-markdown-tokens` is an estimate (characters / 4). As Cloudflare does, `ETag`, `Last-Modified`, `Content-Length`, `Content-Encoding`, `Content-Range` and `Transfer-Encoding` are dropped; all other headers (CSP, HSTS, `Cache-Control`, `Expires`, cookies) stay. One exception: on a page Joomla marks as uncachable, Joomla itself adds `Last-Modified` with the response time after the plugin has run.

A `Content-Signal` the site already sends is kept; otherwise the plugin sends the one from its settings, or none. Unlike Cloudflare there is no default (`ai-train=yes, search=yes, ai-input=yes`): what agents may do with the content is the site owner's call.

### Differences from Cloudflare

- The frontmatter `title` falls back to `<title>` when the page has no `meta name="title"` or `og:title`.
- `x-markdown-tokens` is sent.
- No default `Content-Signal` (see above).

## When it converts

Markdown only when **all** of these hold:

- the request has an explicit `text/markdown` with a `q` at least as high as HTML's (`text/html`, else `text/*`, else `*/*`); `*/*` alone never asks for Markdown;
- front end, `GET` or `HEAD`, an HTML document with status 200, at most 6 MiB of HTML (Cloudflare's limit);
- the visitor is a guest (setting) and the page has no `noindex` in its robots meta tag or `X-Robots-Tag` (setting).

Otherwise the HTML goes out unchanged. If the conversion fails, the HTML goes out and a warning is logged in the `agentready` log category.

## Settings

| Tab | Setting | Default |
|---|---|---|
| Markdown | Markdown version on/off | on |
| Markdown | Main content: CSS selectors, first match wins | `main, [role=main], article, body` |
| Markdown | Leave out: CSS selectors removed from the content (add your cookie banner here) | scripts, styles, svg, forms, buttons, `nav`, `dialog`, `[hidden]`, `[aria-hidden=true]` |
| Markdown | Frontmatter, JSON-LD | on, on |
| Link headers | Link headers on/off; llms.txt and agent skills index (only when the file exists in the site root); sitemap URL (empty = none); Markdown alternate | on |
| Advanced | Not for logged-in users, not for noindex pages, `Vary: Accept` on HTML, `Content-Signal` header (empty = none) | on, on, on, empty |

The site header and footer always go, as the HTML spec defines them: a `header` or `footer` outside `article`, `aside`, `main`, `nav` and `section`, and `[role=banner]` and `[role=contentinfo]`. The header of an article (its title) stays.

The selectors support `tag`, `#id`, `.class`, `[attr]`, `[attr=value]`, compounds and the space and `>` combinators. Relative links and image sources in the Markdown become absolute; links to `#fragments` or `javascript:` become plain text; images with `alt=""` are left out.

## Caching

- **Joomla page cache** (`System - Page Cache`): the Markdown variant gets its own cache entry (`onPageCacheGetKey`), so a browser never gets cached Markdown and an agent never gets cached HTML.
- **Joomla's gzip setting**: Joomla's own compression drops every `Vary` value except `Accept-Encoding` (a core bug in `sendHeaders()`). The plugin therefore switches Joomla's gzip off for front-end HTML pages while it sends `Vary: Accept`; let the web server or CDN compress, as most do already.
- **Cloudflare and other CDNs**: every HTML page carries `Vary: Accept`. Cloudflare caches HTML only with a *Cache Everything* rule, and then ignores `Vary: Accept`. With such a rule, add a cache rule that bypasses the cache when the request header `Accept` contains `text/markdown`.

## Develop

Built and released with the HKweb Joomla tooling (`bin/`, `scripts.conf`, `package.sh`). See `CLAUDE.md` and `docs/Ontwikkelworkflow.md`.

```bash
bash package.sh                                        # packages/{version}/pkg_agentready-{version}.zip
for f in tests/unit/*.php; do php "$f" || echo "FAIL $f"; done
bash tests/shell/run-all.sh
bash bin/preflight.sh
```

HTML → Markdown uses [league/html-to-markdown](https://github.com/thephpleague/html-to-markdown) (MIT), bundled in the plugin's `vendor/`.

## License

GNU General Public License version 2 or later; see `LICENSE.txt`.
