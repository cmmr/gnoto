// directory-index.js - The CloudFront function in front of gnoto's results:
// serves a folder's page for a folder's address.
//
// Deployed by:  gnoto config s3 --deploy, inline in service/aws/stacks/s3.yaml,
//               with RUN_PREFIX set to aws.run_prefix. A site that sets up
//               its own CloudFront publishes this file as a cloudfront-js-2.0
//               function, with RUN_PREFIX set by hand, and associates it with
//               the viewer request event of the behavior that serves results.
//
// S3 stores objects, so a request for a folder matches none, and every folder
// link inside a pipeline's own report would be a 404 without this. Across a
// published run, two names never collide: index.html is a page something wrote
// to be read, the run's dashboard at the top of a run, and
// directory_listing.html is the listing written into every folder. So a folder
// address is either the top of a run, which means the dashboard, or any other
// folder, which means its listing. Every link gnoto writes names the file
// outright; this is for the links it doesn't write, and for an address typed
// by hand.
//
// A run's folder is <uid>-<token>, eight base32 characters, a hyphen and
// sixteen more:
//
//   /gnoto/<run>            301 to /gnoto/<run>/
//   /gnoto/<run>/           the dashboard, /gnoto/<run>/index.html
//   /gnoto/<run>/qiime2     301 to /gnoto/<run>/qiime2/
//   /gnoto/<run>/qiime2/    its listing, qiime2/directory_listing.html
//   anything with a dot     as it is

var RUN_PREFIX = 'gnoto';

function handler(event) {
    var request = event.request;
    var uri = request.uri;

    // A folder without its trailing slash, so its page's relative links
    // resolve against the folder rather than its parent
    if (!uri.endsWith('/') && !uri.includes('.')) {
        return {
            statusCode: 301,
            statusDescription: 'Moved Permanently',
            headers: { 'location': { value: uri + '/' } }
        };
    }
    if (uri.endsWith('/')) {
        request.uri += isRunRoot(uri) ? 'index.html' : 'directory_listing.html';
    }
    return request;
}

// "/<prefix>/<run>/" and nothing deeper: split on "/", that's four fields,
// the last empty
function isRunRoot(uri) {
    var parts = uri.split('/');
    return parts.length === 4 && parts[1] === RUN_PREFIX && /^[a-z2-7]{8}-[a-z2-7]{16}$/.test(parts[2]);
}
