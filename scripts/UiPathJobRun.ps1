<#
.SYNOPSIS 
    Run UiPath Orchestrator Job via API with External Application authentication.
    UPDATED: Automatically finds ReleaseKey GUID via API call and supports machine/robot targeting
#>
Param (
    [Parameter(Mandatory=$true)]
    [string] $processName = "",
    [Parameter(Mandatory=$true)]
    [string] $uriOrch = "",
    [Parameter(Mandatory=$true)]
    [string] $tenantlName = "",
    [Parameter(Mandatory=$true)]
    [string] $accountForApp = "",
    [Parameter(Mandatory=$true)]
    [string] $applicationId = "",
    [Parameter(Mandatory=$true)]
    [string] $applicationSecret = "",
    [Parameter(Mandatory=$true)]
    [string] $applicationScope = "",
    [string] $input_path = "",
    [string] $jobscount = "1",
    [string] $result_path = "",
    [string] $priority = "Normal",
    [string] $robots = "",
    [string] $folder_organization_unit = "",
    [string] $machine = "",
    [string] $timeout = "1800",
    [string] $fail_when_job_fails = "true",
    [string] $wait = "true",
    [string] $job_type = "Unattended"
)

function WriteLog {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [switch]$err
    )
    $timestamp = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') "
    $logEntry = "$timestamp$Message"
    if ($err) {
        Write-Error $logEntry
    } else {
        Write-Host $logEntry
    }
}

WriteLog "🚀 Starting UiPath Orchestrator Job via API..."
WriteLog "Script Parameters:"
WriteLog "  - Process Name: $processName"
WriteLog "  - Orchestrator URL: $uriOrch"
WriteLog "  - Tenant: $tenantlName"
WriteLog "  - Account: $accountForApp"
WriteLog "  - Folder: $folder_organization_unit"
WriteLog "  - Robot: $robots"
WriteLog "  - Machine: $machine"
WriteLog "  - Timeout: $timeout"

# Define URLs
$orchestratorApiBase = "$uriOrch/orchestrator_"
$identityServerRoot = if ($uriOrch -match "^(https?:\/\/[^\/]+)\/") { $Matches[1] } else { $uriOrch }

WriteLog "Orchestrator API Base: $orchestratorApiBase"
WriteLog "Identity Server Root: $identityServerRoot"

# --- 1. Get Access Token ---
WriteLog "🔐 Getting access token..."
$identityUrl = "$identityServerRoot/identity_/connect/token"
$bodyParams = @{
    "grant_type"    = "client_credentials"
    "client_id"     = $applicationId
    "client_secret" = $applicationSecret
    "scope"         = $applicationScope
}

try {
    $response = Invoke-RestMethod -Uri $identityUrl -Method Post -ContentType "application/x-www-form-urlencoded" -Body $bodyParams -ErrorAction Stop
    if ($response.access_token) {
        WriteLog "✅ Successfully retrieved access token"
        $accessToken = $response.access_token
    } else {
        WriteLog "❌ Failed to retrieve access token" -err
        exit 1
    }
} catch {
    WriteLog "❌ Error getting access token: $($_.Exception.Message)" -err
    exit 1
}

# Set up headers
$headers = @{
    "Authorization" = "Bearer $accessToken"
    "X-UIPATH-TenantName" = $tenantlName
    "X-UIPATH-AccountName" = $accountForApp
    "Content-Type" = "application/json"
}

# --- 2. Get Folder ID ---
try {
    WriteLog "📁 Finding folder '$folder_organization_unit'..."
    $foldersUri = "$orchestratorApiBase/odata/Folders"
    $foldersResponse = Invoke-RestMethod -Uri $foldersUri -Method Get -Headers $headers -ErrorAction Stop
    
    $folder = $foldersResponse.value | Where-Object { $_.DisplayName -eq $folder_organization_unit }
    if (-not $folder) {
        WriteLog "❌ Folder '$folder_organization_unit' not found" -err
        WriteLog "Available folders:" -err
        $foldersResponse.value | ForEach-Object { WriteLog "  - $($_.DisplayName)" }
        exit 1
    }
    
    $folderId = $folder.Id
    WriteLog "✅ Found folder ID: $folderId"
    
    # Add folder context to headers
    $headers."X-UIPATH-OrganizationUnitId" = $folderId
    
} catch {
    WriteLog "❌ Error accessing folders: $($_.Exception.Message)" -err
    exit 1
}

# --- 3. Find ReleaseKey by Looking Up Process/Release ---
WriteLog "🔍 Looking up ReleaseKey for process '$processName'..."

$releaseKey = $null
$foundProcess = $null

# Try multiple endpoints to find the process
$endpoints = @(
    @{ Name = "Releases"; Uri = "$orchestratorApiBase/odata/Releases"; KeyField = "Key"; NameField = "Name"; ProcessField = "ProcessKey" },
    @{ Name = "Processes"; Uri = "$orchestratorApiBase/odata/Processes"; KeyField = "Key"; NameField = "Name"; ProcessField = "Key" }
)

foreach ($endpoint in $endpoints) {
    try {
        WriteLog "Trying endpoint: $($endpoint.Name)"
        $response = Invoke-RestMethod -Uri $endpoint.Uri -Method Get -Headers $headers -ErrorAction Stop
        
        if ($response.value) {
            WriteLog "Found $($response.value.Count) items in $($endpoint.Name)"
            
            # Try to find exact match by name
            $foundProcess = $response.value | Where-Object { 
                $_."$($endpoint.NameField)" -eq $processName
            }
            
            if ($foundProcess) {
                $releaseKey = $foundProcess."$($endpoint.KeyField)"
                WriteLog "✅ Found exact match in $($endpoint.Name)!"
                WriteLog "✅ Process Name: '$($foundProcess."$($endpoint.NameField)")"
                WriteLog "✅ ReleaseKey: '$releaseKey'"
                break
            } else {
                WriteLog "⚠️ No exact match found in $($endpoint.Name)"
            }
        } else {
            WriteLog "⚠️ No data returned from $($endpoint.Name)"
        }
    }
    catch {
        WriteLog "❌ Error accessing $($endpoint.Name): $($_.Exception.Message)"
    }
}

# If we still haven't found it, try partial matching
if (-not $releaseKey) {
    WriteLog "🔍 Trying partial name matching..."
    
    foreach ($endpoint in $endpoints) {
        try {
            $response = Invoke-RestMethod -Uri $endpoint.Uri -Method Get -Headers $headers -ErrorAction SilentlyContinue
            if ($response.value) {
                # Try partial match (contains)
                $foundProcess = $response.value | Where-Object { 
                    $_."$($endpoint.NameField)" -like "*$processName*" -or $processName -like "*$($_."$($endpoint.NameField)")*"
                }
                
                if ($foundProcess) {
                    if ($foundProcess.Count -gt 1) {
                        WriteLog "⚠️ Multiple partial matches found in $($endpoint.Name):"
                        $foundProcess | ForEach-Object { 
                            WriteLog "  - '$($_."$($endpoint.NameField)")' (Key: '$($_."$($endpoint.KeyField)")')" 
                        }
                        $foundProcess = $foundProcess[0]
                        WriteLog "Using first match: '$($foundProcess."$($endpoint.NameField)")'"
                    }
                    
                    $releaseKey = $foundProcess."$($endpoint.KeyField)"
                    WriteLog "✅ Found partial match in $($endpoint.Name)!"
                    WriteLog "✅ Process Name: '$($foundProcess."$($endpoint.NameField)")"
                    WriteLog "✅ ReleaseKey: '$releaseKey'"
                    break
                }
            }
        }
        catch {
            # Silent continue for partial matching attempts
        }
    }
}

# Final fallback: use the process name as-is
if (-not $releaseKey) {
    WriteLog "⚠️ Could not find ReleaseKey via API calls"
    WriteLog "⚠️ Using process name directly as ReleaseKey (might fail): $processName"
    $releaseKey = $processName
}

# --- 4. Get Robot and Machine Information for Targeting ---
WriteLog "🤖 Looking up Robot and Machine information for targeting..."

$robotId = $null
$machineId = $null

# Look up Robot ID if robot name is provided
if ($robots -and $robots.Trim() -ne "") {
    try {
        WriteLog "🔍 Looking up Robot: '$robots'"
        $usersUri = "$orchestratorApiBase/odata/Users"
        $usersResponse = Invoke-RestMethod -Uri $usersUri -Method Get -Headers $headers -ErrorAction Stop
        
        $targetRobot = $usersResponse.value | Where-Object { 
            $_.Name -eq $robots -and $_.Type -eq "Robot"
        }
        
        if ($targetRobot) {
            $robotId = $targetRobot.Id
            WriteLog "✅ Found Robot '$robots' with ID: $robotId"
        } else {
            WriteLog "⚠️ Robot '$robots' not found"
            WriteLog "Available robots:"
            $usersResponse.value | Where-Object { $_.Type -eq "Robot" } | ForEach-Object {
                WriteLog "  - Robot: '$($_.Name)' (ID: $($_.Id))"
            }
        }
    } catch {
        WriteLog "⚠️ Error looking up robot: $($_.Exception.Message)"
    }
} else {
    WriteLog "ℹ️ No robot name specified, will use dynamic allocation"
}

# Look up Machine ID if machine name is provided
if ($machine -and $machine.Trim() -ne "") {
    try {
        WriteLog "🔍 Looking up Machine: '$machine'"
        $machinesUri = "$orchestratorApiBase/odata/Machines"
        $machinesResponse = Invoke-RestMethod -Uri $machinesUri -Method Get -Headers $headers -ErrorAction Stop
        
        $targetMachine = $machinesResponse.value | Where-Object { 
            $_.Name -eq $machine
        }
        
        if ($targetMachine) {
            $machineId = $targetMachine.Id
            WriteLog "✅ Found Machine '$machine' with ID: $machineId"
        } else {
            WriteLog "⚠️ Machine '$machine' not found"
            WriteLog "Available machines:"
            $machinesResponse.value | ForEach-Object {
                WriteLog "  - Machine: '$($_.Name)' (ID: $($_.Id))"
            }
        }
    } catch {
        WriteLog "⚠️ Error looking up machine: $($_.Exception.Message)"
    }
} else {
    WriteLog "ℹ️ No machine name specified, will use dynamic allocation"
}

# --- 5. Start Job with Machine/Robot Targeting ---
WriteLog "🚀 Starting job with ReleaseKey: $releaseKey"

# Build the job request with specific targeting
$startInfo = @{
    "ReleaseKey" = $releaseKey
    "JobsCount" = [int]$jobscount
    "InputArguments" = "{}"
}

# Add Strategy and RuntimeType for better control
$startInfo["Strategy"] = "ModernJobsCount"
$startInfo["RuntimeType"] = $job_type

# Add robot targeting if we found the robot
if ($robotId) {
    $startInfo["RobotIds"] = @([int]$robotId)
    WriteLog "✅ Targeting specific Robot ID: $robotId"
}

# Add machine targeting if we found the machine
if ($machineId) {
    # Try to get machine sessions for the target machine
    try {
        WriteLog "🔍 Looking for active sessions on machine '$machine'..."
        $machineSessionsUri = "$orchestratorApiBase/odata/Sessions?\$filter=Machine/Id eq $machineId and State eq 'Available'"
        $sessionsResponse = Invoke-RestMethod -Uri $machineSessionsUri -Method Get -Headers $headers -ErrorAction Stop
        
        if ($sessionsResponse.value -and $sessionsResponse.value.Count -gt 0) {
            $sessionId = $sessionsResponse.value[0].Id
            $startInfo["MachineSessionIds"] = @([int]$sessionId)
            WriteLog "✅ Targeting Machine Session ID: $sessionId for Machine: $machine"
        } else {
            WriteLog "⚠️ No available sessions found for machine '$machine', trying fallback method"
            # Fallback: try using MachineIds (for older Orchestrator versions or different configurations)
            $startInfo["MachineIds"] = @([int]$machineId)
            WriteLog "✅ Targeting Machine ID: $machineId (fallback method)"
        }
    } catch {
        WriteLog "⚠️ Could not get machine sessions: $($_.Exception.Message)"
        WriteLog "⚠️ Using MachineIds fallback method"
        $startInfo["MachineIds"] = @([int]$machineId)
        WriteLog "✅ Targeting Machine ID: $machineId"
    }
}

# Log targeting summary
WriteLog "📋 Job Targeting Summary:"
if ($robotId) {
    WriteLog "   🤖 Robot: '$robots' (ID: $robotId)"
} else {
    WriteLog "   🤖 Robot: Dynamic allocation (no specific robot)"
}

if ($machineId) {
    WriteLog "   💻 Machine: '$machine' (ID: $machineId)"
} else {
    WriteLog "   💻 Machine: Dynamic allocation (no specific machine)"
}

$startJobBody = @{
    "startInfo" = $startInfo
} | ConvertTo-Json -Depth 10

WriteLog "Job request body:"
WriteLog $startJobBody

try {
    $startJobUri = "$orchestratorApiBase/odata/Jobs/UiPath.Server.Configuration.OData.StartJobs"
    WriteLog "Job start URI: $startJobUri"
    
    $jobResponse = Invoke-RestMethod -Uri $startJobUri -Method Post -Headers $headers -Body $startJobBody -ErrorAction Stop
    
    if ($jobResponse.value -and $jobResponse.value.Count -gt 0) {
        $jobId = $jobResponse.value[0].Id
        WriteLog "✅ Job started successfully! Job ID: $jobId"
        
        if ($wait -eq "true") {
            WriteLog "⏳ Waiting for job completion..."
            $timeoutSeconds = [int]$timeout
            $startTime = Get-Date
            
            do {
                Start-Sleep -Seconds 10
                $elapsedSeconds = ((Get-Date) - $startTime).TotalSeconds
                
                try {
                    $jobStatusUri = "$orchestratorApiBase/odata/Jobs($jobId)"
                    $jobStatus = Invoke-RestMethod -Uri $jobStatusUri -Method Get -Headers $headers -ErrorAction Stop
                    
                    $status = $jobStatus.State
                    $machineName = if ($jobStatus.Robot -and $jobStatus.Robot.MachineName) { $jobStatus.Robot.MachineName } else { "Unknown" }
                    $robotName = if ($jobStatus.Robot -and $jobStatus.Robot.Name) { $jobStatus.Robot.Name } else { "Unknown" }
                    
                    WriteLog "Job status: $status (elapsed: $([math]::Round($elapsedSeconds))s) - Running on Machine: $machineName, Robot: $robotName"
                    
                    if ($status -in @("Successful", "Failed", "Stopped", "Faulted")) {
                        WriteLog "✅ Job completed with status: $status"
                        WriteLog "📍 Final execution details - Machine: $machineName, Robot: $robotName"
                        
                        if ($fail_when_job_fails -eq "true" -and $status -in @("Failed", "Faulted")) {
                            WriteLog "❌ Job failed with status: $status" -err
                            exit 1
                        }
                        break
                    }
                    
                    if ($elapsedSeconds -ge $timeoutSeconds) {
                        WriteLog "⏰ Timeout reached ($timeout seconds)" -err
                        exit 1
                    }
                    
                } catch {
                    WriteLog "❌ Error checking job status: $($_.Exception.Message)" -err
                    exit 1
                }
                
            } while ($true)
        }
        
        WriteLog "🎉 Job execution completed successfully!"
        exit 0
    } else {
        WriteLog "❌ No jobs were started" -err
        exit 1
    }
    
} catch {
    WriteLog "❌ Error starting job: $($_.Exception.Message)" -err
    
    # Enhanced error logging
    if ($_.Exception.Response) {
        $statusCode = $_.Exception.Response.StatusCode
        WriteLog "HTTP Status Code: $statusCode" -err
        
        try {
            $errorStream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorStream)
            $errorBody = $reader.ReadToEnd()
            WriteLog "Detailed error response: $errorBody" -err
        } catch {
            WriteLog "Could not read detailed error response" -err
        }
    }
    
    WriteLog "🔧 TROUBLESHOOTING:" -err
    WriteLog "   1. Verify process '$processName' exists and is published" -err
    WriteLog "   2. Check if your external app has execution permissions" -err
    WriteLog "   3. Verify robot '$robots' and machine '$machine' exist and are available" -err
    WriteLog "   4. Ask admin to add required scopes to your external application" -err
    exit 1
}
