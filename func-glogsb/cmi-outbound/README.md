# cmi-outbound

`cmi-outbound` is the HTTP entry point for outbound CMI payloads.

## Trigger

- Type: HTTP trigger
- Methods: `GET`, `POST`
- Auth level: `FUNCTION`

`GET` returns a simple text message explaining that callers should POST JSON.

## What it does

On `POST`, the function:

1. Reads and parses the request JSON body.
2. Normalizes JSON property names by removing spaces and hyphens.
3. Reads `topicKey` from the payload.
4. Routes known topic keys to Service Bus:
   - `matter` -> `cmi-matter`
   - `client` -> `cmi-client`
   - `payor` -> `cmi-payor`
5. Calls Integration Builder with the original raw JSON body in the `jsonBody` input.
6. Waits briefly after the IB POST using `intapp__ibThrottleSeconds`, defaulting to 1 second.
7. Returns a text response describing whether the payload was routed.

If `topicKey` does not match a known route, the payload is not published to Service Bus. The function still calls IB so the failed routing attempt can be recorded.

## Bindings

- HTTP response: `Response`
- Service Bus output: `matter`, topic `cmi-matter`
- Service Bus output: `client`, topic `cmi-client`
- Service Bus output: `payor`, topic `cmi-payor`

The Service Bus outputs use the `service_bus_RBAC` connection.

## Required app settings

- `intapp__ibHost`
- `intapp__ibRuleId`
- `intapp__ibToken`

## Optional app settings

- `intapp__ibIp`: Used for a TCP reachability preflight check.
- `intapp__ibThrottleSeconds`: Delay after successful IB POST. Defaults to 1.

## Failure behavior

Service Bus publish failures return HTTP 500. Integration Builder failures are logged but do not fail the HTTP request.
