#!/usr/bin/env python3
"""
Convert Narsese statements from stdin to JSON Lines (graph operations).
Recursively decomposes simple inheritance; for complex statements (==>, <->, variables, etc.)
it falls back to a top‑level relation node with an edge.
"""

import sys
import re
import json
import argparse
import signal

signal.signal(signal.SIGPIPE, signal.SIG_DFL)

# ------------------------------------------------------------
# Tokenizer (unchanged)
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
# Parser (unchanged)
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
        self.consume(expected_value='<')
        left = self.parse_term()
        rel = None
        kind, val = self.peek()
        if val in ('-->', '<->', '<=>', '==>', '=/='):
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
                    raise SyntaxError(f"Expected ',' or ')', got {nxt}")
            self.consume(expected_value=')')
            return ('compound', op, args)
        else:
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
# Graph Emitter (unchanged)
# ------------------------------------------------------------
class GraphEmitter:
    def __init__(self, add_tag=None):
        self.add_tag = add_tag
        self.seen_nodes = set()
        self.out = sys.stdout

    def node_id(self, term_node):
        return self.term_to_string(term_node)

    def term_to_string(self, term_node):
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
        cur_id = self.emit_node(term_node)
        if parent_node is not None and relation_label is not None:
            self.emit_edge(parent_node, term_node, relation_label)
        typ = term_node[0]
        if typ == 'atom':
            pass
        elif typ == 'stmt':
            _, left, rel, right = term_node
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

    # ----------------------------------------------
    # Fallback for complex statements (added)
    # ----------------------------------------------
    def process_complex_statement(self, line):
        """
        Fallback parser for statements that the normal parser cannot handle.
        Extracts top‑level relation using regex, creates two atomic nodes
        (left and right parts as literal strings) and an edge labeled with the relation.
        """
        # Remove trailing punctuation . ? ! for matching
        original = line
        punct = ''
        if line[-1] in ('.', '?', '!'):
            punct = line[-1]
            line = line[:-1]

        # Match outermost structure: < ... RELATION ... >
        # We use a simple regex that finds the first '<' and the matching '>' at the same level.
        # This is not foolproof, but works for most Narsese statements.
        level = 0
        start = -1
        end = -1
        for i, ch in enumerate(line):
            if ch == '<':
                if level == 0:
                    start = i
                level += 1
            elif ch == '>':
                level -= 1
                if level == 0 and start != -1:
                    end = i
                    break
        if start == -1 or end == -1:
            sys.stderr.write(f"Fallback parse error: cannot find outer brackets in {original}\n")
            return

        inner = line[start+1:end]  # content inside <...>
        # Find the main relation operator (we keep it simple: try known operators)
        # Order matters: longest first
        ops = ['==>', '<->', '-->', '<=>', '=/=']
        rel = None
        left = None
        right = None
        for op in ops:
            # Find the operator that is not inside deeper brackets (rough heuristic: split from the rightmost occurrence)
            # Simpler: we look for the first occurrence of op after splitting at the outermost level? We'll do a simple split.
            # Because we don't have a full tokenizer, we assume the top‑level relation is the outermost operator.
            # We'll take the first occurrence that is not inside parentheses (but with Narsese, it's usually the only operator at this level).
            # Note: This may fail for nested implications like <<A --> B> ==> <C --> D>> but we'll just treat the whole inner as left/right.
            # For simplicity, we split on the first occurrence of op.
            parts = inner.split(op, 1)
            if len(parts) == 2:
                rel = op
                left = parts[0].strip()
                right = parts[1].strip()
                break
        if not rel:
            # No operator found – treat whole inner as a single node (unlikely, but fallback)
            left = inner
            rel = "N/A"
            right = ""

        # Create nodes as atoms (literal strings)
        left_node = ('atom', left)
        right_node = ('atom', right) if right else None

        # Emit nodes and edge
        left_id = self.emit_node(left_node)
        if right_node:
            right_id = self.emit_node(right_node)
            # Edge from left to right with the relation as label
            op = {'op': 'add_edge', 'source': left_id, 'target': right_id, 'label': rel}
            if self.add_tag:
                op.setdefault('tags', []).append(self.add_tag)
            self.out.write(json.dumps(op) + '\n')
        # Also, emit the whole statement as a node? Not necessary, but if you want a root node:
        # root_node = ('atom', f'<{inner}>')
        # self.emit_node(root_node)

    def process_statement(self, line):
        """Try normal parsing; if it fails, fallback to complex parsing."""
        tokens = tokenize(line)
        parser = Parser(tokens)
        try:
            term = parser.parse_term()
        except SyntaxError as e:
            # Use fallback for complex statements
            self.process_complex_statement(line)
            return
        # Normal parsing succeeded
        self.traverse_term(term)
        if term[0] == 'stmt' and term[2] is not None:
            _, left, rel, right = term
            if right:
                self.emit_edge(left, right, rel)

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description='Convert Narsese to graph JSON lines (with decomposition and fallback)')
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
