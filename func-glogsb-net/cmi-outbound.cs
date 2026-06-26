using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace func_glogsb_net;

public class CmiOutboundFunction
{
    private readonly ILogger<CmiOutboundFunction> _logger;
    private readonly PayloadLookupService _lookupService;
    private readonly JsonMergeService _mergeService;
    private readonly PayloadSchemaValidationService _schemaValidationService;
    private readonly SchemaValidationFailureWriter _schemaValidationFailureWriter;
    private readonly ServiceBusPublisher _publisher;

    public CmiOutboundFunction(
        ILogger<CmiOutboundFunction> logger,
        PayloadLookupService lookupService,
        JsonMergeService mergeService,
        PayloadSchemaValidationService schemaValidationService,
        SchemaValidationFailureWriter schemaValidationFailureWriter,
        ServiceBusPublisher publisher)
    {
        _logger = logger;
        _lookupService = lookupService;
        _mergeService = mergeService;
        _schemaValidationService = schemaValidationService;
        _schemaValidationFailureWriter = schemaValidationFailureWriter;
        _publisher = publisher;
    }

    [Function("cmi-outbound-v0")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post")] HttpRequestData req,
        CancellationToken cancellationToken)
    {
        string rawBody;
        JsonObject? incomingJson;

        try
        {
            using var reader = new StreamReader(req.Body);
            rawBody = await reader.ReadToEndAsync();

            var contentType = FirstHeaderValue(req, "Content-Type");

            _logger.LogInformation(
                "Inbound request received. Method={Method}, Url={Url}, ContentType={ContentType}, RawBodyLength={RawBodyLength}",
                req.Method,
                req.Url?.ToString() ?? "(null)",
                contentType ?? "(null)",
                rawBody?.Length ?? 0);

            if (string.IsNullOrWhiteSpace(rawBody))
            {
                _logger.LogWarning("Request body was empty.");
                return await CreateResponse(req, HttpStatusCode.BadRequest, "Empty request body.");
            }

            var parseBody = JsonTextRepairer.EscapeControlCharactersInsideStrings(rawBody, out var repairedJsonText);
            if (repairedJsonText)
            {
                _logger.LogInformation("Escaped raw control characters inside inbound JSON string values before parsing.");
            }

            incomingJson = JsonNode.Parse(parseBody) as JsonObject;
            if (incomingJson is null)
            {
                _logger.LogWarning("Request body parsed, but root was not a JSON object.");
                return await CreateResponse(req, HttpStatusCode.BadRequest, "Request body must be a JSON object.");
            }

            incomingJson = JsonPayloadNormalizer.NormalizeObject(incomingJson);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to parse request body.");
            return await CreateResponse(req, HttpStatusCode.BadRequest, $"Invalid JSON body: {ex.Message}");
        }

        _logger.LogInformation("Inbound payload received and parsed successfully.");

        var topicKey = GetJsonScalarString(incomingJson, "topicKey")?.Trim();
        var inboundObjectId = GetJsonScalarString(incomingJson, "objectId");
        var inboundEntityNumber = GetJsonScalarString(incomingJson, "entityNumber");
        var inboundMatterNumber = GetJsonScalarString(incomingJson, "matterNumber");
        var inboundRequestId = GetJsonScalarString(incomingJson, "requestID");
        var inboundMsgNumber = GetJsonScalarString(incomingJson, "msgNumber");
        var inboundRequestType = GetJsonScalarString(incomingJson, "requestType");
        var inboundEventType = GetJsonScalarString(incomingJson, "eventType");
        var inboundCorrelationId = GetJsonScalarString(incomingJson, "correlationId");
        var inboundMemberFirmCode = GetJsonScalarString(incomingJson, "memberFirmCode");

        var objectId = string.Equals(topicKey, "matter", StringComparison.OrdinalIgnoreCase)
            ? FirstNonBlank(inboundObjectId, inboundMatterNumber, inboundEntityNumber)
            : FirstNonBlank(inboundObjectId, inboundEntityNumber);

        _logger.LogInformation(
            "Inbound parsed fields: topicKey={TopicKey}, objectId={InboundObjectId}, entityNumber={InboundEntityNumber}, matterNumber={InboundMatterNumber}, lookupObjectId={LookupObjectId}, requestID={InboundRequestId}, msgNumber={InboundMsgNumber}, requestType={InboundRequestType}, eventType={InboundEventType}, memberFirmCode={InboundMemberFirmCode}, correlationId={InboundCorrelationId}",
            topicKey ?? "(null)",
            inboundObjectId ?? "(null)",
            inboundEntityNumber ?? "(null)",
            inboundMatterNumber ?? "(null)",
            objectId ?? "(null)",
            inboundRequestId ?? "(null)",
            inboundMsgNumber ?? "(null)",
            inboundRequestType ?? "(null)",
            inboundEventType ?? "(null)",
            inboundMemberFirmCode ?? "(null)",
            inboundCorrelationId ?? "(null)");

        if (string.IsNullOrWhiteSpace(topicKey))
        {
            _logger.LogWarning("Missing topicKey.");
            return await CreateResponse(req, HttpStatusCode.BadRequest, "Missing topicKey.");
        }

        if (string.IsNullOrWhiteSpace(objectId))
        {
            _logger.LogWarning("Missing objectId/entityNumber/matterNumber.");
            return await CreateResponse(req, HttpStatusCode.BadRequest, "Missing objectId/entityNumber/matterNumber.");
        }

        var topicName = ResolveTopicName(topicKey);
        var routeStatus = topicName is null ? "error" : "ok";
        var routeTarget = topicName;

        if (topicName is null)
        {
            _logger.LogWarning("No matching route for topicKey '{TopicKey}'. Not publishing to Service Bus.", topicKey);
        }
        else
        {
            _logger.LogInformation(
                "Resolved topic route. topicKey={TopicKey}, topicName={TopicName}, objectId={ObjectId}",
                topicKey,
                topicName,
                objectId);
        }

        if (topicName is null)
        {
            return await CreateResponse(req, HttpStatusCode.OK, $"No SB route for '{topicKey}'. Nothing published.");
        }

        JsonObject? schemaTemplateJson;
        JsonObject? existingPayloadJson;
        try
        {
            schemaTemplateJson = await _lookupService.LookupSchemaTemplateAsync(topicKey);
            existingPayloadJson = await _lookupService.LookupExistingPayloadAsync(objectId, topicKey);

            _logger.LogInformation(
                "SQL lookup complete for topicKey {TopicKey}, objectId {ObjectId}. SchemaTemplateFound={SchemaTemplateFound}, SchemaTemplateTopLevelFieldCount={SchemaTemplateTopLevelFieldCount}, PayloadFound={PayloadFound}, PayloadTopLevelFieldCount={PayloadTopLevelFieldCount}",
                topicKey,
                objectId,
                schemaTemplateJson is not null,
                schemaTemplateJson?.Count ?? 0,
                existingPayloadJson is not null,
                existingPayloadJson?.Count ?? 0);

            if (schemaTemplateJson is not null)
            {
                _logger.LogInformation(
                    "Schema template top-level fields for topicKey {TopicKey}: {SchemaTemplateFields}",
                    topicKey,
                    string.Join(", ", schemaTemplateJson.Select(kvp => kvp.Key)));
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "SQL lookup failed for topicKey {TopicKey}, objectId {ObjectId}", topicKey, objectId);
            return await CreateResponse(req, HttpStatusCode.InternalServerError, $"SQL lookup failed: {ex.Message}");
        }

        var mergedJson = schemaTemplateJson is not null
            ? _mergeService.MergeIntoTemplate(schemaTemplateJson, incomingJson, existingPayloadJson)
            : existingPayloadJson is null
                ? (JsonObject?)incomingJson.DeepClone() ?? new JsonObject()
                : _mergeService.MergeObjects(incomingJson, existingPayloadJson);

        _logger.LogInformation(
            "Three-source merge prepared. Incoming payload wins, existing SQL payload fills next, schema template defines final shape. SchemaTemplateFound={SchemaTemplateFound}, PayloadFound={PayloadFound}",
            schemaTemplateJson is not null,
            existingPayloadJson is not null);

        var correlationId = FirstNonBlank(
            GetJsonScalarString(mergedJson, "correlationId"),
            inboundCorrelationId,
            Guid.NewGuid().ToString()
        )!;

        mergedJson["correlationId"] = correlationId;

        var requestId = FirstNonBlank(
            GetJsonScalarString(mergedJson, "requestID"),
            inboundRequestId
        );

        var msgNumber = FirstNonBlank(
            GetJsonScalarString(mergedJson, "msgNumber"),
            inboundMsgNumber
        );

        var requestType = FirstNonBlank(
            GetJsonScalarString(mergedJson, "requestType"),
            inboundRequestType
        );

        var entityNumber = FirstNonBlank(
            GetJsonScalarString(mergedJson, "entityNumber"),
            inboundEntityNumber
        );

        var memberFirmCode = FirstNonBlank(
            GetJsonScalarString(mergedJson, "memberFirmCode"),
            inboundMemberFirmCode
        );

        var eventType = FirstNonBlank(
            GetJsonScalarString(mergedJson, "eventType"),
            inboundEventType
        );

        var subject = FirstNonBlank(
            requestType,
            topicKey
        );

        var applicationProperties = new Dictionary<string, object>();

        AddIfNotBlank(applicationProperties, "objectId", objectId);
        AddIfNotBlank(applicationProperties, "entityNumber", entityNumber);
        AddIfNotBlank(applicationProperties, "requestID", requestId);
        AddIfNotBlank(applicationProperties, "msgNumber", msgNumber);
        AddIfNotBlank(applicationProperties, "requestType", requestType);
        AddIfNotBlank(applicationProperties, "memberFirmCode", memberFirmCode);
        AddIfNotBlank(applicationProperties, "eventType", eventType);
        AddIfNotBlank(applicationProperties, "topicKey", topicKey);

        var mergedBody = mergedJson.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true
        });
// -----------------------------------------------------------------------------
// Schema validation gate
//
// "I reject bad JSON before it becomes someone else's problem." 😎
//
// Validate the final merged payload before calling Integration Builder or
// publishing to Service Bus. If validation fails, write the reject details to SQL
// and stop the outbound flow.
// -----------------------------------------------------------------------------

        var schemaValidation = _schemaValidationService.Validate(topicKey, mergedBody);
        if (!schemaValidation.IsValid)
        {
            var statusCode = schemaValidation.Status == PayloadSchemaValidationStatus.ConfigurationError
                ? HttpStatusCode.InternalServerError
                : HttpStatusCode.BadRequest;

            var errorCode = schemaValidation.Status == PayloadSchemaValidationStatus.ConfigurationError
                ? "SCHEMA_CONFIGURATION_ERROR"
                : "SCHEMA_VALIDATION_FAILED";

            var validationStatus = schemaValidation.Status.ToString();

            var responseError =
                $"Merged payload failed JSON schema validation: {schemaValidation.ErrorMessage}";

            var failedField = ExtractSchemaValidationField(schemaValidation.ErrorMessage);

            var functionName = FirstNonBlank(
                req.FunctionContext.FunctionDefinition.Name,
                "cmi-outbound-v0")!;

            var invocationId = req.FunctionContext.InvocationId;

            _logger.LogWarning(
                "Merged payload failed JSON schema validation. functionName={FunctionName}, invocationId={InvocationId}, topicKey={TopicKey}, objectId={ObjectId}, correlationId={CorrelationId}, StatusCode={StatusCode}, ErrorCode={ErrorCode}, ValidationStatus={ValidationStatus}, FailedField={FailedField}, Error={SchemaValidationError}",
                functionName,
                invocationId,
                topicKey,
                objectId,
                correlationId,
                (int)statusCode,
                errorCode,
                validationStatus,
                failedField ?? "(unknown)",
                schemaValidation.ErrorMessage ?? "(null)");

            await TryWriteSchemaValidationFailureAsync(
                topicKey: topicKey,
                objectId: objectId,
                entityNumber: entityNumber,
                matterNumber: inboundMatterNumber,
                requestId: requestId,
                msgNumber: msgNumber,
                requestType: requestType,
                eventType: eventType,
                memberFirmCode: memberFirmCode,
                functionName: functionName,
                invocationId: invocationId,
                correlationId: correlationId,
                statusCode: statusCode,
                errorCode: errorCode,
                validationStatus: validationStatus,
                responseError: responseError,
                validationError: schemaValidation.ErrorMessage,
                failedField: failedField,
                mergedPayload: mergedBody,
                cancellationToken: cancellationToken);

            return await CreateResponse(
                req,
                statusCode,
                responseError);
        }

        _logger.LogInformation(
            "Merged payload passed JSON schema validation. topicKey={TopicKey}, objectId={ObjectId}, correlationId={CorrelationId}",
            topicKey,
            objectId,
            correlationId);

        // ---------------------------------------------------------------------
        // POST-MERGE IB CALL
        // Send the final merged payload to IB so it sees the same shaped JSON
        // that is published to Service Bus. Fail-open on purpose.
        // ---------------------------------------------------------------------
        await TrySendToIbAsync(
            jsonBody: mergedBody,
            topicKey: topicKey,
            routeStatus: routeStatus,
            routeTarget: routeTarget,
            cancellationToken: cancellationToken);

        _logger.LogInformation(
            "Merged payload prepared. objectId={ObjectId}, CorrelationId={CorrelationId}, RequestId={RequestId}, MsgNumber={MsgNumber}, Subject={Subject}, MergedBodyLength={MergedBodyLength}, AppPropertyCount={AppPropertyCount}",
            objectId,
            correlationId,
            requestId ?? "(null)",
            msgNumber ?? "(null)",
            subject ?? "(null)",
            mergedBody.Length,
            applicationProperties.Count);

        if (applicationProperties.Count > 0)
        {
            var appPropsSummary = string.Join(
                ", ",
                applicationProperties.Select(kvp => $"{kvp.Key}={kvp.Value}"));

            _logger.LogInformation("Application properties: {ApplicationProperties}", appPropsSummary);
        }
        else
        {
            _logger.LogInformation("Application properties: (none)");
        }

        try
        {
            _logger.LogInformation(
                "Publishing to Service Bus topic {TopicName} with CorrelationId={CorrelationId}, Subject={Subject}",
                topicName,
                correlationId,
                subject ?? "(null)");

            await _publisher.PublishAsync(
                topicName: topicName,
                jsonPayload: mergedBody,
                correlationId: correlationId,
                subject: subject,
                applicationProperties: applicationProperties,
                cancellationToken: cancellationToken);

            _logger.LogInformation(
                "Published merged payload. topic={TopicName}, objectId={ObjectId}, correlationId={CorrelationId}",
                topicName,
                objectId,
                correlationId);
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "Service Bus publish failed. topic={TopicName}, objectId={ObjectId}, correlationId={CorrelationId}",
                topicName,
                objectId,
                correlationId);

            return await CreateResponse(req, HttpStatusCode.InternalServerError, $"Service Bus publish failed: {ex.Message}");
        }

        return await CreateResponse(
            req,
            HttpStatusCode.OK,
            $"Sent merged payload to IB and published merged payload to '{topicName}'. objectId={objectId}; correlationId={correlationId}");
    }

    private async Task TrySendToIbAsync(
        string jsonBody,
        string topicKey,
        string routeStatus,
        string? routeTarget,
        CancellationToken cancellationToken)
    {
        try
        {
            var ibHost = Environment.GetEnvironmentVariable("intapp__ibHost");
            var ruleId = Environment.GetEnvironmentVariable("intapp__ibRuleId");
            var ibToken = Environment.GetEnvironmentVariable("intapp__ibToken");
            var skipCertCheckRaw = Environment.GetEnvironmentVariable("intapp__ibSkipCertificateCheck");

            if (string.IsNullOrWhiteSpace(ibHost))
            {
                throw new InvalidOperationException("Missing env:intapp__ibHost");
            }

            if (string.IsNullOrWhiteSpace(ruleId))
            {
                throw new InvalidOperationException("Missing env:intapp__ibRuleId");
            }

            if (string.IsNullOrWhiteSpace(ibToken))
            {
                throw new InvalidOperationException("Missing env:intapp__ibToken");
            }

            var skipCertificateCheck =
                bool.TryParse(skipCertCheckRaw, out var parsedSkip) && parsedSkip;

            var ibUrl = $"https://{ibHost}/api/v1/rules/{ruleId}/execution?wait_for_completion=-1";

            _logger.LogInformation(
                "Calling IB rule post-merge. Host={IbHost}, RuleId={RuleId}, RouteStatus={RouteStatus}, RouteTarget={RouteTarget}, JsonBodyLength={JsonBodyLength}, SkipCertificateCheck={SkipCertificateCheck}",
                ibHost,
                ruleId,
                routeStatus,
                routeTarget ?? "(null)",
                jsonBody.Length,
                skipCertificateCheck);

            var ibRequest = new
            {
                inputs = new[]
                {
                    new
                    {
                        name = "jsonBody",
                        value = jsonBody
                    }
                }
            };

            var ibRequestJson = JsonSerializer.Serialize(ibRequest);

            using var handler = new HttpClientHandler();

            if (skipCertificateCheck)
            {
                handler.ServerCertificateCustomValidationCallback =
                    HttpClientHandler.DangerousAcceptAnyServerCertificateValidator;
            }

            using var client = new HttpClient(handler)
            {
                Timeout = TimeSpan.FromSeconds(100)
            };

            using var request = new HttpRequestMessage(HttpMethod.Post, ibUrl);
            request.Headers.Add("IntegrateAuthenticationToken", ibToken);
            request.Content = new StringContent(ibRequestJson, Encoding.UTF8, "application/json");

            using var response = await client.SendAsync(request, cancellationToken);
            var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);

            if (response.IsSuccessStatusCode)
            {
                _logger.LogInformation(
                    "IB rule execution request accepted post-merge. StatusCode={StatusCode}, ResponseLength={ResponseLength}",
                    (int)response.StatusCode,
                    responseBody?.Length ?? 0);
            }
            else
            {
                _logger.LogWarning(
                    "IB rule execution returned non-success post-merge. StatusCode={StatusCode}, ReasonPhrase={ReasonPhrase}, ResponseBody={ResponseBody}",
                    (int)response.StatusCode,
                    response.ReasonPhrase ?? "(null)",
                    Truncate(responseBody, 4000));
            }
        }
        catch (Exception ex)
        {
            // Fail-open on purpose to preserve main HTTP/SB flow even if IB is down.
            _logger.LogError(ex, "IB rule execution failed post-merge.");
        }
    }

    private async Task TryWriteSchemaValidationFailureAsync(
        string topicKey,
        string objectId,
        string? entityNumber,
        string? matterNumber,
        string? requestId,
        string? msgNumber,
        string? requestType,
        string? eventType,
        string? memberFirmCode,
        string? functionName,
        string? invocationId,
        string correlationId,
        HttpStatusCode statusCode,
        string errorCode,
        string? validationStatus,
        string responseError,
        string? validationError,
        string? failedField,
        string mergedPayload,
        CancellationToken cancellationToken)
    {
        try
        {
            var wasWritten = await _schemaValidationFailureWriter.WriteAsync(
                new SchemaValidationFailureRecord
                {
                    TopicKey = topicKey,
                    ObjectId = objectId,
                    EntityNumber = entityNumber,
                    MatterNumber = matterNumber,
                    RequestId = requestId,
                    MsgNumber = msgNumber,
                    RequestType = requestType,
                    EventType = eventType,
                    MemberFirmCode = memberFirmCode,
                    FunctionName = functionName,
                    InvocationId = invocationId,
                    CorrelationId = correlationId,
                    HttpStatusCode = (int)statusCode,
                    ErrorCode = errorCode,
                    ValidationStatus = validationStatus,
                    FailedField = failedField,
                    ResponseError = responseError,
                    ValidationError = validationError,
                    MergedPayload = mergedPayload
                },
                cancellationToken);

            if (wasWritten)
            {
                _logger.LogInformation(
                    "Schema validation failure written to SQL. functionName={FunctionName}, invocationId={InvocationId}, topicKey={TopicKey}, objectId={ObjectId}, correlationId={CorrelationId}, statusCode={StatusCode}, errorCode={ErrorCode}, failedField={FailedField}",
                    functionName ?? "(null)",
                    invocationId ?? "(null)",
                    topicKey,
                    objectId,
                    correlationId,
                    (int)statusCode,
                    errorCode,
                    failedField ?? "(unknown)");
            }
            else
            {
                _logger.LogInformation(
                    "Schema validation failure SQL write was skipped because SchemaRejects__Enabled is false. functionName={FunctionName}, invocationId={InvocationId}, topicKey={TopicKey}, objectId={ObjectId}, correlationId={CorrelationId}, statusCode={StatusCode}, errorCode={ErrorCode}, failedField={FailedField}",
                    functionName ?? "(null)",
                    invocationId ?? "(null)",
                    topicKey,
                    objectId,
                    correlationId,
                    (int)statusCode,
                    errorCode,
                    failedField ?? "(unknown)");
            }
        }
        catch (Exception ex)
        {
            var failOpen = GetBooleanEnvironmentVariable("SchemaRejects__FailOpen", defaultValue: true);

            if (failOpen)
            {
                // Keep the original validation response behavior. The payload is still invalid,
                // and this logging failure should not accidentally turn a clean 400 into something
                // harder for the caller to understand.
                _logger.LogError(
                    ex,
                    "Failed to write schema validation failure to SQL. Continuing because SchemaRejects__FailOpen is true. functionName={FunctionName}, invocationId={InvocationId}, topicKey={TopicKey}, objectId={ObjectId}, correlationId={CorrelationId}, statusCode={StatusCode}, errorCode={ErrorCode}, failedField={FailedField}",
                    functionName ?? "(null)",
                    invocationId ?? "(null)",
                    topicKey,
                    objectId,
                    correlationId,
                    (int)statusCode,
                    errorCode,
                    failedField ?? "(unknown)");

                return;
            }

            _logger.LogError(
                ex,
                "Failed to write schema validation failure to SQL. Rethrowing because SchemaRejects__FailOpen is false. functionName={FunctionName}, invocationId={InvocationId}, topicKey={TopicKey}, objectId={ObjectId}, correlationId={CorrelationId}, statusCode={StatusCode}, errorCode={ErrorCode}, failedField={FailedField}",
                functionName ?? "(null)",
                invocationId ?? "(null)",
                topicKey,
                objectId,
                correlationId,
                (int)statusCode,
                errorCode,
                failedField ?? "(unknown)");

            throw;
        }
    }

    private static bool GetBooleanEnvironmentVariable(string name, bool defaultValue)
    {
        var rawValue = Environment.GetEnvironmentVariable(name);

        if (string.IsNullOrWhiteSpace(rawValue))
        {
            return defaultValue;
        }

        return rawValue.Trim().ToLowerInvariant() switch
        {
            "1" or "true" or "yes" or "y" or "on" => true,
            "0" or "false" or "no" or "n" or "off" => false,
            _ => defaultValue
        };
    }

    private static string? ExtractSchemaValidationField(string? errorMessage)
    {
        if (string.IsNullOrWhiteSpace(errorMessage))
        {
            return null;
        }

        // JsonSchema.Net messages can vary by output format/version, so this is intentionally
        // defensive. It preserves the full validationError in SQL and extracts a useful field/path
        // when the message contains one.
        var patterns = new[]
        {
            @"(?i)\bInstanceLocation\b\s*[:=]\s*[""']?(?<path>[$#/]?[A-Za-z0-9_\-./\[\]~]+)",
            @"(?i)\bInstance\s+Location\b\s*[:=]\s*[""']?(?<path>[$#/]?[A-Za-z0-9_\-./\[\]~]+)",
            @"(?i)\bJsonPath\b\s*[:=]\s*[""']?(?<path>[$#.]?[A-Za-z0-9_\-./\[\]~]+)",
            @"(?i)\bPath\b\s*[:=]\s*[""']?(?<path>[$#.]?[A-Za-z0-9_\-./\[\]~]+)",
            @"(?i)\bProperty\b\s+[""'](?<path>[^""']+)[""']",
            @"(?i)\brequired\s+propert(?:y|ies)\b.*?[""'](?<path>[^""']+)[""']"
        };

        foreach (var pattern in patterns)
        {
            var match = Regex.Match(errorMessage, pattern);
            if (match.Success)
            {
                var value = match.Groups["path"].Value.Trim();
                if (!string.IsNullOrWhiteSpace(value))
                {
                    return NormalizeSchemaValidationField(value);
                }
            }
        }

        return null;
    }

    private static string NormalizeSchemaValidationField(string value)
    {
        var normalized = value
            .Trim()
            .Trim(',', ';', '.', ')', ']', '"', '\'');

        if (normalized == "#" || normalized == "$" || normalized == "/" || normalized == "#/")
        {
            return "$";
        }

        if (normalized.StartsWith("#/", StringComparison.Ordinal))
        {
            normalized = normalized[1..];
        }

        if (normalized.StartsWith("/", StringComparison.Ordinal))
        {
            normalized = "$" + normalized.Replace("/", ".");
        }

        normalized = normalized
            .Replace("..", ".", StringComparison.Ordinal)
            .TrimEnd('.');

        return string.IsNullOrWhiteSpace(normalized)
            ? "$"
            : normalized;
    }

    private static string? ResolveTopicName(string? topicKey) =>
        topicKey?.ToLowerInvariant() switch
        {
            "matter" => Environment.GetEnvironmentVariable("ServiceBus__MatterTopic") ?? "cmi-matter",
            "client" => Environment.GetEnvironmentVariable("ServiceBus__ClientTopic") ?? "cmi-client",
            "payor"  => Environment.GetEnvironmentVariable("ServiceBus__PayorTopic") ?? "cmi-payor",
            _ => null
        };

    private static string? FirstNonBlank(params string?[] values) =>
        values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));

    private static string? GetJsonScalarString(JsonObject json, string propertyName)
    {
        if (!json.TryGetPropertyValue(propertyName, out var node) || node is null)
        {
            return null;
        }

        if (node is JsonValue value && value.TryGetValue<string>(out var s))
        {
            return s;
        }

        return null;
    }

    private static void AddIfNotBlank(IDictionary<string, object> dict, string key, string? value)
    {
        if (!string.IsNullOrWhiteSpace(value))
        {
            dict[key] = value;
        }
    }

    private static string? FirstHeaderValue(HttpRequestData req, string headerName)
    {
        if (req.Headers.TryGetValues(headerName, out var values))
        {
            return values.FirstOrDefault();
        }

        return null;
    }

    private static string Truncate(string? value, int maxLength)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        return value.Length <= maxLength
            ? value
            : value[..maxLength];
    }

    private static async Task<HttpResponseData> CreateResponse(HttpRequestData req, HttpStatusCode code, string body)
    {
        var response = req.CreateResponse(code);
        response.Headers.Add("Content-Type", "text/plain; charset=utf-8");
        await response.WriteStringAsync(body);
        return response;
    }
}
