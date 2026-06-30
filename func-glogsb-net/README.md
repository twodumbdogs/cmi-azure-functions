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

Each environment is expected to already have its SQL connection settings configured.

The deploy script ensures missing SchemaRejects settings before publish/deploy:

```powershell
.\deployme-net.ps1 dev
.\deployme-net.ps1 pre-prod
```

During deployment, the script scans code-referenced Function App settings, shows
which settings are present/missing, and prompts before creating missing settings
that are safe to create. Optional settings that would change runtime behavior,
such as `SchemaValidation__Directory`, are skipped by default.

The standalone settings helper can also apply or refresh the SchemaRejects settings without redeploying:

```powershell
.\set-schema-rejects-app-settings.example.ps1 dev
.\set-schema-rejects-app-settings.example.ps1 pre-prod
```

Known shorthand targets:

| Environment | Resource group | Function app |
|---|---|---|
| `dev` | `rg-glogsb-dev-uksouth-001` | `func-glogsb-net-dev-uksouth-001` |
| `pre-prod`, `preprod`, `qa` | `rg-glogsb-qa-ukwest-001` | `func-glogsb-net-qa-ukwest-001` |
| `prod` | Not configured yet | Not configured yet |

## Files

- `cmi-outbound.cs`
  - Full updated function file.
- `SchemaValidationFailureWriter.cs`
  - Direct parameterized INSERT writer.
- `Program.registration.snippet.cs`
  - DI registration snippet.
- `Sql/001_create_NRF_sbSchemaRejects.sql`
  - Table/index script only. No stored procedure.
- `deployme-net.ps1`
  - More resilient .NET deploy script with known environment shortcuts.
- `set-schema-rejects-app-settings.example.ps1`
  - Optional helper to apply the SchemaRejects app settings with the same known environment shortcuts.
- `SchemaRejects.app-settings.md`
  - App settings reference.
