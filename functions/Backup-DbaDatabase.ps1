﻿Function Backup-DbaDatabase
{
<#
.SYNOPSIS
Backup one or more SQL Sever databases from a SQL Server SqlInstance

.DESCRIPTION
Performs a backup of a specified type of 1 or more databases on a SQL Server Instance.
These backups may be Full, Differential or Transaction log backups

.PARAMETER DatabaseName
Names of the databases to be backed up. May be either a list of comma seperated names, or if can be piped in from
Get-DbaDatabases

.PARAMETER SqlInstance
The SQL Server instance hosting the databases to be backed up

.PARAMETER SqlCredential
Credentials to connect to the SQL Server instance if the calling user doesn't have permission

.PARAMETER BackupFileName
name of the file to backup to. This is only accepted for single database backups
If no name is specified then the backup files will be named DatabaseName_yyyyMMddHHmm (ie; Database1_201714022131)
with the appropriate extension.

.PARAMETER BackupPath
Path to place the backup files. If not specified the backups will be placed in the default backup location for SQLInstance
If multuple paths specified, the backups will be stiped across these locations. This will overwrite the FileCount option

.PARAMETER NoCopyOnly
By default function performa

.PARAMETER BackupType
The type of SQL Server backup to perform.
Accepted values are Full, Log, Differential, Diff, Database

.PARAMETER FileCount
Number of files to stripe each backup across if a single BackupPath is provided.

.PARAMETER CreateFolder
Switch to indicate that a folder should be created under each folder for each database if it doesn't already existing

.EXAMPLE 
Backup-DbaDatabase -SqlInstance Server1 -Databases HR, Finance -BackupType Full

This will perform a full database backup on the databases HR and Finance on SQL Server Instance Server1 to Server1's 
default backup directory

.EXAMPLE

#>
	[CmdletBinding()]
	param (
		[parameter(ValueFromPipeline = $True)]
		[object[]]$DatabaseName, # Gotten from Get-DbaDatabase
		[object]$SqlInstance,
		[System.Management.Automation.PSCredential]$SqlCredential,
		[string[]]$BackupPath,
		[string]$BackupFileName,
		[switch]$NoCopyOnly,
		[ValidateSet('Full', 'Log', 'Differential','Diff','Database')] # Unsure of the names
		[string]$BackupType = "Full",
		[int]$FileCount = 1,
		[switch]$CreateFolder=$true

	)
	BEGIN
	{
		$FunctionName = $FunctionName =(Get-PSCallstack)[0].Command
		$Databases = @()
	}
	PROCESS
	{
	
		if ($BackupPath.count -gt 1)
		{
			$Filecount = $BackupPath.count
		}
		foreach ($Name in $DatabaseName)
		{
			if ($Name -is [String])
			{
				$Databases += [PSCustomObject]@{Name = $Name; RecoveryModel=$null}
			}
			elseif ($Name -is [System.Object] -and $Name.Name.Length -ne 0 )
			{
				$Databases += [PSCustomObject]@{Name = 'name'; RecoveryModel= $RecoveryModel}
			}
		}
	}
	END
	{
		try 
		{
			$Server = Connect-SqlServer -SqlServer $SqlInstance -SqlCredential $SqlCredential	          
		}
		catch {
            $server.ConnectionContext.Disconnect()
			Write-Warning "$FunctionName - Cannot connect to $SqlInstance" -WarningAction Stop
		}

		if ($databases.count -gt 1 -and $BackupFileName -ne '')
		{
			Write-warning "$FunctionName - 1 BackupFile specified, but more than 1 database."
			break
		}

		
		try
		{
			$tmp = @($Databases.Name) 
			$BackupHistory = Get-DbaBackupHistory -SqlServer $SqlInstance -databases $Databases.Name  -LastFull -ErrorAction SilentlyContinue
			write-Verbose ($Databases.Name -join ',')
		}
		Catch
		{
			$_.exception
		}
		Write-Verbose "$FunctionName - $($Databases.count) database to backup"
		ForEach ($Database in $Databases)
		{
			$FailReasons = @()
			Write-Verbose "$FunctionName - Backup up database $($Database.name)"
			if ($Database.RecoveryModel -eq $null)
			{
				$Database.RecoveryModel = $server.databases[$Database.Name].RecoveryModel
				Write-Verbose "$($DataBase.Name) is in $($Database.RecoveryModel) recovery model"
			}
			
			if ($Database.RecoveryModel -eq 'Simple' -and $BackupType -eq 'Log')
			{
				$FailReason = "$($Database.Name) is in simple recovery mode, cannot take log backup"
				$FailReasons += $FailReason
				Write-Warning "$FunctionName - $FailReason"

			}
			$FullExists = $BackupHistory | Where-Object {$_.Database -eq $Database.Name}
			if ($BackupType -ne "Full" -and $FullExists.length -eq 0)
			{
				$FailReason = "$($Database.Name) does not have an existing full backup, cannot take log or differentialbackup"
				$FailReasons += $FailReason
				Write-Warning "$FunctionName - $FailReason"	
			}

			$val = 0
			$copyonly = !$NoCopyOnly
			
			$server.ConnectionContext.StatementTimeout = 0
			$backup = New-Object Microsoft.SqlServer.Management.Smo.Backup
			$backup.Database = $Database.Name
			$Type = "Database"
			$Suffix = "bak"
			if ($BackupType -eq "Log")
			{
					$Type = "Log" 
					$Suffix = "trn"
			}
			$backup.Action = $Type
			$backup.CopyOnly = $copyonly
			if ($BackupType -in ('diff','differential'))
			{
				$backup.Incremental = $true
			}
			Write-Verbose "$FunctionName - Sorting Paths"
			#If a backupfilename has made it this far, use it
			$FinalBackupPath = @()
			if ($BackupFileName -ne '')
			{
				Write-Verbose "$FunctionName - Single db and filename"
				if (Test-SqlPath -SqlServer $SqlInstance -Path (Split-Path $BackupFileName))
				{
					$FinalBackupPath += $BackupFileName
				}else{
					$FailReason = "Sql Server cannot write to the location $(Split-Path $BackupFileName)"
					$FailReasons += $FailReason
					Write-Warning "$FunctionName - $FailReason"	
				}
			}
			else
			{
				$TimeStamp = (Get-date -Format yyyyMMddHHmm)
				Foreach ($path in $BackupPath)
				{
					if ($CreateFolder){
						$Path = $path+"\"+$Database.name
					}
					if( (New-DbaSqlDirectory -SqlServer:$SqlInstance -SqlCredential:$SqlCredential -Path $path) -eq $false)
					{
							$FailReason = "Cannot create or write to folder $path"
							$FailReasons += $FailReason
							Write-Warning "$FunctionName - $FailReason"	
					}
					else
					{
						$FinaLBackupPath += "$path\$(($Database.name).trim())_$Timestamp.$suffix"
					}
				}
			}
			Write-Verbose "before reasons"
			if ($FailReasons.count -eq 0)
			{
				$val = 1
				if ($FinalBackupPath.count -gt 1)
				{
					$filecount = $FinalBackupPath.count
					foreach ($backupfile in $FinalBackupPath)
					{
						$device = New-Object Microsoft.SqlServer.Management.Smo.BackupDeviceItem
						$device.DeviceType = "File"
						$device.Name = $backupfile.Replace(".$suffix", "-$val-of-$filecount.$suffix")
						$backup.Devices.Add($device)
						$val++
					}
				}
				else
				{
					while ($val -lt ($filecount+1))
					{
						$device = New-Object Microsoft.SqlServer.Management.Smo.BackupDeviceItem
						$device.DeviceType = "File"
						if ($filecount -gt  1)
						{
							Write-Verbose "$FunctionName - adding stripes"
							$tFinalBackupPath = $FinalBackupPath.Replace(".$suffix", "-$val-of-$filecount.$suffix")
						}
						$device.Name = $tFinalBackupPath
						Write-Verbose $tFinalBackupPath
						$backup.Devices.Add($device)
						$val++
					}
				}
				Write-Verbose "$FunctionName - Devices added"
				$percent = [Microsoft.SqlServer.Management.Smo.PercentCompleteEventHandler] {
					Write-Progress -id 1 -activity "Backing up database $($Database.Name)  to $backupfile" -percentcomplete $_.Percent -status ([System.String]::Format("Progress: {0} %", $_.Percent))
				}
				$backup.add_PercentComplete($percent)
				$backup.PercentCompleteNotification = 1
				$backup.add_Complete($complete)
				
				Write-Progress -id 1 -activity "Backing up database $($Database.Name)  to $backupfile" -percentcomplete 0 -status ([System.String]::Format("Progress: {0} %", 0))
				
				try
				{
					$backup.SqlBackup($server)
					$Tsql = $backup.Script($Server)
					Write-Progress -id 1 -activity "Backing up database $($Database.Name)  to $backupfile" -status "Complete" -Completed
					$BackupComplete =  $true
				}
				catch
				{
					Write-Progress -id 1 -activity "Backup" -status "Failed" -completed
					Write-Exception $_
					$BackupComplete = $false
				}
			}
			if ($failreasons.count -eq 0)
			{
				$failreasons += "None to report"
			}
			[PSCustomObject]@{
				SqlInstance = $SqlInstance
				DatabaseName = $($Database.Name)
				BackupComplete = $BackupComplete
				BackupFilesCount = $filecount
				TSql = $Tsql  
				FailReasons = $FailReasons -join (',')				
			} 
			#| Select-DefaultView 
		}
	
		}
	
	}




