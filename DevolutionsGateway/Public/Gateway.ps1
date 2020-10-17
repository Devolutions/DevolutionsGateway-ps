
. "$PSScriptRoot/../Private/CertificateHelper.ps1"
. "$PSScriptRoot/../Private/PlatformHelper.ps1"
. "$PSScriptRoot/../Private/DockerHelper.ps1"
. "$PSScriptRoot/../Private/CaseHelper.ps1"

function Get-DGatewayImage
{
    param(
        [string] $Platform
    )

    $JetVersion = '0.12.0'

    $image = if ($Platform -ne "windows") {
        "devolutions/devolutions-jet:${JetVersion}-buster"
    } else {
        "devolutions/devolutions-jet:${JetVersion}-servercore-ltsc2019"
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
    [string] $GatewayFarmName
    [string] $GatewayHostname
    [DGatewayListener[]] $GatewayListeners

    [string] $CertificateFile
    [string] $PrivateKeyFile
    [string] $ProvisionerPublicKeyFile
    [string] $DelegationPrivateKeyFile

    [string] $DockerPlatform
    [string] $DockerIsolation
    [string] $DockerRestartPolicy
    [string] $DockerImage
}

function Save-DGatewayConfig
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [Parameter(Mandatory=$true)]
        [DGatewayConfig] $Config
    )

    $Properties = $Config.PSObject.Properties.Name
    $NonNullProperties = $Properties.Where({ -Not [string]::IsNullOrEmpty($Config.$_) })
    $Config = $Config | Select-Object $NonNullProperties
    $ConfigData = ConvertTo-Json -InputObject $Config

    [System.IO.File]::WriteAllLines($ConfigFile, $ConfigData, $(New-Object System.Text.UTF8Encoding $False))
}

function Set-DGatewayConfig
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [string] $GatewayFarmName,
        [string] $GatewayHostname,
        [DGatewayListener[]] $GatewayListeners,

        [string] $CertificateFile,
        [string] $PrivateKeyFile,
        [string] $ProvisionerPublicKeyFile,
        [string] $DelegationPrivateKeyFile,

        [ValidateSet("linux","windows")]
        [string] $DockerPlatform,
        [ValidateSet("process","hyperv")]
        [string] $DockerIsolation,
        [ValidateSet("no","on-failure","always","unless-stopped")]
        [string] $DockerRestartPolicy = "always",
        [string] $DockerImage,
        [string] $Force
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath

    if (-Not (Test-Path -Path $ConfigPath -PathType 'Container')) {
        New-Item -Path $ConfigPath -ItemType 'Directory'
    }

    $ConfigFile = Join-Path $ConfigPath "gateway.json"

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

    $ConfigFile = Join-Path $ConfigPath "gateway.json"
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
    $LowerName = "gateway"
    $CompanyName = "Devolutions"

	if (Get-IsWindows)	{
		$GlobalPath = $Env:ProgramData + "\${CompanyName}\${DisplayName}"
	} elseif ($IsMacOS) {
		$GlobalPath = "/Library/Application Support/${DisplayName}"
	} elseif ($IsLinux) {
		$GlobalPath = "/etc/${LowerName}"
	}

	switch ($PathType) {
        'ConfigPath' { $GlobalPath }
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
    $Config.GatewayListeners
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

    $CertificateFile = Join-Path $ConfigPath "certificate.pem"
    $PrivateKeyFile = Join-Path $ConfigPath "certificate.key"

    Set-Content -Path $CertificateFile -Value $CertificateData -Force
    Set-Content -Path $PrivateKeyFile -Value $PrivateKeyData -Force

    $Config.CertificateFile = "certificate.pem"
    $Config.PrivateKeyFile = "certificate.key"

    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Get-DGatewayService
{
    param(
        [string] $ConfigPath,
        [DGatewayConfig] $Config
    )

    if ($config.DockerPlatform -eq "linux") {
        $PathSeparator = "/"
        $ContainerDataPath = "/etc/jet-relay"
    } else {
        $PathSeparator = "\"
        $ContainerDataPath = "c:\jet-relay"
    }

    $Service = [DockerService]::new()
    $Service.ContainerName = 'devolutions-jet'
    $Service.Image = $config.DockerImage
    $Service.Platform = $config.DockerPlatform
    $Service.Isolation = $config.DockerIsolation
    $Service.RestartPolicy = $config.DockerRestartPolicy
    $Service.TargetPorts = @(10256)

    foreach ($JetListener in $config.GatewayListeners) {
        $ListenerUrl = ([string[]] $($JetListener -Split ','))[0]
        $url = [System.Uri]::new($ListenerUrl)
        $Service.TargetPorts += @($url.Port)
    }

    $Service.PublishAll = $true
    $Service.Environment = [ordered]@{
        "JET_INSTANCE" = $config.GatewayHostname;
        "JET_UNRESTRICTED" = "true";
        "RUST_BACKTRACE" = "1";
        "RUST_LOG" = "info";
    }
    $Service.Volumes = @("${ConfigPath}:${JetRelayDataPath}")
    $Service.External = $false

    if (Test-Path "${ConfigPath}/certificate.pem" -PathType 'Leaf') {
        $Service.Environment['JET_CERTIFICATE_FILE'] = @($ContainerDataPath, 'certificate.pem') -Join $PathSeparator
    }

    if (Test-Path "${ConfigPath}/certificate.key" -PathType 'Leaf') {
        $Service.Environment['JET_PRIVATE_KEY_FILE'] = @($ContainerDataPath, 'certificate.key') -Join $PathSeparator
    }

    $CommandArgs = @()
    foreach ($JetListener in $config.GatewayListeners) {
        $CommandArgs += @('-l', "`"$JetListener`"")
    }

    $Service.Command = $($CommandArgs -Join " ")

    return $Service
}

function Update-DGatewayImage
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $config = Get-DGatewayConfig -ConfigPath:$ConfigPath
    Expand-DGatewayConfig -Config $config

    $Service = Get-JetService -ConfigPath:$ConfigPath -Config:$config
    Request-ContainerImage -Name $Service.Image
}

function Start-DGateway
{
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $config = Get-DGatewayConfig -ConfigPath:$ConfigPath
    Expand-DGatewayConfig -Config $config

    $Service = Get-JetService -ConfigPath:$ConfigPath -Config:$config

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
    $config = Get-DGatewayConfig -ConfigPath:$ConfigPath
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
    New-DGatewayListener, Get-DGatewayListeners, `
    Get-DGatewayPath, Import-DGatewayCertificate, `
    Start-DGateway, Stop-DGateway, Restart-DGateway, `
    Get-DGatewayImage, Update-DGatewayImage
