#!/usr/bin/env bash
# Проверка на личные данные: ищет слова из стоп-листа в отслеживаемых файлах,
# а с флагом --history — ещё в сообщениях и диффах всех коммитов.
# Стоп-лист лежит вне репозитория: $KLUBOK_DENYLIST, по умолчанию ~/.config/klubok/denylist.txt.
# Одна строка — одно слово, без учёта регистра; строки с # и пустые пропускаются.
# Строка вида «=слово» ищется только целым словом (для коротких имён, которые
# иначе совпадают с частью обычных слов).
# Коды выхода: 0 — чисто, 1 — найдены совпадения, 2 — нет стоп-листа или он пуст.
set -euo pipefail

denylist="${KLUBOK_DENYLIST:-$HOME/.config/klubok/denylist.txt}"
if [[ ! -f "$denylist" ]]; then
  echo "privacy-scan: нет стоп-листа: $denylist" >&2
  exit 2
fi

patterns="$(mktemp)"; words="$(mktemp)"
trap 'rm -f "$patterns" "$words"' EXIT
grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' -e '^=' "$denylist" > "$patterns" || true
grep -e '^=' "$denylist" | sed 's/^=//' > "$words" || true
if [[ ! -s "$patterns" && ! -s "$words" ]]; then
  echo "privacy-scan: в стоп-листе нет слов: $denylist" >&2
  exit 2
fi

export LC_ALL=en_US.UTF-8
found=0

# Отслеживаемые файлы (и добавленные в индекс) в рабочем дереве.
files=()
while IFS= read -r -d '' f; do
  [[ -f "$f" ]] && files+=("$f")
done < <(git ls-files -z)
# Ищет по подстрокам и по целым словам; печатает совпадения, код 0 — если что-то нашлось.
search() {
  local hit=1
  if [[ -s "$patterns" ]] && grep -n -i -F -f "$patterns" "$@"; then hit=0; fi
  if [[ -s "$words" ]] && grep -n -i -w -F -f "$words" "$@"; then hit=0; fi
  return $hit
}

if (( ${#files[@]} > 0 )) && search -H -- "${files[@]}"; then
  found=1
fi

# История: сообщения и диффы всех коммитов, без строк автора.
if [[ "${1:-}" == "--history" ]] && git rev-parse -q --verify HEAD >/dev/null; then
  history_dump="$(git log -p --all --format='commit %h%n%B')"
  if search <<< "$history_dump"; then
    found=1
  fi
fi

if (( found )); then
  echo "privacy-scan: найдены слова из стоп-листа (см. выше)" >&2
  exit 1
fi
echo "privacy-scan: чисто"
