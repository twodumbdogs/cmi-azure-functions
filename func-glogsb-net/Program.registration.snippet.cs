// Add this to Program.cs wherever the other app services are registered.
// Exact placement depends on your existing Program.cs, but it should live with
// PayloadLookupService / JsonMergeService / PayloadSchemaValidationService / ServiceBusPublisher.

builder.Services.AddSingleton<SchemaValidationFailureWriter>();
