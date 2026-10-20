/* =============================================================================
   DIZPROD – Datenbank DIZ_NET_stage (Staging / Rohdaten aus Quellsystemen)
   Testschemata: kis (Rohdaten KIS), lis (Rohdaten Labor), stage (bereinigt)
   Enthaelt bewusst datenbankuebergreifende Referenzen auf [DIZ_NET]
   (View + Prozedur), um --reference im Toolkit zu testen.
   ============================================================================= */
SET NOCOUNT ON;
GO
CREATE DATABASE [DIZ_NET_stage] COLLATE Latin1_General_CI_AS;
GO
ALTER DATABASE [DIZ_NET_stage] SET RECOVERY SIMPLE;
GO
USE [DIZ_NET_stage];
GO

CREATE SCHEMA [kis]   AUTHORIZATION [dbo];
GO
CREATE SCHEMA [lis]   AUTHORIZATION [dbo];
GO
CREATE SCHEMA [stage] AUTHORIZATION [dbo];
GO

/* ------------------------------------------------------------- Rohdaten */
CREATE TABLE [kis].[Patient_raw] (
    [LadeId]       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_Patient_raw] PRIMARY KEY,
    [PatNr]        NVARCHAR(20)  NOT NULL,
    [Pseudonym]    CHAR(12)      NULL,
    [Geburtsdatum] NVARCHAR(20)  NULL,          -- Rohformat TT.MM.JJJJ
    [Geschlecht]   NVARCHAR(20)  NULL,
    [PLZ]          NVARCHAR(10)  NULL,
    [EingelesenAm] DATETIME2(0)  NOT NULL CONSTRAINT [DF_Patient_raw_EingelesenAm] DEFAULT (SYSDATETIME())
);
GO
CREATE TABLE [kis].[Fall_raw] (
    [LadeId]       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_Fall_raw] PRIMARY KEY,
    [FallNr]       NVARCHAR(20)  NOT NULL,
    [PatNr]        NVARCHAR(20)  NOT NULL,
    [Fallart]      NVARCHAR(20)  NULL,
    [Abteilung]    NVARCHAR(10)  NULL,
    [AufnahmeTS]   NVARCHAR(30)  NULL,
    [EntlassTS]    NVARCHAR(30)  NULL,
    [EingelesenAm] DATETIME2(0)  NOT NULL CONSTRAINT [DF_Fall_raw_EingelesenAm] DEFAULT (SYSDATETIME())
);
GO
CREATE TABLE [lis].[Befund_raw] (
    [LadeId]       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_Befund_raw] PRIMARY KEY,
    [FallNr]       NVARCHAR(20)  NOT NULL,
    [Loinc]        NVARCHAR(20)  NULL,
    [WertText]     NVARCHAR(50)  NULL,
    [Einheit]      NVARCHAR(20)  NULL,
    [MessTS]       NVARCHAR(30)  NULL,
    [EingelesenAm] DATETIME2(0)  NOT NULL CONSTRAINT [DF_Befund_raw_EingelesenAm] DEFAULT (SYSDATETIME())
);
GO
CREATE NONCLUSTERED INDEX [IX_Befund_raw_FallNr] ON [lis].[Befund_raw] ([FallNr]);
GO

/* ------------------------------------------------------------- bereinigt */
CREATE TABLE [stage].[Patient] (
    [Pseudonym]   CHAR(12)       NOT NULL CONSTRAINT [PK_stage_Patient] PRIMARY KEY,
    [Geburtsjahr] SMALLINT       NULL,
    [Geschlecht]  CHAR(1)        NULL,
    [PLZ]         CHAR(5)        NULL,
    [Gueltig]     BIT            NOT NULL CONSTRAINT [DF_stage_Patient_Gueltig] DEFAULT (1),
    [Fehlertext]  NVARCHAR(200)  NULL
);
GO

/* Abgleich mit dem Kernbestand in DIZ_NET (datenbankuebergreifend) */
CREATE VIEW [stage].[vPatientAbgleich]
AS
SELECT  s.[Pseudonym],
        s.[Geburtsjahr],
        s.[Geschlecht],
        s.[PLZ],
        s.[Gueltig],
        p.[PatientId],
        CASE
            WHEN p.[PatientId] IS NULL THEN 'NEU'
            WHEN p.[Geburtsjahr] <> s.[Geburtsjahr]
              OR p.[Geschlecht]  <> s.[Geschlecht]
              OR ISNULL(p.[PLZ], '') <> ISNULL(s.[PLZ], '') THEN 'GEAENDERT'
            ELSE 'UNVERAENDERT'
        END AS [Abgleich]
FROM      [stage].[Patient]            s
LEFT JOIN [DIZ_NET].[core].[Patient]   p ON p.[Pseudonym] = s.[Pseudonym];
GO

CREATE PROCEDURE [stage].[usp_PatientBereinigen]
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE [stage].[Patient];

    ;WITH r AS (
        SELECT  [Pseudonym], [Geburtsdatum], [Geschlecht], [PLZ],
                ROW_NUMBER() OVER (PARTITION BY [Pseudonym] ORDER BY [LadeId] DESC) AS rn
        FROM [kis].[Patient_raw]
        WHERE [Pseudonym] IS NOT NULL
    )
    INSERT INTO [stage].[Patient] ([Pseudonym], [Geburtsjahr], [Geschlecht], [PLZ], [Gueltig], [Fehlertext])
    SELECT  r.[Pseudonym],
            YEAR(TRY_CONVERT(DATE, r.[Geburtsdatum], 104)),
            CASE LOWER(LTRIM(RTRIM(r.[Geschlecht])))
                WHEN 'm' THEN 'm' WHEN N'männlich' THEN 'm'
                WHEN 'w' THEN 'w' WHEN 'weiblich'  THEN 'w'
                WHEN 'd' THEN 'd' WHEN 'divers'    THEN 'd'
                ELSE 'u' END,
            CASE WHEN r.[PLZ] LIKE '[0-9][0-9][0-9][0-9][0-9]' THEN r.[PLZ] END,
            CASE WHEN TRY_CONVERT(DATE, r.[Geburtsdatum], 104) IS NULL THEN 0 ELSE 1 END,
            CASE WHEN TRY_CONVERT(DATE, r.[Geburtsdatum], 104) IS NULL
                 THEN N'Ungültiges Geburtsdatum: ' + ISNULL(r.[Geburtsdatum], N'<leer>') END
    FROM r
    WHERE r.rn = 1;
END;
GO

/* Uebernahme neuer/geaenderter Patienten nach DIZ_NET (datenbankuebergreifend) */
CREATE PROCEDURE [stage].[usp_PatientUebernehmen]
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO [DIZ_NET].[core].[Patient] ([Pseudonym], [Geburtsjahr], [Geschlecht], [PLZ])
    SELECT a.[Pseudonym], a.[Geburtsjahr], a.[Geschlecht], a.[PLZ]
    FROM [stage].[vPatientAbgleich] a
    WHERE a.[Abgleich] = 'NEU' AND a.[Gueltig] = 1;

    UPDATE p
       SET p.[Geburtsjahr] = a.[Geburtsjahr],
           p.[Geschlecht]  = a.[Geschlecht],
           p.[PLZ]         = a.[PLZ]
    FROM [DIZ_NET].[core].[Patient] p
    INNER JOIN [stage].[vPatientAbgleich] a ON a.[PatientId] = p.[PatientId]
    WHERE a.[Abgleich] = 'GEAENDERT' AND a.[Gueltig] = 1;
END;
GO

/* ================================================================ Testdaten */
/* 30 Rohpatienten: 25 bekannte (davon 3 mit geaenderter PLZ), 5 neue, 2 mit ungueltigem Geburtsdatum */
;WITH n AS (SELECT TOP (30) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects)
INSERT INTO [kis].[Patient_raw] ([PatNr], [Pseudonym], [Geburtsdatum], [Geschlecht], [PLZ])
SELECT  'P' + RIGHT('0000000' + CAST(100000 + n AS VARCHAR(7)), 7),
        'PSN' + RIGHT('000000000' + CAST(n * 7919 AS VARCHAR(9)), 9),
        CASE n
            WHEN 27 THEN N'31.02.1980'
            WHEN 29 THEN N'unbekannt'
            ELSE CONVERT(NVARCHAR(10), DATEFROMPARTS(1935 + (n * 37) % 75, n % 12 + 1, n % 28 + 1), 104)
        END,
        CASE WHEN n = 13 THEN N'D'
             WHEN n % 2 = 0 THEN CASE WHEN n % 4 = 0 THEN N'weiblich' ELSE N'W' END
             ELSE CASE WHEN n % 3 = 0 THEN N'männlich' ELSE N'M' END END,
        CASE WHEN n IN (3, 8, 21) THEN '39130'
             ELSE CHOOSE(n % 5 + 1, '39104', '39108', '39112', '06108', '10115') END
FROM n
ORDER BY n;

/* 10 Rohfaelle */
;WITH n AS (SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects)
INSERT INTO [kis].[Fall_raw] ([FallNr], [PatNr], [Fallart], [Abteilung], [AufnahmeTS], [EntlassTS])
SELECT  'F2026' + RIGHT('00000' + CAST(40 + n AS VARCHAR(5)), 5),
        'P' + RIGHT('0000000' + CAST(100000 + 20 + n AS VARCHAR(7)), 7),
        CASE WHEN n % 3 = 0 THEN N'AMB' ELSE N'STAT' END,
        CHOOSE(n % 5 + 1, N'0100', N'0300', N'1000', N'1500', N'2800'),
        CONVERT(NVARCHAR(30), DATEADD(HOUR, n * 7, CAST('2026-10-10T07:30:00' AS DATETIME2(0))), 120),
        CASE WHEN n % 3 = 0 THEN CONVERT(NVARCHAR(30), DATEADD(HOUR, n * 7 + 2, CAST('2026-10-10T07:30:00' AS DATETIME2(0))), 120) END
FROM n
ORDER BY n;

/* 20 Laborbefunde (Rohformat mit Dezimalkomma) */
;WITH n AS (SELECT TOP (20) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects)
INSERT INTO [lis].[Befund_raw] ([FallNr], [Loinc], [WertText], [Einheit], [MessTS])
SELECT  'F2026' + RIGHT('00000' + CAST(40 + (n - 1) % 10 + 1 AS VARCHAR(5)), 5),
        CHOOSE(n % 5 + 1, N'2345-7', N'718-7', N'2160-0', N'1988-5', N'6690-2'),
        REPLACE(CAST(CAST(CHOOSE(n % 5 + 1, 95.0, 13.2, 0.9, 12.5, 7.8) + n * 0.1 AS DECIMAL(10,2)) AS NVARCHAR(20)), '.', ','),
        CHOOSE(n % 5 + 1, N'mg/dL', N'g/dL', N'mg/dL', N'mg/L', N'10*3/uL'),
        CONVERT(NVARCHAR(30), DATEADD(MINUTE, n * 45, CAST('2026-10-10T09:00:00' AS DATETIME2(0))), 120)
FROM n
ORDER BY n;
GO

EXEC [stage].[usp_PatientBereinigen];
GO

PRINT 'DIZ_NET_stage angelegt.';
GO
