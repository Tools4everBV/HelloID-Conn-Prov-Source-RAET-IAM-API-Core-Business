# Set TLS to accept TLS, TLS 1.1 and TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

$VerbosePreference = "SilentlyContinue"
$InformationPreference = "Continue"
$WarningPreference = "Continue"

$c = $configuration | ConvertFrom-Json

$clientId = $c.clientId
$clientSecret = $c.clientSecret
$tenantId = $c.tenantId
$excludePersonsWithoutContractsInHelloID = $c.excludePersonsWithoutContractsInHelloID

$Script:BaseUrl = "https://api.youserve.nl"

function New-RaetSession { 
    [CmdletBinding()]
    param (
        [Alias("Param1")] 
        [parameter(Mandatory = $true)]  
        [string]      
        $ClientId,

        [Alias("Param2")] 
        [parameter(Mandatory = $true)]  
        [string]
        $ClientSecret,

        [Alias("Param3")] 
        [parameter(Mandatory = $false)]  
        [string]
        $TenantId
    )
   
    #Check if the current token is still valid
    if (Confirm-AccessTokenIsValid -eq $true) {       
        return
    }

    $url = "$Script:BaseUrl/authentication/token"
    $authorisationBody = @{
        'grant_type'    = "client_credentials"
        'client_id'     = $ClientId
        'client_secret' = $ClientSecret
    }
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

        $result = Invoke-WebRequest -Uri $url -Method Post -Body $authorisationBody -ContentType 'application/x-www-form-urlencoded' -Headers @{'Cache-Control' = "no-cache" } -UseBasicParsing
        $accessToken = $result.Content | ConvertFrom-Json
        $Script:expirationTimeAccessToken = (Get-Date).AddSeconds($accessToken.expires_in)

        $Script:AuthenticationHeaders = @{
            'X-Client-Id'      = $ClientId
            'Authorization'    = "Bearer $($accessToken.access_token)"
            'X-Raet-Tenant-Id' = $TenantId
        }
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq "Forbidden") {
            $errorMessage = "Something went wrong $($_.ScriptStackTrace). Error message: '$($_.Exception.Message)'"
        }
        elseif (![string]::IsNullOrEmpty($_.ErrorDetails.Message)) {
            $errorMessage = "Something went wrong $($_.ScriptStackTrace). Error message: '$($_.ErrorDetails.Message)'"
        }
        else {
            $errorMessage = "Something went wrong $($_.ScriptStackTrace). Error message: '$($_)'"
        }
        throw $errorMessage
    } 
}

function Confirm-AccessTokenIsValid {
    if ($null -ne $Script:expirationTimeAccessToken) {
        if ((Get-Date) -le $Script:expirationTimeAccessToken) {
            return $true
        }        
    }
    return $false    
}

function Invoke-RaetRestMethodList {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]
        $Url
    )
    try {
        [System.Collections.ArrayList]$ReturnValue = @()
        $counter = 0
        do {
            if ($counter -gt 0) {
                $SkipTakeUrl = $resultSubset.nextLink.Substring($resultSubset.nextLink.IndexOf("?"))
            }
            $counter++
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $accessTokenValid = Confirm-AccessTokenIsValid
            if ($accessTokenValid -ne $true) {
                New-RaetSession -ClientId $clientId -ClientSecret $clientSecret -TenantId $tenantId
            }
            $result = Invoke-RestMethod -Uri $Url$SkipTakeUrl -Method GET -ContentType "application/json" -Headers $Script:AuthenticationHeaders -UseBasicParsing
            $resultSubset = $result
            $ReturnValue.AddRange($resultSubset.value)
        } until([string]::IsNullOrEmpty($resultSubset.nextLink))
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq "Forbidden") {
            $errorMessage = "Something went wrong $($_.ScriptStackTrace). Error message: '$($_.Exception.Message)'"
        }
        elseif (![string]::IsNullOrEmpty($_.ErrorDetails.Message)) {
            $errorMessage = "Something went wrong $($_.ScriptStackTrace). Error message: '$($_.ErrorDetails.Message)'"
        }
        else {
            $errorMessage = "Something went wrong $($_.ScriptStackTrace). Error message: '$($_)'"
        }
        throw $errorMessage
    }
    return $ReturnValue
}


Write-Information "Starting person import"

# Query persons
try {
    Write-Verbose "Querying persons"

    $persons = Invoke-RaetRestMethodList -Url "$Script:BaseUrl/iam/v1.0/persons"
    
    # Filter for valid persons
    $filterDateValidPersons = Get-Date
    $persons = $persons | Where-Object { $_.validUntil -as [datetime] -ge $filterDateValidPersons.AddDays(-90) -and $_.validFrom -as [datetime] -le $filterDateValidPersons.AddDays(90) }

    # Check if there still are duplicate persons
    $duplicatePersons = ($persons | Group-Object -Property personCode | Where-Object { $_.Count -gt 1 }).Name
    if ($duplicatePersons.Count -ge 1) {
        # Sort by validUntil and validFrom (Descending)
        $prop1 = @{Expression = { if (($_.validUntil -eq "") -or ($null -eq $_.validUntil) ) { (Get-Date -Year 2199 -Month 12 -Day 31) -as [datetime] } else { $_.validUntil -as [datetime] } }; Descending = $true }
        $prop2 = @{Expression = { if (($_.validFrom -eq "") -or ($null -eq $_.validFrom) ) { (Get-Date -Year 2199 -Month 12 -Day 31) -as [datetime] } else { $_.validFrom -as [datetime] } }; Descending = $false }

        $persons = $persons | Sort-Object -Property personCode, $prop1, $prop2 | Sort-Object -Property personCode -Unique
    }

    Write-Information "Successfully queried persons. Result: $($persons.Count)"
}
catch {
    throw "Could not retrieve persons. Error: $($_.Exception.Message)"
}

# Query employments
try {
    Write-Verbose "Querying employments"

    $employments = Invoke-RaetRestMethodList -Url "$Script:BaseUrl/iam/v1.0/employments"

    # Filter for valid employments
    $filterDateValidEmployments = Get-Date
    $employments = $employments | Where-Object { $_.validUntil -as [datetime] -ge $filterDateValidEmployments -and $_.validFrom -as [datetime] -le $filterDateValidEmployments.AddDays(90) }

    # Check if there still are duplicate persons
    $duplicateEmployments = ($employments | Group-Object -Property id | Where-Object { $_.Count -gt 1 }).Name
    if ($duplicateEmployments.Count -ge 1) {
        # Sort by  validFrom and validUntil(Ascending)
        $prop1 = @{Expression = { if (($_.validFrom -eq "") -or ($null -eq $_.validFrom) ) { (Get-Date -Year 2199 -Month 12 -Day 31) -as [datetime] } else { $_.validFrom -as [datetime] } }; Descending = $false }
        $prop2 = @{Expression = { if (($_.validUntil -eq "") -or ($null -eq $_.validUntil) ) { (Get-Date -Year 2199 -Month 12 -Day 31) -as [datetime] } else { $_.validUntil -as [datetime] } }; Descending = $true }

        $employments = $employments | Sort-Object -Property id, $prop1, $prop2 | Sort-Object -Property id -Unique
    }

    # Group by personCode
    $employmentsGrouped = $employments | Group-Object personCode -AsHashTable -AsString

    Write-Information "Successfully queried employments. Result: $($employments.Count)"
}
catch {
    throw "Could not retrieve employments. Error: $($_.Exception.Message)"
}

# Query companies
try {
    Write-Verbose "Querying companies"
    
    $companies = Invoke-RaetRestMethodList -Url "$Script:BaseUrl/iam/v1.0/companies"

    # Filter for valid companies
    $filterDateValidCompanies = Get-Date
    $companies = $companies | Where-Object { $_.validUntil -as [datetime] -ge $filterDateValidCompanies -and $_.validFrom -as [datetime] -le $filterDateValidCompanies }

    # Group by ShortName
    $companiesGrouped = $companies | Group-Object shortName -AsHashTable -AsString

    Write-Information "Successfully queried companies. Result: $($companies.Count)"
}
catch {
    throw "Could not retrieve companies. Error: $($_.Exception.Message)"
}

# Query organizationunits
try {
    Write-Verbose "Querying organizationUnits"
    
    $organizationUnits = Invoke-RaetRestMethodList -Url "$Script:BaseUrl/iam/v1.0/organizationunits"

    # Filter for valid organizationunits
    $filterDateValidOrganizationUnits = Get-Date
    $organizationUnits = $organizationUnits | Where-Object { $_.validUntil -as [datetime] -ge $filterDateValidOrganizationUnits -and $_.validFrom -as [datetime] -le $filterDateValidOrganizationUnits }

    # Group by id
    $organizationUnitsGrouped = $organizationUnits | Group-Object id -AsHashTable -AsString

    Write-Information "Successfully queried organizationunits. Result: $($organizationUnits.Count)"
}
catch {
    throw "Could not retrieve organizationunits. Error: $($_.Exception.Message)"
}

# Query costCenters
try {
    Write-Verbose "Querying costCenters"
    
    $costCenters = Invoke-RaetRestMethodList -Url "$Script:BaseUrl/iam/v1.0/valueList/costCenter"

    # Filter for valid costCenters
    $filterDateValidCostCenters = Get-Date
    $costCenters = $costCenters | Where-Object { $_.validUntil -as [datetime] -ge $filterDateValidCostCenters -and $_.validFrom -as [datetime] -le $filterDateValidCostCenters }

    # Group by ShortName
    $costCentersGrouped = $costCenters | Group-Object shortName -AsHashTable -AsString

    Write-Information "Successfully queried costCenters. Result: $($costCenters.Count)"
}
catch {
    throw "Could not retrieve costCenters. Error: $($_.Exception.Message)"
}

# Query classifications
try {
    Write-Verbose "Querying classifications"
    
    $classifications = Invoke-RaetRestMethodList -Url "$Script:BaseUrl/iam/v1.0/valueList/classification"

    # Filter for valid classifications
    $filterDateValidClassifications = Get-Date
    $classifications = $classifications | Where-Object { $_.validUntil -as [datetime] -ge $filterDateValidClassifications -and $_.validFrom -as [datetime] -le $filterDateValidClassifications }

    # Group by ShortName
    $classificationsGrouped = $classifications | Group-Object shortName -AsHashTable -AsString

    Write-Information "Successfully queried classifications. Result: $($classifications.Count)"
}
catch {
    throw "Could not retrieve classifications. Error: $($_.Exception.Message)"
}

# Query jobProfiles
try {
    Write-Verbose "Querying jobProfiles"
    
    $jobProfiles = Invoke-RaetRestMethodList -Url "$Script:BaseUrl/iam/v1.0/jobProfiles"

    # Filter for valid classifications
    $filterDateValidJobProfiles = Get-Date
    $jobProfiles = $jobProfiles | Where-Object { $_.validUntil -as [datetime] -ge $filterDateValidJobProfiles -and $_.validFrom -as [datetime] -le $filterDateValidJobProfiles.AddDays(90) }

    # Group by id
    $jobProfilesGrouped = $jobProfiles | Group-Object id -AsHashTable -AsString

    Write-Information "Successfully queried jobProfiles. Result: $($jobProfiles.Count)"
}
catch {
    throw "Could not retrieve jobProfiles. Error: $($_.Exception.Message)"
}

try {
    # Enhance the persons model
    $persons | Add-Member -MemberType NoteProperty -Name "ExternalId" -Value $null -Force
    $persons | Add-Member -MemberType NoteProperty -Name "DisplayName" -Value $null -Force
    $persons | Add-Member -MemberType NoteProperty -Name "Contracts" -Value $null -Force

    $persons | ForEach-Object {
        # Set required fields for HelloID
        $_.ExternalId = $_.personCode
        $_.DisplayName = "$($_.knownAs) $($_.lastNameAtBirth) ($($_.ExternalId))" 

        # Transform emailAddresses and add to the person
        if ($null -ne $_.emailAddresses) {
            foreach ($emailAddress in $_.emailAddresses) {
                if (![string]::IsNullOrEmpty($emailAddress)) {
                    # Add a property for each type of EmailAddress
                    $_ | Add-Member -MemberType NoteProperty -Name "$($emailAddress.type)EmailAddress" -Value $emailAddress -Force
                }
            }

            # Remove unneccesary fields from  object (to avoid unneccesary large objects)
            # Remove customFieldGroup, since the data is transformed into seperate properties
            $_.PSObject.Properties.Remove('emailAddresses')
        }

        # Transform phoneNumbers and add to the person
        if ($null -ne $_.phoneNumbers) {
            foreach ($phoneNumber in $_.phoneNumbers) {
                if (![string]::IsNullOrEmpty($phoneNumber)) {
                    # Add a property for each type of PhoneNumber
                    $_ | Add-Member -MemberType NoteProperty -Name "$($phoneNumber.type)PhoneNumber" -Value $phoneNumber -Force
                }
            }

            # Remove unneccesary fields from  object (to avoid unneccesary large objects)
            # Remove phoneNumbers, since the data is transformed into seperate properties
            $_.PSObject.Properties.Remove('phoneNumbers')
        }

        # Transform addresses and add to the person
        if ($null -ne $_.addresses) {
            foreach ($address in $_.addresses) {
                if (![string]::IsNullOrEmpty($address)) {
                    # Add a property for each type of address
                    $_ | Add-Member -MemberType NoteProperty -Name "$($address.type)Address" -Value $address -Force
                }
            }

            # Remove unneccesary fields from  object (to avoid unneccesary large objects)
            # Remove addresses, since the data is transformed into seperate properties
            $_.PSObject.Properties.Remove('addresses')
        }

        # Transform extensions and add to the person
        if ($null -ne $_.extensions) {
            foreach ($extension in $_.extensions) {
                # Add a property for each extension
                $_ | Add-Member -Name $extension.key -MemberType NoteProperty -Value $extension.value -Force
            }

            # Remove unneccesary fields from  object (to avoid unneccesary large objects)
            # Remove extensions, since the data is transformed into seperate properties
            $_.PSObject.Properties.Remove('extensions')
        }

        # Enhance person with employment
        # Get employments for person, linking key is company personCode
        $personEmployments = $employmentsGrouped[$_.personCode]
        # Create contracts object
        $contractsList = [System.Collections.ArrayList]::new()
        if ($null -ne $personEmployments) {
            foreach ($employment in $personEmployments) {
                # Set required fields for HelloID
                $employmentExternalId = "$($employment.id)"
                $employment | Add-Member -MemberType NoteProperty -Name "ExternalId" -Value $employmentExternalId -Force

                # Enhance employment with company for for extra information, such as: fullName
                # Get company for employment, linking key is company ShortName
                $company = $companiesGrouped[($employment.company)]
                if ($null -ne $company) {
                    # In the case multiple companies are found with the same ID, we always select the first one in the array
                    $employment | Add-Member -MemberType NoteProperty -Name "company" -Value $company[0] -Force
                }

                # Enhance employment with organizationUnit for for extra information, such as: fullName
                # Get organizationUnit for employment, linking key is organizationUnit id
                $organizationUnit = $organizationUnitsGrouped[($employment.organizationUnit)]
                if ($null -ne $organizationUnit) {
                    # In the case multiple organizationUnits are found with the same ID, we always select the first one in the array
                    $employment | Add-Member -MemberType NoteProperty -Name "organizationUnit" -Value $organizationUnit[0] -Force
                }
                
                # Enhance employment with costCenter for for extra information, such as: fullName
                # Get costCenter for employment, linking key is costCenter ShortName
                $costCenter = $costCentersGrouped[($employment.costCenter)]
                if ($null -ne $costCenter) {
                    # In the case multiple costCenters are found with the same ID, we always select the first one in the array
                    $employment | Add-Member -MemberType NoteProperty -Name "costCenter" -Value $costCenter[0] -Force
                }

                # Enhance employment with jobProfile for for extra information, such as: fullName
                # Get jobProfile for employment, linking key is jobProfile id
                $jobProfile = $jobProfilesGrouped["$($employment.jobProfile)"]
                if ($null -ne $jobProfile) {
                    # In the case multiple jobProfiles are found with the same ID, we always select the first one in the array
                    $employment | Add-Member -MemberType NoteProperty -Name "jobProfile" -Value $jobProfile[0] -Force
                }

                # Enhance employment with classification for for extra information, such as: fullName
                # Get classification for employment, linking key is classification ShortName
                if ($employment.classification.count -gt 0) {
                    $classification = $classificationsGrouped[$employment.classification]
                    if ($null -ne $classification) {
                        # In the case multiple classification are found with the same ID, we always select the first one in the array
                        $employment | Add-Member -MemberType NoteProperty -Name "classification" -Value $classification[0] -Force
                    }
                }

                # Create Contract object(s) based on employments
                # Create custom employment object to include prefix of properties
                $employmentObject = [PSCustomObject]@{}
                $employment.psobject.properties | ForEach-Object {
                    $employmentObject | Add-Member -MemberType $_.MemberType -Name "employment_$($_.Name)" -Value $_.Value -Force
                }

                [Void]$contractsList.Add($employmentObject)
            }

            # Remove unneccesary fields from object (to avoid unneccesary large objects)
            # Remove employments, since the data is transformed into a seperate object: contracts
            $_.PSObject.Properties.Remove('employments')
        }
        else {
            ### Be very careful when logging in a loop, only use this when the amount is below 100
            ### When this would log over 100 lines, please refer from using this in HelloID and troubleshoot this in local PS
            # Write-Warning "No employments found for person: $($_.ExternalId)"
        }

        # Add Contracts to person
        if ($contractsList.Count -ge 1) {
            $_.Contracts = $contractsList
        }
        elseif ($true -eq $excludePersonsWithoutContractsInHelloID) {
            ### Be very careful when logging in a loop, only use this when the amount is below 100
            ### When this would log over 100 lines, please refer from using this in HelloID and troubleshoot this in local PS
            # Write-Warning "Excluding person from export: $($_.ExternalId). Reason: Person has no contract data"
            return
        }           
    
        # Sanitize and export the json
        $person = $_ | ConvertTo-Json -Depth 10
        $person = $person.Replace("._", "__")

        Write-Output $person
    }

    Write-Information "Person import completed"
}
catch {
    Write-Error "Error at line: $($_.InvocationInfo.PositionMessage)"
    throw "Error: $_"
}