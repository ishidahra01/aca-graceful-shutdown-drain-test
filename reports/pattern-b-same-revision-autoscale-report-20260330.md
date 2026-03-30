# Pattern B Same-Revision Autoscaler Shrink Report

Date: 2026-03-30 UTC

## Scope

Validate Pattern B under pure autoscaler shrink conditions:

1. keep `Single` revision mode and do not update scale settings during the test
2. scale out by load only
3. stop the extra load
4. let ACA autoscaler shrink replicas within the same active revision
5. confirm that Application Gateway request completion and ACA shutdown behavior can coexist in the same run window

## Final Result

The target validation was confirmed.

- initial active revision: `acadrain-app--0000007`
- final active revision: `acadrain-app--0000007`
- scale-out: confirmed
- natural shrink back to one replica: confirmed
- delayed 60-second request through Application Gateway: completed with `200`
- app log correlation: `request.start` and `request.end` recovered for the successful request
- removed replica shutdown sequence: `shutdown.signal`, `readiness.changed`, `shutdown.exit` recovered in the same run window
- public `/health/ready`: remained `200`

This means the repo achieved the intended ACA-side behavior for Pattern B: same-revision autoscaler shrink and end-to-end request completion can coexist when the request is injected into the natural shrink window.

## Baseline Used

The stable baseline used for the final validation was:

```bash
./scripts/deploy-app.sh "$RESOURCE_GROUP" "$PREFIX" v1 120 true Single 5 1 5 600
```

Effective parameters:

- `DRAIN_READINESS_ON_SIGTERM=true`
- `REJECT_NEW_REQUESTS_ON_DRAIN=true`
- `terminationGracePeriodSeconds=120`
- `concurrentRequests=5`
- `minReplicas=1`
- `maxReplicas=5`

## Validation Flow

### 1. Measure shrink delay

Two measurement-only runs were executed first with `longParallelism=0` and `stopAfterFirstScaleReduction=true`.

- run 1: `loadStoppedAt=2026-03-30T07:44:03Z`, `firstScaleReductionAt=2026-03-30T07:51:16Z`, delay `433s`
- run 2: `loadStoppedAt=2026-03-30T07:51:43Z`, `firstScaleReductionAt=2026-03-30T07:59:06Z`, delay `443s`
- average measured delay: about `438s`

### 2. Validate request completion in the shrink window

After measuring the shrink delay, one 60-second request was injected `360s` after load stop.

Command:

```bash
./scripts/autoscale-shrink-test.sh acadrain-rg acadrain-app http://20.104.165.187 6 0.2 1 60 2 1200 360 false
```

Main result:

```json
{
  "initialRevision": "acadrain-app--0000007",
  "loadStoppedAt": "2026-03-30T08:01:30Z",
  "firstScaleReductionAt": "2026-03-30T08:08:40Z",
  "delayBeforeLongSeconds": 360,
  "longStartedAt": "2026-03-30T08:07:30Z",
  "longCompletedAt": "2026-03-30T08:08:31Z",
  "scaledOut": true,
  "shrunk": true,
  "statusCode": 200,
  "requestId": "long-1-1774858050860"
}
```

Interpretation:

- the active revision stayed `acadrain-app--0000007` throughout the run
- the request completed with `200` through Application Gateway
- the request finished before the first observed scale reduction
- shrink to one replica still completed in the same revision

## Evidence

### App-side request completion

The successful delayed request was recovered directly from app logs on replica `acadrain-app--0000007-7b7786c677-rj8df`.

```json
{
  "timestamp": "2026-03-30T08:07:32.850Z",
  "event": "request.start",
  "replica": "acadrain-app--0000007-7b7786c677-rj8df",
  "requestId": "long-1-1774858050860",
  "path": "/work?duration=60"
}
```

```json
{
  "timestamp": "2026-03-30T08:08:32.851Z",
  "event": "request.end",
  "replica": "acadrain-app--0000007-7b7786c677-rj8df",
  "requestId": "long-1-1774858050860",
  "path": "/work?duration=60",
  "elapsedMs": 60001
}
```

### Removed replica shutdown sequence

The removed replica from the same run window was `acadrain-app--0000007-7b7786c677-627v7`.

```json
{
  "timestamp": "2026-03-30T08:06:33.245Z",
  "event": "shutdown.signal",
  "replica": "acadrain-app--0000007-7b7786c677-627v7"
}
```

```json
{
  "timestamp": "2026-03-30T08:06:33.246Z",
  "event": "readiness.changed",
  "replica": "acadrain-app--0000007-7b7786c677-627v7",
  "ready": false,
  "reason": "SIGTERM"
}
```

```json
{
  "timestamp": "2026-03-30T08:06:33.246Z",
  "event": "shutdown.exit",
  "replica": "acadrain-app--0000007-7b7786c677-627v7",
  "reason": "no-active-requests"
}
```

### Gateway-visible health

During the validation window, Application Gateway backend health remained healthy and public `/health/ready` stayed `200`.

## What Was Proved

- pure autoscaler shrink occurred inside one revision
- replica count increased and later decreased without creating a new active revision
- the app returned to a single running replica
- the Application Gateway path still completed the validation request successfully
- the removed replica emitted the expected shutdown and readiness events

## What Was Not Proved

- successful completion on the replica that was actually removed
- `request.rejected` on a draining replica in this exact run

## Practical Conclusion

For this repo and topology, Pattern B is validated with the following approach:

1. deploy a stable baseline once
2. do not update the container app during the run
3. create scale-out by load only
4. stop only the synthetic short load
5. measure the natural shrink delay
6. inject a short validation request into the shrink window
7. confirm same-revision shrink, request completion, and removed-replica shutdown logs
