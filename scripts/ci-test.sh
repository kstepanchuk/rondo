#!/bin/bash
# End-to-end tests, run locally and in CI: ./scripts/ci-test.sh [path/to/Rondo]
# Builds sample files with tools that ship with macOS (plus ffmpeg if installed),
# runs every operation on them and checks the command line, data and encodings.
set -euo pipefail
cd "$(dirname "$0")/.."
R="${1:-.build/debug/Rondo}"
[ -x "$R" ] || swift build
S="$(mktemp -d)/samples"; mkdir -p "$S"
pass=0; fail=0
ok()   { echo "  ✓ $1"; pass=$((pass + 1)); }
bad()  { echo "  ✗ $1"; fail=$((fail + 1)); }
# pipefail off inside checks: `grep -q` closing the pipe early isn't a failure.
check() { if (set +o pipefail; eval "$2"); then ok "$1"; else bad "$1"; fi; }

echo "== Samples"
printf 'P3\n2 2\n255\n255 0 0  0 255 0\n0 0 255  255 255 255\n' > "$S/tiny.ppm"
sips -s format png -z 600 800 "$S/tiny.ppm" --out "$S/photo.png" >/dev/null
rm "$S/tiny.ppm"
sips -s format pdf "$S/photo.png" --out "$S/doc.pdf" >/dev/null
printf 'Привет, Rondo!\n\nТест.\n' > "$S/note.txt"
textutil -convert docx "$S/note.txt" -output "$S/report.docx"
printf '1\n00:00:01,000 --> 00:00:02,500\nПривет\n' > "$S/subs.srt"
printf '[{"name":"Анна","age":31,"tags":["a","b"]},{"name":"Bob","age":42,"tags":[]}]' > "$S/team.json"
if command -v ffmpeg >/dev/null; then
  ffmpeg -loglevel error -f lavfi -i testsrc=size=640x360:rate=25 -f lavfi -i sine=frequency=440 -t 3 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac "$S/video.mp4"
  ffmpeg -loglevel error -i "$S/video.mp4" -vn "$S/voice.wav"
fi
ls "$S"

echo "== Self-test (every operation on every sample)"
if "$R" --self-test "$S" --ci > "$S/../selftest.log" 2>&1; then
  ok "self-test: $(grep -c '^ok' "$S/../selftest.log") operations"
else
  grep -E "FAIL" "$S/../selftest.log" || true; bad "self-test"
fi

echo "== Command line"
O="$(mktemp -d)"; cp "$S/photo.png" "$O/"
check "rondo convert --to jpg" '"$R" convert --to jpg "$O/photo.png" >/dev/null && [ -s "$O/photo.jpg" ]'
check "rondo list" '"$R" list "$O/photo.png" | grep -q "img-JPG"'
check "rondo formats" '"$R" formats | grep -q "MP4\|JPG"'
check "rondo info" '"$R" info "$O/photo.png" | grep -q "800 × 600"'
check "unknown format fails" '! "$R" convert --to xyz "$O/photo.png" >/dev/null 2>&1'
check "fit under 1 MB" '"$R" run fit-1 "$O/photo.png" >/dev/null && [ "$(stat -f %z "$O"/photo*1*.jpg)" -le 1000000 ]'

echo "== Data and encodings"
D="$(mktemp -d)"; cp "$S/team.json" "$D/"
"$R" convert --to yaml "$D/team.json" >/dev/null
mv "$D/team.json" "$D/orig.json"
"$R" convert --to json "$D/team.yaml" >/dev/null
check "JSON → YAML → JSON is lossless" 'python3 -c "import json,sys; sys.exit(json.load(open(\"$D/orig.json\")) != json.load(open(\"$D/team.json\")))"'
"$R" convert --to xlsx "$D/orig.json" >/dev/null
check "JSON → XLSX writes a valid workbook" 'unzip -l "$D/orig.xlsx" | grep -q "xl/worksheets/sheet1.xml"'
"$R" run d-json "$D/orig.xlsx" --out "$D/x" >/dev/null
check "XLSX → JSON keeps Cyrillic" 'grep -q "Анна" "$D/x/orig.json"'
printf 'Съешь же ещё этих мягких французских булок\n' | iconv -f UTF-8 -t WINDOWS-1251 > "$D/cp1251.txt"
printf 'Съешь же ещё этих мягких французских булок\n' | iconv -f UTF-8 -t KOI8-R > "$D/koi8.txt"
"$R" run utf8 "$D/cp1251.txt" "$D/koi8.txt" >/dev/null
check "Windows-1251 → UTF-8" 'grep -q "французских" "$D/cp1251 (UTF-8).txt"'
check "KOI8-R → UTF-8" 'grep -q "французских" "$D/koi8 (UTF-8).txt"'

echo "== v0.2.1 tools"
T="$(mktemp -d)"
"$R" run merge "$S/photo.png" "$S/doc.pdf" --out "$T" >/dev/null 2>&1 || true
P="$(ls "$T"/*.pdf 2>/dev/null | head -1)"
check "PDF: keep pages" '"$R" pages keep 1 "$P" >/dev/null && "$R" info "$T"/*pages*.pdf | grep -q "Страниц: 1\|Pages: 1"'
check "PDF: watermark" '"$R" watermark DRAFT "$P" >/dev/null && [ -s "$(ls "$T"/*watermarked*.pdf)" ]'
check "PDF: page numbers" '"$R" run pdf-num "$P" >/dev/null'
mkdir -p "$T/folder"
check "custom folder icon" '"$R" icon "$S/photo.png" "$T/folder" >/dev/null && ls -a "$T/folder" | grep -q "^Icon"'
if command -v ffmpeg >/dev/null; then
  cp "$S/video.mp4" "$T/a.mp4"; cp "$S/video.mp4" "$T/b.mp4"
  check "join videos" '"$R" run join "$T/a.mp4" "$T/b.mp4" --out "$T/j" >/dev/null && [ -s "$T/j/"*.mp4 ]'
  check "rewrap MP4 → MOV" '"$R" run remux "$T/a.mp4" --out "$T/r" >/dev/null && [ -s "$T/r/a.mov" ]'
  ffmpeg -loglevel error -f lavfi -i sine=f=440 -t 1 -c:a libmp3lame "$T/song.mp3"
  check "audio tags and cover" '"$R" tags "$T/song.mp3" --title "Ёжик" --cover "$S/photo.png" >/dev/null && ffprobe -v error -show_entries format_tags=title -of csv=p=0 "$T/song tagged.mp3" | grep -q "Ёжик"'
fi
if command -v cwebp >/dev/null; then
  check "WebP" '"$R" convert --to webp "$S/photo.png" --out "$T/w" >/dev/null && [ -s "$T/w/photo.webp" ]'
fi

if [ -d dist/Rondo.app ]; then
  echo "== App bundle"
  check "Shortcuts actions in the bundle" 'grep -q "ConvertToJPEGIntent" dist/Rondo.app/Contents/Resources/Metadata.appintents/extract.actionsdata'
  check "code signature" 'codesign --verify --deep --strict dist/Rondo.app'
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
