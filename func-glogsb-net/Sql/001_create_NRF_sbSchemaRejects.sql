/*
    dbo._NRF_sbSchemaRejects

    Purpose:
    Capture final merged CMI payloads that fail JSON Schema validation before
    the function calls Integration Builder or publishes to Service Bus.

    Notes:
    - correlationId is intended to join back to dbo._NRF_sbPayloads.
    - This script creates only the table and indexes.
    - The Azure Function writes with a direct parameterized INSERT.
    - environmentName, schemaName, schemaVersion, resolvedBy, and notes are intentionally omitted.
*/

IF OBJECT_ID(N'dbo._NRF_sbSchemaRejects', N'U') IS NULL
BEGIN
    CREATE TABLE dbo._NRF_sbSchemaRejects
    (
        id bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK__NRF_sbSchemaRejects PRIMARY KEY,

        dateProcessed datetime2(3) NOT NULL
            CONSTRAINT DF__NRF_sbSchemaRejects_dateProcessed
            DEFAULT SYSUTCDATETIME(),

        correlationId nvarchar(100) NOT NULL,

        topicKey nvarchar(50) NULL,
        objectId nvarchar(100) NULL,
        entityNumber nvarchar(100) NULL,
        matterNumber nvarchar(100) NULL,
        requestID nvarchar(100) NULL,
        msgNumber nvarchar(100) NULL,
        requestType nvarchar(100) NULL,
        eventType nvarchar(100) NULL,
        memberFirmCode nvarchar(50) NULL,

        functionName nvarchar(100) NULL,
        invocationId nvarchar(100) NULL,

        httpStatusCode int NOT NULL,
        errorCode nvarchar(100) NOT NULL,
        validationStatus nvarchar(100) NULL,

        failedField nvarchar(500) NULL,
        responseError nvarchar(max) NULL,
        validationError nvarchar(max) NULL,

        mergedPayload nvarchar(max) NULL,
        payloadHash varbinary(32) NULL,

        isResolved bit NOT NULL
            CONSTRAINT DF__NRF_sbSchemaRejects_isResolved
            DEFAULT 0,

        resolvedDate datetime2(3) NULL
    );
END;
GO


IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE name = N'IX__NRF_sbSchemaRejects_correlationId'
      AND object_id = OBJECT_ID(N'dbo._NRF_sbSchemaRejects')
)
BEGIN
    CREATE INDEX IX__NRF_sbSchemaRejects_correlationId
    ON dbo._NRF_sbSchemaRejects (correlationId);
END;
GO


IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE name = N'IX__NRF_sbSchemaRejects_dateProcessed'
      AND object_id = OBJECT_ID(N'dbo._NRF_sbSchemaRejects')
)
BEGIN
    CREATE INDEX IX__NRF_sbSchemaRejects_dateProcessed
    ON dbo._NRF_sbSchemaRejects (dateProcessed DESC);
END;
GO


IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE name = N'IX__NRF_sbSchemaRejects_topic_object'
      AND object_id = OBJECT_ID(N'dbo._NRF_sbSchemaRejects')
)
BEGIN
    CREATE INDEX IX__NRF_sbSchemaRejects_topic_object
    ON dbo._NRF_sbSchemaRejects (topicKey, objectId, dateProcessed DESC);
END;
GO


IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE name = N'IX__NRF_sbSchemaRejects_invocationId'
      AND object_id = OBJECT_ID(N'dbo._NRF_sbSchemaRejects')
)
BEGIN
    CREATE INDEX IX__NRF_sbSchemaRejects_invocationId
    ON dbo._NRF_sbSchemaRejects (invocationId)
    WHERE invocationId IS NOT NULL;
END;
GO


IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE name = N'IX__NRF_sbSchemaRejects_failedField'
      AND object_id = OBJECT_ID(N'dbo._NRF_sbSchemaRejects')
)
BEGIN
    CREATE INDEX IX__NRF_sbSchemaRejects_failedField
    ON dbo._NRF_sbSchemaRejects (failedField, dateProcessed DESC)
    WHERE failedField IS NOT NULL;
END;
GO


/*
    Optional helper queries
*/

-- Recent schema rejects
SELECT TOP (100)
    id,
    dateProcessed,
    correlationId,
    topicKey,
    objectId,
    httpStatusCode,
    errorCode,
    validationStatus,
    failedField,
    invocationId
FROM dbo._NRF_sbSchemaRejects
ORDER BY dateProcessed DESC;


-- Most common failed fields in the last 7 days
SELECT
    failedField,
    COUNT(*) AS rejectCount,
    MAX(dateProcessed) AS lastRejectDate
FROM dbo._NRF_sbSchemaRejects
WHERE dateProcessed >= DATEADD(day, -7, SYSUTCDATETIME())
GROUP BY failedField
ORDER BY rejectCount DESC, failedField;


-- Join back to sbPayloads by correlationId
SELECT TOP (100)
    r.id AS rejectId,
    r.dateProcessed AS rejectDate,
    r.correlationId,
    r.topicKey,
    r.objectId,
    r.httpStatusCode,
    r.errorCode,
    r.failedField,
    r.responseError,
    p.id AS sbPayloadId,
    p.dateProcessed AS sbPayloadDate,
    p.topic AS sbPayloadTopic
FROM dbo._NRF_sbSchemaRejects r
LEFT JOIN dbo._NRF_sbPayloads p
    ON p.correlationId = r.correlationId
ORDER BY r.dateProcessed DESC;
