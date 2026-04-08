using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using func_glogsb_net_qa_ukwest_001;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices(services =>
    {
        services.AddSingleton(sp =>
        {
            var serviceBusConnectionString =
                Environment.GetEnvironmentVariable("service_bus__connectionString");

            if (!string.IsNullOrWhiteSpace(serviceBusConnectionString))
            {
                Console.WriteLine("Using Service Bus SAS connection string authentication.");
                return new ServiceBusClient(serviceBusConnectionString);
            }

            var fullyQualifiedNamespace =
                Environment.GetEnvironmentVariable("service_bus_RBAC__fullyQualifiedNamespace")
                ?? throw new InvalidOperationException(
                    "Missing configuration. Set either 'service_bus__connectionString' or 'service_bus_RBAC__fullyQualifiedNamespace'.");

            Console.WriteLine("Using Service Bus RBAC (DefaultAzureCredential) authentication.");

            return new ServiceBusClient(
                fullyQualifiedNamespace,
                new DefaultAzureCredential());
        });

        services.AddSingleton<JsonMergeService>();
        services.AddSingleton<PayloadLookupService>();
        services.AddSingleton<ServiceBusPublisher>();
    })
    .Build();

host.Run();