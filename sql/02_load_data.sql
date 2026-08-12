/* =====================================================================
   02_load_data.sql
   Loads the processed CSVs in data/processed into the lending schema's tables.

   Run this from inside the SQL Server container, where docker-compose.yml
   mounts ./data/processed to /var/opt/mssql/import (read-only). Load order
   follows the foreign-key dependency chain: reference/dimension tables
   first, then Members, then Loans last.

   BULK INSERT's FORMAT='CSV' option (SQL Server 2017+) is used so empty
   fields become NULL for nullable columns (e.g. CollateralValue on an
   unsecured loan) instead of being rejected or coerced to zero.

   The CSVs are written by Python with bare LF ('\n') line endings, not
   Windows-style CRLF -- BULK INSERT defaults to CRLF, so ROWTERMINATOR
   is set explicitly on every statement below. Skipping that on even one
   table would make it silently load everything as a single malformed row.
   ===================================================================== */

USE LoanPortfolioDB;
GO

TRUNCATE TABLE lending.Loans;
DELETE FROM lending.Members;
DELETE FROM lending.LoanOfficers;
DELETE FROM lending.Branches;
DELETE FROM lending.LoanTypes;
DELETE FROM lending.InstitutionParameters;
GO

BULK INSERT lending.Branches
FROM '/var/opt/mssql/import/branches.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, TABLOCK, ROWTERMINATOR = '0x0a');

BULK INSERT lending.LoanOfficers
FROM '/var/opt/mssql/import/loan_officers.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, TABLOCK, ROWTERMINATOR = '0x0a');

BULK INSERT lending.LoanTypes
FROM '/var/opt/mssql/import/loan_types.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, TABLOCK, ROWTERMINATOR = '0x0a');

BULK INSERT lending.InstitutionParameters
FROM '/var/opt/mssql/import/institution_parameters.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, TABLOCK, ROWTERMINATOR = '0x0a');

BULK INSERT lending.Members
FROM '/var/opt/mssql/import/members.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, TABLOCK, ROWTERMINATOR = '0x0a');

BULK INSERT lending.Loans
FROM '/var/opt/mssql/import/loans.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, TABLOCK, ROWTERMINATOR = '0x0a');
GO

PRINT 'Load complete. Row counts:';
SELECT 'Branches' AS TableName, COUNT(*) AS RowCnt FROM lending.Branches
UNION ALL SELECT 'LoanOfficers', COUNT(*) FROM lending.LoanOfficers
UNION ALL SELECT 'LoanTypes', COUNT(*) FROM lending.LoanTypes
UNION ALL SELECT 'InstitutionParameters', COUNT(*) FROM lending.InstitutionParameters
UNION ALL SELECT 'Members', COUNT(*) FROM lending.Members
UNION ALL SELECT 'Loans', COUNT(*) FROM lending.Loans;
GO
