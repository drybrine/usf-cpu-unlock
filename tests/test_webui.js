// Host-side test for module/webroot/index.html — runs the page's actual
// script under Node with stubbed window/ksu/document, feeding it the real
// `usfcpu.sh status` output format, and asserting the rendered state.
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

const SAMPLE = [
  "module      : usf-cpu-unlock v1.0.5",
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

const SAMPLE_STOCK = [
  "module      : usf-cpu-unlock v1.0.5",
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

let currentSample = SAMPLE;
const execCalls = [];
const toasts = [];

// ksu.exec per the npm "kernelsu" 3.0.2 contract: callback style.
const ksu = {
  exec(cmd, optionsJson, callbackName) {
    execCalls.push(cmd);
    if (typeof optionsJson !== "string") throw new Error("options must be a JSON string");
    setTimeout(() => {
      const cb = globalThis[callbackName];
      if (typeof cb === "function") cb(0, currentSample, "");
    }, 5);
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

(async () => {
  eval(script); // defines functions and fires refresh() at the end

  await new Promise(r => setTimeout(r, 50));

  check("refresh() issued a status command", /usfcpu\.sh status/.test(execCalls[0] || ""));
  check("version parsed", els.ver.textContent === "v1.0.5");
  check("state label ACTIVE", els.stateLbl.textContent === "Patch ACTIVE");
  check("dot is green", /(^|\s)on(\s|$)/.test(els.dot.className));
  check("little cluster unlocked", els.p0.textContent.indexOf("2.00") !== -1 && els.p0.textContent.indexOf("\u2713") !== -1);
  check("big cluster unlocked", els.p4.textContent.indexOf("2.60") !== -1 && els.p4.textContent.indexOf("\u2713") !== -1);
  check("engine level shown", els.engine.textContent.indexOf("level 43") !== -1);
  check("engine no-cap noted", els.engine.textContent.indexOf("no CPU cap") !== -1);
  check("pid shown", els.pid.textContent === "18354");
  check("log contains status text", els.log.textContent.indexOf("patch mount: ACTIVE") !== -1);

  // --- stock sample ----------------------------------------------------------
  currentSample = SAMPLE_STOCK;
  els.ver.textContent = ""; els.stateLbl.textContent = ""; els.p0.textContent = "";
  els.p4.textContent = ""; els.engine.textContent = ""; els.pid.textContent = "";
  els.log.children = [];

  // invoke the page's own refresh handler
  els.btnRefresh.onclick ? els.btnRefresh.onclick() : null;
  await new Promise(r => setTimeout(r, 50));

  check("stock: state label", els.stateLbl.textContent === "Stock behavior");
  check("stock: dot is red", /(^|\s)off(\s|$)/.test(els.dot.className));
  check("stock: little capped", els.p0.textContent.indexOf("1.80") !== -1 && els.p0.textContent.indexOf("\u2713") === -1);
  check("stock: big capped", els.p4.textContent.indexOf("2.20") !== -1 && els.p4.textContent.indexOf("\u2713") === -1);
  check("stock: engine level 41 without no-cap", els.engine.textContent.indexOf("level 41") !== -1 && els.engine.textContent.indexOf("no CPU cap") === -1);

  console.log(failures === 0 ? "\nwebui tests: all passed" : "\nwebui tests: " + failures + " FAILED");
  process.exit(failures === 0 ? 0 : 1);
})().catch(e => { console.error("FAIL harness error:", e); process.exit(1); });
