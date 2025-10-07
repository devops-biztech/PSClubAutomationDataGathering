Import-Module ./TokenDatabaseModule/TokenDatabaseModule.psm1
Get-CurrentTokens
Initialize-DataTables -DataPath $([System.Environment]::GetEnvironmentVariable('database_location', 'Process'))
Save-DataFromApiResponse -DataPath $([System.Environment]::GetEnvironmentVariable('database_location', 'Process'))
# 3) Read them back to verify
#Get-Report -DataPath $([System.Environment]::GetEnvironmentVariable('database_location', 'Process'))  -TableName ReportList | Format-Table
