#!/bin/zsh
# Extracts a lecture's audio (16 kHz mono WAV) and captions (VTT) from a saved Illinois MediaSpace
# (Kaltura) page. In the browser: open the lecture, press play once, then copy the <html> element
# from Inspect into a file (the signed stream URLs only appear after playback starts).
# Usage: Scripts/fetch-mediaspace.sh page.html out-name   → TestData/out-name.{wav,vtt}
set -euo pipefail
page="$1"; name="${2:-lecture}"; out="$(dirname "$0")/../TestData"; mkdir -p "$out"
manifest=$(grep -oE 'https://www\.kaltura\.com/p/[0-9]+/sp/[0-9]+/playManifest/entryId/[^"'"'"' <>]*a\.m3u8[^"'"'"' <>]*' "$page" \
  | head -1 | sed 's/&amp;/\&/g')
[[ -n "$manifest" ]] || { echo "No playManifest URL found — press play before saving the page." >&2; exit 1; }
master=$(curl -sfL "$manifest")
flavor=$(echo "$master" | grep -m1 '^https')   # lowest bitrate is plenty for audio
ffmpeg -hide_banner -loglevel error -y -i "$flavor" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$out/$name.wav"
subs=$(echo "$master" | grep 'TYPE=SUBTITLES' | grep -oE 'URI="[^"]+"' | head -1 | sed 's/URI="//;s/"$//' || true)
if [[ -n "$subs" ]]; then
  base=${subs%/a.m3u8}; : > "$out/$name.vtt"
  for i in $(curl -sfL "$subs" | grep -oE 'segmentIndex/[0-9]+' | cut -d/ -f2); do
    curl -sfL "$base/segmentIndex/$i.vtt" >> "$out/$name.vtt"; echo >> "$out/$name.vtt"
  done
fi
ls -lh "$out/$name".*
