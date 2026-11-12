<?php

declare(strict_types=1);

/**
 * Controleert dat de <files>/<media>-secties van extensie-manifests overeenkomen met de schijf.
 *
 * Joomla installeert alleen wat het manifest noemt: een vergeten map (bijv. forms/ of services/)
 * ontbreekt na een schone installatie, en een genoemde map die niet bestaat is een fout in het
 * manifest. Elk item in een sectie moet dus bestaan en elk item op schijf moet genoemd zijn.
 *
 * Regels per manifest:
 *  - een component-manifest lost <files folder="…"> en <media folder="…"> op vanaf de bronmap
 *    (--src, default Src); alle andere manifests vanaf de map van het manifest zelf, behalve een
 *    <media> die daar niet bestaat: die zoekt het onder {src}/media/{destination};
 *    let op: dan moet de build {src}/media/{destination} in de zip onder {folder} zetten (zoals
 *    package.sh in hkweb_adventcalendar doet voor tpl_mu.zip). Een gewone zip van alleen de map
 *    van het manifest levert zonder die stap geen media uit, terwijl deze controle OK meldt;
 *  - een <files> zonder folder-attribuut is alleen toegestaan in een niet-component-manifest
 *    (bijv. een plugin): dat betekent de map van het manifest zelf;
 *  - het manifest zelf, het <scriptfile> en verborgen bestanden (.DS_Store) hoeven niet genoemd
 *    te worden, CLAUDE.md (verwijzing voor AI-tools, niet meegepakt) evenmin;
 *  - <languages>: elk genoemd taalbestand moet bestaan en de map ervan telt als genoemd;
 *  - een genoemd item dat met --built is opgegeven (BUILT_DIRS in scripts.conf: een map die de
 *    build maakt en die niet in git staat, zoals een library-vendor/) mag op schijf ontbreken.
 *
 * Gebruik: php bin/check-manifests.php [--src=Src] [--built=pad ...] manifest.xml [manifest.xml ...]
 *   Paden zijn relatief aan de huidige map (de repo-root).
 * Uitvoer: één regel per afwijking. Exitcode: 0 = consistent, 1 = afwijkingen,
 *   2 = geen manifests opgegeven, manifest ontbreekt of is onleesbaar.
 */

const IGNORED_ENTRIES = ['CLAUDE.md'];
const ITEM_TAGS       = ['folder', 'filename', 'file'];

/**
 * @return list<string> namen van de <folder>-, <filename>- en <file>-kinderen
 */
function listedEntries(SimpleXMLElement $element): array
{
    $names = [];

    foreach (ITEM_TAGS as $tag) {
        foreach ($element->{$tag} as $node) {
            $name = trim((string) $node);

            if ($name !== '') {
                $names[] = $name;
            }
        }
    }

    return $names;
}

/**
 * @return list<string> top-level namen in $dir, zonder verborgen bestanden
 */
function entriesOnDisk(string $dir): array
{
    $names = [];

    foreach (scandir($dir) ?: [] as $name) {
        if ($name !== '' && $name[0] !== '.') {
            $names[] = $name;
        }
    }

    return $names;
}

/**
 * Normalises a repo-relative path for comparison (forward slashes, no empty or ./ segments).
 */
function normalisePath(string $path): string
{
    $path = str_replace('\\', '/', $path);

    // Lege en ./-segmenten weg (een <files> zonder folder geeft "map/./naam").
    $parts = array_filter(explode('/', $path), static fn (string $part): bool => $part !== '' && $part !== '.');

    return implode('/', $parts);
}

/**
 * @param  list<string>  $built  normalised paths of directories the build creates (may be missing)
 *
 * @return list<string> gevonden afwijkingen voor één manifest
 */
function checkManifest(string $manifest, string $src, array $built = []): array
{
    $errors   = [];
    $xml      = simplexml_load_file($manifest);
    $manifest = str_replace('\\', '/', $manifest);

    if ($xml === false) {
        return ["{$manifest}: geen geldige XML"];
    }

    $isComponent = (string) $xml['type'] === 'component';
    $manifestDir = dirname($manifest);
    $base        = $isComponent ? $src : $manifestDir;
    $scriptfile  = trim((string) $xml->scriptfile);

    // Taalbestanden uit <languages>: relatief aan de map van het manifest (plus het folder-attribuut).
    $languageDirs = [];

    foreach ($xml->xpath('//languages') ?: [] as $block) {
        $prefix = (string) $block['folder'];
        $prefix = $prefix === '' ? '' : rtrim($prefix, '/') . '/';

        foreach ($block->language as $node) {
            $relative = $prefix . trim((string) $node);

            if (!is_file($manifestDir . '/' . $relative)) {
                $errors[] = "{$manifest}: taalbestand {$relative} staat in het manifest maar niet op schijf";
            }

            $languageDirs[] = explode('/', $relative)[0];
        }

        // <languages folder="language"> zonder <language>-kinderen installeert de map als geheel.
        if ($prefix !== '' && count($block->language) === 0) {
            $languageDirs[] = explode('/', rtrim($prefix, '/'))[0];
        }
    }

    $languageDirs = array_values(array_unique($languageDirs));

    foreach ($xml->xpath('//files | //media') ?: [] as $block) {
        $tag      = $block->getName();
        $folder   = (string) $block['folder'];
        $implicit = false;

        if ($folder === '' && $tag === 'files' && !$isComponent && $block->xpath('parent::*')[0]->getName() === 'extension') {
            $folder   = '.';
            $implicit = true;
        }

        if ($folder === '') {
            $errors[] = "{$manifest}: <{$tag}> zonder folder-attribuut";

            continue;
        }

        $directory = rtrim($base . '/' . $folder, '/');
        $label     = $folder === '.' ? '' : "{$folder}/";

        // <media> van een niet-component (template, module, plugin): in de zip staat de map naast
        // het manifest, in de bronboom onder {src}/media/{destination}, zoals Joomla hem installeert.
        if ($tag === 'media' && !$isComponent && !is_dir($directory)) {
            $destination = trim((string) $block['destination'], '/');

            if ($destination !== '' && is_dir($src . '/media/' . $destination)) {
                $directory = $src . '/media/' . $destination;
            }
        }

        if (!is_dir($directory)) {
            $errors[] = "{$manifest}: map {$folder} bestaat niet";

            continue;
        }

        $listed = listedEntries($block);

        if ($implicit) {
            $listed = array_merge($listed, $languageDirs);
        }

        $onDisk       = entriesOnDisk($directory);
        $selfContains = realpath($directory) === realpath($manifestDir);
        $skip         = IGNORED_ENTRIES;

        if ($selfContains) {
            $skip[] = basename($manifest);

            if ($scriptfile !== '') {
                $skip[] = $scriptfile;
            }
        }

        foreach (array_diff($listed, $onDisk) as $name) {
            // Een geneste verwijzing (map/bestand) staat niet als top-level item op schijf.
            // Een map die de build maakt (--built) staat niet in git en mag ontbreken.
            if (!file_exists($directory . '/' . $name) && !in_array(normalisePath($directory . '/' . $name), $built, true)) {
                $errors[] = "{$manifest}: {$label}{$name} staat in het manifest maar niet op schijf";
            }
        }

        foreach (array_diff($onDisk, $listed, $skip) as $name) {
            $errors[] = "{$manifest}: {$label}{$name} staat op schijf maar niet in het manifest";
        }
    }

    return $errors;
}

// ---------------------------------------------------------------------------------------------

$src       = 'Src';
$built     = [];
$manifests = [];

foreach (array_slice($argv, 1) as $arg) {
    if (strncmp($arg, '--src=', 6) === 0) {
        $src = rtrim(substr($arg, 6), '/');
    } elseif (strncmp($arg, '--built=', 8) === 0) {
        $built[] = normalisePath(substr($arg, 8));
    } else {
        $manifests[] = $arg;
    }
}

if ($manifests === []) {
    fwrite(STDERR, "Gebruik: check-manifests.php [--src=Src] [--built=pad ...] manifest.xml [manifest.xml ...]\n");
    exit(2);
}

libxml_use_internal_errors(true);

$problems = [];

foreach ($manifests as $manifest) {
    if (!is_file($manifest)) {
        fwrite(STDERR, "Manifest ontbreekt of is onleesbaar: {$manifest}\n");
        exit(2);
    }

    $problems = array_merge($problems, checkManifest($manifest, $src, $built));
}

foreach ($problems as $problem) {
    echo $problem, "\n";
}

if ($problems === []) {
    echo "Manifests komen overeen met de schijf.\n";
}

exit($problems === [] ? 0 : 1);
