using System.Text.Json.Nodes;
using Microsoft.Data.SqlClient;

namespace func_glogsb_net_qa_ukwest_001;

public class PayloadLookupService
{
    public async Task<JsonObject?> LookupExistingPayloadAsync(
        string objectId,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(objectId))
        {
            throw new ArgumentException("objectId is required.", nameof(objectId));
        }

        var connectionString = SqlConnectionHelper.BuildConnectionString();

        const string sql = @"
SELECT TOP (1) jsonPayload
FROM dbo._NRF_sbPayloads
WHERE objectId = @objectId
ORDER BY id DESC;";

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add(new SqlParameter("@objectId", System.Data.SqlDbType.VarChar, 20)
        {
            Value = objectId
        });

        var result = await cmd.ExecuteScalarAsync(cancellationToken);

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
}