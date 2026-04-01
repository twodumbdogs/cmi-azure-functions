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
    private readonly JsonMergeService _mergeService;
    private readonly ServiceBusPublisher _publisher;

    public CmiOutboundFunction(
        ILogger<CmiOutboundFunction> logger,
        PayloadLookupService lookupService,
        JsonMergeService mergeService,
        ServiceBusPublisher publisher)
    {
        _logger = logger;
        _lookupService = lookupService;
        _mergeService = mergeService;
        _publisher = publisher;
    }

    [Function("cmi-outbound-v0")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post")] HttpRequestData req)
    {
        string rawBody;
        JsonObject? rightJson;

        try
        {
            using var reader = new StreamReader(req.Body);
            rawBody = await reader.ReadToEndAsync();

            if (string.IsNullOrWhiteSpace(rawBody))
            {
                return await CreateResponse(req, HttpStatusCode.BadRequest, "Empty request body.");
            }

            rightJson = JsonNode.Parse(rawBody) as JsonObject;
            if (rightJson is null)
            {
                return await CreateResponse(req, HttpStatusCode.BadRequest, "Request body must be a JSON object.");
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to parse request body.");
            return await CreateResponse(req, HttpStatusCode.BadRequest, $"Invalid JSON body: {ex.Message}");
        }

        _logger.LogInformation("Inbound payload received.");

        var topicKey = rightJson["topicKey"]?.GetValue<string>()?.Trim();
        var objectId = FirstNonBlank(
            GetJsonString(rightJson, "objectId"),
            GetJsonString(rightJson, "entityNumber")
        );

        if (string.IsNullOrWhiteSpace(topicKey))
        {
            return await CreateResponse(req, HttpStatusCode.BadRequest, "Missing topicKey.");
        }

        if (string.IsNullOrWhiteSpace(objectId))
        {
            return await CreateResponse(req, HttpStatusCode.BadRequest, "Missing objectId/entityNumber.");
        }

        var topicName = ResolveTopicName(topicKey);
        if (topicName is null)
        {
            _logger.LogWarning("No matching route for topicKey '{TopicKey}'. Not publishing.", topicKey);
            return await CreateResponse(req, HttpStatusCode.OK, $"No SB route for '{topicKey}'. Not published.");
        }

        JsonObject? leftJson;
        try
        {
            leftJson = await _lookupService.LookupExistingPayloadAsync(objectId);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "SQL lookup failed for objectId {ObjectId}", objectId);
            return await CreateResponse(req, HttpStatusCode.InternalServerError, $"SQL lookup failed: {ex.Message}");
        }

        JsonObject mergedJson;
        if (leftJson is null)
        {
            _logger.LogInformation("No SQL payload found for objectId {ObjectId}. Using inbound payload as-is.", objectId);
            mergedJson = (JsonObject?)rightJson.DeepClone() ?? new JsonObject();
        }
        else
        {
            _logger.LogInformation("SQL payload found for objectId {ObjectId}. Merging left <- right.", objectId);
            mergedJson = _mergeService.MergeObjects(leftJson, rightJson);
        }

        var correlationId = FirstNonBlank(
            GetJsonString(mergedJson, "correlationId"),
            GetJsonString(rightJson, "correlationId"),
            Guid.NewGuid().ToString()
        )!;

        mergedJson["correlationId"] = correlationId;

        var mergedBody = mergedJson.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = false
        });

try
{
    _logger.LogInformation(
        "Publishing to Service Bus topic {TopicName} with correlationId {CorrelationId}",
        topicName, correlationId);

    await _publisher.PublishAsync(topicName, mergedBody, correlationId, objectId, topicKey);

    _logger.LogInformation(
        "Published merged payload. topic={TopicName}, objectId={ObjectId}, correlationId={CorrelationId}",
        topicName, objectId, correlationId);
}
catch (Exception ex)
{
    _logger.LogError(ex,
        "Service Bus publish failed. topic={TopicName}, objectId={ObjectId}, correlationId={CorrelationId}",
        topicName, objectId, correlationId);

    return await CreateResponse(req, HttpStatusCode.InternalServerError, $"Service Bus publish failed: {ex.Message}");
}

        return await CreateResponse(
            req,
            HttpStatusCode.OK,
            $"Published merged payload to '{topicName}'. objectId={objectId}; correlationId={correlationId}");
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

    private static string? GetJsonString(JsonObject json, string propertyName)
    {
        if (!json.TryGetPropertyValue(propertyName, out var node) || node is null)
        {
            return null;
        }

        if (node is JsonValue value && value.TryGetValue<string>(out var s))
        {
            return s;
        }

        return node.ToJsonString();
    }

    private static async Task<HttpResponseData> CreateResponse(HttpRequestData req, HttpStatusCode code, string body)
    {
        var response = req.CreateResponse(code);
        response.Headers.Add("Content-Type", "text/plain; charset=utf-8");
        await response.WriteStringAsync(body);
        return response;
    }
}