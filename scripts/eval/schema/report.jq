# Executable report contract for zc eval framework (schema_version 1).
# Usage: jq -e -f scripts/eval/schema/report.jq < report.json
# Exits nonzero (via jq -e) when the document is invalid.

def fail($msg):
  error("eval report contract: \($msg)");

def is_nonempty_string:
  (type == "string") and (length > 0);

def is_string_array:
  (type == "array") and all(.[]; type == "string");

def is_object_array:
  (type == "array") and all(.[]; type == "object");

def is_run_id:
  is_nonempty_string
  and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$");

def is_suite_name:
  . == "correctness"
  or . == "contract"
  or . == "interop"
  or . == "perf"
  or . == "reliability";

def is_result:
  . == "pass" or . == "fail" or . == "error";

def is_iso_timestamp:
  is_nonempty_string
  and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");

def require_keys($keys):
  . as $obj
  | ($keys - ($obj | keys_unsorted)) as $missing
  | if ($missing | length) > 0 then
      fail("missing required field(s): \($missing | join(", "))")
    else
      $obj
    end;

def validate_env:
  require_keys(["os", "arch", "zig_version"])
  | if (.os | is_nonempty_string | not) then fail("env.os must be a non-empty string")
    elif (.arch | is_nonempty_string | not) then fail("env.arch must be a non-empty string")
    elif (.zig_version | is_nonempty_string | not) then fail("env.zig_version must be a non-empty string")
    else . end;

def validate_provenance:
  if (.run_id | is_run_id | not) then fail("run_id must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}")
  elif (.timestamp | is_iso_timestamp | not) then fail("timestamp must be UTC ISO-8601 ending with Z")
  elif (.subject_commit | is_nonempty_string | not) then fail("subject_commit must be a non-empty string")
  elif (.harness_commit | is_nonempty_string | not) then fail("harness_commit must be a non-empty string")
  elif ((.worktree_dirty | type) != "boolean") then fail("worktree_dirty must be a boolean")
  elif ((.env | type) != "object") then fail("env must be an object")
  else (.env |= validate_env) end;

def validate_step:
  require_keys(["name", "result"])
  | if (.name | is_nonempty_string | not) then fail("steps[].name must be a non-empty string")
    elif (.result | is_result | not) then fail("steps[].result must be pass|fail|error")
    else . end;

def validate_suite_entry:
  require_keys(["suite", "result", "report"])
  | if (.suite | is_suite_name | not) then fail("suites[].suite must be a known suite name")
    elif (.result | is_result | not) then fail("suites[].result must be pass|fail|error")
    elif (.report | is_nonempty_string | not) then fail("suites[].report must be a non-empty string")
    else . end;

def validate_suite:
  require_keys([
    "schema_version",
    "kind",
    "run_id",
    "timestamp",
    "suite",
    "scenarios",
    "subject_commit",
    "harness_commit",
    "worktree_dirty",
    "env",
    "result",
    "metrics",
    "omitted",
    "failed",
    "artifacts",
    "notes"
  ])
  | if .schema_version != 1 then fail("schema_version must be 1")
    elif .kind != "suite" then fail("kind must be \"suite\"")
    elif (.suite | is_suite_name | not) then fail("suite must be correctness|contract|interop|perf|reliability")
    elif (.result | is_result | not) then fail("result must be pass|fail|error")
    elif ((.scenarios | is_string_array) | not) then fail("scenarios must be an array of strings")
    elif ((.metrics | type) != "object") then fail("metrics must be an object")
    elif ((.omitted | is_string_array) | not) then fail("omitted must be an array of strings")
    elif ((.failed | is_string_array) | not) then fail("failed must be an array of strings")
    elif ((.artifacts | is_string_array) | not) then fail("artifacts must be an array of strings")
    elif ((.notes | is_string_array) | not) then fail("notes must be an array of strings")
    elif (has("steps") and ((.steps | is_object_array) | not)) then fail("steps must be an array of objects when present")
    else
      validate_provenance
      | if has("steps") then .steps |= map(validate_step) else . end
    end;

def validate_summary:
  require_keys([
    "schema_version",
    "kind",
    "run_id",
    "timestamp",
    "subject_commit",
    "harness_commit",
    "worktree_dirty",
    "env",
    "requested_suites",
    "suites",
    "result",
    "failed",
    "notes"
  ])
  | if .schema_version != 1 then fail("schema_version must be 1")
    elif .kind != "summary" then fail("kind must be \"summary\"")
    elif (.result | is_result | not) then fail("result must be pass|fail|error")
    elif ((.requested_suites | type) != "array") then fail("requested_suites must be an array")
    elif ((.requested_suites | all(is_suite_name)) | not) then fail("requested_suites entries must be known suite names")
    elif ((.suites | is_object_array) | not) then fail("suites must be an array of objects")
    elif ((.failed | is_string_array) | not) then fail("failed must be an array of strings")
    elif ((.notes | is_string_array) | not) then fail("notes must be an array of strings")
    else
      validate_provenance
      | .suites |= map(validate_suite_entry)
    end;

if type != "object" then
  fail("report must be a JSON object")
elif (has("kind") | not) then
  fail("missing required field(s): kind")
elif .kind == "suite" then
  validate_suite
elif .kind == "summary" then
  validate_summary
else
  fail("kind must be \"suite\" or \"summary\"")
end
| true
