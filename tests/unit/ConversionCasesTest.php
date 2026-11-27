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

check('indented price is no code block',
	md("<div class=\"price-box\"><span class=\"price\">\n                     € 7,49\n                </span></div><p>Op voorraad</p>"),
	"€ 7,49\n\nOp voorraad");
check('icon-only links dropped',
	md('<p>Deel <a href="https://example.org/share"><svg><path d="M0"/></svg></a><a href="/wishlist"> </a><a href="/compare"><span aria-hidden="true">+</span></a><a href="/zoom"><img src="/images/zoom.svg" alt=""></a> hier</p>'),
	'Deel hier');
check('image link with aria-label or title gets that as text',
	md('<ul><li><a href="/merk/a" aria-label="Merk A"><img src="/images/a.webp" alt=""></a></li><li><a href="/merk/b" title="Merk B"><svg></svg></a></li></ul>'),
	"- [Merk A](" . BASE . "merk/a)\n- [Merk B](" . BASE . "merk/b)");
check('empty list items and lists dropped',
	md('<p>Voor</p><ul><li><a href="/x"><img src="/images/x.webp" alt=""></a></li><li>Blijft</li><li> </li></ul><ul><li><a href="/y"></a></li><li><button>Meer</button></li></ul><p>Na</p>'),
	"Voor\n\n- Blijft\n\nNa");
check('spaces inside link text move outside',
	md('<p>Zie<a href="/waarborg"> Veilig melden </a>en <a href="/reviews"><span> 4,8 </span><span>Google</span> </a>nu</p>'),
	'Zie [Veilig melden](' . BASE . 'waarborg) en [4,8 Google](' . BASE . 'reviews) nu');
check('link around an image with alt kept',
	md('<p><a href="/foto.html"><img src="/images/a.jpg" alt="Drempel"></a></p>'),
	'[![Drempel](' . BASE . 'images/a.jpg)](' . BASE . 'foto.html)');
check('skip links removed',
	md('<a href="#slider-end" class="sr-only focus:not-sr-only">Carrousel overslaan</a><a class="skip-link" href="#main">Naar de inhoud</a><p>Inhoud</p><span id="slider-end"></span>'),
	'Inhoud');
check('label of a removed control removed',
	md('<p>Naam</p><label for="q">Zoeken</label><input id="q" name="q"><label><input type="checkbox" name="news"> Nieuwsbrief</label><label for="elsewhere">Blijft</label><p>Einde</p>'),
	"Naam\n\nBlijft\n\nEinde");

finish('ConversionCases');
