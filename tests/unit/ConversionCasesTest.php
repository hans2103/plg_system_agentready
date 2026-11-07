<?php

declare(strict_types=1);

/**
 * End-to-end HTML → Markdown cases from real Joomla pages (gehandicaptenvalkenswaard.nl,
 * momentsuntil.com): PageExtractor followed by MarkdownRenderer.
 * Run: php tests/unit/ConversionCasesTest.php
 */

require __DIR__ . '/../bootstrap.php';

use HKweb\Plugin\System\AgentReady\Html\PageExtractor;
use HKweb\Plugin\System\AgentReady\Markdown\MarkdownRenderer;

const BASE = 'https://gehandicaptenvalkenswaard.nl/';
const REMOVE = 'script, style, noscript, template, svg, canvas, iframe, object, embed, form, button, input, select, textarea, nav, dialog, [hidden], [aria-hidden=true]';

function md(string $html): string
{
	$page = PageExtractor::extract('<html><body><main>' . $html . '</main></body></html>', 'main, body', REMOVE, BASE);

	return $page === null ? 'NULL' : rtrim(MarkdownRenderer::render($page, false, false), "\n");
}

check('headings and paragraphs, whitespace collapsed',
	md('<h1>Titel</h1><p>Een alinea met <strong>vet</strong> en <em>schuin</em>.</p><h2>Kop twee</h2><p>Tweede   alinea.</p>'),
	"# Titel\n\nEen alinea met **vet** en *schuin*.\n\n## Kop twee\n\nTweede alinea.");
check('links absolute',
	md('<p>Lees <a href="/over-ons">over ons</a> of <a href="https://example.com/a">extern</a>.</p>'),
	'Lees [over ons](https://gehandicaptenvalkenswaard.nl/over-ons) of [extern](https://example.com/a).');
check('mailto kept, anchor and javascript links become text',
	md('<p><a href="mailto:info@example.com">Mail</a> en <a href="#top">naar boven</a> of <a href="javascript:void(0)">menu</a></p>'),
	'[Mail](mailto:info@example.com) en naar boven of menu');
check('noise removed',
	md('<script>alert(1)</script><style>p{}</style><p>Zichtbaar</p><p hidden>Weg</p><span aria-hidden="true">icoon</span><svg><title>x</title></svg><form><input name="q"></form>'),
	'Zichtbaar');
check('image with alt kept, decorative image dropped',
	md('<p><img src="/images/a.jpg" alt="Rolstoel bij drempel"></p><p><img src="/images/deco.png" alt="">Tekst</p>'),
	"![Rolstoel bij drempel](https://gehandicaptenvalkenswaard.nl/images/a.jpg)\n\nTekst");
check('br is a hard line break, also in a blockquote',
	md('<blockquote><p>Citaat<br>regel twee</p></blockquote><p>Adres<br>Postcode</p>'),
	"> Citaat  \n> regel twee\n\nAdres  \nPostcode");
check('table',
	md('<table><thead><tr><th>Dag</th><th>Tijd</th></tr></thead><tbody><tr><td>Maandag</td><td>10:00</td></tr></tbody></table>'),
	"| Dag | Tijd |\n|---|---|\n| Maandag | 10:00 |");
check('clickable card becomes one link with spaced words',
	md('<a href="/melden"><h3>Knelpunt melden</h3><p>Meld een drempel.</p></a>'),
	'[Knelpunt melden Meld een drempel.](https://gehandicaptenvalkenswaard.nl/melden)');
check('name and job title in separate elements get a space, avatar gone',
	md('<ul><li><span aria-hidden="true">ES</span><span><strong>Ed Sprokkel</strong><span>Voorzitter</span></span></li></ul>'),
	'- **Ed Sprokkel** Voorzitter');
check('text glued to an element stays glued',
	md('<p>Een <strong>vet</strong>woord</p>'),
	'Een **vet**woord');
check('markdown characters escaped',
	md('<p>Prijs *korting* en 1_2</p>'),
	'Prijs \*korting\* en 1\_2');
check('JSON-LD inside main is no text',
	md('<script type="application/ld+json">{"@type":"BreadcrumbList"}</script><p>Inhoud</p>'),
	'Inhoud');
check('nested list',
	md('<ul><li>een</li><li>twee<ul><li>genest</li></ul></li></ul><ol><li>eerst</li><li>dan</li></ol>'),
	"- een\n- twee\n    - genest\n\n1. eerst\n2. dan");

finish('ConversionCases');
