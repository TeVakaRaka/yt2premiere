<#
  yt2premiere.ps1  —  скачать видео с YouTube в максимальном качестве
  и сконвертировать в формат для монтажа в Adobe Premiere Pro (Windows).

    * по умолчанию    : H.264 .mp4  (универсально, открывается везде)
    * -Format prores  : Apple ProRes 422 HQ .mov  (лучший формат для монтажа)
    * -Mp3            : только звук -> mp3

  При первом запуске сам скачает yt-dlp.exe и ffmpeg.exe в подпапку bin\.
  Аппаратное ускорение: автоматически NVIDIA (nvenc) / Intel (qsv) / AMD (amf),
  иначе программный libx264.

  Примеры:
    .\yt2premiere.ps1 "https://youtu.be/XXXX"
    .\yt2premiere.ps1 -Format prores -Out "D:\Footage" "https://youtu.be/XXXX"
    .\yt2premiere.ps1 -Max 1080 url1 url2 url3
    .\yt2premiere.ps1 -Mp3 "https://youtu.be/XXXX"
#>
[CmdletBinding()]
param(
  [string]$Out = (Join-Path $env:USERPROFILE 'Videos\YouTube'),
  [ValidateSet('mp4','prores')][string]$Format = 'mp4',
  [int]$Max = 0,
  [switch]$Mp3,
  [switch]$Keep,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Urls
)

# быстрые загрузки в Windows PowerShell 5.1 (иначе IWR тормозит из-за прогресс-бара)
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Info($m){ Write-Host ">> $m" -ForegroundColor Green }
function Warn($m){ Write-Host " ! $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host " x $m" -ForegroundColor Red }

$Root = $PSScriptRoot
$Bin  = Join-Path $Root 'bin'

# ── интерактивный режим, если ссылок не передали (запуск через .bat двойным кликом) ──
if (-not $Urls -or $Urls.Count -eq 0) {
  Write-Host ""
  Write-Host "  YouTube -> Premiere Pro" -ForegroundColor Cyan
  Write-Host "  скачать в макс. качестве и конвертировать" -ForegroundColor Cyan
  Write-Host ""
  $line = Read-Host "1) Ссылка(и) на YouTube (несколько через пробел)"
  $Urls = $line -split '\s+' | Where-Object { $_ }
  if (-not $Urls) { Warn "Ссылка не введена."; Start-Sleep 1; return }
  $o = Read-Host "2) Папка для скачивания (Enter = $Out)"
  if ($o) { $Out = $o.Trim().Trim('"') }
  $f = Read-Host "3) Формат: 1=MP4  2=ProRes(для монтажа)  3=MP3  [1]"
  switch ($f) { '2' { $Format = 'prores' } '3' { $Mp3 = $true } }
  Write-Host ""
}

# на случай, если несколько ссылок пришли одной строкой
$Urls = $Urls | ForEach-Object { $_ -split '\s+' } | Where-Object { $_ }

# ── поиск инструментов: сначала bin\, потом PATH ──
function Resolve-Tool($name) {
  $local = Join-Path $Bin $name
  if (Test-Path $local) { return $local }
  $c = Get-Command $name -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return $null
}

# ── автозагрузка yt-dlp.exe и ffmpeg.exe при первом запуске ──
function Ensure-Tools {
  New-Item -ItemType Directory -Force -Path $Bin | Out-Null
  if (-not (Resolve-Tool 'yt-dlp.exe')) {
    Info "Скачиваю yt-dlp.exe (разово)..."
    Invoke-WebRequest -UseBasicParsing -ErrorAction Stop `
      -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' `
      -OutFile (Join-Path $Bin 'yt-dlp.exe')
  }
  if (-not (Resolve-Tool 'ffmpeg.exe') -or -not (Resolve-Tool 'ffprobe.exe')) {
    Info "Скачиваю ffmpeg (разово, ~80 МБ)..."
    $zip = Join-Path $env:TEMP 'yt2prem_ffmpeg.zip'
    $ext = Join-Path $env:TEMP 'yt2prem_ffmpeg'
    Invoke-WebRequest -UseBasicParsing -ErrorAction Stop `
      -Uri 'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip' `
      -OutFile $zip
    if (Test-Path $ext) { Remove-Item $ext -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $ext -Force -ErrorAction Stop
    foreach ($t in 'ffmpeg.exe','ffprobe.exe') {
      $found = Get-ChildItem -Path $ext -Recurse -Filter $t | Select-Object -First 1
      if ($found) { Copy-Item $found.FullName (Join-Path $Bin $t) -Force }
    }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue
  }
}

try {
  Ensure-Tools
} catch {
  Fail "Не удалось скачать инструменты: $($_.Exception.Message)"
  Fail "Проверь интернет-соединение и запусти снова."
  return
}

$YTDLP   = Resolve-Tool 'yt-dlp.exe'
$FFMPEG  = Resolve-Tool 'ffmpeg.exe'
$FFPROBE = Resolve-Tool 'ffprobe.exe'
$FFDIR   = Split-Path $FFMPEG

New-Item -ItemType Directory -Force -Path $Out | Out-Null

# ── выбор H.264-кодировщика: аппаратный если есть, иначе программный ──
function Get-H264Encoder {
  $list = & $FFMPEG -hide_banner -encoders 2>$null
  foreach ($e in 'h264_nvenc','h264_qsv','h264_amf') {
    if ($list -match $e) { return $e }
  }
  return 'libx264'
}
$H264 = Get-H264Encoder

# ── строка качества для yt-dlp ──
$Fmt = if ($Max -gt 0) { "bv*[height<=$Max]+ba/b[height<=$Max]/bv*+ba/b" } else { "bv*+ba/b" }

# ── самолечение yt-dlp (обновление + смена клиента YouTube) ──
$script:Updated = $false
function Update-Ytdlp {
  if ($script:Updated) { return }
  $script:Updated = $true
  Warn "Обновляю yt-dlp..."
  & $YTDLP -U 2>$null | Out-Null
}
function Invoke-Heal([string[]]$a) {
  $a = @('--ffmpeg-location', $FFDIR) + $a
  & $YTDLP @a; if ($LASTEXITCODE -eq 0) { return $true }
  Warn "Сбой загрузки — повторяю через пару секунд..."; Start-Sleep 3
  & $YTDLP @a; if ($LASTEXITCODE -eq 0) { return $true }
  Update-Ytdlp
  & $YTDLP @a; if ($LASTEXITCODE -eq 0) { return $true }
  Warn "Обходной режим (другой клиент YouTube — частый фикс 403)..."
  & $YTDLP '--extractor-args' 'youtube:player_client=tv,web,android,ios' @a
  return ($LASTEXITCODE -eq 0)
}

# ── транскод одного файла под Premiere ──
function Convert-One([string]$src) {
  $base = [IO.Path]::GetFileNameWithoutExtension($src)
  $h = (& $FFPROBE -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$src" 2>$null | Select-Object -First 1)
  if (-not $h) { $h = 1080 } else { $h = [int]$h }

  if ($Format -eq 'prores') {
    $out = Join-Path $Out "$base.mov"
    Info "ProRes 422 HQ (${h}p) -> $([IO.Path]::GetFileName($out))"
    & $FFMPEG -y -hide_banner -loglevel warning -stats -i "$src" `
      -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -vendor apl0 `
      -c:a pcm_s16le "$out"
  } else {
    $vb = if     ($h -ge 2160) { '45M' }
          elseif ($h -ge 1440) { '24M' }
          elseif ($h -ge 1080) { '14M' }
          elseif ($h -ge 720)  { '8M'  }
          else                 { '5M'  }
    $out = Join-Path $Out "$base.mp4"
    Info "MP4 H.264 / $H264 (${h}p, $vb) -> $([IO.Path]::GetFileName($out))"
    & $FFMPEG -y -hide_banner -loglevel warning -stats -i "$src" `
      -c:v $H264 -b:v $vb -pix_fmt yuv420p `
      -c:a aac -b:a 320k -movflags +faststart "$out"
  }
}

# ── главный цикл ──
$total = $Urls.Count; $n = 0; $ok = 0
foreach ($url in $Urls) {
  $n++; Info "[$n/$total] $url"

  if ($Mp3) {
    $tpl = Join-Path $Out '%(title)s [%(id)s].%(ext)s'
    if (Invoke-Heal @('-x','--audio-format','mp3','--audio-quality','0','-o',$tpl,$url)) { $ok++ }
    else { Fail "Не удалось скачать звук: $url" }
    continue
  }

  $work = Join-Path $env:TEMP ('yt2prem_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $tpl = Join-Path $work '%(title)s [%(id)s].%(ext)s'

  if (Invoke-Heal @('-f',$Fmt,'--merge-output-format','mkv','-o',$tpl,$url)) {
    $files = Get-ChildItem -Path $work -Recurse -Include *.mkv,*.mp4,*.webm,*.mov
    if ($files) {
      foreach ($f in $files) {
        Convert-One $f.FullName
        if ($Keep) { Move-Item $f.FullName $Out -Force }
      }
      $ok++
    } else { Fail "Файл не найден после загрузки: $url" }
  } else {
    Fail "Не удалось скачать даже после авто-обновления: $url"
    Warn "Видео может быть приватным/удалённым/региональным или требовать входа."
  }
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Info "Готово: $ok из $total.  Папка: $Out"
if ($ok -gt 0) { try { Start-Process explorer.exe $Out } catch {} }
