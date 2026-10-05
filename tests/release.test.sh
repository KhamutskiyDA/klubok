#!/usr/bin/env bash
# Тесты scripts/release.sh на временных репозиториях: ветка dist, ZIP и обновление клона (критерий 4).
# Команда обновления — как в README: git pull --no-rebase --no-edit upstream dist.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
release="$root/scripts/release.sh"
fail=0

check() { # имя, ожидаемое, фактическое
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: ожидали $2, получили $3"; fail=1; fi
}

# Запуск с ограничением по времени: зависание считается провалом (код 142).
run() { perl -e 'alarm 30; exec @ARGV or exit 127' "$@"; }

# Код 0, если в списке есть строка целиком, иначе 1.
listed() { grep -q -x -F -- "$2" <<< "$1"; echo $?; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Чистый git: без глобальных настроек мейнтейнера (pull.rebase, хуки и т. п.).
printf '[user]\n\tname = t\n\temail = t@t\n' > "$tmp/gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1

# Репозиторий разработки: продукт в vault/, рядом служебное.
src="$tmp/src"
mkdir -p "$src" && cd "$src" && git init -q -b main
mkdir -p vault/.claude/skills/x vault/.obsidian vault/Journal vault/Reviews vault/Me vault/Reference evals docs
echo "инструкции v1" > vault/CLAUDE.md
echo "скилл" > vault/.claude/skills/x/SKILL.md
echo "{}" > vault/.obsidian/app.json
echo "справка v1" > "vault/Reference/Кризисная помощь.md"
touch vault/Journal/.gitkeep vault/Reviews/.gitkeep vault/Me/.gitkeep
echo "сценарий" > evals/01.md
echo "план" > docs/plan.md
echo "readme" > README.md
git add . && git commit -qm init
echo "скилл v2" > vault/.claude/skills/x/SKILL.md && git commit -qam "dev history"

# Неверная версия и неподходящее состояние — отказ.
run "$release" 0.1 >/dev/null 2>&1; check "версия не X.Y.Z → 2" 2 $?
run "$release" >/dev/null 2>&1; check "без версии → 2" 2 $?
git switch -q -c dev
run "$release" 0.1.0 >/dev/null 2>&1; check "не на main → 1" 1 $?
git switch -q main
echo "правка" >> vault/CLAUDE.md
run "$release" 0.1.0 >/dev/null 2>&1; check "незакоммиченная правка → 1" 1 $?
git checkout -q -- vault/CLAUDE.md

# Первый релиз. Неотслеживаемый файл Obsidian в рабочей папке не должен попасть в ZIP.
echo '{"w":1}' > vault/.obsidian/workspace.json
run "$release" 0.1.0 >/dev/null 2>&1; check "релиз 0.1.0 → 0" 0 $?
tree="$(git ls-tree -r --name-only dist 2>/dev/null)"
check "dist: CLAUDE.md в корне" 0 "$(listed "$tree" CLAUDE.md)"
check "dist: скрытая .claude/" 0 "$(listed "$tree" .claude/skills/x/SKILL.md)"
check "dist: скрытая .obsidian/" 0 "$(listed "$tree" .obsidian/app.json)"
check "dist: Journal/.gitkeep" 0 "$(listed "$tree" Journal/.gitkeep)"
check "dist: без evals/" 1 "$(listed "$tree" evals/01.md)"
check "dist: без docs/" 1 "$(listed "$tree" docs/plan.md)"
check "dist: без README разработки" 1 "$(listed "$tree" README.md)"
check "dist: без префикса vault/" 1 "$(listed "$tree" vault/CLAUDE.md)"
check "dist: один коммит — снимок релиза" 1 "$(git rev-list --count dist 2>/dev/null)"
check "dist: сообщение коммита" "Klubok 0.1.0" "$(git log -1 --format=%s dist 2>/dev/null)"
first="$(git rev-parse -q --verify dist)"

zip="$src/build/klubok-0.1.0.zip"
check "ZIP создан" 0 "$([[ -f "$zip" ]]; echo $?)"
zlist="$(unzip -Z1 "$zip" 2>/dev/null)"
check "ZIP: папка Klubok/ со скрытой .claude/" 0 "$(listed "$zlist" Klubok/.claude/skills/x/SKILL.md)"
check "ZIP: скрытая .obsidian/" 0 "$(listed "$zlist" Klubok/.obsidian/app.json)"
check "ZIP: Journal/.gitkeep" 0 "$(listed "$zlist" Klubok/Journal/.gitkeep)"
check "ZIP: без workspace.json" 1 "$(listed "$zlist" Klubok/.obsidian/workspace.json)"
check "ZIP: без evals/" 1 "$(listed "$zlist" Klubok/evals/01.md)"

# Пользователь: клон по README, свои записи и файлы Obsidian.
# A — записи не закоммичены; Б — закоммичены (бэкап в приватный репозиторий, как советует README).
for who in a b; do
  run git clone -q -b dist "$src" "$tmp/user-$who" >/dev/null 2>&1; check "клон $who: git clone -b dist → 0" 0 $?
  cd "$tmp/user-$who" 2>/dev/null || continue
  git remote rename origin upstream
  echo "мой день" > Journal/2026-10-05.md
  echo "мой разбор" > Reviews/2026-10-05-письмо.md
  echo "обо мне" > "Me/Как со мной работать.md"
  echo '{"w":2}' > .obsidian/workspace.json
  echo '{}' > .obsidian/appearance.json
done
cd "$tmp/user-b" 2>/dev/null && git add Journal Reviews Me && git commit -qm "мои записи"

# Второй релиз: меняется только системное.
cd "$src"
echo "инструкции v2" > vault/CLAUDE.md
echo "справка v2" > "vault/Reference/Кризисная помощь.md"
git commit -qam "update system files"
run "$release" 0.1.1 >/dev/null 2>&1; check "релиз 0.1.1 → 0" 0 $?
git merge-base --is-ancestor "$first" dist 2>/dev/null; check "dist 0.1.1 — продолжение 0.1.0" 0 $?
check "dist: два коммита, без истории разработки" 2 "$(git rev-list --count dist 2>/dev/null)"

for who in a b; do
  cd "$tmp/user-$who" 2>/dev/null || { check "клон $who есть" 0 1; continue; }
  run git pull --no-rebase --no-edit upstream dist </dev/null >/dev/null 2>&1; check "клон $who: git pull → 0" 0 $?
  check "клон $who: CLAUDE.md обновился" "инструкции v2" "$(cat CLAUDE.md)"
  check "клон $who: дневник цел" "мой день" "$(cat Journal/2026-10-05.md)"
  check "клон $who: разбор цел" "мой разбор" "$(cat Reviews/2026-10-05-письмо.md)"
  check "клон $who: Me/ цел" "обо мне" "$(cat "Me/Как со мной работать.md")"
  check "клон $who: workspace.json цел" '{"w":2}' "$(cat .obsidian/workspace.json)"
  check "клон $who: нет конфликтов" "" "$(git diff --name-only --diff-filter=U)"
done

exit $fail
