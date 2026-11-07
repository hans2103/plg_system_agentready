<?php

declare(strict_types=1);

/**
 * Shared bootstrap for the plain-PHP unit tests in tests/unit/ (no PHPUnit).
 * Loads the plugin classes (PSR-4) and the bundled vendor autoloader, and defines check().
 */

\define('_JEXEC', 1);

const PLUGIN_DIR = __DIR__ . '/../Src/plugins/system/agentready';

spl_autoload_register(static function (string $class): void {
	$prefix = 'HKweb\\Plugin\\System\\AgentReady\\';

	if (str_starts_with($class, $prefix)) {
		$file = PLUGIN_DIR . '/src/' . str_replace('\\', '/', substr($class, \strlen($prefix))) . '.php';

		if (is_file($file)) {
			require $file;
		}
	}
});

require PLUGIN_DIR . '/vendor/autoload.php';

$failures = 0;

function check(string $label, mixed $actual, mixed $expected): void
{
	global $failures;

	if ($actual === $expected) {
		echo "  ok   $label\n";

		return;
	}

	$failures++;
	echo "  FAIL $label\n       expected: " . var_export($expected, true) . "\n       actual:   " . var_export($actual, true) . "\n";
}

function finish(string $name): never
{
	global $failures;

	echo $failures === 0 ? "\nAll $name assertions passed.\n" : "\n$failures FAILURE(S) in $name.\n";
	exit($failures === 0 ? 0 : 1);
}
