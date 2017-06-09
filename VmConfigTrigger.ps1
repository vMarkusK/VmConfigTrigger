﻿ #Requires -Version 4
 #Requires -Modules VMware.VimAutomation.Core, @{ModuleName="VMware.VimAutomation.Core";ModuleVersion="6.3.0.0"}
 [CmdletBinding()]
param( 
    [Parameter(Mandatory=$True, ValueFromPipeline=$False, Position=0)]
    [ValidateNotNullorEmpty()]
        [String] $VIServer,
    [Parameter(Mandatory=$false, ValueFromPipeline=$False, Position=1)]
    [ValidateNotNullorEmpty()]
        [int] $SleepTimer = 300,
        [Parameter(Mandatory=$false, ValueFromPipeline=$False, Position=1)]
    [ValidateNotNullorEmpty()]
        [bool] $Test = $False
)

<#
.Synopsis
   Write-Log writes a message to a specified log file with the current time stamp.
.DESCRIPTION
   The Write-Log function is designed to add logging capability to other scripts.
   In addition to writing output and/or verbose you can write to a log file for
   later debugging.
.NOTES
   Created by: Jason Wasser @wasserja
   Modified: 11/24/2015 09:30:19 AM  

   Changelog:
    * Code simplification and clarification - thanks to @juneb_get_help
    * Added documentation.
    * Renamed LogPath parameter to Path to keep it standard - thanks to @JeffHicks
    * Revised the Force switch to work as it should - thanks to @JeffHicks

   To Do:
    * Add error handling if trying to create a log file in a inaccessible location.
    * Add ability to write $Message to $Verbose or $Error pipelines to eliminate
      duplicates.
.PARAMETER Message
   Message is the content that you wish to add to the log file. 
.PARAMETER Path
   The path to the log file to which you would like to write. By default the function will 
   create the path and file if it does not exist. 
.PARAMETER Level
   Specify the criticality of the log information being written to the log (i.e. Error, Warning, Informational)
.PARAMETER NoClobber
   Use NoClobber if you do not wish to overwrite an existing file.
.EXAMPLE
   Write-Log -Message 'Log message' 
   Writes the message to c:\Logs\PowerShellLog.log.
.EXAMPLE
   Write-Log -Message 'Restarting Server.' -Path c:\Logs\Scriptoutput.log
   Writes the content to the specified log file and creates the path and file specified. 
.EXAMPLE
   Write-Log -Message 'Folder does not exist.' -Path c:\Logs\Script.log -Level Error
   Writes the message to the specified log file as an error message, and writes the message to the error pipeline.
.LINK
   https://gallery.technet.microsoft.com/scriptcenter/Write-Log-PowerShell-999c32d0
#>
function Write-Log
{
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory=$true,
                   ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias("LogContent")]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [Alias('LogPath')]
        [string]$Path=$LogPath,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("Error","Warn","Info")]
        [string]$Level="Info",
        
        [Parameter(Mandatory=$false)]
        [switch]$NoClobber
    )

    Begin
    {
        # Set VerbosePreference to Continue so that verbose messages are displayed.
        $VerbosePreference = 'Continue'
    }
    Process
    {
        
        # If the file already exists and NoClobber was specified, do not write to the log.
        if ((Test-Path $Path) -AND $NoClobber) {
            Write-Error "Log file $Path already exists, and you specified NoClobber. Either delete the file or specify a different name."
            Return
            }

        # If attempting to write to a log file in a folder/path that doesn't exist create the file including the path.
        elseif (!(Test-Path $Path)) {
            Write-Verbose "Creating $Path."
            $NewLogFile = New-Item $Path -Force -ItemType File
            }

        else {
            # Nothing to see here yet.
            }

        # Format Date for our Log File
        $FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        # Write message to error, warning, or verbose pipeline and specify $LevelText
        switch ($Level) {
            'Error' {
                Write-Error $Message
                $LevelText = 'ERROR:'
                }
            'Warn' {
                Write-Warning $Message
                $LevelText = 'WARNING:'
                }
            'Info' {
                Write-Verbose $Message
                $LevelText = 'INFO:'
                }
            }
        
        # Write log entry to $Path
        "$FormattedDate $LevelText $Message" | Out-File -FilePath $Path -Append -Encoding utf8
    }
    End
    {
    }
}

#region: Main Loop
do{
    #region: Clear stuff
    $error.clear()
    #endregion
    
    #region: sleep and variables
    sleep -Seconds $SleepTimer
    cls
    $Date = $(get-date -format 'MMddyyyy-hhmmss')
    $LogPath = "$PSScriptRoot\Output-$Date.txt"
    $ErrorPath = "$PSScriptRoot\Error-$Date.txt"   
    #endregion

    #region: Clean Log Files an start new log number
    Get-ChildItem $PSScriptRoot | Where-Object {$_.Name -match "Output-\d{8}\-\d{6}.txt"} | sort CreationTime -desc | select -Skip 10 | Remove-Item -Force
    Get-ChildItem $PSScriptRoot | Where-Object {$_.Name -match "Error-\d{8}\-\d{6}.txt"} | sort CreationTime -desc | select -Skip 10 | Remove-Item -Force
    Write-Log -Message "vmConfigTrigger log Number $date starts"
    #endregion

    #region: Start vCenter Connection
    Write-Log -Message "Starting to Process vCenter Connection to $VIServer ..."
    $OpenConnection = $global:DefaultVIServer | where { $_.Name -eq $VIServer }
    if($OpenConnection.IsConnected) {
        Write-Log -Message "vCenter is Already Connected..."
        $VIConnection = $OpenConnection
        } else {
	        Write-Log -Message "Connecting vCenter..."
	        $VIConnection = Connect-VIServer -Server $VIServer
            }

    if (-not $VIConnection.IsConnected) {
        Write-Log -Message "vCenter Connection Failed" -Level Error
        }
    #endregion

    #region: Read Json Config
    ## Schema Example:
    ##[
    ##    {
    ##        "Name": "test",
    ##        "RAM": "",
    ##        "CPU": "+1"
    ##        "Start": "no"
    ##    },
    ##    {
    ##        "Name": "test2",
    ##        "RAM": "+1",
    ##        "CPU": ""
    ##        "Start": "yes"
    ##    }
    ##]
    [Array] $Configs = Get-Content -Raw -Path "$PSScriptRoot\Config.json" | ConvertFrom-Json
    #endregion

    #region: Process Config
    ## Reads all VM names in the Config and compares them with poweredoff VMs in vCenter Inventory
    ## When VM is identified the given configuration is done
    if ($Configs) {
        Write-Log -Message "'$($Configs.count)' VMs were found in Config File to Process."

        foreach ($Config in $Configs) {
            $VmFilter = @{"Runtime.PowerState" ="poweredOff"; "Name" = $Config.name}
            [Array] $FilteredPoweredOffVms = Get-View -ViewType "VirtualMachine" -Property Name, Runtime, Config -Filter $VmFilter
            Write-Log -Message "'$($FilteredPoweredOffVms.count)' VMs found with matching Name: '$($Config.name)'"
            if ($FilteredPoweredOffVms) {
                foreach ($FilteredPoweredOffVm in $FilteredPoweredOffVms) {
                    $VmChanged = $false
                    if ($FilteredPoweredOffVm.Name -eq $Config.Name) {
                        Write-Log -Message "VM '$($FilteredPoweredOffVms.Name)' Unique Identified!" 
        
                        If ($($Config.RAM)) {
                            Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': Requested RAM Change: '$($Config.RAM)' GB."
                            Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': Actual RAM: '$(($FilteredPoweredOffVm.Config.Hardware.MemoryMB) / 1024)' GB."
                            Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': New RAM: '$($Config.RAM)' GB."
                            if ($(($FilteredPoweredOffVm.Config.Hardware.MemoryMB) / 1024) -ne $($Config.RAM)) {
                                Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': RAM need to be changed."
                                if ($Test -eq $False) {
                                    $VmSpec = New-Object –Type VMware.Vim.VirtualMAchineConfigSpec –Property @{“MemoryMB” = $([single]($Config.RAM) * 1024)}
                                    $Trash = $FilteredPoweredOffVm.ReconfigVM($VmSpec)
                                    Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': RAM changed."
                                    $VmChanged = $true
                                    Remove-Variable -Name VmSpec, Trash
                                    }
                                    else {
                                        Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': RAM NOT changed, Test Mode requested."
                                        }
                                        
                                }
                                Else {
                                    Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': RAM already fine."
                                    }
                            }
                        If ($($Config.CPU)) {
                            Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': Requested CPU Change: '$($Config.CPU)' vCPU."
                            Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': Actual vCPUs: '$($FilteredPoweredOffVm.Config.Hardware.NumCpu)'."
                            Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': New vCPUs: '$($Config.CPU)'."
                            if ($($FilteredPoweredOffVm.Config.Hardware.NumCPU) -ne $($Config.CPU)) {
                                Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': vCPUs need to be changed."
                                if ($Test -eq $False) {
                                    $VmSpec = New-Object –Type VMware.Vim.VirtualMAchineConfigSpec –Property @{“NumCPUs” = $Config.CPU}
                                    $Trash = $FilteredPoweredOffVm.ReconfigVM($VmSpec)
                                    Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': vCPUs changed."
                                    $VmChanged = $true
                                    Remove-Variable -Name VmSpec, Trash
                                    }
                                    else {
                                        Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': vCPUs NOT changed, Test Mode requested."
                                        }
                                }
                                Else {
                                    Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': vCPUs already fine."
                                    }
                            }
                        if ($VmChanged -eq $true) {
                            Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': Was changed."
                            If ($($Config.Start) -eq "yes") {
                                Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': Needs to powered on."
                                $Trash = $FilteredPoweredOffVm.PowerOnVM_Task($null)
                                Remove-Variable -Name Trash
                                }
                                elseIf ($($Config.Start) -eq "no") {
                                    Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': Needs NOT to powered on."
                                    }
                                    else {
                                        Write-Log -Message "VM '$($FilteredPoweredOffVm.Name)': Invalid Start configuration."
                                        }
                            }    
        
                        }
                        Else {
                            Write-Log -Message "Name: '$($Config.Name)' Not Unique Identified in VM '$($FilteredPoweredOffVm.Name)'!" -Level Warn
                            }
                    }
                }  
            }

        }
        else {
            Write-Log -Message "Failed to Read Config File!" -Level Warn
            }  
    #endregion

    #region: Error Handling
    if ($error.Count -ne 0) {
        Write-Log -Message "A Global Error occured, Script will stop! Problem needs to be resolved and then the Script can be restarted. `n$($error) " -Level Error
        "Last Error: " +  $($error[0]) | Out-File -FilePath $ErrorPath -Append -Encoding utf8
        } 
    #endregion

    #region: Finalize log number and cleanup
    Write-Log -Message "vmConfigTrigger log Number $date ends"
    Remove-Variable -Name Config, Configs, Date, FilteredPoweredOffVm, FilteredPoweredOffVms, VmChanged, VmFilter, LogPath, ErrorPath, OpenConnection, VIConnection
    #endregion
}
while ($error.Count -eq 0)
#endregion
