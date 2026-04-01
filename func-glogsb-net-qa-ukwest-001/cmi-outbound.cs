using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace func_glogsb_net_qa_ukwest_001;

public class cmi_outbound
{
    private readonly ILogger<cmi_outbound> _logger;

    public cmi_outbound(ILogger<cmi_outbound> logger)
    {
        _logger = logger;
    }

    [Function("cmi_outbound")]
    public IActionResult Run([HttpTrigger(AuthorizationLevel.Function, "get", "post")] HttpRequest req)
    {
        _logger.LogInformation("C# HTTP trigger function processed a request.");
        return new OkObjectResult("Welcome to Azure Functions!");
    }
}