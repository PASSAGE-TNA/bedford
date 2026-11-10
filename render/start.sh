#!/usr/bin/env bash
# Process supervisor for the Passage Render container.
# Order: Quickwit -> (re)build index -> AnnoSearch -> Nginx. Any process exiting stops the container.
set -uo pipefail

PORT="${PORT:-10000}"
PASSAGE_MANIFEST_BASE_URL="${PASSAGE_MANIFEST_BASE_URL:-https://passage-tna.github.io/bedford/iiif}"
PASSAGE_INDEXES="${PASSAGE_INDEXES:-secondpassage thirdpassage}"
CORS_ALLOWED_ORIGINS="${CORS_ALLOWED_ORIGINS:-https://passage-tna.github.io https://tamerlaneviewer.github.io}"
TRUSTED_PROXY_CIDRS="${TRUSTED_PROXY_CIDRS:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"
INDEX_ATTEMPTS="${INDEX_ATTEMPTS:-3}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-300}"

APP_DIR=/opt/passage
RUN_DIR=/tmp/passage
NGINX_CONF="$RUN_DIR/nginx/nginx.conf"
ANNOSEARCH_PORT=3000
QUICKWIT_PORT=7280

export QW_DATA_DIR="$RUN_DIR/qwdata"
export QW_CONFIG="${QW_CONFIG:-$APP_DIR/quickwit.yaml}"
export RUST_LOG="${RUST_LOG:-warn,quickwit_serve=info}"
export QUICKWIT_BASE_URL="http://127.0.0.1:$QUICKWIT_PORT/api/v1/"
export ANNOSEARCH_PUBLIC_URL="${ANNOSEARCH_PUBLIC_URL:-http://localhost:$PORT/annosearch}"
export ANNOSEARCH_HOST=127.0.0.1
export ANNOSEARCH_PORT

declare -A PIDS=()
FG_PID=""
STOPPING=0

log() { printf '%s [start] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

shutdown() {
    local code="$1" name pid
    (( STOPPING )) && return
    STOPPING=1
    [[ -n "$FG_PID" ]] && kill -TERM "$FG_PID" 2>/dev/null
    for name in nginx annosearch quickwit; do
        pid="${PIDS[$name]:-}"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log "stopping $name (pid $pid)"
            if [[ "$name" == nginx ]]; then kill -QUIT "$pid"; else kill -TERM "$pid"; fi
        fi
    done
    # Quickwit's graceful drain can exceed Render's 30s grace period; its data is ephemeral, so cap the wait at 10s.
    for _ in $(seq 1 20); do
        local alive=0
        for pid in "${PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
        (( alive )) || break
        sleep 0.5
    done
    for name in "${!PIDS[@]}"; do
        pid="${PIDS[$name]}"
        if kill -0 "$pid" 2>/dev/null; then
            log "$name did not stop in time; killing"
            kill -KILL "$pid" 2>/dev/null
        fi
    done
    log "shutdown complete (exit $code)"
    exit "$code"
}

die() { log "FATAL: $*"; shutdown 1; }

trap 'log "received SIGTERM"; shutdown 0' TERM
trap 'log "received SIGINT"; shutdown 0' INT

# Runs a foreground command in the background so signal traps fire immediately.
run() {
    local tag="$1"; shift
    "$@" > >(sed -u "s/^/[$tag] /") 2>&1 &
    FG_PID=$!
    local rc=0
    wait "$FG_PID" || rc=$?
    FG_PID=""
    return "$rc"
}

nap() { sleep "$1" & FG_PID=$!; wait "$FG_PID"; FG_PID=""; }

start_service() {
    local name="$1"; shift
    "$@" > >(sed -u "s/^/[$name] /") 2>&1 &
    PIDS[$name]=$!
    log "started $name (pid ${PIDS[$name]})"
}

alive() { kill -0 "${PIDS[$1]}" 2>/dev/null; }

# Minimal loopback HTTP GET without curl. Sets HTTP_STATUS/HTTP_BODY; succeeds on 200.
http_get() {
    local resp
    HTTP_STATUS="" HTTP_BODY=""
    resp=$(timeout 5 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$0" || exit 1
        printf "GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n" "$1" >&3
        cat <&3' "$1" "$2" 2>/dev/null) || return 1
    HTTP_STATUS="${resp:9:3}"
    HTTP_BODY="${resp#*$'\r\n\r\n'}"
    [[ "$HTTP_STATUS" == 200 ]]
}

wait_for_http() {
    local name="$1" port="$2" path="$3" deadline=$((SECONDS + STARTUP_TIMEOUT)) started
    log "waiting for $name on 127.0.0.1:$port$path"
    until http_get "$port" "$path"; do
        for started in "${!PIDS[@]}"; do
            alive "$started" || die "$started exited during startup"
        done
        (( SECONDS < deadline )) || die "$name not ready after ${STARTUP_TIMEOUT}s (last status: ${HTTP_STATUS:-none})"
        nap 1
    done
    log "$name ready (${SECONDS}s since start)"
}

validate_config() {
    local item
    [[ "$PORT" =~ ^[0-9]{2,5}$ && "$PORT" != "$ANNOSEARCH_PORT" && "$PORT" != "$QUICKWIT_PORT" ]] \
        || die "PORT must be a free TCP port (got '$PORT')"
    [[ "$PASSAGE_MANIFEST_BASE_URL" =~ ^https?://[^[:space:]\"\']+$ ]] || die "invalid PASSAGE_MANIFEST_BASE_URL"
    [[ "$ANNOSEARCH_PUBLIC_URL" =~ ^https?://[^[:space:]\"\']+[^/]$ ]] \
        || die "ANNOSEARCH_PUBLIC_URL must be an absolute URL without a trailing slash"
    [[ "$INDEX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die "invalid INDEX_ATTEMPTS"
    [[ "$STARTUP_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "invalid STARTUP_TIMEOUT"
    [[ -n "${PASSAGE_INDEXES// }" ]] || die "PASSAGE_INDEXES is empty"
    for item in $PASSAGE_INDEXES; do
        [[ "$item" =~ ^[a-z][a-z0-9_-]{2,62}$ ]] || die "invalid index name '$item'"
    done
    for item in $CORS_ALLOWED_ORIGINS; do
        [[ "$item" == "*" || "$item" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || die "invalid CORS origin '$item'"
    done
    for item in $TRUSTED_PROXY_CIDRS; do
        [[ "$item" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || die "invalid trusted proxy CIDR '$item'"
    done
}

render_nginx_conf() {
    local conf origin cidr cors="" real_ip="" indexes
    indexes="$(echo $PASSAGE_INDEXES | tr ' ' '|')"
    if [[ " $CORS_ALLOWED_ORIGINS " == *" * "* ]]; then
        cors='        default "*";'
    else
        cors='        default "";'
        for origin in $CORS_ALLOWED_ORIGINS; do
            cors+=$'\n'"        \"$origin\" \"$origin\";"
        done
    fi
    for cidr in $TRUSTED_PROXY_CIDRS; do
        real_ip+="    set_real_ip_from $cidr;"$'\n'
    done
    conf="$(<"$APP_DIR/nginx.conf.template")"
    conf="${conf//@PORT@/$PORT}"
    conf="${conf//@INDEX_PATTERN@/$indexes}"
    conf="${conf//@HEALTH_INDEX@/${PASSAGE_INDEXES%% *}}"
    conf="${conf//@CORS_ORIGINS@/$cors}"
    conf="${conf//@REAL_IP_FROM@/${real_ip%$'\n'}}"
    printf '%s\n' "$conf" > "$NGINX_CONF"
    nginx -t -q -e stderr -c "$NGINX_CONF" || die "generated nginx config is invalid"
}

annosearch_cli() {
    QUICKWIT_TIMEOUT=60000 run index node /opt/annosearch/dist/index.js "$@"
}

published_docs() {
    http_get "$QUICKWIT_PORT" "/api/v1/indexes/$1/describe" || { echo 0; return; }
    local n
    n="$(grep -oE '"num_published_docs"[[:space:]]*:[[:space:]]*[0-9]+' <<<"$HTTP_BODY" | head -1 | grep -oE '[0-9]+$')"
    echo "${n:-0}"
}

# AnnoSearch's CLI exits 0 even on failure, so success is verified against Quickwit directly.
build_index() {
    local name="$1" uri="$PASSAGE_MANIFEST_BASE_URL/$1.json" attempt docs
    for (( attempt = 1; attempt <= INDEX_ATTEMPTS; attempt++ )); do
        log "indexing '$name' from $uri (attempt $attempt/$INDEX_ATTEMPTS)"
        (( attempt > 1 )) && annosearch_cli delete --index "$name"
        annosearch_cli init --index "$name" \
            && annosearch_cli load --index "$name" --type Manifest --uri "$uri" --commit
        for _ in $(seq 1 15); do
            docs="$(published_docs "${name}_annotations")"
            (( docs > 0 )) && break
            nap 1
        done
        if (( docs > 0 )); then
            log "index '$name' ready: $docs annotations, $(published_docs "${name}_autocomplete") autocomplete terms"
            return 0
        fi
        log "indexing '$name' produced no searchable annotations"
        (( attempt < INDEX_ATTEMPTS )) && nap $(( attempt * 5 ))
    done
    return 1
}

main() {
    local name health_index="${PASSAGE_INDEXES%% *}"
    validate_config
    log "public search URL: $ANNOSEARCH_PUBLIC_URL; indexes: $PASSAGE_INDEXES"

    # Ephemeral by design: every start rebuilds the index from the published manifests.
    rm -rf "$RUN_DIR"
    mkdir -p "$QW_DATA_DIR" "$RUN_DIR/nginx" || die "cannot create $RUN_DIR"
    render_nginx_conf

    start_service quickwit quickwit run
    wait_for_http quickwit "$QUICKWIT_PORT" /health/readyz

    for name in $PASSAGE_INDEXES; do
        build_index "$name" || die "failed to build index '$name'"
    done

    start_service annosearch node /opt/annosearch/dist/index.js serve \
        --host 127.0.0.1 --port "$ANNOSEARCH_PORT" --cors "${CORS_ALLOWED_ORIGINS%% *}"
    wait_for_http annosearch "$ANNOSEARCH_PORT" "/$health_index/search?q=passage"

    start_service nginx nginx -e stderr -c "$NGINX_CONF" -g 'daemon off;'
    wait_for_http nginx "$PORT" /health
    log "ready: listening on 0.0.0.0:$PORT"

    while true; do
        wait -n "${PIDS[@]}"
        for name in "${!PIDS[@]}"; do
            alive "$name" || die "$name exited unexpectedly"
        done
    done
}

main
