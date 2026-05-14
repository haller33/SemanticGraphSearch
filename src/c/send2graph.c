/*
 * send2graph.c – Send graph operations (JSON Lines) to visualizer API.
 * Compile: gcc -o send2graph send2graph.c -lcurl -lcjson
 * Usage: ./send2graph [--api URL] [--color HEX] < operations.jsonl
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <curl/curl.h>
#include <cjson/cJSON.h>
#include <unistd.h>

#define MAX_URL_LEN 512
#define MAX_LINE_LEN 65536

typedef struct {
    char *api_base;
    char *forced_color;
    CURL *curl;
    int total;
    int ok;
} AppState;

/* Helper: build URL for endpoint */
static void build_url(char *buf, size_t size, const char *api_base, const char *endpoint) {
    snprintf(buf, size, "%s%s", api_base, endpoint);
}

/* Helper: send POST request with JSON payload */
static int send_post(AppState *state, const char *url, const char *json_str) {
    CURLcode res;
    struct curl_slist *headers = NULL;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    curl_easy_setopt(state->curl, CURLOPT_URL, url);
    curl_easy_setopt(state->curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(state->curl, CURLOPT_POSTFIELDS, json_str);
    curl_easy_setopt(state->curl, CURLOPT_TIMEOUT, 2L);
    res = curl_easy_perform(state->curl);
    curl_slist_free_all(headers);
    if (res != CURLE_OK) {
        fprintf(stderr, "Request failed: %s\n", curl_easy_strerror(res));
        return 0;
    }
    long http_code = 0;
    curl_easy_getinfo(state->curl, CURLINFO_RESPONSE_CODE, &http_code);
    return (http_code == 200 || http_code == 201 || http_code == 202);
}

/* Handle add_node operation */
static void handle_add_node(AppState *state, cJSON *node) {
    cJSON *id = cJSON_GetObjectItem(node, "id");
    if (!cJSON_IsString(id)) {
        fprintf(stderr, "Invalid add_node: missing id\n");
        return;
    }
    const char *node_id = id->valuestring;
    cJSON *label = cJSON_GetObjectItem(node, "label");
    const char *label_str = (label && cJSON_IsString(label)) ? label->valuestring : node_id;
    cJSON *metadata = cJSON_GetObjectItem(node, "metadata");
    cJSON *tags = cJSON_GetObjectItem(node, "tags");
    cJSON *color = cJSON_GetObjectItem(node, "color");

    /* Build payload JSON */
    cJSON *payload = cJSON_CreateObject();
    cJSON_AddStringToObject(payload, "id", node_id);
    cJSON_AddStringToObject(payload, "label", label_str);
    if (metadata && cJSON_IsObject(metadata))
        cJSON_AddItemToObject(payload, "metadata", cJSON_Duplicate(metadata, 1));
    else
        cJSON_AddNullToObject(payload, "metadata");
    if (tags && cJSON_IsArray(tags))
        cJSON_AddItemToObject(payload, "tags", cJSON_Duplicate(tags, 1));
    else
        cJSON_AddNullToObject(payload, "tags");
    /* Color: forced overrides node's color */
    if (state->forced_color)
        cJSON_AddStringToObject(payload, "color", state->forced_color);
    else if (color && cJSON_IsString(color))
        cJSON_AddStringToObject(payload, "color", color->valuestring);

    char *json_str = cJSON_PrintUnformatted(payload);
    char url[MAX_URL_LEN];
    build_url(url, sizeof(url), state->api_base, "/nodes");
    if (send_post(state, url, json_str))
        state->ok++;
    cJSON_Delete(payload);
    free(json_str);
}

/* Handle add_edge operation */
static void handle_add_edge(AppState *state, cJSON *edge) {
    cJSON *src = cJSON_GetObjectItem(edge, "source");
    cJSON *tgt = cJSON_GetObjectItem(edge, "target");
    if (!cJSON_IsString(src) || !cJSON_IsString(tgt)) {
        fprintf(stderr, "Invalid add_edge: missing source/target\n");
        return;
    }
    cJSON *label = cJSON_GetObjectItem(edge, "label");
    cJSON *tags = cJSON_GetObjectItem(edge, "tags");

    cJSON *payload = cJSON_CreateObject();
    cJSON_AddStringToObject(payload, "source", src->valuestring);
    cJSON_AddStringToObject(payload, "target", tgt->valuestring);
    if (label && cJSON_IsString(label)) {
        cJSON *meta = cJSON_CreateObject();
        cJSON_AddStringToObject(meta, "relation", label->valuestring);
        cJSON_AddItemToObject(payload, "metadata", meta);
    } else {
        cJSON_AddNullToObject(payload, "metadata");
    }
    if (tags && cJSON_IsArray(tags))
        cJSON_AddItemToObject(payload, "tags", cJSON_Duplicate(tags, 1));
    else
        cJSON_AddNullToObject(payload, "tags");

    char *json_str = cJSON_PrintUnformatted(payload);
    char url[MAX_URL_LEN];
    build_url(url, sizeof(url), state->api_base, "/edges");
    if (send_post(state, url, json_str))
        state->ok++;
    cJSON_Delete(payload);
    free(json_str);
}

/* Handle add_tags operation */
static void handle_add_tags(AppState *state, cJSON *tags_op) {
    cJSON *node_id = cJSON_GetObjectItem(tags_op, "id");
    cJSON *tags = cJSON_GetObjectItem(tags_op, "tags");
    if (!cJSON_IsString(node_id) || !cJSON_IsArray(tags)) {
        fprintf(stderr, "Invalid add_tags: missing id or tags array\n");
        return;
    }
    cJSON *payload = cJSON_CreateObject();
    cJSON_AddItemToObject(payload, "tags", cJSON_Duplicate(tags, 1));
    char *json_str = cJSON_PrintUnformatted(payload);
    char url[MAX_URL_LEN];
    snprintf(url, sizeof(url), "%s/nodes/%s/tags", state->api_base, node_id->valuestring);
    if (send_post(state, url, json_str))
        state->ok++;
    cJSON_Delete(payload);
    free(json_str);
}

int main(int argc, char *argv[]) {
    AppState state = {
        .api_base = "http://localhost:5000",
        .forced_color = NULL,
        .curl = NULL,
        .total = 0,
        .ok = 0
    };
    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--api") == 0 && i+1 < argc) {
            state.api_base = argv[++i];
        } else if (strcmp(argv[i], "--color") == 0 && i+1 < argc) {
            state.forced_color = argv[++i];
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            return 1;
        }
    }
    /* Initialize curl */
    curl_global_init(CURL_GLOBAL_ALL);
    state.curl = curl_easy_init();
    if (!state.curl) {
        fprintf(stderr, "Failed to init curl\n");
        return 1;
    }
    /* Process stdin line by line */
    char *line = NULL;
    size_t line_len = 0;
    ssize_t nread;
    while ((nread = getline(&line, &line_len, stdin)) != -1) {
        /* Strip trailing newline */
        while (nread > 0 && (line[nread-1] == '\n' || line[nread-1] == '\r'))
            line[--nread] = '\0';
        if (nread == 0) continue;
        cJSON *op = cJSON_Parse(line);
        if (!op) {
            fprintf(stderr, "Invalid JSON: %s\n", line);
            continue;
        }
        state.total++;
        cJSON *type = cJSON_GetObjectItem(op, "op");
        if (!cJSON_IsString(type)) {
            fprintf(stderr, "Missing 'op' field\n");
            cJSON_Delete(op);
            continue;
        }
        const char *op_type = type->valuestring;
        if (strcmp(op_type, "add_node") == 0) {
            handle_add_node(&state, op);
        } else if (strcmp(op_type, "add_edge") == 0) {
            handle_add_edge(&state, op);
        } else if (strcmp(op_type, "add_tags") == 0) {
            handle_add_tags(&state, op);
        } else {
            fprintf(stderr, "Unknown operation: %s\n", op_type);
        }
        cJSON_Delete(op);
        /* Visual feedback */
        fprintf(stderr, state.ok == state.total ? "." : "F");
        fflush(stderr);
    }
    free(line);
    curl_easy_cleanup(state.curl);
    curl_global_cleanup();
    fprintf(stderr, "\nDone: %d/%d operations succeeded.\n", state.ok, state.total);
    return 0;
}
