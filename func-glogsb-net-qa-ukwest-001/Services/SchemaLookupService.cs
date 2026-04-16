using System.Text.Json.Nodes;
using Microsoft.Data.SqlClient;

namespace func_glogsb_net_qa_ukwest_001;

public class SchemaLookupService
{
    public async Task<JsonObject> GetSchemaAsync(
        string messageType,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(messageType))
        {
            throw new ArgumentException("Message type is required.", nameof(messageType));
        }

        var normalizedMessageType = messageType.Trim().ToLowerInvariant();
        if (normalizedMessageType is not ("client" or "matter" or "payor"))
        {
            throw new InvalidOperationException(
                $"Unsupported message type '{messageType}'. Expected client, matter, or payor.");
        }

        var connectionString = SqlConnectionHelper.BuildConnectionString();

        const string sql = @"
SELECT TOP (1)
    client,
    matter,
    payor
FROM dbo._NRF_sbSchemas
ORDER BY Id DESC;";

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand(sql, conn);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

        if (!await reader.ReadAsync(cancellationToken))
        {
            throw new InvalidOperationException(
                "No rows were found in dbo._NRF_sbSchemas.");
        }

        var schemaJson = normalizedMessageType switch
        {
            "client" => reader["client"] as string,
            "matter" => reader["matter"] as string,
            "payor"  => reader["payor"] as string,
            _ => null
        };

        if (string.IsNullOrWhiteSpace(schemaJson))
        {
            throw new InvalidOperationException(
                $"Schema column '{normalizedMessageType}' in dbo._NRF_sbSchemas is null or empty.");
        }

        var parsed = JsonNode.Parse(schemaJson) as JsonObject;
        if (parsed is null)
        {
            throw new InvalidOperationException(
                $"Schema column '{normalizedMessageType}' does not contain a valid JSON object.");
        }

        return parsed;
    }
}