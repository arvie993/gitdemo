// Secure Azure AI (Foundry/ML Workspace) with CMK, Managed Identity, and secured dependencies

@description('Location for all resources')
param location string = resourceGroup().location

@minLength(2)
@maxLength(12)
@description('Prefix for resource names. Use letters/numbers. Will be lowercased where needed.')
param namePrefix string

@description('When false, public network access is disabled on supported resources. You should add private endpoints before disabling in production.')
param publicNetworkAccessEnabled bool = true

@description('Data retention (days) in Log Analytics workspace')
@minValue(7)
@maxValue(730)
param logAnalyticsRetentionDays int = 30

@description('Tags to apply to all resources')
param tags object = {
	environment: 'dev'
	workload: 'azure-ai-foundry'
}

var suffix = uniqueString(resourceGroup().id, namePrefix)
var pnaSetting = publicNetworkAccessEnabled ? 'Enabled' : 'Disabled'

// Name helpers honoring service constraints
var saName = toLower('st${take(suffix, 20)}') // 3-24 lowercase
// ACR must be 5-50 alphanumeric. Pad and trim to satisfy analyzer.
var acrBase = 'acr${replace(suffix, '-', '')}00000'
var acrName = toLower(take(acrBase, 50))
var kvName = toLower('${take(namePrefix, 10)}-kv-${take(suffix, 8)}') // 3-24, dashes ok
var lawName = toLower('${take(namePrefix, 14)}-law-${take(suffix, 6)}')
var uamiName = toLower('${take(namePrefix, 14)}-uai')
var amlName = '${take(namePrefix, 20)}-mlw'
var cmkKeyName = 'ml-cmk'

// User-assigned managed identity for CMK access
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
	name: uamiName
	location: location
	tags: tags
}

// Log Analytics workspace for diagnostics
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
	name: lawName
	location: location
	tags: tags
	properties: {
		sku: {
			name: 'PerGB2018'
		}
		retentionInDays: logAnalyticsRetentionDays
		publicNetworkAccessForIngestion: pnaSetting
		publicNetworkAccessForQuery: pnaSetting
	}
}

// Key Vault for CMK (using access policies to avoid hardcoding RBAC role IDs)
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
	name: kvName
	location: location
	tags: tags
	properties: {
		tenantId: tenant().tenantId
		sku: {
			family: 'A'
			name: 'standard'
		}
		enableSoftDelete: true
		softDeleteRetentionInDays: 90
		enablePurgeProtection: true
		// For production, consider enableRbacAuthorization = true and assign data-plane roles instead of access policies
		enableRbacAuthorization: false
		publicNetworkAccess: toLower(pnaSetting)
		networkAcls: {
			bypass: 'AzureServices'
			defaultAction: publicNetworkAccessEnabled ? 'Allow' : 'Deny'
			ipRules: []
			virtualNetworkRules: []
		}
		accessPolicies: [
			// Grant the UAMI permission to use CMK (get/wrap/unwrap) for AML encryption
			{
				tenantId: tenant().tenantId
				objectId: uami.properties.principalId
				permissions: {
					keys: [
						'get'
						'wrapKey'
						'unwrapKey'
					]
					secrets: []
					certificates: []
					storage: []
				}
			}
		]
	}
}

// Create an RSA key for CMK
resource kvKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
	name: cmkKeyName
	parent: kv
	properties: {
		kty: 'RSA'
		keySize: 3072
		keyOps: [ 'encrypt', 'decrypt', 'wrapKey', 'unwrapKey' ]
	}
}

// Storage Account for AML workspace
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
	name: saName
	location: location
	tags: tags
	sku: {
		name: 'Standard_ZRS'
	}
	kind: 'StorageV2'
	properties: {
		supportsHttpsTrafficOnly: true
		minimumTlsVersion: 'TLS1_2'
		allowBlobPublicAccess: false
		isHnsEnabled: true // Hierarchical namespace required for AML features
		allowSharedKeyAccess: false
		publicNetworkAccess: pnaSetting
		networkAcls: {
			defaultAction: publicNetworkAccessEnabled ? 'Allow' : 'Deny'
			bypass: 'AzureServices'
			ipRules: []
			virtualNetworkRules: []
			resourceAccessRules: []
		}
		encryption: {
			keySource: 'Microsoft.Storage'
			requireInfrastructureEncryption: true
			services: {
				blob: {
					enabled: true
					keyType: 'Account'
				}
				file: {
					enabled: true
					keyType: 'Account'
				}
			}
		}
	}
}

// Azure Container Registry for AML images
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
	name: acrName
	location: location
	tags: tags
	sku: {
		name: 'Premium'
	}
	properties: {
		adminUserEnabled: false
		publicNetworkAccess: pnaSetting
		networkRuleSet: publicNetworkAccessEnabled ? null : {
			defaultAction: 'Deny'
			ipRules: []
		}
		policies: {
			retentionPolicy: {
				status: 'enabled'
				days: 30
			}
		}
	}
}

// Azure AI/ML Workspace (aka Azure AI Foundry workspace)
resource aml 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
	name: amlName
	location: location
	tags: union(tags, {
	hbi: 'true'
	})
	identity: {
		type: 'SystemAssigned,UserAssigned'
		userAssignedIdentities: {
			'${uami.id}': {}
		}
	}
	properties: {
		friendlyName: amlName
		description: 'Secure Azure AI workspace with CMK and managed identity'
		hbiWorkspace: true
		keyVault: kv.id
		storageAccount: sa.id
		containerRegistry: acr.id
		publicNetworkAccess: pnaSetting
		// Restrict outbound to approved destinations (you can add rules as needed)
		managedNetwork: {
			isolationMode: 'AllowOnlyApprovedOutbound'
		}
		encryption: {
			status: 'Enabled'
			keyVaultProperties: {
				// Use a versionless key identifier; you can update to a versioned URI later for key rotation pinning
				keyIdentifier: '${kv.properties.vaultUri}keys/${cmkKeyName}'
				keyVaultArmId: kv.id
			}
			identity: {
				userAssignedIdentity: uami.id
			}
		}
	}
	dependsOn: [ kvKey ]
}

// Optional: diagnostic settings wiring to Log Analytics (categories vary by RP; enable as needed)
@description('Set to true to create minimal diagnostic settings to Log Analytics (categories must exist per RP).')
param enableDiagnostics bool = false

resource amlDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableDiagnostics) {
	name: 'aml-diag'
	scope: aml
	properties: {
		workspaceId: law.id
		logs: []
		metrics: []
	}
}

output workspaceName string = aml.name
output workspaceResourceId string = aml.id
output keyVaultName string = kv.name
output storageName string = sa.name
output containerRegistryName string = acr.name
