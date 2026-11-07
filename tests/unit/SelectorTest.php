<?php

declare(strict_types=1);

/**
 * CSS selector subset → XPath. Run: php tests/unit/SelectorTest.php
 */

require __DIR__ . '/../bootstrap.php';

use HKweb\Plugin\System\AgentReady\Html\Selector;

$html = <<<'HTML'
<html><body>
<nav id="menu"><a id="n1" href="/">Home</a></nav>
<main id="content" class="mu-main page" role="main">
  <div class="x a b" id="d1"><p id="p1">One</p></div>
  <div class="a" id="d2" hidden><span id="s1" aria-hidden="true">x</span></div>
  <ul id="u1"><li id="l1">A<ul><li id="l2">B</li></ul></li></ul>
</main>
</body></html>
HTML;

$doc = new DOMDocument();
@$doc->loadHTML($html);
$xp = new DOMXPath($doc);

function ids(DOMXPath $xp, string $selector): array
{
	$path = Selector::toXPath($selector);

	if ($path === null) {
		return ['NULL'];
	}

	$ids = [];

	foreach ($xp->query($path) as $node) {
		$ids[] = $node instanceof DOMElement ? ($node->getAttribute('id') ?: $node->nodeName) : '?';
	}

	return $ids;
}

check('tag', ids($xp, 'main'), ['content']);
check('id', ids($xp, '#content'), ['content']);
check('two classes', ids($xp, '.a.b'), ['d1']);
check('tag.class', ids($xp, 'div.x'), ['d1']);
check('class matches whole word only', ids($xp, '.mu'), []);
check('attr bare value', ids($xp, '[role=main]'), ['content']);
check('attr quoted value', ids($xp, '[aria-hidden="true"]'), ['s1']);
check('attr presence', ids($xp, '[hidden]'), ['d2']);
check('descendant', ids($xp, 'nav a'), ['n1']);
check('child', ids($xp, '#u1 > li'), ['l1']);
check('descendant reaches nested', ids($xp, '#u1 li'), ['l1', 'l2']);
check('list', ids($xp, 'nav, main'), ['menu', 'content']);
check('invalid part skipped', ids($xp, 'div::before, #p1'), ['p1']);
check('all invalid gives null', Selector::toXPath('a:hover, ~x'), null);
check('empty list gives null', Selector::toXPath(' , '), null);
check('toXPaths keeps list order', count(Selector::toXPaths('body, main, a:hover')), 2);
check('quote in value', ids($xp, "[title=\"it's\"]"), []);
check('uppercase tag', ids($xp, 'MAIN'), ['content']);

finish('Selector');
