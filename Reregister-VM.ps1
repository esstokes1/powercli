<#
.SYNOPSIS
    Unregister and re-register a VM
.DESCRIPTION
    Unregister and re-register a VM.  The VM will be placed back into the same resource pool and folder.
.PARAMETER vcserver
    Required: The FQDN/IP of the vCenter Server.
.PARAMETER vmname
    Required: The name of the VM as it appears in vCenter. VM names that contain spaces should be placed
    inside double quotes. Please see examples.
.PARAMETER nopower
    Optional: Do not power on the VM after registering it back. By default the VM will be powered on.
.EXAMPLE
    E:\ve\cli\bin\Reregister-VM.ps1 -vcserver vemembo1.ve.fedex.com -vmname "BACKENDS WIPRO WAVE5 - 008"
.EXAMPLE
    E:\ve\cli\bin\Reregister-VM.ps1 -vcserver vemembo1.ve.fedex.com -vmname "BACKENDS WIPRO WAVE5 - 008" -nopower

.NOTES
    Author: Eric Stokes
    Date:   October 15, 2014
#>

Param(
[Parameter(mandatory = $true,HelpMessage="VC Server")] [String] $vcserver,
[Parameter(mandatory = $true,HelpMessage="Name of the VM")] [String] $vmname,
[Parameter(mandatory = $false,HelpMessage="Do not power on")][Switch] $nopower
)

# source setenv for extra functions and variables
. .\setenv.ps1

# this should be added to setenv.ps1
$global:winuser = [Environment]::UserName

viconnect $vcserver

$vm = get-vm -name $vmname -server $vcserver
if (-not($vm)) {
  write-host "$vmname not found on $vcserver " -foregroundcolor "red"

} elseif  ($vm -is [system.array]) {
  write-host "multiple VMs named '$vmname' found on $vcserver " -foregroundcolor "red"

} elseif ($vm.powerState.toString().toLower() -eq "poweredon") {
  write-host "$vmname is in powered on state and cannot be removed from inventory " -foregroundcolor "red"

} else {
  write-host "found $vmname - getting current configuration" -foregroundcolor "cyan"
  $resourcePool = $vm.resourcePool
  $vmhost = $vm.vmhost
  $folder = $vm.folder
  $vmxPath = $vm.extensionData.summary.config.vmPathName
  write-host "  VMhost - $($vmhost.name) " -foregroundcolor "cyan"
  write-host "  folder - $($folder.name) " -foregroundcolor "cyan"
  write-host "  vmx location - $vmxPath " -foregroundcolor "cyan"
  echo ""

  write-host "unregistering $vmname" -foregroundcolor "cyan"
  remove-vm -vm $vm -confirm:$false
  echo ""

  write-host "re-registering $vmname : " -foregroundcolor "cyan"
  echo ""
  $regvm = new-vm -resourcePool $vm.resourcePool -location $vm.folder -VMFilePath $vm.extensionData.summary.config.vmPathName
  if ($regvm) {
    write-host "$vmname re-registered successfully" -foregroundcolor "green"

    if ($nopower) {
      write-host "$vmname not being powered on " -foregroundcolor "cyan"
    } else {
      write-host "powering on $vmname " -foregroundcolor "cyan"
      start-vm -vm $regvm -confirm:$false
    }

  } else {
    write-host "error re-registering $vmname" -foregroundcolor "red"
  }
  echo ""

}
