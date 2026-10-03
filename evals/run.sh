#!/usr/bin/env bash
# Раннер сценариев: подаёт реплики сценария в claude -p в копии vault вне репозитория
# и сохраняет сырой вывод, транскрипт, снимок vault после прогона и заготовку оценки.
# Использование: evals/run.sh <сценарий.md> [папка-результата]
# Переменные: KLUBOK_CLAUDE (по умолчанию claude), KLUBOK_VAULT (<репо>/vault),
# KLUBOK_FIXTURES (<репо>/evals/fixtures), KLUBOK_EVAL_MODEL (если задана — --model).
# Фикстура берётся из <фикстуры>/map.txt (строки «<имя сценария> <фикстура>»), иначе onboarded.
# Коды выхода: 0 — все ходы прошли, 1 — claude завершился с ошибкой, 2 — ошибка входных данных.
set -euo pipefail

# Флаги claude для каждого хода; -p, --model и --continue добавляются отдельно.
# Изоляция от личной настройки Claude Code (глобальный CLAUDE.md, плагины, хуки, автопамять, MCP):
# только настройки проекта, без MCP; из инструментов — только файлы vault и скиллы.
claude_flags=(--output-format stream-json --verbose
  --setting-sources project
  --settings '{"autoMemoryEnabled":false,"disableBundledSkills":true}'
  --strict-mcp-config
  --tools Read,Write,Edit,Glob,Grep,Skill
  --permission-mode acceptEdits)
# Переменные родительского Claude Code, если раннер запущен из него.
parent_env=(CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION
  CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN
  CLAUDE_CODE_EXECPATH CLAUDE_AGENT_SDK_VERSION CLAUDE_EFFORT CLAUDE_PID AI_AGENT)

root="$(cd "$(dirname "$0")/.." && pwd)"
claude="${KLUBOK_CLAUDE:-claude}"
vault="${KLUBOK_VAULT:-$root/vault}"
fixtures="${KLUBOK_FIXTURES:-$root/evals/fixtures}"
model="${KLUBOK_EVAL_MODEL:-}"

die() { echo "run: $*" >&2; exit 2; }

[[ $# -ge 1 ]] || die "использование: evals/run.sh <сценарий.md> [папка-результата]"
scenario="$1"
[[ -f "$scenario" ]] || die "нет файла сценария: $scenario"
name="$(basename "$scenario" .md)"

work="$(mktemp -d "${TMPDIR:-/tmp}/klubok-eval.XXXXXX")"
# claude хранит транскрипты прогона в <конфиг>/projects/<путь копии, где не буквы и цифры заменены на «-»>;
# --continue без них не работает, поэтому они удаляются только в конце.
sessions="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
cleanup() {
  rm -rf "$work"
  local d
  for d in "$sessions"/*-klubok-eval-"${work##*.}"-vault; do [[ -d "$d" ]] && rm -rf "$d"; done
  return 0
}
trap cleanup EXIT
case "$work/" in "$root"/*) die "временная папка внутри репозитория: $work (проверь TMPDIR)" ;; esac
mkdir "$work/in" "$work/vault"

# Ходы из раздела «## Ходы»: in/NN.txt — реплика, in/NN.new — пометка «(новый разговор)».
turns="$(awk -v dir="$work/in" '
  /^## / { h = $0; sub(/[[:space:]]+$/, "", h); sect = (h == "## Ходы"); next }
  !sect { next }
  infence { if ($0 ~ /^```[[:space:]]*$/) { infence = 0; close(f) } else print > f; next }
  /^### Ход [0-9]+/ {
    if (pending) bad = 1
    n++; id = sprintf("%02d", n); f = dir "/" id ".txt"; pending = 1
    if ($0 ~ /\(новый разговор\)[[:space:]]*$/) { m = dir "/" id ".new"; printf "" > m; close(m) }
    next
  }
  pending && /^```text[[:space:]]*$/ { infence = 1; pending = 0; printf "" > f; next }
  END { if (bad || pending || infence) exit 3; print n + 0 }
' "$scenario")" || die "в сценарии у хода нет блока text или блок не закрыт: $scenario"
(( turns > 0 )) || die "в сценарии нет ходов (### Ход N в разделе «## Ходы»): $scenario"

[[ -d "$vault" ]] || die "нет папки vault: $vault"
[[ -d "$fixtures" ]] || die "нет папки фикстур: $fixtures"
fixture="onboarded"
if [[ -f "$fixtures/map.txt" ]]; then
  mapped="$(awk -v s="$name" '$1 !~ /^#/ && $1 == s { print $2; exit }' "$fixtures/map.txt")"
  [[ -n "$mapped" ]] && fixture="$mapped"
fi
[[ -d "$fixtures/$fixture" ]] || die "нет фикстуры «${fixture}»: $fixtures/$fixture"
command -v "$claude" >/dev/null || die "не найден claude: $claude"
command -v jq >/dev/null || die "не найден jq: он нужен для проверки ходов"

out="${2:-$root/evals/tmp/$name/$(date +%Y%m%d-%H%M%S)}"
if [[ -d "$out" && -n "$(ls -A "$out")" ]]; then die "папка результата не пуста: $out"; fi
mkdir -p "$out/turns" "$out/vault-after"

cp -R "$vault/." "$work/vault/"
cp -R "$fixtures/$fixture/." "$work/vault/"

commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null)" || commit="нет"
if [[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then commit="$commit (есть незакоммиченные изменения)"; fi
version="$("$claude" --version 2>&1 | head -n 1)" || version="не удалось получить"
{
  echo "сценарий: $scenario"
  echo "фикстура: $fixture"
  echo "начало: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "коммит: $commit"
  echo "claude: $version"
  echo "модель: ${model:-по умолчанию}"
  echo "флаги: -p ${claude_flags[*]}${model:+ --model $model} (+ --continue со второго хода, кроме новых разговоров)"
  echo "ходов: $turns"
} > "$out/meta.txt"

# Прогон ходов: при ошибке claude следующие ходы не запускаются.
failed=0; failmsg=""
for (( i = 1; i <= turns; i++ )); do
  id="$(printf '%02d' "$i")"
  args=(-p "${claude_flags[@]}")
  if [[ -n "$model" ]]; then args+=(--model "$model"); fi
  if (( i > 1 )) && [[ ! -f "$work/in/$id.new" ]]; then args+=(--continue); fi
  echo "run: ход $i из $turns" >&2
  code=0
  (cd "$work/vault" && for v in "${parent_env[@]}"; do unset "$v"; done && exec "$claude" "${args[@]}") \
    < "$work/in/$id.txt" > "$out/turns/$id.jsonl" 2> "$out/turns/$id.stderr" || code=$?
  [[ -s "$out/turns/$id.stderr" ]] || rm -f "$out/turns/$id.stderr"
  if [[ " ${args[*]} " == *" --continue "* ]]; then cont=", --continue"; else cont=""; fi
  echo "ход $i: код $code$cont" >> "$out/meta.txt"
  if (( code != 0 )); then
    failmsg="claude завершился, код $code, см. turns/$id.stderr."
  else
    # Код 0 бывает и при ошибке API, поэтому смотрим ещё на init и result.
    failmsg="$(jq -R -r 'fromjson? | objects |
      if .type == "system" and .subtype == "init"
         and ((.plugins // []) + (.mcp_servers // []) | length) > 0
      then "изоляция нарушена: в init есть плагины или MCP-серверы, прогон не засчитывается."
      elif .type == "result" and .is_error == true
      then "claude вернул ошибку: \(.result // .terminal_reason // "?")"
      else empty end' "$out/turns/$id.jsonl" | head -n 1)"
  fi
  if [[ -n "$failmsg" ]]; then
    failed=$i
    echo "ход $i: $failmsg" >> "$out/meta.txt"
    break
  fi
done

cp -R "$work/vault/." "$out/vault-after/"

# Читаемый вывод одного хода из stream-json; неизвестные и битые строки пропускаются.
render() {
  jq -R -r '
    def cut($n): if length > $n then .[0:$n] + "…" else . end;
    fromjson? | objects |
    if .type == "assistant" then
      (.message.content // [])[] | objects |
      if .type == "text" then (.text // "") + "\n"
      elif .type == "tool_use" then "- вызов `\(.name)`: \(.input | tojson | cut(400))\n"
      else empty end
    elif .type == "user" then
      (.message.content // [] | if type == "array" then .[] else empty end) | objects |
      select(.type == "tool_result") |
      (.content | if type == "array" then map(.text? // "") | join(" ")
                  elif type == "string" then . else tojson end) as $c |
      "- \(if .is_error == true then "ошибка" else "результат" end): \($c | gsub("\\s+"; " ") | cut(300))\n"
    elif .type == "system" and .subtype == "init" then
      "_модель: \(.model // "?"), session_id: \(.session_id // "?"); инструменты: \(.tools // [] | join(", ")); скиллы: \(.skills // [] | join(", "))_\n"
    elif .type == "result" then
      ((.permission_denials // [])[] | objects |
        "- отказ в доступе: \(.tool_name // "?") \(.tool_input.file_path // (.tool_input | tojson | cut(200)))\n"),
      (if .is_error == true then "- ошибка: \(.result // .terminal_reason // "?")\n" else empty end),
      "_итог хода: \(.subtype // "?"), шагов \(.num_turns // "?"), $\(.total_cost_usd // "?"), \(.duration_ms // "?") мс_\n"
    else empty end
  ' "$1" || echo "_не удалось разобрать turns/$(basename "$1")_"
}

title="$(grep -m 1 '^# ' "$scenario" | sed 's/^# //')" || title="$name"
{
  echo "# Транскрипт: $title"
  for (( i = 1; i <= turns; i++ )); do
    id="$(printf '%02d' "$i")"
    [[ -f "$out/turns/$id.jsonl" ]] || break
    echo
    if [[ -f "$work/in/$id.new" ]]; then echo "## Ход $i (новый разговор)"; else echo "## Ход $i"; fi
    echo
    echo "**Пользователь:**"
    echo
    echo '```text'
    cat "$work/in/$id.txt"
    echo '```'
    echo
    echo "**Помощник:**"
    echo
    render "$out/turns/$id.jsonl"
    if (( i == failed )); then
      echo
      echo "**Ошибка:** $failmsg"
    fi
  done
  if (( failed > 0 && failed < turns )); then
    echo
    echo "Ходы $(( failed + 1 ))–$turns не запускались."
  fi
} > "$out/transcript.md"

# Заготовка ручной оценки: пункты Must и Must-not из сценария.
{
  echo "# Оценка: $title"
  echo
  echo "Прогон: $out"
  awk '
    /^## / { h = $0; sub(/[[:space:]]+$/, "", h); sect = h
      if (h == "## Must") print "\n## Must\n\nОтметить пункт, если он выполнен.\n"
      if (h == "## Must-not") print "\n## Must-not\n\nОтметить пункт, если он не нарушен.\n"
      next }
    (sect == "## Must" && /^- \*\*M[0-9]+\*\*/) || (sect == "## Must-not" && /^- \*\*N[0-9]+\*\*/) {
      print "- [ ] " substr($0, 3); print "  Цитата/обоснование:" }
  ' "$scenario"
  echo
  echo "Итог: пройден / не пройден"
} > "$out/grading.md"

if (( failed > 0 )); then
  echo "итог: ход $failed не прошёл" >> "$out/meta.txt"
  echo "run: ход $failed: $failmsg" >&2
  echo "$out"
  exit 1
fi
echo "итог: все ходы прошли" >> "$out/meta.txt"
echo "$out"
