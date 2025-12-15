#!/bin/bash

# Script to enable/disable accelerated networking on VMs based on a CSV file
# CSV Format: VMName,ResourceGroup,EnableAcceleratedNetworking
# Example: testvm1,RG-EastUS,true

if [ -z "$1" ]; then
    echo "Error: CSV file is required"
    echo "Usage: $0 <csv-file>"
    echo ""
    echo "CSV Format:"
    echo "  VMName,ResourceGroup,EnableAcceleratedNetworking"
    echo ""
    echo "Example CSV content:"
    echo "  testvm1,RG-EastUS,true"
    echo "  testvm2,RG-EastUS,false"
    echo "  testvm3,RG-EastUS,true"
    exit 1
fi

CSV_FILE="$1"

if [ ! -f "$CSV_FILE" ]; then
    echo "Error: CSV file '$CSV_FILE' not found"
    exit 1
fi

# Check for required tools
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI is not installed or not in PATH"
    exit 1
fi

# Check Azure login
if ! az account show &> /dev/null; then
    echo "Error: Not logged into Azure. Please run 'az login' first"
    exit 1
fi

echo "Starting accelerated networking configuration..."
echo "Reading from: $CSV_FILE"
echo ""

# Skip header line and process each VM
success_count=0
error_count=0
skipped_count=0
line_number=0

while IFS=',' read -r vm_name resource_group enable_an || [ -n "$vm_name" ]; do
    ((line_number++))
    
    # Skip header line
    if [ $line_number -eq 1 ]; then
        continue
    fi
    # Remove any carriage returns
    vm_name=$(echo "$vm_name" | tr -d '\r' | xargs)
    resource_group=$(echo "$resource_group" | tr -d '\r' | xargs)
    enable_an=$(echo "$enable_an" | tr -d '\r' | xargs)
    
    # Skip empty lines
    if [ -z "$vm_name" ]; then
        continue
    fi
    
    echo "Processing VM: $vm_name"
    
    # Validate enable_an value
    if [ "$enable_an" != "true" ] && [ "$enable_an" != "false" ]; then
        echo "  ⚠️  WARNING: Invalid value for EnableAcceleratedNetworking: '$enable_an' (must be 'true' or 'false')"
        echo "  Skipping VM: $vm_name"
        echo ""
        ((skipped_count++))
        continue
    fi
    
    # Get the NIC ID for the VM
    echo "  Getting NIC information..."
    nic_id=$(az vm show --name "$vm_name" --resource-group "$resource_group" \
        --query "networkProfile.networkInterfaces[0].id" -o tsv 2>/dev/null </dev/null)
    
    if [ -z "$nic_id" ]; then
        echo "  ❌ ERROR: Could not find VM '$vm_name' in resource group '$resource_group'"
        echo ""
        ((error_count++))
        continue
    fi
    
    # Extract NIC name from ID
    nic_name=$(basename "$nic_id")
    
    # Get current accelerated networking status
    current_an=$(az network nic show --ids "$nic_id" \
        --query "enableAcceleratedNetworking" -o tsv 2>/dev/null </dev/null | tr -d '\r' | xargs)
    
    echo "  Current accelerated networking: $current_an"
    echo "  Target accelerated networking: $enable_an"
    
    # Check if change is needed
    if [ "$current_an" = "$enable_an" ]; then
        echo "  ℹ️  No change needed - already set to $enable_an"
        echo ""
        ((skipped_count++))
        continue
    fi
    
    # Update accelerated networking
    echo "  Updating accelerated networking to $enable_an..."
    if az network nic update --ids "$nic_id" --accelerated-networking "$enable_an" </dev/null > /dev/null 2>&1; then
        if [ "$enable_an" == "true" ]; then
            echo "  ✅ Successfully enabled accelerated networking on $nic_name"
        else
            echo "  ✅ Successfully disabled accelerated networking on $nic_name"
        fi
        ((success_count++))
    else
        echo "  ❌ ERROR: Failed to update accelerated networking on $nic_name"
        ((error_count++))
    fi
    
    echo ""
done < "$CSV_FILE"

echo "================================================"
echo "Summary:"
echo "  ✅ Successfully updated: $success_count VM(s)"
echo "  ⚠️  Skipped (no change needed or invalid value): $skipped_count VM(s)"
echo "  ❌ Failed: $error_count VM(s)"
echo "================================================"

if [ $error_count -gt 0 ]; then
    exit 1
fi

exit 0
