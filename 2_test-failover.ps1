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
        if ((get-vm -name $_ -server $siteSRC).PowerState -eq "PoweredOn") {
            write-host "force stopping $_.name"
            stop-vm $_ -Confirm:$false  | Out-Null
        }
    }
}

write-host "Prepare Failover"
$prepareFailover = start-spbmreplicationpreparefailover $rgPair.Source -Confirm:$false -RunAsync
Wait-Task $prepareFailover
$startFailover = Start-SpbmReplicationTestFailover $rgPair.Target -Confirm:$false -RunAsync
$vmxfile = Wait-Task $startFailover

$newDstVMs= @()
$vmhostDST = get-vmhost -Server $siteDST | select -First 1
$vmxfile | ForEach-Object {
    write-host $_
    $newVM = New-VM -VMFilePath $_ -VMHost $vmhostDST 
    $newDstVMs += $newVM
}
$newDstVms | forEach-object {
    get-vm -name $_.name -server $siteSRC | Start-VM -Confirm:$false -RunAsync | out-null
    $vmtask = start-vm $_ -server $siteDST -ErrorAction SilentlyContinue -Confirm:$false -RunAsync
    wait-task $vmtask -ErrorAction SilentlyContinue | out-null
    $_ | Get-VMQuestion | Set-VMQuestion -Option ‘button.uuid.movedTheVM’ -Confirm:$false
    while ((get-vm -name $_.name -server $siteDST).PowerState -eq "PoweredOff" ) {
        Start-Sleep -Seconds 5 
    }
    $_ | get-networkadapter | Set-NetworkAdapter -server $siteDST -connected:$false -StartConnected:$false -Confirm:$false
}
####

#$newDstVMs | foreach-object { stop-vm -Confirm:$false $_; remove-vm -Confirm:$false $_ }
#Stop-SpbmReplicationTestFailover $rgpair.target


#Disconnect-viserver -Server * -confirm:$false -ErrorAction SilentlyContinue |out-null
