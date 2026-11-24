<?php

declare(strict_types=1);

/**
 * Parser for bin/claude-pr-guard.sh (#643): decides whether a Bash command from a Claude Code
 * PreToolUse hook opens a PR for review.
 *
 * Reads the hook JSON on stdin and prints two lines: the reason ("gh pr ready" or
 * "gh pr create zonder --draft", empty when the command is fine) and the hook's cwd.
 *
 * The whole command is tokenised like a shell does it (quotes, escapes, heredocs, comments,
 * command substitution, separators), so text inside a quoted argument or a heredoc body is never
 * read as a command, and flags after a multi-line argument still count. Wrappers (env, command,
 * exec, nohup, time, timeout, sudo, nice, xargs, stdbuf, each with its options), a full path to
 * gh, bash/sh/zsh -c, eval and gh's -R/--repo flag are seen through.
 *
 * Deliberately not followed: variable expansion (`$GH pr ready`, `"$(which gh)" pr ready`) and
 * aliases or functions. The guard is a safety net against the usual commands, not a sandbox;
 * the CI on the PR stays the source of truth.
 */

/**
 * Splits a shell string into simple commands (lists of words). Command substitutions and
 * subshells become commands of their own.
 *
 * @return list<list<string>>
 */
function guardParse(string $s): array
{
    $i = 0;

    return guardParseUntil($s, $i, false);
}

/**
 * @return list<list<string>>
 */
function guardParseUntil(string $s, int &$i, bool $stopAtParen): array
{
    $commands = [];
    $words    = [];
    $word     = null;
    $heredocs = [];
    $depth    = 0;
    $len      = strlen($s);

    $endWord = static function () use (&$word, &$words): void {
        if ($word !== null) {
            $words[] = $word;
            $word    = null;
        }
    };
    $endCommand = static function () use (&$words, &$commands, $endWord): void {
        $endWord();
        if ($words !== []) {
            $commands[] = $words;
        }
        $words = [];
    };

    while ($i < $len) {
        $c = $s[$i];

        if ($c === "\n") {
            $endCommand();
            $i++;
            // Heredoc bodies start after the newline that ends the command line.
            foreach ($heredocs as $delimiter) {
                while ($i < $len) {
                    $eol  = strpos($s, "\n", $i);
                    $line = $eol === false ? substr($s, $i) : substr($s, $i, $eol - $i);
                    $i    = $eol === false ? $len : $eol + 1;
                    if (trim($line) === $delimiter) {
                        break;
                    }
                }
            }
            $heredocs = [];
            continue;
        }
        if ($c === ' ' || $c === "\t") {
            $endWord();
            $i++;
            continue;
        }
        if ($c === '#' && $word === null) {
            $eol = strpos($s, "\n", $i);
            $i   = $eol === false ? $len : $eol;
            continue;
        }
        if ($c === ';' || $c === '&' || $c === '|') {
            $endCommand();
            $i++;
            continue;
        }
        if ($c === '(') {
            $endCommand();
            $depth++;
            $i++;
            continue;
        }
        if ($c === ')') {
            $endCommand();
            $i++;
            if ($depth === 0 && $stopAtParen) {
                return $commands;
            }
            $depth = max(0, $depth - 1);
            continue;
        }
        if ($c === '\\') {
            $word = ($word ?? '') . ($s[$i + 1] ?? '');
            $i += 2;
            continue;
        }
        if ($c === "'") {
            $end  = strpos($s, "'", $i + 1);
            $end  = $end === false ? $len : $end;
            $word = ($word ?? '') . substr($s, $i + 1, $end - $i - 1);
            $i    = $end + 1;
            continue;
        }
        if ($c === '"') {
            $i++;
            $word = $word ?? '';
            while ($i < $len && $s[$i] !== '"') {
                if ($s[$i] === '\\') {
                    $word .= $s[$i + 1] ?? '';
                    $i += 2;
                } elseif (substr($s, $i, 2) === '$(') {
                    $i += 2;
                    array_push($commands, ...guardParseUntil($s, $i, true));
                    $word .= '$()';
                } elseif ($s[$i] === '`') {
                    $end = strpos($s, '`', $i + 1);
                    $end = $end === false ? $len : $end;
                    array_push($commands, ...guardParse(substr($s, $i + 1, $end - $i - 1)));
                    $i = $end + 1;
                } else {
                    $word .= $s[$i];
                    $i++;
                }
            }
            $i++;
            continue;
        }
        if (substr($s, $i, 2) === '$(') {
            $i += 2;
            array_push($commands, ...guardParseUntil($s, $i, true));
            $word = ($word ?? '') . '$()';
            continue;
        }
        if ($c === '`') {
            $end = strpos($s, '`', $i + 1);
            $end = $end === false ? $len : $end;
            array_push($commands, ...guardParse(substr($s, $i + 1, $end - $i - 1)));
            $word = ($word ?? '') . '$()';
            $i    = $end + 1;
            continue;
        }
        if (substr($s, $i, 2) === '<<' && substr($s, $i, 3) !== '<<<') {
            $endWord();
            if (preg_match('/\G<<-?[ \t]*(["\']?)([A-Za-z_][A-Za-z0-9_]*)\1/', $s, $m, 0, $i) === 1) {
                $heredocs[] = $m[2];
                $i += strlen($m[0]);
                continue;
            }
        }
        $word = ($word ?? '') . $c;
        $i++;
    }
    $endCommand();

    return $commands;
}

/**
 * Wrappers that run the next word as a command, with the short options that take a separate
 * value (an attached value like -oL or a long --opt=value needs no entry).
 */
const GUARD_WRAPPERS = [
    'command' => [],
    'builtin' => [],
    'exec'    => ['-a'],
    'nohup'   => [],
    'time'    => [],
    'env'     => ['-u', '-C', '-S'],
    'timeout' => ['-s', '-k', '--signal', '--kill-after'],
    'sudo'    => ['-u', '-g', '-h', '-p', '-C', '-D', '-r', '-t', '-U', '-T'],
    'nice'    => ['-n', '--adjustment'],
    'xargs'   => ['-n', '-I', '-L', '-P', '-d', '-E', '-s', '-a'],
    'stdbuf'  => ['-i', '-o', '-e'],
];

/**
 * Drops a wrapper's options (and their values) up to the wrapped command.
 *
 * @param list<string> $words
 * @param list<string> $withValue
 *
 * @return list<string>
 */
function guardSkipWrapperOptions(array $words, array $withValue): array
{
    while ($words !== [] && str_starts_with($words[0], '-')) {
        $option = array_shift($words);
        if ($option === '--') {
            break;
        }
        if (in_array($option, $withValue, true) && $words !== []) {
            array_shift($words);
        }
    }

    return $words;
}

/**
 * Returns the reason a command opens a PR for review, or '' when it does not.
 *
 * @param list<string> $words
 */
function guardCheckCommand(array $words): string
{
    // Leading assignments and wrappers that run the next word as a command.
    while ($words !== []) {
        $first = $words[0];
        if (preg_match('/^[A-Za-z_][A-Za-z0-9_]*=/', $first) === 1) {
            array_shift($words);
            continue;
        }
        $wrapper = basename($first);
        if (array_key_exists($wrapper, GUARD_WRAPPERS)) {
            array_shift($words);
            $words = guardSkipWrapperOptions($words, GUARD_WRAPPERS[$wrapper]);
            // timeout DURATION COMMAND: the duration is a positional argument.
            if ($wrapper === 'timeout' && $words !== []) {
                array_shift($words);
            }
            continue;
        }
        break;
    }
    if ($words === []) {
        return '';
    }

    $program = basename($words[0]);
    if (in_array($program, ['bash', 'sh', 'zsh', 'dash'], true)) {
        $c = array_search('-c', $words, true);

        return $c !== false && isset($words[$c + 1]) ? guardCheck($words[$c + 1]) : '';
    }
    if ($program === 'eval') {
        return guardCheck(implode(' ', array_slice($words, 1)));
    }
    if ($program !== 'gh') {
        return '';
    }

    // gh [-R repo|--repo repo|--repo=repo|--flag] pr [same] <subcommand> args…
    $args = guardSkipFlags(array_slice($words, 1));
    if (($args[0] ?? '') !== 'pr') {
        return '';
    }
    $args = guardSkipFlags(array_slice($args, 1));
    $sub  = $args[0] ?? '';
    $rest = array_slice($args, 1);

    if ($sub === 'ready') {
        return in_array('--undo', $rest, true) ? '' : 'gh pr ready';
    }
    if ($sub === 'create') {
        foreach ($rest as $arg) {
            if ($arg === '--draft' || $arg === '--draft=true' || $arg === '-d') {
                return '';
            }
        }

        return 'gh pr create zonder --draft';
    }

    return '';
}

/**
 * Drops leading flags; -R and --repo take a value.
 *
 * @param list<string> $args
 *
 * @return list<string>
 */
function guardSkipFlags(array $args): array
{
    while ($args !== [] && str_starts_with($args[0], '-')) {
        $flag = array_shift($args);
        if (($flag === '-R' || $flag === '--repo') && $args !== []) {
            array_shift($args);
        }
    }

    return $args;
}

function guardCheck(string $command): string
{
    foreach (guardParse($command) as $words) {
        $reason = guardCheckCommand($words);
        if ($reason !== '') {
            return $reason;
        }
    }

    return '';
}

$input = json_decode((string) stream_get_contents(STDIN), true);
$input = is_array($input) ? $input : [];
$cmd   = $input['tool_input']['command'] ?? '';
$cwd   = $input['cwd'] ?? '';

$reason = ($input['tool_name'] ?? '') === 'Bash' && is_string($cmd) ? guardCheck($cmd) : '';
echo $reason, "\n", is_string($cwd) ? $cwd : '', "\n";
