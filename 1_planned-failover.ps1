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
$rg = get-spbmreplicationgroup -server $siteSRC -VM $vm
write-host "get Replication Group Pair information on $siteSRC for "$vm.name
$rgPair = Get-SpbmReplicationPair -Source $rg
write-host "get get VMs in Replication Group "$rg.name
$rgVMs=(Get-SpbmReplicationGroup -server $siteSRC -Name $rg| get-vm)
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

### 3
write-host -foregroundcolor Yellow "======= Step 3 ======="
$rgVMs | ForEach-Object {
    if ( (get-vm $_).PowerState -eq "PoweredOn")
    {
        write-host "Poweroff VM" $_
        stop-vmguest -VM $_ -confirm:$false -ErrorAction silentlycontinue | Out-Null
        start-sleep -Seconds 10

        # give 3x 10seconds time to finish shutdown
        $cnt=1
        while ((get-vm $_).PowerState -eq "PoweredOn" -AND $cnt -le 3 ) {
            Start-Sleep -Seconds 10
            $cnt++
        }
        if ((get-vm $_).PowerState -eq "PoweredOn") {
            write-host "force stopping $_.name"
            stop-vm $_ -Confirm:$false  | Out-Null
        }
    }
}

### 4
write-host -foregroundcolor Yellow "======= Step 4 ======="
write-host "Prepare Failover"
$prepareFailover = start-spbmreplicationpreparefailover $rgPair.Source -Confirm:$false -RunAsync
Wait-Task $prepareFailover

write-host "Execute Failover"
$startFailover = Start-SpbmReplicationFailover $rgPair.Target -Confirm:$false -RunAsync
$vmxfile = Wait-Task $startFailover

write-host "vmxfiles"
$vmxfile

### 5
write-host -foregroundcolor Yellow "======= Step 5 ======="
$rgvms | ForEach-Object {
    write-host "Delete VM $_ on SRC ( $siteSRC)"
    $_ | Remove-VM -ErrorAction SilentlyContinue -Confirm:$false
}
write-host -foregroundcolor Blue "----------------------"
$vmhostDST = get-vmhost -Server $siteDST | select -First 1
$newDstVMs= @()
$vmxfile | ForEach-Object {
    write-host "Register VMX $_ on SRC ( $siteDST)"
    $newVM = New-VM -VMFilePath $_ -VMHost $vmhostDST 
    $newDstVMs += $newVM
}
write-host -foregroundcolor Blue "----------------------"
$newDstVms | forEach-object {
    write-host "start VM $_"
    $vmtask = start-vm $_ -ErrorAction SilentlyContinue -Confirm:$false -RunAsync
    wait-task $vmtask -ErrorAction SilentlyContinue | out-null
    $_ | Get-VMQuestion | Set-VMQuestion -Option ‘button.uuid.movedTheVM’ -Confirm:$false

    write-host "apply Storage Policy $stopol to $_"
    $hdds = Get-HardDisk -VM $_ -Server $siteDST
    Set-SpbmEntityConfiguration -Configuration $_ -StoragePolicy $stopol -ReplicationGroup  $rgPair.Target | out-null
    Set-SpbmEntityConfiguration -Configuration $hdds -StoragePolicy $stopol -ReplicationGroup  $rgPair.Target | out-null
}

### 6
write-host -foregroundcolor Yellow "======= Step 6 ======="
write-host "reverse replication for replication group "$rgPair.target
start-spbmreplicationreverse $rgPair.Target  | Out-Null
write-host "show new configuration"
$newDstVMs  | foreach-object {
    write-host "VM $_"
    Get-SpbmEntityConfiguration -HardDisk $hdds -VM $_ | format-table -AutoSize   
}
Disconnect-viserver -Server * -confirm:$false -ErrorAction SilentlyContinue |out-null
