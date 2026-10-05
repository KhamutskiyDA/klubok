#!/usr/bin/env bash
# Сборка релиза: папка vault/ из main → локальная ветка dist + ZIP build/klubok-X.Y.Z.zip.
# Запуск: scripts/release.sh X.Y.Z — из корня репозитория, на чистой ветке main.
# Ничего не публикует: push ветки dist, тег и GitHub Release делаются вручную.
# Коды выхода: 0 — готово, 1 — отказ (не main или есть правки), 2 — неверная версия.
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release: нужна версия вида X.Y.Z, например 0.1.0" >&2
  exit 2
fi

cd "$(git rev-parse --show-toplevel)"
if [[ "$(git symbolic-ref -q --short HEAD)" != main ]]; then
  echo "release: релиз собирается только из main" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "release: есть незакоммиченные правки" >&2
  exit 1
fi

# Снимок отслеживаемого содержимого vault/ — один коммит поверх прошлого релиза.
# История разработки в dist не попадает, а dist только продолжается: git pull у пользователей
# идёт без переписывания истории.
tree="$(git rev-parse HEAD:vault)"
if git rev-parse -q --verify dist >/dev/null; then
  commit="$(git commit-tree "$tree" -p dist -m "Klubok $version")"
else
  commit="$(git commit-tree "$tree" -m "Klubok $version")"
fi
git update-ref -m "release $version" refs/heads/dist "$commit"

mkdir -p build
zip="build/klubok-$version.zip"
git archive --format=zip --prefix=Klubok/ -o "$zip" dist

echo "release: dist → $(git rev-parse --short dist), ZIP → $zip"
echo "Дальше вручную: git push origin dist; gh release create v$version $zip --verify-tag --notes-file docs/releases/v$version.md"
