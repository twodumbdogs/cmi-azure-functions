# func-glogsb PowerShell Functions

This folder contains the PowerShell Azure Function App for the CMI Service Bus and Integration Builder flow.

## Functions

- `cmi-outbound`: HTTP entry point that accepts JSON, routes known payloads to Service Bus topics, and notifies Integration Builder.
- `cmi-subscribe-client-us`: Service Bus subscriber for US client messages.
- `cmi-subscribe-matter-us`: Service Bus subscriber for US matter messages.
- `cmi-subscribe-payor-us`: Service Bus subscriber for US payor messages.
- `cmi-subscribe-errors-emea`: Service Bus subscriber for EMEA error messages.
- `cmi-subscribe-cmi-fails`: Service Bus subscriber for messages on the `cmi-fails` topic.
- `net-test-us`: HTTP diagnostic endpoint for DNS and outbound network testing.

## Common Integration Builder settings

Most functions that call Integration Builder use these app settings:

- `intapp__ibHost`: Integration Builder host name.
- `intapp__ibIp`: Optional IP used for TCP preflight checks.
- `intapp__ibToken`: Integration Builder authentication token.
- `intapp__ibThrottleSeconds`: Optional post-send delay. Defaults to 1 second when missing.

The outbound HTTP function uses `intapp__ibRuleId`.

The regional subscriber functions use `intapp__rule_id_regional_subscribe`.

The `cmi-subscribe-cmi-fails` function uses `intapp__ibRuleId`.

## Service Bus connections and settings

Service Bus trigger and output bindings use these connection/settings names:

- `service_bus_RBAC`
- `us_sb`
- `emea_sb`
- `topicClientUS`
- `subClientUS`
- `topicMatterUS`
- `subMatterUS`
- `topicPayorUS`
- `subPayorUS`
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
