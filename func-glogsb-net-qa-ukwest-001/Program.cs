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
            var fullyQualifiedNamespace =
                 Environment.GetEnvironmentVariable("service_bus_RBAC__fullyQualifiedNamespace")
                 ?? throw new InvalidOperationException("Missing env var: service_bus_RBAC__fullyQualifiedNamespace");

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
