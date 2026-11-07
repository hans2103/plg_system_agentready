<?php

declare(strict_types=1);

/**
 * Contract between the manifest, the language files, the plugin class and the package.
 * Run: php tests/unit/PluginContractTest.php
 */

require __DIR__ . '/../bootstrap.php';


// The plugin class extends Joomla classes; read its source instead of loading it.
$source   = (string) file_get_contents(PLUGIN_DIR . '/src/Extension/AgentReady.php');
$manifest = simplexml_load_file(PLUGIN_DIR . '/agentready.xml');
$package  = simplexml_load_file(__DIR__ . '/../../package.xml');

check('manifest parses', $manifest !== false, true);
check('plugin group system', (string) $manifest['group'], 'system');
check('namespace', (string) $manifest->namespace, 'HKweb\\Plugin\\System\\AgentReady');
check('plugin version equals package version', (string) $manifest->version, (string) $package->version);
check('package ships the plugin zip', (string) $package->files->file, 'plg_system_agentready.zip');
check('package has no download key (public)', isset($package->dlid), false);

$fields = [];

foreach ($manifest->xpath('//field') as $field) {
	$fields[(string) $field['name']] = $field;
}


preg_match("/DEFAULT_REMOVE_SELECTORS = '([^']+)'/", $source, $remove);
preg_match("/DEFAULT_CONTENT_SELECTOR = '([^']+)'/", $source, $content);
check('content selector default in class source', $content[1] ?? null, (string) $fields['content_selector']['default']);
check('remove selectors default in class source', $remove[1] ?? null, (string) $fields['remove_selectors']['default']);

preg_match_all("/params->get\('([a-z_]+)'/", $source, $used);
check('every setting the class reads is in the manifest', array_values(array_diff(array_unique($used[1]), array_keys($fields))), []);
check('every manifest setting is read by the class', array_values(array_diff(array_keys($fields), $used[1])), []);

check('listens to onAfterRender at lowest priority', str_contains($source, "'onAfterRender'       => ['onAfterRender', Priority::MIN]"), true);
check('listens to onAfterRoute at high priority', str_contains($source, "'onAfterRoute'        => ['onAfterRoute', Priority::HIGH]"), true);
check('listens to onPageCacheGetKey', str_contains($source, "'onPageCacheGetKey'   => 'onPageCacheGetKey'"), true);
check('listens to onBeforeCompileHead', str_contains($source, "'onBeforeCompileHead' => 'onBeforeCompileHead'"), true);
check('ai-catalog Link header', str_contains($source, "LinkHeader::link(\$root . self::AI_CATALOG, 'ai-catalog', 'application/json')"), true);
check('MCP Server Card Link header, only when the file exists', str_contains($source, "is_file(JPATH_ROOT . '/' . self::MCP_SERVER_CARD)") && str_contains($source, "LinkHeader::link(\$root . self::MCP_SERVER_CARD, 'describedby', 'application/json')"), true);
check('MCP Server Card path', str_contains($source, "MCP_SERVER_CARD = '.well-known/mcp/server-card.json'"), true);
check('link_mcp_server_card defaults on', (string) ($fields['link_mcp_server_card']['default'] ?? ''), '1');
check('ai-catalog head link', str_contains($source, "addHeadLink(Uri::root(true) . '/' . self::AI_CATALOG, 'ai-catalog', 'rel', ['type' => 'application/json'])"), true);

foreach (['en-GB', 'nl-NL'] as $tag) {
	$ini = parse_ini_file(PLUGIN_DIR . "/language/$tag/plg_system_agentready.ini");
	$sys = parse_ini_file(PLUGIN_DIR . "/language/$tag/plg_system_agentready.sys.ini");
	$pkg = parse_ini_file(__DIR__ . "/../../Src/language/$tag/pkg_agentready.sys.ini");

	check("$tag ini files parse", \is_array($ini) && \is_array($sys) && \is_array($pkg), true);

	$missing = [];

	foreach ([...$fields, ...$manifest->xpath('//fieldset')] as $field) {
		foreach (['label', 'description'] as $attribute) {
			$key = (string) $field[$attribute];

			if ($key !== '' && !isset($ini[$key])) {
				$missing[] = $key;
			}
		}
	}

	check("$tag has every field string", $missing, []);
	check("$tag sys has the description", isset($sys[(string) $manifest->description]), true);
	check("$tag package description", isset($pkg[(string) $package->description]), true);
}

$en = array_keys(parse_ini_file(PLUGIN_DIR . '/language/en-GB/plg_system_agentready.ini'));
$nl = array_keys(parse_ini_file(PLUGIN_DIR . '/language/nl-NL/plg_system_agentready.ini'));
check('en-GB and nl-NL have the same keys', [array_values(array_diff($en, $nl)), array_values(array_diff($nl, $en))], [[], []]);

finish('PluginContract');
