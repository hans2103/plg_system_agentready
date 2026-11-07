# Release en deployment procedure

Een release is één commando: `bash bin/run-release.sh`. Het script merget `develop` naar `main`, bouwt het pakket, commit, tagt `v{versie}` en pusht. De workflow `.github/workflows/release.yml` maakt daarna de GitHub Release, werkt `updates.xml` bij en zet de zip en `updates.xml` op `https://updates.hkweb.nl/agentready/`.

```
run-release.sh:  develop → main mergen → package.sh {versie} → commit → push main → tag v{versie} → push tag
release.yml:     tag = package.xml? → package.sh → git-cliff release notes → GitHub Release → updates.xml naar main → zip + updates.xml naar updates.hkweb.nl
```

## Versienummers

Calendar versioning `JJ.WW.N`: jaar, ISO-week, volgnummer binnen de week (bijv. `26.45.0`). `run-release.sh` stelt het volgende nummer voor op basis van de tags. `package.xml` is de enige bron; `package.sh {versie}` stempelt het plugin-manifest en vervangt `__DEPLOY_VERSION__`.

## Een release maken

1. Alles wat mee moet staat op `develop` (PR's gemerged, CI groen).
2. `bash bin/run-release.sh --dry-run` om het versievoorstel en de stappen te zien.
3. `bash bin/run-release.sh` en bevestig.
4. Controleer de GitHub Release en `https://updates.hkweb.nl/agentready/updates.xml`.

## Wat de workflow doet

1. Controleert dat de tag gelijk is aan `<version>` in `package.xml`.
2. Bouwt het pakket met `package.sh {versie}`.
3. Maakt release notes met git-cliff uit de conventional commits.
4. Maakt de GitHub Release met de zip (de repo is publiek: iedereen kan hem downloaden).
5. Voegt een entry toe aan `updates.xml` (met `<sha512>` van de zip) en pusht die naar `main`.
6. Zet met `rsync` eerst de zip en dan `updates.xml` in `https://updates.hkweb.nl/agentready/`. Nodig: secret `UPDATES_SSH_KEY` (een deploy-sleutel die met `rrsync -wo` alleen in die map mag schrijven) en variabele `UPDATES_SSH_HOST` (het origin-IP van web03). Ontbreekt een van beide, dan slaat de stap zichzelf over met een waarschuwing; de GitHub Release staat er dan al.

Stap 4 tot 6 worden overgeslagen als `LOCAL_ACT` is gezet (`bash bin/run-release.sh --act`).

## Update server

`package.xml` verwijst naar `https://updates.hkweb.nl/agentready/updates.xml`. Anders dan bij `pkg_adventcalendar` is er geen download-sleutel: de extensie is publiek. `updates.xml` krijgt `targetplatform` en `php_minimum` uit `scripts.conf` (`UPDATE_TARGETPLATFORM`, `UPDATE_PHP_MINIMUM`); houd die gelijk aan de minima in `package_script.php`.

Eenmalig op de server (web03, tooling `cloudpanel-git-deploy`): de map voor `updates.hkweb.nl/agentready/` en een deploy-sleutel met `rrsync -wo` op die map; de private sleutel als secret `UPDATES_SSH_KEY` in deze repo, `UPDATES_SSH_HOST` als variabele.

## Het pakket installeren

Download `pkg_agentready-{versie}.zip` van de GitHub Release en installeer via *Systeem → Installeren → Extensies*. Bij een eerste installatie zet `package_script.php` de plugin aan; een update laat de keuze van de site staan. Daarna komen updates via Joomla's updatebeheer.

## Hotfix

Een `feature/{issue}-…`-branch vanaf `develop`, PR, en dan `bash bin/run-release.sh` (het volgnummer telt op binnen de week).

## Als run-release.sh halverwege misgaat

Tot de push van `main` staat er niets op GitHub: zet de lokale `main` terug (`git reset --hard origin/main`) en verwijder een lokale tag. Is de tag al gepusht en faalt de workflow, los het op in een nieuwe release; verplaats nooit een gepushte tag.
