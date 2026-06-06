#!/usr/bin/env bash
#
# yt2premiere — скачать видео с YouTube в максимальном качестве и
# сконвертировать в формат, удобный для монтажа в Adobe Premiere Pro.
#
#   • по умолчанию  : H.264 .mp4  (универсально, открывается везде)
#   • --prores      : Apple ProRes 422 HQ .mov  (самый плавный монтаж на Mac)
#   • --mp3         : только звук → mp3
#
# Зависимости: yt-dlp, ffmpeg (brew install yt-dlp ffmpeg)
#
set -uo pipefail

# ─────────────────────────── настройки по умолчанию ───────────────────────────
OUT_FORMAT="mp4"                 # mp4 | prores
MAXRES=""                        # пусто = максимально доступное
OUTDIR="$HOME/Movies/YouTube"    # куда складывать готовые файлы
KEEP=false                       # сохранять ли исходный скачанный файл
AUDIO_ONLY=false

# ─────────────────────────────── оформление ──────────────────────────────────
g=$'\033[1;32m'; y=$'\033[1;33m'; r=$'\033[1;31m'; d=$'\033[2m'; x=$'\033[0m'
info(){ printf "%s▶ %s%s\n" "$g" "$*" "$x" >&2; }
warn(){ printf "%s! %s%s\n" "$y" "$*" "$x" >&2; }
err(){  printf "%s✖ %s%s\n" "$r" "$*" "$x" >&2; }

usage(){
  cat >&2 <<EOF
yt2premiere — скачать YouTube в максимальном качестве и конвертировать для Premiere Pro

Использование:
  yt2premiere [опции] ССЫЛКА [ССЫЛКА2 ...]

Опции:
  -p, --prores      ProRes 422 HQ (.mov) вместо mp4 — лучший формат для монтажа
      --mp3         только звук → mp3
  -m, --max N       ограничить разрешение: 720 | 1080 | 1440 | 2160
  -o, --out DIR     папка вывода (по умолчанию: ~/Movies/YouTube)
  -k, --keep        сохранить и исходный скачанный файл
  -h, --help        показать эту справку

Примеры:
  yt2premiere "https://youtu.be/XXXX"                  # mp4, макс. качество
  yt2premiere --prores "https://youtu.be/XXXX"         # ProRes для монтажа
  yt2premiere --max 1080 url1 url2 url3                # пачкой, не выше 1080p
  yt2premiere --mp3 "https://youtu.be/XXXX"            # только звук
EOF
  exit "${1:-0}"
}

# ──────────────────────────── разбор аргументов ──────────────────────────────
URLS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--prores) OUT_FORMAT="prores" ;;
    --mp3)       AUDIO_ONLY=true ;;
    -m|--max)    MAXRES="${2:-}"; shift ;;
    -o|--out)    OUTDIR="${2:-}"; shift ;;
    -k|--keep)   KEEP=true ;;
    -h|--help)   usage 0 ;;
    -*)          err "неизвестная опция: $1"; usage 1 ;;
    *)           URLS+=("$1") ;;
  esac
  shift
done

[ ${#URLS[@]} -eq 0 ] && { err "не передано ни одной ссылки на YouTube"; echo >&2; usage 1; }

# ──────────────────────────────── проверки ───────────────────────────────────
for bin in yt-dlp ffmpeg ffprobe; do
  command -v "$bin" >/dev/null 2>&1 || { err "$bin не установлен → brew install yt-dlp ffmpeg"; exit 1; }
done
mkdir -p "$OUTDIR"

# ─────────────────────── строка выбора качества для yt-dlp ────────────────────
if [ -n "$MAXRES" ]; then
  DL_FMT="bv*[height<=$MAXRES]+ba/b[height<=$MAXRES]/bv*+ba/b"
else
  DL_FMT="bv*+ba/b"   # лучшее видео + лучший звук, иначе лучший общий
fi

# ─────────────────────────── транскод одного файла ───────────────────────────
transcode(){
  local src="$1" base out H VB
  base="$(basename "${src%.*}")"
  H="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$src" 2>/dev/null | head -1)"
  [ -z "$H" ] && H=1080

  if [ "$OUT_FORMAT" = "prores" ]; then
    out="$OUTDIR/$base.mov"
    info "ProRes 422 HQ (${H}p) → $(basename "$out")"
    if ! ffmpeg -y -hide_banner -loglevel warning -stats -i "$src" \
        -c:v prores_videotoolbox -profile:v hq -pix_fmt yuv422p10le \
        -c:a pcm_s16le "$out"; then
      warn "аппаратный ProRes не сработал — перехожу на программный кодировщик…"
      ffmpeg -y -hide_banner -loglevel warning -stats -i "$src" \
        -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -vendor apl0 \
        -c:a pcm_s16le "$out"
    fi
  else
    # битрейт под разрешение (запас по качеству для монтажного исходника)
    if   [ "$H" -ge 2160 ]; then VB="45M"
    elif [ "$H" -ge 1440 ]; then VB="24M"
    elif [ "$H" -ge 1080 ]; then VB="14M"
    elif [ "$H" -ge 720  ]; then VB="8M"
    else                         VB="5M";  fi
    out="$OUTDIR/$base.mp4"
    info "MP4 H.264 (${H}p, ${VB}) → $(basename "$out")"
    ffmpeg -y -hide_banner -loglevel warning -stats -i "$src" \
      -c:v h264_videotoolbox -b:v "$VB" -tag:v avc1 -pix_fmt yuv420p \
      -c:a aac -b:a 320k -movflags +faststart "$out"
  fi
}

# ─────────────────────── авто-лечение yt-dlp при сбоях ───────────────────────
# YouTube периодически меняет раздачу → yt-dlp начинает падать (HTTP 403 и т.п.).
# Лечим автоматически: обновляем yt-dlp (не больше раза за запуск) и повторяем.
UPDATED_THIS_RUN=false
update_ytdlp(){
  $UPDATED_THIS_RUN && return 0
  UPDATED_THIS_RUN=true
  warn "Обновляю yt-dlp (возможно, YouTube поменял формат раздачи)…"
  if command -v brew >/dev/null 2>&1 && brew list yt-dlp >/dev/null 2>&1; then
    brew upgrade yt-dlp >/dev/null 2>&1 || brew reinstall yt-dlp >/dev/null 2>&1 || true
  else
    yt-dlp -U >/dev/null 2>&1 || true
  fi
  info "Версия yt-dlp: $(yt-dlp --version 2>/dev/null)"
}

# Запуск yt-dlp с самолечением. Эскалация: обычно → повтор → обновить → сменить клиент.
ytdlp_heal(){
  yt-dlp "$@" && return 0
  warn "Сбой загрузки — повторяю через пару секунд…"
  sleep 3
  yt-dlp "$@" && return 0
  update_ytdlp
  yt-dlp "$@" && return 0
  warn "Пробую обходной режим (другой клиент YouTube — частый фикс 403)…"
  yt-dlp --extractor-args "youtube:player_client=tv,web,android,ios" "$@" && return 0
  return 1
}

# ──────────────────────────────── главный цикл ────────────────────────────────
total=${#URLS[@]}; n=0; ok=0
for url in "${URLS[@]}"; do
  n=$((n+1))
  info "[$n/$total] $url"

  # только звук → отдаём целиком yt-dlp
  if $AUDIO_ONLY; then
    if ytdlp_heal -x --audio-format mp3 --audio-quality 0 \
         -o "$OUTDIR/%(title)s [%(id)s].%(ext)s" "$url"; then
      ok=$((ok+1)); else err "не удалось скачать звук: $url"; fi
    continue
  fi

  # видео → во временную папку (любой кодек), потом транскод в OUTDIR
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/yt2prem.XXXXXX")"
  if ytdlp_heal -f "$DL_FMT" --merge-output-format mkv \
       -o "$WORK/%(title)s [%(id)s].%(ext)s" "$url"; then
    shopt -s nullglob
    got=false
    for f in "$WORK"/*.mkv "$WORK"/*.mp4 "$WORK"/*.webm "$WORK"/*.mov; do
      got=true
      transcode "$f"
      $KEEP && mv -n "$f" "$OUTDIR/"
    done
    shopt -u nullglob
    if $got; then ok=$((ok+1)); else err "файл не найден после загрузки: $url"; fi
  else
    err "Не удалось скачать даже после авто-обновления и обходных попыток: $url"
    warn "Если так со всеми видео → вручную: brew update && brew upgrade yt-dlp"
    warn "Если только с этим → видео может быть приватным/удалённым/региональным или требовать входа."
  fi
  rm -rf "$WORK"
done

echo >&2
info "Готово: $ok из $total.  Папка: $OUTDIR"
command -v open >/dev/null 2>&1 && [ "$ok" -gt 0 ] && [ -t 1 ] && open "$OUTDIR" || true
