using System.Collections.Concurrent;
using System.Text;
using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.Logging;

namespace func_glogsb_net_qa_ukwest_001;

public sealed class ServiceBusPublisher : IAsyncDisposable
{
    private readonly ServiceBusClient _client;
    private readonly ILogger<ServiceBusPublisher> _logger;
    private readonly ConcurrentDictionary<string, ServiceBusSender> _senders = new();

    public ServiceBusPublisher(
        ServiceBusClient client,
        ILogger<ServiceBusPublisher> logger)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public async Task PublishAsync(
        string topicName,
        string jsonPayload,
        string? correlationId = null,
        string? subject = null,
        IDictionary<string, object>? applicationProperties = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(topicName))
            throw new ArgumentException("Topic name is required.", nameof(topicName));

        if (string.IsNullOrWhiteSpace(jsonPayload))
            throw new ArgumentException("JSON payload is required.", nameof(jsonPayload));

        var sender = _senders.GetOrAdd(topicName, t =>
        {
            _logger.LogInformation("Creating Service Bus sender for topic: {TopicName}", t);
            return _client.CreateSender(t);
        });

        var message = new ServiceBusMessage(Encoding.UTF8.GetBytes(jsonPayload))
        {
            ContentType = "application/json"
        };

        if (!string.IsNullOrWhiteSpace(correlationId))
        {
            message.CorrelationId = correlationId.Trim();
        }

        if (!string.IsNullOrWhiteSpace(subject))
        {
            message.Subject = subject.Trim();
        }

        if (applicationProperties is not null)
        {
            foreach (var kvp in applicationProperties)
            {
                if (string.IsNullOrWhiteSpace(kvp.Key) || kvp.Value is null)
                {
                    continue;
                }

                message.ApplicationProperties[kvp.Key] = kvp.Value;
            }
        }

        _logger.LogInformation(
            "Publishing message to topic {TopicName}. CorrelationId={CorrelationId}, Subject={Subject}, AppPropertyCount={AppPropertyCount}",
            topicName,
            message.CorrelationId ?? "(null)",
            message.Subject ?? "(null)",
            message.ApplicationProperties.Count);

        await sender.SendMessageAsync(message, cancellationToken);

        _logger.LogInformation(
            "Successfully published message to topic {TopicName}. CorrelationId={CorrelationId}",
            topicName,
            message.CorrelationId ?? "(null)");
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var sender in _senders.Values)
        {
            await sender.DisposeAsync();
        }

        await _client.DisposeAsync();
    }
}