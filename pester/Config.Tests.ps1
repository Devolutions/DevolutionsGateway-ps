Import-Module "$PSScriptRoot/../DevolutionsGateway"

Describe 'Devolutions Gateway config' {
	InModuleScope DevolutionsGateway {
		Context 'Fresh environment' {
			It 'Creates basic configuration' {
				$ConfigPath = Join-Path $TestDrive 'Gateway'
				Set-DGatewayConfig -ConfigPath:$ConfigPath -GatewayHostname 'gateway.local'
				$(Get-DGatewayConfig -ConfigPath:$ConfigPath).GatewayHostname | Should -Be 'gateway.local'
			}
		}
	}
}
