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

        Write-Host "'.env' file created at $envFilePath."
        Write-Host "Please fill in the required values before running the script again."
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
        Write-Host "No DB found. Creating..."
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Touch DB by running a harmless PRAGMA (creates file if it doesn't exist)
    Invoke-SqliteQuery -DataSource $DataSource -Query "PRAGMA journal_mode=WAL;" | Out-Null
    Write-Host "DB ready..."
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
function Get-CurrentTokens {
    [CmdletBinding()]
    param()

    #initial setup
    
    Write-Host "Installing required modules to system..."
    Install-RequiredModules
    Write-Host "Checking if env file exists and creating if needed..."
    Initialize-EnvFile
    Write-Host "Importing the data from the env file into the Process variables..."
    Import-Env -Path ".\.env" | Out-Null
    Write-CurrentProcessVariables
    #Now we check the database and get data from it
    Write-Host "Checking the database at: $([System.Environment]::GetEnvironmentVariable('database_location', 'Process'))"
    Test-DatabaseExistence -DataSource $([System.Environment]::GetEnvironmentVariable('database_location', 'Process'))
    Test-TokenTableExists -DataSource $([System.Environment]::GetEnvironmentVariable('database_location', 'Process')) -TableName "AccessToken"
    Test-TokenTableExists -DataSource $([System.Environment]::GetEnvironmentVariable('database_location', 'Process')) -TableName "RefreshToken"
    Update-ProcessVariablesFromDatabase -DataSource $([System.Environment]::GetEnvironmentVariable('database_location', 'Process'))
    Write-CurrentProcessVariables
    #Now we check if the token needs to be refreshed
    if(Test-AccessTokenExpired) {
        Write-Host "Refreshing Token..."
        Request-DaxkoToken
        Update-TokenInDb -DataSource $([System.Environment]::GetEnvironmentVariable('database_location', 'Process')) -TableName "AccessToken" -Token $([System.Environment]::GetEnvironmentVariable('access_token', 'Process'))
        Update-TokenInDb -DataSource $([System.Environment]::GetEnvironmentVariable('database_location', 'Process')) -TableName "RefreshToken" -Token $([System.Environment]::GetEnvironmentVariable('refresh_token', 'Process'))
        Write-Host "Tokens updated."
    } else {
        Write-Host "Token still active..."
    }
    Write-CurrentProcessVariables
}
function Initialize-DataTables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter()][string]$SchemaDirectory = ".\schemas"  # Default location for schema files
    )


    # Get all schema files in the directory
    $schemaFiles = Get-ChildItem -Path $SchemaDirectory -Filter "*.schema.json"

    foreach ($schemaFile in $schemaFiles) {
        $TableName = [System.IO.Path]::GetFileNameWithoutExtension($schemaFile.BaseName)
        Write-Host "Checking if table '$TableName' exists in database '$DataPath'..."

        $checkQuery = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$TableName' LIMIT 1;"
        $result = Invoke-DbQuery -DataSource $DataPath -Query $checkQuery

        if ($result.Count -gt 0) {
            Write-Host "Table '$TableName' already exists."
        } else {
            Write-Host "Table '$TableName' not found. Creating it..."

            $schemaPath = Join-Path $SchemaDirectory "$TableName.schema.json"
            if (-Not (Test-Path $schemaPath)) {
                throw "Schema file not found for table '$TableName' at '$schemaPath'"
            }

            $schemaJson = Get-Content -Raw -Path $schemaPath | ConvertFrom-Json
            $uniqueId = $schemaJson.uniqueID
            $columns = $schemaJson.Columns | ForEach-Object {
                $colName = $_.Name
                $colType = $_.Type
                # Quote column name if it starts with a digit or contains special characters
                if ($colName -match '^[0-9]' -or $colName -match '[^a-zA-Z0-9_]') {
                    $colName = "`"$colName`""  # double quotes for SQL
                }
                if ($colName -eq $uniqueId) {
                    "$colName $colType UNIQUE"
                } else {
                    "$colName $colType"
                }
            }

            $createQuery = @"
CREATE TABLE IF NOT EXISTS $TableName (
    $($columns -join ",`n    ")
);
"@

            Invoke-DbQuery -DataSource $DataPath -Query $createQuery | Out-Null
            Write-Host "Table '$TableName' created successfully."
        }
    }
}

function Save-DataFromApiResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter()][string]$SchemaDirectory = ".\schemas"
    )

    $schemaFiles = Get-ChildItem -Path $SchemaDirectory -Filter "*.schema.json"

    foreach ($schemaFile in $schemaFiles) {
        $schema = Get-Content -Raw -Path $schemaFile.FullName | ConvertFrom-Json
        $tableName = $schema.Name
        $apiUrl = $schema.APIURL
        $apiType = $schema.APITYPE.ToUpper()

        Write-Host "`nFetching data for '$tableName' from '$apiUrl' using $apiType..."

        # Get access token
        $token = $([System.Environment]::GetEnvironmentVariable('access_token', 'Process'))

        # Prepare headers
        $headers = @{
            Authorization = "Bearer $token"
            Accept        = "application/json"
        }

        if ($apiType -eq "GET") {
            $response = Invoke-DebugApiRequest -Uri $apiUrl -Method $apiType -Headers $headers
            foreach ($item in $response.data) {
                $columns = $schema.Columns | ForEach-Object { $_.Name }
                $values = $columns | ForEach-Object {
                    $val = $item.$_
                    if ($val -is [string]) {
                        "'$val'"
                    } elseif ($null -eq $val) {
                        "NULL"
                    } else {
                        "$val"
                    }
                }
                $uniqueIdField = $schema.uniqueID
                if ($uniqueIdField) {
                    $uniqueIdValue = $item.$uniqueIdField
                    $checkQuery = "SELECT COUNT(*) FROM $tableName WHERE $uniqueIdField = '$uniqueIdValue';"
                    $exists = Invoke-DbQuery -DataSource $DataPath -Query $checkQuery

                    if ($exists -gt 0) {
                        # Build UPDATE query
                        $setClause = ($columns | Where-Object { $_ -ne $uniqueIdField } | ForEach-Object {
                            $val = $item.$_
                            if ($val -is [string]) {
                                "$_ = '$val'"
                            } elseif ($null -eq $val) {
                                "$_ = NULL"
                            } else {
                                "$_ = $val"
                            }
                        }) -join ", "
                        $updateQuery = "UPDATE $tableName SET $setClause WHERE $uniqueIdField = '$uniqueIdValue';"
                        Invoke-DbQuery -DataSource $DataPath -Query $updateQuery | Out-Null
                    } else {
                        # Insert as new
                        $insertQuery = "INSERT INTO $tableName ($($columns -join ',')) VALUES ($($values -join ','));"
                        Invoke-DbQuery -DataSource $DataPath -Query $insertQuery | Out-Null
                    }
                } else {
                    # Fallback to insert or replace
                    $insertQuery = "INSERT OR REPLACE INTO $tableName ($($columns -join ',')) VALUES ($($values -join ','));"
                    Invoke-DbQuery -DataSource $DataPath -Query $insertQuery | Out-Null
                }   
            }
            Write-Host "Saved data to '$tableName'."
        }
        elseif ($apiType -eq "POST") {
            $pageNumber = 1
            $done = $false
            $outputFields = $schema.Columns | ForEach-Object { $_.Name }

            while (-not $done) {
                Write-Host "Working on page: $pageNumber ..."
                if (-not $schema.RequestBody) {
                    throw "POST request for '$tableName' is missing 'RequestBody' in schema."
                }

                $body = [PSCustomObject]@{}
                foreach ($key in $schema.RequestBody.PSObject.Properties.Name) {
                    $body | Add-Member -MemberType NoteProperty -Name $key -Value $schema.RequestBody.$key
                }
                $body | Add-Member -MemberType NoteProperty -Name "pageNumber" -Value $pageNumber
                $body | Add-Member -MemberType NoteProperty -Name "outputFields" -Value $outputFields

                $response = Invoke-DebugApiRequest -Uri $apiUrl -Method $apiType -Headers $headers -Body $body

                if ($response.error -match "This result set only contains (\d+) page\(s\)") {
                    Write-Host "Reached end of result set at page $pageNumber"
                    $done = $true
                    continue
                }

                foreach ($item in $response.data) {
                    $columns = $schema.Columns | ForEach-Object { $_.Name }
                    $values = $columns | ForEach-Object {
                        $val = $item.$_
                        if ($val -is [string]) {
                            "'$val'"
                        } elseif ($null -eq $val) {
                            "NULL"
                        } else {
                            "$val"
                        }
                    }
                    $insertQuery = "INSERT OR REPLACE INTO $tableName ($($columns -join ',')) VALUES ($($values -join ','));"
                    Invoke-DbQuery -DataSource $DataPath -Query $insertQuery | Out-Null
                }

                Write-Host "Saved page $pageNumber to '$tableName'."
                $pageNumber += 1
            }
        }
        else {
            throw "Unsupported API type '$apiType' for table '$tableName'"
        }
    }
}
function Invoke-DebugApiRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Method,
        [Parameter()][hashtable]$Headers,
        [Parameter()][object]$Body,
        [Parameter()][string]$LogPath = ".\api-debug-log.json"
    )

    Write-Host "Invoking $Method request to $Uri"
    Write-Host "Logging response to $LogPath"

    try {
        $params = @{
            Uri     = $Uri
            Method  = $Method
            Headers = $Headers
        }

        if ($Method -eq "POST" -and $Body) {
            $params.Body = ($Body | ConvertTo-Json -Depth 10)
            $params.ContentType = "application/json"
        }

        $response = Invoke-RestMethod @params

        # Save full response to log
        $log = @{
            Timestamp = (Get-Date)
            Uri       = $Uri
            Method    = $Method
            Headers   = $Headers
            Body      = $Body
            Response  = $response
        }

        $log | ConvertTo-Json -Depth 10 | Out-File -FilePath $LogPath
        return $response
    }
    catch {
        $errorLog = @{
            Timestamp = (Get-Date)
            Uri       = $Uri
            Method    = $Method
            Headers   = $Headers
            Body      = $Body
            Error     = $_.Exception.Message
            Response  = $_.ErrorDetails.Message
        }

        $errorLog | ConvertTo-Json -Depth 10 | Out-File -FilePath $LogPath
        throw "API call failed. See $LogPath for details."
    }
}

function Get-Report {
    #do stuff
}

