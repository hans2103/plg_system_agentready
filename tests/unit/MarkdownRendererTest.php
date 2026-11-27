<?php

declare(strict_types=1);

/**
 * Markdown document layout (frontmatter, body, JSON-LD) and the token estimate.
 * Run: php tests/unit/MarkdownRendererTest.php
 */

require __DIR__ . '/../bootstrap.php';

use HKweb\Plugin\System\AgentReady\Html\ExtractedPage;
use HKweb\Plugin\System\AgentReady\Markdown\MarkdownRenderer;

$html = '<h1>Café</h1><p>Text with <strong>bold</strong> and <a href="https://example.com/x">a link</a>.</p>'
	. '<ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul>'
	. '<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>'
	. '<section><div><span>Wrapped</span></div></section>';

$page = new ExtractedPage(['title' => 'Say "hi" — ok', 'description' => 'D'], $html, ['{"@type":"A"}', '{"@type":"B"}']);
$md   = MarkdownRenderer::render($page);

check('frontmatter first, JSON-quoted, unicode kept', str_starts_with($md, "---\ntitle: \"Say \\\"hi\\\" — ok\"\ndescription: \"D\"\n---\n\n# Café\n"), true);
check('bold', str_contains($md, '**bold**'), true);
check('link', str_contains($md, '[a link](https://example.com/x)'), true);
check('list', str_contains($md, "- One\n- Two\n    - Nested"), true);
check('table', str_contains($md, '| A | B |'), true);
check('wrapper tags stripped', str_contains($md, '<section>') || str_contains($md, '<span>'), false);
check('wrapped text kept', str_contains($md, 'Wrapped'), true);
check('json-ld block last', str_ends_with($md, "```json\n{\"@type\":\"A\"}\n{\"@type\":\"B\"}\n```\n"), true);
check('single trailing newline', substr($md, -2) !== "\n\n", true);

$plain = MarkdownRenderer::render(new ExtractedPage([], '<p>x</p>', []));
check('no meta, no json-ld', $plain, "x\n");
check('frontmatter disabled', str_starts_with(MarkdownRenderer::render($page, false, true), '# Café'), true);
check('json-ld disabled', str_contains(MarkdownRenderer::render($page, true, false), '```json'), false);
$full = MarkdownRenderer::render(new ExtractedPage(['image' => 'https://e.test/i.png', 'lang' => 'nl', 'url' => 'https://e.test/p', 'title' => 'T'], '<p>B</p>', []));
check('frontmatter order title, url, lang, image', str_starts_with($full, "---\ntitle: \"T\"\nurl: \"https://e.test/p\"\nlang: \"nl\"\nimage: \"https://e.test/i.png\"\n---\n\nB\n"), true);
check('empty content', MarkdownRenderer::render(new ExtractedPage(['title' => 'T'], '', ['{}'])), '');
check('whitespace-only content', MarkdownRenderer::render(new ExtractedPage(['title' => 'T'], "<div> \n </div>", [])), '');

check('tokens of 5 chars', MarkdownRenderer::estimateTokens('abcde'), 2);
check('tokens count characters, not bytes', MarkdownRenderer::estimateTokens('éééé'), 1);
check('tokens of empty', MarkdownRenderer::estimateTokens(''), 0);

check('tidy: whitespace-only lines and blank runs', MarkdownRenderer::tidy("a\n \n  \n\n\nb"), "a\n\nb");
check('tidy: stray indentation and trailing space', MarkdownRenderer::tidy(" [x](y) \n   z"), "[x](y)\nz");
check('tidy: one space after heading marks', MarkdownRenderer::tidy("#  How it works\n##   Two"), "# How it works\n## Two");
check('tidy: four-space nesting kept', MarkdownRenderer::tidy("- a\n    - b"), "- a\n    - b");
check('tidy: deep indentation outside lists gone', MarkdownRenderer::tidy("Price\n\n     € 7,49\n\t\tIn stock"), "Price\n\n€ 7,49\nIn stock");
check('tidy: list nesting kept after blank line', MarkdownRenderer::tidy("1. a\n\n    - b\n        - c"), "1. a\n\n    - b\n        - c");
check('tidy: ordered list continuation kept', MarkdownRenderer::tidy("1. Name\n\n      Review text"), "1. Name\n\n      Review text");
check('tidy: indentation after a list ends gone', MarkdownRenderer::tidy("- a\n\nText\n\n     more"), "- a\n\nText\n\nmore");
check('tidy: empty links dropped', MarkdownRenderer::tidy("Share [ ](https://x.test/a)[](https://x.test/b)[\t](https://x.test/c) here"), "Share here");
check('tidy: image without alt kept', MarkdownRenderer::tidy('![](https://x.test/a.jpg)'), '![](https://x.test/a.jpg)');
check('tidy: hard break kept', MarkdownRenderer::tidy("Adres  \nPostcode"), "Adres  \nPostcode");
check('tidy: entities decoded, lt/gt kept', MarkdownRenderer::tidy('Sophie &amp; Jamie &rsquo; &#169; &lt;b&gt;'), 'Sophie & Jamie ’ © &lt;b&gt;');
check('tidy: fenced code untouched', MarkdownRenderer::tidy("```\n  &amp;  \n```"), "```\n  &amp;  \n```");

finish('MarkdownRenderer');
