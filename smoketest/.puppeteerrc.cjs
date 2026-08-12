const { join } = require("node:path");

// Puppeteer's own documented project-scoped config mechanism
// (https://pptr.dev/guides/configuration). Pins the bundled-Chromium
// cache to a path local to this directory instead of the shared
// "~/.cache/puppeteer", so `npm install` works out of the box on any
// machine regardless of that shared directory's own permission/ownership
// history on a given dev machine -- no PUPPETEER_CACHE_DIR env var export
// needed.

/** @type {import("puppeteer").Configuration} */
module.exports = {
  cacheDirectory: join(__dirname, ".cache", "puppeteer"),
};
