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

    # Uhr synchronisieren bevor Zertifikate ausgestellt werden
    Write-Step "Systemuhr synchronisieren"
    try {
        w32tm /resync /force | Out-Null
        Write-OK "Uhr synchronisiert: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
    } catch {
        Write-Warn "Uhrsync fehlgeschlagen (kein NTP erreichbar?) - Zertifikat notBefore koennte in der Zukunft liegen"
    }

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

    # Sicherstellen dass CertSvc laeuft bevor wir Zertifikate anfordern
    Start-Sleep -Seconds 5
    $caExportPath = "C:\certs"
    New-Item -Path $caExportPath -ItemType Directory -Force | Out-Null

    # ---- CA-Zertifikat exportieren ----
    Write-Step "CA-Zertifikat exportieren"

    $caCert = Get-ChildItem Cert:\LocalMachine\Root |
        Where-Object { $_.Subject -like "*$($config.CAName)*" } |
        Select-Object -First 1

    if ($null -eq $caCert) {
        $caCert = Get-ChildItem Cert:\LocalMachine\CA |
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

    # ---- LDAPS-Zertifikat mit expliziten SANs ausstellen ----
    #
    # Warum explizit statt Auto-Enrollment?
    #   AD CS stellt beim DC-Enrollment automatisch ein Kerberos Authentication
    #   Zertifikat aus, dessen SANs nur den aktuellen FQDN enthalten.
    #   Java prueft bei LDAPS den Hostnamen gegen die SANs - schlaegt fehl wenn
    #   IIQ den DC unter einem anderen Namen erreicht (z.B. cluster-intern
    #   ad.seri.svc.cluster.local statt ad-resource.seri.sailpointdemo.com).
    #   Wir stellen daher ein eigenes Zertifikat mit allen bekannten SANs aus.
    #
    Write-Step "LDAPS-Zertifikat mit SANs ausstellen"

    # Alle SANs die das LDAPS-Zertifikat erhalten soll.
    # DNS-Namen: alle Hostnamen unter denen IIQ den DC ansprechen wird.
    # Erweiterbar ohne Rebuild des seri-iiq Images - nur Windows-Image neu bauen.
    $ldapsSanDns = @(
        # Externer FQDN (sailpointdemo.com Domain)
        "$($config.ComputerName).$($config.DomainName)",   # ad-resource.seri.sailpointdemo.com
        "*.$($config.DomainName)",                          # *.seri.sailpointdemo.com (Wildcard)
        # Kubernetes cluster-intern
        "windows-ad.seri.svc.cluster.local",                # Service FQDN im seri Namespace
        "windows-ad",                                        # Kurzname
        # Hostname ohne Domain (NetBIOS-kompatibel)
        $config.ComputerName                                 # ad-resource
    )

    # INF-Datei fuer certreq - definiert Zertifikatsanforderung mit SANs
    $sanEntries = ($ldapsSanDns | ForEach-Object { "dns=$_" }) -join "&"

    $infContent = @"
[Version]
Signature="`$Windows NT`$"

[NewRequest]
Subject          = "CN=$($config.ComputerName).$($config.DomainName)"
KeySpec          = 1
KeyLength        = 2048
Exportable       = TRUE
MachineKeySet    = TRUE
SMIME            = FALSE
PrivateKeyArchive = FALSE
UserProtected    = FALSE
UseExistingKeySet = FALSE
ProviderName     = "Microsoft RSA SChannel Cryptographic Provider"
ProviderType     = 12
RequestType      = CMC
KeyUsage         = 0xa0
HashAlgorithm    = SHA256

[EnhancedKeyUsageExtension]
OID = 1.3.6.1.5.5.7.3.1  ; Server Authentication
OID = 1.3.6.1.5.5.7.3.2  ; Client Authentication

[Extensions]
; Subject Alternative Names
2.5.29.17 = "{text}"
_continue_ = "$sanEntries"

[RequestAttributes]
CertificateTemplate = WebServer
"@

    $infPath = "$caExportPath\ldaps-request.inf"
    $reqPath = "$caExportPath\ldaps-request.req"
    $crtPath = "$caExportPath\ldaps.crt"
    $rspPath = "$caExportPath\ldaps.rsp"

    [System.IO.File]::WriteAllText($infPath, $infContent, [System.Text.Encoding]::ASCII)

    # Zertifikatsanforderung erstellen
    $certreqNew = certreq -new -machine -q $infPath $reqPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "certreq -new Fehler (ExitCode $LASTEXITCODE): $certreqNew"
    } else {
        Write-OK "Zertifikatsanforderung erstellt: $reqPath"
    }

    # Bei der lokalen CA einreichen und sofort ausstellen
    $caName = "$($config.ComputerName)\$($config.CAName)"
    $certreqSubmit = certreq -submit -q -config $caName $reqPath $crtPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "certreq -submit Fehler (ExitCode $LASTEXITCODE): $certreqSubmit"
    } else {
        Write-OK "Zertifikat ausgestellt: $crtPath"
    }

    # Zertifikat in den lokalen Zertifikatstore importieren (damit NTDS es findet)
    $certreqAccept = certreq -accept -machine -q $crtPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "certreq -accept Fehler (ExitCode $LASTEXITCODE): $certreqAccept"
    } else {
        Write-OK "Zertifikat in LocalMachine\My importiert"
    }

    # ---- Private Key fuer IQService-Dienstkonto zugaenglich machen ----
    # IQService laeuft als adadmin - dieser Account braucht Lesezugriff auf den
    # Private Key des WebServer-Zertifikats (certreq erstellt Keys nur fuer SYSTEM/Admins).
    Write-Step "Private Key fuer IQService-Dienstkonto freigeben"
    $webCert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object {
            $_.Subject -like "*$($config.ComputerName)*" -and
            $_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.1" -and
            -not ($_.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.17" } |
                  ForEach-Object { $_.Format($false) } | Select-String "DS Object Guid")
        } |
        Sort-Object NotBefore -Descending |
        Select-Object -First 1

    if ($webCert) {
        try {
            $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($webCert)
            $keyPath = [System.IO.Path]::Combine(
                $env:ProgramData, "Microsoft\Crypto\RSA\MachineKeys", $rsa.Key.UniqueName)
            $acl = Get-Acl $keyPath
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "$($config.DomainNetBIOS)\adadmin", "Read", "Allow")
            $acl.AddAccessRule($rule)
            Set-Acl $keyPath $acl
            Write-OK "Private Key freigegeben: $keyPath"
            Write-OK "WebServer-Cert Thumbprint: $($webCert.Thumbprint)"
            Write-OK "WebServer-Cert Serial:     $($webCert.SerialNumber)"
        } catch {
            Write-Warn "Private Key Freigabe fehlgeschlagen: $_"
        }
    } else {
        Write-Warn "WebServer-Zertifikat nicht gefunden - Private Key Freigabe uebersprungen"
    }

    # ---- hosts-Eintrag fuer IQService DNS-Aufloesung ----
    # IQService laeuft auf dem DC selbst und versucht windows-ad.seri.svc.cluster.local
    # aufzuloesen - dieser Name ist nur innerhalb des Kubernetes-Clusters bekannt.
    # Der Eintrag leitet den Namen auf localhost (127.0.0.1) um, da der DC sich selbst ist.
    Write-Step "hosts-Eintrag fuer Kubernetes-DNS-Name setzen"
    $hostsPath = "C:\Windows\System32\drivers\etc\hosts"
    $hostsEntry = "127.0.0.1   windows-ad.seri.svc.cluster.local"
    $hostsContent = Get-Content $hostsPath -Raw
    if ($hostsContent -notmatch [regex]::Escape("windows-ad.seri.svc.cluster.local")) {
        Add-Content -Path $hostsPath -Value "`r`n$hostsEntry"
        Write-OK "hosts-Eintrag gesetzt: $hostsEntry"
    } else {
        Write-Skip "hosts-Eintrag windows-ad.seri.svc.cluster.local"
    }

    # Ausstehende Anforderungen in der CA genehmigen falls noetig
    # (bei EnterpriseRootCA mit WebServer-Template normalerweise automatisch)
    $pending = certutil -view -restrict "Disposition=9" -out "RequestID,CommonName" 2>&1
    if ($pending -match "RequestId") {
        Write-Warn "Offene CA-Anforderungen gefunden - bitte manuell genehmigen oder Template-Permissions pruefen"
        Write-Host $pending -ForegroundColor Yellow
    }

    # SANs im exportierten Zertifikat zur Verifikation ausgeben
    Write-Step "Verifikation: SANs im ausgestellten LDAPS-Zertifikat"
    $ldapsCert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -like "*$($config.ComputerName)*" -and $_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.1" } |
        Sort-Object NotBefore -Descending |
        Select-Object -First 1

    if ($ldapsCert) {
        $sanExt = $ldapsCert.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.17" }
        if ($sanExt) {
            Write-OK "SANs im LDAPS-Zertifikat:"
            $sanExt.Format($true) -split "`n" | Where-Object { $_ -ne "" } | ForEach-Object {
                Write-Host "    $_" -ForegroundColor White
            }
        }
        Write-OK "Gueltig bis: $($ldapsCert.NotAfter)"
    } else {
        Write-Warn "LDAPS-Zertifikat nicht im Store gefunden - NTDS-Neustart abwarten"
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
    Write-Host "CA-Zertifikat   : C:\certs\ca.cer  (→ seri-iiq Truststore)" -ForegroundColor White
    Write-Host "CA Base64       : C:\certs\ca.crt.b64" -ForegroundColor White
    Write-Host "LDAPS-Cert INF  : C:\certs\ldaps-request.inf" -ForegroundColor White
    Write-Host "LDAPS-Cert CRT  : C:\certs\ldaps.crt" -ForegroundColor White
    Write-Host ""
    Write-Host "LDAPS SANs:" -ForegroundColor Cyan
    foreach ($san in $ldapsSanDns) {
        Write-Host "    dns=$san" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "RDP             : Port 3389, NLA deaktiviert" -ForegroundColor White
    Write-Host "LDAPS           : Port 636" -ForegroundColor White
    Write-Host ""
    Write-Host "NAECHSTE SCHRITTE:" -ForegroundColor Cyan
    Write-Host "  1. VirtIO Treiber in System32\drivers pruefen (Warnungen oben)" -ForegroundColor White
    Write-Host "  2. Windows Updates installieren" -ForegroundColor White
    Write-Host "  3. C:\certs\ca.cer auf Synology NAS kopieren (fuer seri-iiq Image-Build)" -ForegroundColor White
    Write-Host "  4. VM herunterfahren: Stop-Computer -Force" -ForegroundColor White
    Write-Host "  5. Image komprimieren und auf Synology hochladen" -ForegroundColor White
    Write-Host "  6. ArgoCD sync: argocd app sync windows-ad" -ForegroundColor White
    Write-Host "  7. Phase 4 ausfuehren: .\setup-ad-dc.ps1 -Phase 4" -ForegroundColor White
    Write-Host ""
    Write-Warn "Nur ca.cer wird im seri-iiq Image-Build benoetigt (keytool Import)!"
    Write-Warn "Das LDAPS-Cert (ldaps.crt) bleibt im Windows-Image - nicht exportieren."
    Write-Host ""
    Write-Warn "CA-Zertifikat als Kubernetes Secret speichern (optional, fuer Init-Jobs):"
    Write-Warn "kubectl create secret generic windows-ad-ca --from-file=ca.crt=ca.cer -n windows-ad"
}

# ============================================================
# PHASE 4: IQService-Zertifikat registrieren
# Muss nach Phase 3 ausgefuehrt werden sobald IQService installiert ist.
# Idempotent: kann wiederholt werden.
# ============================================================
if ($Phase -eq 4) {
    Write-Step "Phase 4: IQService-Zertifikat registrieren"

    $iqServiceName = "IQService-IIQ"
    $iqServiceExe  = "C:\SailPoint\IQService-IIQ\IQService.exe"

    # IQService installiert?
    $svc = Get-Service -Name $iqServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Warn "Service '$iqServiceName' nicht gefunden - bitte IQService zunaechst installieren."
        exit 1
    }

    # WebServer-Cert mit SANs finden (kein 'DS Object Guid' = kein Auto-Enrolled-DC-Cert)
    Write-Step "WebServer-Zertifikat mit cluster-SANs suchen"
    $webCert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object {
            $_.Subject -like "*$($config.ComputerName)*" -and
            $_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.1" -and
            -not ($_.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.17" } |
                  ForEach-Object { $_.Format($false) } | Select-String "DS Object Guid")
        } |
        Sort-Object NotBefore -Descending |
        Select-Object -First 1

    if ($null -eq $webCert) {
        Write-Warn "Kein WebServer-Zertifikat gefunden - Phase 3 zunaechst ausfuehren."
        exit 1
    }

    Write-OK "Gefunden: $($webCert.Thumbprint) / NotBefore: $($webCert.NotBefore)"
    $sanExt = $webCert.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.17" }
    if ($sanExt) {
        Write-OK "SANs: $($sanExt.Format($false))"
    }

    # Private Key fuer adadmin zugaenglich machen (idempotent)
    Write-Step "Private Key fuer $($config.DomainNetBIOS)\adadmin freigeben"
    try {
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($webCert)
        $keyPath = [System.IO.Path]::Combine(
            $env:ProgramData, "Microsoft\Crypto\RSA\MachineKeys", $rsa.Key.UniqueName)
        $acl = Get-Acl $keyPath
        $existingRule = $acl.Access | Where-Object {
            $_.IdentityReference -like "*adadmin*" -and $_.FileSystemRights -match "Read"
        }
        if ($null -eq $existingRule) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "$($config.DomainNetBIOS)\adadmin", "Read", "Allow")
            $acl.AddAccessRule($rule)
            Set-Acl $keyPath $acl
            Write-OK "Zugriffsregel gesetzt: $keyPath"
        } else {
            Write-Skip "Zugriffsregel fuer adadmin"
        }
    } catch {
        Write-Warn "Private Key Freigabe: $_"
    }

    # IQService auf dieses Zertifikat festlegen via Serial Number
    # Verhindert dass IQService beim naechsten Start ein Auto-Enrolled-Cert waehlt
    Write-Step "IQService-Zertifikat per Serial Number fixieren"
    $serial = $webCert.SerialNumber
    Write-Host "  Serial: $serial" -ForegroundColor White
    & $iqServiceExe -m "SN:$serial"
    Write-OK "IQService konfiguriert: SN:$serial"

    # IQService neu starten
    Write-Step "IQService-IIQ neu starten"
    Restart-Service -Name $iqServiceName -Force
    Start-Sleep -Seconds 5
    $svcStatus = (Get-Service -Name $iqServiceName).Status
    Write-OK "IQService Status: $svcStatus"

    Write-Host ""
    Write-Separator
    Write-Host "PHASE 4 ABGESCHLOSSEN" -ForegroundColor Green
    Write-Separator
    Write-Host "IQService-Zertifikat : $($webCert.Thumbprint)" -ForegroundColor White
    Write-Host "Serial Number        : $serial" -ForegroundColor White
    Write-Host "Gueltig bis          : $($webCert.NotAfter)" -ForegroundColor White
    Write-Host ""
    Write-Host "WICHTIG: IIQ Application-Konfiguration (Active Directory):" -ForegroundColor Cyan
    Write-Host "  Den bevorzugten DC explizit setzen, damit IIQ nicht per DNS-Discovery" -ForegroundColor White
    Write-Host "  einen fuer den Cluster unaufloeslichen Hostnamen bekommt:" -ForegroundColor White
    Write-Host ""
    Write-Host "  <entry key=""servers"">" -ForegroundColor White
    Write-Host "    <value><List><String>windows-ad.seri.svc.cluster.local</String></List></value>" -ForegroundColor White
    Write-Host "  </entry>" -ForegroundColor White
    Write-Host ""
    Write-Warn "Ohne 'servers'-Eintrag liefert IQService per Get-ADDomainController den"
    Write-Warn "Namen 'ad-resource.seri.sailpointdemo.com' - unbekannt im Kubernetes-Cluster!"
}
