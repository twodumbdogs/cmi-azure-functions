namespace func_glogsb_net_qa_ukwest_001;

internal static class SqlConnectionHelper
{
    public static string BuildConnectionString()
    {
        var fullConnectionString = Environment.GetEnvironmentVariable("Sql__ConnectionString");
        if (!string.IsNullOrWhiteSpace(fullConnectionString))
        {
            return fullConnectionString;
        }

        var server = Environment.GetEnvironmentVariable("Sql__Server")
                     ?? throw new InvalidOperationException("Missing env var: Sql__Server");

        var database = Environment.GetEnvironmentVariable("Sql__Database")
                       ?? throw new InvalidOperationException("Missing env var: Sql__Database");

        return $"Server={server};Database={database};Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;";
    }
}