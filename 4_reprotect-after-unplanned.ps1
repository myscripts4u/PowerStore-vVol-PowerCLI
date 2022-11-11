### 0 CLEAN ALL
Disconnect-viserver -Server * -confirm:$false -ErrorAction SilentlyContinue |out-null
Remove-Variable * -ErrorAction SilentlyContinue
Remove-Module *
$error.Clear();

### 1
write-host -foregroundcolor Yellow "======= Step 1 ======="
Import-Module VMware.VimAutomation.Core
Import-Module VMware.VimAutomation.Common
Import-Module VMware.VimAutomation.Storage
Set-PowerCLIConfiguration -DefaultVIServerMode 'Multiple' -Scope ([VMware.VimAutomation.ViCore.Types.V1.ConfigurationScope]::Session) -Confirm:$false  | Out-Null
$virtualmachine = "vm2”
$vcUser = 'administrator@vsphere.local'
$vcPass = 'Password123!'
$siteA = "vcsa-a.lab"
$siteB = "vcsa-b.lab"
write-host "connecting to vCenter $siteA"
Connect-VIServer -User "$vcUser" -Password "$vcPass" -Server $siteA -WarningAction SilentlyContinue 
write-host "connecting to vCenter $siteB"
Connect-VIServer -User "$vcUser" -Password "$vcPass" -Server $siteB -WarningAction SilentlyContinue 

### 2
write-host -foregroundcolor Yellow "======= Step 2 ======="
write-host "get vm infomration for $virtualmachine"
$vm = get-vm $virtualmachine
# find source vCenter – this allows the script to failover (Site-A -> Site-B) and failback (Site-B -> Site-A)
$srcvCenter=$vm.Uid.Split(":")[0].Split("@")[1]
if ( $srcvCenter -like $siteA ) {
    $siteSRC=$siteA
    $siteDST=$siteB 
} else {
    $siteSRC=$siteB
    $siteDST=$siteA 
}
write-host "$siteSRC is source for $virtualmachine"
write-host -foregroundcolor Blue "----------------------"
write-host "get Replication Group information on $siteSRC for "$vm.name
$rg = get-spbmreplicationgroup -server $siteDST -VM $vm
write-host "get get VMs in Replication Group "$rg.name
$rgVMs=(Get-SpbmReplicationGroup -server $siteDST -Name $rg| get-vm)
write-host "get Storage pool"
$stoPol = ( $vm | Get-SpbmEntityConfiguration).StoragePolicy.Name
write-host -foregroundcolor Blue "----------------------"
write-host "failover summary:"
write-host "Replication Group : " $rg
write-host "Storage Policy    : " $stoPol
write-host "Protected VMs     :"

$rgVMs | ForEach-Object {
write-host "        -" $_
}

$rgdst=(Get-SpbmReplicationGroup -server $siteDST)

$rgvms | forEach-object {
    write-host "apply Storage Policy $stopol / group $rgdst to $_"
    $vmtg = get-vm -name $_ -server $siteDST
    $hdds = Get-HardDisk -VM $vmtg -Server $siteDST
    Set-SpbmEntityConfiguration -server $siteDST -Configuration $vmtg -StoragePolicy $stopol -ReplicationGroup  $rgdst | out-null
    Set-SpbmEntityConfiguration -server $siteDST -Configuration $hdds -StoragePolicy $stopol -ReplicationGroup  $rgdst | out-null
}

$rgvms | forEach-object {
    write-host "stop and remove VMs on previous SRC $siteSRC"
    $vmsr = get-vm -name $_ -server $siteSRC
    $vmsr | stop-vm -server $siteSRC  -ErrorAction SilentlyContinue -Confirm:$false  | Out-Null
    $vmsr | Remove-VM -server $siteSRC -ErrorAction SilentlyContinue -Confirm:$false
    
}


# delete VMs on target
Start-SpbmReplicationReverse $rgdst


