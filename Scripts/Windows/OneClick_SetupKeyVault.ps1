param(
	[string]
	$keyvaultName,

	[string]
	$AADApplicationName,

    [ValidateNotNullOrEmpty()]
	[string]
	$resourceGroupName="cdn_https_keyvault_script_setup",

	[string]
	$subscriptionId
)

function Create-AesManagedObject($key, $IV) {

    $aesManaged = New-Object "System.Security.Cryptography.AesManaged"
    $aesManaged.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aesManaged.Padding = [System.Security.Cryptography.PaddingMode]::Zeros
    $aesManaged.BlockSize = 128
    $aesManaged.KeySize = 256

    if ($IV) {
        if ($IV.getType().Name -eq "String") {
            $aesManaged.IV = [System.Convert]::FromBase64String($IV)
        }
        else {
            $aesManaged.IV = $IV
        }
    }

    if ($key) {
        if ($key.getType().Name -eq "String") {
            $aesManaged.Key = [System.Convert]::FromBase64String($key)
        }
        else {
            $aesManaged.Key = $key
        }
    }

    $aesManaged
}


function Create-AesKey() {
    $aesManaged = Create-AesManagedObject 
    $aesManaged.GenerateKey()
    [System.Convert]::ToBase64String($aesManaged.Key)
}

# set stop when error
$ErrorActionPreference = "Stop"

$highlightForgroundColor=[System.ConsoleColor]::Yellow

$keyvaultResourceGroupName=$resourceGroupName

Write-Host "This script is to setup KeyVault as certificate holder for Azure China CDN Https. "
Write-Host -NoNewLine 'Press any key to sign in with your China Azure Credential...';
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');

Write-Host

#check whether AzureRM module has been installed 
try
{
	Write-Host "Makesure AzureRM module is loaded..."
	Import-Module -Name AzureRM
}
catch
{
	Write-Host "AzureRM module has not been added in this machine, will install now..."
	Install-Module -Name AzureRM -RequiredVersion 4.3.1 -AllowClobber
	Import-Module -Name AzureRM
}
finally
{
	Write-Host "AzureRM module is loaded..."
}

#login azure account
Login-AzureRmAccount -EnvironmentName AzureChinaCloud | Out-Null

Write-Host
Write-Host "Login succeeded!"
Write-Host

#setup subscription

if ([string]::IsNullOrEmpty($subscriptionId))
{
	Write-Host "SubscriptionId not specified. Will use default one..."
}
else
{
	Write-Host "SubscriptionId is " $subscriptionId ". Will set it as default..."
	Select-AzureRmSubscription -SubscriptionId $subscriptionId | Out-Null
}

$currentContext = Get-AzureRmContext
Write-Host "Subscription: " $currentContext.Subscription.Name -ForegroundColor $highlightForgroundColor
Write-Host "SubscriptionId: " $currentContext.Subscription.Id -ForegroundColor $highlightForgroundColor

#setup resource group

Write-Host
write-host "Checking resource group status..."
Write-Host "Resource Group Name: " $resourceGroupName -ForegroundColor $highlightForgroundColor

$resourceGroup = Get-AzureRmResourceGroup -Name $keyvaultResourceGroupName -ErrorVariable rgNotPresent -ErrorAction SilentlyContinue
if ($rgNotPresent)
{
	write-host "ResourceGroup $keyvaultResourceGroupName does not exists, creating..."
	$resourceGroup = New-AzureRmResourceGroup -Name $keyvaultResourceGroupName -Location "chinanorth"
}

write-host "Resource group status check pass"

#setup key vault

Write-Host
write-host "Checking key vault status..."

if ([string]::IsNullOrEmpty($keyvaultName))
{

	Write-Host "KeyVault not specified. Will generate one..."
	$randNum = Get-Random
	$keyvaultName = "CdnHttpsAuto" + $randNum
}

Write-Host "KeyVault Name: " $keyvaultName  -ForegroundColor $highlightForgroundColor

$keyvault = Get-AzureRmKeyVault -VaultName $keyvaultName -ErrorVariable keyvaultNotPresent -ErrorAction SilentlyContinue
if (!$keyvault)
{
	write-host "KeyVault $keyvaultName does not exists, creating..."
	$keyvault = New-AzureRmKeyVault -VaultName $keyvaultName -ResourceGroupName $keyvaultResourceGroupName -Location 'chinanorth'
}

write-host "key vault status check pass"

# Create AAD application by secrets authentication

Write-Host
write-host "Checking AAD Application status..."

if ([string]::IsNullOrEmpty($AADApplicationName))
{
	Write-Host "AAD Application Name is not specified. Will use the same name as keyvault..."
	$aadAppName = $keyvaultName
}
else
{
	$aadAppName = $AADApplicationName
}

Write-Host "AAD Application Name: " $aadAppName -ForegroundColor $highlightForgroundColor

$aadAppUrl = "https://" + $aadAppName
Write-Host "AAD Application Url: " $aadAppUrl

$adapp = Get-AzureRmADApplication -IdentifierUri $aadAppUrl
if (!$adapp)
{
	write-host "Creating AAD application $aadAppName with Uri $aadAppUrl ..."

	#Create the 44-character key value

	$keyValue = Create-AesKey
	
	try
	{
		$psadCredential = New-Object Microsoft.Azure.Graph.RBAC.Version1_6.ActiveDirectory.PSADPasswordCredential -ErrorVariable psadCredentialNotPresent -ErrorAction SilentlyContinue
		if ($psadCredentialNotPresent)
		{
		$psadCredential = New-Object Microsoft.Azure.Commands.Resources.Models.ActiveDirectory.PSADPasswordCredential
		}
	}
	catch
	{
		$psadCredential = New-Object Microsoft.Azure.Commands.Resources.Models.ActiveDirectory.PSADPasswordCredential
	}

	$startDate = Get-Date
	$psadCredential.StartDate = $startDate
	$psadCredential.EndDate = $startDate.AddYears(2)
	$psadCredential.KeyId = [guid]::NewGuid()
	$psadCredential.Password = $KeyValue

	$adapp = New-AzureRmADApplication -DisplayName $aadAppName -HomePage $aadAppUrl -IdentifierUris $aadAppUrl -PasswordCredentials $psadCredential
	Write-Host 'Created. AAD App ApplicationId:' $adapp.ApplicationId
}
Write-Host "AAD Application Id" $adapp.ApplicationId -ForegroundColor $highlightForgroundColor
write-host 'AAD Application status check pass.'

# assign AAD application to key vault and grant permissions
Write-Host
write-host "Assigning AAD application $aadAppName with AppId " $adapp.ApplicationId " to key vault $keyvaultName for permissions..."

write-host "Checking AAD Service Principal status..."
$sp = get-AzureRmADServicePrincipal -ServicePrincipalName $adapp.ApplicationId

if (!$sp)
{
	write-host "Creating AAD Service Principal for AAD Application Id " $adapp.ApplicationId "..."
	$sp = New-AzureRmADServicePrincipal -ApplicationId $adapp.ApplicationId
}
write-host "AAD Service Principal status check pass"

Set-AzureRmKeyVaultAccessPolicy -VaultName $keyvaultName -ServicePrincipalName $aadAppUrl -ResourceGroupName $keyvaultResourceGroupName -PermissionsToSecrets list,get -PermissionsToCertificates get,list,create,import

Write-Host "Assigned."

Write-Host
Write-Host "Setup Key Vault for Azure China CDN Https done!"
Write-Host
Write-Host "====== Please fill Azure China CDN Unified Portal Https settings with bellowing info ======"
Write-Host
Write-Host "KeyVault:                     " $keyvault.VaultUri -ForegroundColor $highlightForgroundColor
Write-Host "AAD Application ClientId:     " $adapp.ApplicationId -ForegroundColor $highlightForgroundColor
Write-Host "AAD Application ClientSecret: " $keyValue -ForegroundColor $highlightForgroundColor
Write-Host

Write-Host -NoNewLine 'KeyVault set complete! Press any key continue...';
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');