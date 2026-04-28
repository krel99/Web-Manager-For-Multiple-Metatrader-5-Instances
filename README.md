# zoneTrader

Three components:

1. **Express server** (`index.js`) — listens on port `3001`.
2. **Web UI** (`public/index.html`) — vanilla HTML served by the server at `/`.
3. **MT5 Expert Advisor** (`mt5/ZoneTrader.mq5`).

## Setup

```
npm install
npm start
```

Open `http://localhost:3001/`.

Data is persisted as flat JSON files next to `index.js`:

- `trades.json` — every submitted trade.
- `reports.json` — every closed-trade report from MT5.

## Time zones

The web UI submits times in **CET/CEST** (`Europe/Berlin`). The server
converts them to UTC at write-time (`valid_until_utc`, `close_time_utc`)
and stores the original `HH:MM` strings as `valid_until` / `close_time`.

## API

- `GET /<SYMBOL>` — active (today, not expired, not yet reported) trades.
- `POST /<SYMBOL>` — create a trade. Body fields:
  `direction`, `limit_price`, `stop_loss`, `level_type`, `valid_until` (HH:MM),
  optional: `take_profit`, `partial_take_profit`, `level_size`, `close_time`.
- `POST /reports/<SYMBOL>` — append a report. Body:
  `id`, `exit_price`, optional `exit_reason`, `exit_time`. Returns `409` on duplicate `id`.
- `GET /trades`, `GET /reports` — full history (used by the UI).

## MT5 EA

Compile `mt5/ZoneTrader.mq5` in MetaEditor and attach to a chart whose
symbol resolves to one of: `EURUSD, GBPUSD, USDJPY, EURGBP, AUDUSD,
AUDNZD, EURJPY, USDCAD, XAUUSD` (broker suffixes like `_ecn` are
stripped — the base must be the *prefix* of the chart symbol).

Magic numbers:

| Symbol  | Magic |
|---------|-------|
| EURUSD  | 1001  |
| GBPUSD  | 1002  |
| USDJPY  | 1003  |
| EURGBP  | 1004  |
| AUDUSD  | 1005  |
| AUDNZD  | 1006  |
| EURJPY  | 1007  |
| USDCAD  | 1008  |
| XAUUSD  | 1009  |

Inputs:

- `ServerURL` — default `http://37.46.211.146:3001`. Must be added to
  **Tools → Options → Expert Advisors → Allow WebRequest for listed URL**.
- `RiskAmount` — $ risked per trade (default 40).
- `Capital` — kept for spec compatibility; sizing only depends on
  `RiskAmount` and stop distance.
- `PollMinutes` — default 10.

Behavior:

- Polls `GET /<BASE>` every `PollMinutes`.
- For every new trade ID, places a pending **limit** order at
  `limit_price` with `stop_loss` and `take_profit` (if any). Orders are
  tagged `ZT:<id>` in the comment.
- `level_type` and `level_size` are stored for analytics only — every
  level becomes a limit order.
- When `partial_take_profit` is reached, closes 50% of the current
  volume rounded **down** to the volume step. **Stop loss is not
  moved.**
- Cancels still-pending orders whose `valid_until_utc` has passed.
- On exit (SL/TP/manual close, deal `DEAL_ENTRY_OUT`), `POST`s to
  `/reports/<BASE>`. Duplicate `409`s are treated as success so multiple
  EA instances on the same trade do not double-report.
# Web-Manager-For-Multiple-Metatrader-5-Instances
