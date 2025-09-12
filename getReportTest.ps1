Import-Module ./TokenDatabaseModule/TokenDatabaseModule.psm1
Install-RequiredModules
# Create .env file if missing
Initialize-EnvFile
Import-Env -Path ".\.env"
Update-TokenIfExpired -dbPath $env:database_location -refreshThreshold ([int]$env:refresh_time)


