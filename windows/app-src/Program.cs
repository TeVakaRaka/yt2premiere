using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace YT2Premiere
{
    class QueueItem
    {
        public string Url = "";
        public int MaxRes;       // 0 = макс
        public string Format = "mp4"; // mp4 | prores | mp3
    }

    static class Tools
    {
        public static readonly string BinDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "yt2premiere", "bin");
        public static string YtDlp { get { return Path.Combine(BinDir, "yt-dlp.exe"); } }
        public static string Ffmpeg { get { return Path.Combine(BinDir, "ffmpeg.exe"); } }
        public static string Ffprobe { get { return Path.Combine(BinDir, "ffprobe.exe"); } }

        public static void Ensure(Action<string> log)
        {
            Directory.CreateDirectory(BinDir);
            using (var http = new HttpClient())
            {
                http.Timeout = TimeSpan.FromMinutes(15);
                if (!File.Exists(YtDlp))
                {
                    log("Скачиваю yt-dlp.exe (разово)…");
                    var d = http.GetByteArrayAsync("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe").GetAwaiter().GetResult();
                    File.WriteAllBytes(YtDlp, d);
                }
                if (!File.Exists(Ffmpeg) || !File.Exists(Ffprobe))
                {
                    log("Скачиваю ffmpeg (~80 МБ, разово)…");
                    string zip = Path.Combine(Path.GetTempPath(), "yt2prem_ffmpeg.zip");
                    var d = http.GetByteArrayAsync("https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip").GetAwaiter().GetResult();
                    File.WriteAllBytes(zip, d);
                    string ext = Path.Combine(Path.GetTempPath(), "yt2prem_ffmpeg");
                    if (Directory.Exists(ext)) Directory.Delete(ext, true);
                    System.IO.Compression.ZipFile.ExtractToDirectory(zip, ext);
                    foreach (var n in new[] { "ffmpeg.exe", "ffprobe.exe" })
                    {
                        var f = Directory.GetFiles(ext, n, SearchOption.AllDirectories).FirstOrDefault();
                        if (f != null) File.Copy(f, Path.Combine(BinDir, n), true);
                    }
                    try { File.Delete(zip); Directory.Delete(ext, true); } catch { }
                }
            }
        }
    }

    class MainForm : Form
    {
        static readonly string[] RES_TITLES = { "Макс. качество", "2160p (4K)", "1440p", "1080p", "720p", "480p", "360p" };
        static readonly int[] RES_VALUES = { 0, 2160, 1440, 1080, 720, 480, 360 };
        static readonly string[] FMT_TITLES = { "MP4 (H.264)", "ProRes (.mov)", "MP3 (звук)" };
        static readonly string[] FMT_KEYS = { "mp4", "prores", "mp3" };
        static readonly string DefaultOut = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Videos", "YouTube");

        TextBox urlBox, folderBox, logBox;
        ComboBox resBox, fmtBox;
        Button addBtn, removeBtn, chooseBtn, dlBtn;
        ListView lv;
        Label statusLbl;
        readonly List<QueueItem> queue = new List<QueueItem>();
        bool updatedYtDlp = false;
        string cachedEnc = null;

        public MainForm()
        {
            Text = "yt2premiere — YouTube → Premiere Pro";
            ClientSize = new Size(664, 724);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9F);
            BuildUI();
        }

        Label L(string t, int x, int y, int w, bool bold = false)
        {
            var l = new Label { Text = t, Location = new Point(x, y), Size = new Size(w, 18) };
            if (bold) l.Font = new Font(Font, FontStyle.Bold);
            Controls.Add(l);
            return l;
        }

        void BuildUI()
        {
            L("Скачивание YouTube для монтажа — очередь", 12, 10, 640, true);
            L("Ссылка на YouTube (можно несколько через пробел)", 12, 40, 640, true);
            urlBox = new TextBox { Location = new Point(12, 60), Size = new Size(640, 24) };
            Controls.Add(urlBox);

            resBox = new ComboBox { Location = new Point(12, 92), Size = new Size(180, 24), DropDownStyle = ComboBoxStyle.DropDownList };
            resBox.Items.AddRange(RES_TITLES); resBox.SelectedIndex = 0; Controls.Add(resBox);
            fmtBox = new ComboBox { Location = new Point(202, 92), Size = new Size(180, 24), DropDownStyle = ComboBoxStyle.DropDownList };
            fmtBox.Items.AddRange(FMT_TITLES); fmtBox.SelectedIndex = 0; Controls.Add(fmtBox);
            addBtn = new Button { Text = "＋ Добавить в очередь", Location = new Point(392, 90), Size = new Size(260, 28) };
            addBtn.Click += Add_Click; Controls.Add(addBtn);

            L("Очередь", 12, 126, 640, true);
            lv = new ListView { Location = new Point(12, 148), Size = new Size(640, 200), View = View.Details, FullRowSelect = true, GridLines = true, HideSelection = false };
            lv.Columns.Add("Видео", 300); lv.Columns.Add("Качество", 90); lv.Columns.Add("Формат", 80); lv.Columns.Add("Статус", 160);
            Controls.Add(lv);
            removeBtn = new Button { Text = "✕ Убрать выбранное", Location = new Point(12, 356), Size = new Size(200, 26) };
            removeBtn.Click += Remove_Click; Controls.Add(removeBtn);

            L("Папка для сохранения", 12, 392, 640, true);
            folderBox = new TextBox { Location = new Point(12, 412), Size = new Size(490, 24), Text = DefaultOut };
            Controls.Add(folderBox);
            chooseBtn = new Button { Text = "Выбрать…", Location = new Point(512, 410), Size = new Size(140, 28) };
            chooseBtn.Click += Choose_Click; Controls.Add(chooseBtn);

            dlBtn = new Button { Text = "⬇  Скачать всю очередь", Location = new Point(12, 448), Size = new Size(640, 40) };
            dlBtn.Font = new Font(Font.FontFamily, 11F, FontStyle.Bold);
            dlBtn.Click += Download_Click; Controls.Add(dlBtn);

            statusLbl = L("Готов к работе.", 12, 496, 640);
            statusLbl.ForeColor = Color.DimGray;

            L("Журнал", 12, 522, 640, true);
            logBox = new TextBox { Location = new Point(12, 542), Size = new Size(640, 170), Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Font = new Font("Consolas", 9F) };
            Controls.Add(logBox);
        }

        void Ui(Action a) { if (!IsHandleCreated) return; if (InvokeRequired) BeginInvoke(a); else a(); }
        void SetStatus(string s) { statusLbl.Text = s; }
        void AppendLog(string s)
        {
            if (string.IsNullOrWhiteSpace(s)) return;
            if (Regex.IsMatch(s, @"\d+\.\d+%")) return;   // прогресс в процентах
            if (s.StartsWith("frame=")) return;            // прогресс ffmpeg
            logBox.AppendText(s + "\r\n");
        }
        void SetItemStatus(int i, string s) { if (i >= 0 && i < lv.Items.Count) lv.Items[i].SubItems[3].Text = s; }
        void SetRunning(bool r) { dlBtn.Enabled = !r; addBtn.Enabled = !r; removeBtn.Enabled = !r; }

        void Add_Click(object sender, EventArgs e)
        {
            var urls = urlBox.Text.Split(new[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                                  .Where(u => u.StartsWith("http")).ToList();
            if (urls.Count == 0) { SetStatus("⚠ Вставьте ссылку (должна начинаться с http)"); return; }
            int res = RES_VALUES[resBox.SelectedIndex];
            string fmt = FMT_KEYS[fmtBox.SelectedIndex];
            string resLbl = res == 0 ? "Макс." : res + "p";
            string fmtLbl = FMT_TITLES[fmtBox.SelectedIndex].Split(' ')[0];
            foreach (var u in urls)
            {
                queue.Add(new QueueItem { Url = u, MaxRes = res, Format = fmt });
                var li = new ListViewItem(u);
                li.SubItems.Add(resLbl); li.SubItems.Add(fmtLbl); li.SubItems.Add("⏳ Ожидает");
                lv.Items.Add(li);
            }
            urlBox.Clear();
            SetStatus("В очереди: " + queue.Count);
        }

        void Remove_Click(object sender, EventArgs e)
        {
            var idxs = lv.SelectedIndices.Cast<int>().OrderByDescending(x => x).ToList();
            foreach (var i in idxs) { lv.Items.RemoveAt(i); queue.RemoveAt(i); }
            SetStatus("В очереди: " + queue.Count);
        }

        void Choose_Click(object sender, EventArgs e)
        {
            using (var d = new FolderBrowserDialog())
            {
                if (Directory.Exists(folderBox.Text)) d.SelectedPath = folderBox.Text;
                if (d.ShowDialog() == DialogResult.OK) folderBox.Text = d.SelectedPath;
            }
        }

        async void Download_Click(object sender, EventArgs e)
        {
            if (queue.Count == 0) { SetStatus("Очередь пуста — добавьте ссылки."); return; }
            string outDir = folderBox.Text.Trim();
            if (outDir == "") { outDir = DefaultOut; folderBox.Text = outDir; }
            try { Directory.CreateDirectory(outDir); } catch { }
            for (int i = 0; i < lv.Items.Count; i++) SetItemStatus(i, "⏳ Ожидает");
            logBox.Clear(); SetRunning(true); updatedYtDlp = false;

            await Task.Run(() =>
            {
                try { Ui(() => SetStatus("Подготовка инструментов…")); Tools.Ensure(x => Ui(() => AppendLog(x))); }
                catch (Exception ex)
                {
                    Ui(() => { AppendLog("✖ Не удалось скачать инструменты: " + ex.Message); SetStatus("✖ Ошибка"); SetRunning(false); });
                    return;
                }
                int ok = 0;
                for (int i = 0; i < queue.Count; i++)
                {
                    int idx = i; var it = queue[i];
                    Ui(() =>
                    {
                        SetItemStatus(idx, "⬇ Скачивание…");
                        SetStatus("Скачивание " + (idx + 1) + "/" + queue.Count + "…");
                        AppendLog("──── [" + (idx + 1) + "/" + queue.Count + "] " + it.Url);
                    });
                    bool good = false;
                    try { good = ProcessItem(it, outDir, x => Ui(() => AppendLog(x))); }
                    catch (Exception ex) { Ui(() => AppendLog("✖ " + ex.Message)); }
                    if (good) ok++;
                    int fi = idx; bool fg = good;
                    Ui(() => SetItemStatus(fi, fg ? "✅ Готово" : "✖ Ошибка"));
                }
                int okF = ok;
                Ui(() =>
                {
                    SetRunning(false);
                    SetStatus("✅ Завершено: " + okF + " из " + queue.Count + ". Папка открыта.");
                    try { Process.Start("explorer.exe", outDir); } catch { }
                });
            });
        }

        // ——— движок ———
        string Q(string s) { return "\"" + s + "\""; }

        int Run(string exe, string args, Action<string> onLine)
        {
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = args,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            using (var p = new Process { StartInfo = psi })
            {
                p.OutputDataReceived += (o, ev) => { if (ev.Data != null) onLine(ev.Data); };
                p.ErrorDataReceived += (o, ev) => { if (ev.Data != null) onLine(ev.Data); };
                p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine(); p.WaitForExit();
                return p.ExitCode;
            }
        }

        bool Heal(string args, Action<string> log)
        {
            if (Run(Tools.YtDlp, args, log) == 0) return true;
            log("Сбой загрузки — повтор…"); Thread.Sleep(3000);
            if (Run(Tools.YtDlp, args, log) == 0) return true;
            if (!updatedYtDlp) { updatedYtDlp = true; log("Обновляю yt-dlp…"); Run(Tools.YtDlp, "-U", log); }
            if (Run(Tools.YtDlp, args, log) == 0) return true;
            log("Обходной режим (смена клиента YouTube)…");
            return Run(Tools.YtDlp, "--extractor-args \"youtube:player_client=tv,web,android,ios\" " + args, log) == 0;
        }

        bool ProcessItem(QueueItem it, string outDir, Action<string> log)
        {
            string ff = Q(Tools.BinDir);
            if (it.Format == "mp3")
            {
                string a = "-x --audio-format mp3 --audio-quality 0 --ffmpeg-location " + ff +
                           " -o " + Q(Path.Combine(outDir, "%(title)s [%(id)s].%(ext)s")) + " " + Q(it.Url);
                return Heal(a, log);
            }
            string fmt = it.MaxRes > 0
                ? "bv*[height<=" + it.MaxRes + "]+ba/b[height<=" + it.MaxRes + "]/bv*+ba/b"
                : "bv*+ba/b";
            string work = Path.Combine(Path.GetTempPath(), "yt2prem_" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Directory.CreateDirectory(work);
            try
            {
                string dl = "-f " + Q(fmt) + " --merge-output-format mkv --ffmpeg-location " + ff +
                            " -o " + Q(Path.Combine(work, "%(title)s [%(id)s].%(ext)s")) + " " + Q(it.Url);
                if (!Heal(dl, log)) return false;
                var files = Directory.GetFiles(work).Where(f =>
                    f.EndsWith(".mkv") || f.EndsWith(".mp4") || f.EndsWith(".webm") || f.EndsWith(".mov")).ToList();
                if (files.Count == 0) return false;
                foreach (var f in files) Transcode(f, outDir, it, log);
                return true;
            }
            finally { try { Directory.Delete(work, true); } catch { } }
        }

        int Probe(string src)
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = Tools.Ffprobe,
                    Arguments = "-v error -select_streams v:0 -show_entries stream=height -of csv=p=0 " + Q(src),
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8
                };
                using (var p = Process.Start(psi))
                {
                    string o = p.StandardOutput.ReadToEnd(); p.WaitForExit();
                    string t = o.Split('\n')[0].Trim();
                    int h; return int.TryParse(t, out h) ? h : 1080;
                }
            }
            catch { return 1080; }
        }

        string Enc()
        {
            if (cachedEnc != null) return cachedEnc;
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = Tools.Ffmpeg,
                    Arguments = "-hide_banner -encoders",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8
                };
                using (var p = Process.Start(psi))
                {
                    string o = p.StandardOutput.ReadToEnd(); p.WaitForExit();
                    foreach (var en in new[] { "h264_nvenc", "h264_qsv", "h264_amf" })
                        if (o.Contains(en)) { cachedEnc = en; return en; }
                }
            }
            catch { }
            cachedEnc = "libx264"; return cachedEnc;
        }

        void Transcode(string src, string outDir, QueueItem it, Action<string> log)
        {
            int h = Probe(src);
            string bn = Path.GetFileNameWithoutExtension(src);
            if (it.Format == "prores")
            {
                string o = Path.Combine(outDir, bn + ".mov");
                log("ProRes 422 HQ (" + h + "p) → " + Path.GetFileName(o));
                Run(Tools.Ffmpeg, "-y -hide_banner -loglevel warning -stats -i " + Q(src) +
                    " -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -vendor apl0 -c:a pcm_s16le " + Q(o), log);
            }
            else
            {
                string vb = h >= 2160 ? "45M" : h >= 1440 ? "24M" : h >= 1080 ? "14M" : h >= 720 ? "8M" : "5M";
                string venc = Enc();
                string o = Path.Combine(outDir, bn + ".mp4");
                log("MP4 H.264 / " + venc + " (" + h + "p, " + vb + ") → " + Path.GetFileName(o));
                Run(Tools.Ffmpeg, "-y -hide_banner -loglevel warning -stats -i " + Q(src) +
                    " -c:v " + venc + " -b:v " + vb + " -pix_fmt yuv420p -c:a aac -b:a 320k -movflags +faststart " + Q(o), log);
            }
        }
    }

    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.SetHighDpiMode(HighDpiMode.SystemAware);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }
}
