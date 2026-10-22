const express = require("express");
const cors = require("cors");
const fs = require("fs");
const path = require("path");

const app = express();
const PORT = 3001;

const TRADES_FILE = path.join(__dirname, "trades.json");

const VALID_SYMBOLS = ["EURUSD", "GBPUSD", "USDJPY", "EURGBP", "AUDUSD", "AUDNZD", "EURJPY", "USDCAD", "XAUUSD"];
const VALID_DIRECTIONS = ["long", "short"];
const VALID_LEVEL_TYPES = ["watch", "order", "option"];
const VALID_LEVEL_SIZES = ["watched", "medium", "large"];
const VALID_ORDER_KINDS = ["limit", "market"];

const TZ = "Europe/Berlin";

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

// ---------- File helpers ----------
function readJsonArray(file) {
  try {
    if (!fs.existsSync(file)) return [];
    const raw = fs.readFileSync(file, "utf8").trim();
    if (!raw) return [];
    const data = JSON.parse(raw);
    return Array.isArray(data) ? data : [];
  } catch (e) {
    console.error(`Failed to read ${file}:`, e);
    return [];
  }
}
function writeJsonArray(file, arr) {
  fs.writeFileSync(file, JSON.stringify(arr, null, 2));
}

// ---------- Time helpers ----------
function tzOffsetMinutes(utcDate, timeZone) {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const parts = Object.fromEntries(
    dtf
      .formatToParts(utcDate)
      .filter((p) => p.type !== "literal")
      .map((p) => [p.type, p.value]),
  );
  const asUTC = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour === "24" ? "0" : parts.hour),
    Number(parts.minute),
    Number(parts.second),
  );
  return (asUTC - utcDate.getTime()) / 60000;
}

function zonedDateTimeToUTC(dateStr, timeStr, timeZone) {
  const [y, mo, d] = dateStr.split("-").map(Number);
  const [h, mi] = timeStr.split(":").map(Number);
  const guessUTC = Date.UTC(y, mo - 1, d, h, mi, 0);
  const offset1 = tzOffsetMinutes(new Date(guessUTC), timeZone);
  const utc1 = guessUTC - offset1 * 60000;
  const offset2 = tzOffsetMinutes(new Date(utc1), timeZone);
  return new Date(guessUTC - offset2 * 60000);
}

function todayInTZ(timeZone) {
  const dtf = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  return dtf.format(new Date());
}

// Wall-clock parts ("now") in the given timeZone, as numbers.
function nowPartsInTZ(timeZone) {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const parts = Object.fromEntries(
    dtf
      .formatToParts(new Date())
      .filter((p) => p.type !== "literal")
      .map((p) => [p.type, p.value]),
  );
  return {
    year: Number(parts.year),
    month: Number(parts.month),
    day: Number(parts.day),
    hour: Number(parts.hour === "24" ? "0" : parts.hour),
    minute: Number(parts.minute),
    second: Number(parts.second),
  };
}

function addDaysISO(dateStr, days) {
  const [y, mo, d] = dateStr.split("-").map(Number);
  const dt = new Date(Date.UTC(y, mo - 1, d));
  dt.setUTCDate(dt.getUTCDate() + days);
  const yy = dt.getUTCFullYear();
  const mm = String(dt.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(dt.getUTCDate()).padStart(2, "0");
  return `${yy}-${mm}-${dd}`;
}

// ---------- ID generation ----------
// Format: YYYYMMDDHHmm (Europe/Berlin wall time at submission).
// If a collision occurs in the same minute, append "-2", "-3", ...
function generateTradeId(existingTrades) {
  const p = nowPartsInTZ(TZ);
  const base =
    String(p.year).padStart(4, "0") +
    String(p.month).padStart(2, "0") +
    String(p.day).padStart(2, "0") +
    String(p.hour).padStart(2, "0") +
    String(p.minute).padStart(2, "0");
  const taken = new Set(existingTrades.map((t) => t.id));
  if (!taken.has(base)) return base;
  let n = 2;
  while (taken.has(`${base}-${n}`)) n++;
  return `${base}-${n}`;
}

// ---------- Validation ----------
function validateSymbol(sym) {
  return VALID_SYMBOLS.includes(sym);
}

function validateTradeBody(b) {
  const errs = [];
  if (!validateSymbol(b.symbol)) errs.push("invalid symbol");
  if (!VALID_DIRECTIONS.includes(b.direction)) errs.push("invalid direction");
  if (b.order_kind != null && !VALID_ORDER_KINDS.includes(b.order_kind)) errs.push("invalid order_kind");
  const orderKind = b.order_kind || "limit";
  if (orderKind === "limit") {
    if (typeof b.limit_price !== "number" || !isFinite(b.limit_price)) errs.push("invalid limit_price");
  } else if (b.limit_price != null && (typeof b.limit_price !== "number" || !isFinite(b.limit_price))) {
    errs.push("invalid limit_price");
  }
  if (typeof b.stop_loss !== "number" || !isFinite(b.stop_loss)) errs.push("invalid stop_loss");
  if (!VALID_LEVEL_TYPES.includes(b.level_type)) errs.push("invalid level_type");
  if (!/^\d{2}:\d{2}$/.test(b.valid_until || "")) errs.push("invalid valid_until (HH:MM)");
  if (b.take_profit != null && (typeof b.take_profit !== "number" || !isFinite(b.take_profit))) errs.push("invalid take_profit");
  if (b.partial_take_profit != null && (typeof b.partial_take_profit !== "number" || !isFinite(b.partial_take_profit)))
    errs.push("invalid partial_take_profit");
  if (b.level_size != null && !VALID_LEVEL_SIZES.includes(b.level_size)) errs.push("invalid level_size");
  if (b.close_time != null && b.close_time !== "" && !/^\d{2}:\d{2}$/.test(b.close_time)) errs.push("invalid close_time (HH:MM)");
  if (b.valid_until_next_day != null && typeof b.valid_until_next_day !== "boolean") errs.push("invalid valid_until_next_day");
  if (b.manual_close != null && typeof b.manual_close !== "boolean") errs.push("invalid manual_close");
  if (b.close_after_minutes != null && b.close_after_minutes !== "") {
    if (!Number.isInteger(b.close_after_minutes) || b.close_after_minutes <= 0) {
      errs.push("invalid close_after_minutes (positive integer)");
    }
    if (b.close_time) errs.push("close_time and close_after_minutes are mutually exclusive");
  }
  if (b.manual_close && (b.close_time || (b.close_after_minutes != null && b.close_after_minutes !== ""))) {
    errs.push("manual_close excludes close_time and close_after_minutes");
  }
  return errs;
}

// A trade is active while its active_until_utc is in the future. Past trades
// are not kept: they are dropped from trades.json whenever a new trade is saved.
// (report_at_utc is the same deadline on trades saved by older versions.)
function isActive(t, nowMs) {
  const horizon = t.active_until_utc || t.report_at_utc;
  if (!horizon) return false;
  return new Date(horizon).getTime() > nowMs;
}

// ---------- Routes ----------

// GET /<SYMBOL> - active trades the EA must still manage.
// This intentionally does NOT filter on local_date so that:
//   - trades using "valid_until next day" remain visible after midnight
//   - trades whose limit has filled and become a position remain visible so
//     the EA can manage partial TP / auto-close even after a restart
app.get("/:symbol", (req, res) => {
  const symbol = req.params.symbol.toUpperCase();
  if (!validateSymbol(symbol)) return res.status(400).json({ error: "invalid symbol" });

  const now = Date.now();
  const active = readJsonArray(TRADES_FILE).filter((t) => t.symbol === symbol && isActive(t, now));
  res.json(active);
});

app.post("/:symbol", (req, res) => {
  const symbol = req.params.symbol.toUpperCase();
  if (!validateSymbol(symbol)) return res.status(400).json({ error: "invalid symbol" });

  const body = { ...(req.body || {}), symbol };
  const errs = validateTradeBody(body);
  if (errs.length) return res.status(400).json({ error: "validation failed", details: errs });

  const localDate = todayInTZ(TZ);
  const validUntilDate = body.valid_until_next_day ? addDaysISO(localDate, 1) : localDate;
  const validUntilUTC = zonedDateTimeToUTC(validUntilDate, body.valid_until, TZ);
  // close_time falls on the same day as valid_until.
  const closeTimeUTC = body.close_time ? zonedDateTimeToUTC(validUntilDate, body.close_time, TZ) : null;

  if (closeTimeUTC && closeTimeUTC.getTime() <= validUntilUTC.getTime()) {
    return res.status(400).json({
      error: "validation failed",
      details: ["close_time must be after valid_until"],
    });
  }

  // active_until_utc: how long GET /<SYMBOL> keeps serving the trade to the EA.
  // If close_time is set, that is the cutoff.
  // If close_after_minutes is set, the latest possible auto-close is
  // valid_until_utc + close_after_minutes (since the limit can fill at the
  // last allowed moment); add a 60-minute buffer so the EA still sees the
  // trade when the close is due.
  // Otherwise (manual close) default to 23:59 local of the valid_until date.
  const closeAfterMinutes = body.close_after_minutes != null && body.close_after_minutes !== "" ? Number(body.close_after_minutes) : null;
  let activeUntilUTC;
  if (closeTimeUTC) {
    activeUntilUTC = closeTimeUTC;
  } else if (closeAfterMinutes) {
    activeUntilUTC = new Date(validUntilUTC.getTime() + (closeAfterMinutes + 60) * 60_000);
  } else {
    activeUntilUTC = zonedDateTimeToUTC(validUntilDate, "23:59", TZ);
  }

  const now = Date.now();
  const trades = readJsonArray(TRADES_FILE).filter((t) => isActive(t, now));

  const orderKind = body.order_kind || "limit";
  const trade = {
    id: generateTradeId(trades),
    symbol,
    direction: body.direction,
    order_kind: orderKind,
    limit_price: orderKind === "market" ? (body.limit_price ?? null) : body.limit_price,
    stop_loss: body.stop_loss,
    take_profit: body.take_profit ?? null,
    partial_take_profit: body.partial_take_profit ?? null,
    level_type: body.level_type,
    level_size: body.level_size ?? null,
    valid_until: body.valid_until,
    valid_until_next_day: !!body.valid_until_next_day,
    close_time: body.close_time || null,
    close_after_minutes: closeAfterMinutes,
    manual_close: !!body.manual_close,
    local_date: localDate,
    timezone: TZ,
    valid_until_utc: validUntilUTC.toISOString(),
    close_time_utc: closeTimeUTC ? closeTimeUTC.toISOString() : null,
    active_until_utc: activeUntilUTC.toISOString(),
    created_at: new Date().toISOString(),
  };

  trades.push(trade);
  writeJsonArray(TRADES_FILE, trades);
  res.status(201).json(trade);
});

app.listen(PORT, () => {
  console.log(`zoneTrader server listening on :${PORT} (tz=${TZ})`);
});
