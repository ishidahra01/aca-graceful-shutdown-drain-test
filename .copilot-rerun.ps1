$ErrorActionPreference='Stop'
Set-Location 'C:\Users\hishida\repo\aca-graceful-shutdown-drain-test'

$base='http://20.104.165.187'
$resourceGroup='acadrain-rg'
$appName='acadrain-app'
$workspaceId='c4f4a0e0-04ff-4520-8792-7cebcb744521'
$healthFile='reports/pattern-b-autoscale-health-3.ndjson'
$replicaFile='reports/pattern-b-autoscale-rerun-replica-timeline.ndjson'
$finalFile='reports/pattern-b-autoscale-rerun-final.json'
$longFile='reports/pattern-b-autoscale-rerun-long-result.json'
$logsFile='reports/pattern-b-autoscale-rerun-shutdown-logs.json'
$publicReadyFile='reports/pattern-b-autoscale-rerun-public-ready.txt'
$debugFile='reports/pattern-b-autoscale-rerun-debug.log'
$testStart=Get-Date

Remove-Item $healthFile,$replicaFile,$finalFile,$longFile,$logsFile,$publicReadyFile,$debugFile -ErrorAction SilentlyContinue

function Write-DebugLine {
  param([string]$Message)
  $line = "$(Get-Date -Format o) $Message"
  Add-Content -Path $debugFile -Value $line
  Write-Host $line
}

function Add-Ndjson {
  param([string]$Path,[object]$Object)
  $Object | ConvertTo-Json -Depth 10 -Compress | Add-Content $Path
}

function Invoke-WithRetry {
  param([scriptblock]$Block,[int]$MaxAttempts=6)
  for($i=1;$i -le $MaxAttempts;$i++){
    try {
      return & $Block
    } catch {
      if($i -eq $MaxAttempts){ throw }
      Start-Sleep -Seconds ([Math]::Min(15,$i*3))
    }
  }
}

function Get-ActiveRevision {
  az containerapp revision list -g $resourceGroup -n $appName --query "[?properties.active].name | [0]" -o tsv
}

function Get-Replicas {
  az containerapp replica list -g $resourceGroup -n $appName -o json | ConvertFrom-Json
}

function Get-BackendHealth {
  $server = az network application-gateway show-backend-health -g $resourceGroup -n acadrain-agw -o json |
    ConvertFrom-Json |
    Select-Object -ExpandProperty backendAddressPools |
    Select-Object -First 1 |
    Select-Object -ExpandProperty backendHttpSettingsCollection |
    Select-Object -First 1 |
    Select-Object -ExpandProperty servers |
    Select-Object -First 1
  [pscustomobject]@{health=$server.health;address=$server.address;detail=$server.healthProbeLog}
}

function Invoke-PublicReady {
  try {
    $response = Invoke-WebRequest -UseBasicParsing "$base/health/ready"
    return [pscustomobject]@{ statusCode = $response.StatusCode; ok = $true; error = $null }
  } catch {
    $statusCode = $null
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $statusCode = [int]$_.Exception.Response.StatusCode
    }
    return [pscustomobject]@{ statusCode = $statusCode; ok = $false; error = $_.Exception.Message }
  }
}

$initialRevision = Invoke-WithRetry { Get-ActiveRevision }
$initialReplicas = @((Invoke-WithRetry { Get-Replicas }) | ForEach-Object { $_.name })
Write-DebugLine "Initial revision: $initialRevision"
Write-DebugLine "Initial replicas: $($initialReplicas -join ', ')"

$shortJobs = @()
foreach($i in 1..6){
  $shortJobs += Start-Job -ScriptBlock {
    param($u,$workerId)
    while($true){
      $rid = "short-$workerId-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
      try {
        curl.exe --silent --show-error --output NUL -H "x-request-id: $rid" "$u/work?duration=1" | Out-Null
      } catch {}
      Start-Sleep -Milliseconds 200
    }
  } -ArgumentList $base,$i
}

$longRequestId = "long-autoscale-timeout600-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$longJob = Start-Job -ScriptBlock {
  param($u,$rid)
  $body = & curl.exe --silent --show-error --fail --max-time 700 -H "x-request-id: $rid" "$u/work?duration=360" 2>&1
  $bodyText = ($body | Out-String).Trim()
  if ($LASTEXITCODE -eq 0) {
    [pscustomobject]@{ requestId = $rid; ok = $true; exitCode = 0; body = $bodyText }
    return
  }

  [pscustomobject]@{ requestId = $rid; ok = $false; exitCode = $LASTEXITCODE; body = $bodyText }
} -ArgumentList $base,$longRequestId

$scaledOut = $false
$shrunk = $false
$loadStoppedAt = $null
$scaleOutAt = $null
$shrinkAt = $null
$finalReplicaNames = @()
$seenAfterLoadStop = New-Object 'System.Collections.Generic.HashSet[string]'

for($attempt=1; $attempt -le 180; $attempt++){
  $utc = (Get-Date).ToUniversalTime().ToString('o')
  $activeRevision = Invoke-WithRetry { Get-ActiveRevision }
  $replicas = @((Invoke-WithRetry { Get-Replicas }))
  $replicaNames = @($replicas | ForEach-Object { $_.name })
  if($loadStoppedAt){ foreach($name in $replicaNames){ [void]$seenAfterLoadStop.Add($name) } }
  $health = Invoke-WithRetry { Get-BackendHealth }

  Add-Ndjson $replicaFile ([pscustomobject]@{
    utc=$utc
    attempt=$attempt
    phase=$(if($scaledOut){'shrink'}else{'scaleOut'})
    activeRevision=$activeRevision
    replicaCount=$replicaNames.Count
    replicaNames=$replicaNames
  })

  Add-Ndjson $healthFile ([pscustomobject]@{
    utc=$utc
    sample=$attempt
    health=$health.health
    address=$health.address
    detail=$health.detail
  })

  Write-DebugLine "attempt=$attempt phase=$(if($scaledOut){'shrink'}else{'scaleOut'}) replicas=$($replicaNames.Count) revision=$activeRevision health=$($health.health)"

  if(-not $scaledOut -and $replicaNames.Count -ge 2){
    $scaledOut = $true
    $scaleOutAt = $utc
    $loadStoppedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-DebugLine "Scale-out confirmed at $scaleOutAt; stopping short-load workers"
    foreach($job in $shortJobs){ Stop-Job $job -ErrorAction SilentlyContinue }
    foreach($job in $shortJobs){ Remove-Job $job -Force -ErrorAction SilentlyContinue }
    $shortJobs = @()
    foreach($name in $replicaNames){ [void]$seenAfterLoadStop.Add($name) }
  }

  if($scaledOut -and $activeRevision -ne $initialRevision){
    throw "Active revision changed unexpectedly from $initialRevision to $activeRevision"
  }

  if($scaledOut -and $replicaNames.Count -le 1){
    $shrunk = $true
    $shrinkAt = $utc
    $finalReplicaNames = $replicaNames
    Write-DebugLine "Shrink confirmed at $shrinkAt; final replicas: $($finalReplicaNames -join ', ')"
    break
  }

  Start-Sleep -Seconds $(if($scaledOut){10}else{5})
}

if($shortJobs.Count -gt 0){
  foreach($job in $shortJobs){ Stop-Job $job -ErrorAction SilentlyContinue }
  foreach($job in $shortJobs){ Remove-Job $job -Force -ErrorAction SilentlyContinue }
}

if(-not $shrunk){
  $finalReplicaNames = @((Invoke-WithRetry { Get-Replicas }) | ForEach-Object { $_.name })
}

$removedReplicas = @($seenAfterLoadStop | Where-Object { $_ -and ($_ -notin $finalReplicaNames) } | Sort-Object -Unique)
Write-DebugLine "Removed replicas: $($removedReplicas -join ', ')"

$logResults = @()
foreach($replica in $removedReplicas){
  $events = @()
  for($try=1; $try -le 10; $try++){
    $query = @"
ContainerAppConsoleLogs_CL
| where TimeGenerated between (datetime($($testStart.ToUniversalTime().ToString('o'))) .. now())
| extend parsed = parse_json(Log_s)
| extend event = tostring(parsed.event), replica = tostring(parsed.replica)
| where ContainerGroupName_s == "$replica" or replica == "$replica"
| where event in ("shutdown.signal","readiness.changed","shutdown.waiting","shutdown.exit","request.rejected")
| project TimeGenerated, RevisionName_s, ContainerGroupName_s, event, Log_s
| order by TimeGenerated asc
"@
    $result = az monitor log-analytics query --workspace $workspaceId --analytics-query $query -o json | ConvertFrom-Json
    $table = $result.tables | Select-Object -First 1
    if($table -and $table.rows){
      $events = @($table.rows | ForEach-Object {
        [pscustomobject]@{
          TimeGenerated = $_[0]
          RevisionName = $_[1]
          ReplicaName = $_[2]
          Event = $_[3]
          Log = $_[4]
        }
      })
      if($events.Count -gt 0){ break }
    }
    Start-Sleep -Seconds 20
  }
  Write-DebugLine "Replica $replica yielded $($events.Count) shutdown-related log rows"
  $logResults += [pscustomobject]@{replica=$replica;events=$events}
}
$logResults | ConvertTo-Json -Depth 10 | Set-Content $logsFile

$longWait = Wait-Job -Job $longJob -Timeout 900
if(-not $longWait){ Stop-Job $longJob -ErrorAction SilentlyContinue }
$longResult = Receive-Job $longJob -ErrorAction SilentlyContinue
$longResult | ConvertTo-Json -Depth 10 | Set-Content $longFile
Remove-Job $longJob -Force -ErrorAction SilentlyContinue

$publicReady = Invoke-PublicReady
$publicReady.statusCode | Set-Content $publicReadyFile
$finalHealth = Invoke-WithRetry { Get-BackendHealth }

[pscustomobject]@{
  testStart=$testStart.ToUniversalTime().ToString('o')
  initialRevision=$initialRevision
  initialReplicas=$initialReplicas
  scaledOut=$scaledOut
  scaleOutAt=$scaleOutAt
  loadStoppedAt=$loadStoppedAt
  shrunk=$shrunk
  shrinkAt=$shrinkAt
  finalRevision=(Invoke-WithRetry { Get-ActiveRevision })
  finalReplicaNames=$finalReplicaNames
  removedReplicas=$removedReplicas
  longRequestId=$longRequestId
  longResult=$longResult
  finalBackendHealth=$finalHealth
  publicReady=$publicReady
  replicaTimelineFile=$replicaFile
  healthTimelineFile=$healthFile
  shutdownLogsFile=$logsFile
  debugFile=$debugFile
} | ConvertTo-Json -Depth 10 | Set-Content $finalFile

Get-Content $finalFile
