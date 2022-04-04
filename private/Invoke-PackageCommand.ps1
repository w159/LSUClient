﻿function Invoke-PackageCommand {
    <#
        .SYNOPSIS
        Tries to run a command and returns an object containing an error
        code and optionally information about the process that was run.
    #>

    [CmdletBinding()]
    [OutputType('ExternalProcessResult')]
    Param (
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [ValidateNotNullOrEmpty()]
        [Parameter( Mandatory = $true )]
        [string]$Command,
        [switch]$FallbackToShellExecute
    )

    # Remove any trailing backslashes from the Path.
    # This isn't necessary, because Split-ExecutableAndArguments can handle and trims
    # extra backslashes, but this will make the path look more sane in errors and warnings.
    $Path = $Path.TrimEnd('\')

    # Lenovo sometimes forgets to put a directory separator betweeen %PACKAGEPATH% and the executable so make sure it's there
    # If we end up with two backslashes, Split-ExecutableAndArguments removes the duplicate from the executable path, but
    # we could still end up with a double-backslash after %PACKAGEPATH% somewhere in the arguments for now.
    [string]$ExpandedCommandString = Resolve-CmdVariable -String $Command -ExtraVariables @{'PACKAGEPATH' = "${Path}\"; 'WINDOWS' = $env:SystemRoot}
    $ExeAndArgs = Split-ExecutableAndArguments -Command $ExpandedCommandString -WorkingDirectory $Path
    # Split-ExecutableAndArguments returns NULL if no executable could be found
    if (-not $ExeAndArgs) {
        Write-Warning "The command or file '$Command' could not be found from '$Path' and was not run"
        return [ExternalProcessResult]::new(
            [ExternalProcessError]::FILE_NOT_FOUND,
            $null
        )
    }

    $ExeAndArgs.Arguments = Remove-CmdEscapeCharacter -String $ExeAndArgs.Arguments
    Write-Debug "Starting external process:`r`n  File: $($ExeAndArgs.Executable)`r`n  Arguments: $($ExeAndArgs.Arguments)`r`n  WorkingDirectory: $Path"

    $Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateOutOfProcessRunspace($null)
    $Runspace.Open()

    $Powershell = [PowerShell]::Create().AddScript{
        [CmdletBinding()]
        Param (
            [ValidateNotNullOrEmpty()]
            [string]$WorkingDirectory,
            [ValidateNotNullOrEmpty()]
            [Parameter( Mandatory = $true )]
            [string]$Executable,
            [string]$Arguments,
            [switch]$FallbackToShellExecute
        )

        Set-StrictMode -Version 3.0

        # This value is used to communicate problems and errors that can be handled and or remedied/retried
        # internally to the calling function. It stays 0 when no known errors occurred.
        $HandledError = 0
        $ProcessStarted = $false
        [string[]]$StdOutLines = @()
        [string[]]$StdErrLines = @()

        $process                                  = [System.Diagnostics.Process]::new()
        $process.StartInfo.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $process.StartInfo.UseShellExecute        = $false
        $process.StartInfo.WorkingDirectory       = $WorkingDirectory
        $process.StartInfo.FileName               = $Executable
        $process.StartInfo.Arguments              = $Arguments
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError  = $true

        if ($FallbackToShellExecute) {
            $process.StartInfo.UseShellExecute        = $true
            $process.StartInfo.RedirectStandardOutput = $false
            $process.StartInfo.RedirectStandardError  = $false
        }

        try {
            if (-not $process.Start()) {
                $HandledError = 1
            } else {
                $ProcessStarted = $true
            }
        }
        catch {
            # In case we get ERROR_ELEVATION_REQUIRED (740) retry with ShellExecute to elevate with UAC
            if ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException.NativeErrorCode -eq 740) {
                $HandledError = 740
            # In case we get ERROR_BAD_EXE_FORMAT (193) retry with ShellExecute to open files like MSI
            } elseif ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException.NativeErrorCode -eq 193) {
                $HandledError = 193
            # In case we get ERROR_ACCESS_DENIED (5, only observed on PowerShell 7 so far)
            } elseif ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException.NativeErrorCode -eq 5) {
                $HandledError = 5
            } else {
                Write-Error $_
                $HandledError = 2 # Any other Process.Start exception
            }
        }

        if ($ProcessStarted) {
            $process.ID

            if (-not $FallbackToShellExecute) {
                # When redirecting StandardOutput or StandardError you have to start reading the streams asynchronously, or else it can cause
                # programs that output a lot (like package u3aud03w_w10 - Conexant USB Audio) to fill a stream and deadlock/hang indefinitely.
                # See issue #25 and https://stackoverflow.com/questions/11531068/powershell-capturing-standard-out-and-error-with-process-object
                $StdOutAsync = $process.StandardOutput.ReadToEndAsync()
                $StdErrAsync = $process.StandardError.ReadToEndAsync()
            }

            $process.WaitForExit()

            if (-not $FallbackToShellExecute) {
                $StdOutInOneString = $StdOutAsync.GetAwaiter().GetResult()
                $StdErrInOneString = $StdErrAsync.GetAwaiter().GetResult()

                [string[]]$StdOutLines = $StdOutInOneString.Split(
                    [string[]]("`r`n", "`r", "`n"),
                    [StringSplitOptions]::None
                )

                [string[]]$StdErrLines = $StdErrInOneString.Split(
                    [string[]]("`r`n", "`r", "`n"),
                    [StringSplitOptions]::None
                )
            }
        }

        return [PSCustomObject]@{
            'StandardOutput' = $StdOutLines
            'StandardError'  = $StdErrLines
            'ExitCode'       = $process.ExitCode
            'Runtime'        = $process.ExitTime - $process.StartTime
            'HandledError'   = $HandledError
        }
    }

    [void]$Powershell.AddParameters(@{
        'WorkingDirectory'       = $Path
        'Executable'             = $ExeAndArgs.Executable
        'Arguments'              = $ExeAndArgs.Arguments
        'FallbackToShellExecute' = $FallbackToShellExecute
    })

    $Powershell.Runspace = $Runspace
    $RunspaceStandardInput = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    $RunspaceStandardInput.Complete()
    $RunspaceStandardOut = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    [Datetime]$RunspaceStartTime = Get-Date
    $PSAsyncRunspace = $Powershell.BeginInvoke($RunspaceStandardInput, $RunspaceStandardOut)

    Add-Type -Debug:$false -TypeDefinition @'
    using System;
    using System.Text;
    using System.Runtime.InteropServices;

    public class User32 {
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern int GetWindowTextLength(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 Msg, int wParam, StringBuilder lParam);

        public delegate bool EnumThreadDelegate(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Auto, CallingConvention = CallingConvention.StdCall, SetLastError = true)]
        public static extern bool EnumThreadWindows(int dwThreadId, EnumThreadDelegate lpfn, IntPtr lParam);

        [DllImport("user32.dll", SetLastError=true, CharSet = CharSet.Auto, CallingConvention = CallingConvention.StdCall)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError=true, CharSet = CharSet.Auto)]
        public static extern UInt32 GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;        // x position of upper-left corner
            public int Top;         // y position of upper-left corner
            public int Right;       // x position of lower-right corner
            public int Bottom;      // y position of lower-right corner
        }
    }
'@

    function Get-ChildProcesses {
        [CmdletBinding()]
        Param (
            $ParentProcessId
        )
        Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = '$ParentProcessId'" | Foreach-Object {
            $_.ProcessId
            if ($_.ParentProcessId -ne $_.ProcessId) {
                Get-ChildProcesses -ParentProcessId $_.ProcessId
            }
        }
    }

    # Very experimental code to try and detect hanging processes
    [int]$WM_GETTEXT = 0xD
    [int]$GWL_STYLE = -16
    [Uint32]$WS_DISABLED = 0x08000000
    [Uint32]$WS_VISIBLE  = 0x10000000
    while ($PSAsyncRunspace.IsCompleted -eq $false) {
        $ProcessRuntimeElapsed = (Get-Date) - $RunspaceStartTime
        # Only start looking into processes if they have been running for x time,
        # many are really short lived and don't need to be tested for 'hanging'
        if ($ProcessRuntimeElapsed.TotalMinutes -gt 1) { # Set to low time of 1 minute intentionally during testing
            if ($RunspaceStandardOut.Count -ge 1) {
                [bool]$InteractableWindowOpen = $false
                [bool]$AllThreadsWaiting      = $true

                $ProcessID = $RunspaceStandardOut[0]
                $process   = Get-Process -Id $ProcessID
                $TimeStamp = Get-Date -Format 'HH:mm:ss'

                Write-Debug "[$TimeStamp] Process $($process.ID) has been running for $ProcessRuntimeElapsed"
                Write-Debug "Process has $($process.Threads.Count) threads"
                [array]$ChildProcesses = $process.ID
                [array]$ChildProcesses += Get-ChildProcesses -ParentProcessId $process.ID -Verbose:$false
                Write-Debug "Process has $($ChildProcesses.Count - 1) child processes"

                foreach ($SpawnedProcessID in $ChildProcesses) {
                    $SpawnedProcess = Get-Process -Id $SpawnedProcessID

                    if ($SpawnedProcess.MainWindowHandle -ne [IntPtr]::Zero) {
                        $WindowTextLen = [User32]::GetWindowTextLength($SpawnedProcess.MainWindowHandle) + 1

                        [System.Text.StringBuilder]$sb = [System.Text.StringBuilder]::new($WindowTextLen)
                        $null = [User32]::SendMessage($SpawnedProcess.MainWindowHandle, $WM_GETTEXT, $WindowTextLen, $sb)

                        $windowTitle = $sb.Tostring()
                        $style = [User32]::GetWindowLong($SpawnedProcess.MainWindowHandle, $GWL_STYLE)
                        [User32+RECT]$RECT = New-Object 'User32+RECT'
                        [User32]::GetWindowRect($SpawnedProcess.MainWindowHandle, [ref]$RECT)
                        $WindowWidth  = $RECT.Right - $RECT.Left
                        $WindowHeight = $RECT.Bottom - $RECT.Top

                        if ([User32]::IsWindowVisible($SpawnedProcess.MainWindowHandle) -and $WindowWidth -gt 0 -and $WindowHeight -gt 0) {
                            $InteractableWindowOpen = $true
                        }

                        Write-Debug "Process $($SpawnedProcess.ID) ('$($SpawnedProcess.ProcessName)') has main window:"
                        Write-Debug "  Window $($SpawnedProcess.MainWindowHandle), TitleCaption '${windowTitle}', IsVisible: $([User32]::IsWindowVisible($SpawnedProcess.MainWindowHandle)), IsDisabled: $(($style -band $WS_DISABLED) -eq $WS_DISABLED), Style: $('{0:X}' -f $style), Size: $WindowWidth x $WindowHeight"
                    }

                    if ($SpawnedProcess.Threads.ThreadState -ne 'Wait') {
                        $AllThreadsWaiting = $false
                    } else {
						Write-Debug "Process $($SpawnedProcess.ID) ('$($SpawnedProcess.ProcessName)') All threads are waiting:"
						'  ' + ($SpawnedProcess.Threads.WaitReason | Group-Object -NoElement | Sort-Object Count -Descending | % { "$($_.Count)x $($_.Name)" } ) -join ", " | Write-Debug
                    }

                    foreach ($Thread in $SpawnedProcess.Threads) {
                        $ThreadWindows = [System.Collections.Generic.List[IntPtr]]::new()
                        $null = [User32]::EnumThreadWindows($thread.id, { Param($hwnd, $lParam) $ThreadWindows.Add($hwnd) }, [System.IntPtr]::Zero)

                        foreach ($window in $ThreadWindows) {
                            $WindowTextLen = [User32]::GetWindowTextLength($window) + 1

                            [System.Text.StringBuilder]$sb = [System.Text.StringBuilder]::new($WindowTextLen)
                            $null = [User32]::SendMessage($window, $WM_GETTEXT, $WindowTextLen, $sb)

                            $windowTitle = $sb.Tostring()
                            $style = [User32]::GetWindowLong($window, $GWL_STYLE)
                            [User32+RECT]$RECT = New-Object 'User32+RECT'
                            [User32]::GetWindowRect($window, [ref]$RECT)
                            $WindowWidth  = $RECT.Right - $RECT.Left
                            $WindowHeight = $RECT.Bottom - $RECT.Top

                            if ([User32]::IsWindowVisible($window) -and $WindowWidth -gt 0 -and $WindowHeight -gt 0) {
                                $InteractableWindowOpen = $true
                            }

                            Write-Debug "Process $($SpawnedProcess.ID) ('$($SpawnedProcess.ProcessName)'), Thread $($thread.id) in state $($thread.ThreadState) ($($thread.WaitReason)) has window:"
                            Write-Debug "  Window ${window}, TitleCaption '${windowTitle}', IsVisible: $([User32]::IsWindowVisible($window)), IsDisabled: $(($style -band $WS_DISABLED) -eq $WS_DISABLED), Style: $('{0:X}' -f $style), Size: $($RECT.Right - $RECT.Left) x $($RECT.Bottom - $RECT.Top)"
                        }
                    }
                }
            }

            Write-Debug "CONCLUSION: The process looks $( if ($InteractableWindowOpen -and $AllThreadsWaiting) { 'blocked' } else { 'normal' } )."
            Write-Debug ""
            Start-Sleep -Seconds 30
        }

        Start-Sleep -Milliseconds 200
    }

    # Print any unhandled / unexpected errors as warnings
    if ($PowerShell.Streams.Error.Count -gt 0) {
        foreach ($ErrorRecord in $PowerShell.Streams.Error.ReadAll()) {
            Write-Warning $ErrorRecord
        }
    }

    $PowerShell.Runspace.Dispose()
    $PowerShell.Dispose()

    # Test for NULL before indexing into array. RunspaceStandardOut can be null
    # when the runspace aborted abormally, for example due to an exception.
    if ($null -ne $RunspaceStandardOut -and $RunspaceStandardOut.Count -gt 0) {
        switch ($RunspaceStandardOut[-1].HandledError) {
            # Success case
            0 {
                $NonEmptyPredicate = [Predicate[string]] { -not [string]::IsNullOrWhiteSpace($args[0]) }

                $StdOutFirstNonEmpty = [array]::FindIndex([string[]]$RunspaceStandardOut[-1].StandardOutput, $NonEmptyPredicate)
                if ($StdOutFirstNonEmpty -ne -1) {
                    $StdOutLastNonEmpty = [array]::FindLastIndex([string[]]$RunspaceStandardOut[-1].StandardOutput, $NonEmptyPredicate)
                    $StdOutTrimmed = $RunspaceStandardOut[-1].StandardOutput[$StdOutFirstNonEmpty..$StdOutLastNonEmpty]
                } else {
                    $StdOutTrimmed = @()
                }

                $StdErrFirstNonEmpty = [array]::FindIndex([string[]]$RunspaceStandardOut[-1].StandardError, $NonEmptyPredicate)
                if ($StdErrFirstNonEmpty -ne -1) {
                    $StdErrLastNonEmpty = [array]::FindLastIndex([string[]]$RunspaceStandardOut[-1].StandardError, $NonEmptyPredicate)
                    $StdErrTrimmed = $RunspaceStandardOut[-1].StandardError[$StdErrFirstNonEmpty..$StdErrLastNonEmpty]
                } else {
                    $StdErrTrimmed = @()
                }

                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::NONE,
                    [ProcessReturnInformation]@{
                        'FilePath'         = $ExeAndArgs.Executable
                        'Arguments'        = $ExeAndArgs.Arguments
                        'WorkingDirectory' = $Path
                        'StandardOutput'   = $StdOutTrimmed
                        'StandardError'    = $StdErrTrimmed
                        'ExitCode'         = $RunspaceStandardOut[-1].ExitCode
                        'Runtime'          = $RunspaceStandardOut[-1].Runtime
                    }
                )
            }
            # Error cases that are handled explicitly inside the runspace
            1 {
                Write-Warning "No new process was created or a handle to it could not be obtained."
                Write-Warning "Executable was: '$($ExeAndArgs.Executable)' - this should *probably* not have happened"
                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::PROCESS_NONE_CREATED,
                    $null
                )
            }
            2 {
                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::UNKNOWN,
                    $null
                )
            }
            5 {
                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::ACCESS_DENIED,
                    $null
                )
            }
            740 {
                if (-not $FallbackToShellExecute) {
                    Write-Warning "This process requires elevated privileges - falling back to ShellExecute, consider running PowerShell as Administrator"
                    Write-Warning "Process output cannot be captured when running with ShellExecute!"
                    return (Invoke-PackageCommand -Path:$Path -Command:$Command -FallbackToShellExecute)
                } else {
                    return [ExternalProcessResult]::new(
                        [ExternalProcessError]::PROCESS_REQUIRES_ELEVATION,
                        $null
                    )
                }
            }
            193 {
                if (-not $FallbackToShellExecute) {
                    Write-Warning "The file to be run is not an executable - falling back to ShellExecute"
                    return (Invoke-PackageCommand -Path:$Path -Command:$Command -FallbackToShellExecute)
                } else {
                    return [ExternalProcessResult]::new(
                        [ExternalProcessError]::FILE_NOT_EXECUTABLE,
                        $null
                    )
                }
            }
        }
    } else {
        Write-Warning "The external process runspace did not run to completion because an unexpected error occurred."
        return [ExternalProcessResult]::new(
            [ExternalProcessError]::RUNSPACE_DIED_UNEXPECTEDLY,
            $null
        )
    }

    Write-Warning "An unexpected error occurred when trying to run the extenral process."
    return [ExternalProcessResult]::new(
        [ExternalProcessError]::UNKNOWN,
        $null
    )
}
