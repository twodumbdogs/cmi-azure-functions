# Integration Builder Send Limiter

We added a small limiter to the PowerShell Azure Functions that send payloads to Integration Builder (IB).

The reason for this change is to avoid a backlog of Service Bus messages clearing too quickly and sending a burst of requests to IB all at once. When messages pile up, Azure Functions can process them very fast. That is usually good, but in this case every processed message can trigger an outbound IB rule execution request. If enough messages are waiting, that can effectively bum rush IB.

## What changed

The PowerShell Function App `host.json` now limits Service Bus trigger processing:

```json
{
  "extensions": {
    "serviceBus": {
      "prefetchCount": 0,
      "maxConcurrentCalls": 1,
      "maxAutoLockRenewalDuration": "00:10:00"
    }
  }
}
```

This does three things:

- `maxConcurrentCalls` limits Service Bus processing to one message at a time per Function App instance.
- `prefetchCount` is set to `0` so the app does not aggressively pull messages ahead of processing.
- `maxAutoLockRenewalDuration` allows more time for the message lock to be renewed while processing is slowed down.

Each PowerShell function that calls IB also pauses briefly after a successful IB POST:

```powershell
Start-Sleep -Seconds ([int]($env:intapp__ibThrottleSeconds ?? 1))
```

The delay is controlled by the `intapp__ibThrottleSeconds` app setting. If the setting is missing, the default delay is 1 second.

## Why this helps

This change intentionally trades some throughput for stability. During normal message volume, the difference should be small. During a backlog or replay, the Function App drains messages more slowly and gives IB breathing room instead of sending many requests at nearly the same time.

## App setting

Recommended setting:

```powershell
intapp__ibThrottleSeconds=1
```

For stricter throttling, the Function App scale-out settings can also be capped:

```powershell
WEBSITE_MAX_DYNAMIC_APPLICATION_SCALE_OUT=1
FUNCTIONS_WORKER_PROCESS_COUNT=1
```

Without the scale-out cap, `maxConcurrentCalls = 1` applies per Function App instance. If Azure scales the app out to multiple instances, each instance may still process one message at a time.
