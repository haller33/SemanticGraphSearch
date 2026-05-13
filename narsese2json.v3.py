#!/usr/bin/env python3
"""
Convert Narsese statements from stdin to JSON Lines (graph operations).
- Full recursive descent parser for valid Narsese.
- Fallback for unparseable lines: creates a giant node for the whole line,
  extracts all nested statements/compounds inside it, and connects them.
- Supports --tag argument.
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
    ('ATOM',      r'[a-zA-Z_][a-zA-Z0-9_]*'),
    ('VAR',       r'[#$][1-9][0-9]*'),
    ('WILDCARD',  r'_'),
    ('BRACE',     r'\{[\w\s]+\}'),
    ('BRACKET',   r'\[[\w\s_]+\]'),
    ('RELATION',  r'-->|<->|==>|<=>|=/>|=/='),   # operadores de relação
    ('SPECIAL',   r'[<>=&|*(),.;?!%~-]'),        # inclui '-'
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
        # Verifica se o próximo token é uma relação
        if kind == 'RELATION' or val in ('-->', '<->', '<=>', '==>', '=/=', '=/>'):
            rel = val
            self.consume()
            right = self.parse_term()
        else:
            right = None
        self.consume(expected_value='>')
        # consome pontuação final opcional
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
        # operador composto (&&, ||, --, &/, |, &, ~)
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
            # produto: A * B * C ...
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
                # parênteses comuns (apenas agrupamento)
                self.consume(expected_value=')')
                return left

# ------------------------------------------------------------
# Graph Emitter
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
        # Emite o nó atual
        color = None
        typ = term[0]
        if typ == 'atom':
            color = '#7FDBFF'
        elif typ == 'stmt':
            color = '#FF851B'
        elif typ == 'compound':
            color = '#B10DC9'
        elif typ == 'product':
            color = '#39CCCC'
        self.emit_node(term, color=color)

        # Se tem um pai, desenha a aresta estrutural
        if parent_term is not None and relation_label is not None:
            self.emit_edge(parent_term, term, relation_label, color='#DDDDDD')

        # Recurse nos filhos
        if typ == 'atom':
            pass
        elif typ == 'stmt':
            _, left, rel, right = term
            self.traverse_term(left, parent_term=term, relation_label='[subject]')
            if right:
                self.traverse_term(right, parent_term=term, relation_label='[predicate]')
                # aresta direta entre sujeito e predicado com o operador
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
            self.process_line_fallback(line)
            return
        self.traverse_term(term)

    # ------------------------------------------------------------
    # Fallback: cria um nó gigante e liga subestruturas
    # ------------------------------------------------------------
    def extract_nested_blocks(self, s):
        """
        Retorna uma lista de substrings que são blocos Narsese de primeiro nível:
        <...> ou (...) que não estão aninhados dentro de outro bloco.
        """
        blocks = []
        stack = []
        start = -1
        for i, ch in enumerate(s):
            if ch in '<(':
                if not stack:
                    start = i
                stack.append(ch)
            elif ch in '>)':
                if stack and ((stack[-1] == '<' and ch == '>') or (stack[-1] == '(' and ch == ')')):
                    stack.pop()
                    if not stack:
                        blocks.append(s[start:i+1])
                else:
                    # mal formado – reinicia
                    stack = []
        return blocks

    def process_line_fallback(self, line):
        # 1. Nó gigante representando a linha inteira
        giant_term = ('atom', line)
        self.emit_node(giant_term, color='#AAAAAA')

        # 2. Extrai blocos de primeiro nível e os processa
        blocks = self.extract_nested_blocks(line)
        for block in blocks:
            tokens = tokenize(block)
            parser = Parser(tokens)
            try:
                subterm = parser.parse_term()
            except ParseError:
                # Se falhar, trata o bloco como um átomo literal
                subterm = ('atom', block)
            # Processa o bloco (seus nós e arestas internas)
            self.traverse_term(subterm)
            # Adiciona aresta do nó gigante para a raiz do bloco
            src_id = self.node_id(giant_term)
            dst_id = self.node_id(subterm)
            if src_id != dst_id:
                edge_op = {
                    'op': 'add_edge',
                    'source': src_id,
                    'target': dst_id,
                    'label': '[contains]',
                    'color': '#777777'
                }
                if self.add_tag:
                    edge_op.setdefault('tags', []).append(self.add_tag)
                self.out.write(json.dumps(edge_op) + '\n')

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description='Convert Narsese to graph JSON lines (robust parser with fallback)')
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
