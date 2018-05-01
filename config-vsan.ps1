<#
.SYNOPSIS
    Configure vSAN and add disk groups
.DESCRIPTION
    Script has multiple options which allows for configuring vSAN and disk group(s) on a entire 
    cluster or configuring disk groups on individual ESXi servers when vSAN is already configured
    for the cluster.
.PARAMETER vcserver
    Required: The FQDN/IP of the VC Server
.PARAMETER datacenter
    Required: The name of the datacenter
.PARAMETER cluster
    Required: The name of the cluster
.PARAMETER esxi
    Optional: The name of an individual ESXi server
.PARAMETER license
    Optional: License key to apply cluster
.PARAMETER vmhbas
    Optional: Comma-separated list vmhbas. A single disk group will be created on each vmhba provided
              and cache/capacity disks will automatically by picked based on MINCAP & MAXCAP variables
.PARAMETER numDiskGroupsPerHost
    Optional: number of disk groups to add per ESXi server. this paramater should only be used along 
              with the selectDisks switch (next item)
.PARAMETER selectDisks
    Optional: This switch is used when wanting to manually pick disks for each disk group

.EXAMPLE
config-vsan.ps1 -vcserver vcsa1.corp.local -datacenter VCSA1 -cluster VSAN01 -vmhbas "vmhba1,vmhba2"

.EXAMPLE
config-vsan.ps1 -vcserver vcsa1.corp.local -datacenter VCSA1 -cluster VSAN01 -esxi esxi01.corp.local -vmhbas "vmhba1,vmhba2"

.EXAMPLE
config-vsan.ps1 -vcserver vcsa1.corp.local -datacenter VCSA1 -cluster VSAN01 -numDiskGroupsPerHost 2 -selectDisks

.NOTES
    Author: Eric Stokes
    Date:   April 5, 2018
    Tested: Get-PowerCLIVersion - VMware PowerCLI 10.0.0 build 7895300

#>

Param(
[Parameter(mandatory = $true)] [String] $vcserver,
[Parameter(mandatory = $true)] [String] $datacenter,
[Parameter(mandatory = $true)] [String] $cluster,
[Parameter(mandatory = $false)] [String] $esxi,
[Parameter(mandatory = $false)] [String] $license,
[Parameter(mandatory = $false)] [String] $vmhbas,
[Parameter(mandatory = $false)] [int] $numDiskGroupsPerHost,
[Parameter(mandatory = $false)] [Switch] $selectDisks
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

# add disk groups to ESXi server
function addDiskGroupsToVmhost {
param($myVmhost)
  echo ""
  write-host "adding disks from $($myVmhost.name)" -foregroundcolor "cyan"
  $esxcli = get-esxcli -vmhost $myVmhost

  # create specific number of disk groups
  for ($i = 1 ; $i -le $numDiskGroupsPerHost ; $i++) {

    # selectDisks switch was given on the command-line
    if ($selectDisks) {

      # find all of the disks on the ESXi server
      $luns = $esxcli.storage.nmp.path.list()

      # initialize array to hold runtime names of each disk
      $allDisks = New-Object String[] ($luns.length)
      $index = 0

      # assign each disk as an element in the array
      # also display each disk with the associated index
      # this way we can simply provide the index number when prompted
      foreach ($lun in $luns) {
        $naa = $lun.device
        $allDisks[$index] = $naa
        $vmhba = $esxcli.storage.nmp.path.list($naa,$null).runtimeName
        $capacity = [Math]::Round($esxcli.storage.core.device.list($naa).size / 1024,2)
        write-host "`t $index - $vmhba : $naa ($capacity GB)"
        $index++
      }
      echo ""
  
      # prompt for the cache disk index
      $cacheDiskIndex = read-host "enter number for cache disk"
      $cacheDisk = $allDisks[$cacheDiskIndex]
  
      # prompt for capacity disk indexes
      $capacityDiskIndexes = read-host "enter comma-separated list of numbers for capacity disks"
      $capacityDisks = @()
      foreach ($index in $capacityDiskIndexes.split(",")) {
        $capacityDisks += $allDisks[$index]
      }
  
    # the selectDisks switch was not provided
    # instead the vmhbas parameter was given
    # now we select the disks programmatically
    } else {

      # minimum & maximum capacities for the cache disks
      # the assumption is that cache disk sizes are smaller
      # than capacity disks
      $MINCAP = 700
      $MAXCAP = 800

      # initialize the cache disk and the capacity disks array
      $cacheDisk = $null
      $capacityDisks = @()

      # get the next vmhba from the list provided
      $scsi = ($vmhbas.split(","))[$i-1]

      if ($scsi) {

        # get all of the disks attached to the vmhba
        $disks = $esxcli.storage.nmp.path.list() | where {(($_.runtimeName.contains($scsi)) -and ($_.deviceDisplayName.toLower().contains("disk")))} | sort {$_.runtimeName}

        # max of 8 disks - 1 cache & 7 capacity
        if ($disks.length -le 8) {

          # loop through disks to find cache & capacity disks
          for ($j = 0 ; $j -lt $disks.length ; $j++) {
            $disk = ($disks[$j]).device
            $capacity = [Math]::Round($esxcli.storage.core.device.list($disk).size / 1024,2)

            # find cache disk based on MINCAP & MAXCAP variables
            if (($capacity -gt $MINCAP) -and ($capacity -lt $MAXCAP)) {
              write-host "using $disk for cache disk" -foregroundcolor "cyan"
              $cacheDisk = $disk
   
            # if not a cache disk then it has to be a capacity disk
            } else {
              write-host "using $disk for capacity disk" -foregroundcolor "cyan"
              $capacityDisks += $disk
            }
          }

        # there are too many disks on the vmhba so
        # we dont know which ones to use for capacity
        } else {
          write-host "$vmhba has more than 8 disks - automation cannot configure for vSAN" -foregroundcolor "red"
       }
      }
    }

    # now we should have cache & capacity disks
    # create the disk group and store the vCenter task
    if (($cacheDisk) -and ($capacityDisks.length -gt 0)) {
      $global:tasks += new-vsanDiskGroup -vmhost $myVmhost -ssdCanonicalName $cacheDisk -dataDiskCanonicalName $capacityDisks -runAsync
    }
  }
}

# script assumption that when vmhbas is given 
# then a disk group is created per vmhba
if ($vmhbas) {
  $numDiskGroupsPerHost = $vmhbas.split(",").length
}

# set default number of diskgroups if value wasnt set
if (-not $numDiskGroupsPerHost) {
  $numDiskGroupsPerHost = 1
}

# connect to vCenter
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

# enable vSAN if not already enabled
if (-not $cl.extensionData.configurationEx.vSanConfigInfo.enabled) {
  # disable HA if needed
  $enableHA = $false
  if ($cl.HAEnabled) {
    write-host "disabling HA on $cluster" -foregroundcolor "yellow"
    $cl | set-cluster -HAEnabled:$false -confirm:$false -ea silentlycontinue
    $enableHA = $true
  }

  # enable cluster for VSAN
  write-host "enabling vSAN on $cluster" -foregroundcolor "cyan"
  $cl | set-cluster -VsanEnabled:$true -VsanDiskClaimMode Manual -confirm:$false -ea silentlycontinue

  # assign the license if it was given on the command-line
  if ($license) {
    $licComment = "vSAN license - "+ $cluster
    $si = get-view ServiceInstance
    $licMgr = get-view $si.content.licenseManager
    $licAssignMgr = get-view $licMgr.licenseAssignmentManager
    $licInfo = $licAssignMgr.updateAssignedLicense($cl.moRef.value,$license,$licComment)
  }
}

# add diskgroup to each vmhost
if ($cl.extensionData.configurationEx.vSanConfigInfo.enabled) {
  $global:tasks = @()
  $vmhosts = @()

  # get vmhosts to parse
  if ($esxi) {
    # get the ESXi server
    $vmhosts = @(get-vmhost -location $cl -name $esxi -ea silentlycontinue)
    if (-not $vmhosts) {
      write-host "`nUnable to find $esxi in cluster $cluster `n" -foregroundcolor "red"
    }
  } else {
    $vmhosts = get-vmhost -location $cl | sort {$_.name}
  }

  # parse vmhosts
  foreach ($vmhost in $vmhosts) {
    addDiskGroupsToVmhost $vmhost
  }

  # monitor each of the vSAN tasks
  while ($true) {
    $allComplete = $true
    foreach ($task in $global:tasks) {
      $task.extensionData.updateViewData()
      write-host "$($task.extensionData.info.entityName) : $($task.extensionData.info.state.toString())" -foregroundcolor "cyan"
      if ($task.extensionData.info.state.toString().toLower().equals("running")) {
        $allComplete = $false
      }

    }

    # if all completed then stop
    # otherwise wait a few seconds and then check again
    if ($allComplete) {
      write-host "all tasks completed ..." -foregroundcolor "cyan"
      break
    } else {
      write-host "waiting for all tasks to complete ..." -foregroundcolor "cyan"
      echo ""
      start-sleep -s 15 
    }
  }

} else {
  write-host "something went wrong enabling vSAN" -foregroundcolor "red"
}

# re-enable HA on cluster if needed
if ($enableHA) {
  write-host "re-enabling HA on $cluster" -foregroundcolor "yellow"
  $cl | set-cluster -HAEnabled:$true -confirm:$false -ea silentlycontinue
}

# add storage policies if needed
if (-not(get-spbmStoragePolicy -name "RAID1-FTT2")) {
  new-spbmStoragePolicy -name "RAID1-FTT2" -AnyOfRuleSets `
  (new-spbmRuleSet `
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.hostFailuresToTolerate") -value 2),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.replicaPreference") -value "RAID-1 (Mirroring) - Performance"),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.forceProvisioning") -value $false),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.cacheReservation") -value 0),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.proportionalCapacity") -value 0),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.stripeWidth") -value 1),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.iopsLimit") -value 0)`
  )
}

if (-not(get-spbmStoragePolicy -name "RAID5")) {
  new-spbmStoragePolicy -name "RAID5" -AnyOfRuleSets `
  (new-spbmRuleSet `
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.hostFailuresToTolerate") -value 1),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.replicaPreference") -value "RAID-5/6 (Erasure Coding) - Capacity"),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.forceProvisioning") -value $false),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.cacheReservation") -value 0),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.proportionalCapacity") -value 0),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.stripeWidth") -value 1),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.iopsLimit") -value 0)`
  )
}

if (-not(get-spbmStoragePolicy -name "RAID1-FTT1")) {
  new-spbmStoragePolicy -name "RAID1-FTT1" -AnyOfRuleSets `
  (new-spbmRuleSet `
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.hostFailuresToTolerate") -value 1),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.replicaPreference") -value "RAID-1 (Mirroring) - Performance"),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.forceProvisioning") -value $false),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.cacheReservation") -value 0),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.proportionalCapacity") -value 0),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.stripeWidth") -value 1),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.iopsLimit") -value 0)`
  )
}

if (-not(get-spbmStoragePolicy -name "RAID6")) {
  new-spbmStoragePolicy -name "RAID6" -AnyOfRuleSets `
  (new-spbmRuleSet `
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.hostFailuresToTolerate") -value 2),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.replicaPreference") -value "RAID-5/6 (Erasure Coding) - Capacity"),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.forceProvisioning") -value $false),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.cacheReservation") -value 0),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.proportionalCapacity") -value 0),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.stripeWidth") -value 1),`
    (new-spbmRule -capability (get-spbmCapability -name "VSAN.iopsLimit") -value 0)`
  )
}

disconnect-viserver -server $vcserver -confirm:$false
