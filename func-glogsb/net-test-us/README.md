# net-test-us

`net-test-us` is a small HTTP diagnostic function for checking DNS resolution and outbound network connectivity from the Function App.

## Trigger

- Type: HTTP trigger
- Method: `GET`
- Route: `net-test`
- Auth level: `function`

## What it does

When called, the function:

1. Reads `us_sb__fullyQualifiedNamespace`.
2. Falls back to `sb-us-non-prod-dev-esb-scus.servicebus.windows.net` if the setting is missing.
3. Performs a DNS lookup for the Service Bus host.
4. Calls `https://api.ipify.org?format=json` to report the Function App's public outbound IP.
5. Returns the DNS and outbound HTTP results as JSON.

## App settings

- `us_sb__fullyQualifiedNamespace`: Optional Service Bus host name to test.

## Failure behavior

DNS or outbound HTTP failures are included in the JSON response. Unhandled errors return HTTP 500.
