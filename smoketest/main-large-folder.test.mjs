import puppeteer from "puppeteer";
import http from "node:http";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Checks the main listing of a large folder: page.mustache's
// content-visibility on "#svn-index > wa-tree-item" lets the browser skip
// off-screen rows, and its contain-intrinsic-block-size placeholder keeps
// scrolling sane -- a fresh page's scroll height already right, so jumping
// straight to the end shows the last entry, and the scroll height doesn't
// change while paging through rows as they get rendered.
const FILE_COUNT = 1000;
const LOAD_TIMEOUT_MS = 60000;

// --- Synthetic repository: "/big/" holds FILE_COUNT files. ---

function fileName(i) {
    return `file${String(i).padStart(4, "0")}.xml`;
}

function indexXml(repoPath) {
    let entries = "";

    if (repoPath === "/") {
        entries = '<dir name="big" href="big/" />\n';
    } else if (repoPath === "/big/") {
        for (let i = 0; i < FILE_COUNT; i++) {
            entries += `<file name="${fileName(i)}" href="${fileName(i)}" />\n`;
        }
    }

    return `<?xml version="1.0" encoding="utf-8"?>
<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="${repoPath}" base="demo1">
${entries}</index>
</svn>
`;
}

// --- Run the real Lua driver (same one nav-large-folder.test.mjs uses). ---

function renderIndexHtml(uri, headers) {
    const luaBin = process.env.LUA_BIN || "lua5.3";
    const repoPath = uri.replace(/^\/svn\/demo1/, "").replace(/\?.*$/, "");
    const args = [path.join(__dirname, "render-index.lua"), uri];
    if (headers["hx-request"]) args.push(headers["hx-target"] || "", headers["hx-current-url"] || "");
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
const origin = `http://127.0.0.1:${server.address().port}`;

let browser;
try {
    browser = await puppeteer.launch({
        headless: true,
        // Same reasoning as history-dialog.test.mjs's own launch options.
        args: process.env.CI ? ["--no-sandbox", "--disable-setuid-sandbox"] : [],
        protocolTimeout: 180000,
    });
    const page = await browser.newPage();
    await page.setViewport({ width: 1300, height: 900 });

    const pageErrors = [];
    page.on("pageerror", (err) => pageErrors.push(err.message));

    await page.goto(`${origin}/svn/demo1/big/`, { waitUntil: "domcontentloaded", timeout: LOAD_TIMEOUT_MS });
    await page.waitForFunction(() => customElements.get("wa-tree-item"), { timeout: LOAD_TIMEOUT_MS });
    await page.evaluate(() => Promise.all([...document.querySelectorAll("#svn-index > wa-tree-item")].map((i) => i.updateComplete)));

    const state = await page.evaluate(async () => {
        const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
        await frame();
        const se = document.scrollingElement;
        const rows = [...document.querySelectorAll("#svn-index > wa-tree-item")];
        // A skipped row's shadow content reports itself not visible.
        const rendered = (row) => row.shadowRoot.querySelector("[part~=item]").checkVisibility({ contentVisibilityAuto: true });
        const firstRendered = rendered(rows[0]);
        const lastRenderedBefore = rendered(rows[rows.length - 1]);
        const rowHeight = rows[0].getBoundingClientRect().height;

        // Fresh page, nothing below the fold rendered yet: jump to the end.
        const freshHeight = se.scrollHeight;
        se.scrollTop = se.scrollHeight;
        await frame();
        await frame();
        const last = rows[rows.length - 1].getBoundingClientRect();
        const lastInView = last.top >= 0 && last.bottom <= innerHeight + 1;

        // Page through from the top, rendering every row once.
        se.scrollTop = 0;
        await frame();
        let minHeight = se.scrollHeight;
        let maxHeight = se.scrollHeight;
        while (se.scrollTop + se.clientHeight < se.scrollHeight - 1) {
            se.scrollTop += se.clientHeight;
            await frame();
            minHeight = Math.min(minHeight, se.scrollHeight);
            maxHeight = Math.max(maxHeight, se.scrollHeight);
        }

        return { rows: rows.length, rowHeight, firstRendered, lastRenderedBefore, freshHeight, lastInView, minHeight, maxHeight };
    });

    record(`all ${FILE_COUNT} files are listed`, state.rows === FILE_COUNT, JSON.stringify(state));
    record(
        "off-screen rows are skipped by content-visibility, on-screen ones rendered",
        state.firstRendered && !state.lastRenderedBefore,
        JSON.stringify(state)
    );
    record("a fresh page's jump to the end shows the last entry", state.lastInView, JSON.stringify(state));
    record(
        "the scroll height stays the same while paging through and rendering every row",
        state.maxHeight - state.minHeight <= 1 && Math.abs(state.maxHeight - state.freshHeight) <= 1,
        JSON.stringify(state)
    );
    record("no page errors", pageErrors.length === 0, pageErrors.join(" | "));
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
