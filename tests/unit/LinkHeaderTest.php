<?php

declare(strict_types=1);

/**
 * Link header values (RFC 8288). Run: php tests/unit/LinkHeaderTest.php
 */

require __DIR__ . '/../bootstrap.php';

use HKweb\Plugin\System\AgentReady\Http\LinkHeader;

$llms = LinkHeader::link('https://example.com/llms.txt', 'describedby', 'text/markdown');

check('link value', $llms, '<https://example.com/llms.txt>; rel="describedby"; type="text/markdown"');
check('link without type', LinkHeader::link('https://example.com/', 'canonical'), '<https://example.com/>; rel="canonical"');
check('unsafe characters encoded', LinkHeader::link('https://example.com/a b>', 'x'), '<https://example.com/a%20b%3E>; rel="x"');
check('merge with nothing', LinkHeader::merge([], [$llms]), $llms);
check('existing value first, kept as is',
	LinkHeader::merge(['</style.css>; rel=preload; as=style'], [$llms]),
	'</style.css>; rel=preload; as=style, ' . $llms);
check('same uri and rel from another plugin not repeated',
	LinkHeader::merge(['<https://example.com/llms.txt>; rel="describedby"'], [$llms]),
	'<https://example.com/llms.txt>; rel="describedby"');
check('same uri, other rel kept',
	LinkHeader::merge(['<https://example.com/llms.txt>; rel="alternate"'], [$llms]),
	'<https://example.com/llms.txt>; rel="alternate", ' . $llms);
check('commas inside uri and quotes do not split',
	LinkHeader::merge(['<https://e.com/a,b>; rel="x"; title="a, b"'], []),
	'<https://e.com/a,b>; rel="x"; title="a, b"');
check('several existing headers and lists',
	LinkHeader::merge(['<a>; rel="x", <b>; rel="y"', '<a>; rel=x'], []),
	'<a>; rel="x", <b>; rel="y"');

finish('LinkHeader');
