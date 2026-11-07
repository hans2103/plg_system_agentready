<?php

/**
 * bin/check-aidocs.php — controleert de pagina's in AIdocs/.
 *
 * Gebruik (vanuit elke map van de repo):
 *   php bin/check-aidocs.php structure [pagina...]
 *   php bin/check-aidocs.php coverage [--base <ref>]
 *
 * structure: elke pagina heeft een geldige header (Last updated, Verified against, Covers) en elk
 *            Covers-pad bestaat (een leeg lijstitem is een ERROR); elke map tussen AIdocs/ en de
 *            map van een pagina heeft een _index.md die alle pagina's en de _index.md van de
 *            submappen noemt, zonder dode verwijzingen; elke CLAUDE.md in Src/ verwijst naar
 *            bestaande AIdocs-pagina's. Een verwijzing in een _index.md mag als (p.md),
 *            (<mijn pagina.md>) of met %20 zijn geschreven en mag een titel hebben
 *            ((p.md "titel")). Met paginanamen als argument worden alleen de headers van die
 *            pagina's gecontroleerd; een relatief argument wordt opgelost tegen de map waarin
 *            het script is gestart, niet tegen de repo-root.
 * coverage:  bestanden die sinds de merge-base met de basisbranch zijn gewijzigd (plus wijzigingen
 *            die nog niet zijn gecommit) moeten onder de Covers van een pagina vallen (ERROR); een
 *            gedekt bestand waarvan de pagina niet is meegewijzigd geeft een WARNING.
 *            De basis is --base, anders origin/develop, develop of main (de eerste die bestaat).
 *
 * Uitvoer: één regel per bevinding, "ERROR: ..." of "WARNING: ...".
 * Exitcode: 0 = geen ERROR, 1 = minstens één ERROR, 2 = configuratieprobleem.
 */

declare(strict_types=1);

const AIDOCS_DIR = 'AIdocs';
const PACKAGE_FILES = ['package.xml', 'package_script.php', 'package.sh'];
const BINARY_EXTENSIONS = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'ico', 'woff', 'woff2', 'mp4', 'pdf'];

$failed = false;

function fail(string $message): void
{
    global $failed;
    $failed = true;
    echo "ERROR: {$message}\n";
}

function warn(string $message): void
{
    echo "WARNING: {$message}\n";
}

/** Draait git met argumenten en geeft de uitvoerregels terug; $code krijgt de exitcode. */
function git(array $args, ?int &$code = null): array
{
    $command = 'git -c core.quotePath=false ' . implode(' ', array_map('escapeshellarg', $args)) . ' 2>/dev/null';
    exec($command, $lines, $exit);
    $code = $exit;

    return $lines;
}

/** Herleidt een pad naar zijn kortste vorm: verwijdert lege delen, ./ en ../. */
function normalize(string $path): string
{
    $out = [];

    foreach (explode('/', $path) as $part) {
        if ($part === '' || $part === '.') {
            continue;
        }

        if ($part === '..') {
            array_pop($out);

            continue;
        }

        $out[] = $part;
    }

    return implode('/', $out);
}

/** Alle .md-bestanden onder AIdocs/, gesorteerd, met paden relatief aan de repo-root. */
function aidocsPages(): array
{
    if (!is_dir(AIDOCS_DIR)) {
        return [];
    }

    $pages    = [];
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator(AIDOCS_DIR, FilesystemIterator::SKIP_DOTS));

    foreach ($iterator as $file) {
        if ($file->isFile() && substr($file->getFilename(), -3) === '.md') {
            $pages[] = str_replace('\\', '/', $file->getPathname());
        }
    }

    sort($pages);

    return $pages;
}

/** Alle CLAUDE.md-bestanden onder Src/, zonder vendor/. */
function extensionPointers(): array
{
    if (!is_dir('Src')) {
        return [];
    }

    $found    = [];
    $iterator = new RecursiveIteratorIterator(
        new RecursiveCallbackFilterIterator(
            new RecursiveDirectoryIterator('Src', FilesystemIterator::SKIP_DOTS),
            static fn (SplFileInfo $file): bool => $file->getFilename() !== 'vendor'
        )
    );

    foreach ($iterator as $file) {
        if ($file->isFile() && $file->getFilename() === 'CLAUDE.md') {
            $found[] = str_replace('\\', '/', $file->getPathname());
        }
    }

    sort($found);

    return $found;
}

/**
 * Leest het headerblok van een pagina: alles vóór de eerste "## "-kop.
 *
 * @return array{updated: ?string, verified: ?string, covers: string[]}
 */
function parseHeader(string $path): array
{
    $header    = ['updated' => null, 'verified' => null, 'covers' => []];
    $inCovers  = false;

    foreach (file($path, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (strncmp($line, '## ', 3) === 0) {
            break;
        }

        if (preg_match('/^Last updated:\s*(.*?)\s*$/', $line, $m)) {
            $header['updated'] = $m[1];
            $inCovers          = false;

            continue;
        }

        if (preg_match('/^Verified against:\s*(.*?)\s*$/', $line, $m)) {
            $header['verified'] = $m[1];
            $inCovers           = false;

            continue;
        }

        if (preg_match('/^Covers:\s*$/', $line)) {
            $inCovers = true;

            continue;
        }

        if ($inCovers) {
            // Elke regel die met "-" begint (alleen, of gevolgd door witruimte) is een lijstitem; een
            // leeg item blijft in de lijst zodat checkHeader() het meldt. "-foo" is geen lijstitem.
            if (preg_match('/^-(?:\s+(.*))?$/', $line, $m)) {
                $header['covers'][] = trim(trim($m[1] ?? ''), '`');

                continue;
            }

            $inCovers = false;
        }
    }

    return $header;
}

function checkHeader(string $page): void
{
    $header = parseHeader($page);

    $date = $header['updated'];
    if ($date === null || !preg_match('/^(\d{4})-(\d{2})-(\d{2})$/', $date, $m) || !checkdate((int) $m[2], (int) $m[3], (int) $m[1])) {
        fail("{$page}: 'Last updated' ontbreekt of is geen geldige datum (JJJJ-MM-DD)");
    }

    $sha = $header['verified'];
    if ($sha === null || !preg_match('/^[0-9a-f]{7,40}$/', $sha)) {
        fail("{$page}: 'Verified against' ontbreekt of is geen commit-sha");
    } else {
        git(['cat-file', '-e', $sha . '^{commit}'], $code);

        if ($code !== 0) {
            warn("{$page}: commit {$sha} uit 'Verified against' bestaat niet in deze clone (squash-merge of ondiepe clone?)");
        }
    }

    if ($header['covers'] === []) {
        fail("{$page}: 'Covers:' ontbreekt of is leeg");
    }

    foreach ($header['covers'] as $cover) {
        if ($cover === '') {
            fail("{$page}: Covers-pad is leeg (een lijstitem zonder pad)");
        } elseif ($cover[0] === '/' || in_array('..', explode('/', $cover), true)) {
            fail("{$page}: Covers-pad moet relatief aan de repo-root zijn: {$cover}");
        } elseif (!file_exists($cover)) {
            fail("{$page}: Covers-pad bestaat niet: {$cover}");
        } elseif (is_dir($cover) && substr($cover, -1) !== '/') {
            fail("{$page}: Covers-pad is een map en moet op / eindigen: {$cover}");
        }
    }
}

/**
 * Bestanden waarnaar een _index.md verwijst (markdown-links, relatief aan de index). Een doel mag
 * tussen <...> staan (voor een spatie in de naam) en mag procent-gecodeerd zijn (my%20page.md).
 * Met $report komt een verwijzing naar een bestand dat niet bestaat als ERROR.
 */
function linkedFiles(string $index, bool $report = true): array
{
    $found = [];

    if (preg_match_all('/\]\((?|<([^>]*)>|([^)\s]+))(?:\s+(?:"[^"]*"|\'[^\']*\'))?\)/', (string) file_get_contents($index), $m)) {
        foreach ($m[1] as $target) {
            if ($target === '' || preg_match('#^[a-z][a-z0-9+.-]*:#i', $target) || $target[0] === '#') {
                continue;
            }

            $target = (string) preg_replace('/[#?].*$/', '', $target);

            if ($target === '') {
                continue;
            }

            $path = normalize(dirname($index) . '/' . rawurldecode($target));

            if (!file_exists($path)) {
                $path = normalize(dirname($index) . '/' . $target); // een naam met een letterlijke %
            }

            if (!file_exists($path)) {
                if ($report) {
                    fail("{$index}: verwijzing naar een bestand dat niet bestaat: {$target}");
                }

                continue;
            }

            $found[] = $path;
        }
    }

    return array_values(array_unique($found));
}

function checkIndexes(array $pages): void
{
    $dirs = [AIDOCS_DIR => true];

    // Elke map tussen AIdocs/ en de map van een pagina heeft ook een _index.md nodig.
    foreach ($pages as $page) {
        for ($dir = dirname($page); $dir !== AIDOCS_DIR && strncmp($dir, AIDOCS_DIR . '/', strlen(AIDOCS_DIR) + 1) === 0; $dir = dirname($dir)) {
            $dirs[$dir] = true;
        }
    }

    foreach (array_keys($dirs) as $dir) {
        $index = $dir . '/_index.md';

        if (!is_file($index)) {
            fail("{$dir}: _index.md ontbreekt");

            continue;
        }

        $linked = linkedFiles($index);

        foreach ($pages as $page) {
            if (dirname($page) === $dir && basename($page) !== '_index.md' && !in_array($page, $linked, true)) {
                fail("{$page}: niet vermeld in {$index}");
            }
        }

        if ($dir !== AIDOCS_DIR) {
            $parent = dirname($dir) . '/_index.md';

            if (is_file($parent) && !in_array($index, linkedFiles($parent, false), true)) {
                fail("{$index}: niet vermeld in {$parent}");
            }
        }
    }
}

function checkPointers(): void
{
    foreach (extensionPointers() as $pointer) {
        $text = (string) file_get_contents($pointer);

        if (!preg_match_all('#AIdocs/[A-Za-z0-9_./-]+\.md#', $text, $m)) {
            fail("{$pointer}: verwijst niet naar een AIdocs-pagina");

            continue;
        }

        foreach (array_unique($m[0]) as $target) {
            if (!is_file($target)) {
                fail("{$pointer}: verwijst naar een pagina die niet bestaat: {$target}");
            }
        }
    }
}

/**
 * Maakt van een paginaargument een pad relatief aan de repo-root. Een relatief argument wordt
 * opgelost tegen de map waarin het script is gestart ($start), niet tegen de repo-root.
 * Een pad buiten de repo blijft een absoluut pad.
 */
function repoRelative(string $page, string $start, string $top): string
{
    if ($page === '') {
        return ''; // checkStructure() meldt een leeg paginapad
    }

    $start = realpath($start) ?: $start;
    $top   = realpath($top) ?: $top;
    $abs   = '/' . normalize(strncmp($page, '/', 1) === 0 ? $page : $start . '/' . $page);
    $dir   = realpath(dirname($abs)); // symlinks in de map oplossen (op macOS is /var een link naar /private/var)

    if ($dir !== false) {
        $abs = rtrim($dir, '/') . '/' . basename($abs);
    }

    if ($abs === $top) {
        return '.'; // de repo-root zelf
    }

    return strncmp($abs, $top . '/', strlen($top) + 1) === 0 ? substr($abs, strlen($top) + 1) : $abs;
}

function checkStructure(array $only): void
{
    $pages   = aidocsPages();
    $content = array_values(array_filter($pages, static fn (string $p): bool => basename($p) !== '_index.md'));

    if ($only !== []) {
        foreach ($only as $page) {
            if ($page === '') {
                fail('leeg paginapad (een lege paginanaam als argument)');
            } elseif (is_dir($page)) {
                fail("{$page}: is een map, geen pagina");
            } elseif (!is_file($page)) {
                fail("{$page}: bestand bestaat niet");
            } elseif (basename($page) !== '_index.md') {
                checkHeader($page);
            }
        }

        return;
    }

    if (!is_file(AIDOCS_DIR . '/_index.md')) {
        fail(AIDOCS_DIR . '/_index.md ontbreekt');
    }

    foreach ($content as $page) {
        checkHeader($page);
    }

    checkIndexes($pages);
    checkPointers();
}

function inScope(string $file): bool
{
    if (in_array($file, PACKAGE_FILES, true)) {
        return true;
    }

    if (strncmp($file, 'Src/', 4) !== 0
        || strpos($file, '/vendor/') !== false
        || strpos($file, '/language/') !== false
        || basename($file) === 'CLAUDE.md') {
        return false;
    }

    return !in_array(strtolower(pathinfo($file, PATHINFO_EXTENSION)), BINARY_EXTENSIONS, true);
}

function covers(string $cover, string $file): bool
{
    return substr($cover, -1) === '/' ? strncmp($file, $cover, strlen($cover)) === 0 : $file === $cover;
}

/**
 * Bepaalt de basis voor de dekkingscontrole en geeft de merge-base van HEAD met die basis terug.
 * Zonder bruikbare basis komt een bevinding (ERROR voor een opgegeven --base, anders WARNING) en
 * is het resultaat null: de controle wordt dan overgeslagen.
 */
function resolveBase(?string $baseOption): ?string
{
    $base = null;

    foreach ($baseOption !== null ? [$baseOption] : ['origin/develop', 'develop', 'main'] as $ref) {
        git(['rev-parse', '--verify', '--quiet', $ref . '^{commit}'], $code);

        if ($code === 0) {
            $base = $ref;

            break;
        }
    }

    if ($base === null) {
        if ($baseOption !== null) {
            fail("basis '{$baseOption}' bestaat niet");
        } else {
            warn('geen basisbranch gevonden (origin/develop, develop, main); dekkingscontrole overgeslagen');
        }

        return null;
    }

    $mergeBase = git(['merge-base', 'HEAD', $base], $code)[0] ?? '';

    if ($code !== 0 || $mergeBase === '') {
        warn("geen merge-base tussen HEAD en {$base}; dekkingscontrole overgeslagen");

        return null;
    }

    return $mergeBase;
}

/**
 * Werkboom tegenover de merge-base: gecommitte en nog niet gecommitte wijzigingen van gevolgde
 * bestanden, plus nieuwe bestanden die nog niet gevolgd worden. Zonder renamedetectie: een
 * verplaatsing telt als verwijderd bestand plus nieuw bestand.
 *
 * @return array<string, string> pad => 'D' (verwijderd) of 'M' (gewijzigd of nieuw), gesorteerd op pad
 */
function changedFiles(string $mergeBase): array
{
    $changed = [];

    foreach (git(['diff', '--name-status', '--no-renames', $mergeBase]) as $line) {
        [$status, $path] = array_pad(explode("\t", $line, 2), 2, '');

        if ($path !== '') {
            $changed[$path] = $status[0] === 'D' ? 'D' : 'M';
        }
    }

    foreach (git(['ls-files', '--others', '--exclude-standard']) as $path) {
        $changed[$path] ??= 'M';
    }

    ksort($changed);

    return $changed;
}

/** De pagina's waarvan een Covers-item $file dekt; $pageCovers is pagina => lijst met Covers. */
function coveringPages(string $file, array $pageCovers): array
{
    $covering = [];

    foreach ($pageCovers as $page => $covers) {
        foreach ($covers as $cover) {
            if (covers($cover, $file)) {
                $covering[] = $page;

                break;
            }
        }
    }

    return $covering;
}

function checkCoverage(?string $baseOption): void
{
    $mergeBase = resolveBase($baseOption);

    if ($mergeBase === null) {
        return;
    }

    $changed    = changedFiles($mergeBase);
    $pageCovers = [];

    foreach (aidocsPages() as $page) {
        if (basename($page) !== '_index.md') {
            $pageCovers[$page] = parseHeader($page)['covers'];
        }
    }

    foreach ($changed as $file => $status) {
        $file = (string) $file; // een puur numerieke bestandsnaam wordt door PHP een integer-sleutel

        if (!inScope($file)) {
            continue;
        }

        $covering = coveringPages($file, $pageCovers);

        if ($covering === []) {
            if ($status !== 'D') {
                fail("{$file}: geen AIdocs-pagina dekt dit bestand (voeg het toe aan de Covers: van een pagina)");
            }

            continue;
        }

        if (array_intersect($covering, array_keys($changed)) === []) {
            warn("{$file}: gedekt door " . implode(', ', $covering) . ', maar die pagina is niet gewijzigd');
        }
    }
}

// ---------------------------------------------------------------------------------------------

$start = getcwd();
$top   = git(['rev-parse', '--show-toplevel'], $code)[0] ?? '';

if ($code !== 0 || $top === '' || !chdir($top)) {
    fwrite(STDERR, "Geen git-repo.\n");
    exit(2);
}

$args = array_slice($argv, 1);
$mode = array_shift($args);

if ($mode === 'structure') {
    checkStructure(array_map(static fn (string $page): string => repoRelative($page, (string) $start, $top), $args));
} elseif ($mode === 'coverage') {
    $baseOption = null;

    if ($args !== []) {
        if ($args[0] !== '--base' || count($args) !== 2 || $args[1] === '') {
            fwrite(STDERR, "Gebruik: check-aidocs.php coverage [--base <ref>]\n");
            exit(2);
        }

        $baseOption = $args[1];
    }

    checkCoverage($baseOption);
} else {
    fwrite(STDERR, "Gebruik: check-aidocs.php structure [pagina...] | coverage [--base <ref>]\n");
    exit(2);
}

exit($failed ? 1 : 0);
