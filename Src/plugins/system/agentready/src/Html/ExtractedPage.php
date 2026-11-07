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
 * What PageExtractor takes from an HTML page: metadata, the cleaned main content and JSON-LD.
 *
 * @since  26.45.0
 */
final readonly class ExtractedPage
{
	/**
	 * @param   array<string, string>  $meta         title, description and image; only keys with a value
	 * @param   string                 $contentHtml  Inner HTML of the main content, cleaned
	 * @param   list<string>           $jsonLd       Trimmed contents of each application/ld+json script
	 *
	 * @since   26.45.0
	 */
	public function __construct(
		public array $meta,
		public string $contentHtml,
		public array $jsonLd,
	) {
	}
}
