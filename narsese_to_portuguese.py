#!/usr/bin/env python3
"""
 * The MIT License
 *
 * Copyright 2020 The OpenNARS authors.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 * """

import sys
import re

GREEN = "\x1B[32m"
YELLOW = "\x1B[33m"
CYAN = "\x1B[36m"
MAGENTA = "\x1B[35m"
RED = "\x1B[31m"
RESET = "\x1B[0m"
BOLD = "\x1B[1m"
STATEMENT_OPENER = ""
STATEMENT_CLOSER = ""

def narseseToPortuguese_noColors():
    global GREEN, YELLOW, CYAN, MAGENTA, RED, RESET, BOLD
    GREEN = ""
    YELLOW = ""
    CYAN = ""
    MAGENTA = ""
    RED = ""
    RESET = ""
    BOLD = ""

if "noColors" in sys.argv:
    narseseToPortuguese_noColors()

def narseseToPortuguese(line):
    COLOR = GREEN
    line = line.rstrip().replace("(! ", CYAN + "não " + COLOR).replace("#1", "ele").replace("$1", "ele").replace("#2", "coisa").replace("$2", "coisa")
    if line.startswith("performing ") or line.startswith("done with"):
        COLOR = CYAN
    elif line.startswith("Comment: expected:"):
        COLOR = BOLD + MAGENTA
    elif line.startswith("Comment:") or line.startswith("//"):
        COLOR = MAGENTA
    elif line.startswith("Input:"):
        COLOR = GREEN
    elif line.startswith("Derived:") or line.startswith("Revised:"):
        COLOR = YELLOW
    elif line.startswith("Answer:") or line.startswith("^") or "decision expectation" in line:
        COLOR = BOLD + RED
    if not (" | " in line or " \\1 " in line or " \\2 " in line or " - " in line or " ~ " in line):
        # Conjuntos extensão e intensão
        l = re.sub(r"{([^><:\(\)\*]*)}", MAGENTA + r"" + GREEN + r"\1" + MAGENTA + "" + COLOR, line)
        l = re.sub(r"\[([^><:\(\)\*]*)\]", MAGENTA + r"" + GREEN + r"\1" + MAGENTA + "" + COLOR, l)
        # Imagem
        l = re.sub(r"\(([^><:]*)\s(/1|\\1|/2|\\1|\\2)\s([^><:]*)\)", YELLOW + r"" + GREEN + r"\1" + YELLOW + r" \2 " + GREEN + r"\3" + YELLOW + "" + COLOR, l)
        # Implicação
        l = re.sub(r"<([^:]*)\s=(/|=|\|)>\s([^:]*)>", CYAN + STATEMENT_OPENER + GREEN + r"\1" + CYAN + r" leva a " + GREEN + r"\3" + CYAN + STATEMENT_CLOSER + COLOR, l)
        # Conjunção
        l = re.sub(r"\(([^:]*)\s&(/|&|\|)\s([^:]*)\)", MAGENTA + r"" + GREEN + r"\1" + MAGENTA + r" e " + GREEN + r"\3" + MAGENTA + "" + COLOR, l)
        # Similaridade e herança
        l = re.sub(r"<([^><:]*)\s(-->)\s([^><:]*)>", RED + STATEMENT_OPENER + GREEN + r"\1" + RED + r" é " + GREEN + r"\3" + RED + STATEMENT_CLOSER + COLOR, l)
        l = re.sub(r"<([^><:]*)\s(<->)\s([^><:]*)>", RED + STATEMENT_OPENER + GREEN + r"\1" + RED + r" se assemelha a " + GREEN + r"\3" + RED + STATEMENT_CLOSER + COLOR, l)
        # Outros termos compostos (não de ordem superior)
        l = re.sub(r"\(([^><:]*)\s(\*|&)\s([^><:]*)\)", YELLOW + r"" + GREEN + r"\1" + YELLOW + r" " + GREEN + r"\3" + YELLOW + "" + COLOR, l)
        return COLOR + l.replace(")", "").replace("(", "").replace("||", MAGENTA + "ou" + COLOR).replace("==>", CYAN + "implica" + COLOR).replace("<=>", CYAN + "equivale a" + COLOR).replace(">", "").replace("<", "").replace("&/", "e").replace(" * ", " ").replace(" & ", " ").replace(" /1", "").replace("/2", "por") + RESET
    return ""

if __name__ == "__main__":
    for line in sys.stdin:
        line = narseseToPortuguese(line)
        if line != "":
            print(line)
            sys.stdout.flush()
