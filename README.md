# yt2premiere

Скачивание видео с YouTube в максимальном качестве и конвертация в формат,
удобный для монтажа в **Adobe Premiere Pro**. Две версии — macOS и Windows.

## Что делает
- Качает лучшее доступное видео+звук (любой кодек: VP9 / AV1 / H.264).
- Конвертирует под монтаж:
  - **MP4 H.264** — по умолчанию, универсально;
  - **ProRes 422 HQ .mov** — лучший формат для монтажа (плавный таймлайн, без подвисаний);
  - **MP3** — только звук.
- Можно указывать **папку для скачивания**.
- **Самолечение**: при сбое (YouTube ломает раздачу, HTTP 403) сам обновляет
  yt-dlp и пробует другой клиент — повторять вручную не нужно.
- Аппаратное ускорение: macOS — VideoToolbox; Windows — NVIDIA/Intel/AMD, иначе libx264.

## Структура
```
yt2premiere/
├─ mac/
│  ├─ yt2premiere.sh                  ← ядро (команда `yt2premiere`)
│  └─ Скачать видео с YouTube.command ← двойной клик
└─ windows/
   ├─ yt2premiere.ps1                 ← ядро
   ├─ Скачать видео с YouTube.bat     ← двойной клик
   └─ ПРОЧТИ-МЕНЯ.txt
```

## macOS
Требуется: `brew install yt-dlp ffmpeg` (уже установлено).
Команда `yt2premiere` доступна из любого терминала (симлинк в `/opt/homebrew/bin`).

```bash
yt2premiere "https://youtu.be/XXXX"                 # MP4, макс. качество
yt2premiere --prores "https://youtu.be/XXXX"        # ProRes для монтажа
yt2premiere --out ~/Desktop/footage "ССЫЛКА"        # своя папка
yt2premiere --max 1080 url1 url2 url3               # пачкой, не выше 1080p
yt2premiere --mp3 "ССЫЛКА"                           # только звук
```
Либо двойной клик по `mac/Скачать видео с YouTube.command` — спросит ссылку, папку и формат.

Папка по умолчанию: `~/Movies/YouTube`.

## Windows (10/11, 64-бит)
Ничего ставить заранее не нужно — при первом запуске сам скачает
`yt-dlp.exe` и `ffmpeg.exe` в `windows\bin\`. Подробности — в `windows/ПРОЧТИ-МЕНЯ.txt`.

```powershell
.\yt2premiere.ps1 "https://youtu.be/XXXX"
.\yt2premiere.ps1 -Format prores -Out "D:\Footage" "ССЫЛКА"
.\yt2premiere.ps1 -Max 1080 url1 url2
.\yt2premiere.ps1 -Mp3 "ССЫЛКА"
```
Либо двойной клик по `windows/Скачать видео с YouTube.bat`.

Папка по умолчанию: `%USERPROFILE%\Videos\YouTube`.

## Битрейт MP4 (масштабируется по разрешению)
| Разрешение | Битрейт |
|-----------|---------|
| 2160p (4K)| 45 Мбит/с |
| 1440p     | 24 Мбит/с |
| 1080p     | 14 Мбит/с |
| 720p      | 8 Мбит/с  |
| ниже      | 5 Мбит/с  |

Для тяжёлого монтажа (особенно 4K) используй ProRes — он создан для таймлайна.
