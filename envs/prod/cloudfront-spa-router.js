// CloudFront Function (viewer-request) — SPA deep-link fallback.
//
// Attached to the DEFAULT cache behaviour only, never to /api/*. That
// restriction is the whole reason this file exists instead of the two lines
// of `custom_error_response` that every SPA-on-CloudFront tutorial shows.
// See the long comment in cloudfront.tf above aws_cloudfront_function for
// why those two lines would silently corrupt every API error response.
//
// The frontend uses BrowserRouter with real paths (/checkout, /orders,
// /products/:slug — see src/App.jsx), so a hard refresh or a pasted URL asks
// S3 for a key that does not exist. S3 with OAC answers 403, not 404. This
// rewrites those to /index.html so React Router can take over.
//
// Runtime is cloudfront-js-2.0, which is close to ES5. No arrow functions,
// no String.prototype.includes — kept deliberately plain so it cannot fail
// to compile on a runtime that is not Node.

function handler(event) {
  var request = event.request;
  var uri = request.uri;

  // "/" and "/products/" — a trailing slash is never a file.
  if (uri.charAt(uri.length - 1) === '/') {
    request.uri = '/index.html';
    return request;
  }

  // Everything else: a last path segment containing a dot is treated as a
  // real asset and passed through untouched. That covers the content-hashed
  // /assets/index-<hash>.js and .css, plus the unhashed root files Vite
  // emits (favicon.svg, robots.txt, site.webmanifest) — all confirmed
  // against an actual `npm run build` output, not assumed.
  //
  // KNOWN LIMIT: a product slug containing a dot would be passed through to
  // S3 and 403. Every current slug is hyphenated, and the alternative — a
  // hard-coded list of route prefixes — has to be edited every time App.jsx
  // gains a route, which is the more likely failure.
  var lastSegment = uri.substring(uri.lastIndexOf('/') + 1);
  if (lastSegment.indexOf('.') === -1) {
    request.uri = '/index.html';
  }

  return request;
}
