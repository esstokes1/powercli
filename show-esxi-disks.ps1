<#
.SYNOPSIS
    Display vSAN information and controller/disk information for a particular ESXi server
.DESCRIPTION
    Displays the disks associated with each vSAN disk group along with the physical disks
    attached to each storage controller
.PARAMETER vcserver
    Required: The FQDN/IP of the VC Server
.PARAMETER datacenter
    Required: The name of the datacenter 
.PARAMETER cluster
    Required: The name of the cluster 
.PARAMETER esxi
    Required: The name of the ESXi servers

.EXAMPLE
show-esxi-disks.ps1 -vcserver vcsa1.corp.local -datacenter VCSA1 -cluster VSAN01 -esxi esxi01.corp.local

Sample Output:
connecting to vcsa1.corp.local
getting vSAN info for esxi01.corp.local - 2 disk groups
Disk group (02000000005000cca0820126e8454f30303038)
cache disk(s):
        vmhba3:C0:T67:L0
capacity disk(s): 5 disks total
        vmhba3:C0:T66:L0
        vmhba3:C0:T65:L0
        vmhba3:C0:T69:L0
        vmhba3:C0:T68:L0
        disk error - vsan:52f981cb-9e25-d151-ddee-31af3584322d

Disk group (02000000005000cca0820126ec454f30303038)
cache disk(s):
        vmhba0:C0:T67:L0
capacity disk(s): 5 disks total
        vmhba0:C0:T64:L0
        vmhba0:C0:T69:L0
        vmhba0:C0:T68:L0
        vmhba0:C0:T66:L0
        vmhba0:C0:T65:L0

getting storage controllers...
HPE Smart Array E208i-a SR Gen10 in Slot 0 (Embedded)  (sn: PEYHB0BRHA50LK) : 6 disks total
              physicaldrive 1I:1:1 (port 1I:box 1:bay 1, SAS SSD, 800 GB, OK)
              physicaldrive 1I:1:2 (port 1I:box 1:bay 2, SATA SSD, 1.9 TB, OK)
              physicaldrive 1I:1:3 (port 1I:box 1:bay 3, SATA SSD, 1.9 TB, OK)
              physicaldrive 1I:1:4 (port 1I:box 1:bay 4, SATA SSD, 1.9 TB, OK)
              physicaldrive 2I:1:5 (port 2I:box 1:bay 5, SATA SSD, 1.9 TB, OK)
              physicaldrive 2I:1:6 (port 2I:box 1:bay 6, SATA SSD, 1.9 TB, OK)

HPE Smart Array E208i-p SR Gen10 in Slot 3  (sn: PEYHL0ARCAC0QZ) : 2 disks total
              physicaldrive 1I:6:1 (port 1I:box 6:bay 1, SATA SSD, 480 GB, OK)
              physicaldrive 1I:6:2 (port 1I:box 6:bay 2, SATA SSD, 480 GB, OK)

HPE Smart Array E208i-p SR Gen10 in Slot 4  (sn: PEYHL0ARCAC0P5) : 0 disks total

HPE Smart Array E208i-p SR Gen10 in Slot 5  (sn: PEYHL0ARC93001) : 5 disks total
              physicaldrive 1I:2:1 (port 1I:box 2:bay 1, SAS SSD, 800 GB, OK)
              physicaldrive 1I:2:2 (port 1I:box 2:bay 2, SATA SSD, 1.9 TB, OK)
              physicaldrive 1I:2:3 (port 1I:box 2:bay 3, SATA SSD, 1.9 TB, OK)
              physicaldrive 2I:2:5 (port 2I:box 2:bay 5, SATA SSD, 1.9 TB, OK)
              physicaldrive 2I:2:6 (port 2I:box 2:bay 6, SATA SSD, 1.9 TB, OK)

.NOTES
    Author: Eric Stokes
    Date:   April 30, 2018
    Tested: Get-PowerCLIVersion - VMware PowerCLI 10.0.0 build 7895300

#>

Param(
[Parameter(mandatory = $true)] [String] $vcserver,
[Parameter(mandatory = $true)] [String] $datacenter,
[Parameter(mandatory = $true)] [String] $cluster,
[Parameter(mandatory = $true)] [String] $esxi
)

# connect to vCenter - make sure there is only a single connection
function viconnect {
param([string]$vsserver)
  if (($global:defaultVIServers).name -contains $vsserver) {
    write-host "already connected to $vsserver" -foregroundcolor "green"
  } else {
    write-host "connecting to $vsserver" -foregroundcolor "cyan"
    connect-viserver -server $vsserver -wa silentlycontinue | out-null
  }
}

# connect to VC if not already connected
viconnect $vcserver

# get the datacenter object
$dc = get-datacenter -server $vcserver -name $datacenter -ea silentlycontinue
if (-not $dc) {
  write-host "`nUnable to find $datacenter in $vcserver`n" -foregroundcolor "red"
  exit 1
}

# get the cluster
$cl = get-cluster -name $cluster -location $dc -ea silentlycontinue
if (-not $cl) {
  write-host "`nUnable to find $cluster in $datacenter`n" -foregroundcolor "red"
  exit 1
}

# get the ESXi
$vmhost = get-vmhost -name $esxi -location $cl -ea silentlycontinue
if (-not $vmhost) {
  write-host "`nUnable to find $esxi in $cluster`n" -foregroundcolor "red"
  exit 1
}

# show disks in each disk group
$dgs = Get-VsanDiskGroup -vmhost $vmhost
write-host "getting vSAN info for $($vmhost.name) - $($dgs.length) disk groups" -foregroundcolor "green"
foreach ($dg in $dgs) {
  write-host "$($dg.name)" -foregroundcolor "cyan"

  # display the cache disks
  write-host "cache disk(s):" -foregroundcolor "green"
  foreach ($ssd in $dg.extensionData.ssd) {
    if ($ssd.operationalState[0] -ne "ok") {
      write-host "`tcache disk error - $($ssd.canonicalName)" -foregroundcolor "red"
    } else {
      $naa = $ssd.canonicalName
      $vmhba = $esxcli.storage.nmp.path.list($naa,$null).runtimeName
      write-host "`t$vmhba" -foregroundcolor "cyan"
    }
  }

  # display the capacity disks
  write-host "capacity disk(s): $($dg.extensionData.nonSsd.length) disks total" -foregroundcolor "green"
  foreach ($ssd in $dg.extensionData.nonSsd) {
    if ($ssd.operationalState[0] -ne "ok") {
      write-host "`tdisk error - $($ssd.canonicalName)" -foregroundcolor "red"
    } else {
      $naa = $ssd.canonicalName
      $vmhba = $esxcli.storage.nmp.path.list($naa,$null).runtimeName
      write-host "`t$vmhba" -foregroundcolor "cyan"
    }
  }  
  echo ""
}

# now show disks on each controller
$esxcli = get-esxcli -vmhost $vmhost

# list controllers and physical disks for HP/HPE servers
if ($vmhost.extensionData.hardware.systemInfo[0].vendor.startsWith("HP")) {
  write-host "getting storage controllers..." -foregroundcolor "green"

  # check each controller
  $ctrls = $esxcli.ssacli.cmd("ctrl all show").split("`n")
  foreach ($ctrl in $ctrls) {

    # find character index for string Slot
    $index = $ctrl.indexOf("Slot ")
    $slot = $ctrl.substring(($index+5),2).replace(" ","")

    # build the query string for ssacli
    $ctrlQuery = "ctrl slot="+ $slot +" pd all show"

    # find the disks on the controller
    $disks = $esxcli.ssacli.cmd($ctrlQuery).split("`n") | where {$_.contains("physicaldrive")}
    write-host "$ctrl : $($disks.length) disks total" -foregroundcolor "green"

    # display each disk on the controller
    foreach ($disk in $disks) {
      write-host "`t$disk" -foregroundcolor "green"
    }
    echo ""
  }

# dont know how to list controllers for other vendors yet
} else {
  write-host "unable to list controllers/disks for $($vmhost.extensionData.hardware.systemInfo[0].vendor)" -foregroundcolor "red"
}

disconnect-viserver -server $vcserver -confirm:$false
