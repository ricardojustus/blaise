#!/bin/bash
# c15 leak tripwire — blocks confidential personal/company data from a commit or
# the tree. Replaces the publish-time scrub with a commit-time + CI gate.
#
#   scripts/tripwire.sh --staged   scan files staged for commit (pre-commit hook)
#   scripts/tripwire.sh --tree     scan all tracked files (CI on push / seed)
#
# Exit 0 = clean, 1 = a hit was found, 2 = usage error.
#
# Coverage: the structural rules (private-path, dangling-reference, generic
# patterns) ship in this script and carry no real value. The specific real
# identifiers (emails, IPs, ids, codenames, names) load at runtime from two
# GITIGNORED files the maintainer keeps locally — tripwire-secrets.txt (literal
# patterns) and tripwire-names.txt (low-ambiguity name list) — so the shipped
# script never embeds the very values it guards. Absent those files (a fresh
# public clone / CI), the structural rules still apply; the maintainer's local
# hook (which has the files) is the full net.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
MODE="${1:---staged}"
case "$MODE" in --staged|--tree) ;; *) echo "usage: tripwire.sh --staged|--tree" >&2; exit 2 ;; esac
# bash 3.2 (macOS system bash) has no `mapfile`, so read into the array manually.
FILES=()
while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(
  if [ "$MODE" = "--staged" ]; then
    git diff --cached --name-only --diff-filter=ACM
  else
    git ls-files
  fi
)
[ "${#FILES[@]}" -eq 0 ] && { echo "tripwire: nothing to scan"; exit 0; }

fail=0
hit() { echo "  ✗ [$1] $2" >&2; fail=1; }

# --- Path rule (M3): no file under a private working-files dir, even via add -f.
for f in "${FILES[@]}"; do
  case "$f" in
    context/*|audits/*|research/*|notes/*|design/*|private/*|.claude/*)
      hit "private-path" "$f — private surface, never in the clean repo" ;;
  esac
done

# --- Allowlisted paths for the broad CONTENT patterns (documented survivors).
allow_path() {
  case "$1" in
    fixtures/stoplist_*.txt|fixtures/br_common_names.txt|fixtures/icsi_sample/*) return 0 ;;
    app/Sources/BlaiseCore/Resources/stoplist_*.txt) return 0 ;;
    .gitignore|publish/gitignore) return 0 ;;
    scripts/blaise.env|scripts/tripwire-names.txt|scripts/tripwire-secrets.txt|scripts/tripwire.sh) return 0 ;;
    *) return 1 ;;
  esac
}
# Sanctioned ric_action_items compat sites (frozen wire constant, Option A).
allow_ric() {
  case "$1" in
    app/Sources/BlaiseCore/EvidencePayloadBuilder.swift) return 0 ;;
    app/Sources/BlaiseCore/NotesSynthesis.swift|app/Sources/BlaiseCore/Engines.swift) return 0 ;;
    app/Sources/BlaiseCore/HandoffWorker.swift) return 0 ;;
    docs/evidence_inbox_contract.md|specs/g2_name_substitution.md) return 0 ;;
    app/Tests/BlaiseCoreTests/CanonicalJSONTests.swift) return 0 ;;
    app/Tests/BlaiseCoreTests/HandoffWorkerTests.swift) return 0 ;;
    app/Tests/BlaiseCoreTests/ClaudeEngineTests.swift) return 0 ;;
    app/Tests/BlaiseCoreTests/NotesSynthesisTests.swift) return 0 ;;
    *) return 1 ;;
  esac
}

# scannable = existing text files, minus the path-allowlist
SCAN=(); for f in "${FILES[@]}"; do allow_path "$f" && continue; [ -f "$f" ] && SCAN+=("$f"); done

scan() { # desc ; ERE ; optional per-file allow fn
  local desc="$1" re="$2" af="${3:-}"
  [ "${#SCAN[@]}" -eq 0 ] && return
  while IFS=: read -r file line _; do
    [ -z "$file" ] && continue
    [ -n "$af" ] && "$af" "$file" && continue
    hit "$desc" "$file:$line"
  done < <(grep -HInE "$re" "${SCAN[@]}" 2>/dev/null)
}

# Structural patterns that carry NO real value (safe in the shipped script).
scan "tailscale-host" '[A-Za-z0-9-]+\.ts\.net'
scan "ric_action"     'ric_action|ricActionItems' allow_ric

# Dangling private-path references — a public file must not cite an internal
# audit/research/notes path, a private state-ledger file, an internal Appendix,
# or the policy file. allow_path already
# drops the tripwire + the .gitignore-class files that legitimately name these.
scan "dangling-audits"   'audits/[A-Za-z0-9]'
scan "dangling-research" 'research/[A-Za-z0-9]'
scan "dangling-notes"    'notes/[A-Za-z0-9_-]+\.md'
scan "dangling-state"    '\b(DECISIONS|QUESTIONS|BACKLOG|JOURNAL|PLAN|RESEARCH|FINAL_REPORT|DEFINITION_OF_DONE|OVERNIGHT_RUN|VISION_BLAISE|PROMPT_KICKOFF_BLAISE)\.md\b'
scan "dangling-appendix" 'Vision Appendix|\bAppendix [A-Z]\b'
scan "dangling-claudemd" '\bCLAUDE\.md\b'

# Real maintainer secrets (emails, IPs, codenames, ids, prod bundle id, the
# company name) load from a GITIGNORED file so the shipped script carries no
# real value. Absent the file (a fresh public clone / CI), these specific scans
# are simply inert — the structural rules above + the private-path rule still
# apply, and the maintainer's local hook (which HAS the file) is the full net.
SECRETS="$ROOT/scripts/tripwire-secrets.txt"
if [ -f "$SECRETS" ]; then
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    case "$pat" in \#*) continue ;; esac
    scan "secret" "$pat"
  done < "$SECRETS"
fi

# Maintainer name alternation (gitignored; low-ambiguity codenames + glossary).
NAMES="$ROOT/scripts/tripwire-names.txt"
if [ -f "$NAMES" ]; then
  while IFS= read -r term; do
    [ -z "$term" ] && continue
    case "$term" in \#*) continue ;; esac
    scan "name:$term" "\\b${term}\\b"
  done < "$NAMES"
fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Commit BLOCKED by the leak tripwire ($MODE)." >&2
  echo "If a hit is a documented survivor, add its path to the allowlist in scripts/tripwire.sh." >&2
  exit 1
fi
echo "tripwire: clean (${#SCAN[@]} files scanned, $MODE)"
exit 0
