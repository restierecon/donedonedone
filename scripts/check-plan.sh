#!/bin/bash

plan="${1:-vault/plan-draft.json}"
command -v jq >/dev/null 2>&1 || { echo "check-plan: FAIL — jq not installed" >&2; exit 1; }
[ -f "$plan" ] || { echo "check-plan: FAIL — no plan at $plan" >&2; exit 1; }

known=()
if [ -f vault/task-tree.json ]; then
  ids=$(jq -r '.slices[]?.id // empty' vault/task-tree.json) \
    || { echo "check-plan: FAIL — vault/task-tree.json is not valid JSON" >&2; exit 1; }
  while IFS= read -r id; do [ -n "$id" ] && known+=("$id"); done <<<"$ids"
fi
if [ -f vault/stories.md ]; then
  while IFS= read -r id; do known+=("$id"); done < <(sed -n 's/^## \([^ ]*\) .*/\1/p' vault/stories.md)
fi
external=$(printf '%s\n' "${known[@]}" | jq -R . | jq -s 'map(select(length > 0))')

errors=$(jq -r --argjson external "$external" '
  def verdicts: ["PASS","FAIL","COMPLETE","FAILED","APPROVED","REJECTED","CLEARED","CLEARED-WITH-FINDINGS","BLOCKED"];
  def nonempty: type == "string" and test("\\S");
  def stuck:
    if length == 0 then []
    else (to_entries | map(select(.value | length == 0)) | map(.key)) as $free
      | if ($free | length) == 0 then keys
        else with_entries(select(.value | length > 0) | .value |= map(select(IN($free[]) | not))) | stuck
        end
    end;
  if type != "array" then "plan: top level must be a JSON array of slices"
  else
    (map(.id | select(nonempty))) as $ids
    | (to_entries[] | .key as $i | .value | (if (.id | nonempty) then .id else "slice[\($i)]" end) as $s
      | (if (.id | nonempty) then empty else "\($s): missing id" end),
        (if (.title | nonempty) and (.title | test("^\\S.*\\scan\\s+\\S")) then empty
         else "\($s): title must read '\''<Actor> can <...>'\'' (got: \(.title // "none"))" end),
        (if (.so_that | nonempty) then empty else "\($s): missing so_that" end),
        (if (.acceptance_criteria | type) == "array" and (.acceptance_criteria | length) > 0
            and all(.acceptance_criteria[]; nonempty) then empty
         else "\($s): needs >= 1 non-empty acceptance_criteria entry" end),
        (if (.verify | nonempty) then empty else "\($s): missing verify step" end),
        (if (.depends_on | type) != "array" then "\($s): depends_on must be an array"
         else .depends_on[] | select(IN($ids[], $external[]) | not)
           | "\($s): depends_on '\''\(.)'\'' unresolved (not in draft, task-tree.json or stories.md)" end),
        (if has("gates") | not then empty
         elif (.gates | type) != "object" then "\($s): gates must be an object"
         else .gates | to_entries[]
           | select(.value != null and ((.value | type) != "string"
                    or ((.value | test("^skip: *\\S")) or IN(.value; verdicts[]) | not)))
           | "\($s): gate '\''\(.key)'\'' is \(.value | tojson) — must be a verdict or \"skip: <reason>\"" end)),
      ($ids | group_by(.)[] | select(length > 1) | "plan: duplicate id \(.[0])"),
      (map(select(.id | nonempty) | {key: .id, value: ((if (.depends_on | type) == "array" then .depends_on else [] end)
                                                     | map(select(IN($ids[]))))})
       | from_entries | stuck | select(length > 0) | "plan: depends_on cycle among: \(join(", "))")
  end' "$plan" 2>&1) || { echo "check-plan: FAIL — $plan could not be checked: $errors" | head -3 >&2; exit 1; }

if [ -z "$errors" ]; then
  echo "check-plan: OK — $plan ($(jq length "$plan") slices)"
  exit 0
fi
n=$(wc -l <<<"$errors" | tr -d ' ')
echo "check-plan: FAIL — $n problem(s) in $plan" >&2
head -18 <<<"$errors" >&2
[ "$n" -gt 18 ] && echo "... $((n - 18)) more" >&2
exit 1
