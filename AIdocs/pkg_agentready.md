# Package (pkg_agentready)

### History
- 2026-11-07: page created with the first version (issue #1)
- 2026-11-07: update server is GitHub (`updates.xml` on main via raw.githubusercontent.com) instead of updates.hkweb.nl (issue #6)
- 2026-11-07: `package.sh` stamps `__DEPLOY_VERSION__` in `Src/` only (issue #10)

Last updated: 2026-11-07
Verified against: 00ff79c
Covers:
- package.xml
- package_script.php
- package.sh
- Src/language/

## Purpose

`pkg_agentready` wraps the one plugin, `plg_system_agentready`, in a Joomla package. The package exists because the shared tooling in `bin/` (`add-update-entry.php` writes `<type>package</type>`, `preflight.sh` and `run-release.sh` read the version from `package.xml`) is built around a package; it also gives the site an install message in its own language.

## package.xml

- `<version>` is the single source of truth for the version (calendar versioning `YY.WW.PATCH`); `package.sh {version}` stamps it, with `<creationDate>`, into `package.xml` and `Src/plugins/system/agentready/agentready.xml`.
- `<files>`: one entry, `plg_system_agentready.zip` (type plugin, group system, id agentready).
- `<languages folder="language">`: `pkg_agentready.sys.ini` for en-GB and nl-NL; Joomla installs them in the site's global `language/` folders.
- `<updateservers>`: `https://raw.githubusercontent.com/hans2103/plg_system_agentready/main/updates.xml` (GitHub as the update server, like the other public `plg_` repos; the zip downloads from the GitHub Release). No `<dlid>`: the extension is public.

## package_script.php

Class `Pkg_AgentreadyInstallerScript` (Joomla finds it by the package element; a wrong class name means the script silently does not run).

- `preflight()`: refuses install and update below PHP 8.3.0 (`PKG_AGENTREADY_MIN_PHP`) or Joomla 5.3.3 (`PKG_AGENTREADY_MIN_JOOMLA`). Keep these equal to `UPDATE_PHP_MINIMUM` and `UPDATE_TARGETPLATFORM` in `scripts.conf`.
- `postflight()`: on `install` and `discover_install` only, sets `enabled = 1` for the plugin in `#__extensions` (bound parameters). An update keeps the site's choice.

## package.sh

`bash package.sh [version]`, from the repo root.

1. With a version (`^[0-9]{2}\.[0-9]{1,2}\.[0-9]+$`): stamps version and date, replaces `__DEPLOY_VERSION__` in `Src/` only (that is what `bin/run-release.sh` commits; `package_script.php` carries real `@since` versions, as in `hkweb_adventcalendar`). Without: reads the version from `package.xml` and changes nothing.
2. Stops when `vendor/autoload.php` is missing in the plugin folder.
3. Zips the plugin folder's contents into `packages/{version}/plg_system_agentready.zip`, excluding the patterns in `.deployignore` (`CLAUDE.md`, `vendor/bin`, tests and docs of bundled libraries); `composer.json` and `composer.lock` go along, so a site can see what is bundled.
4. Builds `packages/{version}/pkg_agentready-{version}.zip` with `pkg_agentready.xml`, `package_script.php`, `language/{tag}/pkg_agentready.sys.ini` and the plugin zip.

`.github/workflows/validate.yml` builds the package and checks the zip contains the manifest, the script, both package language files and, inside the plugin zip, the manifest, provider, extension class, vendor autoloader, the library and its LICENSE, and both plugin language files.

## See also

- [plg_system_agentready](plg_system_agentready.md)
