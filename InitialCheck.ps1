Import-Module ./TokenDatabaseModule/TokenDatabaseModule.psm1
Install-RequiredModules
# Create .env file if missing
Initialize-EnvFile
Import-Env -Path ".\.env"

# Validate required keys
Test-EnvVariables

# Initialize database and table
Initialize-Database -dbPath $env:database_location
Initialize-RefreshTokenTable -dbPath $env:database_location
Initialize-AccessTokenTable -dbPath $env:database_location
# Optionally update the refresh token
if ($env:refresh_token) {
    Set-RefreshToken -dbPath $env:database_location -token $env:refresh_token
}
if ($env:access_token) {
    Set-AccessToken -dbPath $env:database_location -token $env:access_token
}
