# JSON Schema Files

Place the outbound JSON Schema files in this folder using these exact names:

- `CmiClientSchema.json`
- `CmiMatterSchema.json`
- `CmiPayorSchema.json`

The Function App validates the final merged payload against the matching schema
after merge/correlation handling and before Integration Builder or Service Bus.

At runtime, `SchemaValidation__Directory` can override this folder path.
