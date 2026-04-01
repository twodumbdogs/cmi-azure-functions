using System.Text.Json.Nodes;
using Microsoft.Data.SqlClient;

namespace func_glogsb_net_qa_ukwest_001;

public class PayloadLookupService
{
    public async Task<JsonObject?> LookupExistingPayloadAsync(string objectId)
    {
        var connectionString = BuildConnectionString();

        const string sql = @"
SELECT TOP (1) jsonPayload
FROM dbo._NRF_sbPayloads
WHERE objectId = @objectId
ORDER BY id DESC;";

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync();

        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@objectId", objectId);

        var result = await cmd.ExecuteScalarAsync();
        if (result is null || result == DBNull.Value)
        {
            return null;
        }

        var jsonText = Convert.ToString(result);
        if (string.IsNullOrWhiteSpace(jsonText))
        {
            return null;
        }

        return JsonNode.Parse(jsonText) as JsonObject;
    }

    private static string BuildConnectionString()
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