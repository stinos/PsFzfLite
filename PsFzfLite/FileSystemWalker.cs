using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
//For testing this when building without the System.Management.Automation NuGet package.
#if !VS
using System.Management.Automation;
#endif
#if !WIN
using System.IO;
#else
using System.Runtime.InteropServices;
#endif
using System.Threading;
using System.Threading.Tasks;

namespace PsFzfLite
{
#if WIN
  //Mostly from http://www.pinvoke.net/default.aspx/Structures/WIN32_FIND_DATA.html
  internal class Interop
  {
    [StructLayout( LayoutKind.Sequential, CharSet = CharSet.Ansi )]
    internal struct WIN32_FIND_DATA
    {
      public uint dwFileAttributes;
      public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
      public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
      public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
      public uint nFileSizeHigh;
      public uint nFileSizeLow;
      public uint dwReserved0;
      public uint dwReserved1;
      [MarshalAs( UnmanagedType.ByValTStr, SizeConst = 260 )]
      public string cFileName;
      [MarshalAs( UnmanagedType.ByValTStr, SizeConst = 14 )]
      public string cAlternateFileName;
    }

    internal enum FINDEX_INFO_LEVELS
    {
      FindExInfoStandard = 0,
      FindExInfoBasic = 1,
      FindExInfoMaxInfoLevel = 2
    }

    internal enum FINDEX_SEARCH_OPS
    {
      FindExSearchNameMatch = 0,
      FindExSearchLimitToDirectories = 1,
      FindExSearchLimitToDevices = 2,
      FindExSearchMaxSearchOp = 3
    }

    internal const int FIND_FIRST_EX_CASE_SENSITIVE = 1;
    internal const int FIND_FIRST_EX_LARGE_FETCH = 2;
    internal const int FIND_FIRST_EX_ON_DISK_ENTRIES_ONLY = 4;
    internal static readonly IntPtr NULLPTR = new IntPtr( 0 );
    internal static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr( -1 );

    [DllImport( "kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi )]
    public static extern IntPtr FindFirstFileEx(
      string lpFileName, FINDEX_INFO_LEVELS fInfoLevelId,
      out WIN32_FIND_DATA lpFindFileData, FINDEX_SEARCH_OPS fSearchOp,
      IntPtr lpSearchFilter, int dwAdditionalFlags );

    [DllImport( "kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi )]
    internal static extern bool FindNextFile( IntPtr hFindFile, out WIN32_FIND_DATA lpFindFileData );

    [DllImport( "kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi )]
    internal static extern bool FindClose( IntPtr hFindFile );
  }
#endif

  /// <summary>
  /// Multithreaded filesystem walking tailored for piping output into PS and fzf.
  /// Despite this being a fairly naive and simple implementation, it works pretty well
  /// because listing files is I/O bound anyway, so using multiple threads just takes
  /// care that we hit the limit of what is possible.
  ///
  /// This is fzf-like in this sense:
  /// - by default returns everything found and can only filter directories
  /// - FilterDotDirectories defaults to what fzf does
  /// - can produce file paths relative to the directory being listed
  /// - searches either files or directories, one normally doesn't fuzzy match both
  /// </summary>
  public class FileSystemWalker
  {
    [Flags]
    public enum SearchType
    {
      Files = 1,
      Directories = 2
    }

    public static bool FilterDotDirectories( string d )
    {
      return d.StartsWith( "." );
    }

#if WIN
    public static IEnumerable<string> Walk(
      string root, string rootReplacement, SearchType searchType,
      Func<string, bool> excludeDirectories = null )
    {
      var rootDir = root.TrimEnd( '\\', '/' );
      var eraseLen = rootDir.Length + 1; // +1 for the separator
      //If empty we'll completely erase the root, else replace it so must have a separator.
      if( rootReplacement.Length > 0 && !( rootReplacement.EndsWith( "\\" ) || rootReplacement.EndsWith( "/" ) ) )
      {
        rootReplacement += "\\";
      }

      //All directories get pushed into this one.
      //Note these must always be paths ending with a separator (and we use \ because it's for windows).
      var dirs = new BlockingCollection<string> { rootDir + "\\" };
      //All output paths (files or directories) go into this one.
      var paths = new BlockingCollection<string>();
      //Walk spawns tasks which iterate over dirs, and for each list the directory
      //populating paths and/or dirs.
      var tasks = Walk( dirs, paths, searchType, excludeDirectories );
      //While the tasks are producing items consume them here and output them.
      foreach( var file in paths.GetConsumingEnumerable() )
      {
        yield return file.Remove( 0, eraseLen ).Insert( 0, rootReplacement );
      }
      //All done, cleanup tasks (even though they'll all be completed by now).
      Task.WaitAll( tasks );
    }

    public static Task[] Walk(
      BlockingCollection<string> dirs, BlockingCollection<string> paths, SearchType searchType,
      Func<string, bool> excludeDirectories )
    {
      var dirsToDo = dirs.Count;
      if( dirsToDo == 0 )
      {
        return new Task[] { };
      }
      var numWorkers = Environment.ProcessorCount;
      var workersLeft = numWorkers;

#if NET40
      var ConsumeDirs = new Action( () =>
#else
      void ConsumeDirs()
#endif
      {
        foreach( var root in dirs.GetConsumingEnumerable() )
        {
          Interop.WIN32_FIND_DATA fileData;
          var handle = Interop.FindFirstFileEx(
            root + "*", Interop.FINDEX_INFO_LEVELS.FindExInfoBasic, out fileData,
            Interop.FINDEX_SEARCH_OPS.FindExSearchNameMatch, Interop.NULLPTR,
            Interop.FIND_FIRST_EX_LARGE_FETCH );
          if( handle != Interop.INVALID_HANDLE_VALUE )
          {
            do
            {
              if( fileData.cFileName == "." || fileData.cFileName == ".." )
              {
                continue;
              }
              var fullPath = root + fileData.cFileName;
              if( ( fileData.dwFileAttributes & 0x10 ) > 0 )
              {
                if( excludeDirectories != null && excludeDirectories( fileData.cFileName ) )
                {
                  continue;
                }
                if( searchType.HasFlag( SearchType.Directories ) )
                {
                  paths.Add( fullPath );
                }
                Interlocked.Increment( ref dirsToDo );
                dirs.Add( fullPath + "\\" );
              }
              else if( searchType.HasFlag( SearchType.Files ) )
              {
                paths.Add( fullPath );
              }
            } while( Interop.FindNextFile( handle, out fileData ) );
            Interop.FindClose( handle );
          }
          if( Interlocked.Decrement( ref dirsToDo ) == 0 )
          {
            dirs.CompleteAdding();
          }
        }
        if( Interlocked.Decrement( ref workersLeft ) == 0 )
        {
          paths.CompleteAdding();
        }
      }
#if NET40
      );
#endif

      return Enumerable.Range( 1, numWorkers ).Select( n => Task.Factory.StartNew( ConsumeDirs ) ).ToArray();
    }

#else //#if WIN

    public static IEnumerable<string> Walk(
      string root, string rootReplacement, SearchType searchType,
      Func<string, bool> excludeDirectories = null )
    {
      var rootDir = root.TrimEnd( '\\', '/' );
      var eraseLen = rootDir.Length + 1;
      if( rootReplacement.Length > 0 && !( rootReplacement.EndsWith( "\\" ) || rootReplacement.EndsWith( "/" ) ) )
      {
        rootReplacement += Path.DirectorySeparatorChar;
      }

      var dirs = new BlockingCollection<DirectoryInfo> { new DirectoryInfo( rootDir ) };
      var paths = new BlockingCollection<string>();
      var tasks = Walk( dirs, paths, searchType, excludeDirectories );
      foreach( var file in paths.GetConsumingEnumerable() )
      {
        yield return file.Remove( 0, eraseLen ).Insert( 0, rootReplacement );
      }
      Task.WaitAll( tasks );
    }

    public static Task[] Walk(
      BlockingCollection<DirectoryInfo> dirs, BlockingCollection<string> paths, SearchType searchType,
      Func<string, bool> excludeDirectories )
    {
      var dirsToDo = dirs.Count;
      if( dirsToDo == 0 )
      {
        return new Task[] { };
      }
      var numWorkers = Environment.ProcessorCount;
      var workersLeft = numWorkers;

#if NET40
      var ConsumeDirs = new Action( () =>
#else
      void ConsumeDirs()
#endif
      {
        foreach( var root in dirs.GetConsumingEnumerable() )
        {
          try
          {
            foreach( var dir in root.EnumerateDirectories( "*", SearchOption.TopDirectoryOnly ) )
            {
              if( excludeDirectories != null && excludeDirectories( dir.Name ) )
              {
                continue;
              }
              if( searchType.HasFlag( SearchType.Directories ) )
              {
                paths.Add( dir.FullName );
              }
              Interlocked.Increment( ref dirsToDo );
              dirs.Add( dir );
            }
          }
          catch( Exception )
          {
          }
          if( searchType.HasFlag( SearchType.Files ) )
          {
            try
            {
              foreach( var file in root.EnumerateFiles( "*", SearchOption.TopDirectoryOnly ) )
              {
                paths.Add( file.FullName );
              }
            }
            catch( Exception )
            {
            }
          }
          if( Interlocked.Decrement( ref dirsToDo ) == 0 )
          {
            dirs.CompleteAdding();
          }
        }
        if( Interlocked.Decrement( ref workersLeft ) == 0 )
        {
          paths.CompleteAdding();
        }
      }
#if NET40
      );
#endif

      return Enumerable.Range( 1, numWorkers ).Select( n => Task.Factory.StartNew( ConsumeDirs ) ).ToArray();
    }
#endif
  }

#if !VS
  [Cmdlet( VerbsCommon.Get, "ChildPathNames" )]
  [OutputType( typeof( string ) )]
  public class GetChildPathNamesCmdlet : PSCmdlet
  {
    public GetChildPathNamesCmdlet()
    {
      PathReplacement = ""; // Default: return paths relative to Path.
      SearchType = FileSystemWalker.SearchType.Files;
      Filter = FileSystemWalker.FilterDotDirectories;
    }

    [Parameter( Mandatory = true )]
    public string Path { get; set; }

    [Parameter()]
    public string PathReplacement { get; set; }

    [Parameter()]
    public FileSystemWalker.SearchType SearchType { get; set; }

    [Parameter()]
    public Func<string, bool> Filter { get; set; }

    protected override void ProcessRecord()
    {
      var path = GetUnresolvedProviderPathFromPSPath( Path );
      foreach( var i in FileSystemWalker.Walk( path, PathReplacement, SearchType, Filter ) )
      {
        WriteObject( i );
      }
    }
  }
#endif
}
