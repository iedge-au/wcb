# Windows Container Bridge (WCB)

> _Build and run Windows containers from any Linux environment_

## Overview

Windows Container Bridge enables Linux developers to build and test native Windows containers locally using standard Docker commands. It provides a Windows Server Core virtual machine with Docker Engine pre-installed, running inside a Linux Docker container.

**Why WCB?**

- Cross-platform Windows container development
- No dedicated Windows environment required
- Standard Docker workflow and tooling
- Automated Windows license management

## Usage

### Quick Start

```bash
# Start WCB (requires privileged access for bridge networking)
docker run -d --privileged --network host -v /dev/kvm:/dev/kvm --name wcb ghcr.io/iedge-au/wcb:latest

# Create Docker context (VM available at static IP)
docker context create wcb --docker host=tcp://172.17.0.100:2376

# Use Windows containers
docker -c wcb run --rm hello-world:nanoserver
```

### Configuration Options

```bash
# Custom VM specs and VNC access
docker run -d \
  --privileged --network host \
  -e VM_RAM=8192 \
  -e VM_CPUS=4 \
  -e ENABLE_VNC=true \
  -v /dev/kvm:/dev/kvm \
  --name wcb \
  ghcr.io/iedge-au/wcb:latest
```

### Docker Context Methods

```bash
# Method 1: Named context (recommended)
docker context create wcb --docker host=tcp://172.17.0.100:2376
docker --context wcb run -d -p 8080:80 mcr.microsoft.com/windows/servercore/iis

# Method 2: Direct host flag
docker -H tcp://172.17.0.100:2376 run -d -p 8080:80 mcr.microsoft.com/windows/servercore/iis

# Method 3: Set as default
docker context use wcb
docker run -d -p 8080:80 mcr.microsoft.com/windows/servercore/iis  # Now uses WCB automatically
```

### Port Access

```bash
# Container ports are directly accessible at the VM IP
docker -c wcb run -d -p 8080:80 my-iis-app
curl http://172.17.0.100:8080  # Direct access to your Windows container
```

## System Requirements

- **Minimum**: 4GB RAM, 10GB disk space
- **Recommended**: 8GB+ RAM, hardware virtualization (`/dev/kvm`)
- **Platform**: x86_64 Linux with Docker
- **Privileges**: `--privileged --network host` (required for bridge networking)

## Advanced Configuration

### Environment Variables

| Variable     | Default | Description                    |
| ------------ | ------- | ------------------------------ |
| `VM_RAM`     | `4096`  | Memory allocation (MB)         |
| `VM_CPUS`    | `2`     | CPU core count                 |
| `ENABLE_VNC` | `false` | Enable VNC access on port 5901 |

### NAT Mode Fallback

If bridge networking is unavailable, WCB automatically falls back to NAT mode:

```bash
# NAT mode (automatic fallback)
docker run -d -p 2376:2376 -p 8888:8888 -v /dev/kvm:/dev/kvm --name wcb ghcr.io/iedge-au/wcb:latest

# Create context for NAT mode
docker context create wcb --docker host=tcp://localhost:2376

# Container access via forwarded port
docker -c wcb run -d -p 8080:80 my-app
curl http://localhost:8888  # Access via NAT forwarding
```

| Port   | Purpose            | NAT Mode |
| ------ | ------------------ | -------- |
| `2376` | Docker API         | Required |
| `8888` | Application access | Required |
| `5901` | VNC display        | Optional |

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development

```bash
# Clone repository
git clone https://github.com/iedge-au/wcb.git
cd wcb

# Download Windows Server 2022 evaluation ISO
# Place in isos/windows-server-2022.iso

# Build container image
docker build -t wcb .

# Run with development volumes
docker run -d --privileged --network host \
  -e VM_RAM=8192 -e VM_CPUS=4 \
  -v /dev/kvm:/dev/kvm \
  -v "$(pwd)/vm-images:/vm-images" \
  -v "$(pwd)/isos:/isos:ro" \
  --name wcb-dev wcb
```

| Volume Mount | Purpose               | Development Use |
| ------------ | --------------------- | --------------- |
| `/vm-images` | Persist VM images     | Building/testing |
| `/isos`      | Custom Windows ISO    | Custom builds |
