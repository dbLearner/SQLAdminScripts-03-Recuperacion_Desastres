/*
Opciones de SET de ALTER DATABASE
https://msdn.microsoft.com/es-es/library/bb522682.aspx

tabla backupset 
https://technet.microsoft.com/es-es/library/ms186299(v=sql.110).aspx

tabla backupmediafamily 
https://msdn.microsoft.com/es-es/library/ms190284.aspx

tabla backupfile 
https://msdn.microsoft.com/es-es/library/ms190274.aspx

RESTORE DATABASE
https://msdn.microsoft.com/es-es/library/ms186858.aspx

sp_executesql 
https://msdn.microsoft.com/es-es/library/ms188001.aspx

Modelos de recuperación 
https://msdn.microsoft.com/es-es/library/ms189275.aspx

CHECKPOINT 
https://msdn.microsoft.com/es-es/library/ms188748.aspx

DBCC SHRINKFILE 
https://msdn.microsoft.com/es-es/library/ms189493.aspx

*/

--variables de proeso
DECLARE 
  @NombreBaseDatos varchar(255),	-->-- Base de datos que se desea restaurar
  @Sufijo varchar(20),              -->-- Sufije que se añade al nombre de la base de datos restaurada
  @Archivo varchar(250),			-->-- Para almacenar el nombre del último backup
  @Sentencia nvarchar(4000),		-->-- Para almacenar la sentecnia del backup
  @NumeroArchivos tinyint,			-->-- Para definir iteraciones del loop de archivos a restaurar
  @Contador tinyint=1,				-->-- Para controlar el loop de archivos a restaurar (Default = 1)
  @BackupSetId int,					-->-- Para almacenar el identificador del backup que queremos restaurar
  @DiasBackup tinyint=0;			-->-- Para definir los días de antiguedad del backup (Default = 0)

--Definimos el nombre de la base de datos a restaurar
SET @NombreBaseDatos = 'MiBaseDatos'
SET @Sufijo = 'CopiaDiaria'
  
USE Master;

--*************************************************************************
--PASO 1 - Verifica existencia de la base de datos a restaurar y la elimina
--*************************************************************************
IF EXISTS(SELECT * FROM sys.databases WHERE name = @NombreBaseDatos + @Sufijo)
  BEGIN 
    -- nos aseguramos que se cierren las conexiones existentes
    SET @Sentencia = 'ALTER DATABASE '+@NombreBaseDatos + @Sufijo+' SET SINGLE_USER WITH ROLLBACK IMMEDIATE' 
    EXEC sys.sp_executesql @Command1=@Sentencia
    --Eliminamos la base de datos existente
    SET @Sentencia = 'DROP DATABASE '+@NombreBaseDatos + @Sufijo 
    EXEC sys.sp_executesql @Command1=@Sentencia
  END

--*************************************************************************
--PASO 2 - Armamos dinámicamente la sentencia de restore
--         Se usa MOVE TO para cambiar de nombre los archivos
--*************************************************************************
-- Obtenemos el id del último backup ejecutado de la tabla msdb.dbo.backupset
SELECT @BackupSetId = backup_set_id
FROM msdb.dbo.backupset
WHERE CAST(backup_start_date AS DATE) = CAST(GETDATE()-@DiasBackup AS DATE)
AND Type = 'D';

--Obtenemos la ubicación y nombre físico del archivo de backup 
SELECT @Archivo = bm.physical_device_name
 FROM msdb.dbo.backupset bs
   INNER JOIN msdb.dbo.backupmediafamily bm
     ON bs.media_set_id=bm.media_set_id
WHERE backup_set_id = @BackupSetId

/* Armamos una sentencia dinámica con el nombre del backup obtenido   
   y con la opción MOVE TO para cambiar el nombre de los archivos*/
SET @Sentencia = 'RESTORE DATABASE ' + @NombreBaseDatos + @Sufijo ;
SET @Sentencia = @Sentencia + ' FROM DISK = '''+@Archivo+''' WITH';

--Obtenemos el numero total de archivos en el backup para el loop
SELECT @NumeroArchivos = MAX(file_number)
 FROM msdb.dbo.backupfile bf
WHERE backup_set_id = @BackupSetId

/*Loop para generar la línea de sentencia que cambia de nombre 
  a los archivos usando MOVE TO*/
WHILE @Contador<=@NumeroArchivos
  BEGIN
   SELECT @Sentencia=@Sentencia+' MOVE '''+logical_name+''' TO '''+LEFT(physical_name,LEN(physical_name)-4)+@Sufijo+RIGHT(physical_name,4)+'''' 
   FROM msdb.dbo.backupfile WHERE backup_set_id = @BackupSetId AND file_number = @Contador
   
   IF @Contador<@NumeroArchivos
     SELECT @Sentencia=@Sentencia+','
   SET @Contador+=1
  END

--OPCIONAL: Para pintar la sentencia dinámica para depuración
--print @Sentencia

--Ejecucuón de la sentencia mediante el procedimiento almacenado del sistema sp_executesql 
EXEC sys.sp_executesql @Command1=@Sentencia;

--*************************************************************************
--PASO 3 - Cambios en la configuración y mantenimiento del log
--*************************************************************************
/* En caso la BD original estuviera en modelo de recuperaicón FULL, la camibamos a SIMPLE
   Para simplificar la administración y reducir el tamaño del log. 
   Al ser una BD de prueba o desarrollo podemos mantener un log simple*/

--Cambiamos a modelo de recuperación simple
SET @Sentencia = 'ALTER DATABASE '+ @NombreBaseDatos + @Sufijo +' SET RECOVERY SIMPLE'
EXEC sys.sp_executesql @Command1=@Sentencia;

/*Debido a que vamos a usar USE, hay que ejecutar la soperaciones en un solo paso
  1.Movemos la conexión a la base de datos recién restaurada 
  2.Ejecutamos un checkpoint para sincronizar las páginas de datos
  3.Obtenemos el nombre lógico del archivo de log (Asumimos que la BD tiene solo un archivo de log)
*/
SET @Sentencia = 'USE '+ @NombreBaseDatos + @Sufijo + ';' + ASCII(10)
SET @Sentencia = @Sentencia + 'CHECKPOINT;'

SELECT @Archivo = logical_name
 FROM msdb.dbo.backupfile bf
WHERE backup_set_id = @BackupSetId
AND file_type='L'

--Armamos la sentencia con el nombre de archivo y reducimos el archivo de log
--Se esta reduciendo a 1024MB (1GB) el número se puede cambiar según se requiera
SET @Sentencia = @Sentencia + 'DBCC SHRINKFILE ('''+@Archivo+''', 1024)'
EXEC sys.sp_executesql @Command1=@Sentencia;
GO