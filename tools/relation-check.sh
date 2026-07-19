#!/usr/bin/env bash
set -euo pipefail

# relation-check.sh — Pre-flight code relation analyzer for Poste
#
# Usage:
#   tools/relation-check.sh                  # run all checks
#   tools/relation-check.sh set-lines        # nvim_buf_set_lines + sanitize
#   tools/relation-check.sh state <field>    # state field lifecycle
#   tools/relation-check.sh format           # format function callers
#   tools/relation-check.sh pre-render       # pre-render consistency
#   tools/relation-check.sh all              # same as no-args
#
# Run this BEFORE making changes to catch incomplete modifications.

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; GRAY='\033[90m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Fields that are intentionally persistent — always-current values, config, or caches.
# These trigger ⚠ "NEVER cleared" but that's by design, not a bug.
# Request-scoped fields must be cleared by session.begin(); persistent fields are exempt.
EXEMPT_FIELDS="current_view|current_env|config|http_history|http_history_id_counter|http_history_max|last_request|_lsp_doc_buf|log|find_poste_binary|format_keymap|format_key_string|get_keymap|apply_highlight_overrides|dirty|global_vars|script_variables|_http_session|_sql_session|_deprecated_write_log|deprecated_write"

check_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "require $1"; exit 1; }; }
check_cmd rg

cd "$PROJECT_ROOT"

###############################################################################
# nvim_buf_set_lines + sanitize_lines coverage
###############################################################################
check_set_lines() {
  echo -e "${BOLD}${CYAN}═══ nvim_buf_set_lines + sanitize_lines coverage${NC}"
  local http_dir="lua/poste/http/"
  [ ! -d "$http_dir" ] && echo -e "${YELLOW}  [SKIP] $http_dir not found${NC}" && return

  while IFS= read -r line; do
    local file="${line%%:*}"
    local lineno="${line#*:}"; lineno="${lineno%%:*}"
    local near="" near_status=""
    if near=$(rg -n -B5 -A2 "nvim_buf_set_lines" "$file" | rg -m1 "sanitize_lines" 2>/dev/null); then
      near_status="${GREEN}✓ sanitize_lines nearby${NC}"
    else
      near_status="${RED}✗ NO sanitize_lines nearby${NC}"
    fi
    echo -e "  ${GRAY}$file:$lineno${NC} $near_status"
  done < <(rg -n "nvim_buf_set_lines" "$http_dir" --type lua | rg -v ":\s*--")

  # also check highlight functions that compute end_col from line length
  echo
  echo -e "${BOLD}${DIM}  --- highlight functions using #line as end_col (risk: OOB if lines differ)${NC}"
  while IFS= read -r line; do
    echo -e "  ${GRAY}$line${NC}"
  done < <(rg -n "end_col.*#line\|#lines\|#lines\[" "$http_dir" --type lua || echo "  (none)")
}

###############################################################################
# state field lifecycle
###############################################################################
check_state() {
  local field="${1:-}"
  local pattern="state\.${field}"

  if [ -z "$field" ]; then
    echo -e "${BOLD}${CYAN}═══ state field lifecycle (all fields)${NC}"
    local fields
    fields=$(rg -o "state\.\w+" "lua/poste/" --type lua -g '!tests/' | sed 's/.*state\.//' | sort -u | head -30)
    for f in $fields; do
      local exempt=0
      echo "$f" | rg -q "^($EXEMPT_FIELDS)$" && exempt=1
      echo -e "${BOLD}  $f${NC}$([ "$exempt" -eq 1 ] && echo " ${DIM}(exempt — intentional persistence)${NC}")"
      local file
      for file in $(rg -l "state\.$f\b" "lua/poste/" --type lua -g '!tests/'); do
        local set_count=0 read_count=0 clear_count=0
        set_count=$(rg -c "state\.${f}\b(\.\w+)?\s*=" "$file" 2>/dev/null || echo 0)
        clear_count=$(rg -c "state\.${f}\b(\.\w+)?\s*=\s*nil" "$file" 2>/dev/null || echo 0)
        read_count=$(rg -c "state\.${f}\b" "$file" 2>/dev/null || echo 0)
        read_count=$((read_count - set_count))
        echo -e "    ${GRAY}$file${NC}  SET=${CYAN}$set_count${NC} READ=${YELLOW}$read_count${NC} CLEAR=${RED}$clear_count${NC}"
        if [ "$exempt" -eq 0 ] && [ "$set_count" -gt 0 ] && [ "$clear_count" -eq 0 ]; then
          echo -e "    ${RED}    ⚠  WRITTEN but NEVER cleared!${NC}"
        fi
      done
    done
    return
  fi

  local exempt=0
  echo "$field" | rg -q "^($EXEMPT_FIELDS)$" && exempt=1
  echo -e "${BOLD}${CYAN}═══ state.$field lifecycle${NC}$([ "$exempt" -eq 1 ] && echo " ${DIM}(exempt — intentional persistence)${NC}")"
  local state_pattern="state\.${field}\b"
  local assign_pattern="state\.${field}\b(\.\w+)?\s*="
  local clear_pattern="state\.${field}\b(\.\w+)?\s*=\s*nil"
  local set_total=0 clear_total=0

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    # SET: assignment (including sub-fields)
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo -e "  SET  ${GRAY}$line${NC}"; ((set_total++))
    done < <(rg -n "$assign_pattern" "$file" 2>/dev/null || true)
    # CLEAR: ... = nil (including sub-fields)
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo -e "  ${RED}CLEAR${NC} ${GRAY}$line${NC}"; ((clear_total++))
    done < <(rg -n "$clear_pattern" "$file" 2>/dev/null || true)
    # READ: any non-assignment usage
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      # skip assignment lines (already counted above)
      if echo "$line" | rg -q "=\s*nil"; then continue; fi
      if echo "$line" | rg -q "=\s*\$"; then continue; fi
      if echo "$line" | rg -q "$assign_pattern"; then continue; fi
      echo -e "  READ ${GRAY}$line${NC}"
    done < <(rg -n "$state_pattern" "$file" 2>/dev/null || true)
  done < <(rg -l "$state_pattern" "lua/poste/" --type lua -g '!tests/')

  echo
  if [ "$exempt" -eq 1 ]; then
    echo -e "  ${DIM}  Skipped — field is exempt (intentional persistence)${NC}"
  elif [ "$set_total" -gt "$clear_total" ]; then
    echo -e "  ${RED}⚠  SET ($set_total) > CLEAR ($clear_total) — possible stale state${NC}"
  elif [ "$set_total" -eq 0 ]; then
    echo -e "  ${YELLOW}  No SETs found (state.$field may be computed or unused)${NC}"
  else
    echo -e "  ${GREEN}✓ SET ($set_total) ≤ CLEAR ($clear_total)${NC}"
  fi
}

###############################################################################
# format function callers
###############################################################################
check_format() {
  echo -e "${BOLD}${CYAN}═══ format function definitions + callers${NC}"
  local http_dir="lua/poste/http/"
  [ ! -d "$http_dir" ] && echo -e "${YELLOW}  [SKIP] $http_dir not found${NC}" && return

  # define all format functions
  echo -e "${BOLD}${DIM}  --- definitions in format.lua${NC}"
  local funcs=()
  while IFS= read -r line; do
    local func_name
    func_name=$(echo "$line" | rg -o "function\s+M\.(\w+)" | sed 's/function M\.//')
    [ -n "$func_name" ] && funcs+=("$func_name")
    echo -e "  ${GRAY}$line${NC}"
  done < <(rg -n "^function M\.(format_|sanitize_)" "$http_dir/format.lua" 2>/dev/null || true)

  echo
  echo -e "${BOLD}${DIM}  --- callers across http/ lua${NC}"
  for fn in "${funcs[@]}"; do
    local count=0 files_with=()
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local c="${line##*:}"
      count=$((count + c))
      files_with+=("$line")
    done < <(rg -c "format\.$fn\b" "$http_dir" --type lua 2>/dev/null || true)
    [ "$count" -eq 0 ] && continue
    local file_list=""
    for f in "${files_with[@]}"; do file_list="$file_list ${f%%:*}"; done
    echo -e "${BOLD}  format.$fn${NC} (called $count times across: $file_list)"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo -e "    ${GRAY}$line${NC}"
    done < <(rg -n "format\.$fn\b" "$http_dir" --type lua 2>/dev/null | head -10)
  done

  # check sibling paths: view.lua calls format functions
  echo
  echo -e "${BOLD}${DIM}  --- render paths in view.lua${NC}"
  while IFS= read -r line; do
    echo -e "  ${GRAY}$line${NC}"
  done < <(rg -n "function M\.(show_view|render_view|render_detail|show_verbose)" "$http_dir/view.lua" 2>/dev/null || echo "  (none)")

  # check history module also calls format
  if [ -f "$http_dir/history.lua" ]; then
    echo
    echo -e "${BOLD}${DIM}  --- format calls from history.lua${NC}"
    while IFS= read -r line; do
      echo -e "  ${GRAY}$line${NC}"
    done < <(rg -n "format\.(format_|sanitize_)" "$http_dir/history.lua" 2>/dev/null || echo "  (none)")
  fi
}

###############################################################################
# pre-render path consistency
###############################################################################
check_prerender() {
  echo -e "${BOLD}${CYAN}═══ pre-render/cached buffer consistency${NC}"
  local http_dir="lua/poste/http/"
  [ ! -d "$http_dir" ] && echo -e "${YELLOW}  [SKIP] $http_dir not found${NC}" && return

  echo -e "${BOLD}${DIM}  --- pre-render functions${NC}"
  while IFS= read -r line; do
    echo -e "  ${GRAY}$line${NC}"
  done < <(rg -n "prepare_multi_responses\b|M\.render_" "$http_dir" --type lua -g '!tests/' 2>/dev/null | head -20 || echo "  (none)")

  echo
  echo -e "${BOLD}${DIM}  --- apply_highlights / apply_extmarks calls${NC}"
  while IFS= read -r line; do
    echo -e "  ${GRAY}$line${NC}"
  done < <(rg -n "apply_verbose_highlights|apply_request_highlights|apply_file_link_highlight|setup_json_buffer|nvim_buf_set_extmark" "$http_dir" --type lua -g '!tests/' 2>/dev/null || echo "  (none)")
}

###############################################################################
# session lifecycle (Phase 2b)
###############################################################################
check_session() {
  echo -e "${BOLD}${CYAN}═══ session lifecycle (run_* must begin a session)${NC}"

  local ok=1
  if rg -q 'session\.begin|poste\.http\.session' "lua/poste/http/run.lua" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} http/run.lua creates HTTP session"
  else
    echo -e "  ${RED}✗${NC} http/run.lua missing session.begin"
    ok=0
  fi

  if rg -q 'sql\.session|poste\.sql\.session' "lua/poste/sql/init.lua" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} sql/init.lua creates SQL session"
  else
    echo -e "  ${RED}✗${NC} sql/init.lua missing session.begin"
    ok=0
  fi

  # Request-scoped fields that session.begin must clear
  local required_clears="last_response last_responses response_index last_assertion_results last_script_logs pending_request"
  for f in $required_clears; do
    if rg -q "state\.${f}\s*=\s*nil" "lua/poste/http/session.lua" 2>/dev/null; then
      echo -e "  ${GREEN}✓${NC} session clears state.$f"
    else
      echo -e "  ${RED}✗${NC} session does not clear state.$f"
      ok=0
    fi
  done

  # run.lua must not re-parse method/headers from buffer lines
  if rg -n "text:match\(\"\^\\(%S\\+\\)%s\\+\"\|request_found\s*=\s*true" "lua/poste/http/run.lua" 2>/dev/null | rg -q .; then
    echo -e "  ${YELLOW}⚠${NC} run.lua still has Lua request-line re-parse patterns"
  else
    echo -e "  ${GREEN}✓${NC} run.lua has no Lua request-block re-parse loop"
  fi

  # describe module must exist
  if [ -f "lua/poste/http/describe.lua" ]; then
    echo -e "  ${GREEN}✓${NC} http/describe.lua present (single parse authority)"
  else
    echo -e "  ${RED}✗${NC} http/describe.lua missing"
    ok=0
  fi

  if [ "$ok" -eq 0 ]; then
    echo -e "  ${RED}session lifecycle check FAILED${NC}"
    return 1
  fi
  echo -e "  ${GREEN}session lifecycle check OK${NC}"
}

###############################################################################
# main
###############################################################################
main() {
  local mode="${1:-all}"
  shift 2>/dev/null || true

  case "$mode" in
    set-lines|set_lines)
      check_set_lines
      ;;
    state)
      check_state "${1:-}"
      ;;
    format)
      check_format
      ;;
    pre-render|prerender)
      check_prerender
      ;;
    session)
      check_session
      ;;
    all|"")
      echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────────────┐${NC}"
      echo -e "${BOLD}${CYAN}│  Poste Code Relation Check                         │${NC}"
      echo -e "${BOLD}${CYAN}│  Run before editing to catch incomplete mods       │${NC}"
      echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────┘${NC}"
      echo
      check_set_lines
      echo
      check_state
      echo
      check_format
      echo
      check_prerender
      echo
      check_session
      ;;
    *)
      echo "usage: $0 [set-lines|state [field]|format|pre-render|session|all]"
      exit 1
      ;;
  esac
}

main "$@"
