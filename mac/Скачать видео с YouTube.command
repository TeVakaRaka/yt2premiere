#!/bin/bash
# Двойной клик → окно спросит ссылку, папку и формат.
DIR="$(cd "$(dirname "$0")" && pwd)"

clear
cat <<'BANNER'
┌────────────────────────────────────────────────┐
│   YouTube  →  Premiere Pro                       │
│   скачать в макс. качестве и конвертировать      │
└────────────────────────────────────────────────┘
BANNER
echo
echo "1) Ссылка(и) на YouTube (несколько — через пробел):"
read -r urls
[ -z "$urls" ] && { echo "Ссылка не введена. Выход."; sleep 1; exit 0; }

echo
echo "2) Куда скачивать? (перетащи папку сюда из Finder или впиши путь)"
echo "   Enter = по умолчанию (~/Movies/YouTube)"
read -r outdir

echo
echo "3) Формат:"
echo "   1) MP4 H.264    — универсально                  (по умолчанию)"
echo "   2) ProRes .mov  — лучший для монтажа в Premiere"
echo "   3) MP3          — только звук"
printf "Номер [1]: "
read -r choice

opts=()
case "$choice" in
  2) opts+=(--prores) ;;
  3) opts+=(--mp3) ;;
esac

# нормализуем путь к папке: убрать кавычки, разэкранировать пробелы (перетаскивание), trim
if [ -n "$outdir" ]; then
  outdir="${outdir%\"}"; outdir="${outdir#\"}"
  outdir="${outdir%\'}"; outdir="${outdir#\'}"
  outdir="${outdir//\\ / }"
  outdir="$(printf '%s' "$outdir" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  outdir="${outdir%/}"
  opts+=(--out "$outdir")
fi

echo
# shellcheck disable=SC2086
"$DIR/yt2premiere.sh" "${opts[@]}" $urls

echo
echo "── Готово. Можно закрыть окно (нажми любую клавишу). ──"
read -n 1 -s
