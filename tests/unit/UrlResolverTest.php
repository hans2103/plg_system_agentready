<?php

declare(strict_types=1);

/**
 * Relative links become absolute against the page URL. Run: php tests/unit/UrlResolverTest.php
 */

require __DIR__ . '/../bootstrap.php';

use HKweb\Plugin\System\AgentReady\Html\UrlResolver;

$base = 'https://example.com/a/b?x=1';

check('root-relative', UrlResolver::resolve($base, '/x'), 'https://example.com/x');
check('path-relative', UrlResolver::resolve($base, 'img.png'), 'https://example.com/a/img.png');
check('dot segments', UrlResolver::resolve($base, '../c/./d'), 'https://example.com/c/d');
check('too many dot-dots', UrlResolver::resolve($base, '../../../e'), 'https://example.com/e');
check('query only', UrlResolver::resolve($base, '?y=2'), 'https://example.com/a/b?y=2');
check('query and fragment kept', UrlResolver::resolve($base, 'f?q=1#top'), 'https://example.com/a/f?q=1#top');
check('fragment untouched', UrlResolver::resolve($base, '#top'), '#top');
check('absolute untouched', UrlResolver::resolve($base, 'https://other.test/x'), 'https://other.test/x');
check('mailto untouched', UrlResolver::resolve($base, 'mailto:a@b.c'), 'mailto:a@b.c');
check('protocol-relative', UrlResolver::resolve($base, '//cdn.test/y'), 'https://cdn.test/y');
check('port kept', UrlResolver::resolve('https://site.ddev.site:8443/', 'p'), 'https://site.ddev.site:8443/p');
check('empty untouched', UrlResolver::resolve($base, ''), '');
check('base without path', UrlResolver::resolve('https://example.com', 'z'), 'https://example.com/z');
check('invalid base leaves reference', UrlResolver::resolve('not a url', '/x'), '/x');

finish('UrlResolver');
