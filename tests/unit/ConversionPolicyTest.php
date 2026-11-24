<?php

declare(strict_types=1);

/**
 * Which pages may be served as Markdown (and so get the Markdown alternate in the Link header).
 * Run: php tests/unit/ConversionPolicyTest.php
 */

require __DIR__ . '/../bootstrap.php';

use HKweb\Plugin\System\AgentReady\Negotiation\ConversionPolicy;

// Default settings: skip_logged_in and skip_noindex on.
check('normal page, guest', ConversionPolicy::allows(true, true, true, 'index, follow', []), true);
check('no robots at all, guest', ConversionPolicy::allows(true, true, true, '', []), true);
check('noindex in the robots meta', ConversionPolicy::allows(true, true, true, 'noindex, follow', []), false);
check('none in the robots meta', ConversionPolicy::allows(true, true, true, 'none', []), false);
check('NOINDEX is case-insensitive', ConversionPolicy::allows(true, true, true, 'NOINDEX', []), false);
check('X-Robots-Tag: noindex', ConversionPolicy::allows(true, true, true, 'index, follow', ['noindex']), false);
check('X-Robots-Tag for a bot: noindex', ConversionPolicy::allows(true, true, true, '', ['googlebot: noindex']), false);
check('X-Robots-Tag without noindex', ConversionPolicy::allows(true, true, true, '', ['noarchive']), true);
check('logged-in user', ConversionPolicy::allows(true, false, true, 'index, follow', []), false);

// Settings off.
check('noindex page with skip_noindex off', ConversionPolicy::allows(true, true, false, 'noindex', ['noindex']), true);
check('logged-in user with skip_logged_in off', ConversionPolicy::allows(false, false, true, '', []), true);
check('logged-in user on a noindex page, only skip_logged_in off', ConversionPolicy::allows(false, false, true, 'noindex', []), false);

// Whole words only.
check('isNoindex: noindex', ConversionPolicy::isNoindex('noindex'), true);
check('isNoindex: nofollow is not noindex', ConversionPolicy::isNoindex('index, nofollow'), false);
check('isNoindex: "nonexistent" is not none', ConversionPolicy::isNoindex('nonexistent'), false);

finish('ConversionPolicy');
