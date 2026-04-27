using System.Net;
using System.Net.Http;
using System.Text;
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

            incomingJson = JsonNode.Parse(rawBody) as JsonObject;
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
        var inboundRequestId = GetJsonScalarString(incomingJson, "requestID");
        var inboundMsgNumber = GetJsonScalarString(incomingJson, "msgNumber");
        var inboundRequestType = GetJsonScalarString(incomingJson, "requestType");
        var inboundEventType = GetJsonScalarString(incomingJson, "eventType");
        var inboundCorrelationId = GetJsonScalarString(incomingJson, "correlationId");
        var inboundMemberFirmCode = GetJsonScalarString(incomingJson, "memberFirmCode");

        var objectId = FirstNonBlank(
            inboundObjectId,
            inboundEntityNumber
        );

        _logger.LogInformation(
            "Inbound parsed fields: topicKey={TopicKey}, objectId={InboundObjectId}, entityNumber={InboundEntityNumber}, requestID={InboundRequestId}, msgNumber={InboundMsgNumber}, requestType={InboundRequestType}, eventType={InboundEventType}, memberFirmCode={InboundMemberFirmCode}, correlationId={InboundCorrelationId}",
            topicKey ?? "(null)",
            inboundObjectId ?? "(null)",
            inboundEntityNumber ?? "(null)",
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
            _logger.LogWarning("Missing objectId/entityNumber.");
            return await CreateResponse(req, HttpStatusCode.BadRequest, "Missing objectId/entityNumber.");
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

        // ---------------------------------------------------------------------
        // PRE-MERGE IB CALL
        // Send the RAW inbound payload to IB before SQL lookup / merge.
        // Fail-open on purpose, matching prior PowerShell behavior.
        // ---------------------------------------------------------------------
        await TrySendToIbAsync(
            rawBody: rawBody,
            topicKey: topicKey,
            routeStatus: routeStatus,
            routeTarget: routeTarget,
            cancellationToken: cancellationToken);

        if (topicName is null)
        {
            return await CreateResponse(req, HttpStatusCode.OK, $"No SB route for '{topicKey}'. Sent to IB pre-merge only (status=error).");
        }

        JsonObject? sqlPayloadJson;
        try
        {
            sqlPayloadJson = await _lookupService.LookupExistingPayloadAsync(objectId);

            _logger.LogInformation(
                "SQL lookup complete for objectId {ObjectId}. PayloadFound={PayloadFound}",
                objectId,
                sqlPayloadJson is not null);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "SQL lookup failed for objectId {ObjectId}", objectId);
            return await CreateResponse(req, HttpStatusCode.InternalServerError, $"SQL lookup failed: {ex.Message}");
        }

        JsonObject mergedJson;
        if (sqlPayloadJson is null)
        {
            _logger.LogInformation(
                "No SQL payload found for objectId {ObjectId}. Using inbound payload as-is.",
                objectId);

            mergedJson = (JsonObject?)incomingJson.DeepClone() ?? new JsonObject();
        }
        else
        {
            _logger.LogInformation(
                "SQL payload found for objectId {ObjectId}. Merging inbound payload over SQL template.",
                objectId);

            mergedJson = _mergeService.MergeObjects(incomingJson, sqlPayloadJson);
        }

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
            $"Sent raw payload to IB pre-merge and published merged payload to '{topicName}'. objectId={objectId}; correlationId={correlationId}");
    }

    private async Task TrySendToIbAsync(
        string rawBody,
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
                "Calling IB rule pre-merge. Host={IbHost}, RuleId={RuleId}, RouteStatus={RouteStatus}, RouteTarget={RouteTarget}, RawBodyLength={RawBodyLength}, SkipCertificateCheck={SkipCertificateCheck}",
                ibHost,
                ruleId,
                routeStatus,
                routeTarget ?? "(null)",
                rawBody.Length,
                skipCertificateCheck);

            var ibRequest = new
            {
                inputs = new[]
                {
                    new
                    {
                        name = "jsonBody",
                        value = rawBody
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
                    "IB rule execution request accepted pre-merge. StatusCode={StatusCode}, ResponseLength={ResponseLength}",
                    (int)response.StatusCode,
                    responseBody?.Length ?? 0);
            }
            else
            {
                _logger.LogWarning(
                    "IB rule execution returned non-success pre-merge. StatusCode={StatusCode}, ReasonPhrase={ReasonPhrase}, ResponseBody={ResponseBody}",
                    (int)response.StatusCode,
                    response.ReasonPhrase ?? "(null)",
                    Truncate(responseBody, 4000));
            }
        }
        catch (Exception ex)
        {
            // Fail-open on purpose to preserve main HTTP/SB flow even if IB is down.
            _logger.LogError(ex, "IB rule execution failed pre-merge.");
        }
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
