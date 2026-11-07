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
 * Merges a field name into the existing Vary header values without duplicates.
 *
 * @since  26.45.0
 */
final class VaryHeader
{
	/**
	 * The combined Vary value. An existing "*" stays "*" (it already varies on everything).
	 *
	 * @param   list<string>  $existing  The current Vary header values (each may be a list)
	 * @param   string        $add       The field name to add
	 *
	 * @return  string
	 *
	 * @since   26.45.0
	 */
	public static function merge(array $existing, string $add = 'Accept'): string
	{
		$fields = [];

		foreach ($existing as $value) {
			foreach (explode(',', $value) as $field) {
				$field = trim($field);

				if ($field === '*') {
					return '*';
				}

				if ($field !== '' && !\in_array(strtolower($field), array_map('strtolower', $fields), true)) {
					$fields[] = $field;
				}
			}
		}

		if (!\in_array(strtolower($add), array_map('strtolower', $fields), true)) {
			$fields[] = $add;
		}

		return implode(', ', $fields);
	}
}
