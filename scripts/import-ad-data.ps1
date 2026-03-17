#Requires -RunAsAdministrator
<#
.SYNOPSIS
    AD-Datenimport für SERI-Umgebung
    Importiert OUs, Gruppen und User aus LDIF-Dateien
    Setzt Passwörter, legt adadmin-Account an und erstellt Shares.

.DESCRIPTION
    Die Tasks können einzeln oder alle zusammen ausgeführt werden.

    LDIF-Dateien werden im selben Verzeichnis wie das Skript erwartet,
    oder per Parameter angegeben.

.PARAMETER Task
    Welcher Task ausgeführt werden soll:
      All        - Alle Tasks der Reihe nach (Standard)
      ImportOUs  - Nur OUs importieren (seri-ou.ldif)
      ImportGrps - Nur Gruppen importieren (seri-groups.ldif)
      ImportUsers- Nur User importieren (seri-user.ldif)
      SetPasswd  - Nur Passwörter für alle User setzen
      CreateAdmin- Nur adadmin-Account anlegen/aktualisieren
      CreateShare- Nur Shares anlegen
      Cleanup    - Alles unterhalb von OU=demo,DC=seri,... löschen (User, Gruppen, OUs)

.PARAMETER LdifDir
    Verzeichnis mit den LDIF-Dateien (Standard: Skript-Verzeichnis)

.PARAMETER UserPassword
    Passwort für alle importierten User (Standard: User@SERI2025!)

.PARAMETER AdminPassword
    Passwort für adadmin und Administrator (Standard: Admin@SERI2025!)

.EXAMPLE
    # Alles in einem Durchgang
    .\import-ad-data.ps1

    # Nur User-Passwörter zurücksetzen
    .\import-ad-data.ps1 -Task SetPasswd

    # Shares neu anlegen
    .\import-ad-data.ps1 -Task CreateShare

    # LDIF-Dateien aus anderem Verzeichnis
    .\import-ad-data.ps1 -Task ImportUsers -LdifDir "C:\ldif"

    # Mit abweichendem Passwort
    .\import-ad-data.ps1 -Task All -UserPassword "MeinPasswort123!"

    # Demo-Daten bereinigen (alles unter OU=demo löschen)
    .\import-ad-data.ps1 -Task Cleanup

    # Cleanup ohne Rückfrage (z.B. für Scripting)
    .\import-ad-data.ps1 -Task Cleanup -Force
#>

param(
    [ValidateSet("All", "ImportOUs", "ImportGrps", "ImportUsers", "SetPasswd", "CreateAdmin", "CreateShare", "Cleanup")]
    [string]$Task = "All",

    [string]$LdifDir = $PSScriptRoot,

    [string]$UserPassword = "User@SERI2025!",

    [string]$AdminPassword = "Admin@SERI2025!",

    [switch]$Force  # Cleanup ohne Bestätigungsabfrage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ──────────────────────────────────────────────────────────────
# Hilfsfunktionen
# ──────────────────────────────────────────────────────────────

function Write-Step {
    param([string]$Message)
    Write-Host "`n$('─' * 60)" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "$('─' * 60)" -ForegroundColor Cyan
}

function Write-OK   { param([string]$m) Write-Host "  [OK]  $m" -ForegroundColor Green  }
function Write-Skip { param([string]$m) Write-Host "  [--]  $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "  [ERR] $m" -ForegroundColor Red    }
function Write-Info { param([string]$m) Write-Host "        $m" -ForegroundColor Gray   }

function Require-Module {
    param([string]$Name)
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Modul '$Name' nicht gefunden. Wird das Skript auf einem DC ausgeführt?"
    }
    Import-Module $Name -ErrorAction Stop
}

function Invoke-Ldifde {
    param(
        [string]$LdifFile,
        [string]$Description
    )
    Write-Step "Importiere $Description"

    if (-not (Test-Path $LdifFile)) {
        throw "LDIF-Datei nicht gefunden: $LdifFile"
    }

    Write-Info "Datei: $LdifFile"

    # ldifde.exe ist auf Windows DCs standardmäßig vorhanden
    $result = & ldifde.exe -i -f $LdifFile -k 2>&1
    $exitCode = $LASTEXITCODE

    # Ausgabe filtern und anzeigen
    $result | ForEach-Object {
        $line = $_.ToString().Trim()
        if ($line -ne "") { Write-Info $line }
    }

    # ldifde gibt 0 bei Erfolg, aber "Entries modified" kann 0 sein wenn alles schon da ist
    # Exit-Code 0 = OK, 87 = Parameter-Fehler, andere = Fehler
    if ($exitCode -eq 0) {
        Write-OK "$Description importiert."
    }
    elseif ($exitCode -eq 87) {
        throw "ldifde Parameterfehler (Exit $exitCode) beim Import von: $LdifFile"
    }
    else {
        # Manche Fehler sind tolerierbar (z.B. Objekt existiert bereits mit -k Flag)
        Write-Skip "$Description: ldifde Exit-Code $exitCode (möglicherweise Duplikate übersprungen)"
    }
}

# ──────────────────────────────────────────────────────────────
# Task-Funktionen
# ──────────────────────────────────────────────────────────────

function Import-OUs {
    Invoke-Ldifde -LdifFile (Join-Path $LdifDir "seri-ou.ldif") -Description "Organisationseinheiten (OUs)"
}

function Import-Groups {
    Invoke-Ldifde -LdifFile (Join-Path $LdifDir "seri-groups.ldif") -Description "Gruppen"
}

function Import-Users {
    Invoke-Ldifde -LdifFile (Join-Path $LdifDir "seri-user.ldif") -Description "Benutzer"
}

function Set-AllUserPasswords {
    Write-Step "Setze Passwörter für alle AD-User"

    $securePassword = ConvertTo-SecureString $UserPassword -AsPlainText -Force

    # Alle User außer eingebauten Konten (Administrator, krbtgt, Guest)
    $builtinExclusions = @("Administrator", "krbtgt", "Guest", "adadmin")
    $users = Get-ADUser -Filter * -Properties SamAccountName, Enabled |
             Where-Object { $builtinExclusions -notcontains $_.SamAccountName }

    if ($users.Count -eq 0) {
        Write-Skip "Keine User gefunden (OUs/User noch nicht importiert?)"
        return
    }

    Write-Info "$($users.Count) User gefunden."

    $ok = 0; $err = 0
    foreach ($user in $users) {
        try {
            Set-ADAccountPassword -Identity $user.SamAccountName `
                                  -NewPassword $securePassword `
                                  -Reset

            # Passwortablauf und "Muss bei nächster Anmeldung zurücksetzen" deaktivieren
            Set-ADUser -Identity $user.SamAccountName `
                       -ChangePasswordAtLogon $false `
                       -PasswordNeverExpires $true

            # Account aktivieren (nach ldifde-Import oft deaktiviert)
            Enable-ADAccount -Identity $user.SamAccountName

            Write-OK $user.SamAccountName
            $ok++
        }
        catch {
            Write-Err "$($user.SamAccountName): $_"
            $err++
        }
    }

    Write-Info "Ergebnis: $ok OK, $err Fehler"
}

function Create-AdminAccount {
    Write-Step "Lege adadmin-Account an"

    $secureAdminPwd = ConvertTo-SecureString $AdminPassword -AsPlainText -Force

    # Administrator-Objekt als Vorlage holen
    $adminUser = Get-ADUser -Identity "Administrator" -Properties *

    $adadminSam = "adadmin"
    $adadminUPN = "adadmin@$((Get-ADDomain).DNSRoot)"

    $existingAdadmin = Get-ADUser -Filter { SamAccountName -eq "adadmin" } -ErrorAction SilentlyContinue

    if ($existingAdadmin) {
        Write-Skip "adadmin existiert bereits – aktualisiere Passwort und Einstellungen."
        Set-ADAccountPassword -Identity $adadminSam -NewPassword $secureAdminPwd -Reset
        Set-ADUser -Identity $adadminSam `
                   -ChangePasswordAtLogon $false `
                   -PasswordNeverExpires $true
        Enable-ADAccount -Identity $adadminSam
        Write-OK "adadmin aktualisiert."
    }
    else {
        # Container des Administrator-Accounts ermitteln (meist CN=Users,DC=...)
        $adminDN      = $adminUser.DistinguishedName
        $adminPath    = ($adminDN -replace "^CN=[^,]+,", "")  # alles nach "CN=Administrator,"

        New-ADUser `
            -SamAccountName       $adadminSam `
            -UserPrincipalName    $adadminUPN `
            -Name                 "adadmin" `
            -GivenName            "AD" `
            -Surname              "Admin" `
            -DisplayName          "AD Admin (adadmin)" `
            -Description          "Kopie des Administrator-Accounts für SERI" `
            -Path                 $adminPath `
            -AccountPassword      $secureAdminPwd `
            -ChangePasswordAtLogon $false `
            -PasswordNeverExpires $true `
            -Enabled              $true

        Write-OK "adadmin angelegt unter: $adminPath"
    }

    # Zu denselben Gruppen wie Administrator hinzufügen
    $adminGroups = Get-ADUser -Identity "Administrator" -Properties MemberOf |
                   Select-Object -ExpandProperty MemberOf

    Write-Info "Füge adadmin zu $($adminGroups.Count) Gruppe(n) hinzu..."
    foreach ($groupDN in $adminGroups) {
        try {
            Add-ADGroupMember -Identity $groupDN -Members $adadminSam -ErrorAction Stop
            $gName = ($groupDN -split ",")[0] -replace "^CN=", ""
            Write-OK "Gruppe: $gName"
        }
        catch {
            # Fehler "already a member" tolerieren
            if ($_ -match "already a member") {
                $gName = ($groupDN -split ",")[0] -replace "^CN=", ""
                Write-Skip "Bereits Mitglied: $gName"
            }
            else {
                Write-Err "Gruppe $groupDN : $_"
            }
        }
    }
}

function Create-Shares {
    Write-Step "Erstelle Freigaben"

    # Pfade anlegen
    $sharePaths = @(
        "C:\share",
        "C:\share\projects"
    )

    foreach ($path in $sharePaths) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Write-OK "Verzeichnis erstellt: $path"
        }
        else {
            Write-Skip "Verzeichnis existiert bereits: $path"
        }
    }

    # Domain-Admins-SID ermitteln (sprachunabhängig)
    $domainAdminsSid = (Get-ADGroup -Identity "Domain Admins").SID

    # ACL: Nur Domain Admins haben vollen Zugriff (NTFS)
    foreach ($path in $sharePaths) {
        $acl = Get-Acl $path

        # Bestehende Vererbung entfernen und eigene Regeln setzen
        $acl.SetAccessRuleProtection($true, $false)

        # Domain Admins: Full Control
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $domainAdminsSid,
            "FullControl",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )
        $acl.AddAccessRule($adminRule)

        # SYSTEM: Full Control (wird für Windows-Dienste benötigt)
        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "NT AUTHORITY\SYSTEM",
            "FullControl",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )
        $acl.AddAccessRule($systemRule)

        Set-Acl -Path $path -AclObject $acl
        Write-OK "NTFS-Rechte gesetzt: $path"
    }

    # SMB-Shares anlegen
    $shareDefinitions = @(
        @{ Name = "share";    Path = "C:\share";          Description = "SERI Root Share" },
        @{ Name = "projects"; Path = "C:\share\projects"; Description = "SERI Projects Share" }
    )

    foreach ($def in $shareDefinitions) {
        $existingShare = Get-SmbShare -Name $def.Name -ErrorAction SilentlyContinue

        if ($existingShare) {
            Write-Skip "SMB-Share existiert bereits: \\<hostname>\$($def.Name)"
        }
        else {
            New-SmbShare `
                -Name           $def.Name `
                -Path           $def.Path `
                -Description    $def.Description `
                -FullAccess     "Domain Admins" `
                -FolderEnumerationMode AccessBased | Out-Null

            Write-OK "SMB-Share erstellt: \\<hostname>\$($def.Name) → $($def.Path)"
        }

        # SMB-Berechtigungen explizit setzen (Share-Ebene)
        Grant-SmbShareAccess `
            -Name        $def.Name `
            -AccountName "Domain Admins" `
            -AccessRight Full `
            -Force | Out-Null

        Write-OK "SMB-Berechtigung gesetzt: Domain Admins = Full auf '$($def.Name)'"
    }
}

function Invoke-Cleanup {
    Write-Step "Bereinige Demo-Daten (OU=demo,...)"

    $domain    = Get-ADDomain
    $demoOUDN  = "OU=demo,$($domain.DistinguishedName)"

    # Prüfen ob OU=demo überhaupt existiert
    $demoOU = Get-ADOrganizationalUnit -Filter { DistinguishedName -eq $demoOUDN } -ErrorAction SilentlyContinue
    if (-not $demoOU) {
        Write-Skip "OU=demo nicht gefunden – nichts zu löschen."
        return
    }

    Write-Info "Ziel-Container: $demoOUDN"

    # Alle Objekte unterhalb OU=demo ermitteln (User, Gruppen, OUs, Computer, ...)
    $allObjects = Get-ADObject -SearchBase $demoOUDN `
                               -SearchScope Subtree `
                               -Filter * `
                               -Properties DistinguishedName, ObjectClass |
                  Where-Object { $_.DistinguishedName -ne $demoOUDN }

    if ($allObjects.Count -eq 0) {
        Write-Skip "OU=demo ist bereits leer."
    }
    else {
        Write-Info "Gefundene Objekte: $($allObjects.Count)"
        $allObjects | Group-Object ObjectClass | ForEach-Object {
            Write-Info "  $($_.Name): $($_.Count)"
        }

        if (-not $Force) {
            Write-Host "`n  ACHTUNG: $($allObjects.Count) Objekte werden unwiderruflich gelöscht!" -ForegroundColor Red
            $confirm = Read-Host "  Bestätigen mit 'ja'"
            if ($confirm -ne "ja") {
                Write-Skip "Abgebrochen."
                return
            }
        }

        # Löschen in der richtigen Reihenfolge:
        # 1. User und Computer (keine Container)
        # 2. Gruppen
        # 3. OUs (tiefste zuerst, damit Container leer sind)

        $users = $allObjects | Where-Object { $_.ObjectClass -eq "user" }
        $computers = $allObjects | Where-Object { $_.ObjectClass -eq "computer" }
        $groups = $allObjects | Where-Object { $_.ObjectClass -eq "group" }
        # OUs nach Tiefe sortieren (längster DN zuerst = tiefste OU zuerst)
        $ous = $allObjects | Where-Object { $_.ObjectClass -eq "organizationalUnit" } |
               Sort-Object { $_.DistinguishedName.Length } -Descending
        $others = $allObjects | Where-Object { $_.ObjectClass -notin @("user","computer","group","organizationalUnit") }

        $deleted = 0; $errors = 0

        foreach ($obj in (@($users) + @($computers) + @($others) + @($groups) + @($ous))) {
            try {
                # OUs haben oft ProtectedFromAccidentalDeletion gesetzt
                if ($obj.ObjectClass -eq "organizationalUnit") {
                    Set-ADOrganizationalUnit -Identity $obj.DistinguishedName `
                                            -ProtectedFromAccidentalDeletion $false `
                                            -ErrorAction SilentlyContinue
                }
                Remove-ADObject -Identity $obj.DistinguishedName -Recursive -Confirm:$false
                Write-OK "[$($obj.ObjectClass)] $($obj.DistinguishedName)"
                $deleted++
            }
            catch {
                # Objekt könnte bereits durch -Recursive eines Elternteils weg sein
                if ($_ -match "Cannot find an object with identity") {
                    Write-Skip "Bereits entfernt: $($obj.DistinguishedName)"
                }
                else {
                    Write-Err "$($obj.DistinguishedName): $_"
                    $errors++
                }
            }
        }

        Write-Info "Ergebnis: $deleted gelöscht, $errors Fehler"
    }

    # OU=demo selbst löschen?
    $demoOUStillExists = Get-ADOrganizationalUnit -Filter { DistinguishedName -eq $demoOUDN } -ErrorAction SilentlyContinue
    if ($demoOUStillExists) {
        try {
            Set-ADOrganizationalUnit -Identity $demoOUDN -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
            Remove-ADObject -Identity $demoOUDN -Recursive -Confirm:$false
            Write-OK "OU=demo selbst gelöscht."
        }
        catch {
            Write-Err "OU=demo konnte nicht gelöscht werden: $_"
        }
    }
}

# ──────────────────────────────────────────────────────────────
# Vorbedingungen prüfen
# ──────────────────────────────────────────────────────────────

Write-Host "`n$('═' * 60)" -ForegroundColor Magenta
Write-Host "  SERI AD Import Script" -ForegroundColor Magenta
Write-Host "  Task: $Task" -ForegroundColor Magenta
Write-Host "$('═' * 60)" -ForegroundColor Magenta

# AD-Modul laden
Require-Module ActiveDirectory

# Sicherstellen, dass AD-Dienst läuft
$adws = Get-Service -Name ADWS -ErrorAction SilentlyContinue
if (-not $adws -or $adws.Status -ne "Running") {
    throw "Active Directory Web Services (ADWS) läuft nicht. Ist dieser Server ein DC?"
}

# Domain-Info ausgeben
$domain = Get-ADDomain
Write-Info "Domain: $($domain.DNSRoot)"
Write-Info "LDIF-Verzeichnis: $LdifDir"

# ──────────────────────────────────────────────────────────────
# Tasks ausführen
# ──────────────────────────────────────────────────────────────

$startTime = Get-Date

switch ($Task) {
    "ImportOUs"   { Import-OUs   }
    "ImportGrps"  { Import-Groups }
    "ImportUsers" { Import-Users  }
    "SetPasswd"   { Set-AllUserPasswords }
    "CreateAdmin" { Create-AdminAccount  }
    "CreateShare" { Create-Shares        }
    "Cleanup"     { Invoke-Cleanup       }
    "All" {
        Import-OUs
        Import-Groups
        Import-Users
        Set-AllUserPasswords
        Create-AdminAccount
        Create-Shares
    }
}

$elapsed = (Get-Date) - $startTime

Write-Host "`n$('═' * 60)" -ForegroundColor Magenta
Write-Host "  Fertig in $([math]::Round($elapsed.TotalSeconds, 1))s" -ForegroundColor Green
Write-Host "$('═' * 60)" -ForegroundColor Magenta
