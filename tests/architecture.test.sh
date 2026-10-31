#!/usr/bin/env bash
# Проверка упаковки реального vault и обновления пользовательского клона.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '[user]\nname = Test\nemail = test@example.invalid\n' > "$tmp/gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$tmp/src/vault"
cp -R "$root/vault/." "$tmp/src/vault/"
cd "$tmp/src"
git init -q -b main
git add vault
git commit -qm 'Architecture snapshot'
bash "$root/scripts/release.sh" 0.2.0 >/dev/null
python3 -c 'import zipfile; print("\n".join(zipfile.ZipFile("build/klubok-0.2.0.zip").namelist()))' > "$tmp/zip-list"
for path in 'Journal/CLAUDE.md' 'Psychology/CLAUDE.md' 'Journal/Daily notes/.gitkeep' 'Journal/Archive/.gitkeep' 'Psychology/Reviews/.gitkeep' 'Psychology/Dossiers/.gitkeep' 'Psychology/Period reviews/.gitkeep' 'Карта хранилища.md' 'Templates/Досье темы.md' 'Reference/Переход на новую структуру.md'; do
  git cat-file -e "dist:$path"
  grep -Fxq "Klubok/$path" "$tmp/zip-list"
done
echo 'ok   реальная структура блоков входит в dist и ZIP'
git clone -q -b dist . "$tmp/user"
cd "$tmp/user"
git remote rename origin upstream
printf 'Саша: запись дня\n' > 'Journal/Daily notes/2026-10-31.md'
printf 'Саша: разбор\n' > 'Psychology/Reviews/2026-10-31 Письмо.md'
printf 'Саша: тема\n' > 'Psychology/Dossiers/Письма.md'
printf 'Саша: старый разбор\n' > 'Reviews/2026-10-30.md'
printf 'Саша: старый дневник\n' > 'Journal/2026-10-30.md'
printf 'Саша: контекст\n' > 'Psychology/Контекст.md'
printf '{"folder":"Journal/Daily notes"}\n' > .obsidian/daily-notes.json
# Коммитим данные, но оставляем настройку Obsidian незакоммиченной.
git add Journal Psychology Reviews
git commit -qm 'Synthetic user notes'
python3 - <<'PY'
import hashlib,json
from pathlib import Path
files=[p for base in ('Journal','Psychology','Reviews','.obsidian') for p in Path(base).rglob('*') if p.is_file() and p.name != 'CLAUDE.md']
Path('../before.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}))
PY
cd "$tmp/src"
printf '\nДополнение контракта.\n' >> vault/Journal/CLAUDE.md
printf '\nДополнение контракта.\n' >> vault/Psychology/CLAUDE.md
git add vault
git commit -qm 'Update block contracts'
bash "$root/scripts/release.sh" 0.2.1 >/dev/null
cd "$tmp/user"
git pull -q --no-rebase --no-edit upstream dist
python3 - <<'PY'
import hashlib,json
from pathlib import Path
for name,digest in json.loads(Path('../before.json').read_text()).items():
 assert hashlib.sha256(Path(name).read_bytes()).hexdigest()==digest,name
for name in ('Journal/CLAUDE.md','Psychology/CLAUDE.md'):
 assert 'Дополнение контракта.' in Path(name).read_text(),name
print('ok   контракты обновились, новые и старые записи и настройка Obsidian сохранены')
PY
