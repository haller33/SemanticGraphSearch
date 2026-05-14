/*
 * narsese2json.c – Convert Narsese statements to JSON Lines (graph operations)
 * Compile: gcc -O2 -o narsese2json narsese2json.c -lm
 * Usage: ./narsese2json [--tag TAG] < input.nal
 *
 * Output matches the Python implementation narsese2json.v3.py exactly.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdbool.h>
#include <stdarg.h>

#define MAX_TOKEN_LEN 256
#define MAX_LINE_LEN  65536
#define MAX_ARGS      32
#define HASH_SIZE     4096

// ------------------------------------------------------------
// Dynamic string builder
// ------------------------------------------------------------
typedef struct {
    char *buf;
    size_t len;
    size_t cap;
} StringBuilder;

void sb_init(StringBuilder *sb) {
    sb->buf = malloc(64);
    sb->buf[0] = '\0';
    sb->len = 0;
    sb->cap = 64;
}

void sb_append(StringBuilder *sb, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int need = vsnprintf(NULL, 0, fmt, args) + 1;
    va_end(args);
    if (sb->len + need >= sb->cap) {
        sb->cap = sb->len + need + 64;
        sb->buf = realloc(sb->buf, sb->cap);
    }
    va_start(args, fmt);
    vsnprintf(sb->buf + sb->len, need, fmt, args);
    va_end(args);
    sb->len += need - 1;
}

void sb_free(StringBuilder *sb) {
    free(sb->buf);
}

// ------------------------------------------------------------
// Tokenizer
// ------------------------------------------------------------
typedef enum {
    TOK_WHITESPACE,
    TOK_COMMENT,
    TOK_NUMBER,
    TOK_ATOM,
    TOK_VAR,
    TOK_WILDCARD,
    TOK_BRACE,
    TOK_OP,
    TOK_SPECIAL
} TokenType;

typedef struct {
    TokenType type;
    char value[MAX_TOKEN_LEN];
} Token;

typedef struct {
    Token *tokens;
    int count;
    int capacity;
} TokenList;

void token_list_init(TokenList *list) {
    list->tokens = NULL;
    list->count = 0;
    list->capacity = 0;
}

void token_list_add(TokenList *list, TokenType type, const char *value) {
    if (list->count >= list->capacity) {
        list->capacity = list->capacity ? list->capacity * 2 : 64;
        list->tokens = realloc(list->tokens, list->capacity * sizeof(Token));
    }
    Token *t = &list->tokens[list->count++];
    t->type = type;
    strncpy(t->value, value, MAX_TOKEN_LEN - 1);
    t->value[MAX_TOKEN_LEN-1] = '\0';
}

void token_list_free(TokenList *list) {
    free(list->tokens);
    list->tokens = NULL;
    list->count = list->capacity = 0;
}

void tokenize(const char *line, TokenList *tokens) {
    int i = 0;
    int len = strlen(line);
    token_list_init(tokens);
    
    while (i < len) {
        char c = line[i];
        if (isspace(c)) { i++; continue; }
        if (c == '/' && i+1 < len && line[i+1] == '/') break;
        if (isdigit(c) || (c == '.' && i+1 < len && isdigit(line[i+1]))) {
            int start = i;
            while (i < len && (isdigit(line[i]) || line[i] == '.')) i++;
            char buf[MAX_TOKEN_LEN];
            snprintf(buf, sizeof(buf), "%.*s", i-start, line+start);
            token_list_add(tokens, TOK_NUMBER, buf);
            continue;
        }
        // multi-char operators
        if (strncmp(line+i, "-->", 3) == 0) { token_list_add(tokens, TOK_OP, "-->"); i+=3; continue; }
        if (strncmp(line+i, "<->", 3) == 0) { token_list_add(tokens, TOK_OP, "<->"); i+=3; continue; }
        if (strncmp(line+i, "==>", 3) == 0) { token_list_add(tokens, TOK_OP, "==>"); i+=3; continue; }
        if (strncmp(line+i, "<=>", 3) == 0) { token_list_add(tokens, TOK_OP, "<=>"); i+=3; continue; }
        if (strncmp(line+i, "=/>", 3) == 0) { token_list_add(tokens, TOK_OP, "=/>"); i+=3; continue; }
        if (strncmp(line+i, "&&", 2) == 0)  { token_list_add(tokens, TOK_OP, "&&");  i+=2; continue; }
        if (strncmp(line+i, "||", 2) == 0)  { token_list_add(tokens, TOK_OP, "||");  i+=2; continue; }
        if (strncmp(line+i, "&/", 2) == 0)  { token_list_add(tokens, TOK_OP, "&/");  i+=2; continue; }
        if (strncmp(line+i, "--", 2) == 0)  { token_list_add(tokens, TOK_OP, "--");  i+=2; continue; }
        if (c == '#' || c == '$') {
            int start = i;
            i++;
            while (i < len && isdigit(line[i])) i++;
            char buf[MAX_TOKEN_LEN];
            snprintf(buf, sizeof(buf), "%.*s", i-start, line+start);
            token_list_add(tokens, TOK_VAR, buf);
            continue;
        }
        if (c == '_') {
            token_list_add(tokens, TOK_WILDCARD, "_");
            i++;
            continue;
        }
        if (c == '{') {
            int start = i, depth = 1;
            i++;
            while (i < len && depth > 0) {
                if (line[i] == '{') depth++;
                else if (line[i] == '}') depth--;
                i++;
            }
            char buf[MAX_TOKEN_LEN];
            snprintf(buf, sizeof(buf), "%.*s", i-start, line+start);
            token_list_add(tokens, TOK_BRACE, buf);
            continue;
        }
        // BRACKET: extract inner content as an ATOM (no brackets)
        if (c == '[') {
            int start = i;
            int depth = 1;
            i++;
            while (i < len && depth > 0) {
                if (line[i] == '[') depth++;
                else if (line[i] == ']') depth--;
                i++;
            }
            int inner_start = start + 1;
            int inner_len = (i - 1) - inner_start;
            if (inner_len > 0) {
                char inner[MAX_TOKEN_LEN];
                snprintf(inner, sizeof(inner), "%.*s", inner_len, line + inner_start);
                // trim spaces
                char *p = inner;
                while (*p == ' ') p++;
                char *end = p + strlen(p) - 1;
                while (end > p && *end == ' ') end--;
                *(end + 1) = '\0';
                token_list_add(tokens, TOK_ATOM, p);
            } else {
                token_list_add(tokens, TOK_ATOM, "");
            }
            continue;
        }
        if (isalpha(c) || c == '_') {
            int start = i;
            while (i < len && (isalnum(line[i]) || line[i] == '_')) i++;
            char buf[MAX_TOKEN_LEN];
            snprintf(buf, sizeof(buf), "%.*s", i-start, line+start);
            token_list_add(tokens, TOK_ATOM, buf);
            continue;
        }
        if (strchr("<>(),.;?!%~*=", c)) {
            char buf[2] = {c, 0};
            token_list_add(tokens, TOK_SPECIAL, buf);
            i++;
            continue;
        }
        i++; // skip unknown
    }
}

// ------------------------------------------------------------
// AST nodes
// ------------------------------------------------------------
typedef struct ASTNode {
    enum { NODE_ATOM, NODE_STMT, NODE_COMPOUND, NODE_PRODUCT } type;
    char *atom;
    struct ASTNode *left, *right;
    char *rel;
    char *op;
    struct ASTNode **args;
    int arg_count;
} ASTNode;

ASTNode* new_atom(const char *s) {
    ASTNode *n = calloc(1, sizeof(ASTNode));
    n->type = NODE_ATOM;
    n->atom = strdup(s);
    return n;
}

ASTNode* new_stmt(ASTNode *left, const char *rel, ASTNode *right) {
    ASTNode *n = calloc(1, sizeof(ASTNode));
    n->type = NODE_STMT;
    n->left = left;
    n->right = right;
    n->rel = strdup(rel);
    return n;
}

ASTNode* new_compound(const char *op, ASTNode **args, int arg_count) {
    ASTNode *n = calloc(1, sizeof(ASTNode));
    n->type = NODE_COMPOUND;
    n->op = strdup(op);
    n->args = malloc(arg_count * sizeof(ASTNode*));
    for (int i = 0; i < arg_count; i++) n->args[i] = args[i];
    n->arg_count = arg_count;
    return n;
}

ASTNode* new_product(ASTNode **args, int arg_count) {
    ASTNode *n = calloc(1, sizeof(ASTNode));
    n->type = NODE_PRODUCT;
    n->args = malloc(arg_count * sizeof(ASTNode*));
    for (int i = 0; i < arg_count; i++) n->args[i] = args[i];
    n->arg_count = arg_count;
    return n;
}

void free_ast(ASTNode *node) {
    if (!node) return;
    if (node->type == NODE_ATOM) {
        free(node->atom);
    } else if (node->type == NODE_STMT) {
        free_ast(node->left);
        free_ast(node->right);
        free(node->rel);
    } else if (node->type == NODE_COMPOUND || node->type == NODE_PRODUCT) {
        for (int i = 0; i < node->arg_count; i++) free_ast(node->args[i]);
        free(node->args);
        if (node->type == NODE_COMPOUND) free(node->op);
    }
    free(node);
}

// ------------------------------------------------------------
// Parser
// ------------------------------------------------------------
typedef struct {
    Token *tokens;
    int pos;
    int count;
} Parser;

void parser_init(Parser *p, TokenList *tokens) {
    p->tokens = tokens->tokens;
    p->pos = 0;
    p->count = tokens->count;
}

Token* peek(Parser *p) {
    return p->pos < p->count ? &p->tokens[p->pos] : NULL;
}

Token* consume(Parser *p) {
    return p->pos < p->count ? &p->tokens[p->pos++] : NULL;
}

bool match(Parser *p, TokenType type, const char *value) {
    Token *t = peek(p);
    if (t && t->type == type && (!value || strcmp(t->value, value) == 0)) {
        consume(p);
        return true;
    }
    return false;
}

ASTNode* parse_term(Parser *p);
ASTNode* parse_statement(Parser *p);
ASTNode* parse_compound(Parser *p);

ASTNode* parse_term(Parser *p) {
    Token *t = peek(p);
    if (!t) return NULL;
    if (t->type == TOK_ATOM || t->type == TOK_BRACE || t->type == TOK_NUMBER ||
        t->type == TOK_VAR || t->type == TOK_WILDCARD) {
        consume(p);
        return new_atom(t->value);
    }
    if (t->type == TOK_SPECIAL && strcmp(t->value, "<") == 0)
        return parse_statement(p);
    if (t->type == TOK_SPECIAL && strcmp(t->value, "(") == 0)
        return parse_compound(p);
    fprintf(stderr, "Parse error: unexpected token %s\n", t->value);
    return NULL;
}

ASTNode* parse_statement(Parser *p) {
    if (!match(p, TOK_SPECIAL, "<")) return NULL;
    ASTNode *left = parse_term(p);
    if (!left) return NULL;
    char *rel = NULL;
    Token *t = peek(p);
    if (t && t->type == TOK_OP && (strcmp(t->value, "-->") == 0 || strcmp(t->value, "<->") == 0 ||
                                   strcmp(t->value, "==>") == 0 || strcmp(t->value, "<=>") == 0 ||
                                   strcmp(t->value, "=/>") == 0)) {
        rel = strdup(t->value);
        consume(p);
    } else {
        if (match(p, TOK_SPECIAL, ">")) {
            t = peek(p);
            if (t && t->type == TOK_SPECIAL && (strcmp(t->value, ".") == 0 ||
                strcmp(t->value, "?") == 0 || strcmp(t->value, "!") == 0))
                consume(p);
            return left;
        } else {
            free_ast(left);
            return NULL;
        }
    }
    ASTNode *right = parse_term(p);
    if (!right) { free(rel); free_ast(left); return NULL; }
    if (!match(p, TOK_SPECIAL, ">")) { free(rel); free_ast(left); free_ast(right); return NULL; }
    t = peek(p);
    if (t && t->type == TOK_SPECIAL && (strcmp(t->value, ".") == 0 ||
        strcmp(t->value, "?") == 0 || strcmp(t->value, "!") == 0))
        consume(p);
    ASTNode *stmt = new_stmt(left, rel, right);
    free(rel);
    return stmt;
}

ASTNode* parse_compound(Parser *p) {
    if (!match(p, TOK_SPECIAL, "(")) return NULL;
    Token *t = peek(p);
    if (t && t->type == TOK_OP) {
        char *op = strdup(t->value);
        consume(p);
        if (!match(p, TOK_SPECIAL, ",")) { free(op); return NULL; }
        ASTNode **args = NULL;
        int arg_count = 0;
        while (1) {
            ASTNode *arg = parse_term(p);
            if (!arg) {
                for (int i=0; i<arg_count; i++) free_ast(args[i]);
                free(args); free(op);
                return NULL;
            }
            args = realloc(args, (arg_count+1) * sizeof(ASTNode*));
            args[arg_count++] = arg;
            t = peek(p);
            if (t && t->type == TOK_SPECIAL && strcmp(t->value, ",") == 0) {
                consume(p);
                continue;
            } else if (t && t->type == TOK_SPECIAL && strcmp(t->value, ")") == 0) {
                consume(p);
                break;
            } else {
                for (int i=0; i<arg_count; i++) free_ast(args[i]);
                free(args); free(op);
                return NULL;
            }
        }
        ASTNode *node = new_compound(op, args, arg_count);
        free(op); free(args);
        return node;
    } else {
        ASTNode *first = parse_term(p);
        if (!first) return NULL;
        ASTNode **args = malloc(sizeof(ASTNode*));
        args[0] = first;
        int arg_count = 1;
        while (match(p, TOK_SPECIAL, "*")) {
            ASTNode *next = parse_term(p);
            if (!next) {
                for (int i=0; i<arg_count; i++) free_ast(args[i]);
                free(args);
                return NULL;
            }
            args = realloc(args, (arg_count+1) * sizeof(ASTNode*));
            args[arg_count++] = next;
        }
        if (!match(p, TOK_SPECIAL, ")")) {
            for (int i=0; i<arg_count; i++) free_ast(args[i]);
            free(args);
            return NULL;
        }
        ASTNode *node = new_product(args, arg_count);
        free(args);
        return node;
    }
}

// ------------------------------------------------------------
// Hash set for node deduplication
// ------------------------------------------------------------
typedef struct HashSet {
    char **entries;
    int size;
} HashSet;

void hash_set_init(HashSet *set) {
    set->entries = calloc(HASH_SIZE, sizeof(char*));
    set->size = HASH_SIZE;
}

unsigned int hash(const char *str) {
    unsigned int h = 5381;
    int c;
    while ((c = *str++)) h = ((h << 5) + h) + c;
    return h % HASH_SIZE;
}

bool hash_set_contains(HashSet *set, const char *key) {
    unsigned int idx = hash(key);
    unsigned int start = idx;
    while (set->entries[idx]) {
        if (strcmp(set->entries[idx], key) == 0) return true;
        idx = (idx + 1) % HASH_SIZE;
        if (idx == start) break;
    }
    return false;
}

void hash_set_add(HashSet *set, const char *key) {
    if (hash_set_contains(set, key)) return;
    unsigned int idx = hash(key);
    while (set->entries[idx]) idx = (idx + 1) % HASH_SIZE;
    set->entries[idx] = strdup(key);
}

void hash_set_free(HashSet *set) {
    for (int i = 0; i < HASH_SIZE; i++) free(set->entries[i]);
    free(set->entries);
}

// ------------------------------------------------------------
// JSON emitter
// ------------------------------------------------------------
typedef struct {
    const char *add_tag;
    HashSet *seen_nodes;
} Emitter;

void emit_string(FILE *out, const char *s) {
    fputc('"', out);
    while (*s) {
        if (*s == '"' || *s == '\\') fputc('\\', out);
        fputc(*s, out);
        s++;
    }
    fputc('"', out);
}

void emit_json_node(FILE *out, const char *id, const char *label, const char *color, const char *tag) {
    fprintf(out, "{\"op\": \"add_node\", \"id\": ");
    emit_string(out, id);
    fprintf(out, ", \"label\": ");
    emit_string(out, label);
    if (color) fprintf(out, ", \"color\": \"%s\"", color);
    if (tag) fprintf(out, ", \"tags\": [\"%s\"]", tag);
    fprintf(out, "}\n");
}

void emit_json_edge(FILE *out, const char *src, const char *dst, const char *label, const char *color, const char *tag) {
    fprintf(out, "{\"op\": \"add_edge\", \"source\": ");
    emit_string(out, src);
    fprintf(out, ", \"target\": ");
    emit_string(out, dst);
    fprintf(out, ", \"label\": ");
    emit_string(out, label);
    if (color) fprintf(out, ", \"color\": \"%s\"", color);
    if (tag) fprintf(out, ", \"tags\": [\"%s\"]", tag);
    fprintf(out, "}\n");
}

// ------------------------------------------------------------
// Term to string (canonical representation)
// ------------------------------------------------------------
char* term_to_string(ASTNode *node) {
    StringBuilder sb;
    sb_init(&sb);
    
    if (node->type == NODE_ATOM) {
        sb_append(&sb, "%s", node->atom);
    } else if (node->type == NODE_STMT) {
        char *left_str = term_to_string(node->left);
        char *right_str = term_to_string(node->right);
        sb_append(&sb, "<%s %s %s>", left_str, node->rel, right_str);
        free(left_str);
        free(right_str);
    } else if (node->type == NODE_COMPOUND) {
        sb_append(&sb, "(%s, ", node->op);
        for (int i = 0; i < node->arg_count; i++) {
            char *arg_str = term_to_string(node->args[i]);
            sb_append(&sb, "%s", arg_str);
            free(arg_str);
            if (i < node->arg_count - 1) sb_append(&sb, ", ");
        }
        sb_append(&sb, ")");
    } else if (node->type == NODE_PRODUCT) {
        sb_append(&sb, "(");
        for (int i = 0; i < node->arg_count; i++) {
            char *arg_str = term_to_string(node->args[i]);
            sb_append(&sb, "%s", arg_str);
            free(arg_str);
            if (i < node->arg_count - 1) sb_append(&sb, " * ");
        }
        sb_append(&sb, ")");
    }
    
    char *result = strdup(sb.buf);
    sb_free(&sb);
    return result;
}

// ------------------------------------------------------------
// Graph traversal and emission
// ------------------------------------------------------------
const char* node_color(ASTNode *node) {
    switch (node->type) {
        case NODE_ATOM:     return "#7FDBFF";
        case NODE_STMT:     return "#FF851B";
        case NODE_COMPOUND: return "#B10DC9";
        case NODE_PRODUCT:  return "#39CCCC";
        default:            return "#AAAAAA";
    }
}

void emit_node(Emitter *emitter, ASTNode *node) {
    char *id = term_to_string(node);
    if (!hash_set_contains(emitter->seen_nodes, id)) {
        hash_set_add(emitter->seen_nodes, id);
        emit_json_node(stdout, id, id, node_color(node), emitter->add_tag);
    }
    free(id);
}

void emit_edge(Emitter *emitter, ASTNode *src, ASTNode *dst, const char *label, const char *color) {
    char *src_id = term_to_string(src);
    char *dst_id = term_to_string(dst);
    emit_json_edge(stdout, src_id, dst_id, label, color, emitter->add_tag);
    free(src_id);
    free(dst_id);
}

void traverse_term(Emitter *emitter, ASTNode *node, ASTNode *parent, const char *rel_label) {
    emit_node(emitter, node);
    
    if (parent && rel_label) {
        char *parent_id = term_to_string(parent);
        char *child_id = term_to_string(node);
        emit_json_edge(stdout, parent_id, child_id, rel_label, "#DDDDDD", emitter->add_tag);
        free(parent_id);
        free(child_id);
    }
    
    if (node->type == NODE_STMT) {
        traverse_term(emitter, node->left, node, "[subject]");
        traverse_term(emitter, node->right, node, "[predicate]");
        emit_edge(emitter, node->left, node->right, node->rel, "#FF4136");
    } else if (node->type == NODE_COMPOUND) {
        char label_buf[32];
        for (int i = 0; i < node->arg_count; i++) {
            snprintf(label_buf, sizeof(label_buf), "[%s_arg%d]", node->op, i);
            traverse_term(emitter, node->args[i], node, label_buf);
        }
    } else if (node->type == NODE_PRODUCT) {
        char label_buf[32];
        for (int i = 0; i < node->arg_count; i++) {
            snprintf(label_buf, sizeof(label_buf), "[product_arg%d]", i);
            traverse_term(emitter, node->args[i], node, label_buf);
        }
    }
}

// ------------------------------------------------------------
// Main
// ------------------------------------------------------------
int main(int argc, char *argv[]) {
    const char *tag = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--tag") == 0 && i+1 < argc) {
            tag = argv[++i];
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            return 1;
        }
    }
    
    setvbuf(stdout, NULL, _IOLBF, 0);
    HashSet seen_nodes;
    hash_set_init(&seen_nodes);
    Emitter emitter = { .add_tag = tag, .seen_nodes = &seen_nodes };
    
    char line[MAX_LINE_LEN];
    while (fgets(line, sizeof(line), stdin)) {
        line[strcspn(line, "\n")] = 0;
        if (line[0] == '\0' || strncmp(line, "//", 2) == 0) continue;
        
        TokenList tokens;
        tokenize(line, &tokens);
        if (tokens.count == 0) {
            token_list_free(&tokens);
            continue;
        }
        
        Parser parser;
        parser_init(&parser, &tokens);
        ASTNode *root = parse_term(&parser);
        if (!root) {
            static int fallback_counter = 0;
            char id[64];
            snprintf(id, sizeof(id), "fallback_%d", ++fallback_counter);
            emit_json_node(stdout, id, line, "#AAAAAA", tag);
            token_list_free(&tokens);
            continue;
        }
        
        traverse_term(&emitter, root, NULL, NULL);
        free_ast(root);
        token_list_free(&tokens);
    }
    
    hash_set_free(&seen_nodes);
    return 0;
}
