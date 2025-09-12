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
database_location=
refresh_token=
access_token=
refresh_time=
"@ | Out-File -FilePath $envFilePath -Encoding UTF8 -Force

        Write-Host "'.env' file created at $envFilePath."
        Write-Host "Please fill in the required values before running the script again."
        exit 1
    } else {
        Write-Host "'.env' file already exists at $envFilePath."
    }
}

function Test-EnvVariables {
    $requiredKeys = @("client_id", "scope", "database_location")
    $missingKeys = @()

    foreach ($key in $requiredKeys) {
        $value = [System.Environment]::GetEnvironmentVariable($key)
        if (-not $value) {
            $missingKeys += $key
        }
    }

    if ($missingKeys.Count -gt 0) {
        Write-Error "Missing required environment variables: $($missingKeys -join ', ')"
        exit 1
    }
}

function Initialize-Database {
    param (
        [string]$dbPath
    )

    $folder = Split-Path $dbPath
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    if (-not (Test-Path $dbPath)) {
        $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$dbPath;Version=3;")
        try {
            $connection.Open()
            $connection.Close()
            Write-Host "Database created at $dbPath"
        } catch {
            Write-Error "Failed to create database: $_"
        }
    } else {
        Write-Host "Database already exists at $dbPath"
    }
}

function Initialize-RefreshTokenTable {
    param (
        [string]$dbPath
    )

    $createTableQuery = @"
CREATE TABLE IF NOT EXISTS RefreshToken (
    id TEXT PRIMARY KEY,
    refreshToken TEXT,
    createdDateTime TEXT
);
CREATE INDEX IF NOT EXISTS idx_refresh_id ON RefreshToken (id);
"@

    try {
        Invoke-SqliteQuery -DataSource $dbPath -Query $createTableQuery
        Write-Host "RefreshToken table initialized."
    } catch {
        Write-Error "Failed to create RefreshToken table: $_"
    }
}

function Initialize-AccessTokenTable {
    param (
        [string]$dbPath
    )

    $createTableQuery = @"
CREATE TABLE IF NOT EXISTS AccessToken (
    id TEXT PRIMARY KEY,
    accessToken TEXT,
    createdDateTime TEXT
);
CREATE INDEX IF NOT EXISTS idx_access_id ON AccessToken (id);
"@

    try {
        Invoke-SqliteQuery -DataSource $dbPath -Query $createTableQuery
        Write-Host "accessToken table initialized."
    } catch {
        Write-Error "Failed to create AccessToken table: $_"
    }
}

function Set-RefreshToken {
    param (
        [string]$dbPath,
        [string]$token
    )

    $id = "current"
    $createdDateTime = (Get-Date).ToString("o")

    $query = @"
INSERT INTO RefreshToken (id, refreshToken, createdDateTime)
VALUES ('$id', '$token', '$createdDateTime')
ON CONFLICT(id) DO UPDATE SET
    refreshToken = '$token',
    createdDateTime = '$createdDateTime';
"@

    try {
        Invoke-SqliteQuery -DataSource $dbPath -Query $query
        Write-Host "Refresh token updated."
    } catch {
        Write-Error "Failed to update refresh token: $_"
    }
}
function Set-AccessToken {
    param (
        [string]$dbPath,
        [string]$token
    )

    $id = "current"
    $createdDateTime = (Get-Date).ToString("o")

    $query = @"
INSERT INTO AccessToken (id, accessToken, createdDateTime)
VALUES ('$id', '$token', '$createdDateTime')
ON CONFLICT(id) DO UPDATE SET
    accessToken = '$token',
    createdDateTime = '$createdDateTime';
"@

    try {
        Invoke-SqliteQuery -DataSource $dbPath -Query $query
        Write-Host "Access token updated."
    } catch {
        Write-Error "Failed to update access token: $_"
    }
}
function Install-RequiredModules {
    param (
        [string[]]$Modules = @("PSSQLite")
    )

    foreach ($module in $Modules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Host "Installing missing module: $module"
            Install-Module -Name $module -Scope CurrentUser -Force
        }
        Import-Module $module -ErrorAction Stop
    }
}
function Import-Env {
    param (
        [string]$Path = ".env"
    )

    if (-not (Test-Path $Path)) {
        Write-Warning "No .env file found at $Path"
        return
    }

    Get-Content $Path | ForEach-Object {
        if ($_ -match "^[^#].+=.+") {
            $name, $value = $_ -split "=", 2
            $name = $name.Trim()
            $value = $value.Trim().Trim('"').Trim("'")
            [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

function Update-TokenIfExpired {
    param (
        [string]$dbPath,
        [int]$refreshThreshold
    )

    $query = "SELECT createdDateTime, refreshToken FROM RefreshToken WHERE id = 'current'"
    $result = Invoke-SqliteQuery -DataSource $dbPath -Query $query

    if ($result.Count -eq 0) {
        Write-Warning "No refresh token found in database."
        return
    }

    $createdDateTime = [datetime]::Parse($result[0].createdDateTime)
    $tokenAge = (Get-Date) - $createdDateTime

    if ($tokenAge.TotalSeconds -lt $refreshThreshold) {
        Write-Host "Refresh token is still valid. Age: $($tokenAge.TotalSeconds) seconds."
        return
    }

    $clientId = [System.Environment]::GetEnvironmentVariable("client_id")
    $refreshToken = $result[0].refreshToken

    $body = @{
        client_id     = $clientId
        refresh_token = $refreshToken
        grant_type    = "refresh_token"
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-RestMethod -Uri "https://api.partners.daxko.com/auth/token" -Method Post -Body $body -ContentType "application/json"
        $newRefreshToken = $response.refresh_token
        $newAccessToken = $response.access_token
        $now = (Get-Date).ToString("o")

        Set-RefreshToken -dbPath $dbPath -token $newRefreshToken
        Set-AccessToken -dbPath $dbPath -token $newAccessToken


        Write-Host "New refresh token: $newRefreshToken"
        Write-Host "New access token: $newAccessToken"
    } catch {
        Write-Error "Failed to refresh token: $_"
    }
}
function Get-AccessTokenFromDb {
    param([Parameter(Mandatory)][string]$DbPath)
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Data.SQLite')
    $conn = New-Object System.Data.SQLite.SQLiteConnection "Data Source=$DbPath;Version=3;"
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "
            SELECT at.accessToken
            FROM AccessToken at
            WHERE at.id = (SELECT id FROM AccessToken LIMIT 1)
            LIMIT 1;"
        return ($cmd.ExecuteScalar()).Trim()
    } finally { $conn.Close() }
}
