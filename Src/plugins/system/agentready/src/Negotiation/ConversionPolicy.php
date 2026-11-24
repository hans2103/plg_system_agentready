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
 * The settings that keep a page out of the Markdown version: logged-in users and noindex pages.
 * The same answer decides the conversion and the Markdown alternate in the Link header, so the
 * header never promises a version the site does not deliver.
 *
 * @since  26.48.0
 */
final class ConversionPolicy
{
	/**
	 * Whether the page may be served as Markdown.
	 *
	 * @param   boolean       $skipLoggedIn  The "not for logged-in users" setting
	 * @param   boolean       $guest         Whether the visitor is a guest
	 * @param   boolean       $skipNoindex   The "not for noindex pages" setting
	 * @param   string        $robotsMeta    The robots meta tag of the page
	 * @param   list<string>  $xRobotsTag    The X-Robots-Tag header values
	 *
	 * @return  boolean
	 *
	 * @since   26.48.0
	 */
	public static function allows(bool $skipLoggedIn, bool $guest, bool $skipNoindex, string $robotsMeta, array $xRobotsTag): bool
	{
		if ($skipLoggedIn && !$guest) {
			return false;
		}

		return !$skipNoindex || !self::isNoindex(implode(',', [$robotsMeta, ...$xRobotsTag]));
	}

	/**
	 * Whether a robots value (meta tag or X-Robots-Tag) contains noindex or none.
	 *
	 * @param   string  $robots  The robots value
	 *
	 * @return  boolean
	 *
	 * @since   26.48.0
	 */
	public static function isNoindex(string $robots): bool
	{
		return preg_match('/\b(noindex|none)\b/i', $robots) === 1;
	}
}
