$tenantID='72f988bf-86f1-41af-91ab-2d7cd011db47'
$managedIdentityObjectId='e1ed6e2c-f380-4334-b7f5-3eaf210ca9de'

Connect-MgGraph -TenantId $tenantID

# Get the app role for the Graph API.
$graphAppId = '00000003-0000-0000-c000-000000000000' # This is a well-known Microsoft Graph application ID.
$graphApiAppRoleName = 'Application.ReadWrite.All'
$graphServicePrincipal = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
$graphApiAppRole = $graphServicePrincipal.AppRoles | Where-Object {$_.Value -eq $graphApiAppRoleName -and $_.AllowedMemberTypes -contains "Application"}

# Assign the role to the managed identity.
New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $managedIdentityObjectId `
  -PrincipalId $managedIdentityObjectId `
  -ResourceId $graphServicePrincipal.Id `
  -AppRoleId $graphApiAppRole.Id