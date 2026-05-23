#!/usr/bin/env python3
"""
morphology_to_nal.py - Recursive parser for Latin morphology XML (from stdin) to Narsese.
Handles multiple concatenated XML fragments by wrapping them in a single root.
Supports translation of attribute names and values into English (default) or Portuguese.
Usage: cat morphology_extended.xml | python morphology_to_nal.py [--lang {en,pt}]
"""

import sys
import xml.etree.ElementTree as ET
import re
import argparse

# ----------------------------------------------------------------------
# Translation tables for morphological VALUES (English/technical -> Portuguese)
# ----------------------------------------------------------------------
VALUE_TRANSLATIONS = {
    'case': {
        'nominative': 'nominativo', 'genitive': 'genitivo', 'dative': 'dativo',
        'accusative': 'acusativo', 'ablative': 'ablativo', 'vocative': 'vocativo',
        'locative': 'locativo', 'nom': 'nominativo', 'gen': 'genitivo',
        'dat': 'dativo', 'acc': 'acusativo', 'abl': 'ablativo', 'voc': 'vocativo',
        'loc': 'locativo'
    },
    'num': {
        'singular': 'singular', 'plural': 'plural',
        'sg': 'singular', 'pl': 'plural'
    },
    'gend': {
        'masculine': 'masculino', 'feminine': 'feminino', 'neuter': 'neutro',
        'masc': 'masculino', 'fem': 'feminino', 'neut': 'neutro'
    },
    'mood': {
        'indicative': 'indicativo', 'subjunctive': 'subjuntivo', 'imperative': 'imperativo',
        'infinitive': 'infinitivo', 'participle': 'particípio', 'gerund': 'gerúndio',
        'supine': 'supino', 'ind': 'indicativo', 'subj': 'subjuntivo', 'imp': 'imperativo',
        'inf': 'infinitivo', 'part': 'particípio', 'ger': 'gerúndio',
        'gerundive': 'gerundivo'   # <-- NOVO
    },
    'tense': {
        'present': 'presente', 'imperfect': 'imperfeito', 'future': 'futuro',
        'perfect': 'perfeito', 'pluperfect': 'mais-que-perfeito', 'future perfect': 'futuro perfeito',
        'pres': 'presente', 'imperf': 'imperfeito', 'fut': 'futuro', 'perf': 'perfeito',
        'plup': 'mais-que-perfeito', 'futperf': 'futuro perfeito'
    },
    'voice': {
        'active': 'ativo', 'passive': 'passivo',
        'act': 'ativo', 'pass': 'passivo'
    },
    'pers': {
        '1st': 'primeira', '2nd': 'segunda', '3rd': 'terceira',
        'first': 'primeira', 'second': 'segunda', 'third': 'terceira',
        '1': 'primeira', '2': 'segunda', '3': 'terceira'
    },
    'pofs': {
        'noun': 'substantivo', 'verb': 'verbo', 'adjective': 'adjetivo',
        'adverb': 'advérbio', 'pronoun': 'pronome', 'conjunction': 'conjunção',
        'preposition': 'preposição', 'interjection': 'interjeição',
        'verb_participle': 'particípio'
    },
    'decl': {
        '1st': 'primeira_declinacao', '2nd': 'segunda_declinacao', '3rd': 'terceira_declinacao', '4th': 'quarta_declinacao', '5th': 'quinta_declinacao',
        'first': '1ª', 'second': '2ª', 'third': '3ª', 'fourth': '4ª', 'fifth': '5ª',
        '1': '1ª', '2': '2ª', '3': '3ª', '4': '4ª', '5': '5ª'
    },
    'stemtype': {
        'pp4': 'participio_perfeito_4',
        'conj': 'conjuncao_tematica',
        'adverb': 'advérbio',
        'conj1': 'conjugacao_1',
        'irreg_adj3': 'adjetivo_irregular_3',
        'pron3': 'pronome_3',
        'are_vb': 'verbo_are',
        'irreg_comp_indeclform': 'irregular_comparativo_indeclinavel',
        'conj3': 'conjugacao_3',               # NOVO
        'irreg_pp1': 'irregular_participio_perfeito_1',  # NOVO
        'demonstr': 'demonstrativo',           # NOVO
        'pron1': 'pronome_1',                  # NOVO
        'pron2': 'pronome_2',                  # NOVO
        'us_i': 'us_i'                         # mantém como código (não é inglês)
    },
    'morph': {
        'indeclform': 'indeclinavel',
        'irreg_comp_indeclform': 'irregular_comparativo_indeclinavel'
    },
    'derivtype': {
        'are_vb': 'verbo_are'
    }
}

# ----------------------------------------------------------------------
# Translation for ATTRIBUTE NAMES (the keys in the Narsese statement)
# ----------------------------------------------------------------------
ATTR_TRANSLATION = {
    'case': 'caso',
    'num': 'numero',
    'lemma': 'lema',
    'stemtype': 'tipo_de_tema',
    'mood': 'modo',
    'tense': 'tempo',
    'voice': 'voz',
    'pers': 'pessoa',
    'pofs': 'classe_gramatical',
    'decl': 'declinacao',
    'gend': 'genero',
    'morph': 'morfologia',
    'derivtype': 'tipo_derivacao'
}

def translate_value(attr: str, value: str, target_lang: str) -> str:
    """Return translated morphological value if target_lang is 'pt' and mapping exists."""
    if target_lang != 'pt':
        return value
    if attr in VALUE_TRANSLATIONS and value in VALUE_TRANSLATIONS[attr]:
        return VALUE_TRANSLATIONS[attr][value]
    return value

def translate_attr(attr: str, target_lang: str) -> str:
    """Return translated attribute name (e.g., 'case' -> 'caso') if lang == 'pt'."""
    if target_lang != 'pt':
        return attr
    return ATTR_TRANSLATION.get(attr, attr)

def normalize_term(value: str, attr: str = None, lang: str = 'en') -> str:
    """Clean a morphological value into a valid Narsese atomic term."""
    if not value:
        return "unknown"
    term = re.sub(r'[\s\-&]+', '_', value.strip())
    term = re.sub(r'[^\w_]', '', term, flags=re.UNICODE)
    term = term.lower()
    if attr and lang != 'en':
        term = translate_value(attr, term, lang)
    return term

def extract_attributes(element, word_form: str, statements: set, lang: str):
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
                    norm_val = normalize_term(value, attr, lang)
                    attr_name = translate_attr(attr, lang)
                    stmt = f"< ({word_form} * {{{attr_name}}}) --> {norm_val} >."
                    statements.add(stmt)

        if element.tag == 'dict':
            hdwd = element.find('hdwd')
            if hdwd is not None and hdwd.text:
                lemma = hdwd.text.strip()
                lemma_clean = re.sub(r'#\d+$', '', lemma)
                # Lemma value is never translated (remains Latin)
                norm_lemma = normalize_term(lemma_clean, attr=None, lang='en')
                attr_name = translate_attr('lemma', lang)
                stmt = f"< ({word_form} * {{{attr_name}}}) --> {norm_lemma} >."
                statements.add(stmt)

    for child in element:
        extract_attributes(child, word_form, statements, lang)

def generate_narsese_from_xml(xml_data: str, lang: str = 'en') -> list:
    """Parse XML (possibly with multiple roots) and return sorted Narsese statements."""
    xml_data = xml_data.strip()
    if not xml_data.startswith('<?xml'):
        xml_data = f"<root>{xml_data}</root>"
    else:
        match = re.match(r'(<\?xml[^?]*\?>)\s*(.*)', xml_data, re.DOTALL)
        if match:
            decl, rest = match.groups()
            xml_data = f"{decl}<root>{rest}</root>"
        else:
            xml_data = f"<root>{xml_data}</root>"

    try:
        root = ET.fromstring(xml_data)
    except ET.ParseError as e:
        xml_data = re.sub(r'<\?xml[^?]*\?>', '', xml_data)
        xml_data = f"<root>{xml_data}</root>"
        root = ET.fromstring(xml_data)

    statements = set()
    for word_elem in root.findall('.//word'):
        form_elem = word_elem.find('form')
        if form_elem is None or form_elem.text is None:
            continue
        latin_word = form_elem.text.strip().rstrip(',')
        extract_attributes(word_elem, latin_word, statements, lang)

    return sorted(statements)

def main():
    parser = argparse.ArgumentParser(
        description="Convert Latin morphology XML to Narsese, with optional translation to Portuguese."
    )
    parser.add_argument(
        '--lang', choices=['en', 'pt'], default='pt',
        help="Output language for attribute names and values: English (default) or Portuguese."
    )
    args = parser.parse_args()

    xml_data = sys.stdin.read()
    if not xml_data.strip():
        print("// Error: No input received on stdin.", file=sys.stderr)
        sys.exit(1)

    try:
        narsese_statements = generate_narsese_from_xml(xml_data, lang=args.lang)
        for stmt in narsese_statements:
            print(stmt)
    except ET.ParseError as e:
        print(f"// XML parsing error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
