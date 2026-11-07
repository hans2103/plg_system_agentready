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
 *   without the elements matching the remove selectors and without comments, tidied for a
 *   clean conversion (see tidy()), with relative href/src made absolute against the page URL
 *   (or a <base href>).
 *
 * @since  __DEPLOY_VERSION__
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
	 * @since   __DEPLOY_VERSION__
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
	 * @since   __DEPLOY_VERSION__
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
	 * @since   __DEPLOY_VERSION__
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
	 * Removes comments and the elements matching the remove selectors from the content.
	 *
	 * @param   DOMXPath    $xpath      The document
	 * @param   DOMElement  $content    The main content element
	 * @param   string      $selectors  Comma-separated selectors
	 *
	 * @return  void
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function removeNodes(DOMXPath $xpath, DOMElement $content, string $selectors): void
	{
		$remove   = [];
		$comments = $xpath->query('.//comment()', $content);

		foreach ($comments === false ? [] : $comments as $node) {
			$remove[] = $node;
		}

		foreach (Selector::toXPaths($selectors) as $path) {
			// The selector paths are absolute (//...); relative to the content they become .//...
			$nodes = $xpath->query('.' . $path, $content);

			foreach ($nodes === false ? [] : $nodes as $node) {
				$remove[] = $node;
			}
		}

		foreach ($remove as $node) {
			if ($node->parentNode instanceof DOMNode) {
				$node->parentNode->removeChild($node);
			}
		}
	}

	/**
	 * Block-level elements: a link around one of these is a clickable card.
	 *
	 * @since  __DEPLOY_VERSION__
	 */
	private const BLOCK_ELEMENTS = ['address', 'article', 'aside', 'blockquote', 'dd', 'div', 'dl', 'dt', 'figcaption', 'figure', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hr', 'li', 'ol', 'p', 'pre', 'section', 'table', 'ul'];

	/**
	 * Fixes the HTML patterns that convert to broken or glued-together Markdown:
	 *
	 * - a decorative image (alt="") is removed;
	 * - a link to a fragment (#…) or javascript: keeps only its text;
	 * - a link around blocks (a clickable card) becomes a link around its text, the blocks' texts
	 *   separated by a space;
	 * - two sibling elements with nothing between them (name and job title that CSS shows on two
	 *   lines) get a space between them.
	 *
	 * @param   DOMXPath    $xpath    The document
	 * @param   DOMElement  $content  The main content element
	 *
	 * @return  void
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function tidy(DOMXPath $xpath, DOMElement $content): void
	{
		$doc = $content->ownerDocument;

		foreach (self::nodes($xpath, ".//img[@alt and normalize-space(@alt)='']", $content) as $image) {
			$image->parentNode?->removeChild($image);
		}

		foreach (self::nodes($xpath, './/a[@href]', $content) as $link) {
			$href = strtolower(trim($link->getAttribute('href')));

			if ($href !== '' && ($href[0] === '#' || str_starts_with($href, 'javascript:'))) {
				while ($link->firstChild !== null) {
					$link->parentNode?->insertBefore($link->firstChild, $link);
				}

				$link->parentNode?->removeChild($link);
			}
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

		foreach (self::nodes($xpath, './/*[following-sibling::node()[1][self::*]]', $content) as $element) {
			$element->parentNode?->insertBefore($doc->createTextNode(' '), $element->nextSibling);
		}
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
	 * @since   __DEPLOY_VERSION__
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
	 * @since   __DEPLOY_VERSION__
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
	 * @since   __DEPLOY_VERSION__
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
