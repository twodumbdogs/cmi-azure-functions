# cmi-subscribe-errors-emea

`cmi-subscribe-errors-emea` processes EMEA error messages from Service Bus and forwards them to Integration Builder.

## Trigger

- Type: Service Bus trigger
- Topic setting: `topicErrorEMEA`
- Subscription setting: `subErrorEMEA`
- Connection: `emea_sb`

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

## Bindings

- Service Bus trigger: configured by `topicErrorEMEA`, `subErrorEMEA`, and `emea_sb`
- Service Bus output: `fails`, topic `cm-fails`, connection `service_bus_RBAC`

## Required app settings

- `intapp__ibHost`
- `intapp__rule_id_regional_subscribe`
- `intapp__ibToken`
- `topicErrorEMEA`
- `subErrorEMEA`
- `emea_sb`

## Optional app settings

- `intapp__ibIp`: Used for a TCP reachability preflight check.
- `intapp__ibThrottleSeconds`: Delay after successful IB POST. Defaults to 1.

## Failure behavior

On unhandled errors, the script attempts to push the original message to the `fails` output binding and then rethrows the error.
