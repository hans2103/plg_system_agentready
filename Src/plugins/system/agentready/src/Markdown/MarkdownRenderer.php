<?php

/**
 * @package     Agent Ready
 * @subpackage  plg_system_agentready
 *
 * @copyright   (C) 2026 Hans Kuijpers <https://hkweb.nl>
 * @license     GNU General Public License version 2 or later; see LICENSE.txt
 */

declare(strict_types=1);

namespace HKweb\Plugin\System\AgentReady\Markdown;

// phpcs:disable PSR1.Files.SideEffects
\defined('_JEXEC') or die;
// phpcs:enable PSR1.Files.SideEffects

use HKweb\Plugin\System\AgentReady\Html\ExtractedPage;
use League\HTMLToMarkdown\Converter\TableConverter;
use League\HTMLToMarkdown\HtmlConverter;

/**
 * Builds the Markdown document in the layout of Cloudflare's Markdown for Agents: optional YAML
 * frontmatter, the converted body, and the JSON-LD in one fenced json block at the end.
 *
 * @since  __DEPLOY_VERSION__
 */
final class MarkdownRenderer
{
	/**
	 * The Markdown document, or '' when the content converts to nothing.
	 *
	 * @param   ExtractedPage  $page         The extracted page
	 * @param   boolean        $frontmatter  Whether to prepend the YAML frontmatter
	 * @param   boolean        $jsonLd       Whether to append the JSON-LD block
	 *
	 * @return  string
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	public static function render(ExtractedPage $page, bool $frontmatter = true, bool $jsonLd = true): string
	{
		$body = $page->contentHtml === '' ? '' : self::tidy(self::converter()->convert($page->contentHtml));

		if ($body === '') {
			return '';
		}

		$parts = [];

		if ($frontmatter && $page->meta !== []) {
			$lines = ['---'];

			foreach (['title', 'description', 'image'] as $key) {
				if (isset($page->meta[$key])) {
					// A JSON string is a valid YAML double-quoted scalar.
					$lines[] = $key . ': ' . json_encode($page->meta[$key], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
				}
			}

			$lines[] = '---';
			$parts[] = implode("\n", $lines);
		}

		$parts[] = $body;

		if ($jsonLd && $page->jsonLd !== []) {
			$parts[] = "```json\n" . implode("\n", $page->jsonLd) . "\n```";
		}

		return implode("\n\n", $parts) . "\n";
	}

	/**
	 * Cleans the converter output outside fenced code blocks: whitespace-only lines become empty,
	 * stray indentation of one to three spaces, extra spaces after a heading's # and trailing spaces go (two trailing spaces after
	 * text stay: that is a hard line break), runs of blank lines become one, and HTML entities
	 * become their characters (except &lt; and &gt;, which keep text from turning into HTML).
	 *
	 * @param   string  $markdown  The converter output
	 *
	 * @return  string
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	public static function tidy(string $markdown): string
	{
		$lines   = explode("\n", str_replace(["\r\n", "\r"], "\n", $markdown));
		$inFence = false;

		foreach ($lines as $i => $line) {
			if (preg_match('/^\s{0,3}(```|~~~)/', $line) === 1) {
				$inFence   = !$inFence;
				$lines[$i] = ltrim($line, ' ');
				continue;
			}

			if ($inFence) {
				continue;
			}

			if (trim($line) === '') {
				$lines[$i] = '';
				continue;
			}

			$line = preg_replace('/^ {1,3}(?=\S)/', '', $line) ?? $line;
			$line = preg_replace('/^(#{1,6})\s{2,}/', '$1 ', $line) ?? $line;
			$line = preg_match('/\S  $/', $line) === 1 ? $line : rtrim($line);

			$lines[$i] = preg_replace_callback(
				'/&(?!lt;|gt;)(#\d+|#x[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]+);/',
				static fn (array $m): string => html_entity_decode($m[0], ENT_QUOTES | ENT_HTML5, 'UTF-8'),
				$line
			) ?? $line;
		}

		return trim(preg_replace("/\n{3,}/", "\n\n", implode("\n", $lines)) ?? '');
	}

	/**
	 * Estimated token count for the x-markdown-tokens header: about four characters per token.
	 *
	 * @param   string  $markdown  The Markdown document
	 *
	 * @return  integer
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	public static function estimateTokens(string $markdown): int
	{
		return (int) ceil(mb_strlen($markdown, 'UTF-8') / 4);
	}

	/**
	 * The configured converter.
	 *
	 * @return  HtmlConverter
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private static function converter(): HtmlConverter
	{
		$converter = new HtmlConverter([
			'header_style'            => 'atx',
			'strip_tags'              => true,
			'remove_nodes'            => 'script style noscript template',
			'strip_placeholder_links' => true,
			'hard_break'              => false,
			'list_item_style'         => '-',
			'suppress_errors'         => true,
		]);
		$converter->getEnvironment()->addConverter(new TableConverter());

		return $converter;
	}
}
