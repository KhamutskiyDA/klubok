#!/usr/bin/env bash
# Тесты evals/run.sh на заглушке claude, поддельных vault, фикстурах и сценарии.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$root/evals/run.sh"
fail=0

check() { # имя, ожидаемое, фактическое
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: ожидали $2, получили $3"; fail=1; fi
}

# Запуск с ограничением по времени: зависание считается провалом (код 142).
run() { perl -e 'alarm 30; exec @ARGV or exit 127' "$@"; }

# Код 0, если файл содержит строку целиком (fixed string), иначе 1.
has() { grep -q -F -- "$2" "$1" 2>/dev/null; echo $?; }
exists() { [[ -n "$1" ]] || { echo "пустой путь"; return; }; [[ -e "$1" ]]; echo $?; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Заглушка claude: пишет argv, stdin, cwd, окружение и снимок cwd каждого вызова в $STUB_LOG,
# создаёт файл в cwd и папку транскриптов в $HOME/.claude/projects, печатает поддельный stream-json.
# STUB_FAIL_AT=N — вызов N падает; STUB_ERROR_AT=N — вызов N выходит с 0, но is_error в result;
# STUB_LEAK_AT=N — в init вызова N есть плагин; STUB_DENY_AT=N — в result вызова N отказ в доступе;
# STUB_BUILTIN_AT=N — в init вызова N встроенный плагин plugin-authoring@builtin, как у CLI 2.1.272.
stub="$tmp/claude-stub"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "stub-claude 0.0"; exit 0; fi
n=$(( $(ls "$STUB_LOG" | grep -c '\.args$') + 1 ))
id="$(printf '%02d' "$n")"
printf '%s\n' "$@" > "$STUB_LOG/$id.args"
cat > "$STUB_LOG/$id.stdin"
pwd -P > "$STUB_LOG/$id.cwd"
env > "$STUB_LOG/$id.env"
proj="$HOME/.claude/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$proj" && echo "{}" > "$proj/s-$id.jsonl"
mkdir "$STUB_LOG/$id.snap" && cp -R . "$STUB_LOG/$id.snap/"
if [[ "${STUB_FAIL_AT:-}" == "$n" ]]; then echo "boom" >&2; exit 3; fi
mkdir -p Journal && echo "запись $id" > "Journal/stub-$id.md"
plugins='[]'; [[ "${STUB_LEAK_AT:-}" == "$n" ]] && plugins='[{"name":"leaked-plugin"}]'
skills='["x"]'
if [[ "${STUB_BUILTIN_AT:-}" == "$n" ]]; then
  plugins='[{"name":"plugin-authoring","path":"builtin","source":"plugin-authoring@builtin"}]'
  skills='["x","plugin-authoring"]'
fi
is_error=false; [[ "${STUB_ERROR_AT:-}" == "$n" ]] && is_error=true
denials='[]'; [[ "${STUB_DENY_AT:-}" == "$n" ]] && denials='[{"tool_name":"Write","tool_use_id":"d1","tool_input":{"file_path":"/etc/outside.md"}}]'
cat <<JSON
{"type":"system","subtype":"init","session_id":"s-$id","model":"stub-model","tools":["Read","Write"],"skills":$skills,"mcp_servers":[],"plugins":$plugins}
{"type":"assistant","message":{"content":[{"type":"text","text":"Ответ заглушки $id"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t$id","name":"Write","input":{"file_path":"Journal/stub-$id.md","content":"запись $id"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t$id","content":"File created successfully"}]}}
{"type":"something_new","foo":1}
не json вовсе
{"type":"result","subtype":"success","is_error":$is_error,"result":"итог $id","num_turns":2,"total_cost_usd":0.01,"duration_ms":10,"permission_denials":$denials}
JSON
EOF
chmod +x "$stub"

vault="$tmp/vault"
mkdir -p "$vault/.claude/skills/x" "$vault/Me"
echo "# Ядро" > "$vault/CLAUDE.md"
echo "skill" > "$vault/.claude/skills/x/SKILL.md"
: > "$vault/Me/.gitkeep"
echo "из vault" > "$vault/Me/Профиль.md"

fixtures="$tmp/fixtures"
mkdir -p "$fixtures/onboarded/Me" "$fixtures/fresh/Me"
echo "из фикстуры onboarded" > "$fixtures/onboarded/Me/Профиль.md"
echo "fresh" > "$fixtures/fresh/Me/fresh.md"
echo "dot" > "$fixtures/fresh/.fixture-dot"
printf '# комментарий\n\n99-test-scenario fresh\n97-missing-fixture nope\n' > "$fixtures/map.txt"

scen="$tmp/99-test-scenario.md"
cat > "$scen" <<'EOF'
# 99. Тестовый сценарий

## Что проверяем

Этот ход вне раздела «Ходы» и не должен попасть в прогон.

### Ход 0

```text
Лишняя реплика.
```

## Исходное состояние

- Знакомство пройдено.

## Ходы

### Ход 1

```text
Первая реплика.
```

### Ход 2

```text
Строка один.

Строка три с `кавычками` и $HOME.
  отступ
```

### Ход 3 (новый разговор)

```text
Третья реплика.
```

## Must

- **M1** `[тон]` (ход 1) Первое требование.
- **M2** `[границы ИИ]` (после прогона) Второе требование.

## Must-not

- **N1** `[тон]` (все ходы) Запрет.

## Источники

- **M9** не пункт: раздел источников.
EOF

# Запуск раннера: лог заглушки, затем аргументы раннера.
go() {
  local log="$1"; shift
  mkdir -p "$log"
  STUB_LOG="$log" HOME="$tmp/home" CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=parent CLAUDE_CODE_ENTRYPOINT=cli \
    KLUBOK_CLAUDE="$stub" KLUBOK_VAULT="${V:-$vault}" KLUBOK_FIXTURES="${F:-$fixtures}" \
    run "$runner" "$@"
}
calls() { ls "$1" 2>/dev/null | grep -c '\.args$'; }

mkdir -p "$tmp/home/.claude/projects/-other-project"

# Ошибки входных данных: код 2 и ни одного вызова claude.
go "$tmp/l-noargs" >/dev/null 2>&1; check "без аргументов → 2" 2 $?
go "$tmp/l-nofile" "$tmp/nope.md" "$tmp/o" >/dev/null 2>&1; check "нет файла сценария → 2" 2 $?
printf '# 98. Пусто\n\n## Ходы\n\nтекста нет\n' > "$tmp/98-empty.md"
go "$tmp/l-noturns" "$tmp/98-empty.md" "$tmp/o" >/dev/null 2>&1; check "нет ходов → 2" 2 $?
V="$tmp/no-vault" go "$tmp/l-novault" "$scen" "$tmp/o-novault" >/dev/null 2>&1; check "нет vault → 2" 2 $?
F="$tmp/no-fixtures" go "$tmp/l-nofix" "$scen" "$tmp/o-nofix" >/dev/null 2>&1; check "нет папки фикстур → 2" 2 $?
cp "$scen" "$tmp/97-missing-fixture.md"
go "$tmp/l-nofix2" "$tmp/97-missing-fixture.md" "$tmp/o-nofix2" >/dev/null 2>&1; check "фикстура из map.txt не найдена → 2" 2 $?
printf '# 95. Без блока\n\n## Ходы\n\n### Ход 1\n\nпросто текст\n' > "$tmp/95-noblock.md"
go "$tmp/l-noblock" "$tmp/95-noblock.md" "$tmp/o-noblock" >/dev/null 2>&1; check "у хода нет блока text → 2" 2 $?
KLUBOK_CLAUDE="$tmp/no-claude" KLUBOK_VAULT="$vault" KLUBOK_FIXTURES="$fixtures" run "$runner" "$scen" "$tmp/o-noclaude" >/dev/null 2>&1
check "нет claude → 2" 2 $?
mkdir -p "$tmp/busy" && echo old > "$tmp/busy/transcript.md"
go "$tmp/l-busy" "$scen" "$tmp/busy" >/dev/null 2>&1; check "папка результата не пуста → 2" 2 $?
mkdir -p "$root/evals/tmp/zz-tmpdir"
TMPDIR="$root/evals/tmp/zz-tmpdir" go "$tmp/l-tmpdir" "$scen" "$tmp/o-tmpdir" >/dev/null 2>&1
check "временная папка внутри репозитория → 2" 2 $?
rm -rf "$root/evals/tmp/zz-tmpdir"
msg="$(go "$tmp/l-nofile2" "$tmp/nope.md" "$tmp/o" 2>&1 >/dev/null)"
check "сообщение об ошибке по-русски" 0 "$(echo "$msg" | grep -q 'нет файла сценария'; echo $?)"
total=0
for l in l-noargs l-nofile l-noturns l-novault l-nofix l-nofix2 l-noblock l-busy l-tmpdir; do total=$(( total + $(calls "$tmp/$l") )); done
check "при ошибках claude не вызывается" 0 "$total"

# Успешный прогон с фикстурой из map.txt и моделью.
log="$tmp/l-ok"; out="$tmp/out-ok"
stdout="$(KLUBOK_EVAL_MODEL=stub-m go "$log" "$scen" "$out" 2>/dev/null)"; code=$?
check "успешный прогон → 0" 0 "$code"
check "в конце печатается папка результата" "$out" "$(echo "$stdout" | tail -n 1)"
check "три вызова claude (ход 0 вне раздела не считается)" 3 "$(calls "$log")"
check "первый аргумент -p" "-p" "$(head -n 1 "$log/01.args")"
check "ход 1 без --continue" 1 "$(has "$log/01.args" --continue)"
check "ход 2 с --continue" 0 "$(has "$log/02.args" --continue)"
check "ход 3 (новый разговор) без --continue" 1 "$(has "$log/03.args" --continue)"
check "флаги stream-json" 0 "$(has "$log/01.args" stream-json)"
for flag in --setting-sources --strict-mcp-config --tools; do
  check "флаг изоляции $flag" 0 "$(grep -qx -- "$flag" "$log/01.args"; echo $?)"
done
check "только проектные настройки" 0 "$(grep -A1 -x -- '--setting-sources' "$log/01.args" | grep -qx project; echo $?)"
check "без Bash и веба" 0 "$(grep -A1 -x -- '--tools' "$log/01.args" | tail -n 1 | grep -qvE 'Bash|Web'; echo $?)"
check "автопамять выключена" 0 "$(has "$log/01.args" '"autoMemoryEnabled":false')"
check "встроенный плагин plugin-authoring выключен" 0 "$(has "$log/01.args" '"enabledPlugins":{"plugin-authoring@builtin":false}')"
check "переменные родительского Claude Code убраны" 1 "$(grep -qE '^(CLAUDECODE|CLAUDE_CODE_SESSION_ID|CLAUDE_CODE_ENTRYPOINT)=' "$log/01.env"; echo $?)"
check "транскрипты прогона удалены" 1 "$(exists "$tmp/home/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' "$log/01.cwd")")"
check "чужие транскрипты не тронуты" 0 "$(exists "$tmp/home/.claude/projects/-other-project")"
check "модель передана через --model" 0 "$(grep -A1 -x -- '--model' "$log/01.args" | grep -qx stub-m; echo $?)"

printf 'Первая реплика.\n' > "$tmp/exp1"
printf 'Строка один.\n\nСтрока три с `кавычками` и $HOME.\n  отступ\n' > "$tmp/exp2"
printf 'Третья реплика.\n' > "$tmp/exp3"
for i in 1 2 3; do
  cmp -s "$tmp/exp$i" "$log/0$i.stdin"; check "stdin хода $i совпадает с репликой" 0 $?
done

cwd="$(cat "$log/01.cwd" 2>/dev/null)"
case "$cwd/" in /) inside=нет-cwd ;; "$root"/*) inside=0 ;; *) inside=1 ;; esac
check "cwd claude вне репозитория" 1 "$inside"
parent_claude=1; d="$(dirname "$cwd")"
while [[ "$d" == /?* ]]; do [[ -f "$d/CLAUDE.md" ]] && parent_claude=0; d="$(dirname "$d")"; done
check "над cwd нет чужого CLAUDE.md" 1 "$parent_claude"
check "один и тот же vault во всех ходах" "$cwd" "$(cat "$log/03.cwd")"
snap="$log/01.snap"
check "в копии есть CLAUDE.md" 0 "$(exists "$snap/CLAUDE.md")"
check "в копии есть .claude/" 0 "$(exists "$snap/.claude/skills/x/SKILL.md")"
check "в копии есть Me/.gitkeep" 0 "$(exists "$snap/Me/.gitkeep")"
check "фикстура из map.txt наложена" 0 "$(exists "$snap/Me/fresh.md")"
check "dot-файл фикстуры наложен" 0 "$(exists "$snap/.fixture-dot")"
check "фикстура по умолчанию не наложена" 1 "$(has "$snap/Me/Профиль.md" onboarded)"
check "ход 3 видит файл, записанный в ходе 1" 0 "$(exists "$log/03.snap/Journal/stub-01.md")"
check "временный vault удалён" 1 "$(exists "$cwd")"

check "turns/01.jsonl — сырой вывод" 0 "$(has "$out/turns/01.jsonl" '"type":"result"')"
check "turns/03.jsonl есть" 0 "$(exists "$out/turns/03.jsonl")"
check "пустой stderr не сохраняется" 1 "$(exists "$out/turns/01.stderr")"

t="$out/transcript.md"
check "транскрипт: реплика хода 1" 0 "$(has "$t" 'Первая реплика.')"
check "транскрипт: многострочная реплика" 0 "$(has "$t" 'Строка три с `кавычками` и $HOME.')"
check "транскрипт: ответ помощника" 0 "$(has "$t" 'Ответ заглушки 01')"
check "транскрипт: ответ после неизвестных строк" 0 "$(has "$t" 'Ответ заглушки 03')"
check "транскрипт: имя инструмента" 0 "$(has "$t" 'Write')"
check "транскрипт: вход инструмента" 0 "$(has "$t" 'Journal/stub-01.md')"
check "транскрипт: результат инструмента" 0 "$(has "$t" 'File created successfully')"
check "транскрипт: пометка нового разговора" 0 "$(grep -q '^## Ход 3 (новый разговор)' "$t"; echo $?)"
check "транскрипт: ход 2 без пометки" 0 "$(grep -qx '## Ход 2' "$t"; echo $?)"
check "транскрипт: лишняя реплика не попала" 1 "$(has "$t" 'Лишняя реплика.')"
check "транскрипт: инструменты и скиллы из init" 0 "$(has "$t" 'инструменты: Read, Write; скиллы: x')"

check "vault-after: файл из хода 1" 0 "$(exists "$out/vault-after/Journal/stub-01.md")"
check "vault-after: файл из хода 3" 0 "$(exists "$out/vault-after/Journal/stub-03.md")"
check "vault-after: .claude/" 0 "$(exists "$out/vault-after/.claude/skills/x/SKILL.md")"

m="$out/meta.txt"
check "meta: фикстура" 0 "$(has "$m" 'fresh')"
check "meta: версия claude" 0 "$(has "$m" 'stub-claude 0.0')"
check "meta: флаги" 0 "$(has "$m" '--permission-mode acceptEdits')"
check "meta: модель" 0 "$(has "$m" 'stub-m')"
check "meta: модель из init первого хода" 0 "$(has "$m" 'модель в init: stub-model')"
check "meta: коммит" 0 "$(has "$m" "$(git -C "$root" rev-parse --short HEAD)")"

g="$out/grading.md"
check "grading: заголовок сценария" 0 "$(has "$g" '99. Тестовый сценарий')"
check "grading: M1" 0 "$(has "$g" '- [ ] **M1** `[тон]` (ход 1) Первое требование.')"
check "grading: M2" 0 "$(has "$g" '- [ ] **M2** `[границы ИИ]` (после прогона) Второе требование.')"
check "grading: N1" 0 "$(has "$g" '- [ ] **N1** `[тон]` (все ходы) Запрет.')"
check "grading: ровно три пункта" 3 "$(grep -c '^- \[ \]' "$g")"
check "grading: поле для обоснования у каждого" 3 "$(grep -c '^  Цитата/обоснование:' "$g")"
check "grading: итог" 0 "$(has "$g" 'Итог: пройден / не пройден')"

# Без записи в map.txt берётся фикстура onboarded; без модели нет --model.
cp "$scen" "$tmp/96-default.md"
log="$tmp/l-def"
go "$log" "$tmp/96-default.md" "$tmp/out-def" >/dev/null 2>&1; check "прогон с фикстурой по умолчанию → 0" 0 $?
check "фикстура по умолчанию onboarded" 0 "$(has "$log/01.snap/Me/Профиль.md" 'onboarded')"
check "чужая фикстура не наложена" 1 "$(exists "$log/01.snap/Me/fresh.md")"
check "без KLUBOK_EVAL_MODEL нет --model" 1 "$(has "$log/01.args" --model)"
check "meta: фикстура onboarded" 0 "$(has "$tmp/out-def/meta.txt" 'onboarded')"
check "meta: без KLUBOK_EVAL_MODEL модель из init" 0 "$(has "$tmp/out-def/meta.txt" 'модель в init: stub-model')"

# Падение claude на ходе 2: код 1, ход 3 не запускается, vault-after сохранён.
log="$tmp/l-fail"; out="$tmp/out-fail"
STUB_FAIL_AT=2 go "$log" "$scen" "$out" >/dev/null 2>&1; check "claude упал → 1" 1 $?
check "после падения вызовов больше нет" 2 "$(calls "$log")"
check "stderr упавшего хода сохранён" 0 "$(has "$out/turns/02.stderr" boom)"
check "vault-after сохранён после падения" 0 "$(exists "$out/vault-after/Journal/stub-01.md")"
check "транскрипт: код выхода упавшего хода" 0 "$(has "$out/transcript.md" 'код 3')"
check "meta: код выхода упавшего хода" 0 "$(has "$out/meta.txt" 'код 3')"
check "временный vault удалён после падения" 1 "$(exists "$(cat "$log/01.cwd" 2>/dev/null)")"

# claude вышел с 0, но в result is_error (например, нет авторизации): ход провален.
log="$tmp/l-err"; out="$tmp/out-err"
STUB_ERROR_AT=1 go "$log" "$scen" "$out" >/dev/null 2>&1; check "is_error в result → 1" 1 $?
check "после is_error вызовов больше нет" 1 "$(calls "$log")"
check "транскрипт: текст ошибки из result" 0 "$(has "$out/transcript.md" 'итог 01')"

# В init есть плагин: изоляция нарушена, прогон не засчитывается.
log="$tmp/l-leak"; out="$tmp/out-leak"
STUB_LEAK_AT=2 go "$log" "$scen" "$out" >/dev/null 2>&1; check "плагин в init → 1" 1 $?
check "после нарушения изоляции вызовов больше нет" 2 "$(calls "$log")"
check "транскрипт: изоляция нарушена" 0 "$(has "$out/transcript.md" 'изоляция нарушена')"
check "meta: изоляция нарушена" 0 "$(has "$out/meta.txt" 'изоляция нарушена')"

# Встроенный плагин plugin-authoring@builtin в init: раннер выключает его в --settings,
# и если он всё же появился, это нарушение изоляции, как с любым другим плагином.
log="$tmp/l-builtin"; out="$tmp/out-builtin"
STUB_BUILTIN_AT=1 go "$log" "$scen" "$out" >/dev/null 2>&1; check "plugin-authoring@builtin в init → 1" 1 $?
check "после встроенного плагина вызовов больше нет" 1 "$(calls "$log")"
check "meta: встроенный плагин — нарушение изоляции" 0 "$(has "$out/meta.txt" 'изоляция нарушена')"
check "meta: названо, какой плагин" 0 "$(has "$out/meta.txt" 'plugin-authoring@builtin')"

# Отказ в доступе не ошибка прогона, но виден в транскрипте.
log="$tmp/l-deny"; out="$tmp/out-deny"
STUB_DENY_AT=1 go "$log" "$scen" "$out" >/dev/null 2>&1; check "отказ в доступе → 0" 0 $?
check "транскрипт: отказ в доступе" 0 "$(has "$out/transcript.md" 'отказ в доступе: Write /etc/outside.md')"

# Папка результата по умолчанию: evals/tmp/<сценарий>/<время>/.
cp "$scen" "$tmp/zz-runner-selftest.md"
rm -rf "$root/evals/tmp/zz-runner-selftest"
stdout="$(go "$tmp/l-defout" "$tmp/zz-runner-selftest.md" 2>/dev/null)"; check "прогон без out-dir → 0" 0 $?
last="$(echo "$stdout" | tail -n 1)"
check "out-dir по умолчанию в evals/tmp/<сценарий>/<время>" 0 \
  "$(echo "$last" | grep -qE "^$root/evals/tmp/zz-runner-selftest/[0-9]{8}-[0-9]{6}/?$"; echo $?)"
check "out-dir по умолчанию заполнен" 0 "$(exists "$last/transcript.md")"
rm -rf "$root/evals/tmp/zz-runner-selftest"

exit $fail
