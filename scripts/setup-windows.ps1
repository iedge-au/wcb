# Windows Server Core Post-Installation Setup Script
# This script configures Windows Server Core for Docker container development

param(
    [Parameter(Mandatory=$false)]
    [string]$LogFile = "C:\setup-log.txt"
)

# Function to log messages
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $logMessage
    Add-Content -Path $LogFile -Value $logMessage
}

# Function to test internet connectivity
function Test-InternetConnectivity {
    try {
        $result = Test-NetConnection -ComputerName "8.8.8.8" -Port 53 -InformationLevel Quiet
        return $result
    } catch {
        return $false
    }
}

# Main setup process
try {
    Write-Log "Starting Windows Server Core setup for Docker development"
    
    # Test internet connectivity
    Write-Log "Testing internet connectivity..."
    if (-not (Test-InternetConnectivity)) {
        Write-Log "WARNING: No internet connectivity detected. Some features may not work."
    } else {
        Write-Log "Internet connectivity confirmed"
    }
    
    # Configure PowerShell execution policy
    Write-Log "Configuring PowerShell execution policy..."
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force
    
    # Configure WinRM for remote management
    Write-Log "Configuring WinRM for remote management..."
    try {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck
        winrm quickconfig -q
        winrm set winrm/config/service/auth '@{Basic="true"}'
        winrm set winrm/config/client/auth '@{Basic="true"}'
        winrm set winrm/config/service '@{AllowUnencrypted="true"}'
        Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value true
        Write-Log "WinRM configuration completed"
    } catch {
        Write-Log "ERROR: Failed to configure WinRM: $($_.Exception.Message)"
    }
    
    # Configure Windows Firewall
    Write-Log "Configuring Windows Firewall..."
    try {
        # Enable firewall (but allow our required ports)
        Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
        
        # Allow WinRM
        New-NetFirewallRule -DisplayName "WinRM HTTP" -Direction Inbound -LocalPort 5985 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
        
        # Allow Docker API  
        New-NetFirewallRule -DisplayName "Docker API" -Direction Inbound -LocalPort 2376 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
        
        # Allow common application ports
        New-NetFirewallRule -DisplayName "HTTP" -Direction Inbound -LocalPort 80 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "HTTPS" -Direction Inbound -LocalPort 443 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "Custom App Port" -Direction Inbound -LocalPort 8080 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
        
        Write-Log "Firewall configuration completed"
    } catch {
        Write-Log "ERROR: Failed to configure firewall: $($_.Exception.Message)"
    }
    
    # Install Windows Containers feature
    Write-Log "Installing Windows Containers feature..."
    try {
        $feature = Install-WindowsFeature -Name Containers -IncludeManagementTools
        if ($feature.RestartNeeded -eq "Yes") {
            Write-Log "Windows Containers feature installed - restart required"
        } else {
            Write-Log "Windows Containers feature installed successfully"
        }
    } catch {
        Write-Log "ERROR: Failed to install Containers feature: $($_.Exception.Message)"
    }
    
    # Configure system settings for containerization
    Write-Log "Configuring system settings..."
    try {
        # Disable Windows Defender real-time protection for better performance
        # (This is acceptable for development environments)
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
        
        # Configure automatic logon (development convenience)
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoAdminLogon -Value 1
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultUserName -Value "developer"
        
        # Set timezone to UTC for consistency
        Set-TimeZone -Id "UTC" -ErrorAction SilentlyContinue
        
        Write-Log "System configuration completed"
    } catch {
        Write-Log "ERROR: Failed to configure system settings: $($_.Exception.Message)"
    }
    
    # Create setup completion marker
    Write-Log "Creating setup completion marker..."
    "Windows setup completed successfully at $(Get-Date)" | Out-File -FilePath "C:\setup-complete.txt" -Encoding ASCII
    
    Write-Log "Windows Server Core setup completed successfully"
    Write-Log "System is ready for Docker installation and container development"
    
} catch {
    Write-Log "FATAL ERROR: Setup failed: $($_.Exception.Message)"
    Write-Log "Stack trace: $($_.Exception.StackTrace)"
    exit 1
}

# Display system information
Write-Log "System Information:"
Write-Log "OS Version: $((Get-WmiObject -Class Win32_OperatingSystem).Caption)"
Write-Log "Total RAM: $([math]::Round((Get-WmiObject -Class Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)) GB"
Write-Log "Processor: $((Get-WmiObject -Class Win32_Processor).Name)"
Write-Log "Computer Name: $env:COMPUTERNAME"

Write-Log "Setup script execution completed"