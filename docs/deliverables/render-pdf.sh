#!/usr/bin/env bash
# Render a deliverable markdown file to PDF and report the page count.
#
# The design summary is held to five pages, and a word count is not a
# page count — this is the check. Typography is fixed here so a re-render is
# comparable: A4, 18mm margins, 10.5pt serif.
#
#   ./render-pdf.sh design-summary.md
set -euo pipefail

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
src="${1:-design-summary.md}"
cd "$(dirname "$0")"
out="${src%.md}.pdf"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

npx -y marked@latest -i "$src" -o "$work/body.html"

cat > "$work/page.html" <<'CSS'
<style>
@page { size: A4; margin: 18mm; }
body { font-family: Georgia, serif; font-size: 10.5pt; line-height: 1.32; }
h1 { font-size: 16pt; margin: 0 0 6pt; }
h2 { font-size: 13pt; margin: 12pt 0 4pt; }
h3 { font-size: 11pt; margin: 9pt 0 3pt; }
p, ul { margin: 0 0 6pt; }
table { border-collapse: collapse; font-size: 9.5pt; width: 100%; }
td, th { border: 1px solid #999; padding: 2px 5px; }
code { font-size: 9.5pt; }
hr { display: none; }
</style>
CSS
cat "$work/body.html" >> "$work/page.html"

"$CHROME" --headless --disable-gpu --no-sandbox --no-pdf-header-footer \
  --print-to-pdf="$out" "$work/page.html" 2>/dev/null

python3 - "$out" <<'PY'
import re, sys
data = open(sys.argv[1], 'rb').read()
print(f"{sys.argv[1]}: {len(re.findall(rb'/Type\s*/Page[^s]', data))} pages")
PY
