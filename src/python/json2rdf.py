#!/usr/bin/env python3
"""
json2rdf.py – Convert JSON Lines graph from narsese2json to RDF Turtle.
Usage: narsese2json input.nal | python json2rdf.py > output.ttl
"""

import sys
import json
import re
from collections import defaultdict

# ------------------------------------------------------------
# Mapping from Narsese predicates to RDF predicates
# ------------------------------------------------------------
PREDICATE_MAP = {
    "-->": "rdf:type",
    "<->": "owl:sameAs",
    "==>": "n:implies",
    "<=>": "n:equivalent",
    "=/>": "n:eventually",
}

# ------------------------------------------------------------
# Determine if a node ID is an atomic URI (not a blank node)
# ------------------------------------------------------------
def is_atomic_node(node_id: str) -> bool:
    """Return True if node_id should become a URI, False for blank node."""
    # Numbers and simple identifiers
    if re.match(r'^[a-zA-Z_][a-zA-Z0-9_]*$', node_id):
        return True
    if re.match(r'^\d+(\.\d+)?$', node_id):
        return True
    # Braced atoms: {something} -> URI after stripping braces
    if node_id.startswith('{') and node_id.endswith('}'):
        return True
    # Bracketed atoms (already stripped) are simple strings
    return False

def node_to_uri_or_bnode(node_id: str, bnode_map: dict, bnode_counter: int) -> tuple[str, int]:
    """Convert node ID to RDF term (URI or blank node). Returns (term, updated_counter)."""
    if is_atomic_node(node_id):
        # Strip braces if present
        if node_id.startswith('{') and node_id.endswith('}'):
            inner = node_id[1:-1]
        else:
            inner = node_id
        # Escape special characters in URI? We'll use simple local name.
        # For numbers, prefix with '_' to avoid numeric URIs? Turtle allows numeric localnames? Better to prefix.
        if inner[0].isdigit():
            inner = f"n{inner}"
        return f":{inner}", bnode_counter
    else:
        # Blank node
        if node_id not in bnode_map:
            bnode_map[node_id] = f"_:b{bnode_counter}"
            bnode_counter += 1
        return bnode_map[node_id], bnode_counter

# ------------------------------------------------------------
# Main processing
# ------------------------------------------------------------
def main():
    # Data structures
    nodes = {}          # node_id -> label (not used except for debugging)
    edges = []          # list of (source, target, label)

    # Read JSON lines from stdin
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as e:
            sys.stderr.write(f"Invalid JSON: {line}\n")
            continue

        op = obj.get("op")
        if op == "add_node":
            node_id = obj.get("id")
            if node_id:
                nodes[node_id] = obj.get("label", node_id)
        elif op == "add_edge":
            src = obj.get("source")
            tgt = obj.get("target")
            label = obj.get("label")
            if src and tgt and label:
                edges.append((src, tgt, label))
        # ignore other ops

    # Collect all triples from edges that are Narsese predicates
    triples = set()
    bnode_map = {}
    bnode_counter = 0

    for src, tgt, label in edges:
        # Only consider edges where label is a Narsese predicate (not starting with '[')
        if label.startswith('['):
            continue
        # Map predicate
        pred = PREDICATE_MAP.get(label, f":{label}")
        # Convert nodes
        src_term, bnode_counter = node_to_uri_or_bnode(src, bnode_map, bnode_counter)
        tgt_term, bnode_counter = node_to_uri_or_bnode(tgt, bnode_map, bnode_counter)
        triples.add((src_term, pred, tgt_term))

    # Output Turtle
    print("@prefix : <http://example.org/ns#> .")
    print("@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .")
    print("@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .")
    print("@prefix owl: <http://www.w3.org/2002/07/owl#> .")
    print("@prefix n: <http://example.org/nars/> .")
    print()

    for s, p, o in sorted(triples):
        # If object is a blank node, no extra handling needed
        print(f"{s} {p} {o} .")

if __name__ == "__main__":
    main()
