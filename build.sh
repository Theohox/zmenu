#!/usr/bin/env bash
# ============================================================
#  zmenu build script
#  Concatenates src/*.sh into a single distributable zmenu.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
OUT_FILE="${SCRIPT_DIR}/zmenu.sh"

# ── Header ─────────────────────────────────────────────────
echo "Building zmenu..."

# Create output with shebang and build timestamp
{
    echo '#!/usr/bin/env bash'
    echo "# ============================================================"
    echo "#  Z-MENU  —  Built $(date '+%Y-%m-%d %H:%M:%S')"
    echo "#  Auto-generated from src/*.sh — edit sources, not this file"
    echo "#  Build: ./build.sh"
    echo "# ============================================================"
    echo ""
} > "$OUT_FILE"

# ── Concatenate all source files in order ──────────────────
for src in "${SRC_DIR}"/*.sh; do
    [[ -f "$src" ]] || continue
    fname="$(basename "$src")"
    echo "  + ${fname}"
    {
        echo ""
        echo "# ═══════════════════════════════════════════════════════════"
        echo "#  MODULE: ${fname}"
        echo "# ═══════════════════════════════════════════════════════════"
        echo ""
        cat "$src"
    } >> "$OUT_FILE"
done

# ── Verify syntax ──────────────────────────────────────────
if ! bash -n "$OUT_FILE"; then
    echo "  ✗ Syntax errors detected!"
    exit 1
fi

# ── Navigation validation ──────────────────────────────────
python3 - <<PYEOF
import sys

with open("$OUT_FILE", 'r') as f:
    lines = f.readlines()

errors = []

def find_block_end(start):
    """Find matching 'done' for a block starting with 'while true; do',
    accounting for nested do/done (for/while/until)."""
    depth = 1
    for j in range(start + 1, len(lines)):
        stripped = lines[j].strip()
        # Count new do blocks (for ...; do, while ...; do, until ...; do)
        if any(stripped.startswith(kw) for kw in ['for ', 'while ', 'until ']):
            if '; do' in stripped or stripped.endswith(' do'):
                depth += 1
        elif stripped == 'do':
            depth += 1
        elif stripped == 'done':
            depth -= 1
            if depth == 0:
                return j
    return len(lines) - 1

def has_escape(read_line, block_end):
    """Check if there's a break, return, or exit after read_line within block."""
    for j in range(read_line, block_end):
        stripped = lines[j].strip()
        if stripped.startswith('break') or stripped.startswith('return') or stripped.startswith('exit'):
            return True
        words = stripped.split()
        if 'break' in words or 'return' in words or 'exit' in words:
            return True
    return False

# Check 1: AI_BACKEND_ACTIVE conditional must not wrap Back/Export hints
for i, line in enumerate(lines):
    if 'if [[' in line and 'AI_BACKEND_ACTIVE' in line:
        indent = len(line) - len(line.lstrip())
        for j in range(i+1, min(i+6, len(lines))):
            next_line = lines[j].rstrip()
            if not next_line or next_line.strip().startswith('#'):
                continue
            next_indent = len(next_line) - len(next_line.lstrip())
            if next_indent == indent and 'echo' in next_line and ('Back' in next_line or 'Export' in next_line):
                errors.append(f"Line {j+1}: Footer wrapped in AI_BACKEND_ACTIVE conditional")
                break
            if next_indent == indent and next_line.strip() == 'fi':
                break
            if next_indent > indent:
                break

# Check 2 & 3: while true menus need back option and escape
for i, line in enumerate(lines):
    if 'while true; do' in line:
        block_end = find_block_end(i)
        reads = []
        for j in range(i+1, block_end):
            if 'read -rp' in lines[j]:
                reads.append(j)
        if not reads:
            continue
        # Check visible back option before the FIRST read in this menu
        first_read = reads[0]
        found_back = False
        for j in range(max(i, first_read-15), first_read):
            if 'Back' in lines[j] or 'back' in lines[j]:
                found_back = True
                break
        if not found_back:
            errors.append(f"Line {first_read+1}: Menu read without visible back option")
        # Check escape exists after the LAST read (covers nested reads inside cases)
        last_read = reads[-1]
        if not has_escape(last_read, block_end):
            errors.append(f"Lines {i+1}-{block_end+1}: while true menu has no break/return/exit")

if errors:
    print("")
    print("  ✗ NAVIGATION VALIDATION FAILED:")
    for e in errors:
        print(f"     {e}")
    sys.exit(1)
else:
    print("  ✓ Navigation validation passed")
PYEOF

# ── Success ────────────────────────────────────────────────
echo ""
echo "  ✓ Syntax OK"
lines=$(wc -l < "$OUT_FILE")
echo "  ✓ Output: ${OUT_FILE} (${lines} lines)"
chmod +x "$OUT_FILE"
