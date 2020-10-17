Import-Module "$PSScriptRoot/../DevolutionsGateway"

Describe 'Devolutions Gateway config' {
	InModuleScope DevolutionsGateway {
		Context 'Fresh environment' {
			It 'Creates basic configuration' {
				$ConfigPath = Join-Path $TestDrive 'Gateway'
				Set-DGatewayConfig -ConfigPath:$ConfigPath -GatewayHostname 'gateway.local'
				$(Get-DGatewayConfig -ConfigPath:$ConfigPath).GatewayHostname | Should -Be 'gateway.local'
			}
			It 'Sets gateway listeners' {
				$ConfigPath = Join-Path $TestDrive 'Gateway'
				$HttpListener = New-DGatewayListener -ListenerUrl 'http://*:4040' -ExternalUrl 'http://*:4040'
				$WsListener = New-DGatewayListener -ListenerUrl 'ws://*:4040' -ExternalUrl 'ws://*:4040'
				$TcpListener = New-DGatewayListener -ListenerUrl 'tcp://*:4041' -ExternalUrl 'tcp://*:4041'
				$ExpectedListeners = @($HttpListener, $WsListener, $TcpListener)

				Set-DGatewayConfig -ConfigPath:$ConfigPath -GatewayListeners $ExpectedListeners
				$ActualListeners = Get-DGatewayListeners -ConfigPath:$ConfigPath
				$ExpectedListeners.Count | Should -Be $ActualListeners.Count
			}
		}
	}
}
