[CmdletBinding()]
param()

# Dev Mode: Clear cached function if it exists
if (Get-Command Get-DataFromCA -ErrorAction SilentlyContinue) {
    Remove-Item Function:Get-DataFromCA -Force
}

function Get-DataFromCA {
    [CmdletBinding()]
    param()

    #initial setup
    Write-Verbose "Importing Modules..."
    Import-Module ./TokenDatabaseModule/TokenDatabaseModule.psm1
    Write-Verbose "Installing required modules to system..."
    Install-RequiredModules
    Write-Verbose "Checking if env file exists and creating if needed..."
    Initialize-EnvFile
    Write-Verbose "Importing the data from the env file into the Process variables..."
    Import-Env -Path ".\.env" | Out-Null
    Write-CurrentProcessVariables
    #Now we check the database and get data from it
    Write-Verbose "Checking the database at: $([System.Environment]::GetEnvironmentVariable('database_location', 'Process'))"
    Test-DatabaseExistence -DataSource $([System.Environment]::GetEnvironmentVariable('database_location', 'Process'))
    Test-TokenTableExists -DataSource $([System.Environment]::GetEnvironmentVariable('database_location', 'Process')) -TableName "AccessToken"
    Test-TokenTableExists -DataSource $([System.Environment]::GetEnvironmentVariable('database_location', 'Process')) -TableName "RefreshToken"
    Update-ProcessVariablesFromDatabase -DataSource $([System.Environment]::GetEnvironmentVariable('database_location', 'Process'))
    Write-CurrentProcessVariables
    #Now we check if the token needs to be refreshed
    if(Test-AccessTokenExpired) {
        Write-Verbose "Refreshing Token..."
        Request-DaxkoToken
        Update-TokenInDb -DataSource $([System.Environment]::GetEnvironmentVariable('database_location', 'Process')) -TableName "AccessToken" -Token $([System.Environment]::GetEnvironmentVariable('access_token', 'Process'))
        Update-TokenInDb -DataSource $([System.Environment]::GetEnvironmentVariable('database_location', 'Process')) -TableName "RefreshToken" -Token $([System.Environment]::GetEnvironmentVariable('refresh_token', 'Process'))
        Write-Host "Tokens updated in database tables."
    } else {
        Write-Verbose "Token still active..."
    }
    Write-CurrentProcessVariables
}

Get-DataFromCA