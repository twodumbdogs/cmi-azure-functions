# func-glogsb PowerShell Functions

This folder contains the PowerShell Azure Function App for the CMI Service Bus subscriber flow.

Outbound HTTP payload intake is handled by the .NET Function App in `../func-glogsb-net`. The old PowerShell `cmi-outbound` HTTP function was removed so the outbound payload is not sent to Integration Builder twice.

## Functions

- `cmi-subscribe-client-us`: Service Bus subscriber for US client messages.
- `cmi-subscribe-matter-us`: Service Bus subscriber for US matter messages.
- `cmi-subscribe-payor-us`: Service Bus subscriber for US payor messages.
- `cmi-subscribe-client-can`: Service Bus subscriber for Canada client messages.
- `cmi-subscribe-matter-can`: Service Bus subscriber for Canada matter messages.
- `cmi-subscribe-payor-can`: Service Bus subscriber for Canada payor messages.
- `cmi-subscribe-errors-emea`: Service Bus subscriber for EMEA error messages.
- `cmi-subscribe-cmi-fails`: Service Bus subscriber for messages on the `cmi-fails` topic.
- `net-test-us`: HTTP diagnostic endpoint for DNS and outbound network testing.

## Common Integration Builder settings

Most functions that call Integration Builder use these app settings:

- `intapp__ibHost`: Integration Builder host name.
- `intapp__ibIp`: Optional IP used for TCP preflight checks.
- `intapp__ibToken`: Integration Builder authentication token.
- `intapp__ibThrottleSeconds`: Optional post-send delay. Defaults to 1 second when missing.

The regional subscriber functions use `intapp__rule_id_regional_subscribe`.

The `cmi-subscribe-cmi-fails` function uses `intapp__ibRuleId`.

## Service Bus connections and settings

Service Bus trigger and output bindings use these connection/settings names:

- `service_bus_RBAC`
- `us_sb`
- `can_sb`
- `emea_sb`
- `topicClientUS`
- `subClientUS`
- `topicMatterUS`
- `subMatterUS`
- `topicPayorUS`
- `subPayorUS`
- `topicClientCAN`
- `subClientCAN`
- `topicMatterCAN`
- `subMatterCAN`
- `topicPayorCAN`
- `subPayorCAN`
- `topicErrorEMEA`
- `subErrorEMEA`

## Throttling

`host.json` limits Service Bus trigger concurrency and disables prefetching. The IB-calling functions also pause after successful IB sends. See `IB_SEND_LIMITER.md` for details.

## Deployment

Use the single deploy script in this folder:

```powershell
.\deployme.ps1 -ResourceGroup "<resource-group>" -FunctionApp "<function-app>"
```

The script expects to deploy the folder containing `host.json`. When run from this folder, no `-ProjectPath` value is required.
