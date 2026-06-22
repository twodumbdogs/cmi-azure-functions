# cmi-subscribe-payor-us

`cmi-subscribe-payor-us` processes US payor messages from Service Bus and forwards them to Integration Builder.

## Trigger

- Type: Service Bus trigger
- Topic setting: `topicPayorUS`
- Subscription setting: `subPayorUS`
- Connection: `us_sb`

## What it does

For each message, the function:

1. Serializes the incoming message to text when needed.
2. Resolves the current Function name for use as `region-subscription`.
3. Derives a message type from the Service Bus topic name.
4. Builds an Integration Builder request with regional inputs:
   - `region-body`
   - `region-topic`
   - `region-subscription`
   - `region-subscriberId`
   - `region-messageType`
   - `region-receivedUtc`
5. Calls the regional Integration Builder rule.
6. Waits briefly after the IB POST using `intapp__ibThrottleSeconds`, defaulting to 1 second.

## Required app settings

- `intapp__ibHost`
- `intapp__rule_id_regional_subscribe`
- `intapp__ibToken`
- `topicPayorUS`
- `subPayorUS`
- `us_sb`

## Optional app settings

- `intapp__ibIp`: Used for a TCP reachability preflight check.
- `intapp__ibThrottleSeconds`: Delay after successful IB POST. Defaults to 1.

## Failure behavior

The script logs the error and attempts to push the failed message to an output binding named `fails`, then rethrows the error. The current `function.json` only declares the Service Bus trigger, so add a `fails` output binding before relying on that route.
