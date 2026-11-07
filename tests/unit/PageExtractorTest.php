<?php

declare(strict_types=1);

/**
 * Metadata, JSON-LD and the cleaned main content. Run: php tests/unit/PageExtractorTest.php
 */

require __DIR__ . '/../bootstrap.php';

use HKweb\Plugin\System\AgentReady\Html\PageExtractor;

const REMOVE = 'script, style, nav, [hidden], [aria-hidden=true], button';

$page = <<<'HTML'
<!DOCTYPE html>
<html lang="en"><head>
<title>Doc title</title>
<meta property="og:title" content="OG title">
<meta property="og:description" content="OG description">
<meta name="description" content="  Real
 description ">
<meta property="og:image" content="https://example.com/i.png">
<script type="application/ld+json">
 {"@type":"Organization"}
</script>
<style>body{}</style>
</head><body>
<header><nav><a href="/">Menu</a></nav></header>
<main id="main">
  <!-- a comment -->
  <h1>Café — 🎄</h1>
  <p>Read <a href="/more">more</a> or <a href="#x">jump</a>. <img src="img/a.png" alt="A"></p>
  <nav><a href="/sub">Sub menu</a></nav>
  <div hidden>Hidden notice</div>
  <span aria-hidden="true">icon</span>
  <button type="button">Close</button>
  <script>alert(1)</script>
  <script type="application/ld+json">{"@type":"WebPage"}</script>
</main>
<div id="cookie">Cookies!</div>
</body></html>
HTML;

$result = PageExtractor::extract($page, 'main, body', REMOVE, 'https://example.com/en/page');

check('result', $result !== null, true);
check('meta name wins over og, whitespace collapsed', $result?->meta['description'] ?? null, 'Real description');
check('og:title before <title>', $result?->meta['title'] ?? null, 'OG title');
check('image', $result?->meta['image'] ?? null, 'https://example.com/i.png');
check('json-ld from head and body', $result?->jsonLd, ['{"@type":"Organization"}', '{"@type":"WebPage"}']);

$content = $result?->contentHtml ?? '';
check('heading kept, UTF-8 intact', str_contains($content, '<h1>Café — 🎄</h1>'), true);
check('root-relative link absolute', str_contains($content, 'href="https://example.com/more"'), true);
check('fragment link becomes text', str_contains($content, 'href="#x"') || !str_contains($content, 'jump'), false);
check('img src absolute', str_contains($content, 'src="https://example.com/en/img/a.png"'), true);
foreach (['Sub menu', 'Hidden notice', 'icon', 'Close', 'alert(1)', 'WebPage', 'a comment', 'Cookies!', 'Menu</a>'] as $gone) {
	check("removed: $gone", str_contains($content, $gone), false);
}

$noMain = PageExtractor::extract('<html><head><title>T</title></head><body><p>Only body</p></body></html>', 'main, body', REMOVE, 'https://example.com/');
check('falls back to body', $noMain?->contentHtml, '<p>Only body</p>');
check('title fallback', $noMain?->meta, ['title' => 'T']);
check('no json-ld', $noMain?->jsonLd, []);

$order = PageExtractor::extract('<body><article>A</article><main>M</main></body>', 'main, article', '', 'https://example.com/');
check('list order wins, not document order', $order?->contentHtml, 'M');

$base = PageExtractor::extract('<head><base href="/sub/"></head><body><a href="x">x</a></body>', 'body', '', 'https://example.com/a/b');
check('base href respected', $base?->contentHtml, '<a href="https://example.com/sub/x">x</a>');

$landmarks = <<<'HTML'
<body>
<header class="site">Site header</header>
<div role="banner">Banner div</div>
<article><header><h1>Article title</h1></header><p>Text</p><footer>Article footer</footer></article>
<section><header>Section header</header></section>
<div class="wrap"><footer>Wrapped site footer</footer></div>
<div role="contentinfo">Contentinfo div</div>
<footer>Site footer</footer>
</body>
HTML;
$body = PageExtractor::extract($landmarks, 'body', '', 'https://example.com/')?->contentHtml ?? '';
foreach (['Site header', 'Banner div', 'Wrapped site footer', 'Contentinfo div', 'Site footer'] as $gone) {
	check("site landmark removed: $gone", str_contains($body, $gone), false);
}
foreach (['Article title', 'Article footer', 'Section header', 'Text'] as $kept) {
	check("sectioning header/footer kept: $kept", str_contains($body, $kept), true);
}
$inMain = PageExtractor::extract('<body><main><header><h1>Main title</h1></header><p>x</p></main></body>', 'main', '', 'https://example.com/');
check('header inside main kept', $inMain?->contentHtml, '<header><h1>Main title</h1></header> <p>x</p>');

check('empty html', PageExtractor::extract('   ', 'body', '', 'https://example.com/'), null);
check('no matching selector', PageExtractor::extract('<body><p>x</p></body>', 'main', '', 'https://example.com/'), null);
check('invalid selectors only', PageExtractor::extract('<body><p>x</p></body>', 'a:hover', '', 'https://example.com/'), null);

finish('PageExtractor');
