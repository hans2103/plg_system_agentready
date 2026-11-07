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
 * Response rules for a Markdown answer, as Cloudflare's Markdown for Agents applies them.
 *
 * @since  26.45.0
 */
final class MarkdownHeaders
{
	/**
	 * Headers that describe the HTML representation and are removed from the Markdown answer.
	 *
	 * @var    list<string>
	 * @since  26.45.0
	 */
	public const STRIP = ['ETag', 'Last-Modified', 'Content-Length', 'Content-Encoding', 'Content-Range', 'Transfer-Encoding'];

	/**
	 * Largest HTML body (uncompressed, in bytes) that is converted: 6 MiB, as Cloudflare.
	 *
	 * @var    integer
	 * @since  26.45.0
	 */
	public const MAX_HTML_BYTES = 6291456;

	/**
	 * Whether the HTML body is small enough to convert.
	 *
	 * @param   string  $html  The uncompressed HTML body
	 *
	 * @return  boolean
	 *
	 * @since   26.45.0
	 */
	public static function fits(string $html): bool
	{
		return \strlen($html) <= self::MAX_HTML_BYTES;
	}

	/**
	 * The Content-Signal value to set, or null to leave the header as it is. A value the site
	 * already sends wins; otherwise the setting, when filled in. No default: what agents may do
	 * with the content is the site owner's call.
	 *
	 * @param   list<string>  $existing  The Content-Signal values already on the response
	 * @param   string        $setting   The plugin setting
	 *
	 * @return  string|null
	 *
	 * @since   26.45.0
	 */
	public static function contentSignal(array $existing, string $setting): ?string
	{
		foreach ($existing as $value) {
			if (trim($value) !== '') {
				return null;
			}
		}

		$setting = trim($setting);

		return $setting === '' ? null : $setting;
	}
}
