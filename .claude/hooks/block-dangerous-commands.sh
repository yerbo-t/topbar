#!/usr/bin/env bash
# Blocks dangerous shell commands: push to protected branches, force push,
# destructive operations. PreToolUse hook for Bash operations.
# Exit 2 = block. Exit 0 = allow.
#
# Configurable via env:
#   CLAUDE_PROTECTED_BRANCHES  comma list (default: derived from git + main,master)

set -uo pipefail

emit_deny() {
  # Emit a JSON deny decision and exit 2.
  local reason="${1//\"/\\\"}"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 2
}

# Действия наружу не блокируются, а требуют подтверждения владельца. Причину копим и выдаём в самом конце,
# чтобы проверки на запрет ниже успели сработать для той же составной команды.
ASK_REASON=""

if ! command -v jq >/dev/null 2>&1; then
  emit_deny "jq is required for command protection hooks but is not installed."
fi

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$COMMAND" ] && exit 0

# ── Protected branch list ────────────────────────────────────────────────
DEFAULT_BRANCHES="main,master"
if GIT_DEFAULT=$(git config --get init.defaultBranch 2>/dev/null) && [ -n "$GIT_DEFAULT" ]; then
  DEFAULT_BRANCHES="$DEFAULT_BRANCHES,$GIT_DEFAULT"
fi
PROTECTED_BRANCHES="${CLAUDE_PROTECTED_BRANCHES:-$DEFAULT_BRANCHES}"
# Build a regex alternation: main|master|develop|...
BR_REGEX=$(printf '%s' "$PROTECTED_BRANCHES" | tr ',' '\n' | awk 'NF{printf "%s%s",sep,$0; sep="|"}')

contains_cmd() { printf '%s' "$COMMAND" | grep -qE "$1"; }
contains_icmd() { printf '%s' "$COMMAND" | grep -qiE "$1"; }

# ── Git push protections ────────────────────────────────────────────────
if contains_cmd '(^|[;&|()]+[[:space:]]*)git[[:space:]]+push'; then
  # Explicit refspec to a protected branch (origin main, :main, HEAD:main, remote branch)
  if contains_cmd "git[[:space:]]+push[[:space:]]+[^[:space:]]+[[:space:]]+([^[:space:]]*:)?($BR_REGEX)(\$|[[:space:]])"; then
    MATCHED_BRANCH=$(printf '%s' "$COMMAND" | grep -oE "($BR_REGEX)(\$|[[:space:]])" | head -1 | tr -d '[:space:]')
    emit_deny "Blocked: push to protected branch '${MATCHED_BRANCH:-main}'. Use a feature branch and open a PR."
  fi
  if contains_cmd "git[[:space:]]+push.*:($BR_REGEX)(\$|[[:space:]])"; then
    MATCHED_BRANCH=$(printf '%s' "$COMMAND" | grep -oE ":($BR_REGEX)(\$|[[:space:]])" | head -1 | tr -d ': [:space:]')
    emit_deny "Blocked: push to protected branch '${MATCHED_BRANCH:-main}' via refspec. Use a feature branch and open a PR."
  fi
  # Bare `git push` while on protected branch
  if contains_cmd 'git[[:space:]]+push[[:space:]]*($|[;&|])'; then
    CURRENT=$(git branch --show-current 2>/dev/null || true)
    if [ -n "$CURRENT" ] && printf '%s' ",$PROTECTED_BRANCHES," | grep -q ",$CURRENT,"; then
      emit_deny "Blocked: you are on '$CURRENT' (a protected branch). Switch to a feature branch."
    fi
  fi
  ASK_REASON="git push — только по решению владельца."
  # Force push (but allow --force-with-lease)
  if contains_cmd 'git[[:space:]]+push([[:space:]]+[^[:space:]]+)*[[:space:]]+(-[a-zA-Z]*f[a-zA-Z]*|--force)([[:space:]=]|$)' \
     && ! contains_cmd '\-\-force-with-lease'; then
    emit_deny "Blocked: force push is not allowed. Use --force-with-lease if you must overwrite remote."
  fi
fi

# ── Destructive filesystem operations ───────────────────────────────────
# rm -rf targeting root, home, $HOME, $VAR (any unresolved expansion), or parent traversal.
# We normalise quotes before matching so "my folder", '$HOME/trash', etc. Are all inspected.
CMD_NOQUOTE=$(printf '%s' "$COMMAND" | tr -d "'\"")
if printf '%s' "$CMD_NOQUOTE" | grep -qE 'rm[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*-?[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*[[:space:]]+(/([[:space:]]|\*|$)|~|\$HOME|\$[A-Za-z_][A-Za-z0-9_]*|\.\./\.\.)' ; then
  emit_deny "Blocked: recursive force-delete on /, ~, \$HOME, an unresolved \$VAR, or .../.. Path. Specify a concrete safe target."
fi
# rm -rf /usr, /etc, /var, /bin, etc.
if printf '%s' "$CMD_NOQUOTE" | grep -qE 'rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-?[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*[[:space:]]+/(usr|etc|var|bin|sbin|lib|opt|root|boot)([[:space:]/]|$)'; then
  emit_deny "Blocked: recursive delete targeting a system directory."
fi

# ── Dangerous database operations ───────────────────────────────────────
# Проверяется только то, что может выполнить SQL: части команды, начинающиеся с поиска (grep, rg…) или git
# (сообщение коммита, git log -S), выбрасываются — иначе `grep -n "DELETE FROM" server/src/store.ts` блокировался бы.
# Разделители (; & | перевод строки) сохраняются, чтобы ниже инструкции разбирались так же, как в исходной команде.
# Регистр снимается через tr: awk на macOS не знает IGNORECASE, и строчный `delete from` проходил бы мимо.
SQL_TEXT=$(printf '%s' "$COMMAND" | awk '
  BEGIN { RS = "\001" }
  {
    rest = $0; out = ""
    while (length(rest) > 0) {
      if (match(rest, /[;&|\n]/)) { seg = substr(rest, 1, RSTART - 1); sep = substr(rest, RSTART, 1); rest = substr(rest, RSTART + 1) }
      else { seg = rest; sep = ""; rest = "" }
      head = seg
      sub(/^[[:space:](]*/, "", head)
      while (head ~ /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/) sub(/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/, "", head)
      if (head ~ /^(grep|egrep|fgrep|rg|ag|ack|git)([[:space:]]|$)/) seg = ""
      out = out seg sep
    }
    printf "%s", out
  }
' | tr '[:upper:]' '[:lower:]')
# DROP TABLE|DATABASE|SCHEMA
if printf '%s' "$SQL_TEXT" | grep -qE 'drop[[:space:]]+(table|database|schema)[[:space:]]+'; then
  emit_deny "Blocked: DROP TABLE/DATABASE/SCHEMA detected. Run manually if intended."
fi
# DELETE FROM without a WHERE on the SAME statement.
# Split on ';' so multi-statement inputs are analysed per-statement.
if printf '%s\n' "$SQL_TEXT" | awk '
  BEGIN { RS=";" }
  /delete[[:space:]]+from[[:space:]]+[a-z_][a-z0-9_.]*/ {
    if ($0 !~ /where/) { print "BAD"; exit }
  }
' | grep -q BAD; then
  emit_deny "Blocked: DELETE FROM without a WHERE clause. Add a WHERE or run manually."
fi
if printf '%s' "$SQL_TEXT" | grep -qE 'truncate[[:space:]]+table'; then
  emit_deny "Blocked: TRUNCATE TABLE detected. Run manually if intended."
fi

# ── Dangerous system commands ───────────────────────────────────────────
# chmod: any world-writable/universal mode (0?777 or a+rwx)
if contains_cmd 'chmod([[:space:]]+-[a-zA-Z]+)*[[:space:]]+0?777([[:space:]]|$)' \
  || contains_cmd 'chmod([[:space:]]+-[a-zA-Z]+)*[[:space:]]+a\+rwx([[:space:]]|$)'; then
  emit_deny "Blocked: chmod 777 / a+rwx grants everyone full access. Use restrictive perms."
fi

# curl/wget piped to a shell
if contains_cmd '(curl|wget)[[:space:]].*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|ksh|fish|dash|csh)([[:space:]]|$)'; then
  emit_deny "Blocked: piping downloaded content directly to a shell is dangerous."
fi

# Disk / partition. Note: only REDIRECTIONS to /dev/ are destructive. `2>/dev/null` is not.
# Pattern matches: `>[ ]*/dev/<something>` but NOT `2>/dev/null` or `&>/dev/null` style for fd-null.
# Strategy: match `>` optionally with whitespace, followed by /dev/<name>, EXCLUDING /dev/null and /dev/stderr/stdout.
if printf '%s' "$COMMAND" | grep -qE '(^|[^0-9&])>[[:space:]]*/dev/[a-zA-Z][a-zA-Z0-9]*' \
   && ! printf '%s' "$COMMAND" | grep -qE '>[[:space:]]*/dev/(null|stdout|stderr|tty|zero|random|urandom)([[:space:]]|$)' ; then
  emit_deny "Blocked: redirection into a raw device file can destroy data."
fi
if contains_cmd '(^|[;&|[:space:]])(mkfs|mkfs\.[a-z0-9]+)([[:space:]]|$)' \
  || contains_cmd '(^|[;&|[:space:]])dd[[:space:]]+[^|]*(if|of)=/dev/[a-zA-Z]' ; then
  emit_deny "Blocked: mkfs/dd against a device node. Irreversible data loss."
fi

# ── Destructive git ─────────────────────────────────────────────────────
if contains_cmd 'git[[:space:]]+reset[[:space:]]+--hard'; then
  emit_deny "Blocked: git reset --hard discards uncommitted changes permanently."
fi
if contains_cmd 'git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f'; then
  emit_deny "Blocked: git clean -f permanently deletes untracked files."
fi

# ── Accidental package publishing ───────────────────────────────────────
# Allow --dry-run variants (npm publish --dry-run is safe and common in CI).
publish_patterns=(
  '(npm|yarn|pnpm|bun)[[:space:]]+publish'
  'cargo[[:space:]]+publish'
  'gem[[:space:]]+push'
  'twine[[:space:]]+upload'
)
for pat in "${publish_patterns[@]}"; do
  if contains_cmd "$pat" && ! contains_cmd '(^|[[:space:]])(--dry-run|-n)([[:space:]=]|$)'; then
    emit_deny "Blocked: publishing packages should run in CI or manually, not via Claude."
  fi
done

# ── topbar: выкладка наружу ─────────────────────────────────────────────
# Скрипт выкладки в любом виде вызова (scripts/publish.sh, ./publish.sh, bash scripts/publish.sh, с переменными впереди),
# но не его чтение (cat, grep) и не упоминание в тексте коммита.
SEG='(^|[;&|(][[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
if contains_cmd "${SEG}((ba|z)?sh[[:space:]]+)?([^[:space:];&|]*/)?publish\.sh([[:space:]]|\$)"; then
  ASK_REASON="Выкладка релиза наружу (publish.sh) — только по решению владельца."
fi
if contains_cmd "${SEG}gh[[:space:]]+release[[:space:]]+(create|upload|edit|delete)([[:space:]]|\$)"; then
  ASK_REASON="Изменение релиза на GitHub — только по решению владельца."
fi

if [ -n "$ASK_REASON" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "${ASK_REASON//\"/\\\"}"
  exit 0
fi

exit 0
