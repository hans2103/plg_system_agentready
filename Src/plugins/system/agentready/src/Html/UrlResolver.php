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
 * Resolves a reference against an absolute base URL (RFC 3986, section 5.2).
 *
 * @since  __DEPLOY_VERSION__
 */
final class UrlResolver
{
	/**
	 * The absolute URL for $reference. Fragment-only references, references with a scheme
	 * (https:, mailto:, tel:, data:) and an empty reference are returned unchanged.
	 *
	 * @param   string  $base       Absolute base URL
	 * @param   string  $reference  The href or src value
	 *
	 * @return  string
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	public static function resolve(string $base, string $reference): string
	{
		if ($reference === '' || $reference[0] === '#' || preg_match('/^[a-zA-Z][a-zA-Z0-9+.-]*:/', $reference) === 1) {
			return $reference;
		}

		$parts = parse_url($base);

		if ($parts === false || !isset($parts['scheme'], $parts['host'])) {
			return $reference;
		}

		$origin = $parts['scheme'] . '://' . (isset($parts['user']) ? $parts['user'] . (isset($parts['pass']) ? ':' . $parts['pass'] : '') . '@' : '')
			. $parts['host'] . (isset($parts['port']) ? ':' . $parts['port'] : '');

		if (str_starts_with($reference, '//')) {
			return $parts['scheme'] . ':' . $reference;
		}

		$basePath = $parts['path'] ?? '/';

		if ($reference[0] === '?') {
			return $origin . $basePath . $reference;
		}

		[$refPath, $suffix] = self::splitSuffix($reference);

		$path = $refPath[0] === '/'
			? $refPath
			: substr($basePath, 0, (int) strrpos($basePath, '/') + 1) . $refPath;

		return $origin . self::removeDotSegments($path) . $suffix;
	}

	/**
	 * Splits a reference into its path and its ?query#fragment suffix.
	 *
	 * @param   string  $reference  The reference
	 *
	 * @return  array{0: string, 1: string}
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function splitSuffix(string $reference): array
	{
		$cut = strcspn($reference, '?#');

		return [substr($reference, 0, $cut), substr($reference, $cut)];
	}

	/**
	 * Removes . and .. segments from a path.
	 *
	 * @param   string  $path  An absolute path
	 *
	 * @return  string
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function removeDotSegments(string $path): string
	{
		$output = [];
		$segments = explode('/', $path);
		$last = end($segments);

		foreach ($segments as $segment) {
			if ($segment === '.') {
				continue;
			}

			if ($segment === '..') {
				if (\count($output) > 1) {
					array_pop($output);
				}

				continue;
			}

			$output[] = $segment;
		}

		if ($last === '.' || $last === '..') {
			$output[] = '';
		}

		$result = implode('/', $output);

		return $result === '' || $result[0] !== '/' ? '/' . $result : $result;
	}
}
