// WinUtils Disk Cleaner - native scan engine.
// Compiled at runtime by Add-Type (C# 5 / .NET Framework 4.x). Avoid C# 6+ syntax.
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace WinUtils
{
    public static class Fmt
    {
        private static readonly string[] Units = new string[] { "B", "KB", "MB", "GB", "TB", "PB" };

        public static string Bytes(long value)
        {
            if (value < 0) return "-";
            double d = value;
            int i = 0;
            while (d >= 1024.0 && i < Units.Length - 1) { d /= 1024.0; i++; }
            string n = (i == 0) ? d.ToString("0") : d.ToString("0.##");
            return n + " " + Units[i];
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct WIN32_FIND_DATA
    {
        public uint dwFileAttributes;
        public uint ftCreationTimeLow;
        public uint ftCreationTimeHigh;
        public uint ftLastAccessTimeLow;
        public uint ftLastAccessTimeHigh;
        public uint ftLastWriteTimeLow;
        public uint ftLastWriteTimeHigh;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint dwReserved0;
        public uint dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
        public string cAlternateFileName;
    }

    internal sealed class SafeFindHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal SafeFindHandle() : base(true) { }
        protected override bool ReleaseHandle() { return NativeMethods.FindClose(handle); }
    }

    internal static class NativeMethods
    {
        internal const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
        internal const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
        internal const int FindExInfoBasic = 1;
        internal const int FindExSearchNameMatch = 0;
        internal const int FIND_FIRST_EX_LARGE_FETCH = 2;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeFindHandle FindFirstFileExW(
            string lpFileName, int fInfoLevelId, out WIN32_FIND_DATA lpFindFileData,
            int fSearchOp, IntPtr lpSearchFilter, int dwAdditionalFlags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool FindNextFileW(SafeFindHandle hFindFile, out WIN32_FIND_DATA lpFindFileData);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool FindClose(IntPtr hFindFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool DeleteFileW(string lpFileName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool RemoveDirectoryW(string lpPathName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetFileAttributesW(string lpFileName, uint dwFileAttributes);

        internal const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct SHFILEOPSTRUCTW
        {
            public IntPtr hwnd;
            public uint wFunc;
            public IntPtr pFrom;
            public IntPtr pTo;
            public ushort fFlags;
            [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
            public IntPtr hNameMappings;
            public IntPtr lpszProgressTitle;
        }

        internal const uint FO_DELETE = 0x0003;
        internal const ushort FOF_SILENT = 0x0004;
        internal const ushort FOF_NOCONFIRMATION = 0x0010;
        internal const ushort FOF_ALLOWUNDO = 0x0040;
        internal const ushort FOF_NOERRORUI = 0x0400;
        internal const ushort FOF_NOCONFIRMMKDIR = 0x0200;

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        internal static extern int SHFileOperationW(ref SHFILEOPSTRUCTW lpFileOp);
    }

    internal static class PathUtil
    {
        // Win32 wide APIs need the \\?\ prefix to go beyond MAX_PATH.
        public static string Extended(string path)
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) return path;
            if (path.StartsWith(@"\\", StringComparison.Ordinal)) return @"\\?\UNC\" + path.Substring(2);
            return @"\\?\" + path;
        }

        public static string Join(string dir, string leaf)
        {
            if (dir.EndsWith(@"\", StringComparison.Ordinal)) return dir + leaf;
            return dir + @"\" + leaf;
        }

        public static string SearchPattern(string dir, string pattern)
        {
            return Extended(Join(dir, pattern));
        }

        public static bool HasWildcard(string s)
        {
            return s.IndexOf('*') >= 0 || s.IndexOf('?') >= 0;
        }

        public static string LeafOf(string path)
        {
            string p = path.TrimEnd('\\');
            int i = p.LastIndexOf('\\');
            return i < 0 ? p : p.Substring(i + 1);
        }

        public static string ParentOf(string path)
        {
            string p = path.TrimEnd('\\');
            int i = p.LastIndexOf('\\');
            return i < 0 ? p : p.Substring(0, i + 1);
        }

        public static DateTime ToDateTime(uint high, uint low)
        {
            try
            {
                long ft = ((long)high << 32) | (long)low;
                if (ft <= 0) return DateTime.MinValue;
                return DateTime.FromFileTimeUtc(ft).ToLocalTime();
            }
            catch { return DateTime.MinValue; }
        }
    }

    /// <summary>A folder in the scanned tree. Bound directly by the WPF TreeView.</summary>
    public class DirNode : INotifyPropertyChanged
    {
        public string Name { get; set; }
        public string FullPath { get; set; }
        public long Size { get; set; }
        public long OwnSize { get; set; }
        public long FileCount { get; set; }
        public long FolderCount { get; set; }
        public bool AccessDenied { get; set; }
        public bool IsFilesBucket { get; set; }
        public double PercentOfParent { get; set; }
        public DirNode Parent { get; set; }
        public ObservableCollection<DirNode> Children { get; set; }

        public DirNode()
        {
            Children = new ObservableCollection<DirNode>();
        }

        public string SizeText { get { return Fmt.Bytes(Size); } }
        public string PercentText { get { return PercentOfParent.ToString("0.0") + "%"; } }
        public double BarWidth { get { return Math.Max(1.0, Math.Min(100.0, PercentOfParent)) * 1.1; } }

        public string Detail
        {
            get
            {
                if (IsFilesBucket) return FileCount.ToString("N0") + " files";
                string s = FileCount.ToString("N0") + " files, " + FolderCount.ToString("N0") + " folders";
                if (AccessDenied) s += "  (access denied)";
                return s;
            }
        }

        /// <summary>Propagate a size change up the tree after a deletion, refreshing bound rows.</summary>
        public void ApplyDelta(long deltaBytes, long deltaFiles)
        {
            DirNode n = this;
            while (n != null)
            {
                n.Size += deltaBytes;
                n.FileCount += deltaFiles;
                if (n.Size < 0) n.Size = 0;
                if (n.FileCount < 0) n.FileCount = 0;
                n.RecomputePercentages();
                n.Refresh();
                n = n.Parent;
            }
        }

        public void RecomputePercentages()
        {
            if (Children == null) return;
            foreach (DirNode c in Children)
            {
                c.PercentOfParent = (Size > 0) ? (c.Size * 100.0 / Size) : 0.0;
                c.Refresh();
            }
        }

        public void Refresh()
        {
            Raise("SizeText");
            Raise("PercentText");
            Raise("BarWidth");
            Raise("Detail");
        }

        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise(string p)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(p));
        }
    }

    public class FileEntry
    {
        public string Name { get; set; }
        public string FullPath { get; set; }
        public string Folder { get; set; }
        public long Size { get; set; }
        public DateTime Modified { get; set; }

        public string SizeText { get { return Fmt.Bytes(Size); } }
        public string ModifiedText
        {
            get { return Modified == DateTime.MinValue ? "" : Modified.ToString("yyyy-MM-dd"); }
        }
        public string Extension
        {
            get
            {
                int i = Name.LastIndexOf('.');
                return (i > 0 && i < Name.Length - 1) ? Name.Substring(i + 1).ToLowerInvariant() : "";
            }
        }
    }

    /// <summary>
    /// Parallel recursive directory scanner built on FindFirstFileEx. Runs on a background
    /// task so the WPF dispatcher can poll counters for live progress.
    /// </summary>
    public class Scanner
    {
        private long _dirs;
        private long _files;
        private long _bytes;
        private long _denied;
        private volatile string _current = "";
        private volatile bool _cancel;
        private Task<DirNode> _task;

        public long LargeFileThreshold { get; set; }
        public int MaxLargeFiles { get; set; }
        public int ParallelDepth { get; set; }
        public ConcurrentBag<FileEntry> LargeFiles { get; private set; }
        public string Root { get; private set; }
        public Exception Error { get; private set; }

        public Scanner()
        {
            LargeFileThreshold = 100L * 1024 * 1024;
            MaxLargeFiles = 5000;
            ParallelDepth = 2;
            LargeFiles = new ConcurrentBag<FileEntry>();
        }

        public long DirsScanned { get { return Interlocked.Read(ref _dirs); } }
        public long FilesScanned { get { return Interlocked.Read(ref _files); } }
        public long BytesScanned { get { return Interlocked.Read(ref _bytes); } }
        public long DeniedCount { get { return Interlocked.Read(ref _denied); } }
        public string CurrentPath { get { return _current; } }
        public bool IsRunning { get { return _task != null && !_task.IsCompleted; } }
        public bool IsCancelled { get { return _cancel; } }

        public DirNode Result
        {
            get
            {
                if (_task == null || !_task.IsCompleted) return null;
                if (_task.IsFaulted) return null;
                return _task.Result;
            }
        }

        public void Cancel() { _cancel = true; }

        public void Start(string root)
        {
            Root = NormalizeRoot(root);
            _cancel = false;
            _dirs = 0; _files = 0; _bytes = 0; _denied = 0;
            _current = Root;
            Error = null;
            LargeFiles = new ConcurrentBag<FileEntry>();

            string target = Root;
            _task = Task.Factory.StartNew<DirNode>(delegate
            {
                try
                {
                    DirNode root2 = ScanDir(target, DisplayNameFor(target), null, 0);
                    root2.PercentOfParent = 100.0;
                    return root2;
                }
                catch (Exception ex)
                {
                    Error = ex;
                    return null;
                }
            }, TaskCreationOptions.LongRunning);
        }

        private static string NormalizeRoot(string root)
        {
            string r = root.Trim();
            if (r.Length == 2 && r[1] == ':') r += @"\";
            return r;
        }

        private static string DisplayNameFor(string path)
        {
            string p = path.TrimEnd('\\');
            if (p.Length == 2 && p[1] == ':') return p + @"\";
            return PathUtil.LeafOf(p);
        }

        private DirNode ScanDir(string path, string name, DirNode parent, int depth)
        {
            DirNode node = new DirNode();
            node.Name = name;
            node.FullPath = path;
            node.Parent = parent;

            if (_cancel) return node;

            long seen = Interlocked.Increment(ref _dirs);
            if ((seen & 0xFF) == 0) _current = path;

            List<string> subdirNames = new List<string>();
            long ownSize = 0;
            long ownFiles = 0;

            WIN32_FIND_DATA fd;
            SafeFindHandle handle = NativeMethods.FindFirstFileExW(
                PathUtil.SearchPattern(path, "*"),
                NativeMethods.FindExInfoBasic, out fd,
                NativeMethods.FindExSearchNameMatch, IntPtr.Zero,
                NativeMethods.FIND_FIRST_EX_LARGE_FETCH);

            if (handle.IsInvalid)
            {
                handle.Dispose();
                node.AccessDenied = true;
                Interlocked.Increment(ref _denied);
                return node;
            }

            using (handle)
            {
                do
                {
                    string fn = fd.cFileName;
                    if (fn == "." || fn == "..") continue;

                    bool isDir = (fd.dwFileAttributes & NativeMethods.FILE_ATTRIBUTE_DIRECTORY) != 0;
                    bool isLink = (fd.dwFileAttributes & NativeMethods.FILE_ATTRIBUTE_REPARSE_POINT) != 0;

                    if (isDir)
                    {
                        // Junctions/symlinks point elsewhere: following them double-counts and can loop.
                        if (isLink) continue;
                        subdirNames.Add(fn);
                    }
                    else
                    {
                        long size = isLink ? 0 : (((long)fd.nFileSizeHigh << 32) | (long)fd.nFileSizeLow);
                        ownSize += size;
                        ownFiles++;

                        if (size >= LargeFileThreshold && LargeFiles.Count < MaxLargeFiles)
                        {
                            FileEntry fe = new FileEntry();
                            fe.Name = fn;
                            fe.Folder = path;
                            fe.FullPath = PathUtil.Join(path, fn);
                            fe.Size = size;
                            fe.Modified = PathUtil.ToDateTime(fd.ftLastWriteTimeHigh, fd.ftLastWriteTimeLow);
                            LargeFiles.Add(fe);
                        }
                    }
                }
                while (!_cancel && NativeMethods.FindNextFileW(handle, out fd));
            }

            Interlocked.Add(ref _files, ownFiles);
            Interlocked.Add(ref _bytes, ownSize);

            node.OwnSize = ownSize;

            List<DirNode> kids = new List<DirNode>(subdirNames.Count);
            if (subdirNames.Count > 0 && !_cancel)
            {
                if (depth < ParallelDepth && subdirNames.Count > 1)
                {
                    DirNode[] buf = new DirNode[subdirNames.Count];
                    ParallelOptions po = new ParallelOptions();
                    po.MaxDegreeOfParallelism = Math.Max(2, Environment.ProcessorCount);
                    Parallel.For(0, subdirNames.Count, po, delegate(int i)
                    {
                        if (_cancel) return;
                        buf[i] = ScanDir(PathUtil.Join(path, subdirNames[i]), subdirNames[i], node, depth + 1);
                    });
                    for (int i = 0; i < buf.Length; i++)
                    {
                        if (buf[i] != null) kids.Add(buf[i]);
                    }
                }
                else
                {
                    for (int i = 0; i < subdirNames.Count; i++)
                    {
                        if (_cancel) break;
                        kids.Add(ScanDir(PathUtil.Join(path, subdirNames[i]), subdirNames[i], node, depth + 1));
                    }
                }
            }

            long total = ownSize;
            long fileTotal = ownFiles;
            long folderTotal = kids.Count;
            for (int i = 0; i < kids.Count; i++)
            {
                total += kids[i].Size;
                fileTotal += kids[i].FileCount;
                folderTotal += kids[i].FolderCount;
            }

            node.Size = total;
            node.FileCount = fileTotal;
            node.FolderCount = folderTotal;

            // Loose files in this folder get their own row so the tree always adds up.
            if (ownSize > 0 && kids.Count > 0)
            {
                DirNode bucket = new DirNode();
                bucket.Name = "[files in this folder]";
                bucket.FullPath = path;
                bucket.Size = ownSize;
                bucket.OwnSize = ownSize;
                bucket.FileCount = ownFiles;
                bucket.IsFilesBucket = true;
                bucket.Parent = node;
                kids.Add(bucket);
            }

            kids.Sort(delegate(DirNode a, DirNode b) { return b.Size.CompareTo(a.Size); });
            for (int i = 0; i < kids.Count; i++)
            {
                kids[i].PercentOfParent = (total > 0) ? (kids[i].Size * 100.0 / total) : 0.0;
                node.Children.Add(kids[i]);
            }

            return node;
        }

        /// <summary>Recursive size of a single path. Supports a wildcard in the final segment.</summary>
        public static void Measure(string path, bool skipReparse, ref long bytes, ref long files)
        {
            if (string.IsNullOrEmpty(path)) return;
            string leaf = PathUtil.LeafOf(path);
            if (leaf.Length == 2 && leaf[1] == ':') return;
            MeasureMatches(PathUtil.ParentOf(path), leaf, skipReparse, ref bytes, ref files);
        }

        private static void MeasureMatches(string parent, string pattern, bool skipReparse, ref long bytes, ref long files)
        {
            WIN32_FIND_DATA fd;
            SafeFindHandle h = NativeMethods.FindFirstFileExW(
                PathUtil.SearchPattern(parent, pattern),
                NativeMethods.FindExInfoBasic, out fd,
                NativeMethods.FindExSearchNameMatch, IntPtr.Zero,
                NativeMethods.FIND_FIRST_EX_LARGE_FETCH);

            if (h.IsInvalid) { h.Dispose(); return; }

            using (h)
            {
                do
                {
                    string fn = fd.cFileName;
                    if (fn == "." || fn == "..") continue;

                    bool isDir = (fd.dwFileAttributes & NativeMethods.FILE_ATTRIBUTE_DIRECTORY) != 0;
                    bool isLink = (fd.dwFileAttributes & NativeMethods.FILE_ATTRIBUTE_REPARSE_POINT) != 0;

                    if (isDir)
                    {
                        if (isLink && skipReparse) continue;
                        MeasureDirRecursive(PathUtil.Join(parent, fn), skipReparse, ref bytes, ref files);
                    }
                    else if (!isLink)
                    {
                        bytes += ((long)fd.nFileSizeHigh << 32) | (long)fd.nFileSizeLow;
                        files++;
                    }
                }
                while (NativeMethods.FindNextFileW(h, out fd));
            }
        }

        private static void MeasureDirRecursive(string dir, bool skipReparse, ref long bytes, ref long files)
        {
            WIN32_FIND_DATA fd;
            SafeFindHandle h = NativeMethods.FindFirstFileExW(
                PathUtil.SearchPattern(dir, "*"),
                NativeMethods.FindExInfoBasic, out fd,
                NativeMethods.FindExSearchNameMatch, IntPtr.Zero,
                NativeMethods.FIND_FIRST_EX_LARGE_FETCH);

            if (h.IsInvalid) { h.Dispose(); return; }

            List<string> subs = new List<string>();
            using (h)
            {
                do
                {
                    string fn = fd.cFileName;
                    if (fn == "." || fn == "..") continue;

                    bool isDir = (fd.dwFileAttributes & NativeMethods.FILE_ATTRIBUTE_DIRECTORY) != 0;
                    bool isLink = (fd.dwFileAttributes & NativeMethods.FILE_ATTRIBUTE_REPARSE_POINT) != 0;

                    if (isDir)
                    {
                        if (isLink && skipReparse) continue;
                        subs.Add(fn);
                    }
                    else if (!isLink)
                    {
                        bytes += ((long)fd.nFileSizeHigh << 32) | (long)fd.nFileSizeLow;
                        files++;
                    }
                }
                while (NativeMethods.FindNextFileW(h, out fd));
            }

            for (int i = 0; i < subs.Count; i++)
            {
                MeasureDirRecursive(PathUtil.Join(dir, subs[i]), skipReparse, ref bytes, ref files);
            }
        }
    }

    /// <summary>A junk/cache location the user can review and clean.</summary>
    public class CleanupItem : INotifyPropertyChanged
    {
        private bool _selected;
        private long _size;
        private long _fileCount;
        private bool _measured;

        public string Id { get; set; }
        public string Name { get; set; }
        public string Description { get; set; }
        public string Risk { get; set; }
        public string[] Paths { get; set; }
        public bool Deletable { get; set; }
        public bool DeleteFolderItself { get; set; }
        public string SpecialAction { get; set; }
        public string Hint { get; set; }

        public CleanupItem()
        {
            Paths = new string[0];
            Risk = "Safe";
            Deletable = true;
            SpecialAction = "";
            Hint = "";
            Description = "";
            Name = "";
            Id = "";
        }

        public bool Selected
        {
            get { return _selected; }
            set { if (_selected != value) { _selected = value; Raise("Selected"); } }
        }

        public long Size
        {
            get { return _size; }
            set { if (_size != value) { _size = value; Raise("Size"); Raise("SizeText"); } }
        }

        public long FileCount
        {
            get { return _fileCount; }
            set { if (_fileCount != value) { _fileCount = value; Raise("FileCount"); Raise("Detail"); } }
        }

        public bool Measured
        {
            get { return _measured; }
            set { if (_measured != value) { _measured = value; Raise("Measured"); Raise("SizeText"); Raise("Detail"); } }
        }

        public string SizeText
        {
            get { return _measured ? Fmt.Bytes(_size) : "..."; }
        }

        public string Detail
        {
            get
            {
                if (!_measured) return "measuring...";
                if (!Deletable) return string.IsNullOrEmpty(Hint) ? "review manually" : Hint;
                return _fileCount.ToString("N0") + " items";
            }
        }

        public string PathText { get { return string.Join("; ", Paths); } }

        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise(string p)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(p));
        }
    }

    /// <summary>Measures many cleanup locations in parallel on a background task.</summary>
    public class BatchMeasurer
    {
        private Task _task;
        private volatile bool _cancel;
        private int _completed;
        private List<CleanupItem> _items;

        public bool IsRunning { get { return _task != null && !_task.IsCompleted; } }
        public int Completed { get { return Thread.VolatileRead(ref _completed); } }
        public int Total { get { return _items == null ? 0 : _items.Count; } }

        public void Cancel() { _cancel = true; }

        public void Start(List<CleanupItem> items)
        {
            _items = items;
            _cancel = false;
            _completed = 0;

            _task = Task.Factory.StartNew(delegate
            {
                ParallelOptions po = new ParallelOptions();
                po.MaxDegreeOfParallelism = Math.Max(2, Environment.ProcessorCount);
                try
                {
                    Parallel.ForEach(items, po, delegate(CleanupItem item)
                    {
                        if (_cancel) return;
                        long bytes = 0;
                        long files = 0;
                        for (int i = 0; i < item.Paths.Length; i++)
                        {
                            if (_cancel) break;
                            try { Scanner.Measure(item.Paths[i], true, ref bytes, ref files); }
                            catch { }
                        }
                        item.Size = bytes;
                        item.FileCount = files;
                        item.Measured = true;
                        Interlocked.Increment(ref _completed);
                    });
                }
                catch { }
            }, TaskCreationOptions.LongRunning);
        }
    }

    /// <summary>
    /// Deletes paths on a dedicated STA background thread so the UI stays responsive.
    /// Uses Win32 directly, which handles paths longer than MAX_PATH.
    /// </summary>
    public class Deleter
    {
        private Thread _thread;
        private volatile bool _cancel;
        private int _completed;
        private long _freed;
        private long _removedFiles;
        private volatile string _current = "";
        private string[] _paths;
        private bool _recycle;
        private bool _contentsOnly;
        private readonly List<string> _errors = new List<string>();

        public bool IsRunning { get { return _thread != null && _thread.IsAlive; } }
        public int Completed { get { return Thread.VolatileRead(ref _completed); } }
        public int Total { get { return _paths == null ? 0 : _paths.Length; } }
        public long FreedBytes { get { return Interlocked.Read(ref _freed); } }
        public long RemovedFiles { get { return Interlocked.Read(ref _removedFiles); } }
        public string CurrentPath { get { return _current; } }

        public string[] Errors
        {
            get { lock (_errors) { return _errors.ToArray(); } }
        }

        public void Cancel() { _cancel = true; }

        /// <param name="contentsOnly">Empty each folder but keep the folder itself.</param>
        public void Start(string[] paths, bool recycle, bool contentsOnly)
        {
            _paths = paths;
            _recycle = recycle;
            _contentsOnly = contentsOnly;
            _cancel = false;
            _completed = 0;
            _freed = 0;
            _removedFiles = 0;
            lock (_errors) { _errors.Clear(); }

            _thread = new Thread(Run);
            _thread.IsBackground = true;
            _thread.SetApartmentState(ApartmentState.STA); // SHFileOperation prefers STA
            _thread.Start();
        }

        private void AddError(string path, string message)
        {
            lock (_errors)
            {
                if (_errors.Count < 200) _errors.Add(path + " -- " + message);
            }
        }

        private void Run()
        {
            for (int i = 0; i < _paths.Length; i++)
            {
                if (_cancel) break;
                string path = _paths[i];
                _current = path;
                try
                {
                    long bytes = 0;
                    long files = 0;
                    try { Scanner.Measure(path, true, ref bytes, ref files); }
                    catch { }

                    bool isDir = IsDirectory(path);
                    if (_contentsOnly && isDir) DeleteContents(path);
                    else DeleteOne(path, isDir);

                    // Re-measure so partial failures are reported honestly.
                    long left = 0;
                    long leftFiles = 0;
                    try { Scanner.Measure(path, true, ref left, ref leftFiles); }
                    catch { }

                    Interlocked.Add(ref _freed, Math.Max(0, bytes - left));
                    Interlocked.Add(ref _removedFiles, Math.Max(0, files - leftFiles));
                }
                catch (Exception ex)
                {
                    AddError(path, ex.Message);
                }
                Interlocked.Increment(ref _completed);
            }
            _current = "";
        }

        private void DeleteContents(string dir)
        {
            List<string> entries = new List<string>();
            List<bool> dirs = new List<bool>();

            WIN32_FIND_DATA fd;
            SafeFindHandle h = NativeMethods.FindFirstFileExW(
                PathUtil.SearchPattern(dir, "*"),
                NativeMethods.FindExInfoBasic, out fd,
                NativeMethods.FindExSearchNameMatch, IntPtr.Zero,
                NativeMethods.FIND_FIRST_EX_LARGE_FETCH);

            if (h.IsInvalid) { h.Dispose(); AddError(dir, "cannot open folder"); return; }

            using (h)
            {
                do
                {
                    string fn = fd.cFileName;
                    if (fn == "." || fn == "..") continue;
                    entries.Add(PathUtil.Join(dir, fn));
                    dirs.Add((fd.dwFileAttributes & NativeMethods.FILE_ATTRIBUTE_DIRECTORY) != 0);
                }
                while (NativeMethods.FindNextFileW(h, out fd));
            }

            for (int i = 0; i < entries.Count; i++)
            {
                if (_cancel) break;
                try { DeleteOne(entries[i], dirs[i]); }
                catch (Exception ex) { AddError(entries[i], ex.Message); }
            }
        }

        private void DeleteOne(string path, bool isDir)
        {
            if (_recycle) { RecycleDelete(path); return; }
            if (isDir) DeleteTree(path);
            else DeleteFileHard(path);
        }

        private static bool IsDirectory(string path)
        {
            WIN32_FIND_DATA fd;
            SafeFindHandle h = NativeMethods.FindFirstFileExW(
                PathUtil.Extended(path.TrimEnd('\\')),
                NativeMethods.FindExInfoBasic, out fd,
                NativeMethods.FindExSearchNameMatch, IntPtr.Zero, 0);

            if (h.IsInvalid)
            {
                h.Dispose();
                // Drive roots cannot be enumerated by name; treat trailing-slash paths as folders.
                return path.EndsWith("\\", StringComparison.Ordinal);
            }
            using (h)
            {
                return (fd.dwFileAttributes & NativeMethods.FILE_ATTRIBUTE_DIRECTORY) != 0;
            }
        }

        private void RecycleDelete(string path)
        {
            NativeMethods.SHFILEOPSTRUCTW op = new NativeMethods.SHFILEOPSTRUCTW();
            op.wFunc = NativeMethods.FO_DELETE;
            // pFrom is a double-null-terminated list, so it must be marshalled by hand.
            op.pFrom = Marshal.StringToHGlobalUni(path.TrimEnd('\\') + "\0\0");
            op.fFlags = (ushort)(NativeMethods.FOF_ALLOWUNDO | NativeMethods.FOF_NOCONFIRMATION
                               | NativeMethods.FOF_NOERRORUI | NativeMethods.FOF_SILENT
                               | NativeMethods.FOF_NOCONFIRMMKDIR);
            try
            {
                int rc = NativeMethods.SHFileOperationW(ref op);
                if (rc != 0) AddError(path, "could not move to Recycle Bin (code " + rc + ")");
                else if (op.fAnyOperationsAborted) AddError(path, "Recycle Bin operation aborted");
            }
            finally
            {
                Marshal.FreeHGlobal(op.pFrom);
            }
        }

        private void DeleteFileHard(string path)
        {
            string ex = PathUtil.Extended(path);
            if (NativeMethods.DeleteFileW(ex)) return;

            // Most failures here are the read-only attribute; clear it and retry once.
            NativeMethods.SetFileAttributesW(ex, NativeMethods.FILE_ATTRIBUTE_NORMAL);
            if (NativeMethods.DeleteFileW(ex)) return;

            AddError(path, new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message);
        }

        private void DeleteTree(string dir)
        {
            List<string> subdirs = new List<string>();

            WIN32_FIND_DATA fd;
            SafeFindHandle h = NativeMethods.FindFirstFileExW(
                PathUtil.SearchPattern(dir, "*"),
                NativeMethods.FindExInfoBasic, out fd,
                NativeMethods.FindExSearchNameMatch, IntPtr.Zero,
                NativeMethods.FIND_FIRST_EX_LARGE_FETCH);

            if (!h.IsInvalid)
            {
                using (h)
                {
                    do
                    {
                        if (_cancel) break;
                        string fn = fd.cFileName;
                        if (fn == "." || fn == "..") continue;

                        bool isDir = (fd.dwFileAttributes & NativeMethods.FILE_ATTRIBUTE_DIRECTORY) != 0;
                        bool isLink = (fd.dwFileAttributes & NativeMethods.FILE_ATTRIBUTE_REPARSE_POINT) != 0;
                        string child = PathUtil.Join(dir, fn);

                        if (isDir)
                        {
                            // Never recurse through a junction: that would delete the target's contents.
                            if (isLink) NativeMethods.RemoveDirectoryW(PathUtil.Extended(child));
                            else subdirs.Add(child);
                        }
                        else
                        {
                            DeleteFileHard(child);
                        }
                    }
                    while (NativeMethods.FindNextFileW(h, out fd));
                }
            }
            else { h.Dispose(); }

            for (int i = 0; i < subdirs.Count; i++)
            {
                if (_cancel) break;
                DeleteTree(subdirs[i]);
            }

            string exDir = PathUtil.Extended(dir);
            if (!NativeMethods.RemoveDirectoryW(exDir))
            {
                NativeMethods.SetFileAttributesW(exDir, NativeMethods.FILE_ATTRIBUTE_NORMAL);
                if (!NativeMethods.RemoveDirectoryW(exDir))
                {
                    AddError(dir, new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message);
                }
            }
        }
    }

    /// <summary>An entry from the Windows uninstall registry.</summary>
    public class ProgramItem
    {
        public string Name { get; set; }
        public string Version { get; set; }
        public string Publisher { get; set; }
        public string InstallDate { get; set; }
        public long Size { get; set; }
        public string InstallLocation { get; set; }
        public string UninstallString { get; set; }
        public string QuietUninstallString { get; set; }
        public string Scope { get; set; }
        public string RegistryKey { get; set; }

        public ProgramItem()
        {
            Name = ""; Version = ""; Publisher = ""; InstallDate = "";
            InstallLocation = ""; UninstallString = ""; QuietUninstallString = "";
            Scope = ""; RegistryKey = "";
        }

        public string SizeText { get { return Size > 0 ? Fmt.Bytes(Size) : "unknown"; } }
        public bool CanUninstall
        {
            get { return !string.IsNullOrEmpty(UninstallString) || !string.IsNullOrEmpty(QuietUninstallString); }
        }
    }
}
