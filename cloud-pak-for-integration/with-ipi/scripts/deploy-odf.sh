#
# Script to deploy OpenShift Data Foundation onto ARO
# To be run in an Azure deployment script container, with az CLI installed
# The az cli is used to retrieve values from the supplied key vault
#
# Written by:  Rich Ehrhardt
# Email: rich_ehrhardt@au1.ibm.com

OUTPUT_FILE="cp4i-script-output-$(date -u +'%Y-%m-%d-%H%M%S').log"
source common.sh

######
# Set defaults
if [[ -z $CLIENT_ID ]]; then CLIENT_ID=""; fi
if [[ -z $CLIENT_SECRET ]]; then CLIENT_SECRET=""; fi
if [[ -z $TENANT_ID ]]; then TENANT_ID=""; fi
if [[ -z $SUBSCRIPTION_ID ]]; then SUBSCRIPTION_ID=""; fi
if [[ -z $WORKSPACE_DIR ]]; then export WORKSPACE_DIR="/workspace"; fi
if [[ -z $BIN_DIR ]]; then export BIN_DIR="/usr/local/bin"; fi
if [[ -z $TMP_DIR ]]; then export TMP_DIR="${WORKSPACE_DIR}/tmp"; fi
if [[ -z $NEW_CLUSTER ]]; then NEW_CLUSTER="no"; fi
if [[ -z $STORAGE_SIZE ]]; then export STORAGE_SIZE="2Ti"; fi
if [[ -z $EXISTING_NODES ]]; then EXISTING_NODES="no"; fi
if [[ -z $OCP_USERNAME ]]; then OCP_USERNAME="kubeadmin"; fi

######
# Create working directories
mkdir -p ${WORKSPACE_DIR}
mkdir -p ${TMP_DIR}

#######
# Login to Azure CLI
az account show > /dev/null 2>&1
if (( $? != 0 )); then
    # Login with service principal details
    az login --identity

    if (( $? != 0 )); then
      log-error "Unable to login with the assigned managed identity"
      exit 1
    else
      log-info "Successfully logged in with the assigned managed identity"
    fi
else
    log-info "Using existing Azure CLI login"
fi

######
# Check environment variables
ENV_VAR_NOT_SET=""

if [[ -z $API_SERVER ]]; then ENV_VAR_NOT_SET="API_SERVER"; fi
if [[ -z $CLUSTER_LOCATION ]]; then ENV_VAR_NOT_SET="CLUSTER_LOCATION"; fi
if [[ -z $VAULT_NAME ]]; then 
  if [[ -z $OCP_PASSWORD ]]; then ENV_VAR_NOT_SET="OCP_PASSWORD"; fi
elif [[ -z $SECRET_NAME ]]; then
  ENV_VAR_NOT_SET="SECRET_NAME"
else
  log-info "Will use $VAULT_NAME to retrieve secrets"
fi

if [[ -n $ENV_VAR_NOT_SET ]]; then
    log-error "$ENV_VAR_NOT_SET not set. Please set and retry."
    exit 1
fi


########
# Get the cluster credentials from the key vault if necessary
if [[ -z $OCP_PASSWORD ]] && [[ $VAULT_NAME ]]; then
  OCP_PASSWORD=$(az keyvault secret show -n "$SECRET_NAME" --vault-name $VAULT_NAME --query 'value' -o tsv)
  if (( #? != 0 )); then
    log-error "Unable to retrieve secret $SECRET_NAME from $VAULT_NAME"
    exit 1
  else
    log-info "Successfully retrieved cluster password from $SECRET_NAME in $VAULT_NAME"
  fi
fi

#######
# Download and install CLI's if they do not already exist
if [[ ! -f ${BIN_DIR}/oc ]] || [[ ! -f ${BIN_DIR}/kubectl ]]; then
    cli-download $BIN_DIR $TMP_DIR
fi

#####
# Wait for cluster operators to be available
wait_for_cluster_operators $API_SERVER $OCP_USERNAME $OCP_PASSWORD $BIN_DIR

#######
# Login to cluster
oc-login $API_SERVER $OCP_USERNAME $OCP_PASSWORD $BIN_DIR

##### 
# Obtain cluster id, version and other details
log-info "Obtaining information on cluster"
export CLUSTER_ID=$(${BIN_DIR}/oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)
log-info "CLUSTER_ID = $CLUSTER_ID"

export OCP_VERSION=$(${BIN_DIR}/oc version -o json | jq -r '.openshiftVersion' | awk '{split($0,version,"."); print version[1],version[2]}' | sed 's/ /./g')
log-info "OCP_VERSION = $OCP_VERSION"

export IMAGE_RESOURCE_ID=$(${BIN_DIR}/oc get machineset/${CLUSTER_ID}-worker-${CLUSTER_LOCATION}1 -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.image.resourceID}{"\n"}')
log-info "IMAGE_RESOURCE_ID = $IMAGE_RESOURCE_ID"

export OCP_RESOURCE_GROUP=$(${BIN_DIR}/oc get machineset/${CLUSTER_ID}-worker-${CLUSTER_LOCATION}1 -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.resourceGroup}{"\n"}')
log-info "OCP_RESOURCE_GROUP = $OCP_RESOURCE_GROUP"

export VNET_NAME=$(${BIN_DIR}/oc get machineset/${CLUSTER_ID}-worker-${CLUSTER_LOCATION}1 -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.vnet}{"\n"}')
log-info "VNET_NAME = $VNET_NAME"

export SUBNET_NAME=$(${BIN_DIR}/oc get machineset/${CLUSTER_ID}-worker-${CLUSTER_LOCATION}1 -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.subnet}{"\n"}')
log-info "SUBNET_NAME = $SUBNET_NAME"



######
# Create the openshift storage namespace
if [[ -z $(${BIN_DIR}/oc get namespace | grep "openshift-storage") ]]; then
    log-info "Creating namespace openshift-storage"
    cat << EOF | oc apply -f - 
apiVersion: v1
kind: Namespace
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: "openshift-storage"
spec: {}
EOF

    if (( $? != 0 )); then
      log-error "Unable to create namespace openshift-storage"
      exit 1
    else
      log-info "Successfully created namespace openshift-storage"
    fi
else
    log-info "Using existing openshift-storage namespace"
fi

#####
# Create ODF operator group
if [[ -z $(${BIN_DIR}/oc get operatorgroup -n openshift-storage | grep openshift-storage-operatorgroup) ]]; then
    log-info "Creating operator group openshift-storage-operatorgroup under namespace openshift-storage"
    cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
    name: openshift-storage-operatorgroup
    namespace: openshift-storage
spec:
    targetNamespaces:
    - openshift-storage
EOF

    if (( $? != 0 )); then
      log-error "Unable to create openshift storage operator group"
      exit 1
    else
      log-info "Successfully created openshift storage operator group"
    fi
else
    log-info "Using existing operator group"
fi

#####
# Create ODF subscription
if [[ -z $(${BIN_DIR}/oc get subscription -n openshift-storage | grep odf-operator) ]]; then
    log-info "Creating subscription for odf-operator"
    cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
    name: odf-operator
    namespace: openshift-storage
spec:
    channel: "stable-${OCP_VERSION}"
    installPlanApproval: Automatic
    name: odf-operator
    source: redhat-operators
    sourceNamespace: openshift-marketplace
EOF

    if (( $? != 0 )); then
      log-error "Unable to create subscription for odf-operator"
      exit 1
    else
      log-info "Successfully created subscription for odf-operator"
    fi
else
    log-info "Using existing odf-operator subscription"
fi

wait_for_subscription openshift-storage odf-operator

####
# Patch the console to add the ODF console
if [[ -z $(${BIN_DIR}/oc get console.operator cluster -n openshift-storage -o json | grep odf-console) ]]; then
    log-info "Patching openshift console to add ODF console"
    ${BIN_DIR}/oc patch console.operator cluster -n openshift-storage --type json -p '[{"op": "add", "path": "/spec/plugins", "value": ["odf-console"]}]'

    if (( $? != 0 )); then
      log-error "Unable to patch openshift console for ODF console"
      exit 1
    else
      log-info "Successfully patched openshift console for ODF console"
    fi
else
    log-info "Openshift console already patched for ODF console"
fi

if [[ $EXISTING_NODES == "no" ]]; then
  log-info "Creating new machinesets for ODF storage cluster"

  ####
  # Generate new machineset for ODF storage cluster - zone 1
  if [[ -z $(${BIN_DIR}/oc get machineset -n openshift-machine-api ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}1) ]]; then
      log-info "Creating machineset for zone 1 for ODF storage cluster"
      cat << EOF | oc apply -f -
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  labels:
    machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
    machine.openshift.io/cluster-api-machine-role: worker
    machine.openshift.io/cluster-api-machine-type: worker
  name: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}1
  namespace: openshift-machine-api
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
      machine.openshift.io/cluster-api-machineset: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}1
  template:
    metadata:
      creationTimestamp: null
      labels:
        machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}1
    spec:
      metadata:
        creationTimestamp: null
        labels:
          cluster.ocs.openshift.io/openshift-storage: ""
      providerSpec:
        value:
          apiVersion: azureproviderconfig.openshift.io/v1beta1
          credentialsSecret:
            name: azure-cloud-credentials
            namespace: openshift-machine-api
          image:
            offer: ''
            publisher: ''
            resourceID: '${IMAGE_RESOURCE_ID}'
            sku: ''
            version: ''
          internalLoadBalancer: ""
          kind: AzureMachineProviderSpec
          location: ${CLUSTER_LOCATION}
          metadata:
            creationTimestamp: null
          natRule: null
          networkResourceGroup: ${RESOURCE_GROUP}
          osDisk:
            diskSizeGB: 128
            managedDisk:
              storageAccountType: Premium_LRS
            osType: Linux
          publicIP: false
          publicLoadBalancer: ${CLUSTER_ID}
          resourceGroup: ${OCP_RESOURCE_GROUP} 
          sshPrivateKey: ""
          sshPublicKey: ""
          subnet: ${SUBNET_NAME}  
          userDataSecret:
            name: worker-user-data 
          vmSize: Standard_D16s_v3
          vnet: ${VNET_NAME}
          zone: "1" 
EOF

      if (( $? != 0 )); then
        log-error "Unable to create machineset for zone 1 for ODF storage cluster"
        exit 1
      else
        log-info "Successfully created machineset for zone 1 for ODF storage cluster"
      fi
  else
      log-info "Using existing machinesets for zone 1 for ODF storage cluster"
  fi

  ####
  # Generate new machineset for ODF storage cluster - zone 2
  if [[ -z $(${BIN_DIR}/oc get machineset -n openshift-machine-api ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}2) ]]; then
      log-info "Creating machineset for zone 2 for ODF storage cluster"
      cat << EOF | oc apply -f -
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  labels:
    machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
    machine.openshift.io/cluster-api-machine-role: worker
    machine.openshift.io/cluster-api-machine-type: worker
  name: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}2
  namespace: openshift-machine-api
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
      machine.openshift.io/cluster-api-machineset: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}2
  template:
    metadata:
      creationTimestamp: null
      labels:
        machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}2
    spec:
      metadata:
        creationTimestamp: null
        labels:
          cluster.ocs.openshift.io/openshift-storage: ""
      providerSpec:
        value:
          apiVersion: azureproviderconfig.openshift.io/v1beta1
          credentialsSecret:
            name: azure-cloud-credentials
            namespace: openshift-machine-api
          image:
            offer: ''
            publisher: ''
            resourceID: '${IMAGE_RESOURCE_ID}'
            sku: ''
            version: ''
          internalLoadBalancer: ""
          kind: AzureMachineProviderSpec
          location: ${CLUSTER_LOCATION}
          metadata:
            creationTimestamp: null
          natRule: null
          networkResourceGroup: ${RESOURCE_GROUP}
          osDisk:
            diskSizeGB: 128
            managedDisk:
              storageAccountType: Premium_LRS
            osType: Linux
          publicIP: false
          publicLoadBalancer: ${CLUSTER_ID}
          resourceGroup: ${OCP_RESOURCE_GROUP} 
          sshPrivateKey: ""
          sshPublicKey: ""
          subnet: ${SUBNET_NAME}  
          userDataSecret:
            name: worker-user-data 
          vmSize: Standard_D16s_v3
          vnet: ${VNET_NAME}
          zone: "2" 
EOF

      if (( $? != 0 )); then
        log-error "Unable to create machineset for zone 2 for ODF storage cluster"
        exit 1
      else
        log-info "Successfully created machineset for zone 2 for ODF storage cluster"
      fi
  else
      log-info "Using existing machinesets for zone 2 for ODF storage cluster"
  fi

  ####
  # Generate new machineset for ODF storage cluster - zone 3
  if [[ -z $(${BIN_DIR}/oc get machineset -n openshift-machine-api ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}3) ]]; then
      log-info "Creating machineset for zone 3 for ODF storage cluster"
      cat << EOF | oc apply -f -
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  labels:
    machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
    machine.openshift.io/cluster-api-machine-role: worker
    machine.openshift.io/cluster-api-machine-type: worker
  name: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}3
  namespace: openshift-machine-api
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
      machine.openshift.io/cluster-api-machineset: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}3
  template:
    metadata:
      creationTimestamp: null
      labels:
        machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}3
    spec:
      metadata:
        creationTimestamp: null
        labels:
          cluster.ocs.openshift.io/openshift-storage: ""
      providerSpec:
        value:
          apiVersion: azureproviderconfig.openshift.io/v1beta1
          credentialsSecret:
            name: azure-cloud-credentials
            namespace: openshift-machine-api
          image:
            offer: ''
            publisher: ''
            resourceID: '${IMAGE_RESOURCE_ID}'
            sku: ''
            version: ''
          internalLoadBalancer: ""
          kind: AzureMachineProviderSpec
          location: ${CLUSTER_LOCATION}
          metadata:
            creationTimestamp: null
          natRule: null
          networkResourceGroup: ${RESOURCE_GROUP}
          osDisk:
            diskSizeGB: 128
            managedDisk:
              storageAccountType: Premium_LRS
            osType: Linux
          publicIP: false
          publicLoadBalancer: ${CLUSTER_ID}
          resourceGroup: ${OCP_RESOURCE_GROUP} 
          sshPrivateKey: ""
          sshPublicKey: ""
          subnet: ${SUBNET_NAME}  
          userDataSecret:
            name: worker-user-data 
          vmSize: Standard_D16s_v3
          vnet: ${VNET_NAME}
          zone: "3" 
EOF

      if (( $? != 0 )); then
        log-error "Unable to create machineset for zone 3 for ODF storage cluster"
        exit 1
      else
        log-info "Successfully created machineset for zone 3 for ODF storage cluster"
      fi
  else
      log-info "Using existing machinesets for zone 3 for ODF storage cluster"
  fi

  #####
  # Wait for machines to provision
  count=0
  while [[ $(${BIN_DIR}/oc get machinesets -n openshift-machine-api ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}1 -o jsonpath='{.status.availableReplicas}{"\n"}') != "1" ]] \
      || [[ $(${BIN_DIR}/oc get machinesets -n openshift-machine-api ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}2 -o jsonpath='{.status.availableReplicas}{"\n"}') != "1" ]] \
      || [[ $(${BIN_DIR}/oc get machinesets -n openshift-machine-api ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}3 -o jsonpath='{.status.availableReplicas}{"\n"}') != "1" ]]; do
      log-info "Waiting for machinesets to become available. Waiting $count minutes. Will wait up to 30 minutes."
      sleep 60
      count=$(( $count + 1 ))
      if (( $count > 30 )); then
          log-error "Timeout waiting for cluster operators to be available"
          exit 1;    
      fi
  done

else
  log-info "Labelling existing worker nodes for use with ODF storage cluster"

  # Get list of worker nodes
  log-info "Getting list of worker nodes"
  NODES=( $(oc get nodes | grep worker | awk '{print $1}') )

  # Confirm that there are 3 nodes available
  if (( $(echo ${#NODES[@]}) < 3  )); then
    log-error "Insufficient nodes for storage cluster. Must have at least 3 nodes available"
    exit 1
  fi

  # Get the size and zone of each node in array
  log-info "Getting node details"
  for node in ${NODES[@]}; do
    cpu=$(${BIN_DIR}/oc get node $node -o json | jq -r '.status.capacity.cpu')
    mem=$(${BIN_DIR}/oc get node $node -o json | jq -r '.status.capacity.memory')
    zone=$(${BIN_DIR}/oc get machine -n openshift-machine-api | grep $node | awk '{print $5}')
    if (( $cpu > 15 )); then
      if [[ -z $(${BIN_DIR}/oc get node ${ODF_NODES_ZONE1[1]//\"/} -o json | jq '.metadata.labels' | grep "cluster.ocs.openshift.io") ]]; then
        labelled="false"
      else
        labelled="true"
      fi
      jq -n \
        --arg name "$node" \
        --arg cpu $cpu \
        --arg mem $mem \
        --arg zone $zone \
        --arg labelled $labelled \
        '{name: $name, cpu: $cpu, mem: $mem, zone: $zone, labelled: $labelled}'
    fi
  done | jq -n '.nodes |= [inputs]' > ${WORKSPACE_DIR}/node-details.json

  NODE_DETAIL="$(cat ${WORKSPACE_DIR}/node-details.json)"

  # Check enough nodes of 16 CPU or higher available
  log-info "Checking size of nodes"
  if (( $( echo $NODE_DETAIL | jq '.nodes | length' ) < 3  )); then
    log-error "Insufficient nodes of sufficient size available for storage cluster"
    log-error "Minimum of 3 nodes with 16 CPU or more required"
    exit 1
  fi

  # Choose 1 node from each availability zone


  ZONE1_LABELLED_NODES=( $(echo $NODE_DETAIL| jq '.nodes[] | select(.zone == "1") | select(.labelled == "true") | .name' ) )
  if (( ${#ZONE1_LABELLED_NODES[@]} > 0 )); then    
    for node in ${ZONE1_LABELLED_NODES[@]}; do
      log-info "Using existing labelled node $node"
    done
  else
    log-info "Checking sufficiently sized node available availability zone 1"
    ODF_NODES_ZONE1=( $(echo $NODE_DETAIL | jq '.nodes[] | select(.zone == "1") | .name') )
    if (( ${#ODF_NODES_ZONE1[@]} < 1 )); then
      log-error "Insufficient nodes in availability zone 1 of sufficient size for storage cluster"
      exit 1
    else
      log-info "${ODF_NODES_ZONE1[0]} is of sufficient size in availability zone 1 and will be labelled for ODF"
      log-info "Labelling ${ODF_NODES_ZONE1[0]//\"/} as ODF node for availability zone 1"
      ${BIN_DIR}/oc label node ${ODF_NODES_ZONE1[0]//\"/} cluster.ocs.openshift.io/openshift-storage=''

      if (( $? != 0 )); then
        log-error "Unable to label ${ODF_NODES_ZONE1[0]//\"/} as ODF node for availability zone 1"
        exit 1
      else
        log-info "Successfully labelled ${ODF_NODES_ZONE1[0]//\"/} as ODF node for availability zone 1"
      fi
    fi
  fi

  ZONE2_LABELLED_NODES=( $(echo $NODE_DETAIL| jq '.nodes[] | select(.zone == "2") | select(.labelled == "true") | .name' ) )
  if (( ${#ZONE2_LABELLED_NODES[@]} > 0 )); then    
    for node in ${ZONE2_LABELLED_NODES[@]}; do
      log-info "Using existing labelled node $node"
    done
  else
    ODF_NODES_ZONE2=( $(echo $NODE_DETAIL | jq '.nodes[] | select(.zone == "2") | .name') )
    if (( ${#ODF_NODES_ZONE2[@]} < 1 )); then
      log-error "Insufficient nodes in availability zone 2 of sufficient size for storage cluster"
      exit 1
    else
      log-info "${ODF_NODES_ZONE2[0]//\"/} is of sufficient size in availability zone 2 and will be labelled for ODF"
      log-info "Labelling ${ODF_NODES_ZONE2[0]//\"/} as ODF node for availability zone 2"
      ${BIN_DIR}/oc label node ${ODF_NODES_ZONE2[0]//\"/} cluster.ocs.openshift.io/openshift-storage=''

      if (( $? != 0 )); then
        log-error "Unable to label ${ODF_NODES_ZONE1[0]//\"/} as ODF node for availability zone 2"
        exit 1
      else
        log-info "Successfully labelled ${ODF_NODES_ZONE1[0]//\"/} as ODF node for availability zone 2"
      fi
    fi
  fi

  ZONE2_LABELLED_NODES=( $(echo $NODE_DETAIL| jq '.nodes[] | select(.zone == "2") | select(.labelled == "true") | .name' ) )
  if (( ${#ZONE2_LABELLED_NODES[@]} > 0 )); then    
    for node in ${ZONE2_LABELLED_NODES[@]}; do
      log-info "Using existing labelled node $node"
    done
  else
    ODF_NODES_ZONE3=( $(echo $NODE_DETAIL | jq '.nodes[] | select(.zone == "3") | .name') )
    if (( ${#ODF_NODES_ZONE2[@]} < 1 )); then
      log-error "Insufficient nodes in availability zone 3 of sufficient size for storage cluster"
      exit 1
    else
      log-info "${ODF_NODES_ZONE2[0]//\"/} is of sufficient size in availability zone 3 and will be labelled for ODF"
      log-info "Labelling ${ODF_NODES_ZONE3[0]//\"/} as ODF node for availability zone 3"
      ${BIN_DIR}/oc label node ${ODF_NODES_ZONE3[0]//\"/} cluster.ocs.openshift.io/openshift-storage=''

      if (( $? != 0 )); then
        log-error "Unable to label ${ODF_NODES_ZONE1[0]//\"/} as ODF node for availability zone 3"
        exit 1
      else
        log-info "Successfully labelled ${ODF_NODES_ZONE1[0]//\"/} as ODF node for availability zone 3"
      fi
    fi
  fi

fi


#####
# Create the storage cluster
if [[ -z $(${BIN_DIR}/oc get storagecluster -n openshift-storage ocs-storagecluster) ]]; then
    log-info "Creating storage cluster ocs-storagecluster"
    SC_NAME=$(${BIN_DIR}/oc get sc | grep disk.csi.azure.com | awk '{print$1}')
    cat << EOF | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  arbiter: {}
  encryption:
    kms: {}
  externalStorage: {}
  flexibleScaling: true
  resources:
    mds:
      limits:
        cpu: "3"
        memory: "8Gi"
      requests:
        cpu: "3"
        memory: "8Gi"
  monDataDirHostPath: /var/lib/rook
  managedResources:
    cephBlockPools:
      reconcileStrategy: manage   
    cephConfig: {}
    cephFilesystems: {}
    cephObjectStoreUsers: {}
    cephObjectStores: {}
  multiCloudGateway:
    reconcileStrategy: manage   
  storageDeviceSets:
  - count: 1  
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: "${STORAGE_SIZE}"
        storageClassName: ${SC_NAME}
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: false
    replica: 3
    resources:
      limits:
        cpu: "2"
        memory: "5Gi"
      requests:
        cpu: "2"
        memory: "5Gi"
EOF
    if (( $? != 0 )); then
      log-error "Unable to create storage cluster"
      exit 1
    else
      log-info "Successfully created storage cluster"
    fi
else
    log-info "Using existing storage cluster"
fi

######
# Wait for storage cluster to become available
count=0
while [[ $(${BIN_DIR}/oc get StorageCluster ocs-storagecluster -n openshift-storage --no-headers -o custom-columns='phase:status.phase') != "Ready" ]]; do
    log-info "Waiting for storage cluster to become available. Waited $count minutes. Will wait up to 30 minutes"
    sleep 60
    count=$(( $count + 1 ))
    if (( $count > 30 )); then
        log-error "Timeout waiting for cluster operators to be available"
        exit 1;    
    fi
done
log-info "ODF successfully installed on cluster $CLUSTER_ID at $API_SERVER"