# make sure we have a single connection to a vCenter server
function viconnect {
<#
.SYNOPSIS
    Make sure there is only one connection to a given vCenter server
.DESCRIPTION
    Since Connect-VIServer allows multiple connections we need to make sure there is a single connection
    to a given vCenter server.
.PARAMETER vcserver
    Required: The FQDN/IP address of a vCenter server.
.EXAMPLE
    viconnect 172.16.2.22

.NOTES
    Author: Eric Stokes
    Date:   September 29, 2011
#>
param([Parameter(Mandatory=$true)][string]$vsserver)
  $connect = $true
  foreach ($vs in $global:defaultVIServers) {
    $name = $vs.name
    if ( ($name.length -gt 0) -and ($name.toLower().equals($vsserver.toLower())) ) {
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


# get folder location based on full-path
# if any level doesnt exist then create it
function Get-FolderByPath {
<#
.SYNOPSIS
    Return folder provided by full-path
.DESCRIPTION
    Given the full-path of a folder location - return the folder object. This requires a single parameter
    which is the full folder path delimited by the "\" character.
.PARAMETER fullPath
    Required: The full-path to a folder delimited by the "\" character.
.EXAMPLE
    Get-FolderByPath "\dotcom\linux\dev"

.NOTES
    Author:  Eric Stokes
    Date:    January 29, 2014
    Updated: October 22, 2014 - added logic to handle Unix "/" character
#>

param([string]$fullPath)

  # get top-level folder
  $folder = get-folder -norecursion

  $folderArr = $fullPath.replace("/","\") -split "\\"  
  for ($i=1 ; $i -lt $folderArr.length ; $i++) {
    if (($folderArr[$i]) -and ($folderArr[$i].length -gt 0)) {
      $subfolder = get-folder -name $folderArr[$i] -location $folder -wa silentlycontinue -ea silentlycontinue
    
      # if we didnt find the subfolder then break and return null
      if (-not($subfolder)) {
        $folder = $null
        break
      }
      $folder = $subfolder
    }
  }
  return $folder
}

# get folder location based on full-path
# if any level doesnt exist then create it
function New-FolderByPath {
<#
.SYNOPSIS
    Create and return the folder provide by full-path
.DESCRIPTION
    Given the full-path of a folder location - create and return the folder object. This requires a 
    single parameter which is the full folder path delimited by the "\" character.
.PARAMETER fullPath
    Required: The full-path to a folder delimited by the "\" character.
.EXAMPLE
    New-FolderByPath "\dotcom\linux\dev"

.NOTES
    Author:  Eric Stokes
    Date:    February 10, 2014
    Updated: October 22, 2014 - added logic to handle Unix "/" character
#>

param([string]$fullPath)

  # get top-level folder
  $folder = get-folder -norecursion

  $folderArr = $fullPath.replace("/","\") -split "\\"  
  for ($i=1 ; $i -lt $folderArr.length ; $i++) {
    if (($folderArr[$i]) -and ($folderArr[$i].length -gt 0)) {
      $subfolder = get-folder -name $folderArr[$i] -location $folder -wa silentlycontinue -ea silentlycontinue
    
      # if we didnt find the subfolder then create it
      if (-not($subfolder)) {
        $subfolder = new-folder -name $folderArr[$i] -location $folder
      }
      $folder = $subfolder
    }
  }
  return $folder
}

