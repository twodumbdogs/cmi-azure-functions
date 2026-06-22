# func-glogsb-net .NET Functions

This folder contains the .NET isolated-worker Function App for the merged outbound CMI payload flow.

## Function

- `cmi-outbound-v0`: HTTP endpoint that accepts a CMI payload, merges it with SQL-backed template/existing payload data, sends the merged payload to Integration Builder, and publishes the merged payload to Service Bus.

## Runtime

- .NET isolated worker
- Target framework: `net10.0`
- Azure Functions runtime: v4

## HTTP endpoint

`cmi-outbound-v0` is defined in `cmi-outbound.cs`.

- Trigger type: HTTP
- Method: `POST`
- Auth level: `Function`

The request body must be a JSON object.

## What the function does

For each request, the function:

1. Reads the raw request body.
2. Repairs raw control characters inside JSON strings before parsing.
3. Parses the body as JSON.
4. Normalizes property names by removing spaces and hyphens.
5. Normalizes string boolean values such as `"true"` and `"false"` into real booleans.
6. Reads routing and lookup fields such as `topicKey`, `objectId`, `entityNumber`, `matterNumber`, `requestID`, `msgNumber`, `requestType`, `eventType`, `memberFirmCode`, and `correlationId`.
7. Resolves the Service Bus topic from `topicKey`.
8. Looks up a schema template and existing payload from SQL.
9. Merges the incoming payload, existing SQL payload, and schema template.
10. Ensures a `correlationId` exists.
11. Sends the final merged JSON payload to Integration Builder.
12. Publishes the final merged JSON payload to Service Bus.
13. Returns a plain text status response.

## Routing

Supported `topicKey` values:

- `matter`
- `client`
- `payor`

Default Service Bus topics:

- `matter` -> `cmi-matter`
- `client` -> `cmi-client`
- `payor` -> `cmi-payor`

The topic names can be overridden with app settings:

- `ServiceBus__MatterTopic`
- `ServiceBus__ClientTopic`
- `ServiceBus__PayorTopic`

If `topicKey` is missing, the function returns HTTP 400.

If `topicKey` is not one of the supported values, the function returns HTTP 200 and does not publish to Service Bus.

## Service Bus settings

The app supports either SAS connection string auth or RBAC auth.

For SAS connection string auth:

- `service_bus__connectionString`

For RBAC auth:

- `service_bus_RBAC__fullyQualifiedNamespace`

When both are present, `service_bus__connectionString` is used.

## SQL settings

SQL is used to load schema templates and existing payloads.

Use either a full connection string:

- `Sql__ConnectionString`

Or server/database settings for Azure AD default authentication:

- `Sql__Server`
- `Sql__Database`

Tables used:

- `dbo._NRF_sbSchemas`
- `dbo._NRF_sbPayloads`

## Integration Builder settings

Required:

- `intapp__ibHost`
- `intapp__ibRuleId`
- `intapp__ibToken`

Optional:

- `intapp__ibSkipCertificateCheck`

Integration Builder is called with the final merged payload in the `jsonBody` input.

The IB call is intentionally fail-open. If IB is unavailable or returns an error, the function logs the failure but continues to publish the merged payload to Service Bus.

## Merge behavior

The merge is designed so the incoming request has priority, the existing SQL payload fills gaps, and the schema template defines the final shape when one exists.

High-level rules:

- Incoming values win when present.
- Existing SQL values fill blank or missing incoming values.
- Schema templates define the output fields when available.
- Arrays are shaped from templates when possible.
- `matterUsers` and `matterUser` arrays are treated specially and deduplicated.
- Duplicate JSON objects in arrays are removed by exact JSON representation.

See `Services/README.md` for more detail on the helper services.

## Failure behavior

- Invalid or empty JSON returns HTTP 400.
- Missing routing or lookup identifiers returns HTTP 400.
- SQL lookup errors return HTTP 500.
- Service Bus publish errors return HTTP 500.
- Integration Builder errors are logged but do not fail the request.

## Deployment

This folder currently contains environment-specific deploy scripts:

```powershell
.\deployme-net-dev.ps1
.\deployme-net-pre-prod.ps1
```

Use the script that matches the target environment.
