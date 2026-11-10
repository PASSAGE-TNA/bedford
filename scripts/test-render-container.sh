#!/usr/bin/env bash
# Integration tests for the Render container (Dockerfile.render). Needs docker, curl and jq.
# Usage: scripts/test-render-container.sh [image]   (builds passage-search:test when no image is given)
# CPUS=0.1 simulates Render's free instance; LOAD sets the number of search+autocomplete request pairs.
set -uo pipefail
export no_proxy="localhost,127.0.0.1${no_proxy:+,$no_proxy}" NO_PROXY="localhost,127.0.0.1${NO_PROXY:+,$NO_PROXY}"
IMAGE="${1:-}"
NAME=passage-search-test
HOST_PORT="${HOST_PORT:-18080}"
BASE="http://localhost:$HOST_PORT"
PUBLIC_URL="$BASE/annosearch"
ALLOWED_ORIGIN=https://passage-tna.github.io
MANIFEST_BASE=https://passage-tna.github.io/bedford/iiif
FAILS=0

cd "$(dirname "$0")/.."

# Results go to fd 3 so checks can redirect their command's output freely.
exec 3>&1
pass() { printf 'PASS  %s\n' "$*" >&3; }
fail() { printf 'FAIL  %s\n' "$*" >&3; FAILS=$((FAILS + 1)); }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
not() { ! "$@"; }

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
header() { curl -s -D - -o /dev/null "${@:2}" | tr -d '\r' | awk -v h="$(tr '[:upper:]' '[:lower:]' <<<"$1")" -F': ' 'tolower($1)==h {print $2}'; }

wait_healthy() {
    local start=$SECONDS
    until [[ "$(status "$BASE/health")" == 200 ]]; do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != true ]]; then
            echo "container stopped during startup"; docker logs --tail 50 "$NAME"; return 1
        fi
        (( SECONDS - start < 600 )) || { echo "not healthy after 600s"; return 1; }
        sleep 1
    done
    echo "healthy after $((SECONDS - start))s"
}

cleanup() { [[ -n "${SAMPLER:-}" ]] && kill "$SAMPLER" 2>/dev/null; docker rm -f "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT

if [[ -z "$IMAGE" ]]; then
    IMAGE=passage-search:test
    docker build -q -f Dockerfile.render -t "$IMAGE" . >/dev/null || { echo "docker build failed"; exit 1; }
fi

cleanup
# Behind a TLS-inspecting proxy, set EXTRA_CA_CERT=/path/to/proxy-ca.pem so indexing can fetch the manifests.
ca_args=()
if [[ -n "${EXTRA_CA_CERT:-}" ]]; then
    ca_args=(-v "$EXTRA_CA_CERT:/etc/passage-extra-ca.pem:ro" -e NODE_EXTRA_CA_CERTS=/etc/passage-extra-ca.pem)
fi
# Each index has only 20 annotations, so a page size of 5 is used to exercise pagination.
docker run -d --name "$NAME" -p "127.0.0.1:$HOST_PORT:10000" --memory=512m ${CPUS:+--cpus=$CPUS} "${ca_args[@]}" \
    -e ANNOSEARCH_PUBLIC_URL="$PUBLIC_URL" -e ANNOSEARCH_MAX_HITS=5 "$IMAGE" >/dev/null || exit 1

# Sample container memory once a second for the whole run.
MEM_LOG="$(mktemp)"
( while docker stats --no-stream --format '{{.MemUsage}}' "$NAME" 2>/dev/null; do sleep 1; done ) > "$MEM_LOG" &
SAMPLER=$!
mem_report() {
    awk -v label="$1" '{ v=$1; u=v; gsub(/[0-9.]/, "", u); sub(/[A-Za-z]+$/, "", v);
        m = (u == "GiB") ? v * 1024 : (u == "KiB") ? v / 1024 : v + 0; if (m > max) max = m; last = m }
        END { printf "    %s: peak %.0f MiB, latest %.0f MiB (%d samples)\n", label, max, last, NR }' "$MEM_LOG" >&3
    : > "$MEM_LOG"
}

sleep 2
check "health is not 200 while indexing" test "$(status "$BASE/health")" != 200
wait_healthy || exit 1
mem_report "startup + indexing"

echo "--- search API"
body="$(curl -s "$BASE/annosearch/secondpassage/search?q=Gravesend")"
check "search returns IIIF Search 2 AnnotationPage" \
    jq -e '."@context" == "http://iiif.io/api/search/2/context.json" and .type == "AnnotationPage" and (.items | length) > 0' <<<"$body" >/dev/null
check "search ids use the public URL" \
    jq -e --arg u "$PUBLIC_URL/secondpassage/search?q=Gravesend" '.id | startswith($u)' <<<"$body" >/dev/null
check "hits keep canvas xywh targets" \
    jq -e 'all(.items[]; .target.id | test("^https://passage-tna.github.io/bedford/canvas/1#xywh=[0-9]+,[0-9]+,[0-9]+,[0-9]+$"))' <<<"$body" >/dev/null
check "hits are partOf the secondpassage manifest" \
    jq -e --arg m "$MANIFEST_BASE/secondpassage.json" 'all(.items[]; .target.partOf.id == $m)' <<<"$body" >/dev/null
check "hit ids are the original annotation ids" \
    jq -e 'all(.items[]; .id | test("^https://passage-tna.github.io/bedford/canvas/1/annotation/[0-9]+$"))' <<<"$body" >/dev/null

body="$(curl -s "$BASE/annosearch/thirdpassage/search?q=Bedford")"
check "thirdpassage index only returns thirdpassage annotations" \
    jq -e --arg m "$MANIFEST_BASE/thirdpassage.json" '(.items | length) > 0 and all(.items[]; .target.partOf.id == $m and (.target.id | startswith("https://passage-tna.github.io/bedford/canvas/3#xywh=")))' <<<"$body" >/dev/null

body="$(curl -s "$BASE/annosearch/secondpassage/search?q=Bedford")"
check "pagination: partOf total, first/last and next link" \
    jq -e '.partOf.total > 5 and .partOf.type == "AnnotationCollection" and (.partOf.last.id | test("page=[1-9]")) and (.next | test("page=1$")) and (.items | length) == 5' <<<"$body" >/dev/null
next="$(jq -r '.next // "missing"' <<<"$body")"
body2="$(curl -s "${next/$PUBLIC_URL/$BASE/annosearch}")"
check "pagination: next page resolves with startIndex 5 and prev" \
    jq -e '.startIndex == 5 and (.prev | test("page=0$"))' <<<"$body2" >/dev/null
check "pagination: pages do not overlap" \
    test -z "$(comm -12 <(jq -r '.items[].id' <<<"$body" | sort) <(jq -r '.items[].id' <<<"$body2" | sort))"

body="$(curl -s "$BASE/annosearch/secondpassage/search?q=Gravesend&motivation=commenting")"
check "motivation filter accepted" jq -e '(.items | length) > 0' <<<"$body" >/dev/null

body="$(curl -s "$BASE/annosearch/secondpassage/autocomplete?q=grav")"
check "autocomplete returns TermPage with en terms" \
    jq -e '.type == "TermPage" and (.items | length) > 0 and all(.items[]; .language == "en")' <<<"$body" >/dev/null
check "autocomplete service ids use the public URL" \
    jq -e --arg u "$PUBLIC_URL/secondpassage/search?q=" 'all(.items[]; .service[0].id | startswith($u))' <<<"$body" >/dev/null

check "HEAD search is allowed" test "$(status -I "$BASE/annosearch/secondpassage/search?q=Bedford")" == 200
check "invalid query returns 400 validation error" \
    test "$(status "$BASE/annosearch/secondpassage/search?q=%7Bfoo%7D")" == 400

echo "--- CORS"
check "allowed origin is echoed" \
    test "$(header Access-Control-Allow-Origin -H "Origin: $ALLOWED_ORIGIN" "$BASE/annosearch/secondpassage/search?q=Bedford")" == "$ALLOWED_ORIGIN"
check "Tamerlane origin is allowed" \
    test "$(header Access-Control-Allow-Origin -H "Origin: https://tamerlaneviewer.github.io" "$BASE/annosearch/secondpassage/search?q=Bedford")" == https://tamerlaneviewer.github.io
check "other origins get no CORS header" \
    test -z "$(header Access-Control-Allow-Origin -H "Origin: https://evil.example" "$BASE/annosearch/secondpassage/search?q=Bedford")"
check "only one Access-Control-Allow-Origin header" \
    test "$(curl -s -D - -o /dev/null -H "Origin: $ALLOWED_ORIGIN" "$BASE/annosearch/secondpassage/search?q=Bedford" | grep -ci '^access-control-allow-origin')" == 1
check "OPTIONS preflight returns 204" \
    test "$(status -X OPTIONS -H "Origin: $ALLOWED_ORIGIN" -H 'Access-Control-Request-Method: GET' "$BASE/annosearch/secondpassage/search?q=x")" == 204
check "preflight allows GET" \
    grep -q GET <<<"$(header Access-Control-Allow-Methods -X OPTIONS -H "Origin: $ALLOWED_ORIGIN" "$BASE/annosearch/secondpassage/search")"

echo "--- methods and routes"
for m in POST PUT PATCH DELETE TRACE; do
    check "$m is rejected with 405" test "$(status -X "$m" "$BASE/annosearch/secondpassage/search?q=x")" == 405
done
check "405 advertises Allow" test "$(header Allow -X POST "$BASE/annosearch/secondpassage/search")" == "GET, HEAD, OPTIONS"
check "POST body is rejected" test "$(status -X POST --data '{"a":1}' "$BASE/annosearch/secondpassage/search")" == 405
for p in / /api/v1/indexes /api/v1/secondpassage_annotations/search /health/livez /health/readyz \
         /annosearch/ /annosearch/version /annosearch/secondpassage /annosearch/secondpassage_annotations/search \
         /annosearch/otel-logs-v0_7/search /annosearch/jamaicapassage/search /annosearch/secondpassage/search/extra \
         "/annosearch/secondpassage/../../api/v1/indexes" "/annosearch/%2e%2e/api/v1/indexes" "/_ready"; do
    check "blocked: $p" test "$(status --path-as-is "$BASE$p")" == 404
done
body="$(curl -s "$BASE/api/v1/indexes")"
check "404 body is generic JSON" test "$body" == '{"error":"Not found"}'

echo "--- headers"
hdrs="$(curl -s -D - -o /dev/null "$BASE/annosearch/secondpassage/search?q=Bedford" | tr -d '\r')"
for h in 'X-Content-Type-Options: nosniff' 'X-Frame-Options: DENY' 'Referrer-Policy: no-referrer' \
         "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'" 'Server: nginx' 'Vary: Origin'; do
    check "header '$h'" grep -qx "$h" <<<"$hdrs"
done
check "no X-Powered-By" not grep -qi '^x-powered-by' <<<"$hdrs"
check "no duplicate X-Frame-Options" test "$(grep -ci '^x-frame-options' <<<"$hdrs")" == 1

echo "--- internal services are not reachable from outside the container"
ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")"
probe() { docker run --rm --entrypoint bash "$IMAGE" -c "timeout 3 bash -c 'exec 3<>/dev/tcp/$ip/$1' 2>/dev/null"; }
check "nginx reachable on $ip:10000" probe 10000
check "AnnoSearch $ip:3000 refused" not probe 3000
check "Quickwit REST $ip:7280 refused" not probe 7280
check "Quickwit gRPC $ip:7281 refused" not probe 7281
listeners="$(docker exec "$NAME" cat /proc/net/tcp | awk 'NR>1 && $4=="0A" {print $2}')"
check "only 0.0.0.0:10000 listens on a non-loopback address" \
    test "$(grep -v '^0100007F' <<<"$listeners" | sort -u | tr '\n' ' ')" == "00000000:2710 "
echo "    listeners: $(tr '\n' ' ' <<<"$listeners")"

echo "--- memory"
mem_report "functional tests"
sleep 15
mem_report "idle"
terms=(Bedford Jamaica slave ship Gravesend captain crew sugar voyage Kingston)
LOAD="${LOAD:-1000}"
for i in $(seq 1 "$LOAD"); do
    idx=$([[ $((i % 2)) == 0 ]] && echo secondpassage || echo thirdpassage)
    echo "$BASE/annosearch/$idx/search?q=${terms[$((i % 10))]}&page=$((i % 3))"
    echo "$BASE/annosearch/$idx/autocomplete?q=${terms[$((i % 10))]:0:3}"
done | xargs -P 16 -n 1 curl -s -o /dev/null -w '%{http_code} %{time_total}\n' > "$MEM_LOG.load"
awk '{ n[$1]++ } END { for (c in n) printf "    load responses: %d x %s\n", n[c], c }' "$MEM_LOG.load" >&3
sort -n -k2 "$MEM_LOG.load" | awk '{ t[NR] = $2 } END { printf "    latency: median %.3fs, p95 %.3fs, max %.3fs\n", t[int(NR/2)+1], t[int(NR*0.95)], t[NR] }' >&3
mem_report "$((LOAD * 2)) requests, 16 concurrent"
docker exec "$NAME" sh -c 'for p in /proc/[0-9]*; do n=$(tr "\0" " " < $p/cmdline 2>/dev/null | cut -c1-50); r=$(awk "/VmRSS/ {print \$2}" $p/status 2>/dev/null); [ -n "$r" ] && [ "$r" -gt 2048 ] && echo "    RSS $(( r / 1024 )) MiB  $n"; done | sort -k2 -rn' >&3

echo "--- restart rebuilds the index"
docker restart -t 30 "$NAME" >/dev/null
wait_healthy || fail "healthy after restart"
mem_report "restart + re-index"
check "search works after restart" \
    jq -e '(.items | length) > 0' <<<"$(curl -s "$BASE/annosearch/secondpassage/search?q=Gravesend")" >/dev/null
check "index was rebuilt on restart" test "$(docker logs "$NAME" 2>&1 | grep -c "index 'secondpassage' ready")" == 2

echo "--- shutdown"
start=$SECONDS
docker stop -t 30 "$NAME" >/dev/null
check "SIGTERM stops the container within Render's 30s grace period ($((SECONDS - start))s)" test $((SECONDS - start)) -lt 30
check "clean exit code 0" test "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")" == 0
check "all services stopped in order" \
    bash -c 'docker logs "$1" 2>&1 | grep -q "shutdown complete (exit 0)"' _ "$NAME"
docker logs "$NAME" 2>&1 | grep '\[start\]' | tail -6 | sed 's/^/    /' >&3

echo "--- failure of an essential process stops the container"
boot_ts="$(date +%s)"
docker start "$NAME" >/dev/null && wait_healthy >/dev/null || fail "restart for failure test"
# Wait until the supervisor itself has logged readiness for this boot.
for _ in $(seq 1 30); do
    docker logs --since "$boot_ts" "$NAME" 2>&1 | grep -q 'ready: listening' && break
    sleep 1
done
docker exec "$NAME" bash -c 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = quickwit ] && kill -KILL "${p#/proc/}"; done; true'
for _ in $(seq 1 30); do
    [[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" == false ]] && break
    sleep 1
done
check "container exited after Quickwit died" test "$(docker inspect -f '{{.State.Running}}' "$NAME")" == false
check "non-zero exit code" test "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")" != 0
docker logs "$NAME" 2>&1 | grep '\[start\]' | tail -5 | sed 's/^/    /' >&3

echo
if (( FAILS )); then echo "$FAILS check(s) failed"; exit 1; fi
echo "all checks passed"
