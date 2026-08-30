# rad_lambda — AWS Ops Handoff

Deploying the RAD generation lambda: NOAA MRMS S3 notification in → grib
warped in-process (GDAL) → RAD v2 + `manifest.json` written to S3 → served via
CloudFront. Ships as a Lambda **container image** with a custom runtime (the
binary is the bootstrap). Region for everything: **us-east-1** (NOAA MRMS data
and its SNS topic live there). Architecture: **arm64** (Graviton).

I can build and push the image and will supply every config below — I need
the account-side resources created/enabled by ops.

---

## Part 1 — What I need from ops (in dependency order)

### 1. ECR repository + my push access
- Private ECR repo `rad-lambda`, us-east-1.
- IAM for me: `ecr:GetAuthorizationToken` (account) and
  `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`,
  `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage` on the repo.
- Also `lambda:UpdateFunctionCode` + `lambda:GetFunction` on the function
  (item 5) so I can roll new images without a ticket each time.

### 2. Output S3 bucket
- New private bucket (Block Public Access ON), us-east-1. Objects land under
  `rads/`.
- Lifecycle rule: expire `rads/*` after **7 days** (client plays back ~3 h;
  7 d is headroom — tunable, tell me what you set).
- No versioning needed. Objects are small (RADs ≤ ~1.5 MB, ~17k writes/month).

### 3. CloudFront distribution (fronting the bucket via Origin Access Control)
Objects are stored **pre-gzipped with `Content-Encoding: gzip` metadata** —
clients inflate transparently. Therefore:
- CloudFront compression **OFF** for these behaviors (double-compression
  breaks nothing but wastes cycles; the metadata must pass through untouched).
- Behavior `/rads/manifest.json`: min/default TTL ~**30 s** (rewritten every
  10 minutes; this bounds client staleness).
- Behavior `/rads/*.rad`: **long TTL** (24 h+) — a stamp's bytes never change.
- HTTPS only. No signed URLs/cookies for now.
- I need the distribution domain name back for the client config.

### 4. SQS queue + DLQ, subscribed to NOAA's SNS topic
- Standard queue `rad-lambda-events` + DLQ `rad-lambda-events-dlq`,
  us-east-1.
- Cross-account subscription: queue subscribed to NOAA NODD's public MRMS
  new-object SNS topic (`arn:aws:sns:us-east-1:123901341784:NewMRMSObject` —
  verify current ARN against the NODD docs). I provide the subscription
  filter policy (Part 2) so only the four SeamlessHSR products flow.
- Queue policy allowing that topic to `sqs:SendMessage`.
- Redrive to DLQ after **3** receives. Visibility timeout **≥ 6× the function
  timeout** (i.e., ≥ 360 s with the 60 s timeout below).

### 5. Lambda function + event source mapping
- Function `rad-lambda` from the ECR image (I supply URI:tag), **arm64**,
  **2048 MB**, **60 s timeout**, reserved concurrency **10**.
- Env vars per my config sheet (Part 2). No VPC. Ephemeral storage default.
- Event source mapping from the queue, **batch size 1** to start (one S3
  event per invocation; a failed record then can't poison a batch — we can
  raise it later).

### 6. Execution role
From my policy JSON (Part 2). Summary of what it grants:
- `s3:GetObject` on `arn:aws:s3:::noaa-mrms-pds/*` (public NOAA bucket)
- `s3:PutObject`, `s3:GetObject` on `<output-bucket>/rads/*`, plus
  `s3:ListBucket` on the bucket (prefix-scoped) — the manifest rebuild lists
  the output dir
- SQS receive/delete on the queue
- CloudWatch Logs create/put

### 7. Observability
- Log group retention **14 days** (cost guard — verbose logs would cost more
  than this function's compute, which is ~$1/month).
- Alarms: DLQ ApproximateNumberOfMessagesVisible > 0 (5 min), and function
  error rate > ~5/hour. Route to the usual channel; I should be on it.

### 8. Heads-up — phase 2, not blocking this deploy
Typed (snow/mixed) RADs need the **mixedPhase feed in S3** (today it lands on
the data_manager EC2 host's local disk). When we get there I'll need a
bucket/prefix for it and a delivery mechanism from its source. The EC2
data_manager keeps running in parallel until that lands — nothing is
decommissioned by this deploy.

---

## Part 2 — What I will provide ops

| Deliverable | When |
|---|---|
| ECR image URI + tag (arm64 build) | after item 1 |
| Function config sheet (below) | with the ticket |
| SNS subscription filter policy JSON (below) | with the ticket |
| Execution role policy JSON (below, ARNs filled once bucket/queue named) | after items 2 & 4 |
| CloudFront behavior spec | Part 1 item 3 is the spec |
| Test events + validation runbook (below) | with the ticket |

### Function config sheet
```
Name:          rad-lambda
Arch:          arm64        Memory: 2048 MB      Timeout: 60 s
Concurrency:   10 reserved
Env:
  RAD_OUTPUT           = /vsis3/<output-bucket>/rads   (required)
  RAD_URL_PREFIX       = /rads                         (manifest URL prefix)
  RAD_UNSIGNED_BUCKETS = noaa-mrms-pds                 (read public input
                         buckets anonymously — sidesteps SCP/role blocks on
                         signed reads of external buckets; writes stay signed)
  RAD_RESOLUTION       = (unset — defaults to 1222.8 m/px)
  RAD_GZIP             = (unset — gzip-at-rest on by default; 0 disables)
  RAD_MANIFEST_HOURS   = (unset — manifest timeline window, default 3;
                         0 = unwindowed. Older RADs stay fetchable by URL
                         until the bucket lifecycle expires them)
```

### SNS subscription filter policy (SeamlessHSR, 4 regions)
```json
{
  "s3_object_key": [
    { "prefix": "CONUS/SeamlessHSR_00.00_" },
    { "prefix": "ALASKA/SeamlessHSR_00.00_" },
    { "prefix": "HAWAII/SeamlessHSR_00.00_" },
    { "prefix": "CARIB/SeamlessHSR_00.00_" }
  ]
}
```
(Attribute name depends on how NODD publishes; if the topic doesn't set
message attributes, drop the filter and the function's own 10-minute-grid +
key checks handle the rest — it costs milliseconds per skipped event.)

### Execution role policy (template)
```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::noaa-mrms-pds/*" },
    { "Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::<OUTPUT_BUCKET>/rads/*" },
    { "Effect": "Allow", "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<OUTPUT_BUCKET>",
      "Condition": { "StringLike": { "s3:prefix": "rads/*" } } },
    { "Effect": "Allow",
      "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"],
      "Resource": "arn:aws:sqs:us-east-1:<ACCOUNT>:rad-lambda-events" },
    { "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:us-east-1:<ACCOUNT>:*" }
  ]
}
```

### Test event (raw S3 shape; the handler also unwraps SQS→SNS envelopes)
```json
{
  "Records": [{
    "s3": {
      "bucket": { "name": "noaa-mrms-pds" },
      "object": { "key": "CONUS/SeamlessHSR_00.00/<DATE>/MRMS_SeamlessHSR_00.00_<YYYYMMDD-HHMM00>.grib2.gz" }
    }
  }]
}
```
Use any real key whose stamp minute ends in 0 (10-minute grid); off-grid
stamps return `{"processed":[],"skipped":1}` by design.

### Validation runbook (I run this; ops on standby)
1. Push image; ops (or I, with UpdateFunctionCode) point the function at it.
2. `aws lambda invoke` with the test event → expect
   `{"processed":["/vsis3/.../rads/<stamp>.rad"],"skipped":0}`.
3. Confirm `rads/<stamp>.rad` + `rads/manifest.json` exist, both with
   `Content-Encoding: gzip` metadata.
4. `curl` both through CloudFront — they must inflate transparently and the
   manifest's frame URLs must resolve.
5. Byte-compare the fetched RAD against a local build run on the same grib
   (`zig-out/bin/rad_lambda <grib>` — output is deterministic).
6. Enable the live SNS subscription; watch one 10-minute cycle: 4 regions
   processed, ~4× off-grid skips per region, DLQ empty, no error alarms.
