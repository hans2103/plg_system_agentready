<?php

/**
 * @package     Agent Ready
 * @subpackage  plg_system_agentready
 *
 * @copyright   (C) 2026 Hans Kuijpers <https://hkweb.nl>
 * @license     GNU General Public License version 2 or later; see LICENSE.txt
 */

declare(strict_types=1);

namespace HKweb\Plugin\System\AgentReady\Http;

// phpcs:disable PSR1.Files.SideEffects
\defined('_JEXEC') or die;
// phpcs:enable PSR1.Files.SideEffects

/**
 * Builds and merges Link header values (RFC 8288).
 *
 * @since  26.45.0
 */
final class LinkHeader
{
	/**
	 * One link value: <uri>; rel="…"; type="…".
	 *
	 * @param   string  $uri   Absolute URI
	 * @param   string  $rel   Relation type
	 * @param   string  $type  Media type ('' = none)
	 *
	 * @return  string
	 *
	 * @since   26.45.0
	 */
	public static function link(string $uri, string $rel, string $type = ''): string
	{
		$uri = str_replace(['<', '>', ' '], ['%3C', '%3E', '%20'], $uri);

		return '<' . $uri . '>; rel="' . $rel . '"' . ($type === '' ? '' : '; type="' . $type . '"');
	}

	/**
	 * The combined Link header: the existing values first, then each new link whose URI and rel
	 * are not there yet.
	 *
	 * @param   list<string>  $existing  Current Link header values (each may hold several links)
	 * @param   list<string>  $links     New link values from link()
	 *
	 * @return  string
	 *
	 * @since   26.45.0
	 */
	public static function merge(array $existing, array $links): string
	{
		$values = [];
		$seen   = [];

		foreach ([...$existing, ...$links] as $header) {
			foreach (self::split($header) as $value) {
				$key = self::key($value);

				if (!isset($seen[$key])) {
					$seen[$key] = true;
					$values[]   = $value;
				}
			}
		}

		return implode(', ', $values);
	}

	/**
	 * Splits a header value on the commas between links (not those inside <…> or quotes).
	 *
	 * @param   string  $header  A Link header value
	 *
	 * @return  list<string>
	 *
	 * @since   26.45.0
	 */
	private static function split(string $header): array
	{
		$parts   = [];
		$current = '';
		$inUri   = false;
		$inQuote = false;

		foreach (str_split($header) as $char) {
			if ($char === '"' && !$inUri) {
				$inQuote = !$inQuote;
			} elseif ($char === '<' && !$inQuote) {
				$inUri = true;
			} elseif ($char === '>' && !$inQuote) {
				$inUri = false;
			} elseif ($char === ',' && !$inUri && !$inQuote) {
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
	 * Identity of a link for de-duplication: its URI and its rel, case-insensitive.
	 *
	 * @param   string  $value  One link value
	 *
	 * @return  string
	 *
	 * @since   26.45.0
	 */
	private static function key(string $value): string
	{
		preg_match('/<([^>]*)>/', $value, $uri);
		preg_match('/;\s*rel\s*=\s*"?([^";]+)"?/i', $value, $rel);

		return strtolower(trim($uri[1] ?? $value) . ' ' . trim($rel[1] ?? ''));
	}
}
