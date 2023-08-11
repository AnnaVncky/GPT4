-- 1. Create ErrorLog Table if not exists
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'ErrorLog')
BEGIN
    CREATE TABLE ErrorLog (
        ErrorID INT IDENTITY(1,1) PRIMARY KEY,
        ErrorNumber INT,
        ErrorSeverity INT,
        ErrorMessage VARCHAR(255),
        CustomerID INT,
        Period VARCHAR(8),
        CreatedAt DATETIME DEFAULT GETDATE()
    )
END


-- 2. Stored Procedure Definition
ALTER PROCEDURE sp_CalculateRevenue 
    @FromYear INT = NULL, 
    @ToYear INT = NULL, 
    @Period VARCHAR(8) = 'Y', 
    @CustomerID INT = NULL
AS
BEGIN
    BEGIN TRY
        -- 3. Logic for Input Parameters
        IF @FromYear IS NULL 
            SET @FromYear = (SELECT MIN(YEAR([Invoice Date Key])) FROM [Fact].[Sale])
        
        IF @ToYear IS NULL 
            SET @ToYear = (SELECT MAX(YEAR([Invoice Date Key])) FROM [Fact].[Sale])
 
        
        -- 4. Table Name Creation Logic
		DECLARE @CustomerName NVARCHAR(100) = 
			CASE WHEN @CustomerID IS NOT NULL THEN 
				(SELECT TOP 1 [Customer] FROM Dimension.Customer WHERE [WWI Customer ID] = @CustomerID) 
			ELSE 
				''
			END
		SET @CustomerName = REPLACE(@CustomerName, '''', '')


		DECLARE @TableName NVARCHAR(255)

		SET @TableName = 
			CASE 
				WHEN @CustomerID IS NULL THEN 'All'
				ELSE CAST(@CustomerID AS NVARCHAR) + '_' + @CustomerName
			END + 
			'_' + 
			CAST(@FromYear AS NVARCHAR) +
			(CASE WHEN @FromYear <> @ToYear THEN '_' + CAST(@ToYear AS NVARCHAR) ELSE '' END) +
			'_' + 
			CASE 
				WHEN @Period IN ('Month', 'M') THEN 'M'
				WHEN @Period IN ('Quarter', 'Q') THEN 'Q'
				ELSE 'Y' 
			END

		-- To handle special characters and spaces in the customer name, which can be problematic in a table name:
		SET @TableName = REPLACE(REPLACE(@TableName, ' ', ''), '-', '')
        
        -- Drop and recreate table
        EXEC('DROP TABLE IF EXISTS ' + @TableName + ';
              CREATE TABLE ' + @TableName + ' (
                  CustomerID INT,
                  Period VARCHAR(8),
                  Revenue NUMERIC(19,2)
              );')
        
      
			-- 5. Revenue Calculation Logic
			DECLARE @sql NVARCHAR(MAX)
			SET @sql = 
				'INSERT INTO ' + @TableName + '
				 SELECT 
					 c.[WWI Customer ID],
					 CASE 
						 WHEN ''' + @Period + ''' IN (''Month'', ''M'') THEN FORMAT(s.[Invoice Date Key], ''MMM yyyy'')
						 WHEN ''' + @Period + ''' IN (''Quarter'', ''Q'') THEN ''Q'' + CAST(DATEPART(QUARTER, s.[Invoice Date Key]) AS VARCHAR) + '' '' + CAST(YEAR(s.[Invoice Date Key]) AS VARCHAR)
						 ELSE CAST(YEAR(s.[Invoice Date Key]) AS VARCHAR)
					 END AS Period,
					 COALESCE(SUM(s.Quantity * s.[Unit Price]), 0) AS Revenue
				 FROM Dimension.Customer c
				 LEFT JOIN [Fact].[Sale] s ON c.[WWI Customer ID] = s.[Customer Key]
					AND YEAR(s.[Invoice Date Key]) BETWEEN @FromYear AND @ToYear
				 WHERE (@CustomerID IS NULL OR c.[WWI Customer ID] = @CustomerID)
				 GROUP BY c.[WWI Customer ID], c.[Customer], CASE 
															  WHEN ''' + @Period + ''' IN (''Month'', ''M'') THEN FORMAT(s.[Invoice Date Key], ''MMM yyyy'')
															  WHEN ''' + @Period + ''' IN (''Quarter'', ''Q'') THEN ''Q'' + CAST(DATEPART(QUARTER, s.[Invoice Date Key]) AS VARCHAR) + '' '' + CAST(YEAR(s.[Invoice Date Key]) AS VARCHAR)
															  ELSE CAST(YEAR(s.[Invoice Date Key]) AS VARCHAR)
														  END'
			-- Execute the revenue calculation SQL:
			EXEC sp_executesql @sql, N'@FromYear INT, @ToYear INT, @CustomerID INT', @FromYear, @ToYear, @CustomerID

			-- 6. Inserting Data into Result Table (only zero-revenue logic, without duplication):
			DECLARE @sqlForZeroRevenue NVARCHAR(MAX) = N'
				IF NOT EXISTS (SELECT 1 FROM ' + @TableName + ' WHERE CustomerID = @CustomerID)
				BEGIN
					INSERT INTO ' + @TableName + ' (CustomerID, Period, Revenue)
					VALUES (@CustomerID, 
							CASE 
								WHEN @Period = ''M'' THEN FORMAT(GETDATE(), ''MMM yyyy'')
								WHEN @Period = ''Q'' THEN ''Q'' + CAST(DATEPART(QUARTER, GETDATE()) AS VARCHAR) + '' '' + CAST(YEAR(GETDATE()) AS VARCHAR)
								ELSE CAST(YEAR(GETDATE()) AS VARCHAR)
							END,
							0)
				END'
			-- Execute the zero-revenue SQL:
			EXEC sp_executesql @sqlForZeroRevenue, N'@CustomerID INT, @Period VARCHAR(8)', @CustomerID, @Period



    END TRY
    BEGIN CATCH
        -- 7. Error Handling
        INSERT INTO ErrorLog (ErrorNumber, ErrorSeverity, ErrorMessage, CustomerID, Period)
        VALUES (ERROR_NUMBER(), ERROR_SEVERITY(), ERROR_MESSAGE(), @CustomerID, @Period)
    END CATCH
END
