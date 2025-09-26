
if (Get-Module TokenDatabaseModule) {
    Remove-Module TokenDatabaseModule -Force
    Write-Host "Module 'TokenDatabaseModule' removed from session cache."
}
Import-Module ./TokenDatabaseModule/TokenDatabaseModule.psm1
Install-RequiredModules
# Create .env file if missing
Initialize-EnvFile
Import-Env -Path ".\.env"
Update-TokenIfExpired -dbPath $env:database_location -refreshThreshold ([int]$env:refresh_time)

# 1) Make sure the Reports table exists
Initialize-ReportsTable -dbPath $env:database_location

# 2) Get the data from the API and save it to the database
Save-ReportsFromApiResponse -dbPath $env:database_location

# 3) Read them back to verify
Get-Reports -dbPath $env:database_location | Format-Table
