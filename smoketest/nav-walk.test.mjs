import puppeteer from "puppeteer";
import http from "node:http";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Checks that loading a page deep inside the repository walks nav open
// down to that folder in the browser (page.mustache's "htmx:after:swap"
// listener, navPathRelation): every folder on the path ends up expanded,
// the current folder selected, nothing off the path expanded, and each
// expansion is an ordinary lazy one, so wa-tree-item shows its own loading
// spinner (aria-busy) while the folder's listing is fetched. Repeated with
// a "?p=" revision pin, which mod_dav_svn carries on every href.
const NAV_FETCH_DELAY_MS = 300;
const WALK_TIMEOUT_MS = 20000;

// --- Synthetic repository, three levels deep. ---

const LISTINGS = {
    "/": ['<dir name="trunk" href="trunk/" />', '<dir name="branches" href="branches/" />'],
    "/trunk/": ['<dir name="sub" href="sub/" />', '<file name="a.xml" href="a.xml" />'],
    "/trunk/sub/": ['<dir name="deeper" href="deeper/" />', '<file name="c.xml" href="c.xml" />'],
    "/trunk/sub/deeper/": ['<file name="d.xml" href="d.xml" />'],
    "/branches/": [],
};

// Like mod_dav_svn, a revision-pinned request gets the pin on every href.
function indexXml(repoPath, revision) {
    const entries = (LISTINGS[repoPath] || []).map((e) => (revision ? e.replace(/href="([^"]*)"/, `href="$1?p=${revision}"`) : e));
    return `<?xml version="1.0" encoding="utf-8"?>
<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="${revision || 7}" path="${repoPath}" base="demo1">
${entries.join("\n")}
</index>
</svn>
`;
}

// --- Run the real Lua driver (same one nav-large-folder.test.mjs uses). ---

function renderIndexHtml(uri, headers) {
    const luaBin = process.env.LUA_BIN || "lua5.3";
    const repoPath = uri.replace(/^\/svn\/demo1/, "").replace(/\?.*$/, "");
    const revision = (uri.match(/[?&]p=(\d+)/) || [])[1];
    const args = [path.join(__dirname, "render-index.lua"), uri];
    if (headers["hx-request"]) args.push(headers["hx-target"] || "", headers["hx-current-url"] || "");
    const result = spawnSync(luaBin, args, { input: indexXml(repoPath, revision), encoding: "utf8" });

    if (result.error) {
        throw new Error(
            `failed to launch "${luaBin}": ${result.error.message} (set the LUA_BIN environment variable to override the interpreter name, e.g. LUA_BIN=lua)`
        );
    }
    if (result.status !== 0) {
        throw new Error(`render-index.lua exited with status ${result.status}:\n${result.stderr}`);
    }

    return result.stdout;
}

// --- main ---

const results = [];
const record = (name, pass, detail) => {
    results.push({ name, pass, detail });
    console.log(`${pass ? "PASS" : "FAIL"}: ${name}${detail ? " -- " + detail : ""}`);
};

const server = http.createServer(async (req, res) => {
    // Chromium's own automatic request -- not the page's, so not an error.
    if (req.url === "/favicon.ico") {
        res.writeHead(204).end();
        return;
    }
    if (!req.url.startsWith("/svn/demo1/") || !req.url.replace(/\?.*$/, "").endsWith("/")) {
        res.writeHead(404).end();
        return;
    }
    // Slows nav's own per-folder fetches so each folder's loading state
    // lasts long enough to be observed.
    if (req.headers["hx-target"] === "wa-tree-item") {
        await new Promise((r) => setTimeout(r, NAV_FETCH_DELAY_MS));
    }
    try {
        const body = renderIndexHtml(req.url, req.headers);
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end(body);
    } catch (err) {
        console.error(err.message);
        res.writeHead(500).end();
    }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;

let browser;
try {
    browser = await puppeteer.launch({
        headless: true,
        // Same reasoning as history-dialog.test.mjs's own launch options.
        args: process.env.CI ? ["--no-sandbox", "--disable-setuid-sandbox"] : [],
    });

    for (const suffix of ["", "?p=7"]) {
        const label = suffix ? `with revision pin ${suffix}` : "at HEAD";
        const page = await browser.newPage();
        const pageErrors = [];
        page.on("pageerror", (err) => pageErrors.push(err.message));
        // Records every nav folder that showed wa-tree-item's own spinner.
        await page.evaluateOnNewDocument(() => {
            window.__busy = new Set();
            new MutationObserver((mutations) => {
                for (const m of mutations) {
                    if (m.target.getAttribute?.("aria-busy") === "true" && m.target.closest(".svn-nav")) {
                        window.__busy.add(m.target.querySelector(":scope > span")?.textContent.trim());
                    }
                }
            }).observe(document, { attributes: true, attributeFilter: ["aria-busy"], subtree: true });
        });
        await page.goto(`${origin}/svn/demo1/trunk/sub/deeper/${suffix}`, { waitUntil: "domcontentloaded" });

        let walked = true;
        try {
            await page.waitForFunction(
                () => {
                    const deeper = [...document.querySelectorAll(".svn-nav wa-tree-item.dir")].find(
                        (i) => i.querySelector(":scope > span")?.textContent.trim() === "deeper/"
                    );
                    return deeper?.selected && !deeper.lazy && !deeper.loading;
                },
                { timeout: WALK_TIMEOUT_MS, polling: 100 }
            );
        } catch {
            walked = false;
        }

        const state = await page.evaluate(() => {
            const items = [...document.querySelectorAll(".svn-nav wa-tree-item.dir")];
            const name = (i) => i.querySelector(":scope > span").textContent.trim();
            return {
                expanded: items.filter((i) => i.expanded).map(name),
                selected: items.filter((i) => i.selected).map(name),
                lazyCollapsed: items.filter((i) => i.lazy && !i.expanded).map(name),
                busy: [...window.__busy],
            };
        });

        record(`${label}: nav walks open down to the current folder`, walked, JSON.stringify(state));
        record(
            `${label}: exactly the folders on the path are expanded, the current one selected`,
            state.expanded.join() === "trunk/,sub/,deeper/" && state.selected.join() === "deeper/",
            JSON.stringify(state)
        );
        record(`${label}: a folder off the path stays collapsed and lazy`, state.lazyCollapsed.includes("branches/"), JSON.stringify(state));
        record(
            `${label}: each folder on the path showed wa-tree-item's own loading spinner`,
            ["trunk/", "sub/", "deeper/"].every((n) => state.busy.includes(n)),
            JSON.stringify(state)
        );
        record(`${label}: no page errors`, pageErrors.length === 0, pageErrors.join(" | "));
        await page.close();
    }
} finally {
    await browser?.close();
    server.close();
}

console.log("\n=== SUMMARY ===");
const failed = results.filter((r) => !r.pass);
console.log(`${results.length - failed.length}/${results.length} passed`);
if (failed.length) {
    console.log("FAILURES:");
    for (const f of failed) console.log(` - ${f.name}: ${f.detail || ""}`);
    process.exitCode = 1;
}
