#!/usr/bin/env python3
"""
folder2json.py – Convert a list of file paths (with possible .. and .) to JSON Lines
for send2graph.c. Normalizes paths without filesystem access, then builds graph.

Usage:
    cat path_list.txt | ./folder2json.py > graph.jsonl
    ./folder2json.py --input paths.txt --output graph.jsonl
"""

import sys
import os
import json
import argparse
from collections import deque

# Node colors
COLOR_DIR = "#7FDBFF"
COLOR_FILE = "#FF851B"
COLOR_ROOT = "#39CCCC"


def normalize_path(path):
    """
    Normalize a path by resolving '..' and '.' without filesystem access.
    Works with both absolute and relative paths. Returns a clean path.
    Example: '../../../wget/ROSACRUZ/./db' -> 'wget/ROSACRUZ/db'
    """
    parts = path.split('/')
    stack = []
    for part in parts:
        if part == '' or part == '.':
            continue
        elif part == '..':
            if stack:
                stack.pop()
        else:
            stack.append(part)
    return '/'.join(stack) if stack else '.'


class FolderGraph:
    def __init__(self):
        self.nodes = set()
        self.edges = set()
        self.edge_list = []

    def add_node(self, path):
        """Add a normalized path (no trailing slash)."""
        norm = path.rstrip('/')
        self.nodes.add(norm)
        return norm

    def add_edge(self, parent, child):
        parent_norm = self.add_node(parent)
        child_norm = self.add_node(child)
        key = (parent_norm, child_norm, "contains")
        if key not in self.edges:
            self.edges.add(key)
            self.edge_list.append(key)

    def build_from_paths(self, file_paths):
        """
        Build graph from a list of file paths (normalized first).
        """
        # First normalize all paths
        normalized = set()
        for fp in file_paths:
            fp = fp.strip()
            if not fp:
                continue
            norm = normalize_path(fp)
            normalized.add(norm)
            # Also add all parent directories (by splitting)
            parts = norm.split('/')
            for i in range(1, len(parts)):
                parent = '/'.join(parts[:i])
                normalized.add(parent)
            normalized.add('.')  # root

        # Determine directories: any node that is a prefix of another node (with trailing slash)
        dirs = set()
        for p in normalized:
            if p == '.':
                dirs.add(p)
                continue
            p_with_slash = p + '/'
            for other in normalized:
                if other != p and other.startswith(p_with_slash):
                    dirs.add(p)
                    break

        # Add all nodes
        for p in normalized:
            self.add_node(p)

        # Add edges: parent -> child
        for p in normalized:
            if p == '.':
                continue
            if '/' in p:
                parent = '/'.join(p.split('/')[:-1])
            else:
                parent = '.'
            if parent in normalized or parent == '.':
                self.add_edge(parent, p)

    def output_json_lines(self, out_file):
        # Emit nodes
        for path in sorted(self.nodes):
            is_dir = (path == '.') or any(e[0] == path for e in self.edge_list)
            if path == '.':
                label = "root"
                color = COLOR_ROOT
            else:
                label = os.path.basename(path)
                color = COLOR_DIR if is_dir else COLOR_FILE
            node_obj = {
                "op": "add_node",
                "id": path,
                "label": label,
                "color": color,
                "tags": ["folder_graph"]
            }
            out_file.write(json.dumps(node_obj) + "\n")

        # Emit edges
        for src, dst, label in self.edge_list:
            edge_obj = {
                "op": "add_edge",
                "source": src,
                "target": dst,
                "label": label,
                "color": "#DDDDDD",
                "tags": ["folder_graph"]
            }
            out_file.write(json.dumps(edge_obj) + "\n")


def main():
    parser = argparse.ArgumentParser(description="Convert file paths to JSON Lines (normalizes .. and .)")
    parser.add_argument("--input", "-i", help="Input file with one path per line (default: stdin)")
    parser.add_argument("--output", "-o", help="Output file (default: stdout)")
    args = parser.parse_args()

    paths = []
    if args.input:
        with open(args.input, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    paths.append(line)
    else:
        for line in sys.stdin:
            line = line.strip()
            if line and not line.startswith('#'):
                paths.append(line)

    if not paths:
        sys.stderr.write("No input paths provided.\n")
        sys.exit(1)

    sys.stderr.write(f"Read {len(paths)} paths.\n")
    graph = FolderGraph()
    graph.build_from_paths(paths)
    sys.stderr.write(f"Created {len(graph.nodes)} nodes and {len(graph.edges)} edges.\n")

    out_fh = open(args.output, 'w') if args.output else sys.stdout
    graph.output_json_lines(out_fh)
    if args.output:
        out_fh.close()


if __name__ == "__main__":
    main()
