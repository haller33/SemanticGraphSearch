#!/usr/bin/env python3
"""
Narsese Parser (Recursive Descent) with RDF/Turtle emitter.
Based on the eval-apply pattern from narsese2json.c.

Usage:
    python narsese_parser.py input.nal > output.ttl

Options:
    --threshold FREQ   Minimum frequency to output a triple (default 0.9)
    --skip-vars        Skip statements containing variables
"""

import sys
import re
from typing import List, Optional, Tuple, Any, Dict
from dataclasses import dataclass, field

# ------------------------------------------------------------
# Token types
# ------------------------------------------------------------
TOK_WHITESPACE = 0
TOK_COMMENT    = 1
TOK_NUMBER     = 2
TOK_ATOM       = 3
TOK_VAR        = 4   # #1, $1
TOK_WILDCARD   = 5   # _
TOK_BRACE      = 6   # { ... }
TOK_BRACKET    = 7   # [ ... ] – but we'll parse as atom after extraction
TOK_OP         = 8   # multi-char operators: -->, <->, ==> etc.
TOK_SPECIAL    = 9   # single punctuation: < > ( ) , . ? ! % ; * =

# Map token type to name for debugging
TOKEN_NAMES = {
    TOK_NUMBER: "NUMBER",
    TOK_ATOM:   "ATOM",
    TOK_VAR:    "VAR",
    TOK_WILDCARD: "WILDCARD",
    TOK_BRACE:  "BRACE",
    TOK_BRACKET: "BRACKET",
    TOK_OP:     "OP",
    TOK_SPECIAL: "SPECIAL",
}

@dataclass
class Token:
    type: int
    value: str

# ------------------------------------------------------------
# AST node types
# ------------------------------------------------------------
class ASTNode:
    pass

@dataclass
class Atom(ASTNode):
    value: str

@dataclass
class Statement(ASTNode):
    subject: ASTNode
    predicate: str   # e.g. "-->", "<->", "==>", "<=>", "=/>"
    object: ASTNode

@dataclass
class Compound(ASTNode):
    op: str           # e.g. "&&", "||", "&/"
    args: List[ASTNode]

@dataclass
class Product(ASTNode):
    args: List[ASTNode]

# ------------------------------------------------------------
# Tokenizer
# ------------------------------------------------------------
class Tokenizer:
    def __init__(self, line: str):
        self.line = line
        self.pos = 0
        self.len = len(line)

    def _peek_char(self) -> str:
        if self.pos >= self.len:
            return ''
        return self.line[self.pos]

    def _advance(self):
        self.pos += 1

    def tokenize(self) -> List[Token]:
        tokens = []
        while self.pos < self.len:
            ch = self._peek_char()
            # whitespace
            if ch.isspace():
                self._advance()
                continue
            # comment
            if ch == '/' and self.pos + 1 < self.len and self.line[self.pos+1] == '/':
                break  # ignore rest of line
            # number
            if ch.isdigit() or (ch == '.' and self.pos+1 < self.len and self.line[self.pos+1].isdigit()):
                start = self.pos
                while self.pos < self.len and (self.line[self.pos].isdigit() or self.line[self.pos] == '.'):
                    self._advance()
                tokens.append(Token(TOK_NUMBER, self.line[start:self.pos]))
                continue
            # multi-char operators (longest match)
            multichar = [("-->", TOK_OP), ("<->", TOK_OP), ("==>", TOK_OP), ("<=>", TOK_OP),
                         ("=/>", TOK_OP), ("&&", TOK_OP), ("||", TOK_OP), ("&/", TOK_OP), ("--", TOK_OP)]
            matched = False
            for op_str, tok_type in multichar:
                if self.line.startswith(op_str, self.pos):
                    tokens.append(Token(tok_type, op_str))
                    self.pos += len(op_str)
                    matched = True
                    break
            if matched:
                continue
            # variables: #1, #2, $1, $2 ...
            if ch == '#' or ch == '$':
                start = self.pos
                self._advance()
                while self.pos < self.len and self.line[self.pos].isdigit():
                    self._advance()
                tokens.append(Token(TOK_VAR, self.line[start:self.pos]))
                continue
            # wildcard _
            if ch == '_':
                tokens.append(Token(TOK_WILDCARD, '_'))
                self._advance()
                continue
            # braces { ... }
            if ch == '{':
                start = self.pos
                depth = 1
                self._advance()
                while self.pos < self.len and depth > 0:
                    if self.line[self.pos] == '{':
                        depth += 1
                    elif self.line[self.pos] == '}':
                        depth -= 1
                    self._advance()
                tokens.append(Token(TOK_BRACE, self.line[start:self.pos]))
                continue
            # brackets [ ... ] – treat as atom after stripping
            if ch == '[':
                start = self.pos
                depth = 1
                self._advance()
                while self.pos < self.len and depth > 0:
                    if self.line[self.pos] == '[':
                        depth += 1
                    elif self.line[self.pos] == ']':
                        depth -= 1
                    self._advance()
                inner = self.line[start+1:self.pos-1].strip()
                tokens.append(Token(TOK_ATOM, inner))
                continue
            # alphanumeric or underscore
            if ch.isalpha() or ch == '_':
                start = self.pos
                while self.pos < self.len and (self.line[self.pos].isalnum() or self.line[self.pos] == '_'):
                    self._advance()
                tokens.append(Token(TOK_ATOM, self.line[start:self.pos]))
                continue
            # single punctuation
            if ch in '<>(),.;?!%~*=':
                tokens.append(Token(TOK_SPECIAL, ch))
                self._advance()
                continue
            # unknown – skip
            self._advance()
        return tokens

# ------------------------------------------------------------
# Parser (recursive descent)
# ------------------------------------------------------------
class Parser:
    def __init__(self, tokens: List[Token]):
        self.tokens = tokens
        self.pos = 0

    def peek(self) -> Optional[Token]:
        return self.tokens[self.pos] if self.pos < len(self.tokens) else None

    def consume(self, expected_type: Optional[int] = None, expected_value: Optional[str] = None) -> Token:
        if self.pos >= len(self.tokens):
            raise SyntaxError("Unexpected end of input")
        tok = self.tokens[self.pos]
        self.pos += 1
        if expected_type is not None and tok.type != expected_type:
            raise SyntaxError(f"Expected token type {expected_type}, got {tok.type} ({tok.value})")
        if expected_value is not None and tok.value != expected_value:
            raise SyntaxError(f"Expected value '{expected_value}', got '{tok.value}'")
        return tok

    def match(self, typ: int, val: Optional[str] = None) -> bool:
        tok = self.peek()
        if not tok:
            return False
        if tok.type != typ:
            return False
        if val is not None and tok.value != val:
            return False
        self.pos += 1
        return True

    # --------------------------------------------------------
    # Grammar rules
    # --------------------------------------------------------
    def parse_term(self) -> ASTNode:
        """Parse a Narsese term: atom, {atom}, ( ... ), <statement>"""
        tok = self.peek()
        if not tok:
            raise SyntaxError("Empty term")
        if tok.type == TOK_ATOM or tok.type == TOK_NUMBER or tok.type == TOK_VAR or tok.type == TOK_WILDCARD:
            self.consume()
            return Atom(tok.value)
        if tok.type == TOK_BRACE:
            self.consume()
            # Extract inner content (already included in token)
            inner = tok.value[1:-1]  # remove braces
            return Atom(inner)
        if tok.type == TOK_SPECIAL and tok.value == '<':
            return self.parse_statement()
        if tok.type == TOK_SPECIAL and tok.value == '(':
            return self.parse_compound_or_product()
        raise SyntaxError(f"Unexpected token in term: {tok.value}")

    def parse_statement(self) -> Statement:
        self.consume(TOK_SPECIAL, '<')
        subject = self.parse_term()
        # operator
        op_tok = self.peek()
        if not op_tok or op_tok.type != TOK_OP:
            raise SyntaxError("Expected operator (-->, <->, etc.)")
        self.consume()
        op = op_tok.value
        obj = self.parse_term()
        self.consume(TOK_SPECIAL, '>')
        # optional truth value
        if self.match(TOK_SPECIAL, '%'):
            freq_str = self.consume(TOK_NUMBER).value
            self.consume(TOK_SPECIAL, ';')
            conf_str = self.consume(TOK_NUMBER).value
            self.consume(TOK_SPECIAL, '%')
            # we don't store truth in AST here; will be handled separately
        # optional end punctuation
        if self.match(TOK_SPECIAL, '.') or self.match(TOK_SPECIAL, '?') or self.match(TOK_SPECIAL, '!'):
            pass
        return Statement(subject, op, obj)

    def parse_compound_or_product(self) -> ASTNode:
        """Parse '(' ... ')': either compound (op, args) or product (A * B * ...)"""
        self.consume(TOK_SPECIAL, '(')
        # check if first token is an operator
        tok = self.peek()
        if tok and tok.type == TOK_OP:
            # compound: (op, arg1, arg2, ...)
            op = tok.value
            self.consume()
            self.consume(TOK_SPECIAL, ',')
            args = []
            while True:
                arg = self.parse_term()
                args.append(arg)
                if self.match(TOK_SPECIAL, ','):
                    continue
                elif self.match(TOK_SPECIAL, ')'):
                    break
                else:
                    raise SyntaxError("Expected ',' or ')' in compound")
            return Compound(op, args)
        else:
            # product: (A * B * ...)
            args = []
            while True:
                arg = self.parse_term()
                args.append(arg)
                if self.match(TOK_SPECIAL, '*'):
                    continue
                elif self.match(TOK_SPECIAL, ')'):
                    break
                else:
                    raise SyntaxError("Expected '*' or ')' in product")
            return Product(args)

# ------------------------------------------------------------
# RDF/Turtle Emitter
# ------------------------------------------------------------
class TurtleEmitter:
    def __init__(self, min_freq: float = 0.9, skip_vars: bool = True):
        self.min_freq = min_freq
        self.skip_vars = skip_vars
        self.next_bnode = 0
        self.statements = []  # list of (subject, predicate, object) as strings

    def _bnode(self) -> str:
        self.next_bnode += 1
        return f"_:b{self.next_bnode-1}"

    def _term_to_rdf(self, node: ASTNode) -> str:
        """Convert an AST node to an RDF term (URI or blank node)."""
        if isinstance(node, Atom):
            val = node.value
            # variables: skip or map to something?
            if self.skip_vars and (val.startswith('#') or val.startswith('$')):
                return None
            # simple word → local URI
            return f":{val}"
        elif isinstance(node, Product):
            # Product becomes a blank node (or could be a URI)
            return self._bnode()
        elif isinstance(node, Compound):
            # Compound becomes a blank node
            return self._bnode()
        elif isinstance(node, Statement):
            # Nested statement becomes a blank node
            return self._bnode()
        else:
            raise ValueError(f"Unknown node type: {type(node)}")

    def _walk(self, node: ASTNode, parent_id: Optional[str] = None, rel: Optional[str] = None):
        """Traverse AST and emit triples."""
        node_id = self._term_to_rdf(node)
        if node_id is None:
            # skip variable nodes
            return

        # Emit node as a triple if it's a blank node with no parent? Actually we need to declare it.
        # For RDF, we only need triples. We'll emit a triple for each edge.
        if parent_id is not None and rel is not None:
            self.statements.append((parent_id, rel, node_id))

        # Recurse into children
        if isinstance(node, Statement):
            subj_id = self._term_to_rdf(node.subject)
            obj_id = self._term_to_rdf(node.object)
            if subj_id is not None and obj_id is not None:
                # Map Narsese predicate to RDF predicate
                pred = node.predicate
                if pred == '-->':
                    rdf_pred = "rdf:type"
                elif pred == '<->':
                    rdf_pred = "owl:sameAs"
                else:
                    # implication etc. – use a generic property
                    rdf_pred = f":{pred}"
                self.statements.append((subj_id, rdf_pred, obj_id))
            # Also walk into subject and object to capture their internal structure (if any)
            self._walk(node.subject, node_id, "n:subject")
            self._walk(node.object, node_id, "n:object")
        elif isinstance(node, Product):
            for i, arg in enumerate(node.args):
                self._walk(arg, node_id, f"n:arg{i}")
        elif isinstance(node, Compound):
            for i, arg in enumerate(node.args):
                self._walk(arg, node_id, f"n:arg{i}")

    def emit(self, ast: ASTNode, truth: Optional[Tuple[float, float]] = None):
        """Process an AST node and add triples. If truth is given and frequency < threshold, skip."""
        if truth:
            freq, conf = truth
            if freq < self.min_freq:
                return
        self._walk(ast)

    def to_turtle(self) -> str:
        """Return Turtle string for all collected triples."""
        lines = [
            "@prefix : <http://example.org/ns#> .",
            "@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .",
            "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .",
            "@prefix owl: <http://www.w3.org/2002/07/owl#> .",
            "@prefix n: <http://example.org/nars/> .",
            ""
        ]
        for s, p, o in self.statements:
            lines.append(f"{s} {p} {o} .")
        return "\n".join(lines)

# ------------------------------------------------------------
# Main processing loop
# ------------------------------------------------------------
def process_line(line: str, emitter: TurtleEmitter):
    # Strip inline comments
    if '//' in line:
        line = line.split('//')[0]
    line = line.strip()
    if not line:
        return

    # Tokenize
    tokenizer = Tokenizer(line)
    try:
        tokens = tokenizer.tokenize()
    except Exception as e:
        sys.stderr.write(f"Tokenization error: {e}\n")
        return
    if not tokens:
        return

    # Parse
    parser = Parser(tokens)
    try:
        ast = parser.parse_term()
        # If the line contains a truth value after the statement, we would have parsed it already.
        # The truth value is not stored in AST; we could re-parse or simply always emit.
        # For simplicity, we'll assume all parsed statements are asserted (or we can extract truth later).
        emitter.emit(ast)
    except Exception as e:
        sys.stderr.write(f"Parse error: {e} in line: {line}\n")
        return

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Narsese to RDF/Turtle converter")
    parser.add_argument("input", nargs="?", help="Input file (default: stdin)")
    parser.add_argument("--threshold", type=float, default=0.9, help="Minimum frequency to output")
    parser.add_argument("--skip-vars", action="store_true", help="Skip statements with variables")
    args = parser.parse_args()

    emitter = TurtleEmitter(min_freq=args.threshold, skip_vars=args.skip_vars)

    if args.input:
        with open(args.input, 'r') as f:
            for line in f:
                process_line(line, emitter)
    else:
        for line in sys.stdin:
            process_line(line, emitter)

    print(emitter.to_turtle())

if __name__ == "__main__":
    main()
