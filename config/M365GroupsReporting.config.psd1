@{
    # M365 Groups Reporting - operational configuration.
    # Prefer Certificate. External client-secret modes are retained for compatibility/lab use.
    # Secrets and private keys stay outside this file.
    # Like PurviewDlpReport, relative paths resolve from the TOOL root, not config\.
    Tenant = @{
        TenantId       = ''
        Organization   = ''
        SharePointAdminUrl = ''
    }

    Authentication = @{
        Mode = 'ClientSecretFile' # Compatibility default; prefer Certificate for new deployments.
        AppId = ''
        CertificateThumbprint = ''
        CredentialsPath = '.\app_creds.json'
        SecretEnvironmentVariable = 'M365_GROUPS_CLIENT_SECRET'
    }

    Collection = @{
        ThrottleLimit = 12
        SkipMembers   = $false
        MaxGroups     = 0
        SharePointTimeoutMinutes = 30
    }

    Storage = @{
        DatabasePath         = '.\data\M365GroupsReporting.sqlite'
        RetentionDays        = 180
        KeepIncompleteRuns   = $true
    }

    Logging = @{
        Path = '.\logs'
        RetentionDays = 30
    }

    Report = @{
        OutputPath         = '.\reports'
        Formats            = @('CSV', 'HTML')
        FilePrefix         = 'M365GroupsReporting'
        CsvDelimiter       = ';'
        TimeZone           = 'Europe/Paris'
        Title              = 'M365 groups inventory'
        CompanyName        = ''
        ShowTenantInformation = $false
        EnvironmentName    = ''
        HtmlRowsPerPart    = 10000
        HtmlMaxRelations   = 25
        HtmlPartitioned    = $false
        RawCsvValues       = $false
    }
}
