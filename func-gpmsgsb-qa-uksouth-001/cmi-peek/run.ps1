param($Request, $TriggerMetadata)

# ==========================================
# HTTP GET -> peek/receive Service Bus messages (topic/sub)
# Requires: bin/Azure.Messaging.ServiceBus.dll, bin/Azure.Core.dll
# App setting: SB_CONN (Listen or Manage)
# Query:
#   mode=peek|receive (alias: get)
#   topic=<name> (required)
#   subscription=<name> (required)
#   max=1..50 (default 1)
#   timeoutSec=1..60 (default 5; receive only)
#   settle=complete|abandon|deadletter (optional; receive only)
# ==========================================

$ErrorActionPreference = 'Stop'
$__VERSION = 'ps-sb-http-v1'

function OK($obj)   { @{ statusCode = 200; headers = @{ "Content-Type" = "application/json" }; body = ($obj | ConvertTo-Json -Depth 20) } }
function BAD($msg)  { @{ statusCode = 400; headers = @{ "Content-Type" = "application/json" }; body = (@{ error = $msg } | ConvertTo-Json) } }
function FAIL($msg) { @{ statusCode = 500; headers = @{ "Content-Type" = "application/json" }; body = (@{ error = $msg } | ConvertTo-Json) } }

function Coerce-IntInRange($s, [int]$def, [int]$min, [int]$max) {
  try {
    if ($null -eq $s -or [string]::IsNullOrWhiteSpace([string]$s)) { return $def }
    [int]$n = [int]$s
    if ($n -lt $min) { return $min }
    if ($n -gt $max) { return $max }
    return $n
  } catch { return $def }
}

function Await([object]$task) { $task.GetAwaiter().GetResult() }

# --- Load SDK assemblies from bin ---
try {
  $asmDir = Join-Path $PSScriptRoot '..\bin'
  $sbDll  = Join-Path $asmDir 'Azure.Messaging.ServiceBus.dll'
  $coreDll= Join-Path $asmDir 'Azure.Core.dll'

  if (-not (Test-Path $sbDll))  { throw "Missing $sbDll" }
  if (-not (Test-Path $coreDll)){ throw "Missing $coreDll" }

  # Load only if not already loaded
  if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Azure.Messaging.ServiceBus' })) {
    [void][Reflection.Assembly]::LoadFrom($coreDll)
    [void][Reflection.Assembly]::LoadFrom($sbDll)
  }
}
catch {
  Push-OutputBinding -Name Response -Value (FAIL "SDK assemblies not found. Place Azure.Messaging.ServiceBus.dll and Azure.Core.dll in a 'bin' folder next to this function. Details: $($_.Exception.Message)")
  return
}

# --- Resolve and validate query ---
$q = $Request.Query
$mode = (($q['mode'] ?? $q['action'] ?? 'peek') + '').ToLowerInvariant()
if ($mode -eq 'get') { $mode = 'receive' }

$topic = ($q['topic'] ?? '').Trim()
$sub   = ($q['subscription'] ?? '').Trim()
$max   = Coerce-IntInRange $q['max'] 1 1 50
$timeoutSec = Coerce-IntInRange $q['timeoutSec'] 5 1 60
$settle = (($q['settle'] ?? '') + '').Trim().ToLowerInvariant() # complete|abandon|deadletter

if ([string]::IsNullOrWhiteSpace($topic) -or [string]::IsNullOrWhiteSpace($sub)) {
  Push-OutputBinding -Name Response -Value (BAD "Query requires 'topic' and 'subscription'.")
  return
}
if ($mode -notin @('peek','receive')) {
  Push-OutputBinding -Name Response -Value (BAD "mode must be 'peek' or 'receive'.")
  return
}

# --- Connection ---
$sbConn = $env:SB_CONN
if ([string]::IsNullOrWhiteSpace($sbConn)) {
  Push-OutputBinding -Name Response -Value (FAIL "Missing SB_CONN app setting (Service Bus connection string).")
  return
}

# --- Import types ---
$ServiceBusClient           = [Azure.Messaging.ServiceBus.ServiceBusClient]
$ServiceBusReceiveMode      = [Azure.Messaging.ServiceBus.ServiceBusReceiveMode]
$ServiceBusReceiverOptions  = [Azure.Messaging.ServiceBus.ServiceBusReceiverOptions]

# --- Helpers to serialize messages ---
function To-Base64($bytes) {
  if ($null -eq $bytes) { return $null }
  return [Convert]::ToBase64String([byte[]]$bytes)
}

function Serialize-Peeked($m) {
  # Peeked messages expose a subset of props (SequenceNumber, EnqueuedTime, etc.)
  $bodyBytes = $null
  try { $bodyBytes = $m.Body.ToArray() } catch { }
  [pscustomobject]@{
    sequenceNumber    = $m.SequenceNumber
    enqueuedTimeUtc   = ($m.EnqueuedTime?.UtcDateTime.ToString('o'))
    messageId         = $m.MessageId
    subject           = $m.Subject
    contentType       = $m.ContentType
    correlationId     = $m.CorrelationId
    applicationProps  = $m.ApplicationProperties
    bodyBase64        = (To-Base64 $bodyBytes)
  }
}

function Serialize-Received($m) {
  $bodyBytes = $null
  try { $bodyBytes = $m.Body.ToArray() } catch { }
  [pscustomobject]@{
    sequenceNumber    = $m.SequenceNumber
    enqueuedTimeUtc   = ($m.EnqueuedTime?.UtcDateTime.ToString('o'))
    lockedUntilUtc    = ($m.LockedUntil?.UtcDateTime.ToString('o'))
    messageId         = $m.MessageId
    subject           = $m.Subject
    contentType       = $m.ContentType
    correlationId     = $m.CorrelationId
    deliveryCount     = $m.DeliveryCount
    sessionId         = $m.SessionId
    applicationProps  = $m.ApplicationProperties
    lockToken         = $m.LockToken
    bodyBase64        = (To-Base64 $bodyBytes)
  }
}

# --- Main ---
try {
  $client = [Azure.Messaging.ServiceBus.ServiceBusClient]::new($sbConn)

  if ($mode -eq 'peek') {
    # Non-destructive peek
    $rx = $client.CreateReceiver($topic, $sub)  # receive mode irrelevant for Peek
    try {
      $msgs = Await ($rx.PeekMessagesAsync($max))
      $arr  = foreach ($m in $msgs) { Serialize-Peeked $m }
      Push-OutputBinding -Name Response -Value (OK @{
        version      = $__VERSION
        mode         = 'peek'
        topic        = $topic
        subscription = $sub
        count        = $arr.Count
        messages     = $arr
      })
      return
    }
    finally {
      if ($rx) { Await ($rx.DisposeAsync()) }
      if ($client) { Await ($client.DisposeAsync()) }
    }
  }
  else {
    # Receive with lock; optionally settle
    $opts = [Azure.Messaging.ServiceBus.ServiceBusReceiverOptions]::new()
    $opts.ReceiveMode = $ServiceBusReceiveMode::PeekLock
    $rx = $client.CreateReceiver($topic, $sub, $opts)

    try {
      $msgs = Await ($rx.ReceiveMessagesAsync($max, [TimeSpan]::FromSeconds($timeoutSec)))
      $arr  = New-Object System.Collections.Generic.List[object]

      foreach ($m in $msgs) {
        $arr.Add( (Serialize-Received $m) )
        try {
          switch ($settle) {
            'complete'   { Await ($rx.CompleteMessageAsync($m)) }
            'abandon'    { Await ($rx.AbandonMessageAsync($m)) }
            'deadletter' { Await ($rx.DeadLetterMessageAsync($m, "manual", "HTTP requested deadletter")) }
            default      { } # leave locked; lock will expire
          }
        } catch {
          # If settlement fails, we still return the message metadata
          Write-Warning ("Settlement failed for MessageId={0} : {1}" -f $m.MessageId, $_.Exception.Message)
        }
      }

      Push-OutputBinding -Name Response -Value (OK @{
        version      = $__VERSION
        mode         = 'receive'
        topic        = $topic
        subscription = $sub
        count        = $arr.Count
        timeoutSec   = $timeoutSec
        settle       = ($settle ? $settle : $null)
        messages     = $arr
      })
      return
    }
    finally {
      if ($rx) { Await ($rx.DisposeAsync()) }
      if ($client) { Await ($client.DisposeAsync()) }
    }
  }
}
catch {
  Push-OutputBinding -Name Response -Value (FAIL ("Unhandled error: " + $_.Exception.Message))
}
