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
- ✅ **Smart Detection** - Automatically detects already-processed VMs and skips unnecessary operations
- ✅ **Accelerated Networking Enhancement** - Enables accelerated networking without VM deallocation when possible
- ✅ **Idempotency** - Safe to re-run multiple times without side effects
- ✅ **Naming Conflict Detection** - Handles existing NICs intelligently with alternate naming
- ✅ **Azure IP Query** - Queries subnet for available temporary IPs
- ✅ **Optimized Performance** - 15-second wait time
- ✅ **Comprehensive Error Handling** - Automatic rollback on failure
- ✅ **Temporary IP Strategy** - Uses temporary IP during swap, then updates to final IP

### Post-Execution Features
- ✅ **Detailed Logging** - Color-coded console output and file logs
- ✅ **Duration Tracking** - Timestamps and total execution time
- ✅ **Final VM Status Summary** - Clear display of final VM configuration with IP addresses and accelerated networking status

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

## Automated CSV Generation

Instead of manually creating the CSV file, you can use the included `generate_csv.sh` script to automatically discover VMs and generate the CSV file with all required information.

### Prerequisites for CSV Generation

- **Bash shell** (Linux/macOS/WSL/Git Bash on Windows)
- **Azure CLI** installed and authenticated (`az login`)
- **jq** installed (JSON processor)
- VMs must have **secondary IP addresses** already configured

### CSV Generation Usage

#### Make Script Executable (First Time Only)

```bash
chmod +x generate_csv.sh
```

#### Basic Usage - All VMs in Resource Group

```bash
./generate_csv.sh RG-EastUS
```

This creates: `RG-EastUS-vms.csv`

#### Custom Output Filename

```bash
./generate_csv.sh RG-EastUS my-custom-vms.csv
```

This creates: `my-custom-vms.csv`

#### Filter VMs by Name Pattern

```bash
./generate_csv.sh RG-EastUS RG-EastUS-vms.csv prod
```

This creates: `RG-EastUS-vms.csv` containing only VMs with "prod" in their name

### CSV Generation Features

✅ **Automatic Discovery** - Queries Azure to find all VMs in the resource group
✅ **Secondary IP Validation** - Verifies each VM has a secondary IP (required for NIC swap)
✅ **Network Details Extraction** - Automatically retrieves VNet, subnet, and IP information
✅ **Error Prevention** - Fails with clear error if any VM is missing a secondary IP
✅ **Resource Group Naming** - Default output file named after the resource group
✅ **VM Filtering** - Optional name pattern matching for selective VM processing

### CSV Generation Output Example

```bash
$ ./generate_csv.sh RG-EastUS
Querying VMs in resource group: RG-EastUS
Processing all VMs in the resource group...
Processing VM: testvm1
  ✅ Primary IP: 10.0.0.7, Secondary IP: 10.0.0.9
Processing VM: testvm2
  ✅ Primary IP: 10.0.0.8, Secondary IP: 10.0.0.10
Processing VM: testvm3
  ✅ Primary IP: 10.0.0.6, Secondary IP: 10.0.0.11

✅ Successfully processed 3 VM(s) - All VMs have secondary IPs
CSV file generated: RG-EastUS-vms.csv

You can now use this CSV file with the NIC swap scripts:
  PowerShell: .\Update-VMNics.ps1 -CsvPath RG-EastUS-vms.csv
  Bash:       bash ./update-vm-nics.sh RG-EastUS-vms.csv
```

### Important Notes

**Secondary IP Requirement**: The script will **fail** if any VM does not have a secondary IP address. This is by design, as secondary IPs are required for the NIC swap process.

**To add a secondary IP** to a VM's NIC:
```bash
az network nic ip-config create \
  --resource-group <resource-group> \
  --nic-name <nic-name> \
  --name ipconfig2 \
  --private-ip-address <new-ip-address>
```

**Example**:
```bash
az network nic ip-config create \
  --resource-group RG-EastUS \
  --nic-name testvm1-nic \
  --name ipconfig2 \
  --private-ip-address 10.0.0.9
```

### Manual CSV Creation

If you prefer to create the CSV manually or need to customize it, you can create a CSV file with the format shown in the "CSV File Format" section above.

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
- **15-Second Wait**: After deleting old NIC, script waits 15 seconds for IP release 
- **Static Allocation**: When `--private-ip-address` is specified, Azure CLI automatically assigns Static allocation

### Naming Strategy & Smart Detection
- **Default Naming**: New NIC named `{vmname}-nic-new`
- **Smart Detection**: If VM already has `{vmname}-nic-new`, script intelligently:
  - ✅ **Skips full replacement** - No unnecessary NIC swap operations
  - ✅ **Updates accelerated networking only** - Enables if missing from existing NIC
  - ✅ **No-op if already configured** - Exits successfully if accelerated networking already enabled
  - ✅ **Avoids unnecessary deallocations** - Only deallocates VMs when absolutely required
- **Accelerated Networking Enhancement**: 
  - ✅ **Portal-style enablement** - Attempts to enable accelerated networking on running VMs first
  - ✅ **Fallback deallocation** - Only deallocates if the running approach fails
  - ✅ **Zero downtime when possible** - Minimizes VM disruption
- **Idempotency**: Script is completely safe to re-run multiple times
  - Previous replacements detected and handled intelligently
  - Only missing configurations are applied
  - Detached NICs from failed runs are cleaned up automatically

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

**Issue**: Failed to retrieve available IP from subnet
- **Solution**: Check if subnet has available IPs or expand the subnet address space
- **Causes**: 
  - Subnet is full (all IPs allocated)
  - Insufficient permissions to query subnet
  - Azure API issue
- **Command**: `az network vnet subnet show --ids <subnet-id> --query "addressPrefix"`
- **Check available IPs**: `az network vnet subnet list-available-ips --ids <subnet-id>`

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

### Execution Log
- **Console Output**: Color-coded messages (Errors=Red, Warnings=Yellow, Success=Green, Info=Blue)
- **Log File**: Complete operation history with timestamps
- **Automatic Naming**: `vm-nic-update-{ResourceGroup}.log` (extracted from CSV)
- **Default Location**: `.\vm-nic-update-{ResourceGroup}.log`
- **Per Resource Group**: Each resource group gets its own dedicated log file

**Examples:**
- Processing VMs in `RG-Production`: creates `vm-nic-update-RG-Production.log`
- Processing VMs in `RG-EastUS`: creates `vm-nic-update-RG-EastUS.log`
- Processing VMs in `rg-dev-westus`: creates `vm-nic-update-rg-dev-westus.log`

**Log Levels:**
- `INFO`: General informational messages
- `SUCCESS`: Operation completed successfully
- `WARNING`: Non-critical issues
- `ERROR`: Critical failures

**Custom Log Path:**
You can override the automatic naming by specifying a custom log path:
- PowerShell: `.\Update-VMNics.ps1 -CsvPath ".\vms.csv" -LogPath ".\custom-log.txt"`
- Bash: `./update-vm-nics.sh ./vms.csv ./custom-log.txt`



## Safety Features

1. **Validation Before Execution**: Checks CSV format and Azure authentication
2. **Smart Idempotency**: Detects already-processed VMs and applies only needed updates
3. **Intelligent Deallocation**: Only deallocates VMs when absolutely necessary
4. **Accelerated Networking Only Mode**: Updates existing NICs without full replacement when appropriate
5. **Portal-style Updates**: Attempts accelerated networking changes on running VMs first
6. **Rollback Capability**: Attempts to restore original state on failure
7. **State Monitoring**: Waits for operations to complete before proceeding
8. **Detailed Logging**: Complete audit trail of all operations
9. **Error Recovery**: Attempts to restart VMs if operations fail

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
- **Average time per VM**: 2-3 minutes
- **Wait time**: 15 seconds

**Example**: Processing 3 VMs takes ~8-9 minutes

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
[2025-10-21 17:08:15] [INFO] Processing VM: testvm4
[2025-10-21 17:08:16] [INFO] VM already has new NIC format (testvm4-nic-new), checking accelerated networking...
[2025-10-21 17:08:17] [INFO] Enabling accelerated networking on existing NIC: testvm4-nic-new
[2025-10-21 17:08:45] [SUCCESS] Successfully enabled accelerated networking on testvm4-nic-new
[2025-10-21 17:08:50] [SUCCESS] Successfully updated accelerated networking for VM: testvm4
[2025-10-21 17:08:15] [INFO] Total VMs processed: 4
[2025-10-21 17:08:15] [SUCCESS] Successful: 4
[2025-10-21 17:08:15] [INFO] Failed: 0
[2025-10-21 17:08:15] [INFO] Log file: .\vm-nic-update-RG-Production.log

=== Final VM Status ===

VM: testvm1 | IP: 10.0.0.7 | Accelerated Networking: ✅ Enabled
VM: testvm2 | IP: 10.0.0.8 | Accelerated Networking: ✅ Enabled
VM: testvm3 | IP: 10.0.0.9 | Accelerated Networking: ✅ Enabled
VM: testvm4 | IP: 10.0.0.10 | Accelerated Networking: ✅ Enabled
```

### Final VM Status Summary

After successful completion, the script displays a clean summary showing:
- **VM Name**: The name of each processed VM
- **Current IP**: The current primary IP address assigned to the VM
- **Accelerated Networking Status**: Whether accelerated networking is enabled (✅) or disabled (❌)

This summary provides an at-a-glance view of the final configuration state without requiring manual verification commands.



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

## Accelerated Networking Configuration Tool

In addition to the full NIC swap functionality, this repository includes a standalone tool specifically for enabling/disabling accelerated networking on existing VMs **without performing a NIC replacement**.

### When to Use This Tool

Use the accelerated networking tool (`set-accelerated-networking.sh`) when you:
- ✅ Want to enable/disable accelerated networking on existing NICs
- ✅ Need to bulk-configure accelerated networking across multiple VMs
- ✅ Want to avoid a full NIC swap operation
- ❌ Do **NOT** need to change IP addresses or replace NICs

**Note**: This tool **only modifies the accelerated networking setting** - it does not swap NICs or change IP addresses.

### Accelerated Networking Tool Location

The tool is located in the `accelerated-networking/` subfolder:
- **Script**: `accelerated-networking/set-accelerated-networking.sh`
- **Sample CSV**: `accelerated-networking/accelerated-networking-config.csv`

### CSV Format for Accelerated Networking

Create a CSV file with these columns:

| Column | Description | Example |
|--------|-------------|---------|
| `VMName` | Name of the VM | testvm1 |
| `ResourceGroup` | Resource group containing the VM | RG-EastUS |
| `EnableAcceleratedNetworking` | `true` to enable, `false` to disable | true |

**Sample CSV**:
```csv
VMName,ResourceGroup,EnableAcceleratedNetworking
testvm1,RG-EastUS,true
testvm2,RG-EastUS,true
testvm3,RG-EastUS,false
```

### Usage

```bash
cd accelerated-networking
bash set-accelerated-networking.sh accelerated-networking-config.csv
```

### Features

✅ **Bulk Processing** - Configure multiple VMs from a single CSV file
✅ **Smart Skip Logic** - Automatically skips VMs already in the desired state
✅ **No VM Restart Required** - Changes take effect immediately without reboot
✅ **Auto-Discovery** - Automatically finds the VM's NIC (no manual NIC name required)
✅ **Detailed Summary** - Shows count of successful updates, skipped VMs, and errors

### Example Output

```
Starting accelerated networking configuration...
Reading from: accelerated-networking-config.csv

Processing VM: testvm1 (Line: 2)
  Getting NIC information...
  Current accelerated networking: false
  Target accelerated networking: true
  Updating accelerated networking to true...
  ✅ Successfully enabled accelerated networking on testvm1-nic-new

Processing VM: testvm2 (Line: 3)
  Getting NIC information...
  Current accelerated networking: true
  Target accelerated networking: true
  ℹ️  No change needed - already set to true

Processing VM: testvm3 (Line: 4)
  Getting NIC information...
  Current accelerated networking: true
  Target accelerated networking: false
  Updating accelerated networking to false...
  ✅ Successfully disabled accelerated networking on testvm3-nic-new

================================================
Summary:
  ✅ Successfully updated: 2 VM(s)
  ⚠️  Skipped (no change needed or invalid value): 1 VM(s)
  ❌ Failed: 0 VM(s)
================================================
```

### Important Notes

- **No VM Deallocation**: Unlike the full NIC swap, this tool does NOT require VM deallocation or restart
- **Instant Effect**: Accelerated networking changes take effect immediately
- **Independent Tool**: This tool operates completely independently from the NIC swap scripts
- **Validation**: Only accepts `true` or `false` values for the `EnableAcceleratedNetworking` column

## License

This script is provided as-is for use with Azure resources.
