# Agent Ready voor Joomla — ontwerp

Datum: 2026-11-07 · Issue: #1 · Status: goedgekeurd voor bouw (opdracht uit de momentsuntil-sessie)

## Aanleiding

momentsuntil.com (Joomla 6, mu-template, Cloudflare Free) faalt op isitagentready.com voor
`markdownNegotiation`. Cloudflare's eigen *Markdown for Agents* vraagt een Pro-plan. Deze plugin doet
hetzelfde aan de origin en is herbruikbaar op elke Joomla 5.3+/6-site.

## Doel

Een system-plugin die een site-HTML-pagina als Markdown teruggeeft wanneer de client daar met
`Accept: text/markdown` om vraagt. Gedrag en uitvoerformaat volgen Cloudflare
(<https://developers.cloudflare.com/fundamentals/reference/markdown-for-agents/>), de check is
<https://isitagentready.com/.well-known/agent-skills/markdown-negotiation/SKILL.md>.

### Niet-doelen

- Geen eigen `.md`-URL's, geen llms.txt (staat al in de mu-template), geen robots.txt.
- Geen echte tokenizer: `x-markdown-tokens` is een schatting.
- Geen conversie in de administrator, voor API- of andere formats.

### Anti-doelen (dan is het mislukt, ook al werkt het)

- Een browser of crawler zonder `text/markdown` in de Accept-header krijgt ooit Markdown (bijv. uit
  de pagecache of Cloudflare).
- Persoonlijke inhoud van ingelogde gebruikers belandt in een Markdown-antwoord.
- De plugin breekt de HTML-pagina als de conversie faalt.

## Gedrag

1. **Onderhandeling** (`AcceptHeader`): Markdown alleen bij een expliciete `text/markdown` met q > 0
   en een q die minstens zo hoog is als die van HTML (`text/html`, anders `text/*`, anders `*/*`).
   `text/*` en `*/*` tellen niet als vraag om Markdown. Zonder Accept-header: HTML.
2. **Voorwaarden**: site-client, methode GET of HEAD, document van het type `html`, status 200.
   Instelbaar (default aan): niet voor ingelogde gebruikers, niet voor pagina's met `noindex`
   (robots-metadata van het document of een `X-Robots-Tag`-header).
3. **Conversie** in `onAfterRender` met lage prioriteit (na andere plugins die de body aanpassen):
   - Parse de body met `DOMDocument` (UTF-8).
   - Metadata voor de YAML-frontmatter: `title` (`meta name=title` → `og:title` → `<title>`),
     `description` (`meta name=description` → `og:description`), `image` (`og:image`). Alleen velden
     met een waarde; geen frontmatter als ze alle leeg zijn. Waarden als JSON-string (geldige YAML).
   - JSON-LD: alle `<script type="application/ld+json">` uit het hele document, in één
     ```` ```json ````-blok aan het eind, elk op een eigen regel.
   - Hoofdcontent: het eerste element dat matcht met de instelbare selectorlijst
     (default `main, [role=main], article, body`).
   - Daarbinnen weg: instelbare selectorlijst (default scripts, styles, svg, formulieren, knoppen,
     nav, dialog, `[hidden]`, `[aria-hidden=true]`). Extra selectors voor bijv. een cookiebanner.
   - Relatieve `href`/`src` worden absoluut (tegen de URL van de pagina), want een agent heeft de
     context van de pagina niet.
   - HTML → Markdown met `league/html-to-markdown` (ATX-koppen, `-`-lijsten, tabellen).
4. **Antwoord**: body = frontmatter + Markdown + JSON-LD.
   Headers: `Content-Type: text/markdown; charset=utf-8`, `Vary` met `Accept` (bestaande Vary-waarden
   blijven), `x-markdown-tokens` (schatting: tekens / 4, naar boven), optioneel `Content-Signal`
   (instelling, default leeg). `ETag` en `Content-Length` vervallen. Overige headers (CSP, HSTS,
   Cache-Control) blijven.
5. **HTML-antwoorden** van site-pagina's krijgen ook `Vary: Accept` (instelbaar, default aan), zodat
   een cache de twee varianten scheidt.
6. **Fout**: een exception of lege uitkomst laat de HTML staan en wordt gelogd (categorie
   `agentready`).

## Caching

- **Joomla-pagecache** (`plg_system_cache`): de sleutel is de URL plus wat `onPageCacheGetKey`
  teruggeeft. De plugin geeft daar `agentready:markdown` terug als Markdown gevraagd is, en
  niets anders (HTML-sleutels blijven gelijk). De cache bewaart de headers mee, dus een cache-hit
  geeft ook het juiste `Content-Type`.
- **Cloudflare Free** cachet HTML standaard niet. Met een *Cache Everything*-regel negeert Cloudflare
  `Vary: Accept` voor HTML; dan is een cacheregel nodig die verzoeken met `text/markdown` in de
  Accept-header niet uit de cache bedient. Staat in de README.

## Converter: library of eigen code — keuze

Gekozen: **`league/html-to-markdown` ^5.2, gebundeld in `vendor/` van de plugin** (zoals
`com_adventcalendar` Dompdf bundelt).

- Licentie MIT: verenigbaar met de GPL-2.0-or-later van de plugin; licentiebestand gaat mee.
- Volwassen en breed gebruikt (thephpleague), dekt de lastige gevallen die een eigen converter
  opnieuw moet uitvinden: geneste lijsten, tabellen, code-blokken, escapen van Markdown-tekens,
  witruimte.
- Alleen `ext-dom` en `ext-xml`, die Joomla zelf al nodig heeft; pure PHP, ~100 kB, geen
  composer-stap op de site: de zip bevat de vendor-map.
- Wat de library niet doet (selectie van de hoofdcontent, weglaten van elementen, metadata,
  JSON-LD, absolute URL's) is eigen, kleine en testbare code rond `DOMDocument`.
- Risico: een andere extensie laadt een andere versie van dezelfde namespace. Klein (Joomla zelf
  bundelt de library niet); de autoloader wordt pas geladen als er echt geconverteerd wordt.

Een eigen DOM-naar-Markdown-converter is afgewezen: meer code om te onderhouden, en juist de
randgevallen van Markdown-escaping zijn waar die fout gaat.

## Selectors

Joomla bundelt geen CSS-selector-component. Een kleine eigen vertaling CSS → XPath ondersteunt:
`tag`, `*`, `#id`, `.class`, `[attr]`, `[attr=waarde]`, samengestelde selectors, de afstammeling-
(spatie) en kind-combinator (`>`) en komma-lijsten. Onbekende syntaxis wordt overgeslagen, niet fataal.

## Repo en build

Repo `hans2103/plg_system_agentready` (publiek), opgezet als `hkweb_adventcalendar`:
`Src/`-layout, byte-identieke `bin/`, `scripts.conf`, `package.sh`, `package.xml` als enige
versiebron, release-workflow met updates.xml en de update server
`https://updates.hkweb.nl/agentready/`, AIdocs, CLAUDE.md, main/develop. De tooling in `bin/`
gaat uit van een Joomla-*package*, dus de plugin komt in `pkg_agentready` (één plugin); een
publieke extensie heeft geen download-sleutel (`dlid`). De installatie zet de plugin aan.

## Eigen keuzes (door de bouwer, niet door Hans)

- Package-omhulsel rond de plugin (volgt uit `bin/add-update-entry.php`, dat `type=package` schrijft).
- Namespace `HKweb\Plugin\System\AgentReady`, licentie GPL-2.0-or-later.
- Bij gelijke q wint Markdown; `text/*` en `*/*` vragen geen Markdown.
- Frontmatter neemt `<title>` als laatste terugval (Cloudflare doet dat niet).
- Tokenschatting tekens/4.
- Plugin wordt bij een eerste installatie ingeschakeld.

## Samenvoeging met plg_system_agentready (2026-11-07)

Op verzoek van Hans (via de sessie "Gehandicapten Valkenswaard site testing") is deze plugin
samengevoegd met de `plg_system_agentready` die daar voor gehandicaptenvalkenswaard.nl was gemaakt.
Naam: **Agent Ready** (`pkg_agentready`, `plg_system_agentready`, namespace
`HKweb\Plugin\System\AgentReady`, update server `https://updates.hkweb.nl/agentready/`): de plugin
doet Markdown én agent-discovery, en sluit aan bij isitagentready.com.

- Basis blijft dit ontwerp (selector, extractor, league/html-to-markdown, de voorwaarden, caching).
- Erbij: **Link-headers** (RFC 8288) op HTML-pagina's, één samengevoegde `Link`-header (bestaande
  links van andere plugins blijven, dubbele URI+rel vallen weg), elk onderdeel met een eigen
  instelling plus een hoofdschakelaar: `llms.txt` en `.well-known/agent-skills/index.json`
  (`rel=describedby`, alleen als het bestand in de site-root staat), de sitemap (`rel=sitemap`,
  URL als instelling, leeg = weg) en de Markdown-versie (`rel=alternate`, alleen als Markdown aan staat).
- Markdown krijgt een eigen aan/uit-schakelaar.
- Regressiegevallen van echte pagina's als tests: klikbare kaart (link om blokken → één link,
  woorden met spatie), naam en functie in losse elementen (spatie ertussen), `<br>` als harde
  regelafbreking (ook in een blockquote), decoratieve afbeelding (`alt=""`) weg, `#`- en
  `javascript:`-links worden tekst, JSON-LD in `<main>` geen tekst.
- Bewust niet in de plugin: WebMCP, de agent-skills-index zelf, llms.txt en Content-Signal in
  robots.txt: dat is site-inhoud.

## Gevonden tijdens de bouw

- Joomla's eigen gzip (`compress()`) voegt `Vary: Accept-Encoding` als tweede waarde toe, en
  `sendHeaders()` stuurt elke waarde met `header(…, replace: true)`: alleen de laatste blijft over.
  De plugin zet Joomla's gzip daarom uit voor front-end-HTML-pagina's (in `onAfterRoute`, vóór
  `plg_system_cache` een pagina uit de cache serveert); de webserver of CDN comprimeert. Kandidaat
  voor een melding bij Joomla.
- league/html-to-markdown laat HTML-entiteiten (`&amp;`) staan en laat witruimte-regels achter;
  `MarkdownRenderer::tidy()` ruimt dat op buiten code-blokken.
