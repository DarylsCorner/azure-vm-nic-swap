# Azure VM NIC Update Script

[![Azure](https://img.shields.io/badge/Azure-0078D4?style=for-the-badge&logo=microsoft-azure&logoColor=white)](https://azure.microsoft.com/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](LICENSE)
[![Status](https://img.shields.io/badge/Status-Production%20Ready-success?style=for-the-badge)](README.md)

This script automates the process of replacing Azure VM NICs while preserving secondary IP addresses. The secondary IP from the old NIC becomes the primary IP on the new NIC with Static allocation.

**Available in two versions:**
- **PowerShell** (`Update-VMNics.ps1`) - For Windows
- **Bash** (`update-vm-nics.sh`) - For Linux/macOS

## Key Features

### Core Functionality
- ✅ **Batch Processing** - Process multiple VMs from CSV file
- ✅ **IP Preservation** - Preserves secondary IPs from original NICs
- ✅ **Static IP Allocation** - Automatic Static allocation when IP specified
- ✅ **NSG Preservation** - Maintains Network Security Groups
- ✅ **Accelerated Networking** - Preserves accelerated networking configuration
- ✅ **Safe Deallocation** - Safely shuts down VMs before NIC changes
- ✅ **Auto Power-On** - Starts VMs after successful changes

### Advanced Features
- ✅ **Idempotency** - Safe to re-run multiple times without side effects
- ✅ **Naming Conflict Detection** - Handles existing NICs intelligently with alternate naming
- ✅ **Azure IP Query** - Queries subnet for available temporary IPs
- ✅ **Optimized Performance** - 15-second wait time (40% faster than 2-minute wait)
- ✅ **Comprehensive Error Handling** - Automatic rollback on failure
- ✅ **Temporary IP Strategy** - Uses temporary IP during swap, then updates to final IP

### Post-Execution Features
- ✅ **Post-Execution Verification** - Verifies each VM's new NIC configuration
- ✅ **IP Validation** - Confirms actual IP vs expected IP
- ✅ **Allocation Verification** - Confirms Static IP allocation
- ✅ **Detailed Logging** - Color-coded console output and file logs
- ✅ **Duration Tracking** - Timestamps and total execution time

## Prerequisites

### Common Prerequisites

1. **Azure CLI** must be installed
   - Download from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
   - Verify installation: `az --version`

2. **Authentication** to Azure
   ```bash
   az login
   ```

3. **Permissions** required:
   - Virtual Machine Contributor (or Owner) on VM resource groups
   - Network Contributor (or Owner) on network resource groups
   - Reader access on VNet resource groups

### Linux/Bash Additional Prerequisites

4. **jq** (JSON processor) must be installed
   - Ubuntu/Debian: `sudo apt-get install jq`
   - RHEL/CentOS: `sudo yum install jq`
   - macOS: `brew install jq`

## CSV File Format

Create a CSV file with the following columns:

| Column | Description | Example |
|--------|-------------|---------|
| `VMName` | Name of the VM | vm-web-01 |
| `ResourceGroup` | Resource group containing the VM | rg-production-eastus |
| `VNetResourceGroup` | Resource group containing the VNet | rg-network-eastus |
| `VNetName` | Name of the virtual network | vnet-prod-eastus |
| `SubnetName` | Name of the subnet | subnet-web |
| `NewNicIPAddress` | IP address for the new NIC | 10.0.1.10 |

**Important**: The `NewNicIPAddress` can be:
- The same as the current VM's IP (it will be freed when old NIC is removed)
- A different IP address in the same subnet
- Must be available in the target subnet

### Sample CSV

See `sample-vms.csv` for an example.

## Usage

### Windows (PowerShell)

#### Basic Usage

```powershell
.\Update-VMNics.ps1 -CsvPath ".\vms.csv"
```

#### With Custom Log Path

```powershell
.\Update-VMNics.ps1 -CsvPath ".\vms.csv" -LogPath ".\custom-log.txt"
```

#### Review Script Before Running

```powershell
Get-Content .\Update-VMNics.ps1
```

### Linux/macOS (Bash)

#### Make Script Executable

```bash
chmod +x update-vm-nics.sh
```

#### Basic Usage

```bash
./update-vm-nics.sh ./vms.csv
```

#### With Custom Log Path

```bash
./update-vm-nics.sh ./vms.csv ./custom-log.txt
```

#### Review Script Before Running

```bash
cat update-vm-nics.sh
```

## How It Works

For each VM in the CSV file, the script performs these steps:

1. **Validation**
   - Verifies Azure CLI installation and authentication
   - Validates CSV format and required columns
   - Retrieves current VM and NIC information

2. **Deallocate VM**
   - Safely shuts down the VM
   - Waits for deallocated state (max 10 minutes)

3. **Create New NIC with Temporary IP**
   - Queries Azure subnet for available IP addresses
   - Creates new NIC in the same location with temporary IP
   - Uses the same subnet as original NIC
   - Preserves Network Security Group (NSG) if present
   - Preserves accelerated networking configuration
   - Detects naming conflicts and uses alternate names if needed

4. **Swap NICs**
   - Attaches new NIC to VM (VM now has 2 NICs)
   - Detaches original NIC from VM
   - Deletes original NIC
   - Waits 15 seconds for IP release

5. **Update to Final IP**
   - Updates new NIC IP from temporary to final (secondary IP from old NIC)
   - IP is assigned with Static allocation

6. **Power On & Verify**
   - Starts the VM
   - Waits for running state (max 10 minutes)
   - Verifies final NIC configuration
   - Confirms Static IP allocation

## Important Notes

### IP Address Handling
- **Temporary IP Strategy**: The script creates the new NIC with a temporary IP, then updates to the final IP after the old NIC is deleted
- **Azure IP Query**: Script automatically queries Azure for available IPs in the subnet
- **15-Second Wait**: After deleting old NIC, script waits 15 seconds for IP release (optimized from 2 minutes)
- **Static Allocation**: When `--private-ip-address` is specified, Azure CLI automatically assigns Static allocation

### Naming Strategy
- **Default Naming**: New NIC named `{vmname}-nic-new`
- **Conflict Detection**: If `{vmname}-nic-new` already exists, uses `{vmname}-nic-replacement`
- **Idempotency**: Script handles existing NICs from previous runs
  - Detached NICs are deleted automatically
  - Attached NICs cause an error (manual intervention required)

### Secondary IP Preservation
- **CSV IP Address**: The `NewNicIPAddress` should be the **secondary IP** from the original NIC
- **What Happens**: 
  1. Original NIC has: Primary IP (e.g., 10.0.0.6) + Secondary IP (e.g., 10.0.0.9)
  2. Script creates new NIC with temporary IP (e.g., 10.0.0.4)
  3. After old NIC deleted, updates new NIC to final IP (10.0.0.9)
  4. Result: New NIC has only one IP (10.0.0.9) with Static allocation

## Error Handling

The script includes comprehensive error handling:

- **Rollback on Failure**: If any step fails, the script attempts to restore the VM to its original state
- **Logging**: All operations are logged with timestamps and severity levels
- **State Validation**: Waits for VMs to reach expected states before proceeding
- **Retry Logic**: Built into Azure CLI operations

### Common Issues

**Issue**: VM fails to deallocate
- **Solution**: Check if VM has extensions that prevent deallocation
- **Command**: `az vm show --name <vm-name> --resource-group <rg> --query "resources"`

**Issue**: IP address already in use
- **Solution**: Verify the new NIC IP is available in the subnet or wait for the old NIC to be detached
- **Command**: `az network nic list --resource-group <rg> --query "[].ipConfigurations[].privateIPAddress"`

**Issue**: Insufficient permissions
- **Solution**: Verify you have the required RBAC roles
- **Command**: `az role assignment list --assignee <your-email>`

**Issue**: (Linux) `jq: command not found`
- **Solution**: Install jq JSON processor
- **Ubuntu/Debian**: `sudo apt-get install jq`
- **RHEL/CentOS**: `sudo yum install jq`
- **macOS**: `brew install jq`

**Issue**: (Linux) `Permission denied` when running script
- **Solution**: Make script executable
- **Command**: `chmod +x update-vm-nics.sh`

## Output Files

After execution, the script generates:

### Execution Log (`vm-nic-update-log.txt`)
- **Console Output**: Color-coded messages (Errors=Red, Warnings=Yellow, Success=Green, Info=Blue)
- **Log File**: Complete operation history with timestamps
- **Default Location**: `.\vm-nic-update-log.txt`

**Log Levels:**
- `INFO`: General informational messages
- `SUCCESS`: Operation completed successfully
- `WARNING`: Non-critical issues
- `ERROR`: Critical failures

**Example Verification Output:**
```
========================================
Post-Execution Verification
========================================
VM: testvm1 | NIC: testvm1-nic-new | IP: 10.0.0.9 (Expected: 10.0.0.9) | Allocation: Static | Status: ✅ PASS
VM: testvm2 | NIC: testvm2-nic-new | IP: 10.0.0.10 (Expected: 10.0.0.10) | Allocation: Static | Status: ✅ PASS
VM: testvm3 | NIC: testvm3-nic-new | IP: 10.0.0.11 (Expected: 10.0.0.11) | Allocation: Static | Status: ✅ PASS
```

## Safety Features

1. **Validation Before Execution**: Checks CSV format and Azure authentication
2. **Rollback Capability**: Attempts to restore original state on failure
3. **State Monitoring**: Waits for operations to complete before proceeding
4. **Detailed Logging**: Complete audit trail of all operations
5. **Error Recovery**: Attempts to restart VMs if operations fail

## Performance

### Timing Breakdown (Per VM)
| Phase | Duration | % of Total |
|-------|----------|------------|
| Deallocate VM | 30-45 seconds | 25% |
| Create New NIC | ~4 seconds | 2% |
| Attach New NIC | ~36 seconds | 21% |
| Detach Old NIC | ~36 seconds | 21% |
| Delete Old NIC | ~5 seconds | 3% |
| **Wait Period** | **15 seconds** | **9%** |
| Update IP | ~5 seconds | 3% |
| Start VM | ~17 seconds | 10% |
| Overhead | ~10 seconds | 6% |

### Optimized Performance
- **Average time per VM**: 2-3 minutes (optimized from 5-15 minutes)
- **Wait time**: 15 seconds (reduced from 2 minutes - **87.5% reduction**)
- **Total improvement**: **40% faster** for batch operations

**Example**: Processing 3 VMs takes ~8-9 minutes (down from ~14-15 minutes)

**Tip**: The script processes VMs sequentially. For large batches, consider splitting the CSV and running multiple instances in parallel.

## Example Output

### Console Output
```
[2025-10-21 16:59:32] [INFO] Starting VM NIC Update Process
[2025-10-21 16:59:32] [SUCCESS] Authenticated to subscription: your-subscription-name
[2025-10-21 16:59:32] [SUCCESS] Successfully imported 3 VMs from CSV
[2025-10-21 16:59:32] [INFO] Processing VM: testvm1
[2025-10-21 16:59:35] [INFO] Original NIC: testvm1-nic
[2025-10-21 16:59:35] [INFO] Accelerated Networking: true
[2025-10-21 16:56:35] [INFO] Querying subnet for available temporary IP...
[2025-10-21 16:56:35] [INFO] Using available IP from subnet: 10.0.0.4
[2025-10-21 16:56:35] [INFO] Creating new NIC: testvm1-nic-new with temporary IP: 10.0.0.4
[2025-10-21 16:56:35] [INFO] Enabling accelerated networking on new NIC
[2025-10-21 17:02:03] [INFO] Waiting 15 seconds after deleting NIC to ensure IPs are fully released...
[2025-10-21 17:02:18] [INFO] Updating new NIC IP from temporary (10.0.0.4) to final (10.0.0.9)...
[2025-10-21 17:02:45] [SUCCESS] Successfully completed NIC update for VM: testvm1
[2025-10-21 17:08:15] [INFO] Total VMs processed: 3
[2025-10-21 17:08:15] [SUCCESS] Successful: 3
[2025-10-21 17:08:15] [INFO] Failed: 0

========================================
Post-Execution Verification
========================================
VM: testvm1 | NIC: testvm1-nic-new | IP: 10.0.0.9 (Expected: 10.0.0.9) | Allocation: Static | Status: ✅ PASS
VM: testvm2 | NIC: testvm2-nic-new | IP: 10.0.0.10 (Expected: 10.0.0.10) | Allocation: Static | Status: ✅ PASS
VM: testvm3 | NIC: testvm3-nic-new | IP: 10.0.0.11 (Expected: 10.0.0.11) | Allocation: Static | Status: ✅ PASS
```



## Best Practices

1. **Test First**: Run on a single test VM before processing production VMs
2. **Backup**: Take VM snapshots before making changes
3. **Maintenance Window**: Schedule during low-usage periods
4. **Small Batches**: Process VMs in small batches for easier troubleshooting
5. **Verify**: Check VM connectivity and application functionality after updates

## Security Considerations

- Uses Azure CLI authentication (supports Managed Identity, Service Principal, etc.)
- No credentials stored in script or CSV
- Follows principle of least privilege
- All operations logged for audit purposes

## Troubleshooting

### Enable Debug Mode

Add `-Debug` parameter to Azure CLI commands in the script for verbose output.

### Check VM State

```powershell
az vm get-instance-view --name <vm-name> --resource-group <rg> --query "instanceView.statuses"
```

### Verify NIC Configuration

```powershell
az vm show --name <vm-name> --resource-group <rg> --query "networkProfile.networkInterfaces"
```

### List All IPs on NIC

```powershell
az network nic show --name <nic-name> --resource-group <rg> --query "ipConfigurations[].privateIPAddress"
```

## Support

For issues or questions:
1. Review the log file for detailed error messages
2. Check Azure CLI documentation: https://docs.microsoft.com/en-us/cli/azure/
3. Verify Azure permissions and quotas

## License

This script is provided as-is for use with Azure resources.
