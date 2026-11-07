<?php

declare(strict_types=1);

/**
 * Accept negotiation: Markdown only when text/markdown is asked for explicitly and ranks at least
 * as high as HTML. Run: php tests/unit/AcceptHeaderTest.php
 */

require __DIR__ . '/../bootstrap.php';

use HKweb\Plugin\System\AgentReady\Negotiation\AcceptHeader;

check('no header', AcceptHeader::prefersMarkdown(null), false);
check('empty header', AcceptHeader::prefersMarkdown(''), false);
check('only markdown', AcceptHeader::prefersMarkdown('text/markdown'), true);
check('markdown and html, equal q', AcceptHeader::prefersMarkdown('text/markdown, text/html'), true);
check('html first, markdown lower q', AcceptHeader::prefersMarkdown('text/html, text/markdown;q=0.9'), false);
check('markdown lower than html', AcceptHeader::prefersMarkdown('text/markdown;q=0.5, text/html'), false);
check('markdown q=0', AcceptHeader::prefersMarkdown('text/markdown;q=0'), false);
check('wildcard is not markdown', AcceptHeader::prefersMarkdown('*/*'), false);
check('text wildcard is not markdown', AcceptHeader::prefersMarkdown('text/*'), false);
check('markdown above */*', AcceptHeader::prefersMarkdown('text/markdown;q=0.8, */*;q=0.1'), true);
check('markdown below text/*', AcceptHeader::prefersMarkdown('text/markdown;q=0.5, text/*;q=0.9'), false);
check('specific html beats wildcard', AcceptHeader::prefersMarkdown('text/markdown;q=0.5, text/html;q=0.4, */*'), true);
check('case-insensitive', AcceptHeader::prefersMarkdown('Text/Markdown'), true);
check('spaces and charset param', AcceptHeader::prefersMarkdown(' text/markdown ; charset=utf-8 ; q=1.0 , text/html;q=0.9'), true);
check('browser header', AcceptHeader::prefersMarkdown('text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'), false);
check('garbage q', AcceptHeader::prefersMarkdown('text/markdown;q=abc'), false);

finish('AcceptHeader');
