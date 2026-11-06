#!/usr/bin/env bash
# One-time conversion of the SEG spec PDFs to page-marked plain text.
# Output is committed under "SEG Spec/text/" so this never needs re-running
# (and no session ever needs to load the PDFs). Requires poppler-utils.
set -euo pipefail
cd "$(dirname "$0")/../SEG Spec"
mkdir -p text
for f in *.pdf; do
  b="${f%.pdf}"
  pdftotext -layout "$f" - | awk 'BEGIN{p=1; print "=== PAGE 1 ==="}
    { n=split($0, parts, "\f"); for(i=1;i<=n;i++){ if(i>1){p++; print "=== PAGE " p " ==="} if(parts[i]!="" || i==1) print parts[i] } }' > "text/$b.txt"
done
