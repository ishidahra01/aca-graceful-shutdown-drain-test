# Pattern B Long Request / Scale-In Report

Date: 2026-03-29 UTC

## Scope

Validate Pattern B (`DRAIN_READINESS_ON_SIGTERM=true`, `REJECT_NEW_REQUESTS_ON_DRAIN=true`) under the same basic scenario as Pattern A by:

1. Sending parallel long requests through Application Gateway
2. Waiting for replica scale-out
3. Forcing `minReplicas=1,maxReplicas=1`
4. Comparing old-revision drain behavior and App Gateway backend health behavior against Pattern A

## Environment Snapshot

- Resource group: `acadrain-rg`
- Container app: `acadrain-app`
- Application Gateway URL: `http://20.104.165.187`
- Workspace ID used during this session: `c4f4a0e0-04ff-4520-8792-7cebcb744521`
- Pattern B test start time: `2026-03-29T13:57:23.3747940Z`

## Pattern B Configuration Confirmed Before Test

The app was redeployed for Pattern B and confirmed to be using:

- `DRAIN_READINESS_ON_SIGTERM=True`
- `REJECT_NEW_REQUESTS_ON_DRAIN=True`
- `EXIT_ON_IDLE_AFTER_SIGNAL=true`
- `terminationGracePeriodSeconds=120`

Pre-test state:

- latest revision: `acadrain-app--0000003`
- backend health: `Healthy`
- public endpoint `/health/ready`: `200`

## Commands Executed

### 1. Confirm Pattern B deployment state

```powershell
az containerapp show --resource-group acadrain-rg --name acadrain-app --query "properties.template.{terminationGracePeriodSeconds:terminationGracePeriodSeconds,scale:scale,containers:containers}" -o json
az network application-gateway show-backend-health --resource-group acadrain-rg --name acadrain-agw --query "backendAddressPools[0].backendHttpSettingsCollection[0].servers[0].{address:address,health:health,healthProbeLog:healthProbeLog}" -o json
Invoke-WebRequest -UseBasicParsing http://20.104.165.187/health/ready
```

### 2. Run Pattern B scenario

The scenario matched Pattern A in principle:

- start 6 parallel long requests to `/work?duration=60`
- poll until replica count scaled out to at least 2
- force `az containerapp update --min-replicas 1 --max-replicas 1`
- poll Application Gateway backend health every 5 seconds while the scenario ran

### 3. Check state after test

```powershell
az containerapp revision list --resource-group acadrain-rg --name acadrain-app --query "[].{name:name,active:properties.active,trafficWeight:properties.trafficWeight,healthState:properties.healthState,createdTime:properties.createdTime}" -o json
az containerapp replica list --resource-group acadrain-rg --name acadrain-app --query "[].{name:name,state:properties.runningState,created:properties.createdTime}" -o json
az network application-gateway show-backend-health --resource-group acadrain-rg --name acadrain-agw --query "backendAddressPools[0].backendHttpSettingsCollection[0].servers[0].{address:address,health:health,healthProbeLog:healthProbeLog}" -o json
(Invoke-WebRequest -UseBasicParsing http://20.104.165.187/health/ready).StatusCode
```

## Observed Results

### Revision / replica transition

After the forced scale-in update:

- active revision became `acadrain-app--0000004`
- that revision was `Healthy`
- traffic weight was `100`
- the remaining running replica was `acadrain-app--0000004-5f4849f5f8-gphbb`

Representative post-test result:

```json
[
  {
    "active": true,
    "createdTime": "2026-03-29T13:58:09+00:00",
    "healthState": "Healthy",
    "name": "acadrain-app--0000004",
    "trafficWeight": 100
  }
]
```

```json
[
  {
    "created": "2026-03-29T13:58:10Z",
    "name": "acadrain-app--0000004-5f4849f5f8-gphbb",
    "state": "Running"
  }
]
```

### App Gateway backend health during Pattern B

The background monitor sampled backend health every 5 seconds. The recovered output for samples 19 through 44 showed:

- `health = Healthy`
- `healthProbeLog = "Success. Received 200 status code"`

The final explicit backend-health check after the Pattern B run also returned:

```json
{
  "address": "acadrain-app.agreeablesand-53836cf5.canadaeast.azurecontainerapps.io",
  "health": "Healthy",
  "healthProbeLog": "Success. Received 200 status code"
}
```

The public health endpoint after the Pattern B run returned:

```text
200
```

## Comparison With Pattern A

### What is clearly different

- Pattern A had direct app evidence of `readiness.unchanged` on shutdown.
- Pattern B was deployed with `DRAIN_READINESS_ON_SIGTERM=true` and `REJECT_NEW_REQUESTS_ON_DRAIN=true`, so the intended old-revision behavior differs by configuration.

### What is clearly the same from the gateway side

- In Pattern A, Application Gateway remained usable throughout the exercise.
- In Pattern B, the recovered backend-health samples also stayed `Healthy`, and final public health remained `200`.

That means no externally visible Application Gateway backend-health degradation was observed in either run.

## Important Caveat

As with Pattern A, this was not a pure autoscaler-only same-revision scale-in.

The command used to force the scale change was:

```powershell
az containerapp update --min-replicas 1 --max-replicas 1
```

In `Single` revision mode, that produced a new revision and shifted traffic to it. For Pattern B, the effective sequence was:

1. long requests were started while revision `acadrain-app--0000003` was active
2. the scale-setting change created revision `acadrain-app--0000004`
3. traffic moved to the new revision
4. the old revision terminated afterward

So this validates revision replacement drain behavior under Pattern B settings, not a same-revision platform-only shrink.

## Missing Evidence / Limits

The key missing artifact for this session is direct old-revision log evidence for `acadrain-app--0000003`.

Attempts were made to recover:

- `readiness.changed`
- `shutdown.signal`
- `request.end`
- `request.rejected`
- `shutdown.exit`

from Log Analytics and revision-targeted log retrieval, but no old-revision log lines were recovered during this session for `acadrain-app--0000003`.

Because of that, the following statement cannot be claimed as directly proven from logs in this run:

- that `readiness.changed` was emitted on the terminating old revision

The strongest defensible conclusion is therefore:

- Pattern B was configured to drain readiness on `SIGTERM`
- the user-visible and gateway-visible path remained healthy throughout the observed transition
- direct old-revision log proof of `readiness.changed` was not recovered in this session

## Interpretation

### Confirmed

- Pattern B configuration was deployed correctly.
- The forced scale-setting change created a new active revision.
- Application Gateway backend health stayed `Healthy` in the recovered monitor output.
- Public `/health/ready` stayed `200` after the transition.

### Not confirmed from evidence collected here

- old-revision `readiness.changed`
- whether any new requests were explicitly rejected by the draining old revision
- a full client-side completion matrix for all 6 long requests in the Pattern B run

## Practical Takeaway

For this architecture, probing the app FQDN behind Application Gateway did not expose a visible backend-health transition during Pattern B. Even if readiness drain happened inside the terminating old revision, traffic had already shifted to the new active revision by the time the gateway-visible checks were sampled.

In other words, the measurable difference between Pattern A and Pattern B was not visible at the Application Gateway backend-health level in this revision-replacement setup.

## Cleanup / Restore

After the Pattern B test, scale settings were restored:

```powershell
az containerapp update --resource-group acadrain-rg --name acadrain-app --min-replicas 1 --max-replicas 5
```

That restore created a new latest revision:

```json
{
  "latestRevision": "acadrain-app--0000005",
  "maxReplicas": 5,
  "minReplicas": 1
}
```

Post-restore checks:

- Application Gateway backend health: `Healthy`
- public `/health/ready`: `200`