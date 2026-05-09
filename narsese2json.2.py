#!/usr/bin/env python3
"""
Convert Narsese statements from stdin to JSON Lines (graph operations).
Usage: ./narsese2json.py [--tag narsese] < input.nars
"""

import sys
import re
import json
import argparse

# Patterns for Narsese statements
# Match < ... > followed by . ? ! and optional truth value
STATEMENT_PAT = re.compile(r'^\s*<(.*)>\s*[\.?!](\s*%.*%)?\s*$')
# Split subject and predicate by relation
RELATIONS = [
    (r'<->', 'similarity'),
    (r'<=>', 'similarity'),
    (r'==>', 'implication'),
    (r'=/=', 'temporal'),
    (r'-->', 'inheritance'),
]

def parse_statement(line):
    """Parse a Narsese statement. Return (subject, predicate, relation_type) or None."""
    m = STATEMENT_PAT.match(line)
    if not m:
        return None
    inner = m.group(1).strip()
    for rel_pat, rel_type in RELATIONS:
        if rel_pat in inner:
            parts = inner.split(rel_pat, 1)
            if len(parts) == 2:
                subj = parts[0].strip()
                pred = parts[1].strip()
                return (subj, pred, rel_type)
    # No relation found – treat as a single term (node only)
    return (inner, None, None)

def term_to_node_id(term):
    """Convert a Narsese term to a safe node ID (use the term itself)."""
    # Terms can contain spaces, parentheses, etc. – keep as is for ID.
    return term

def emit_node(term, add_tag=None):
    """Emit an add_node operation for the term."""
    node_id = term_to_node_id(term)
    op = {'op': 'add_node', 'id': node_id, 'label': term}
    if add_tag:
        op.setdefault('tags', []).append(add_tag)
    sys.stdout.write(json.dumps(op) + '\n')

def emit_edge(subj, pred, rel_type, add_tag=None):
    """Emit an add_edge operation between two nodes."""
    op = {
        'op': 'add_edge',
        'source': term_to_node_id(subj),
        'target': term_to_node_id(pred),
        'label': rel_type   # optional for the visualizer (we can store as tag or metadata)
    }
    if add_tag:
        op.setdefault('tags', []).append(add_tag)
    sys.stdout.write(json.dumps(op) + '\n')

def main():
    parser = argparse.ArgumentParser(description='Convert Narsese to graph JSON lines')
    parser.add_argument('--tag', default=None, help='Add this tag to every node/edge')
    args = parser.parse_args()

    for line in sys.stdin:
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        parsed = parse_statement(line)
        if parsed is None:
            # Not a valid statement – skip or warn to stderr
            sys.stderr.write(f"Warning: Could not parse: {line}\n")
            continue

        subj, pred, rel_type = parsed
        # Emit node for subject
        emit_node(subj, args.tag)
        if pred is not None:
            emit_node(pred, args.tag)
            emit_edge(subj, pred, rel_type, args.tag)
        # Optional: if you want to store the original statement as metadata,
        # you can output an add_tags operation for the subject node.
        # Here we skip for simplicity.

if __name__ == '__main__':
    main()
