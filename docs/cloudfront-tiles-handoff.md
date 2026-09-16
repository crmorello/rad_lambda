# CloudFront change request — raster tiles

Add a `/tiles/*` behavior to distribution **`E1SJXXC8FMVM4Q`**
(`internal-radar.weatherflow.com`) pointing at an existing Lambda Function URL.

**Nothing outside CloudFront needs to change.** The Lambda, its IAM role, and its
Function URL already exist and are configured. The distribution is already
granted invoke permission on the function (`AllowCloudFrontServicePrincipal_E1SJXXC8FMVM4Q`
is present on the Lambda's resource policy). Today `/tiles/*` falls through to
the default behavior and returns **403 from S3**.

## 1. Cache policy (new, custom)

| Field | Value |
|---|---|
| Name | `tempest-radar-output-tiles` |
| Min TTL | `0` |
| Default TTL | `86400` |
| Max TTL | `31536000` |
| Headers | **None** |
| Cookies | **None** |
| Query strings | **Whitelist:** `tms`, `size`, `palette` |
| Gzip / Brotli | **Off** (both) |

The query-string whitelist is load-bearing. Forwarding *all* query strings lets
any caller bust the cache with a junk parameter, and every miss is a Lambda
invocation.

## 2. Origin (add to the existing distribution)

| Field | Value |
|---|---|
| Origin ID / name | `rad-tiles-lambda` |
| Origin domain | `bjbvpovuzmss2unukwaxwb7vfa0qtsrb.lambda-url.us-east-1.on.aws` |
| Protocol | **HTTPS only** |
| Minimum origin SSL | `TLSv1.2` |
| Origin path | *(empty)* |
| Custom headers | none |
| Origin access | **None / public** — do *not* attach OAC |

The Function URL auth type is `NONE` by design; gating happens at the edge later
(see "Follow-up"). Attaching OAC would require SigV4 origin signing and break it.

## 3. Cache behavior (new)

| Field | Value |
|---|---|
| Path pattern | `/tiles/*` |
| **Precedence** | **Must sit ABOVE the `*.json` behavior** |
| Origin | `rad-tiles-lambda` |
| Viewer protocol policy | Redirect HTTP to HTTPS |
| Allowed methods | `GET, HEAD` |
| Cache policy | `tempest-radar-output-tiles` (from step 1) |
| Origin request policy | **`Managed-AllViewerExceptHostHeader`** |
| Compress objects automatically | **No** |

Two of these are easy to get wrong and both produce confusing failures:

- **`Managed-AllViewerExceptHostHeader` is required.** A Lambda Function URL
  validates the `Host` header. If CloudFront forwards its own host, the origin
  returns 403 and it looks like a permissions problem.
- **Ordering matters.** CloudFront evaluates behaviors in order, and `*.json`
  would otherwise match `/tiles/v1/rads/manifest.json` and route it to S3.
- Compression off: the payloads are PNG (already compressed).

## CLI equivalent

```bash
DIST=E1SJXXC8FMVM4Q
HOST=bjbvpovuzmss2unukwaxwb7vfa0qtsrb.lambda-url.us-east-1.on.aws

# 1. cache policy
aws cloudfront create-cache-policy --cache-policy-config '{
  "Name":"tempest-radar-output-tiles","Comment":"RAD3 raster tiles",
  "DefaultTTL":86400,"MaxTTL":31536000,"MinTTL":0,
  "ParametersInCacheKeyAndForwardedToOrigin":{
    "EnableAcceptEncodingGzip":false,"EnableAcceptEncodingBrotli":false,
    "HeadersConfig":{"HeaderBehavior":"none"},
    "CookiesConfig":{"CookieBehavior":"none"},
    "QueryStringsConfig":{"QueryStringBehavior":"whitelist",
      "QueryStrings":{"Quantity":3,"Items":["tms","size","palette"]}}}}'

# 2. look up the managed origin request policy by NAME (do not hardcode the id)
aws cloudfront list-origin-request-policies --type managed \
  --query "OriginRequestPolicyList.Items[?OriginRequestPolicy.OriginRequestPolicyConfig.Name=='Managed-AllViewerExceptHostHeader'].OriginRequestPolicy.Id | [0]" --output text
```

`deploy/08-tiles.sh` in this repo performs steps 2–3 as a read-modify-write of
the distribution config (`get-distribution-config` → patch JSON →
`update-distribution --if-match <etag>`). It also creates a Lambda and IAM role,
which are **already done** — so if ops runs it, only its CloudFront section is
relevant. Applying by hand is safer given it round-trips the whole config.

## Verify after propagation (~5 min)

```bash
H=https://internal-radar.weatherflow.com
# 200 image/png, immutable
curl -sI "$H/tiles/v1/rads/20260915-164000/5/7/12.png" | grep -iE 'HTTP|content-type|cache-control|x-cache'
# second request should be a HIT
curl -sI "$H/tiles/v1/rads/20260915-164000/5/7/12.png" | grep -i x-cache
# manifest must NOT be served by S3 (server: AmazonS3 means the *.json behavior won)
curl -sI "$H/tiles/v1/rads/manifest.json" | grep -iE 'HTTP|server'
```

Expected: `200`, `content-type: image/png`,
`cache-control: public, max-age=31536000, immutable`, `X-Cache: Miss` then
`Hit from cloudfront`. The manifest check must **not** show `server: AmazonS3`.

## Follow-up (separate request)

API-key gating at the edge — a CloudFront KeyValueStore plus a viewer-request
function that checks `api_key`/`Authorization` and strips it before caching, so
cached hits are gated too (`deploy/09-tiles-auth.sh`). When that lands, the
`FunctionURLAllowPublicAccess` statement should be removed from the Lambda's
resource policy so the origin can't be called directly, bypassing both the key
check and the cache.

## Permissions needed (if cmorello applies this instead of ops)

`iam:user/cmorello` currently has **no** CloudFront permissions at all — every
action probed (`ListDistributions`, `GetDistributionConfig`, `GetDistribution`,
`ListCachePolicies`, `ListOriginRequestPolicies`) returns AccessDenied.

This policy covers exactly the three steps above plus verification. Writes are
scoped to the one distribution; the policy/lookup calls are account-level
resources that CloudFront does not support scoping.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadCloudFrontConfig",
      "Effect": "Allow",
      "Action": [
        "cloudfront:GetDistribution",
        "cloudfront:GetDistributionConfig",
        "cloudfront:ListDistributions",
        "cloudfront:ListCachePolicies",
        "cloudfront:GetCachePolicy",
        "cloudfront:GetCachePolicyConfig",
        "cloudfront:ListOriginRequestPolicies",
        "cloudfront:GetOriginRequestPolicy",
        "cloudfront:GetOriginRequestPolicyConfig"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CreateTileCachePolicy",
      "Effect": "Allow",
      "Action": "cloudfront:CreateCachePolicy",
      "Resource": "*"
    },
    {
      "Sid": "UpdateRadarDistribution",
      "Effect": "Allow",
      "Action": [
        "cloudfront:UpdateDistribution",
        "cloudfront:CreateInvalidation",
        "cloudfront:GetInvalidation",
        "cloudfront:ListInvalidations"
      ],
      "Resource": "arn:aws:cloudfront::960102610069:distribution/E1SJXXC8FMVM4Q"
    }
  ]
}
```

CloudFront is global — distribution ARNs carry no region.

### Optional: the API-key follow-up

Only needed to run `deploy/09-tiles-auth.sh` later. Ask for it now if you want
one round-trip with ops instead of two.

```json
{
  "Sid": "EdgeAuthFunctionAndKeyStore",
  "Effect": "Allow",
  "Action": [
    "cloudfront:CreateKeyValueStore",
    "cloudfront:DescribeKeyValueStore",
    "cloudfront:ListKeyValueStores",
    "cloudfront:CreateFunction",
    "cloudfront:UpdateFunction",
    "cloudfront:PublishFunction",
    "cloudfront:DescribeFunction",
    "cloudfront:GetFunction",
    "cloudfront:TestFunction",
    "cloudfront-keyvaluestore:DescribeKeyValueStore",
    "cloudfront-keyvaluestore:PutKey",
    "cloudfront-keyvaluestore:DeleteKey",
    "cloudfront-keyvaluestore:ListKeys",
    "cloudfront-keyvaluestore:UpdateKeys"
  ],
  "Resource": "*"
}
```
