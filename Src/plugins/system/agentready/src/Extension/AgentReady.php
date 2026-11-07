<?php

/**
 * @package     Agent Ready
 * @subpackage  plg_system_agentready
 *
 * @copyright   (C) 2026 Hans Kuijpers <https://hkweb.nl>
 * @license     GNU General Public License version 2 or later; see LICENSE.txt
 */

declare(strict_types=1);

namespace HKweb\Plugin\System\AgentReady\Extension;

// phpcs:disable PSR1.Files.SideEffects
\defined('_JEXEC') or die;
// phpcs:enable PSR1.Files.SideEffects

use HKweb\Plugin\System\AgentReady\Html\PageExtractor;
use HKweb\Plugin\System\AgentReady\Http\LinkHeader;
use HKweb\Plugin\System\AgentReady\Http\MarkdownHeaders;
use HKweb\Plugin\System\AgentReady\Http\VaryHeader;
use HKweb\Plugin\System\AgentReady\Markdown\MarkdownRenderer;
use HKweb\Plugin\System\AgentReady\Negotiation\AcceptHeader;
use Joomla\CMS\Application\CMSApplication;
use Joomla\CMS\Document\HtmlDocument;
use Joomla\CMS\Event\Application\AfterRenderEvent;
use Joomla\CMS\Event\Application\AfterRouteEvent;
use Joomla\CMS\Event\Application\BeforeCompileHeadEvent;
use Joomla\CMS\Event\PageCache\GetKeyEvent;
use Joomla\CMS\Log\Log;
use Joomla\CMS\Plugin\CMSPlugin;
use Joomla\CMS\Uri\Uri;
use Joomla\Event\Priority;
use Joomla\Event\SubscriberInterface;

/**
 * Agent Ready: makes a Joomla site readable for AI agents.
 *
 * - Markdown for Agents: a request with Accept: text/markdown gets a Markdown version of the page
 *   (layout as Cloudflare's Markdown for Agents), HTML stays the default.
 * - Link headers (RFC 8288) on HTML pages to llms.txt, the agent skills index, the sitemap and the
 *   Markdown version of the page, so agents can discover them.
 * - The ARD manifest (.well-known/ai-catalog.json) as Link header and as <link rel="ai-catalog"> in
 *   the HTML head.
 *
 * @since  __DEPLOY_VERSION__
 */
final class AgentReady extends CMSPlugin implements SubscriberInterface
{
	/**
	 * Default selectors for the main content, in order of preference.
	 *
	 * @since  __DEPLOY_VERSION__
	 */
	public const DEFAULT_CONTENT_SELECTOR = 'main, [role=main], article, body';

	/**
	 * Default selectors removed from the main content.
	 *
	 * @since  __DEPLOY_VERSION__
	 */
	public const DEFAULT_REMOVE_SELECTORS = 'script, style, noscript, template, svg, canvas, iframe, object, embed, form, button, input, select, textarea, nav, dialog, [hidden], [aria-hidden=true]';

	/**
	 * Page cache key part of the Markdown variant.
	 *
	 * @since  __DEPLOY_VERSION__
	 */
	public const CACHE_KEY = 'agentready:markdown';

	/**
	 * The Agentic Resource Discovery manifest, relative to the site root.
	 *
	 * @since  __DEPLOY_VERSION__
	 */
	public const AI_CATALOG = '.well-known/ai-catalog.json';

	/**
	 * Returns the events this plugin listens to. onAfterRoute runs before plg_system_cache serves
	 * a cached page; onAfterRender runs last, after every plugin that still changes the body.
	 *
	 * @return  array<string, mixed>
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	public static function getSubscribedEvents(): array
	{
		return [
			'onAfterRoute'        => ['onAfterRoute', Priority::HIGH],
			'onAfterRender'       => ['onAfterRender', Priority::MIN],
			'onPageCacheGetKey'   => 'onPageCacheGetKey',
			'onBeforeCompileHead' => 'onBeforeCompileHead',
		];
	}

	/**
	 * Switches off Joomla's own gzip for front-end HTML pages while this plugin sends Vary: Accept.
	 *
	 * Joomla's compress() adds "Vary: Accept-Encoding" as a second value, and sendHeaders() sends
	 * every value with header(…, replace: true), so only that last value would reach the client,
	 * also for a page plg_system_cache serves from its cache in onAfterRoute. The web server or CDN
	 * compresses instead (plg_system_cache switches gzip off the same way before storing a page).
	 *
	 * @param   AfterRouteEvent  $event  The event
	 *
	 * @return  void
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	public function onAfterRoute(AfterRouteEvent $event): void
	{
		$app = $this->getApplication();

		if (!$app instanceof CMSApplication || !$app->isClient('site') || !$app->get('gzip') || !$this->markdownEnabled()) {
			return;
		}

		if (!\in_array($app->getInput()->getCmd('format', 'html'), ['', 'html'], true)) {
			return;
		}

		if ((int) $this->params->get('vary_html', 1) === 1 || AcceptHeader::prefersMarkdown($this->acceptHeader($app))) {
			$app->set('gzip', false);
		}
	}

	/**
	 * Puts <link rel="ai-catalog"> in the HTML head, the way the ARD discovery reads the manifest
	 * from a page (the Link header alone is not enough for it).
	 *
	 * @param   BeforeCompileHeadEvent  $event  The event
	 *
	 * @return  void
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	public function onBeforeCompileHead(BeforeCompileHeadEvent $event): void
	{
		$app = $this->getApplication();

		if (!$app instanceof CMSApplication || !$app->isClient('site') || !$this->aiCatalogEnabled()) {
			return;
		}

		$document = $app->getDocument();

		if ($document instanceof HtmlDocument) {
			$document->addHeadLink(Uri::root(true) . '/' . self::AI_CATALOG, 'ai-catalog', 'rel', ['type' => 'application/json']);
		}
	}

	/**
	 * Gives the Markdown variant its own page cache entry; the HTML key stays as it was.
	 *
	 * @param   GetKeyEvent  $event  The event
	 *
	 * @return  void
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	public function onPageCacheGetKey(GetKeyEvent $event): void
	{
		$app = $this->getApplication();

		if ($app instanceof CMSApplication && $app->isClient('site') && $this->markdownEnabled() && AcceptHeader::prefersMarkdown($this->acceptHeader($app))) {
			$event->addResult(self::CACHE_KEY);
		}
	}

	/**
	 * Replaces the rendered HTML with Markdown when the client asks for it. HTML pages get
	 * Vary: Accept (so caches keep the variants apart) and the agent discovery Link headers.
	 *
	 * @param   AfterRenderEvent  $event  The event
	 *
	 * @return  void
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	public function onAfterRender(AfterRenderEvent $event): void
	{
		$app = $this->getApplication();

		if (!$app instanceof CMSApplication || !$this->isHtmlSitePage($app)) {
			return;
		}

		if ($this->markdownEnabled()) {
			if (AcceptHeader::prefersMarkdown($this->acceptHeader($app)) && $this->mayConvert($app) && $this->convert($app)) {
				return;
			}

			if ((int) $this->params->get('vary_html', 1) === 1) {
				$this->addVary($app);
			}
		}

		if ((int) $this->params->get('link_headers', 1) === 1) {
			$this->addLinks($app);
		}
	}

	/**
	 * Whether the Markdown version is switched on.
	 *
	 * @return  boolean
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private function markdownEnabled(): bool
	{
		return (int) $this->params->get('markdown', 1) === 1;
	}

	/**
	 * Whether the ARD manifest link is on and the manifest exists in the site root.
	 *
	 * @return  boolean
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private function aiCatalogEnabled(): bool
	{
		return (int) $this->params->get('link_headers', 1) === 1
			&& (int) $this->params->get('link_ai_catalog', 1) === 1
			&& is_file(JPATH_ROOT . '/' . self::AI_CATALOG);
	}

	/**
	 * Adds the agent discovery links to the Link header, merged with links other plugins set:
	 * llms.txt and the agent skills index (only when the file exists in the site root), the
	 * sitemap (when its URL is set) and the Markdown version of this page.
	 *
	 * @param   CMSApplication  $app  The application
	 *
	 * @return  void
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private function addLinks(CMSApplication $app): void
	{
		$root  = Uri::root();
		$links = [];

		if ((int) $this->params->get('link_llms', 1) === 1 && is_file(JPATH_ROOT . '/llms.txt')) {
			$links[] = LinkHeader::link($root . 'llms.txt', 'describedby', 'text/markdown');
		}

		if ((int) $this->params->get('link_agent_skills', 1) === 1 && is_file(JPATH_ROOT . '/.well-known/agent-skills/index.json')) {
			$links[] = LinkHeader::link($root . '.well-known/agent-skills/index.json', 'describedby', 'application/json');
		}

		if ($this->aiCatalogEnabled()) {
			$links[] = LinkHeader::link($root . self::AI_CATALOG, 'ai-catalog', 'application/json');
		}

		$sitemap = trim((string) $this->params->get('sitemap_url', ''));

		if ($sitemap !== '') {
			$sitemapUrl = preg_match('#^https?://#i', $sitemap) === 1 ? $sitemap : $root . ltrim($sitemap, '/');
			$links[]    = LinkHeader::link($sitemapUrl, 'sitemap', 'application/xml');
		}

		if ($this->markdownEnabled() && (int) $this->params->get('link_markdown', 1) === 1) {
			$links[] = LinkHeader::link(Uri::getInstance()->toString(), 'alternate', 'text/markdown');
		}

		if ($links !== []) {
			$app->setHeader('Link', LinkHeader::merge($this->headerValues($app, 'Link'), $links), true);
		}
	}

	/**
	 * The values of every response header with this name (case-insensitive).
	 *
	 * @param   CMSApplication  $app   The application
	 * @param   string          $name  The header name
	 *
	 * @return  list<string>
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private function headerValues(CMSApplication $app, string $name): array
	{
		$values = [];

		foreach ($app->getHeaders() as $header) {
			if (strtolower((string) $header['name']) === strtolower($name)) {
				$values[] = (string) $header['value'];
			}
		}

		return $values;
	}

	/**
	 * A front-end GET or HEAD request for an HTML document with status 200.
	 *
	 * @param   CMSApplication  $app  The application
	 *
	 * @return  boolean
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private function isHtmlSitePage(CMSApplication $app): bool
	{
		if (!$app->isClient('site') || !\in_array($app->getInput()->getMethod(), ['GET', 'HEAD'], true)) {
			return false;
		}

		$document = $app->getDocument();

		if ($document === null || $document->getType() !== 'html') {
			return false;
		}

		foreach ($this->headerValues($app, 'Status') as $status) {
			if ((int) $status !== 200) {
				return false;
			}
		}

		return $app->getResponse()->getStatusCode() === 200;
	}

	/**
	 * The settings that keep a page out of the Markdown version: logged-in users and noindex.
	 *
	 * @param   CMSApplication  $app  The application
	 *
	 * @return  boolean
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private function mayConvert(CMSApplication $app): bool
	{
		if ((int) $this->params->get('skip_logged_in', 1) === 1 && !$app->getIdentity()?->guest) {
			return false;
		}

		if ((int) $this->params->get('skip_noindex', 1) === 1) {
			$robots = implode(',', [(string) $app->getDocument()->getMetaData('robots'), ...$this->headerValues($app, 'X-Robots-Tag')]);

			if (preg_match('/\b(noindex|none)\b/i', $robots) === 1) {
				return false;
			}
		}

		return true;
	}

	/**
	 * Converts the body and sets the Markdown headers. False (HTML untouched) when the page is larger
	 * than MarkdownHeaders::MAX_HTML_BYTES, has no content to convert or the conversion fails.
	 *
	 * @param   CMSApplication  $app  The application
	 *
	 * @return  boolean
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private function convert(CMSApplication $app): bool
	{
		$html = (string) $app->getBody();

		if (!MarkdownHeaders::fits($html)) {
			return false;
		}

		try {
			require_once \dirname(__DIR__, 2) . '/vendor/autoload.php';

			$page = PageExtractor::extract(
				$html,
				trim((string) $this->params->get('content_selector', self::DEFAULT_CONTENT_SELECTOR)) ?: self::DEFAULT_CONTENT_SELECTOR,
				(string) $this->params->get('remove_selectors', self::DEFAULT_REMOVE_SELECTORS),
				Uri::getInstance()->toString()
			);

			$markdown = $page === null ? '' : MarkdownRenderer::render(
				$page,
				(int) $this->params->get('frontmatter', 1) === 1,
				(int) $this->params->get('jsonld', 1) === 1
			);
		} catch (\Throwable $e) {
			Log::add('Markdown conversion failed for ' . Uri::getInstance()->toString() . ': ' . $e->getMessage(), Log::WARNING, 'agentready');

			return false;
		}

		if ($markdown === '') {
			return false;
		}

		$app->setBody($markdown);
		$app->mimeType = 'text/markdown';
		$app->charSet  = 'utf-8';
		$app->setHeader('Content-Type', 'text/markdown; charset=utf-8', true);
		$app->setHeader('x-markdown-tokens', (string) MarkdownRenderer::estimateTokens($markdown), true);
		$this->addVary($app);

		$signal = MarkdownHeaders::contentSignal(
			$this->headerValues($app, 'Content-Signal'),
			(string) $this->params->get('content_signal', '')
		);

		if ($signal !== null) {
			$app->setHeader('Content-Signal', $signal, true);
		}

		// Headers that describe the HTML body no longer match the Markdown.
		$response = $app->getResponse();

		foreach (MarkdownHeaders::STRIP as $name) {
			$response = $response->withoutHeader($name);
		}

		$app->setResponse($response);

		// Without a modified date respond() adds no Last-Modified to a cacheable page. An uncachable
		// page still gets Joomla's "always modified" Last-Modified (the response time) in respond().
		$app->modifiedDate = null;

		return true;
	}

	/**
	 * Adds Accept to the Vary header, keeping what is already there, and switches off Joomla's own
	 * gzip for this response (see onAfterRoute()).
	 *
	 * @param   CMSApplication  $app  The application
	 *
	 * @return  void
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private function addVary(CMSApplication $app): void
	{
		$app->setHeader('Vary', VaryHeader::merge($this->headerValues($app, 'Vary')), true);

		// See onAfterRoute(): Joomla's gzip would drop this Vary value. Also covers a page that
		// onAfterRoute could not judge (format set later).
		if ($app->get('gzip')) {
			$app->set('gzip', false);
		}
	}

	/**
	 * The raw Accept header of the request.
	 *
	 * @param   CMSApplication  $app  The application
	 *
	 * @return  string
	 *
	 * @since   __DEPLOY_VERSION__
	 */
	private function acceptHeader(CMSApplication $app): string
	{
		return (string) $app->getInput()->server->get('HTTP_ACCEPT', '', 'raw');
	}
}
