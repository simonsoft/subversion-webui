import puppeteer from "puppeteer";
import http from "node:http";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const OUTPUT_DIR = path.join(__dirname, "output");
const PAGE_MUSTACHE_PATH = path.join(ROOT, "templates", "wa-page", "page.mustache");

// --- Extract the real <script>/<style> blocks + CDN tags from
// page.mustache, by string search on the literal markers rather than
// hardcoded line numbers, so this automatically tracks future edits to
// page.mustache instead of testing a stale frozen copy. ---

function extractBlock(source, openTag, closeTag, label) {
    // The bare "<script>"/"<style>" markers (no attributes) are used
    // deliberately: page.mustache's two CDN <script> tags always carry
    // attributes (type=/src=/integrity=), so they never match the bare
    // opening-tag literal -- only the single inline block does. Requiring
    // exactly one match means this fails loudly instead of silently
    // extracting the wrong thing if page.mustache is ever restructured.
    const occurrences = source.split(openTag).length - 1;
    if (occurrences !== 1) {
        throw new Error(
            `expected exactly one bare "${openTag}" in page.mustache for the ${label} block, found ${occurrences} -- page.mustache's structure has changed; update extractBlock()'s assumptions in history-dialog.test.mjs.`
        );
    }

    const start = source.indexOf(openTag);
    // Search for the closing tag starting AFTER the opening tag's own
    // position -- page.mustache's two CDN <script ...></script> tags close
    // on the same line they open, and both appear earlier in the file than
    // the bare <script> block, so a from-index search here correctly skips
    // them and lands on this block's own closing tag.
    const closeStart = source.indexOf(closeTag, start);
    if (closeStart === -1) {
        throw new Error(`no closing "${closeTag}" found after the ${label} block's opening tag.`);
    }

    return source.slice(start, closeStart + closeTag.length);
}

function extractCdnTagLines(source) {
    const lines = source
        .split("\n")
        .filter((line) => line.includes("ka-f.webawesome.com") || line.includes("cdn.jsdelivr.net/npm/htmx.org"));

    if (lines.length !== 3) {
        throw new Error(
            `expected exactly 3 CDN tag lines (webawesome stylesheet + loader, htmx script) in page.mustache, found ${lines.length} -- update extractCdnTagLines().`
        );
    }

    return lines.join("\n");
}

function extractLineContaining(source, needle, label) {
    const lines = source.split("\n").filter((line) => line.includes(needle));

    if (lines.length !== 1) {
        throw new Error(`expected exactly one line containing ${JSON.stringify(needle)} (${label}), found ${lines.length}.`);
    }

    return lines[0];
}

async function buildHarness(renderedLogHtml) {
    const source = await readFile(PAGE_MUSTACHE_PATH, "utf8");

    const scriptBlock = extractBlock(source, "<script>", "</script>", "inline <script>");
    const styleBlock = extractBlock(source, "<style>", "</style>", "<style>");
    const cdnTagLines = extractCdnTagLines(source);

    let dialogOpenTag = extractLineContaining(source, 'id="history-dialog"', "#history-dialog");
    // Statically pre-opened: this harness isn't exercising the real htmx
    // REPORT fetch, only what happens once the dialog already has content.
    dialogOpenTag = dialogOpenTag.replace('id="history-dialog"', 'id="history-dialog" open');

    const expandToggleLine = extractLineContaining(source, 'id="history-expand-toggle"', "#history-expand-toggle");

    const contentDivLine = extractLineContaining(source, 'id="history-content"', "#history-content");
    const contentDivOpenTagMatch = contentDivLine.match(/^<div id="history-content">/);
    if (!contentDivOpenTagMatch) {
        throw new Error('could not find a literal \'<div id="history-content">\' opening tag in page.mustache.');
    }
    const contentDivOpenTag = contentDivOpenTagMatch[0];

    const dialogTagNameMatch = dialogOpenTag.match(/^<(\w[\w-]*)/);
    if (!dialogTagNameMatch) {
        throw new Error("could not determine the #history-dialog element's own tag name.");
    }
    const dialogTagName = dialogTagNameMatch[1];

    return `<!DOCTYPE html>
<html lang="en" class="wa-cloak">
<head>
<meta charset="utf-8">
<title>History dialog smoke test</title>
${cdnTagLines}
${scriptBlock}
${styleBlock}
</head>
<body>
${dialogOpenTag}
${expandToggleLine}
${contentDivOpenTag}
${renderedLogHtml}
</div>
</${dialogTagName}>
</body>
</html>
`;
}

// --- Run the real Lua driver (renders real HTML via the actual
// mod-lua/svn-log.lua output_filter, not a hand-approximated mock). ---

function renderLogHtml() {
    const luaBin = process.env.LUA_BIN || "lua5.3";
    const result = spawnSync(luaBin, [path.join(__dirname, "render-fixture.lua")], { encoding: "utf8" });

    if (result.error) {
        throw new Error(
            `failed to launch "${luaBin}": ${result.error.message} (set the LUA_BIN environment variable to override the interpreter name, e.g. LUA_BIN=lua)`
        );
    }
    if (result.status !== 0) {
        throw new Error(`render-fixture.lua exited with status ${result.status}:\n${result.stderr}`);
    }
    if (result.stderr) {
        process.stderr.write(result.stderr);
    }

    return result.stdout;
}

// --- main ---

const results = [];
const record = (name, pass, detail) => {
    results.push({ name, pass, detail });
    console.log(`${pass ? "PASS" : "FAIL"}: ${name}${detail ? " -- " + detail : ""}`);
};

await mkdir(OUTPUT_DIR, { recursive: true });

const renderedLogHtml = renderLogHtml();
const harness = await buildHarness(renderedLogHtml);
await writeFile(path.join(OUTPUT_DIR, "harness.html"), harness, "utf8");

const server = http.createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(harness);
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;

let browser;
try {
    browser = await puppeteer.launch({ headless: true });
    const page = await browser.newPage();
    await page.setViewport({ width: 1000, height: 900 });

    const consoleErrors = [];
    page.on("pageerror", (err) => consoleErrors.push("pageerror: " + err.message));
    page.on("console", (msg) => {
        if (msg.type() === "error") consoleErrors.push("console.error: " + msg.text());
    });

    await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle0" });
    await page.evaluate(() =>
        Promise.all([
            customElements.whenDefined("wa-dialog"),
            customElements.whenDefined("wa-details"),
            customElements.whenDefined("wa-button"),
            customElements.whenDefined("wa-format-date"),
            customElements.whenDefined("wa-icon"),
        ])
    );
    await new Promise((r) => setTimeout(r, 300)); // let wa-format-date actually paint

    // 1. All entries start collapsed.
    const initialStates = await page.evaluate(() =>
        [...document.querySelectorAll("wa-details.log-item")].map((d) => d.open)
    );
    record(
        "3 entries present, all start collapsed",
        initialStates.length === 3 && initialStates.every((o) => o === false),
        JSON.stringify(initialStates)
    );

    await page.screenshot({ path: path.join(OUTPUT_DIR, "01-collapsed.png"), fullPage: true });

    // 2. wa-format-date renders a real formatted date, not raw ISO text.
    const dateText = await page.evaluate(
        () => document.querySelector("wa-format-date")?.shadowRoot?.textContent?.trim() || ""
    );
    record(
        "wa-format-date rendered non-empty formatted text",
        dateText.length > 0 && !dateText.includes("2026-08-10T"),
        `rendered: "${dateText}"`
    );

    // 3. Clicking the revision-badge <a> does not also toggle details open.
    await page.evaluate(() => {
        document.querySelectorAll("a.revision-badge").forEach((a) => a.addEventListener("click", (e) => e.preventDefault()));
    });
    const firstBadge = await page.$("wa-details.log-item a.revision-badge");
    await firstBadge.click();
    await new Promise((r) => setTimeout(r, 150));
    const afterBadgeClick = await page.evaluate(() => document.querySelector("wa-details.log-item").open);
    record("clicking revision-badge link does not toggle the details open", afterBadgeClick === false);

    // 4. "Expand all" opens every entry and relabels to "Collapse all".
    await page.click("#history-expand-toggle");
    await new Promise((r) => setTimeout(r, 200));
    let state = await page.evaluate(() => ({
        states: [...document.querySelectorAll("wa-details.log-item")].map((d) => d.open),
        label: document.getElementById("history-expand-toggle").textContent.trim(),
    }));
    record("Expand all opens every entry", state.states.every((o) => o === true), JSON.stringify(state.states));
    record("button label flips to 'Collapse all'", state.label === "Collapse all", state.label);

    await page.screenshot({ path: path.join(OUTPUT_DIR, "02-expanded.png"), fullPage: true });

    // 5. Expanded content sanity.
    const expandedChecks = await page.evaluate(() => {
        const html = document.getElementById("history-content").innerHTML;
        return {
            hasFullMessage: html.includes("smoke test can measure the clamp/overflow behavior"),
            hasCopyFrom: html.includes("copy-from") && html.includes("old-name.txt"),
            hasIcons: ["plus", "pen", "trash", "arrow-right"].every((n) => html.includes(`name="${n}"`)),
        };
    });
    record("full (uncapped) commit message visible when expanded", expandedChecks.hasFullMessage);
    record("copy-from source indicator rendered", expandedChecks.hasCopyFrom);
    record("all 4 changed-path/copy-from icons present", expandedChecks.hasIcons);

    // 6. Clicking again collapses everything and relabels back.
    await page.click("#history-expand-toggle");
    await new Promise((r) => setTimeout(r, 200));
    state = await page.evaluate(() => ({
        states: [...document.querySelectorAll("wa-details.log-item")].map((d) => d.open),
        label: document.getElementById("history-expand-toggle").textContent.trim(),
    }));
    record("clicking toggle again collapses every entry", state.states.every((o) => o === false));
    record("button label flips back to 'Expand all'", state.label === "Expand all", state.label);

    // 7. Manually opening ONE entry first: label must still read "Expand
    // all" (not stuck on "Collapse all"), then the toggle must correctly
    // open the remaining entries and relabel to "Collapse all".
    await page.evaluate(() => {
        document.querySelectorAll("wa-details.log-item")[1].open = true;
    });
    await new Promise((r) => setTimeout(r, 100));
    const labelWithOneOpen = await page.evaluate(() =>
        document.getElementById("history-expand-toggle").textContent.trim()
    );
    record("label still reads 'Expand all' when only one of three entries is open", labelWithOneOpen === "Expand all");

    await page.click("#history-expand-toggle");
    await new Promise((r) => setTimeout(r, 200));
    state = await page.evaluate(() => ({
        states: [...document.querySelectorAll("wa-details.log-item")].map((d) => d.open),
        label: document.getElementById("history-expand-toggle").textContent.trim(),
    }));
    record(
        "clicking Expand all with one already open still opens the remaining two",
        state.states.every((o) => o === true)
    );
    record("label reads 'Collapse all' after that click", state.label === "Collapse all");

    await page.screenshot({ path: path.join(OUTPUT_DIR, "03-final.png"), fullPage: true });

    // 8. Regression check for the actual bug this smoke test was built to
    // catch: white-space: pre-line was preserving an incidental
    // template-source newline as a visible blank line, wasting half the
    // intended 2-line clamp. A short (1-line) message must produce a
    // clientHeight of ~1 line-height (not 2, which would mean a phantom
    // blank line is still being reserved); a long message must produce
    // ~2 line-heights AND scrollHeight > clientHeight (confirms real
    // overflow is being clamped, not coincidentally short content).
    const clampInfo = await page.evaluate(() => {
        const previews = [...document.querySelectorAll(".log-message-preview")];
        return previews.map((el) => {
            const cs = getComputedStyle(el);
            return {
                clientHeight: el.clientHeight,
                scrollHeight: el.scrollHeight,
                lineHeightPx: parseFloat(cs.lineHeight),
            };
        });
    });
    // Fixture document order: rev 103 (short), rev 102 (long), rev 101 (short).
    const [shortEntry, longEntry] = clampInfo;
    const TOLERANCE = 2; // px rounding
    record(
        "short message's preview height is ~1 line-height (no phantom blank line)",
        Math.abs(shortEntry.clientHeight - shortEntry.lineHeightPx) <= TOLERANCE,
        JSON.stringify(shortEntry)
    );
    record(
        "long message's preview height is ~2 line-heights (correctly clamped)",
        Math.abs(longEntry.clientHeight - longEntry.lineHeightPx * 2) <= TOLERANCE,
        JSON.stringify(longEntry)
    );
    record(
        "long message actually overflows the clamp box (scrollHeight > clientHeight)",
        longEntry.scrollHeight > longEntry.clientHeight,
        JSON.stringify(longEntry)
    );

    // High-DPI zoomed crop of the clamped preview element for visual review.
    await page.setViewport({ width: 1000, height: 900, deviceScaleFactor: 3 });
    const previewHandles = await page.$$(".log-message-preview");
    await previewHandles[1].screenshot({ path: path.join(OUTPUT_DIR, "04-clamp-zoom.png") });

    // 9. No console/page errors during the whole run.
    record("no console/page errors during the whole run", consoleErrors.length === 0, consoleErrors.join(" | "));
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
