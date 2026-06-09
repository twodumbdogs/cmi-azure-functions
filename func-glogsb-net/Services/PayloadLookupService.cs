using System.Text.Json.Nodes;
using Microsoft.Data.SqlClient;

namespace func_glogsb_net;

public class PayloadLookupService
{
    public async Task<JsonObject?> LookupSchemaTemplateAsync(string topicKey)
    {
        var columnName = ResolveSchemaColumnName(topicKey);
        if (columnName is null)
        {
            return null;
        }

        var connectionString = BuildConnectionString();
        var sql = $@"
SELECT TOP (1) [{columnName}]
FROM dbo._NRF_sbSchemas
WHERE NULLIF(LTRIM(RTRIM([{columnName}])), '') IS NOT NULL
  AND ISJSON([{columnName}]) = 1
ORDER BY UpdatedUtc DESC, Id DESC;";

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync();

        await using var cmd = new SqlCommand(sql, conn);

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

        var json = JsonNode.Parse(jsonText) as JsonObject;
        return json is null ? null : JsonPayloadNormalizer.NormalizeObject(json);
    }

    public async Task<JsonObject?> LookupExistingPayloadAsync(string objectId, string topicKey)
    {
        var connectionString = BuildConnectionString();

        const string sql = @"
SELECT TOP (1) jsonPayload
FROM dbo._NRF_sbPayloads
WHERE (
    (LOWER(@topicKey) = 'matter' AND (matterNumber = @objectId OR objectId = @objectId))
    OR (LOWER(@topicKey) <> 'matter' AND (entityNumber = @objectId OR objectId = @objectId))
)
  AND ISJSON(jsonPayload) = 1
  AND LOWER(topic) = LOWER(@topicKey)
ORDER BY id DESC;";

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync();

        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@objectId", objectId);
        cmd.Parameters.AddWithValue("@topicKey", topicKey);

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

        var json = JsonNode.Parse(jsonText) as JsonObject;
        return json is null ? null : JsonPayloadNormalizer.NormalizeObject(json);
    }

    private static string? ResolveSchemaColumnName(string topicKey) =>
        topicKey.Trim().ToLowerInvariant() switch
        {
            "client" => "client",
            "matter" => "matter",
            "payor" => "payor",
            _ => null
        };

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
