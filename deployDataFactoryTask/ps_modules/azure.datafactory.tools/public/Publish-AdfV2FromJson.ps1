<#
.SYNOPSIS
Publishes all ADF objects from JSON files into target ADF service.

.DESCRIPTION
Publishes all ADF objects from JSON files into target ADF service.
Creates a data factory with the specified resource group name and location, if that doesn't exist.
Takes care of creating ADF, appropriate order of deployment, deleting objects not in the source anymore, replacing properties environment-related based on CSV config file, and more.

.PARAMETER RootFolder
Source folder where all ADF objects are kept. The folder should contain subfolders like pipeline, linkedservice, etc.

.PARAMETER ResourceGroupName
Resource Group Name of target instance of ADF

.PARAMETER DataFactoryName
Name of target ADF instance

.PARAMETER Stage
Optional parameter. When defined, process will replace all properties defined in (csv) configuration file.
The parameter can be either full path to csv file (must ends with .csv) or just stage name.
When you provide parameter value 'UAT' the process will try open config file located .\deployment\config-UAT.csv

.PARAMETER Location
Azure Region for target ADF. Used only for create new ADF instance.

.PARAMETER Option
This objects allows to define certain behaviour of deployment process. Use cmdlet "New-AdfPublishOption" to create new instance of objects and set required properties.

.EXAMPLE
# Publish entire ADF
$ResourceGroupName = 'rg-devops-factory'
$DataFactoryName = "SQLPlayerDemo"
$Location = "NorthEurope"
$RootFolder = "c:\GitHub\AdfName\"
Publish-AdfV2FromJson -RootFolder "$RootFolder" -ResourceGroupName "$ResourceGroupName" -DataFactoryName "$DataFactoryName" -Location "$Location"

.EXAMPLE
# Publish entire ADF with specified properties (different environment stage name provided)
Publish-AdfV2FromJson -RootFolder "$RootFolder" -ResourceGroupName "$ResourceGroupName" -DataFactoryName "$DataFactoryName" -Location "$Location" -Stage "UAT"

.EXAMPLE
# Publish entire ADF with specified properties (different environment config full path file provided)
$configCsvFile = 'c:\myCode\myadf\deployment\config-UAT.csv'
Publish-AdfV2FromJson -RootFolder "$RootFolder" -ResourceGroupName "$ResourceGroupName" -DataFactoryName "$DataFactoryName" -Location "$Location" -Stage "$configCsvFile"

.EXAMPLE
# Including objects by type and name pattern
$opt = New-AdfPublishOption
$opt.Includes.Add("pipeline.Copy*", "")
$opt.DeleteNotInSource = $false
Publish-AdfV2FromJson -RootFolder "$RootFolder" -ResourceGroupName "$ResourceGroupName" -DataFactoryName "$DataFactoryName" -Location "$Location" -Stage "UAT" -Option $opt

.EXAMPLE
# Including only one object to deployment and do not stop/start triggers
$opt = New-AdfPublishOption
$opt.Includes.Add("pipeline.Wait1", "")
$opt.StopStartTriggers = $false
Publish-AdfV2FromJson -RootFolder "$RootFolder" -ResourceGroupName "$ResourceGroupName" -DataFactoryName "$DataFactoryName" -Location "$Location" -Stage "UAT" -Option $opt

.LINK
Online version: https://github.com/SQLPlayer/azure.datafactory.tools/
#>
function Publish-AdfV2FromJson {
    [CmdletBinding()]
    param
    (
        [parameter(Mandatory = $true)] [String] $RootFolder,
        [parameter(Mandatory = $true)] [String] $ResourceGroupName,
        [parameter(Mandatory = $true)] [String] $DataFactoryName,
        [parameter(Mandatory = $false)] [String] $Stage = $null,
        [parameter(Mandatory = $false)] [String] $Location,
        [parameter(Mandatory = $false)] [AdfPublishOption] $Option
    )

    $m = Get-Module -Name "azure.datafactory.tools"
    $verStr = $m.Version.ToString(2) + "." + $m.Version.Build.ToString("000");
    Write-Host "======================================================================================";
    Write-Host "### azure.datafactory.tools                                       Version $verStr ###";
    Write-Host "======================================================================================";
    Write-Host "Invoking Publish-AdfV2FromJson (https://github.com/SQLPlayer/azure.datafactory.tools)";
    Write-Host "with the following parameters:";
    Write-Host "======================================================================================";
    Write-Host "RootFolder:         $RootFolder";
    Write-Host "ResourceGroupName:  $ResourceGroupName";
    Write-Host "DataFactoryName:    $DataFactoryName";
    Write-Host "Location:           $Location";
    Write-Host "Stage:              $Stage";
    Write-Host "Options provided:   $($null -ne $Option)";
    Write-Host "======================================================================================";

    $script:StartTime = Get-Date

    if ($null -ne $Option) {
        Write-Host "Publish options are provided."
        $opt = $Option
    }
    else {
        Write-Host "Publish options are not provided."
        $opt = New-AdfPublishOption
    }

    Write-Host "STEP: Verifying whether ADF exists..."
    $targetAdf = Get-AzDataFactoryV2 -ResourceGroupName "$ResourceGroupName" -Name "$DataFactoryName" -ErrorAction:Ignore
    if ($targetAdf) {
        Write-Host "Azure Data Factory exists."
    } else {
        $msg = "Azure Data Factory instance does not exist."
        if ($opt.CreateNewInstance) {
            Write-Host "$msg"
            Write-Host "Creating a new instance of Azure Data Factory..."
            Set-AzDataFactoryV2 -ResourceGroupName "$ResourceGroupName" -Name "$DataFactoryName" -Location "$Location"
        } else {
            Write-Host "Creation operation skipped as publish option 'CreateNewInstance' = false"
            Write-Error "$msg"
        }
    }

    Write-Host "===================================================================================";
    Write-Host "STEP: Reading Azure Data Factory from JSON files..."
    $adf = Import-AdfFromFolder -FactoryName $DataFactoryName -RootFolder "$RootFolder"
    $adf.ResourceGroupName = "$ResourceGroupName";
    Write-Debug ($adf | Format-List | Out-String)

    # Apply Deployment Options if applicable
    if ($null -ne $Option) {
        ApplyExclusionOptions -adf $adf -option $opt
    }

    Write-Host "===================================================================================";
    Write-Host "STEP: Replacing all properties environment-related..."
    if (![string]::IsNullOrEmpty($Stage)) {
        Update-PropertiesFromCsvFile -adf $adf -stage $Stage
    } else {
        Write-Host "Stage parameter was not provided - action skipped."
    }

    Write-Host "===================================================================================";
    Write-Host "STEP: Stopping triggers..."
    if ($opt.StopStartTriggers -eq $true) {
        Stop-Triggers -adf $adf
    } else {
        Write-Host "Operation skipped as publish option 'StopStartTriggers' = false"
    }

    Write-Host "===================================================================================";
    Write-Host "STEP: Deployment of all ADF objects..."
    $adf.AllObjects() | ForEach-Object {
        Deploy-AdfObject -obj $_
    }

    Write-Host "===================================================================================";
    Write-Host "STEP: Deleting objects not in source ..."
    if ($opt.DeleteNotInSource -eq $true) {
        $adfIns = Get-AdfFromService -FactoryName "$DataFactoryName" -ResourceGroupName "$ResourceGroupName"
        $adfIns.AllObjects() | ForEach-Object {
            Remove-AdfObjectIfNotInSource -adfSource $adf -adfTargetObj $_ -adfInstance $adfIns
        }
    } else {
        Write-Host "Operation skipped as publish option 'DeleteNotInSource' = false"
    }

    Write-Host "===================================================================================";
    Write-Host "STEP: Starting all triggers..."
    if ($opt.StopStartTriggers -eq $true) {
        Start-Triggers -adf $adf
    } else {
        Write-Host "Operation skipped as publish option 'StopStartTriggers' = false"
    }
    
    $elapsedTime = new-timespan $script:StartTime $(get-date)
    Write-Host "==============================================================================";
    Write-Host "       Azure Data Factory files have been deployed successfully.";
    Write-Host ([string]::Format("             Elapsed time: {0:d1}:{1:d2}:{2:d2}.{3:d3}", $elapsedTime.Hours, $elapsedTime.Minutes, $elapsedTime.Seconds, $elapsedTime.Milliseconds))
    Write-Host "==============================================================================";
}
