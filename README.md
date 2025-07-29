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
# Start WCB (may take 120+ seconds to fully connect to docker)
docker run -d -p 2376:2376 -p 8888:8888 --device /dev/kvm:/dev/kvm --name wcb ghcr.io/iedge-au/wcb:latest

# Create Docker context
docker context create wcb --docker "host=tcp://localhost:2376"

# Use Windows containers
docker -c wcb run --rm hello-world:nanoserver
```

### Full Configuration

```bash
# All options
docker run -d \
  -p 2376:2376 \
  -p 8888:8888 \
  -p 5901:5901 \
  -e VM_RAM=8192 \
  -e VM_CPUS=4 \
  -e ENABLE_VNC=true \
  --device /dev/kvm:/dev/kvm \
  -v "$(pwd)/vm-images:/vm-images" \
  -v "$(pwd)/isos:/isos:ro" \
  --name wcb \
  ghcr.io/iedge-au/wcb:latest
```

### Docker Context Methods

```bash
# Method 1: Named context (recommended)
docker context create wcb --docker "host=tcp://localhost:2376"
docker --context wcb run -d -p 8080:80 mcr.microsoft.com/windows/servercore/iis

# Method 2: Direct host flag
docker -H tcp://localhost:2376 run -d -p 8080:80 mcr.microsoft.com/windows/servercore/iis

# Method 3: Set as default
docker context use wcb
docker run -d -p 8080:80 mcr.microsoft.com/windows/servercore/iis  # Now uses WCB automatically
```

### Port Access

```bash
# Container ports bind to VM, access via host port 8888
docker -c wcb run -d -p 8080:80 my-iis-app
curl http://localhost:8888  # Access your Windows container
```

## Configuration

| Environment Variable | Default | Description                    |
| -------------------- | ------- | ------------------------------ |
| `VM_RAM`             | `4096`  | Memory allocation (MB)         |
| `VM_CPUS`            | `2`     | CPU core count                 |
| `ENABLE_VNC`         | `false` | Enable VNC access on port 5901 |

| Port   | Purpose            | Required |
| ------ | ------------------ | -------- |
| `2376` | Docker API         | Yes      |
| `8888` | Application access | Yes      |
| `5901` | VNC display        | Optional |

| Volume Mount | Purpose               | Required    |
| ------------ | --------------------- | ----------- |
| `/vm-images` | Persist VM images     | Recommended |
| `/isos`      | Custom Windows ISO    | Optional    |
| `/dev/kvm`   | Hardware acceleration | Recommended |

**System Requirements:**

- 8GB+ RAM, 10GB+ disk space
- Hardware virtualization (`/dev/kvm` recommended)
- x86_64 Linux with Docker

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

**Development:**

```bash
# Clone repository
git clone https://github.com/iedge-au/wcb.git
cd wcb

# Download Windows Server 2022 evaluation ISO
# Place in isos/windows-server-2022.iso

# Build container image
docker build -t wcb .

# Run with custom specs
docker run -d -p 2376:2376 -p 8888:8888 \
  -e VM_RAM=8192 -e VM_CPUS=4 \
  --device /dev/kvm:/dev/kvm wcb
```
