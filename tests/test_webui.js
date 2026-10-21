// Host-side test for module/webroot/index.html — runs the page's actual
// script under Node with stubbed window/ksu/document, feeding it the real
// `usfcpu.sh` output format, and asserting the rendered state.
//
// The stub answers `webui-quick` in 5ms and the full `status` in 40ms so the
// staged load (fast card paint -> background detail fill) is observable.
//
// Run: node tests/test_webui.js   (exit 0 = pass)

const fs = require("fs");
const path = require("path");

const html = fs.readFileSync(
  path.join(__dirname, "..", "module", "webroot", "index.html"), "utf8");

// --- extract the inline <script> body ---------------------------------------
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m) { console.error("FAIL: no inline <script> found"); process.exit(1); }
const script = m[1];

// --- minimal DOM stub ---------------------------------------------------------
function makeEl() {
  return {
    textContent: "", innerHTML: "", className: "", disabled: false,
    style: {}, onclick: null,
    children: [],
    // mirror real DOM behavior: appending a child contributes its text
    appendChild(c) { this.children.push(c); this.textContent += c.textContent; },
    scrollTop: 0, scrollHeight: 0
  };
}
const els = {};
const document = {
  getElementById(id) { return els[id] || (els[id] = makeEl()); },
  createElement() { return makeEl(); }
};

// --- samples: quick (sysfs-only) and full status -----------------------------
const QUICK_ACTIVE = [
  "module      : usf-cpu-unlock v1.3.0",
  "patch mount: ACTIVE (USF CPU cap disabled)",
  "cpufreq caps (max vs hardware max):",
  "  policy0: max=2000000 hw=2000000",
  "  policy4: max=2600000 hw=2600000"
].join("\n");

const QUICK_STOCK = [
  "module      : usf-cpu-unlock v1.3.0",
  "patch mount: inactive (stock behavior)",
  "cpufreq caps (max vs hardware max):",
  "  policy0: max=1800000 hw=2000000",
  "  policy4: max=2200000 hw=2600000"
].join("\n");

const FULL_ACTIVE = [
  "module      : usf-cpu-unlock v1.3.0",
  "module dir  : /data/adb/modules/usf-cpu-unlock",
  "active xml  : /tr_product/etc/vconfig/tranusf/config/thermal/tran_thermal.xml",
  "patch mount: ACTIVE (USF CPU cap disabled)",
  "usf pid(s) : 18354",
  "engine state (excerpt):",
  "    MTK thermal CPU limit support: ENABLED",
  "    Thermal CPU handle: 0",
  "    Current temp config: TempConfig{",
  "      tempLevel=43",
  "      cpu=0,",
  "      clusterCpu0=0,",
  "      clusterCpu1=0,",
  "      clusterCpu2=0,",
  "cpufreq caps (max vs hardware max):",
  "  policy0: max=2000000 hw=2000000",
  "  policy4: max=2600000 hw=2600000"
].join("\n");

const FULL_STOCK = [
  "module      : usf-cpu-unlock v1.3.0",
  "active xml  : /tr_product/etc/vconfig/tranusf/config/thermal/tran_thermal.xml",
  "patch mount: inactive (stock behavior)",
  "usf pid(s) : 14771",
  "    Current temp config: TempConfig{",
  "      tempLevel=41",
  "      clusterCpu0=1800000,",
  "      clusterCpu1=2200000,",
  "cpufreq caps (max vs hardware max):",
  "  policy0: max=1800000 hw=2000000",
  "  policy4: max=2200000 hw=2600000"
].join("\n");

let fullSample = FULL_ACTIVE;
let quickSample = QUICK_ACTIVE;
const execCalls = [];
const toasts = [];

// ksu.exec per the npm "kernelsu" 3.0.2 contract: callback style.
// quick commands answer in 5ms, full status in 40ms.
const ksu = {
  exec(cmd, optionsJson, callbackName) {
    execCalls.push(cmd);
    if (typeof optionsJson !== "string") throw new Error("options must be a JSON string");
    const quick = cmd.indexOf("webui-quick") !== -1;
    const out = quick ? quickSample : fullSample;
    setTimeout(() => {
      const cb = globalThis[callbackName];
      if (typeof cb === "function") cb(0, out, "");
    }, quick ? 5 : 40);
  },
  toast(msg) { toasts.push(msg); }
};

globalThis.window = globalThis;
globalThis.document = document;
globalThis.ksu = ksu;
globalThis.navigator = {};

let failures = 0;
function check(name, cond) {
  if (cond) { console.log("ok   " + name); }
  else { failures++; console.log("FAIL " + name); }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  eval(script); // defines functions and fires refresh() at the end

  // --- staged load: quick paints the card before full status returns --------
  await sleep(15); // quick done (5ms); full status still pending (40ms)

  check("first command is webui-quick", /webui-quick/.test(execCalls[0] || ""));
  check("quick: version parsed", els.ver.textContent === "v1.3.0");
  check("quick: state label ACTIVE", els.stateLbl.textContent === "Patch ACTIVE");
  check("quick: dot is green", /(^|\s)on(\s|$)/.test(els.dot.className));
  check("quick: little unlocked", els.p0.textContent.indexOf("2.00") !== -1 && els.p0.textContent.indexOf("\u2713") !== -1);
  check("quick: big unlocked", els.p4.textContent.indexOf("2.60") !== -1 && els.p4.textContent.indexOf("\u2713") !== -1);
  check("quick: engine pending (\u2013)", els.engine.textContent === "\u2013");
  check("quick: buttons re-enabled while full loads", els.btnRestore.disabled === false && els.btnRefresh.disabled === false);
  check("no Apply button in the page", html.indexOf("btnApply") === -1 && html.indexOf(">Apply<") === -1);
  check("log hidden by default", els.log.style.display === "none");

  await sleep(80); // full status (40ms) has landed

  check("full status issued in background", execCalls.some(c => /usfcpu\.sh status/.test(c)));
  check("full: engine level 43", els.engine.textContent.indexOf("level 43") !== -1);
  check("full: engine no-cap noted", els.engine.textContent.indexOf("no CPU cap") !== -1);
  check("full: pid filled", els.pid.textContent === "18354");
  check("log collected while hidden", els.log.textContent.indexOf("patch mount: ACTIVE") !== -1);

  // --- log toggle ------------------------------------------------------------
  els.btnLog.onclick();
  check("toggle: log shown", els.log.style.display === "block");
  check("toggle: label reads Hide log", els.btnLog.textContent.indexOf("Hide log") === 0);
  els.btnLog.onclick();
  check("toggle: log hidden again", els.log.style.display === "none");
  check("toggle: label reads Show log", els.btnLog.textContent.indexOf("Show log") === 0);

  // --- stock sample ----------------------------------------------------------
  fullSample = FULL_STOCK;
  quickSample = QUICK_STOCK;
  els.ver.textContent = ""; els.stateLbl.textContent = ""; els.p0.textContent = "";
  els.p4.textContent = ""; els.engine.textContent = ""; els.pid.textContent = "";

  els.btnRefresh.onclick ? els.btnRefresh.onclick() : null;
  await sleep(15);
  check("stock quick: state label", els.stateLbl.textContent === "Stock behavior");
  check("stock quick: dot is red", /(^|\s)off(\s|$)/.test(els.dot.className));
  await sleep(80);
  check("stock full: little capped", els.p0.textContent.indexOf("1.80") !== -1 && els.p0.textContent.indexOf("\u2713") === -1);
  check("stock full: big capped", els.p4.textContent.indexOf("2.20") !== -1 && els.p4.textContent.indexOf("\u2713") === -1);
  check("stock full: engine level 41 without no-cap", els.engine.textContent.indexOf("level 41") !== -1 && els.engine.textContent.indexOf("no CPU cap") === -1);

  console.log(failures === 0 ? "\nwebui tests: all passed" : "\nwebui tests: " + failures + " FAILED");
  process.exit(failures === 0 ? 0 : 1);
})().catch(e => { console.error("FAIL harness error:", e); process.exit(1); });
