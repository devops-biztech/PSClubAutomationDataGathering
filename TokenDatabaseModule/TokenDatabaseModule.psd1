@{
    # Script module or binary module file associated with this manifest
    RootModule = 'TokenDatabaseModule.psm1'

    # Version number of this module
    ModuleVersion = '1.0.0'

    # ID used to uniquely identify this module
    GUID = '804332fd-cc83-43d6-bb7c-d1e52dd89158'

    # Author of this module
    Author = 'Patrick'

    # Description of the functionality provided by this module
    Description = 'Provides functions to manage environment configuration and SQLite database for storing refresh tokens.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '7.0'

    # Company or vendor of this module
    CompanyName = 'Biztech'

    # Copyright statement for this module
    Copyright = '© 2025 Biztech. All rights reserved.'

    # Functions to export from this module
    FunctionsToExport = @(
        'Initialize-EnvFile',
        'Test-EnvVariables',
        'Initialize-Database',
        'Initialize-RefreshTokenTable',
        'Initialize-AccessTokenTable',
        'Set-RefreshToken',
        'Set-AccessToken',
        'Install-RequiredModules',
        'Import-Env',
        'Update-TokenIfExpired'
    )

    # Cmdlets to export from this module
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport = @()

    # Private data to pass to the module specified in RootModule
    PrivateData = @{}

    # Help info URI
    HelpInfoURI = ''

    # Default prefix for exported commands
    DefaultCommandPrefix = ''
}
