#!/bin/bash
# shellcheck disable=SC2016
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

DEFAULT_POLICY='{"thresholds":{"moderate":21,"elevated":41,"high":61,"critical":81},"weights":{"blast_radius":25,"reversibility":25,"security":25,"complexity":10,"uncertainty":15}}'

LIB='
def dims: ["blast_radius","reversibility","security","complexity","uncertainty"];
def classes: ["low","moderate","elevated","high","critical"];
def rank: . as $c | classes | index($c);
def hazard_floors: {
  "data-loss": "critical", "destructive-op": "critical",
  "auth": "high", "secrets": "high", "sensitive-data": "high", "money": "high", "irreversible": "high",
  "schema-migration": "elevated", "external-side-effect": "elevated", "new-dependency": "elevated"};
def hazard_patterns: {
  "data-loss": "\\b(delet\\w*|purg\\w*|wip(e|es|ed|ing)|eras(e|es|ed|ing)|overwrit\\w*|truncat\\w*|drop(s|ped|ping)?|destroy\\w*)\\b",
  "destructive-op": "drop (table|database|column|schema|index)|rm -rf|force[- ]push|\\b(bulk|mass)[- ]delet|\\bdelete all\\b",
  "schema-migration": "\\bmigrat\\w*|\\bschema\\b|alter table|\\b(new|adds?|added|adding) (a |an |the )?(db |database )?(column|table)s?\\b",
  "auth": "\\b(log ?in|log ?out|sign ?in|sign ?out|sign ?up|passwords?|passphrases?|authenticat\\w*|authori[sz]\\w*|permissions?|roles?|sessions?|access control|admins?|tokens?|2fa|mfa|oauth|sso)\\b",
  "secrets": "\\b(secrets?|api[ _-]?keys?|credentials?|private keys?|signing keys?)\\b|\\.env\\b",
  "money": "\\b(payments?|pay|paid|billing|invoices?|charg(e|es|ed|ing)|refunds?|subscriptions?|checkout|currenc(y|ies)|pric(e|es|ing)|money|wallets?)\\b",
  "sensitive-data": "\\b(personal data|pii|ssn|social security|credit cards?|card numbers?|date of birth|medical|health records?|passports?|gdpr)\\b",
  "external-side-effect": "\\b(sends?|sending|sent) (an? |the )?(e-?mails?|sms|text messages?|notifications?)\\b|\\bwebhooks?\\b|\\bpush notifications?\\b",
  "new-dependency": "\\b(new|adds?|added|adding) (a |an |the )?(third[- ]party )?(dependency|dependencies|library|package)\\b",
  "irreversible": "\\b(one[- ]way|irreversibl\\w*|cannot be undone|permanent(ly)?)\\b"};
def trigger_floors: {"auth": 4, "secrets": 4, "sessions": 3, "data-access": 3, "file-uploads": 3, "llm-tools": 3,
  "user-input": 2, "external-calls": 2, "dependencies": 2};
def autonomy: {
  "low": "autonomous: gate and reviewer",
  "moderate": "autonomous with verification: reviewer evidence must reach unit-test-verified",
  "elevated": "reviewer-gated with deeper tests (gate.mutation or live-verified, else a human approves the merge); builder on the session model",
  "high": "a human approves the merge (approve-risk.sh merge) after reviewer and auditor",
  "critical": "stopped: a human authorizes before any build (approve-risk.sh authorize) and approves the merge"};
def nonempty: type == "string" and test("\\S");
def placeholder: test("^\\s*(none|n/?a|tbd|todo|unknown|-|\\?)?\\s*$"; "i");
def strlist: type == "array" and all(.[]; nonempty);
def slabel($i): if (.id | nonempty) then .id else "slice[\($i)]" end;
def risk_text: [.title, .so_that, ((.acceptance_criteria // []) | if type == "array" then .[] else empty end)]
  | map(select(type == "string")) | join(" ") | ascii_downcase;
def detected: risk_text as $t | [hazard_patterns | to_entries[] | select(.value as $p | $t | test($p)) | .key];
def structure($s):
  .risk as $r
  | if ($r | type) != "object" then "\($s): no risk assessment — add risk {dimensions, rationale, hazards, scope, rollback} (risk-gate skill)"
    else
      (if ($r.dimensions | type) != "object" then "\($s): risk.dimensions must rate \(dims | join(", ")) as 0-4"
       else dims[] as $k | $r.dimensions[$k] as $v
         | select(if ($v | type) != "number" then true else ($v != ($v | floor) or $v < 0 or $v > 4) end)
         | "\($s): risk.dimensions.\($k) must be a whole number 0-4 (got \($v | tojson))" end),
      (if ($r.rationale | nonempty) then empty else "\($s): risk.rationale missing — why these ratings" end),
      (if ($r.hazards | type) != "array" then "\($s): risk.hazards must be an array, [] for none"
       else $r.hazards[] | select(IN(hazard_floors | keys[]) | not)
         | "\($s): risk hazard \(tojson) unknown (one of: \(hazard_floors | keys | join(", ")))" end),
      (if $r.ruled_out == null or ($r.ruled_out | type) == "object" then empty
       else "\($s): risk.ruled_out must map a hazard to the reason it does not apply" end),
      (if ($r.scope | type) != "object" then "\($s): risk.scope missing — {change, files, unchanged, regressions}"
       else
         (if ($r.scope.change | nonempty) then empty else "\($s): risk.scope.change missing — the smallest change that solves the task" end),
         (if ($r.scope.files | strlist) and ($r.scope.files | length) > 0
          then $r.scope.files[] | select(test("^[./*]*$")) | "\($s): risk.scope.files entry \(tojson) matches everything — name the paths the change touches"
          else "\($s): risk.scope.files must list the paths or globs the change may touch" end),
         (if ($r.scope.unchanged | strlist) then empty else "\($s): risk.scope.unchanged must list behavior that must not change, [] for none" end),
         (if ($r.scope.regressions | strlist) then empty else "\($s): risk.scope.regressions must list the regressions to watch, [] for none" end)
       end),
      (if ($r.rollback | nonempty) and (($r.rollback | placeholder) | not) then empty
       else "\($s): risk.rollback must name a rollback strategy" end),
      (if $r.safeguards == null or ($r.safeguards | strlist) then empty else "\($s): risk.safeguards must be an array of strings" end),
      (if (.auditor_triggers | type) == "array" then empty else "\($s): auditor_triggers must be an array before risk can be scored" end)
    end;
def floors_of($d):
  [ (.risk.hazards[] | {class: hazard_floors[.], why: "hazard \(.)"}),
    (if $d.security == 4 then {class: "high", why: "security 4"} else empty end),
    (if $d.reversibility == 4 then {class: "high", why: "reversibility 4"} else empty end) ];
def controls($class; $triggers):
  ($class | rank) as $n
  | ["gate", "reviewer"]
    + (if $n >= 1 then ["verified"] else [] end)
    + (if $n >= 2 then ["deep-tests", "full-model"] else [] end)
    + (if $n >= 3 or ($triggers | length) > 0 then ["auditor"] else [] end)
    + (if $n >= 3 then ["human-approval"] else [] end)
    + (if $n >= 4 then ["authorization"] else [] end);
def assess($policy):
  (.auditor_triggers // []) as $t
  | ([$t[] | trigger_floors[.] // 0] + [0] | max) as $secfloor
  | (.risk.dimensions | with_entries(select(.key | IN(dims[]))) | .security = ([.security, $secfloor] | max)) as $d
  | ([dims[] as $k | $policy.weights[$k] * $d[$k]] | add) as $sum
  | (($sum + 2) / 4 | floor) as $score
  | $policy.thresholds as $th
  | (if $score >= $th.critical then "critical" elif $score >= $th.high then "high"
     elif $score >= $th.elevated then "elevated" elif $score >= $th.moderate then "moderate" else "low" end) as $base
  | floors_of($d) as $floors
  | ([$base] + ($floors | map(.class)) | max_by(rank)) as $class
  | {score: $score, base: $base, class: $class,
     lifted_by: [$floors[] | select((.class | rank) > ($base | rank)) | "\(.why) -> \(.class)"],
     security_floor: (if $secfloor > .risk.dimensions.security then $secfloor else null end),
     dimensions: $d, controls: controls($class; $t)};
def derived($s; $policy):
  .risk as $r | assess($policy) as $a
  | (detected[] | select(. as $h | ($r.hazards | index($h)) == null and ((($r.ruled_out // {})[$h]) | nonempty | not))
       | "\($s): the criteria mention \(.) — add it to risk.hazards, or say why not in risk.ruled_out"),
    (if $a.class == "critical" and (($r.safeguards // []) | length) == 0
     then "\($s): critical risk needs risk.safeguards — the extra protections a human authorizes" else empty end),
    (if $r.score != null and $r.score != $a.score
     then "\($s): risk.score \($r.score | tojson) is not the computed \($a.score) — leave score and class to risk-gate.sh" else empty end),
    (if $r.class != null and $r.class != $a.class
     then "\($s): risk.class \($r.class | tojson) is not the computed \($a.class)" else empty end);
def problems($s; $policy): [structure($s)] as $e | if ($e | length) > 0 then $e[] else derived($s; $policy) end;
'

usage() {
  echo "usage: risk-gate.sh lint <plan.json> | table <plan.json> | score [slice.json|-] | show <ID> | assess <ID>" >&2
  echo "       risk-gate.sh check <ID> <build|merge> | scope [ID] | pending | calibrate | audit <ID>" >&2
  exit 2
}
die() { echo "risk-gate: $1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq · winget install jqlang.jq · apt install jq). Failing closed."

root="" common="" tree="" log="" ledger="" project=""
if common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  root=$(dirname "$common")
  tree="$root/vault/task-tree.json"
  log="$root/vault/log.jsonl"
  ledger="$common/donedonedone/approvals.jsonl"
  project="$root/vault/project.md"
fi
base="${GATE_BASE:-main}"
here="$(cd "$(dirname "$0")" && pwd)"

POLICY="$DEFAULT_POLICY"
policy_note=""
if [ -n "$root" ] && [ -f "$root/vault/risk-policy.json" ]; then
  POLICY=$(jq -c --argjson d "$DEFAULT_POLICY" '$d * .' "$root/vault/risk-policy.json" 2>/dev/null) \
    || die "vault/risk-policy.json is not a JSON object. Failing closed."
  policy_err=$(jq -r "$LIB"'
    def whole: type == "number" and . == floor;
    .thresholds as $t | .weights as $w
    | if ([$t.moderate, $t.elevated, $t.high, $t.critical] | all(.[]; whole)) | not then "thresholds must be whole numbers"
      elif ($t.moderate >= 1 and $t.moderate < $t.elevated and $t.elevated < $t.high and $t.high < $t.critical and $t.critical <= 100) | not
        then "thresholds must rise: 1 <= moderate < elevated < high < critical <= 100"
      elif ($w | keys | sort) != (dims | sort) then "weights must rate exactly \(dims | join(", "))"
      elif ([$w[]] | all(.[]; whole and . >= 0)) | not then "weights must be whole numbers >= 0"
      elif ([$w[]] | add) != 100 then "weights must add up to 100"
      else empty end' <<<"$POLICY" 2>&1)
  [ -z "$policy_err" ] || die "vault/risk-policy.json: $policy_err. Failing closed."
  policy_note=" policy=vault/risk-policy.json"
fi

jqlib() { local prog="$1"; shift; jq "$@" --argjson policy "$POLICY" "$LIB$prog"; }

hash_of() {
  jq -cS '{title, acceptance_criteria, auditor_triggers, risk: (.risk | del(.score, .class))}' <<<"$1" | git hash-object --stdin | cut -c1-12
}

require_tree() {
  [ -n "$root" ] || die "not inside a git repo"
  [ -f "$tree" ] || die "no vault/task-tree.json — run /init-codebase"
  jq -e 'type == "object"' "$tree" >/dev/null 2>&1 || die "vault/task-tree.json is not valid JSON. Failing closed."
}

slice_from() {
  jq -c --arg id "$2" '[.slices[]? | select(.id == $id)][0] // empty' 2>/dev/null <<<"$1"
}

working_slice() { slice_from "$(cat "$tree")" "$1"; }

branch_slice() {
  local content
  content=$(git -C "$root" show "slice/$1:vault/task-tree.json" 2>/dev/null) || return 0
  slice_from "$content" "$1"
}

problems_of() { jqlib 'problems(.id // "slice"; $policy)' -r <<<"$1"; }

assessment_of() { jqlib 'assess($policy)' -c <<<"$1"; }

events_of() {
  {
    [ -f "$log" ] && awk '{ print "F " $0 }' "$log"
    [ -n "${2:-}" ] && git -C "$root" show "$2:vault/log.jsonl" 2>/dev/null | awk '{ print "G " $0 }'
  } | awk '{ line = substr($0, 3) } /^F / { kept[line]++; print line; next } ++extra[line] > kept[line] { print line }' \
    | jq -Rc --arg id "$1" 'fromjson? | select(type == "object" and .slice == $id)' | jq -sc 'sort_by(.ts // "")'
}

ledger_of() {
  if [ -f "$ledger" ]; then
    jq -Rc --arg id "$1" 'fromjson? | select(type == "object" and .slice == $id)' "$ledger" | jq -sc 'sort_by(.ts // "")'
  else
    echo '[]'
  fi
}

append_only() {
  local rel="$1" committed n status=0
  git -C "$root" cat-file -e "HEAD:$rel" 2>/dev/null || return 0
  committed=$(mktemp)
  git -C "$root" show "HEAD:$rel" > "$committed"
  n=$(wc -c < "$committed" | tr -d ' ')
  if [ ! -f "$root/$rel" ] || ! head -c "$n" "$root/$rel" | cmp -s - "$committed"; then status=1; fi
  rm -f "$committed"
  return "$status"
}

mutation_configured() {
  local value
  [ -f "$project" ] || return 1
  value=$(sed -n 's/^[-*][[:space:]]*gate\.mutation:[[:space:]]*//p' "$project" | head -1 | tr -d '\r`')
  [ -n "$value" ] && [ "$value" != "none" ]
}

out_of_scope() {
  local slice="$1" dir="$2" range="$3" globs=() g f hit
  while IFS= read -r g; do globs+=("$g"); done < <(jq -r '.risk.scope.files[]' <<<"$slice")
  git -C "$dir" diff --name-only "$range" -- . ':(exclude)vault' | while IFS= read -r f; do
    hit=0
    for g in "${globs[@]}"; do
      # shellcheck disable=SC2254
      case "$f" in $g) hit=1; break ;; esac
    done
    [ "$hit" -eq 1 ] || printf '%s\n' "$f"
  done
}

summary() {
  local slice="$1" hash="$2"
  jqlib '
    assess($policy) as $a | .risk as $r
    | "RISK: \(.id // "-") class=\($a.class) score=\($a.score) base=\($a.base) hash=\($hash)",
      "DIMENSIONS: \(dims | map("\(.) \($a.dimensions[.])") | join(" · "))\(if $a.security_floor then " (security raised to \($a.security_floor) by auditor_triggers)" else "" end)",
      "LIFTED BY: \(if ($a.lifted_by | length) > 0 then $a.lifted_by | join(", ") else "nothing — the score sets the class" end)",
      "HAZARDS: \(if ($r.hazards | length) > 0 then $r.hazards | join(", ") else "none" end)\(if (($r.ruled_out // {}) | length) > 0 then " · ruled out: \($r.ruled_out | to_entries | map("\(.key) (\(.value))") | join("; "))" else "" end)",
      "CONTROLS: \($a.controls | join(", "))",
      "AUTONOMY: \(autonomy[$a.class])",
      "SAFEGUARDS: \(if (($r.safeguards // []) | length) > 0 then $r.safeguards | join("; ") else "none" end)",
      "ROLLBACK: \($r.rollback)",
      "SCOPE: \($r.scope.change) — files: \($r.scope.files | join(", "))",
      "UNCHANGED: \(if ($r.scope.unchanged | length) > 0 then $r.scope.unchanged | join("; ") else "none listed" end)",
      "REGRESSIONS: \(if ($r.scope.regressions | length) > 0 then $r.scope.regressions | join("; ") else "none listed" end)",
      "RATIONALE: \($r.rationale)"' -r --arg hash "$hash" <<<"$slice"
}

cmd_lint() {
  [ -f "$1" ] || die "no plan at $1"
  jqlib 'if type != "array" then empty
         else to_entries[] | .key as $i | .value | select(type == "object") | problems(slabel($i); $policy) end' -r < "$1" 2>/dev/null \
    || die "$1 could not be read as JSON"
}

cmd_table() {
  [ -f "$1" ] || die "no plan at $1"
  jqlib 'to_entries[] | .key as $i | .value | slabel($i) as $s
    | if ([problems($s; $policy)] | length) > 0 then "\($s) · risk: invalid"
      else assess($policy) as $a
        | "\($s) · \($a.class) \($a.score)\(if ($a.lifted_by | length) > 0 then " (lifted: \($a.lifted_by | join(", ")))" else "" end) · controls: \($a.controls | join(", "))"
      end' -r < "$1" 2>/dev/null || die "$1 could not be read as JSON"
}

cmd_score() {
  local slice found
  slice=$(cat "${1:--}") || die "cannot read ${1:--}"
  jq -e 'type == "object"' <<<"$slice" >/dev/null 2>&1 || die "input is not a slice JSON object"
  found=$(problems_of "$slice")
  if [ -n "$found" ]; then
    echo "$found" | head -18
    echo "RISK: INVALID"
    exit 1
  fi
  summary "$slice" "$(hash_of "$slice")"
}

cmd_show() {
  local slice found
  require_tree
  slice=$(working_slice "$1")
  [ -n "$slice" ] || die "slice $1 is not in vault/task-tree.json"
  found=$(problems_of "$slice")
  [ -z "$found" ] || { echo "$found" | head -18; echo "RISK: INVALID"; exit 1; }
  summary "$slice" "$(hash_of "$slice")"
}

cmd_assess() {
  local id="$1" slice found hash a class score prev lifted args=()
  require_tree
  slice=$(working_slice "$id")
  [ -n "$slice" ] || die "slice $id is not in vault/task-tree.json"
  found=$(problems_of "$slice")
  if [ -n "$found" ]; then
    echo "$found" | head -18
    echo "RISK: INVALID — fix the assessment, then re-run risk-gate.sh assess $id"
    exit 1
  fi
  hash=$(hash_of "$slice")
  a=$(assessment_of "$slice")
  class=$(jq -r .class <<<"$a")
  score=$(jq -r .score <<<"$a")
  prev=$(events_of "$id" | jq -c '[.[] | select(.event == "risk")] | last // empty')
  if [ -n "$prev" ] && [ "$(jq -r '.hash // ""' <<<"$prev")" = "$hash" ]; then
    summary "$slice" "$hash"
    echo "RECORDED: already in vault/log.jsonl"
    return 0
  fi
  args=("$id" risk "$class" --score "$score" --hash "$hash" --signal "$(jq -r .risk.rationale <<<"$slice")")
  lifted=$(jq -r '.lifted_by | join(", ")' <<<"$a")
  [ -n "$lifted" ] && args+=(--signal "lifted by: $lifted")
  if [ -n "$prev" ]; then
    args+=(--signal "reassessed from $(jq -r '"\(.verdict) \(.score // "?")"' <<<"$prev")")
    if [ "$(jqlib '($a | rank) > ($b | rank)' -n --arg a "$class" --arg b "$(jq -r .verdict <<<"$prev")" 2>/dev/null)" = "true" ]; then
      args+=(--category risk-underestimate)
    fi
  fi
  "$here/log-event.sh" "${args[@]}" || die "could not record the assessment in vault/log.jsonl"
  summary "$slice" "$hash"
  echo "RECORDED: risk event in vault/log.jsonl"
}

joined() {
  local out
  [ $# -gt 0 ] || { echo none; return; }
  out=$(printf '%s, ' "$@")
  echo "${out%, }"
}

evaluate_controls() {
  jqlib '
    .events as $e | .ledger as $l | .patch as $p | .hash as $h | .id as $id
    | def last_ev($ev): [$e[] | select(.event == $ev and .patch_id == $p)] | last;
      def last_appr($kind): [$l[] | select(.kind == $kind and .hash == $h and ($kind != "merge" or .patch_id == $p))] | last;
    .controls[] as $c
    | if $c == "gate" then
        (last_ev("gate") as $g
         | if $g == null then "MISSING gate: no gate verdict logged at patch_id \($p)"
           elif $g.verdict == "PASS" then "OK gate PASS" else "MISSING gate: latest verdict \($g.verdict)" end)
      elif $c == "reviewer" then
        (last_ev("reviewer") as $r
         | if $r == null then "MISSING reviewer: no reviewer verdict logged at patch_id \($p)"
           elif $r.verdict == "APPROVED" then "OK reviewer APPROVED" else "MISSING reviewer: latest verdict \($r.verdict)" end)
      elif $c == "verified" then
        (last_ev("reviewer").evidence // "none") as $ev
        | if ($ev | IN("live-verified", "unit-test-verified")) then "OK verified \($ev)"
          else "MISSING verified: reviewer evidence is \($ev) — needs unit-test-verified or live-verified" end
      elif $c == "deep-tests" then
        if last_ev("reviewer").evidence == "live-verified" then "OK deep-tests live-verified"
        elif .mutation then "OK deep-tests gate.mutation in the full gate"
        elif last_appr("merge").decision == "approve" then "OK deep-tests waived by the human merge approval"
        else "MISSING deep-tests: configure gate.mutation, reach live-verified, or a human approves the merge (approve-risk.sh merge \($id))" end
      elif $c == "auditor" then
        (last_ev("auditor") as $a
         | if $a == null then "MISSING auditor: no auditor verdict logged at patch_id \($p)"
           elif ($a.verdict | IN("CLEARED", "CLEARED-WITH-FINDINGS")) then "OK auditor \($a.verdict)"
           else "MISSING auditor: latest verdict \($a.verdict)" end)
      elif $c == "full-model" then "OK full-model (enforced when the builder spawns)"
      elif $c == "human-approval" then
        (last_appr("merge") as $a
         | if $a == null then "MISSING human-approval: a human runs approve-risk.sh merge \($id) in their own terminal"
           elif $a.decision == "approve" then "OK human-approval by \($a.approver) at \($a.ts)"
           else "MISSING human-approval: denied by \($a.approver) at \($a.ts)" end)
      elif $c == "authorization" then
        (last_appr("authorize") as $a
         | if $a == null then "MISSING authorization: critical — a human runs approve-risk.sh authorize \($id) in their own terminal"
           elif $a.decision == "approve" then "OK authorization by \($a.approver) at \($a.ts)"
           else "MISSING authorization: denied by \($a.approver) at \($a.ts)" end)
      else "MISSING \($c): unknown control" end' -r
}

cmd_check() {
  local id="$1" stage="$2" fails=() events ledger_json recorded candidate slice="" hash="" a class score
  local eclass max_recorded downgrade triggers controls patch="" scope_out lines
  [ -n "$root" ] || die "not inside a git repo"
  if [ ! -f "$tree" ]; then
    echo "RISK: SKIP $stage $id (no vault/task-tree.json)"
    return 0
  fi
  jq -e 'type == "object"' "$tree" >/dev/null 2>&1 || die "vault/task-tree.json is not valid JSON. Failing closed."
  append_only vault/log.jsonl || fails+=("vault/log.jsonl no longer starts with its committed content — the log is append-only")

  local ref=""
  [ "$stage" = merge ] && ref="slice/$id"
  events=$(events_of "$id" "$ref")
  ledger_json=$(ledger_of "$id")
  recorded=$(jq -r '[.[] | select(.event == "risk")] | last | .hash // ""' <<<"$events")

  local candidates=()
  candidate=$(working_slice "$id"); [ -n "$candidate" ] && candidates+=("$candidate")
  if [ "$stage" = merge ]; then
    candidate=$(branch_slice "$id"); [ -n "$candidate" ] && candidates+=("$candidate")
  fi
  if [ ${#candidates[@]} -eq 0 ]; then
    echo "slice $id is not in vault/task-tree.json"
    echo "RISK: FAIL $stage $id"
    return 1
  fi
  for candidate in "${candidates[@]}"; do
    [ -z "$(problems_of "$candidate")" ] || continue
    if [ "$(hash_of "$candidate")" = "$recorded" ]; then slice="$candidate"; break; fi
  done
  if [ -z "$slice" ]; then
    lines=$(problems_of "${candidates[0]}")
    if [ -n "$lines" ]; then
      while IFS= read -r l; do fails+=("$l"); done <<<"$lines"
    elif [ -z "$recorded" ]; then
      fails+=("$id: no recorded risk assessment — the Director runs risk-gate.sh assess $id before any builder")
    else
      fails+=("$id: the assessment changed since it was recorded (now $(hash_of "${candidates[0]}"), recorded $recorded) — reassess: risk-gate.sh assess $id")
    fi
    printf '%s\n' "${fails[@]}" | head -16
    echo "RISK: FAIL $stage $id"
    return 1
  fi

  hash=$(hash_of "$slice")
  a=$(assessment_of "$slice")
  class=$(jq -r .class <<<"$a")
  score=$(jq -r .score <<<"$a")
  triggers=$(jq -c '.auditor_triggers // []' <<<"$slice")
  max_recorded=$(jqlib '[.[] | select(.event == "risk") | .verdict | select(IN(classes[]))] | max_by(rank) // "low"' -r <<<"$events")
  eclass="$class"
  if [ "$(jqlib '($a | rank) > ($b | rank)' -n --arg a "$max_recorded" --arg b "$class")" = "true" ]; then
    downgrade=$(jq -r --arg h "$hash" '[.[] | select(.kind == "downgrade" and .hash == $h)] | last | .decision // ""' <<<"$ledger_json")
    if [ "$downgrade" != "approve" ]; then
      eclass="$max_recorded"
      echo "NOTE: $id was reassessed down from $max_recorded to $class — its controls stay at $max_recorded until a human runs approve-risk.sh downgrade $id"
    fi
  fi
  controls=$(jqlib 'controls($c; $t)' -c -n --arg c "$eclass" --argjson t "$triggers")
  [ "$stage" = build ] && controls=$(jq -c 'map(select(. == "authorization" or . == "full-model"))' <<<"$controls")

  if [ "$stage" = merge ]; then
    if ! git -C "$root" rev-parse -q --verify "$base^{commit}" >/dev/null; then
      fails+=("no $base branch to merge into; set GATE_BASE")
    elif ! git -C "$root" rev-parse -q --verify "slice/$id^{commit}" >/dev/null; then
      fails+=("no slice/$id branch")
    else
      patch=$(git -C "$root" diff "$base...slice/$id" -- . ':(exclude)vault' | git patch-id --stable | cut -d' ' -f1)
      [ -n "$patch" ] || fails+=("slice/$id has no changes against $base outside vault/")
      scope_out=$(out_of_scope "$slice" "$root" "$base...slice/$id")
      [ -z "$scope_out" ] || fails+=("scope expanded beyond risk.scope.files: $(echo "$scope_out" | head -5 | tr '\n' ' ')— reassess before merging")
    fi
  fi

  local mutation=false
  mutation_configured && mutation=true
  lines=$(jq -n --argjson events "$events" --argjson ledger "$ledger_json" --argjson controls "$controls" \
    --arg patch "$patch" --arg hash "$hash" --arg id "$id" --argjson mutation "$mutation" \
    '{events: $events, ledger: $ledger, controls: $controls, patch: $patch, hash: $hash, id: $id, mutation: $mutation}' | evaluate_controls)
  local done_list=() missing=()
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in
      OK\ *) l="${l#OK }"; done_list+=("${l%% *}") ;;
      MISSING\ *) fails+=("${l#MISSING }"); l="${l#MISSING }"; missing+=("${l%%:*}") ;;
    esac
  done <<<"$lines"
  [ ${#fails[@]} -gt 0 ] && printf '%s\n' "${fails[@]}" | head -14
  echo "CONTROLS: $eclass requires $(jq -r 'if length == 0 then "nothing more at build" else join(", ") end' <<<"$controls") · done: $(joined "${done_list[@]}") · missing: $(joined "${missing[@]}")"
  if [ ${#fails[@]} -eq 0 ]; then
    echo "RISK: PASS $stage $id class=$eclass score=$score hash=$hash${patch:+ patch_id=$patch}$policy_note"
    return 0
  fi
  echo "RISK: FAIL $stage $id class=$eclass score=$score hash=$hash${patch:+ patch_id=$patch}$policy_note"
  return 1
}

cmd_scope() {
  local id="${1:-}" top branch slice found out n
  top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repo"
  if [ -z "$id" ]; then
    branch=$(git -C "$top" branch --show-current)
    case "$branch" in
      slice/?*) id="${branch#slice/}" ;;
      *) echo "not on a slice/<ID> branch"; exit 3 ;;
    esac
  fi
  [ -f "$tree" ] || { echo "no vault/task-tree.json"; exit 3; }
  git -C "$top" rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "no $base branch to diff against; set GATE_BASE"; exit 3; }
  jq -e 'type == "object"' "$tree" >/dev/null 2>&1 || { echo "vault/task-tree.json is not valid JSON"; exit 1; }
  slice=$(working_slice "$id")
  [ -n "$slice" ] || { echo "slice $id is not in vault/task-tree.json"; exit 1; }
  found=$(problems_of "$slice")
  [ -z "$found" ] || { echo "slice $id has no valid risk assessment: $(echo "$found" | head -1)"; exit 1; }
  out=$(out_of_scope "$slice" "$top" "$base...HEAD")
  if [ -n "$out" ]; then
    echo "the diff leaves the approved risk.scope.files — stop and report SCOPE-EXPANSION; the Director reassesses risk before you continue:"
    echo "$out"
    exit 1
  fi
  n=$(git -C "$top" diff --name-only "$base...HEAD" -- . ':(exclude)vault' | grep -c .)
  echo "$n changed files inside the approved scope"
}

cmd_pending() {
  local id slice hash recorded class auth
  [ -n "$root" ] && [ -f "$tree" ] || return 0
  jq -e 'type == "object"' "$tree" >/dev/null 2>&1 || { echo "vault/task-tree.json is not valid JSON"; return 0; }
  jq -r '.slices[]?.id // empty' "$tree" | head -40 | while IFS= read -r id; do
    slice=$(working_slice "$id")
    if [ -n "$(problems_of "$slice")" ]; then
      echo "$id · no valid risk assessment — its builder can't spawn until one is added and recorded"
      continue
    fi
    hash=$(hash_of "$slice")
    recorded=$(events_of "$id" | jq -r '[.[] | select(.event == "risk")] | last | .hash // ""')
    if [ "$recorded" != "$hash" ]; then
      echo "$id · assessment not recorded — risk-gate.sh assess $id"
      continue
    fi
    class=$(assessment_of "$slice" | jq -r .class)
    if [ "$class" = critical ]; then
      auth=$(ledger_of "$id" | jq -r --arg h "$hash" '[.[] | select(.kind == "authorize" and .hash == $h)] | last | .decision // ""')
      [ "$auth" = approve ] || echo "$id · critical — waiting on a human: approve-risk.sh authorize $id (in your own terminal)"
    fi
  done | head -12
}

cmd_calibrate() {
  [ -f "$log" ] || die "no vault/log.jsonl"
  jq -Rrs '
    def classes: ["low","moderate","elevated","high","critical"];
    def rank: . as $c | classes | index($c);
    [split("\n")[] | fromjson? | select(type == "object" and (.slice // "-") != "-")] as $all
    | [ $all | group_by(.slice)[] | . as $ev
        | ([$ev[] | select(.event == "risk" and (.verdict | IN(classes[])))] | sort_by(.ts // "")) as $r
        | select(($r | length) > 0)
        | {slice: $ev[0].slice, first: $r[0].verdict, last: $r[-1].verdict,
           rejected: ([$ev[] | select(.event == "reviewer" and .verdict == "REJECTED")] | length),
           blocked: ([$ev[] | select(.event == "auditor" and .verdict == "BLOCKED")] | length),
           expanded: ([$ev[] | select(.event == "scope")] | length),
           rolled_back: ([$ev[] | select(.event == "rollback")] | length),
           escalated: ([$ev[] | select(.event == "escalation")] | length),
           defects: ([$ev[] | select(.event == "defect")] | length)} ] as $s
    | "CALIBRATION: \($s | length) assessed slices (read-only — thresholds change only when a human edits vault/risk-policy.json)",
      (classes[] as $c | [$s[] | select(.first == $c)] as $g | select(($g | length) > 0)
        | "\($c): \($g | length) slices · \([$g[].rejected] | add) reviewer rejections · \([$g[].blocked] | add) auditor blocks · \([$g[] | select(.expanded > 0)] | length) scope expansions · \([$g[] | select(.rolled_back > 0)] | length) rollbacks · \([$g[] | select(.escalated > 0)] | length) escalations · \([$g[].defects] | add) post-merge defects"),
      ($s[] | select((.last | rank) > (.first | rank)
                     or ((.first | rank) <= 2 and (.rolled_back > 0 or .blocked > 0 or .escalated > 0 or .expanded > 0 or .defects > 0 or .rejected >= 2)))
        | "UNDERESTIMATE?: \(.slice) assessed \(.first)\(if .last != .first then ", reassessed \(.last)" else "" end) — \(.expanded) scope expansions, \(.rolled_back) rollbacks, \(.blocked) auditor blocks, \(.escalated) escalations, \(.rejected) rejections, \(.defects) post-merge defects")
  ' "$log" | head -20
}

cmd_audit() {
  require_tree
  events_of "$1" "slice/$1" | jq -r '.[] | select(.event | IN("risk", "scope", "gate", "reviewer", "auditor", "merge", "rollback", "escalation"))
    | "\(.ts) \(.event) \(.verdict)\(if .score then " score=\(.score)" else "" end)\(if .hash then " hash=\(.hash)" else "" end)\(if .patch_id then " patch_id=\(.patch_id)" else "" end)"' | tail -12
  ledger_of "$1" | jq -r '.[] | "\(.ts) human \(.kind) \(.decision) by \(.approver) hash=\(.hash)\(if .patch_id then " patch_id=\(.patch_id)" else "" end)"' | tail -6
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  lint) [ $# -eq 1 ] || usage; cmd_lint "$1" ;;
  table) [ $# -eq 1 ] || usage; cmd_table "$1" ;;
  score) [ $# -le 1 ] || usage; cmd_score "${1:--}" ;;
  show) [ $# -eq 1 ] || usage; cmd_show "$1" ;;
  assess) [ $# -eq 1 ] || usage; cmd_assess "$1" ;;
  check)
    [ $# -eq 2 ] || usage
    case "$2" in build|merge) ;; *) usage ;; esac
    cmd_check "$1" "$2" ;;
  scope) [ $# -le 1 ] || usage; cmd_scope "${1:-}" ;;
  pending) [ $# -eq 0 ] || usage; cmd_pending ;;
  calibrate) [ $# -eq 0 ] || usage; cmd_calibrate ;;
  audit) [ $# -eq 1 ] || usage; cmd_audit "$1" ;;
  *) usage ;;
esac
