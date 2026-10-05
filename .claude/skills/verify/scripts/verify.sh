#!/usr/bin/env bash
# Drive mautrix-gmessages from this checkout against a disposable Synapse.
# Usage: GMV_RUN_ID=<id> verify.sh up|doctor|say <mapped command>|whoami|restart|evidence|down
#   up also needs GMV_EVIDENCE=<fresh absolute dir outside the checkout and /tmp>.
set -euo pipefail
umask 077

ROOT=$(cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" && pwd -P)
HELPER=$ROOT/.claude/skills/verify/scripts/verify.sh
SKILL=$ROOT/.claude/skills/verify/SKILL.md
IMAGE=${GMV_SYNAPSE_IMAGE:-matrixdotorg/synapse:latest}
SERVER=gmv.localhost
TESTUSER=@gmvtester:$SERVER
BOT=@gmessagesbot:$SERVER
SCRATCH_ROOT=/private/tmp
ALLOWED=("help" "version" "frobnicate" "login" "login google" "login qr" "cancel" "list-logins" "start-chat +15555550100")

die() { echo "FAIL: $*" >&2; exit 1; }
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

[[ ${GMV_RUN_ID:-} =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die "GMV_RUN_ID must match ^[a-z0-9][a-z0-9-]{0,31}\$"
RUN_ID=$GMV_RUN_ID
RUN=$SCRATCH_ROOT/gmv-$RUN_ID

# HEAD, tracked diff, untracked files (content or symlink target), which covers this helper.
fingerprint() {
  {
    git -C "$ROOT" rev-parse HEAD
    git -C "$ROOT" diff HEAD --binary
    git -C "$ROOT" ls-files -o --exclude-standard -z | while IFS= read -r -d '' f; do
      if [[ -L $ROOT/$f ]]; then echo "$f -> $(readlink "$ROOT/$f")"; else echo "$f $(shasum -a 256 <"$ROOT/$f" | cut -c1-64)"; fi
    done
  } | shasum -a 256 | cut -c1-64
}

setstate() { sed -i '' "/^$1=/d" "$RUN/state.env"; echo "$1=$(printf '%q' "$2")" >>"$RUN/state.env"; }

# The owner marker binds the scratch dir to this run ID and this checkout.
load_run() {
  [[ -d $RUN && ! -L $RUN ]] || die "$RUN is not a run directory"
  [[ $(stat -f '%u %Lp' "$RUN") == "$(id -u) 700" ]] || die "$RUN is not owned by uid $(id -u) with mode 700"
  [[ -f $RUN/owner && ! -L $RUN/owner && -f $RUN/state.env && ! -L $RUN/state.env ]] || die "$RUN has no owner marker or state; refusing"
  [[ $(cat "$RUN/owner") == "gmv $RUN_ID $ROOT" ]] || die "$RUN belongs to another run or checkout ($(cat "$RUN/owner")); refusing"
  source "$RUN/state.env"
  [[ $SOURCE_ROOT == "$ROOT" ]] || die "run was created from $SOURCE_ROOT, not $ROOT"
}

bridge_identity_ok() {
  [[ -n ${BRIDGE_PID:-} && $(ps -o lstart= -p "$BRIDGE_PID" 2>/dev/null) == "$BRIDGE_START" ]] || return 1
  [[ $(ps -o args= -p "$BRIDGE_PID") == "$BRIDGE_ARGV" ]] || return 1
  [[ $(lsof -a -p "$BRIDGE_PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p') == "$RUN" ]]
}
bridge_listen_ok() { [[ $(lsof -nP -a -p "$BRIDGE_PID" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u) == "127.0.0.1:$BRIDGE_PORT" ]]; }
container_ok() {
  [[ -n ${CONTAINER_ID:-} ]] && [[ $(docker inspect -f '{{.Id}}|{{.Name}}|{{index .Config.Labels "gmv.run"}}|{{index .Config.Labels "gmv.checkout"}}' "$CONTAINER_ID" 2>/dev/null) \
    == "$CONTAINER_ID|/$CONTAINER_NAME|$RUN_ID|$ROOT" ]]
}
container_port_ok() {
  [[ $(docker inspect -f '{{.State.Running}} {{range $p,$b := .NetworkSettings.Ports}}{{range $b}}{{$p}}={{.HostIp}}:{{.HostPort}} {{end}}{{end}}' "$CONTAINER_ID") \
    == "true 8008/tcp=127.0.0.1:$HS_PORT " ]]
}
hs() { curl -fsS -H "Authorization: Bearer $USER_TOKEN" "$@"; }
prov_secret() { awk '/^provisioning:/{p=1} p&&/shared_secret:/{print $2; exit}' "$RUN/config.yaml"; }
prov_whoami() { curl -fsS -H "Authorization: Bearer $(prov_secret)" "http://127.0.0.1:$BRIDGE_PORT/_matrix/provision/v3/whoami?user_id=$TESTUSER"; }

cmd_doctor() {
  load_run
  local ok=1
  check() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "ok   $label"; else echo "FAIL $label"; ok=0; fi; }
  check "owner marker binds run $RUN_ID to $ROOT" true
  check "checkout fingerprint unchanged since up (HEAD $SOURCE_SHA, dirty files, helper)" test "$(fingerprint)" = "$SOURCE_FP"
  check "binary hash unchanged" test "$(shasum -a 256 "$RUN/mautrix-gmessages" | cut -c1-64)" = "${BINARY_SHA256:-}"
  check "binary --version carries ${SOURCE_SHA:0:8}" grep -q "${SOURCE_SHA:0:8}" <<<"$("$RUN/mautrix-gmessages" --version 2>/dev/null)"
  check "bridge pid ${BRIDGE_PID:-none}: recorded start, full argv, cwd $RUN" bridge_identity_ok
  check "bridge listens only on 127.0.0.1:$BRIDGE_PORT" bridge_listen_ok
  check "synapse container ${CONTAINER_ID:0:12}: id, name, run and checkout labels" container_ok
  check "synapse running, published only on 127.0.0.1:$HS_PORT" container_port_ok
  check "synapse answers" curl -fsS "http://127.0.0.1:$HS_PORT/_matrix/client/versions"
  check "token belongs to disposable $TESTUSER" test "$(hs "http://127.0.0.1:$HS_PORT/_matrix/client/v3/account/whoami" 2>/dev/null | jq -r .user_id)" = "$TESTUSER"
  check "provisioning whoami names $BOT" test "$(prov_whoami 2>/dev/null | jq -r .bridge_bot)" = "$BOT"
  if [[ -n ${ROOM_ID:-} ]]; then check "stored management room is $ROOM_ID" test "$(prov_whoami 2>/dev/null | jq -r .management_room)" = "$ROOM_ID"; fi
  [[ $ok == 1 ]] || die "doctor failed; do not drive this instance"
  echo "doctor: healthy"
}

# Every drive, signal and capture runs the full doctor first.
preflight() { local out; out=$(cmd_doctor 2>&1) || { echo "$out" >&2; die "doctor failed before $1"; }; }

new_evidence_dir() {
  local d=$1 parent
  [[ $d == /* && $d != */ && $d != *//* ]] || die "GMV_EVIDENCE must be an absolute path without a trailing slash"
  case "$d/" in */../*|*/./*) die "GMV_EVIDENCE must not contain . or .. segments" ;; esac
  parent=$(dirname "$d")
  [[ -d $parent && $(cd "$parent" && pwd -P) == "$parent" ]] || die "evidence parent $parent must exist and contain no symlinks"
  case "$d/" in "$ROOT"/*|/private/tmp/*|/tmp/*|/private/var/*|/var/*) die "evidence must live outside the checkout and scratch space" ;; esac
  mkdir -m 700 "$d" 2>/dev/null || die "evidence dir $d already exists; use a fresh one"
}

spawn_bridge() {
  local from=1 pid
  [[ -f $RUN/bridge.stdout.log ]] && from=$(( $(wc -l <"$RUN/bridge.stdout.log") + 1 ))
  # argv identity per process-identity Tier 1: gmessages:bridge@<run id>
  (cd "$RUN" && exec -a "gmessages:bridge@$RUN_ID" "$RUN/mautrix-gmessages" -c "$RUN/config.yaml" -r "$RUN/registration.yaml" -n \
    </dev/null >>"$RUN/bridge.stdout.log" 2>&1) &
  pid=$!
  setstate BRIDGE_PID "$pid"; setstate BRIDGE_START "$(ps -o lstart= -p "$pid")"; source "$RUN/state.env"
  for _ in $(seq 50); do [[ $(ps -o args= -p "$pid" 2>/dev/null) == "$BRIDGE_ARGV" ]] && break; sleep 0.1; done
  [[ $(ps -o args= -p "$pid" 2>/dev/null) == "$BRIDGE_ARGV" ]] || die "pid $pid never became '$BRIDGE_ARGV'"
  echo "bridge: pid $pid start '$BRIDGE_START' argv '$BRIDGE_ARGV'"
  for _ in $(seq 60); do
    tail -n "+$from" "$RUN/bridge.stdout.log" | grep -q 'Bridge started' && return 0
    kill -0 "$pid" 2>/dev/null || die "bridge exited during startup; see bridge.stdout.log"
    sleep 1
  done
  die "bridge not ready after 60s"
}

stop_bridge() {
  bridge_identity_ok || die "pid ${BRIDGE_PID:-none} is not this run's bridge; refusing to signal it (state kept in $RUN)"
  kill -TERM "$BRIDGE_PID"
  for _ in $(seq 20); do kill -0 "$BRIDGE_PID" 2>/dev/null || { echo "stopped bridge pid $BRIDGE_PID"; return 0; }; sleep 0.5; done
  die "bridge $BRIDGE_PID ignored SIGTERM; state kept in $RUN"
}

up_body() {
  [[ -z ${GMV_TEST_FAIL_AFTER_SPAWN:-} ]] || echo "forced failure armed: GMV_TEST_FAIL_AFTER_SPAWN"
  echo "build: go build -tags goolm from $ROOT"
  (cd "$ROOT" && go build -tags goolm -ldflags "-X main.Commit=$SOURCE_SHA" -o "$RUN/mautrix-gmessages" ./cmd/mautrix-gmessages)
  setstate BINARY_SHA256 "$(shasum -a 256 "$RUN/mautrix-gmessages" | cut -c1-64)"

  echo "config: example config from the binary, then scoped edits"
  (cd "$RUN" && ./mautrix-gmessages -e -c config.yaml >/dev/null)
  sed -i '' \
    -e "s#^    address: http://example.localhost:8008#    address: http://127.0.0.1:$HS_PORT#" \
    -e "s#^    domain: example.com#    domain: $SERVER#" \
    -e "s#^    address: http://localhost:29336#    address: http://host.docker.internal:$BRIDGE_PORT#" \
    -e "s#^    hostname: .*#    hostname: 127.0.0.1#" \
    -e "s#^    port: 29336#    port: $BRIDGE_PORT#" \
    -e "s#^    type: postgres#    type: sqlite3-fk-wal#" \
    -e "s#^    uri: postgres://.*#    uri: file:$RUN/bridge.db?_txlock=immediate#" \
    -e "s#^        \"example.com\": user#        \"$SERVER\": user#" \
    -e "s#^        \"@admin:example.com\": admin#        \"@gmvadmin:$SERVER\": admin#" \
    -e "s#filename: ./logs/bridge.log#filename: $RUN/logs/bridge.log#" \
    -e "s#format: pretty-colored#format: pretty#" \
    "$RUN/config.yaml"
  grep -q "^    address: http://127.0.0.1:$HS_PORT" "$RUN/config.yaml" && grep -q '^    hostname: 127.0.0.1$' "$RUN/config.yaml" \
    && grep -q "^    port: $BRIDGE_PORT$" "$RUN/config.yaml" && grep -q '^    type: sqlite3-fk-wal' "$RUN/config.yaml" \
    || die "config edits did not apply; example config shape changed"
  (cd "$RUN" && ./mautrix-gmessages -g -c config.yaml -r registration.yaml >/dev/null)

  echo "synapse: $CONTAINER_NAME on 127.0.0.1:$HS_PORT"
  mkdir -m 700 "$RUN/synapse"
  docker run --rm --label "gmv.run=$RUN_ID" --label "gmv.checkout=$ROOT" -v "$RUN/synapse:/data" \
    -e SYNAPSE_SERVER_NAME=$SERVER -e SYNAPSE_REPORT_STATS=no "$IMAGE" generate >/dev/null
  cp "$RUN/registration.yaml" "$RUN/synapse/gmessages-registration.yaml"
  # A second config file instead of editing the generated one in place.
  printf 'app_service_config_files:\n  - /data/gmessages-registration.yaml\nenable_registration: false\n' >"$RUN/synapse/gmv.yaml"
  local cid
  cid=$(docker run -d --name "$CONTAINER_NAME" --label "gmv.run=$RUN_ID" --label "gmv.checkout=$ROOT" \
    -p "127.0.0.1:$HS_PORT:8008" -v "$RUN/synapse:/data" --entrypoint python "$IMAGE" \
    -m synapse.app.homeserver --config-path /data/homeserver.yaml --config-path /data/gmv.yaml)
  setstate CONTAINER_ID "$cid"; source "$RUN/state.env"
  echo "synapse: container $cid"
  for _ in $(seq 60); do curl -fsS "http://127.0.0.1:$HS_PORT/_matrix/client/versions" >/dev/null 2>&1 && break; sleep 1; done
  curl -fsS "http://127.0.0.1:$HS_PORT/_matrix/client/versions" >/dev/null || die "synapse not answering"

  echo "test identity: $TESTUSER (disposable; password never stored, token only in state.env)"
  local pw token
  pw=$(openssl rand -hex 16)
  docker exec "$cid" register_new_matrix_user -c /data/homeserver.yaml -u gmvtester -p "$pw" --no-admin http://localhost:8008 >/dev/null
  token=$(jq -n --arg p "$pw" '{type:"m.login.password",identifier:{type:"m.id.user",user:"gmvtester"},password:$p}' \
    | curl -fsS -X POST --data @- "http://127.0.0.1:$HS_PORT/_matrix/client/v3/login" | jq -r .access_token)
  setstate USER_TOKEN "$token"; source "$RUN/state.env"

  spawn_bridge
  [[ -z ${GMV_TEST_FAIL_AFTER_SPAWN:-} ]] || die "forced failure after spawn (GMV_TEST_FAIL_AFTER_SPAWN)"
  cmd_doctor
  UP_DONE=1
}

up_failed() {
  local rc=$?
  [[ ${UP_DONE:-0} == 1 ]] && return 0
  echo "up failed (exit $rc): capturing evidence, then stopping only this run's resources"
  set +e
  ( capture "$EVIDENCE_DIR/failed-startup" )
  ( cmd_down ) || echo "teardown refused; state kept in $RUN"
  exit "$rc"
}

cmd_up() {
  [[ -d $SCRATCH_ROOT && ! -L $SCRATCH_ROOT ]] || die "$SCRATCH_ROOT is not a real directory"
  [[ ! -e $RUN && ! -L $RUN ]] || die "$RUN already exists; pick a new GMV_RUN_ID"
  new_evidence_dir "${GMV_EVIDENCE:-}"
  mkdir -m 700 "$RUN" 2>/dev/null || die "$RUN already exists; pick a new GMV_RUN_ID"
  printf 'gmv %s %s\n' "$RUN_ID" "$ROOT" >"$RUN/owner"
  : >"$RUN/state.env"
  setstate SOURCE_ROOT "$ROOT"; setstate SOURCE_SHA "$(git -C "$ROOT" rev-parse HEAD)"; setstate SOURCE_FP "$(fingerprint)"
  setstate EVIDENCE_DIR "$GMV_EVIDENCE"; setstate HS_PORT "$(free_port)"; setstate BRIDGE_PORT "$(free_port)"
  setstate CONTAINER_NAME "gmessages-synapse-$RUN_ID"; setstate LOGIN_PENDING 0
  setstate BRIDGE_ARGV "gmessages:bridge@$RUN_ID -c $RUN/config.yaml -r $RUN/registration.yaml -n"
  mkdir "$RUN/logs"; : >"$RUN/transcript.txt"
  source "$RUN/state.env"
  echo "run: GMV_RUN_ID=$RUN_ID dir=$RUN evidence=$EVIDENCE_DIR" | tee "$EVIDENCE_DIR/up.log"
  set +e
  ( set -e; trap up_failed EXIT; trap 'exit 130' INT TERM; up_body ) 2>&1 | tee -a "$EVIDENCE_DIR/up.log"
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

ensure_room() {
  [[ -n ${ROOM_ID:-} ]] && return 0
  local since; since=$(now_ms)
  ROOM_ID=$(hs -X POST "http://127.0.0.1:$HS_PORT/_matrix/client/v3/createRoom" \
    -d "$(jq -n --arg b "$BOT" '{preset:"private_chat",is_direct:true,invite:[$b],name:"gmv management"}')" | jq -r .room_id)
  setstate ROOM_ID "$ROOM_ID"
  printf '[%s] USER invites %s to new DM %s\n' "$(ts)" "$BOT" "$ROOM_ID" | tee -a "$RUN/transcript.txt"
  wait_bot_replies "$since"
}

# Print bot messages in ROOM_ID sent at or after epoch-ms $1, until 4s of quiet (max ~40s).
wait_bot_replies() {
  local since=$1 seen=" " got=0 quiet=0 out id body
  for _ in $(seq 20); do
    sleep 2
    out=$(hs "http://127.0.0.1:$HS_PORT/_matrix/client/v3/rooms/$ROOM_ID/messages?dir=b&limit=50")
    local new=0
    while IFS=$'\t' read -r id body; do
      [[ -z $id || $seen == *" $id "* ]] && continue
      seen+="$id "; new=1; echo "BOT> ${body//\\n/$'\n'     }"
    done < <(jq -r --arg b "$BOT" --argjson t "$since" \
      '[.chunk[] | select(.type=="m.room.message" and .sender==$b and .origin_server_ts>=$t)] | reverse[] | [.event_id, .content.body] | @tsv' <<<"$out")
    if [[ $new == 1 ]]; then got=1; quiet=0; elif [[ $got == 1 ]]; then quiet=$((quiet+1)); [[ $quiet -ge 2 ]] && break; fi
  done | tee -a "$RUN/transcript.txt"
}

cmd_say() {
  local text=$1 a ok=0 since replies
  for a in "${ALLOWED[@]}"; do [[ $text == "$a" ]] && ok=1; done
  [[ $ok == 1 ]] || die "'$text' is not a mapped command. Allowed: $(printf '"%s" ' "${ALLOWED[@]}")"
  load_run
  # While a login prompt is open, the bridge submits any unregistered command to Google as cookies.
  [[ $text == frobnicate && $LOGIN_PENDING == 1 ]] && die "a login prompt is open; send 'cancel' before free text"
  preflight "say $text"
  ensure_room
  since=$(now_ms)
  printf '\n[%s] USER> %s\n' "$(ts)" "$text" | tee -a "$RUN/transcript.txt"
  hs -X PUT "http://127.0.0.1:$HS_PORT/_matrix/client/v3/rooms/$ROOM_ID/send/m.room.message/gmv$(now_ms)" \
    -d "$(jq -n --arg t "$text" '{msgtype:"m.text",body:$t}')" >/dev/null
  replies=$(wait_bot_replies "$since")
  echo "$replies"
  if grep -q 'Login URL:' <<<"$replies"; then setstate LOGIN_PENDING 1; fi
  if grep -qE 'Login cancelled|No ongoing command' <<<"$replies"; then setstate LOGIN_PENDING 0; fi
}

cmd_whoami() { load_run; preflight whoami; prov_whoami | jq '{bridge_bot,command_prefix,management_room,logins,login_flows:[.login_flows[].id]}'; }

cmd_restart() {
  load_run; preflight restart
  stop_bridge
  setstate LOGIN_PENDING 0
  spawn_bridge
  cmd_doctor
}

redact() {
  python3 -c 'import sys,re,os
s=sys.stdin.read()
secrets=sys.argv[2:]
if os.path.exists(sys.argv[1]):
    secrets+=re.findall(r"^(?:as|hs)_token:\s*\"?([^\"\s]+)", open(sys.argv[1]).read(), re.M)
for t in secrets:
    if len(t) > 8: s=s.replace(t,"REDACTED")
sys.stdout.write(re.sub(r"syt_[A-Za-z0-9_]+","syt_REDACTED",s))' \
    "$RUN/registration.yaml" "${USER_TOKEN:-}" "$(prov_secret 2>/dev/null)"
}

capture() {
  local dest=$1
  [[ -d $EVIDENCE_DIR && ! -L $EVIDENCE_DIR && $(stat -f %u "$EVIDENCE_DIR") == "$(id -u)" ]] || die "evidence dir $EVIDENCE_DIR is missing or not ours"
  mkdir -m 700 "$dest" 2>/dev/null || die "$dest already exists; refusing to overwrite evidence"
  local f
  for f in transcript.txt bridge.stdout.log; do [[ -f $RUN/$f ]] && redact <"$RUN/$f" >"$dest/$f"; done
  if [[ -f $RUN/bridge.db ]]; then
    sqlite3 -readonly "$RUN/bridge.db" '.mode line' "select bridge_id, mxid, management_room from \"user\";" \
      "select count(*) as user_logins from user_login;" "select count(*) as portals from portal;" >"$dest/store.txt" 2>&1 || true
  fi
  ( cmd_doctor ) >"$dest/doctor.txt" 2>&1 || true
  {
    echo "captured_at=$(ts)"; echo "run_id=$RUN_ID"; echo "run_dir=$RUN"; echo "owner=$(cat "$RUN/owner")"
    echo "source_root=$SOURCE_ROOT"; echo "source_sha=$SOURCE_SHA"; echo "source_fingerprint_at_up=$SOURCE_FP"; echo "source_fingerprint_now=$(fingerprint)"
    echo "binary_sha256=${BINARY_SHA256:-}"; echo "helper_sha256=$(shasum -a 256 "$HELPER" | cut -c1-64)"; echo "skill_sha256=$(shasum -a 256 "$SKILL" | cut -c1-64)"
    echo "synapse_container=${CONTAINER_ID:-} name=$CONTAINER_NAME image=$(docker inspect -f '{{.Image}}' "${CONTAINER_ID:-none}" 2>/dev/null)"
    echo "synapse_port=127.0.0.1:$HS_PORT bridge_port=127.0.0.1:$BRIDGE_PORT"
    echo "bridge_pid=${BRIDGE_PID:-} bridge_start=${BRIDGE_START:-}"; echo "bridge_argv=$BRIDGE_ARGV"
    echo "dirty_files:"; git -C "$ROOT" status --porcelain --untracked-files=all | sed 's/^/  /'
  } >"$dest/manifest.txt"
  echo "evidence: $dest"
}

cmd_evidence() { load_run; preflight evidence; capture "$EVIDENCE_DIR/capture-$(date +%H%M%S)"; }

cmd_down() {
  load_run
  local stop=0 named others
  # Preflight everything before stopping anything.
  if [[ -n ${BRIDGE_PID:-} ]] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    bridge_identity_ok || die "pid $BRIDGE_PID is alive but no longer this run's bridge (start/argv/cwd); refusing, state kept in $RUN"
    stop=1
  elif [[ -n ${BRIDGE_PID:-} ]]; then echo "bridge pid $BRIDGE_PID already exited"; fi
  others=$(pgrep -f "^gmessages:bridge@$RUN_ID " | grep -vx "${BRIDGE_PID:-none}" || true)
  [[ -z $others ]] || die "unrecorded process(es) $others claim this run; refusing, state kept in $RUN"
  named=$(docker ps -aq --no-trunc --filter "name=^/$CONTAINER_NAME\$")
  # A container created before its ID was recorded is adopted only if its labels match.
  [[ -n $named && -z ${CONTAINER_ID:-} ]] && CONTAINER_ID=$named
  if [[ -n $named ]]; then
    [[ $named == "$CONTAINER_ID" ]] && container_ok || die "container $CONTAINER_NAME is not this run's (id/labels); refusing, state kept in $RUN"
  elif [[ -n ${CONTAINER_ID:-} ]]; then echo "container ${CONTAINER_ID:0:12} already gone"; fi

  if [[ $stop == 1 ]]; then stop_bridge; fi
  if [[ -n $named ]]; then docker rm -f "$CONTAINER_ID" >/dev/null; echo "removed container ${CONTAINER_ID:0:12}"; fi
  load_run
  rm -rf -- "$RUN"
  echo "down: removed $RUN"
}

case ${1:-} in
  up) cmd_up ;; doctor) cmd_doctor ;; say) shift; cmd_say "$*" ;; whoami) cmd_whoami ;;
  restart) cmd_restart ;; evidence) cmd_evidence ;; down) cmd_down ;;
  *) sed -n '2,4p' "$0"; exit 2 ;;
esac
