using System.Collections.Concurrent;
using System.Text.Json;
using Json.Schema;
using Microsoft.Extensions.Logging;

namespace func_glogsb_net;

public sealed class PayloadSchemaValidationService
{
    private const int MaxErrorCount = 20;

    private static readonly IReadOnlyDictionary<string, string> SchemaFilesByTopicKey =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["client"] = "CmiClientSchema.json",
            ["cmi-client"] = "CmiClientSchema.json",
            ["matter"] = "CmiMatterSchema.json",
            ["cmi-matter"] = "CmiMatterSchema.json",
            ["payor"] = "CmiPayorSchema.json",
            ["cmi-payor"] = "CmiPayorSchema.json"
        };

    private readonly ILogger<PayloadSchemaValidationService> _logger;
    private readonly ConcurrentDictionary<string, Lazy<JsonSchema>> _schemasByPath = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _schemaDirectory;

    public PayloadSchemaValidationService(ILogger<PayloadSchemaValidationService> logger)
    {
        _logger = logger;
        _schemaDirectory = Environment.GetEnvironmentVariable("SchemaValidation__Directory")
            ?? Path.Combine(AppContext.BaseDirectory, "Schemas");
    }

    public PayloadSchemaValidationResult Validate(string topicKey, string jsonPayload)
    {
        if (!SchemaFilesByTopicKey.TryGetValue(topicKey, out var schemaFileName))
        {
            return PayloadSchemaValidationResult.Valid();
        }

        var schemaPath = Path.Combine(_schemaDirectory, schemaFileName);
        if (!File.Exists(schemaPath))
        {
            return PayloadSchemaValidationResult.ConfigurationError(
                $"JSON schema file '{schemaFileName}' was not found in '{_schemaDirectory}'.");
        }

        JsonSchema schema;
        try
        {
            schema = _schemasByPath
                .GetOrAdd(schemaPath, path => new Lazy<JsonSchema>(() => LoadSchema(path)))
                .Value;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to load JSON schema. SchemaPath={SchemaPath}", schemaPath);
            return PayloadSchemaValidationResult.ConfigurationError(
                $"JSON schema file '{schemaFileName}' could not be loaded: {ex.Message}");
        }

        try
        {
            using var document = JsonDocument.Parse(jsonPayload);
            var results = schema.Evaluate(
                document.RootElement,
                new EvaluationOptions
                {
                    OutputFormat = OutputFormat.List,
                    RequireFormatValidation = true
                });

            if (results.IsValid)
            {
                return PayloadSchemaValidationResult.Valid();
            }

            var errors = FlattenErrors(results)
                .Take(MaxErrorCount)
                .ToArray();

            return PayloadSchemaValidationResult.PayloadInvalid(errors.Length == 0
                ? "Payload does not match the configured JSON schema."
                : string.Join("; ", errors));
        }
        catch (JsonException ex)
        {
            return PayloadSchemaValidationResult.PayloadInvalid($"Merged payload was not valid JSON: {ex.Message}");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "JSON schema validation failed unexpectedly. SchemaPath={SchemaPath}", schemaPath);
            return PayloadSchemaValidationResult.ConfigurationError($"JSON schema validation failed unexpectedly: {ex.Message}");
        }
    }

    private static JsonSchema LoadSchema(string schemaPath)
    {
        var schemaText = File.ReadAllText(schemaPath);
        return JsonSchema.FromText(schemaText, baseUri: new Uri(schemaPath));
    }

    private static IEnumerable<string> FlattenErrors(EvaluationResults results)
    {
        if (results.Errors is not null)
        {
            foreach (var error in results.Errors)
            {
                yield return $"{results.InstanceLocation}: {error.Value}";
            }
        }

        foreach (var detail in results.Details ?? [])
        {
            foreach (var error in FlattenErrors(detail))
            {
                yield return error;
            }
        }
    }
}

public sealed record PayloadSchemaValidationResult(
    PayloadSchemaValidationStatus Status,
    string? ErrorMessage)
{
    public bool IsValid => Status == PayloadSchemaValidationStatus.Valid;

    public static PayloadSchemaValidationResult Valid() => new(PayloadSchemaValidationStatus.Valid, null);

    public static PayloadSchemaValidationResult PayloadInvalid(string errorMessage) =>
        new(PayloadSchemaValidationStatus.PayloadInvalid, errorMessage);

    public static PayloadSchemaValidationResult ConfigurationError(string errorMessage) =>
        new(PayloadSchemaValidationStatus.ConfigurationError, errorMessage);
}

public enum PayloadSchemaValidationStatus
{
    Valid,
    PayloadInvalid,
    ConfigurationError
}
