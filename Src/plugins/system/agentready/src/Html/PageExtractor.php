<?php

/**
 * @package     Agent Ready
 * @subpackage  plg_system_agentready
 *
 * @copyright   (C) 2026 Hans Kuijpers <https://hkweb.nl>
 * @license     GNU General Public License version 2 or later; see LICENSE.txt
 */

declare(strict_types=1);

namespace HKweb\Plugin\System\AgentReady\Html;

// phpcs:disable PSR1.Files.SideEffects
\defined('_JEXEC') or die;
// phpcs:enable PSR1.Files.SideEffects

use DOMDocument;
use DOMElement;
use DOMNode;
use DOMXPath;

/**
 * Takes the parts of an HTML page that the Markdown version needs.
 *
 * - metadata for the frontmatter (title, description, image);
 * - all JSON-LD blocks of the whole document;
 * - the main content: the first element that matches the content selectors (in list order),
 *   without the site header and footer, the elements matching the remove selectors and comments, tidied for a
 *   clean conversion (see tidy()), with relative href/src made absolute against the page URL
 *   (or a <base href>).
 *
 * @since  26.45.0
 */
final class PageExtractor
{
	/**
	 * Extracts the page; null when the HTML cannot be parsed or has no matching content element.
	 *
	 * @param   string  $html              The rendered page
	 * @param   string  $contentSelectors  Comma-separated selectors for the main content
	 * @param   string  $removeSelectors   Comma-separated selectors removed from the content
	 * @param   string  $pageUrl           Absolute URL of the page, for relative links
	 *
	 * @return  ExtractedPage|null
	 *
	 * @since   26.45.0
	 */
	public static function extract(string $html, string $contentSelectors, string $removeSelectors, string $pageUrl): ?ExtractedPage
	{
		if (trim($html) === '') {
			return null;
		}

		$doc      = new DOMDocument();
		$previous = libxml_use_internal_errors(true);
		$loaded   = $doc->loadHTML('<?xml encoding="UTF-8">' . $html, LIBXML_NONET | LIBXML_NOERROR | LIBXML_NOWARNING | LIBXML_COMPACT);
		libxml_clear_errors();
		libxml_use_internal_errors($previous);

		if (!$loaded) {
			return null;
		}

		$xpath  = new DOMXPath($doc);
		$meta   = self::meta($xpath);
		$jsonLd = self::jsonLd($xpath);

		$content = null;

		foreach (Selector::toXPaths($contentSelectors) as $path) {
			$found = $xpath->query($path);

			if ($found !== false && $found->length > 0 && $found->item(0) instanceof DOMElement) {
				$content = $found->item(0);
				break;
			}
		}

		if ($content === null) {
			return null;
		}

		self::removeNodes($xpath, $content, $removeSelectors);
		self::tidy($xpath, $content);
		self::absolutize($xpath, $content, self::baseUrl($xpath, $pageUrl));

		$inner = '';

		foreach ($content->childNodes as $child) {
			$inner .= $doc->saveHTML($child);
		}

		return new ExtractedPage($meta, trim($inner), $jsonLd);
	}

	/**
	 * Title, description and image. The standard meta name wins over Open Graph; the title falls
	 * back to the <title> element.
	 *
	 * @param   DOMXPath  $xpath  The document
	 *
	 * @return  array<string, string>
	 *
	 * @since   26.45.0
	 */
	private static function meta(DOMXPath $xpath): array
	{
		$first = static function (array $queries) use ($xpath): string {
			foreach ($queries as $query) {
				$nodes = $xpath->query($query);

				foreach ($nodes === false ? [] : $nodes as $node) {
					$value = trim(preg_replace('/\s+/u', ' ', $node->nodeValue ?? '') ?? '');

					if ($value !== '') {
						return $value;
					}
				}
			}

			return '';
		};

		$meta = [
			'title'       => $first(["//meta[@name='title']/@content", "//meta[@property='og:title']/@content", '//title']),
			'description' => $first(["//meta[@name='description']/@content", "//meta[@property='og:description']/@content"]),
			'image'       => $first(["//meta[@property='og:image']/@content"]),
		];

		return array_filter($meta, static fn (string $value): bool => $value !== '');
	}

	/**
	 * The trimmed contents of every application/ld+json script in the document.
	 *
	 * @param   DOMXPath  $xpath  The document
	 *
	 * @return  list<string>
	 *
	 * @since   26.45.0
	 */
	private static function jsonLd(DOMXPath $xpath): array
	{
		$blocks = [];
		$nodes  = $xpath->query("//script[translate(normalize-space(@type), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')='application/ld+json']");

		foreach ($nodes === false ? [] : $nodes as $node) {
			$json = trim($node->textContent);

			if ($json !== '') {
				$blocks[] = $json;
			}
		}

		return $blocks;
	}

	/**
	 * The site header and footer, as the HTML spec defines the banner and contentinfo landmarks:
	 * a header or footer that is not inside article, aside, main, nav or section, and any element
	 * with role banner or contentinfo. A header inside an article (its title) is not one.
	 *
	 * @var    string
	 * @since  26.45.0
	 */
	private const SITE_LANDMARKS = './/*[(self::header or self::footer)'
		. ' and not(ancestor::article or ancestor::aside or ancestor::main or ancestor::nav or ancestor::section)]'
		. " | .//*[@role='banner' or @role='contentinfo']";

	/**
	 * Removes comments, the site header and footer (SITE_LANDMARKS) and the elements matching the
	 * remove selectors from the content.
	 *
	 * @param   DOMXPath    $xpath      The document
	 * @param   DOMElement  $content    The main content element
	 * @param   string      $selectors  Comma-separated selectors
	 *
	 * @return  void
	 *
	 * @since   26.45.0
	 */
	private static function removeNodes(DOMXPath $xpath, DOMElement $content, string $selectors): void
	{
		$remove = [];

		foreach (['.//comment()', self::SITE_LANDMARKS] as $query) {
			$nodes = $xpath->query($query, $content);

			foreach ($nodes === false ? [] : $nodes as $node) {
				$remove[] = $node;
			}
		}

		foreach (Selector::toXPaths($selectors) as $path) {
			// The selector paths are absolute (//...); relative to the content they become .//...
			$nodes = $xpath->query('.' . $path, $content);

			foreach ($nodes === false ? [] : $nodes as $node) {
				$remove[] = $node;
			}
		}

		$remove = array_merge($remove, self::orphanedLabels($xpath, $content, $remove));

		foreach ($remove as $node) {
			if ($node->parentNode instanceof DOMNode) {
				$node->parentNode->removeChild($node);
			}
		}
	}

	/**
	 * The labels whose form control is being removed: the element their for attribute names, or
	 * the control they wrap. Without the control the label ("Quantity") is stray UI text.
	 *
	 * @param   DOMXPath       $xpath    The document
	 * @param   DOMElement     $content  The main content element
	 * @param   list<DOMNode>  $remove   The nodes being removed
	 *
	 * @return  list<DOMNode>
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function orphanedLabels(DOMXPath $xpath, DOMElement $content, array $remove): array
	{
		$removed = static function (DOMNode $node) use ($remove, $content): bool {
			for ($current = $node; $current !== null && $current !== $content; $current = $current->parentNode) {
				if (in_array($current, $remove, true)) {
					return true;
				}
			}

			return false;
		};

		$labels = [];

		foreach (self::nodes($xpath, './/label', $content) as $label) {
			if (!$label instanceof DOMElement || $removed($label)) {
				continue;
			}

			$for      = trim($label->getAttribute('for'));
			$controls = $for !== ''
				? self::nodes($xpath, '//*[@id=' . self::xpathLiteral($for) . ']', $label)
				: self::nodes($xpath, './/input | .//select | .//textarea | .//button | .//meter | .//output | .//progress', $label);

			if ($controls !== [] && $removed($controls[0])) {
				$labels[] = $label;
			}
		}

		return $labels;
	}

	/**
	 * A string as an XPath literal, also when it contains quotes.
	 *
	 * @param   string  $value  The string
	 *
	 * @return  string
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function xpathLiteral(string $value): string
	{
		if (!str_contains($value, "'")) {
			return "'" . $value . "'";
		}

		if (!str_contains($value, '"')) {
			return '"' . $value . '"';
		}

		return "concat('" . str_replace("'", "', \"'\", '", $value) . "')";
	}

	/**
	 * Block-level elements: a link around one of these is a clickable card.
	 *
	 * @since  26.45.0
	 */
	private const BLOCK_ELEMENTS = ['address', 'article', 'aside', 'blockquote', 'dd', 'div', 'dl', 'dt', 'figcaption', 'figure', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hr', 'li', 'ol', 'p', 'pre', 'section', 'table', 'ul'];

	/**
	 * Fixes the HTML patterns that convert to broken or glued-together Markdown:
	 *
	 * - a decorative image (alt="") is removed;
	 * - a skip link (see isSkipLink()) is removed;
	 * - a link to a fragment (#…) or javascript: keeps only its text;
	 * - a link with no text and no image left (an icon) gets its aria-label or title as text, or
	 *   is removed when it has neither; list items left empty go, and lists left without items;
	 * - a link around blocks (a clickable card) becomes a link around its text, the blocks' texts
	 *   separated by a space;
	 * - whitespace at the start and end of a link's text moves outside the link;
	 * - two sibling elements with nothing between them (name and job title that CSS shows on two
	 *   lines) get a space between them, unless one of them already has one at that side.
	 *
	 * @param   DOMXPath    $xpath    The document
	 * @param   DOMElement  $content  The main content element
	 *
	 * @return  void
	 *
	 * @since   26.45.0
	 */
	private static function tidy(DOMXPath $xpath, DOMElement $content): void
	{
		$doc = $content->ownerDocument;

		foreach (self::nodes($xpath, ".//img[@alt and normalize-space(@alt)='']", $content) as $image) {
			$image->parentNode?->removeChild($image);
		}

		foreach (self::nodes($xpath, './/a[@href]', $content) as $link) {
			$href = strtolower(trim($link->getAttribute('href')));

			if (!$link instanceof DOMElement) {
				continue;
			}

			if (strlen($href) > 1 && $href[0] === '#' && self::isSkipLink($link)) {
				$link->parentNode?->removeChild($link);
				continue;
			}

			if ($href !== '' && ($href[0] === '#' || str_starts_with($href, 'javascript:'))) {
				while ($link->firstChild !== null) {
					$link->parentNode?->insertBefore($link->firstChild, $link);
				}

				$link->parentNode?->removeChild($link);
			}
		}

		// A link with no text and no image left (an icon, or a decorative image removed above):
		// its accessible name (aria-label, else title) becomes the text; without one it goes.
		foreach (self::nodes($xpath, './/a[@href][not(normalize-space(.))][not(.//img)]', $content) as $link) {
			if (!$link instanceof DOMElement) {
				continue;
			}

			$name = '';

			foreach (['aria-label', 'title'] as $attribute) {
				$name = trim(preg_replace('/\s+/u', ' ', $link->getAttribute($attribute)) ?? '');

				if ($name !== '') {
					break;
				}
			}

			if ($name === '') {
				$link->parentNode?->removeChild($link);
				continue;
			}

			while ($link->firstChild !== null) {
				$link->removeChild($link->firstChild);
			}

			$link->appendChild($doc->createTextNode($name));

			if ($attribute === 'title') {
				// Else the converter repeats it as the link title: [Name](url "Name").
				$link->removeAttribute('title');
			}
		}

		// List items left empty (their only content removed) would become bare bullets; a list
		// without items goes too.
		foreach (self::nodes($xpath, './/li[not(normalize-space(.))][not(.//img)]', $content) as $item) {
			$item->parentNode?->removeChild($item);
		}

		foreach (self::nodes($xpath, './/ul[not(li)] | .//ol[not(li)]', $content) as $list) {
			$list->parentNode?->removeChild($list);
		}

		$blocks = implode(' or ', array_map(static fn (string $tag): string => 'self::' . $tag, self::BLOCK_ELEMENTS));

		foreach (self::nodes($xpath, './/a[@href][.//*[' . $blocks . ']]', $content) as $card) {
			$texts = [];

			foreach (self::nodes($xpath, './/text()', $card) as $text) {
				$texts[] = $text->nodeValue;
			}

			$label = trim(preg_replace('/\s+/u', ' ', implode(' ', $texts)) ?? '');

			while ($card->firstChild !== null) {
				$card->removeChild($card->firstChild);
			}

			$card->appendChild($doc->createTextNode($label));
		}

		foreach (self::nodes($xpath, './/a[@href]', $content) as $link) {
			self::trimLinkText($xpath, $link);
		}

		foreach (self::nodes($xpath, './/*[following-sibling::node()[1][self::*]]', $content) as $element) {
			$next = $element->nextSibling;

			if (preg_match('/\s$/u', $element->textContent) === 1 || preg_match('/^\s/u', (string) $next?->textContent) === 1) {
				continue;
			}

			$element->parentNode?->insertBefore($doc->createTextNode(' '), $next);
		}
	}

	/**
	 * Moves the whitespace at the start and end of a link's text outside the link, so the text
	 * converts to [text](url) instead of [ text ](url) and stays apart from the words around it.
	 *
	 * @param   DOMXPath  $xpath  The document
	 * @param   DOMNode   $link   A link
	 *
	 * @return  void
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function trimLinkText(DOMXPath $xpath, DOMNode $link): void
	{
		$texts = self::nodes($xpath, './/text()', $link);

		foreach (['before' => $texts, 'after' => array_reverse($texts)] as $side => $ordered) {
			$trimmed = false;

			foreach ($ordered as $text) {
				$value = (string) $text->nodeValue;
				$kept  = $side === 'before' ? (preg_replace('/^\s+/u', '', $value) ?? $value) : (preg_replace('/\s+$/u', '', $value) ?? $value);

				if ($kept !== $value) {
					$text->nodeValue = $kept;
					$trimmed         = true;
				}

				if ($kept !== '') {
					break;
				}
			}

			if ($trimmed && $link->parentNode !== null && $link->ownerDocument !== null) {
				$link->parentNode->insertBefore($link->ownerDocument->createTextNode(' '), $side === 'before' ? $link : $link->nextSibling);
			}
		}
	}

	/**
	 * Whether an in-page link is a skip link ("Skip carousel", "Skip to content"): a keyboard
	 * shortcut past a part of the page, hidden until it gets focus. Recognised by its class: a
	 * token sr-only, visually-hidden, screen-reader-text, or skip (also as part, like skip-link).
	 *
	 * @param   DOMElement  $link  A link to a fragment
	 *
	 * @return  boolean
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function isSkipLink(DOMElement $link): bool
	{
		foreach (preg_split('/\s+/', strtolower($link->getAttribute('class')), -1, PREG_SPLIT_NO_EMPTY) ?: [] as $token) {
			if (in_array($token, ['sr-only', 'visually-hidden', 'screen-reader-text'], true)
				|| preg_match('/(^|-)skip(-|$)/', $token) === 1
			) {
				return true;
			}
		}

		return false;
	}

	/**
	 * The nodes an XPath query finds, as an array (safe to change the tree while looping).
	 *
	 * @param   DOMXPath  $xpath    The document
	 * @param   string    $query    A relative XPath query
	 * @param   DOMNode   $context  The context node
	 *
	 * @return  list<DOMNode>
	 *
	 * @since   26.45.0
	 */
	private static function nodes(DOMXPath $xpath, string $query, DOMNode $context): array
	{
		$found = $xpath->query($query, $context);

		return $found === false ? [] : iterator_to_array($found, false);
	}

	/**
	 * The URL relative links resolve against: a <base href> (itself resolved), else the page URL.
	 *
	 * @param   DOMXPath  $xpath    The document
	 * @param   string    $pageUrl  The page URL
	 *
	 * @return  string
	 *
	 * @since   26.45.0
	 */
	private static function baseUrl(DOMXPath $xpath, string $pageUrl): string
	{
		$base = $xpath->query('//base[@href]/@href');

		if ($base !== false && $base->length > 0 && trim((string) $base->item(0)?->nodeValue) !== '') {
			return UrlResolver::resolve($pageUrl, trim((string) $base->item(0)?->nodeValue));
		}

		return $pageUrl;
	}

	/**
	 * Makes href and src attributes in the content absolute.
	 *
	 * @param   DOMXPath    $xpath    The document
	 * @param   DOMElement  $content  The main content element
	 * @param   string      $baseUrl  The base URL
	 *
	 * @return  void
	 *
	 * @since   26.45.0
	 */
	private static function absolutize(DOMXPath $xpath, DOMElement $content, string $baseUrl): void
	{
		if ($baseUrl === '') {
			return;
		}

		$nodes = $xpath->query('.//*[@href or @src]', $content);

		foreach ($nodes === false ? [] : $nodes as $node) {
			if (!$node instanceof DOMElement) {
				continue;
			}

			foreach (['href', 'src'] as $attribute) {
				if ($node->hasAttribute($attribute)) {
					$node->setAttribute($attribute, UrlResolver::resolve($baseUrl, trim($node->getAttribute($attribute))));
				}
			}
		}
	}
}
