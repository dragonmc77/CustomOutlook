﻿<#
	.SYNOPSIS
		Extract messages from a Mail store or PST file in .msg format.

	.DESCRIPTION
		Saves all mail messages within the specified PST file or the current profile's
		mailbox (if PST is not specified) as .msg files within a predetermined folder
		structure.

	.PARAMETER  TargetPath
		The full path of the location to where the .msg files will be saved.

	.PARAMETER  MaxDateReceived
		The date threshold for saving messages. Messages received after this date will
		not be extracted/saved.

	.PARAMETER  MailStore
		The name of the mail store to extract. This is the name of a currently mounted
		store within the current Outlook profile, as it appears in the Outlook
		navigation pane. This may also be the full path and file name of a .pst or .msg
        file to mount for extraction. If this parameter is used, only the specified mail 
        store will be processed. If this parameter is omitted, every mounted mail store
        within the current Outlook profile will be processed.

	.PARAMETER  Archive
		Specifies whether to delete the messages from the mail store after they have
		been saved to disk.

	.PARAMETER  WhatIf
		Simulates an extraction, but does not actually save any files or makes changes
		to the mail store.

	.EXAMPLE
		PS C:\> TODO:: Provide the first example.

	.EXAMPLE
		PS C:\> TODO:: Provide the second example.

	.INPUTS
		System.String,System.DateTime

	.OUTPUTS
		Custom object: TaskResult (see New-TaskResult).

	.NOTES
		Msg files are saved to the file system based on the following structure:
		<TargetPath>\<ReceivedYear>-<ReceivedMonth>\<SenderName>\<Subject>.<Hashcode>.msg
		Example:
		C:\MyMsgFiles\2011-03\sender@domain.com\
			RE subject line.5DCC688E4FFB9E8DFB6C504E1007175B.msg
		However, when the script detects a sender that is a member of the current domain,
		the domain account DisplayName of the sender is used instead:
		C:\MyMsgFiles\2011-03\_John Doe\
			RE subject line.5DCC688E4FFB9E8DFB6C504E1007175B.msg
		An underscore is prepended to the name to seperate all internal domain senders from
		external senders. By default, this results in all internal senders appearing first
		on the list when the folder structure is browsed in Windows Explorer.
		
		If the MailStore parameter is used to specify a .pst file, the .pst file is opened 
        via Outlook and its contents are extracted. If an .msg file is specified, the .msg 
        file is opened and exracted to the target location. If it already exists at the target
        location, the security permissions for the message are verified and re-applied if
        necessary (see below for description of how security permissions are applied).
        Otherwise, the mailbox of the current Outlook profile is used as the source
		(all mail messages in the Inbox and all other folders).
		
		Security permissions are set on each file as it is saved. For each recipient and
		sender of a message with a domain account on the current domain, explicit
		ReadAndExecute permissions are assigned to the file for that account. However, the
		script does not assign permissions to individual users. Instead, for each domain
		account encountered, the script will create an associated Global Security group
		(if one doesn't already exist) within the specified OU in active directory 
		(by default, this is: DomainRoot\SecurityGroups\EmailAccess. These security groups
		are used to set permissions on each .msg. Outlook distribution lists are resolved
		down to their component users and assigned permissions as above. If the
		distribution list is also a security group, that security group itself is also
		assigned the same permissions. If not, then a security group is created for it
		in the previously mentioned OU and permissions are assigned using that.
		
		If the -Archive parameter is present, the script will delete messages as they are
		saved to disk. Messages will only be deleted if they are saved successfully AND
		permissions are successfully set for ALL recipients and senders (via creating
		groups as above, if necessary).

	.LINK
		about_functions_advanced

	.LINK
		about_comment_based_help

#>

param (
    [ValidateScript({Test-Path $_ -PathType 'Container'})]
	[string]
	$TargetPath
	,
	[ValidateScript({[System.DateTime]::TryParse($_,[ref](New-Object System.DateTime))})]
	[datetime]
	$MaxDateReceived = (Get-Date)
	,
    [Parameter(
		ValueFromPipeline=$true,
		ValueFromPipelineByPropertyName=$true)
	]
	[Alias('FullName')]
    [string]
	$MailStore = ''
	,
	[string[]]
	$DefaultFolderFilter = @()
	,
	[switch]
	$Archive
	,
    [switch]
	$WhatIf
)

Begin {
	function New-ADGroup {
	<#	function to create an AD global security group at the specified path in AD,
		and optionally add an initial set of members to it. #>
		param (
			# The name of the new group
			[string]$Name,
			# The path of the OU where the new group should be created. This is expressed
			# as an LDAP path without the domain root informtaion.
			[string]$LdapPath="OU=EmailAccess,OU=SecurityGroups",
			# An array of DirectoryEntry user objects to add to the new group as members
			[System.DirectoryServices.SearchResult[]]$Members = @()
		)
        $result = New-TaskResult
		$LdapPath += (',{0}' -f $domainRoot.Value)
		$newGroupPath = "CN={0},{1}" -f $Name,$LdapPath
		<#	make sure the group doesn't already exist #>
		if (-not [adsi]::Exists("LDAP://$newGroupPath")) {
			<# create the group object and assign its relevant properties #>
			$ou = [adsi]("LDAP://$LdapPath")
			$group = $ou.Children.Add("CN=$Name", "group")
			$group.Properties['displayName'].Value = $Name
			$group.Properties['sAmAccountName'].Value = $Name
			$group.Properties['groupType'].Value = $groupType['GlobalSecurity']
			<#	add initial members (if any)#>
			foreach ($member in $Members) {
				$userDN = $domainObject.Properties['distinguishedname']
				$group.Properties['member'].Add("$userDN") | Out-Null
			}
			try {
				<#	create the group #>
				$group.CommitChanges()
			} catch {
                $result.AddError((New-TaskError 'CREATE_GROUP_FAIL' $newGroupPath))
                return $result
			}
		}
		$newGroup = [adsi]"LDAP://$newGroupPath"
		$result.ReturnValue = Get-ADSearchResults -SearchRoot $newGroup -Scope Base
		if ($result.ReturnValue -eq $null) {
            $result.AddError((New-TaskError 'GET_AD_OBJECT_FAIL' $newGroupPath))
            return $result
		}
        <#  an ACL entry based on this newly created group will be applied to the 
            saved messsage file later in the main script. in testing, the attempt
            to apply the ACL almost always fails. i suspect this is because the
            new group has not propagated through the AD topology via replication.
            let's try having the script wait a bit here for replication to catch up
            so that hopefully our attempt at setting permissions is successful.#>
        Start-Sleep -Seconds 30
        return $result
	}
	function Get-ADSearchResults {
		param (
            # The DirectoryEntry used to represent the root of the search.
			[System.DirectoryServices.DirectoryEntry]$SearchRoot,
            # The LDAP filter to apply to the search.
			[string]$Filter = '(objectClass=*)',
            # The SearchScope enum used to limit the scope of the search.
			[System.DirectoryServices.SearchScope]$Scope =
				[System.DirectoryServices.SearchScope]::Subtree
		)
		$searcher = New-Object System.DirectoryServices.DirectorySearcher
		$searcher.SearchRoot = $SearchRoot
		$searcher.PageSize = 1000
		$searcher.Filter = $Filter
		$searcher.SearchScope = $Scope
		'displayName','sAMAccountName','distinguishedName','memberOf','objectClass','member' | 
			ForEach-Object {$searcher.PropertiesToLoad.Add($_) | Out-Null}
		$searcher.FindAll()
	}
	function Get-SavePath {
	<#	function to compile a path and file name for the msg file based on certain properties
		of the message. the full target path returned by this function will look like:
		\2012\01\sender@domain.com\subjectline.E9717147AE78D1E8448C4B94D1F622A5.msg #>
	    param (
	        [object]$MailItem
	    )
		$route = Get-Route $MailItem.MessageClass
		$datePart = ""
		$senderPart = ""
		$staticPart = ""
		
	    # get the time the message was received
		if ([boolean]::Parse($route.SavePath.UseDate)) {
			$receivedTime = $mailData.ReceivedTime
			if ($receivedTime -eq $null) {$datePart = '\_no_date'}
			else {$datePart = '\{0}' -f $receivedTime.ToString('yyyy\\MM')}
		}
		<#	get the sender name. for internal users (sender type EX) this will be the sender's
			display name (i.e. John Doe). for external users (sender type SMTP) this will be
			an email address.
			NOTE: interestingly, some (but not all) emails archived into a pst file from a 
			user's Sent folder return a zero-length string for the SenderEmailType property.
			we handle those cases here so that the script doesn't categorize the email as
			_unknown_sender	#>
	    if ([boolean]::Parse($route.SavePath.UseSender)) {
			$sender = $mailData.Sender
			<#	on rare occasions, the sender field will be blank, so check for that #>
			if ($sender -eq $null -or $sender.Trim().Length -eq 0) {$sender = "__unknown_sender"}
			# if the sender does not contain an actual email address, prepend an underscore
			if ($sender -notmatch '^[A-Z0-9._%+-=&]+@[A-Z0-9.-]+\.[A-Z]{2,4}$') {$sender = "_$sender"}
			$senderPart = '\{0}' -f [regex]::Replace($sender, $invalidChars, '')
			$senderPart = $senderPart.Trim()
		}
		$staticPart = $route.SavePath.InnerText
		<#	compile the full folder path where the message will go and create that path #>
	    $targetFolderName = "{0}{1}{2}{3}" -f $TargetPath, $datePart, $senderPart, $staticPart
	    New-Item    -Path $targetFolderName `
                    -ItemType Directory `
                    -Force `
                    -ErrorAction SilentlyContinue `
                    -ErrorVariable errCreateFolder | Out-Null
        # [IO.Directory]::CreateDirectory($targetFolderName) | Out-Null
		<#	compile the file name that the message will be saved to. the file name consists
			of the first 50 characters of the subject, followed by the value of a computed hash
			based on certain data in the message (see Message Module documentation).
			Ex. Subject of message.E9717147AE78D1E8448C4B94D1F622A5.msg #>
		[string]$truncatedSubject = [regex]::Match($MailItem.Subject, '.{1,50}').Value
	    [string]$filteredSubject = [regex]::Replace($truncatedSubject, '[^a-zA-Z0-9\s\-\.]', "")
        $filteredSubject = [regex]::Replace($filteredSubject, '\s',' ')
		$filteredSubject = [regex]::Replace($filteredSubject, '\s{2,}', ' ')
		$filteredSubject = $filteredSubject.Trim()
	    if ($filteredSubject.Length -eq 0) {$filteredSubject = "(No Subject)"}
		$hash = Get-MailItemHash $MailItem
		$targetFileName = "{0}.{1}{2}" -f $filteredSubject, $hash, $route.SavePath.Type
		return "$targetFolderName\$targetFileName"
	}
	function Get-Route {
		param([string]$Class)
		
		$route = $settings.Routes | Where-Object {$_.Class -eq $Class}
		$settings.Templates | Where-Object {$_.Name -eq $route.Template} |
			Select-Object -First 1
	}
	function Import-Settings {
		param([string]$Path)
		
		$settings = New-Object PSObject -Property @{Templates=@();Routes=@()}
		[xml]$doc = Get-Content $Path
		foreach ($template in $doc.Settings.Templates.Template) {
			$settings.Templates += $template
		}
		foreach ($route in $doc.Settings.Routes.Route) {
			$settings.Routes += $route
		}
		return $settings
	}
    function New-TaskError {
        param (
            # The name of the error. This should be a key name in the eventList hashtable, which
            # is defined in the the beginning of the script.
            [string]$ErrorName,
            # An object associated with the error.
            [string]$ErrorData
        )
        $errorDef = Get-LogEntryTypes | Where-Object {$_.Id -eq $ErrorName} | Select -First 1
        if ($errorDef -ne $null) {
            $exception = New-Object System.Exception($errorDef.Message)
        } else {
            $exception = New-Object System.Exception("!!!UNKNOWN!!!")
        }
        <# add the error data to the exception by appending to the Data dictionary of the exception:
           http://msdn.microsoft.com/en-us/library/system.exception.data.aspx #>
        $exception.Data.Add("ErrorData",$ErrorData)
        # return a new ErrorRecord object:
        # http://msdn.microsoft.com/en-us/library/ms572373(v=vs.85).aspx
        return New-Object System.Management.Automation.ErrorRecord(
            $exception,
            $ErrorName,
            [System.Management.Automation.ErrorCategory]::NotSpecified,
            $null
        )
    }
    function New-TaskResult {
        param (
            [string]$ReturnValue = '',
            [object[]]$Errors = @(),
            [boolean]$Success = $true
        )
        $newTask = New-Object PSObject -Property @{
            Success=$Success;
            Errors=@();
            ReturnValue=$ReturnValue;
			StartTime=(Get-Date);
			FinishTime=$null;
			TotalItems=0;
			MaxItems=0;
			SkippedItems=0
        }
		$newTask | Add-Member -MemberType ScriptProperty -Name ElapsedTime -Value {
			[TimeSpan]$elapsedTime = New-Object TimeSpan
			if ($this.FinishTime -ne $null) {
				$elapsedTime = $this.FinishTime - $this.StartTime
			}
			return $elapsedTime
		}
        $newTask | Add-Member -MemberType ScriptMethod -Name AddError -Value {
            param ([System.Management.Automation.ErrorRecord]$ErrorObject)
            $this.Success = $false
            $this.Errors += $Error
            # errors should fire an event to let the consumer know:
            # http://technet.microsoft.com/library/hh849954.aspx
            Add-LogEntry -EntryId $ErrorObject.FullyQualifiedErrorId `
                -Data $ErrorObject.Exception.Data['ErrorData']
            "---::{0}::---`n::{1}`n::{2}`n::Category Info: {3}`n::Data: {4}" -f 
                $ErrorObject.FullyQualifiedErrorId,
                $error[0].Exception.Message,
                $error[0].FullyQualifiedErrorId,
                $error[0].CategoryInfo.ToSTring(),
                $ErrorObject.Exception.Data['ErrorData'] |
                    Add-Content -Path "$PSScriptRoot\Extract-MailStore_Log-Verbose.log" -Force
            #New-Event -SourceIdentifier $Error.FullyQualifiedErrorId -MessageData $this | Out-Null
        }
        if ($Errors.Count -gt 0) {
            foreach ($Error in $Errors) {
                $this.AddError($Error)
            }
        }
        return $newTask
    }
	function Process-MapiFolder {
	<#	function that iterates through all the messages in an outlook folder and saves them 
	    to the file system #>
	    param (
	        [object]$MapiFolder,
            [string[]]$ClassFilter = @('IPM.Note')
	    )
        $result = New-TaskResult
        Add-LogEntry -EntryId 'PROCESS_FOLDER_START' `
			-Data ('{0} ({1} items)' -f $MapiFolder.FolderPath, $MapiFolder.Items.Count)
	    <#	check that the folder itself is marked to contain items of type IPM.Note, which
			are email messages. this in itself does not guarantee that the folder contains
			only emails, as pretty much any type of item can be dragged into Outlook folders,
			including the Inbox. But this first step ignores 'non-email' folders, such as
			Calendar, Journal, Notes, RSS Feeds, Contacts, etc. The Public Folder store has
            a DefaultMessageClass of IPM.Post, so we check for that as well. #>
		if ($MapiFolder.DefaultMessageClass -in $ClassFilter) {
	        <#	in testing, there were rare occasions where the OOM was unable to retrieve
				the item count of a folder, so let's test for that. if we cannont retrieve
				the item count, an erorr is logged and the folder is skipped, as we can't
				really proceed without it. #>
			if ($MapiFolder.Items.Count -eq $null) {
                $result.AddError((New-TaskError 'GET_ITEM_COUNT_FAIL' $MapiFolder.FolderPath))
	            return $result
	        }
			# proceed only if the folder actually contains items
	        if ($MapiFolder.Items.Count -gt 0) {
				$result.MaxItems = $MapiFolder.Items.Count
				$count = $MapiFolder.Items.Count
				<#	iterate through all the items in the folder using an index. the index starts
					with the LAST item and decrements to work its way down to the first item.
					this has the consequence of processing the most recent email first, and
					progressing down to the oldest. this is the only reliable method to 
					delete items from the folder without unexpected behavior. #>
				for ($index = $count; $index -gt 0; $index -= 1) {
					$currentItem = $MapiFolder.Items.Item($index)
					$currentRoute = Get-Route $currentItem.MessageClass
					$saveResult = $null
	                if ($currentRoute -ne $null) {
						switch ($currentRoute.Process.Action) {
							'Save' {
								if ($currentItem.ReceivedTime -le $MaxDateReceived) {
									$mailData = New-MailItem $currentItem
									# calculate the full save path of the message
									$mailData.FilePath = Get-SavePath $currentItem
									$applyPerms = [boolean]::Parse($currentRoute.ApplyPermissions)
									Write-Progress  -Activity ("Extracting {0}" -f $MailStore) `
								        -Status "Items remaining in current folder: $index" `
										-PercentComplete ([Math]::Abs(($index - $count) / $count * 100)) `
								        -CurrentOperation $mailData.FilePath
									# save the message to the specified path
									$saveResult = Save-Message -Path $mailData.FilePath -ApplyPermissions $applyPerms
									$result.TotalItems += 1
								}
							}
						}
	                } else {
						Add-LogEntry -EntryId 'SKIP_ITEM' -NoEcho `
							-Data ('Subject: {0} (Type: {1})' -f $currentItem.Subject, $currentItem.MessageClass)
						$result.SkippedItems += 1
					}
					<#	delete the message ONLY if it was successfully saved, which includes
						successful permissions set for all recipients and the sender, or if the message
						type is marked for deletion (in the settings file)
						either condition will apply only if the -Archive switch is specified
						http://msdn.microsoft.com/en-us/library/office/bb175263(v=office.12).aspx #>
					if ($Archive) {
						if ($saveResult.Success -or $currentRoute.Process.Action -eq 'Delete') {
							try {$currentItem.Delete()} 
							catch {$result.AddError((New-TaskError 'DELETE_MESSAGE_FAIL' $Path))}
						}
					}
				}
	        }
	        <#	if this folder contains any subfolders, call this function recursively on each on #>
			if ($MapiFolder.Folders.Count -gt 0) {
	            $subFolderList = $MapiFolder.Folders
				foreach ($subFolder in $subFolderList) {
					Process-MapiFolder $subFolder $ClassFilter
				}
	        }
	    } else {
			<#	if this folder is marked as containing items of anything other than the IPM.Note type,
				log it and continue. i'm not sure of the usefulness of actually logging this behavior #>
            Add-LogEntry -EntryId 'WRONG_FOLDER_TYPE' `
                -Data ('{0} (Type: {1})' -f $MapiFolder.FolderPath, $MapiFolder.DefaultMessageClass)
	    }
		<#	clear the 'Deleted Items' folder, which contains the messages that were just deleted.
			(only if the -Archive switch was used, of course #>
		if ($Archive) {
			$deletedItems = $session.GetDefaultFolder($olDefaultFolders['DeletedItems'])
			$count = $deletedItems.Items.Count
			for ($index = $count; $index -gt 0; $index -= 1) {
				Write-Progress  -Activity 'Emptying Deleted Items...' `
			        -Status 'Percent Complete:' `
					-PercentComplete ([Math]::Abs(($index - $count) / $count * 100)) `
					-CurrentOperation "Items remaining: $index"
				$currentItem = $deletedItems.Items.Item($index)
				try {
					$currentItem.Delete()
				} catch {
					continue
				}
			}
		}
        Add-LogEntry -EntryId 'PROCESS_FOLDER_DONE' `
			-Data ('{0} ({1} items processed)' -f $MapiFolder.FolderPath, $result.TotalItems)
        $result.FinishTime = Get-Date
		$result.ReturnValue = $MapiFolder.FolderPath
        Write-Output $result
	}
	function Map-AdObject {
	<#	function that maps an AD object with an associated special email access group
        if this group does not exist, it is created as a global security group #>
		param ([System.DirectoryServices.SearchResult]$domainObject)
		$result = New-TaskResult
		$displayName = $domainObject.Properties['displayname'] | 
						Where-Object {$_ -ne $null} |
						Select-Object -First 1
		
		<#	if the object is a user, create the special Email Access AD group
			associated with that user (if it does not exist) and return its name #>
		if ($domainObject.Properties['objectclass'] -contains 'user') {
			$groupName = "EmailAccess - {0}" -f $displayName
			$groupPath = "CN=$groupName,$emailAccessPath"
			<# Check if the object is a member of the new group in the master list, 
               which is essentially a check to see if the new group exists or not #>
            if (-not ($domainObject.Properties['memberof'] -contains $groupPath)) {
				$newGroupResult = New-ADGroup -Name $groupName -Members $domainObject
				if ($newGroupResult.Success) {
					# ReturnValue will be a SearchResult object representing the new group
                    $newGroupPath = $newGroupResult.ReturnValue.Properties['distinguishedname'] |
						Select-Object -First 1
					# make the object a member of the new group in the master list
                    $adList[$displayName].Properties['memberof'] += $newGroupPath
					# add the newly created group to the master list
                    if (-not $adList.ContainsKey($groupName)) {
						$adList.Add($groupName, $newGroupResult.ReturnValue)
					}
				} else {
                    <# if we couldn't create the new group, then we can't map the object,
                       so this operation must fail #>
                    $result.AddError("MAP_OBJECT_FAILED", $groupName)
                    return $result
                }
			}
			$result.ReturnValue = $adList[$groupName]
		} elseif ($domainObject.Properties['objectclass'] -contains 'group') {
			$result.ReturnValue = $adList[$displayName]
		} else {
            $result.AddError('MAP_OBJECT_BAD_TYPE', $displayName)
		}
        return $result
	}
	function Save-Message {
	<# function that saves the currently active outlook message item to disk as a .msg file #>
	    param (
	        #[object]$MailItem,
            [string]$Path,
			[boolean]$ApplyPermissions = $true
	    )
        $result = New-TaskResult
	    try {
			# save the message if it does not already exist at the specified location
	        if (-not [IO.File]::Exists($Path)) {
	            if ($WhatIf) {return $result}
	            <#	save the message to the specified path
					http://msdn.microsoft.com/en-us/library/office/bb175283(v=office.12).aspx #>
				Save-MailItem -Path $Path
				$result.TotalItems += 1
	        } else {$result.SkippedItems += 1}
	    } catch {
			<#	there was an error saving the message
                however, sometimes an exception is thrown even though the actual
                message was saved successfully to disk, so we do a last-minute
                check for the existence of the file #>
			$testPath = @{
				Path=$Path;
				ErrorAction='SilentlyContinue';
				ErrorVariable='pathError';
				OutVariable='fileExists'
			}; Test-Path @testPath | Out-Null
			if ((-not ($fileExists)) -or ($pathError -ne $null)) {
                $result.AddError((New-TaskError 'SAVE_MESSAGE_FAIL' $Path))
                return $result
			}
	    }
		<#	set the necessary permissions on the file. the file might have been newly created
			above or it might have already existed. either way, we want to make sure the
			permissions on that file are exactly right #>
	    if ($ApplyPermissions) {
			$setPermResult = Set-Permissions $Path
			<#	if there were any errors setting permissions on the file for any of the recipients,
				log an error #>
        	if (-not $setPermResult.Success) {
            	$result.AddError((New-TaskError 'SAVE_MESSAGE_PARTIAL' $Path))
        	}
		}
		<#	write the message attributes to the sql database, provided one was setup in the
			preferences file #>
		try {
			if ([boolean]::Parse((Get-Route $mailData.MessageClass).Process.WriteToDB)) {
				Export-MailItem $sqlConnection
			}
		} catch {
			$result.AddError((New-TaskError 'WRITE_SQL_FAIL' $Path))
		}
        $result.ReturnValue = $Path
        $result.FinishTime = Get-Date
        return $result
	}
	function Set-Permissions {
	<#	function that sets read permissions on a file for the sender and recipients of
		the specified mail item #>
	    param (
            # The file to set permissions on.
	        [string]$FileName
	    )
        $result = New-TaskResult
		<#  hashtable which will contain all the AD objects related to the current message
            for each entry in this hashtable, an acl will be added to the saved msg file's
            permissions. most of the code in this function is dedicated to populating this
            list #>
	    $messageObjects = @{}
        <#	get the expanded list of recipients from the message (see Get-ExpandedRecipients
            documentation in the Message module for details) #>
		$recipients = Get-ExpandedRecipients
		<#	process all the errors that occurred getting the list of expanded recipients #>
		$recipients | Where-Object {$_ -is [System.Exception]} | ForEach-Object {
			<#  check if the name of the group is in our AD master list. #>
            if ($adList.Keys -contains $_.Data['Name']) {
                <#  this error should never occur. this check was originally put in place because 
                Outlook's distribution list resolution would
                fail even though the name of that group is in AD. since the script now uses
                an active directory query to resolve names, we should never have to worry
                about that #>
				$result.AddError((New-TaskError 'RESOLVE_GROUP_FAIL' $_.Data['Name']))
			} else {
				$newGroupName = 'EmailAccess - {0}' -f $_.Data['Name']
                <# strip out everything but alphanumeric characters, spaces, dashes, periods,
                    and the @ symbol #>
                $newGroupName = [regex]::Replace($newGroupName, "[^a-zA-Z0-9\s\-'\.@]", '')
                if (-not $adList.ContainsKey($newGroupName)) {
                    $newGroupResult = New-ADGroup $newGroupName
                    if ($newGroupResult.Success) {
						Add-LogEntry 'CREATE_GROUP_OK' $newGroupName
                        $adList.Add($newGroupName,$newGroupResult.ReturnValue)
                        $messageObjects.Add($newGroupName, $newGroupResult.ReturnValue)
                    }
                } elseif (-not $messageObjects.ContainsKey($newGroupName)) {
                    $messageObjects.Add($newGroupName, $adList[$newGroupName])
                }
			}
		}
		$recipients | 
			Where-Object {$_ -is [System.String]} |
			Where-Object {$adList.ContainsKey($_)} |
			Where-Object {-not $messageObjects.ContainsKey($_)} |
			ForEach-Object {
				$messageObjects[$_] = $adList[$_]
			}
	    <#	look up the sender in the list of domain objects and save it if found #>
	    $sender = $mailData.Sender
	    if (
			($sender -ne '') -and
			$adList.ContainsKey($sender) -and 
			-not $messageObjects.ContainsKey($sender)
		) {
	        $messageObjects.Add($sender, $adList[$sender])
	    }
		<#	get the current permsissions of the file. do NOT use Get-Acl, as that cmdlet
			returns ownership info along with the acl. since we use the object returned 
			here to later write the acl information back into the file, it wouldn't
			work because we do not want to change ownership info
			GetAccessControl returns a FileSecurity object:
			http://msdn.microsoft.com/en-us/library/system.security.accesscontrol.filesecurity.aspx #>
		try {
			$permissions = (Get-Item $FileName).GetAccessControl('Access')
		} catch {
			$result.AddError((New-TaskError 'READ_ACL_FAIL' $FileName))
            return $result
		}
		$aclNames = ($permissions.GetAccessRules(
			$true,
			$true,
			[System.Security.Principal.NTAccount])) |
				ForEach-Object {
					[regex]::Replace($_.IdentityReference.Value, "^$netBiosName", $fullDomainName)
				} | Where-Object {$_.StartsWith($fullDomainName)}
		$mailData.Permissions += $aclNames
		<#	now that we have a list of all (valid) domain objects associated with the
			message, go through and add permissions for those users to the file #>
	    foreach ($key in $messageObjects.Keys) {
	        try {
				$mapResult = Map-AdObject $messageObjects[$key]
				$groupAccountName = '{0}\{1}' -f 
					$fullDomainName,
					($mapResult.ReturnValue.Properties['samaccountname'] | 
						Select-Object -First 1)
	            if ($aclNames -notcontains $groupAccountName) {
					$mailData.Permissions += $groupAccountName
					$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($groupAccountName,"ReadAndExecute","Allow")
					$permissions.AddAccessRule($rule)
					$setAcl = @{
						Path=$FileName;
						AclObject=$permissions;
						ErrorAction='SilentlyContinue';
						ErrorVariable='aclError'
					}; Set-Acl @setAcl
					if ($aclError -ne $null) {throw $aclError.Exception.Message}
				}
	        } catch {
				$result.AddError((New-TaskError 'SET_ACL_FAIL' $groupAccountName))
				continue
	        }
	    }
        $result.FinishTime = Get-Date
        $result.ReturnValue = $FileName
		return $result
	}

	#region VARIABLE INITIALIZATION
	<#  declare some variables we will need, including script-level ones #>
	if ($PSScriptRoot -eq $null) {$PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent}
	[string]$parentDir = Split-Path $PSScriptRoot -Parent
	. "$parentDir\globalfunctions.ps1"
	<# load the Custom.Outlook module, which gives us access to some convenient constants #>
	if (-not (Get-Module -Name "Custom.Outlook")) {
        Import-Module "$parentDir\Modules\Custom.Outlook" -ErrorAction Stop
    }
	<# load the Message module, which gives us access to the *-MailItem commands #>
	if (-not (Get-Module -Name "Custom.Outlook.Message")) {
        Import-Module "$parentDir\Modules\Custom.Outlook\Message" -ErrorAction Stop
    }
	<# load and set up the logging module, which gives us access to the *-LogEntry commands #>
    if (-not (Get-Module -Name "Custom.Logging")) {
	    Import-Module "$parentDir\Modules\Custom.Logging" -ErrorAction Stop
    }
	<# load status message info #>
	Import-Csv "$PSScriptRoot\Extract-Mailstore_Events.csv" | Add-LogEntryType
	<#	setting script-level variables triggers a confirmation message unless this built-in 
		variable is set to "High". this used to be the default, but was apparently changed
		with an update #>	
	$ConfirmPreference = "High"
	<#	used to strip out characters not allowed in file and folder names #>
	$invalidChars = '["\<\>\|\:\*\?\\\/\[\]\t&]'
	<#	this hashtable will contain the results of the ldap query we will run to get a list
		of all users and global security groups on the domain, keyed by the DisplayName
		attribute #>
	$adList = @{}
	<#	get the domain root in LDAP notation #>
	$domainRoot = ([adsi]"LDAP://RootDSE").rootDomainNamingContext
	<#	all security groups created by this script to set permissions on files will be
		created in the LDAP path specified in this variable #>
	$emailAccessPath = 'OU=EmailAccess,OU=SecurityGroups,{0}' -f $domainRoot.Value
	<#	get the full domain name in plain text #>
	$fullDomainName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name
	<#	get the NetBIOS name of the current domain. this is no longer actually used #>
	$netBiosName = (Get-WmiObject Win32_NTDomain -Filter "DnsForestName = '$fullDomainName'").DomainName
	<#	this hashtable contains the possible valid values of the active
		directory 'groupType' attribute. this will be used when the script needs
		to determine the type of a particular group, and when creating groups:
		http://msdn.microsoft.com/en-us/library/windows/desktop/ms675935%28v=vs.85%29.aspx #>
	$groupType = @{
		'GlobalSecurity'=-2147483646;
		'LocalSecurity'=-2147483644;
		'BuiltIn'=-2147483643;
		'UniversalSecurity'=-2147483640;
		'GlobalDistribution'=2;
		'LocalDistribution'=4
		'UniversalDistribution'=8;
	}
	<#	get the settings for routing messages, defined in a seperate xml file
		settings are based on message type:
		http://msdn.microsoft.com/en-us/library/office/bb175508%28v=office.12%29.aspx #>
	$settings = Import-Settings "$PSScriptRoot\Extract-MailStore_Settings.xml"
	#endregion

	#region ACTIVE DIRECTORY OPERATIONS
	<#  get a list of all domain users and global security groups on the current domain
		into the adList hashtable, keyed by displayName #>
	<#	this ldap filter returns all users AND global and universal security groups #>
	$adFilterUser = '&(objectCategory=User)(objectClass=User)'
	$adFilterGlobal = '&(objectCategory=Group)(groupType=-2147483646)'
	$adFilterUniversal = '&(objectCategory=Group)(groupType=-2147483640)'
	$adFilter = '(|({0})({1})({2}))' -f $adFilterUser,$adFilterGlobal,$adFilterUniversal
	$domain = New-Object System.DirectoryServices.DirectoryEntry
	Get-ADSearchResults -SearchRoot $domain -Filter $adFilter | 
	    Where-Object {
			$_.Properties['displayname'] -ne $null -and 
			$_.Properties['samaccountname'] -ne $null
		} |
	    ForEach-Object {
            [string]$key = $_.Properties['displayname']
            if (-not $adList.ContainsKey($key)) {
                $adList.Add($key,$_)
            }
	    }
    Set-GroupLookup $adList
	#endregion
	
	#region OUTLOOK OBJECT(S) OPERATIONS
	<#  initialize the Outlook application and connect to the default session
		(the current user's mailbox). we need to do this regardless of whether
		we actually access anything within the user's mailbox. #>
	try {
	    $outlook = New-Object -ComObject Outlook.Application
	    $session = $outlook.Session
	} catch {
	    Show-LogEntry "Start Outlook" -Result Fail; break
	}
	Show-LogEntry "Start Outlook" -Result OK
	<#	get the global address list from exchange via outlook #>
	$globalList = $session.AddressLists | Where-Object {$_.Name -eq "Global Address List"}
	#endregion
	
	#region SQL OPERATIONS
	$sqlConnection = New-Object System.Data.SqlClient.SqlConnection
	$sqlConnection.ConnectionString = "Data Source=sfo-sql;Initial Catalog=EmailArchive;Integrated Security=True;MultipleActiveResultSets=True;"
	$sqlConnection.Open()
	#endregion
}

Process {
	$result = New-TaskResult
    Add-LogEntry -EntryId 'PROCESS_STORE_START' -Data $MailStore
	# take action based on the value of certain parameters:
	# MAILSTORE: PST
	<#  connect to the .pst and iterate through each folder recursively to extract the messages
		within #>
	if ([IO.Path]::GetExtension($MailStore).ToLower() -eq '.pst') {
	    if ((Test-Path $MailStore)) {
	        try {
				$session.AddStoreEx($MailStore, $olStore.Default)
                $pstStore = $session.Stores | Where-Object {$_.FilePath -eq $MailStore}
                $pstRootFolder = $pstStore.GetRootFolder()
                $results = Process-MapiFolder $pstRootFolder
	        } catch {
				$result.AddError((New-TaskError 'ATTACH_PST_FAIL' $MailStore))
			}
	    } else {$result.AddError((New-TaskError 'FILE_NOT_FOUND' $MailStore))}
    # MAILSTORE: Outlook Folder
    } elseif ($Mailstore.StartsWith('Outlook:\\')) {
        $pathParts = $MailStore.Split("\", [StringSplitOptions]::RemoveEmptyEntries)
        $pathParts = $pathParts[1..999]
        if ($pathParts.Length -lt 2) {
            $result.AddError((New-TaskError 'INVALID_PATH' $MailStore)); break
        }
        $store = $session.Stores | Where-Object {$_.DisplayName -eq $pathParts[0]}
        if ($store -eq $null) {
            $result.AddError((New-TaskError 'STORE_NOT_FOUND' $MailStore)); break
        }
        $rootFolder = $store.GetRootFolder()
        $olFolder = $rootFolder.Folders | Where-Object {$_.Name -eq $pathParts[1]}
        if ($olFolder -eq $null) {
            $result.AddError((New-TaskError 'FOLDER_NOT_FOUND' $pathParts[1])); break
        }
        foreach ($part in $pathParts[2..999]) {
            $olFolder = $olFolder.Folders | Where-Object {$_.Name -eq $part}
            if ($olFolder -eq $null) {
                $result.AddError((New-TaskError 'FOLDER_NOT_FOUND' $part)); break
            }
        }
        $results = Process-MapiFolder $olfolder
    # MAILSTORE: FOLDER
	<#	retrieve all the files with an .msg extension in the folder and save them to the target path #>
	} elseif ($MailStore.Length -gt 0 -and (Test-Path -Path $MailStore -PathType Container)) {
        <#  for folders with a very large number of files (I suspect something above 32k or so)
            Get-ChildItem will error out if the script is run in 32-bit Powershell. #>
		Get-ChildItem -Recurse -Path $MailStore -Filter '*.msg' | ForEach-Object {
            $msg = $_
			$result.MaxItems += 1
            try {
                New-MailItem $session.OpenSharedItem($msg.FullName)
            } catch {
            	$result.AddError((New-TaskError 'OPEN_MSG_FAIL' $msg.Fullname))
				$result.SkippedItems += 1
				continue
			}
			$currentRoute = Get-Route $mailData.MessageClass
            if ($currentRoute -ne $null) {
                $mailData.FilePath = (Get-SavePath $mailData.BaseMailItem)
                $applyPerms = [boolean]::Parse($currentRoute.ApplyPermissions)
			    Write-Progress  -Activity ("Extracting {0}" -f $MailStore) `
		            -Status "Items processed: $($result.MaxItems)" `
		            -CurrentOperation $mailData.FilePath
			    $saveResult = Save-Message -Path $mailData.FilePath -ApplyPermissions $applyPerms
			    if ($Archive -and $saveResult.Success) {
				    Add-LogEntry -EntryId 'MARK_FOR_DELETE' -Data $msg.FullName -NoEcho
			    }
                $mailData.BaseMailItem.Close($olCloseAction['Discard'])
			    $result.TotalItems += $saveResult.TotalItems
			    $result.SkippedItems += $saveResult.SkippedItems
            } else {
				Add-LogEntry -EntryId 'SKIP_ITEM' -NoEcho `
					-Data ('File: {0} (Type: {1})' -f $msg.FullName, $mailData.MessageClass)
				$result.SkippedItems += 1
			}
		}
	# DEFAULTOUTLOOKFOLDER: ANY
	<#	connect to each of the specified Outlook default folders and extract their contents #>
	} elseif ($DefaultFolderFilter.Count -gt 0) {
		foreach ($folder in $DefaultFolderFilter) {
			if (-not $olDefaultFolders.ContainsKey($folder)) {continue}
			# get the default folder that matches the filter specified:
			# http://msdn.microsoft.com/en-us/library/office/bb219900(v=office.12).aspx
			$currentFolder = $session.GetDefaultFolder($olDefaultFolders[$folder])
			switch ($folder) {
                'PublicFolders' {$classFilter = @('IPM.Note','IPM.Post'); break}
                default {$classFilter = @('IPM.Note')}
            }
            $results = Process-MapiFolder $currentFolder $classFilter
		}
	# DEFAULT
	<#	connect to the Outlook profile of the currently logged on user and iterate through
		its folders to extract their contents #>
	} else {
	    $rootFolderList = $session.Folders
		$currentRootFolder = $rootFolderList.GetFirst()
		do {
			if (($MailStore -eq '') -or ($currentRootFolder.Name -eq $MailStore)) {
                $results += Process-MapiFolder $currentRootFolder
            }
		    $currentRootFolder = $rootFolderList.GetNext()
		} while ($currentRootFolder -ne $null)
	}
	
	$result.FinishTime = Get-Date
	<#	if a PST file was processed, let's make sure to disconnect it #>
	if (($pstStore -ne $null) -and ($result.Errors.Count -eq 0)) {
		$pstFolder = $session.Folders.Item($pstRootFolder.Name)
		try {
            $session.GetType().InvokeMember('RemoveStore',[System.Reflection.BindingFlags]::InvokeMethod,$null,$session,($pstFolder))
        } catch {
            $result.AddError((New-TaskError 'DETACH_PST_FAIL' $MailStore))
        }
	}
	# gather, log, and display the statistics of the operation
	if ($results -ne $null) {
		$result.MaxItems = ($results | Measure-Object -Sum -Property 'MaxItems').Sum
		$result.TotalItems = ($results | Measure-Object -Sum -Property 'TotalItems').Sum
		$result.SkippedItems = ($results | Measure-Object -Sum -Property 'SkippedItems').Sum
	}
	$time = '{0:N1} min.' -f $result.ElapsedTime.TotalMinutes
	Add-LogEntry -EntryId 'PROCESS_STORE_DONE' `
		-Data ('{0} ({1} of {2} items processed in {3})' -f $MailStore, $result.TotalItems, $result.MaxItems, $time) -NoEcho
	Show-LogEntry -Action 'Total Items:' -Result $result.MaxItems -Indent 5
	Show-LogEntry -Action 'Saved items:' -Result $result.TotalItems -Indent 5
	Show-LogEntry -Action 'Skipped items:' -Result $result.SkippedItems -Indent 5
    Save-Log -Path "$PSScriptRoot\Extract-MailStore_Log.csv" -Clear
}

End {
	$sqlConnection.Close()
    $session.LogOff()
    ##$outlook.Quit()
}
