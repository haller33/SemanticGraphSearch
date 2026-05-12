#!/usr/bin/env python3
"""
Convert Narsese statements from stdin to JSON Lines (graph operations).
- Full recursive descent parser that handles nested statements, compounds, products.
- Emits nodes for every term (atomic, compound, statement) and edges for relations.
- Operators (&&, ||, --, &/, |, &, ~) become operator nodes with edges to arguments.
- Copulas (-->, <->, ==>, <=>, =/=>) become edges between subject and predicate.
- Flattens product chains for readability.
- Supports --tag argument to label all nodes/edges (e.g., "derived").
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
# Parser (Recursive Descent)
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
        """Parse a Narsese term (atom, compound, statement, product)."""
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
        """Parse < ... > with a relation."""
        self.consume(expected_value='<')
        left = self.parse_term()
        rel = None
        kind, val = self.peek()
        if val in ('-->', '<->', '<=>', '==>', '=/=', '=/>'):   # '=/>' is temporal
            rel = val
            self.consume()
            right = self.parse_term()
        else:
            right = None
        self.consume(expected_value='>')
        # optional trailing punctuation . ? !
        if self.pos < len(self.tokens):
            kind, val = self.peek()
            if kind == 'SPECIAL' and val in ('.', '?', '!'):
                self.consume()
        if rel:
            return ('stmt', left, rel, right)
        else:
            return left   # statement without relation (rare, treat as atom)

    def parse_compound(self):
        """Parse ( ... ) compound: (&&, ...), (||, ...), (--, ...), (A * B), (&/, ...) etc."""
        self.consume(expected_value='(')
        kind, val = self.peek()
        # operator compound: (&&, A, B, ...)
        if val in ('&&', '||', '--', '&/', '|', '&', '~'):
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
            # product: A * B (or longer)
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
                # just parentheses grouping
                self.consume(expected_value=')')
                return left

# ------------------------------------------------------------
# Graph Emitter – builds nodes and edges from AST
# ------------------------------------------------------------
class GraphEmitter:
    def __init__(self, add_tag=None):
        self.add_tag = add_tag
        self.seen_nodes = set()
        self.out = sys.stdout
        self.edge_counter = 0   # for unique IDs if needed, not used

    def node_id(self, term):
        """Generate a unique ID for an AST node."""
        # Use a string representation that is deterministic
        return self.term_to_string(term)

    def term_to_string(self, term):
        """Convert AST node back to Narsese source string (canonical)."""
        typ = term[0]
        if typ == 'atom':
            return term[1]
        elif typ == 'stmt':
            _, left, rel, right = term
            left_str = self.term_to_string(left)
            right_str = self.term_to_string(right) if right else ''
            # Standard format: no extra spaces
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
        """Add a node for this term if not already seen. Optionally set color."""
        nid = self.node_id(term)
        if nid in self.seen_nodes:
            return nid
        self.seen_nodes.add(nid)
        op = {
            'op': 'add_node',
            'id': nid,
            'label': self.term_to_string(term) or nid
        }
        if color:
            op['color'] = color
        if self.add_tag:
            op.setdefault('tags', []).append(self.add_tag)
        self.out.write(json.dumps(op) + '\n')
        return nid

    def emit_edge(self, src_term, dst_term, label, color=None):
        """Emit an edge from src_term to dst_term with given label."""
        src_id = self.node_id(src_term)
        dst_id = self.node_id(dst_term)
        op = {
            'op': 'add_edge',
            'source': src_id,
            'target': dst_id,
            'label': label
        }
        if color:
            op['color'] = color
        if self.add_tag:
            op.setdefault('tags', []).append(self.add_tag)
        self.out.write(json.dumps(op) + '\n')

    def traverse_term(self, term, parent_term=None, relation_label=None):
        """
        Recursively emit nodes and edges.
        If parent_term is given, draw an edge from parent to this term with relation_label.
        """
        # Emit this term's node (choose color based on term type)
        color = None
        typ = term[0]
        if typ == 'atom':
            color = '#7FDBFF'    # light blue for atoms
        elif typ == 'stmt':
            color = '#FF851B'    # orange for statements
        elif typ == 'compound':
            color = '#B10DC9'    # purple for operators
        elif typ == 'product':
            color = '#39CCCC'    # teal for products

        self.emit_node(term, color=color)

        # If we have a parent, draw the edge
        if parent_term is not None and relation_label is not None:
            self.emit_edge(parent_term, term, relation_label, color='#DDDDDD')

        # Recurse into children
        if typ == 'atom':
            pass
        elif typ == 'stmt':
            _, left, rel, right = term
            # left and right are terms
            self.traverse_term(left, parent_term=term, relation_label='[subject]')
            if right:
                self.traverse_term(right, parent_term=term, relation_label='[predicate]')
                # Also add the direct relation edge from left to right
                self.emit_edge(left, right, rel, color='#FF4136')  # red for copulas
        elif typ == 'compound':
            _, op, args = term
            for i, arg in enumerate(args):
                self.traverse_term(arg, parent_term=term, relation_label=f'[{op}_arg{i}]')
        elif typ == 'product':
            _, args = term
            for i, arg in enumerate(args):
                self.traverse_term(arg, parent_term=term, relation_label=f'[product_arg{i}]')

    def process_line(self, line):
        """Parse a line, then traverse the resulting AST."""
        tokens = tokenize(line)
        parser = Parser(tokens)
        try:
            term = parser.parse_term()
        except ParseError as e:
            sys.stderr.write(f"Parse error: {e} on line: {line}\n")
            return
        # Traverse the whole AST – this creates all nodes and internal edges
        self.traverse_term(term)

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description='Convert Narsese to graph JSON lines (robust parser)')
    parser.add_argument('--tag', default=None, help='Add this tag to every node/edge')
    args = parser.parse_args()

    emitter = GraphEmitter(add_tag=args.tag)

    for line in sys.stdin:
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        emitter.process_line(line)

if __name__ == '__main__':
    main()
