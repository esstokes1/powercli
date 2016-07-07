<#
.SYNOPSIS
  Build vCenter inventory based XML output from get-vc-inventory.ps1 script
.DESCRIPTION
  Recreates vCenter inventory based on XML output from get-vc-inventory.ps1 script.  This includes
  
  1. Roles
  2. Permissions
  3. Datacenters
  4. Clusters
  5. Resource Pools
  6. DRS Rules
  7. Folders
  8. Distrubited Switches (imported)
  
  This script has only been tested to convert vCenter 5.5 to vcsa 6.0. There are known limitations
  that will cause errors with the script.  For example
  
  1. cmdlets for VDS are not available in vCenters older than 5.1
  2. export VDS is not available in vCenters older than 5.5
  3. local permissions from previous vCenter may fail when added (i.e. Administrators group does not exist on vcsa)
  
.PARAMETER vcserver
  Required: The FQDN/IP of the VC Server
.PARAMETER inputFile
  Required: Input file - must be enclosed in quotes (")
.EXAMPLE
  import-vc-inventory.ps1 -vcserver vcsa60.esstokes1.local -inputFile "C:\Temp\vcsa55.esstokes1.local\config.xml"

.NOTES
    Author: Eric Stokes
    Date:   May 5, 2016   
    Tested Using: VMware vSphere PowerCLI 6.0 Release 3 build 3205540
#>

Param(
[Parameter(mandatory = $true)] [String] $vcserver,
[Parameter(mandatory = $true)] [String] $inputFile
)

function viconnect {
param([Parameter(Mandatory=$true,ValueFromPipeline=$true)][string]$vsserver)
  $connect = $true
  foreach ($vs in $global:defaultVIServers) {
    $name = $vs.name
    if (($name.length -gt 0) -and ($name.toLower() -contains $vsserver.toLower())) {
      $connect = $false
      break
    }
  }
  if ($connect) {
    write-host "connecting to $vsserver" -foregroundcolor "cyan"
    connect-viserver -server $vsserver -warningaction silentlycontinue | out-null
  } else {
    write-host "already connected to $vsserver" -foregroundcolor "green"
  }
}

# get folder 
function getDcFolderByPath {
param($dc,[string]$folderString)

  $folderArr = $folderString -split "\\"  
  $folder = get-folder -location $dc -name $folderArr[1] -norecursion

  for ($i=2 ; $i -lt $folderArr.length ; $i++) {
    $levelFolder = get-folder -name $folderArr[$i] -location $folder -norecursion -wa silentlycontinue -ea silentlycontinue
    if ($levelFolder -eq $null) {
      $levelFolder = new-folder -name $folderArr[$i] -location $folder
    }
    $folder = $levelFolder
  }
  return $folder
}

function updateVmDrsGroup {
param($cluster,[string]$drsGrpName,[string]$vmname)

  $cluster.extensionData.updateViewData()
  $vm = get-vm -name $vmname -location $cluster
  if ($vm) {
    $spec = New-Object VMware.Vim.ClusterConfigSpecEx
    $group = New-Object VMware.Vim.ClusterGroupSpec
    $group.info = New-Object VMware.Vim.ClusterVmGroup
    $group.info.name = $drsGrpName

    $clusterDrsGrp = $cluster.extensionData.configurationEx.group | where {$_.name -like $drsGrpName}
    if ($clusterDrsGrp) {
      $group.operation = "edit"
      $group.info.vm = $clusterDrsGrp.vm
      $group.info.vm += $vm.extensionData.moRef
    } else {
      $group.operation = "add"
      $group.info.vm = $vm.extensionData.moRef
    }

    if ($group.info.vm) {
      $spec.groupSpec += $group
      $cluster.extensionData.reconfigureComputeResource_Task($spec,$true)
    }
  }
}

function updateVmhostDrsGroup {
param($cluster,[string]$drsGrpName,[string]$vmhostName)

  $cluster.extensionData.updateViewData()
  $vmhost = get-vmhost -name $vmhostName -location $cluster
  if ($vmhost) {
    $spec = New-Object VMware.Vim.ClusterConfigSpecEx
    $group = New-Object VMware.Vim.ClusterGroupSpec
    $group.info = New-Object VMware.Vim.ClusterHostGroup
    $group.info.name = $drsGrpName

    $clusterDrsGrp = $cluster.extensionData.configurationEx.group | where {$_.name -like $drsGrpName}
    if ($clusterDrsGrp) {
      $group.operation = "edit"
      $group.info.host = $clusterDrsGrp.host
      $group.info.host += $vmhost.extensionData.moRef
    } else {
      $group.operation = "add"
      $group.info.host = $vmhost.extensionData.moRef
    }

    if ($group.info.host) {
      $spec.groupSpec += $group
      $cluster.extensionData.reconfigureComputeResource_Task($spec,$true)
    }
  }
}

# check to make sure the xml exists
if (-not(test-path $inputFile)) {
  write-host "$inputFile does not exist - quitting" -foregroundcolor "red"
  exit 1
}

# read the contents of the xml file into a variable
[xml]$vcconfig = get-content $inputFile
if ((-not($vcconfig.hasChildNodes)) -or ($vcconfig.getElementsByTagName("vcenter").count -eq 0)) {
  write-host "$inputFile is not valid - quitting" -foregroundcolor "red"
  exit 1
}

# connect to vcserver
viconnect $vcserver

# add roles
foreach ($xmlRole in $vcconfig.vcenter.role) {
  $vcrole = get-virole -server $vcserver -name $($xmlRole.name) -wa silentlycontinue -ea silentlycontinue
  if ($vcrole -eq $null) {
    write-host "adding Role $($xmlRole.name)" -foregroundcolor "cyan"
    new-virole -server $vcserver -name $($xmlRole.name) -privilege (get-viprivilege -id $($xmlRole.privilege)) -confirm:$false
  }
}

# get the roles
$vcRoleHash = @{}
$roles = get-virole -server $vcserver
foreach ($role in $roles) {
  $vcRoleHash.add($role.extensionData.roleId.toString(),$role.name)
}

# set top-level vCenter permissions
$vcRoot = get-folder -noRecursion
foreach ($xmlPermission in $vcconfig.vcenter.permission) {
  $addPermission = $true
  $xmlRole = $xmlPermission.role
  $xmlPrincipal = $xmlPermission.principal
  $xmlPropagate = $xmlPermission.propagate
  foreach ($permission in $vcRoot.extensionData.permission) {
    $vcRole = $vcRoleHash.get_item($permission.roleId.toString())
    $vcPrincipal = $permission.principal
    $vcPropagate = $permission.propagate
    if (($xmlRole -eq $vcRole) -and ($xmlPrincipal -eq $vcPrincipal) -and ($xmlPropagate -eq $vcPropagate)) {
      $addPermission = $false
      continue
    }
  }
  if ($addPermission) {
    write-host "adding $xmlRole role to $xmlPrincipal at vCenter root" -foregroundcolor "cyan"
    new-vipermission -server $vcserver -entity $vcRoot -role (get-virole -server $vcserver -name $xmlRole) -principal "$($xmlPrincipal)" -propagate ([System.Convert]::ToBoolean($xmlPropagate)) -confirm:$false
  }
}

# get ESXi credentials to add hosts back into vCenter
write-host "getting ESXi root credentials" -foregroundcolor "green"
$creds = get-credential -message "Enter ESXi root user and password"

# add datacenter entities
foreach ($xmlDc in $vcconfig.vcenter.datacenter) {
  $datacenter = get-datacenter -location $vcRoot -name $($xmlDc.name) -wa silentlycontinue -ea silentlycontinue
  if ($datacenter -eq $null) {
    write-host "adding datacenter $($xmlDc.name)" -foregroundcolor "cyan"
    $datacenter = new-datacenter -location $vcRoot -server $vcserver -name $($xmlDc.name) -confirm:$false
  }

  # import the vds if one exists
  foreach ($xmlVds in $xmlDc.vds) {
    write-host "importing VDS $($xmlVds.name) from exported zip file" -foregroundcolor "cyan"
    new-vdswitch -name $xmlVds.name -location $datacenter -backupPath $xmlVds.zip -confirm:$false
  }

  # add folders that had specific permissions
  foreach ($xmlFolder in $xmlDc.folder) {
    $folderByPath = getDcFolderByPath $datacenter $($xmlFolder.path)
    foreach ($xmlPermission in $xmlFolder.permission) {
      $xmlRole = $xmlPermission.role
      $xmlPrincipal = $xmlPermission.principal
      $xmlPropagate = $xmlPermission.propagate
      write-host "adding $xmlRole role for $xmlPrincipal to folder $($xmlFolder.path)" -foregroundcolor "cyan"
      new-vipermission -server $vcserver -entity $folderByPath -role (get-virole -server $vcserver -name $xmlRole) -principal "$($xmlPrincipal)" -propagate ([System.Convert]::ToBoolean($xmlPropagate)) -confirm:$false
    }
  }

  # add the clusters to the datacenter
  foreach ($xmlCluster in $xmlDc.cluster) {
    $cluster = get-cluster -server $vcserver -location $datacenter -name $($xmlCluster.name) -wa silentlycontinue -ea silentlycontinue
    if ($cluster -eq $null) {
      write-host "adding cluster $($xmlCluster.name) to $($datacenter.name)" -foregroundcolor "cyan"
      $cluster = new-cluster -server $vcserver -location $datacenter -name $($xmlCluster.name) -evcMode $($xmlCluster.evcMode)  -confirm:$false
    }

    # set EVC mode if needed
    if ($xmlCluster.evcMode) {
      set-cluster -cluster $cluster -evcMode $xmlCluster.evcMode -confirm:$false
    }
  }

  # add the vmhosts to the datacenter
  foreach ($xmlVmhost in $xmlDc.vmhost) {
    $vmhostName = $xmlVmhost.name
    $parentType = $xmlVmhost.parentType
    if ($parentType -eq "Cluster") {
      write-host "adding vmhost $vmhostName to cluster $($xmlVmhost.parentName)" -foregroundcolor "cyan"
      $locationObject = get-cluster -server $vcserver -location $datacenter -name $($xmlVmhost.parentName)
    } elseif ($parentType -eq "Folder") {
      write-host "adding vmhost $vmhostName to folder $($xmlVmhost.parentName)" -foregroundcolor "cyan"
      $locationObject = getDcFolderByPath $datacenter $($xmlVmhost.parentName)
    } else {
      $locationObject = $datacenter
      write-host "adding vmhost $vmhostName to datacenter $($datacenter.name)" -foregroundcolor "cyan"
    } 
    $vmhost = add-vmhost -server $vcserver -location $locationObject -name $vmhostName -credential $creds -confirm:$false -force
  }

  # set cluster ha/drs if needed
  # add resource pools
  foreach ($xmlCluster in $xmlDc.cluster) {
    $cluster = get-cluster -server $vcserver -location $datacenter -name $($xmlCluster.name) -wa silentlycontinue -ea silentlycontinue

    # set HA
    if ($xmlCluster.ha -eq "True") {
      write-host "enabling HA on $($cluster.name)"
      set-cluster -cluster $cluster -HAEnabled $true -confirm:$false
    }

    # set DRS
    if ($xmlCluster.drs -eq "True") {
      write-host "enabling DRS on $($cluster.name)"
      set-cluster -cluster $cluster -DrsEnabled $true -DrsAutomationLevel $($xmlCluster.drsAutomation) -confirm:$false

      # add DRS groups
      if ($xmlCluster.getElementsByTagName("drsGroup").count -gt 0) {
        foreach ($xmlDrsGrp in $xmlCluster.drsGroup) {
          $drsGrpName = $xmlDrsGrp.name
          if ($xmlDrsGrp.getElementsByTagName("vm").count -gt 0) {
            foreach ($xmlVm in $xmlDrsGrp.vm) {
              write-host "adding $xmlVm to drs group $drsGrpName"
              updateVmDrsGroup $cluster $drsGrpName $xmlVm
            }
          } elseif ($xmlDrsGrp.getElementsByTagName("vmhost").count -gt 0) {
            foreach ($xmlVmhost in $xmlDrsGrp.vmhost) {
              write-host "adding $xmlVmhost to drs group $drsGrpName"
              updateVmhostDrsGroup $cluster $drsGrpName $xmlVmhost
            }
          }
        }
      }

      # add DRS rules
      if ($xmlCluster.getElementsByTagName("drsRule").count -gt 0) {
        foreach ($xmlDrsRule in $xmlCluster.drsRule) {
          $drsRuleName = $xmlDrsRule.name
          $ruleEnabled = $xmlDrsRule.enabled
          if ($xmlDrsRule.getElementsByTagName("vm").count -gt 0) {
            $keepTogether = [System.Convert]::ToBoolean($xmlDrsRule.keepTogether.toString())
            $vms = @()
            foreach ($xmlVm in $xmlDrsRule.vm) {
              $vm = get-vm -name $xmlVm -location $cluster
              if ($vm) {
                 write-host "adding $xmlVm to $ruleType rule $drsRuleName" 
                 $vms += $vm
               }
            }
            new-drsrule -name $drsRuleName -cluster $cluster -vm $vms -keepTogether $keepTogether -confirm:$false
          } else {
            $vmGroupName = $xmlDrsRule.vmGroupName

            $spec = New-Object VMware.Vim.ClusterConfigSpecEx
            $rule = New-Object VMware.Vim.ClusterRuleSpec
            $rule.operation = "add"
            $rule.info = New-Object VMware.Vim.ClusterVmHostRuleInfo
            $rule.info.enabled = $true
            $rule.info.name = $drsRuleName
            $rule.info.mandatory = $false
            $rule.info.vmGroupName = $xmlDrsRule.vmGroupName
            if ($xmlDrsRule.antiAffineHostGroupName) {
              $rule.info.antiAffineHostGroupName = $xmlDrsRule.anitAffineHostGroupName
              $vmhostGroupName = $xmlDrsRule.antiAffineHostGroupName
            } else {
              $rule.info.affineHostGroupName = $xmlDrsRule.affineHostGroupName
              $vmhostGroupName = $xmlDrsRule.affineHostGroupName
            }
            $spec.rulesSpec += $rule
            write-host "adding drs rule $drsRuleName for $vmGroupName and $vmhostGroupName" 
            $cluster.extensionData.reconfigureComputeResource_Task($spec,$true)
          }
        }
      }
    }

    # add resource pools
    if ($xmlCluster.getElementsByTagName("resourcePool").count -gt 0) {
      foreach ($xmlRp in $xmlCluster.resourcePool) {
        $rpName = $xmlRp.name
        $rpParentName = $xmlRp.parentName
        if ($rpParentName -like "Resources") {
          $rpParent = $cluster
        } else {
          $rpParent = get-resourcePool -name $rpParentName -location $cluster
        }
        $rpCpuShares = $xmlRp.cpuShares
        $rpMemShares = $xmlRp.memoryShares
        $rpCpuReservation = $xmlRp.cpuReservation
        $rpCpuLimit = $xmlRp.cpuLimit
        $rpMemReservation = $xmlRp.memoryReservation
        write-host "adding resource pool $rpName to $rpParentName" -foregroundcolor "cyan"
        write-host "new-resourcepool -server $vcserver -location $($rpParent.name) -CpuSharesLevel $rpCpuShares -MemSharesLevel $rpMemShares -CpuReservationMhz $rpCpuReservation -CpuLimitMhz $rpCpuLimit -MemReservationGB $rpMemReservation"
        new-resourcepool -name $rpName -server $vcserver -location $rpParent -CpuSharesLevel $rpCpuShares -MemSharesLevel $rpMemShares -CpuReservationMhz $rpCpuReservation -CpuLimitMhz $rpCpuLimit -MemReservationGB $rpMemReservation
      }
    }
  }

  # move the vms back to the correct folders & resource pools
  $vms = get-vm -server $vcserver -location $datacenter
  foreach ($vm in $vms) {
    $vmname = $vm.name
    $xmlVm = $xmlDc.vm | where {$_.name.equals($vmname)}
    if ($xmlVm -ne $null) {
      # move vm to correct folder if given
      if ($xmlVm.hasAttribute('folder')) {
        write-host "moving $vmname to folder $($xmlVm.folder)" -foregroundcolor "cyan"
        $vmFolder = getDcFolderByPath $datacenter $($xmlVm.folder)
        move-vm -vm $vm -destination $vmFolder -confirm:$false
      }

      # move vm to correct resource pool if given
      if ($xmlVm.hasAttribute('resourcePool')) {
        $rp = get-resourcePool -server $vcserver -location ($vm.vmhost.parent) -name $($xmlVm.resourcePool) -wa silentlycontinue -ea silentlycontinue
        if ($rp -ne $null) {
          write-host "moving $vmname to resource pool $($xmlVm.resourcePool)" -foregroundcolor "cyan"
          move-vm -vm $vm -destination $rp -confirm:$false
        }
      }
    }
  }

  # add the templates to the datacenter
  foreach ($xmlTemplate in $xmlDc.template) {
    $templateName = $xmlTemplate.name
    $vmtxPath = $xmlTemplate.vmtxPath
    $folder = getDcFolderByPath $datacenter $($xmlTemplate.folder)
    $vmhostName = $xmlTemplate.vmhost
    write-host "importing template $templateName" -foregroundcolor "cyan"
    $template = new-template -name $templateName -templateFilePath $vmtxPath -vmhost $vmhostName -confirm:$false
    write-host "moving template $templateName to folder $($xmlTemplate.folder)" -foregroundcolor "cyan"
    move-template -template $template -destination $folder -confirm:$false

    # move template to correct resource pool if one was given
    if ($xmlTemplate.hasAttribute('resourcePool')) {
      $rp = get-resourcePool -server $vcserver -location ((get-vmhost -name $vmhostName).parent) -name $($xmlTemplate.resourcePool) -wa silentlycontinue -ea silentlycontinue
      if ($rp -ne $null) {
        write-host "moving template $templateName to resource pool $($xmlVm.resourcePool)" -foregroundcolor "cyan"
        move-template -template $template -destination $rp -confirm:$false
      }
    }
  }

}

Disconnect-VIServer $vcserver -confirm:$false
