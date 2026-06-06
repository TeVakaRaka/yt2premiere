# yt2premiere-gui.ps1 — графическое окно (WinForms) с очередью.
# Использует движок yt2premiere.ps1 (он сам ставит yt-dlp.exe/ffmpeg.exe).
# Запуск: через «Приложение yt2premiere.bat» (двойной клик).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Dir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$Engine     = Join-Path $Dir 'yt2premiere.ps1'
$DefaultOut = Join-Path $env:USERPROFILE 'Videos\YouTube'

$RES_TITLES = @('Макс. качество','2160p (4K)','1440p','1080p','720p','480p','360p')
$RES_VALUES = @(0,2160,1440,1080,720,480,360)
$FMT_TITLES = @('MP4 (H.264)','ProRes (.mov)','MP3 (звук)')
$FMT_KEYS   = @('mp4','prores','mp3')

# общее состояние между фоновым потоком и интерфейсом
$sync = [hashtable]::Synchronized(@{ st = @{}; cur = -1; done = $false; running = $false })
$script:queue     = New-Object System.Collections.ArrayList
$script:logFile   = Join-Path $env:TEMP ('yt2prem_gui_' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.log')
$script:logOffset = 0
$script:rs        = $null
$script:rsps      = $null

# ——— форма ———
$form = New-Object Windows.Forms.Form
$form.Text = 'yt2premiere — YouTube -> Premiere Pro'
$form.ClientSize = New-Object Drawing.Size(664,724)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

function Add-Label($text,$x,$y,$w,$bold = $false){
  $l = New-Object Windows.Forms.Label
  $l.Text = $text
  $l.Location = New-Object Drawing.Point($x,$y)
  $l.AutoSize = $false
  $l.Size = New-Object Drawing.Size($w,18)
  if ($bold){ $l.Font = New-Object Drawing.Font($l.Font,[Drawing.FontStyle]::Bold) }
  $form.Controls.Add($l)
  return $l
}

Add-Label 'Скачивание YouTube для монтажа — очередь' 12 10 624 $true | Out-Null

# 1. ссылка
Add-Label 'Ссылка на YouTube (можно несколько через пробел)' 12 40 624 $true | Out-Null
$urlBox = New-Object Windows.Forms.TextBox
$urlBox.Location = New-Object Drawing.Point(12,60)
$urlBox.Size = New-Object Drawing.Size(640,24)
$form.Controls.Add($urlBox)

# 2. качество + формат + добавить
$resBox = New-Object Windows.Forms.ComboBox
$resBox.DropDownStyle = 'DropDownList'
$resBox.Location = New-Object Drawing.Point(12,92)
$resBox.Size = New-Object Drawing.Size(180,24)
$resBox.Items.AddRange($RES_TITLES); $resBox.SelectedIndex = 0
$form.Controls.Add($resBox)

$fmtBox = New-Object Windows.Forms.ComboBox
$fmtBox.DropDownStyle = 'DropDownList'
$fmtBox.Location = New-Object Drawing.Point(202,92)
$fmtBox.Size = New-Object Drawing.Size(180,24)
$fmtBox.Items.AddRange($FMT_TITLES); $fmtBox.SelectedIndex = 0
$form.Controls.Add($fmtBox)

$addBtn = New-Object Windows.Forms.Button
$addBtn.Text = '＋ Добавить в очередь'
$addBtn.Location = New-Object Drawing.Point(392,90)
$addBtn.Size = New-Object Drawing.Size(260,28)
$form.Controls.Add($addBtn)

# 3. очередь
Add-Label 'Очередь' 12 126 624 $true | Out-Null
$lv = New-Object Windows.Forms.ListView
$lv.Location = New-Object Drawing.Point(12,148)
$lv.Size = New-Object Drawing.Size(640,200)
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.GridLines = $true
$lv.HideSelection = $false
[void]$lv.Columns.Add('Видео',300)
[void]$lv.Columns.Add('Качество',90)
[void]$lv.Columns.Add('Формат',80)
[void]$lv.Columns.Add('Статус',160)
$form.Controls.Add($lv)

$removeBtn = New-Object Windows.Forms.Button
$removeBtn.Text = '✕ Убрать выбранное'
$removeBtn.Location = New-Object Drawing.Point(12,356)
$removeBtn.Size = New-Object Drawing.Size(200,26)
$form.Controls.Add($removeBtn)

# 4. папка
Add-Label 'Папка для сохранения' 12 392 624 $true | Out-Null
$folderBox = New-Object Windows.Forms.TextBox
$folderBox.Location = New-Object Drawing.Point(12,412)
$folderBox.Size = New-Object Drawing.Size(490,24)
$folderBox.Text = $DefaultOut
$form.Controls.Add($folderBox)

$chooseBtn = New-Object Windows.Forms.Button
$chooseBtn.Text = 'Выбрать…'
$chooseBtn.Location = New-Object Drawing.Point(512,410)
$chooseBtn.Size = New-Object Drawing.Size(140,28)
$form.Controls.Add($chooseBtn)

# скачать
$dlBtn = New-Object Windows.Forms.Button
$dlBtn.Text = '⬇  Скачать всю очередь'
$dlBtn.Location = New-Object Drawing.Point(12,448)
$dlBtn.Size = New-Object Drawing.Size(640,40)
$dlBtn.Font = New-Object Drawing.Font($dlBtn.Font.FontFamily,11,[Drawing.FontStyle]::Bold)
$form.Controls.Add($dlBtn)

$statusLbl = Add-Label 'Готов к работе.' 12 496 640
$statusLbl.ForeColor = [Drawing.Color]::DimGray

# журнал
Add-Label 'Журнал' 12 522 624 $true | Out-Null
$logBox = New-Object Windows.Forms.TextBox
$logBox.Location = New-Object Drawing.Point(12,542)
$logBox.Size = New-Object Drawing.Size(640,170)
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Font = New-Object Drawing.Font('Consolas',9)
$form.Controls.Add($logBox)

# ——— функции ———
function Set-Running($r){
  $dlBtn.Enabled = -not $r
  $addBtn.Enabled = -not $r
  $removeBtn.Enabled = -not $r
}

function Start-Worker($out){
  $rs = [runspacefactory]::CreateRunspace()
  $rs.ApartmentState = 'MTA'
  $rs.Open()
  $rs.SessionStateProxy.SetVariable('sync',   $sync)
  $rs.SessionStateProxy.SetVariable('queue',  $script:queue)
  $rs.SessionStateProxy.SetVariable('engine', $Engine)
  $rs.SessionStateProxy.SetVariable('outdir', $out)
  $rs.SessionStateProxy.SetVariable('logfile',$script:logFile)
  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddScript({
    for ($i = 0; $i -lt $queue.Count; $i++){
      $sync.cur = $i; $sync.st[$i] = 'dl'
      $it = $queue[$i]
      Add-Content -LiteralPath $logfile -Value "`r`n──── [$($i+1)/$($queue.Count)] $($it.Url)" -Encoding UTF8
      $q = '"'
      $inner = "powershell -NoProfile -ExecutionPolicy Bypass -File $q$engine$q -Out $q$outdir$q"
      if ($it.Max -gt 0){ $inner += " -Max $($it.Max)" }
      if     ($it.Format -eq 'prores'){ $inner += ' -Format prores' }
      elseif ($it.Format -eq 'mp3')   { $inner += ' -Mp3' }
      $inner += " $q$($it.Url)$q 1>>$q$logfile$q 2>&1"
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = 'cmd.exe'
      $psi.Arguments = "/c $inner"
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      try {
        $p = [Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        $sync.st[$i] = $(if ($p.ExitCode -eq 0){'done'}else{'err'})
      } catch {
        $sync.st[$i] = 'err'
      }
    }
    $sync.cur = -1; $sync.done = $true
  })
  $script:rs = $rs
  $script:rsps = $ps
  [void]$ps.BeginInvoke()
}

# ——— события ———
$addBtn.Add_Click({
  $urls = $urlBox.Text -split '\s+' | Where-Object { $_ -like 'http*' }
  if (-not $urls){ $statusLbl.Text = '⚠ Вставьте ссылку (должна начинаться с http)'; return }
  $res = $RES_VALUES[$resBox.SelectedIndex]
  $fmt = $FMT_KEYS[$fmtBox.SelectedIndex]
  $resLbl = if ($res -eq 0){'Макс.'}else{"${res}p"}
  $fmtLbl = $FMT_TITLES[$fmtBox.SelectedIndex].Split(' ')[0]
  foreach ($u in $urls){
    [void]$script:queue.Add([pscustomobject]@{ Url = $u; Max = $res; Format = $fmt })
    $li = New-Object Windows.Forms.ListViewItem($u)
    [void]$li.SubItems.Add($resLbl)
    [void]$li.SubItems.Add($fmtLbl)
    [void]$li.SubItems.Add('⏳ Ожидает')
    [void]$lv.Items.Add($li)
  }
  $urlBox.Clear()
  $statusLbl.Text = "В очереди: $($script:queue.Count)"
})

$removeBtn.Add_Click({
  if ($sync.running){ return }
  $sel = @($lv.SelectedIndices) | Sort-Object -Descending
  foreach ($i in $sel){ $lv.Items.RemoveAt($i); $script:queue.RemoveAt($i) }
  $statusLbl.Text = "В очереди: $($script:queue.Count)"
})

$chooseBtn.Add_Click({
  $dlg = New-Object Windows.Forms.FolderBrowserDialog
  if ($folderBox.Text){ $dlg.SelectedPath = $folderBox.Text }
  if ($dlg.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){ $folderBox.Text = $dlg.SelectedPath }
})

$dlBtn.Add_Click({
  if ($sync.running){ return }
  if ($script:queue.Count -eq 0){ $statusLbl.Text = 'Очередь пуста — добавьте ссылки.'; return }
  $out = $folderBox.Text.Trim()
  if (-not $out){ $out = $DefaultOut; $folderBox.Text = $out }
  if (-not (Test-Path $Engine)){ $statusLbl.Text = "✖ Не найден движок: $Engine"; return }
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  for ($i = 0; $i -lt $lv.Items.Count; $i++){ $lv.Items[$i].SubItems[3].Text = '⏳ Ожидает' }
  $sync.st = @{}; $sync.cur = -1; $sync.done = $false; $sync.running = $true
  Remove-Item $script:logFile -ErrorAction SilentlyContinue
  $script:logOffset = 0; $logBox.Clear()
  Set-Running $true
  Start-Worker $out
  $timer.Start()
})

# ——— таймер: тянет лог из файла и обновляет статусы ———
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
  if (Test-Path $script:logFile){
    try {
      $fs = [IO.File]::Open($script:logFile,'Open','Read','ReadWrite')
      [void]$fs.Seek($script:logOffset,'Begin')
      $sr = New-Object IO.StreamReader($fs,[Text.Encoding]::UTF8)
      $new = $sr.ReadToEnd()
      $script:logOffset = $fs.Position
      $sr.Close(); $fs.Close()
      if ($new){
        foreach ($ln in ($new -split "\r\n|\r|\n")){
          if ($ln -match '^\s*$'){ continue }
          if ($ln -match '\d+\.\d+%'){ continue }   # промежуточный прогресс в %
          if ($ln -match '^frame='){ continue }      # прогресс ffmpeg
          $logBox.AppendText($ln + "`r`n")
        }
      }
    } catch { }
  }
  for ($i = 0; $i -lt $lv.Items.Count; $i++){
    switch ($sync.st[$i]){
      'dl'   { $lv.Items[$i].SubItems[3].Text = '⬇ Скачивание…' }
      'done' { $lv.Items[$i].SubItems[3].Text = '✅ Готово' }
      'err'  { $lv.Items[$i].SubItems[3].Text = '✖ Ошибка' }
    }
  }
  if ($sync.cur -ge 0){ $statusLbl.Text = "Скачивание $($sync.cur + 1)/$($script:queue.Count)…" }
  if ($sync.done){
    $timer.Stop()
    $sync.running = $false
    Set-Running $false
    $ok = 0
    foreach ($k in $sync.st.Keys){ if ($sync.st[$k] -eq 'done'){ $ok++ } }
    $statusLbl.Text = "✅ Завершено: $ok из $($script:queue.Count). Папка открыта."
    try { Start-Process explorer.exe $folderBox.Text } catch { }
    if ($script:rsps){ try { $script:rsps.Dispose(); $script:rs.Close() } catch { } }
  }
})

[void]$form.ShowDialog()
Remove-Item $script:logFile -ErrorAction SilentlyContinue
