# Pattern A Long Request / Scale-In Report

Date: 2026-03-29 UTC

## Scope

Validate Pattern A (`DRAIN_READINESS_ON_SIGTERM=false`, `REJECT_NEW_REQUESTS_ON_DRAIN=false`) by:

1. Sending parallel long requests through Application Gateway
2. Waiting for replica scale-out
3. Forcing `minReplicas=1,maxReplicas=1`
4. Checking whether existing requests complete and whether shutdown logs match the expected Pattern A behavior

## Environment Snapshot

- Resource group: `acadrain-rg`
- Container app: `acadrain-app`
- Application Gateway URL: `http://20.104.165.187`
- Workspace ID: `c4f4a0e0-04ff-4520-8792-7cebcb744521`
- Test start time: `2026-03-29T00:24:23.2666506Z`

## Commands Executed

### 1. Confirm starting state

```powershell
az containerapp show --resource-group acadrain-rg --name acadrain-app --query "properties.template.scale.{minReplicas:minReplicas,maxReplicas:maxReplicas}" -o json
az containerapp replica list --resource-group acadrain-rg --name acadrain-app --query "[].{name:name,state:properties.runningState,created:properties.createdTime}" -o json
az containerapp revision list --resource-group acadrain-rg --name acadrain-app --query "[].{name:name,active:properties.active,trafficWeight:properties.trafficWeight,healthState:properties.healthState}" -o json
```

Result:

- `minReplicas=1`
- `maxReplicas=5`
- single running replica: `acadrain-app--lz9g260-56fc7bd5bd-76j7k`
- active revision: `acadrain-app--lz9g260`

### 2. Confirm ingress path before test

```powershell
az network application-gateway show-backend-health --resource-group acadrain-rg --name acadrain-agw --query "backendAddressPools[0].backendHttpSettingsCollection[0].servers" -o json
Invoke-WebRequest -UseBasicParsing http://20.104.165.187/health/ready
```

Result:

- backend health: `Healthy`
- public endpoint `/health/ready`: `200`

### 3. Run Pattern A scenario

```powershell
$base='http://20.104.165.187'
$parallel=6
$duration=60

# start 6 long requests in parallel
# poll replica count until scale-out to >= 2
# then force min/max replicas to 1
az containerapp update --resource-group acadrain-rg --name acadrain-app --min-replicas 1 --max-replicas 1
```

Actual execution result:

```json
{
  "requestIds": [
    "long-1-1774743865",
    "long-2-1774743865",
    "long-3-1774743866",
    "long-4-1774743866",
    "long-5-1774743866",
    "long-6-1774743867"
  ],
  "scaledOut": true,
  "scaleInInvoked": true,
  "replicaTimeline": [
    {
      "attempt": 1,
      "utc": "2026-03-29T00:24:38.2674447Z",
      "replicas": 1
    },
    {
      "attempt": 2,
      "utc": "2026-03-29T00:24:56.1046712Z",
      "replicas": 2
    }
  ]
}
```

### 4. Long request completion results

All six requests returned successfully.

Representative outputs:

```json
{"ok":true,"requestId":"long-1-1774743865","durationSeconds":60,"replica":"acadrain-app--lz9g260-56fc7bd5bd-76j7k","readiness":true,"draining":false}
{"ok":true,"requestId":"long-2-1774743865","durationSeconds":60,"replica":"acadrain-app--lz9g260-56fc7bd5bd-76j7k","readiness":true,"draining":false}
{"ok":true,"requestId":"long-3-1774743866","durationSeconds":60,"replica":"acadrain-app--lz9g260-56fc7bd5bd-76j7k","readiness":true,"draining":false}
{"ok":true,"requestId":"long-4-1774743866","durationSeconds":60,"replica":"acadrain-app--lz9g260-56fc7bd5bd-76j7k","readiness":true,"draining":false}
{"ok":true,"requestId":"long-5-1774743866","durationSeconds":60,"replica":"acadrain-app--lz9g260-56fc7bd5bd-76j7k","readiness":true,"draining":false}
{"ok":true,"requestId":"long-6-1774743867","durationSeconds":60,"replica":"acadrain-app--lz9g260-56fc7bd5bd-76j7k","readiness":true,"draining":false}
```

## Post-Test State

### Replica state after scale-in

```powershell
az containerapp replica list --resource-group acadrain-rg --name acadrain-app --query "[].{name:name,state:properties.runningState,created:properties.createdTime}" -o json
```

Result:

```json
[
  {
    "created": "2026-03-29T00:25:12Z",
    "name": "acadrain-app--0000001-56784877c9-bqhvv",
    "state": "Running"
  }
]
```

### Revision state after test

```powershell
az containerapp revision list --resource-group acadrain-rg --name acadrain-app --query "[].{name:name,active:properties.active,trafficWeight:properties.trafficWeight,healthState:properties.healthState,createdTime:properties.createdTime}" -o json
```

Result:

```json
[
  {
    "active": true,
    "createdTime": "2026-03-29T00:25:11+00:00",
    "healthState": "Healthy",
    "name": "acadrain-app--0000001",
    "trafficWeight": 100
  }
]
```

## Relevant Logs Observed

From Log Analytics for old replica `acadrain-app--lz9g260-56fc7bd5bd-76j7k`:

```json
{"timestamp":"2026-03-29T00:26:04.048Z","event":"readiness.unchanged","replica":"acadrain-app--lz9g260-56fc7bd5bd-76j7k","pid":1,"readiness":true,"draining":true,"activeRequests":0,"reason":"drain disabled by configuration"}
{"timestamp":"2026-03-29T00:26:04.048Z","event":"shutdown.exit","replica":"acadrain-app--lz9g260-56fc7bd5bd-76j7k","pid":1,"readiness":true,"draining":true,"activeRequests":0,"reason":"no-active-requests"}
```

Notes:

- `readiness.changed` was not observed for this run, which is correct for Pattern A.
- `shutdown.signal` for the current run was not captured in the Log Analytics output retrieved during this session, although the app state (`draining=true`) and `shutdown.exit` indicate shutdown handling occurred.
- All six long requests completed successfully from the client side.

## Interpretation

### What matched Pattern A expectations

- Long requests completed successfully; no client-side interruption occurred.
- No `readiness.changed` was observed.
- `readiness.unchanged` was observed with `reason="drain disabled by configuration"`.
- Shutdown completed with `reason="no-active-requests"` after requests finished.

### Important caveat

This was not a pure autoscaler-driven replica scale-in.

The command used to force scale-in was:

```powershell
az containerapp update --min-replicas 1 --max-replicas 1
```

That change is revision-scoped, so in `Single` revision mode it created a new revision (`acadrain-app--0000001`) and cut traffic over to it. The old revision then terminated. That means this validation is closer to:

- `long requests in old revision`
- `new revision created by config update`
- `old revision shutdown after active requests drained`

than to a pure platform autoscale shrink of the same revision.

## Final Assessment

Pattern A behavior was partially confirmed:

- Confirmed: existing long requests were allowed to complete.
- Confirmed: no readiness drain happened (`readiness.unchanged`, not `readiness.changed`).
- Confirmed: old serving replica exited only after active work was gone.
- Not fully confirmed: this run used revision replacement as the trigger, not a same-revision autoscaler-only scale-in.
- Not fully confirmed: `shutdown.signal` was not directly recovered from Log Analytics for this exact run.

## Cleanup / Restore

After the test, scale settings were restored:

```powershell
az containerapp update --resource-group acadrain-rg --name acadrain-app --min-replicas 1 --max-replicas 5
```

Current state after restore:

```json
{
  "latestRevision": "acadrain-app--0000002",
  "maxReplicas": 5,
  "minReplicas": 1
}
```

Application Gateway backend health remained healthy after restore.