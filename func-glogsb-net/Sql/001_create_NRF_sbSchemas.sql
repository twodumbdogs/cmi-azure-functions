USE [IntAppOpen_Dev]
GO

/****** Object:  Table [dbo].[_NRF_sbSchemas]    Script Date: 6/24/2026 8:16:43 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[_NRF_sbSchemas](
	[Id] [int] IDENTITY(1,1) NOT NULL,
	[client] [varchar](max) NULL,
	[matter] [varchar](max) NULL,
	[payor] [varchar](max) NULL,
	[CreatedUtc] [datetime2](3) NOT NULL,
	[UpdatedUtc] [datetime2](3) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

ALTER TABLE [dbo].[_NRF_sbSchemas] ADD  DEFAULT (sysutcdatetime()) FOR [CreatedUtc]
GO


