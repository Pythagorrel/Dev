/* =========================================================================
   app.js — the whole front end.

   RESPONSIBILITY, STATED PLAINLY: collect one day's figures, check they look
   sensible, and POST them. That is all. It never computes a ledger row, never
   decides a filename, never learns what an account is. Every one of those
   belongs to the server, and keeping them there is what makes this page
   replaceable without touching anything else.

   WHERE THE DATA LIVES: not here. Every completed day is sent to the server
   immediately and read back from the server afterwards. This page holds no
   record it cannot re-fetch, so closing the tab loses nothing.
   ========================================================================= */

const MONTHS = ["January","February","March","April","May","June",
                "July","August","September","October","November","December"];

const state = {
  config:  null,   // groups + labels, from /api/config
  staged:  [],     // days on the server's notepad, from /api/staged
  editing: null,   // date string being edited, or null for a fresh day
  today:   null,
};

const $  = (id) => document.getElementById(id);
const money = (n) => "$" + Number(n || 0).toLocaleString(undefined,
                       { minimumFractionDigits: 2, maximumFractionDigits: 2 });

/* ---------------------------------------------------------------------------
   Server calls. Everything that can fail returns through here so one error
   path handles the lot.
--------------------------------------------------------------------------- */
async function api(path, opts = {}) {
  const res  = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...opts,
  });
  let data;
  try { data = await res.json(); }
  catch { throw new Error("The server sent back something unreadable."); }
  if (!res.ok || data.ok === false) throw new Error(data.error || "The server refused that.");
  return data;
}

function banner(where, kind, text, actionLabel, actionFn) {
  const host = $(where);
  host.innerHTML = "";
  if (!text) return;
  const div = document.createElement("div");
  div.className = "banner " + kind;
  const span = document.createElement("span");
  span.textContent = text;
  div.appendChild(span);
  if (actionLabel) {
    const b = document.createElement("button");
    b.className = "btn-ghost mini";
    b.textContent = actionLabel;
    b.onclick = actionFn;
    div.appendChild(b);
  }
  host.appendChild(div);
}

/* ---------------------------------------------------------------------------
   Building the form from the server's category list
--------------------------------------------------------------------------- */
function buildGroups() {
  const host = $("groups");
  host.innerHTML = "";

  state.config.groups.forEach(group => {
    const card = document.createElement("div");
    card.className = "card";
    card.dataset.group = group.id;

    const h = document.createElement("h3");
    h.textContent = group.title;
    const hint = document.createElement("p");
    hint.className = "hint";
    hint.textContent = group.hint;

    const grid = document.createElement("div");
    grid.className = "grid";

    group.categories.forEach(cat => {
      const field = document.createElement("div");
      field.className = "field";

      const label = document.createElement("label");
      label.setAttribute("for", "in-" + cat.key);
      label.textContent = cat.label;

      const wrap = document.createElement("div");
      wrap.className = "money";
      const sym = document.createElement("span");
      sym.className = "sym";
      sym.textContent = "$";
      const input = document.createElement("input");
      input.type = "text";
      input.id = "in-" + cat.key;
      input.dataset.key = cat.key;
      input.dataset.label = cat.label;
      input.placeholder = "0.00";
      input.inputMode = "decimal";
      input.autocomplete = "off";
      wrap.append(sym, input);

      const err = document.createElement("div");
      err.className = "err";
      err.id = "err-" + cat.key;

      field.append(label, wrap, err);
      grid.appendChild(field);

      // Live feedback: validate as the user types, not only on submit.
      input.addEventListener("input", () => { validateAmount(input); refreshTotals(); });
      input.addEventListener("blur",  () => { tidyAmount(input); refreshTotals(); });
    });

    card.append(h, hint, grid);
    host.appendChild(card);
  });
}

/* ---------------------------------------------------------------------------
   Validation.

   This is for the person typing, not for the server's benefit — the server
   re-checks every one of these rules and its answer is the one that counts.
   The point here is that mistakes are visible the instant they are made
   instead of after a submission is rejected.
--------------------------------------------------------------------------- */
function validateAmount(input) {
  const raw = input.value.trim();
  const err = $("err-" + input.dataset.key);
  let msg = "";

  if (raw !== "") {
    if (raw.startsWith("-"))                       msg = "Amounts cannot be negative.";
    else if (!/^\d*\.?\d*$/.test(raw))             msg = "Numbers only — no letters or symbols.";
    else if (raw === ".")                          msg = "Enter a number.";
    else if (Number(raw) > 1e7)                    msg = "That looks too large — please check it.";
    else if (/\.\d{3,}$/.test(raw))                msg = "At most two decimal places.";
  }

  input.classList.toggle("invalid", msg !== "");
  input.classList.toggle("filled", msg === "" && raw !== "");
  err.textContent = msg;
  err.classList.toggle("show", msg !== "");
  updateButtons();
  return msg === "";
}

// Tidy on blur so the value the user leaves behind matches what gets sent.
function tidyAmount(input) {
  const raw = input.value.trim();
  if (raw === "" || input.classList.contains("invalid")) return;
  input.value = Number(raw).toFixed(2);
}

function currentDate() {
  const y = Number($("sel-year").value);
  const m = Number($("sel-month").value);
  const d = Number($("sel-day").value);
  if (!y || !m || !d) return null;
  return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

function validateDate() {
  const err = $("err-date");
  const iso = currentDate();
  let msg = "";

  if (!iso) {
    msg = "Choose a full date.";
  } else if (iso > state.today) {
    msg = "That day has not happened yet.";
  }

  err.textContent = msg;
  err.classList.toggle("show", msg !== "");

  // Not an error, but worth saying out loud before they type a whole day again.
  if (!msg && !state.editing && state.staged.some(d => d.date === iso)) {
    banner("banner-area", "warn",
      `${prettyDate(iso)} has already been entered in this session. Saving will replace it.`,
      "Edit that day", () => startEdit(iso));
  } else if (!state.editing) {
    resumeBanner();
  }

  updateButtons();
  return msg === "";
}

function formValid() {
  const dateOk = $("err-date").textContent === "";
  const amountsOk = !document.querySelector("#groups input.invalid");
  return dateOk && currentDate() !== null && amountsOk;
}

function updateButtons() {
  const ok = formValid();
  $("btn-next").disabled = !ok;
  $("btn-review").disabled = !ok && state.staged.length === 0;
}

/* ---------------------------------------------------------------------------
   Date selects
--------------------------------------------------------------------------- */
function fillDateSelects(iso) {
  const now = new Date(state.today + "T00:00:00");
  const ySel = $("sel-year"), mSel = $("sel-month"), dSel = $("sel-day");

  if (!ySel.options.length) {
    for (let y = now.getFullYear() - 2; y <= now.getFullYear(); y++) {
      ySel.add(new Option(y, y));
    }
    MONTHS.forEach((name, i) => mSel.add(new Option(name, i + 1)));
    [ySel, mSel].forEach(s => s.addEventListener("change", () => { fillDays(); validateDate(); }));
    dSel.addEventListener("change", validateDate);
  }

  const target = iso || state.today;
  const [yy, mm, dd] = target.split("-").map(Number);
  ySel.value = yy;
  mSel.value = mm;
  fillDays(dd);
}

// Rebuild the day list for the chosen month, so 31 September is never offered
// in the first place. The server rejects impossible dates too; this just means
// nobody has to be told.
function fillDays(keep) {
  const dSel = $("sel-day");
  const y = Number($("sel-year").value);
  const m = Number($("sel-month").value);
  const n = new Date(y, m, 0).getDate();
  const want = keep || Number(dSel.value) || 1;
  dSel.innerHTML = "";
  for (let d = 1; d <= n; d++) dSel.add(new Option(d, d));
  dSel.value = Math.min(want, n);
}

function prettyDate(iso) {
  const [y, m, d] = iso.split("-").map(Number);
  return `${d} ${MONTHS[m - 1]} ${y}`;
}

/* ---------------------------------------------------------------------------
   Reading and writing the form
--------------------------------------------------------------------------- */
function readAmounts() {
  const out = {};
  document.querySelectorAll("#groups input").forEach(i => {
    const raw = i.value.trim();
    out[i.dataset.key] = raw === "" ? 0 : Number(raw);   // blank means zero, decided here
  });
  return out;
}

function writeAmounts(amounts) {
  document.querySelectorAll("#groups input").forEach(i => {
    const v = amounts ? amounts[i.dataset.key] : 0;
    i.value = v ? Number(v).toFixed(2) : "";
    i.classList.remove("invalid", "filled");
    if (v) i.classList.add("filled");
    const err = $("err-" + i.dataset.key);
    err.textContent = ""; err.classList.remove("show");
  });
  refreshTotals();
}

function refreshTotals() {
  const a = readAmounts();
  const sum = (cats) => cats.reduce((t, c) => t + (a[c.key] || 0), 0);
  const g = (id) => state.config.groups.find(x => x.id === id).categories;

  $("tot-cash").textContent = money(sum(g("cash")));
  $("tot-exp").textContent  = money(sum(g("expenses")));
  // "Banked" is the deposits figure, identified by the server rather than by a
  // name written into this file. Shown because it is the figure most often mistyped.
  $("tot-dep").textContent  = money(a[state.config.depositKey] || 0);
  $("tot-staged").textContent = state.staged.length;
}

/* ---------------------------------------------------------------------------
   Saving a day
--------------------------------------------------------------------------- */
async function saveDay() {
  if (!formValid()) return false;
  const payload = { date: currentDate(), amounts: readAmounts() };
  try {
    const res = await api("/api/staged", { method: "POST", body: JSON.stringify(payload) });
    await loadStaged();
    state.editing = null;
    $("btn-cancel-edit").hidden = true;
    banner("banner-area", "info",
      `${prettyDate(res.date)} ${res.replaced ? "updated" : "saved"}. ` +
      `${state.staged.length} day${state.staged.length === 1 ? "" : "s"} ready to save.`,
      "Review them", showReview);
    return true;
  } catch (e) {
    banner("banner-area", "error", e.message);
    return false;
  }
}

function nextDate(iso) {
  const d = new Date(iso + "T00:00:00");
  d.setDate(d.getDate() + 1);
  const next = d.toISOString().slice(0, 10);
  // return next > state.today ? iso : next;   // never roll past today
}

async function onNextDay() {
  const from = currentDate();
  if (!(await saveDay())) return;
  fillDateSelects(nextDate(from));
  writeAmounts(null);
  validateDate();
  window.scrollTo({ top: 0, behavior: "smooth" });
  document.querySelector("#groups input").focus();
}

async function onReview() {
  // A part-filled form on screen should not be silently discarded.
  const hasEntries = Object.values(readAmounts()).some(v => v > 0);
  const alreadyStaged = state.staged.some(d => d.date === currentDate());
  if (hasEntries && !alreadyStaged && formValid()) {
    if (!(await saveDay())) return;
  } else if (hasEntries && alreadyStaged && state.editing) {
    if (!(await saveDay())) return;
  }
  if (state.staged.length === 0) {
    banner("banner-area", "warn", "There are no days to review yet.");
    return;
  }
  showReview();
}

/* ---------------------------------------------------------------------------
   Review
--------------------------------------------------------------------------- */
function showReview() {
  setStep(2);
  $("view-entry").classList.add("hidden");
  $("view-done").classList.add("hidden");
  $("view-review").classList.remove("hidden");
  renderReview();
  window.scrollTo({ top: 0 });
}

function renderReview() {
  const keys = state.config.keyOrder;
  const labels = state.config.labels;
  const t = $("review-table");
  t.innerHTML = "";

  // header
  const thead = t.createTHead();
  const hr = thead.insertRow();
  ["Date", ...keys.map(k => labels[k]), "Status", ""].forEach(txt => {
    const th = document.createElement("th");
    th.textContent = txt;
    hr.appendChild(th);
  });

  // body
  const tb = t.createTBody();
  const totals = Object.fromEntries(keys.map(k => [k, 0]));

  state.staged.forEach(day => {
    const tr = tb.insertRow();
    tr.insertCell().textContent = prettyDate(day.date);

    keys.forEach(k => {
      const v = day.amounts[k] || 0;
      totals[k] += v;
      const td = tr.insertCell();
      td.textContent = v ? money(v) : "—";
      if (!v) td.className = "zero";
    });

    const st = tr.insertCell();
    st.style.textAlign = "left";
    st.innerHTML =
      (day.inJournal
        ? '<span class="badge repl">replaces existing entry</span>'
        : '<span class="badge new">new</span>') +
      (day.hasDailyLedger ? '<span class="badge lock">ledger file exists</span>' : "");

    const act = tr.insertCell();
    act.className = "act";
    const edit = document.createElement("button");
    edit.className = "btn-ghost mini";
    edit.textContent = "Edit";
    edit.onclick = () => startEdit(day.date);
    const del = document.createElement("button");
    del.className = "btn-danger mini";
    del.textContent = "Remove";
    del.onclick = () => removeDay(day.date);
    act.append(edit, del);
  });

  // totals
  const tf = t.createTFoot();
  const fr = tf.insertRow();
  fr.insertCell().textContent = `${state.staged.length} day${state.staged.length === 1 ? "" : "s"}`;
  keys.forEach(k => { fr.insertCell().textContent = totals[k] ? money(totals[k]) : "—"; });
  fr.insertCell(); fr.insertCell();

  // overwrite option only matters if something would actually be skipped
  const clashes = state.staged.filter(d => d.hasDailyLedger).length;
  $("force-line").hidden = clashes === 0;
  if (clashes > 0) {
    banner("review-banner", "warn",
      `${clashes} of these days already has a daily ledger file. Those files will be left ` +
      `alone unless you tick the box below — the journal and monthly ledger update either way.`);
  } else {
    banner("review-banner", "");
  }
}

async function startEdit(iso) {
  const day = state.staged.find(d => d.date === iso);
  if (!day) return;
  state.editing = iso;
  setStep(1);
  $("view-review").classList.add("hidden");
  $("view-done").classList.add("hidden");
  $("view-entry").classList.remove("hidden");
  fillDateSelects(iso);
  writeAmounts(day.amounts);
  validateDate();
  $("btn-cancel-edit").hidden = false;
  banner("banner-area", "info", `Editing ${prettyDate(iso)}. Saving will replace it.`);
  window.scrollTo({ top: 0 });
}

async function removeDay(iso) {
  if (!confirm(`Remove ${prettyDate(iso)} from this session? It has not been saved to the books yet.`)) return;
  try {
    await api("/api/staged?date=" + encodeURIComponent(iso), { method: "DELETE" });
    await loadStaged();
    if (state.staged.length === 0) { backToEntry(); banner("banner-area", "info", "Nothing left to review."); }
    else renderReview();
  } catch (e) {
    banner("review-banner", "error", e.message);
  }
}

function backToEntry() {
  setStep(1);
  state.editing = null;
  $("btn-cancel-edit").hidden = true;
  $("view-review").classList.add("hidden");
  $("view-done").classList.add("hidden");
  $("view-entry").classList.remove("hidden");
  resumeBanner();
  window.scrollTo({ top: 0 });
}

/* ---------------------------------------------------------------------------
   Commit — the one action that writes to the books
--------------------------------------------------------------------------- */
async function commit() {
  const btn = $("btn-commit");
  btn.disabled = true;
  btn.textContent = "Saving…";
  try {
    const res = await api("/api/commit", {
      method: "POST",
      body: JSON.stringify({ force: $("chk-force").checked }),
    });
    await loadStaged();
    showDone(res);
  } catch (e) {
    banner("review-banner", "error", e.message);
  } finally {
    btn.disabled = false;
    btn.textContent = "Generate ledgers & update journal";
  }
}

function showDone(res) {
  setStep(3);
  $("view-review").classList.add("hidden");
  $("view-entry").classList.add("hidden");
  $("view-done").classList.remove("hidden");

  const good = res.results.filter(r => r.ok).length;
  $("done-title").textContent = res.ok ? "Saved to the books" : "Saved with problems";
  $("done-sub").textContent = res.ok
    ? `${good} day${good === 1 ? "" : "s"} written. The monthly ledger has been rebuilt from the journal.`
    : `${good} of ${res.results.length} days written. The rest are still waiting and have not been lost.`;

  const host = $("done-list");
  host.innerHTML = "";
  res.results.forEach(r => {
    const box = document.createElement("div");
    box.className = "result" + (r.ok ? "" : " bad");
    const h = document.createElement("h4");
    h.textContent = prettyDate(r.date);
    const ul = document.createElement("ul");

    const lines = r.ok ? [
      r.journal === "replaced" ? "Journal entry replaced" : "Added to the journal",
      r.dailyLedger === "skipped"
        ? "Daily ledger already existed and was left alone"
        : r.dailyLedger === "overwritten" ? "Daily ledger overwritten" : "Daily ledger written",
      `Monthly ledger ${r.monthlyLedger} from ${r.daysInMonth} day${r.daysInMonth === 1 ? "" : "s"}`,
    ] : ["Could not be saved"];

    lines.concat(r.warnings.map(w => "⚠ " + w)).forEach(txt => {
      const li = document.createElement("li");
      li.textContent = txt;
      ul.appendChild(li);
    });

    box.append(h, ul);
    if (r.ok && r.outputDir) {
      const p = document.createElement("div");
      p.className = "pathline";
      p.textContent = r.outputDir;
      box.appendChild(p);
    }
    host.appendChild(box);
  });
  window.scrollTo({ top: 0 });
}

/* ---------------------------------------------------------------------------
   Boot
--------------------------------------------------------------------------- */
function setStep(n) {
  [1, 2, 3].forEach(i => {
    const el = $("step-" + i);
    el.classList.toggle("active", i === n);
    el.classList.toggle("done", i < n);
  });
}

function resumeBanner() {
  if (state.staged.length > 0) {
    banner("banner-area", "info",
      `${state.staged.length} day${state.staged.length === 1 ? "" : "s"} from an earlier session ` +
      `${state.staged.length === 1 ? "is" : "are"} waiting and not yet saved to the books.`,
      "Review them", showReview);
  } else {
    banner("banner-area", "");
  }
}

async function loadStaged() {
  const res = await api("/api/staged");
  state.staged = res.days;
  refreshTotals();
  updateButtons();
}

async function boot() {
  try {
    state.config = await api("/api/config");
    state.today  = state.config.today;
  } catch (e) {
    document.querySelector(".wrap").innerHTML =
      '<div class="banner error"><span>Could not reach the server. ' +
      'Is the terminal window still open?</span></div>';
    return;
  }

  buildGroups();
  fillDateSelects(null);
  writeAmounts(null);
  await loadStaged();
  validateDate();
  resumeBanner();

  $("btn-next").onclick   = onNextDay;
  $("btn-review").onclick = onReview;
  $("btn-clear").onclick  = () => { writeAmounts(null); validateDate(); };
  $("btn-cancel-edit").onclick = () => { state.editing = null; $("btn-cancel-edit").hidden = true; writeAmounts(null); fillDateSelects(null); validateDate(); resumeBanner(); };
  $("btn-back").onclick   = backToEntry;
  $("btn-commit").onclick = commit;
  $("btn-restart").onclick = () => { writeAmounts(null); fillDateSelects(null); backToEntry(); };
}

boot();
