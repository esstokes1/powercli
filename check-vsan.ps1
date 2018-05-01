<#
.SYNOPSIS
    Displays vSAN information for a cluster
.DESCRIPTION
    Script displays cache and capacity disks for each disk group on each
    ESXi server in the cluster. The first ESXi server in the cluster is
    used as the reference and vSAN configuration for each ESXi server is
    compared to it. Any differences are displayed in red.
.PARAMETER vcserver
    Required: The FQDN/IP of the VC Server
.PARAMETER datacenter
    Required: The name of the datacenter where the cluster resides
.PARAMETER cluster
    Required: The name of the cluster where the ESXi servers reside

.EXAMPLE
check-vsan.ps1 -vcserver vcsa1.corp.local -datacenter VCSA1 -cluster VSAN01

.NOTES
    Author: Eric Stokes
    Date:   March 5, 2018
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
for ($i = 0 ; $i -lt $vmhosts.length ; $i++) {
  echo ""
  $vmhost = $vmhosts[$i]
  $esxcli = get-esxcli -vmhost $vmhost

  $dgs = Get-VsanDiskGroup -vmhost $vmhost

  # use first node as reference node
  if ($i -eq 0) {
    $numDgs = $dgs.length
  }

  # check that vmhost matches reference
  $color = "green"
  if ($dgs.length -ne $numDgs) {
    $color = "red"
  }
  write-host "getting info for $($vmhost.name) - $($dgs.length) disk groups" -foregroundcolor $color

  for ($j = 0 ; $j -lt $dgs.length ; $j++) {
    $dg = $dgs[$j]
    write-host "$($dg.name)" -foregroundcolor "cyan"

    # cache disks
    write-host "cache disk(s):" -foregroundcolor "green"
    foreach ($ssd in $dg.extensionData.ssd) {
      $naa = $ssd.canonicalName
      $vmhba = $esxcli.storage.nmp.path.list($naa,$null).runtimeName
      write-host "`t$vmhba" -foregroundcolor "cyan"
    }

    # capacity disks
    if (($i -eq 0) -and ($j -eq 0)) {
      $numCapDisks = $dg.extensionData.nonSsd.length
    }

    # check num capacity disks match reference
    $color = "green"
    if ($dg.extensionData.nonSsd.length -ne $numCapDisks) {
      $color = "red"
    }

    write-host "capacity disk(s): $($dg.extensionData.nonSsd.length) disks total" -foregroundcolor $color
    foreach ($ssd in $dg.extensionData.nonSsd) {
      $naa = $ssd.canonicalName
      $vmhba = $esxcli.storage.nmp.path.list($naa,$null).runtimeName
      write-host "`t$vmhba" -foregroundcolor "cyan"
    }  
    echo ""

  }
}

disconnect-viserver -server $vcserver -confirm:$false
