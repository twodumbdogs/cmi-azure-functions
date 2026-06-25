using System.Data;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace func_glogsb_net;

public sealed class SchemaValidationFailureRecord
{
    public string? TopicKey { get; init; }
    public string? ObjectId { get; init; }
    public string? EntityNumber { get; init; }
    public string? MatterNumber { get; init; }
    public string? RequestId { get; init; }
    public string? MsgNumber { get; init; }
    public string? RequestType { get; init; }
    public string? EventType { get; init; }
    public string? MemberFirmCode { get; init; }

    public string? FunctionName { get; init; }
    public string? InvocationId { get; init; }

    public string? CorrelationId { get; init; }

    public int HttpStatusCode { get; init; }
    public string? ErrorCode { get; init; }
    public string? ValidationStatus { get; init; }

    public string? FailedField { get; init; }
    public string? ResponseError { get; init; }
    public string? ValidationError { get; init; }

    public string? MergedPayload { get; init; }
}

public sealed class SchemaValidationFailureWriter
{
    private const string DefaultTableName = "dbo._NRF_sbSchemaRejects";
    private const int DefaultCommandTimeoutSeconds = 30;

    private static readonly Regex TwoPartSqlNameRegex = new(
        @"^(?<schema>[A-Za-z_][A-Za-z0-9_]*)\.(?<table>[A-Za-z_][A-Za-z0-9_]*)$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private readonly ILogger<SchemaValidationFailureWriter> _logger;

    public SchemaValidationFailureWriter(ILogger<SchemaValidationFailureWriter> logger)
    {
        _logger = logger;
    }

    /// <summary>
    /// Writes a schema reject row using a direct parameterized INSERT.
    /// Returns false when SchemaRejects__Enabled is explicitly disabled.
    /// </summary>
    public async Task<bool> WriteAsync(
        SchemaValidationFailureRecord failure,
        CancellationToken cancellationToken)
    {
        if (!GetBooleanEnvironmentVariable("SchemaRejects__Enabled", defaultValue: true))
        {
            return false;
        }

        if (string.IsNullOrWhiteSpace(failure.CorrelationId))
        {
            throw new ArgumentException("Schema validation failure record is missing correlationId.", nameof(failure));
        }

        if (failure.HttpStatusCode <= 0)
        {
            throw new ArgumentException("Schema validation failure record is missing httpStatusCode.", nameof(failure));
        }

        if (string.IsNullOrWhiteSpace(failure.ErrorCode))
        {
            throw new ArgumentException("Schema validation failure record is missing errorCode.", nameof(failure));
        }

        var tableName = GetValidatedTableName();
        var commandTimeoutSeconds = GetIntEnvironmentVariable(
            "SchemaRejects__CommandTimeoutSeconds",
            defaultValue: DefaultCommandTimeoutSeconds,
            minValue: 1,
            maxValue: 300);

        var writeMergedPayload = GetBooleanEnvironmentVariable(
            "SchemaRejects__WriteMergedPayload",
            defaultValue: true);

        var mergedPayload = writeMergedPayload
            ? failure.MergedPayload
            : null;

        var connectionString = BuildSqlConnectionString();

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand(BuildInsertSql(tableName), connection)
        {
            CommandType = CommandType.Text,
            CommandTimeout = commandTimeoutSeconds
        };

        AddNullableString(command.Parameters, "@correlationId", SqlDbType.NVarChar, 100, failure.CorrelationId);

        AddNullableString(command.Parameters, "@topicKey", SqlDbType.NVarChar, 50, failure.TopicKey);
        AddNullableString(command.Parameters, "@objectId", SqlDbType.NVarChar, 100, failure.ObjectId);
        AddNullableString(command.Parameters, "@entityNumber", SqlDbType.NVarChar, 100, failure.EntityNumber);
        AddNullableString(command.Parameters, "@matterNumber", SqlDbType.NVarChar, 100, failure.MatterNumber);
        AddNullableString(command.Parameters, "@requestID", SqlDbType.NVarChar, 100, failure.RequestId);
        AddNullableString(command.Parameters, "@msgNumber", SqlDbType.NVarChar, 100, failure.MsgNumber);
        AddNullableString(command.Parameters, "@requestType", SqlDbType.NVarChar, 100, failure.RequestType);
        AddNullableString(command.Parameters, "@eventType", SqlDbType.NVarChar, 100, failure.EventType);
        AddNullableString(command.Parameters, "@memberFirmCode", SqlDbType.NVarChar, 50, failure.MemberFirmCode);

        AddNullableString(command.Parameters, "@functionName", SqlDbType.NVarChar, 100, failure.FunctionName);
        AddNullableString(command.Parameters, "@invocationId", SqlDbType.NVarChar, 100, failure.InvocationId);

        command.Parameters.Add(new SqlParameter("@httpStatusCode", SqlDbType.Int)
        {
            Value = failure.HttpStatusCode
        });

        AddNullableString(command.Parameters, "@errorCode", SqlDbType.NVarChar, 100, failure.ErrorCode);
        AddNullableString(command.Parameters, "@validationStatus", SqlDbType.NVarChar, 100, failure.ValidationStatus);

        AddNullableString(command.Parameters, "@failedField", SqlDbType.NVarChar, 500, failure.FailedField);
        AddNullableString(command.Parameters, "@responseError", SqlDbType.NVarChar, -1, failure.ResponseError);
        AddNullableString(command.Parameters, "@validationError", SqlDbType.NVarChar, -1, failure.ValidationError);

        AddNullableString(command.Parameters, "@mergedPayload", SqlDbType.NVarChar, -1, mergedPayload);

        await command.ExecuteNonQueryAsync(cancellationToken);

        _logger.LogInformation(
            "Inserted SB schema reject using direct INSERT. tableName={TableName}, functionName={FunctionName}, invocationId={InvocationId}, correlationId={CorrelationId}, topicKey={TopicKey}, objectId={ObjectId}, httpStatusCode={HttpStatusCode}, errorCode={ErrorCode}, failedField={FailedField}, writeMergedPayload={WriteMergedPayload}",
            tableName,
            failure.FunctionName ?? "(null)",
            failure.InvocationId ?? "(null)",
            failure.CorrelationId,
            failure.TopicKey ?? "(null)",
            failure.ObjectId ?? "(null)",
            failure.HttpStatusCode,
            failure.ErrorCode,
            failure.FailedField ?? "(unknown)",
            writeMergedPayload);

        return true;
    }

    private static string BuildInsertSql(string tableName) =>
        $"""
        INSERT INTO {tableName}
        (
            correlationId,

            topicKey,
            objectId,
            entityNumber,
            matterNumber,
            requestID,
            msgNumber,
            requestType,
            eventType,
            memberFirmCode,

            functionName,
            invocationId,

            httpStatusCode,
            errorCode,
            validationStatus,

            failedField,
            responseError,
            validationError,

            mergedPayload,
            payloadHash
        )
        VALUES
        (
            @correlationId,

            @topicKey,
            @objectId,
            @entityNumber,
            @matterNumber,
            @requestID,
            @msgNumber,
            @requestType,
            @eventType,
            @memberFirmCode,

            @functionName,
            @invocationId,

            @httpStatusCode,
            @errorCode,
            @validationStatus,

            @failedField,
            @responseError,
            @validationError,

            @mergedPayload,
            CASE
                WHEN @mergedPayload IS NULL THEN NULL
                ELSE HASHBYTES('SHA2_256', CONVERT(varbinary(max), @mergedPayload))
            END
        );
        """;

    private static string GetValidatedTableName()
    {
        var rawTableName = Environment.GetEnvironmentVariable("SchemaRejects__TableName");

        if (string.IsNullOrWhiteSpace(rawTableName))
        {
            rawTableName = DefaultTableName;
        }

        rawTableName = rawTableName.Trim();

        var match = TwoPartSqlNameRegex.Match(rawTableName);
        if (!match.Success)
        {
            throw new InvalidOperationException(
                "Invalid SchemaRejects__TableName. Use a simple two-part SQL name like dbo._NRF_sbSchemaRejects. " +
                "Do not include brackets, quotes, spaces, semicolons, database names, or dynamic SQL.");
        }

        var schemaName = match.Groups["schema"].Value;
        var tableName = match.Groups["table"].Value;

        return $"[{schemaName}].[{tableName}]";
    }

    private static string BuildSqlConnectionString()
    {
        var fullConnectionString = Environment.GetEnvironmentVariable("Sql__ConnectionString");

        if (!string.IsNullOrWhiteSpace(fullConnectionString))
        {
            return fullConnectionString;
        }

        var sqlServer = Environment.GetEnvironmentVariable("Sql__Server");
        var sqlDatabase = Environment.GetEnvironmentVariable("Sql__Database");

        if (string.IsNullOrWhiteSpace(sqlServer))
        {
            throw new InvalidOperationException("Missing SQL setting. Configure Sql__ConnectionString or Sql__Server.");
        }

        if (string.IsNullOrWhiteSpace(sqlDatabase))
        {
            throw new InvalidOperationException("Missing SQL setting. Configure Sql__ConnectionString or Sql__Database.");
        }

        var builder = new SqlConnectionStringBuilder
        {
            DataSource = sqlServer,
            InitialCatalog = sqlDatabase,
            Encrypt = true,
            TrustServerCertificate = false,
            ConnectTimeout = 30,
            Authentication = SqlAuthenticationMethod.ActiveDirectoryDefault
        };

        return builder.ConnectionString;
    }

    private static bool GetBooleanEnvironmentVariable(string name, bool defaultValue)
    {
        var rawValue = Environment.GetEnvironmentVariable(name);

        if (string.IsNullOrWhiteSpace(rawValue))
        {
            return defaultValue;
        }

        return rawValue.Trim().ToLowerInvariant() switch
        {
            "1" or "true" or "yes" or "y" or "on" => true,
            "0" or "false" or "no" or "n" or "off" => false,
            _ => defaultValue
        };
    }

    private static int GetIntEnvironmentVariable(
        string name,
        int defaultValue,
        int minValue,
        int maxValue)
    {
        var rawValue = Environment.GetEnvironmentVariable(name);

        if (!int.TryParse(rawValue, out var value))
        {
            return defaultValue;
        }

        return Math.Clamp(value, minValue, maxValue);
    }

    private static void AddNullableString(
        SqlParameterCollection parameters,
        string name,
        SqlDbType sqlDbType,
        int size,
        string? value)
    {
        var parameter = size == -1
            ? new SqlParameter(name, sqlDbType)
            : new SqlParameter(name, sqlDbType, size);

        parameter.Value = string.IsNullOrWhiteSpace(value)
            ? DBNull.Value
            : value;

        parameters.Add(parameter);
    }
}
