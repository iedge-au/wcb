# Windows VM Manager Container
# Provides a Windows Server Core VM with Docker for building Windows containers on Linux

FROM alpine:latest

# Set working directory
WORKDIR /

# Install dependencies
# - qemu-system-x86_64: For running VMs
# - qemu-img: For disk image management  
# - python3, py3-pip: For WinRM automation
# - genisoimage: For creating ISO images
# - curl: For health checks
# - ovmf: UEFI firmware for QEMU
RUN apk add --no-cache \
    qemu-system-x86_64 \
    qemu-img \
    qemu-audio-alsa \
    python3 \
    py3-pip \
    xorriso \
    curl \
    ovmf \
    bash \
    mtools \
    dosfstools \
    && pip3 install --no-cache-dir --break-system-packages pywinrm

# Create required directories
RUN mkdir -p /vm-images /isos /unattend /scripts /tmp /virtio-drivers

# Download VirtIO drivers for Windows Server 2022
RUN curl -L -o /tmp/virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso

# Copy scripts and configuration
COPY scripts/ /scripts/
COPY unattend/ /unattend/

# Make scripts executable
RUN chmod +x /scripts/*.sh

# Copy OVMF firmware to expected location
RUN cp /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/ 2>/dev/null || \
    mkdir -p /usr/share/edk2-ovmf/x64/ && \
    cp /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/ 2>/dev/null || \
    echo "OVMF firmware will be located at runtime"

# Build the Windows VM image during container build (optional)
# This step requires the Windows Server 2022 ISO to be mounted at runtime
ARG BUILD_VM=false
RUN if [ "$BUILD_VM" = "true" ]; then \
        echo "Building Windows VM image during container build..." && \
        /scripts/build-vm-image.sh; \
    else \
        echo "Skipping VM image build - will build at runtime if needed"; \
    fi

# Expose ports
# 2376: Docker daemon API
# 8086: Default application port (configurable via HOST_APP_PORT)
# 5901: VNC port (only when ENABLE_VNC=true)
EXPOSE 2376 8086 5901

# Health check to verify VM and Docker are running
HEALTHCHECK --interval=30s --timeout=10s --start-period=5m --retries=3 \
    CMD curl -f http://localhost:2376/version || exit 1

# Environment variables with defaults
ENV VM_RAM=4096 \
    VM_CPUS=2 \
    HOST_DOCKER_PORT=2376 \
    HOST_APP_PORT=8086 \
    ENABLE_VNC=false

# Labels for metadata
LABEL maintainer="AspireOne Development Team" \
      description="Windows VM Manager for building Windows containers on Linux" \
      version="1.0" \
      usage="docker run -p 2376:2376 -p 8086:8086 -v /path/to/windows.iso:/isos/windows-server-2022.iso:ro windows-vm-manager"

# Use vm-manager.sh as entrypoint
ENTRYPOINT ["/scripts/vm-manager.sh"]