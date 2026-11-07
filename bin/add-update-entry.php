<?php

declare(strict_types=1);

/**
 * Voegt een package-entry voor de opgegeven versie toe aan het update-server-bestand.
 *
 * Gebruik: php bin/add-update-entry.php <versie> [pad-naar-updates.xml] [--zip=pad-naar-pakket.zip]
 *
 * De entry krijgt een <sha512> van de pakket-zip, zodat Joomla de download controleert (issue #257):
 * --zip=pad, of zonder die optie de uitvoer van package.sh (packages/<versie>/<element>-<versie>.zip).
 * Geen zip te vinden: de entry komt er zonder checksum, met een waarschuwing. Een --zip die niet
 * bestaat is een fout (exitcode 1). De hash moet van de zip zijn die op de downloadserver komt.
 *
 * Idempotent: bestaat de entry al, dan blijft het bestand ongewijzigd (exitcode 0). De nieuwste
 * release komt bovenaan. Exitcode 1 bij een ongeldige versie of een onbruikbaar updates.xml,
 * 2 bij een ontbrekende instelling.
 *
 * Instellingen komen uit de omgeving of, als die ontbreekt, uit scripts.conf in de repo-root
 * (alleen de scalaire waarden; een release-workflow hoeft scripts.conf dus niet te sourcen):
 *   PACKAGE_ELEMENT, GITHUB_REPO (verplicht), UPDATES_XML, UPDATE_NAME, UPDATE_DESCRIPTION,
 *   UPDATE_TARGETPLATFORM, UPDATE_PHP_MINIMUM, UPDATE_MAINTAINER, UPDATE_MAINTAINER_URL,
 *   UPDATE_DOWNLOAD_BASE.
 *
 * UPDATE_DOWNLOAD_BASE is de URL van de map waar de pakket-zip staat, zonder slash aan het eind
 * (bijvoorbeeld https://updates.hkweb.nl/adventcalendar). Leeg of niet gezet: de downloadlink wijst
 * naar de GitHub Release van GITHUB_REPO.
 */

$root = dirname(__DIR__);

/** Waarde van een instelling: omgeving eerst, dan scripts.conf (NAAM="waarde" of NAAM='waarde'). */
function setting(string $name, string $root): string
{
    $env = getenv($name);

    if ($env !== false && $env !== '') {
        return $env;
    }

    $conf = $root . '/scripts.conf';

    if (is_file($conf) && preg_match('/^' . preg_quote($name, '/') . '=(?:"([^"]*)"|\'([^\']*)\')/m', (string) file_get_contents($conf), $m)) {
        return $m[2] ?? $m[1];
    }

    return '';
}

// Positionele argumenten en de optie --zip=pad, in willekeurige volgorde.
$args    = array_slice($argv, 1);
$zipArg  = null;
$positional = [];

foreach ($args as $arg) {
    if (str_starts_with($arg, '--zip=')) {
        $zipArg = substr($arg, \strlen('--zip='));
    } else {
        $positional[] = $arg;
    }
}

$version = $positional[0] ?? '';

if (!preg_match('/^\d{2}\.\d{1,2}\.\d+$/', $version)) {
    fwrite(STDERR, "Ongeldige versie '{$version}' (verwacht JJ.WW.N)\n");
    exit(1);
}

$element = setting('PACKAGE_ELEMENT', $root);
$repo    = setting('GITHUB_REPO', $root);

if ($element === '' || $repo === '') {
    fwrite(STDERR, "PACKAGE_ELEMENT en GITHUB_REPO ontbreken (scripts.conf of omgeving)\n");
    exit(2);
}

$updatesXml = setting('UPDATES_XML', $root) ?: 'updates.xml';
$file       = $positional[1] ?? $root . '/' . $updatesXml;

$content = is_file($file) ? file_get_contents($file) : false;
$xml     = $content === false ? false : @simplexml_load_string($content);

if ($xml === false || !str_contains($content, '<updates>') || !str_contains($content, '</updates>')) {
    fwrite(STDERR, "Geen geldig updates.xml: {$file}\n");
    exit(1);
}

foreach ($xml->update as $update) {
    if ((string) $update->element === $element && (string) $update->version === $version) {
        echo "Entry voor {$version} staat al in {$file}\n";
        exit(0);
    }
}

// De pakket-zip voor de checksum: --zip, anders de uitvoer van package.sh.
$zip = $zipArg ?? $root . "/packages/{$version}/{$element}-{$version}.zip";

if ($zipArg !== null && !is_file($zip)) {
    fwrite(STDERR, "Pakket-zip niet gevonden: {$zip}\n");
    exit(1);
}

$sha512 = is_file($zip) ? (string) hash_file('sha512', $zip) : '';

if ($sha512 === '') {
    fwrite(STDERR, "Waarschuwing: geen pakket-zip ({$zip}); de entry krijgt geen <sha512>\n");
}

$e = static fn (string $value): string => htmlspecialchars($value, ENT_XML1 | ENT_QUOTES, 'UTF-8');

$name        = setting('UPDATE_NAME', $root) ?: $element;
$description = setting('UPDATE_DESCRIPTION', $root);
$target      = setting('UPDATE_TARGETPLATFORM', $root) ?: '(5|6|7)\.[0-9]+';
$phpMinimum  = setting('UPDATE_PHP_MINIMUM', $root);
$maintainer  = setting('UPDATE_MAINTAINER', $root);
$maintainerU = setting('UPDATE_MAINTAINER_URL', $root);
$downloadBase = rtrim(setting('UPDATE_DOWNLOAD_BASE', $root), '/');
$downloadUrl  = $downloadBase !== ''
    ? "{$downloadBase}/{$element}-{$version}.zip"
    : "https://github.com/{$repo}/releases/download/v{$version}/{$element}-{$version}.zip";

// Sluit aan op de inspringing van het bestaande bestand: elk niveau dieper springt één stap in
// (2 spaties in een bestand waar <update> niet inspringt, anders de inspringing van <update>).
preg_match('/^([ \t]*)<update>/m', $content, $m);
$indent = $m[1] ?? '';
$unit   = $indent === '' ? '  ' : $indent;

// [niveau, regel]; null-regels (lege optionele instellingen) vallen weg.
$lines = [
    [0, '<update>'],
    [1, "<name>{$e($name)}</name>"],
    [1, $description !== '' ? "<description>{$e($description)}</description>" : null],
    [1, "<element>{$e($element)}</element>"],
    [1, '<type>package</type>'],
    [1, "<version>{$version}</version>"],
    [1, "<infourl title=\"{$e($name)}\">https://github.com/{$e($repo)}</infourl>"],
    [1, '<downloads>'],
    [2, "<downloadurl type=\"full\" format=\"zip\">{$e($downloadUrl)}</downloadurl>"],
    [1, '</downloads>'],
    [1, $sha512 !== '' ? "<sha512>{$sha512}</sha512>" : null],
    [1, '<tags>'],
    [2, '<tag>stable</tag>'],
    [1, '</tags>'],
    [1, $maintainer !== '' ? "<maintainer>{$e($maintainer)}</maintainer>" : null],
    [1, $maintainerU !== '' ? "<maintainerurl>{$e($maintainerU)}</maintainerurl>" : null],
    [1, '<section>Updates</section>'],
    [1, "<targetplatform name=\"joomla\" version=\"{$e($target)}\"/>"],
    [1, $phpMinimum !== '' ? "<php_minimum>{$e($phpMinimum)}</php_minimum>" : null],
    [1, '<client>site</client>'],
    [0, '</update>'],
];

$entry = '';

foreach ($lines as [$level, $line]) {
    if ($line !== null) {
        $entry .= $indent . str_repeat($unit, $level) . $line . "\n";
    }
}

// Nieuwste release bovenaan; het eerste <updates> is de openingstag.
$pos     = (int) strpos($content, '<updates>') + strlen('<updates>');
$updated = substr($content, 0, $pos) . "\n" . rtrim($entry, "\n") . substr($content, $pos);

if (@simplexml_load_string($updated) === false) {
    fwrite(STDERR, "De nieuwe entry maakt {$file} ongeldig; niets geschreven\n");
    exit(1);
}

file_put_contents($file, $updated);
echo "Entry voor {$version} toegevoegd aan {$file}\n";
