Write-Host "Importing Modules..."
Import-Module ./TokenDatabaseModule/TokenDatabaseModule.psm1
Write-Host "Installing required modules to system..."
Install-RequiredModules
Write-Host "Checking if env file exists and creating if needed..."
Initialize-EnvFile
Write-Host "Importing the data from the env file into the Process variables..."
Import-Env -Path ".\.env"
Write-Host "Checking tokens for expiration..."
$isExpired = Test-AccessTokenExpired -DataSource $env:database_location -RefreshThresholdSeconds ([int]$env:refresh_time)

if ($isExpired) {
    Write-Host "Token has expired. Updating..."
    $newEnvData = Update-Tokens -dbPath $env:database_location

    Write-Host "new variables: ${newEnvData}"
#    Write-Host "Access token is expired/expiring. You now have refresh_token in Process env." -ForegroundColor Yellow

    # TODO (optional): Perform actual refresh call here, then persist new access token:
    # $newToken = Invoke-YourRefreshCall -ClientId $env:client_id -ClientSecret $env:client_secret -Scope $env:scope -RefreshToken $env:refresh_token
    # $exp = Get-JwtExpiry -Jwt $newToken
    # Update-AccessTokenInDb -DataSource $env:database_location -Token $newToken -ExpiresAt $exp
    # Set-ProcessEnvFromDb -DataSource $env:database_location
} else {
    Write-Host "Token is still valid."
} 