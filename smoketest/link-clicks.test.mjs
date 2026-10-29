import puppeteer from "puppeteer";
import http from "node:http";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Checks that file, folder and breadcrumb links behave like ordinary browser
// links for ctrl-click and middle-click (new tab, current tab untouched),
// while a plain click keeps its existing behavior. File links used to get
// a second, script-synthesized click from wa-tree's row selection (see
// page.mustache's wa-tree comment) that navigated the current tab on a
// ctrl-click; breadcrumbs used to be hx-get-only wa-breadcrumb-items with
// no link at all. Chromium's popup blocker is left ON here (Puppeteer
// disables it by default), matching what a real user's browser does.
const NEW_TAB_TIMEOUT_MS = 5000;
const SETTLE_MS = 1500;

// --- Synthetic repository, three levels deep so the breadcrumb has
// linked ancestors. ---

const LISTINGS = {
    "/": ['<dir name="trunk" href="trunk/" />'],
    "/trunk/": ['<dir name="sub" href="sub/" />', '<file name="a.xml" href="a.xml" />'],
    "/trunk/sub/": ['<dir name="deeper" href="deeper/" />'],
    "/trunk/sub/deeper/": ['<file name="d.xml" href="d.xml" />'],
};

function indexXml(repoPath) {
    return `<?xml version="1.0" encoding="utf-8"?>
<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="${repoPath}" base="demo1">
${(LISTINGS[repoPath] || []).join("\n")}
</index>
</svn>
`;
}

// --- Run the real Lua driver (same one nav-large-folder.test.mjs uses). ---

function renderIndexHtml(uri, headers) {
    const luaBin = process.env.LUA_BIN || "lua5.3";
    const repoPath = uri.replace(/^\/svn\/demo1/, "").replace(/\?.*$/, "");
    const args = [path.join(__dirname, "render-index.lua"), uri];
    if (headers["hx-request"]) args.push(headers["hx-target"] || "", headers["hx-current-url"] || "");
    const result = spawnSync(luaBin, args, { input: indexXml(repoPath), encoding: "utf8" });

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
    if (!req.url.startsWith("/svn/demo1/")) {
        res.writeHead(404).end();
        return;
    }
    // A "file": plain text, as svn would serve a file's own content.
    if (!req.url.replace(/\?.*$/, "").endsWith("/")) {
        res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
        res.end("file content");
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
const origin = `http://127.0.0.1:${port}`;

let browser;
try {
    browser = await puppeteer.launch({
        headless: true,
        // Same reasoning as history-dialog.test.mjs's own launch options.
        args: process.env.CI ? ["--no-sandbox", "--disable-setuid-sandbox"] : [],
        ignoreDefaultArgs: ["--disable-popup-blocking"],
    });

    // Loads `pagePath` in a fresh tab, performs `click` on `selector`, and
    // reports what followed: whether a new tab opened (and at what URL),
    // whether the original document survived (no full navigation), and
    // which requests the original tab itself made.
    async function clickAndObserve(pagePath, selector, click) {
        const page = await browser.newPage();
        const pageErrors = [];
        page.on("pageerror", (err) => pageErrors.push(err.message));
        await page.goto(origin + pagePath, { waitUntil: "networkidle0" });
        await page.evaluate(() =>
            Promise.all([customElements.whenDefined("wa-tree-item"), customElements.whenDefined("wa-breadcrumb-item")])
        );
        await new Promise((r) => setTimeout(r, SETTLE_MS));
        await page.evaluate(() => {
            // Main's own folder rows are hidden until "Show folders" is on.
            document.querySelector("#svn-subheader wa-switch").checked = true;
            window.__sameDocument = true;
        });
        await new Promise((r) => setTimeout(r, 300));

        const requests = [];
        page.on("request", (req) => requests.push(req.url().replace(origin, "") + (req.headers()["hx-request"] ? " (htmx)" : "")));
        // Any page target created from here on -- a ctrl/middle-click tab
        // doesn't necessarily record this page as its opener.
        const newTabs = [];
        const onTarget = (t) => t.type() === "page" && newTabs.push(t);
        browser.on("targetcreated", onTarget);

        const element = await page.waitForSelector(selector, { timeout: 5000 });
        await click(page, element);
        const deadline = Date.now() + NEW_TAB_TIMEOUT_MS;
        while (Date.now() < deadline && !newTabs.some((t) => t.url().startsWith(origin))) {
            await new Promise((r) => setTimeout(r, 100));
        }
        await new Promise((r) => setTimeout(r, SETTLE_MS));
        browser.off("targetcreated", onTarget);
        const newTabUrl = newTabs.map((t) => t.url().replace(origin, "")).join(", ") || null;
        for (const t of newTabs) await (await t.page())?.close();

        const state = await page.evaluate(() => ({
            sameDocument: window.__sameDocument === true,
            breadcrumb: [...document.querySelectorAll("#svn-breadcrumb wa-breadcrumb-item")].map((b) => b.textContent.trim()).join(" / "),
            // Nav folders left expanded, each with its own loaded child folders.
            navExpanded: [...document.querySelectorAll(".svn-nav wa-tree-item.dir")]
                .filter((i) => i.expanded)
                .map((i) => i.querySelector(":scope > span").textContent.trim() + "[" + [...i.querySelectorAll(":scope > wa-tree-item.dir > span")].map((s) => s.textContent.trim()).join(",") + "]")
                .join(" "),
        }));
        await page.close();
        return { newTabUrl, requests, pageErrors, ...state };
    }

    const plainClick = (page, el) => el.click();
    const ctrlClick = async (page, el) => {
        await page.keyboard.down("Control");
        await el.click();
        await page.keyboard.up("Control");
    };
    const middleClick = (page, el) => el.click({ button: "middle" });
    // Keyboard activation: of a tree link's own tree item (the link itself
    // is tabindex="-1" -- focus is wa-tree's own, on the item), or of a
    // breadcrumb's own link, which lives in wa-breadcrumb-item's shadow DOM
    // (where Tab lands; the host itself isn't focusable).
    const enterKey = async (page, el) => {
        await el.evaluate((e) => (e.closest("wa-tree-item") || e.shadowRoot.querySelector("a[href]")).focus());
        await page.keyboard.press("Enter");
    };

    const FILE_LINK = "#svn-index wa-tree-item.file > a";
    // "trunk" -- a linked ancestor of the current "deeper" folder.
    const CRUMB_LINK = "#svn-breadcrumb wa-breadcrumb-item:nth-of-type(2)";
    // "sub/", in main's listing of trunk/ and nested under trunk/ in nav.
    const MAIN_FOLDER_LINK = "#svn-index wa-tree-item.dir > span > a";
    const NAV_FOLDER_LINK = ".svn-nav wa-tree-item.dir wa-tree-item.dir > span > a";

    // One scenario: a missing link (e.g. no breadcrumb <a> at all) or any
    // other error records a FAIL rather than aborting the remaining ones.
    async function check(name, pagePath, selector, click, passes) {
        let r;
        try {
            r = await clickAndObserve(pagePath, selector, click);
        } catch (err) {
            record(name, false, err.message);
            return;
        }
        record(name, passes(r), JSON.stringify(r));
    }

    await check(
        "file: plain click navigates the current tab, requesting the file exactly once",
        "/svn/demo1/trunk/", FILE_LINK, plainClick,
        (r) => !r.newTabUrl && r.requests.filter((u) => u === "/svn/demo1/trunk/a.xml").length === 1
    );
    await check(
        "file: ctrl-click opens the file in a new tab and leaves the current tab alone",
        "/svn/demo1/trunk/", FILE_LINK, ctrlClick,
        (r) => r.newTabUrl === "/svn/demo1/trunk/a.xml" && r.sameDocument && r.requests.length === 0
    );
    await check(
        "file: middle-click opens the file in a new tab and leaves the current tab alone",
        "/svn/demo1/trunk/", FILE_LINK, middleClick,
        (r) => r.newTabUrl === "/svn/demo1/trunk/a.xml" && r.sameDocument && r.requests.length === 0
    );
    await check(
        "breadcrumb: plain click swaps in place via htmx, with no full page load",
        "/svn/demo1/trunk/sub/deeper/", CRUMB_LINK, plainClick,
        (r) => !r.newTabUrl && r.sameDocument && r.requests.join() === "/svn/demo1/trunk/ (htmx)" && r.breadcrumb === "demo1/ / trunk/"
    );
    await check(
        "breadcrumb: ctrl-click opens the folder in a new tab and leaves the current tab alone",
        "/svn/demo1/trunk/sub/deeper/", CRUMB_LINK, ctrlClick,
        (r) => r.newTabUrl === "/svn/demo1/trunk/" && r.sameDocument && r.requests.length === 0 && r.breadcrumb.endsWith("deeper/")
    );
    await check(
        "breadcrumb: middle-click opens the folder in a new tab and leaves the current tab alone",
        "/svn/demo1/trunk/sub/deeper/", CRUMB_LINK, middleClick,
        (r) => r.newTabUrl === "/svn/demo1/trunk/" && r.sameDocument && r.requests.length === 0 && r.breadcrumb.endsWith("deeper/")
    );

    await check(
        "breadcrumb: keyboard Enter swaps in place via htmx",
        "/svn/demo1/trunk/sub/deeper/", CRUMB_LINK, enterKey,
        (r) => !r.newTabUrl && r.sameDocument && r.requests.join() === "/svn/demo1/trunk/ (htmx)" && r.breadcrumb === "demo1/ / trunk/"
    );
    // A plain click on a nav folder also expands it in nav: a second htmx
    // request for the same folder, the nav item's own lazy load.
    const navSubOpened = (r) =>
        r.requests.length === 2 && r.requests.every((u) => u === "/svn/demo1/trunk/sub/ (htmx)") && r.navExpanded.includes("sub/[deeper/]");
    await check(
        "main folder: plain click swaps main in place via htmx, with no full page load",
        "/svn/demo1/trunk/", MAIN_FOLDER_LINK, plainClick,
        (r) => !r.newTabUrl && r.sameDocument && r.requests.join() === "/svn/demo1/trunk/sub/ (htmx)" && r.breadcrumb === "demo1/ / trunk/ / sub/"
    );
    await check(
        "nav folder: plain click swaps main in place via htmx and expands the folder in nav",
        "/svn/demo1/trunk/", NAV_FOLDER_LINK, plainClick,
        (r) => !r.newTabUrl && r.sameDocument && navSubOpened(r) && r.breadcrumb === "demo1/ / trunk/ / sub/"
    );
    for (const [where, link] of [["main", MAIN_FOLDER_LINK], ["nav", NAV_FOLDER_LINK]]) {
        await check(
            `${where} folder: ctrl-click opens the folder in a new tab and leaves the current tab alone`,
            "/svn/demo1/trunk/", link, ctrlClick,
            (r) => r.newTabUrl === "/svn/demo1/trunk/sub/" && r.sameDocument && r.requests.length === 0 && r.breadcrumb === "demo1/ / trunk/"
        );
        await check(
            `${where} folder: middle-click opens the folder in a new tab and leaves the current tab alone`,
            "/svn/demo1/trunk/", link, middleClick,
            (r) => r.newTabUrl === "/svn/demo1/trunk/sub/" && r.sameDocument && r.requests.length === 0 && r.breadcrumb === "demo1/ / trunk/"
        );
    }
    await check(
        "nav folder: keyboard Enter on its tree item swaps main in place and expands the folder in nav",
        "/svn/demo1/trunk/", NAV_FOLDER_LINK, enterKey,
        (r) => !r.newTabUrl && r.sameDocument && navSubOpened(r) && r.breadcrumb === "demo1/ / trunk/ / sub/"
    );
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
