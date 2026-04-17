using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace func_glogsb_net_qa_ukwest_001;

public class CmiOutboundFunction
{
    private readonly ILogger<CmiOutboundFunction> _logger;
    private readonly PayloadLookupService _lookupService;
    private readonly SchemaLookupService _schemaLookupService;
    private readonly JsonMergeService _mergeService;
    private readonly ServiceBusPublisher _publisher;

    public CmiOutboundFunction(
        ILogger<CmiOutboundFunction> logger,
        PayloadLookupService lookupService,
        SchemaLookupService schemaLookupService,
        JsonMergeService mergeService,
        ServiceBusPublisher publisher)
    {
        _logger = logger;
        _lookupService = lookupService;
        _schemaLookupService = schemaLookupService;
        _mergeService = mergeService;
        _publisher = publisher;
    }

    [Function("cmi-outbound-v0")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post")] HttpRequestData req,
        CancellationToken cancellationToken)
    {
        string rawBody;
        JsonObject? leftJson;

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

            leftJson = JsonNode.Parse(rawBody) as JsonObject;
            if (leftJson is null)
            {
                _logger.LogWarning("Request body parsed, but root was not a JSON object.");
                return await CreateResponse(req, HttpStatusCode.BadRequest, "Request body must be a JSON object.");
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to parse request body.");
            return await CreateResponse(req, HttpStatusCode.BadRequest, $"Invalid JSON body: {ex.Message}");
        }

        _logger.LogInformation("Inbound payload received and parsed successfully.");

        var topicKey = GetJsonScalarString(leftJson, "topicKey")?.Trim();
        var inboundObjectId = GetJsonScalarString(leftJson, "objectId");
        var inboundEntityNumber = GetJsonScalarString(leftJson, "entityNumber");
        var inboundRequestId = GetJsonScalarString(leftJson, "requestID");
        var inboundMsgNumber = GetJsonScalarString(leftJson, "msgNumber");
        var inboundRequestType = GetJsonScalarString(leftJson, "requestType");
        var inboundEventType = GetJsonScalarString(leftJson, "eventType");
        var inboundCorrelationId = GetJsonScalarString(leftJson, "correlationId");
        var inboundMemberFirmCode = GetJsonScalarString(leftJson, "memberFirmCode");
        var inboundMatterNumber = GetJsonScalarString(leftJson, "matterNumber");

        var objectId = FirstNonBlank(
            inboundObjectId,
            inboundEntityNumber
        );

        _logger.LogInformation(
            "Inbound parsed fields: topicKey={TopicKey}, objectId={InboundObjectId}, entityNumber={InboundEntityNumber}, requestID={InboundRequestId}, msgNumber={InboundMsgNumber}, requestType={InboundRequestType}, eventType={InboundEventType}, memberFirmCode={InboundMemberFirmCode}, correlationId={InboundCorrelationId}, matterNumber={InboundMatterNumber}",
            topicKey ?? "(null)",
            inboundObjectId ?? "(null)",
            inboundEntityNumber ?? "(null)",
            inboundRequestId ?? "(null)",
            inboundMsgNumber ?? "(null)",
            inboundRequestType ?? "(null)",
            inboundEventType ?? "(null)",
            inboundMemberFirmCode ?? "(null)",
            inboundCorrelationId ?? "(null)",
            inboundMatterNumber ?? "(null)");

        if (string.IsNullOrWhiteSpace(topicKey))
        {
            _logger.LogWarning("Missing topicKey.");
            return await CreateResponse(req, HttpStatusCode.BadRequest, "Missing topicKey.");
        }

        if (string.IsNullOrWhiteSpace(objectId))
        {
            _logger.LogWarning("Missing objectId/entityNumber.");
            return await CreateResponse(req, HttpStatusCode.BadRequest, "Missing objectId/entityNumber.");
        }

        var dedupeKey = FirstNonBlank(
            inboundMsgNumber,
            $"{inboundRequestId}|{objectId}|{topicKey}|{inboundMatterNumber}"
        );

        _logger.LogInformation(
            "Processing dedupeKey={DedupeKey}",
            dedupeKey ?? "(null)");

        var topicName = ResolveTopicName(topicKey);

        if (topicName is null)
        {
            _logger.LogWarning(
                "No Service Bus route found for topicKey {TopicKey}. Nothing published.",
                topicKey);

            return await CreateResponse(
                req,
                HttpStatusCode.OK,
                $"No SB route for '{topicKey}'. Nothing published.");
        }

        _logger.LogInformation(
            "Resolved topic route. topicKey={TopicKey}, topicName={TopicName}, objectId={ObjectId}",
            topicKey,
            topicName,
            objectId);

        JsonObject? rightJson;
        try
        {
            rightJson = await _lookupService.LookupExistingPayloadAsync(objectId, cancellationToken);

            _logger.LogInformation(
                "SQL lookup complete for objectId {ObjectId}. PayloadFound={PayloadFound}",
                objectId,
                rightJson is not null);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "SQL lookup failed for objectId {ObjectId}", objectId);
            return await CreateResponse(req, HttpStatusCode.InternalServerError, $"SQL lookup failed: {ex.Message}");
        }

        JsonObject schemaJson;
        try
        {
            schemaJson = await _schemaLookupService.GetSchemaAsync(topicKey, cancellationToken);

            _logger.LogInformation(
                "Schema lookup complete for topicKey {TopicKey}.",
                topicKey);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Schema lookup failed for topicKey {TopicKey}", topicKey);
            return await CreateResponse(req, HttpStatusCode.InternalServerError, $"Schema lookup failed: {ex.Message}");
        }

        JsonObject canonicalJson;
        try
        {
            canonicalJson = _mergeService.BuildCanonicalPayload(leftJson, rightJson, schemaJson);

            _logger.LogInformation(
                "Canonical payload built from schema. topicKey={TopicKey}, objectId={ObjectId}, RightPayloadFound={RightPayloadFound}",
                topicKey,
                objectId,
                rightJson is not null);
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "Canonical payload build failed. topicKey={TopicKey}, objectId={ObjectId}",
                topicKey,
                objectId);

            return await CreateResponse(req, HttpStatusCode.InternalServerError, $"Canonical payload build failed: {ex.Message}");
        }

        var correlationId = FirstNonBlank(
            GetJsonScalarString(canonicalJson, "correlationId"),
            inboundCorrelationId,
            Guid.NewGuid().ToString()
        )!;

        canonicalJson["correlationId"] = correlationId;

        var requestId = FirstNonBlank(
            GetJsonScalarString(canonicalJson, "requestID"),
            inboundRequestId
        );

        var msgNumber = FirstNonBlank(
            GetJsonScalarString(canonicalJson, "msgNumber"),
            inboundMsgNumber
        );

        var requestType = FirstNonBlank(
            GetJsonScalarString(canonicalJson, "requestType"),
            inboundRequestType
        );

        var entityNumber = FirstNonBlank(
            GetJsonScalarString(canonicalJson, "entityNumber"),
            inboundEntityNumber
        );

        var memberFirmCode = FirstNonBlank(
            GetJsonScalarString(canonicalJson, "memberFirmCode"),
            inboundMemberFirmCode
        );

        var eventType = FirstNonBlank(
            GetJsonScalarString(canonicalJson, "eventType"),
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
        AddIfNotBlank(applicationProperties, "dedupeKey", dedupeKey);

        var canonicalBody = canonicalJson.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true
        });

        _logger.LogInformation(
            "Canonical payload prepared. objectId={ObjectId}, CorrelationId={CorrelationId}, RequestId={RequestId}, MsgNumber={MsgNumber}, Subject={Subject}, CanonicalBodyLength={CanonicalBodyLength}, AppPropertyCount={AppPropertyCount}, DedupeKey={DedupeKey}",
            objectId,
            correlationId,
            requestId ?? "(null)",
            msgNumber ?? "(null)",
            subject ?? "(null)",
            canonicalBody.Length,
            applicationProperties.Count,
            dedupeKey ?? "(null)");

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
                "Publishing to Service Bus topic {TopicName} with CorrelationId={CorrelationId}, Subject={Subject}, DedupeKey={DedupeKey}",
                topicName,
                correlationId,
                subject ?? "(null)",
                dedupeKey ?? "(null)");

            await _publisher.PublishAsync(
                topicName: topicName,
                jsonPayload: canonicalBody,
                correlationId: correlationId,
                subject: subject,
                applicationProperties: applicationProperties,
                cancellationToken: cancellationToken);

            _logger.LogInformation(
                "Published canonical payload. topic={TopicName}, objectId={ObjectId}, correlationId={CorrelationId}, dedupeKey={DedupeKey}",
                topicName,
                objectId,
                correlationId,
                dedupeKey ?? "(null)");
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "Service Bus publish failed. topic={TopicName}, objectId={ObjectId}, correlationId={CorrelationId}, dedupeKey={DedupeKey}",
                topicName,
                objectId,
                correlationId,
                dedupeKey ?? "(null)");

            return await CreateResponse(req, HttpStatusCode.InternalServerError, $"Service Bus publish failed: {ex.Message}");
        }

        return await CreateResponse(
            req,
            HttpStatusCode.OK,
            $"Published canonical payload to '{topicName}'. objectId={objectId}; correlationId={correlationId}");
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

    private static async Task<HttpResponseData> CreateResponse(HttpRequestData req, HttpStatusCode code, string body)
    {
        var response = req.CreateResponse(code);
        response.Headers.Add("Content-Type", "text/plain; charset=utf-8");
        await response.WriteStringAsync(body);
        return response;
    }
}