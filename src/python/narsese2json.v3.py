#!/usr/bin/env python3
"""
Convert Narsese statements from stdin to JSON Lines (graph operations).
- Handles all NAL operators including negation (--, X)
- Multi‑character tokenizer
- Recursive descent parser with fallback for complex/unparseable lines
"""

import sys
import re
import json
import argparse
import signal

signal.signal(signal.SIGPIPE, signal.SIG_DFL)

# ------------------------------------------------------------
# Multi‑character tokenizer (order matters: longest first)
# ------------------------------------------------------------
TOKEN_SPEC = [
    ('COMMENT',     r'//[^\n]*'),
    ('WHITESPACE',  r'\s+'),
    ('NUMBER',      r'\d+(?:\.\d+)?'),
    ('ATOM',        r'[a-zA-Z_][a-zA-Z0-9_]*'),
    ('VAR',         r'[#$][1-9][0-9]*'),
    ('WILDCARD',    r'_'),
    ('BRACE',       r'\{[\w\s]+\}'),
    ('BRACKET',     r'\[[\w\s_]+\]'),
    # Multi‑character operators (longest first)
    ('OP',          r'-->|<->|==>|<=>|=\/>|&&|\|\||&\/|--'),
    ('SPECIAL',     r'[<>=&|*(),.;?!%~]'),   # single punctuation
]

TOKEN_REGEX = re.compile('|'.join('(?P<%s>%s)' % pair for pair in TOKEN_SPEC))

def tokenize(code):
    for mo in TOKEN_REGEX.finditer(code):
        kind = mo.lastgroup
        value = mo.group()
        if kind == 'WHITESPACE' or kind == 'COMMENT':
            continue
        yield kind, value

# ------------------------------------------------------------
# Parser (unchanged logic, but now recognises '--' as an operator)
# ------------------------------------------------------------
class ParseError(Exception):
    pass

class Parser:
    def __init__(self, tokens):
        self.tokens = list(tokens)
        self.pos = 0

    def peek(self):
        return self.tokens[self.pos] if self.pos < len(self.tokens) else (None, None)

    def consume(self, expected_type=None, expected_value=None):
        if self.pos >= len(self.tokens):
            raise ParseError("Unexpected end of input")
        kind, value = self.tokens[self.pos]
        if expected_type and kind != expected_type:
            raise ParseError(f"Expected {expected_type}, got {kind} ({value})")
        if expected_value and value != expected_value:
            raise ParseError(f"Expected '{expected_value}', got '{value}'")
        self.pos += 1
        return kind, value

    def parse_term(self):
        kind, value = self.peek()
        if kind in ('ATOM', 'BRACE', 'BRACKET', 'NUMBER', 'VAR', 'WILDCARD'):
            self.consume()
            return ('atom', value)
        elif value == '<':
            return self.parse_statement()
        elif value == '(':
            return self.parse_compound()
        else:
            raise ParseError(f"Unexpected token: {kind} {value}")

    def parse_statement(self):
        self.consume(expected_value='<')
        left = self.parse_term()
        rel = None
        kind, val = self.peek()
        # Now the tokenizer returns '--' as a single OP token
        if kind == 'OP' and val in ('-->', '<->', '==>', '<=>', '=/='):
            rel = val
            self.consume()
            right = self.parse_term()
        else:
            right = None
        self.consume(expected_value='>')
        if self.pos < len(self.tokens):
            kind, val = self.peek()
            if kind == 'SPECIAL' and val in ('.', '?', '!'):
                self.consume()
        if rel:
            return ('stmt', left, rel, right)
        else:
            return left

    def parse_compound(self):
        self.consume(expected_value='(')
        kind, val = self.peek()
        # Recognise negation '--' as an operator
        if kind == 'OP' and val in ('&&', '||', '--', '&/', '|', '&', '~'):
            op = val
            self.consume()
            self.consume(expected_value=',')
            args = []
            while True:
                arg = self.parse_term()
                args.append(arg)
                nxt = self.peek()
                if nxt[1] == ',':
                    self.consume(expected_value=',')
                    continue
                elif nxt[1] == ')':
                    break
                else:
                    raise ParseError(f"Expected ',' or ')', got {nxt}")
            self.consume(expected_value=')')
            return ('compound', op, args)
        else:
            # product: A * B ...
            left = self.parse_term()
            kind, val = self.peek()
            if val == '*':
                self.consume(expected_value='*')
                right = self.parse_term()
                args = [left, right]
                while True:
                    nxt = self.peek()
                    if nxt[1] == '*':
                        self.consume(expected_value='*')
                        args.append(self.parse_term())
                    else:
                        break
                self.consume(expected_value=')')
                return ('product', args)
            else:
                self.consume(expected_value=')')
                return left

# ------------------------------------------------------------
# Graph Emitter (same as before, but include fallback for robustness)
# ------------------------------------------------------------
class GraphEmitter:
    def __init__(self, add_tag=None):
        self.add_tag = add_tag
        self.seen_nodes = set()
        self.out = sys.stdout

    def node_id(self, term):
        return self.term_to_string(term)

    def term_to_string(self, term):
        typ = term[0]
        if typ == 'atom':
            return term[1]
        elif typ == 'stmt':
            _, left, rel, right = term
            left_str = self.term_to_string(left)
            right_str = self.term_to_string(right) if right else ''
            return f'<{left_str} {rel} {right_str}>'
        elif typ == 'compound':
            _, op, args = term
            args_str = ', '.join(self.term_to_string(a) for a in args)
            return f'({op}, {args_str})'
        elif typ == 'product':
            _, args = term
            args_str = ' * '.join(self.term_to_string(a) for a in args)
            return f'({args_str})'
        else:
            raise ValueError(f"Unknown term type: {typ}")

    def emit_node(self, term, color=None):
        nid = self.node_id(term)
        if nid in self.seen_nodes:
            return nid
        self.seen_nodes.add(nid)
        op = {'op': 'add_node', 'id': nid, 'label': self.term_to_string(term) or nid}
        if color:
            op['color'] = color
        if self.add_tag:
            op.setdefault('tags', []).append(self.add_tag)
        self.out.write(json.dumps(op) + '\n')
        return nid

    def emit_edge(self, src_term, dst_term, label, color=None):
        src_id = self.node_id(src_term)
        dst_id = self.node_id(dst_term)
        op = {'op': 'add_edge', 'source': src_id, 'target': dst_id, 'label': label}
        if color:
            op['color'] = color
        if self.add_tag:
            op.setdefault('tags', []).append(self.add_tag)
        self.out.write(json.dumps(op) + '\n')

    def traverse_term(self, term, parent_term=None, relation_label=None):
        typ = term[0]
        color = {'atom': '#7FDBFF', 'stmt': '#FF851B', 'compound': '#B10DC9', 'product': '#39CCCC'}.get(typ, None)
        self.emit_node(term, color=color)

        if parent_term is not None and relation_label is not None:
            self.emit_edge(parent_term, term, relation_label, color='#DDDDDD')

        if typ == 'atom':
            pass
        elif typ == 'stmt':
            _, left, rel, right = term
            self.traverse_term(left, parent_term=term, relation_label='[subject]')
            if right:
                self.traverse_term(right, parent_term=term, relation_label='[predicate]')
                self.emit_edge(left, right, rel, color='#FF4136')
        elif typ == 'compound':
            _, op, args = term
            for i, arg in enumerate(args):
                self.traverse_term(arg, parent_term=term, relation_label=f'[{op}_arg{i}]')
        elif typ == 'product':
            _, args = term
            for i, arg in enumerate(args):
                self.traverse_term(arg, parent_term=term, relation_label=f'[product_arg{i}]')

    def process_line(self, line):
        tokens = tokenize(line)
        parser = Parser(tokens)
        try:
            term = parser.parse_term()
        except ParseError as e:
            sys.stderr.write(f"Parse error: {e} on line: {line}\n")
            # Fallback: create a single grey node for the whole line
            giant = ('atom', line)
            self.emit_node(giant, color='#AAAAAA')
            return
        self.traverse_term(term)

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag', default=None)
    args = parser.parse_args()
    emitter = GraphEmitter(add_tag=args.tag)
    for line in sys.stdin:
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        emitter.process_line(line)

if __name__ == '__main__':
    main()
