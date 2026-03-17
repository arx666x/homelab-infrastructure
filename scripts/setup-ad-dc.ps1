#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows Server 2025 AD DC Setup fuer SERI KubeVirt Deployment

.DESCRIPTION
    Phase 1: Computername + Firewall + Neustart
    Phase 2: AD DS Forest erstellen (automatischer Neustart)
    Phase 3: CA + LDAPS + RDP + Service Account (idempotent - kann wiederholt werden)

.EXAMPLE
    .\setup-ad-dc.ps1 -Phase 1
    (Neustart abwarten)
    .\setup-ad-dc.ps1 -Phase 2
    (Neustart abwarten - passiert automatisch)
    .\setup-ad-dc.ps1 -Phase 3

.NOTES
    Idempotent: Phase 3 kann mehrfach ausgefuehrt werden ohne Fehler.
    Alle Install-Befehle pruefen vorab ob Komponente bereits vorhanden ist.
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet(1,2,3)]
    [int]$Phase,

    [switch]$AutoContinue
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

# ============================================================
# Konfiguration
# ============================================================
$config = @{
    ComputerName     = "ad-resource"
    DomainName       = "seri.sailpointdemo.com"
    DomainNetBIOS    = "SERI"
    SafeModePassword = "SafeMode@SERI2025!"
    CAName           = "SERI-Root-CA"
    StaticIP         = ""
    PrefixLength     = 24
    DefaultGateway   = ""
    ScriptPath       = $MyInvocation.MyCommand.Path
}

# ============================================================
# Hilfsfunktionen
# ============================================================
function Write-Step { param([string]$msg)
    Write-Host ""
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] === $msg ===" -ForegroundColor Cyan
}

function Write-OK { param([string]$msg)
    Write-Host "[OK] $msg" -ForegroundColor Green
}

function Write-Warn { param([string]$msg)
    Write-Host "[!!] $msg" -ForegroundColor Yellow
}

function Write-Skip { param([string]$msg)
    Write-Host "[--] $msg (bereits vorhanden, uebersprungen)" -ForegroundColor DarkGray
}

function Write-Separator {
    Write-Host ("=" * 60) -ForegroundColor Green
}

function Register-NextPhaseTask { param([int]$nextPhase)
    if (-not $AutoContinue) { return }
    $action = New-ScheduledTaskAction `
        -Execute "PowerShell.exe" `
        -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$($config.ScriptPath)`" -Phase $nextPhase -AutoContinue"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    Register-ScheduledTask -TaskName "AD-Setup-Phase$nextPhase" `
        -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-OK "AutoContinue Task fuer Phase $nextPhase registriert"
}

function Remove-PhaseTask { param([int]$p)
    if (Get-ScheduledTask -TaskName "AD-Setup-Phase$p" -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName "AD-Setup-Phase$p" -Confirm:$false
    }
}

# ============================================================
# PHASE 1: Computername + Netzwerk + Firewall
# ============================================================
if ($Phase -eq 1) {
    Write-Step "Phase 1: Computername und Netzwerk konfigurieren"
    Remove-PhaseTask -p 1

    Write-Step "Firewall-Regeln setzen"
    $ports = @(
        @{Name="AD-LDAP";     Port=389;  P="TCP"},
        @{Name="AD-LDAPS";    Port=636;  P="TCP"},
        @{Name="AD-GC";       Port=3268; P="TCP"},
        @{Name="AD-GC-SSL";   Port=3269; P="TCP"},
        @{Name="AD-Kerb-TCP"; Port=88;   P="TCP"},
        @{Name="AD-Kerb-UDP"; Port=88;   P="UDP"},
        @{Name="AD-DNS-TCP";  Port=53;   P="TCP"},
        @{Name="AD-DNS-UDP";  Port=53;   P="UDP"},
        @{Name="AD-RPC";      Port=135;  P="TCP"},
        @{Name="AD-SMB";      Port=445;  P="TCP"},
        @{Name="AD-Custom";   Port=6060; P="TCP"},
        @{Name="AD-RDP";      Port=3389; P="TCP"}
    )
    foreach ($r in $ports) {
        New-NetFirewallRule -DisplayName $r.Name -Direction Inbound `
            -Protocol $r.P -LocalPort $r.Port -Action Allow `
            -ErrorAction SilentlyContinue | Out-Null
    }
    Write-OK "Firewall-Regeln gesetzt (inkl. RDP Port 3389, Port 6060)"

    if ($config.StaticIP -ne "") {
        Write-Step "Statische IP setzen: $($config.StaticIP)"
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
        $adapter | New-NetIPAddress -IPAddress $config.StaticIP `
            -PrefixLength $config.PrefixLength `
            -DefaultGateway $config.DefaultGateway | Out-Null
        $adapter | Set-DnsClientServerAddress -ServerAddresses "127.0.0.1" | Out-Null
        Write-OK "Statische IP gesetzt"
    }

    Write-Step "Computername setzen: $($config.ComputerName)"
    if ($env:COMPUTERNAME -eq $config.ComputerName) {
        Write-Skip "Computername bereits korrekt"
    } else {
        Rename-Computer -NewName $config.ComputerName -Force
        Write-OK "Umbenannt nach: $($config.ComputerName)"
    }

    Register-NextPhaseTask -nextPhase 2

    Write-Host ""
    Write-Host "Phase 1 abgeschlossen. Bitte neu starten, dann ausfuehren:" -ForegroundColor Yellow
    Write-Host "  .\setup-ad-dc.ps1 -Phase 2" -ForegroundColor White

    if ($AutoContinue) {
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    }
}

# ============================================================
# PHASE 2: AD DS + Forest
# ============================================================
if ($Phase -eq 2) {
    Write-Step "Phase 2: AD DS installieren und Forest erstellen"
    Remove-PhaseTask -p 2

    if ($env:COMPUTERNAME -ne $config.ComputerName) {
        Write-Host "[FEHLER] Computername ist '$($env:COMPUTERNAME)', erwartet '$($config.ComputerName)'" -ForegroundColor Red
        Write-Host "Bitte zuerst Phase 1 ausfuehren." -ForegroundColor Red
        exit 1
    }

    Write-Step "AD DS und DNS Features installieren"
    $result = Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools
    if (-not $result.Success) {
        Write-Host "[FEHLER] Feature-Installation fehlgeschlagen" -ForegroundColor Red
        exit 1
    }
    Write-OK "Features installiert"

    Write-Step "AD Forest erstellen: $($config.DomainName)"
    $safeModePass = ConvertTo-SecureString $config.SafeModePassword -AsPlainText -Force

    Import-Module ADDSDeployment

    Install-ADDSForest `
        -DomainName                    $config.DomainName `
        -DomainNetBIOSName             $config.DomainNetBIOS `
        -DomainMode                    "WinThreshold" `
        -ForestMode                    "WinThreshold" `
        -SafeModeAdministratorPassword $safeModePass `
        -InstallDns:$true `
        -CreateDnsDelegation:$false `
        -DatabasePath                  "C:\Windows\NTDS" `
        -LogPath                       "C:\Windows\NTDS" `
        -SysvolPath                    "C:\Windows\SYSVOL" `
        -NoRebootOnCompletion:$false `
        -Force:$true

    Register-NextPhaseTask -nextPhase 3

    Write-Host ""
    Write-Host "Phase 2: Forest-Erstellung gestartet, System startet neu." -ForegroundColor Yellow
    Write-Host "Danach ausfuehren:" -ForegroundColor Yellow
    Write-Host "  .\setup-ad-dc.ps1 -Phase 3" -ForegroundColor White
}

# ============================================================
# PHASE 3: CA + LDAPS + RDP + Service Account
# Idempotent: kann mehrfach ausgefuehrt werden
# ============================================================
if ($Phase -eq 3) {
    Write-Step "Phase 3: CA, LDAPS, RDP und Service Account konfigurieren"
    Remove-PhaseTask -p 3

    # AD erreichbar?
    try {
        $domain = Get-ADDomain
        Write-OK "AD Domain aktiv: $($domain.DNSRoot)"
    } catch {
        Write-Host "[FEHLER] AD nicht erreichbar. Phase 2 vollstaendig abgeschlossen?" -ForegroundColor Red
        exit 1
    }

    # ---- CA installieren (idempotent) ----
    Write-Step "Certificate Authority pruefen / installieren"
    $caFeature = Get-WindowsFeature -Name ADCS-Cert-Authority
    if ($caFeature.InstallState -ne "Installed") {
        Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools | Out-Null
        Write-OK "ADCS Feature installiert"
    } else {
        Write-Skip "ADCS Feature"
    }

    # CA konfigurieren falls noch nicht geschehen
    $caRunning = $false
    try {
        $caService = Get-Service -Name CertSvc -ErrorAction SilentlyContinue
        $caRunning = ($null -ne $caService -and $caService.Status -eq "Running")
    } catch {}

    if (-not $caRunning) {
        try {
            Install-AdcsCertificationAuthority `
                -CAType              EnterpriseRootCA `
                -CACommonName        $config.CAName `
                -KeyLength           4096 `
                -HashAlgorithmName   SHA256 `
                -ValidityPeriod      Years `
                -ValidityPeriodUnits 10 `
                -Force | Out-Null
            Write-OK "CA konfiguriert: $($config.CAName)"
        } catch {
            if ($_.Exception.Message -like "*already installed*") {
                Write-Skip "CA bereits konfiguriert"
            } else {
                Write-Warn "CA Konfiguration: $_"
            }
        }
    } else {
        Write-Skip "CA laeuft bereits (CertSvc: Running)"
    }

    # CA-Zertifikat exportieren
    $caExportPath = "C:\certs"
    New-Item -Path $caExportPath -ItemType Directory -Force | Out-Null
    Start-Sleep -Seconds 5

    $caCert = Get-ChildItem Cert:\LocalMachine\CA |
        Where-Object { $_.Subject -like "*$($config.CAName)*" } |
        Select-Object -First 1

    if ($null -eq $caCert) {
        $caCert = Get-ChildItem Cert:\LocalMachine\Root |
            Where-Object { $_.Subject -like "*$($config.CAName)*" } |
            Select-Object -First 1
    }

    if ($caCert) {
        Export-Certificate -Cert $caCert -FilePath "$caExportPath\ca.cer" -Type CERT | Out-Null
        $certBytes  = [System.IO.File]::ReadAllBytes("$caExportPath\ca.cer")
        $certBase64 = [System.Convert]::ToBase64String($certBytes)
        [System.IO.File]::WriteAllText("$caExportPath\ca.crt.b64", $certBase64)
        Write-OK "CA-Zertifikat exportiert: $caExportPath\ca.cer"
    } else {
        Write-Warn "CA-Zertifikat nicht im Store gefunden - nach Neustart erneut pruefen"
    }

    # ---- NTDS neu starten damit LDAPS aktiv wird ----
    Write-Step "NTDS neu starten (aktiviert LDAPS mit CA-Zertifikat)"
    try {
        Restart-Service -Name "NTDS" -Force
        Start-Sleep -Seconds 15
        Write-OK "NTDS neu gestartet"
    } catch {
        Write-Warn "NTDS-Neustart: $_"
        Start-Sleep -Seconds 20
    }

    $ldapsTest = Test-NetConnection -ComputerName localhost -Port 636 -WarningAction SilentlyContinue
    if ($ldapsTest.TcpTestSucceeded) {
        Write-OK "LDAPS Port 636 aktiv"
    } else {
        Write-Warn "LDAPS noch nicht aktiv - ggf. DC neu starten"
    }

    # ---- LDAP Signing + Channel Binding ----
    Write-Step "LDAP Signing und Channel Binding haerten"
    Set-ItemProperty `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" `
        -Name "LDAPServerIntegrity" -Value 2 -Type DWord
    Set-ItemProperty `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" `
        -Name "LdapEnforceChannelBinding" -Value 2 -Type DWord
    Write-OK "LDAP Signing: Required / Channel Binding: Always"

    # ---- DNS Forwarder ----
    Write-Step "DNS Forwarder setzen"
    Add-DnsServerForwarder -IPAddress "8.8.8.8","8.8.4.4" -ErrorAction SilentlyContinue
    Write-OK "DNS Forwarder: 8.8.8.8, 8.8.4.4"

    # ---- RDP aktivieren und korrekt konfigurieren ----
    Write-Step "RDP aktivieren"

    # RDP grundsaetzlich aktivieren
    Set-ItemProperty `
        -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" -Value 0 -Type DWord

    # NLA deaktivieren - WICHTIG: ohne diese Werte horcht TermService
    # zwar aber der RDP-Stack bindet sich nicht an Port 3389!
    Set-ItemProperty `
        -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
        -Name "SecurityLayer" -Value 0 -Type DWord
    Set-ItemProperty `
        -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
        -Name "UserAuthentication" -Value 0 -Type DWord

    # TermService neu starten damit neue Registry-Werte aktiv werden
    Set-Service -Name TermService -StartupType Automatic
    Stop-Service -Name TermService -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Start-Service -Name TermService
    Start-Sleep -Seconds 5

    # Pruefen ob Port 3389 offen ist
    $rdpTest = Test-NetConnection -ComputerName localhost -Port 3389 -WarningAction SilentlyContinue
    if ($rdpTest.TcpTestSucceeded) {
        Write-OK "RDP Port 3389 aktiv"
    } else {
        Write-Warn "RDP Port 3389 nicht aktiv - TermService erneut neu starten"
        Restart-Service -Name TermService -Force
        Start-Sleep -Seconds 5
    }

    # Firewall-Regel fuer RDP (idempotent)
    $rdpRule = Get-NetFirewallRule -DisplayName "AD-RDP" -ErrorAction SilentlyContinue
    if ($null -eq $rdpRule) {
        New-NetFirewallRule -DisplayName "AD-RDP" -Direction Inbound `
            -Protocol TCP -LocalPort 3389 -Action Allow | Out-Null
        Write-OK "Firewall-Regel AD-RDP erstellt"
    } else {
        Write-Skip "Firewall-Regel AD-RDP"
    }

    # ---- Service Account (idempotent) ----
    Write-Step "LDAP Service Account pruefen / erstellen"

    $ouPath  = "DC=seri,DC=sailpointdemo,DC=com"
    $svcPass = ConvertTo-SecureString "ServiceAcc@SERI2025!" -AsPlainText -Force

    try {
        $ouExists = Get-ADOrganizationalUnit -Filter "Name -eq 'ServiceAccounts'" -ErrorAction SilentlyContinue
        if ($null -eq $ouExists) {
            New-ADOrganizationalUnit -Name "ServiceAccounts" -Path $ouPath `
                -ProtectedFromAccidentalDeletion $true
            Write-OK "OU ServiceAccounts erstellt"
        } else {
            Write-Skip "OU ServiceAccounts"
        }
    } catch {}

    $existingUser = Get-ADUser -Filter "SamAccountName -eq 'ldap-service'" -ErrorAction SilentlyContinue
    if ($null -eq $existingUser) {
        New-ADUser `
            -Name                "ldap-service" `
            -SamAccountName      "ldap-service" `
            -UserPrincipalName   "ldap-service@$($config.DomainName)" `
            -AccountPassword     $svcPass `
            -Enabled             $true `
            -PasswordNeverExpires $true `
            -CannotChangePassword $true `
            -Path                "OU=ServiceAccounts,$ouPath" `
            -Description         "Service Account fuer LDAPS aus Kubernetes"
        Write-OK "Service Account erstellt: ldap-service@$($config.DomainName)"
    } else {
        Write-Skip "Service Account ldap-service"
    }

    # ---- VirtIO Treiber pruefen ----
    Write-Step "VirtIO Treiber pruefen"
    $vioscsiSys = Test-Path "C:\Windows\System32\drivers\vioscsi.sys"
    $vioscsiPF  = Test-Path "C:\Program Files\Virtio-Win\Vioscsi\vioscsi.sys"
    $netkvmSys  = Test-Path "C:\Windows\System32\drivers\netkvm.sys"
    $netkvmPF   = Test-Path "C:\Program Files\Virtio-Win\Network\netkvm.sys"

    if ($vioscsiSys) {
        Write-OK "VirtIO SCSI: C:\Windows\System32\drivers\vioscsi.sys"
    } elseif ($vioscsiPF) {
        Write-Warn "VirtIO SCSI nur in Program Files - manuell kopieren:"
        Write-Host "  Copy-Item 'C:\Program Files\Virtio-Win\Vioscsi\vioscsi.sys' 'C:\Windows\System32\drivers\'" -ForegroundColor White
    } else {
        Write-Warn "VirtIO SCSI Treiber nicht gefunden!"
    }

    if ($netkvmSys) {
        Write-OK "VirtIO Network: C:\Windows\System32\drivers\netkvm.sys"
    } elseif ($netkvmPF) {
        Write-Warn "VirtIO Network nur in Program Files - manuell kopieren:"
        Write-Host "  Copy-Item 'C:\Program Files\Virtio-Win\Network\netkvm.sys' 'C:\Windows\System32\drivers\'" -ForegroundColor White
    } else {
        Write-Warn "VirtIO Network Treiber nicht gefunden!"
    }

    # ---- Zusammenfassung ----
    Write-Host ""
    Write-Separator
    Write-Host "SETUP ABGESCHLOSSEN" -ForegroundColor Green
    Write-Separator
    Write-Host "Domain    : $($config.DomainName)" -ForegroundColor White
    Write-Host "NetBIOS   : $($config.DomainNetBIOS)" -ForegroundColor White
    Write-Host "Hostname  : $($config.ComputerName)" -ForegroundColor White
    Write-Host "CA Name   : $($config.CAName)" -ForegroundColor White
    Write-Host ""
    Write-Host "Service Account : ldap-service@$($config.DomainName)" -ForegroundColor White
    Write-Host "  Passwort      : ServiceAcc@SERI2025!  <-- AENDERN!" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "CA-Zertifikat   : C:\certs\ca.cer" -ForegroundColor White
    Write-Host "CA Base64       : C:\certs\ca.crt.b64" -ForegroundColor White
    Write-Host ""
    Write-Host "RDP             : Port 3389, NLA deaktiviert" -ForegroundColor White
    Write-Host "LDAPS           : Port 636" -ForegroundColor White
    Write-Host ""
    Write-Host "NAECHSTE SCHRITTE:" -ForegroundColor Cyan
    Write-Host "  1. VirtIO Treiber in System32\drivers pruefen (Warnungen oben)" -ForegroundColor White
    Write-Host "  2. Windows Updates installieren" -ForegroundColor White
    Write-Host "  3. C:\certs\ca.cer auf Synology NAS kopieren" -ForegroundColor White
    Write-Host "  4. VM herunterfahren: Stop-Computer -Force" -ForegroundColor White
    Write-Host "  5. Image komprimieren und auf Synology hochladen" -ForegroundColor White
    Write-Host "  6. ArgoCD sync: argocd app sync windows-ad" -ForegroundColor White
    Write-Host ""
    Write-Warn "CA-Zertifikat als Kubernetes Secret speichern!"
    Write-Warn "kubectl create secret generic windows-ad-ca --from-file=ca.crt=ca.cer -n windows-ad"
}
