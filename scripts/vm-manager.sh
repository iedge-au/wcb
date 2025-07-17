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
DOCKER_TIMEOUT="1800"  # 30 minutes to wait for Docker to be ready (for debugging)
SHUTDOWN_TIMEOUT="60" # 1 minute to wait for graceful shutdown

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

start_vm() {
    log_info "Starting Windows Server Core VM..."
    log_info "VM specs: ${VM_RAM}MB RAM, ${VM_CPUS} CPUs"
    log_info "Port forwarding:"
    log_info "  Host ${HOST_DOCKER_PORT} → VM ${VM_DOCKER_PORT} (Docker API)"
    log_info "  Host ${HOST_APP_PORT} → VM ${VM_APP_PORT} (Application)"
    
    # Configure display options based on ENABLE_VNC
    local display_options=""
    if [ "${ENABLE_VNC:-false}" = "true" ]; then
        log_info "  Host 5901 → VM VNC (Remote Display)"
        log_info "VNC enabled - VM display available at localhost:5901"
        display_options="-vnc :1"
    else
        display_options="-nographic -serial null -display none"
    fi
    
    # Start QEMU with the runtime disk (matching build configuration)
    qemu-system-x86_64 \
        -m "$VM_RAM" \
        -smp "$VM_CPUS" \
        -drive file="$RUNTIME_DISK",format=qcow2,if=ide \
        -netdev user,id=net0,hostfwd=tcp::${HOST_DOCKER_PORT}-:${VM_DOCKER_PORT},hostfwd=udp::${HOST_DOCKER_PORT}-:${VM_DOCKER_PORT},hostfwd=tcp::${HOST_APP_PORT}-:${VM_APP_PORT},hostfwd=tcp::${VM_WINRM_PORT}-:5985 \
        -device e1000,netdev=net0 \
        -enable-kvm \
        -cpu host \
        -machine pc \
        $display_options \
        -monitor none &
    
    QEMU_PID=$!
    log_success "VM started with PID: $QEMU_PID"
}

wait_for_vm_boot() {
    log_info "Waiting for Windows VM to boot..."
    
    local start_time=$(date +%s)
    local timeout=180  # 3 minutes for boot
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            log_error "Timeout waiting for VM to boot (${timeout}s)"
            exit 1
        fi
        
        # Check if QEMU process is still running
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            log_error "VM process died unexpectedly"
            exit 1
        fi
        
        # Try to connect to WinRM to see if VM is responsive
        python3 -c "
import winrm
try:
    session = winrm.Session('http://localhost:5985/wsman', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    result = session.run_cmd('echo VM is ready')
    if result.status_code == 0:
        with open('/tmp/winrm_success', 'w') as f:
            f.write('success')
except:
    pass
        "
        
        if [ -f /tmp/winrm_success ]; then
            rm -f /tmp/winrm_success
            log_success "Windows VM is responsive"
            break
        fi
        
        log_info "VM still booting (${elapsed}s/${timeout}s)..."
        sleep 5
    done
}

check_windows_license() {
    log_info "Checking Windows license status..."
    
    python3 - << EOF
import winrm
try:
    session = winrm.Session('http://localhost:5985/wsman', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    
    print("[LICENSE] Checking rearm availability...")
    
    # Get rearm count (this works reliably)
    rearm_result = session.run_cmd('powershell -c "Get-CimInstance SoftwareLicensingService | Select -ExpandProperty RemainingWindowsReArmCount"')
    if rearm_result.status_code == 0:
        rearm_count = rearm_result.std_out.decode().strip()
        print(f"[LICENSE] Remaining rearms: {rearm_count}")
        
        # For now, just report the rearm count
        # TODO: Add grace period detection when we find working PowerShell command
        print("[LICENSE] License monitoring active - rearm available when needed")
    else:
        print("[LICENSE] Could not check license status")
        
except Exception as e:
    print(f"[LICENSE] Error: {e}")
EOF
}

configure_runtime_docker_api() {
    log_info "Configuring Docker TCP API for runtime access..."
    
    python3 - << EOF
import winrm
try:
    session = winrm.Session('http://localhost:5985/wsman', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    
    print("[RUNTIME] Checking daemon.json configuration...")
    
    # Check if daemon.json exists and has correct content
    result = session.run_cmd('type C:\\\\ProgramData\\\\Docker\\\\config\\\\daemon.json 2>nul')
    if result.status_code == 0 and 'tcp://0.0.0.0:2376' in result.std_out.decode():
        print("[RUNTIME] daemon.json exists with TCP configuration")
        
        # Verify service has no conflicting CLI flags
        result = session.run_cmd('sc qc docker')
        if '-H' in result.std_out.decode() or '--host' in result.std_out.decode():
            print("[RUNTIME] Removing conflicting CLI flags from service...")
            session.run_ps('Stop-Service Docker -Force')
            session.run_cmd('sc config docker binpath= "C:\\\\Windows\\\\system32\\\\dockerd.exe --run-service"')
            session.run_ps('Start-Service Docker')
            print("[RUNTIME] Docker service cleaned of CLI flags")
        else:
            print("[RUNTIME] Docker service configuration is clean")
            
        # Ensure Docker API firewall rule exists (critical fix for TCP connectivity)
        print("[RUNTIME] Ensuring Docker API firewall rule exists...")
        firewall_result = session.run_cmd('netsh advfirewall firewall show rule name="Docker API TCP"')
        if firewall_result.status_code != 0:
            print("[RUNTIME] Adding missing Docker API firewall rule...")
            session.run_cmd('netsh advfirewall firewall add rule name="Docker API TCP" dir=in protocol=TCP localport=2376 action=allow')
            print("[RUNTIME] Docker API firewall rule added")
        else:
            print("[RUNTIME] Docker API firewall rule already exists")
            
    else:
        print("[RUNTIME] daemon.json missing or incorrect, creating it...")
        session.run_ps('Stop-Service Docker -Force')
        
        # Create daemon.json with proper configuration
        session.run_ps('New-Item -ItemType Directory -Path "C:\\\\ProgramData\\\\Docker\\\\config" -Force')
        daemon_json = '{\\"hosts\\": [\\"tcp://0.0.0.0:2376\\", \\"npipe://\\"], \\"debug\\": true}'
        daemon_config = f'echo {daemon_json} > C:\\\\ProgramData\\\\Docker\\\\config\\\\daemon.json'
        session.run_cmd(daemon_config)
        
        # Ensure service has no CLI flags
        session.run_cmd('sc config docker binpath= "C:\\\\Windows\\\\system32\\\\dockerd.exe --run-service"')
        session.run_cmd('sc config docker start= delayed-auto')
        
        # Ensure Docker API firewall rule exists (critical fix for TCP connectivity)
        print("[RUNTIME] Adding Docker API firewall rule...")
        session.run_cmd('netsh advfirewall firewall add rule name="Docker API TCP" dir=in protocol=TCP localport=2376 action=allow')
        print("[RUNTIME] Docker API firewall rule added")
        
        session.run_ps('Start-Service Docker')
        print("[RUNTIME] daemon.json created and Docker restarted")
        
except Exception as e:
    print(f"[RUNTIME] Error configuring Docker API: {e}")
EOF
}

wait_for_docker() {
    log_info "Waiting for Docker daemon to be ready..."
    
    # First try to configure TCP API if needed
    configure_runtime_docker_api
    
    local start_time=$(date +%s)
    local timeout=$DOCKER_TIMEOUT
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            log_error "Timeout waiting for Docker daemon (${timeout}s)"
            exit 1
        fi
        
        # Try to connect to Docker daemon
        if curl -s --max-time 5 "http://localhost:${HOST_DOCKER_PORT}/version" >/dev/null 2>&1; then
            log_success "Docker daemon is ready"
            break
        fi
        
        log_info "Docker daemon not ready yet (${elapsed}s/${timeout}s)..."
        sleep 5
    done
}

show_status() {
    log_success "Windows VM Manager is ready!"
    log_info ""
    log_info "Docker daemon: http://localhost:${HOST_DOCKER_PORT}"
    log_info "Application port: http://localhost:${HOST_APP_PORT}"
    log_info ""
    log_info "Usage examples:"
    log_info "  # Test Docker connection"
    log_info "  curl http://localhost:${HOST_DOCKER_PORT}/version"
    log_info ""
    log_info "  # Build Windows container"
    log_info "  docker --context tcp://localhost:${HOST_DOCKER_PORT} build -t my-app ."
    log_info ""
    log_info "  # Run Windows container"
    log_info "  docker --context tcp://localhost:${HOST_DOCKER_PORT} run -p 8080:8080 my-app"
    log_info ""
    log_info "Stop this container to shutdown the VM"
}

idle_loop() {
    log_info "Entering idle state - VM will run until container is stopped"
    
    # Monitor QEMU process and keep container alive
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        sleep 10
        
        # Optional: Check Docker health periodically
        if ! curl -s --max-time 5 "http://localhost:${HOST_DOCKER_PORT}/version" >/dev/null 2>&1; then
            log_warn "Docker daemon appears to be unresponsive"
        fi
    done
    
    log_error "VM process died unexpectedly"
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