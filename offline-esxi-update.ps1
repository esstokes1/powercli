<#
.SYNOPSIS
    Update ESXi using offline zip file
.DESCRIPTION
    Updates host(s) with VIBs from a zipfile. Host will be placed into maintenance-mode before applying
    the update and will be rebooted after the update is applied. HA may need to be disabled for hosts
    to get into maintenance-mode. If using datastorePath then zipfile needs to be placed on a datastore 
    that all hosts in the cluster can access.
.PARAMETER vcserver
    Required: The FQDN/IP of the VC Server
.PARAMETER cluster
    Required: The cluster to update. A rolling update on the entire cluster will be performed by updating
    a single host at a time.
.PARAMETER datastorePath
    Required: The full-path to the zipfile on the ESXi datastore
.PARAMETER localPath
    Optional: The full-path to the zipfile on the local host. This should be used only if you want this
    script to copy the zipfile to the datastore. Must be used in conjuction with the datastore parameter.
.PARAMETER datasore
    Optional: The shared datastore to copy the zipfile to. This should be used only if you want this script
    to copy the zipfile to the datastore. Must be used in conjuction with the localpath parameter.
.PARAMETER validate
    Optional: Set to $true if you only want to do a dry-run of the update and not actually perform the update
.EXAMPLE
    offline-esxi-update.ps1 -vcserver 172.16.2.22 -cluster Cluster1 -datastorePath /var/updates/update-from-esxi5.5-5.5_update02.zip -validate
.EXAMPLE
    offline-esxi-update.ps1 -vcserver 172.16.2.22 -cluster Cluster1 -datastorePath /var/updates/update-from-esxi5.5-5.5_update02.zip
.EXAMPLE
    offline-esxi-update.ps1 -vcserver 172.16.2.22 -cluster Admin1 -localPath E:\Temp\update-from-esxi5.0-5.0_update03.zip -datastore VMAX1234-024AC-Admin1 -validate
.EXAMPLE
    offline-esxi-update.ps1 -vcserver 172.16.2.22 -cluster Admin1 -localPath E:\Temp\update-from-esxi5.0-5.0_update03.zip -datastore VMAX1234-024AC-Admin1

.NOTES
    Author: Eric Stokes
    Date:   October 29, 2013
#>

Param(
[Parameter(mandatory = $true)] [String] $vcserver,
[Parameter(mandatory = $true)] [String] $cluster,
[Parameter(HelpMessage="Full-path to offline zip file on the VMFS datastore")] [String] $datastorePath,
[Parameter(HelpMessage="full-directory path to the zipfile locally")] [String] $localPath,
[Parameter(HelpMessage="Datastore to copy zipfile to")] [String] $datastore,
[Parameter()] [Switch] $validate
)

# this is the function that updates a single host
# first we do a dry-run to make sure update need to be applied
# puts the host in mx-mode
# applies the update
# reboots the host
# takes the host out of mx-mode
function updateHost {
  write-host "checking $vmhost for update" -foregroundcolor "cyan"

  $esxihost = get-vmhost -name $vmhost
  $esxcli = get-esxcli -vmhost $esxihost

  # dry-run
  $dryrun = $esxcli.software.vib.update($datastorePath,$true,$null,$null,$null,$null,$null,$null,$null) 
  $vibsToInstall = [int]$dryrun.VIBsInstalled.length
  $vibsToRemove = [int]$dryrun.VIBsRemoved.length
  if (($vibsToInstall -gt 0) -and (-not($validate))) {
    write-host "putting $vmhost into mx-mode" -foregroundcolor "cyan"
    $task = $esxihost.ExtensionData.EnterMaintenanceMode_Task(0,$true)
    sleep 10

    # make sure we are mx-mode and no vms on the host
    # log if this seems to be taking a long time
    $counter = 0
    while (($esxihost.ExtensionData.Runtime.inMaintenanceMode -eq $false) -and ($esxihost.ExtensionData.vm -ne 0)) {
      $counter++
      # if this is taking a long time then log a warning message (> 4 minutes)
      if (($counter % 24) -eq 0) {
        write-host "$vmhost taking a long time to go into mx-mode" -foregroundcolor "yellow"
        $counter = 1
      }
      sleep 10
      $esxihost.ExtensionData.UpdateViewData()
    }

    write-host "updating ESXi patches on $vmhost" -foregroundcolor "cyan"
    $update = $esxcli.software.vib.update($datastorePath,$null,$null,$null,$null,$null,$null,$null,$null) 
    $msg = $update.Message.toString()
    write-host "$vmhost returned message : $msg" -foregroundcolor "cyan"
    sleep 2

    $esxihost.ExtensionData.UpdateViewData()
    # make sure the host disconnects from vcenter
    if ($esxihost.ExtensionData.Runtime.inMaintenanceMode -eq $true) {
      write-host "rebooting $vmhost" -foregroundcolor "cyan"
      restart-vmhost -vmhost $esxihost -confirm:$false | out-null
      while ($esxihost.ExtensionData.Summary.Runtime.connectionState.toString().toLower() -eq "connected") {
        sleep 5
        $esxihost.ExtensionData.UpdateViewData()
      }

      # wait for the host to reconnect to vcenter
      $counter = 0
      while ($esxihost.ExtensionData.Summary.Runtime.connectionState.toString().toLower() -ne "connected") {
        $counter++
        # if this is taking a long time then log a warning message (> 5 minutes)
        if (($counter % 30) -eq 0) {
          write-host "$vmhost taking a long time to go reboot" -foregroundcolor "yellow"
          $counter = 1
        }
        sleep 10
        $esxihost.ExtensionData.UpdateViewData()
      }

      # exit mx-mode
      write-host "taking $vmhost out of mx-mode" -foregroundcolor "yellow"
      $task = $esxihost.ExtensionData.ExitMaintenanceMode_Task(0)
      sleep 10

      # make sure we exit mx-mode
      # log if this seems to be taking a long time
      $counter = 0
      while ($esxihost.ExtensionData.Runtime.inMaintenanceMode -eq $true) {
        $counter++
        # if this is taking a long time then log a warning message (> 4 minutes)
        if (($counter % 24) -eq 0) {
          write-host "$vmhost taking a long time to go exit mx-mode" -foregroundcolor "yellow"
          $counter = 1
        }
        sleep 10
        $esxihost.ExtensionData.UpdateViewData()
      }
      
    } else {
      write-host "$vmhost not in mx-mode so cannot reboot" -foregroundcolor "red"
      write-host "stopping update on $cluster" -foregroundcolor "red"
      exit
    }
  } else {
    write-host "$vmhost not being updated" -foregroundcolor "cyan"
    write-host "$vmhost : $vibsToInstall vib(s) would be installed & $vibsToRemove vib(s) would be removed" -foregroundcolor "cyan"
  }
}

# source setenv for extra functions and variables
. .\setenv.ps1

# check to see which arguments we received
if (($vcserver) -and ($cluster)) {
  viconnect $vcserver   # function from setenv.ps1

  if (($datastore) -and ($localPath)) {
    if (Test-Path $localPath -PathType Leaf) {
      $pathlen = $localPath.split("\").length
      $zipfile = $localPath.split("\")[$pathlen-1]
 
      $datastorePath = "/vmfs/volumes/"+ $datastore +"/"+ $zipfile
      write-host "copying $localPath to $datastorePath" -foregroundcolor "cyan"
      $ds = get-datastore $datastore
      copy-datastoreitem $localPath $ds.datastorebrowserpath

    } else {
      write-host "$localPath doesnt exist - exiting now" -foregroundcolor "red"
      exit
    }

  }

  # get all the hosts in the cluster
  get-vmhost -location (get-cluster $cluster) | foreach-object {
    echo ""
    $vmhost = $_.Name
    updateHost
    echo ""
    sleep 10
  }
} else {
  write-host "incorrect arguments supplied - please see get-help offline-esxi-update.ps1 for examples" -foregroundcolor "red"
}
