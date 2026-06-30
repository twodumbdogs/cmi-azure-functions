# Schema Reject App Settings

These app settings control final JSON Schema reject logging for `cmi-outbound-v0`.

| Setting | Default | Purpose |
|---|---:|---|
| `SchemaRejects__Enabled` | `true` | Enables/disables writing rows to SQL. |
| `SchemaRejects__TableName` | `dbo._NRF_sbSchemaRejects` | Target schema reject table. Must be a simple two-part name like `dbo.TableName`. |
| `SchemaRejects__CommandTimeoutSeconds` | `30` | SQL command timeout for the insert. Clamped from 1 to 300 seconds. |
| `SchemaRejects__WriteMergedPayload` | `true` | Stores the final merged payload that failed validation. Set to `false` to store NULL. |
| `SchemaRejects__FailOpen` | `true` | If SQL reject logging fails, preserve the original validation response instead of failing the request because of logging. |

Required SQL connection settings are unchanged:

```text
Sql__ConnectionString
```

Or:

```text
Sql__Server
Sql__Database
```

Each environment should already have its SQL connection settings configured.

Apply or refresh only the SchemaRejects settings with:

```powershell
.\set-schema-rejects-app-settings.example.ps1 dev
.\set-schema-rejects-app-settings.example.ps1 pre-prod
```

The same SchemaRejects defaults are used by `deployme-net.ps1` when missing app settings are ensured before deployment.

The code uses a direct parameterized INSERT. No stored procedure is required.
