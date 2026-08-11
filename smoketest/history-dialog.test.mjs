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

    // Nested inside a real <wa-page> element, mirroring page.mustache's own
    // structure (the dialog is an unslotted -- default-slot -- child of
    // <wa-page>, not a sibling after it): page.mustache's
    // "wa-page[view='desktop']" / "wa-page[view='mobile']" rules depend on
    // ".log-summary" etc. actually being descendants of <wa-page>. Left
    // with no "view" attribute by default -- wrapWithView() below sets one
    // for the desktop/mobile-specific checks.
    return `<!DOCTYPE html>
<html lang="en" class="wa-cloak">
<head>
<meta charset="utf-8">
<title>History dialog smoke test</title>
<script>
// Stubs out "wa-page" as a trivial, do-nothing custom element BEFORE the
// CDN autoloader below (a deferred module script, so this synchronous one
// always runs first) gets a chance to load and register the real
// component. Only the CSS attribute selector ("wa-page[view='...']")
// needs this tag to exist -- the real component's own JS is a
// ResizeObserver-driven "view" resolution expecting full header/nav/menu
// context this minimal dialog-only harness doesn't provide, and would
// fight the "view" attribute wrapWithView() sets for the desktop/mobile
// checks below.
customElements.define("wa-page", class extends HTMLElement {});
</script>
${cdnTagLines}
${scriptBlock}
${styleBlock}
</head>
<body>
<wa-page>
${dialogOpenTag}
${expandToggleLine}
${contentDivOpenTag}
${renderedLogHtml}
</div>
</${dialogTagName}>
</wa-page>
</body>
</html>
`;
}

// Sets the "view" attribute on the harness's own <wa-page> element (see
// buildHarness() above), purely as a CSS selector target for
// page.mustache's "wa-page[view='desktop']" / "wa-page[view='mobile']"
// rules -- attribute selectors match on any element in the DOM regardless
// of whether the custom element's own JS has upgraded it, so this doesn't
// need to load wa-page's real definition or simulate its resize/breakpoint
// behavior, both out of scope for this smoke test. Anchored to the
// literal, whole-line "<wa-page>" tag (not a plain substring replace)
// because the inline <script> block's own comments happen to contain the
// substring "<wa-page>" in prose earlier in the file.
function wrapWithView(html, view) {
    return html.replace(/^<wa-page>$/m, `<wa-page view="${view}">`);
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
    let body = harness;
    if (req.url === "/desktop") body = wrapWithView(harness, "desktop");
    else if (req.url === "/mobile") body = wrapWithView(harness, "mobile");
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(body);
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

    // Regression check: all 3 entries' collapsed message previews must
    // start at exactly the same horizontal position, regardless of
    // author-name length (a real username can be a full email address,
    // not just a short handle -- not safe to size a column around a
    // guessed length) or message length. ".log-message-preview" gets
    // there via a fixed margin-left tied to --log-revision-column (see
    // page.mustache), the same column ".log-body" indents to when
    // expanded -- not by flowing after a fixed-width author field, which
    // an earlier version tried and is exactly the kind of guess that
    // breaks the moment a real author value is longer than assumed.
    // (That earlier, flex-row-based approach also had its own once-real
    // bug, now moot: a flex item using "display: -webkit-box" for its
    // line-clamp defaulted to a "flex-basis: auto" that sized from its
    // own unclamped content's preferred width, tripping the row's own
    // flex-wrap for the one entry with a long message and dropping the
    // ENTIRE preview to a new line. With nothing to share a row with
    // anymore, that whole class of bug no longer applies.)
    const previewLefts = await page.evaluate(() =>
        [...document.querySelectorAll(".log-message-preview")].map((el) => el.getBoundingClientRect().left)
    );
    const maxPreviewLeftSpread = Math.max(...previewLefts) - Math.min(...previewLefts);
    record(
        "all 3 collapsed message previews start at exactly the same horizontal position",
        maxPreviewLeftSpread <= 2, // px rounding only -- a fixed margin-left, not a guessed width
        JSON.stringify(previewLefts)
    );

    // Regression check: the revision badge itself must stay tight around
    // its own digits (this was briefly widened to the full fixed-indent
    // column while solving the ".log-body" alignment problem, then
    // deliberately reverted) -- the fixed column width instead lives on
    // the wrapping ".log-revision-slot", not the badge. A 3-digit
    // revision's own badge should render much narrower than the
    // 4rem/64px column it sits inside.
    const revisionSizes = await page.evaluate(() => {
        const item = document.querySelectorAll("wa-details.log-item")[0];
        const slot = item.querySelector(".log-revision-slot");
        const badge = item.querySelector(".revision-badge");
        return { slotWidth: slot.getBoundingClientRect().width, badgeWidth: badge.getBoundingClientRect().width };
    });
    record(
        "revision badge itself is tight around the digits, narrower than its fixed-width slot",
        revisionSizes.badgeWidth < revisionSizes.slotWidth - 10,
        JSON.stringify(revisionSizes)
    );
    record(
        "revision slot reserves the full fixed indent column (~64px for 4rem)",
        Math.abs(revisionSizes.slotWidth - 64) <= 4,
        JSON.stringify(revisionSizes)
    );

    // Regression check for the actual bug this smoke test was built to
    // catch: white-space: pre-line was preserving an incidental
    // template-source newline as a visible blank line, wasting half the
    // intended 2-line clamp. A short (1-line) message must produce a
    // clientHeight of ~1 line-height (not 2, which would mean a phantom
    // blank line is still being reserved); a long message must produce
    // ~2 line-heights AND scrollHeight > clientHeight (confirms real
    // overflow is being clamped, not coincidentally short content).
    // Measured here, before anything is expanded: ".log-message-preview"
    // is deliberately display:none once its own entry is open (see the
    // "shown once" checks below), so this only makes sense against the
    // pristine, all-collapsed state.
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
    const previewHandlesCollapsed = await page.$$(".log-message-preview");
    await previewHandlesCollapsed[1].screenshot({ path: path.join(OUTPUT_DIR, "04-clamp-zoom.png") });
    await page.setViewport({ width: 1000, height: 900 });

    // Indentation check: the summary row's own second field (the date,
    // right after the fixed-width revision-badge column) and the body's
    // own content (only reachable by opening an entry) should share
    // exactly the same left edge. Opens just the first entry to measure
    // this, then leaves it open (the next assertion block re-derives
    // state fresh rather than assuming collapsed).
    await page.evaluate(() => {
        document.querySelectorAll("wa-details.log-item")[0].open = true;
    });
    await new Promise((r) => setTimeout(r, 150));
    const indentCheck = await page.evaluate(() => {
        const item = document.querySelectorAll("wa-details.log-item")[0];
        const dateLeft = item.querySelector("wa-format-date").getBoundingClientRect().left;
        const bodyLeft = item.querySelector(".log-body").getBoundingClientRect().left;
        return { dateLeft, bodyLeft };
    });
    record(
        "summary's second field and the expanded body share the same left indentation",
        Math.abs(indentCheck.dateLeft - indentCheck.bodyLeft) <= TOLERANCE,
        JSON.stringify(indentCheck)
    );
    await page.evaluate(() => {
        document.querySelectorAll("wa-details.log-item")[0].open = false;
    });
    await new Promise((r) => setTimeout(r, 150));

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
            hasIcons: ["plus", "pen", "trash"].every((n) => html.includes(`name="${n}"`)),
            hasNoArrowIcon: !html.includes("arrow-right"),
            hasSmallRevisionBadge: html.includes('<span class="revision-badge revision-badge-small">90</span>'),
            hasNoAtSign: !html.includes("@90"),
        };
    });
    record("full (uncapped) commit message visible when expanded", expandedChecks.hasFullMessage);
    record("copy-from source indicator rendered", expandedChecks.hasCopyFrom);
    record("changed-path icons present", expandedChecks.hasIcons);
    record("no arrow icon before the copy-from source (removed, was confusing)", expandedChecks.hasNoArrowIcon);
    record("copy-from source revision rendered as a small revision badge", expandedChecks.hasSmallRevisionBadge);
    record("copy-from source revision has no '@' sign", expandedChecks.hasNoAtSign);

    // "Shown once" check: with every entry expanded, every collapsed
    // preview must be hidden (not just visually clamped) and every full
    // message must be the one actually visible -- the same text should
    // never be presented twice at once.
    const shownOnceWhenExpanded = await page.evaluate(() => {
        const previews = [...document.querySelectorAll(".log-message-preview")];
        const fulls = [...document.querySelectorAll(".log-message-full")];
        return {
            previewsHidden: previews.every((el) => getComputedStyle(el).display === "none"),
            fullsVisible: fulls.every((el) => getComputedStyle(el).display !== "none"),
        };
    });
    record(
        "clamped preview is hidden (not shown alongside the full message) once expanded",
        shownOnceWhenExpanded.previewsHidden,
        JSON.stringify(shownOnceWhenExpanded)
    );
    record("full message is visible once expanded", shownOnceWhenExpanded.fullsVisible);

    // Icon alignment: the comment icon on the expanded full message and
    // the action icon on each changed-path <li> both use Web Awesome's
    // "wa-flank" utility (see log-item.mustache) with a shared
    // "--flank-size" (see ".log-body" in page.mustache) specifically so
    // they land in the same vertical line regardless of each icon's own
    // glyph metrics -- verified here via actual rendered x-positions, not
    // just "both use wa-flank so it should be fine".
    const iconAlignment = await page.evaluate(() => {
        const item = [...document.querySelectorAll("wa-details.log-item")].find(
            (el) => el.querySelector(".changed-paths li")
        );
        const messageIcon = item.querySelector(".log-message-full wa-icon");
        const pathIcon = item.querySelector(".changed-paths li wa-icon");
        return {
            messageIconLeft: messageIcon.getBoundingClientRect().left,
            pathIconLeft: pathIcon.getBoundingClientRect().left,
        };
    });
    record(
        "changed-path icon aligns horizontally with the log message icon",
        Math.abs(iconAlignment.messageIconLeft - iconAlignment.pathIconLeft) <= TOLERANCE,
        JSON.stringify(iconAlignment)
    );

    // Sanity check that "wa-flank" is actually controlling the layout
    // (not silently overridden by this app's own later-loaded stylesheet
    // redeclaring a conflicting "display" on the same selector -- exactly
    // the mistake avoided by deliberately NOT redeclaring "display" on
    // ".changed-paths li" once it became a "wa-flank", see that rule's
    // own comment in page.mustache). A flex/grid display and the message
    // icon sitting to the LEFT of (not above/overlapping) the message
    // text are what "flanking" actually means structurally.
    const flankSanity = await page.evaluate(() => {
        const full = document.querySelector(".log-message-full");
        const icon = full.querySelector("wa-icon");
        const em = full.querySelector("em");
        return {
            display: getComputedStyle(full).display,
            iconRight: icon.getBoundingClientRect().right,
            emLeft: em.getBoundingClientRect().left,
        };
    });
    record(
        ".log-message-full's display is flex/grid (wa-flank active, not overridden)",
        flankSanity.display === "flex" || flankSanity.display === "grid",
        JSON.stringify(flankSanity)
    );
    record(
        "message icon sits to the left of the message text (flanking, not stacked/overlapping)",
        flankSanity.iconRight <= flankSanity.emLeft + TOLERANCE,
        JSON.stringify(flankSanity)
    );

    // Regression check: .log-message-full must use "pre-wrap" (preserves
    // runs of multiple spaces/tabs, e.g. an indented bullet list pasted
    // into a commit message -- see the "carol" fixture entry's own
    // "  - added main.c" lines), not "pre-line" (which would collapse
    // that indentation). .log-message-preview is fine with "pre-line" --
    // it's an already-truncated summary, not the "exactly as written"
    // view. A direct computed-style check, not a pixel-position
    // inference, since font rendering could make the latter flaky.
    const whiteSpaceModes = await page.evaluate(() => ({
        preview: getComputedStyle(document.querySelector(".log-message-preview")).whiteSpace,
        full: getComputedStyle(document.querySelector(".log-message-full")).whiteSpace,
    }));
    record(
        ".log-message-full uses white-space: pre-wrap (full fidelity for multi-space formatting)",
        whiteSpaceModes.full === "pre-wrap",
        JSON.stringify(whiteSpaceModes)
    );
    record(
        ".log-message-preview uses white-space: pre-line (acceptable for an already-truncated summary)",
        whiteSpaceModes.preview === "pre-line",
        JSON.stringify(whiteSpaceModes)
    );

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

    // 8. No console/page errors during the whole run.
    record("no console/page errors during the whole run", consoleErrors.length === 0, consoleErrors.join(" | "));

    // 9. Responsive layout, driven by wa-page's own "view" attribute (see
    // wrapWithView() above): desktop puts the collapsed message in a
    // fixed-width column (not one that merely flexes to fill whatever
    // space is left) shoved to the row's right edge via margin-left:auto,
    // to the right of a meta column that ellipsis-truncates a long author
    // value rather than letting it push the message an unpredictable
    // distance -- the fixture's "bob.johansson@example.com" entry exists
    // specifically to exercise this. Both columns are sized with
    // clamp(min, %, max) rather than a flat rem value, so they scale with
    // the dialog's own (viewport-relative) width instead of staying fixed
    // while the dialog around them doesn't -- checked at two different
    // viewport widths below to confirm they actually do. Mobile keeps the
    // existing stacked layout and drops the left indent entirely, for
    // both the collapsed preview and the expanded body, to reclaim width
    // on a narrow screen.
    await page.setViewport({ width: 1200, height: 900 });
    await page.goto(`http://127.0.0.1:${port}/desktop`, { waitUntil: "networkidle0" });
    await page.evaluate(() =>
        Promise.all([customElements.whenDefined("wa-details"), customElements.whenDefined("wa-icon")])
    );

    const desktopCollapsed = await page.evaluate(() => {
        const items = [...document.querySelectorAll(".log-item")];
        const emailItem = items.find((el) => el.querySelector(".log-author strong").textContent.includes("@"));
        const summary = emailItem.querySelector(".log-summary");
        const meta = emailItem.querySelector(".log-summary-meta");
        const authorStrong = emailItem.querySelector(".log-author strong");
        const preview = emailItem.querySelector(".log-message-preview");
        // Every entry's preview width AND left edge, to confirm the column
        // is a fixed size AND a fixed position regardless of message length
        // (not content-dependent, the way a flex-grow column filling
        // leftover space would be, or a fixed-but-right-aligned column
        // whose *visible text* still starts at a different x per entry
        // depending on how much of the column its own text fills).
        const previewWidths = items.map((el) => el.querySelector(".log-message-preview").getBoundingClientRect().width);
        const previewLefts = items.map((el) => el.querySelector(".log-message-preview").getBoundingClientRect().left);
        return {
            row: getComputedStyle(summary).flexDirection === "row",
            authorTruncated: authorStrong.scrollWidth > authorStrong.clientWidth + 1,
            previewNotRightAligned: getComputedStyle(preview).textAlign !== "right",
            previewRightOfMeta: preview.getBoundingClientRect().left >= meta.getBoundingClientRect().right - 1,
            previewFlushRight: Math.abs(preview.getBoundingClientRect().right - summary.getBoundingClientRect().right) <= 1,
            previewWidths,
            previewLefts,
        };
    });
    record(
        "desktop: summary is a single row (meta + message side by side)",
        desktopCollapsed.row,
        JSON.stringify(desktopCollapsed)
    );
    record(
        "desktop: a long (email-address) author truncates with an ellipsis instead of pushing the message",
        desktopCollapsed.authorTruncated,
        JSON.stringify(desktopCollapsed)
    );
    record(
        "desktop: collapsed message sits to the right of the meta column, not right-aligned within its own column",
        desktopCollapsed.previewNotRightAligned && desktopCollapsed.previewRightOfMeta,
        JSON.stringify(desktopCollapsed)
    );
    record(
        "desktop: message column is a fixed width, identical across entries regardless of message length",
        new Set(desktopCollapsed.previewWidths.map((w) => Math.round(w))).size === 1,
        JSON.stringify(desktopCollapsed.previewWidths)
    );
    record(
        "desktop: every entry's message text starts at exactly the same x position (a real column, not ragged right-aligned text)",
        new Set(desktopCollapsed.previewLefts.map((l) => Math.round(l))).size === 1,
        JSON.stringify(desktopCollapsed.previewLefts)
    );
    record(
        "desktop: message column is shoved flush to the row's right edge",
        desktopCollapsed.previewFlushRight,
        JSON.stringify(desktopCollapsed)
    );

    // Both columns are sized with clamp(min, %, max) specifically so they
    // scale with the dialog's own (viewport-relative) width -- re-measured
    // here at a much wider viewport to confirm that's actually happening,
    // not just that the clamp() min/max bounds are being hit both times
    // (which would look identical to a flat rem value from the checks
    // above alone). Widened enough that the "%" term, not either clamp()
    // bound, should be what's controlling both widths at both sizes.
    await page.setViewport({ width: 1800, height: 900 });
    await page.evaluate(() =>
        Promise.all([customElements.whenDefined("wa-details"), customElements.whenDefined("wa-icon")])
    );
    const desktopWide = await page.evaluate(() => {
        const items = [...document.querySelectorAll(".log-item")];
        return {
            metaWidths: items.map((el) => el.querySelector(".log-summary-meta").getBoundingClientRect().width),
            previewWidths: items.map((el) => el.querySelector(".log-message-preview").getBoundingClientRect().width),
        };
    });
    record(
        "desktop: meta column is still identical across entries at a much wider viewport",
        new Set(desktopWide.metaWidths.map((w) => Math.round(w))).size === 1,
        JSON.stringify(desktopWide.metaWidths)
    );
    record(
        "desktop: message column is still identical across entries at a much wider viewport",
        new Set(desktopWide.previewWidths.map((w) => Math.round(w))).size === 1,
        JSON.stringify(desktopWide.previewWidths)
    );
    record(
        "desktop: message column actually grows at a wider viewport (scales with the dialog, not a flat rem value)",
        desktopWide.previewWidths[0] > desktopCollapsed.previewWidths[0] + 10,
        JSON.stringify({ at1200: desktopCollapsed.previewWidths[0], at1800: desktopWide.previewWidths[0] })
    );

    // Regression check: ".log-message-preview" was originally
    // flex-shrink:0 (rigid), which forced 100% of any space deficit onto
    // ".log-summary-meta" alone -- on a tight row that crushed even a
    // short author value like "alice" down to "a..". A hard "min-width"
    // on meta was tried as a fix and rejected too (it blocked clamp()'s
    // own smooth scaling, hard-pinning meta the moment its floor was hit
    // while message kept absorbing the rest of the deficit alone -- the
    // same concentration problem, just shifted to the other column).
    // The actual fix: both columns are shrinkable now, sharing any
    // deficit via normal flex distribution, so neither one should ever
    // need to collapse past its own declared clamp() floor. A narrow
    // desktop viewport (near where the row genuinely doesn't have room to
    // spare) is where that would show up; not caught by the wider
    // viewport checks above, which had enough room that neither column
    // needed to shrink past its own preferred size.
    await page.setViewport({ width: 1000, height: 900 });
    await page.evaluate(() =>
        Promise.all([customElements.whenDefined("wa-details"), customElements.whenDefined("wa-icon")])
    );
    const desktopNarrow = await page.evaluate(() => {
        const items = [...document.querySelectorAll(".log-item")];
        return {
            metaWidths: items.map((el) => el.querySelector(".log-summary-meta").getBoundingClientRect().width),
            previewWidths: items.map((el) => el.querySelector(".log-message-preview").getBoundingClientRect().width),
            authorTexts: items.map((el) => el.querySelector(".log-author strong").textContent),
            authorWidths: items.map((el) => el.querySelector(".log-author strong").getBoundingClientRect().width),
        };
    });
    record(
        "desktop: meta column never shrinks below its own clamp() floor (20rem/320px), even on a tight row",
        desktopNarrow.metaWidths.every((w) => w >= 320 - TOLERANCE),
        JSON.stringify(desktopNarrow.metaWidths)
    );
    record(
        "desktop: message column never shrinks below its own clamp() floor (16rem/256px), even on a tight row",
        desktopNarrow.previewWidths.every((w) => w >= 256 - TOLERANCE),
        JSON.stringify(desktopNarrow.previewWidths)
    );
    record(
        "desktop: a short author value is never crushed to near-nothing on a tight row (the original 'a..' bug)",
        desktopNarrow.authorWidths.every((w, i) => desktopNarrow.authorTexts[i].includes("@") || w > 20),
        JSON.stringify({ texts: desktopNarrow.authorTexts, widths: desktopNarrow.authorWidths })
    );
    await page.setViewport({ width: 1200, height: 900 });

    await page.click("#history-expand-toggle");
    await new Promise((r) => setTimeout(r, 200));
    const desktopBodyIndent = await page.evaluate(() => getComputedStyle(document.querySelector(".log-body")).marginLeft);
    record("desktop: expanded content keeps its left indent", desktopBodyIndent !== "0px", desktopBodyIndent);

    await page.setViewport({ width: 400, height: 900 });
    await page.goto(`http://127.0.0.1:${port}/mobile`, { waitUntil: "networkidle0" });
    await page.evaluate(() =>
        Promise.all([customElements.whenDefined("wa-details"), customElements.whenDefined("wa-icon")])
    );

    const mobileCollapsed = await page.evaluate(() => {
        const summary = document.querySelector(".log-summary");
        const preview = document.querySelector(".log-message-preview");
        return {
            stacked: getComputedStyle(summary).flexDirection === "column",
            previewMarginLeft: getComputedStyle(preview).marginLeft,
        };
    });
    record(
        "mobile: summary stays stacked (meta row, then message on its own row)",
        mobileCollapsed.stacked,
        JSON.stringify(mobileCollapsed)
    );
    record(
        "mobile: collapsed message also drops its left indent (reclaims width)",
        mobileCollapsed.previewMarginLeft === "0px",
        JSON.stringify(mobileCollapsed)
    );

    await page.click("#history-expand-toggle");
    await new Promise((r) => setTimeout(r, 200));
    const mobileBodyIndent = await page.evaluate(() => getComputedStyle(document.querySelector(".log-body")).marginLeft);
    record("mobile: expanded content drops its left indent (reclaims width)", mobileBodyIndent === "0px", mobileBodyIndent);
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
