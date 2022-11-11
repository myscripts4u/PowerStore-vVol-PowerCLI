### 0 CLEAN ALL
Disconnect-viserver -Server * -confirm:$false -ErrorAction SilentlyContinue |out-null
Remove-Variable * -ErrorAction SilentlyContinue
Remove-Module *
$error.Clear();

### 1
Import-Module VMware.VimAutomation.Core
Import-Module VMware.VimAutomation.Common
Import-Module VMware.VimAutomation.Storage
			
$vcUser = 'administrator@vsphere.local'			# Change this to your VC username
$vcPass = 'Password123!'					# VC password

$siteDR = "vcsa-a.lab"
$RgTarget = "5d779a8e-c318-426d-8352-5644e9e884ae"

#$siteDR = "vcsa-b.lab"					# DR vCenter
#$RgTarget = "c6c66ee6-e69b-4d3d-b5f2-7d0658a82292"	# Replication Group Target – required from replication Source before running the unplanned failover
								# to get the information run get-SpbmReplicationPair | format-table -autosize when connected to both vCenter
Connect-VIServer -User "$vcUser" -Password "$vcPass" -Server $siteDR -WarningAction SilentlyContinue
# initiate the failover and preserve vmxfiles in $vmxfile
$vmxfile = Start-SpbmReplicationFailover -server $siteDR -Unplanned -ReplicationGroup $RgTarget
$newDstVMs= @()
$vmhostDST = get-vmhost -Server $siteDR | select -First 1
$vmxfile | ForEach-Object {
    write-host $_
    $newVM = New-VM -VMFilePath $_ -VMHost $vmhostDST 
    $newDstVMs += $newVM
}
$newDstVms | forEach-object {
    $vmtask = start-vm $_ -server $siteDST -ErrorAction SilentlyContinue -Confirm:$false -RunAsync
    wait-task $vmtask -ErrorAction SilentlyContinue | out-null
    $_ | Get-VMQuestion | Set-VMQuestion -Option ‘button.uuid.movedTheVM’ -Confirm:$false
}

