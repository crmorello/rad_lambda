// CloudFront Function (runtime cloudfront-js-2.0), viewer-request.
// Deployed by 09-tiles-auth.sh; associated with every behavior on the radar
// distribution so CACHED hits are gated too, not just origin hits.
//
// Keys live in the CloudFront KeyValueStore the function is associated with
// (tempest-radar-output-tile-keys). The association is part of --function-config:
// push code with update-function and you MUST pass the config too, or the
// binding is dropped and cf.kvs() throws for every request.
//
// This is not a module in the usual sense -- CloudFront invokes `handler` by
// name and there is no bundler, no npm, and no test runner. Check changes with
//   aws cloudfront test-function --stage DEVELOPMENT --event-object <json>
// before publish-function promotes them to LIVE.
import cf from 'cloudfront';
const kvs = cf.kvs();
async function handler(event) {
  const req = event.request;
  let key = null;
  if (req.querystring.api_key) key = req.querystring.api_key.value;
  else if (req.headers.authorization) key = req.headers.authorization.value.replace(/^Bearer\s+/i, '');
  if (!key) return { statusCode: 401, statusDescription: 'Unauthorized', body: 'api_key required' };
  try { await kvs.get(key); } catch (e) {
    return { statusCode: 401, statusDescription: 'Unauthorized', body: 'invalid api_key' };
  }
  delete req.querystring.api_key;      // not part of the cache key or the origin request
  delete req.headers.authorization;
  return req;
}
