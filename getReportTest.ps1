Import-Module ./TokenDatabaseModule/TokenDatabaseModule.psm1
Install-RequiredModules
# Create .env file if missing
Initialize-EnvFile
Import-Env -Path ".\.env"
Update-TokenIfExpired -dbPath $env:database_location -refreshThreshold ([int]$env:refresh_time)


Import-Module ./TokenDatabaseModule/TokenDatabaseModule.psm1
Install-RequiredModules

# --- Ensure TLS 1.2 on Windows PowerShell 5.1 ---
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# --- Read access token from environment ---
$token = Get-AccessTokenFromDb -DbPath $env:database_location
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "No access token retrieved from database."
}
Write-Host ("Using DB token (suffix): " + $token.Substring([Math]::Max(0, $token.Length - 10)))

Write-Host "token:" $token
# --- Build headers and URI identical to Postman ---
$headers = @{
    'Authorization' = "Bearer $token"
    'Accept'        = 'application/json'
    # Optional but nice:
    # 'User-Agent'    = 'ClubAutomationGatherer/1.0 (+PowerShell)'
}

$uri = 'https://api.partners.daxko.com/api/v1/available-reports'

# --- Call the API ---
try {
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 60
    # For quick inspection:
    # $response | ConvertTo-Json -Depth 20 | Set-Content -Path .\locations.json -Encoding UTF8
} catch {
    Write-Error "API call failed: $($_.Exception.Message)"
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
        Write-Error "HTTP Status: $([int]$_.Exception.Response.StatusCode)"
    }
    throw
}

# --- Save raw JSON to SQLite (corrected parameter handling) ---
try {
    $dbPath = $env:database_location

    $conn = New-Object System.Data.SQLite.SQLiteConnection "Data Source=$dbPath;Version=3;"
    $conn.Open()

    $createSql = @"
CREATE TABLE IF NOT EXISTS raw_daxko_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    fetched_utc TEXT NOT NULL,
    payload TEXT NOT NULL
);
"@
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $createSql
    $null = $cmd.ExecuteNonQuery()

    # Prepare insert
    $json = $response | ConvertTo-Json -Depth 20

    $cmd.CommandText = "INSERT INTO raw_daxko_reports (fetched_utc, payload) VALUES (@ts, @payload);"
    $cmd.Parameters.Clear() | Out-Null

    # Add parameters, then set values (do NOT cast to [void] before setting .Value)
    $pTs      = $cmd.Parameters.Add("@ts",      [System.Data.DbType]::String)
    $pPayload = $cmd.Parameters.Add("@payload", [System.Data.DbType]::String)

    $pTs.Value      = (Get-Date).ToUniversalTime().ToString('o')
    $pPayload.Value = $json

    $null = $cmd.ExecuteNonQuery()

    $conn.Close()
    Write-Host "Saved locations payload to SQLite (raw_daxko_reports)."
} catch {
    Write-Warning "SQLite save skipped/failed: $($_.Exception.Message)"
}

