Import-Module "$PSScriptRoot/../DevolutionsGateway"

Describe 'Devolutions Gateway config' {
	InModuleScope DevolutionsGateway {
		Context 'Fresh environment' {
			It 'Creates basic configuration' {
				$ConfigPath = Join-Path $TestDrive 'Gateway'
				Set-DGatewayConfig -ConfigPath:$ConfigPath -GatewayHostname 'gateway.local' -DockerRestartPolicy 'no'
				$(Get-DGatewayConfig -ConfigPath:$ConfigPath).GatewayHostname | Should -Be 'gateway.local'
			}
			It 'Sets gateway listeners' {
				$ConfigPath = Join-Path $TestDrive 'Gateway'
				$HttpListener = New-DGatewayListener 'http://*:4040' 'http://*:4040'
				$WsListener = New-DGatewayListener 'ws://*:4040' 'ws://*:4040'
				$TcpListener = New-DGatewayListener 'tcp://*:4041' 'tcp://*:4041'

				$ExpectedListeners = @($HttpListener, $WsListener, $TcpListener)
				Set-DGatewayConfig -ConfigPath:$ConfigPath -GatewayListeners $ExpectedListeners
				$ActualListeners = Get-DGatewayListeners -ConfigPath:$ConfigPath
				$ExpectedListeners.Count | Should -Be $ActualListeners.Count

				$ExpectedListeners = @($HttpListener, $TcpListener)
				Set-DGatewayListeners -ConfigPath:$ConfigPath $ExpectedListeners
				$ActualListeners = Get-DGatewayListeners -ConfigPath:$ConfigPath
				$ExpectedListeners.Count | Should -Be $ActualListeners.Count
			}
			It 'Starts Gateway' {
				$ConfigPath = Join-Path $TestDrive 'Gateway'
				Start-DGateway -ConfigPath:$ConfigPath -Verbose
			}
			It 'Stops Gateway' {
				$ConfigPath = Join-Path $TestDrive 'Gateway'
				Stop-DGateway -ConfigPath:$ConfigPath -Verbose
			}
		}
	}
}
