#!/usr/bin/env bash
# Self-healing dependency update: deterministic co-upgrade + AI escalation.
# Called from .github/workflows/ai.yml. Config comes from env vars set there
# (UPDATE_LEVEL, FRAMEWORK_NAME, AI_MODEL, AI_MAX_ATTEMPTS, ANTHROPIC_API_KEY).
# GITHUB_OUTPUT is inherited from the calling step, so writes to it still work.

set -o pipefail
npm install -g npm-check-updates semver

TARGET="${UPDATE_LEVEL:-minor}"
MAX_ATTEMPTS=20
BISECT_MAX_DEPTH=4                      # 0 disables bisection

cp package.json /tmp/pkg.orig
cp package-lock.json /tmp/lock.orig

# Sanity-check the baseline package.json.
if ! jq empty /tmp/pkg.orig 2>/dev/null; then
    echo "::error::Baseline package.json is not valid JSON — aborting"
    exit 1
fi

# ---------- Framework gate ----------
# Only do work if the framework we care about actually has a new version
# at this update level.
if ! ncu "$FRAMEWORK_NAME" --target "$TARGET" 2>/dev/null \
        | tee /tmp/framework-update.txt \
        | grep -qE "^[[:space:]]*$FRAMEWORK_NAME[[:space:]]"; then
    echo "::notice::No $FRAMEWORK_NAME update available at target '$TARGET' — skipping"
    {
        echo "attempts=0"
        echo "bisect_trials=0"
        echo "test_outcome=skipped"
        echo "forced_legacy=0"
        echo "ai_used=0"
        echo "rejected="
        echo "coupgraded="
        echo "reject_details<<REJECT_EOF"
        echo ""
        echo "REJECT_EOF"
        echo "coupgrade_details<<COUP_EOF"
        echo ""
        echo "COUP_EOF"
        echo "ai_diagnosis<<AI_EOF"
        echo ""
        echo "AI_EOF"
    } >> $GITHUB_OUTPUT
    exit 0
fi
echo "✅ $FRAMEWORK_NAME has an update available — running robust update"

# ---------- Probe: capture every available bump up front ----------
cp /tmp/pkg.orig /tmp/probe.json
PROBE=$(ncu --packageFile /tmp/probe.json --target "$TARGET" --jsonUpgraded 2>/dev/null || echo '{}')
if ! echo "$PROBE" | jq empty >/dev/null 2>&1; then
    PROBE='{}'
fi
echo "Probe found $(echo "$PROBE" | jq 'length') packages with available updates"

OUR_DEPS=$(jq -r '.dependencies, .devDependencies | keys[]' package.json | sort -u)
HAS_BUILD=$(npm pkg get scripts.build | grep -cv '^{}$' || true)
HAS_TEST=$(npm pkg get scripts.test  | grep -cv '^{}$' || true)

# ---------- State (survives the top-of-loop baseline reset) ----------
REJECT_LIST=""            # packages held back to baseline
PIN_LIST=""               # plugins pinned to an EXACT version compatible with the
                          # framework version being installed. Format: "pkg=ver,pkg=ver".
NPM_INSTALL_FLAGS=""      # becomes --legacy-peer-deps only as a last resort
LEGACY_FALLBACK_USED=0
AI_ATTEMPTS_USED=0
AI_DIAGNOSIS=""
TEST_OUTCOME="skipped"
LOOP_RESULT=""

# Bisection state lives on disk because helpers run inside $(...) subshells.
TRIAL_CACHE=/tmp/trial_cache
TRIAL_COUNTER=/tmp/trial_counter
: > "$TRIAL_CACHE"
echo 0 > "$TRIAL_COUNTER"

# ================= Helpers =================

make_reject_arg() { echo "$REJECT_LIST"; }

# is_pinned PKG → 0 if the package already has a pin
is_pinned() {
    local e
    for e in $(echo "$PIN_LIST" | tr ',' ' '); do
        [ "${e%%=*}" = "$1" ] && return 0
    done
    return 1
}

# add_reject PKG — enforce invariants centrally:
#   * NEVER reject the framework (policy: framework is always updated)
#   * a pinned plugin outranks a reject (don't undo compatibility work)
#   * idempotent
add_reject() {
    [ "$1" = "$FRAMEWORK_NAME" ] && { echo "::warning::refused to reject framework $1"; return; }
    is_pinned "$1" && return
    echo ",$REJECT_LIST," | grep -q ",$1," && return
    REJECT_LIST="${REJECT_LIST:+$REJECT_LIST,}$1"
}

# add_pin PKG VERSION — record an exact-version pin; a pin outranks a reject,
# so remove the package from REJECT_LIST if present. Idempotent per package.
add_pin() {
    is_pinned "$1" && return
    PIN_LIST="${PIN_LIST:+$PIN_LIST,}$1=$2"
    REJECT_LIST=$(echo "$REJECT_LIST" | tr ',' '\n' | grep -vx "$1" | grep -v '^$' | paste -sd, -)
}

# pin_dep PKG VERSION — write an exact version into whichever section holds it.
pin_dep() {
    local tmp; tmp=$(mktemp)
    jq --arg p "$1" --arg v "$2" '
        if   (.dependencies[$p]    != null) then .dependencies[$p]    = $v
        elif (.devDependencies[$p] != null) then .devDependencies[$p] = $v
        else . end
    ' package.json > "$tmp" && mv "$tmp" package.json
}

# apply_pins — re-assert every pin over whatever ncu just wrote. Must run every
# iteration (and inside bisection trials) because the baseline is restored first.
apply_pins() {
    [ -z "$PIN_LIST" ] && return
    local entry
    for entry in $(echo "$PIN_LIST" | tr ',' ' '); do
        [ -z "$entry" ] && continue
        pin_dep "${entry%%=*}" "${entry#*=}"
    done
}

# framework_install_version — the CONCRETE framework version npm will install for
# the range currently in package.json (i.e. the highest release matching it).
framework_install_version() {
    local range ver
    range=$(jq -r --arg fw "$FRAMEWORK_NAME" '(.dependencies[$fw] // .devDependencies[$fw]) // empty' package.json)
    [ -z "$range" ] && { echo ""; return; }
    ver=$(npm view "$FRAMEWORK_NAME@$range" version --json 2>/dev/null \
          | jq -r 'if type=="array" then (.[-1] // "") else (. // "") end' 2>/dev/null)
    echo "$ver"
}

# best_compatible_version PLUGIN FRAMEWORK_VER MIN_VER
# Highest non-prerelease PLUGIN version that (a) is >= MIN_VER (never regress the
# plugin) and (b) declares a framework peer range satisfied by FRAMEWORK_VER — or
# declares no framework peer at all. Prints the version, or nothing if none fits.
best_compatible_version() {
    local plugin="$1" fver="$2" minver="$3" encoded doc v peer
    encoded=$(printf '%s' "$plugin" | sed 's|/|%2F|g')
    doc=$(curl -sS --max-time 30 "https://registry.npmjs.org/$encoded" 2>/dev/null || echo "")
    [ -z "$doc" ] && return
    echo "$doc" | jq -r --arg fw "$FRAMEWORK_NAME" '
        .versions | to_entries[]
        | select(.key | test("-") | not)                       # skip prereleases
        | [.key, (.value.peerDependencies[$fw] // "")] | @tsv
    ' 2>/dev/null | sort -t "$(printf '\t')" -k1,1 -rV | while IFS=$'\t' read -r v peer; do
        [ -z "$v" ] && continue
        if [ -n "$minver" ] && ! semver -r ">=$minver" "$v" >/dev/null 2>&1; then continue; fi
        if [ -z "$peer" ] || semver -r "$peer" "$fver" >/dev/null 2>&1; then
            echo "$v"; break
        fi
    done | head -n1
}

# resolve_and_pin PLUGIN — find a plugin version compatible with the framework
# version we're installing and pin it. Returns 0 if a new pin was added.
# By default it will NOT downgrade the plugin below its current version (so an
# "update" PR never silently regresses a plugin); set ALLOW_PLUGIN_DOWNGRADE=true
# to permit picking an older-but-compatible release as a last resort.
resolve_and_pin() {
    local plugin="$1" fver base floor best
    is_pinned "$plugin" && return 1
    fver=$(framework_install_version)
    [ -z "$fver" ] && { echo "::warning::could not resolve $FRAMEWORK_NAME install version"; return 1; }
    base=$(jq -r --arg p "$plugin" '((.dependencies[$p] // .devDependencies[$p]) // "") | sub("^[~^><= ]+";"")' /tmp/pkg.orig)
    floor="$base"
    [ "${ALLOW_PLUGIN_DOWNGRADE:-false}" = "true" ] && floor=""
    best=$(best_compatible_version "$plugin" "$fver" "$floor")
    if [ -n "$best" ]; then
        add_pin "$plugin" "$best"
        if [ -n "$base" ] && semver -r "<$base" "$best" >/dev/null 2>&1; then
            echo "🤝 Pin $plugin@$best — compatible with $FRAMEWORK_NAME@$fver (⚠️ DOWNGRADE from $base)"
        else
            echo "🤝 Pin $plugin@$best — compatible with $FRAMEWORK_NAME@$fver (was $base)"
        fi
        return 0
    fi
    echo "::warning::No release of $plugin (>= ${floor:-any}) accepts $FRAMEWORK_NAME@$fver — a downgrade may be the only compatible option (set ALLOW_PLUGIN_DOWNGRADE=true to permit it)"
    return 1
}

identify_major_bumps() {
    jq -r --slurpfile orig /tmp/pkg.orig '
        def safe_obj(x): if (x | type) == "object" then x else {} end;
        def major(v):
            if (v | type) != "string" then null
            else (v | sub("^[~^><= ]+";"") | split(".")[0])
            end;
        (safe_obj($orig[0].dependencies) + safe_obj($orig[0].devDependencies)) as $o |
        (safe_obj(.dependencies)         + safe_obj(.devDependencies))         as $n |
        [ $n | to_entries[]
          | select((.value | type) == "string")
          | select($o[.key] != null and ($o[.key] | type) == "string")
          | select(major(.value) != null and major($o[.key]) != null)
          | select(major(.value) != major($o[.key]))
          | .key
        ] | join(",")
    ' package.json
}

# ---------- Bisection helpers ----------

try_majors() {
    local apply_majors="$1"
    local phase="$2"

    local n
    n=$(( $(cat "$TRIAL_COUNTER") + 1 ))
    echo "$n" > "$TRIAL_COUNTER"

    local key
    key=$(echo "$apply_majors" | tr ',' '\n' | grep -v '^$' | sort | paste -sd, -)
    key="${phase}|${key}"

    local cached
    cached=$(grep -F "${key}=" "$TRIAL_CACHE" 2>/dev/null | tail -n1 | cut -d= -f2-)
    if [ -n "$cached" ]; then
        echo "::group::Trial #$n (cached) phase=$phase apply=[$apply_majors] → $cached" >&2
        echo "::endgroup::" >&2
        echo "$cached"
        return
    fi

    echo "::group::Trial #$n phase=$phase apply=[$apply_majors]" >&2

    rm -rf node_modules
    cp /tmp/pkg.orig package.json
    cp /tmp/lock.orig package-lock.json

    local reject_for_trial="$REJECT_LIST"
    local m
    for m in $(echo "$CURRENT_MAJORS" | tr ',' '\n'); do
        [ -z "$m" ] && continue
        if ! echo ",${apply_majors}," | grep -q ",${m},"; then
            reject_for_trial="${reject_for_trial:+$reject_for_trial,}${m}"
        fi
    done

    if [ -n "$reject_for_trial" ]; then
        ncu -u --target "$TARGET" --reject "$reject_for_trial" >&2 || true
    else
        ncu -u --target "$TARGET" >&2 || true
    fi
    apply_pins   # keep framework-compat plugin pins in place inside trials too

    local result="pass"
    if ! npm install $NPM_INSTALL_FLAGS >/tmp/bisect.log 2>&1; then
        echo "Install failed in trial" >&2
        result="fail"
    elif [ "$HAS_BUILD" -gt 0 ] && ! npm run build >/tmp/bisect.log 2>&1; then
        echo "Build failed in trial" >&2
        result="fail"
    elif [ "$phase" = "test" ] && [ "$HAS_TEST" -gt 0 ] && ! npm test >/tmp/bisect.log 2>&1; then
        echo "Test failed in trial" >&2
        result="fail"
    fi

    echo "${key}=${result}" >> "$TRIAL_CACHE"
    echo "Result: $result" >&2
    echo "::endgroup::" >&2
    echo "$result"
}

bisect_culprits() {
    local candidates="$1"
    local phase="$2"
    local depth="${3:-0}"

    local count
    count=$(echo "$candidates" | tr ',' '\n' | grep -c .)

    if [ "$count" -le 1 ]; then echo "$candidates"; return; fi
    if [ "$depth" -ge "$BISECT_MAX_DEPTH" ]; then
        echo "::warning::Bisect depth cap at depth=$depth — rejecting remaining: $candidates" >&2
        echo "$candidates"; return
    fi

    local half_a half_b
    half_a=$(echo "$candidates" | tr ',' '\n' | head -n $((count / 2)) | paste -sd, -)
    half_b=$(echo "$candidates" | tr ',' '\n' | tail -n $((count - count / 2)) | paste -sd, -)

    local result_a result_b
    result_a=$(try_majors "$half_a" "$phase")
    result_b=$(try_majors "$half_b" "$phase")

    if [ "$result_a" = "pass" ] && [ "$result_b" = "pass" ]; then
        echo "::warning::Both halves passed at depth=$depth — re-running once for flake check" >&2
        result_a=$(try_majors "$half_a" "$phase")
        result_b=$(try_majors "$half_b" "$phase")
        if [ "$result_a" = "pass" ] && [ "$result_b" = "pass" ]; then echo ""; return; fi
    fi

    local culprits_a="" culprits_b=""
    [ "$result_a" = "fail" ] && culprits_a=$(bisect_culprits "$half_a" "$phase" $((depth + 1)))
    [ "$result_b" = "fail" ] && culprits_b=$(bisect_culprits "$half_b" "$phase" $((depth + 1)))

    echo "${culprits_a},${culprits_b}" | tr ',' '\n' | grep -v '^$' | sort -u | paste -sd, -
}

locate_and_confirm() {
    local candidates="$1"
    local phase="$2"

    if [ "$BISECT_MAX_DEPTH" -le 0 ]; then echo "$candidates"; return; fi

    local culprits
    culprits=$(bisect_culprits "$candidates" "$phase" 0)

    if [ -z "$culprits" ]; then
        echo "::warning::Bisection nominated no culprits — falling back to full set" >&2
        echo "$candidates"; return
    fi

    local non_culprits
    non_culprits=$(echo "$candidates" | tr ',' '\n' | grep -v '^$' \
                   | grep -vxFf <(echo "$culprits" | tr ',' '\n' | grep -v '^$') \
                   | paste -sd, -)

    local verify
    verify=$(try_majors "$non_culprits" "$phase")
    if [ "$verify" = "fail" ]; then
        echo "::warning::Confirmation failed (interaction effects) — falling back to full set" >&2
        echo "$candidates"; return
    fi
    echo "$culprits"
}

# ---------- AI escalation helpers ----------

# ai_resolve PHASE LOGFILE → prints a JSON plan (or empty on failure).
# The model only PROPOSES levers; apply_ai_plan validates before acting.
ai_resolve() {
    local phase="$1" logfile="$2" sys user body resp
    [ -z "$ANTHROPIC_API_KEY" ] && { echo ""; return; }

    sys='You resolve failures in a CI job that updates ONE framework and opens a PR.
Output ONLY minified JSON. No prose, no markdown fences.
Schema: {"diagnosis":string,"confidence":"high"|"medium"|"low","actions":[{"type":"coupgrade"|"reject"|"legacy_peer_deps","package":string?}]}
HARD RULES:
1. The package named in FRAMEWORK must ALWAYS end up updated. NEVER propose reject for it.
2. Only reference packages listed in OWNED.
3. NEVER emit version numbers — the pipeline resolves versions via ncu/npm.
4. Prefer coupgrade of the plugin whose peer range blocks the framework. Use legacy_peer_deps only if no owned package can be moved to fix it.'

    user=$(jq -n \
        --arg fw "$FRAMEWORK_NAME" --arg phase "$phase" \
        --arg owned "$OUR_DEPS" --arg rej "$REJECT_LIST" --arg cou "$PIN_LIST" \
        --arg deps "$(jq -c '{dependencies,devDependencies}' package.json)" \
        --arg err "$(tail -c 6000 "$logfile")" \
        '{FRAMEWORK:$fw, PHASE:$phase,
          OWNED:($owned|split("\n")|map(select(.!=""))),
          ALREADY_REJECTED:$rej, ALREADY_COUPGRADED:$cou,
          CURRENT_DEPS:$deps, ERROR_LOG:$err}
         | "Resolve this failure. Choose the minimal set of actions.\n" + tojson')

    body=$(jq -n --arg m "$AI_MODEL" --arg s "$sys" --arg u "$user" \
        '{model:$m, max_tokens:1024, system:$s, messages:[{role:"user",content:$u}]}')

    resp=$(curl -sS --max-time 60 https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$body" 2>/dev/null || echo '{}')

    echo "$resp" | jq -r '[.content[]?|select(.type=="text")|.text]|join("")' 2>/dev/null \
        | sed 's/```json//g; s/```//g'
}

# apply_ai_plan PLAN → validates + applies; returns 0 if it changed state.
apply_ai_plan() {
    local plan="$1" applied=0 atype apkg before
    echo "$plan" | jq empty 2>/dev/null || { echo "::warning::AI plan not valid JSON"; return 1; }
    AI_DIAGNOSIS=$(echo "$plan" | jq -r '.diagnosis // ""')

    while IFS=$'\t' read -r atype apkg; do
        case "$atype" in
          legacy_peer_deps)
            NPM_INSTALL_FLAGS="--legacy-peer-deps"; LEGACY_FALLBACK_USED=1
            echo "🤖 AI: force --legacy-peer-deps"; applied=1 ;;
          coupgrade)
            echo "$OUR_DEPS" | grep -qx "$apkg" || { echo "::warning::AI coupgrade of non-owned '$apkg' ignored"; continue; }
            # resolve_and_pin picks the newest version compatible with the framework
            # version being installed — never a blind bump to latest.
            if resolve_and_pin "$apkg"; then applied=1; fi ;;
          reject)
            [ "$apkg" = "$FRAMEWORK_NAME" ] && { echo "::warning::AI tried to reject framework $apkg — REFUSED"; continue; }
            echo "$OUR_DEPS" | grep -qx "$apkg" || { echo "::warning::AI reject of non-owned '$apkg' ignored"; continue; }
            before="$REJECT_LIST"; add_reject "$apkg"
            [ "$REJECT_LIST" != "$before" ] && { echo "🤖 AI: reject $apkg"; applied=1; } ;;
          *) echo "::warning::AI unknown action '$atype' ignored" ;;
        esac
    done < <(echo "$plan" | jq -r '.actions[]? | [.type, (.package // "")] | @tsv' 2>/dev/null)

    return $((applied ? 0 : 1))
}

# try_ai PHASE LOGFILE → returns 0 if a plan was applied (caller should continue).
try_ai() {
    [ "$AI_ATTEMPTS_USED" -ge "$AI_MAX_ATTEMPTS" ] && { echo "::warning::AI attempt budget exhausted"; return 1; }
    [ -z "$ANTHROPIC_API_KEY" ] && { echo "::warning::ANTHROPIC_API_KEY not set — skipping AI escalation"; return 1; }
    AI_ATTEMPTS_USED=$((AI_ATTEMPTS_USED + 1))
    echo "🤖 Escalating to AI ($AI_MODEL, attempt $AI_ATTEMPTS_USED)"
    local plan; plan=$(ai_resolve "$1" "$2")
    echo "AI plan: ${plan:-<empty>}"
    apply_ai_plan "$plan"
}

# ================= Self-healing loop =================
for attempt in $(seq 1 $MAX_ATTEMPTS); do
    echo ""
    echo "===== Attempt $attempt of $MAX_ATTEMPTS ====="

    rm -rf node_modules lib dist
    cp /tmp/pkg.orig package.json
    cp /tmp/lock.orig package-lock.json

    REJECT_ARG=$(make_reject_arg)
    if [ -n "$REJECT_ARG" ]; then
        echo "Rejecting: $REJECT_ARG"
        ncu -u --target "$TARGET" --reject "$REJECT_ARG"
    else
        ncu -u --target "$TARGET"
    fi

    # Re-assert compatibility pins over whatever ncu wrote (must run every iteration).
    if [ -n "$PIN_LIST" ]; then
        echo "🤝 Applying compatibility pins: $(echo "$PIN_LIST" | tr ',' ' ')"
        apply_pins
    fi

    # ----- Install -----
    npm install $NPM_INSTALL_FLAGS 2>&1 | tee /tmp/install.log
    INSTALL_EXIT=${PIPESTATUS[0]}

    if [ $INSTALL_EXIT -ne 0 ]; then
        if grep -qE "ETIMEDOUT|ECONNRESET|ENOTFOUND|EAI_AGAIN" /tmp/install.log; then
            echo "::warning::Network issue, retrying in 10s"; sleep 10; continue
        fi
        if ! grep -q "ERESOLVE" /tmp/install.log; then
            echo "::error::Non-ERESOLVE install failure"; cat /tmp/install.log; exit 1
        fi

        # ----- Framework-vs-plugin peer conflict -----
        # The framework we're bumping is too new for a plugin's declared peer range.
        # We never drop the framework, and we must NOT blindly bump the plugin to its
        # latest (its latest may demand a different framework version → still broken).
        # Instead pin each blocking plugin to the newest version whose framework peer
        # range is actually satisfied by the framework version we're installing.
        if grep -qE "peer +${FRAMEWORK_NAME}@" /tmp/install.log; then
            RAWBLOCK=$(grep -oP "from \K[@a-z0-9][@a-z0-9/._-]*(?=@)" /tmp/install.log | sort -u || true)
            PROGRESS=0
            while IFS= read -r b; do
                [ -z "$b" ] && continue
                [ "$b" = "$FRAMEWORK_NAME" ] && continue
                echo "$OUR_DEPS" | grep -qx "$b" || continue    # only packages we own
                if resolve_and_pin "$b"; then PROGRESS=1; fi
            done <<< "$RAWBLOCK"

            if [ "$PROGRESS" -eq 1 ]; then continue; fi

            # No plugin version (>= its baseline) accepts this framework version →
            # the ecosystem hasn't caught up. Force it through for human review.
            if [ "$LEGACY_FALLBACK_USED" -eq 0 ]; then
                echo "::warning::No compatible plugin release for the target $FRAMEWORK_NAME version — forcing --legacy-peer-deps (tests will arbitrate)"
                NPM_INSTALL_FLAGS="--legacy-peer-deps"; LEGACY_FALLBACK_USED=1
                continue
            fi

            if try_ai "install" /tmp/install.log; then continue; fi
            echo "::error::$FRAMEWORK_NAME peer conflict unresolved even with --legacy-peer-deps"
            cat /tmp/install.log; exit 1
        fi

        # ----- Generic ERESOLVE conflict -----
        CANDIDATES=$( {
            grep -oP "Conflicting peer dependency: \K[@a-z0-9/-]+" /tmp/install.log
            grep -oP "peer \K[@a-z0-9/-]+(?=@)" /tmp/install.log
            grep -oP "Found: \K[@a-z0-9/-]+(?=@)" /tmp/install.log
        } | sort -u | tr '\n' ',' | sed 's/,$//')

        BEFORE_RJ="$REJECT_LIST"
        IFS=',' read -ra ARR <<< "$CANDIDATES"
        for pkg in "${ARR[@]}"; do
            [ -z "$pkg" ] && continue
            echo "$OUR_DEPS" | grep -qx "$pkg" || continue     # only packages we own
            add_reject "$pkg"                                   # skips framework + coupgraded
        done

        if [ "$REJECT_LIST" = "$BEFORE_RJ" ]; then
            if try_ai "install" /tmp/install.log; then continue; fi
            echo "::error::ERESOLVE conflict with no actionable packages (AI could not help)"
            cat /tmp/install.log; exit 1
        fi
        echo "🔎 Reject (install conflict): $REJECT_LIST"
        continue
    fi

    # ----- Build -----
    if [ "$HAS_BUILD" -gt 0 ]; then
        echo "Running build..."
        if npm run build 2>&1 | tee /tmp/build.log; then
            echo "✅ Build succeeded"
        else
            CURRENT_MAJORS=$(identify_major_bumps)
            if [ -z "$CURRENT_MAJORS" ]; then
                if try_ai "build" /tmp/build.log; then continue; fi
                echo "::error::Build failed and no major bumps left to roll back"
                cat /tmp/build.log; exit 1
            fi
            echo "🔬 Bisecting build culprits among: $CURRENT_MAJORS"
            CULPRITS=$(locate_and_confirm "$CURRENT_MAJORS" "build")
            BEFORE_RJ="$REJECT_LIST"
            for pkg in $(echo "$CULPRITS" | tr ',' '\n'); do
                [ -z "$pkg" ] && continue
                add_reject "$pkg"      # never rolls back framework or a coupgraded plugin
            done
            if [ "$REJECT_LIST" = "$BEFORE_RJ" ]; then
                if try_ai "build" /tmp/build.log; then continue; fi
                echo "::error::Build failed and bisection returned nothing actionable"
                cat /tmp/build.log; exit 1
            fi
            echo "🔎 Reject (build failure, bisected): $REJECT_LIST"
            continue
        fi
    fi

    # ----- Test -----
    if [ "$HAS_TEST" -gt 0 ]; then
        echo "Running tests..."
        if npm test 2>&1 | tee /tmp/test.log; then
            echo "✅ Tests passed"
            TEST_OUTCOME="success"
        else
            CURRENT_MAJORS=$(identify_major_bumps)
            if [ -n "$CURRENT_MAJORS" ]; then
                echo "🔬 Bisecting test culprits among: $CURRENT_MAJORS"
                CULPRITS=$(locate_and_confirm "$CURRENT_MAJORS" "test")
                BEFORE_RJ="$REJECT_LIST"
                for pkg in $(echo "$CULPRITS" | tr ',' '\n'); do
                    [ -z "$pkg" ] && continue
                    add_reject "$pkg"
                done
                if [ "$REJECT_LIST" != "$BEFORE_RJ" ]; then
                    echo "🔎 Reject (test failure, bisected): $REJECT_LIST"
                    continue
                fi
            fi
            # A test failure that survives bisection is likely a real regression,
            # not a resolution problem — ship the PR flagged for a human rather
            # than dropping the framework or spending AI budget guessing.
            echo "::warning::Tests still failing with no actionable rollbacks — shipping PR for human review"
            TEST_OUTCOME="failure"
        fi
    fi

    LOOP_RESULT="success"
    break
done

if [ "$LOOP_RESULT" != "success" ]; then
    echo "::error::Could not converge after $MAX_ATTEMPTS attempts"
    echo "Final reject list: $REJECT_LIST"
    echo "Final pin list: $PIN_LIST"
    exit 1
fi

BISECT_TRIALS=$(cat "$TRIAL_COUNTER")

# ---------- Held-back report (defensive) ----------
REJECT_DETAILS=$(jq -r -n \
    --slurpfile orig /tmp/pkg.orig \
    --argjson probe "$PROBE" \
    --arg list "$REJECT_LIST" '
    def safe_obj(x): if (x | type) == "object" then x else {} end;
    (safe_obj($orig[0].dependencies) + safe_obj($orig[0].devDependencies)) as $old |
    ($list | split(",") | map(select(. != ""))) as $rejected |
    $rejected[] |
    select($probe[.] != null and $old[.] != null) |
    select(($old[.] | type) == "string" and ($probe[.] | type) == "string") |
    "- **\(.)**: `\($old[.])` → `\($probe[.])` _(held back)_"
')

# ---------- Compatibility-pin report (baseline → pinned exact version) ----------
# PIN_LIST is "pkg=ver,pkg=ver"; report old range vs the exact version we pinned.
COUPGRADE_LIST=$(echo "$PIN_LIST" | tr ',' '\n' | sed 's/=.*//' | grep -v '^$' | paste -sd, -)
COUPGRADE_DETAILS=$(
    printf '%s\n' "$PIN_LIST" | tr ',' '\n' | grep -v '^$' | while IFS='=' read -r p v; do
        old=$(jq -r --arg p "$p" '((.dependencies[$p] // .devDependencies[$p]) // "") ' /tmp/pkg.orig)
        echo "- **$p**: \`${old:-—}\` → \`$v\` _(pinned for $FRAMEWORK_NAME compatibility)_"
    done
)

{
    echo "attempts=$attempt"
    echo "bisect_trials=$BISECT_TRIALS"
    echo "test_outcome=$TEST_OUTCOME"
    echo "forced_legacy=$LEGACY_FALLBACK_USED"
    echo "ai_used=$AI_ATTEMPTS_USED"
    echo "rejected=$REJECT_LIST"
    echo "coupgraded=$COUPGRADE_LIST"
    echo "reject_details<<REJECT_EOF"
    echo "$REJECT_DETAILS"
    echo "REJECT_EOF"
    echo "coupgrade_details<<COUP_EOF"
    echo "$COUPGRADE_DETAILS"
    echo "COUP_EOF"
    echo "ai_diagnosis<<AI_EOF"
    echo "$AI_DIAGNOSIS"
    echo "AI_EOF"
} >> $GITHUB_OUTPUT
