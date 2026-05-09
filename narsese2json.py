#!/usr/bin/env python3
"""
Convert Narsese statements from stdin to JSON Lines (graph operations).
Recursively decomposes terms and creates nodes for atoms and compounds,
plus edges representing term structure.

Usage: ./narsese2json.py [--tag narsese] < input.nars
"""

import sys
import re
import json
import argparse
import signal

signal.signal(signal.SIGPIPE, signal.SIG_DFL)

# ------------------------------------------------------------
# Tokenizer
# ------------------------------------------------------------
TOKEN_SPEC = [
    ('COMMENT',   r'//[^\n]*'),
    ('WHITESPACE',r'\s+'),
    ('NUMBER',    r'\d+(?:\.\d+)?'),
    ('ATOM',      r'[a-zA-Z_][a-zA-Z0-9_]*'),   # identifiers like amor, Cicero
    ('VAR',       r'[#$][1-9][0-9]*'),          # #1, $5
    ('WILDCARD',  r'_'),                         # placeholder _
    ('BRACE',     r'\{[\w\s]+\}'),               # {context}
    ('BRACKET',   r'\[[\w\s_]+\]'),              # [property]
    ('SPECIAL',   r'[<>=&|*(),.;?!%~]'),         # punctuation symbols
]

TOKEN_REGEX = re.compile('|'.join('(?P<%s>%s)' % pair for pair in TOKEN_SPEC))

def tokenize(code):
    """Yield (type, value) tokens."""
    for mo in TOKEN_REGEX.finditer(code):
        kind = mo.lastgroup
        value = mo.group()
        if kind == 'WHITESPACE' or kind == 'COMMENT':
            continue
        yield kind, value

# ------------------------------------------------------------
# Parser
# ------------------------------------------------------------
class Parser:
    def __init__(self, tokens):
        self.tokens = list(tokens)
        self.pos = 0

    def peek(self):
        return self.tokens[self.pos] if self.pos < len(self.tokens) else (None, None)

    def consume(self, expected_type=None, expected_value=None):
        if self.pos >= len(self.tokens):
            raise SyntaxError("Unexpected end of input")
        kind, value = self.tokens[self.pos]
        if expected_type and kind != expected_type:
            raise SyntaxError(f"Expected {expected_type}, got {kind} ({value})")
        if expected_value and value != expected_value:
            raise SyntaxError(f"Expected '{expected_value}', got '{value}'")
        self.pos += 1
        return kind, value

    def parse_term(self):
        """Parse a Narsese term (atom, compound, statement, product, etc.)"""
        kind, value = self.peek()
        if kind in ('ATOM', 'BRACE', 'BRACKET', 'NUMBER', 'VAR', 'WILDCARD'):
            self.consume()
            return ('atom', value)
        elif value == '<':
            return self.parse_statement()
        elif value == '(':
            return self.parse_compound()
        else:
            raise SyntaxError(f"Unexpected token: {kind} {value}")

    def parse_statement(self):
        """Parse < ... > with a relation."""
        self.consume(expected_value='<')
        left = self.parse_term()
        # relation operator
        rel = None
        kind, val = self.peek()
        if val in ('-->', '<->', '<=>', '==>', '=/='):
            rel = val
            self.consume()
            right = self.parse_term()
        else:
            # standalone term inside < > (unlikely, but handle)
            right = None
        self.consume(expected_value='>')
        # consume trailing punctuation . ? !
        if self.pos < len(self.tokens):
            kind, val = self.peek()
            if kind == 'SPECIAL' and val in ('.', '?', '!'):
                self.consume()
        if rel:
            return ('stmt', left, rel, right)
        else:
            return left  # just a term wrapped in < >

    def parse_compound(self):
        """Parse ( ... ) compound: (&&, ...), (||, ...), (--, ...), (A * B), (&/, ...) etc."""
        self.consume(expected_value='(')
        # first token determines type
        kind, val = self.peek()
        if val in ('&&', '||', '--', '&/', '|', '&', '~'):
            # operator compound: (&&, A, B, ...)
            op = val
            self.consume()
            self.consume(expected_value=',')   # comma after operator
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
                    raise SyntaxError(f"Expected ',' or ')', got {nxt}")
            self.consume(expected_value=')')
            return ('compound', op, args)
        else:
            # product: A * B (or longer)
            left = self.parse_term()
            kind, val = self.peek()
            if val == '*':
                # product chain: (A * B * C ...)
                self.consume(expected_value='*')
                right = self.parse_term()
                # flatten into a list
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
                # just parentheses grouping
                self.consume(expected_value=')')
                return left

# ------------------------------------------------------------
# AST Traversal and Node/Edge Emission
# ------------------------------------------------------------
class GraphEmitter:
    def __init__(self, add_tag=None):
        self.add_tag = add_tag
        self.seen_nodes = set()
        self.out = sys.stdout

    def node_id(self, term_node):
        """Generate a unique ID for a term node (AST representation)."""
        # We'll use the string representation, which we define recursively
        return self.term_to_string(term_node)

    def term_to_string(self, term_node):
        """Convert AST node back to Narsese source string."""
        typ = term_node[0]
        if typ == 'atom':
            return term_node[1]
        elif typ == 'stmt':
            _, left, rel, right = term_node
            left_str = self.term_to_string(left)
            right_str = self.term_to_string(right) if right else ''
            return f'<{left_str} {rel} {right_str}>'
        elif typ == 'compound':
            _, op, args = term_node
            args_str = ', '.join(self.term_to_string(a) for a in args)
            return f'({op}, {args_str})'
        elif typ == 'product':
            _, args = term_node
            args_str = ' * '.join(self.term_to_string(a) for a in args)
            return f'({args_str})'
        else:
            raise ValueError(f"Unknown term type: {typ}")

    def emit_node(self, term_node):
        """Add a node for this term if not already seen."""
        nid = self.node_id(term_node)
        if nid in self.seen_nodes:
            return nid
        self.seen_nodes.add(nid)
        op = {'op': 'add_node', 'id': nid, 'label': nid}
        if self.add_tag:
            op.setdefault('tags', []).append(self.add_tag)
        self.out.write(json.dumps(op) + '\n')
        return nid

    def emit_edge(self, src_node, dst_node, label):
        """Emit an add_edge operation."""
        src_id = self.node_id(src_node)
        dst_id = self.node_id(dst_node)
        op = {
            'op': 'add_edge',
            'source': src_id,
            'target': dst_id,
            'label': label
        }
        if self.add_tag:
            op.setdefault('tags', []).append(self.add_tag)
        self.out.write(json.dumps(op) + '\n')

    def traverse_term(self, term_node, parent_node=None, relation_label=None):
        """
        Recursively emit nodes for all subterms.
        If parent_node is given, add an edge from parent to this term.
        """
        # Emit node for this term
        cur_id = self.emit_node(term_node)

        # If we have a parent, link it
        if parent_node is not None and relation_label is not None:
            self.emit_edge(parent_node, term_node, relation_label)

        # Recurse into children based on term type
        typ = term_node[0]
        if typ == 'atom':
            pass  # no children
        elif typ == 'stmt':
            _, left, rel, right = term_node
            # left and right are terms
            self.traverse_term(left, parent_node=term_node, relation_label='[subject]')
            if right:
                self.traverse_term(right, parent_node=term_node, relation_label='[predicate]')
        elif typ == 'compound':
            _, op, args = term_node
            for i, arg in enumerate(args):
                self.traverse_term(arg, parent_node=term_node, relation_label=f'[{op}_arg{i}]')
        elif typ == 'product':
            _, args = term_node
            for i, arg in enumerate(args):
                self.traverse_term(arg, parent_node=term_node, relation_label=f'[product_arg{i}]')
        else:
            raise ValueError(f"Unknown term type: {typ}")

        return cur_id

    def process_statement(self, line):
        """Parse a line, then traverse the resulting AST."""
        tokens = tokenize(line)
        parser = Parser(tokens)
        try:
            term = parser.parse_term()
        except SyntaxError as e:
            sys.stderr.write(f"Parse error: {e} on line: {line}\n")
            return
        # Traverse the whole AST (this creates all internal nodes and edges)
        self.traverse_term(term)
        # If the term is a statement with a relation, also add the direct relation edge
        if term[0] == 'stmt' and term[2] is not None:
            _, left, rel, right = term
            if right:
                # Add edge from left to right with relation label
                self.emit_edge(left, right, rel)

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description='Convert Narsese to graph JSON lines (with decomposition)')
    parser.add_argument('--tag', default=None, help='Add this tag to every node/edge')
    args = parser.parse_args()

    emitter = GraphEmitter(add_tag=args.tag)

    for line in sys.stdin:
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        emitter.process_statement(line)

if __name__ == '__main__':
    main()
