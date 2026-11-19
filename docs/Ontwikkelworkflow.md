# Ontwikkelworkflow

Repo-indeling, branching, commit-conventies en lokaal bouwen en testen. Voor releases: `docs/Release en deployment procedure.md`.

## Aan de slag (eenmalig per clone)

```bash
git config core.hooksPath .githooks        # hooks: commit-msg (issue-nummer verplicht) en pre-push (bin/ci-local.sh)
echo 'JOOMLA_DIR=/pad/naar/joomla/public_html' > .dev-local   # voor deploy-ddev.sh en setup-dev-links.sh (of zet AGENTREADY_JOOMLA_DIR)
```

Vereisten: PHP 8.3+, `zip`, `unzip`, `xmllint`, `rsync`, `composer` (alleen om de gebundelde library bij te werken) en de GitHub CLI (`gh`, voor releases). De scripts werken op macOS (bash 3.2) en Linux.

## Repo-indeling

| Pad | Inhoud |
|---|---|
| `Src/plugins/system/agentready/` | De plugin: manifest `agentready.xml`, `services/`, `src/`, `language/`, `vendor/` (gebundeld, in git) |
| `Src/language/` | Taalbestanden van het pakket (`pkg_agentready.sys.ini`) |
| `package.xml`, `package_script.php`, `package.sh`, `.deployignore` | Het pakket `pkg_agentready` |
| `bin/` | Gedeelde HKweb-tooling, byte-identiek aan `hkweb_adventcalendar`; wat per repo verschilt staat in `scripts.conf` |
| `tests/unit/` | Plain-PHP unit-tests (geen PHPUnit); `tests/bootstrap.php` laadt de klassen |
| `tests/shell/` | Tests voor `bin/` |
| `AIdocs/` | Geverifieerde documentatie voor AI-assistenten |

## Bouwen en testen

```bash
for f in tests/unit/*.php; do php "$f" || echo "FAIL $f"; done
bash tests/shell/run-all.sh
bash bin/preflight.sh
bash package.sh                      # packages/{versie}/pkg_agentready-{versie}.zip
```

`package.sh` zonder versie stempelt niets. Installeer de zip op een testsite, of zet de plugin met `bash bin/deploy-ddev.sh` in de lokale site (rsync, geen symlinks).

Testen op een DDEV-site (bijv. momentsuntil):

```bash
curl -sk -H 'Accept: text/markdown' -D - https://momentsuntil.ddev.site:<poort>/
curl -sk -D - https://momentsuntil.ddev.site:<poort>/ -o /dev/null | grep -i '^link\|^vary'
```

Verwacht: `content-type: text/markdown; charset=utf-8`, `vary: Accept`, `x-markdown-tokens` en Markdown met frontmatter en JSON-LD; zonder de Accept-header HTML met `Link` en `Vary: Accept`. Zet ook eens *Systeem - Paginacache* aan en vraag beide varianten twee keer op.

## De gebundelde library bijwerken

```bash
cd Src/plugins/system/agentready
composer update --no-dev && rm -rf vendor/bin
```

Draai de tests en commit `vendor/` en `composer.lock` samen. De validate-workflow controleert dat `vendor/` bij `composer.lock` hoort.

## Branching model

- `main`: alleen getagde releases.
- `develop`: integratiebranch; elke PR gaat hierheen.
- Feature-branches: `feature/{issue}-{korte-omschrijving}` vanaf `develop`.
- Nooit rechtstreeks committen op `main` of `develop`. Geen PR van `develop` naar `main`: `bin/run-release.sh` merget zelf.

## Commit-conventies

Nederlands, conventional, met issuenummer: `feat(markdown): #12 tabellen met colspan`. Zonder issue: `#000`. Geen `Co-Authored-By`. Release-commits (`chore(release): …`) en merges zijn uitgezonderd van de hook.

## Lokale CI en draft-PR's

Lokaal = snelle terugkoppeling, CI = bron van waarheid. `bash bin/ci-local.sh` draait vóór een push of `gh pr ready` dezelfde controles als Validate: preflight, PHP-lint over de hele repo, de unit-tests, de vendor-controle, de shell-tests en een testbuild met `package.sh` (en gitleaks als dat geïnstalleerd is). Wat het draait staat in `scripts.conf` (`CI_*`).

```bash
bash bin/ci-local.sh          # alle controles; bij succes een stempel voor HEAD
bash bin/ci-local.sh --quick  # alleen preflight en de snelle tests; geen stempel
bash bin/ci-local.sh --check  # exit 0 als HEAD een geldige stempel heeft
```

- **Stempel.** Bij succes schrijft het script `<git-common-dir>/ci-local/<commit>`. Die geldt alleen als HEAD die commit is en de werkboom schoon is (ook geen ongevolgde bestanden).
- **pre-push hook** (`.githooks/pre-push`, actief via `core.hooksPath`): zonder stempel voor de gepushte commit draait de hook eerst `bin/ci-local.sh`; faalt dat, dan gaat de push niet door. Tags, verwijderingen en pushes naar `main`/`develop` gaan altijd door. Noodknop: `KWEK_SKIP_CI_LOCAL=1 git push …` (de hook is gelijk aan die van `oc1882_kwekfestijn`); `git push --no-verify` slaat alle hooks over.
- **Claude-hook** (`.claude/settings.json`, PreToolUse op Bash → `bin/claude-pr-guard.sh`): weigert `gh pr ready` en `gh pr create` zonder `--draft` als HEAD geen geldige stempel heeft. Een draft openen gaat altijd.
- **Werkwijze:** open de PR als draft (`gh pr create --draft --base develop`), draai `bash bin/ci-local.sh` tot het groen is en zet de PR dan met `gh pr ready` op ready for review. Vanuit Claude: draai `bin/ci-local.sh` eerst als eigen commando met een ruime time-out en push daarna.

## Pull requests

Eén PR per issue naar `develop`, als draft geopend; na een groene `bash bin/ci-local.sh` zet `gh pr ready` hem op ready for review (zie [Lokale CI en draft-PR's](#lokale-ci-en-draft-prs)). De validate-workflow draait lint (PHP 8.3 en 8.5), unit- en shell-tests, manifest- en lengtecontroles, de vendor-controle en een testbuild met controle op de inhoud van de zip.

## Taalbestanden

Elke nieuwe string in `en-GB` én `nl-NL`, in `Src/plugins/system/agentready/language/`. `tests/unit/PluginContractTest.php` faalt als een veld geen label of omschrijving heeft, of als de twee talen andere sleutels hebben.

## AIdocs bijhouden

Wijzig je een bestand dat een AIdocs-pagina dekt, werk die pagina in dezelfde PR bij (`Last updated`, `Verified against`, een `History`-regel). `bash bin/preflight.sh` (controle 14) meldt bestanden zonder pagina.
