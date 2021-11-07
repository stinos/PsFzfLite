#if !VS
using System;
using System.Management.Automation;

namespace PsFzfLite
{
  public static class PipelineHelper
  {
    private static readonly Type stopException = typeof( Cmdlet ).Assembly.GetType(
      "System.Management.Automation.StopUpstreamCommandsException" );

    //https://stackoverflow.com/questions/1499466/powershell-equivalent-of-linq-any/34800670#34800670
    public static void StopUpstreamCommands( Cmdlet cmdlet )
    {
      throw (Exception) System.Activator.CreateInstance( stopException, cmdlet );
    }
  }
}
#endif
