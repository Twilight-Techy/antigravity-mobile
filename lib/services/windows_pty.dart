/// A tmux stand-in for Windows servers, compiled on the server by
/// PowerShell's `Add-Type` (C# 5, .NET Framework).
///
/// `Host.Run` starts a program in a pseudoconsole (ConPTY) and serves it on
/// a named pipe that only the current user can open; it is started through
/// WMI so it outlives the SSH session. `Client.Attach` connects the SSH
/// session's console to that pipe. Messages to the host are framed as
/// `[type][int32 length][data]`: 0 = input, 1 = resize, 2 = attach (resize
/// and repaint). Output goes to every attached client as raw bytes.
const windowsPtySource = r'''
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace AgmPty {
  [StructLayout(LayoutKind.Sequential)]
  public struct Coord { public short X; public short Y; }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct StartupInfo {
    public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public int dwX; public int dwY; public int dwXSize; public int dwYSize;
    public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
    public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
    public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct StartupInfoEx { public StartupInfo StartupInfo; public IntPtr lpAttributeList; }

  [StructLayout(LayoutKind.Sequential)]
  public struct ProcessInformation { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }

  public static class Native {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int CreatePseudoConsole(Coord size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out IntPtr phPC);
    [DllImport("kernel32.dll")]
    public static extern int ResizePseudoConsole(IntPtr hPC, Coord size);
    [DllImport("kernel32.dll")]
    public static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CreatePipe(out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe, IntPtr lpPipeAttributes, int nSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcessW(string lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref StartupInfoEx lpStartupInfo, out ProcessInformation lpProcessInformation);
    [DllImport("kernel32.dll")]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll")]
    public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll")]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll")]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    [DllImport("kernel32.dll")]
    public static extern bool SetConsoleCP(uint wCodePageID);
    [DllImport("kernel32.dll")]
    public static extern bool SetConsoleOutputCP(uint wCodePageID);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool WaitNamedPipeW(string lpNamedPipeName, uint nTimeOut);
  }

  /// Off unless `agmpty.trace` sits next to the DLL; then both sides log
  /// to `agmpty.log` there.
  public static class Trace {
    static readonly string Dir = Path.GetDirectoryName(typeof(Trace).Assembly.Location);
    static readonly bool On = File.Exists(Path.Combine(Dir, "agmpty.trace"));
    public static void Log(string message) {
      if (!On) return;
      try { File.AppendAllText(Path.Combine(Dir, "agmpty.log"), DateTime.Now.ToString("HH:mm:ss.fff") + " " + message + Environment.NewLine); } catch { }
    }
  }

  public static class Host {
    static readonly object Gate = new object();
    static readonly object InputGate = new object();
    static readonly List<Stream> Clients = new List<Stream>();
    static IntPtr pc;
    static volatile bool exited;

    public static int Run(string pipeName, string commandLine, string cwd, short cols, short rows) {
      SafeFileHandle inRead, inWrite, outRead, outWrite;
      if (!Native.CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0) || !Native.CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0))
        throw new Exception("CreatePipe failed: " + Marshal.GetLastWin32Error());
      Coord size = new Coord();
      size.X = cols;
      size.Y = rows;
      int hr = Native.CreatePseudoConsole(size, inRead, outWrite, 0, out pc);
      if (hr != 0) throw new Exception("CreatePseudoConsole failed: 0x" + hr.ToString("x"));

      IntPtr attrSize = IntPtr.Zero;
      Native.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
      IntPtr attrs = Marshal.AllocHGlobal(attrSize);
      if (!Native.InitializeProcThreadAttributeList(attrs, 1, 0, ref attrSize))
        throw new Exception("InitializeProcThreadAttributeList failed: " + Marshal.GetLastWin32Error());
      // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
      if (!Native.UpdateProcThreadAttribute(attrs, 0, (IntPtr)0x00020016, pc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
        throw new Exception("UpdateProcThreadAttribute failed: " + Marshal.GetLastWin32Error());

      StartupInfoEx si = new StartupInfoEx();
      si.StartupInfo.cb = Marshal.SizeOf(typeof(StartupInfoEx));
      // STARTF_USESTDHANDLES with no handles, so the child doesn't inherit ours.
      si.StartupInfo.dwFlags = 0x100;
      si.lpAttributeList = attrs;
      ProcessInformation pi;
      // EXTENDED_STARTUPINFO_PRESENT
      if (!Native.CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, 0x00080000, IntPtr.Zero, cwd, ref si, out pi))
        throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
      inRead.Dispose();
      outWrite.Dispose();

      FileStream input = new FileStream(inWrite, FileAccess.Write);
      FileStream output = new FileStream(outRead, FileAccess.Read);

      Thread pump = new Thread(delegate() {
        byte[] buf = new byte[65536];
        try {
          int n;
          while ((n = output.Read(buf, 0, buf.Length)) > 0) {
            Trace.Log("host: output " + n + " bytes");
            lock (Gate) {
              foreach (Stream c in Clients.ToArray()) {
                try { c.Write(buf, 0, n); c.Flush(); } catch { Clients.Remove(c); }
              }
            }
          }
        } catch { }
      });
      pump.IsBackground = true;
      pump.Start();

      Thread waiter = new Thread(delegate() {
        Native.WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
        Thread.Sleep(500);
        exited = true;
        Native.ClosePseudoConsole(pc);
        lock (Gate) {
          foreach (Stream c in Clients) { try { c.Dispose(); } catch { } }
          Clients.Clear();
        }
      });
      waiter.IsBackground = true;
      waiter.Start();

      PipeSecurity security = new PipeSecurity();
      security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User, PipeAccessRights.FullControl, AccessControlType.Allow));
      while (!exited) {
        NamedPipeServerStream server = new NamedPipeServerStream(pipeName, PipeDirection.InOut,
            NamedPipeServerStream.MaxAllowedServerInstances, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 65536, 65536, security);
        IAsyncResult ar = server.BeginWaitForConnection(null, null);
        while (!ar.AsyncWaitHandle.WaitOne(500)) { if (exited) break; }
        if (exited) { server.Dispose(); break; }
        try { server.EndWaitForConnection(ar); } catch { server.Dispose(); continue; }
        Trace.Log("host: client connected");
        lock (Gate) { Clients.Add(server); }
        NamedPipeServerStream s = server;
        Thread t = new Thread(delegate() {
          try { Serve(s, input); } catch { }
          lock (Gate) { Clients.Remove(s); }
          try { s.Dispose(); } catch { }
        });
        t.IsBackground = true;
        t.Start();
      }
      uint code;
      Native.GetExitCodeProcess(pi.hProcess, out code);
      return (int)code;
    }

    static bool ReadFull(Stream s, byte[] buf, int count) {
      int read = 0;
      while (read < count) {
        int n = s.Read(buf, read, count - read);
        if (n <= 0) return false;
        read += n;
      }
      return true;
    }

    static void Serve(Stream s, Stream input) {
      byte[] head = new byte[5];
      while (!exited) {
        if (!ReadFull(s, head, 5)) return;
        int len = BitConverter.ToInt32(head, 1);
        if (len < 0 || len > (1 << 20)) return;
        byte[] data = new byte[len];
        if (!ReadFull(s, data, len)) return;
        Trace.Log("host: message " + head[0] + " (" + len + " bytes)");
        if (head[0] == 0) {
          lock (InputGate) { input.Write(data, 0, len); input.Flush(); }
        } else if ((head[0] == 1 || head[0] == 2) && len >= 4) {
          Coord c = new Coord();
          c.X = BitConverter.ToInt16(data, 0);
          c.Y = BitConverter.ToInt16(data, 2);
          if (c.X < 2 || c.Y < 2) continue;
          if (head[0] == 2) {
            // A size change makes the program repaint the whole screen.
            Coord t = c;
            t.Y = (short)(c.Y - 1);
            Native.ResizePseudoConsole(pc, t);
            Thread.Sleep(60);
          }
          Native.ResizePseudoConsole(pc, c);
        }
      }
    }
  }

  public static class Client {
    /// Whether a host serves [pipeName]: the pipe exists, free or busy.
    public static bool Exists(string pipeName) {
      if (Native.WaitNamedPipeW("\\\\.\\pipe\\" + pipeName, 100)) return true;
      return Marshal.GetLastWin32Error() != 2;
    }

    public static int Attach(string pipeName) {
      NamedPipeClientStream pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
      pipe.Connect(10000);
      IntPtr hIn = Native.GetStdHandle(-10);
      IntPtr hOut = Native.GetStdHandle(-11);
      uint mode;
      bool console = Native.GetConsoleMode(hIn, out mode);
      if (console) {
        Native.SetConsoleCP(65001);
        // Raw input: no line editing, echo or Ctrl+C handling; VT key codes.
        Native.SetConsoleMode(hIn, 0x0200);
      }
      uint outMode;
      if (Native.GetConsoleMode(hOut, out outMode)) {
        Native.SetConsoleOutputCP(65001);
        // ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN
        Native.SetConsoleMode(hOut, outMode | 0x0004 | 0x0008);
      }
      Stream stdin = Console.OpenStandardInput();
      Stream stdout = Console.OpenStandardOutput();
      object writeGate = new object();
      Action<byte, byte[], int> send = delegate(byte type, byte[] data, int n) {
        lock (writeGate) {
          byte[] head = new byte[5];
          head[0] = type;
          BitConverter.GetBytes(n).CopyTo(head, 1);
          pipe.Write(head, 0, 5);
          if (n > 0) pipe.Write(data, 0, n);
          pipe.Flush();
        }
      };
      Func<byte[]> sizeBytes = delegate() {
        short w = 80, h = 24;
        if (console) {
          try { w = (short)Console.WindowWidth; h = (short)Console.WindowHeight; } catch { }
        }
        byte[] d = new byte[4];
        BitConverter.GetBytes(w).CopyTo(d, 0);
        BitConverter.GetBytes(h).CopyTo(d, 2);
        return d;
      };
      byte[] first = sizeBytes();
      Trace.Log("client: attached (console " + console + ")");
      send(2, first, 4);

      Thread reader = new Thread(delegate() {
        byte[] buf = new byte[65536];
        try {
          int n;
          while ((n = pipe.Read(buf, 0, buf.Length)) > 0) { stdout.Write(buf, 0, n); stdout.Flush(); }
        } catch { }
        // The program ended: end this session too.
        Environment.Exit(0);
      });
      reader.IsBackground = true;
      reader.Start();

      if (console) {
        Thread sizer = new Thread(delegate() {
          byte[] last = first;
          while (true) {
            Thread.Sleep(300);
            byte[] cur = sizeBytes();
            if (cur[0] != last[0] || cur[1] != last[1] || cur[2] != last[2] || cur[3] != last[3]) {
              last = cur;
              try { send(1, cur, 4); } catch { return; }
            }
          }
        });
        sizer.IsBackground = true;
        sizer.Start();
      }

      byte[] ibuf = new byte[4096];
      try {
        int k;
        while ((k = stdin.Read(ibuf, 0, ibuf.Length)) > 0) {
          Trace.Log("client: input " + k + " bytes");
          send(0, ibuf, k);
        }
        Trace.Log("client: input closed");
      } catch (Exception e) { Trace.Log("client: input failed: " + e.Message); }
      // Our input closed (the SSH session ended): detach, leaving the host.
      return 0;
    }
  }
}
''';
