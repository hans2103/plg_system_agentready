<?php

declare(strict_types=1);

/**
 * Response header rules for a Markdown answer. Run: php tests/unit/MarkdownHeadersTest.php
 */

require __DIR__ . '/../bootstrap.php';

use HKweb\Plugin\System\AgentReady\Http\MarkdownHeaders;

foreach (['ETag', 'Last-Modified', 'Content-Length', 'Content-Encoding', 'Content-Range', 'Transfer-Encoding'] as $name) {
	check("stripped: $name", in_array($name, MarkdownHeaders::STRIP, true), true);
}

foreach (['Cache-Control', 'Expires', 'Set-Cookie', 'Content-Security-Policy', 'Strict-Transport-Security', 'Vary'] as $name) {
	check("kept: $name", in_array($name, MarkdownHeaders::STRIP, true), false);
}

check('6 MiB of HTML', MarkdownHeaders::MAX_HTML_BYTES, 6291456);
check('size: at the limit converts', MarkdownHeaders::fits(str_repeat('a', 6291456)), true);
check('size: one byte over stays HTML', MarkdownHeaders::fits(str_repeat('a', 6291457)), false);

check('signal: setting when the site sends none', MarkdownHeaders::contentSignal([], ' search=yes, ai-train=no '), 'search=yes, ai-train=no');
check('signal: none when the setting is empty', MarkdownHeaders::contentSignal([], '  '), null);
check('signal: the site value wins over the setting', MarkdownHeaders::contentSignal(['ai-train=no'], 'ai-train=yes'), null);
check('signal: an empty site value does not count', MarkdownHeaders::contentSignal([' '], 'search=yes'), 'search=yes');

finish('MarkdownHeaders');
