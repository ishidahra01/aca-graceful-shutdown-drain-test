# Pattern B Same-Revision Autoscaler Shrink Report

Date: 2026-03-30 UTC

## Scope

Validate Pattern B under pure autoscaler shrink conditions:

1. keep `Single` revision mode but do not update scale settings during the test
2. scale out by load only
3. stop the extra load
4. let ACA autoscaler shrink replicas within the same active revision
5. compare gateway-visible behavior and app-visible behavior

## Key Result

Pure autoscaler shrink within the same revision was confirmed.

- initial active revision: `acadrain-app--0000007`
- final active revision: `acadrain-app--0000007`
- scale-out: confirmed
- natural shrink back to one replica: confirmed
- delayed 60-second request through Application Gateway: completed with `200`
- app log correlation: `request.start` and `request.end` recovered for the successful delayed request
- removed replica shutdown sequence: `shutdown.signal`, `readiness.changed`, `shutdown.exit` recovered in the same run window
- public `/health/ready`: remained `200`

This is the first run in this repo/session that clearly validated `same revision x autoscale shrink` rather than revision replacement.

The delayed-injection rerun also validated the user-facing question that matters more here: `same-revision shrink` and `Application Gateway` end-to-end completion can coexist in the same run, as long as the validation request is injected near the natural shrink window instead of trying to exceed the separate gateway timeout ceiling.

## Important Findings Before the Final Run

### 1. `concurrentRequests=1` was too aggressive in this topology

When the app was redeployed with `concurrentRequests=1`, the environment did not settle cleanly back to a single idle replica.

Observed behavior:

- idle-looking replicas stayed at `3`
- `/state` showed `activeRequests=0`, but replicas remained up
- a newly started replica with `requestsStarted=0` also appeared

Most likely reason:

- Application Gateway backend probes and other health traffic become significant enough relative to the scaler threshold and distort the autoscale signal.

Practical conclusion:

- for this Application Gateway-fronted topology, `concurrentRequests=1` is not a good baseline for pure autoscaler shrink testing
- `concurrentRequests=5` was the more stable baseline

### 2. Application Gateway request timeout blocked long in-flight validation

`infra/main.bicep` had `requestTimeout: 120` on the backend HTTP settings.

That means a long request above 120 seconds can fail at the gateway even if the app itself might still be alive and draining correctly.

This mattered in the final run because the long request used to keep one replica busy returned `504 Gateway Time-out` through Application Gateway.

Practical conclusion:

- same-revision shrink was validated
- but in-flight completion through Application Gateway was not proven in this run because the gateway timeout was shorter than the request duration

## Final Baseline Used

The final, stable baseline for same-revision shrink testing was:

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
- active revision before final run: `acadrain-app--0000007`

## Final Run

### Test start

- test start: `2026-03-30T01:24:29.8284688Z`
- initial revision: `acadrain-app--0000007`

### Execution shape

The final run used:

- 6 short-load workers calling `/work?duration=1`
- load-only scale-out to at least 2 replicas
- one long request with request ID `long-autoscale-final-1774833948`
- short-load workers stopped after long request was launched
- no revision update during the run
- autoscaler observed until replica count returned to 1

### Command result

```json
{
  "testStart": "2026-03-30T01:24:29.8284688Z",
  "initialRevision": "acadrain-app--0000007",
  "scaledOut": true,
  "longRequestId": "long-autoscale-final-1774833948",
  "shrunk": true,
  "finalRevision": "acadrain-app--0000007",
  "finalReplicaCount": 1
}
```

### Replica timeline

Representative timeline:

```json
[
  {
    "phase": "scaleOut",
    "utc": "2026-03-30T01:25:48.0278450Z",
    "activeRevision": "acadrain-app--0000007",
    "replicaCount": 2,
    "replicaNames": [
      "acadrain-app--0000007-7b7786c677-q7vkh",
      "acadrain-app--0000007-7b7786c677-rj8df"
    ]
  },
  {
    "phase": "shrink",
    "utc": "2026-03-30T01:26:32.3521004Z",
    "activeRevision": "acadrain-app--0000007",
    "replicaCount": 3,
    "replicaNames": [
      "acadrain-app--0000007-7b7786c677-d9cdr",
      "acadrain-app--0000007-7b7786c677-q7vkh",
      "acadrain-app--0000007-7b7786c677-rj8df"
    ]
  },
  {
    "phase": "shrink",
    "utc": "2026-03-30T01:33:27.7003053Z",
    "activeRevision": "acadrain-app--0000007",
    "replicaCount": 1,
    "replicaNames": [
      "acadrain-app--0000007-7b7786c677-rj8df"
    ]
  }
]
```

Interpretation:

- the active revision stayed fixed at `acadrain-app--0000007`
- extra replicas were added and later removed inside the same revision
- the run therefore exercised autoscaler-driven replica shrink, not revision replacement

## Gateway-Side Observations

### Backend health

Application Gateway backend health remained healthy throughout the observed final run window.

Representative samples from `reports/pattern-b-autoscale-health-2.ndjson`:

```json
{"utc":"2026-03-30T01:24:28.9171061Z","sample":14,"health":"Healthy","detail":"Success. Received 200 status code"}
{"utc":"2026-03-30T01:29:47.7645487Z","sample":24,"health":"Healthy","detail":"Success. Received 200 status code"}
{"utc":"2026-03-30T01:33:25.0932137Z","sample":32,"health":"Healthy","detail":"Success. Received 200 status code"}
{"utc":"2026-03-30T01:37:29.0152218Z","sample":40,"health":"Healthy","detail":"Success. Received 200 status code"}
```

### Post-run checks

```json
{
  "address": "acadrain-app.agreeablesand-53836cf5.canadaeast.azurecontainerapps.io",
  "detail": "Success. Received 200 status code",
  "health": "Healthy"
}
```

```text
200
```

So even during same-revision autoscaler shrink, no gateway-visible backend health degradation was observed.

## App-Side Observations

### Long request result

The long request returned:

```json
{
  "requestId": "long-autoscale-final-1774833948",
  "ok": false,
  "statusCode": -1,
  "body": "Response status code does not indicate success: 504 (Gateway Time-out)."
}
```

This should be interpreted carefully:

- it does not by itself prove an app-side drain failure
- it is consistent with the Application Gateway backend request timeout being shorter than the long request duration

### Logs recovered

Recovered Log Analytics data clearly showed request traffic on the removed replica(s), for example `acadrain-app--0000007-7b7786c677-q7vkh`.

However, direct old-replica log recovery for the following events was still incomplete in this session:

- `shutdown.signal`
- `readiness.changed`
- `shutdown.waiting`
- `shutdown.exit`
- `request.rejected`

So this final run confirms same-revision autoscale shrink, but does not directly prove the exact shutdown-event sequence from logs.

## What Was Confirmed

- pure autoscaler shrink occurred inside one revision
- replica count increased and later decreased without creating a new active revision
- the final active revision stayed `acadrain-app--0000007`
- the app returned to a single running replica
- Application Gateway backend health remained `Healthy`
- public health endpoint stayed `200`

## Delayed-Injection Rerun

To answer the narrower validation question, the test was rerun with a short request that was intentionally delayed into the shrink window instead of using a request long enough to hit the gateway timeout ceiling.

### Shrink-delay measurement

Two measurement-only runs were executed first with `longParallelism=0` and `stopAfterFirstScaleReduction=true`.

- run 1: `loadStoppedAt=2026-03-30T07:44:03Z`, `firstScaleReductionAt=2026-03-30T07:51:16Z`, delay `433s`
- run 2: `loadStoppedAt=2026-03-30T07:51:43Z`, `firstScaleReductionAt=2026-03-30T07:59:06Z`, delay `443s`
- average measured shrink delay: about `438s`
- chosen delayed injection for the main run: `360s`

### Baseline control

A standalone 60-second request through Application Gateway succeeded before the main rerun.

```json
{
  "requestId": "agw-baseline-60-1774857579",
  "startUtc": "2026-03-30T07:59:38.5846338Z",
  "endUtc": "2026-03-30T08:00:39.1064764Z",
  "elapsedSeconds": 60.52,
  "ok": true,
  "exitCode": 0
}
```

### Main delayed run

Command shape:

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

- the active revision stayed `acadrain-app--0000007` throughout the rerun
- the long request completed with `200` through Application Gateway
- the long request finished at `08:08:31Z`
- shrink to one replica was observed immediately afterward, with first reduction recorded at `08:08:40Z`

### App-log correlation

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

This rerun does not show the successful 60-second request completing on the removed replica itself. It shows the weaker but sufficient condition that the app completed a user request through Application Gateway while same-revision shrink and removed-replica shutdown were happening in the same overall run.

## What Was Not Fully Confirmed

- successful completion on the removed replica itself
- `request.rejected` on a draining replica in this exact delayed rerun
- exact App Gateway access-log row tied to the request ID, because the client-side `200` result and app-side request correlation were already sufficient for this pass criterion

## Comparison to Earlier Runs

Compared with the earlier Pattern A / Pattern B revision-replacement runs, this run is different in the critical way that matters:

- earlier runs changed revision during the test
- this run kept the same revision throughout the scale-out and shrink cycle

That means this run is the correct shape for validating autoscaler shrink behavior.

## Practical Conclusion

For this repo and topology, the correct validation pattern is:

1. deploy a stable baseline once
2. do not update the container app during the run
3. create scale-out by load only
4. remove only the synthetic load
5. observe same-revision shrink

Additional tuning needed for full drain validation through Application Gateway:

1. keep `concurrentRequests` high enough that health probes do not pin extra replicas
2. set `appGatewayRequestTimeout` longer than the long request you use for validation
3. collect shutdown/readiness logs by replica name immediately after the shrink window
4. if you want the harder proof, target a request at the replica that is actually being removed rather than only overlapping with the shrink window

## 600s Timeout Rerun

After the Application Gateway backend request timeout was raised to `600`, the same-revision shrink scenario was rerun without any revision update during the test.

### Rerun summary

- active revision before rerun: `acadrain-app--0000007`
- active revision after rerun: `acadrain-app--0000007`
- scale-out: confirmed
- shrink back to one replica: confirmed
- surviving final replica: `acadrain-app--0000007-7b7786c677-rj8df`
- removed replica confirmed from replica timeline: `acadrain-app--0000007-7b7786c677-52h4d`
- Application Gateway backend health during rerun: always `Healthy`
- public `/health/ready` after rerun: `200`

Representative rerun timeline from `reports/pattern-b-autoscale-rerun-replica-timeline.ndjson`:

```json
[
  {
    "utc": "2026-03-30T04:30:17.9962705Z",
    "phase": "scaleOut",
    "activeRevision": "acadrain-app--0000007",
    "replicaCount": 2,
    "replicaNames": [
      "acadrain-app--0000007-7b7786c677-52h4d",
      "acadrain-app--0000007-7b7786c677-rj8df"
    ]
  },
  {
    "utc": "2026-03-30T04:37:34.9865718Z",
    "phase": "shrink",
    "activeRevision": "acadrain-app--0000007",
    "replicaCount": 1,
    "replicaNames": [
      "acadrain-app--0000007-7b7786c677-rj8df"
    ]
  }
]
```

### Removed replica logs

For the removed replica `acadrain-app--0000007-7b7786c677-52h4d`, Log Analytics did return shutdown/readiness events in the rerun window:

```json
[
  {
    "timestamp": "2026-03-30T04:35:48.914Z",
    "event": "shutdown.signal",
    "replica": "acadrain-app--0000007-7b7786c677-52h4d",
    "activeRequests": 0
  },
  {
    "timestamp": "2026-03-30T04:35:48.915Z",
    "event": "readiness.changed",
    "replica": "acadrain-app--0000007-7b7786c677-52h4d",
    "ready": false,
    "reason": "SIGTERM"
  },
  {
    "timestamp": "2026-03-30T04:35:48.915Z",
    "event": "shutdown.exit",
    "replica": "acadrain-app--0000007-7b7786c677-52h4d",
    "reason": "no-active-requests"
  }
]
```

No `shutdown.waiting` row was observed for that replica, which is consistent with `activeRequests=0` at signal time. No `request.rejected` row was observed for that replica in the rerun window either.

### Long request verdict under 600s timeout

The rerun still returned `504` to the client through Application Gateway. However, app-side logs show that the 360-second request was started and completed normally on the surviving replica:

```json
[
  {
    "timestamp": "2026-03-30T04:30:23.537Z",
    "event": "request.start",
    "replica": "acadrain-app--0000007-7b7786c677-rj8df",
    "requestId": "long-autoscale4timeout600-1774845016",
    "path": "/work?duration=360"
  },
  {
    "timestamp": "2026-03-30T04:36:23.538Z",
    "event": "request.end",
    "replica": "acadrain-app--0000007-7b7786c677-rj8df",
    "requestId": "long-autoscale4timeout600-1774845016",
    "elapsedMs": 360001
  }
]
```

This changes the interpretation materially:

- the request did complete inside the app
- the removed replica was a different replica (`52h4d`), so the long request was not killed by replica termination
- the client-side `504` therefore appears to be generated on the gateway/proxy path after the app completed, not by app-side drain failure
- because the backend HTTP setting was already confirmed as `requestTimeout=600`, this `504` is not explained by the previous 120-second timeout misconfiguration

### Updated conclusion

The success conditions for the rerun were partially met:

- same-revision pure autoscaler shrink: confirmed
- removed replica `readiness.changed` and `shutdown.*` recovery: confirmed for `shutdown.signal`, `readiness.changed`, `shutdown.exit`
- long request app-side completion: confirmed
- end-to-end completion through Application Gateway: not confirmed, because the client still received `504` even though the app completed the request

The remaining open issue is now narrower than before: investigate why Application Gateway still returns `504` for a request that the surviving replica finishes within 360 seconds while backend health stays `Healthy` and `requestTimeout` is `600`.

## Gateway Timeout Threshold Follow-Up

After the rerun, the remaining question was whether the `504` was specific to scale/drain, or whether the Application Gateway path itself had an independent timeout ceiling.

### Baseline threshold tests without scale activity

With the app back at a single-replica steady state, additional long-request probes were sent through Application Gateway without any scale-out or shrink activity.

Observed results:

```json
[
  {
    "requestId": "agw-threshold-230-1774847388",
    "durationSeconds": 230,
    "exitCode": 0,
    "elapsedSeconds": 230.59
  },
  {
    "requestId": "agw-threshold-260-1774847393",
    "durationSeconds": 260,
    "exitCode": 22,
    "elapsedSeconds": 240.94,
    "error": "curl: (22) The requested URL returned error: 504"
  },
  {
    "requestId": "agw-baseline-after-pip15-1774847733",
    "durationSeconds": 360,
    "exitCode": 22,
    "elapsedSeconds": 240.49,
    "error": "curl: (22) The requested URL returned error: 504"
  }
]
```

Interpretation:

- `230s` succeeds end-to-end through Application Gateway
- `260s` fails, but not after `260s`; it fails at about `241s`
- `360s` also fails at about `240s`

This is strong evidence that the effective client-visible timeout on the gateway path is around four minutes and is not primarily controlled by the backend HTTP setting `requestTimeout=600`.

### Public IP idle-timeout check

The Application Gateway public IP was inspected and then updated:

```json
{
  "name": "acadrain-agw-pip",
  "sku": "Standard",
  "idleTimeoutInMinutes": 4,
  "ipAddress": "20.104.165.187"
}
```

It was then raised to `15` minutes for validation. After the update, the resource showed:

```json
{
  "idleTimeoutInMinutes": 15
}
```

However, the `360s` baseline request still returned `504` after about `240.49s`.

So in this environment, increasing the public IP idle timeout alone was not sufficient to eliminate the four-minute failure.

### App-side evidence for the post-change baseline request

The latest baseline request after the public IP change was still expected to complete inside the app, and that remained consistent with the earlier rerun evidence: the application continues to finish the long request while the client receives `504` on the gateway path.

### Application Gateway diagnostics

Application Gateway diagnostics were enabled to the existing Log Analytics workspace during this investigation. Access logs started ingesting successfully:

```json
[
  {
    "Category": "ApplicationGatewayAccessLog",
    "count_": "4"
  }
]
```

This means a future session can continue by querying the access log rows around these request IDs without needing to re-enable diagnostics.

### Access-log and app-log correlation rerun

To remove ambiguity from the earlier threshold notes, two fresh baseline requests were rerun after diagnostics were already flowing, and the earlier `360s` case was correlated against the same workspace.

Correlated evidence:

```json
[
  {
    "requestId": "agw-threshold-230-rerun-1774851728",
    "path": "/work?duration=230",
    "clientElapsedSeconds": 230.56,
    "gateway": {
      "timeGenerated": "2026-03-30T06:26:01Z",
      "httpStatus": 200,
      "serverStatus": 200,
      "timeTakenSeconds": 230.004,
      "serverResponseLatencySeconds": 230.007
    },
    "app": {
      "start": "2026-03-30T06:22:12.3220185Z",
      "end": "2026-03-30T06:26:02.4042968Z",
      "elapsedMs": 230001,
      "replica": "acadrain-app--0000007-7b7786c677-rj8df"
    }
  },
  {
    "requestId": "agw-threshold-260-rerun-1774851969",
    "path": "/work?duration=260",
    "clientElapsedSeconds": 240.73,
    "gateway": {
      "timeGenerated": "2026-03-30T06:30:11Z",
      "httpStatus": 504,
      "serverStatus": 504,
      "timeTakenSeconds": 240.002,
      "serverResponseLatencySeconds": 239.998
    },
    "app": {
      "start": "2026-03-30T06:26:13.2785453Z",
      "end": "2026-03-30T06:30:32.5390874Z",
      "elapsedMs": 260001,
      "replica": "acadrain-app--0000007-7b7786c677-rj8df"
    }
  },
  {
    "requestId": "agw-baseline-after-pip15-1774847733",
    "path": "/work?duration=360",
    "gateway": {
      "timeGenerated": "2026-03-30T05:19:35Z",
      "httpStatus": 504,
      "serverStatus": 504,
      "timeTakenSeconds": 240.009,
      "serverResponseLatencySeconds": 240.011
    },
    "app": {
      "start": "2026-03-30T05:15:36.2677834Z",
      "end": "2026-03-30T05:21:36.3469051Z",
      "elapsedMs": 360001,
      "replica": "acadrain-app--0000007-7b7786c677-rj8df"
    }
  }
]
```

This correlation sharpens the interpretation:

- `230s` is the control case and succeeds consistently through the gateway
- `260s` fails at the gateway after about `240s`, but the app keeps running for about `20s` more and completes normally
- `360s` fails at the gateway after about `240s`, but the app keeps running for about `120s` more and completes normally
- in all three correlated cases, the same surviving replica handled the request, so replica replacement is not part of the failure explanation

The practical implication is now stronger than before: there is an approximately four-minute client-visible ceiling somewhere on the Application Gateway path for silent long-running responses, and that ceiling remains distinct from ACA drain behavior.

### Refined conclusion

The residual `504` is now best understood as a gateway-path timeout issue that reproduces even without autoscale shrink.

That changes the interpretation of the original drain test significantly:

- the same-revision shrink test still validates ACA-side drain behavior
- the removed replica still shows `shutdown.signal`, `readiness.changed`, and `shutdown.exit`
- the client-visible `504` is not evidence against ACA drain behavior
- the current blocker is an approximately four-minute Application Gateway path limit that remains even after `requestTimeout=600` and even after increasing the public IP idle timeout to `15`
