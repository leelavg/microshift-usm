#!/bin/bash
# MicroShift Cluster Manager
# Basic functions for managing MicroShift clusters

set -euo pipefail

# Configuration - These variables can be overridden by the environment
# They are used throughout the script for single-node and multi-node cluster management
USHIFT_MULTINODE_CLUSTER="${USHIFT_MULTINODE_CLUSTER:-microshift-okd-multinode}"
NODE_BASE_NAME="${NODE_BASE_NAME:-microshift-okd-}"
USHIFT_IMAGE="${USHIFT_IMAGE:-microshift-okd}"
LVM_DISK="${LVM_DISK:-/var/lib/microshift-okd/lvmdisk.image}"
LVM_VOLSIZE="${LVM_VOLSIZE:-1G}"
VG_NAME="${VG_NAME:-myvg1}"
ISOLATED_NETWORK="${ISOLATED_NETWORK:-0}"
WORKER_ONLY="${WORKER_ONLY:-0}"
ENABLE_HA="${ENABLE_HA:-0}"
CONTAINER_CACHE_DIR="${CONTAINER_CACHE_DIR:-/var/lib/containers}"
CREATE_TOPOLVM_BACKEND="${CREATE_TOPOLVM_BACKEND:-0}"
PULL_SECRET="${PULL_SECRET:-}"
REGISTRIES_CONF="${REGISTRIES_CONF:-}"

_is_cluster_created() {
    if sudo podman container exists "${NODE_BASE_NAME}1"; then
        return 0
    fi
    return 1
}

_is_container_created() {
    local -r name="${1}"
    if sudo podman container exists "${name}"; then
        return 0
    fi
    return 1
}

create_topolvm_backend() {
    if [ -f "${LVM_DISK}" ]; then
        echo "INFO: '${LVM_DISK}' exists, reusing"
        return 0
    fi

    sudo mkdir -p "$(dirname "${LVM_DISK}")"
    sudo truncate --size="${LVM_VOLSIZE}" "${LVM_DISK}"
    local -r device_name="$(sudo losetup --find --show --nooverlap "${LVM_DISK}")"
    sudo vgcreate -f -y "${VG_NAME}" "${device_name}"
}

# Delete TopoLVM backend
delete_topolvm_backend() {
    if [ -f "${LVM_DISK}" ]; then
        echo "Deleting TopoLVM backend: ${LVM_DISK}"
        sudo lvremove -y "${VG_NAME}" || true
        sudo vgremove -y "${VG_NAME}" || true
        local -r device_name="$(sudo losetup -j "${LVM_DISK}" | cut -d: -f1)"
        [ -n "${device_name}" ] && sudo losetup -d "${device_name}" || true
        sudo rm -rf "$(dirname "${LVM_DISK}")"
    fi
}

_create_podman_network() {
    local -r name="${1}"
    if ! sudo podman network exists "${name}"; then
        echo "Creating podman network: ${name}"
        sudo podman network create "${name}"
    else
        echo "Podman network '${name}' already exists"
    fi
}

_get_subnet() {
    local -r network_name="${1}"
    local -r subnet_with_mask=$(sudo podman network inspect "${network_name}" --format '{{range .}}{{range .Subnets}}{{.Subnet}}{{end}}{{end}}')
    if [ -z "$subnet_with_mask" ]; then
        echo "ERROR: Could not determine subnet for network '${network_name}'." >&2
        exit 1
    fi
    local -r subnet="${subnet_with_mask%%/*}"
    echo "$subnet"
}

_get_ip_address() {
    local -r subnet="${1}"
    local -r node_id="${2}"
    echo "$subnet" | awk -F. -v new="$node_id" 'NF==4{$4=new+10; printf "%s.%s.%s.%s", $1,$2,$3,$4} NF!=4{print $0}'
}

# Notes:
# - The container joins the cluster network and gets the cluster network IP
#   address when the ISOLATED_NETWORK environment variable is set to 0.
# - The /dev directory is shared with the container to enable TopoLVM CSI driver,
#   masking the devices that may conflict with the host
# - The containers storage is mounted on a shared host volume for image caching
#   to speed up cluster creation by sharing pulled images across all nodes
_add_node() {
    local -r name="${1}"
    local -r network_name="${2}"
    local -r ip_address="${3}"
    local -r is_bootstrap="${4:-0}"  # New parameter: 1 for bootstrap, 0 for joining nodes

    # Create shared cache directory
    sudo mkdir -p "${CONTAINER_CACHE_DIR}"

    local vol_opts="--tty --volume /dev:/dev"
    for device in input snd dri; do
        [ -d "/dev/${device}" ] && vol_opts="${vol_opts} --tmpfs /dev/${device}"
    done

    local network_opts="--network ${network_name}"
    if [ "${ISOLATED_NETWORK}" = "0" ]; then
        network_opts="${network_opts} --ip ${ip_address}"
    fi

    local pull_secret=""
    if  [ -n "${PULL_SECRET}" ] && [ -f "${PULL_SECRET}" ]; then
        pull_secret="--volume ${PULL_SECRET}:/etc/crio/openshift-pull-secret:ro"
    fi

    local registries_opts=""
    if [ -n "${REGISTRIES_CONF}" ] && [ -f "${REGISTRIES_CONF}" ]; then
        registries_opts="--volume ${REGISTRIES_CONF}:/etc/containers/registries.conf.d/99-mirrors.conf:ro"
    fi

    # shellcheck disable=SC2086
    sudo podman run --privileged -d \
        --ulimit nofile=524288:524288 \
        ${vol_opts} \
        ${network_opts} \
        --volume "${CONTAINER_CACHE_DIR}:/var/lib/containers" \
        ${pull_secret} \
        ${registries_opts} \
        --name "${name}" \
        --hostname "${name}" \
        "${USHIFT_IMAGE}"
    
    # Write enable_ha marker file for bootstrap node when ENABLE_HA=1
    # Joining CPs will copy this marker from bootstrap
    # Must be in /var/lib/microshift/ (config.DataDir) not /var/lib/microshift-data/
    if [ "${is_bootstrap}" = "1" ] && [ "${ENABLE_HA}" = "1" ]; then
        echo "Writing .enable-ha marker in bootstrap container ${name}"
        sudo podman exec "${name}" bash -c 'mkdir -p /var/lib/microshift && cat > /var/lib/microshift/.enable-ha <<EOF
# MicroShift HA mode marker
# Copied to all control plane nodes in HA clusters
# Triggers enable_ha=true in .cluster-config
EOF'

        # Write VIP to .tls-san for API server certificate SANs
        # All control plane nodes will read this to add VIP to their certs
        local vip=$(echo "${ip_address}" | awk -F. '{print $1"."$2"."$3".100"}')
        echo "Writing .tls-san=${vip} in bootstrap container ${name}"
        sudo podman exec "${name}" bash -c "echo '${vip}' > /var/lib/microshift/.tls-san"
    fi

    return $?
}


_join_node() {
    local -r name="${1}"
    local -r primary_name="${NODE_BASE_NAME}1"
    local -r src_kubeconfig="/var/lib/microshift/resources/kubeadmin/${primary_name}/kubeconfig"
    local -r tmp_kubeconfig="/tmp/kubeconfig.${primary_name}"

    sudo podman cp "${primary_name}:${src_kubeconfig}" "${tmp_kubeconfig}"
    local -r dest_kubeconfig="kubeconfig"
    sudo podman cp "${tmp_kubeconfig}" "${name}:${dest_kubeconfig}"
    sudo rm -f "${tmp_kubeconfig}"

    # Copy .cluster-config from bootstrap to preserve enable_ha field
    # This ensures add-node can read enable_ha when regenerating the config
    local -r src_cluster_config="/var/lib/microshift/.cluster-config"
    local -r tmp_cluster_config="/tmp/cluster-config.${primary_name}"
    if sudo podman exec "${primary_name}" test -f "${src_cluster_config}"; then
        sudo podman cp "${primary_name}:${src_cluster_config}" "${tmp_cluster_config}"
        sudo podman exec "${name}" mkdir -p /var/lib/microshift
        sudo podman cp "${tmp_cluster_config}" "${name}:${src_cluster_config}"
        sudo rm -f "${tmp_cluster_config}"
        echo "Copied .cluster-config from bootstrap to ${name} (preserves enable_ha field)"
    fi

    # Copy .tls-san and .enable-ha from bootstrap to joining CPs (workers don't need them)
    # All CPs need these markers for VIP in certs and enable_ha in cluster config
    if [ "${WORKER_ONLY}" != "1" ]; then
        local -r src_tls_san="/var/lib/microshift/.tls-san"
        local -r tmp_tls_san="/tmp/tls-san.${primary_name}"
        if sudo podman exec "${primary_name}" test -f "${src_tls_san}"; then
            sudo podman cp "${primary_name}:${src_tls_san}" "${tmp_tls_san}"
            sudo podman cp "${tmp_tls_san}" "${name}:${src_tls_san}"
            sudo rm -f "${tmp_tls_san}"
            echo "Copied .tls-san from bootstrap to ${name}"
        fi

        local -r src_enable_ha="/var/lib/microshift/.enable-ha"
        local -r tmp_enable_ha="/tmp/enable-ha.${primary_name}"
        if sudo podman exec "${primary_name}" test -f "${src_enable_ha}"; then
            sudo podman cp "${primary_name}:${src_enable_ha}" "${tmp_enable_ha}"
            sudo podman cp "${tmp_enable_ha}" "${name}:${src_enable_ha}"
            sudo rm -f "${tmp_enable_ha}"
            echo "Copied .enable-ha from bootstrap to ${name}"
        fi
    fi

    local worker_flag=""
    if [ "${WORKER_ONLY}" = "1" ]; then
        worker_flag="--worker-only"
    fi

    sudo podman exec -i "${name}" bash -c "\
        systemctl stop microshift kubepods.slice crio && \
        microshift add-node --kubeconfig=${dest_kubeconfig} --learner=false ${worker_flag} > add-node.log 2>&1"

    return $?
}


_get_cluster_containers() {
    sudo podman ps -a --format '{{.Names}}' | grep -E "^${NODE_BASE_NAME}[0-9]+$" || true
}


_get_running_containers() {
    sudo podman ps --format '{{.Names}}' | grep -E "^${NODE_BASE_NAME}[0-9]+$" || true
}


cluster_create() {
    local -r container_name="${NODE_BASE_NAME}1"
    echo "Creating cluster: ${container_name}"

    if _is_container_created "${container_name}"; then
        echo "ERROR: Container '${container_name}' already exists" >&2
        exit 1
    fi

    sudo modprobe openvswitch || true
    if [ "${CREATE_TOPOLVM_BACKEND}" = "1" ]; then
        create_topolvm_backend
    fi
    _create_podman_network "${USHIFT_MULTINODE_CLUSTER}"

    local -r subnet=$(_get_subnet "${USHIFT_MULTINODE_CLUSTER}")
    local network_name="${USHIFT_MULTINODE_CLUSTER}"
    if [ "${ISOLATED_NETWORK}" = "1" ]; then
        network_name="none"
    fi

    local -r node_name="${NODE_BASE_NAME}1"
    local -r ip_address=$(_get_ip_address "$subnet" "1")
    if ! _add_node "${node_name}" "${network_name}" "${ip_address}" "1"; then
        echo "ERROR: failed to create node: $node_name" >&2
        exit 1
    fi

    if [ "${ISOLATED_NETWORK}" = "1" ] ; then
        echo "Configuring isolated network for node: ${node_name}"
        sudo podman cp ./src/config_isolated_net.sh "${node_name}:/tmp/config_isolated_net.sh"
        sudo podman exec -i "${node_name}" /tmp/config_isolated_net.sh
        sudo podman exec -i "${node_name}" rm -vf /tmp/config_isolated_net.sh
    fi

    echo "Cluster created successfully. To access the node container, run:"
    echo "  sudo podman exec -it ${node_name} /bin/bash -l"
}


cluster_add_node() {
    if ! _is_cluster_created; then
        echo "ERROR: Cluster is not created" >&2
        exit 1
    fi
    if [ "${ISOLATED_NETWORK}" = "1" ]; then
        echo "ERROR: Network type is isolated" >&2
        exit 1
    fi

    local -r last_id=$(_get_cluster_containers | wc -l)
    local -r subnet=$(_get_subnet "${USHIFT_MULTINODE_CLUSTER}")
    local -r node_id=$((last_id + 1))
    local -r node_name="${NODE_BASE_NAME}${node_id}"
    local -r ip_address=$(_get_ip_address "$subnet" "$node_id")

    # Validate: Cannot add control plane to non-HA cluster
    if [ "${WORKER_ONLY}" = "0" ]; then
        if ! sudo podman exec "${NODE_BASE_NAME}1" test -f /var/lib/microshift/.enable-ha 2>/dev/null; then
            echo "ERROR: Cannot add control plane - bootstrap node not created with ENABLE_HA=1" >&2
            echo "       To create HA cluster: make run ENABLE_HA=1" >&2
            exit 1
        fi
    fi

    # Wait for existing nodes to be ready before adding new node
    # Note: Adding control planes may cause existing CPs to restart (DaemonSet updates)
    # so we retry with a timeout to allow temporary service disruptions
    echo "Waiting for existing nodes to be ready before adding new node..."
    local retries=0
    local max_retries=12  # 12 * 5s = 60s max wait
    while [ $retries -lt $max_retries ]; do
        if cluster_ready 2>/dev/null; then
            break
        fi
        echo "Nodes not ready yet, retrying in 5s (attempt $((retries + 1))/${max_retries})..."
        sleep 5
        retries=$((retries + 1))
    done

    # Final check - if still not ready, fail
    if ! cluster_ready; then
        echo "ERROR: Existing nodes failed to become ready after ${max_retries} attempts" >&2
        exit 1
    fi

    # CRITICAL: Joining nodes must NOT use ENABLE_HA env var
    # They read enable_ha field from .cluster-config instead
    local -r saved_enable_ha="${ENABLE_HA}"
    export ENABLE_HA=0
    
    echo "Creating node: ${node_name}"
    if ! _add_node "${node_name}" "${USHIFT_MULTINODE_CLUSTER}" "${ip_address}" "0"; then
        export ENABLE_HA="${saved_enable_ha}"
        echo "ERROR: failed to create node: ${node_name}" >&2
        exit 1
    fi
    
    export ENABLE_HA="${saved_enable_ha}"
    echo "Joining node to the cluster: ${node_name}"
    if ! _join_node "${node_name}"; then
        echo "ERROR: failed to join node to the cluster: ${node_name}" >&2
        echo "=== Add-node log content ===" >&2
        if sudo podman exec -i "${node_name}" test -f add-node.log; then
            sudo podman exec -i "${node_name}" cat add-node.log >&2
        else
            echo "WARNING: add-node.log not found in ${node_name}" >&2
        fi
        exit 1
    fi

    local node_type="node"
    if [ "${WORKER_ONLY}" = "1" ]; then
        node_type="worker-only node"
    fi

    echo "Node added successfully as ${node_type}. To access the new node container, run:"
    echo "  sudo podman exec -it ${node_name} /bin/bash -l"
    return 0
}


cluster_start() {
    local -r containers=$(_get_cluster_containers)

    if [ -z "${containers}" ]; then
        echo "ERROR: No cluster containers found" >&2
        exit 1
    fi

    echo "Starting cluster"
    for container in ${containers}; do
        echo "Starting container: ${container}"
        sudo podman start "${container}" || true
    done
}


cluster_stop() {
    local -r containers=$(_get_running_containers)

    if [ -z "${containers}" ]; then
        echo "No running cluster containers"
        return 0
    fi

    echo "Stopping cluster"
    for container in ${containers}; do
        echo "Stopping container: ${container}"
        sudo podman stop --time 0 "${container}" || true
    done
}


cluster_destroy() {
    local containers
    containers=$(_get_cluster_containers)
    for container in ${containers}; do
        echo "Stopping container: ${container}"
        sudo podman stop --time 0 "${container}" || true
        echo "Removing container: ${container}"
        # Remove the container and its anonymous volumes
        sudo podman rm -f --volumes "${container}" || true
    done

    if sudo podman network exists "${USHIFT_MULTINODE_CLUSTER}"; then
        echo "Removing podman network: ${USHIFT_MULTINODE_CLUSTER}"
        sudo podman network rm "${USHIFT_MULTINODE_CLUSTER}" || true
    fi

    sudo rmmod openvswitch || true
    delete_topolvm_backend

    echo "Cluster destroyed successfully"
    echo "NOTE: Container images shared with host at ${CONTAINER_CACHE_DIR}"
}


cluster_ready() {
    local -r containers=$(_get_running_containers)
    if [ -z "${containers}" ]; then
        echo "No running nodes found"
        exit 1
    fi

    # First wait for MicroShift services to be running
    for container in ${containers}; do
        echo "Checking if MicroShift service is running on: ${container}"
        state=$(sudo podman exec -i "${container}" systemctl show --property=SubState --value microshift.service 2>/dev/null || echo "unknown")
        if [ "${state}" != "running" ]; then
            echo "Node ${container} MicroShift service is not running (state: ${state})."
            exit 1
        fi
    done

    # Then verify nodes are Ready in Kubernetes (not just running)
    local -r first_node="${NODE_BASE_NAME}1"
    for container in ${containers}; do
        echo "Checking Kubernetes Ready status of node: ${container}"
        # Get node status from kubectl - Ready nodes have "Ready" in status conditions
        ready_status=$(sudo podman exec -i "${first_node}" kubectl get node "${container}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "${ready_status}" != "True" ]; then
            echo "Node ${container} is not Ready in Kubernetes (status: ${ready_status})."
            exit 1
        fi
    done
    echo "All nodes running and Ready."
}

cluster_healthy() {
    if ! _is_cluster_created ; then
        echo "Cluster is not initialized"
        exit 1
    fi

    local -r containers=$(_get_running_containers)

    if [ -z "${containers}" ]; then
        echo "Cluster is down. No cluster nodes are running."
        exit 1
    fi

    for container in ${containers}; do
        echo "Checking health of node: ${container}"
        state=$(sudo podman exec -i "${container}" systemctl show --property=SubState --value greenboot-healthcheck 2>/dev/null || echo "unknown")
        if [ "${state}" != "exited" ]; then
            echo "Node ${container} is not healthy."
            exit 1
        fi
    done
    echo "All nodes healthy."
}


cluster_status() {
    if ! _is_cluster_created ; then
        echo "Cluster is not initialized"
        exit 1
    fi

    local -r running_containers=$(_get_running_containers)

    if [ -z "${running_containers}" ]; then
        echo "Cluster is down. No cluster nodes are running."
        return 0
    fi

    local -r created_containers=$(_get_cluster_containers)
    for container in ${created_containers}; do
        if ! echo "${running_containers}" | grep -q "${container}"; then
            echo "Node ${container} is not running."
        fi
    done

    local -r first_container=$(echo "${running_containers}" | head -n1)
    echo "Cluster is running."
    sudo podman exec -i "${first_container}" oc get nodes,pods -A -o wide 2>/dev/null || echo "Unable to retrieve cluster status"
    return 0
}

main() {
    case "${1:-}" in
        create)
            shift
            cluster_create
            ;;
        add-node)
            shift
            cluster_add_node
            ;;
        start)
            shift
            cluster_start
            ;;
        stop)
            shift
            cluster_stop
            ;;
        delete)
            shift
            cluster_destroy
            ;;
        ready)
            shift
            cluster_ready
            ;;
        healthy)
            shift
            cluster_healthy
            ;;
        status)
            shift
            cluster_status
            ;;
        topolvm-create)
            shift
            create_topolvm_backend
            ;;
        topolvm-delete)
            shift
            delete_topolvm_backend
            ;;
        *)
            echo "Usage: $0 {create|add-node|start|stop|delete|ready|healthy|status|topolvm-create|topolvm-delete}"
            exit 1
            ;;
    esac
}

# Ensure script is running from project root directory (where Makefile exists)
if [ ! -f "./Makefile" ]; then
    echo "ERROR: Please run this script from the project root directory (where Makefile is located)" >&2
    exit 1
fi

main "$@"
