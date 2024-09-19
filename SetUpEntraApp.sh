# Create the final application display name
AppDisplayName="Split Experimentation -express provisioning"

SplitResourceProviderApplicationId="d3e90440-4ec9-4e8b-878b-c89e889e9fbc"

AzureCliApplicationId="04b07795-8ddb-461a-bbee-02f9e1bf7b46"

function Setup-SplitExperimentationEntraApp() {
    ###########
    ## Context
    ###########

    az account show >/dev/null 2>/dev/null

    if [[ $? -ne 0 ]]; then
        az login
    fi

    managedIdentityObjectId=$(Get-ManagedIdentityObjectId)

    Grant-GraphApiPermission "$managedIdentityObjectId"

    ###########
    ## Get or create app
    ###########

    echo "Checking for existence of Entra ID app"

    app=$(Get-SplitApp)

    if [ -z "$app" ]; then
        echo "Creating Entra ID app"

        az ad app create --display-name "$AppDisplayName"

        app=$(Get-SplitApp)
    fi


    ###########
    ## Create sp if non-existent
    ###########

    echo "Checking for existence of Entra ID service principal"

    sp=$(Get-SplitSp)

    if [ -z "$sp" ]
    then
        echo "Creating service principal"

        az ad sp create --id "$app.id"
    fi

    ###########
    ## App role
    ###########

    echo "Checking for existence of app role"

    role=$(echo "$app.appRoles" | grep -E "ExperimentationDataOwner")

    if [ -z "$role" ]
    then
        echo "Creating app role"

        Add-AppRole "$app.id"
    fi

    app=$(Get-SplitApp)

    ###########
    ## ID URIs
    ###########

    echo "Checking for existence of ID URI"

    idUriValue="api://$app.appId"

    idUri=$(echo "$app.identifierUris" | grep -E "$idUriValue")

    if [ -z "$idUri" ]
    then
        echo "Creating ID URI"

        az ad app update --id "$app.id" --identifier-uris "api://$app.appId"
    fi

    app=$(Get-SplitApp)

    ###########
    ## Scopes
    ###########

    echo "Checking for API scopes"

    perm=$(echo "$app.api.oauth2PermissionScopes" | grep -E "user_impersonation")

    if [ -z "$perm" ]; then
        echo "Creating API scope"


        Add-ApiScope "$app.id"
    fi

    app=$(Get-SplitApp)

    ###########
    ## Preauthorize Split resource provider
    ###########

    echo "Checking for Split RP preauthorization"

    authorization=$(echo "$app.api.preAuthorizedApplications" | jq -r '.[] | select(.appId == "'"$SplitResourceProviderApplicationId"'")')

    if [ -z "$authorization" ]; then
        echo "Setting up Split RP preauthorization for Entra ID token acquisition"

        perm=$(echo "$app.api.oauth2PermissionScopes" | jq -r '.[] | select(.value == "user_impersonation")')

        Preauthorize-SplitResourceProvider "$app.id" "$(echo "$perm" | jq -r '.id')"
    fi

    app=$(Get-SplitApp)

    ###########
    ## Preauthorize Azure CLI
    ###########

    echo "Checking for Azure CLI preauthorization"

    authorization=$(echo "$app.api.preAuthorizedApplications" | jq -r '.[] | select(.appId == "'"$AzureCliApplicationId"'")')

    if [ -z "$authorization" ]; then
        echo "Setting up Azure CLI preauthorization for Entra ID token acquisition"

        Confirm-IsOwner "$app.id" "$userObjectId"

        perm=$(echo "$app.api.oauth2PermissionScopes" | jq -r '.[] | select(.value == "user_impersonation")')

        Preauthorize-AzureCli "$app.id" "$(echo "$perm" | jq -r '.id')"
    fi

    app=$(Get-SplitApp)

    ###########
    ## Required resource access
    ###########

    echo "Checking for required resource access configuration"

    if [[ $(echo "$app.requiredResourceAccess" | jq 'length') -eq 0 ]]; then
        echo "Establishing required resource access"

        Add-RequiredResourceAccess "$app.id"
    fi

    app=$(Get-SplitApp)

    ###########
    ## Role assignment
    ###########

    # echo "Checking role assignment for experimentation data owner"

    # sp=$(Get-SplitSp)

    # tenantId=$(az account show | jq -r '.tenantId')

    # appRoleId=$(echo "$app.appRoles" | jq -r '.[] | select(.Value == "ExperimentationDataOwner") | .id')

    # roleAssignments=$(Get-AppRoleAssignments "$tenantId" "$sp.id")

    # roleAssignment=$(echo "$roleAssignments.Value" | jq -r '.[] | select(.id == "'"$appRoleId"'")')

    # if [ -z "$roleAssignment" ]; then
    #     echo "Creating role assignment for experimentation data owner"

    #     Confirm-IsOwner "$app.id" "$userObjectId"

    #     Add-AppRoleAssignment "$tenantId" "$sp.id" "$appRoleId" "$userObjectId"
    # fi
}

function Add-AppRole() {
    local objectId=$1
    local app
    app=$(Get-SplitApp)

    local appRole='{
        "allowedMemberTypes": [
            "User",
            "Application"
        ],
        "description": "data owner",
        "displayName": "ExperimentationDataOwner",
        "isEnabled": true,
        "value": "ExperimentationDataOwner"
    }'

    local appRoles=()

    for role in $(echo "$app" | jq -c '.appRoles[]'); do
        appRoles+=("$role")
    done

    appRoles+=("$appRole")

    app=$(echo "$app" | jq --argjson roles "$(printf '%s\n' "${appRoles[@]}" | jq -s .)" '.appRoles = $roles')

    az ad app update --id "$objectId" --app-roles "$(echo "$app" | jq -c '.appRoles' | tr -d '\r\n' | sed 's/"/\\"/g')"
}

function Add-ApiScope() {
    local objectId=$1
    local app
    app=$(Get-SplitApp)

    local permissionId
    permissionId=$(uuidgen)

    local permission
    permission=$(cat <<EOF
    {
        "adminConsentDescription": "Allows access to the split experimentation workspace",
        "adminConsentDisplayName": "Split Experimentation Access",
        "isEnabled": true,
        "id": "$permissionId",
        "type": "Admin",
        "userConsentDescription": "Allows access to the split experimentation workspace",
        "userConsentDisplayName": "Split Experimentation Access",
        "value": "user_impersonation"
    }
EOF
)

    local permissions=()
    local scopes=app.api.oauth2PermissionScopes

    for perm in "${app.api.oauth2PermissionScopes[@]}"; do
        permissions+=("$perm")
    done

    permissions+=("$permission")

    scopes=("${permissions[@]}")

    local str
    str=$(echo "${app.api}" | jq -c . | tr -d '\r\n' | sed 's/"/\\"/g')

    az ad app update --id "$objectId" --set api="$str"
}

function Preauthorize_SplitResourceProvider() {
    local objectId=$1
    local permissionId=$2

    local app=$(Get-SplitApp)

    local rpPreauthorization=(
        "appId=${SplitResourceProviderApplicationId}"
        "delegatedPermissionIds=(${permissionId})"
    )

    local preauthorizations=()
    local preAuthorizedApplications=app.api.preAuthorizedApplications

    for item in "${app.api.preAuthorizedApplications[@]}"; do
        preauthorizations+=("$item")
    done

    preauthorizations+=("${rpPreauthorization[@]}")

    preAuthorizedApplications=("${preauthorizations[@]}")

    local str=$(echo "${app.api}" | jq -c . | tr -d '\r\n' | sed 's/"/\\"/g')

    az ad app update --id "$objectId" --set "api=$str"
}

function Preauthorize_AzureCli() {
    local objectId=$1
    local permissionId=$2

    local app=$(Get-SplitApp)

    local cliPreauthorization=(
        "appId=$AzureCliApplicationId"
        "delegatedPermissionIds=($permissionId)"
    )

    local preauthorizations=()
    local preAuthorizedApplications=app.api.preAuthorizedApplications

    for item in "${app.api.preAuthorizedApplications[@]}"; do
        preauthorizations+=("$item")
    done

    preauthorizations+=("${cliPreauthorization[@]}")

    preAuthorizedApplications=("${preauthorizations[@]}")

    local str=$(echo "${app.api}" | jq -c . | sed 's/\r//g; s/\n//g; s/"/\\\"/g')

    az ad app update --id "$objectId" --set "api=$str"
}

function Add-RequiredResourceAccess() {
    local objectId=$1
    local app=$(Get-SplitApp)

    local rra='{
        "resourceAppId": "00000003-0000-0000-c000-000000000000",
        "resourceAccess": [
            {
                "id": "e1fe6dd8-ba31-4d61-89e7-88639da4683d",
                "type": "Scope"
            }
        ]
    }'

    local rras=()
    local requiredResourceAccess=app.requiredResourceAccess

    for item in "${app.requiredResourceAccess[@]}"; do
        rras+=("$item")
    done

    rras+=("$rra")

    requiredResourceAccess=("${rras[@]}")

    local str=$(echo "${app.requiredResourceAccess[@]}" | jq -c . | tr -d '\r\n' | sed 's/"/\\"/g')

    az ad app update --id "$objectId" --set "requiredResourceAccess=$str"
}

function Get-SplitApp() {
    apps=$(az ad app list --display-name "$AppDisplayName" | jq -c '.')
    
    if [[ $(echo "$apps" | jq 'length') -eq 0 ]]; then
        return
    fi

    echo "$apps" | jq '.[0]'
}

function Get-SplitSp() {
    sps=$(az ad sp list --display-name "$AppDisplayName" | jq -c '.')
    
    if [[ $(echo "$sps" | jq 'length') -eq 0 ]]; then
        return
    fi

    echo "$sps" | jq '.[0]'
}

function  Get-AppRoleAssignments() {
    local tenantId=$1
    local appObjectId=$2
    az rest --method GET --uri "https://graph.windows.net/$tenantId/servicePrincipals/$appObjectId/appRoleAssignments?api-version=1.6" | jq .
}

function Add-AppRoleAssignment() {
    local tenantId=$1
    local appObjectId=$2
    local appRoleId=$3
    local userObjectId=$4
    local BODY="{\"id\":\"$appRoleId\",\"principalId\":\"$userObjectId\",\"resourceId\":\"$appObjectId\"}"

    az rest --method post --uri "https://graph.windows.net/$tenantId/servicePrincipals/$appObjectId/appRoleAssignments?api-version=1.6" --body "$BODY" --headers "Content-type=application/json"
}

function Confirm-IsOwner() {
    local appObjectId=$1
    local userObjectId=$2
    local owners=$(az ad app owner list --id $appObjectId | jq .)

    local owner=$(echo $owners | jq --arg userObjectId "$userObjectId" '.[] | select(.id == $userObjectId)')

    if [ -z "$owner" ]; then
        local u=$(az ad signed-in-user show | jq .)
        echo "The caller $(echo $u | jq -r .userPrincipalName) is not listed as an owner of the application $appObjectId. Ownership is required to perform setup." >&2
        exit 1
    fi
}

function Get-AzureTenantId() {
    az account show --query tenantId
}

function Get-ManagedIdentityObjectId() {
    az account show --query user.principalId --output tsv
}

function Grant-GraphApiPermission() {
    managedIdentityObjectId=$1
    tenantId=$(Get-AzureTenantId)

    graphAppId='00000003-0000-0000-c000-000000000000' # This is a well-known Microsoft Graph application ID.
    graphApiAppRoleName='Application.ReadWrite.All'
    graphApiApplication=$(az ad sp list --filter "appId eq '$graphAppId'" --query "{ appRoleId: [0] .appRoles [?value=='$graphApiAppRoleName'].id | [0], objectId:[0] .id }" -o json)

    # Get the app role for the Graph API.
    graphServicePrincipalObjectId=$(jq -r '.objectId' <<< "$graphApiApplication")
    graphApiAppRoleId=$(jq -r '.appRoleId' <<< "$graphApiApplication")

    # Assign the role to the managed identity.
    requestBody=$(jq -n \
                    --arg id "$graphApiAppRoleId" \
                    --arg principalId "$managedIdentityObjectId" \
                    --arg resourceId "$graphServicePrincipalObjectId" \
                    '{id: $id, principalId: $principalId, resourceId: $resourceId}' )
    az rest -m post -u "https://graph.windows.net/$tenantId/servicePrincipals/$managedIdentityObjectId/appRoleAssignments?api-version=1.6" -b "$requestBody"
}

Setup-SplitExperimentationEntraApp