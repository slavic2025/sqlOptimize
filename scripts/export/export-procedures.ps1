param(
    [Parameter(Mandatory = $true)]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [string]$SchemaName = "dbo",

    [Parameter(Mandatory = $false)]
    [string]$ProcedureName = $null
)

Set-StrictMode -Version Latest

# --- Funcție helper pentru afișare colorată ---
function Write-Info {
    param(
        [string]$Message,
        [ConsoleColor]$Color = 'White'
    )
    Write-Host $Message -ForegroundColor $Color
}

# --- Verifică și instalează modulul dbatools dacă e necesar ---
if (-not (Get-Module -ListAvailable -Name dbatools)) {
    Write-Info "Installing dbatools module..." -Color Yellow
    Install-Module dbatools -Force -Scope CurrentUser
}

Import-Module dbatools -ErrorAction Stop

# --- Verifică existența fișierului de configurare ---
$configPath = "config/environments.json"

if (-not (Test-Path $configPath)) {
    Write-Info "❌ Configuration file not found: $configPath" -Color Red
    Write-Info "⚠️  Please create the configuration file before running this script." -Color Yellow
    exit 1
}

# --- Încarcă configurația și obține detaliile de mediu ---
try {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $envConfig = $config.$Environment

    if (-not $envConfig) {
        Write-Info "Environment '$Environment' not found in configuration!" -Color Red
        Write-Info "Available environments: $($config.PSObject.Properties.Name -join ', ')" -Color Yellow
        exit 1
    }
}
catch {
    Write-Info "Error reading configuration: $_" -Color Red
    exit 1
}

# --- Afișează detalii conexiune ---
Write-Info "=== Export Stored Procedures ===" -Color Cyan
Write-Info "Environment: $Environment" -Color White
Write-Info "Server: $($envConfig.server)" -Color White
Write-Info "Database: $($envConfig.database)" -Color White
Write-Info "Schema: $SchemaName" -Color White

# --- Construiește parametrii de conexiune ---
$connectionParams = @{
    SqlInstance            = $envConfig.server
    Database               = $envConfig.database
    TrustServerCertificate = $true
}

if ($envConfig.username -and $envConfig.password) {
    $securePassword = ConvertTo-SecureString $envConfig.password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($envConfig.username, $securePassword)
    $connectionParams.SqlCredential = $cred
}

# --- Încearcă conectarea la server ---
try {
    Write-Info "Connecting to server..." -Color Yellow
    $server = Connect-DbaInstance @connectionParams
    Write-Info "Connected successfully!" -Color Green
}
catch {
    Write-Info "Connection failed: $_" -Color Red
    Write-Info "Trying alternative connection methods..." -Color Yellow

    try {
        $server = Connect-DbaInstance -SqlInstance $envConfig.server -Database $envConfig.database -Encrypt Optional
        Write-Info "Connected with optional encryption!" -Color Green
    }
    catch {
        Write-Info "All connection attempts failed: $_" -Color Red
        exit 1
    }
}

# --- Creează folderul pentru schema procedurilor dacă nu există ---
$schemaPath = Join-Path -Path "sql/stored_procedures" -ChildPath $SchemaName

if (-not (Test-Path $schemaPath)) {
    Write-Info "Creating directory: $schemaPath" -Color Yellow
    New-Item -ItemType Directory -Path $schemaPath -Force | Out-Null
}

# --- Obține stored procedures din DB ---
try {
    if ($ProcedureName) {
        Write-Info "Fetching specific procedure: $ProcedureName" -Color Yellow
        $procedures = Get-DbaDbStoredProcedure -SqlInstance $server -Database $envConfig.database -Schema $SchemaName -Name $ProcedureName
    }
    else {
        Write-Info "Fetching all procedures for schema: $SchemaName" -Color Yellow
        $procedures = Get-DbaDbStoredProcedure -SqlInstance $server -Database $envConfig.database -Schema $SchemaName
    }

    if (-not $procedures) {
        Write-Info "No stored procedures found for schema: $SchemaName" -Color Yellow
        exit 0
    }

    Write-Info "Found $($procedures.Count) stored procedure(s)" -Color Green
}
catch {
    Write-Info "Error fetching procedures: $_" -Color Red
    exit 1
}

# --- Exportă fiecare stored procedure în fișier ---
$exportedCount = 0
$failedCount = 0

foreach ($proc in $procedures) {
    try {
        $fileName = Join-Path -Path $schemaPath -ChildPath "$($proc.Name).sql"

        # Combină header și body
        $content = $proc.TextHeader + $proc.TextBody

        # Comentează directive SET ANSI și QUOTED IDENTIFIER
        $content = $content -replace 'SET ANSI_NULLS ON', '-- SET ANSI_NULLS ON'
        $content = $content -replace 'SET QUOTED_IDENTIFIER ON', '-- SET QUOTED_IDENTIFIER ON'
        $content = $content -replace 'SET ANSI_NULLS OFF', '-- SET ANSI_NULLS OFF'
        $content = $content -replace 'SET QUOTED_IDENTIFIER OFF', '-- SET QUOTED_IDENTIFIER OFF'

        # Înlocuiește CREATE PROCEDURE cu CREATE OR ALTER PROCEDURE
        $content = $content -replace '(?i)CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE'

        # Construiește header customizat pentru fișier
$header = @"
-- ==============================================
-- Stored Procedure: $($proc.Schema).$($proc.Name)
-- Description: Auto-exported from $Environment
-- Created: $($proc.CreateDate)
-- Modified: $($proc.DateLastModified)
-- Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
-- ==============================================

"@

        $finalContent = $header + $content

        # Salvează în fișier
        $finalContent | Out-File -FilePath $fileName -Encoding UTF8 -Force

        Write-Info "✓ Exported: $($proc.Schema).$($proc.Name)" -Color Green
        $exportedCount++
    }
    catch {
        Write-Info "✗ Failed to export: $($proc.Schema).$($proc.Name) - $_" -Color Red
        $failedCount++
    }
} # Închide blocul foreach

# --- Afișează sumarul exportului ---
Write-Host "`n=== Export Summary ===" -ForegroundColor Cyan
Write-Host "Successfully exported: $exportedCount procedure(s)" -ForegroundColor Green

if ($failedCount -gt 0) {
    Write-Host "Failed to export: $failedCount procedure(s)" -ForegroundColor Red
}

# --- Creează un fișier de log ---
$logEntry = [PSCustomObject]@{
    Timestamp     = Get-Date
    Environment   = $Environment
    Schema        = $SchemaName
    ExportedCount = $exportedCount
    FailedCount   = $failedCount
    User          = $env:USERNAME
}

if (-not (Test-Path "logs")) {
    New-Item -ItemType Directory -Path "logs" -Force | Out-Null
}

$logPath = "logs/export_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$logEntry | ConvertTo-Json -Depth 3 | Out-File $logPath -Encoding UTF8 -Force

Write-Info "Export log saved to: $logPath" -Color Cyan
Write-Info "Export completed!" -Color Green