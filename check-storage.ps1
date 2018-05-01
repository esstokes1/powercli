<#
.SYNOPSIS
    Display formatted and unformatted disk information on each ESXi server 
    in the cluster
.DESCRIPTION
    Capacity and format information for each disk in the cluster is displayed  
.PARAMETER vcserver
    Required: The FQDN/IP of the VC Server
.PARAMETER datacenter
    Required: The name of the datacenter
.PARAMETER cluster
    Required: The name of the cluster

.EXAMPLE
check-storage.ps1 -vcserver vcsa1.corp.local -datacenter VCSA1 -cluster VSAN01

.NOTES
    Author: Eric Stokes
    Date:   May 31, 2017
    Tested: Get-PowerCLIVersion - VMware PowerCLI 10.0.0 build 7895300

#>

Param(
[Parameter(mandatory = $true)] [String] $vcserver,
[Parameter(mandatory = $true)] [String] $datacenter,
[Parameter(mandatory = $true)] [String] $cluster
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

# display the information about the disks
function printVmhostStorageInfo {
param($myVmhost)

  # get esxcli commands
  $esxcli = get-esxcli -vmhost $myVmhost

  # get all current formatted disks
  $vmhostStorage = @{}
  get-datastore -vmhost $myVmhost | where-object {$_.extensionData.info.getType().name -eq "VmfsDatastoreInfo"} | foreach-object {
    $datastore = $_
    $naa = $datastore.extensionData.info.vmfs.extent | select-object -property diskName
    $vmhostStorage.add($naa.diskName,$datastore.name)
  }

  # display information for all luns
  # $luns = $myVmhost.extensionData.config.storageDevice.scsiLun | sort {$_.canonicalName} | where {$_.canonicalName.startsWith("naa.")}
  $luns = $esxcli.storage.nmp.path.list() | where {($_.deviceDisplayName.toLower().contains("disk"))} | sort {$_.runtimeName}
  foreach ($lun in $luns) {
    $naa = $lun.device
    $vmhba = $esxcli.storage.nmp.path.list($naa,$null).runtimeName
    $capacity = [Math]::Round($esxcli.storage.core.device.list($naa).size / 1024,2)

    # set datastore name
    $dsname = "unformatted"
    if ($vmhostStorage.item($naa)) {
      $dsname = $vmhostStorage.item($naa)
    }

    write-host "`t $vmhba : $naa ($capacity GB) : $dsname"
  }
  echo ""
}

# connect to VC if not already connected
viconnect $vcserver

# get the datacenter object
$dc = get-datacenter -server $vcserver -name $datacenter -ea silentlycontinue
if (-not $dc) {
  write-host "`nUnable to find $datacenter in $vcserver`n" -foregroundcolor "red"
  exit 1
}

# get the cluster and ESXi hosts in the cluster
$cl = get-cluster -name $cluster -location $dc -ea silentlycontinue
if (-not $cl) {
  write-host "`nUnable to find $cluster in $datacenter`n" -foregroundcolor "red"
  exit 1
}

# get network info for each vmhost
$vmhosts = get-vmhost -location $cl | sort {$_.name}
foreach ($vmhost in $vmhosts) {
  write-host "getting info for $($vmhost.name)" -foregroundcolor "green"

  # print storage info vmhost
  printVmhostStorageInfo $vmhost
}
echo ""

disconnect-viserver $vcserver -confirm:$false
