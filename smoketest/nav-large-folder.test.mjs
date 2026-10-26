import puppeteer from "puppeteer";
import http from "node:http";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Regression check for expanding a large folder in wa-page's nav tree:
// marking each newly-fetched entry lazy *after* it rendered made
// wa-tree-item fire wa-lazy-change per entry, and wa-tree re-initializes
// every item in the whole tree on each one -- cubic in the folder's size,
// hanging the tab for minutes at ~2000 entries (see the "htmx:before:swap"
// listener in page.mustache). Unlike history-dialog.test.mjs, this serves
// the whole real page and answers htmx's own nav fetches live, since the
// bug lives in that fetch-swap-mark flow itself.
const DIR_COUNT = 2000;
const FILE_COUNT = 200;
const EXPAND_TIMEOUT_MS = 60000;

// --- Synthetic repository: "/" holds one folder, "big/", which holds
// DIR_COUNT empty folders plus FILE_COUNT files (nav must drop those). ---

function childName(i) {
    return `folder${String(i).padStart(4, "0")}`;
}

function indexXml(repoPath) {
    let entries = "";

    if (repoPath === "/") {
        entries = '<dir name="big" href="big/" />\n';
    } else if (repoPath === "/big/") {
        for (let i = 0; i < DIR_COUNT; i++) {
            entries += `<dir name="${childName(i)}" href="${childName(i)}/" />\n`;
        }
        for (let i = 0; i < FILE_COUNT; i++) {
            entries += `<file name="file${i}.xml" href="file${i}.xml" />\n`;
        }
    }

    return `<?xml version="1.0" encoding="utf-8"?>
<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="${repoPath}" base="demo1">
${entries}</index>
</svn>
`;
}

// --- Run the real Lua driver (renders real HTML via the actual
// mod-lua/svn-index.lua output_filter, not a hand-approximated mock). ---

function renderIndexHtml(uri, headers) {
    const luaBin = process.env.LUA_BIN || "lua5.3";
    const repoPath = uri.replace(/^\/svn\/demo1/, "").replace(/\?.*$/, "");
    const args = [path.join(__dirname, "render-index.lua"), uri];
    if (headers["hx-request"]) args.push(headers["hx-target"] || "", headers["hx-current-url"] || "");
    // "big/"'s rendered page is well past spawnSync's default 1MB maxBuffer.
    const result = spawnSync(luaBin, args, { input: indexXml(repoPath), encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

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

const server = http.createServer((req, res) => {
    // Chromium's own automatic request -- not the page's, so not an error.
    if (req.url === "/favicon.ico") {
        res.writeHead(204).end();
        return;
    }
    if (!req.url.startsWith("/svn/demo1/") || !req.url.replace(/\?.*$/, "").endsWith("/")) {
        res.writeHead(404).end();
        return;
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
const port = server.address().port;

let browser;
try {
    browser = await puppeteer.launch({
        headless: true,
        // Same reasoning as history-dialog.test.mjs's own launch options.
        args: process.env.CI ? ["--no-sandbox", "--disable-setuid-sandbox"] : [],
    });
    const page = await browser.newPage();
    await page.setViewport({ width: 1000, height: 900 });

    const consoleErrors = [];
    page.on("pageerror", (err) => consoleErrors.push("pageerror: " + err.message));
    page.on("console", (msg) => {
        if (msg.type() === "error") consoleErrors.push("console.error: " + msg.text());
    });

    await page.goto(`http://127.0.0.1:${port}/svn/demo1/`, { waitUntil: "networkidle0" });

    // Nav's own root population is itself an htmx fetch: "big/" only
    // becomes expandable once it's both marked lazy and processed by htmx
    // (data-htmx-powered), i.e. its hx-trigger="wa-lazy-load" is bound.
    await page.waitForFunction(
        () => {
            const item = document.querySelector(".svn-nav wa-tree-item.dir");
            return item?.lazy === true && item.hasAttribute("data-htmx-powered");
        },
        { timeout: 30000, polling: 100 }
    );

    await page.evaluate(() => {
        window.__lazyChangeEvents = 0;
        document.addEventListener("wa-lazy-change", () => window.__lazyChangeEvents++, true);
        document.querySelector(".svn-nav wa-tree-item.dir").expanded = true;
    });
    const startedAt = Date.now();

    let expanded = true;
    try {
        await page.waitForFunction(
            () => {
                const big = document.querySelector(".svn-nav wa-tree-item.dir");
                return big.querySelectorAll(":scope > wa-tree-item").length > 0 && !big.lazy && !big.loading;
            },
            { timeout: EXPAND_TIMEOUT_MS, polling: 250 }
        );
    } catch {
        expanded = false;
    }
    const elapsedMs = Date.now() - startedAt;

    record(
        `expanding a folder with ${DIR_COUNT} subfolders finishes within ${EXPAND_TIMEOUT_MS / 1000}s`,
        expanded,
        `${elapsedMs}ms`
    );

    if (expanded) {
        const state = await page.evaluate(() => {
            const big = document.querySelector(".svn-nav wa-tree-item.dir");
            const children = [...big.querySelectorAll(":scope > wa-tree-item")];
            return {
                dirs: children.filter((c) => c.classList.contains("dir")).length,
                nonDirs: children.filter((c) => !c.classList.contains("dir")).length,
                lazyDirs: children.filter((c) => c.lazy).length,
                lazyChangeEvents: window.__lazyChangeEvents,
            };
        });

        record(`all ${DIR_COUNT} subfolders are rendered in nav`, state.dirs === DIR_COUNT, JSON.stringify(state));
        record("file entries are dropped from nav", state.nonDirs === 0, JSON.stringify(state));
        record("every subfolder is itself lazily expandable", state.lazyDirs === DIR_COUNT, JSON.stringify(state));
        // The deterministic half of this check, independent of runner
        // speed: only the expanded folder's own lazy -> false transition
        // may fire wa-lazy-change, never one per fetched entry.
        record(
            "no per-entry wa-lazy-change (at most the expanded folder's own)",
            state.lazyChangeEvents <= 1,
            JSON.stringify(state)
        );

        // A nested expansion still goes through the same flow: an empty
        // folder ends up neither lazy nor loading, and with no chevron.
        await page.evaluate(() => {
            document.querySelector(".svn-nav wa-tree-item.dir wa-tree-item.dir").expanded = true;
        });
        let nestedDone = true;
        try {
            await page.waitForFunction(
                () => {
                    const item = document.querySelector(".svn-nav wa-tree-item.dir wa-tree-item.dir");
                    return !item.lazy && !item.loading;
                },
                { timeout: 15000, polling: 100 }
            );
        } catch {
            nestedDone = false;
        }
        const nested = await page.evaluate(() => {
            const item = document.querySelector(".svn-nav wa-tree-item.dir wa-tree-item.dir");
            return { lazy: item.lazy, loading: item.loading, isLeaf: item.isLeaf };
        });
        record("expanding an empty subfolder clears lazy/loading and marks it a leaf", nestedDone && nested.isLeaf, JSON.stringify(nested));
    }

    record("no page errors", consoleErrors.length === 0, consoleErrors.join(" | "));
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
