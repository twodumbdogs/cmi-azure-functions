# CMI Outbound Direct Schema Reject Logging Update

## What changed

This package changes schema reject logging from a stored-procedure call to a direct parameterized SQL INSERT.

The database now only needs the table:

```sql
dbo._NRF_sbSchemaRejects
```

No stored procedure is required.

## App settings

| Setting | Default | Purpose |
|---|---:|---|
| `SchemaRejects__Enabled` | `true` | Enables/disables writing schema rejects to SQL. |
| `SchemaRejects__TableName` | `dbo._NRF_sbSchemaRejects` | Target table. Must be a simple two-part name like `dbo._NRF_sbSchemaRejects`. |
| `SchemaRejects__CommandTimeoutSeconds` | `30` | SQL insert timeout. Values are clamped from 1 to 300. |
| `SchemaRejects__WriteMergedPayload` | `true` | Stores the final merged payload that failed validation. Set to `false` to store NULL. |
| `SchemaRejects__FailOpen` | `true` | If reject logging fails, keep returning the original validation response. Set to `false` if logging failure should fail the request. |

SQL connection settings are unchanged:

```text
Sql__ConnectionString
```

Or:

```text
Sql__Server
Sql__Database
```

## Files

- `cmi-outbound.cs`
  - Full updated function file.
- `SchemaValidationFailureWriter.cs`
  - Direct parameterized INSERT writer.
- `Program.registration.snippet.cs`
  - DI registration snippet.
- `Sql/001_create_NRF_sbSchemaRejects.sql`
  - Table/index script only. No stored procedure.
- `deployme-net-dev.ps1`
  - More resilient .NET deploy script.
- `set-schema-rejects-app-settings.example.ps1`
  - Optional helper to apply the SchemaRejects app settings.
- `SchemaRejects.app-settings.md`
  - App settings reference.
