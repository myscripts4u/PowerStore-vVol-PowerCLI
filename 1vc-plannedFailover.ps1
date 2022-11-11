### 0 CLEAN ALL
#Disconnect-viserver -Server * -confirm:$false -ErrorAction SilentlyContinue |out-null
#Remove-Variable * -ErrorAction SilentlyContinue
#Remove-Module *
#$error.Clear();
Start-Sleep -Seconds 5
### 1
write-host -foregroundcolor Yellow "======= Step 1 ======="
Import-Module VMware.VimAutomation.Core
Import-Module VMware.VimAutomation.Common
Import-Module VMware.VimAutomation.Storage

$vcUser = 'administrator@vsphere.local'
$vcPass = '<yourSecrectVcenterPassword>'
$siteA = "vcenter.lab"
write-host "connecting to vCenter $siteA"
Connect-VIServer -User "$vcUser" -Password "$vcPass" -Server $siteA -WarningAction SilentlyContinue 

$virtualmachine = "vvol-vm1"
$vm = get-vm $virtualmachine

write-host -foregroundcolor Yellow "======= Step 2 ======="
write-host "$siteA is source for $virtualmachine"
write-host -foregroundcolor Blue "----------------------"
write-host "get Replication Group information on $siteA for "$vm.name
$rg = get-spbmreplicationgroup -VM $vm
write-host "get Replication Group Pair information on $siteA for "$vm.name
$rgPair = Get-SpbmReplicationPair -Source $rg
write-host "get get VMs in Replication Group "$rg.name
$rgVMs=(Get-SpbmReplicationGroup -Name $rg| get-vm)
write-host "get Storage pool"
$stoPol = ( $vm | Get-SpbmEntityConfiguration).StoragePolicy.Name
# Demo uses ReplA-B and ReplB-A - the following line change the name for Storage Policy after failover
$newStoPol=$stopol.Replace("A","x").Replace("B","A").Replace("x","B")
write-host -foregroundcolor Blue "----------------------"
write-host "failover summary:"
write-host "Replication Group : " $rg
write-host "        - Source:"$rgpair.source
write-host "        - Target:"$rgpair.target 
write-host "Storage Policy    : " $stoPol " -> " $newStoPol
write-host "Protected VMs     :"

$rgVMs | ForEach-Object {
write-host "        -" $_
}

write-host -foregroundcolor Yellow "======= Step 3 ======="
$rgVMs | ForEach-Object {
    if ( (get-vm $_).PowerState -eq "PoweredOn")
    {
        write-host "Poweroff VM" $_
        stop-vmguest -VM $_ -confirm:$false -ErrorAction silentlycontinue | Out-Null
        start-sleep -Seconds 5

        # give 3x 10seconds time to finish shutdown
        $cnt=1
        while ((get-vm $_).PowerState -eq "PoweredOn" -AND $cnt -le 3 ) {
            Start-Sleep -Seconds 5
            $cnt++
        }
        if ((get-vm $_).PowerState -eq "PoweredOn") {
            write-host "force stopping $_.name"
            stop-vm $_ -Confirm:$false  | Out-Null
        }
    }
}

write-host -foregroundcolor Yellow "======= Step 4 ======="
write-host "run a PiT sync"
$sync=Sync-SpbmReplicationGroup -PointInTimeReplicaName "test" -ReplicationGroup $rgpair.target

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
    write-host "Delete VM $_ ( $siteA)"
    $_ | Remove-VM -ErrorAction SilentlyContinue -Confirm:$false
}
write-host -foregroundcolor Blue "----------------------"
$vmhost = get-vmhost -Server $siteA -state Connected| select -First 1
$newDstVMs= @()
$vmxfile | ForEach-Object {
    write-host "Register VMX $_ on SRC ( $siteA )"
    $newVM = New-VM -VMFilePath $_ -VMHost $vmhost
    $newDstVMs += $newVM
}

$newDstVms | forEach-object {
    write-host "start VM $_"
    $vmtask = start-vm $_ -ErrorAction SilentlyContinue -Confirm:$false -RunAsync
    wait-task $vmtask -ErrorAction SilentlyContinue | out-null
    $_ | Get-VMQuestion | Set-VMQuestion -Option ‘button.uuid.movedTheVM’ -Confirm:$false
    write-host "apply Storage Policy $newstopol to $_"
    $hdds = Get-HardDisk -VM $_ -Server $siteA
    Set-SpbmEntityConfiguration -Configuration $_ -StoragePolicy $newStoPol -ReplicationGroup  $rgPair.Target | out-null
    Set-SpbmEntityConfiguration -Configuration $hdds -StoragePolicy $newStoPol -ReplicationGroup  $rgPair.Target | out-null
}

write-host -foregroundcolor Yellow "======= Step 6 ======="
write-host "reverse replication for replication group "$rgPair.target
start-spbmreplicationreverse $rgPair.Target  | Out-Null
write-host "show new configuration"
$newDstVMs  | foreach-object {
    write-host "VM $_"
    Get-SpbmEntityConfiguration -VM $_ | format-table -AutoSize   
}
Disconnect-viserver -Server * -confirm:$false -ErrorAction SilentlyContinue |out-null
