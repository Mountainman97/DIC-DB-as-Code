/* =============================================================================
   data-export.sql – erzeugt fuer EINE Tabelle ein MERGE-Skript mit allen
   Datensaetzen (eine Zeile pro Datensatz, sortiert nach Primaerschluessel).

   Aufruf ueber lib/data.sh (sqlcmd-Variablen):
     $(DataSchema)   Schema
     $(DataTable)    Tabelle
     $(ExcludeCols)  kommagetrennte Spalten, die nicht versioniert werden
     $(MaxRows)      Abbruch, wenn die Tabelle mehr Zeilen hat
     $(DbLabel)      Datenbankname fuer den Kopfkommentar

   Ausgabe: genau EINE Ergebnismenge mit einer Spalte (eine Zeile je Skriptzeile).
   Voraussetzung: SQL Server 2017+ (STRING_AGG).

   Hinweis zu Platzhaltern in den dynamischen SQL-Vorlagen:
     ^    wird durch ein einfaches Hochkomma (') ersetzt
     {c}  wird durch den Spaltennamen in [Klammern] ersetzt
   ============================================================================= */
SET NOCOUNT ON;

DECLARE @s   sysname       = N'$(DataSchema)';
DECLARE @t   sysname       = N'$(DataTable)';
DECLARE @fqn nvarchar(300) = QUOTENAME(@s) + N'.' + QUOTENAME(@t);
DECLARE @obj int           = OBJECT_ID(@fqn, N'U');
DECLARE @nl  nchar(1)      = NCHAR(10);
DECLARE @msg nvarchar(2048);

IF @obj IS NULL
BEGIN
    SET @msg = N'Tabelle ' + @fqn + N' nicht gefunden.';
    THROW 50001, @msg, 1;
END;

DECLARE @pk int = (SELECT index_id FROM sys.indexes WHERE object_id = @obj AND is_primary_key = 1);
IF @pk IS NULL
BEGIN
    SET @msg = N'Tabelle ' + @fqn + N' hat keinen Primaerschluessel und kann nicht versioniert werden.';
    THROW 50002, @msg, 1;
END;

/* ------------------------------------------------------------------ Spalten */
DECLARE @excl TABLE (name sysname PRIMARY KEY);
INSERT INTO @excl (name)
SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(N'$(ExcludeCols)', N',') WHERE LTRIM(RTRIM(value)) <> N'';

CREATE TABLE #c (
    ord      int            NOT NULL,
    name     sysname        NOT NULL,
    typ      sysname        NOT NULL,
    typedef  nvarchar(200)  NOT NULL,
    is_pk    bit            NOT NULL,
    pk_ord   int            NULL,
    is_ident bit            NOT NULL,
    expr     nvarchar(max)  NULL,   -- Ausdruck, der den Wert als SQL-Literal liefert
    cmp_s    nvarchar(400)  NULL,   -- Vergleichsausdruck Quelle
    cmp_t    nvarchar(400)  NULL    -- Vergleichsausdruck Ziel
);

INSERT INTO #c (ord, name, typ, typedef, is_pk, pk_ord, is_ident)
SELECT  c.column_id,
        c.name,
        tn.typ,
        CASE
            WHEN tn.typ IN (N'varchar', N'char', N'varbinary', N'binary')
                THEN tn.typ + N'(' + CASE WHEN c.max_length = -1 THEN N'max' ELSE CAST(c.max_length AS nvarchar(10)) END + N')'
            WHEN tn.typ IN (N'nvarchar', N'nchar')
                THEN tn.typ + N'(' + CASE WHEN c.max_length = -1 THEN N'max' ELSE CAST(c.max_length / 2 AS nvarchar(10)) END + N')'
            WHEN tn.typ IN (N'decimal', N'numeric')
                THEN tn.typ + N'(' + CAST(c.precision AS nvarchar(10)) + N',' + CAST(c.scale AS nvarchar(10)) + N')'
            WHEN tn.typ IN (N'datetime2', N'time', N'datetimeoffset')
                THEN tn.typ + N'(' + CAST(c.scale AS nvarchar(10)) + N')'
            WHEN tn.typ = N'text'  THEN N'varchar(max)'
            WHEN tn.typ = N'ntext' THEN N'nvarchar(max)'
            WHEN tn.typ = N'image' THEN N'varbinary(max)'
            ELSE tn.typ
        END,
        CASE WHEN ic.key_ordinal IS NULL THEN 0 ELSE 1 END,
        ic.key_ordinal,
        c.is_identity
FROM sys.columns c
CROSS APPLY (SELECT TYPE_NAME(c.system_type_id) AS typ) tn
LEFT JOIN sys.index_columns ic
       ON ic.object_id = c.object_id AND ic.index_id = @pk AND ic.column_id = c.column_id
WHERE c.object_id = @obj
  AND c.is_computed = 0
  AND tn.typ NOT IN (N'timestamp')
  AND (ic.key_ordinal IS NOT NULL OR c.name NOT IN (SELECT name FROM @excl));

DECLARE @bad nvarchar(1000) = (
    SELECT STRING_AGG(CAST(name + N' (' + typ + N')' AS nvarchar(max)), N', ')
    FROM #c
    WHERE typ NOT IN (N'bigint', N'int', N'smallint', N'tinyint', N'bit', N'decimal', N'numeric',
                      N'money', N'smallmoney', N'float', N'real',
                      N'date', N'datetime', N'datetime2', N'smalldatetime', N'datetimeoffset', N'time',
                      N'char', N'varchar', N'nchar', N'nvarchar', N'text', N'ntext', N'xml',
                      N'uniqueidentifier', N'binary', N'varbinary', N'image'));
IF @bad IS NOT NULL
BEGIN
    SET @msg = N'Nicht unterstuetzte Datentypen in ' + @fqn + N': ' + @bad
             + N'. Spalten ggf. per exclude-column ausnehmen.';
    THROW 50003, @msg, 1;
END;

/* Literal-Ausdruecke je Datentyp (Vorlagen mit ^ = ' und {c} = [Spalte]) */
UPDATE #c SET expr = REPLACE(REPLACE(
    N'CASE WHEN {c} IS NULL THEN N^NULL^ ELSE ' +
    CASE
        WHEN typ IN (N'bigint', N'int', N'smallint', N'tinyint', N'bit', N'decimal', N'numeric')
            THEN N'CONVERT(nvarchar(60), {c})'
        WHEN typ IN (N'money', N'smallmoney')
            THEN N'CONVERT(nvarchar(60), {c}, 2)'
        WHEN typ IN (N'float', N'real')
            THEN N'CONVERT(nvarchar(60), {c}, 3)'
        WHEN typ = N'date'
            THEN N'N^N^^^ + CONVERT(nvarchar(30), {c}, 23) + N^^^^'
        WHEN typ IN (N'datetime', N'smalldatetime')
            THEN N'N^N^^^ + CONVERT(nvarchar(30), {c}, 126) + N^^^^'
        WHEN typ IN (N'datetime2', N'datetimeoffset', N'time', N'uniqueidentifier')
            THEN N'N^N^^^ + CONVERT(nvarchar(60), {c}) + N^^^^'
        WHEN typ IN (N'binary', N'varbinary', N'image')
            THEN N'CONVERT(nvarchar(max), CONVERT(varbinary(max), {c}), 1)'
        ELSE /* Zeichenketten, xml: Hochkommas verdoppeln, Zeilenumbrueche als NCHAR() */
            N'N^N^^^ + REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), {c}), N^^^^, N^^^^^^), '
          + N'NCHAR(13), N^^^ + NCHAR(13) + N^^^), NCHAR(10), N^^^ + NCHAR(10) + N^^^) + N^^^^'
    END + N' END',
    N'^', NCHAR(39)), N'{c}', QUOTENAME(name));

/* Vergleichsausdruecke (text/ntext/image/xml sind nicht direkt vergleichbar) */
UPDATE #c SET
    cmp_s = CASE typ WHEN N'xml' THEN N'CAST(s.' + QUOTENAME(name) + N' AS nvarchar(max))'
                     ELSE N's.' + QUOTENAME(name) END,
    cmp_t = CASE typ WHEN N'xml'   THEN N'CAST(t.' + QUOTENAME(name) + N' AS nvarchar(max))'
                     WHEN N'text'  THEN N'CAST(t.' + QUOTENAME(name) + N' AS varchar(max))'
                     WHEN N'ntext' THEN N'CAST(t.' + QUOTENAME(name) + N' AS nvarchar(max))'
                     WHEN N'image' THEN N'CAST(t.' + QUOTENAME(name) + N' AS varbinary(max))'
                     ELSE N't.' + QUOTENAME(name) END;

/* ------------------------------------------------------------------ Bausteine */
/* STRING_AGG erwartet als Trennzeichen ein Literal oder eine Variable */
DECLARE @sep_cast nvarchar(10) = N',' + NCHAR(10);
DECLARE @sep_set  nvarchar(20) = N',' + NCHAR(10) + N'        ';
DECLARE @collist  nvarchar(max) = (SELECT STRING_AGG(CAST(QUOTENAME(name) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY ord) FROM #c);
DECLARE @casts    nvarchar(max) = (SELECT STRING_AGG(CAST(N'        CAST(v.' + QUOTENAME(name) + N' AS ' + typedef + N') AS ' + QUOTENAME(name) AS nvarchar(max)), @sep_cast) WITHIN GROUP (ORDER BY ord) FROM #c);
DECLARE @on       nvarchar(max) = (SELECT STRING_AGG(CAST(N't.' + QUOTENAME(name) + N' = s.' + QUOTENAME(name) AS nvarchar(max)), N' AND ') WITHIN GROUP (ORDER BY pk_ord) FROM #c WHERE is_pk = 1);
DECLARE @pkasc    nvarchar(max) = (SELECT STRING_AGG(CAST(QUOTENAME(name) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY pk_ord) FROM #c WHERE is_pk = 1);
DECLARE @pkdesc   nvarchar(max) = (SELECT STRING_AGG(CAST(QUOTENAME(name) + N' DESC' AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY pk_ord) FROM #c WHERE is_pk = 1);
DECLARE @set      nvarchar(max) = (SELECT STRING_AGG(CAST(N't.' + QUOTENAME(name) + N' = s.' + QUOTENAME(name) AS nvarchar(max)), @sep_set) WITHIN GROUP (ORDER BY ord) FROM #c WHERE is_pk = 0 AND is_ident = 0);
DECLARE @cmps     nvarchar(max) = (SELECT STRING_AGG(CAST(cmp_s AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY ord) FROM #c WHERE is_pk = 0 AND is_ident = 0);
DECLARE @cmpt     nvarchar(max) = (SELECT STRING_AGG(CAST(cmp_t AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY ord) FROM #c WHERE is_pk = 0 AND is_ident = 0);
DECLARE @inscols  nvarchar(max) = @collist;
DECLARE @insvals  nvarchar(max) = (SELECT STRING_AGG(CAST(N's.' + QUOTENAME(name) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY ord) FROM #c);
DECLARE @nulls    nvarchar(max) = (SELECT STRING_AGG(CAST(N'NULL' AS nvarchar(max)), N', ') FROM #c);
DECLARE @rowexpr  nvarchar(max) = (SELECT STRING_AGG(expr, N' + N'', '' + ') WITHIN GROUP (ORDER BY ord) FROM #c);
DECLARE @hasident bit           = CASE WHEN EXISTS (SELECT 1 FROM #c WHERE is_ident = 1) THEN 1 ELSE 0 END;

/* Zeilenzahl pruefen */
DECLARE @rows bigint, @sql nvarchar(max);
SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + @fqn + N';';
EXEC sp_executesql @sql, N'@n bigint OUTPUT', @n = @rows OUTPUT;
IF @rows > $(MaxRows)
BEGIN
    SET @msg = N'Tabelle ' + @fqn + N' hat ' + CAST(@rows AS nvarchar(20)) + N' Zeilen (Limit $(MaxRows)). '
             + N'Datenversionierung ist fuer Konfigurations-/Stammdaten gedacht.';
    THROW 50004, @msg, 1;
END;

/* ------------------------------------------------------------------ Ausgabe */
CREATE TABLE #out (n int IDENTITY(1,1) PRIMARY KEY, line nvarchar(max) NOT NULL);

INSERT INTO #out (line) VALUES
 (N'-- ============================================================================'),
 (N'-- Datenversionierung: ' + @fqn + N'   (Datenbank: $(DbLabel))'),
 (N'-- Tabelle: ' + @fqn),
 (N'-- Schluessel: ' + @pkasc),
 (N'-- Erzeugt mit db-data-init.sh / db-data-refresh.sh. Eine Zeile pro Datensatz.'),
 (N'-- Zeilen duerfen geaendert, ergaenzt oder entfernt werden. db-data-apply.sh bringt'),
 (N'-- die Tabelle exakt auf diesen Stand (INSERT / UPDATE / DELETE per MERGE).'),
 (N'-- ============================================================================'),
 (N'SET NOCOUNT ON;'),
 (N'SET XACT_ABORT ON;'),
 (N'BEGIN TRANSACTION;'),
 (N'DECLARE @aenderungen TABLE (Aktion NVARCHAR(10));');
IF @hasident = 1
    INSERT INTO #out (line) VALUES (N'SET IDENTITY_INSERT ' + @fqn + N' ON;');
INSERT INTO #out (line) VALUES
 (N'MERGE INTO ' + @fqn + N' AS t'),
 (N'USING ('),
 (N'    SELECT'),
 (@casts),
 (N'    FROM (VALUES');

IF @rows = 0
BEGIN
    INSERT INTO #out (line) VALUES
     (N'    -- Tabelle ist leer. Zum Befuellen die NULL-Zeile ersetzen und "WHERE 1 = 0" entfernen.'),
     (N'    (' + @nulls + N')'),
     (N'    ) AS v (' + @collist + N')'),
     (N'    WHERE 1 = 0');
END
ELSE
BEGIN
    SET @sql = N'INSERT INTO #out (line) SELECT N''    ('' + ' + @rowexpr + N' + N'')'''
             + N' + CASE WHEN ROW_NUMBER() OVER (ORDER BY ' + @pkdesc + N') = 1 THEN N'''' ELSE N'','' END'
             + N' FROM ' + @fqn + N' ORDER BY ' + @pkasc + N';';
    EXEC sp_executesql @sql;
    INSERT INTO #out (line) VALUES (N'    ) AS v (' + @collist + N')');
END;

INSERT INTO #out (line) VALUES
 (N') AS s'),
 (N'ON ' + @on);
IF @set IS NOT NULL
    INSERT INTO #out (line) VALUES
     (N'WHEN MATCHED AND EXISTS (SELECT ' + @cmps + N' EXCEPT SELECT ' + @cmpt + N') THEN'),
     (N'    UPDATE SET ' + @set);
INSERT INTO #out (line) VALUES
 (N'WHEN NOT MATCHED BY TARGET THEN'),
 (N'    INSERT (' + @inscols + N') VALUES (' + @insvals + N')'),
 (N'WHEN NOT MATCHED BY SOURCE THEN DELETE   -- @@DELETE@@'),
 (N'OUTPUT $action INTO @aenderungen;');
IF @hasident = 1
    INSERT INTO #out (line) VALUES (N'SET IDENTITY_INSERT ' + @fqn + N' OFF;');
INSERT INTO #out (line) VALUES
 (N'COMMIT TRANSACTION;'),
 (N'DECLARE @ins INT = (SELECT COUNT(*) FROM @aenderungen WHERE Aktion = N''INSERT''),'),
 (N'        @upd INT = (SELECT COUNT(*) FROM @aenderungen WHERE Aktion = N''UPDATE''),'),
 (N'        @del INT = (SELECT COUNT(*) FROM @aenderungen WHERE Aktion = N''DELETE'');'),
 (N'PRINT N''' + REPLACE(@fqn, N'''', N'''''') + N': '' + CAST(@ins AS NVARCHAR(10)) + N'' eingefuegt, '' + CAST(@upd AS NVARCHAR(10)) + N'' geaendert, '' + CAST(@del AS NVARCHAR(10)) + N'' geloescht'';'),
 (N'GO');

SELECT line AS dv_line FROM #out ORDER BY n;
