#!/usr/bin/env bash
#
# narsese2viz.sh - Translate NARSESE to JSON and optionally send to visualizer.
#
# Usage:
#   ./narsese2viz.sh file.narsese [--output-json] [--send] [--delay ms] [--concurrency N]
#
# Examples:
#   ./narsese2viz.sh narseses.head.txt.nal.txt --output-json
#   ./narsese2viz.sh file.txt --send --concurrency 10
#   ./narsese2viz.sh file.txt --send --delay 50   # 50ms between requests
#
# Depends: python3, curl, jq

set -euo pipefail

INPUT_FILE="$1"
shift

MODE_OUTPUT=false
MODE_SEND=false
DELAY_MS=0
CONCURRENCY=5
API_BASE="${API_BASE:-http://localhost:5000}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-json) MODE_OUTPUT=true ;;
        --send) MODE_SEND=true ;;
        --delay) DELAY_MS="$2"; shift ;;
        --concurrency) CONCURRENCY="$2"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "❌ File not found: $INPUT_FILE"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "❌ python3 required"
    exit 1
fi

if $MODE_SEND && ! command -v curl &>/dev/null; then
    echo "❌ curl required for --send"
    exit 1
fi

if $MODE_SEND && ! command -v jq &>/dev/null; then
    echo "❌ jq required for --send"
    exit 1
fi

# ----------------------------------------------------------------------
# Embedded Python translator (NARSESE → {nodes, edges})
# ----------------------------------------------------------------------
read -r -d '' PYTHON_PARSER << 'EOF' || true
import sys, re, json
from collections import defaultdict

def clean_term(s):
    """Extract a clean identifier from a term like <conssurro> or {contexto_obsceno}."""
    s = re.sub(r'[<>{}*]', ' ', s)
    s = re.sub(r'\s+', ' ', s).strip()
    # Keep letters, numbers, underscore, hyphen, and accented chars
    s = re.sub(r'[^a-zA-Z0-9_\-àâçéèêëîïôùûüÿœæ]', '', s)
    return s if s else None

def extract_nodes_from_text(text):
    """Find all atomic node names (unique words that look like identifiers)."""
    # Match words with optional hyphens/underscores, including unicode letters
    pattern = r'\b[a-zA-Z_àâçéèêëîïôùûüÿœæ][a-zA-Z0-9_\-àâçéèêëîïôùûüÿœæ]*\b'
    raw = re.findall(pattern, text, re.UNICODE)
    nodes = set()
    for w in raw:
        cleaned = clean_term(w)
        if cleaned and len(cleaned) > 1:
            nodes.add(cleaned)
    return sorted(nodes)

def extract_edges(text):
    """Extract edges from patterns: A --> B, A ==> B, A <-> B, and (A * B) --> C."""
    edges = []  # (source, target, type)
    
    # Standard arrows
    for arrow, etype in [('-->', 'directed'), ('==>', 'implies'), ('<->', 'bidirectional')]:
        # Allow whitespace and optional parentheses around terms
        pattern = r'\(?([^()\s][^()]*?)\)?\s*' + re.escape(arrow) + r'\s*\(?([^()\s][^()]*?)\)?'
        for match in re.finditer(pattern, text):
            left_raw, right_raw = match.groups()
            left = clean_term(re.search(r'[a-zA-Z_][a-zA-Z0-9_\-]*', left_raw).group())
            right = clean_term(re.search(r'[a-zA-Z_][a-zA-Z0-9_\-]*', right_raw).group())
            if left and right:
                edges.append((left, right, etype))
    
    # Product: (A * B) --> C
    prod_pattern = r'\(([^()*]+)\s*\*\s*([^()]+)\)\s*-->\s*([^()]+)'
    for match in re.finditer(prod_pattern, text):
        left1_raw, left2_raw, right_raw = match.groups()
        left1 = clean_term(re.search(r'[a-zA-Z_][a-zA-Z0-9_\-]*', left1_raw).group())
        left2 = clean_term(re.search(r'[a-zA-Z_][a-zA-Z0-9_\-]*', left2_raw).group())
        right = clean_term(re.search(r'[a-zA-Z_][a-zA-Z0-9_\-]*', right_raw).group())
        if left1 and right:
            edges.append((left1, right, 'product'))
        if left2 and right:
            edges.append((left2, right, 'product'))
    
    # Remove duplicates while preserving order
    seen = set()
    unique = []
    for e in edges:
        key = (e[0], e[1], e[2])
        if key not in seen:
            seen.add(key)
            unique.append(e)
    return unique

def parse_file(filename):
    with open(filename, 'r', encoding='utf-8') as f:
        content = f.read()
    nodes = extract_nodes_from_text(content)
    edges = extract_edges(content)
    return nodes, edges

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('{"error":"no input file"}')
        sys.exit(1)
    nodes, edges = parse_file(sys.argv[1])
    result = {
        "nodes": [{"id": n, "label": n} for n in nodes],
        "edges": [{"source": s, "target": t, "type": typ} for (s, t, typ) in edges]
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))
EOF

# ----------------------------------------------------------------------
# Stage 1: Translate to JSON
# ----------------------------------------------------------------------
echo "🔍 Stage 1: Translating NARSESE to structured JSON..." >&2
GRAPH_JSON=$(python3 -c "$PYTHON_PARSER" "$INPUT_FILE")

if [[ -z "$GRAPH_JSON" ]]; then
    echo "❌ Translation failed" >&2
    exit 1
fi

if $MODE_OUTPUT; then
    echo "$GRAPH_JSON"
    exit 0
fi

# Save to a temporary file for later use
TMP_JSON=$(mktemp)
echo "$GRAPH_JSON" > "$TMP_JSON"

NODE_COUNT=$(jq '.nodes | length' "$TMP_JSON")
EDGE_COUNT=$(jq '.edges | length' "$TMP_JSON")
echo "📊 Extracted $NODE_COUNT nodes and $EDGE_COUNT edges" >&2

# ----------------------------------------------------------------------
# Stage 2: Send to visualizer API (if requested)
# ----------------------------------------------------------------------
if $MODE_SEND; then
    echo "🚀 Stage 2: Sending to $API_BASE (concurrency=$CONCURRENCY, delay=${DELAY_MS}ms)" >&2
    
    # Prepare a worklist file for parallel processing
    WORKLIST=$(mktemp)
    
    # Nodes: POST /nodes
    jq -c '.nodes[]' "$TMP_JSON" | while read -r node_json; do
        echo "POST|$API_BASE/nodes|$node_json" >> "$WORKLIST"
    done
    
    # Edges: POST /edges (only source/target are required, type is optional)
    jq -c '.edges[] | {source: .source, target: .target}' "$TMP_JSON" | while read -r edge_json; do
        echo "POST|$API_BASE/edges|$edge_json" >> "$WORKLIST"
    done
    
    TOTAL_REQUESTS=$(wc -l < "$WORKLIST")
    echo "📤 Sending $TOTAL_REQUESTS requests..." >&2
    
    # Function to send one request with optional delay
    send_one() {
        local line="$1"
        local method url data
        IFS='|' read -r method url data <<< "$line"
        # Add a small random metadata to mimic stress test (optional)
        # data=$(echo "$data" | jq '.metadata = {"source": "narsese"}')
        curl -s -X "$method" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "$url" > /dev/null
        echo -n "."
        if [[ "$DELAY_MS" -gt 0 ]]; then
            usleep "$((DELAY_MS * 1000))"
        fi
    }
    export -f send_one
    export API_BASE DELAY_MS
    
    # Run using xargs for concurrency
    cat "$WORKLIST" | xargs -P "$CONCURRENCY" -I {} bash -c 'send_one "$@"' _ {}
    
    echo -e "\n✅ Stage 2 completed."
    rm -f "$WORKLIST"
else
    echo "ℹ️  Stage 2 skipped (use --send to post to API)" >&2
fi

rm -f "$TMP_JSON"
