/*
 * filter_derived.c - Filter NARS derived statements by priority, frequency, confidence.
 * Compile: gcc -O2 -o filter_derived filter_derived.c
 * Usage: ./filter_derived [--min-priority P] [--min-frequency F] [--min-confidence C]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define LINE_MAX 4096

/* Parse a floating point number from a string, skipping leading/trailing spaces */
double parse_double(const char *s) {
    char *end;
    double val = strtod(s, &end);
    return val;
}

/* Extract the value after a key like "Priority=", "frequency=", "confidence=".
   Returns 0.0 if not found or invalid. */
double extract_value(const char *line, const char *key) {
    const char *p = strstr(line, key);
    if (!p) return 0.0;
    p += strlen(key);
    /* Skip any spaces? The pattern is usually "key=value". No spaces, but safe. */
    while (*p == ' ') p++;
    /* Read the number until a space or comma or end of line */
    char num_buf[64];
    int i = 0;
    while (*p && !isspace(*p) && *p != ',' && i < 63) {
        num_buf[i++] = *p++;
    }
    num_buf[i] = '\0';
    return parse_double(num_buf);
}

int main(int argc, char *argv[]) {
    double min_priority = 0.0;
    double min_frequency = 0.0;
    double min_confidence = 0.0;

    /* Parse command line arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--min-priority") == 0 && i+1 < argc) {
            min_priority = parse_double(argv[++i]);
        } else if (strcmp(argv[i], "--min-frequency") == 0 && i+1 < argc) {
            min_frequency = parse_double(argv[++i]);
        } else if (strcmp(argv[i], "--min-confidence") == 0 && i+1 < argc) {
            min_confidence = parse_double(argv[++i]);
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            return 1;
        }
    }

    /* Force line buffering for stdout to work well in pipelines */
    setvbuf(stdout, NULL, _IOLBF, 0);

    char line[LINE_MAX];
    while (fgets(line, sizeof(line), stdin)) {
        /* Check if line starts with "Derived:" (case sensitive) */
        if (strncmp(line, "Derived:", 8) == 0) {
            double pri = extract_value(line, "Priority=");
            double freq = extract_value(line, "frequency=");
            double conf = extract_value(line, "confidence=");
            if (pri >= min_priority && freq >= min_frequency && conf >= min_confidence) {
                fputs(line, stdout);
            }
        } else {
            /* Pass through all other lines unchanged */
            fputs(line, stdout);
        }
    }
    return 0;
}
