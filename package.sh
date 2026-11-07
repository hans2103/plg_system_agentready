#!/bin/bash
# Buildscript voor het Agent Ready-pakket (pkg_agentready).
# Gebruik: ./package.sh [versie]
# Zonder argument wordt de versie uit package.xml gelezen; met argument (JJ.WW.N) worden versie
# en datum in package.xml en het plugin-manifest gestempeld en __DEPLOY_VERSION__ vervangen.
# Werkt onder macOS bash 3.2: geen mapfile, geen associatieve arrays.
set -eo pipefail

baseDir=$(pwd)
[ -f "${baseDir}/package.xml" ] || { echo "Draai package.sh vanuit de root van de repo." >&2; exit 1; }

name=agentready
srcDir=${baseDir}/Src
packageDir=${baseDir}/packages
pluginDir=${srcDir}/plugins/system/${name}
packageName=pkg_${name}
pluginZipName=plg_system_${name}.zip

# Manifesten waarin versie en datum worden gestempeld.
manifests=(
  "${baseDir}/package.xml"
  "${pluginDir}/${name}.xml"
)

# Uitsluitpatronen: één zip-patroon per regel in .deployignore, gedeeld met bin/preflight.sh.
exclude=()
while IFS= read -r pattern || [ -n "${pattern}" ]; do
  case "${pattern}" in ''|'#'*) continue ;; esac
  exclude+=("${pattern}")
done < "${baseDir}/.deployignore"
[ ${#exclude[@]} -gt 0 ] || exclude=('*.DS_Store')

stamp() { # bestand versie datum
  sed -i.bak -E "s#<version>[^<]+</version>#<version>${2}</version>#; s#<creationDate>[^<]+</creationDate>#<creationDate>${3}</creationDate>#" "${1}"
  rm -f "${1}.bak"
}

if [ -n "${1:-}" ]; then
  version="${1}"
  [[ "${version}" =~ ^[0-9]{2}\.[0-9]{1,2}\.[0-9]+$ ]] || { echo "Ongeldig versienummer '${version}' (verwacht JJ.WW.N)" >&2; exit 1; }
  creationDate=$(TZ=Europe/Amsterdam date +%Y-%m-%d)
  for manifest in "${manifests[@]}"; do
    stamp "${manifest}" "${version}" "${creationDate}"
  done
  echo "Versie ${version} en creationDate ${creationDate} gestempeld in package.xml en het plugin-manifest"
  # Nieuwe code krijgt @since __DEPLOY_VERSION__; bij de release wordt dat deze versie.
  deployVersionCount=0
  while IFS= read -r deployVersionFile; do
    sed -i.bak "s#__DEPLOY_VERSION__#${version}#g" "${deployVersionFile}"
    rm -f "${deployVersionFile}.bak"
    deployVersionCount=$((deployVersionCount + 1))
  done < <(grep -rlI '__DEPLOY_VERSION__' "${srcDir}" "${baseDir}/package_script.php" || true)
  [ "${deployVersionCount}" -eq 0 ] || echo "__DEPLOY_VERSION__ vervangen door ${version} in ${deployVersionCount} bestand(en)"
else
  version=$(grep -m1 '<version>' "${baseDir}/package.xml" | sed -E 's#.*<version>([^<]+)</version>.*#\1#')
fi

[ -f "${pluginDir}/vendor/autoload.php" ] || { echo "vendor/ ontbreekt in ${pluginDir}: draai daar composer install." >&2; exit 1; }

echo "Agent Ready-pakket bouwen, versie ${version}"
echo "=================================================="

versionDir="${packageDir}/${version}"
rm -rf "${versionDir}"
mkdir -p "${versionDir}"

# Plugin: de inhoud van de pluginmap in de root van de zip.
(cd "${pluginDir}" && zip -q -r "${versionDir}/${pluginZipName}" . -x "${exclude[@]}")
echo "${pluginZipName} gemaakt"

# Pakket: manifest, installer-script, pakkettaal en de plugin-zip.
cp "${baseDir}/package.xml" "${versionDir}/${packageName}.xml"
cp "${baseDir}/package_script.php" "${versionDir}/package_script.php"
for tag in en-GB nl-NL; do
  # Joomla laadt de pakkettaal tijdens installeren uit <zip>/language/{tag}/.
  mkdir -p "${versionDir}/language/${tag}"
  cp "${srcDir}/language/${tag}/${packageName}.sys.ini" "${versionDir}/language/${tag}/"
done

(cd "${versionDir}" && zip -m -q -r "${packageName}-${version}.zip" \
    "${packageName}.xml" package_script.php language "${pluginZipName}" \
    -x "${exclude[@]}")

echo
echo "Pakket klaar: ${versionDir}/${packageName}-${version}.zip"
