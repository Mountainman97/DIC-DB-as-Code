/* =============================================================================
   DIZPROD – DIZ_NET: Schemata conf (Konfiguration) und pc (Prozesssteuerung)
   Testtabellen fuer die Datenversionierung (db-data-*.sh).
   Bewusst enthalten: IDENTITY-Spalte, zusammengesetzte Schluessel, GUID,
   float/decimal/date/datetime2, mehrzeiliger Text, Hochkommas, '$(' im Text
   und Fremdschluessel zwischen den Tabellen.
   Idempotent: kann auch auf einer bereits initialisierten Instanz laufen.
   ============================================================================= */
SET NOCOUNT ON;
GO
USE [DIZ_NET];
GO
IF SCHEMA_ID(N'conf') IS NULL EXEC (N'CREATE SCHEMA [conf] AUTHORIZATION [dbo]');
GO
IF SCHEMA_ID(N'pc') IS NULL EXEC (N'CREATE SCHEMA [pc] AUTHORIZATION [dbo]');
GO

/* ------------------------------------------------------------------ conf */
IF OBJECT_ID(N'[conf].[Parameter]', N'U') IS NULL
CREATE TABLE [conf].[Parameter] (
    [ParameterId]  INT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_Parameter] PRIMARY KEY,
    [Schluessel]   VARCHAR(100)   NOT NULL CONSTRAINT [UQ_Parameter_Schluessel] UNIQUE,
    [Wert]         NVARCHAR(400)  NULL,
    [Beschreibung] NVARCHAR(400)  NULL,
    [GueltigAb]    DATE           NOT NULL CONSTRAINT [DF_Parameter_GueltigAb] DEFAULT ('2026-01-01'),
    [GeaendertAm]  DATETIME2(0)   NOT NULL CONSTRAINT [DF_Parameter_GeaendertAm] DEFAULT (SYSDATETIME())
);
GO
IF OBJECT_ID(N'[conf].[Quellsystem]', N'U') IS NULL
CREATE TABLE [conf].[Quellsystem] (
    [QuellsystemCode] VARCHAR(20)   NOT NULL CONSTRAINT [PK_Quellsystem] PRIMARY KEY,
    [Bezeichnung]     NVARCHAR(100) NOT NULL,
    [Aktiv]           BIT           NOT NULL CONSTRAINT [DF_Quellsystem_Aktiv] DEFAULT (1),
    [Prioritaet]      TINYINT       NOT NULL
);
GO
IF OBJECT_ID(N'[conf].[QuellsystemTabelle]', N'U') IS NULL
CREATE TABLE [conf].[QuellsystemTabelle] (
    [QuellsystemCode]   VARCHAR(20) NOT NULL CONSTRAINT [FK_QuellsystemTabelle_Quellsystem] REFERENCES [conf].[Quellsystem] ([QuellsystemCode]),
    [Tabellenname]      SYSNAME     NOT NULL,
    [LadeintervallMin]  INT         NOT NULL,
    CONSTRAINT [PK_QuellsystemTabelle] PRIMARY KEY ([QuellsystemCode], [Tabellenname])
);
GO

/* ------------------------------------------------------------------ pc */
IF OBJECT_ID(N'[pc].[Job]', N'U') IS NULL
CREATE TABLE [pc].[Job] (
    [JobId]      INT           NOT NULL CONSTRAINT [PK_Job] PRIMARY KEY,
    [Name]       NVARCHAR(100) NOT NULL,
    [Cron]       VARCHAR(50)   NOT NULL,
    [Aktiv]      BIT           NOT NULL,
    [TimeoutSek] INT           NULL
);
GO
IF OBJECT_ID(N'[pc].[JobSchritt]', N'U') IS NULL
CREATE TABLE [pc].[JobSchritt] (
    [JobId]     INT           NOT NULL CONSTRAINT [FK_JobSchritt_Job] REFERENCES [pc].[Job] ([JobId]),
    [Schritt]   INT           NOT NULL,
    [Prozedur]  SYSNAME       NOT NULL,
    [Parameter] NVARCHAR(MAX) NULL,
    CONSTRAINT [PK_JobSchritt] PRIMARY KEY ([JobId], [Schritt])
);
GO
IF OBJECT_ID(N'[pc].[Mapping]', N'U') IS NULL
CREATE TABLE [pc].[Mapping] (
    [MappingId] UNIQUEIDENTIFIER NOT NULL CONSTRAINT [PK_Mapping] PRIMARY KEY,
    [Quelle]    NVARCHAR(50)     NOT NULL,
    [Zielwert]  DECIMAL(9,3)     NOT NULL,
    [Faktor]    FLOAT            NOT NULL,
    [Kommentar] NVARCHAR(200)    NULL
);
GO

/* ================================================================ Testdaten */
IF NOT EXISTS (SELECT 1 FROM [conf].[Parameter])
INSERT INTO [conf].[Parameter] ([Schluessel], [Wert], [Beschreibung], [GueltigAb]) VALUES
    ('etl.batchgroesse',      N'5000',             N'Zeilen je Batch beim Laden', '2026-01-01'),
    ('etl.timeout_sek',       N'3600',             N'Maximale Laufzeit eines Ladelaufs', '2026-01-01'),
    ('export.pfad',           N'/mnt/export/diz',  N'Zielverzeichnis für Exporte', '2026-03-15'),
    ('mail.empfaenger',       N'diz-team@example.local', NULL, '2026-01-01'),
    ('pseudonym.praefix',     N'PSN',              N'Präfix der Pseudonyme – nicht ändern!', '2025-07-01'),
    ('kommentar.beispiel',    N'Text mit ''Hochkomma'' und $(keine_variable)', N'Testet Sonderzeichen', '2026-01-01');
GO
IF NOT EXISTS (SELECT 1 FROM [conf].[Quellsystem])
INSERT INTO [conf].[Quellsystem] ([QuellsystemCode], [Bezeichnung], [Aktiv], [Prioritaet]) VALUES
    ('KIS', N'Krankenhausinformationssystem', 1, 1),
    ('LIS', N'Laborinformationssystem', 1, 2),
    ('PDMS', N'Patientendatenmanagement Intensiv', 0, 3);
GO
IF NOT EXISTS (SELECT 1 FROM [conf].[QuellsystemTabelle])
INSERT INTO [conf].[QuellsystemTabelle] ([QuellsystemCode], [Tabellenname], [LadeintervallMin]) VALUES
    ('KIS', N'Patient_raw', 60),
    ('KIS', N'Fall_raw', 60),
    ('LIS', N'Befund_raw', 15);
GO
IF NOT EXISTS (SELECT 1 FROM [pc].[Job])
INSERT INTO [pc].[Job] ([JobId], [Name], [Cron], [Aktiv], [TimeoutSek]) VALUES
    (10, N'KIS-Import nachts', '0 2 * * *', 1, 3600),
    (20, N'LIS-Import', '*/15 * * * *', 1, 600),
    (30, N'Pseudonymisierung', '30 3 * * *', 0, NULL);
GO
IF NOT EXISTS (SELECT 1 FROM [pc].[JobSchritt])
INSERT INTO [pc].[JobSchritt] ([JobId], [Schritt], [Prozedur], [Parameter]) VALUES
    (10, 1, N'stage.usp_PatientBereinigen', NULL),
    (10, 2, N'stage.usp_PatientUebernehmen', N'{' + NCHAR(10) + N'  "modus": "voll",' + NCHAR(10) + N'  "hinweis": "mehrzeilig"' + NCHAR(10) + N'}'),
    (20, 1, N'etl.usp_LadelaufStarten', N'{"quelle": "LIS"}');
GO
IF NOT EXISTS (SELECT 1 FROM [pc].[Mapping])
INSERT INTO [pc].[Mapping] ([MappingId], [Quelle], [Zielwert], [Faktor], [Kommentar]) VALUES
    ('6F9619FF-8B86-D011-B42D-00C04FC964FF', N'mg/dL',   1.000, 1.0,          NULL),
    ('7A1B2C3D-0000-4000-8000-000000000001', N'mmol/L', 18.016, 0.0555084350, N'Glucose-Umrechnung'),
    ('7A1B2C3D-0000-4000-8000-000000000002', N'µmol/L', 88.400, 0.0113122172, N'Kreatinin – O''Brien-Formel');
GO
PRINT 'DIZ_NET: Schemata conf und pc angelegt.';
GO
