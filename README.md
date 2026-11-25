# Private Microsoft Foundry landing zone

Modular Bicep for a **single-subscription, Azure public-cloud hub/spoke lab**. All workload data endpoints are private. Public Azure Bastion is the sole inbound entry point. The jumpbox has no public IP, and Azure Firewall has no DNAT rules.

**This repository does not deploy anything automatically.** Review configuration, costs, licensing, regional availability, quota, and what-if output before using `-Apply`.

## Architecture and security boundaries

| Resource group | Resources |
| --- | --- |
| Hub | Hub VNet, Bastion Standard, outbound Azure Firewall Standard and policy, private Windows 11 jumpbox, NSGs, jumpbox route table |
| Spoke | Peered spoke VNet, dedicated Foundry agent subnet, private endpoint subnet/NSG, Foundry account/default project/models, Storage, Cosmos DB for NoSQL, AI Search, Key Vault, private DNS, Log Analytics, Application Insights, Azure Monitor Private Link Scope |

Default network layout:

| Network/subnet | CIDR |
| --- | --- |
| Hub | `10.10.0.0/16` |
| `AzureBastionSubnet` | `10.10.0.0/26` |
| `AzureFirewallSubnet` | `10.10.1.0/26` |
| `snet-jumpbox` | `10.10.2.0/24` |
| Spoke | `10.20.0.0/16` |
| `snet-agents`, delegated to `Microsoft.App/environments` | `10.20.0.0/24` |
| `snet-private-endpoints` | `10.20.1.0/24` |

The jumpbox NIC and spoke VNet use the hub firewall's DNS proxy. The proxy forwards to Azure DNS (`168.63.129.16`). Every private DNS zone is linked to **both VNets**; peering alone does not provide private DNS resolution. Private endpoint DNS zone groups create the service records, including Cosmos DB global/regional records and the three Foundry domains.

Jumpbox and agent default routes send public-destination egress through the hub firewall. More-specific VNet/peering/private endpoint routes remain direct; private service traffic is not forced through the firewall. The private endpoint NSG allows HTTPS from the jumpbox subnet and TCP from the delegated agent subnet, then denies other inbound traffic. Agent TCP access includes Cosmos DB direct-mode ports. No customer NSG is attached to the platform-delegated agent subnet: avoid breaking platform provisioning with undocumented intra-subnet rules; its egress is controlled by the UDR/firewall and its resource access by private endpoints/RBAC.

**Important limitations of "private":**

- Private endpoints protect **data-plane access**, not the public Azure management plane, Entra authentication, or the portal website. Authorized administrators can still manage resources using ARM from outside these VNets.
- Bastion has a public HTTPS IP. Firewall has a second public IP for outbound SNAT only; it does not expose the VM or spoke. Bastion retains its required Azure control-plane/certificate-validation egress and has no forced-tunnel route table.
- Foundry is a managed PaaS service, not a customer-owned VM inside the VNet. Account-level network injection attaches agent networking to the dedicated subnet; projects inherit account inbound restrictions.
- Azure platform traffic, such as VM metadata, DNS and the VM agent, is a necessary platform exception. This is **not an air-gapped deployment**.
- Firewall application rules allow only documented baseline authentication/platform endpoints, portal/tool-download endpoints, Windows Update and explicit additions. They do not allow arbitrary web browsing. No TLS interception is configured, including when Premium is selected.
- `GlobalStandard` model processing can occur outside `westus3`. Private networking does **not** impose regional model processing residency.
- The model deployments belong to the **Foundry account**; the default project uses that account. They are not independent project-scoped deployments.
- Standard Agent Service uses the private BYO Storage, Cosmos DB and AI Search through **capability settings**. It does not use API-key connections or trusted-service network bypass.
- The private Key Vault is for **application/workload secrets**; the project identity can read secrets there. Foundry's capability-settings schema has no customer Key Vault binding. This template does not claim to replace Foundry's platform-managed internal vault, and does not enable customer-managed encryption keys.
- Only **Blob** storage is used by this standard setup. File, Queue and Table are not exposed publicly either, but have no private endpoints and are unavailable to clients until their endpoints/DNS are explicitly added.
- Search indexing/vector-store access through Foundry is in scope. Standalone Search indexers calling other private resources, integrated vectorization, hosted-agent container registries, external tools, VPN/ExpressRoute and additional spokes require their own configuration. Do not enable trusted-service bypass to work around these limitations.

## Repository layout

```text
infra\
  main.bicep                 Subscription-scoped staged orchestration
  config.default.json        Nonsecret defaults
  types.bicep                Shared typed configuration contract
  modules\
    hub.bicep                Hub networking and entry orchestration
    firewall.bicep            Approved egress policy and DNS proxy
    jumpbox.bicep             Private Windows VM and Entra login
    foundation.bicep          Spoke/dependency orchestration
    spoke-network.bicep       Delegation, routes, endpoint NSG
    peering.bicep             Reusable directional peering
    private-dns.bicep         Shared zones and both VNet links
    private-endpoint.bicep    Reusable endpoint and zone group
    storage.bicep             Private Blob storage
    cosmos.bicep              Private NoSQL account
    search.bicep              Private RBAC-only AI Search
    key-vault.bicep           Private RBAC vault with purge protection
    monitoring.bicep          Private workspace, App Insights and AMPLS
    hub-diagnostics.bicep     Bastion/firewall diagnostic export
    foundry.bicep             Account, project, model deployments
    foundry-project.bicep     Isolated project creation with explicit BYO stores
    runtime-access.bicep      Container/database-scoped runtime roles
    project-provisioning-access.bicep  Dedicated control-plane roles for explicit-host provisioning
    project-capability-host.bicep      Additive explicit-host recovery without project/account updates
scripts\
  Common.ps1                  Configuration and CLI helpers
  Preflight.ps1               Permissions, providers, models and VM checks
  Deploy.ps1                  What-if by default; explicit -Apply
  Provision-ProjectRuntime.ps1 Guarded provisioning stage; healthy projects are a no-op
  Test-PrivateConnectivity.ps1 Private DNS/TCP/PNA checks from jumpbox
tests\
  Infrastructure.Tests.ps1   Offline regression and syntax checks
  Provisioning.Tests.ps1     Offline provisioning safety/ordering checks
```

## 1. Prerequisites and deployment permissions

Install [PowerShell 7.2 or newer](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows), [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli-windows) and [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install). Run the following in PowerShell from this repository:

```powershell
az login
# Select the subscription locally; no ID is written to repository configuration.
$subscriptionId = Read-Host 'Subscription ID'
az account set --subscription $subscriptionId
az bicep version
```

`az login` authenticates you; **it does not grant permissions**. This subscription-scoped template creates both resource groups, so use an interactive identity with effective subscription-scope **Contributor + Role Based Access Control Administrator**, or **Owner**. Activate eligible PIM roles first. Conditions on role-assignment permissions, deny assignments, Azure Policy or provider-specific restrictions can still prevent deployment.

The foundation stage also grants the caller **Storage Blob Data Contributor** on the new storage account and **Cosmos DB Operator** on the new Cosmos account. The current Foundry capability-settings provisioning path needs these explicit permissions even if the caller can create resources. Wait for RBAC propagation before creating the project.

No subscription ID, tenant ID or user object ID is required in a committed configuration file. The scripts read the active subscription and resolve `az ad signed-in-user show` at runtime; Bicep uses `subscription().tenantId`. These values are visible to authorized users in Azure deployment history, not committed to Git. Built-in role-definition GUIDs in Bicep are public role identifiers, not your identity IDs.

The wrapper intentionally supports **interactive users on Windows only**. Service-principal/CI deployments need a separate wrapper and appropriate `principalType` changes; do not use an application/client ID in place of an object ID.

Windows 11 client images require [eligible Windows licensing rights](https://learn.microsoft.com/azure/virtual-machines/windows/client-images). Default image: `MicrosoftWindowsDesktop:windows-11:win11-24h2-pro:latest`, with `Windows_Client` license type and Trusted Launch. VM size defaults to `Standard_D2s_v4`. Both are configurable; check image availability, SKU restrictions and regional vCPU quota. The local bootstrap administrator/password is required to create a Windows VM, even though normal access uses Entra login. Keep that credential in your password manager; do not put it in JSON, Git or a command line.

## 2. Configure without committing identifiers or secrets

```powershell
Copy-Item .\infra\config.default.json .\infra\config.local.json
notepad .\infra\config.local.json
$configPath = '.\infra\config.local.json'
```

`config.local.json` is ignored by Git. It is a **complete configuration**, not a partial merge. Defaults are also safe to commit if you prefer editing `config.default.json`.

The `.gitignore` also excludes local deployment records/Azure CLI caches, credential exports, private keys, generated ARM JSON, logs and temporary files. Keep Bicep sources, default configuration, scripts, tests and documentation under version control. Ignore rules do not remove already-tracked files or replace secret scanning; review `git diff --cached` before publishing and never commit passwords or tokens.

| Setting | Default / purpose |
| --- | --- |
| `location` | `westus3`; parameterized for every regional resource |
| `workloadName`, `nameSuffix` | `ai`, `l7x2q9`; 1-6 lowercase alphanumeric characters each |
| `projectName` | `default-project` |
| `resourceNames` | Optional exact name overrides; keys match `resourceNames` deployment output |
| `tags` | Extra nonsecret tags; `deploymentSuffix` is added from `nameSuffix` |
| `network` | VNet/subnet names and CIDRs above; nonoverlapping RFC1918 only |
| `hub` | Bastion/firewall SKUs; extra approved jumpbox/agent FQDNs |
| `vm` | Size, OS image, disk, license, security type and bootstrap username |
| `services` | Storage/Search/Key Vault SKUs, Search scale, Cosmos throughput ceiling, log retention/cap |
| `models` | Deployment names, model names/versions, SKUs and capacity units |

The naming suffix is user-controlled. Globally unique resource names also include a stable, random-looking six-character hash derived from the subscription and naming stem. This is deterministic: repeated deployments with the same settings do not generate new names. For example, resource groups are `rg-ai-l7x2q9-hub` and `rg-ai-l7x2q9-spoke`; the storage name is `stail7x2q9<hash>`.

Changing a suffix/name after provisioning creates **another environment**, not a rename. Do not change immutable Foundry capability settings or injection subnet on an existing account/project. Use the same local configuration and signed-in identity for all stages. For extra team members, assign Foundry User and VM login roles explicitly; the wrapper grants access only to the deploying user.

## 3. Preflight and offline checks

```powershell
pwsh -NoProfile -File .\tests\Infrastructure.Tests.ps1
.\scripts\Preflight.ps1 -ConfigurationPath $configPath
# If providers need registration, this explicitly performs that change:
.\scripts\Preflight.ps1 -ConfigurationPath $configPath -RegisterProviders
```

Preflight checks effective deployment actions, required providers, regional model/version/SKU availability, model SKU minimum capacity, VM SKU restrictions and Gen2 image availability. It prints current OpenAI quota. **Quota is not reserved**: confirm the selected model/SKU quota has room for your capacities, and check VM-family vCPU quota and [Agent Service regional support](https://learn.microsoft.com/azure/foundry/agents/concepts/limits-quotas-regions). Capacity units and TPM/RPM ratios differ by model. Check Azure Policy using each stage's what-if.

The hub requires two public IP resources: Bastion ingress and Firewall outbound SNAT. A management-group policy denying public IPs blocks this design even when subscription permissions and preflight pass. Obtain an administrator-approved, narrowly scoped hub networking exception or explicitly revise the architecture before deployment; do not disable policy enforcement or enable public access on workload services.

`westus3` is a requested default, **not an availability guarantee**. The defaults are:

| Deployment/model | Version | SKU | Capacity |
| --- | --- | --- | --- |
| `text-embedding-3-large` | `1` | `GlobalStandard` | 10 |
| `gpt-5-nano` | `2025-08-07` | `GlobalStandard` | 10 |

If the region, model version, quota or SKU is unsupported for your subscription, change the configuration explicitly. The scripts never silently substitute a model, change regions, enable public access or downgrade security. Model versions are pinned with `NoAutoUpgrade`; plan upgrades before retirement dates.

Foundry uses **`2026-07-15-preview` capability settings**, per the current ARM contract. Older Bicep releases (including 0.46.1) compile the template but emit `BCP081` because their bundled types do not include this API. These warnings are not suppressed. Verify against current Microsoft documentation and run live ARM what-if/validation; offline compilation cannot prove that the preview API is available to your subscription. Most other resources use stable API versions.

## 4. Deploy the hub

```powershell
# No deployment occurs without -Apply. Both calls securely prompt for a bootstrap password.
.\scripts\Deploy.ps1 -Stage hub -ConfigurationPath $configPath
.\scripts\Deploy.ps1 -Stage hub -ConfigurationPath $configPath -Apply
```

This creates both resource-group containers and the hub resources only. The spoke group is initially empty. The hub creates Bastion, firewall policy/DNS proxy, private VM/NIC, Entra login extension, VM Administrator Login and hub Reader assignments. The jumpbox's default route is added after the firewall IP exists to avoid a circular dependency.

[Bastion's required NSG rules](https://learn.microsoft.com/azure/bastion/bastion-nsg) include outbound private SSH/RDP on ports 22 and 3389 to the `VirtualNetwork` service tag. The Windows jumpbox still permits inbound RDP only from the Bastion subnet; this platform-required Bastion rule does not expose the jumpbox publicly.

The `AADLoginForWindows` extension permits minor-version selection but does not support `enableAutomaticUpgrade: true`; the template omits that unsupported setting.

After a successful hub ARM deployment, the wrapper discovers the Azure-created OS disk and disables its unused export path (`networkAccessPolicy: DenyAll`, `publicNetworkAccess: Disabled`). This post-provisioning management step is necessary because those generated-disk settings are not exposed on the VM's Bicep resource. It leaves VM attachment and other disk settings unchanged, prevents SAS export through both public and private networking, and requires no disk private endpoint. Failure to enforce these settings fails the wrapper explicitly.

Passwords are passed through an ephemeral, current-user-only Windows-ACL parameter file. Bicep parameters are `@secure()`. The file is removed in `finally`; do not run with command tracing/transcripts that capture sensitive variables. Plaintext exists briefly in process memory because ARM needs the Windows bootstrap credential. The wrapper never saves a password into Key Vault or a deployment output.

## 5. Deploy the spoke foundation

```powershell
.\scripts\Deploy.ps1 -Stage foundation -ConfigurationPath $configPath
.\scripts\Deploy.ps1 -Stage foundation -ConfigurationPath $configPath -Apply
```

This requires a successful hub deployment. It creates the spoke VNet, both directional peerings, agent delegation/UDR, private endpoint NSG, private DNS links, private data services, caller provisioning roles and private monitoring. It also attaches hub diagnostics to the spoke Log Analytics workspace.

All service public access is disabled **from creation**, including during intermediate stages. Shared-key/local-key auth is disabled for Storage, Cosmos DB, Search and Foundry; Key Vault uses RBAC and has soft delete/purge protection. Purge protection cannot simply be turned off for cleanup.

The foundation creates five private endpoints: Blob, Cosmos SQL, Search, Key Vault and AMPLS. AMPLS includes the five required monitoring zones and shares the existing Blob DNS zone. Logs from Bastion, firewall, Blob, Cosmos, Search and Key Vault are exported through Azure diagnostic settings. Foundry diagnostics are added in its stage. Azure's diagnostic-export pipeline is platform-managed, not traffic from the VM through the firewall.

## 6. Connect to the jumpbox and prepare its tools

Open the VM in Azure portal, select **Connect > Bastion**, and choose **Microsoft Entra ID** authentication if available. It is a preview portal capability in some environments. Alternatively use Bastion's Standard native RDP client with Entra authentication:

```powershell
# On your local Windows workstation:
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$deploymentName = "$($config.workloadName)-$($config.nameSuffix)-hub"
$names = az deployment sub show --name $deploymentName --query properties.outputs.resourceNames.value -o json | ConvertFrom-Json
$vmId = az vm show --resource-group $names.hubResourceGroup --name $names.jumpbox --query id -o tsv
az network bastion rdp --name $names.bastion --resource-group $names.hubResourceGroup --target-resource-id $vmId --enable-mfa
```

Follow [Bastion Entra authentication prerequisites](https://learn.microsoft.com/azure/bastion/bastion-entra-id-authentication), including local device registration/join and conditional access. Keep the local bootstrap credential as a break-glass option through Bastion; do not add public RDP or open the jumpbox NSG to other sources.

Inside the VM, install PowerShell 7 and Azure CLI using their official installers, sign in with the **same user/subscription**, and transfer this repository plus the same nonsecret local configuration. Approved download endpoints include GitHub release assets and Microsoft download domains. If a download or portal blade needs another hostname, inspect firewall deny logs and add only that FQDN to `additionalJumpboxFqdns`, review what-if and reapply the hub. Do not allow `*` or temporarily enable public service access.

General browsing/search sites are intentionally blocked. Web egress permits TCP HTTP/HTTPS, not QUIC over UDP/443; a browser QUIC error on an unapproved site does not establish that approved HTTPS destinations are unreachable.

WinGet's community and Microsoft Store package-source endpoints are not in the baseline allowlist. A `Failed when opening source(s)` error can therefore be a network restriction rather than corrupted source configuration; do not reset sources or relax the firewall as a first response. Use the official installers instead. The [Azure CLI 64-bit MSI](https://aka.ms/installazurecliwindowsx64) redirects to the already-approved `azcliprod.blob.core.windows.net`. In an **administrator PowerShell** window inside the VM:

```powershell
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$installer = Join-Path $env:TEMP ("AzureCLI-{0}.msi" -f [guid]::NewGuid())
try {
    Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/installazurecliwindowsx64' -OutFile $installer
    $signature = Get-AuthenticodeSignature -FilePath $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
        throw 'Azure CLI installer Microsoft signature verification failed.'
    }
    $process = Start-Process msiexec.exe -ArgumentList "/i `"$installer`" /qn /norestart" -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "Azure CLI installation failed: MSI exit code $($process.ExitCode)." }
    if ($process.ExitCode -eq 3010) { Write-Warning 'MSI reported that a reboot is required; no reboot was initiated.' }
} finally {
    if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer }
}
```

Close and reopen PowerShell, then run `az version`. For PowerShell 7, use the Windows x64 MSI linked from the [official PowerShell GitHub releases](https://github.com/PowerShell/PowerShell/releases); its release asset host is already approved. Troubleshoot any further failures by their exact hostname without adding blanket internet access.

Azure CLI also needs HTTPS access to `downloads.bicep.azure.com` for Bicep version discovery and downloads when compiling deployment templates. This host is included in the jumpbox allowlist. On an older deployment missing it, review and apply the firewall rule update before running Bicep or deployment what-if; do not disable TLS certificate verification to work around an SSL EOF error.

The portal shell/resource-group list and individual resource blades use different download hosts. The jumpbox HTTPS rule includes the [documented portal hosting endpoints](https://learn.microsoft.com/azure/azure-portal/azure-portal-safelist-urls), including `hosting.portal.azure.net`, `hosting-ms.portal.azure.net`, their wildcard subdomains, `reactblade.portal.azure.net` and `hosting.partners.azure.net`. A wildcard such as `*.hosting.portal.azure.net` does **not** cover the base hostname. Missing these hosts can produce `Microsoft_Azure_ProjectOxford extension failed to load` for Foundry and similar failures for other resource blades, despite successful sign-in/resource listing. Use [Portal Self Help](https://portal.azure.com/selfhelp) or browser developer tools to identify failed requests, correct only the approved frontend allowlist, then hard-refresh the portal. Do not enable public access on workload services or allow blanket internet egress.

Run:

```powershell
az login
$subscriptionId = Read-Host 'Subscription ID'
az account set --subscription $subscriptionId
.\scripts\Test-PrivateConnectivity.ps1 -ConfigurationPath .\infra\config.local.json -FoundationOnly
```

This must resolve service names to **this environment's actual PE NIC addresses**, establish TCP/443, verify endpoint approvals and check public-access flags. Failure is a hard stop, not a reason to add IP allow lists.

## 7. Create Foundry and assign runtime access

Run from the jumpbox after caller RBAC has propagated:

```powershell
$configPath = '.\infra\config.local.json'
.\scripts\Deploy.ps1 -Stage foundry -ConfigurationPath $configPath
.\scripts\Deploy.ps1 -Stage foundry -ConfigurationPath $configPath -Apply -QuotaReviewed
# Verify provisioning, or preview/apply the isolated missing-host path:
.\scripts\Deploy.ps1 -Stage provisioning -ConfigurationPath $configPath
.\scripts\Deploy.ps1 -Stage provisioning -ConfigurationPath $configPath -Apply
# Assign scoped runtime roles only after provisioning reports ready:
.\scripts\Deploy.ps1 -Stage access -ConfigurationPath $configPath
.\scripts\Deploy.ps1 -Stage access -ConfigurationPath $configPath -Apply
```

The Foundry account is created with injection and all three BYO capability defaults. Its private endpoint registers Cognitive Services, OpenAI and Foundry service domains. The project explicitly declares the same three stores at creation instead of relying solely on inheritance. Successful ARM provisioning and shared connections do not by themselves prove that the project's underlying containers/databases were created; verify them before runtime access. Model deployments are serialized to avoid concurrent account updates.

**The stage order is `hub` → `foundation` → `foundry` → `provisioning` → `access`.** The project is not runtime-ready after `foundry` alone. `provisioning` checks the configured project's identity, bindings and actual backing stores before `access` assigns runtime roles. A healthy project is a read-only no-op, even with `-Apply`; do not redeploy earlier stages just to check provisioning.

The `access` wrapper independently verifies the selected project's store bindings, then reads its identity and discovers its generated file and agent containers through the Storage management API. It matches the project's workspace ID, including any service-generated suffix before `-azureml-agent`, and fails if its containers are missing/ambiguous. Containers belonging to other projects are not selected, and discovery never falls back to account-wide data-owner permissions.

### Guarded provisioning and the explicit-host path

If project creation succeeds but its GET response omits effective capability settings and no backing stores exist, the [documented backward-compatible project capability-host path](https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks#permissions) provides an additive alternative. Unlike capability-settings provisioning, it uses the **project managed identity**, not the deployment caller. The integrated `provisioning` stage supports this path deliberately, not as a blind retry after an error.

Without `-Apply`, the stage reads the current state and, only when provisioning is absent, previews both isolated resource-group-scoped Bicep templates. `-Apply` repeats the safety checks and previews before writing. It requires a successfully provisioned account/project, disabled Foundry public access, exactly one healthy account `Agents` host, three correctly bound AAD connections, and **no effective project capability settings, no project host and no project-owned backing data** before considering a host creation.

1. Apply `project-provisioning-access.bicep`: only **Storage Account Contributor** and **Cosmos DB Operator** for the selected project identity on the dedicated resources. Verify both exact-scope assignments, polling up to 30 times at 10-second intervals, then wait 60 seconds for propagation. Visibility and a delay cannot guarantee that every service has refreshed RBAC; a failed host apply is surfaced, not automatically retried.
2. Re-read the project and host list to reject concurrent configuration changes, repeat the host preview, then apply `project-capability-host.bicep`. Its only write is the missing project `Agents` host named `agents`, reusing the healthy account host's validated connection names. Previews permit only creates/no-changes, never modifications or deletions; permission creates must match the intended resource, principal and role.
3. Verify the healthy host and the service-created stores: the project's file/agent Blob containers and its three `enterprise_memory` Cosmos containers. Store readiness is polled up to 30 times at 10-second intervals. Only then proceed to the normal `access` preview/apply against the **same project configuration**. Provisioning-role GUIDs match the runtime template, so the control-plane assignments are reused.

A configured project with complete stores is verified and left untouched. Conflicting settings, an unhealthy/ambiguous host, incorrect AAD resource IDs/endpoints, partial data without bindings, or configured-but-incomplete stores fail closed. Wait for in-flight provisioning or investigate the existing configuration; the stage never creates a second host, overwrites immutable settings, manually creates substitute stores, grants account-wide Blob Data Owner, or recreates a project. A failed/uncertain deployment must be inspected before rerunning.

The provisioning stage does not alter account/project properties, models, networking, public-access restrictions, or another project. `Deploy.ps1` orchestrates its two standalone Bicep modules because live checks and RBAC propagation must separate them; `infra\main.bicep` remains responsible for the other four subscription-scoped stages and does not unconditionally mix provisioning paths. Both `access` and the full private-connectivity check continue to support verified effective settings or one healthy explicit host with matching AAD stores.

Runtime role assignments:

| Identity | Scope | Role |
| --- | --- | --- |
| Signed-in user | Hub/spoke resource groups | Reader |
| Signed-in user | Jumpbox VM | Virtual Machine Administrator Login |
| Signed-in user | Foundry project | Foundry User (formerly Azure AI User) |
| Signed-in user | Foundry account | Cognitive Services OpenAI User, for direct model calls |
| Provisioning caller | Dedicated Storage/Cosmos accounts | Storage Blob Data Contributor / Cosmos DB Operator |
| Project managed identity | Dedicated Storage/Cosmos accounts | Storage Account Contributor / Cosmos DB Operator (standard-setup control-plane roles) |
| Project managed identity | Generated file blob container | Storage Blob Data Contributor |
| Project managed identity | Generated agent blob container | Storage Blob Data Owner |
| Project managed identity | Cosmos `enterprise_memory` database | Cosmos DB Built-in Data Contributor (native Cosmos data RBAC, not Azure IAM) |
| Project managed identity | Dedicated Search service | Search Service Contributor + Search Index Data Contributor |
| Project managed identity | Workload Key Vault | Key Vault Secrets User |

The project receives no Owner/Contributor on the resource group. Blob data roles are container-scoped and Cosmos data access is database-scoped. Storage/Cosmos control-plane roles are broader because the standard setup requires them, but limited to dedicated resources. Key Vault readers cannot create/modify secrets; secret administrators need a separately approved Secrets Officer assignment. No key-vault access policies or connection secrets are generated.

RBAC propagation is asynchronous. A successful role-assignment deployment does not guarantee an immediate successful token/data operation; wait, refresh login/tokens, and run the smoke tests. Provisioning data roles on the caller can be removed by an administrator after project setup if no longer needed. The foundation stage will recreate them if redeployed.

## 8. Verify private networking and authenticated runtime

From the jumpbox:

```powershell
.\scripts\Test-PrivateConnectivity.ps1 -ConfigurationPath $configPath
```

The full check additionally verifies the Foundry endpoint and intended project stores through effective capability settings or a healthy, correctly bound explicit project host. DNS/TCP/PNA checks do **not** prove model quota, runtime data roles or every Agent Service tool works. Test both model calls using your Entra identity:

```powershell
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$deploymentName = "$($config.workloadName)-$($config.nameSuffix)-access"
$outputs = az deployment sub show --name $deploymentName --query properties.outputs -o json | ConvertFrom-Json
$modelEndpoint = $outputs.modelEndpoint.value.TrimEnd('/')
$token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
$embeddingDeployment = ($config.models | Where-Object modelName -eq 'text-embedding-3-large').deploymentName
$chatDeployment = ($config.models | Where-Object modelName -eq 'gpt-5-nano').deploymentName
Invoke-RestMethod -Method Post -Uri "$modelEndpoint/openai/deployments/$embeddingDeployment/embeddings?api-version=2024-10-21" `
    -Headers $headers -Body (@{ input = 'Private endpoint test' } | ConvertTo-Json)
Invoke-RestMethod -Method Post -Uri "$modelEndpoint/openai/deployments/$chatDeployment/chat/completions?api-version=2024-10-21" `
    -Headers $headers -Body (@{ messages = @(@{ role = 'user'; content = 'Reply with OK' }); max_completion_tokens = 512 } | ConvertTo-Json -Depth 10)
Remove-Variable token, headers
```

Use the Foundry portal **inside the jumpbox browser** to create a small test agent using `gpt-5-nano`, send a message, and verify the run completes. Then test an allowed file/vector-store workflow and inspect the BYO containers/indexes, to exercise Storage/Search/Cosmos runtime authorization rather than merely model inference. Respect [private Agent Service feature limitations](https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks#limitations); Code Interpreter file transfer has additional restrictions.

Query the private workspace from the jumpbox portal to confirm diagnostic ingestion. Application Insights is provisioned for application instrumentation but not automatically attached to an application or agent SDK. Because local instrumentation-key authentication is disabled, an instrumented application needs Entra authentication and **Monitoring Metrics Publisher** on this component; no application code/agent telemetry exporter is installed by this repository. Log queries require suitable workspace read permissions (the default RG Reader supports read operations; use Log Analytics Reader for dedicated log readers).

For an outside-network negative check, run DNS/TCP checks from your workstation and verify they cannot reach PE IPs. A public DNS response is normal outside the VNet, but an **authenticated** model call from that workstation must be rejected by Foundry's public-access restriction. An unauthenticated `401`/`403` is not sufficient evidence of network isolation. Do not copy tokens into logs or use production data for these checks.

## Direct Bicep usage

`main.bicep` is a subscription-scoped entry point, not a resource-group deployment. The wrappers build it through Azure CLI. If you prefer direct CLI, identities remain runtime variables:

```powershell
$userId = az ad signed-in-user show --query id -o tsv
az deployment sub what-if --location westus3 --name manual-foundry-review `
    --template-file .\infra\main.bicep `
    --parameters stage=foundry userObjectId=$userId config=@.\infra\config.local.json
```

For `hub`, supply the secure bootstrap password through a protected parameter file, never inline. For `access`, supply discovered `blobContainerName`, `agentContainerName` and `projectPrincipalId`. `provisioning` is a wrapper-orchestrated stage, not a `main.bicep` stage; use `Deploy.ps1` so its live guards, two isolated module previews, propagation wait and store verification are not bypassed. Use **incremental** deployments and the stage order above, not complete-mode deletion.

## Costs, operations and failure recovery

This is a secure lab baseline, **not a zero-cost or production-HA environment**. Always-on Bastion and Azure Firewall are usually the largest fixed-cost components. Budget for VM/disks, Search units, Cosmos RU/s, private endpoints, Log Analytics ingestion, model tokens and traffic. Use the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) before applying.

The Cosmos setting is an **account-wide throughput ceiling**, not a provisioned database RU/s setting. Foundry creates its own containers; published requirements differ between classic/new runtime containers. The default ceiling of 10,000 RU/s leaves room for the baseline and durable state container; inspect actual provisioned throughput and cost after creation. Search defaults to one basic replica and Storage to LRS; increase availability settings intentionally for production. Log retention defaults to 30 days with a 1 GB/day cap; the cap can interrupt logging and is not a strict billing guarantee. Enable budgets/alerts and size logging before production.

| Failure | Action |
| --- | --- |
| Missing role-assignment permission | Activate/grant Owner or Contributor plus RBAC Administrator; verify conditions and deny assignments |
| Foundry provisioning denied | Check caller Blob Data Contributor/Cosmos Operator and RBAC propagation; do not use keys/bypass |
| Model quota/availability | Review preflight and regional quotas; explicitly adjust capacity/region/SKU/version |
| DNS public inside VM | Verify NIC/spoke DNS proxy, hub DNS zone links, PE zone groups and both peerings |
| Portal, login or download blocked | Inspect `AZFWApplicationRule` deny logs from the jumpbox; approve only the required FQDN |
| Agent dependency denied | Inspect firewall rules for the agent subnet and project identity's data roles; confirm effective capability stores |
| Access-stage container discovery fails | Inspect project/capability provisioning and its generated containers; no broad-role fallback |
| Agent subnet service association remains after failure | Do not blindly redeploy networking or remove delegation; follow Foundry deletion/purge guidance |

Reapplying hub networking can briefly reset the separately deployed default route before recreating it. Reapplying the foundation after network injection may encounter platform service-association constraints: avoid gratuitous network PUTs and review what-if carefully. Changing immutable capability settings requires deliberate project recreation, not a retry loop. This repository contains no automatic destructive cleanup, account purge or mutation retries.

For teardown, stop usage and preserve required data/logs. Follow the service's supported order: remove project/agent capability resources, delete and **purge** the Foundry account to release the delegated subnet association, detach AMPLS scoped resources before deleting monitoring resources, then remove remaining spoke/hub resources and VNets last. Key Vault purge protection/retention may prevent immediate name reuse. Never force-remove the delegated subnet while Foundry still owns its association.

## Official references

- [Foundry private Agent Service networking](https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks)
- [Foundry networking architecture and subnet sizing](https://learn.microsoft.com/azure/foundry/agents/concepts/agents-networking-deep-dive)
- [Standard agent setup and runtime roles](https://learn.microsoft.com/azure/foundry/agents/concepts/standard-agent-setup)
- [Foundry account capability-settings ARM schema](https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/2026-07-15-preview/accounts)
- [Project capability-settings inheritance](https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/2026-07-15-preview/accounts/projects)
- [Foundry inbound network isolation](https://learn.microsoft.com/azure/foundry/how-to/configure-private-link)
- [Azure Firewall rules for delegated Container Apps networking](https://learn.microsoft.com/azure/container-apps/use-azure-firewall)
- [Azure Monitor Private Link configuration](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-configure)
- [Bastion required NSG rules](https://learn.microsoft.com/azure/bastion/bastion-nsg)
- [Bastion Entra authentication](https://learn.microsoft.com/azure/bastion/bastion-entra-id-authentication)

Offline compilation and checks do not replace a real deployment and authenticated Agent Service smoke test in your subscription. No live Azure deployment was performed when generating this repository.
