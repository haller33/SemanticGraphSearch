#!/usr/bin/env python3
"""
Read graph operations (JSON Lines) from stdin and send them to the visualizer API.
Usage: ./send2graph.py [--api URL] < operations.jsonl
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
        return resp.status_code in (200, 201)
    except Exception as e:
        sys.stderr.write(f"Request failed: {e}\n")
        return False

def handle_add_node(api_base, node):
    """POST /nodes"""
    url = f"{api_base}/nodes"
    payload = {
        'id': node['id'],
        'label': node.get('label', node['id']),
        'metadata': node.get('metadata', {}),
        'tags': node.get('tags', [])
    }
    return send_request('POST', url, payload)

def handle_add_edge(api_base, edge):
    """POST /edges"""
    url = f"{api_base}/edges"
    payload = {
        'source': edge['source'],
        'target': edge['target']
    }
    # Optionally store label as a tag or metadata
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
    parser.add_argument('--api', default='http://localhost:5000', help='Base URL of the graph visualizer API')
    args = parser.parse_args()

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
            success = handle_add_node(args.api, op)
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
