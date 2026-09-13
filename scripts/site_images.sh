#!/bin/sh
# Builds the images the product page (site/) uses: the app icon at 512px and, per
# language, a handful of 6.9" screenshots as WebP under site/img/<lang>/.
#
#   scripts/site_images.sh                      # all three languages from screenshots/
#   scripts/site_images.sh build/site-shots     # from a single-device run, e.g.
#       make shots-device DEVICE="iPhone 17 Pro Max" LANG_ID=en OUT=build/site-shots/en
#
# The source root must hold <lang>/<name>.png (screenshots/ adds an iphone-6.9/
# level, which the loop below tolerates). 720px wide is enough for the 16rem
# column at 3x; -sharp_yuv keeps text edges clean, which the default chroma
# subsampling smears on UI screenshots.
set -u
ROOT=${1:-screenshots}
sips -Z 512 NovelReader/Assets.xcassets/AppIcon.appiconset/AppIcon.png --out site/icon.png >/dev/null
for lang in zh-Hant zh-Hans en; do
	src="$ROOT/$lang"
	[ -d "$src/iphone-6.9" ] && src="$src/iphone-6.9"
	out="site/img/$lang"
	mkdir -p "$out"
	for pair in 00-recent=recent 02-book=book 03-reader=reader 05-reading-settings=settings 09-comic-reader=comic; do
		png="$src/${pair%%=*}.png"
		if [ ! -f "$png" ]; then
			echo "missing $png" >&2
			continue
		fi
		cwebp -quiet -q 82 -sharp_yuv -resize 720 0 "$png" -o "$out/${pair##*=}.webp"
	done
done
du -sh site/img/*/ site/icon.png
