#!/usr/bin/env python3
"""
morphology_to_nal.py - Recursive parser for Latin morphology XML (from stdin) to Narsese.
Handles multiple concatenated XML fragments by wrapping them in a single root.
Usage: cat morphology_extended.xml | python morphology_to_nal.py
"""

import sys
import xml.etree.ElementTree as ET
import re

def normalize_term(value: str) -> str:
    """Clean a morphological value into a valid Narsese atomic term."""
    if not value:
        return "unknown"
    term = re.sub(r'[\s\-&]+', '_', value.strip())
    term = re.sub(r'[^\w_]', '', term)
    return term.lower()

def extract_attributes(element, word_form: str, statements: set):
    """Recursively traverse XML element and extract morphological attributes."""
    if element.tag in ('infl', 'dict'):
        for attr in ['pofs', 'decl', 'case', 'num', 'mood', 'pers', 'tense',
                     'voice', 'stemtype', 'morph', 'derivtype', 'gend']:
            elem = element.find(attr)
            if elem is not None and elem.text:
                value = elem.text.strip()
                if value and value.lower() not in ('', 'unknown'):
                    if attr == 'gend' and value.lower() == 'adverbial':
                        value = 'adverb'
                    stmt = f"< ({word_form} * {{{attr}}}) --> {normalize_term(value)} >."
                    statements.add(stmt)

        if element.tag == 'dict':
            hdwd = element.find('hdwd')
            if hdwd is not None and hdwd.text:
                lemma = hdwd.text.strip()
                lemma_clean = re.sub(r'#\d+$', '', lemma)
                stmt = f"< ({word_form} * {{lemma}}) --> {normalize_term(lemma_clean)} >."
                statements.add(stmt)

    for child in element:
        extract_attributes(child, word_form, statements)

def generate_narsese_from_xml(xml_data: str) -> list:
    """Parse XML (possibly with multiple roots) and return sorted Narsese statements."""
    # Wrap the content in a single root if it doesn't have a single root already
    xml_data = xml_data.strip()
    if not xml_data.startswith('<?xml'):
        # Simple check: if we see multiple top-level elements, wrap them
        # We'll wrap everything in a <root> tag.
        xml_data = f"<root>{xml_data}</root>"
    else:
        # If there's an XML declaration, we need to insert root after it
        import re
        match = re.match(r'(<\?xml[^?]*\?>)\s*(.*)', xml_data, re.DOTALL)
        if match:
            decl, rest = match.groups()
            xml_data = f"{decl}<root>{rest}</root>"
        else:
            xml_data = f"<root>{xml_data}</root>"

    try:
        root = ET.fromstring(xml_data)
    except ET.ParseError as e:
        # If still failing, try a more aggressive repair: remove all XML declarations
        import re
        xml_data = re.sub(r'<\?xml[^?]*\?>', '', xml_data)
        xml_data = f"<root>{xml_data}</root>"
        root = ET.fromstring(xml_data)

    statements = set()
    # Now find all <word> elements (they may be at any depth due to the wrapper)
    for word_elem in root.findall('.//word'):
        form_elem = word_elem.find('form')
        if form_elem is None or form_elem.text is None:
            continue
        latin_word = form_elem.text.strip().rstrip(',')
        extract_attributes(word_elem, latin_word, statements)

    return sorted(statements)

def main():
    xml_data = sys.stdin.read()
    if not xml_data.strip():
        print("// Error: No input received on stdin.", file=sys.stderr)
        sys.exit(1)

    try:
        narsese_statements = generate_narsese_from_xml(xml_data)
        for stmt in narsese_statements:
            print(stmt)
    except ET.ParseError as e:
        print(f"// XML parsing error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
