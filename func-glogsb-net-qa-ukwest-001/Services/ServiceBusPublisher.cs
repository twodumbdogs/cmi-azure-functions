using System.Text;
using Azure.Messaging.ServiceBus;

namespace func_glogsb_net_qa_ukwest_001;

public class ServiceBusPublisher
{
    private readonly ServiceBusClient _serviceBusClient;

    public ServiceBusPublisher(ServiceBusClient serviceBusClient)
    {
        _serviceBusClient = serviceBusClient;
    }

    public async Task PublishAsync(
        string topicName,
        string body,
        string correlationId,
        string objectId,
        string topicKey)
    {
        var sender = _serviceBusClient.CreateSender(topicName);

        var message = new ServiceBusMessage(Encoding.UTF8.GetBytes(body))
        {
            ContentType = "application/json",
            CorrelationId = correlationId,
            MessageId = Guid.NewGuid().ToString(),
            Subject = topicKey
        };

        message.ApplicationProperties["objectId"] = objectId;
        message.ApplicationProperties["topicKey"] = topicKey;

        await sender.SendMessageAsync(message);
    }
}