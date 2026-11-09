// CloudFront Function (runtime cloudfront-js-2.0), viewer-request, DEFAULT (S3) behaviour only.
// React Router paths such as /login or /register don't exist in S3, so serve index.html for any
// path whose last segment has no file extension. Real files (/assets/app-123.js) pass through.
// /api/* never reaches this function: those paths match the API behaviours first.
function handler(event) {
  var request = event.request;
  var lastSegment = request.uri.substring(request.uri.lastIndexOf('/') + 1);
  if (lastSegment.indexOf('.') === -1) {
    request.uri = '/index.html';
  }
  return request;
}
