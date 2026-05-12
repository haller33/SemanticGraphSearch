#!/usr/bin/env python3
"""
Read graph operations (JSON Lines) from stdin and send them to the visualizer API.
Usage: ./send2graph.py [--api URL] [--color HEX] < operations.jsonl

If --color is given, all created nodes will use that hex color (overrides any
color specified in the input for add_node operations).
"""

import sys
import json
import argparse
import requests
import time

def send_request(method, url, data=None):
    """Send HTTP request, return success bool."""
    try:
        if method == 'POST':
            resp = requests.post(url, json=data, timeout=2)
        elif method == 'DELETE':
            resp = requests.delete(url, params=data, timeout=2)
        else:
            return False
        return resp.status_code in (200, 201, 202)
    except Exception as e:
        sys.stderr.write(f"Request failed: {e}\n")
        return False

def handle_add_node(api_base, node, forced_color=None):
    """POST /nodes
    If forced_color is provided, it overrides any color in the node dict.
    """
    url = f"{api_base}/nodes"
    payload = {
        'id': node['id'],
        'label': node.get('label', node['id']),
        'metadata': node.get('metadata', {}),
        'tags': node.get('tags', [])
    }
    # Add color if forced or present in input
    if forced_color:
        payload['color'] = forced_color
    elif 'color' in node:
        payload['color'] = node['color']
    return send_request('POST', url, payload)

def handle_add_edge(api_base, edge):
    """POST /edges"""
    url = f"{api_base}/edges"
    payload = {
        'source': edge['source'],
        'target': edge['target']
    }
    if 'label' in edge:
        payload['metadata'] = {'relation': edge['label']}
    if 'tags' in edge:
        payload['tags'] = edge['tags']
    return send_request('POST', url, payload)

def handle_add_tags(api_base, tags_op):
    """POST /nodes/{id}/tags"""
    node_id = tags_op['id']
    url = f"{api_base}/nodes/{node_id}/tags"
    payload = {'tags': tags_op['tags']}
    return send_request('POST', url, payload)

def main():
    parser = argparse.ArgumentParser(description='Send graph operations to visualizer API')
    parser.add_argument('--api', default='http://localhost:5000',
                        help='Base URL of the graph visualizer API')
    parser.add_argument('--color', metavar='HEX', default=None,
                        help='Hexadecimal color (e.g. "#ff0000") to apply to all created nodes')
    args = parser.parse_args()

    # Optional: basic validation of the color string
    if args.color and not (args.color.startswith('#') and len(args.color) == 7):
        sys.stderr.write(f"Warning: color '{args.color}' does not look like a hex color (#rrggbb). Still sending as-is.\n")

    total = 0
    ok = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            op = json.loads(line)
        except json.JSONDecodeError as e:
            sys.stderr.write(f"Invalid JSON: {line}\n")
            continue

        total += 1
        success = False
        op_type = op.get('op')
        if op_type == 'add_node':
            success = handle_add_node(args.api, op, forced_color=args.color)
        elif op_type == 'add_edge':
            success = handle_add_edge(args.api, op)
        elif op_type == 'add_tags':
            success = handle_add_tags(args.api, op)
        else:
            sys.stderr.write(f"Unknown operation: {op_type}\n")

        if success:
            ok += 1
            sys.stderr.write('.')
        else:
            sys.stderr.write('F')
        sys.stderr.flush()

    sys.stderr.write(f"\nDone: {ok}/{total} operations succeeded.\n")

if __name__ == '__main__':
    main()
