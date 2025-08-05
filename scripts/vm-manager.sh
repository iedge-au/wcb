#!/bin/bash
set -e

# =============================================================================
# Windows VM Manager - Runtime VM Management
# =============================================================================
# This script manages the lifecycle of a Windows Server Core VM with Docker
# for building and running Windows containers.

# --- Configuration ---
VM_IMAGE_PATH="/vm-images/server-core-docker.qcow2"
RUNTIME_DISK="/tmp/runtime-disk.qcow2"

# VM specifications
VM_RAM="${VM_RAM:-4096}"
VM_CPUS="${VM_CPUS:-2}"

# Port configuration
HOST_DOCKER_PORT="${HOST_DOCKER_PORT:-2376}"
HOST_APP_PORT="${HOST_APP_PORT:-8888}"
VM_DOCKER_PORT="2376"
VM_APP_PORT="8080"
VM_WINRM_PORT="5985"

# Timeouts
DOCKER_TIMEOUT="300"
SHUTDOWN_TIMEOUT="60"

# Static VM network configuration  
VM_STATIC_IP="172.17.0.100"
VM_MAC_ADDRESS="52:54:00:12:34:56"

# Process tracking
QEMU_PID=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Logging Functions ---
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# --- Utility Functions ---
get_vm_ip() {
    # Returns the VM's IP address, using static IP if bridge networking is available
    if is_bridge_networking; then
        echo "$VM_STATIC_IP"
    else
        echo "localhost"
    fi
}

is_bridge_networking() {
    # Check if bridge networking is available and configured
    brctl show | grep -q "^docker0" && [ -f /usr/lib/qemu/qemu-bridge-helper ]
}

get_winrm_url() {
    # Returns the appropriate WinRM URL based on networking mode
    local vm_ip=$(get_vm_ip)
    if [ "$vm_ip" = "localhost" ]; then
        echo "http://localhost:${VM_WINRM_PORT}/wsman"
    else
        echo "http://${vm_ip}:5985/wsman"
    fi
}

get_docker_url() {
    # Returns the appropriate Docker API URL based on networking mode
    local vm_ip=$(get_vm_ip)
    if [ "$vm_ip" = "localhost" ]; then
        echo "http://localhost:${HOST_DOCKER_PORT}/version"
    else
        echo "http://${vm_ip}:2376/version"
    fi
}

wait_for_vm_ip() {
    # Wait for VM to appear on network (bridge mode only)
    if ! is_bridge_networking; then
        return 0  # NAT mode - no IP discovery needed
    fi
    
    log_info "Waiting for VM to obtain IP address..."
    local timeout=60
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if ip neigh show dev docker0 | grep -q "$VM_STATIC_IP"; then
            log_success "VM network ready at $VM_STATIC_IP"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    log_error "VM did not obtain expected IP address within ${timeout}s"
    return 1
}

test_winrm_connection() {
    # Test if WinRM is available on the VM
    if is_bridge_networking; then
        python3 -c "
import winrm
try:
    session = winrm.Session('http://172.17.0.100:5985/wsman', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    result = session.run_cmd('echo test')
    exit(0 if result.status_code == 0 else 1)
except Exception as e:
    exit(1)
        "
    else
        python3 -c "
import winrm
try:
    session = winrm.Session('http://localhost:5985/wsman', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    result = session.run_cmd('echo test')
    exit(0 if result.status_code == 0 else 1)
except Exception as e:
    exit(1)
        "
    fi
}

# --- Cleanup Function ---
cleanup() {
    log_info "VM Manager shutting down, cleaning up..."
    
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        log_info "Gracefully shutting down Windows VM..."
        
        # Try graceful shutdown via WinRM first
        python3 - << EOF 2>/dev/null || true
import winrm
try:
    session = winrm.Session('localhost:${VM_WINRM_PORT}', auth=('developer', 'Password123!'))
    session.run_cmd('shutdown /s /t 10')
    print("Graceful shutdown initiated")
except:
    pass
EOF
        
        # Wait for graceful shutdown
        local count=0
        while [ $count -lt $SHUTDOWN_TIMEOUT ] && kill -0 "$QEMU_PID" 2>/dev/null; do
            sleep 1
            count=$((count + 1))
        done
        
        # Force kill if still running
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            log_warn "Graceful shutdown timed out, force killing VM"
            kill -TERM "$QEMU_PID" 2>/dev/null || true
            sleep 5
            kill -KILL "$QEMU_PID" 2>/dev/null || true
        fi
    fi
    
    # Clean up runtime disk
    rm -f "$RUNTIME_DISK"
    
    log_success "Cleanup complete"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# --- Validation Functions ---
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if VM image exists, build if needed
    if [ ! -f "$VM_IMAGE_PATH" ]; then
        log_info "VM image not found at: $VM_IMAGE_PATH"
        log_info "Building VM image now (this will take 5-15 minutes with KVM)..."
        /scripts/build-vm-image.sh
        if [ ! -f "$VM_IMAGE_PATH" ]; then
            log_error "VM image build failed"
            exit 1
        fi
        log_success "VM image built successfully"
    fi
    
    # Check for required tools
    for tool in qemu-system-x86_64 qemu-img python3; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_error "Required tool not found: $tool"
            exit 1
        fi
    done
    
    # Check if Python winrm module is available
    if ! python3 -c "import winrm" 2>/dev/null; then
        log_error "Python winrm module not found"
        log_error "Install with: pip install pywinrm"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

prepare_runtime_disk() {
    log_info "Preparing runtime VM disk..."
    
    # Create backing file instead of full copy for faster startup
    qemu-img create -f qcow2 -b "$VM_IMAGE_PATH" -F qcow2 "$RUNTIME_DISK" >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log_success "Runtime disk prepared with backing file: $RUNTIME_DISK"
    else
        log_warn "Backing file creation failed, falling back to full copy"
        cp "$VM_IMAGE_PATH" "$RUNTIME_DISK"
        log_success "Runtime disk prepared: $RUNTIME_DISK"
    fi
}

start_bridge_dhcp_server() {
    log_info "Starting DHCP server on Docker bridge..." >&2
    
    pkill dnsmasq 2>/dev/null || true
    
    dnsmasq \
        --interface=docker0 \
        --bind-interfaces \
        --dhcp-range=$VM_STATIC_IP,$VM_STATIC_IP,12h \
        --dhcp-host=$VM_MAC_ADDRESS,$VM_STATIC_IP,wcb-vm,12h \
        --dhcp-option=3,172.17.0.1 \
        --dhcp-option=6,8.8.8.8,8.8.4.4 \
        --no-daemon \
        --log-dhcp \
        --pid-file=/tmp/dnsmasq.pid &
    
    log_success "DHCP server configured for static IP $VM_STATIC_IP" >&2
}

configure_bridge_permissions() {
    # Configure QEMU bridge helper to allow docker0 access
    if [ -f /etc/qemu/bridge.conf ] && ! grep -q "allow docker0" /etc/qemu/bridge.conf; then
        log_info "Configuring QEMU bridge permissions for docker0..." >&2
        echo "allow docker0" >> /etc/qemu/bridge.conf
        log_success "Added docker0 to QEMU bridge configuration" >&2
    fi
}

configure_vm_networking() {
    # Check if we can use bridge networking for better network access
    local bridge_name=""
    
    # Try to find available bridges in order of preference
    for bridge in docker0 br0 virbr0; do
        if brctl show | grep -q "^${bridge}"; then
            bridge_name="$bridge"
            log_info "Found bridge: $bridge_name" >&2
            break
        fi
    done
    
    if [ -n "$bridge_name" ] && [ -f /usr/lib/qemu/qemu-bridge-helper ]; then
        # Configure bridge permissions and start DHCP server
        configure_bridge_permissions >&2
        start_bridge_dhcp_server >&2
        
        # Test if bridge networking is working by checking permissions
        if grep -q "allow $bridge_name" /etc/qemu/bridge.conf 2>/dev/null; then
            log_info "Bridge mode: VM will have direct network access via $bridge_name" >&2
            log_info "VM will be accessible on the Docker network (no port forwarding needed)" >&2
            echo "-netdev bridge,id=net0,br=$bridge_name"
        else
            log_warn "Bridge permissions not configured, falling back to NAT mode" >&2
            echo "-netdev user,id=net0,hostfwd=tcp::${HOST_DOCKER_PORT}-:${VM_DOCKER_PORT},hostfwd=udp::${HOST_DOCKER_PORT}-:${VM_DOCKER_PORT},hostfwd=tcp::${HOST_APP_PORT}-:${VM_APP_PORT},hostfwd=tcp::${VM_WINRM_PORT}-:5985"
        fi
    else
        # Fallback to NAT networking with port forwarding
        if [ -z "$bridge_name" ]; then
            log_warn "No bridge found, using NAT mode" >&2
        else
            log_warn "Bridge helper not available, using NAT mode" >&2
        fi
        log_info "NAT mode: Limited network access with port forwarding" >&2
        log_info "  Host ${HOST_DOCKER_PORT} → VM ${VM_DOCKER_PORT} (Docker API)" >&2
        log_info "  Host ${HOST_APP_PORT} → VM ${VM_APP_PORT} (Application)" >&2
        echo "-netdev user,id=net0,hostfwd=tcp::${HOST_DOCKER_PORT}-:${VM_DOCKER_PORT},hostfwd=udp::${HOST_DOCKER_PORT}-:${VM_DOCKER_PORT},hostfwd=tcp::${HOST_APP_PORT}-:${VM_APP_PORT},hostfwd=tcp::${VM_WINRM_PORT}-:5985"
    fi
}

start_vm() {
    log_info "Starting Windows Server Core VM..."
    log_info "VM specs: ${VM_RAM}MB RAM, ${VM_CPUS} CPUs"
    
    # Configure networking
    log_info "Configuring VM networking..."
    local network_config
    network_config=$(configure_vm_networking)
    
    # Configure display options based on ENABLE_VNC
    local display_options=""
    if [ "${ENABLE_VNC:-false}" = "true" ]; then
        log_info "VNC enabled - VM display available at localhost:5901"
        display_options="-vnc :1"
    else
        display_options="-nographic -serial null -display none"
    fi
    
    log_info "Starting VM with network configuration..."
    
    # Start QEMU with the runtime disk and configured networking
    qemu-system-x86_64 \
        -m "$VM_RAM" \
        -smp "$VM_CPUS" \
        -drive file="$RUNTIME_DISK",format=qcow2,if=ide \
        $network_config \
        -device e1000,netdev=net0,mac=$VM_MAC_ADDRESS \
        -enable-kvm \
        -cpu host \
        -machine pc \
        $display_options \
        -monitor unix:/tmp/qemu-monitor.sock,server,nowait &
    
    QEMU_PID=$!
    log_success "VM started with PID: $QEMU_PID"
}



wait_for_vm_boot() {
    log_info "Waiting for Windows VM to boot..."
    
    local start_time=$(date +%s)
    local timeout=600
    
    # Wait for VM network (bridge mode only)
    if is_bridge_networking; then
        log_info "Bridge networking - waiting for VM network"
        wait_for_vm_ip || exit 1
    else
        log_info "NAT networking - using port forwarding"
    fi
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            log_error "Timeout waiting for VM to boot (${timeout}s)"
            exit 1
        fi
        
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            log_error "VM process died unexpectedly"
            exit 1
        fi
        
        if test_winrm_connection; then
            log_success "Windows VM is responsive"
            # Export VM IP for compatibility
            if is_bridge_networking; then
                export VM_IP="$VM_STATIC_IP"
            fi
            break
        fi
        
        log_info "VM still booting (${elapsed}s/${timeout}s)..."
        sleep 5
    done
}

check_windows_license() {
    log_info "Checking Windows license status..."
    
    local winrm_url=$(get_winrm_url)
    
    python3 - << EOF
import winrm
try:
    session = winrm.Session('${winrm_url}', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    
    rearm_result = session.run_cmd('powershell -c "Get-CimInstance SoftwareLicensingService | Select -ExpandProperty RemainingWindowsReArmCount"')
    if rearm_result.status_code == 0:
        rearm_count = rearm_result.std_out.decode().strip()
        print(f"License rearms remaining: {rearm_count}")
    else:
        print("Could not check license status")
        
except Exception as e:
    print(f"License check error: {e}")
EOF
}

configure_runtime_docker_api() {
    log_info "Configuring Docker TCP API..."
    
    local winrm_url=$(get_winrm_url)
    
    python3 - << EOF
import winrm
try:
    session = winrm.Session('${winrm_url}', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    
    # Check if daemon.json exists and has correct content
    result = session.run_cmd('type C:\\\\ProgramData\\\\Docker\\\\config\\\\daemon.json 2>nul')
    if result.status_code == 0 and 'tcp://0.0.0.0:2376' in result.std_out.decode():
        # Configuration exists, ensure no CLI flag conflicts
        result = session.run_cmd('sc qc docker')
        if '-H' in result.std_out.decode() or '--host' in result.std_out.decode():
            session.run_ps('Stop-Service Docker -Force')
            session.run_cmd('sc config docker binpath= "C:\\\\Windows\\\\system32\\\\dockerd.exe --run-service"')
            session.run_ps('Start-Service Docker')
    else:
        # Create daemon.json configuration
        session.run_ps('Stop-Service Docker -Force')
        session.run_ps('New-Item -ItemType Directory -Path "C:\\\\ProgramData\\\\Docker\\\\config" -Force')
        session.run_ps('New-Item -ItemType Directory -Path "C:\\\\Docker" -Force')
        
        daemon_json = '{\\"hosts\\": [\\"tcp://0.0.0.0:2376\\", \\"npipe://\\"], \\"debug\\": false, \\"data-root\\": \\"C:\\\\\\\\Docker\\", \\"storage-opts\\": [\\"size=60GB\\"]}'
        daemon_config = f'echo {daemon_json} > C:\\\\\\\\ProgramData\\\\\\\\Docker\\\\\\\\config\\\\\\\\daemon.json'
        session.run_cmd(daemon_config)
        
        session.run_cmd('sc config docker binpath= "C:\\\\Windows\\\\system32\\\\dockerd.exe --run-service"')
        session.run_cmd('sc config docker start= auto')
        session.run_ps('Start-Service Docker')
    
    # Ensure firewall rule exists
    firewall_result = session.run_cmd('netsh advfirewall firewall show rule name="Docker API TCP"')
    if firewall_result.status_code != 0:
        session.run_cmd('netsh advfirewall firewall add rule name="Docker API TCP" dir=in protocol=TCP localport=2376 action=allow')
        
except Exception as e:
    print(f"Docker API configuration error: {e}")
EOF
}


wait_for_docker() {
    log_info "Waiting for Docker daemon to be ready..."
    
    configure_runtime_docker_api
    
    local start_time=$(date +%s)
    local timeout=$DOCKER_TIMEOUT
    local docker_url=$(get_docker_url)
    
    if is_bridge_networking; then
        log_info "Bridge networking - connecting to VM at $VM_STATIC_IP"
    else
        log_info "NAT networking - using port forwarding"
    fi
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            log_error "Timeout waiting for Docker daemon (${timeout}s)"
            exit 1
        fi
        
        if curl -s --max-time 5 "$docker_url" >/dev/null 2>&1; then
            log_success "Docker daemon is ready"
            
            if is_bridge_networking; then
                export DOCKER_HOST="tcp://$VM_STATIC_IP:2376"
                log_info "Bridge networking configured"
            fi
            break
        fi
        
        log_info "Docker daemon not ready yet (${elapsed}s/${timeout}s)..."
        sleep 5
    done
}

show_status() {
    log_success "Windows VM Manager is ready!"
    log_info ""
    
    if is_bridge_networking; then
        log_info "Networking: Bridge mode (Static VM IP: $VM_STATIC_IP)"
        log_info "Docker daemon: tcp://$VM_STATIC_IP:2376"
        log_info "VM has full network access"
        log_info ""
        log_info "Usage examples:"
        log_info "  # Create Docker context"
        log_info "  docker context create wcb --docker host=tcp://$VM_STATIC_IP:2376"
        log_info ""
        log_info "  # Test Docker connection"
        log_info "  docker -c wcb version"
        log_info ""
        log_info "  # Run Windows container"
        log_info "  docker -c wcb run mcr.microsoft.com/windows/nanoserver:ltsc2022 ping 8.8.8.8"
    else
        log_info "Networking: NAT mode"
        log_info "Docker daemon: http://localhost:${HOST_DOCKER_PORT}"
        log_info "Application port: http://localhost:${HOST_APP_PORT}"
        log_info ""
        log_info "Usage examples:"
        log_info "  # Test Docker connection"
        log_info "  curl http://localhost:${HOST_DOCKER_PORT}/version"
        log_info ""
        log_info "  # Build Windows container"
        log_info "  docker -H tcp://localhost:${HOST_DOCKER_PORT} build -t my-app ."
    fi
    
    log_info ""
    log_info "Stop this container to shutdown the VM"
}

idle_loop() {
    log_info "VM running - container will remain active until stopped"
    
    local docker_health_url=$(get_docker_url)
    
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        sleep 30
        
        if ! curl -s --max-time 5 "$docker_health_url" >/dev/null 2>&1; then
            log_warn "Docker daemon health check failed"
        fi
    done
    
    log_error "VM process terminated unexpectedly"
    exit 1
}

# --- Main Execution ---
main() {
    log_info "Starting Windows VM Manager"
    log_info "Image: $VM_IMAGE_PATH"
    
    check_prerequisites
    prepare_runtime_disk
    start_vm
    wait_for_vm_boot
    check_windows_license
    wait_for_docker
    show_status
    idle_loop
}

# Execute main function
main "$@"