<#
.SYNOPSIS
    Updates Azure VM NICs by replacing them with new NICs that have secondary IP addresses.

.DESCRIPTION
    This script processes a list of VMs from a CSV file and performs the following operations:
    1. Deallocates the VM
    2. Creates a new NIC with the specified IP address
    3. Attaches the new NIC to the VM
    4. Detaches and deletes the original NIC
    5. Powers on the VM

.PARAMETER CsvPath
    Path to the CSV file containing VM information.
    Required columns: VMName, ResourceGroup, VNetResourceGroup, VNetName, SubnetName, NewNicIPAddress

.PARAMETER LogPath
    Path to the log file. Defaults to .\vm-nic-update-log.txt

.EXAMPLE
    .\Update-VMNics.ps1 -CsvPath ".\vms.csv"

.NOTES
    Author: Azure CLI Script
    Date: 2025-10-21
    Requires: Azure CLI installed and authenticated
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$CsvPath,
    
    [Parameter(Mandatory=$false)]
    [string]$LogPath = ".\vm-nic-update-log.txt"
)

# Function to write log messages
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARNING','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to console with color
    switch ($Level) {
        'ERROR'   { Write-Host $logMessage -ForegroundColor Red }
        'WARNING' { Write-Host $logMessage -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $logMessage -ForegroundColor Green }
        default   { Write-Host $logMessage }
    }
    
    # Write to log file
    Add-Content -Path $LogPath -Value $logMessage
}

# Function to execute Azure CLI commands with error handling
function Invoke-AzCommand {
    param(
        [string]$Command,
        [string]$Description
    )
    
    Write-Log "Executing: $Description" -Level INFO
    Write-Log "Command: az $Command" -Level INFO
    
    try {
        $output = Invoke-Expression "az $Command 2>&1"
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -ne 0) {
            Write-Log "Command failed with exit code $exitCode" -Level ERROR
            Write-Log "Output: $output" -Level ERROR
            return $null
        }
        
        Write-Log "Command completed successfully" -Level SUCCESS
        # Return a success indicator for --no-wait commands that have no output
        if ([string]::IsNullOrWhiteSpace($output)) {
            return "SUCCESS"
        }
        return $output
    }
    catch {
        Write-Log "Exception occurred: $_" -Level ERROR
        return $null
    }
}

# Function to wait for VM to reach a specific state
function Wait-VMState {
    param(
        [string]$VMName,
        [string]$ResourceGroup,
        [string]$TargetState,
        [int]$MaxWaitMinutes = 10
    )
    
    Write-Log "Waiting for VM '$VMName' to reach state: $TargetState" -Level INFO
    
    $maxAttempts = $MaxWaitMinutes * 6  # Check every 10 seconds
    $attempt = 0
    
    while ($attempt -lt $maxAttempts) {
        $vmStatus = az vm get-instance-view --name $VMName --resource-group $ResourceGroup --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus" -o tsv 2>$null
        
        if ($vmStatus -like "*$TargetState*") {
            Write-Log "VM reached target state: $vmStatus" -Level SUCCESS
            return $true
        }
        
        Start-Sleep -Seconds 10
        $attempt++
        
        if ($attempt % 6 -eq 0) {
            Write-Log "Still waiting... Current state: $vmStatus ($(($attempt/6)) minutes elapsed)" -Level INFO
        }
    }
    
    Write-Log "Timeout waiting for VM to reach state: $TargetState" -Level WARNING
    return $false
}

# Main script execution
Write-Log "========================================" -Level INFO
Write-Log "Starting VM NIC Update Process" -Level INFO
Write-Log "========================================" -Level INFO

# Verify Azure CLI is installed
Write-Log "Verifying Azure CLI installation..." -Level INFO
$null = az version 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Log "Azure CLI is not installed or not in PATH" -Level ERROR
    exit 1
}
Write-Log "Azure CLI is installed" -Level SUCCESS

# Verify authentication
Write-Log "Verifying Azure authentication..." -Level INFO
$null = az account show 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Log "Not authenticated to Azure. Please run 'az login'" -Level ERROR
    exit 1
}
$accountName = az account show --query "name" -o tsv
Write-Log "Authenticated to subscription: $accountName" -Level SUCCESS

# Verify CSV file exists
if (-not (Test-Path $CsvPath)) {
    Write-Log "CSV file not found: $CsvPath" -Level ERROR
    exit 1
}

# Import CSV
Write-Log "Importing CSV file: $CsvPath" -Level INFO
try {
    $vms = Import-Csv -Path $CsvPath
    Write-Log "Successfully imported $($vms.Count) VMs from CSV" -Level SUCCESS
}
catch {
    Write-Log "Failed to import CSV: $_" -Level ERROR
    exit 1
}

# Validate CSV columns
$requiredColumns = @('VMName', 'ResourceGroup', 'VNetResourceGroup', 'VNetName', 'SubnetName', 'NewNicIPAddress')
$csvColumns = $vms[0].PSObject.Properties.Name

# Support both NewNicIPAddress and SecondaryIPAddress for backward compatibility
$hasNewNicIP = 'NewNicIPAddress' -in $csvColumns
$hasSecondaryIP = 'SecondaryIPAddress' -in $csvColumns

if (-not $hasNewNicIP -and -not $hasSecondaryIP) {
    Write-Log "Required column 'NewNicIPAddress' or 'SecondaryIPAddress' not found in CSV" -Level ERROR
    Write-Log "Required columns: VMName, ResourceGroup, VNetResourceGroup, VNetName, SubnetName, NewNicIPAddress" -Level ERROR
    exit 1
}

foreach ($column in @('VMName', 'ResourceGroup', 'VNetResourceGroup', 'VNetName', 'SubnetName')) {
    if ($column -notin $csvColumns) {
        Write-Log "Required column '$column' not found in CSV" -Level ERROR
        Write-Log "Required columns: $($requiredColumns -join ', ')" -Level ERROR
        exit 1
    }
}

# Capture script start time for duration calculation
$scriptStartTime = Get-Date

# Process each VM
$successCount = 0
$failureCount = 0

foreach ($vm in $vms) {
    Write-Log "" -Level INFO
    Write-Log "========================================" -Level INFO
    Write-Log "Processing VM: $($vm.VMName)" -Level INFO
    Write-Log "========================================" -Level INFO
    
    $vmName = $vm.VMName
    $resourceGroup = $vm.ResourceGroup
    # Support both column names for backward compatibility
    $newNicIP = if ($vm.PSObject.Properties.Name -contains 'NewNicIPAddress') { $vm.NewNicIPAddress } else { $vm.SecondaryIPAddress }
    
    try {
        # Step 1: Get current VM information
        Write-Log "Getting VM information..." -Level INFO
        $vmInfo = az vm show --name $vmName --resource-group $resourceGroup --query "{location:location, nicId:networkProfile.networkInterfaces[0].id}" -o json 2>$null | ConvertFrom-Json
        
        if ($null -eq $vmInfo) {
            Write-Log "Failed to get VM information. VM may not exist." -Level ERROR
            $failureCount++
            continue
        }
        
        $location = $vmInfo.location
        $originalNicId = $vmInfo.nicId
        $originalNicName = ($originalNicId -split '/')[-1]
        
        Write-Log "VM Location: $location" -Level INFO
        Write-Log "Original NIC: $originalNicName" -Level INFO
        
        # Get original NIC details
        Write-Log "Getting original NIC details..." -Level INFO
        $originalNicInfo = az network nic show --ids $originalNicId --query "{subnetId:ipConfigurations[0].subnet.id, nsgId:networkSecurityGroup.id}" -o json 2>$null | ConvertFrom-Json
        
        if ($null -eq $originalNicInfo) {
            Write-Log "Failed to get original NIC information" -Level ERROR
            $failureCount++
            continue
        }
        
        $originalSubnetId = $originalNicInfo.subnetId
        $nsgId = $originalNicInfo.nsgId
        
        Write-Log "Original NIC Subnet: $(($originalSubnetId -split '/')[-1])" -Level INFO
        Write-Log "New NIC IP: $newNicIP" -Level INFO
        Write-Log "NSG: $(if ($nsgId) { ($nsgId -split '/')[-1] } else { 'None' })" -Level INFO
        
        # Step 2: Deallocate VM
        Write-Log "Deallocating VM..." -Level INFO
        $result = Invoke-AzCommand "vm deallocate --name $vmName --resource-group $resourceGroup --no-wait" "Deallocate VM"
        
        if ($null -eq $result) {
            Write-Log "Failed to deallocate VM" -Level ERROR
            $failureCount++
            continue
        }
        
        # Wait for VM to be deallocated
        if (-not (Wait-VMState -VMName $vmName -ResourceGroup $resourceGroup -TargetState "deallocated" -MaxWaitMinutes 10)) {
            Write-Log "VM did not deallocate in expected time" -Level WARNING
        }
        
        # Step 3: Create new NIC with temporary IP
        $newNicName = "$vmName-nic-new"
        
        # Check if the current NIC is already named *-nic-new (from previous run)
        # If so, use a different name for the new NIC to avoid conflict
        if ($originalNicName -eq $newNicName) {
            Write-Log "Original NIC is already named '$newNicName', using alternate name" -Level WARNING
            $newNicName = "$vmName-nic-replacement"
        }
        
        # Check if new NIC name already exists (from previous failed run) and delete it if not attached
        $existingNewNic = az network nic show --name $newNicName --resource-group $resourceGroup --query "{id:id, vmId:virtualMachine.id}" -o json 2>$null | ConvertFrom-Json
        if ($existingNewNic) {
            if ($existingNewNic.vmId) {
                Write-Log "NIC '$newNicName' exists and is attached to a VM - cannot delete" -Level ERROR
                Write-Log "Please manually clean up this NIC first" -Level ERROR
                $failureCount++
                continue
            } else {
                Write-Log "Found detached NIC '$newNicName' from previous run, deleting..." -Level WARNING
                az network nic delete --name $newNicName --resource-group $resourceGroup 2>$null
                Start-Sleep -Seconds 5
            }
        }
        
        # Get an available IP from the subnet
        Write-Log "Querying subnet for available temporary IP..." -Level INFO
        $availableIPs = az network vnet subnet list-available-ips --ids $originalSubnetId --query "[0]" -o tsv 2>$null
        if ($availableIPs) {
            $tempIP = $availableIPs
            Write-Log "Using available IP from subnet: $tempIP" -Level INFO
        } else {
            # Fallback to hash-based IP if query fails
            $vmHash = [Math]::Abs($vmName.GetHashCode()) % 245 + 10
            $tempIP = "10.0.0.$vmHash"
            Write-Log "Using hash-based temporary IP: $tempIP" -Level WARNING
        }
        Write-Log "Creating new NIC: $newNicName with temporary IP: $tempIP" -Level INFO
        Write-Log "Will update to final IP ($newNicIP) after old NIC is detached and deleted" -Level INFO
        
        # Build the create NIC command with temporary IP (Static allocation is automatic when IP is specified)
        $createNicCmd = "network nic create --name $newNicName --resource-group $resourceGroup --location $location --subnet `"$originalSubnetId`" --private-ip-address $tempIP"
        
        # Add NSG if original NIC had one
        if ($nsgId) {
            $createNicCmd += " --network-security-group `"$nsgId`""
        }
        
        $result = Invoke-AzCommand $createNicCmd "Create new NIC"
        
        if ($null -eq $result) {
            Write-Log "Failed to create new NIC" -Level ERROR
            Write-Log "Attempting to restart VM with original NIC..." -Level WARNING
            az vm start --name $vmName --resource-group $resourceGroup --no-wait 2>$null
            $failureCount++
            continue
        }
        
        # Get new NIC ID
        $newNicId = az network nic show --name $newNicName --resource-group $resourceGroup --query "id" -o tsv 2>$null
        
        # Step 4: Attach new NIC to VM (VM will now have 2 NICs)
        Write-Log "Attaching new NIC to VM..." -Level INFO
        $result = Invoke-AzCommand "vm nic add --vm-name $vmName --resource-group $resourceGroup --nics `"$newNicId`"" "Attach new NIC"
        
        if ($null -eq $result) {
            Write-Log "Failed to attach new NIC" -Level ERROR
            Write-Log "Cleaning up new NIC..." -Level WARNING
            az network nic delete --name $newNicName --resource-group $resourceGroup --no-wait 2>$null
            az vm start --name $vmName --resource-group $resourceGroup --no-wait 2>$null
            $failureCount++
            continue
        }

        # Step 5: Detach original NIC
        Write-Log "Detaching original NIC..." -Level INFO
        $result = Invoke-AzCommand "vm nic remove --vm-name $vmName --resource-group $resourceGroup --nics `"$originalNicId`"" "Detach original NIC"
        
        if ($null -eq $result) {
            Write-Log "Failed to detach original NIC" -Level ERROR
            Write-Log "Attempting to restore original configuration..." -Level WARNING
            az vm nic remove --vm-name $vmName --resource-group $resourceGroup --nics "$newNicId" 2>$null
            az network nic delete --name $newNicName --resource-group $resourceGroup --no-wait 2>$null
            az vm start --name $vmName --resource-group $resourceGroup --no-wait 2>$null
            $failureCount++
            continue
        }

        # Step 6: Delete original NIC (now detached and safe to delete)
        Write-Log "Deleting original NIC: $originalNicName" -Level INFO
        $result = Invoke-AzCommand "network nic delete --name $originalNicName --resource-group $resourceGroup" "Delete original NIC"
        
        if ($null -eq $result) {
            Write-Log "Failed to delete original NIC (non-critical)" -Level WARNING
        } else {
            # Wait 15 seconds after deleting NIC to ensure IPs are fully released
            Write-Log "Waiting 15 seconds after deleting NIC to ensure IPs are fully released..." -Level INFO
            Start-Sleep -Seconds 15
            
            # Step 7: Update new NIC IP from temporary to final
            Write-Log "Updating new NIC IP from temporary ($tempIP) to final ($newNicIP)..." -Level INFO
            $result = Invoke-AzCommand "network nic ip-config update --nic-name `"$newNicName`" --resource-group `"$resourceGroup`" --name ipconfig1 --private-ip-address `"$newNicIP`"" "Update NIC IP address"
            
            if ($null -eq $result) {
                Write-Log "Failed to update NIC IP address" -Level WARNING
                Write-Log "NIC will keep temporary IP: $tempIP" -Level WARNING
            }
        }
        
        # Step 8: Power on VM
        Write-Log "Starting VM..." -Level INFO
        $result = Invoke-AzCommand "vm start --name $vmName --resource-group $resourceGroup --no-wait" "Start VM"
        
        if ($null -eq $result) {
            Write-Log "Failed to start VM" -Level ERROR
            $failureCount++
            continue
        }
        
        # Wait for VM to start
        if (-not (Wait-VMState -VMName $vmName -ResourceGroup $resourceGroup -TargetState "running" -MaxWaitMinutes 10)) {
            Write-Log "VM did not start in expected time" -Level WARNING
        }
        
        Write-Log "Successfully completed NIC update for VM: $vmName" -Level SUCCESS
        $successCount++
    }
    catch {
        Write-Log "Unexpected error processing VM: $_" -Level ERROR
        $failureCount++
    }
}

# Final summary
Write-Log "" -Level INFO
Write-Log "========================================" -Level INFO
Write-Log "VM NIC Update Process Complete" -Level INFO
Write-Log "========================================" -Level INFO
Write-Log "Total VMs processed: $($vms.Count)" -Level INFO
Write-Log "Successful: $successCount" -Level SUCCESS
Write-Log "Failed: $failureCount" -Level $(if ($failureCount -gt 0) { 'WARNING' } else { 'INFO' })
Write-Log "Log file: $LogPath" -Level INFO

# Post-test verification if any VMs were successful
if ($successCount -gt 0) {
    Write-Host "`n=== Post-Test Verification ===`n" -ForegroundColor Cyan
    
    foreach ($vm in $vms) {
        $vmName = $vm.VMName
        $resourceGroup = $vm.ResourceGroup
        $expectedIP = $vm.NewNicIPAddress
        
        try {
            # Determine the new NIC name (same logic as during processing)
            $vmInfo = az vm show --name $vmName --resource-group $resourceGroup --query "{nics:networkProfile.networkInterfaces}" -o json 2>$null | ConvertFrom-Json
            if ($vmInfo.nics -and $vmInfo.nics.Count -gt 0) {
                $originalNicId = $vmInfo.nics[0].id
                $originalNicName = $originalNicId.Split('/')[-1]
                $newNicName = if ($originalNicName -eq "$vmName-nic-new") { "$vmName-nic-replacement" } else { "$vmName-nic-new" }
                
                Write-Host "VM: $vmName (Expected IP: $expectedIP)" -ForegroundColor Yellow
                
                # Get NIC details
                $nicInfo = az network nic show --name $newNicName --resource-group $resourceGroup --query "{Name:name, IP:ipConfigurations[0].privateIPAddress, Allocation:ipConfigurations[0].privateIPAllocationMethod}" -o json 2>$null | ConvertFrom-Json
                
                if ($nicInfo) {
                    if ($nicInfo.IP -eq $expectedIP -and $nicInfo.Allocation -eq "Static") {
                        Write-Host "  ✅ PASS - NIC: $($nicInfo.Name) | IP: $($nicInfo.IP) | Allocation: $($nicInfo.Allocation)" -ForegroundColor Green
                    } else {
                        Write-Host "  ❌ FAIL - NIC: $($nicInfo.Name) | IP: $($nicInfo.IP) | Allocation: $($nicInfo.Allocation)" -ForegroundColor Red
                    }
                    Write-Host ""
                }
            }
        }
        catch {
            Write-Host "  ⚠️  Could not verify VM: $vmName" -ForegroundColor Yellow
            Write-Host ""
        }
    }
}

if ($failureCount -gt 0) {
    exit 1
}
