#!/bin/bash
# Test voor bin/check-manifests.php op een wegwerpkopie. Gebruik: bash tests/shell/test_check_manifests.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

copy_repo "$tmp/copy"
cm() { ( cd "$tmp/copy" && php bin/check-manifests.php --src="$SRC_DIR" ${built_args[@]+"${built_args[@]}"} "${EXTENSION_MANIFESTS[@]}" ); }

expect "schone kopie" 0 cm
has "  meldt overeenstemming" 'komen overeen'

# Een extra bestand in de map van het eerste manifest (het component: die map zit in <files>)
dir="$(dirname "$tmp/copy/${EXTENSION_MANIFESTS[0]}")"
touch "$dir/verdwaald.txt"
run cm; same "extra bestand naast $(basename "${EXTENSION_MANIFESTS[0]}")" 1 "$rc"; has "  benoemd" 'verdwaald\.txt staat op schijf maar niet in het manifest'
rm -f "$dir/verdwaald.txt"

# Een vergeten map in het manifest: een genoemd item dat niet bestaat
m="$tmp/copy/${EXTENSION_MANIFESTS[0]}"
perl -0pi -e 's#</files>#<filename>spook.php</filename></files>#' "$m"   # alleen het eerste voorkomen
run cm; same "genoemd bestand dat niet bestaat" 1 "$rc"; has "  benoemd" 'spook\.php staat in het manifest maar niet op schijf'
reset_copy "$tmp/copy"

# Een nieuwe map naast bestaande secties
mkdir "$tmp/copy/$(dirname "${EXTENSION_MANIFESTS[0]}")/nieuwemap"
run cm; same "niet-genoemde nieuwe map" 1 "$rc"; has "  benoemd" 'nieuwemap staat op schijf maar niet in het manifest'
reset_copy "$tmp/copy"

# CLAUDE.md-verwijzingen en verborgen bestanden hoeven niet in het manifest
dir="$(dirname "$tmp/copy/${EXTENSION_MANIFESTS[0]}")"
echo x > "$dir/CLAUDE.md"; echo x > "$dir/.DS_Store"
expect "CLAUDE.md en verborgen bestanden worden genegeerd" 0 cm
reset_copy "$tmp/copy"

# Een template zet <media folder="media"> in de zip, maar in Src staan de media onder
# media/{destination}, net als bij het component (issue #138).
tdir="$tmp/copy/$SRC_DIR/templates/demo"; mdir="$tmp/copy/$SRC_DIR/media/templates/site/demo"
mkdir -p "$tdir" "$mdir/css"
touch "$tdir/index.php" "$mdir/css/main.css"
cat > "$tdir/templateDetails.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<extension type="template" client="site" method="upgrade">
	<name>demo</name>
	<files><filename>index.php</filename></files>
	<media destination="templates/site/demo" folder="media"><folder>css</folder></media>
</extension>
XML
tm() { ( cd "$tmp/copy" && php bin/check-manifests.php --src="$SRC_DIR" "$SRC_DIR/templates/demo/templateDetails.xml" ); }
expect "template-media onder Src/media/{destination}" 0 tm
mkdir "$mdir/js"
run tm; same "niet-genoemde map in de template-media" 1 "$rc"; has "  benoemd" 'media/js staat op schijf maar niet in het manifest'
rm -rf "$mdir"
run tm; same "template-media ontbreken helemaal" 1 "$rc"; has "  benoemd" 'map media bestaat niet'
reset_copy "$tmp/copy"

# Een map die de build maakt (BUILT_DIRS, bijv. een library-vendor/) staat niet in git: met
# --built mag hij ontbreken, zonder niet. Een andere ontbrekende map blijft een fout.
pdir="$tmp/copy/$SRC_DIR/plugins/demo/gebouwd"
mkdir -p "$pdir"
touch "$pdir/gebouwd.php"
cat > "$pdir/gebouwd.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<extension type="plugin" group="demo" method="upgrade">
	<name>gebouwd</name>
	<files><filename plugin="gebouwd">gebouwd.php</filename><folder>vendor</folder></files>
</extension>
XML
bm() { ( cd "$tmp/copy" && php bin/check-manifests.php --src="$SRC_DIR" "$@" "$SRC_DIR/plugins/demo/gebouwd/gebouwd.xml" ); }
run bm; same "gebouwde map ontbreekt zonder --built" 1 "$rc"; has "  benoemd" 'vendor staat in het manifest maar niet op schijf'
expect "gebouwde map ontbreekt met --built" 0 bm --built="./$SRC_DIR/plugins/demo/gebouwd/vendor/"
run bm --built="$SRC_DIR/plugins/demo/gebouwd/anders"; same "--built voor een andere map helpt niet" 1 "$rc"
reset_copy "$tmp/copy"

expect "ontbrekend manifest" 2 bash -c "cd '$tmp/copy' && php bin/check-manifests.php bestaat-niet.xml"
expect "zonder argumenten" 2 php "$repo/bin/check-manifests.php"
printf '<extension' > "$tmp/kapot.xml"
expect "kapotte XML" 1 bash -c "cd '$tmp' && php '$repo/bin/check-manifests.php' kapot.xml"

finish
