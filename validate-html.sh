#!/bin/bash
# validate-html.sh — Validates HTML files for EBMS review platform rules
# Usage: ./validate-html.sh [file.html ...]
# If no files given, validates all .html files in current directory
#
# Cross-platform: uses awk/sed/grep instead of grep -P (which is GNU-only).

set -uo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

errors=0
warnings=0

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  while IFS= read -r line; do files+=("$line"); done < <(find . -maxdepth 1 -name '*.html' -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/_template/*')
fi

if [ ${#files[@]} -eq 0 ]; then
  echo -e "${YELLOW}No HTML files found.${NC}"
  exit 0
fi

# ── helpers (BSD-compatible) ──
# Extract all data-comment values from a file (one per line, no quotes)
extract_dc() {
  awk 'BEGIN{RS=""} {
    while (match($0, /data-comment="[^"]*"/)) {
      v = substr($0, RSTART, RLENGTH)
      sub(/^data-comment="/, "", v)
      sub(/"$/, "", v)
      print v
      $0 = substr($0, RSTART + RLENGTH)
    }
  }' "$1"
}

# Strip <style>…</style>, <script>…</script>, and HTML comments. Output stays single-line per body element.
strip_non_html() {
  awk '
    BEGIN { in_style=0; in_script=0; in_comment=0 }
    {
      line = $0
      out = ""
      while (length(line) > 0) {
        if (in_comment) {
          p = index(line, "-->")
          if (p == 0) { line=""; break } else { line = substr(line, p+3); in_comment=0 }
        } else if (in_style) {
          p = match(line, /<\/style>/)
          if (p == 0) { line=""; break } else { line = substr(line, RSTART+RLENGTH); in_style=0 }
        } else if (in_script) {
          p = match(line, /<\/script>/)
          if (p == 0) { line=""; break } else { line = substr(line, RSTART+RLENGTH); in_script=0 }
        } else {
          # find earliest opening of style/script/comment
          ps = match(line, /<style[^>]*>/); ps_s = (ps ? RSTART : 0); ps_l = (ps ? RLENGTH : 0)
          pj = match(line, /<script[^>]*>/); pj_s = (pj ? RSTART : 0); pj_l = (pj ? RLENGTH : 0)
          pc = index(line, "<!--"); pc_s = pc; pc_l = 4

          min = 0; kind=""
          if (ps_s > 0 && (min==0 || ps_s < min)) { min=ps_s; kind="style"; ml=ps_l }
          if (pj_s > 0 && (min==0 || pj_s < min)) { min=pj_s; kind="script"; ml=pj_l }
          if (pc_s > 0 && (min==0 || pc_s < min)) { min=pc_s; kind="comment"; ml=pc_l }

          if (min == 0) { out = out line; line="" }
          else {
            out = out substr(line, 1, min-1)
            line = substr(line, min + ml)
            if (kind=="style") in_style=1
            else if (kind=="script") in_script=1
            else in_comment=1
          }
        }
      }
      print out
    }
  ' "$1"
}

for file in "${files[@]}"; do
  echo -e "\n${BOLD}Checking: ${file}${NC}"
  echo "─────────────────────────────────────────"

  file_errors=0
  file_warnings=0

  # ── 1. Self-contained check ──
  local_css=$(grep -nE '<link[^>]+rel="stylesheet"[^>]+href="[^"]+"' "$file" 2>/dev/null | grep -vE 'href="https?://' || true)
  local_js=$(grep -nE '<script[^>]+src="[^"]+"' "$file" 2>/dev/null | grep -vE 'src="https?://' || true)

  if [ -n "$local_css" ]; then
    echo -e "${RED}  ✗ External local CSS file detected:${NC}"
    echo "    $local_css"
    file_errors=$((file_errors + 1))
  fi

  if [ -n "$local_js" ]; then
    echo -e "${RED}  ✗ External local JS file detected:${NC}"
    echo "    $local_js"
    file_errors=$((file_errors + 1))
  fi

  # ── 2. data-comment uniqueness (HTML attributes only, not inside <script>/<style>) ──
  # extract from cleaned body (strip script/style/comments)
  cleaned=$(strip_non_html "$file")
  dc_list=$(printf '%s\n' "$cleaned" | awk '{
    while (match($0, /data-comment="[^"]*"/)) {
      v = substr($0, RSTART, RLENGTH)
      sub(/^data-comment="/, "", v)
      sub(/"$/, "", v)
      print v
      $0 = substr($0, RSTART + RLENGTH)
    }
  }')

  dc_count=$(printf '%s\n' "$dc_list" | grep -c '.' || true)

  if [ "$dc_count" -eq 0 ]; then
    echo -e "${RED}  ✗ No data-comment attributes found at all${NC}"
    file_errors=$((file_errors + 1))
  else
    echo -e "  ℹ Found ${dc_count} data-comment attributes (HTML only, excluding script/style)"

    dupes=$(printf '%s\n' "$dc_list" | sort | uniq -d || true)
    if [ -n "$dupes" ]; then
      echo -e "${RED}  ✗ Duplicate data-comment values:${NC}"
      while IFS= read -r d; do
        [ -z "$d" ] && continue
        count=$(printf '%s\n' "$dc_list" | grep -c "^${d}$" || true)
        echo -e "    ${RED}\"${d}\"${NC} appears ${count} times"
        file_errors=$((file_errors + 1))
      done <<< "$dupes"
    fi

    # empty data-comment=""
    empty_count=$(printf '%s\n' "$cleaned" | grep -o 'data-comment=""' | wc -l | tr -d ' ')
    if [ "$empty_count" -gt 0 ]; then
      echo -e "${RED}  ✗ Found ${empty_count} empty data-comment=\"\" attributes${NC}"
      file_errors=$((file_errors + 1))
    fi
  fi

  # ── 3. Heuristic: visible tags missing data-comment ──
  missing_tags=()
  for tag in h1 h2 h3 h4 h5 h6 button img nav header footer main section; do
    count_total=$(printf '%s\n' "$cleaned" | grep -oE "<${tag}[[:space:]>][^>]*>" 2>/dev/null | wc -l | tr -d ' \n')
    count_with_dc=$(printf '%s\n' "$cleaned" | grep -oE "<${tag}[[:space:]>][^>]*data-comment=\"[^\"]+\"[^>]*>" 2>/dev/null | wc -l | tr -d ' \n')
    count_total=${count_total:-0}
    count_with_dc=${count_with_dc:-0}
    count_without=$(( count_total - count_with_dc ))
    if [ "$count_without" -gt 0 ]; then
      missing_tags+=("${tag}(${count_without})")
    fi
  done

  if [ ${#missing_tags[@]} -gt 0 ]; then
    echo -e "${YELLOW}  ⚠ Elements likely missing data-comment:${NC}"
    echo -e "    ${missing_tags[*]}"
    file_warnings=$((file_warnings + ${#missing_tags[@]}))
  fi

  # ── 4. Google Fonts preconnect ──
  has_gfonts=$(grep -c "fonts.googleapis.com/css" "$file" 2>/dev/null | tr -d '\n'); has_gfonts=${has_gfonts:-0}
  has_preconnect=$(grep -c 'rel="preconnect"' "$file" 2>/dev/null | tr -d '\n'); has_preconnect=${has_preconnect:-0}

  if [ "$has_gfonts" -gt 0 ] && [ "$has_preconnect" -eq 0 ]; then
    echo -e "${YELLOW}  ⚠ Google Fonts used without preconnect hints${NC}"
    file_warnings=$((file_warnings + 1))
  fi

  # ── 5. Basic structure ──
  has_doctype=$(grep -c '<!DOCTYPE html>' "$file" 2>/dev/null | tr -d '\n'); has_doctype=${has_doctype:-0}
  has_charset=$(grep -c 'charset="UTF-8"' "$file" 2>/dev/null | tr -d '\n'); has_charset=${has_charset:-0}
  has_viewport=$(grep -c 'name="viewport"' "$file" 2>/dev/null | tr -d '\n'); has_viewport=${has_viewport:-0}
  has_title=$(grep -cE '<title>.+</title>' "$file" 2>/dev/null | tr -d '\n'); has_title=${has_title:-0}
  has_root_vars=$(grep -c ':root' "$file" 2>/dev/null | tr -d '\n'); has_root_vars=${has_root_vars:-0}

  if [ "$has_doctype" -eq 0 ]; then
    echo -e "${RED}  ✗ Missing <!DOCTYPE html>${NC}"
    file_errors=$((file_errors + 1))
  fi
  if [ "$has_charset" -eq 0 ]; then
    echo -e "${RED}  ✗ Missing charset UTF-8${NC}"
    file_errors=$((file_errors + 1))
  fi
  if [ "$has_viewport" -eq 0 ]; then
    echo -e "${YELLOW}  ⚠ Missing viewport meta tag${NC}"
    file_warnings=$((file_warnings + 1))
  fi
  if [ "$has_title" -eq 0 ]; then
    echo -e "${YELLOW}  ⚠ Missing or empty <title>${NC}"
    file_warnings=$((file_warnings + 1))
  fi
  if [ "$has_root_vars" -eq 0 ]; then
    echo -e "${YELLOW}  ⚠ No :root CSS custom properties found${NC}"
    file_warnings=$((file_warnings + 1))
  fi

  # ── 6. SPA views consistency ──
  view_count=$(printf '%s\n' "$cleaned" | grep -cE 'class="view[^"]*"' 2>/dev/null | tr -d '\n')
  view_count=${view_count:-0}
  if [ "$view_count" -gt 1 ]; then
    echo -e "  ℹ SPA detected: ${view_count} views"

    views_without_dc=$(printf '%s\n' "$cleaned" | grep -oE '<[a-zA-Z]+[^>]*class="view[^"]*"[^>]*>' 2>/dev/null | grep -vc 'data-comment=' | tr -d '\n')
    views_without_dc=${views_without_dc:-0}
    if [ "$views_without_dc" -gt 0 ]; then
      echo -e "${RED}  ✗ ${views_without_dc} view(s) missing data-comment${NC}"
      file_errors=$((file_errors + 1))
    fi

    has_navigate=$(grep -c 'function navigate' "$file" 2>/dev/null | tr -d '\n')
    has_navigate=${has_navigate:-0}
    if [ "$has_navigate" -eq 0 ]; then
      echo -e "${YELLOW}  ⚠ SPA views found but no navigate() function${NC}"
      file_warnings=$((file_warnings + 1))
    fi
  fi

  # ── Summary ──
  if [ "$file_errors" -eq 0 ] && [ "$file_warnings" -eq 0 ]; then
    echo -e "${GREEN}  ✓ All checks passed${NC}"
  else
    [ "$file_errors" -gt 0 ] && echo -e "${RED}  ${file_errors} error(s)${NC}"
    [ "$file_warnings" -gt 0 ] && echo -e "${YELLOW}  ${file_warnings} warning(s)${NC}"
  fi

  errors=$((errors + file_errors))
  warnings=$((warnings + file_warnings))
done

echo ""
echo "═══════════════════════════════════════════"
if [ "$errors" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}✓ All files valid${NC} (${warnings} warning(s))"
  exit 0
else
  echo -e "${RED}${BOLD}✗ Validation failed: ${errors} error(s), ${warnings} warning(s)${NC}"
  echo -e "${RED}  Fix errors before committing.${NC}"
  exit 1
fi
