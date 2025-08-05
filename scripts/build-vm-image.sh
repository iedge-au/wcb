#!/bin/bash
set -e

# =============================================================================
# Windows Server Core VM Image Builder
# =============================================================================
# This script creates a Windows Server Core VM image with Docker pre-installed
# for use in the Windows VM Manager container.

# --- Configuration ---
VM_IMAGE_DIR="/vm-images"
VM_IMAGE_PATH="${VM_IMAGE_DIR}/server-core-docker.qcow2"
WINDOWS_ISO="/isos/windows-server-2022.iso"
AUTOUNATTEND_CD=""
BUILD_DISK="/tmp/build-disk.qcow2"

# VM specifications
VM_RAM="4096"
VM_CPUS="2"
VM_DISK_SIZE="100G"

# Network and timing
WINRM_PORT="5985"
WINRM_TIMEOUT="3600"  # 60 minutes max wait for WinRM
VM_IP=""

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
    log_info "Cleaning up build artifacts..."
    
    # Kill any running QEMU processes
    pkill -f "qemu-system-x86_64.*build-disk" || true
    
    # Remove temporary files (but preserve installation log)
    rm -f "$AUTOUNATTEND_CD" "$BUILD_DISK"
    
    # Copy installation log to persistent location if it exists
    if [ -f "/tmp/windows-install.log" ]; then
        cp "/tmp/windows-install.log" "/tmp/last-install.log" 2>/dev/null || true
        log_info "Installation log preserved at: /tmp/last-install.log"
    fi
    
    # If build failed, don't leave partial VM image
    if [ $? -ne 0 ] && [ -f "$BUILD_DISK" ]; then
        log_warn "Build failed, removing partial image"
        rm -f "$VM_IMAGE_PATH"
    fi
}

trap cleanup SIGINT SIGTERM

# --- Validation Functions ---
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if Windows ISO exists
    if [ ! -f "$WINDOWS_ISO" ]; then
        log_error "Windows Server 2022 ISO not found at: $WINDOWS_ISO"
        log_error "Please download Windows Server 2022 evaluation ISO and place it in isos/"
        log_error "Download from: https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022"
        exit 1
    fi
    
    # Check if autounattend.xml exists
    if [ ! -f "/unattend/autounattend.xml" ]; then
        log_error "autounattend.xml not found at: /unattend/autounattend.xml"
        exit 1
    fi
    
    # Check for required tools
    for tool in qemu-system-x86_64 qemu-img xorriso python3; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_error "Required tool not found: $tool"
            exit 1
        fi
    done
    
    # Create VM images directory
    mkdir -p "$VM_IMAGE_DIR"
    
    log_success "Prerequisites check passed"
}

check_existing_image() {
    if [ -f "$VM_IMAGE_PATH" ]; then
        log_success "VM image already exists at: $VM_IMAGE_PATH"
        log_info "Size: $(du -h "$VM_IMAGE_PATH" | cut -f1)"
        log_info "Skipping build process"
        exit 0
    fi
}

create_autounattend_cd() {
    log_info "Creating CD-ROM with autounattend.xml..."
    
    # Create temporary directory for CD contents
    local cd_dir="/tmp/autounattend_cd"
    mkdir -p "$cd_dir"
    
    # Copy autounattend.xml to CD directory
    cp "/unattend/autounattend.xml" "$cd_dir/"
    
    # Create ISO image with autounattend.xml
    local cd_image="/tmp/autounattend.iso"
    log_info "Creating autounattend CD image..."
    xorriso -as mkisofs -o "$cd_image" -V "AUTOUNATTEND" -J -r "$cd_dir" >/dev/null 2>&1
    
    # Clean up temporary directory
    rm -rf "$cd_dir"
    
    # Export the CD image path for use in QEMU command
    AUTOUNATTEND_CD="$cd_image"
    
    log_success "Autounattend CD created: $cd_image"
}

create_vm_disk() {
    log_info "Creating VM disk image ($VM_DISK_SIZE)..."
    
    qemu-img create -f qcow2 "$BUILD_DISK" "$VM_DISK_SIZE" >/dev/null 2>&1
    
    log_success "VM disk created: $BUILD_DISK"
}

install_windows() {
    log_info "Starting Windows Server Core installation..."
    log_info "This will take 10-20 minutes depending on your system"
    
    # Create log file for installation
    local install_log="/tmp/windows-install.log"
    log_info "Installation logs will be written to: $install_log"
    
    # Configure display options based on ENABLE_VNC
    local display_options=""
    if [ "${ENABLE_VNC:-false}" = "true" ]; then
        log_info "VNC enabled - VM display available at localhost:5901"
        display_options="-vnc :1"
    else
        display_options="-nographic -display none"
    fi
    
    # Start QEMU with Windows installation and capture output
    # Using IDE drives for compatibility (no special drivers needed)
    qemu-system-x86_64 \
        -m "$VM_RAM" \
        -smp "$VM_CPUS" \
        -drive file="$BUILD_DISK",format=qcow2,if=ide \
        -drive file="$WINDOWS_ISO",media=cdrom,readonly=on \
        -drive file="$AUTOUNATTEND_CD",media=cdrom,readonly=on \
        -netdev user,id=net0,hostfwd=tcp::${WINRM_PORT}-:5985 \
        -device e1000,netdev=net0 \
        -enable-kvm \
        -cpu host \
        -machine pc \
        $display_options \
        -serial file:$install_log \
        -monitor none \
        -boot order=cd,once=d &
    
    local qemu_pid=$!
    log_info "QEMU started with PID: $qemu_pid"
    log_info "Monitor installation progress with: tail -f $install_log"
    
    # Wait for installation to complete (VM will restart and be ready for WinRM)
    log_info "Waiting for Windows installation to complete..."
    wait_for_winrm
    
    # Keep VM running for Docker installation
    log_success "Windows installation completed, VM ready for Docker installation"
    log_info "Installation log saved to: $install_log"
    
    # Store QEMU PID for later use
    export QEMU_PID=$qemu_pid
}

wait_for_winrm() {
    log_info "Waiting for Windows to boot and WinRM to be available..."
    
    local start_time=$(date +%s)
    local timeout=$WINRM_TIMEOUT
    local winrm_connected=false
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            log_error "Timeout waiting for WinRM (${timeout}s)"
            exit 1
        fi
        
        # Try to connect to WinRM with explicit Basic auth
        if python3 -c "
import winrm
try:
    session = winrm.Session('http://localhost:${WINRM_PORT}/wsman', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    result = session.run_cmd('echo test')
    if result.status_code == 0:
        exit(0)
except Exception as e:
    print(f'WinRM connection failed: {e}')
exit(1)
        "; then
            log_success "WinRM is available"
            winrm_connected=true
            break
        fi
        
        log_info "WinRM not ready yet (${elapsed}s/${timeout}s)..."
        sleep 10
    done
    
}

restart_vm_without_installation_media() {
    log_info "Stopping VM to remove installation media..."
    
    # Kill the current QEMU process
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID"
        sleep 5
    fi
    
    # Configure display options based on ENABLE_VNC
    local display_options=""
    if [ "${ENABLE_VNC:-false}" = "true" ]; then
        log_info "VNC enabled - VM display available at localhost:5901"
        display_options="-vnc :1"
    else
        display_options="-nographic -display none"
    fi
    
    log_info "Starting VM without installation media for Docker installation..."
    
    # Start QEMU without installation CDs, boot from hard disk
    qemu-system-x86_64 \
        -m "$VM_RAM" \
        -smp "$VM_CPUS" \
        -drive file="$BUILD_DISK",format=qcow2,if=ide \
        -netdev user,id=net0,hostfwd=tcp::${WINRM_PORT}-:5985 \
        -device e1000,netdev=net0 \
        -enable-kvm \
        -cpu host \
        -machine pc \
        $display_options \
        -serial file:/tmp/windows-install.log \
        -monitor none \
        -boot c &
    
    local new_qemu_pid=$!
    log_info "VM restarted with PID: $new_qemu_pid without installation media"
    export QEMU_PID=$new_qemu_pid
    
    # Wait for WinRM to be available again after restart
    log_info "Waiting for VM to boot from hard disk and WinRM to be available..."
    local start_time=$(date +%s)
    local timeout=300  # 5 minutes for reboot
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            log_error "Timeout waiting for VM to restart (${timeout}s)"
            return 1
        fi
        
        # Try to connect to WinRM
        if python3 -c "
import winrm
try:
    session = winrm.Session('http://localhost:${WINRM_PORT}/wsman', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    result = session.run_cmd('echo restart_test')
    if result.status_code == 0:
        exit(0)
except:
    pass
exit(1)
        "; then
            log_success "VM restarted successfully and WinRM is available"
            return 0
        fi
        
        log_info "Waiting for VM restart (${elapsed}s/${timeout}s)..."
        sleep 10
    done
}

wait_for_docker_installation() {
    log_info "Waiting for Docker installation to complete during Windows setup..."
    
    local start_time=$(date +%s)
    local timeout=1800  # 30 minutes for Docker installation during setup
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            log_error "Timeout waiting for Docker installation during setup (${timeout}s)"
            return 1
        fi
        
        # Check if Docker installation completed and service is running
        if python3 -c "
import winrm
try:
    session = winrm.Session('http://localhost:${WINRM_PORT}/wsman', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    
    # Check if Docker service exists and is running
    result = session.run_ps('Get-Service Docker -ErrorAction SilentlyContinue')
    if result.status_code == 0 and 'Running' in result.std_out.decode():
        # Double-check with docker version command
        docker_result = session.run_cmd('docker version')
        if docker_result.status_code == 0:
            print('Docker installation completed and working')
            exit(0)
        else:
            print('Docker service running but docker command failed')
    else:
        print('Docker service not running yet')
except Exception as e:
    print(f'Error checking Docker status: {e}')
exit(1)
        "; then
            log_success "Docker installation completed during Windows setup"
            return 0
        fi
        
        # Try to show Docker installation progress from log file
        local log_output=$(python3 -c "
import winrm
try:
    session = winrm.Session('http://localhost:${WINRM_PORT}/wsman', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    result = session.run_cmd('type C:\\\\docker-install.log 2>nul')
    if result.status_code == 0:
        print(result.std_out.decode())
    else:
        print('Log file not yet available')
except:
    print('Cannot access log file yet')
" 2>/dev/null)
        
        if echo "$log_output" | grep -v -q "Log file not yet available\|Cannot access log file yet"; then
            echo "$log_output" | tail -5 | while read line; do
                if [ -n "$line" ]; then
                    log_info "[DOCKER] $line"
                fi
            done
        fi
        
        log_info "Docker installation in progress (${elapsed}s/${timeout}s)..."
        sleep 30
    done
}

install_docker() {
    log_info "Docker installation is handled during Windows setup via autounattend.xml"
    
    # Just wait for Docker installation to complete
    wait_for_docker_installation
    
    if [ $? -eq 0 ]; then
        log_success "Docker installation completed successfully"
        return 0
    else
        log_error "Docker installation failed or timed out"
        return 1
    fi
}

install_docker_with_reboot_handling() {
    local docker_script="$1"
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log_info "Docker installation attempt $attempt/$max_attempts"
        
        # Execute Docker installation with real-time log streaming
        log_info "Starting Docker installation with live log monitoring..."
        
        # Execute Docker installation commands one by one for better error visibility
        python3 - << EOF &
import winrm
import sys
import time

def run_command_with_logging(session, command, description, is_powershell=True):
    print(f"[DOCKER] {description}...")
    try:
        if is_powershell:
            result = session.run_ps(command)
        else:
            result = session.run_cmd(command)
        
        print(f"[DOCKER] {description} - Exit Code: {result.status_code}")
        
        if result.std_out:
            stdout = result.std_out.decode().strip()
            if stdout:
                print(f"[DOCKER] STDOUT: {stdout}")
        
        if result.std_err:
            stderr = result.std_err.decode().strip()
            if stderr:
                print(f"[DOCKER] STDERR: {stderr}")
        
        return result.status_code == 0, result
    except Exception as e:
        print(f"[DOCKER] {description} failed with exception: {e}")
        return False, None

try:
    session = winrm.Session('http://localhost:${WINRM_PORT}/wsman', auth=('developer', 'Password123'), transport='basic')
    
    print("[DOCKER] Starting Docker installation with individual commands...")
    
    # Setup logging
    success, _ = run_command_with_logging(session, 
        'Write-Output "Docker installation started" | Out-File -FilePath C:\\docker-install.log -Encoding ASCII',
        "Setting up installation logging")
    if not success: raise Exception("Failed to setup logging")
    
    # Install NuGet provider
    success, _ = run_command_with_logging(session,
        'Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force',
        "Installing NuGet provider")
    if not success: raise Exception("Failed to install NuGet provider")
    
    # Download Microsoft Docker installation script
    success, _ = run_command_with_logging(session,
        'Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1" -OutFile "C:\\install-docker-ce.ps1"',
        "Downloading Microsoft Docker installation script")
    if not success: raise Exception("Failed to download Docker installation script")
    
    # Install Docker using Microsoft script (this may take several minutes and could cause VM shutdown)
    print("[DOCKER] Installing Docker using Microsoft script (this may take several minutes and could cause VM shutdown)...")
    success, result = run_command_with_logging(session,
        'C:\\install-docker-ce.ps1 -DockerVersion "latest"',
        "Installing Docker using Microsoft script")
    if not success: raise Exception("Failed to install Docker package")
    
    # Check if Docker service exists after installation
    success, result = run_command_with_logging(session,
        'Get-Service Docker -ErrorAction SilentlyContinue | Select-Object Status',
        "Checking Docker service status")
    
    # Start Docker service
    success, _ = run_command_with_logging(session,
        'Start-Service Docker',
        "Starting Docker service")
    if not success:
        print("[DOCKER] Warning: Docker service failed to start, but continuing...")
    
    # Set Docker to start automatically
    success, _ = run_command_with_logging(session,
        'Set-Service Docker -StartupType Automatic',
        "Setting Docker startup type")
    
    # Create Docker daemon configuration
    success, _ = run_command_with_logging(session,
        'New-Item -ItemType Directory -Path C:\\ProgramData\\docker\\config -Force',
        "Creating Docker config directory")
    
    success, _ = run_command_with_logging(session,
        'Write-Output \'{"hosts": ["tcp://0.0.0.0:2376", "npipe://"], "api-cors-header": "*"}\' | Set-Content C:\\ProgramData\\docker\\config\\daemon.json -Encoding ASCII',
        "Writing Docker daemon configuration")
    
    # Restart Docker with new configuration
    success, _ = run_command_with_logging(session,
        'Restart-Service Docker -Force',
        "Restarting Docker with new configuration")
    if not success:
        print("[DOCKER] Warning: Docker service restart failed, but continuing...")
    
    # Test Docker installation
    success, result = run_command_with_logging(session,
        'docker version',
        "Testing Docker installation")
    
    # Create completion marker
    success, _ = run_command_with_logging(session,
        'Write-Output "Docker installation completed successfully" | Out-File -FilePath C:\\docker-installed.txt -Encoding ASCII',
        "Creating completion marker")
    
    print("[DOCKER] Docker installation completed successfully!")
    
    # Write success result to temp file for main process
    with open('/tmp/docker_install_result.txt', 'w') as f:
        f.write("0")
        
except Exception as e:
    print(f"[DOCKER] Installation failed: {e}")
    with open('/tmp/docker_install_result.txt', 'w') as f:
        f.write("CONNECTION_FAILED")
EOF
        
        local install_pid=$!
        
        # Monitor the Docker installation log in real-time
        log_info "Monitoring Docker installation progress..."
        local log_monitor_attempts=0
        local max_log_attempts=120  # 20 minutes max
        
        while [ $log_monitor_attempts -lt $max_log_attempts ]; do
            # Try to read the Docker installation log from Windows
            local log_output=$(python3 - << EOF 2>/dev/null
import winrm
try:
    session = winrm.Session('http://localhost:${WINRM_PORT}/wsman', auth=('developer', 'Password123'), transport='basic')
    result = session.run_cmd('type C:\\\\docker-install.log 2>nul')
    if result.status_code == 0:
        print(result.std_out.decode())
    else:
        print("LOG_NOT_READY")
except:
    print("CONNECTION_LOST")
EOF
)
            
            if echo "$log_output" | grep -q "CONNECTION_LOST"; then
                log_warn "WinRM connection lost during installation - VM may have rebooted"
                break
            elif echo "$log_output" | grep -v -q "LOG_NOT_READY"; then
                # We have log content - show the latest entries
                echo "$log_output" | tail -10 | while read line; do
                    if [ -n "$line" ]; then
                        echo "[DOCKER LOG] $line"
                    fi
                done
            fi
            
            # Check if installation process is complete
            if [ -f /tmp/docker_install_result.txt ]; then
                log_info "Docker installation process completed"
                break
            fi
            
            sleep 10
            ((log_monitor_attempts++))
        done
        
        # Wait for installation to complete and get result
        wait $install_pid 2>/dev/null
        
        local install_result="UNKNOWN"
        if [ -f /tmp/docker_install_result.txt ]; then
            install_result=$(cat /tmp/docker_install_result.txt)
            rm -f /tmp/docker_install_result.txt
        fi
        
        if [ "$install_result" = "0" ]; then
            log_success "Docker installation completed successfully"
            return 0
        elif echo "$install_result" | grep -q "CONNECTION_FAILED"; then
            log_warn "WinRM connection lost - VM likely rebooted for Docker installation"
            log_info "Waiting for VM to restart and WinRM to become available..."
            
            # Wait for VM to reboot and WinRM to come back online
            wait_for_vm_reboot
            
            # Check if Docker installation continued after reboot
            if check_docker_installation_complete; then
                log_success "Docker installation completed after reboot"
                return 0
            fi
            
            log_info "Docker installation needs to continue after reboot"
            ((attempt++))
        else
            log_error "Docker installation failed with result: $install_result"
            log_error "Check the Docker installation logs above for details"
            return 1
        fi
    done
    
    log_error "Docker installation failed after $max_attempts attempts"
    return 1
}

wait_for_vm_reboot() {
    log_info "Waiting for VM to complete reboot..."
    
    # Wait a bit for reboot to start
    sleep 30
    
    # Wait for WinRM to become available again
    local start_time=$(date +%s)
    local reboot_timeout=600  # 10 minutes for reboot
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $reboot_timeout ]; then
            log_error "Timeout waiting for VM to reboot (${reboot_timeout}s)"
            return 1
        fi
        
        # Try to connect to WinRM
        if python3 -c "
import winrm
try:
    session = winrm.Session('http://localhost:${WINRM_PORT}/wsman', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    result = session.run_cmd('echo reboot_complete')
    if result.status_code == 0:
        exit(0)
except:
    pass
exit(1)
        "; then
            log_success "VM has rebooted and WinRM is available"
            return 0
        fi
        
        log_info "Waiting for VM reboot to complete (${elapsed}s/${reboot_timeout}s)..."
        sleep 15
    done
}

check_docker_installation_complete() {
    log_info "Checking if Docker installation is complete..."
    
    local check_result=$(python3 - << EOF
import winrm
try:
    session = winrm.Session('http://localhost:${WINRM_PORT}/wsman', auth=('developer', 'Password123'), transport='basic')
    
    # Check for completion marker
    result = session.run_cmd('type C:\\docker-installed.txt 2>nul')
    if result.status_code == 0:
        print("COMPLETE")
        exit(0)
    
    # Check if Docker service exists and is running
    result = session.run_ps('Get-Service Docker -ErrorAction SilentlyContinue | Select-Object Status')
    if 'Running' in result.std_out.decode():
        print("COMPLETE")
        exit(0)
    
    print("INCOMPLETE")
    
except Exception as e:
    print(f"CHECK_FAILED: {e}")
EOF
)
    
    if echo "$check_result" | grep -q "COMPLETE"; then
        return 0
    else
        return 1
    fi
}

configure_docker_api() {
    log_info "Configuring Docker daemon for TCP API access using Windows service method..."
    
    python3 - << EOF
import winrm
try:
    session = winrm.Session('http://localhost:${WINRM_PORT}/wsman', 
                           auth=('developer', 'Password123'), 
                           transport='basic')
    
    print("[DOCKER CONFIG] Stopping Docker service...")
    result = session.run_ps('Stop-Service Docker -Force')
    if result.status_code != 0:
        print(f"[DOCKER CONFIG] Warning: Stop service returned {result.status_code}")
    
    # Use ONLY daemon.json configuration for TCP API
    print("[DOCKER CONFIG] Creating daemon.json for TCP API access...")
    
    # Ensure config directory exists
    session.run_ps('New-Item -ItemType Directory -Path "C:\\\\ProgramData\\\\Docker\\\\config" -Force')
    
    # Create Docker data-root directory (required for daemon.json data-root setting)
    print("[DOCKER CONFIG] Creating Docker data-root directory...")
    session.run_ps('New-Item -ItemType Directory -Path "C:\\\\Docker" -Force')
    
    # Create daemon.json with correct Windows syntax (per official Docker docs)
    daemon_json = '{\\"hosts\\": [\\"tcp://0.0.0.0:2376\\", \\"npipe://\\"], \\"debug\\": false, \\"data-root\\": \\"C:\\\\\\\\Docker\\", \\"storage-opts\\": [\\"size=60GB\\"]}'
    daemon_config = f'echo {daemon_json} > C:\\\\\\\\ProgramData\\\\\\\\Docker\\\\\\\\config\\\\\\\\daemon.json'
    
    result = session.run_cmd(daemon_config)
    if result.status_code == 0:
        print("[DOCKER CONFIG] daemon.json created successfully")
        
        # Ensure service has NO CLI flags that conflict with daemon.json
        print("[DOCKER CONFIG] Removing any CLI flags from Docker service...")
        session.run_cmd('sc config docker binpath= "C:\\\\Windows\\\\system32\\\\dockerd.exe --run-service"')
        
        # Set service to immediate start to eliminate 120s startup delay
        print("[DOCKER CONFIG] Setting Docker service to immediate start...")
        session.run_cmd('sc config docker start= auto')
        
        print("[DOCKER CONFIG] Docker configured to use daemon.json on startup")
    else:
        print(f"[DOCKER CONFIG] Failed to create daemon.json: {result.std_err.decode()}")
    
    print("[DOCKER CONFIG] Adding Windows Firewall rule for Docker API...")
    result = session.run_cmd('netsh advfirewall firewall add rule name="Docker API TCP" dir=in protocol=TCP localport=2376 action=allow')
    if result.status_code == 0:
        print("[DOCKER CONFIG] Firewall rule added successfully")
    else:
        print(f"[DOCKER CONFIG] Warning: Firewall rule add failed: {result.std_err.decode()}")
    
    print("[DOCKER CONFIG] Starting Docker service with TCP API configuration...")
    result = session.run_ps('Start-Service Docker')
    if result.status_code == 0:
        print("[DOCKER CONFIG] Docker service started successfully")
        
        # Wait for Docker to fully initialize
        import time
        time.sleep(15)
        
        # Test if Docker is listening on port 2376
        print("[DOCKER CONFIG] Checking if Docker is listening on port 2376...")
        netstat_result = session.run_ps('netstat -an | Select-String "2376"')
        if netstat_result.status_code == 0 and "2376" in netstat_result.std_out.decode():
            print("[DOCKER CONFIG] SUCCESS: Docker is listening on port 2376!")
            
            # Test API endpoint
            api_result = session.run_ps('try { Invoke-WebRequest -Uri http://localhost:2376/version -UseBasicParsing -TimeoutSec 10 | Select-Object StatusCode } catch { Write-Output "API_FAILED" }')
            if "200" in api_result.std_out.decode():
                print("[DOCKER CONFIG] SUCCESS: Docker TCP API is fully functional!")
            else:
                print("[DOCKER CONFIG] Warning: Port 2376 is listening but API test failed")
        else:
            print("[DOCKER CONFIG] Error: Docker is not listening on port 2376")
            print(f"[DOCKER CONFIG] netstat output: {netstat_result.std_out.decode()}")
            
            # Show Docker service status for debugging
            status_result = session.run_ps('Get-Service Docker | Select-Object Status, Name')
            print(f"[DOCKER CONFIG] Docker service status: {status_result.std_out.decode()}")
    else:
        print(f"[DOCKER CONFIG] Error: Docker service failed to start with status {result.status_code}")
        print(f"[DOCKER CONFIG] Error details: {result.std_err.decode()}")
        
except Exception as e:
    print(f"[DOCKER CONFIG] Error configuring Docker: {e}")
EOF
}

finalize_image() {
    log_info "Finalizing VM image..."
    
    # Shutdown the VM gracefully
    python3 - << EOF
import winrm
try:
    session = winrm.Session('http://localhost:${WINRM_PORT}/wsman', auth=('developer', 'Password123'), transport='basic')
    session.run_cmd('shutdown /s /t 0 /f')
    print("Shutdown initiated")
except:
    print("Failed to initiate shutdown")
EOF

    # Wait for shutdown
    sleep 45
    
    # Move build disk to final location
    mv "$BUILD_DISK" "$VM_IMAGE_PATH"
    
    log_success "VM image finalized: $VM_IMAGE_PATH"
    log_info "Image size: $(du -h "$VM_IMAGE_PATH" | cut -f1)"
}

# --- Main Execution ---
main() {
    log_info "Starting Windows Server Core VM image build process"
    
    check_prerequisites
    check_existing_image
    create_autounattend_cd
    create_vm_disk
    install_windows
    install_docker
    configure_docker_api
    finalize_image
    
    log_success "Windows Server Core VM image build completed successfully!"
    log_info "Image location: $VM_IMAGE_PATH"
    log_info "You can now use this image with the Windows VM Manager"
}

# Execute main function
main "$@"