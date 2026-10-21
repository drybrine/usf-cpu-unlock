// Host-side test for module/webroot/index.html — runs the page's actual
// script under Node with stubbed window/ksu/document, feeding it the real
// `usfcpu.sh` output formats, and asserting the rendered state.
//
// The page's protocol (v2.2.0):
//   webui-fast  -> the whole card in ONE call (sysfs + state files, no dumpsys)
//   engine      -> the slow dumpsys detail, fetched lazily and cached
//   <action>    -> prints a full status block, so a tap needs no follow-up call
//
// Round-trip counts are asserted: each extra ksu.exec is latency the user
// feels, so they are part of the contract, not an implementation detail.
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
  const el = {
    className: "", disabled: false,
    style: {}, onclick: null, onkeydown: null,
    children: [], kids: [], attrs: {},
    scrollTop: 0, scrollHeight: 0,
    _text: "", _html: ""
  };
  // Mirror the real DOM: textContent and innerHTML are two views of the same
  // content, so assigning one clears the other. Without this a page that
  // resets the hero with textContent would still "contain" a stale spinner
  // in innerHTML and the harness would report a bug browsers do not have.
  Object.defineProperty(el, "textContent", {
    get() { return el._text; },
    set(v) { el._text = String(v); el._html = ""; el.children = []; }
  });
  Object.defineProperty(el, "innerHTML", {
    get() { return el._html; },
    set(v) { el._html = String(v); el._text = String(v).replace(/<[^>]*>/g, ""); }
  });
  el.appendChild = function (c) { el.children.push(c); el._text += c.textContent; };
  el.setAttribute = function (k, v) { el.attrs[k] = String(v); };
  el.getAttribute = function (k) {
    return Object.prototype.hasOwnProperty.call(el.attrs, k) ? el.attrs[k] : null;
  };
  // enough of the HTMLCollection contract for the page's loops
  el.getElementsByTagName = function () { return el.kids; };
  return el;
}
const els = {};
const docHandlers = {};
const document = {
  getElementById(id) { return els[id] || (els[id] = makeEl()); },
  createElement() { return makeEl(); },
  hidden: false,
  visibilityState: "visible",
  addEventListener(type, fn) { (docHandlers[type] = docHandlers[type] || []).push(fn); },
  removeEventListener() {}
};
// static markup the script queries by collection
els.seg = makeEl();
["performance", "performance_lite", "balance", "powersave"].forEach(p => {
  const b = makeEl();
  b.setAttribute("data-p", p);
  els.seg.kids.push(b);
});
els.segSoff = makeEl();
["powersave", "balance", "keep"].forEach(mode => {
  const b = makeEl();
  b.setAttribute("data-s", mode);
  els.segSoff.kids.push(b);
});

// --- samples: real usfcpu.sh output shapes ----------------------------------
const CAPS_ACTIVE = [
  "cpufreq caps (max vs hardware max):",
  "  policy0: max=2000000 hw=2000000",
  "  policy4: max=2600000 hw=2600000"
];
const CAPS_STOCK = [
  "cpufreq caps (max vs hardware max):",
  "  policy0: max=1800000 hw=2000000",
  "  policy4: max=2200000 hw=2600000"
];

function fastBlock(opts) {
  const lines = [
    "module      : usf-cpu-unlock v2.2.0",
    "patch mount: " + (opts.stock ? "inactive (stock behavior)" : "ACTIVE (USF CPU cap disabled)"),
    "watcher     : " + (opts.watch === false ? "off" : "on (pid 4242)"),
    "profile     : " + opts.profile,
    "gamelist    : " + (opts.games === undefined ? 2 : opts.games) +
      " package(s) -> /data/adb/.config/usf-cpu-unlock/gamelist.txt",
    "screenoff   : " + (opts.soff || "keep"),
    "governor    : " + (opts.gov || "performance") + " (policy0)"
  ];
  return lines.concat(opts.stock ? CAPS_STOCK : CAPS_ACTIVE).join("\n");
}

const FAST_ACTIVE = fastBlock({ profile: "performance" });
const FAST_STOCK = fastBlock({ profile: "balance", stock: true, watch: false,
                               soff: "powersave", gov: "schedutil" });

const ENGINE_ACTIVE = [
  "engine state (excerpt):",
  "    MTK thermal CPU limit support: ENABLED",
  "    Thermal CPU handle: 0",
  "    Current temp config: TempConfig{",
  "      tempLevel=43",
  "      cpu=0,",
  "      clusterCpu0=0,",
  "      clusterCpu1=0,",
  "      clusterCpu2=0,",
  "usf pid(s) : 18354"
].join("\n");

const ENGINE_STOCK = [
  "engine state (excerpt):",
  "    Current temp config: TempConfig{",
  "      tempLevel=41",
  "      clusterCpu0=1800000,",
  "      clusterCpu1=2200000,",
  "usf pid(s) : 14771"
].join("\n");

let fastSample = FAST_ACTIVE;
let engineSample = ENGINE_ACTIVE;

// --- bridge stub -------------------------------------------------------------
const execCalls = [];
const toasts = [];
let hangOn = null;      // command substring that must never call back
let engineFetches = 0;

function statusFor(cmd) {
  if (cmd.indexOf("webui-fast") !== -1) return fastSample;
  if (/usfcpu\.sh engine/.test(cmd)) { engineFetches++; return engineSample; }
  // actions print a confirmation followed by the full status block
  const mp = cmd.match(/profile (\w+)/);
  if (mp) {
    return "profile applied: " + mp[1] + "\n" +
      fastBlock({ profile: mp[1], gov: mp[1] === "performance" ? "performance" : "schedutil" });
  }
  const ms = cmd.match(/screenoff (\w+)/);
  if (ms) {
    return "screen off: " + ms[1] + "\n" + fastBlock({ profile: "performance", soff: ms[1] });
  }
  if (/watch (on|off)/.test(cmd)) {
    return "watcher " + (/watch on/.test(cmd) ? "started" : "disabled") + "\n" +
      fastBlock({ profile: "performance", watch: /watch on/.test(cmd) });
  }
  return fastSample;
}

const ksu = {
  exec(cmd, optionsJson, callbackName) {
    execCalls.push(cmd);
    if (typeof optionsJson !== "string") throw new Error("options must be a JSON string");
    if (hangOn && cmd.indexOf(hangOn) !== -1) return; // never settles
    const out = statusFor(cmd);
    // webui-fast answers fast (5ms); everything else is slower (40ms)
    const quick = cmd.indexOf("webui-fast") !== -1;
    setTimeout(() => {
      const cb = globalThis[callbackName];
      if (typeof cb === "function") cb(0, out, "");
    }, quick ? 5 : 40);
  },
  toast(msg) { toasts.push(msg); }
};

globalThis.window = globalThis;
globalThis.USF_EXEC_TIMEOUT = 300; // fast timeout so the suite stays quick
globalThis.document = document;
globalThis.ksu = ksu;
globalThis.navigator = {};

let failures = 0;
function check(name, cond) {
  if (cond) { console.log("ok   " + name); }
  else { failures++; console.log("FAIL " + name); }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
const countOf = re => execCalls.filter(c => re.test(c)).length;

(async () => {
  eval(script); // defines functions and fires refresh() at the end

  // --- fast path: ONE call paints the whole card -----------------------------
  await sleep(15);

  check("first command is webui-fast", /webui-fast/.test(execCalls[0] || ""));
  // one fast call paints the card; the engine detail is a second, non-blocking
  // call that has not answered yet at this point
  check("fast path is a single paint call", countOf(/webui-fast/) === 1);
  check("engine call does not block the paint", els.engine.textContent === "\u2013");
  check("fast: version parsed", els.ver.textContent === "v2.2.0");
  check("fast: state label ACTIVE", els.stateLbl.textContent === "Patch ACTIVE");
  check("fast: dot is green", /(^|\s)on(\s|$)/.test(els.dot.className));
  check("fast: little unlocked", els.p0.textContent.indexOf("2.00") !== -1 &&
        els.p0.textContent.indexOf("\u2713") !== -1);
  check("fast: big unlocked", els.p4.textContent.indexOf("2.60") !== -1 &&
        els.p4.textContent.indexOf("\u2713") !== -1);
  check("fast: profile painted", els.profTxt.textContent.indexOf("Max performance") === 0);
  check("fast: chip BOOST", els.profChip.textContent === "BOOST");
  check("fast: Max segment selected", els.seg.kids[0].className === "sel");
  check("fast: watcher on", /(^|\s)on(\s|$)/.test(els.watchSw.className));
  check("fast: watcher pid", els.watchTxt.textContent.indexOf("pid 4242") !== -1);
  check("fast: screen-off Keep selected", els.segSoff.kids[2].className === "sel");
  check("fast: gamelist count", els.glTxt.textContent.indexOf("2 packages") === 0);
  check("fast: engine still pending", els.engine.textContent === "\u2013");
  check("fast: buttons enabled", els.btnRestore.disabled === false);
  check("no Apply button in the page", html.indexOf("btnApply") === -1 && html.indexOf(">Apply<") === -1);
  check("log hidden by default", els.log.style.display === "none");

  // --- engine detail is fetched separately and fills in ----------------------
  await sleep(80);
  check("engine fetched once", engineFetches === 1);
  check("engine: level 43", els.engine.textContent.indexOf("level 43") !== -1);
  check("engine: no-cap noted", els.engine.textContent.indexOf("no CPU cap") !== -1);
  check("engine: pid filled", els.pid.textContent === "18354");
  check("log collected while hidden", els.log.textContent.indexOf("patch mount: ACTIVE") !== -1);

  // --- automatic refreshes reuse the cached engine detail -------------------
  const beforeAuto = engineFetches;
  document.hidden = false;
  (docHandlers.visibilitychange || []).forEach(fn => fn());
  await sleep(90);
  check("auto refresh reuses the engine cache", engineFetches === beforeAuto);
  check("auto refresh costs one fast call", countOf(/webui-fast/) === 2);

  // --- the Refresh button reuses the cache too: a refresh must stay cheap ----
  const beforeBtn = engineFetches;
  els.btnRefresh.onclick();
  await sleep(90);
  check("Refresh button reuses the engine cache", engineFetches === beforeBtn);
  check("Refresh button paints in one fast call", countOf(/webui-fast/) === 3);

  // --- an expired cache is refetched automatically --------------------------
  const beforeExpiry = engineFetches;
  window.USF_ENGINE_TTL = 0;          // the page reads this at call time
  els.btnRefresh.onclick();
  await sleep(120);
  check("expired engine cache is refetched", engineFetches === beforeExpiry + 1);
  window.USF_ENGINE_TTL = 60000;

  // --- profile tap: ONE round trip, card renders from the action's output ---
  const beforeTap = execCalls.length;
  els.seg.kids[3].onclick.call(els.seg.kids[3]); // saver
  await sleep(15);
  check("tap paints immediately", els.profTxt.textContent.indexOf("Battery saver") === 0);
  check("tap moves the selection", els.seg.kids[3].className === "sel");
  check("tap keeps the progress label", els.stateLbl.innerHTML.indexOf("spin") !== -1);
  await sleep(120);
  check("tap is a single round trip",
        execCalls.slice(beforeTap).length === 1 &&
        /profile powersave/.test(execCalls[beforeTap]));
  check("tap renders from the action response",
        els.profTxt.textContent.indexOf("Battery saver") === 0);
  check("tap leaves no spinner", els.stateLbl.innerHTML.indexOf("spin") === -1);
  check("tap re-enables the buttons", els.btnRefresh.disabled === false);

  // --- screen-off picker: same single round trip ----------------------------
  const beforeSoff = execCalls.length;
  els.segSoff.kids[1].onclick.call(els.segSoff.kids[1]); // balance
  await sleep(120);
  check("screenoff tap is a single round trip",
        execCalls.slice(beforeSoff).length === 1 &&
        /screenoff balance/.test(execCalls[beforeSoff]));
  check("screenoff selection follows the response", els.segSoff.kids[1].className === "sel");

  // --- watcher switch -------------------------------------------------------
  const beforeWatch = execCalls.length;
  els.watchSw.onclick(); // was on -> off
  await sleep(120);
  check("watcher tap is a single round trip",
        execCalls.slice(beforeWatch).length === 1 &&
        /watch off/.test(execCalls[beforeWatch]));

  // --- gamelist add ---------------------------------------------------------
  const beforeAdd = execCalls.length;
  els.glInput.value = "com.mobile.legends";
  els.btnGlAdd.onclick();
  await sleep(120);
  check("gamelist add runs the CLI",
        execCalls.slice(beforeAdd).some(c => /games add com\.mobile\.legends/.test(c)));
  check("gamelist add clears the field", els.glInput.value === "");

  const beforeBad = execCalls.length;
  const toastsBefore = toasts.length;
  els.glInput.value = "not a package";
  els.btnGlAdd.onclick();
  await sleep(30);
  check("gamelist rejects an invalid package locally",
        execCalls.length === beforeBad && toasts.length === toastsBefore + 1);

  // --- log toggle -----------------------------------------------------------
  els.btnLog.onclick();
  check("toggle: log shown", els.log.style.display === "block");
  check("toggle: label reads Hide log", els.btnLog.textContent.indexOf("Hide log") === 0);
  els.btnLog.onclick();
  check("toggle: log hidden again", els.log.style.display === "none");
  check("toggle: label reads Show log", els.btnLog.textContent.indexOf("Show log") === 0);

  // --- robustness: the UI must never stay stuck on a busy label -------------
  hangOn = "profile performance";
  els.seg.kids[0].onclick.call(els.seg.kids[0]);
  await sleep(450); // past USF_EXEC_TIMEOUT (300ms)
  check("hung command releases busy", els.btnRefresh.disabled === false);
  check("hung command restores the hero",
        els.stateLbl.textContent === "Patch ACTIVE" &&
        els.stateLbl.innerHTML.indexOf("spin") === -1);
  check("hung command warns the user",
        toasts.some(t => /timed out|no response/i.test(t)));
  hangOn = null;

  // --- returning to the page refreshes --------------------------------------
  check("visibilitychange handler registered",
        (docHandlers.visibilitychange || []).length > 0);
  const beforeVis = countOf(/webui-fast/);
  document.hidden = false;
  document.visibilityState = "visible";
  (docHandlers.visibilitychange || []).forEach(fn => fn());
  await sleep(90);
  check("returning to the page triggers a refresh", countOf(/webui-fast/) > beforeVis);

  // --- stock sample ---------------------------------------------------------
  fastSample = FAST_STOCK;
  engineSample = ENGINE_STOCK;
  engineFetches = 0;
  window.USF_ENGINE_TTL = 0;          // force the engine to reflect the new state
  els.ver.textContent = ""; els.stateLbl.textContent = ""; els.p0.textContent = "";
  els.p4.textContent = ""; els.engine.textContent = ""; els.pid.textContent = "";

  els.btnRefresh.onclick();
  await sleep(15);
  check("stock: state label", els.stateLbl.textContent === "Stock behavior");
  check("stock: dot is red", /(^|\s)off(\s|$)/.test(els.dot.className));
  check("stock: little capped", els.p0.textContent.indexOf("1.80") !== -1 &&
        els.p0.textContent.indexOf("\u2713") === -1);
  check("stock: big capped", els.p4.textContent.indexOf("2.20") !== -1 &&
        els.p4.textContent.indexOf("\u2713") === -1);
  check("stock: watcher switch off", !/(^|\s)on(\s|$)/.test(els.watchSw.className));
  check("stock: profile chip NORMAL", els.profChip.textContent === "NORMAL");
  check("stock: balance segment selected",
        els.seg.kids.filter(b => b.className === "sel").length === 1 &&
        els.seg.kids[2].className === "sel");
  check("stock: screen-off Saver selected", els.segSoff.kids[0].className === "sel");

  await sleep(80);
  window.USF_ENGINE_TTL = 60000;
  check("stock: engine level 41 without no-cap",
        els.engine.textContent.indexOf("level 41") !== -1 &&
        els.engine.textContent.indexOf("no CPU cap") === -1);

  console.log(failures === 0 ? "\nwebui tests: all passed" : "\nwebui tests: " + failures + " FAILED");
  process.exit(failures === 0 ? 0 : 1);
})().catch(e => { console.error("FAIL harness error:", e); process.exit(1); });
