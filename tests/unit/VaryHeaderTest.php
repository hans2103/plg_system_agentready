<?php

declare(strict_types=1);

/**
 * Vary merge. Run: php tests/unit/VaryHeaderTest.php
 */

require __DIR__ . '/../bootstrap.php';

use HKweb\Plugin\System\AgentReady\Http\VaryHeader;

check('none', VaryHeader::merge([]), 'Accept');
check('keeps existing', VaryHeader::merge(['Accept-Encoding']), 'Accept-Encoding, Accept');
check('no duplicate, case-insensitive', VaryHeader::merge(['accept']), 'accept');
check('list value', VaryHeader::merge(['Cookie, Accept']), 'Cookie, Accept');
check('several headers', VaryHeader::merge(['Cookie', 'Accept-Encoding, cookie']), 'Cookie, Accept-Encoding, Accept');
check('star stays star', VaryHeader::merge(['*']), '*');
check('empty values ignored', VaryHeader::merge([' , ']), 'Accept');

finish('VaryHeader');
