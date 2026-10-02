#!/usr/bin/env bash
# Тесты scripts/privacy-scan.sh и хука .githooks/pre-push на временных репозиториях и стоп-листе.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scan="$root/scripts/privacy-scan.sh"
fail=0

check() { # имя, ожидаемый код, фактический код
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: ожидали $2, получили $3"; fail=1; fi
}

# Запуск с ограничением по времени: зависание считается провалом (код 142).
run() { perl -e 'alarm 10; exec @ARGV or exit 127' "$@"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
deny="$tmp/denylist.txt"
printf '# комментарий\n\nТестоваяфамилия\nsecretword\n' > "$deny"

new_repo() {
  mkdir "$1" && cd "$1" && git init -q -b main && git config user.email t@t && git config user.name t
}

# Пустой репозиторий: нечего проверять, не зависать.
new_repo "$tmp/empty"
KLUBOK_DENYLIST="$deny" run "$scan" >/dev/null 2>&1; check "пустой репозиторий → 0" 0 $?

new_repo "$tmp/repo"
echo "чистый текст" > clean.md && git add . && git commit -qm init
KLUBOK_DENYLIST="$deny" run "$scan" >/dev/null 2>&1; check "чистое дерево → 0" 0 $?

echo "упоминание тестоваяфамилия в тексте" > leak.md && git add leak.md
KLUBOK_DENYLIST="$deny" run "$scan" >/dev/null 2>&1; check "кириллица без учёта регистра → 1" 1 $?
git rm -q --cached leak.md && rm leak.md

echo "SecretWord" > leak2.md && git add leak2.md && git commit -qm leak && git rm -q leak2.md && git commit -qm remove
KLUBOK_DENYLIST="$deny" run "$scan" >/dev/null 2>&1; check "утечка только в истории, без --history → 0" 0 $?
KLUBOK_DENYLIST="$deny" run "$scan" --history >/dev/null 2>&1; check "утечка в истории, с --history → 1" 1 $?

git commit -q --allow-empty -m "в сообщении secretword"
KLUBOK_DENYLIST="$deny" run "$scan" --history >/dev/null 2>&1; check "утечка в сообщении коммита → 1" 1 $?

# Строка «=слово» ищется только целым словом: имя ловится, часть другого слова — нет.
new_repo "$tmp/words"
printf '=Тестимя\n' > "$tmp/words.txt"
echo "это необходимо: нетестимяное слово" > a.md && git add a.md
KLUBOK_DENYLIST="$tmp/words.txt" run "$scan" >/dev/null 2>&1; check "=слово внутри другого слова → 0" 0 $?
echo "вчера тестимя сказал" > b.md && git add b.md
KLUBOK_DENYLIST="$tmp/words.txt" run "$scan" >/dev/null 2>&1; check "=слово целым словом → 1" 1 $?

KLUBOK_DENYLIST="$tmp/nope.txt" run "$scan" >/dev/null 2>&1; check "нет стоп-листа → 2" 2 $?
printf '# только комментарий\n\n' > "$tmp/blank.txt"
KLUBOK_DENYLIST="$tmp/blank.txt" run "$scan" >/dev/null 2>&1; check "стоп-лист без слов → 2" 2 $?

# Хук pre-push: чистый пуш проходит, пуш с утечкой блокируется.
git init -q --bare "$tmp/remote.git"
new_repo "$tmp/pusher"
git config core.hooksPath "$root/.githooks"
git remote add origin "$tmp/remote.git"
echo "чисто" > a.md && git add a.md && git commit -qm clean
KLUBOK_DENYLIST="$deny" run git push -q origin main >/dev/null 2>&1; check "pre-push: чистый пуш → 0" 0 $?
echo "secretword" > b.md && git add b.md && git commit -qm leak
KLUBOK_DENYLIST="$deny" run git push -q origin main >/dev/null 2>&1; check "pre-push: пуш с утечкой → 1" 1 $?

exit $fail
