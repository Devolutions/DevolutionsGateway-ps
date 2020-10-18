
. "$PSScriptRoot/../Private/CertificateHelper.ps1"
. "$PSScriptRoot/../Private/PlatformHelper.ps1"
. "$PSScriptRoot/../Private/DockerHelper.ps1"
. "$PSScriptRoot/../Private/CaseHelper.ps1"

$script:DGatewayConfigFileName = "gateway.json"
$script:DGatewayCertificateFileName = "certificate.pem"
$script:DGatewayPrivateKeyFileName = "certificate.key"
$script:DGatewayProvisionerPublicKeyFileName = "provisioner.pem"
$script:DGatewayProvisionerPrivateKeyFileName = "provisioner.key"
$script:DGatewayDelegationPublicKeyFileName = "delegation.pem"
$script:DGatewayDelegationPrivateKeyFileName = "delegation.key"

function Get-DGatewayImage
{
    param(
        [string] $Platform
    )

    $Version = '0.13.0'

    $image = if ($Platform -ne "windows") {
        "devolutions/devolutions-jet:${Version}-buster-dev"
    } else {
        "devolutions/devolutions-jet:${Version}-servercore-ltsc2019-dev"
    }

    return $image
}

class DGatewayListener
{
    [string] $InternalUrl
    [string] $ExternalUrl

    DGatewayListener() { }

    DGatewayListener([string] $InternalUrl, [string] $ExternalUrl) {
        $this.InternalUrl = $InternalUrl
        $this.ExternalUrl = $ExternalUrl
    }
}

function New-DGatewayListener()
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string] $ListenerUrl,
        [Parameter(Mandatory=$true, Position=1)]
        [string] $ExternalUrl
    )

    return [DGatewayListener]::new($ListenerUrl, $ExternalUrl)
}

class DGatewayConfig
{
    [string] $FarmName
    [string] $Hostname
    [DGatewayListener[]] $Listeners

    [string] $CertificateFile
    [string] $PrivateKeyFile
    [string] $ProvisionerPublicKeyFile
    [string] $DelegationPrivateKeyFile

    [string] $DockerPlatform
    [string] $DockerIsolation
    [string] $DockerRestartPolicy
    [string] $DockerImage
    [string] $DockerContainerName
}

function Save-DGatewayConfig
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [Parameter(Mandatory=$true)]
        [DGatewayConfig] $Config
    )

    $ConfigFile = Join-Path $ConfigPath $DGatewayConfigFileName

    $Properties = $Config.PSObject.Properties.Name
    $NonNullProperties = $Properties.Where({ -Not [string]::IsNullOrEmpty($Config.$_) })
    $ConfigData = $Config | Select-Object $NonNullProperties | ConvertTo-Json

    [System.IO.File]::WriteAllLines($ConfigFile, $ConfigData, $(New-Object System.Text.UTF8Encoding $False))
}

function Set-DGatewayConfig
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [string] $FarmName,
        [string] $Hostname,
        [DGatewayListener[]] $Listeners,

        [string] $CertificateFile,
        [string] $PrivateKeyFile,
        [string] $ProvisionerPublicKeyFile,
        [string] $DelegationPrivateKeyFile,

        [ValidateSet("linux","windows")]
        [string] $DockerPlatform,
        [ValidateSet("process","hyperv")]
        [string] $DockerIsolation,
        [ValidateSet("no","on-failure","always","unless-stopped")]
        [string] $DockerRestartPolicy,
        [string] $DockerImage,
        [string] $DockerContainerName,
        [string] $Force
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath

    if (-Not (Test-Path -Path $ConfigPath -PathType 'Container')) {
        New-Item -Path $ConfigPath -ItemType 'Directory'
    }

    $ConfigFile = Join-Path $ConfigPath $DGatewayConfigFileName

    if (-Not (Test-Path -Path $ConfigFile -PathType 'Leaf')) {
        $config = [DGatewayConfig]::new()
    } else {
        $config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    }

    $properties = [DGatewayConfig].GetProperties() | ForEach-Object { $_.Name }
    foreach ($param in $PSBoundParameters.GetEnumerator()) {
        if ($properties -Contains $param.Key) {
            $config.($param.Key) = $param.Value
        }
    }

    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Get-DGatewayConfig
{
    [CmdletBinding()]
    [OutputType('DGatewayConfig')]
    param(
        [string] $ConfigPath,
        [switch] $NullProperties,
        [switch] $Expand
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath

    $ConfigFile = Join-Path $ConfigPath $DGatewayConfigFileName
    $ConfigData = Get-Content -Path $ConfigFile -Encoding UTF8
    $json = $ConfigData | ConvertFrom-Json

    $config = [DGatewayConfig]::new()

    [DGatewayConfig].GetProperties() | ForEach-Object {
        $Name = $_.Name
        if ($json.PSObject.Properties[$Name]) {
            $Property = $json.PSObject.Properties[$Name]
            $Value = $Property.Value
            $config.$Name = $Value
        }
    }

    if ($Expand) {
        Expand-DGatewayConfig $config
    }

    if (-Not $NullProperties) {
        $Properties = $Config.PSObject.Properties.Name
        $NonNullProperties = $Properties.Where({ -Not [string]::IsNullOrEmpty($Config.$_) })
        $Config = $Config | Select-Object $NonNullProperties
    }

    return $config
}

function Expand-DGatewayConfig
{
    param(
        [DGatewayConfig] $Config
    )

    if (-Not $config.DockerPlatform) {
        if (Get-IsWindows) {
            $config.DockerPlatform = "windows"
        } else {
            $config.DockerPlatform = "linux"
        }
    }

    if (-Not $config.DockerRestartPolicy) {
        $config.DockerRestartPolicy = "always"
    }

    if (-Not $config.DockerImage) {
        $config.DockerImage = Get-DGatewayImage -Platform $config.DockerPlatform
    }

    if (-Not $config.DockerContainerName) {
        $config.DockerContainerName = 'devolutions-gateway'
    }
}

function Find-DGatewayConfig
{
    param(
        [string] $ConfigPath
    )

    if (-Not $ConfigPath) {
        $ConfigPath = Get-Location
    }

    if ($Env:DGATEWAY_CONFIG_PATH) {
        $ConfigPath = $Env:DGATEWAY_CONFIG_PATH
    }

    return $ConfigPath
}

function Enter-DGatewayConfig
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [switch] $ChangeDirectory
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Env:DGATEWAY_CONFIG_PATH = $ConfigPath

    if ($ChangeDirectory) {
        Set-Location $ConfigPath
    }
}

function Exit-DGatewayConfig
{
    Remove-Item Env:DGATEWAY_CONFIG_PATH
}

function Get-DGatewayPath()
{
	[CmdletBinding()]
	param(
		[Parameter(Position=0)]
        [ValidateSet("ConfigPath")]
		[string] $PathType = "ConfigPath"
	)

    $DisplayName = "Gateway"
    $CompanyName = "Devolutions"

	if (Get-IsWindows)	{
		$ConfigPath = $Env:ProgramData + "\${CompanyName}\${DisplayName}"
	} elseif ($IsMacOS) {
		$ConfigPath = "/Library/Application Support/${CompanyName} ${DisplayName}"
	} elseif ($IsLinux) {
		$ConfigPath = "/etc/devolutions-gateway"
	}

	switch ($PathType) {
        'ConfigPath' { $ConfigPath }
		default { throw("Invalid path type: $PathType") }
	}
}

function Get-DGatewayListeners
{
    [CmdletBinding()]
    [OutputType('DGatewayListener[]')]
    param(
        [string] $ConfigPath
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    $Config.Listeners
}

function Set-DGatewayListeners
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [Parameter(Mandatory=$true, Position=0)]
        [DGatewayListener[]] $Listeners
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    $Config.Listeners = $Listeners
    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Get-DGatewayFarmName
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $(Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties).FarmName
}

function Set-DGatewayFarmName
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [Parameter(Mandatory=$true, Position=0)]
        [string] $FarmName
    )

    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    $Config.FarmName = $FarmName
    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Get-DGatewayHostname
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $(Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties).Hostname
}

function Set-DGatewayHostname
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [Parameter(Mandatory=$true, Position=0)]
        [string] $Hostname
    )

    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    $Config.Hostname = $Hostname
    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Import-DGatewayCertificate
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [string] $CertificateFile,
        [string] $PrivateKeyFile,
        [string] $Password
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties

    $result = Get-PemCertificate -CertificateFile:$CertificateFile `
        -PrivateKeyFile:$PrivateKeyFile -Password:$Password
        
    $CertificateData = $result.Certificate
    $PrivateKeyData = $result.PrivateKey

    New-Item -Path $ConfigPath -ItemType "Directory" -Force | Out-Null

    $CertificateFile = Join-Path $ConfigPath $DGatewayCertificateFileName
    $PrivateKeyFile = Join-Path $ConfigPath $DGatewayPrivateKeyFileName

    Set-Content -Path $CertificateFile -Value $CertificateData -Force
    Set-Content -Path $PrivateKeyFile -Value $PrivateKeyData -Force

    $Config.CertificateFile = $DGatewayCertificateFileName
    $Config.PrivateKeyFile = $DGatewayPrivateKeyFileName

    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Import-DGatewayProvisionerKey
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [string] $PublicKeyFile,
        [string] $PrivateKeyFile
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties

    if ($PublicKeyFile) {
        $PublicKeyData = Get-Content -Path $PublicKeyFile -Encoding UTF8
        $OutputFile = Join-Path $ConfigPath $DGatewayProvisionerPublicKeyFileName
        $Config.ProvisionerPublicKeyFile = $DGatewayProvisionerPublicKeyFileName
        New-Item -Path $ConfigPath -ItemType "Directory" -Force | Out-Null
        Set-Content -Path $OutputFile -Value $PublicKeyData -Force
    }

    if ($PrivateKeyFile) {
        $PrivateKeyData = Get-Content -Path $PrivateKeyFile -Encoding UTF8
        $OutputFile = Join-Path $ConfigPath $DGatewayProvisionerPrivateKeyFileName
        $Config.ProvisionerPrivateKeyFile = $DGatewayProvisionerPrivateKeyFileName
        New-Item -Path $ConfigPath -ItemType "Directory" -Force | Out-Null
        Set-Content -Path $OutputFile -Value $PrivateKeyData -Force
    }

    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Import-DGatewayDelegationKey
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [string] $PublicKeyFile,
        [string] $PrivateKeyFile
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties

    if ($PublicKeyFile) {
        $PublicKeyData = Get-Content -Path $PublicKeyFile -Encoding UTF8
        $OutputFile = Join-Path $ConfigPath $DGatewayDelegationPublicKeyFileName
        $Config.DelegationPublicKeyFile = $DGatewayDelegationPublicKeyFileName
        New-Item -Path $ConfigPath -ItemType "Directory" -Force | Out-Null
        Set-Content -Path $OutputFile -Value $PublicKeyData -Force
    }

    if ($PrivateKeyFile) {
        $PrivateKeyData = Get-Content -Path $PrivateKeyFile -Encoding UTF8
        $OutputFile = Join-Path $ConfigPath $DGatewayDelegationPrivateKeyFileName
        $Config.DelegationPrivateKeyFile = $DGatewayDelegationPrivateKeyFileName
        New-Item -Path $ConfigPath -ItemType "Directory" -Force | Out-Null
        Set-Content -Path $OutputFile -Value $PrivateKeyData -Force
    }

    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Get-DGatewayService
{
    param(
        [string] $ConfigPath,
        [DGatewayConfig] $Config
    )

    if ($config.DockerPlatform -eq "linux") {
        $ContainerConfigPath = "/etc/devolutions-gateway"
    } else {
        $ContainerConfigPath = "C:\ProgramData\Devolutions\Gateway"
    }

    $Service = [DockerService]::new()
    $Service.ContainerName = $config.DockerContainerName
    $Service.Image = $config.DockerImage
    $Service.Platform = $config.DockerPlatform
    $Service.Isolation = $config.DockerIsolation
    $Service.RestartPolicy = $config.DockerRestartPolicy
    $Service.TargetPorts = @()

    foreach ($Listener in $config.GatewayListeners) {
        $InternalUrl = $Listener.InternalUrl -Replace '://\*', '://localhost'
        $url = [System.Uri]::new($InternalUrl)
        $Service.TargetPorts += @($url.Port)
    }
    $Service.TargetPorts = $Service.TargetPorts | Select-Object -Unique

    $Service.PublishAll = $true
    $Service.Environment = [ordered]@{
        "DGATEWAY_CONFIG_PATH" = $ContainerConfigPath;
        "RUST_BACKTRACE" = "1";
        "RUST_LOG" = "info";
    }
    $Service.Volumes = @("${ConfigPath}:${ContainerConfigPath}")
    $Service.External = $false

    return $Service
}

function Update-DGatewayImage
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    Expand-DGatewayConfig -Config $config

    $Service = Get-DGatewayService -ConfigPath:$ConfigPath -Config:$config
    Request-ContainerImage -Name $Service.Image
}

function Start-DGateway
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    Expand-DGatewayConfig -Config:$config

    $Service = Get-DGatewayService -ConfigPath:$ConfigPath -Config:$config

    # pull docker images only if they are not cached locally
    if (-Not (Get-ContainerImageId -Name $Service.Image)) {
        Request-ContainerImage -Name $Service.Image
    }

    Start-DockerService -Service $Service -Remove
}

function Stop-DGateway
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [switch] $Remove
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    Expand-DGatewayConfig -Config $config

    $Service = Get-DGatewayService -ConfigPath:$ConfigPath -Config:$config

    Write-Host "Stopping $($Service.ContainerName)"
    Stop-Container -Name $Service.ContainerName -Quiet

    if ($Remove) {
        Remove-Container -Name $Service.ContainerName
    }
}

function Restart-DGateway
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    Stop-DGateway -ConfigPath:$ConfigPath
    Start-DGateway -ConfigPath:$ConfigPath
}

Export-ModuleMember -Function `
    Enter-DGatewayConfig, Exit-DGatewayConfig, `
    Set-DGatewayConfig, Get-DGatewayConfig, `
    Set-DGatewayFarmName, Get-DGatewayFarmName, `
    Set-DGatewayHostname, Get-DGatewayHostname, `
    New-DGatewayListener, Get-DGatewayListeners, Set-DGatewayListeners, `
    Get-DGatewayPath, Import-DGatewayCertificate, `
    Import-DGatewayProvisionerKey, Import-DGatewayDelegationKey, `
    Start-DGateway, Stop-DGateway, Restart-DGateway, `
    Get-DGatewayImage, Update-DGatewayImage
