<#
.SYNOPSIS
  Save vCenter inventory to XML  
.DESCRIPTION
  Get the following vCenter inventory and save to XML file.
  
  1. Roles
  2. Permissions
  3. Licenses
  4. Datacenters
  5. Folders
  6. Clusters
  7. Resource Pools
  8. DRS rules
  9. ESXi servers
  10. Distributed Switches (exported)
  11. Virtual Machines
  12. Templates
  
  This XML can be used with the import-vc-inventory.ps1 script to rebuild the vCenter inventory. One
  use case is when upgrading from Windows vCenter 5.5 to vcsa 6.0.  Note, vCenter performance data is 
  lost when using this approach.
  
  To-Do:
  1. vApps
  
.PARAMETER vcserver
  Required: The FQDN/IP of the VC Server
.PARAMETER outputDirectory 
  Optional: Output directory must be enclosed in quotes (") - defaults to C:\Temp\<VCSERVER>
.EXAMPLE
  get-vc-inventory.ps1 -vcserver vcsa55.esstokes1.local -outputDirectory "E:\Temp\"

.NOTES
  Author: Eric Stokes
  Date:   May 5, 2016   
  Tested Using: VMware vSphere PowerCLI 6.0 Release 3 build 3205540
#>

Param(
[Parameter(mandatory = $true)] [String] $vcserver,
[Parameter(mandatory = $false)] [String] $outputDirectory
)

# make sure we have only one connection to any VC server
function viconnect {
param([Parameter(Mandatory=$true)][string]$vsserver)
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

# get the full path of an object
function getFullPath {
param([Parameter(Mandatory=$true)]$objLocation)

  # back-track to the root folder
  $pathArray = @()
  while (($objLocation -ne $null) -and ($objLocation.getType().name -ne "DatacenterImpl")) {
    # echo "$($objLocation.name)"
    $pathArray += @($objLocation.name)
    $objLocation = $objLocation.parent
  }

  # create the full path as a string
  $pathLocation = ""
  for ($i = ($pathArray.length-1) ; $i -ge 0 ; $i--) {
    $pathLocation += "\"+ $pathArray[$i]
  }
  return $pathLocation
}

# set default output if nothing was provided
if (-not $outputDirectory) {
  $outputDirectory = "C:\Temp\"+ $vcserver
} else {
  $outputDirectory += "\"+ $vcserver
}
write-host "creating output directory $outputDirectory" -foregroundcolor "green"
new-item $outputDirectory -type directory -force | out-null

# connect to vcserver
viconnect $vcserver

# get VC roles
$vcRoleHash = @{}
write-host "getting roles" -foregroundcolor "cyan"
$roles = get-virole -server $vcserver
foreach ($role in $roles) {
  $vcRoleHash.add($role.extensionData.roleId.toString(),$role.name)
}

# create default xml document
[System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
[System.XML.XMLElement]$xmlRoot=$xmlDoc.createElement("vcenter")
$xmlRoot.setAttribute("name",$vcserver)

# get the top-level roles
$vcRoot = get-folder -noRecursion
write-host "getting permissions at VC level" -foregroundcolor "cyan"
foreach ($permission in $vcRoot.extensionData.permission) {
  [System.XML.XMLElement]$xmlPerm = $xmlDoc.createElement("permission")
  $xmlPerm.setAttribute("role",$vcRoleHash.get_item($permission.roleId.toString()))
  $xmlPerm.setAttribute("principal",$permission.principal.toString())
  $xmlPerm.setAttribute("group",$permission.group.toString())
  $xmlPerm.setAttribute("propagate",$permission.propagate.toString())
  $xmlRoot.appendChild($xmlPerm)
}
$xmlDoc.appendChild($xmlRoot)

# get roles for xml - exclude system & sample roles
foreach ($role in $roles) {
  $roleLabel = $role.extensionData.info.label
  if ((-not($role.isSystem)) -and (-not($roleLabel.contains("(sample)")))) {
    [System.XML.XMLElement]$xmlRole = $xmlDoc.createElement("role")
    $xmlRole.setAttribute("label",$roleLabel)
    $xmlRole.setAttribute("name",$role.extensionData.name)
    foreach ($priv in $role.extensionData.privilege) {
      [System.XML.XMLElement]$xmlPriv = $xmlDoc.createElement("privilege")
      $xmlPriv.appendChild($xmlDoc.createTextNode($priv))
      $xmlRole.appendChild($xmlPriv)
      $xmlRoot.appendChild($xmlRole)
    }
  }
}

# get licenses
$si = get-view ServiceInstance
write-host "getting license info" -foregroundcolor "cyan"
$licMgr = get-view $si.content.licenseManager
foreach ($license in $licMgr.licenses) {
  $licenseKey = $license.licenseKey
  if (-not($licenseKey.equals("00000-00000-00000-00000-00000"))) {
    [System.XML.XMLElement]$xmlLicense = $xmlDoc.createElement("license")
    $xmlLicense.setAttribute("key",$licenseKey)
    foreach ($prop in $license.properties) {
      if ($prop.key -eq "ProductName") {
        $xmlLicense.setAttribute("name",$prop.value)
      }
      if ($prop.key -eq "ProductVersion") {
        $xmlLicense.setAttribute("version",$prop.value)
      }
    }
    $xmlRoot.appendChild($xmlLicense)
  }
}

# get datacenters
$datacenters = get-datacenter
foreach ($datacenter in $datacenters) {
  write-host "getting info for $($datacenter.name)" -foregroundcolor "cyan"
  [System.XML.XMLElement]$xmlDC = $xmlDoc.createElement("datacenter")
  $xmlDC.setAttribute("name",$datacenter.name)
  write-host "getting permissions for $($datacenter.name)" -foregroundcolor "cyan"
  foreach ($permission in $datacenter.extensionData.permission) {
    [System.XML.XMLElement]$xmlPerm = $xmlDoc.createElement("permission")
    $xmlPerm.setAttribute("role",$vcRoleHash.get_item($permission.roleId.toString()))
    $xmlPerm.setAttribute("principal",$permission.principal.toString())
    $xmlPerm.setAttribute("group",$permission.group.toString())
    $xmlPerm.setAttribute("propagate",$permission.propagate.toString())
    $xmlDC.appendChild($xmlPerm)
  }
  $xmlRoot.appendChild($xmlDC)

  # get distributed switches
  $vdss = get-vdswitch -server $vcserver -location $datacenter
  foreach ($vds in $vdss) {
    $backupFile = $outputDirectory +"\"+ $($vds.name).replace(" ","_") +".zip"
    write-host "exporting vds $($vds.name)" -foregroundcolor "cyan"
    export-vdswitch -server $vcserver -vdswitch $vds -destination $backupFile -force

    [System.XML.XMLElement]$xmlVds = $xmlDoc.createElement("vds")
    $xmlVds.setAttribute("name",$($vds.name))
    $xmlVds.setAttribute("zip",$backupFile)
    $xmlDC.appendChild($xmlVds)
  }

  # get clusters
  $clusters = get-cluster -server $vcserver -location $datacenter
  foreach ($cluster in $clusters) {
    write-host "getting info for cluster $($cluster.name)" -foregroundcolor "cyan"
    [System.XML.XMLElement]$xmlCluster = $xmlDoc.createElement("cluster")
    $xmlCluster.setAttribute("name",$cluster.name)
    $xmlCluster.setAttribute("ha",$cluster.haEnabled.toString())
    $xmlCluster.setAttribute("drs",$cluster.haEnabled.toString())
    $xmlCluster.setAttribute("drsAutomation",$cluster.drsAutomationLevel.toString())

    # check EVC Mode
    if ($cluster.extensionData.summary.currentEVCModeKey) { 
      $xmlCluster.setAttribute("evcMode",$cluster.extensionData.summary.currentEVCModeKey.toString())
    }

    # get resource pools - exclude Resources RP since it is the default
    $rps = get-resourcepool -server $vcserver -location $cluster
    foreach ($rp in $rps) {
      if ($rp.name -ne "Resources") {
        write-host "getting info for resource pool $($rp.name)" -foregroundcolor "cyan"
        [System.XML.XMLElement]$xmlRP = $xmlDoc.createElement("resourcePool")
        $xmlRP.setAttribute("name",$rp.name)
        $xmlRP.setAttribute("cpuShares",$rp.cpuSharesLevel.toString())
        $xmlRP.setAttribute("memoryShares",$rp.memSharesLevel.toString())
        $xmlRP.setAttribute("cpuReservation",$rp.cpuReservationMHz.toString())
        $xmlRP.setAttribute("cpuLimit",$rp.cpuLimitMHz.toString())
        $xmlRP.setAttribute("memoryReservation",$rp.memReservationGB.toString())
        $xmlRP.setAttribute("parentName",$rp.parent.name)
        $xmlCluster.appendChild($xmlRP)
      }
    }
	
    # get vapp
    $vapps = get-vapp -server $vcserver -location $cluster
    foreach ($vapp in $vapps) {
      write-host "getting info for vApp $($vapp.name)" -foregroundcolor "cyan"
      [System.XML.XMLElement]$xmlVApp = $xmlDoc.createElement("vapp")
      $xmlVApp.setAttribute("name",$vapp.name)
      $xmlVApp.setAttribute("parentName",$vapp.parent.name)
      $xmlVApp.setAttribute("cpuShares",$vapp.cpuSharesLevel.toString())
      $xmlVApp.setAttribute("memoryShares",$vapp.memSharesLevel.toString())
      $xmlVApp.setAttribute("cpuReservation",$vapp.cpuReservationMHz.toString())
      $xmlVApp.setAttribute("cpuLimit",$vapp.cpuLimitMHz.toString())
      $xmlVApp.setAttribute("memoryReservation",$vapp.memReservationGB.toString())
      $xmlCluster.appendChild($xmlVApp)
    }
  
    # get cluster drs groups
    write-host "checking for DRS rules" -foregroundcolor "cyan"
    foreach ($clusterGrp in $cluster.extensionData.configurationEx.group) {
      [System.XML.XMLElement]$xmlGrp = $xmlDoc.createElement("drsGroup")
      $xmlGrp.SetAttribute("name",$clusterGrp.name)
      if ($clusterGrp.getType().name -eq "ClusterVmGroup") {
        foreach ($vmId in $clusterGrp.vm) {
          $vmname = (get-view -id $vmId).name
          [System.XML.XMLElement]$xmlVm = $xmlDoc.createElement("vm")
          $xmlVm.appendChild($xmlDoc.createTextNode($vmname))
          $xmlGrp.appendChild($xmlVm)
          $xmlCluster.appendChild($xmlGrp)
        }
      } elseif ($clusterGrp.getType().name -eq "ClusterHostGroup") {
        foreach ($vmhostId in $clusterGrp.host) {
          $vmhostname = (get-view -id $vmhostId).name
          [System.XML.XMLElement]$xmlVmhost = $xmlDoc.createElement("vmhost")
          $xmlVmhost.appendChild($xmlDoc.createTextNode($vmhostname))
          $xmlGrp.appendChild($xmlVmhost)
          $xmlCluster.appendChild($xmlGrp)
        }
      }
    }
  
    # get cluster drs rules
    foreach ($clusterRule in $cluster.extensionData.configurationEx.rule) {
      [System.XML.XMLElement]$xmlRule = $xmlDoc.createElement("drsRule")
      $xmlRule.SetAttribute("name",$clusterRule.name)
      $xmlRule.SetAttribute("enabled",$clusterRule.enabled.toString())
      # $xmlRule.SetAttribute("mandatory",$clusterRule.mandatory.toString())
      if ($clusterRule.getType().name -eq "ClusterVmHostRuleInfo") {
        $xmlRule.SetAttribute("vmGroupName",$clusterRule.vmGroupName)
        if ($clusterRule.affineHostGroupName -ne $null) {
          $xmlRule.SetAttribute("affineHostGroupName",$clusterRule.affineHostGroupName)
        } else {
          $xmlRule.SetAttribute("antiAffineHostGroupName",$clusterRule.antiAffineHostGroupName)
        }
      } else {
        if ($clusterRule.getType().name -eq "ClusterAffinityRuleSpec") {
          $xmlRule.SetAttribute("keepTogether","true")
        } else {
          $xmlRule.SetAttribute("keepTogether","false")
        }
        foreach ($vmId in $clusterRule.vm) {
          $vmname = (get-view -id $vmId).name
          [System.XML.XMLElement]$xmlVm = $xmlDoc.createElement("vm")
          $xmlVm.appendChild($xmlDoc.createTextNode($vmname))
          $xmlRule.appendChild($xmlVm)
        }
      }
      $xmlCluster.appendChild($xmlRule)
    }

    $xmlDC.appendChild($xmlCluster)
  }

  # get folder permissions
  write-host "checking for folder permissions" -foregroundcolor "cyan"
  $folders = get-folder -server $vcserver -location $datacenter
  foreach ($folder in $folders) {
    # make sure there are permissions on the folder and also that we are not at the root of any folders
    if (($folder.extensionData.permission -ne $null) -and ($folder.parent.getType().name -ne "DatacenterImpl")) {
      [System.XML.XMLElement]$xmlFolder = $xmlDoc.createElement("folder")
      $folderPath = getFullPath $folder
      $xmlFolder.SetAttribute("path",$folderPath)
      foreach ($permission in $folder.extensionData.permission) {
          [System.XML.XMLElement]$xmlPerm = $xmlDoc.createElement("permission")
          $xmlPerm.setAttribute("role",$vcRoleHash.get_item($permission.roleId.toString()))
          $xmlPerm.setAttribute("principal",$permission.principal.toString())
          $xmlPerm.setAttribute("group",$permission.group.toString())
          $xmlPerm.setAttribute("propagate",$permission.propagate.toString())
          $xmlFolder.appendChild($xmlPerm)
      }
      $xmlDC.appendChild($xmlFolder)
    }
  }

  # get hosts
  write-host "getting info for ESXi servers" -foregroundcolor "cyan"
  $vmhosts = get-vmhost -server $vcserver -location $datacenter
  foreach ($vmhost in $vmhosts) {
    [System.XML.XMLElement]$xmlVMhost = $xmlDoc.createElement("vmhost")
    $xmlVMhost.SetAttribute("name",$vmhost.name)
    if ($vmhost.parent.getType().name -eq "ClusterImpl") {
      $xmlVMhost.SetAttribute("parentType","Cluster")
      $xmlVMhost.SetAttribute("parentName",$vmhost.parent.name)

    } elseif ($vmhost.parent.getType().name -eq "FolderImpl") {
      $xmlVMhost.SetAttribute("parentType","Folder")
      $folderPath = getFullPath $vmhost.parent
      $xmlVMhost.SetAttribute("parentName",$folderPath)

    } else {
      $xmlVMhost.SetAttribute("parentType","Unknown")

    }
    $xmlDC.appendChild($xmlVMhost)
  }

  # get vms
  write-host "getting info for VMs" -foregroundcolor "cyan"
  $vms = get-vm  -server $vcserver -location $datacenter
  foreach ($vm in $vms) {
    [System.XML.XMLElement]$xmlVM = $xmlDoc.createElement("vm")
    $xmlVM.SetAttribute("name",$vm.name)

    if (($vm.resourcePool) -and ($vm.resourcePool.name -ne "Resources")) {
      $xmlVM.SetAttribute("resourcePool",$vm.resourcePool.name)
    }
 
    if ($vm.vApp) {
      $xmlVM.SetAttribute("vApp",$vm.vApp.name)
    } else {
      $folderPath = getFullPath $vm.folder
      $xmlVM.SetAttribute("folder",$folderPath)
    }
    $xmlDC.appendChild($xmlVM)
  }

  # get templates
  write-host "getting info for templates" -foregroundcolor "cyan"
  $templates = get-template  -server $vcserver -location $datacenter
  foreach ($template in $templates) {
    [System.XML.XMLElement]$xmlTemplate = $xmlDoc.createElement("template")
    $xmlTemplate.SetAttribute("name",$template.name)
    $xmlTemplate.SetAttribute("vmtxPath",$template.extensionData.config.files.vmPathName)
    $folderPath = getFullPath (get-folder -id $template.ExtensionData.parent)
    $xmlTemplate.SetAttribute("folder",$folderPath)
    $xmlTemplate.SetAttribute("vmhost",((get-vmhost -id $template.extensionData.runtime.host).name))
    if ($template.extensionData.resourcePool) {
      $xmlTemplate.SetAttribute("resourcePool",$template.extensionData.resourcePool.name)
    }
    $xmlDC.appendChild($xmlTemplate)
  }

}

# Save File
$xmlDoc.Save($outputDirectory +"\config.xml")
write-host "vCenter output saved as $outputDirectory\config.xml" -foregroundcolor "green"

Disconnect-VIServer $vcserver -confirm:$false
