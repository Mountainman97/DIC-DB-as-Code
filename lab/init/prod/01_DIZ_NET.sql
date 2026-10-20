/* =============================================================================
   DIZPROD – Datenbank DIZ_NET (integrierter Kerndatenbestand)
   Testschemata: ref (Kataloge), core (Patient/Fall/Diagnose/Labor), etl (Ladelaeufe)
   Alle Daten sind frei erfunden (pseudonymisierte Testdaten).
   ============================================================================= */
SET NOCOUNT ON;
GO
CREATE DATABASE [DIZ_NET] COLLATE Latin1_General_CI_AS;
GO
ALTER DATABASE [DIZ_NET] SET RECOVERY SIMPLE;
GO
USE [DIZ_NET];
GO

CREATE SCHEMA [ref]  AUTHORIZATION [dbo];
GO
CREATE SCHEMA [core] AUTHORIZATION [dbo];
GO
CREATE SCHEMA [etl]  AUTHORIZATION [dbo];
GO

/* ------------------------------------------------------------------ ref */
CREATE TABLE [ref].[Fachabteilung] (
    [FachabteilungCode] CHAR(4)        NOT NULL CONSTRAINT [PK_Fachabteilung] PRIMARY KEY,
    [Bezeichnung]       NVARCHAR(100)  NOT NULL
);
GO
CREATE TABLE [ref].[ICD10Katalog] (
    [ICD10Code]   VARCHAR(10)    NOT NULL CONSTRAINT [PK_ICD10Katalog] PRIMARY KEY,
    [Bezeichnung] NVARCHAR(255)  NOT NULL,
    [Kapitel]     VARCHAR(5)     NOT NULL
);
GO
CREATE TABLE [ref].[LoincCode] (
    [LoincCode]   VARCHAR(10)    NOT NULL CONSTRAINT [PK_LoincCode] PRIMARY KEY,
    [Bezeichnung] NVARCHAR(255)  NOT NULL,
    [Einheit]     NVARCHAR(20)   NOT NULL
);
GO

/* ------------------------------------------------------------------ core */
CREATE TABLE [core].[Patient] (
    [PatientId]   INT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_Patient] PRIMARY KEY,
    [Pseudonym]   CHAR(12)     NOT NULL CONSTRAINT [UQ_Patient_Pseudonym] UNIQUE,
    [Geburtsjahr] SMALLINT     NOT NULL CONSTRAINT [CK_Patient_Geburtsjahr] CHECK ([Geburtsjahr] BETWEEN 1900 AND 2100),
    [Geschlecht]  CHAR(1)      NOT NULL CONSTRAINT [CK_Patient_Geschlecht] CHECK ([Geschlecht] IN ('m', 'w', 'd', 'u')),
    [PLZ]         CHAR(5)      NULL,
    [AngelegtAm]  DATETIME2(0) NOT NULL CONSTRAINT [DF_Patient_AngelegtAm] DEFAULT (SYSDATETIME())
);
GO
CREATE TABLE [core].[Fall] (
    [FallId]            INT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_Fall] PRIMARY KEY,
    [PatientId]         INT          NOT NULL CONSTRAINT [FK_Fall_Patient] REFERENCES [core].[Patient] ([PatientId]),
    [Fallnummer]        VARCHAR(20)  NOT NULL CONSTRAINT [UQ_Fall_Fallnummer] UNIQUE,
    [Fallart]           VARCHAR(10)  NOT NULL CONSTRAINT [CK_Fall_Fallart] CHECK ([Fallart] IN ('stationaer', 'ambulant')),
    [FachabteilungCode] CHAR(4)      NOT NULL CONSTRAINT [FK_Fall_Fachabteilung] REFERENCES [ref].[Fachabteilung] ([FachabteilungCode]),
    [Aufnahme]          DATETIME2(0) NOT NULL,
    [Entlassung]        DATETIME2(0) NULL,
    CONSTRAINT [CK_Fall_Zeitraum] CHECK ([Entlassung] IS NULL OR [Entlassung] >= [Aufnahme])
);
GO
CREATE NONCLUSTERED INDEX [IX_Fall_PatientId] ON [core].[Fall] ([PatientId]);
GO
CREATE TABLE [core].[Diagnose] (
    [DiagnoseId]    INT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_Diagnose] PRIMARY KEY,
    [FallId]        INT          NOT NULL CONSTRAINT [FK_Diagnose_Fall]  REFERENCES [core].[Fall] ([FallId]),
    [ICD10Code]     VARCHAR(10)  NOT NULL CONSTRAINT [FK_Diagnose_ICD10] REFERENCES [ref].[ICD10Katalog] ([ICD10Code]),
    [Diagnoseart]   VARCHAR(10)  NOT NULL CONSTRAINT [CK_Diagnose_Art] CHECK ([Diagnoseart] IN ('Haupt', 'Neben')),
    [Diagnosedatum] DATE         NOT NULL
);
GO
CREATE NONCLUSTERED INDEX [IX_Diagnose_FallId] ON [core].[Diagnose] ([FallId]) INCLUDE ([ICD10Code], [Diagnoseart]);
GO
CREATE TABLE [core].[Laborwert] (
    [LaborwertId] BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_Laborwert] PRIMARY KEY,
    [FallId]      INT           NOT NULL CONSTRAINT [FK_Laborwert_Fall]  REFERENCES [core].[Fall] ([FallId]),
    [LoincCode]   VARCHAR(10)   NOT NULL CONSTRAINT [FK_Laborwert_Loinc] REFERENCES [ref].[LoincCode] ([LoincCode]),
    [Wert]        DECIMAL(10,2) NOT NULL,
    [Zeitpunkt]   DATETIME2(0)  NOT NULL
);
GO
CREATE NONCLUSTERED INDEX [IX_Laborwert_FallId_Loinc] ON [core].[Laborwert] ([FallId], [LoincCode]);
GO

/* ------------------------------------------------------------------ etl */
CREATE TABLE [etl].[Ladelauf] (
    [LadelaufId]   INT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_Ladelauf] PRIMARY KEY,
    [Quelle]       NVARCHAR(50)  NOT NULL,
    [Start]        DATETIME2(0)  NOT NULL CONSTRAINT [DF_Ladelauf_Start]  DEFAULT (SYSDATETIME()),
    [Ende]         DATETIME2(0)  NULL,
    [Status]       VARCHAR(10)   NOT NULL CONSTRAINT [DF_Ladelauf_Status] DEFAULT ('LAEUFT'),
    [AnzahlZeilen] INT           NULL
);
GO

/* ------------------------------------------------- Funktion / View / Prozeduren */
CREATE FUNCTION [core].[fn_AlterBeiAufnahme] (@Geburtsjahr SMALLINT, @Aufnahme DATETIME2(0))
RETURNS INT
AS
BEGIN
    RETURN YEAR(@Aufnahme) - @Geburtsjahr;
END;
GO
CREATE VIEW [core].[vFallUebersicht]
AS
SELECT  f.[FallId],
        f.[Fallnummer],
        p.[Pseudonym],
        p.[Geschlecht],
        [core].[fn_AlterBeiAufnahme](p.[Geburtsjahr], f.[Aufnahme]) AS [AlterBeiAufnahme],
        f.[Fallart],
        fa.[Bezeichnung]                                         AS [Fachabteilung],
        f.[Aufnahme],
        f.[Entlassung],
        DATEDIFF(DAY, f.[Aufnahme], f.[Entlassung])              AS [Verweildauer],
        hd.[ICD10Code]                                           AS [Hauptdiagnose],
        icd.[Bezeichnung]                                        AS [HauptdiagnoseText]
FROM        [core].[Fall]           f
INNER JOIN  [core].[Patient]        p   ON p.[PatientId] = f.[PatientId]
INNER JOIN  [ref].[Fachabteilung]   fa  ON fa.[FachabteilungCode] = f.[FachabteilungCode]
LEFT JOIN   [core].[Diagnose]       hd  ON hd.[FallId] = f.[FallId] AND hd.[Diagnoseart] = 'Haupt'
LEFT JOIN   [ref].[ICD10Katalog]    icd ON icd.[ICD10Code] = hd.[ICD10Code];
GO
CREATE PROCEDURE [etl].[usp_LadelaufStarten]
    @Quelle     NVARCHAR(50),
    @LadelaufId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO [etl].[Ladelauf] ([Quelle]) VALUES (@Quelle);
    SET @LadelaufId = CAST(SCOPE_IDENTITY() AS INT);
END;
GO
CREATE PROCEDURE [etl].[usp_LadelaufBeenden]
    @LadelaufId   INT,
    @Status       VARCHAR(10),
    @AnzahlZeilen INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE [etl].[Ladelauf]
       SET [Ende] = SYSDATETIME(), [Status] = @Status, [AnzahlZeilen] = @AnzahlZeilen
     WHERE [LadelaufId] = @LadelaufId;
END;
GO

/* ================================================================ Testdaten */
INSERT INTO [ref].[Fachabteilung] ([FachabteilungCode], [Bezeichnung]) VALUES
    ('0100', N'Innere Medizin'),
    ('0300', N'Kardiologie'),
    ('1000', N'Pädiatrie'),
    ('1500', N'Allgemeine Chirurgie'),
    ('2800', N'Neurologie');

INSERT INTO [ref].[ICD10Katalog] ([ICD10Code], [Bezeichnung], [Kapitel]) VALUES
    ('I10.90', N'Essentielle Hypertonie, nicht näher bezeichnet', 'IX'),
    ('E11.90', N'Diabetes mellitus, Typ 2, ohne Komplikationen', 'IV'),
    ('I21.9',  N'Akuter Myokardinfarkt, nicht näher bezeichnet', 'IX'),
    ('J18.9',  N'Pneumonie, nicht näher bezeichnet', 'X'),
    ('K35.8',  N'Akute Appendizitis, nicht näher bezeichnet', 'XI'),
    ('I63.9',  N'Hirninfarkt, nicht näher bezeichnet', 'IX'),
    ('N39.0',  N'Harnwegsinfektion, Lokalisation nicht näher bezeichnet', 'XIV'),
    ('J44.19', N'Chronische obstruktive Lungenkrankheit mit akuter Exazerbation', 'X'),
    ('E78.0',  N'Reine Hypercholesterinämie', 'IV'),
    ('S72.00', N'Schenkelhalsfraktur, Teil nicht näher bezeichnet', 'XIX');

INSERT INTO [ref].[LoincCode] ([LoincCode], [Bezeichnung], [Einheit]) VALUES
    ('2345-7', N'Glucose [Mass/volume] in Serum or Plasma', N'mg/dL'),
    ('718-7',  N'Hemoglobin [Mass/volume] in Blood', N'g/dL'),
    ('2160-0', N'Creatinine [Mass/volume] in Serum or Plasma', N'mg/dL'),
    ('1988-5', N'C reactive protein [Mass/volume] in Serum or Plasma', N'mg/L'),
    ('6690-2', N'Leukocytes [#/volume] in Blood', N'10*3/uL');

/* 25 Patienten (deterministisch erzeugt) */
;WITH n AS (SELECT TOP (25) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects)
INSERT INTO [core].[Patient] ([Pseudonym], [Geburtsjahr], [Geschlecht], [PLZ], [AngelegtAm])
SELECT  'PSN' + RIGHT('000000000' + CAST(n * 7919 AS VARCHAR(9)), 9),
        1935 + (n * 37) % 75,
        CASE WHEN n = 13 THEN 'd' WHEN n % 2 = 0 THEN 'w' ELSE 'm' END,
        CHOOSE(n % 5 + 1, '39104', '39108', '39112', '06108', '10115'),
        DATEADD(DAY, n, '2025-12-01T09:00:00')
FROM n
ORDER BY n;

/* 40 Faelle */
;WITH n AS (SELECT TOP (40) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects),
f AS (
    SELECT  n,
            DATEADD(HOUR, n * 53, CAST('2026-01-02T08:00:00' AS DATETIME2(0))) AS Aufnahme,
            CASE WHEN n % 4 = 0 THEN 'ambulant' ELSE 'stationaer' END          AS Fallart
    FROM n
)
INSERT INTO [core].[Fall] ([PatientId], [Fallnummer], [Fallart], [FachabteilungCode], [Aufnahme], [Entlassung])
SELECT  (n - 1) % 25 + 1,
        'F2026' + RIGHT('00000' + CAST(n AS VARCHAR(5)), 5),
        Fallart,
        CHOOSE(n % 5 + 1, '0100', '0300', '1000', '1500', '2800'),
        Aufnahme,
        CASE WHEN n >= 39               THEN NULL                               -- noch stationaer
             WHEN Fallart = 'ambulant'  THEN DATEADD(HOUR, 2, Aufnahme)
             ELSE DATEADD(DAY, 1 + (n * 3) % 12, Aufnahme) END
FROM f
ORDER BY n;

/* Haupt- und Nebendiagnosen */
INSERT INTO [core].[Diagnose] ([FallId], [ICD10Code], [Diagnoseart], [Diagnosedatum])
SELECT  f.[FallId],
        CHOOSE(f.[FallId] % 10 + 1, 'I10.90', 'E11.90', 'I21.9', 'J18.9', 'K35.8', 'I63.9', 'N39.0', 'J44.19', 'E78.0', 'S72.00'),
        'Haupt',
        CAST(f.[Aufnahme] AS DATE)
FROM [core].[Fall] f;

INSERT INTO [core].[Diagnose] ([FallId], [ICD10Code], [Diagnoseart], [Diagnosedatum])
SELECT  f.[FallId],
        CHOOSE(f.[FallId] % 3 + 1, 'I10.90', 'E11.90', 'E78.0'),
        'Neben',
        CAST(f.[Aufnahme] AS DATE)
FROM [core].[Fall] f
WHERE f.[FallId] % 2 = 0
  AND CHOOSE(f.[FallId] % 3 + 1, 'I10.90', 'E11.90', 'E78.0')
      <> CHOOSE(f.[FallId] % 10 + 1, 'I10.90', 'E11.90', 'I21.9', 'J18.9', 'K35.8', 'I63.9', 'N39.0', 'J44.19', 'E78.0', 'S72.00');

/* Laborwerte */
INSERT INTO [core].[Laborwert] ([FallId], [LoincCode], [Wert], [Zeitpunkt])
SELECT  f.[FallId],
        l.[LoincCode],
        CAST(l.Basis + ((f.[FallId] * 13 + l.Idx * 7) % 50) * l.Spreizung AS DECIMAL(10,2)),
        DATEADD(HOUR, 3 + l.Idx, f.[Aufnahme])
FROM [core].[Fall] f
CROSS JOIN (VALUES
        (1, '2345-7',  70.0, 2.0),
        (2, '718-7',   10.5, 0.1),
        (3, '2160-0',   0.6, 0.03),
        (4, '1988-5',   1.0, 3.0),
        (5, '6690-2',   4.0, 0.2)
    ) AS l (Idx, LoincCode, Basis, Spreizung)
WHERE (f.[FallId] + l.Idx) % 2 = 0 OR l.Idx = 1;

/* ETL-Protokoll */
INSERT INTO [etl].[Ladelauf] ([Quelle], [Start], [Ende], [Status], [AnzahlZeilen]) VALUES
    (N'KIS', '2026-10-14T02:00:00', '2026-10-14T02:07:12', 'OK',     1250),
    (N'LIS', '2026-10-14T02:10:00', '2026-10-14T02:31:40', 'OK',     8420),
    (N'KIS', '2026-10-15T02:00:00', '2026-10-15T02:01:03', 'FEHLER', NULL);
GO

PRINT 'DIZ_NET angelegt.';
GO
