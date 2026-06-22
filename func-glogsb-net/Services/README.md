# func-glogsb-net Services

The .NET Function App uses these helper services to keep the HTTP function focused on orchestration.

## ServiceBusPublisher

`ServiceBusPublisher` publishes merged JSON payloads to Azure Service Bus.

Responsibilities:

- Reuses a singleton `ServiceBusClient` from dependency injection.
- Caches `ServiceBusSender` instances per topic.
- Sends JSON as UTF-8 with `ContentType = application/json`.
- Applies `CorrelationId` when provided.
- Applies `Subject` when provided.
- Copies non-empty application properties onto the Service Bus message.

The Service Bus client is configured in `Program.cs`.

Authentication options:

- `service_bus__connectionString` for SAS connection string auth.
- `service_bus_RBAC__fullyQualifiedNamespace` for RBAC auth with `DefaultAzureCredential`.

## PayloadLookupService

`PayloadLookupService` loads JSON data from SQL.

It provides two lookups:

- `LookupSchemaTemplateAsync(topicKey)`: loads a JSON schema template from `dbo._NRF_sbSchemas`.
- `LookupExistingPayloadAsync(objectId, topicKey)`: loads the most recent existing payload from `dbo._NRF_sbPayloads`.

Schema template columns:

- `client`
- `matter`
- `payor`

Existing payload lookup rules:

- `matter` searches by `matterNumber` or `objectId`.
- Other topics search by `entityNumber` or `objectId`.
- Payload rows must have valid JSON.
- Topic comparison is case-insensitive.

SQL connection options:

- `Sql__ConnectionString`
- `Sql__Server` plus `Sql__Database`

When `Sql__ConnectionString` is not provided, the service builds an Azure AD default-auth connection string.

## JsonMergeService

`JsonMergeService` creates the final outbound JSON payload.

Main methods:

- `MergeIntoTemplate(template, sourcesByPriority)`: creates an output object using the template shape and fills fields from priority-ordered sources.
- `MergeObjects(left, right)`: merges two JSON objects, with the left object treated as the source of truth.

Merge rules:

- Source values are used when they are not blank.
- Existing values fill missing or blank fields.
- Nested objects merge recursively.
- Empty arrays can be filled from populated arrays.
- Populated arrays are preserved.
- Arrays are deduplicated by exact JSON representation.
- `matterUsers` and `matterUser` arrays are specially shaped and deduplicated.

## JsonPayloadNormalizer

`JsonPayloadNormalizer` normalizes incoming and SQL-loaded JSON before merging.

Normalization rules:

- Removes spaces and hyphens from property names.
- Converts string `"true"` and `"false"` to booleans.
- Recurses through nested objects and arrays.
- Throws if two properties collide after name normalization.
- Converts `matterBankingSanctionsExposure` values such as `yes`, `y`, `true`, `no`, `n`, and `false` into booleans.

## JsonTextRepairer

`JsonTextRepairer` handles malformed JSON text that contains raw control characters inside string values.

It escapes:

- Carriage returns
- Newlines
- Tabs
- Other control characters below `0x20`

This happens before JSON parsing so payloads with raw line breaks inside string fields can still be accepted when possible.
