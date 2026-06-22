# cmi-subscribe-cmi-fails

`cmi-subscribe-cmi-fails` processes messages from the `cmi-fails` topic and forwards failure details to Integration Builder.

## Trigger

- Type: Service Bus trigger
- Topic: `cmi-fails`
- Subscription: `cmi-fails`
- Connection: `service_bus_RBAC`

## What it does

For each message, the function:

1. Reads the failed message body.
2. Attempts to parse the message as JSON.
3. Derives a message type from the payload or topic.
4. Builds an Integration Builder `jsonBody` value containing:
   - `timestamp`
   - `status`
   - `topic`
   - `payload`
5. Calls the configured Integration Builder rule.
6. Logs the IB response, truncated when long.
7. Waits briefly after the IB POST using `intapp__ibThrottleSeconds`, defaulting to 1 second.

## Required app settings

- `intapp__ibHost`
- `intapp__ibRuleId`
- `intapp__ibToken`
- `service_bus_RBAC`

## Optional app settings

- `intapp__ibIp`: Used for a TCP reachability preflight check.
- `intapp__ibThrottleSeconds`: Delay after successful IB POST. Defaults to 1.

## Failure behavior

If the IB call fails, the function logs the error and any available response body, then rethrows the error.
