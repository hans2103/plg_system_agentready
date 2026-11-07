<?php

/**
 * @package     Agent Ready
 * @subpackage  plg_system_agentready
 *
 * @copyright   (C) 2026 Hans Kuijpers <https://hkweb.nl>
 * @license     GNU General Public License version 2 or later; see LICENSE.txt
 */

declare(strict_types=1);

namespace HKweb\Plugin\System\AgentReady\Negotiation;

// phpcs:disable PSR1.Files.SideEffects
\defined('_JEXEC') or die;
// phpcs:enable PSR1.Files.SideEffects

/**
 * Decides from an Accept header whether the client prefers Markdown over HTML.
 *
 * Markdown is chosen only when text/markdown is listed explicitly with q > 0 and a q at least as
 * high as that of HTML (text/html, else text/*, else *\/*). Wildcards never ask for Markdown, so a
 * browser or crawler without text/markdown always gets HTML.
 *
 * @since  26.45.0
 */
final class AcceptHeader
{
	/**
	 * Whether the Accept header asks for Markdown.
	 *
	 * @param   string|null  $accept  The raw Accept header (null or empty = none)
	 *
	 * @return  boolean
	 *
	 * @since   26.45.0
	 */
	public static function prefersMarkdown(?string $accept): bool
	{
		if ($accept === null || trim($accept) === '') {
			return false;
		}

		$ranges = self::parse($accept);

		if (!isset($ranges['text/markdown']) || $ranges['text/markdown'] <= 0.0) {
			return false;
		}

		$html = $ranges['text/html'] ?? $ranges['text/*'] ?? $ranges['*/*'] ?? 0.0;

		return $ranges['text/markdown'] >= $html;
	}

	/**
	 * Parses an Accept header into media range => q. A repeated range keeps its highest q; an
	 * invalid q counts as 0.
	 *
	 * @param   string  $accept  The raw Accept header
	 *
	 * @return  array<string, float>
	 *
	 * @since   26.45.0
	 */
	private static function parse(string $accept): array
	{
		$ranges = [];

		foreach (explode(',', $accept) as $part) {
			$params = explode(';', $part);
			$range  = strtolower(trim((string) array_shift($params)));

			if ($range === '' || !str_contains($range, '/')) {
				continue;
			}

			$q = 1.0;

			foreach ($params as $param) {
				[$key, $value] = array_pad(explode('=', $param, 2), 2, '');

				if (strtolower(trim($key)) === 'q') {
					$value = trim($value);
					$q     = preg_match('/^(0(\.\d{0,3})?|1(\.0{0,3})?)$/', $value) === 1 ? (float) $value : 0.0;
				}
			}

			$ranges[$range] = max($ranges[$range] ?? 0.0, $q);
		}

		return $ranges;
	}
}
