USE [IntAppOpen_Dev]
GO

/****** Object:  Table [dbo].[_NRF_sbPayloads]    Script Date: 6/24/2026 8:15:53 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[_NRF_sbPayloads](
	[id] [bigint] IDENTITY(1,1) NOT NULL,
	[topic] [nvarchar](100) NOT NULL,
	[jsonPayload] [nvarchar](max) NOT NULL,
	[dateProcessed] [datetime2](3) NOT NULL,
	[correlationId] [nvarchar](100) NOT NULL,
	[requestId] [nvarchar](100) NOT NULL,
	[response] [nvarchar](10) NOT NULL,
	[memberFirm] [nvarchar](10) NOT NULL,
	[entityNumber] [varchar](20) NULL,
	[regionResponse] [nvarchar](max) NULL,
	[matterNumber] [varchar](20) NULL,
	[prettyError] [nvarchar](max) NULL,
	[objectId] [nvarchar](20) NULL,
	[regionDateProcessed] [datetime2](3) NULL,
 CONSTRAINT [PK__NRF_sbPayloads] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

ALTER TABLE [dbo].[_NRF_sbPayloads] ADD  CONSTRAINT [DF__NRF_sbPayloads_dateProcessed]  DEFAULT (sysutcdatetime()) FOR [dateProcessed]
GO


