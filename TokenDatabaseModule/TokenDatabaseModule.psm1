function Install-RequiredModules {
    param (
        [string[]]$Modules = @("PSSQLite")
    )

    foreach ($module in $Modules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Verbose "Installing missing module: $module"
            Install-Module -Name $module -Scope CurrentUser -Force
        }
        Import-Module $module -ErrorAction Stop
    }
}
function Initialize-EnvFile {
    param (
        [string]$envFilePath = ".env"
    )

    if (-Not (Test-Path $envFilePath)) {
        @"
# Environment Configuration
# Fill in the required values below

client_id=
client_secret=
scope=
database_location=.\data.sqlite3
refresh_token=
access_token=
# Seconds before 'exp' to treat token as "expired"
refresh_time=
"@ | Out-File -FilePath $envFilePath -Encoding UTF8 -Force

        Write-Verbose "'.env' file created at $envFilePath."
        Write-Verbose "Please fill in the required values before running the script again."
        exit 1
    } 
}
function Import-Env {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Env file $Path not found. Run Initialize-EnvFile first."
    }

    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        if ($line.StartsWith("#")) { return }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { return }
        $name = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx+1).Trim()
        [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
}
function Write-CurrentProcessVariables {
    Write-Host "Verifying environment variables:"
    $envVarsToCheck = @(
        "client_id",
        "client_secret",
        "scope",
        "database_location",
        "refresh_token",
        "access_token",
        "refresh_time"
    )

    foreach ($var in $envVarsToCheck) {
        $value = [System.Environment]::GetEnvironmentVariable($var, "Process")
        Write-Host "$var = $value"
    }
}
function Test-DatabaseExistence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataSource
    )
    $dir = Split-Path -Path $DataSource -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        Write-Verbose "No DB found. Creating..."
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Touch DB by running a harmless PRAGMA (creates file if it doesn't exist)
    Invoke-SqliteQuery -DataSource $DataSource -Query "PRAGMA journal_mode=WAL;" | Out-Null
    Write-Verbose "DB ready..."
}
function Test-TokenTableExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataSource,
        [Parameter(Mandatory)][string]$TableName
    )
    Write-Host "Testing table '${TableName}' in database '${DataSource}'"
    $q = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${TableName}' LIMIT 1;"
    $r = Invoke-DbQuery -DataSource $DataSource -Query $q
    if ($r.Count -gt 0) {
        Write-Host "Found ${TableName} table..."
    } else {
         Write-Host "${TableName} not found. Creating table..."
        $q = @"
CREATE TABLE IF NOT EXISTS ${TableName} (
    id        INTEGER PRIMARY KEY CHECK (id = 1),
    token     TEXT NOT NULL,
    updatedAt INTEGER NOT NULL
);
"@
        Invoke-DbQuery -DataSource $DataSource -Query $q | Out-Null
    }
}
function Get-TokenRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataSource,
        [Parameter(Mandatory)][string]$TableName
    )
    $q = "SELECT id, token, updatedAt FROM ${TableName} WHERE id=1 LIMIT 1;"
    $r = Invoke-DbQuery -DataSource $DataSource -Query $q
    if ($r.Count -gt 0) { return $r[0] } else { return $null }
}
function Update-ProcessVariablesFromDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataSource
    )
    Write-Host "Checking for token records in database: $DataSource"

    $accessTokenRecord = Get-TokenRecord -DataSource $DataSource -TableName "AccessToken"
    $refreshTokenRecord = Get-TokenRecord -DataSource $DataSource -TableName "RefreshToken"

    if ($accessTokenRecord) {
        Write-Host "Updating process variable 'access_token' from database record and setting updatedAt..."
        [System.Environment]::SetEnvironmentVariable('access_token', $accessTokenRecord.token, 'Process')
        [System.Environment]::SetEnvironmentVariable('access_token_updatedAt', $accessTokenRecord.updatedAt, 'Process')
    } else {
        Write-Host "No access token found in db"
    }

    if ($refreshTokenRecord) {
        Write-Host "Updating process variable 'refresh_token' from database record..."
        [System.Environment]::SetEnvironmentVariable('refresh_token', $refreshTokenRecord.token, 'Process')
    } else {
        Write-Host "No refresh token found in db"
    }
    Write-Host "Current UpdatedAt: $([System.Environment]::GetEnvironmentVariable('access_token_updatedAt', 'Process'))"
    Write-Host "Current at: $([System.Environment]::GetEnvironmentVariable('access_token', 'Process'))"
}
function Test-AccessTokenExpired {
    [CmdletBinding()]
    param()

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $updatedAt = $([System.Environment]::GetEnvironmentVariable('access_token_updatedAt', 'Process'))
    $RefreshThresholdSeconds = $([System.Environment]::GetEnvironmentVariable('refresh_time', 'Process'))
    $effectiveExpiry = [int64]$updatedAt + [int64]$RefreshThresholdSeconds
    Write-Host "The math is: $now > $effectiveExpiry"

    return ($now -ge $effectiveExpiry)
}
function Request-DaxkoToken {
    # Step 1: Get client_id and refresh_token from process environment variables
    $clientId = [System.Environment]::GetEnvironmentVariable('client_id', 'Process')
    $refreshToken = [System.Environment]::GetEnvironmentVariable('refresh_token', 'Process')

    if (-not $clientId -or -not $refreshToken) {
        Write-Error "Missing client_id or refresh_token in process environment variables."
        return
    }

    # Step 2: Create JSON payload
    $jsonPayload = @{
        client_id     = $clientId
        grant_type    = "refresh_token"
        refresh_token = $refreshToken
    } | ConvertTo-Json -Depth 3

    # Step 3: Send POST request to Daxko API
    try {
        $response = Invoke-RestMethod -Uri "https://api.partners.daxko.com/auth/token" `
                                      -Method Post `
                                      -Body $jsonPayload `
                                      -ContentType "application/json"

        # Step 4: Write new access_token and refresh_token to process environment variables
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        [System.Environment]::SetEnvironmentVariable('access_token', $response.access_token, 'Process')
        [System.Environment]::SetEnvironmentVariable('refresh_token', $response.refresh_token, 'Process')
        [System.Environment]::SetEnvironmentVariable('access_token_updatedAt', $now, 'Process')
        Write-Host "at: $response.access_token"
        Write-Host "at: $response.refresh_token"
        Write-Host "at updated: ${now}"
        Write-Host "New token retrieved and stored successfully."
    }
    catch {
        Write-Error "Error retrieving token: $_"
    }
}
function Update-TokenInDb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataSource,
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string]$Token
    )

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $existsQuery = "SELECT COUNT(*) AS cnt FROM ${TableName} WHERE id=1;"
    $exists = (Invoke-SqliteQuery -DataSource $DataSource -Query $existsQuery)[0].cnt

    if ($exists -eq 0) {
        $insertQuery = "INSERT INTO ${TableName} (id, token, updatedAt) VALUES (1, '$Token', $now);"
        Invoke-SqliteQuery -DataSource $DataSource -Query $insertQuery | Out-Null
    } else {
        $updateQuery = "UPDATE ${TableName} SET token='$Token', updatedAt=$now WHERE id=1;"
        Invoke-SqliteQuery -DataSource $DataSource -Query $updateQuery | Out-Null
    }
}




function Invoke-DbQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataSource,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters
    )
    Write-Verbose "DS: ${DataSource}"
    Write-Verbose "q: ${Query}"
    if ($Parameters) {
        Invoke-SqliteQuery -DataSource $DataSource -Query $Query -Parameters $Parameters
    } else {
        Invoke-SqliteQuery -DataSource $DataSource -Query $Query
    }
}
function Get-JwtExpiry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Jwt
    )
    try {
        $parts = $Jwt.Split('.')
        if ($parts.Count -lt 2) { return $null }
        $payload = $parts[1]
        # base64url -> base64
        $payload = $payload.Replace('-', '+').Replace('_','/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains 'exp') {
            return [int64]$json.exp
        }
        return $null
    } catch {
        return $null
    }
}


