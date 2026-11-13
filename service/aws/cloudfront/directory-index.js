// directory-index.js - The CloudFront function in front of gnoto's results:
// serves a folder's page for a folder's address.
//
// Deployed by:  gnoto config s3 --deploy, inline in service/aws/stacks/s3.yaml.
//               A site that sets up its own CloudFront publishes this file as
//               a cloudfront-js-2.0 function, and associates it with the viewer
//               request event of the behavior that serves results.
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
// sixteen more. The stack's distribution serves the run prefix at its root,
// through its origin path, so this sees addresses without it:
//
//   /<run>                  301 to /<run>/
//   /<run>/                 the dashboard, /<run>/index.html
//   /<run>/qiime2           301 to /<run>/qiime2/
//   /<run>/qiime2/          its listing, qiime2/directory_listing.html
//   anything with a dot     as it is
//
// A run's folder is recognised at any depth, so a site whose own distribution
// serves the prefix as a path works too.

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
        request.uri += /\/[a-z2-7]{8}-[a-z2-7]{16}\/$/.test(uri) ? 'index.html' : 'directory_listing.html';
    }
    return request;
}
