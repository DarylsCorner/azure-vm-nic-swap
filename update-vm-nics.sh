#!/bin/bash

#########################################################################
# Script: update-vm-nics.sh
# Description: Updates Azure VM NICs by replacing them with new NICs.
#
# Usage: ./update-vm-nics.sh <csv-file> [log-file]
#
# CSV Format (required columns):
#   VMName,ResourceGroup,VNetResourceGroup,VNetName,SubnetName,NewNicIPAddress
#
# Author: Azure CLI Script
# Date: 2025-10-21
# Requires: Azure CLI (az) installed and authenticated
#########################################################################

set -o pipefail

# Color codes for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
CSV_FILE=""
LOG_FILE="./vm-nic-update-log.txt"
SUCCESS_COUNT=0
FAILURE_COUNT=0

# Capture script start time for duration calculation
start_timestamp=$(date +%s)
start_time=$(date +"%H:%M:%S")

#########################################################################
# Function: write_log
# Description: Writes log messages to console and log file
# Parameters: $1 = Level (INFO|WARNING|ERROR|SUCCESS)
#             $2 = Message
#########################################################################
write_log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_message="[$timestamp] [$level] $message"
    
    # Write to console with color
    case "$level" in
        ERROR)
            echo -e "${RED}${log_message}${NC}"
            ;;
        WARNING)
            echo -e "${YELLOW}${log_message}${NC}"
            ;;
        SUCCESS)
            echo -e "${GREEN}${log_message}${NC}"
            ;;
        INFO)
            echo -e "${BLUE}${log_message}${NC}"
            ;;
        *)
            echo "$log_message"
            ;;
    esac
    
    # Write to log file
    echo "$log_message" >> "$LOG_FILE"
}

#########################################################################
# Function: invoke_az_command
# Description: Executes Azure CLI command with error handling
# Parameters: $1 = Command (without 'az' prefix)
#             $2 = Description
# Returns: 0 on success, 1 on failure
#########################################################################
invoke_az_command() {
    local command="$1"
    local description="$2"
    
    write_log "INFO" "Executing: $description"
    write_log "INFO" "Command: az $command"
    
    local output
    if output=$(eval "az $command" 2>&1); then
        write_log "SUCCESS" "Command completed successfully"
        # Return output or SUCCESS indicator for --no-wait commands
        if [ -z "$output" ]; then
            echo "SUCCESS"
        else
            echo "$output"
        fi
        return 0
    else
        write_log "ERROR" "Command failed with exit code $?"
        write_log "ERROR" "Output: $output"
        return 1
    fi
}

#########################################################################
# Function: wait_vm_state
# Description: Waits for VM to reach a specific power state
# Parameters: $1 = VM Name
#             $2 = Resource Group
#             $3 = Target State (deallocated|running)
#             $4 = Max Wait Minutes (default: 10)
# Returns: 0 if state reached, 1 if timeout
#########################################################################
wait_vm_state() {
    local vm_name="$1"
    local resource_group="$2"
    local target_state="$3"
    local max_wait_minutes="${4:-10}"
    
    write_log "INFO" "Waiting for VM '$vm_name' to reach state: $target_state"
    
    local max_attempts=$((max_wait_minutes * 6))  # Check every 10 seconds
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        local vm_status
        vm_status=$(az vm get-instance-view --name "$vm_name" --resource-group "$resource_group" \
            --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus" -o tsv 2>/dev/null)
        
        if [[ "$vm_status" == *"$target_state"* ]]; then
            write_log "SUCCESS" "VM reached target state: $vm_status"
            return 0
        fi
        
        sleep 10
        ((attempt++))
        
        if [ $((attempt % 6)) -eq 0 ]; then
            local elapsed_minutes=$((attempt / 6))
            write_log "INFO" "Still waiting... Current state: $vm_status ($elapsed_minutes minutes elapsed)"
        fi
    done
    
    write_log "WARNING" "Timeout waiting for VM to reach state: $target_state"
    return 1
}

#########################################################################
# Function: process_vm
# Description: Processes a single VM to replace its NIC
# Parameters: $1 = VM Name
#             $2 = Resource Group
#             $3 = VNet Resource Group
#             $4 = VNet Name
#             $5 = Subnet Name
#             $6 = New NIC IP Address
# Returns: 0 on success, 1 on failure
#########################################################################
process_vm() {
    local vm_name="$1"
    local resource_group="$2"
    local vnet_resource_group="$3"
    local vnet_name="$4"
    local subnet_name="$5"
    local new_nic_ip="$6"
    
    write_log "INFO" ""
    write_log "INFO" "========================================"
    write_log "INFO" "Processing VM: $vm_name"
    write_log "INFO" "========================================"
    
    # Step 1: Get current VM information
    write_log "INFO" "Getting VM information..."
    local vm_info
    if ! vm_info=$(az vm show --name "$vm_name" --resource-group "$resource_group" \
        --query "{location:location, nicId:networkProfile.networkInterfaces[0].id}" -o json 2>&1); then
        write_log "ERROR" "Failed to get VM information. VM may not exist."
        write_log "ERROR" "$vm_info"
        return 1
    fi
    
    local location=$(echo "$vm_info" | jq -r '.location')
    local original_nic_id=$(echo "$vm_info" | jq -r '.nicId')
    local original_nic_name=$(basename "$original_nic_id")
    
    write_log "INFO" "VM Location: $location"
    write_log "INFO" "Original NIC: $original_nic_name"
    
    # Get original NIC details
    write_log "INFO" "Getting original NIC details..."
    local original_nic_info
    if ! original_nic_info=$(az network nic show --ids "$original_nic_id" \
        --query "{subnetId:ipConfigurations[0].subnet.id, nsgId:networkSecurityGroup.id}" -o json 2>&1); then
        write_log "ERROR" "Failed to get original NIC information"
        write_log "ERROR" "$original_nic_info"
        return 1
    fi
    
    local original_subnet_id=$(echo "$original_nic_info" | jq -r '.subnetId')
    local nsg_id=$(echo "$original_nic_info" | jq -r '.nsgId // empty')
    
    write_log "INFO" "Original NIC Subnet: $(basename "$original_subnet_id")"
    write_log "INFO" "New NIC IP: $new_nic_ip"
    if [ -n "$nsg_id" ]; then
        local nsg_name=$(basename "$nsg_id")
        write_log "INFO" "NSG: $nsg_name"
    else
        write_log "INFO" "NSG: None"
    fi
    
    # Step 2: Deallocate VM
    write_log "INFO" "Deallocating VM..."
    if ! invoke_az_command "vm deallocate --name \"$vm_name\" --resource-group \"$resource_group\" --no-wait" \
        "Deallocate VM" > /dev/null; then
        write_log "ERROR" "Failed to deallocate VM"
        return 1
    fi
    
    # Wait for VM to be deallocated
    if ! wait_vm_state "$vm_name" "$resource_group" "deallocated" 10; then
        write_log "WARNING" "VM did not deallocate in expected time"
    fi
    
    # Step 3: Create new NIC with temporary IP
    local new_nic_name="${vm_name}-nic-new"
    
    # Check if the current NIC is already named *-nic-new (from previous run)
    # If so, use a different name for the new NIC to avoid conflict
    if [ "$original_nic_name" = "$new_nic_name" ]; then
        write_log "WARNING" "Original NIC is already named '$new_nic_name', using alternate name"
        new_nic_name="${vm_name}-nic-replacement"
    fi
    
    # Check if new NIC name already exists (from previous failed run) and delete it if not attached
    if az network nic show --name "$new_nic_name" --resource-group "$resource_group" >/dev/null 2>&1; then
        local vm_id
        vm_id=$(az network nic show --name "$new_nic_name" --resource-group "$resource_group" --query "virtualMachine.id" -o tsv 2>/dev/null)
        if [ -n "$vm_id" ] && [ "$vm_id" != "null" ]; then
            write_log "ERROR" "NIC '$new_nic_name' exists and is attached to a VM - cannot delete"
            write_log "ERROR" "Please manually clean up this NIC first"
            return 1
        else
            write_log "WARNING" "Found detached NIC '$new_nic_name' from previous run, deleting..."
            az network nic delete --name "$new_nic_name" --resource-group "$resource_group" 2>/dev/null
            sleep 5
        fi
    fi
    
    # Get an available IP from the subnet
    write_log "INFO" "Querying subnet for available temporary IP..."
    local temp_ip
    temp_ip=$(az network vnet subnet list-available-ips --ids "$original_subnet_id" --query "[0]" -o tsv 2>/dev/null | tr -d '[:space:]')
    if [ -n "$temp_ip" ] && [ "$temp_ip" != "null" ]; then
        write_log "INFO" "Using available IP from subnet: $temp_ip"
    else
        # Fallback to hash-based IP if query fails
        local vm_hash=$(($(echo -n "$vm_name" | cksum | cut -d' ' -f1) % 245 + 10))
        temp_ip="10.0.0.${vm_hash}"
        write_log "WARNING" "Using hash-based temporary IP: $temp_ip"
    fi
    write_log "INFO" "Creating new NIC: $new_nic_name with temporary IP: $temp_ip"
    write_log "INFO" "Will update to final IP ($new_nic_ip) after old NIC is detached and deleted"
    
    # Build the create NIC command with temporary IP (Static allocation is automatic when IP is specified)
    local create_nic_cmd="network nic create --name \"$new_nic_name\" --resource-group \"$resource_group\" --location \"$location\" --subnet \"$original_subnet_id\" --private-ip-address \"$temp_ip\""
    
    # Add NSG if original NIC had one
    if [ -n "$nsg_id" ]; then
        create_nic_cmd="$create_nic_cmd --network-security-group \"$nsg_id\""
    fi
    
    if ! invoke_az_command "$create_nic_cmd" "Create new NIC" > /dev/null; then
        write_log "ERROR" "Failed to create new NIC"
        write_log "WARNING" "Attempting to restart VM with original NIC..."
        az vm start --name "$vm_name" --resource-group "$resource_group" --no-wait 2>/dev/null
        return 1
    fi
    
    # Get new NIC ID
    local new_nic_id
    if ! new_nic_id=$(az network nic show --name "$new_nic_name" --resource-group "$resource_group" --query "id" -o tsv 2>&1); then
        write_log "ERROR" "Failed to get new NIC ID"
        write_log "WARNING" "Cleaning up and re-attaching original NIC..."
        az network nic delete --name "$new_nic_name" --resource-group "$resource_group" --no-wait 2>/dev/null
        az vm nic add --vm-name "$vm_name" --resource-group "$resource_group" --nics "$original_nic_id" 2>/dev/null
        az vm start --name "$vm_name" --resource-group "$resource_group" --no-wait 2>/dev/null
        return 1
    fi
    
    # Trim whitespace from NIC ID
    new_nic_id=$(echo "$new_nic_id" | tr -d '[:space:]')
    
    # Step 4: Attach new NIC to VM (VM will now have 2 NICs)
    write_log "INFO" "Attaching new NIC to VM..."
    if ! invoke_az_command "vm nic add --vm-name \"$vm_name\" --resource-group \"$resource_group\" --nics \"$new_nic_id\"" \
        "Attach new NIC" > /dev/null; then
        write_log "ERROR" "Failed to attach new NIC"
        write_log "WARNING" "Cleaning up new NIC..."
        az network nic delete --name "$new_nic_name" --resource-group "$resource_group" --no-wait 2>/dev/null
        az vm start --name "$vm_name" --resource-group "$resource_group" --no-wait 2>/dev/null
        return 1
    fi
    
    # Step 5: Detach original NIC
    write_log "INFO" "Detaching original NIC..."
    if ! invoke_az_command "vm nic remove --vm-name \"$vm_name\" --resource-group \"$resource_group\" --nics \"$original_nic_id\"" \
        "Detach original NIC" > /dev/null; then
        write_log "ERROR" "Failed to detach original NIC"
        write_log "WARNING" "Attempting to restore original configuration..."
        az vm nic remove --vm-name "$vm_name" --resource-group "$resource_group" --nics "$new_nic_id" 2>/dev/null
        az network nic delete --name "$new_nic_name" --resource-group "$resource_group" --no-wait 2>/dev/null
        az vm start --name "$vm_name" --resource-group "$resource_group" --no-wait 2>/dev/null
        return 1
    fi
    
    # Step 6: Delete original NIC (now detached and safe to delete)
    write_log "INFO" "Deleting original NIC: $original_nic_name"
    if ! invoke_az_command "network nic delete --name \"$original_nic_name\" --resource-group \"$resource_group\"" \
        "Delete original NIC" > /dev/null; then
        write_log "WARNING" "Failed to delete original NIC (non-critical)"
    else
        # Wait 15 seconds after deleting NIC to ensure IPs are fully released
        write_log "INFO" "Waiting 15 seconds after deleting NIC to ensure IPs are fully released..."
        sleep 15
        
        # Step 7: Update new NIC IP from temporary to final
        write_log "INFO" "Updating new NIC IP from temporary ($temp_ip) to final ($new_nic_ip)..."
        if ! invoke_az_command "network nic ip-config update --nic-name \"$new_nic_name\" --resource-group \"$resource_group\" --name ipconfig1 --private-ip-address \"$new_nic_ip\"" \
            "Update NIC IP address" > /dev/null; then
            write_log "WARNING" "Failed to update NIC IP address"
            write_log "WARNING" "NIC will keep temporary IP: $temp_ip"
        fi
    fi
    
    # Step 8: Power on VM
    write_log "INFO" "Starting VM..."
    if ! invoke_az_command "vm start --name \"$vm_name\" --resource-group \"$resource_group\" --no-wait" \
        "Start VM" > /dev/null; then
        write_log "ERROR" "Failed to start VM"
        return 1
    fi
    
    # Wait for VM to start
    if ! wait_vm_state "$vm_name" "$resource_group" "running" 10; then
        write_log "WARNING" "VM did not start in expected time"
    fi
    
    write_log "SUCCESS" "Successfully completed NIC update for VM: $vm_name"
    return 0
}

#########################################################################
# Function: validate_csv
# Description: Validates CSV file format and required columns
# Parameters: $1 = CSV file path
# Returns: 0 if valid, 1 if invalid
#########################################################################
validate_csv() {
    local csv_file="$1"
    
    if [ ! -f "$csv_file" ]; then
        write_log "ERROR" "CSV file not found: $csv_file"
        return 1
    fi
    
    # Read header line
    local header
    header=$(head -n 1 "$csv_file")
    
    # Check required columns
    local required_columns=("VMName" "ResourceGroup" "VNetResourceGroup" "VNetName" "SubnetName")
    
    for column in "${required_columns[@]}"; do
        if ! echo "$header" | grep -q "$column"; then
            write_log "ERROR" "Required column '$column' not found in CSV"
            write_log "ERROR" "Required columns: ${required_columns[*]} NewNicIPAddress"
            return 1
        fi
    done
    
    # Check for either NewNicIPAddress or SecondaryIPAddress (backward compatibility)
    if ! echo "$header" | grep -q "NewNicIPAddress" && ! echo "$header" | grep -q "SecondaryIPAddress"; then
        write_log "ERROR" "Required column 'NewNicIPAddress' or 'SecondaryIPAddress' not found in CSV"
        write_log "ERROR" "Required columns: ${required_columns[*]} NewNicIPAddress"
        return 1
    fi
    
    return 0
}

#########################################################################
# Function: usage
# Description: Displays script usage information
#########################################################################
usage() {
    cat << EOF
Usage: $0 <csv-file> [log-file]

Updates Azure VM NICs by replacing them with new NICs.

Arguments:
  csv-file    Path to CSV file containing VM information (required)
  log-file    Path to log file (optional, default: ./vm-nic-update-log.txt)

CSV Format (required columns):
  VMName,ResourceGroup,VNetResourceGroup,VNetName,SubnetName,NewNicIPAddress

Example:
  $0 ./vms.csv
  $0 ./vms.csv ./custom-log.txt

EOF
}

#########################################################################
# MAIN SCRIPT EXECUTION
#########################################################################

# Check arguments
if [ $# -lt 1 ]; then
    usage
    exit 1
fi

CSV_FILE="$1"
if [ $# -ge 2 ]; then
    LOG_FILE="$2"
fi

write_log "INFO" "========================================"
write_log "INFO" "Starting VM NIC Update Process"
write_log "INFO" "========================================"

# Verify Azure CLI is installed
write_log "INFO" "Verifying Azure CLI installation..."
if ! command -v az &> /dev/null; then
    write_log "ERROR" "Azure CLI is not installed or not in PATH"
    write_log "ERROR" "Install from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi
write_log "SUCCESS" "Azure CLI is installed"

# Verify jq is installed (for JSON parsing)
write_log "INFO" "Verifying jq installation..."
if ! command -v jq &> /dev/null; then
    write_log "ERROR" "jq is not installed or not in PATH"
    write_log "ERROR" "Install with: sudo apt-get install jq (Ubuntu/Debian) or sudo yum install jq (RHEL/CentOS)"
    exit 1
fi
write_log "SUCCESS" "jq is installed"

# Verify authentication
write_log "INFO" "Verifying Azure authentication..."
if ! account_name=$(az account show --query "name" -o tsv 2>&1); then
    write_log "ERROR" "Not authenticated to Azure. Please run 'az login'"
    exit 1
fi
write_log "SUCCESS" "Authenticated to subscription: $account_name"

# Validate CSV file
write_log "INFO" "Validating CSV file: $CSV_FILE"
if ! validate_csv "$CSV_FILE"; then
    exit 1
fi

# Count VMs in CSV (excluding header and empty lines)
vm_count=$(grep -cv '^[[:space:]]*$\|^VMName' "$CSV_FILE" || true)
write_log "SUCCESS" "Successfully validated CSV with $vm_count VMs"

# Read CSV into array to avoid stdin issues
mapfile -t csv_lines < "$CSV_FILE"

# Process each VM
for line in "${csv_lines[@]}"; do
    # Skip header line
    if [[ "$line" == "VMName"* ]]; then
        continue
    fi
    
    # Skip empty lines
    if [ -z "$line" ]; then
        continue
    fi
    
    # Parse CSV line
    IFS=',' read -r vm_name resource_group vnet_resource_group vnet_name subnet_name new_nic_ip <<< "$line"
    
    # Trim whitespace
    vm_name=$(echo "$vm_name" | xargs)
    resource_group=$(echo "$resource_group" | xargs | tr -d '\r\n')
    vnet_resource_group=$(echo "$vnet_resource_group" | xargs | tr -d '\r\n')
    vnet_name=$(echo "$vnet_name" | xargs | tr -d '\r\n')
    subnet_name=$(echo "$subnet_name" | xargs | tr -d '\r\n')
    new_nic_ip=$(echo "$new_nic_ip" | xargs | tr -d '\r\n')
    
    # Skip if VM name is empty after trimming
    if [ -z "$vm_name" ]; then
        continue
    fi
    
    # Process VM
    if process_vm "$vm_name" "$resource_group" "$vnet_resource_group" "$vnet_name" "$subnet_name" "$new_nic_ip"; then
        ((SUCCESS_COUNT++))
    else
        ((FAILURE_COUNT++))
    fi
    
done

# Final summary
write_log "INFO" ""
write_log "INFO" "========================================"
write_log "INFO" "VM NIC Update Process Complete"
write_log "INFO" "========================================"
write_log "INFO" "Total VMs processed: $vm_count"
write_log "SUCCESS" "Successful: $SUCCESS_COUNT"
if [ $FAILURE_COUNT -gt 0 ]; then
    write_log "WARNING" "Failed: $FAILURE_COUNT"
else
    write_log "INFO" "Failed: $FAILURE_COUNT"
fi
write_log "INFO" "Log file: $LOG_FILE"

# Simple verification of processed VMs
if [ $SUCCESS_COUNT -gt 0 ]; then
    echo ""
    echo -e "\033[0;36m=== Post-Test Verification ===\033[0m"
    echo ""
    
    # Iterate over the csv_lines array already in memory
    for line in "${csv_lines[@]}"; do
        IFS=',' read -r vm_name resource_group vnet_resource_group vnet_name subnet_name new_nic_ip <<< "$line"
        
        # Clean variables
        vm_name=$(echo "$vm_name" | xargs | tr -d '\r\n')
        resource_group=$(echo "$resource_group" | xargs | tr -d '\r\n')
        new_nic_ip=$(echo "$new_nic_ip" | xargs | tr -d '\r\n')
        
        # Determine the new NIC name
        vm_info=$(az vm show --name "$vm_name" --resource-group "$resource_group" --query "{nics:networkProfile.networkInterfaces}" -o json 2>/dev/null)
        if [ -n "$vm_info" ]; then
            original_nic_id=$(echo "$vm_info" | jq -r '.nics[0].id // empty')
            if [ -n "$original_nic_id" ]; then
                original_nic_name="${original_nic_id##*/}"
                new_nic_name=""
                if [ "$original_nic_name" = "${vm_name}-nic-new" ]; then
                    new_nic_name="${vm_name}-nic-replacement"
                else
                    new_nic_name="${vm_name}-nic-new"
                fi
                
                echo -e "\033[0;33mVM: $vm_name (Expected IP: $new_nic_ip)\033[0m"
                
                # Get NIC details
                nic_info=$(az network nic show --name "$new_nic_name" --resource-group "$resource_group" \
                    --query "{Name:name, IP:ipConfigurations[0].privateIPAddress, Allocation:ipConfigurations[0].privateIPAllocationMethod}" \
                    -o json 2>/dev/null)
                
                if [ -n "$nic_info" ]; then
                    actual_ip=$(echo "$nic_info" | jq -r '.IP // empty')
                    allocation=$(echo "$nic_info" | jq -r '.Allocation // empty')
                    nic_name=$(echo "$nic_info" | jq -r '.Name // empty')
                    
                    if [ "$actual_ip" = "$new_nic_ip" ] && [ "$allocation" = "Static" ]; then
                        echo -e "  \033[0;32m✅ PASS - NIC: $nic_name | IP: $actual_ip | Allocation: $allocation\033[0m"
                    else
                        echo -e "  \033[0;31m❌ FAIL - NIC: $nic_name | IP: $actual_ip | Allocation: $allocation\033[0m"
                    fi
                    echo ""
                fi
            fi
        fi
    done
fi

if [ $FAILURE_COUNT -gt 0 ]; then
    exit 1
fi

exit 0
