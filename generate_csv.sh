# Show help message
if [ -z "$1" ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: $0 <resource-group-name> [output-file] [vm-filter]"
    echo ""
    echo "Arguments:"
    echo "  resource-group-name : Name of the Azure resource group (required)"
    echo "  output-file         : Output CSV file name (default: <resource-group>-vms.csv)"
    echo "                        NOTE: Required if using vm-filter"
    echo "  vm-filter           : Filter VMs by name pattern (e.g., 'test', 'prod', 'app')"
    echo ""
    echo "Examples:"
    echo "  $0 RG-EastUS                           # All VMs, default CSV name (RG-EastUS-vms.csv)"
    echo "  $0 RG-EastUS my-vms.csv                # All VMs, custom CSV name"
    echo "  $0 RG-EastUS my-vms.csv app            # Only VMs with 'app' in name"
    exit 1
fi

RESOURCE_GROUP="$1"
OUTPUT_FILE="${2:-${RESOURCE_GROUP}-vms.csv}"
VM_FILTER="${3:-}"


if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI is not installed or not in PATH"
    exit 1
fi


if ! az account show &> /dev/null; then
    echo "Error: Not logged into Azure. Please run 'az login' first"
    exit 1
fi


if ! az group show --name "$RESOURCE_GROUP" &> /dev/null; then
    echo "Error: Resource group '$RESOURCE_GROUP' not found"
    exit 1
fi

echo "Querying VMs in resource group: $RESOURCE_GROUP"
if [ -n "$VM_FILTER" ]; then
    echo "Filtering for VMs with '$VM_FILTER' in the name..."
else
    echo "Processing all VMs in the resource group..."
fi


echo "VMName,ResourceGroup,VNetResourceGroup,VNetName,SubnetName,NewNicIPAddress" > "$OUTPUT_FILE"

# Get all VMs in the resource group and optionally filter with grep
if [ -n "$VM_FILTER" ]; then
    vms=$(az vm list --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv | grep -iE "$VM_FILTER" || true)
else
    vms=$(az vm list --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv)
fi

if [ -z "$vms" ]; then
    if [ -n "$VM_FILTER" ]; then
        echo "No VMs found with '$VM_FILTER' in the name"
    else
        echo "No VMs found in resource group: $RESOURCE_GROUP"
    fi
    echo "CSV file created with headers only: $OUTPUT_FILE"
    exit 0
fi


vm_count=0
missing_secondary_ip=0
while IFS= read -r vm_name; do
    # Remove any carriage returns from VM name (Windows line ending issue)
    vm_name=$(echo "$vm_name" | tr -d '\r')
    
    echo "Processing VM: $vm_name"
    
    nic_id=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$vm_name" \
        --query "networkProfile.networkInterfaces[0].id" -o tsv </dev/null)
    
    if [ -z "$nic_id" ]; then
        echo "  ❌ ERROR: No NIC found for VM $vm_name"
        echo ""
        echo "CRITICAL ERROR: Unable to retrieve NIC information for VM: $vm_name"
        echo "Script cannot continue. Please check the VM configuration."
        rm -f "$OUTPUT_FILE"
        exit 1
    fi
    
    nic_details=$(az network nic show --ids "$nic_id" \
        --query "{subnet: ipConfigurations[0].subnet.id, primaryIp: ipConfigurations[0].privateIPAddress, secondaryIp: ipConfigurations[1].privateIPAddress}" -o json </dev/null)
    

    subnet_id=$(echo "$nic_details" | jq -r '.subnet // empty')
    primary_ip=$(echo "$nic_details" | jq -r '.primaryIp // empty')
    secondary_ip=$(echo "$nic_details" | jq -r '.secondaryIp // empty')
    
    if [ -z "$subnet_id" ]; then
        echo "  ❌ ERROR: No subnet found for VM $vm_name"
        echo ""
        echo "CRITICAL ERROR: Unable to retrieve subnet information for VM: $vm_name"
        echo "Script cannot continue. Please check the VM's network configuration."
        rm -f "$OUTPUT_FILE"
        exit 1
    fi
    
    # Check for secondary IP - REQUIRED for NIC swap
    if [ -z "$secondary_ip" ]; then
        echo "  ❌ ERROR: No secondary IP found for VM $vm_name (Primary IP: $primary_ip)"
        ((missing_secondary_ip++))
    else
        echo "  ✅ Primary IP: $primary_ip, Secondary IP: $secondary_ip"
    fi
    
    vnet_resource_group=$(echo "$subnet_id" | cut -d'/' -f5)
    vnet_name=$(echo "$subnet_id" | cut -d'/' -f9)
    subnet_name=$(echo "$subnet_id" | cut -d'/' -f11)
    

    echo "$vm_name,$RESOURCE_GROUP,$vnet_resource_group,$vnet_name,$subnet_name,$secondary_ip" >> "$OUTPUT_FILE"
    ((vm_count++))
    
done <<< "$vms"

echo ""

# Check if any VMs are missing secondary IPs
if [ $missing_secondary_ip -gt 0 ]; then
    echo "❌ CRITICAL ERROR: $missing_secondary_ip VM(s) are missing secondary IP addresses"
    echo ""
    echo "Secondary IP addresses are REQUIRED for the NIC swap process."
    echo "Please add secondary IPs to all VMs before running the NIC swap script."
    echo ""
    echo "To add a secondary IP to a VM's NIC, use:"
    echo "  az network nic ip-config create --resource-group <rg> --nic-name <nic-name> \\"
    echo "    --name ipconfig2 --private-ip-address <new-ip>"
    echo ""
    rm -f "$OUTPUT_FILE"
    echo "⚠️  CSV file was NOT created due to validation errors."
    echo ""
    exit 1
fi

echo "✅ Successfully processed $vm_count VM(s) - All VMs have secondary IPs"
echo "CSV file generated: $OUTPUT_FILE"
echo ""
echo "You can now use this CSV file with the NIC swap scripts:"
echo "  PowerShell: .\\Update-VMNics.ps1 -CsvPath $OUTPUT_FILE"
echo "  Bash:       bash ./update-vm-nics.sh $OUTPUT_FILE"
 