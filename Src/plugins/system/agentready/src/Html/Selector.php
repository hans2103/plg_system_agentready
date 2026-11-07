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

/**
 * Translates a small subset of CSS selectors into XPath (Joomla bundles no CSS selector component).
 *
 * Supported: tag, *, #id, .class, [attr], [attr=value] (quoted or bare), compound selectors
 * (div.a#b[x]), the descendant (space) and child (>) combinators, and comma-separated lists.
 * A part with other syntax is skipped, so one typo in a setting does not disable the rest.
 *
 * @since  __DEPLOY_VERSION__
 */
final class Selector
{
	/**
	 * XPath expressions for each valid selector in a comma-separated list, in list order.
	 *
	 * @param   string  $selectorList  For example "main, [role=main], body"
	 *
	 * @return  list<string>
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	public static function toXPaths(string $selectorList): array
	{
		$paths = [];

		foreach (self::splitList($selectorList) as $selector) {
			$path = self::selectorToXPath($selector);

			if ($path !== null) {
				$paths[] = $path;
			}
		}

		return $paths;
	}

	/**
	 * One XPath (union) for the whole list, or null when no part is valid.
	 *
	 * @param   string  $selectorList  Comma-separated selectors
	 *
	 * @return  string|null
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	public static function toXPath(string $selectorList): ?string
	{
		$paths = self::toXPaths($selectorList);

		return $paths === [] ? null : implode(' | ', $paths);
	}

	/**
	 * Splits on commas outside attribute brackets and quotes.
	 *
	 * @param   string  $list  The selector list
	 *
	 * @return  list<string>
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function splitList(string $list): array
	{
		$parts   = [];
		$current = '';
		$quote   = '';
		$depth   = 0;

		foreach (str_split($list) as $char) {
			if ($quote !== '') {
				$quote = $char === $quote ? '' : $quote;
			} elseif ($char === '"' || $char === "'") {
				$quote = $char;
			} elseif ($char === '[') {
				$depth++;
			} elseif ($char === ']') {
				$depth = max(0, $depth - 1);
			} elseif ($char === ',' && $depth === 0) {
				$parts[] = trim($current);
				$current = '';
				continue;
			}

			$current .= $char;
		}

		$parts[] = trim($current);

		return array_values(array_filter($parts, static fn (string $part): bool => $part !== ''));
	}

	/**
	 * Translates one selector (compounds joined by combinators) into an absolute XPath.
	 *
	 * @param   string  $selector  One selector without commas
	 *
	 * @return  string|null  Null when the selector uses unsupported syntax
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function selectorToXPath(string $selector): ?string
	{
		$compound = '(?:[a-zA-Z][a-zA-Z0-9-]*|\*)?(?:#[\w-]+|\.[\w-]+|\[\s*[\w-]+\s*(?:=\s*(?:"[^"]*"|\'[^\']*\'|[\w-]+)\s*)?\])*';

		if (preg_match('/^\s*' . $compound . '(?:\s*>\s*' . $compound . '|\s+' . $compound . ')*\s*$/', $selector) !== 1) {
			return null;
		}

		preg_match_all('/(\s*>\s*|\s+)?(' . $compound . ')/', trim($selector), $matches, PREG_SET_ORDER);

		$xpath = '';

		foreach ($matches as $match) {
			if ($match[2] === '') {
				continue;
			}

			$axis   = $xpath === '' ? '//' : (trim($match[1]) === '>' ? '/' : '//');
			$xpath .= $axis . self::compoundToXPath($match[2]);
		}

		return $xpath === '' ? null : $xpath;
	}

	/**
	 * Translates a compound selector (tag plus #id, .class and [attr] parts) into an XPath step.
	 *
	 * @param   string  $compound  For example div.a#b[role=main]
	 *
	 * @return  string
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function compoundToXPath(string $compound): string
	{
		preg_match('/^([a-zA-Z][a-zA-Z0-9-]*|\*)?/', $compound, $tagMatch);
		$tag        = ($tagMatch[1] ?? '') === '' ? '*' : strtolower($tagMatch[1]);
		$conditions = [];

		preg_match_all('/#([\w-]+)|\.([\w-]+)|\[\s*([\w-]+)\s*(?:=\s*(?:"([^"]*)"|\'([^\']*)\'|([\w-]+))\s*)?\]/', $compound, $parts, PREG_SET_ORDER | PREG_UNMATCHED_AS_NULL);

		foreach ($parts as $part) {
			if ($part[1] !== null) {
				$conditions[] = '@id=' . self::literal($part[1]);
			} elseif ($part[2] !== null) {
				$conditions[] = "contains(concat(' ', normalize-space(@class), ' '), " . self::literal(' ' . $part[2] . ' ') . ')';
			} else {
				$value        = $part[4] ?? $part[5] ?? $part[6];
				$conditions[] = $value === null ? '@' . strtolower($part[3]) : '@' . strtolower($part[3]) . '=' . self::literal($value);
			}
		}

		return $tag . implode('', array_map(static fn (string $condition): string => '[' . $condition . ']', $conditions));
	}

	/**
	 * Quotes a string as an XPath literal.
	 *
	 * @param   string  $value  The raw value
	 *
	 * @return  string
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function literal(string $value): string
	{
		if (!str_contains($value, "'")) {
			return "'" . $value . "'";
		}

		if (!str_contains($value, '"')) {
			return '"' . $value . '"';
		}

		return "concat('" . str_replace("'", "', \"'\", '", $value) . "')";
	}
}
