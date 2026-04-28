//+------------------------------------------------------------------+
//|                                                  ZoneTrader.mq5  |
//|  Polls zoneTrader server for trade levels, places limit orders,  |
//|  manages partial TPs, cancels expired pendings, sends reports.   |
//+------------------------------------------------------------------+
#property copyright "ZoneTrader"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>

//--- Inputs
input string  ServerURL    = "http://37.46.211.146:3001";
input double  RiskAmount   = 40.0;     // $ at risk per trade
input int     PollMinutes  = 10;       // polling interval
input int     SlippagePts  = 20;       // deviation (points) for market entries, partial closes and auto-close

CTrade trade;

//+------------------------------------------------------------------+
//| Symbol -> magic number table                                     |
//+------------------------------------------------------------------+
int MagicForSymbol(const string base)
{
   if(base=="EURUSD") return 1001;
   if(base=="GBPUSD") return 1002;
   if(base=="USDJPY") return 1003;
   if(base=="EURGBP") return 1004;
   if(base=="AUDUSD") return 1005;
   if(base=="AUDNZD") return 1006;
   if(base=="EURJPY") return 1007;
   if(base=="USDCAD") return 1008;
   if(base=="XAUUSD") return 1009;
   return 0;
}

//+------------------------------------------------------------------+
//| Strip suffix from symbol, return matching base or ""             |
//+------------------------------------------------------------------+
string ResolveBaseSymbol(const string sym)
{
   string up = sym;
   StringToUpper(up);
   string bases[] = {"EURUSD","GBPUSD","USDJPY","EURGBP","AUDUSD","AUDNZD","EURJPY","USDCAD","XAUUSD"};
   for(int i=0;i<ArraySize(bases);i++)
      if(StringFind(up, bases[i]) == 0) return bases[i];
   return "";
}

//--- runtime
string g_baseSymbol = "";
int    g_magic      = 0;
datetime g_lastPoll = 0;

//--- in-memory tracking
string g_knownIds[];
string g_partialDoneIds[];
string g_reportedIds[];

//+------------------------------------------------------------------+
bool ArrayContainsStr(const string &arr[], const string val)
{
   for(int i=0;i<ArraySize(arr);i++) if(arr[i]==val) return true;
   return false;
}
void ArrayPushStr(string &arr[], const string val)
{
   int n=ArraySize(arr);
   ArrayResize(arr, n+1);
   arr[n]=val;
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_baseSymbol = ResolveBaseSymbol(_Symbol);
   if(g_baseSymbol=="")
   {
      Print("ZoneTrader: chart symbol ", _Symbol, " does not match any supported base. EA disabled.");
      return INIT_FAILED;
   }
   g_magic = MagicForSymbol(g_baseSymbol);
   trade.SetExpertMagicNumber(g_magic);
   trade.SetDeviationInPoints(SlippagePts);

   EventSetTimer(30);
   Print("ZoneTrader started. base=", g_baseSymbol, " magic=", g_magic);
   PollAndAct();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer()
{
   ManagePartials();
   ManageAutoClose();
   ManageExpiry();
   ManageEndOfDay();
   if(TimeCurrent() - g_lastPoll >= PollMinutes*60)
      PollAndAct();
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong dealTicket = trans.deal;
   if(dealTicket==0) return;
   if(!HistoryDealSelect(dealTicket)) return;

   long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   if(magic != g_magic) return;
   long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   string comment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
   string id = ExtractIdFromComment(comment);
   if(id=="") return;

   if(PositionExistsForId(id)) return;
   if(ArrayContainsStr(g_reportedIds, id)) return;

   double price  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   long   reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
   string reasonStr = "manual";
   if(reason==DEAL_REASON_SL) reasonStr="sl";
   else if(reason==DEAL_REASON_TP) reasonStr="tp";
   else if(reason==DEAL_REASON_EXPERT) reasonStr="expert";
   else if(reason==DEAL_REASON_CLIENT) reasonStr="client";

   if(SendReport(id, price, reasonStr))
      ArrayPushStr(g_reportedIds, id);
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string ExtractIdFromComment(const string c)
{
   int p = StringFind(c, "ZT:");
   if(p<0) return "";
   string s = StringSubstr(c, p+3);
   // Strip trailing whitespace some brokers append.
   StringTrimLeft(s); StringTrimRight(s);
   return s;
}

bool PositionExistsForId(const string id)
{
   int total = PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      string c = PositionGetString(POSITION_COMMENT);
      if(ExtractIdFromComment(c) == id) return true;
   }
   return false;
}

bool OrderExistsForId(const string id)
{
   int total = OrdersTotal();
   for(int i=0;i<total;i++)
   {
      ulong tk = OrderGetTicket(i);
      if(tk==0) continue;
      if((int)OrderGetInteger(ORDER_MAGIC) != g_magic) continue;
      string c = OrderGetString(ORDER_COMMENT);
      if(ExtractIdFromComment(c) == id) return true;
   }
   return false;
}

ulong FindOrderTicketForId(const string id)
{
   int total = OrdersTotal();
   for(int i=0;i<total;i++)
   {
      ulong tk = OrderGetTicket(i);
      if(tk==0) continue;
      if((int)OrderGetInteger(ORDER_MAGIC) != g_magic) continue;
      string c = OrderGetString(ORDER_COMMENT);
      if(ExtractIdFromComment(c) == id) return tk;
   }
   return 0;
}

ulong FindPositionTicketForId(const string id)
{
   int total = PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      string c = PositionGetString(POSITION_COMMENT);
      if(ExtractIdFromComment(c) == id) return tk;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Find a closing deal for `id` in account history.                 |
//| Returns true and fills price/reasonStr when found.               |
//+------------------------------------------------------------------+
bool FindClosingDealForId(const string id, double &outPrice, string &outReason)
{
   // Look back ~30 days; trades shouldn't outlive that horizon.
   datetime to   = TimeCurrent() + 60;
   datetime from = to - 30*24*60*60;
   if(!HistorySelect(from, to)) return false;

   int total = HistoryDealsTotal();
   datetime bestTime = 0;
   bool found = false;
   for(int i=0;i<total;i++)
   {
      ulong dt = HistoryDealGetTicket(i);
      if(dt==0) continue;
      if((int)HistoryDealGetInteger(dt, DEAL_MAGIC) != g_magic) continue;
      long entry = HistoryDealGetInteger(dt, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;
      string c = HistoryDealGetString(dt, DEAL_COMMENT);
      if(ExtractIdFromComment(c) != id) continue;

      datetime t = (datetime)HistoryDealGetInteger(dt, DEAL_TIME);
      if(t < bestTime) continue; // pick the latest closing deal
      bestTime = t;
      outPrice = HistoryDealGetDouble(dt, DEAL_PRICE);
      long reason = HistoryDealGetInteger(dt, DEAL_REASON);
      if(reason==DEAL_REASON_SL) outReason="sl";
      else if(reason==DEAL_REASON_TP) outReason="tp";
      else if(reason==DEAL_REASON_EXPERT) outReason="expert";
      else if(reason==DEAL_REASON_CLIENT) outReason="client";
      else outReason="manual";
      found = true;
   }
   return found;
}

//+------------------------------------------------------------------+
//| HTTP helpers                                                     |
//+------------------------------------------------------------------+
string HttpGet(const string url)
{
   char data[], result[];
   string headers = "";
   string resp_headers;
   ResetLastError();
   int code = WebRequest("GET", url, headers, 5000, data, result, resp_headers);
   if(code==-1)
   {
      Print("WebRequest GET error ", GetLastError(), " url=", url,
            " (Tools->Options->Expert Advisors->Allow WebRequest for ", ServerURL, ")");
      return "";
   }
   if(code<200 || code>=300)
   {
      Print("WebRequest GET status ", code, " url=", url);
      return "";
   }
   return CharArrayToString(result, 0, -1, CP_UTF8);
}

int HttpPostJson(const string url, const string body, string &response)
{
   char data[], result[];
   string headers = "Content-Type: application/json\r\n";
   string resp_headers;
   StringToCharArray(body, data, 0, StringLen(body), CP_UTF8);
   ResetLastError();
   int code = WebRequest("POST", url, headers, 5000, data, result, resp_headers);
   if(code==-1)
   {
      Print("WebRequest POST error ", GetLastError(), " url=", url);
      return -1;
   }
   response = CharArrayToString(result, 0, -1, CP_UTF8);
   return code;
}

//+------------------------------------------------------------------+
//| Tiny JSON helpers                                                |
//+------------------------------------------------------------------+
string JsonGetString(const string obj, const string key)
{
   string pat = "\"" + key + "\"";
   int p = StringFind(obj, pat);
   if(p<0) return "";
   p = StringFind(obj, ":", p);
   if(p<0) return "";
   p++;
   while(p<StringLen(obj) && (StringGetCharacter(obj,p)==' '||StringGetCharacter(obj,p)=='\t')) p++;
   if(p>=StringLen(obj)) return "";
   ushort ch = StringGetCharacter(obj, p);
   if(ch=='\"')
   {
      int q = p+1;
      string out = "";
      while(q<StringLen(obj))
      {
         ushort c = StringGetCharacter(obj, q);
         if(c=='\\' && q+1<StringLen(obj))
         {
            ushort c2 = StringGetCharacter(obj, q+1);
            out += ShortToString(c2);
            q+=2; continue;
         }
         if(c=='\"') break;
         out += ShortToString(c);
         q++;
      }
      return out;
   }
   // number / bool / null - read until , or } or ]
   int q=p;
   while(q<StringLen(obj))
   {
      ushort c = StringGetCharacter(obj, q);
      if(c==',' || c=='}' || c==']') break;
      q++;
   }
   string v = StringSubstr(obj, p, q-p);
   StringTrimLeft(v); StringTrimRight(v);
   if(v=="null") return "";
   return v;
}

double JsonGetNumber(const string obj, const string key, double defv)
{
   string s = JsonGetString(obj, key);
   if(s=="") return defv;
   return (double)StringToDouble(s);
}

int JsonSplitArray(const string arr, string &out[])
{
   ArrayResize(out, 0);
   int n = StringLen(arr);
   int i=0;
   while(i<n && StringGetCharacter(arr,i)!='[') i++;
   if(i>=n) return 0;
   i++;
   while(i<n)
   {
      while(i<n)
      {
         ushort c = StringGetCharacter(arr,i);
         if(c==' '||c=='\n'||c=='\r'||c=='\t'||c==',') { i++; continue; }
         break;
      }
      if(i>=n) break;
      ushort c = StringGetCharacter(arr,i);
      if(c==']') break;
      if(c!='{') { i++; continue; }
      int depth=0, start=i;
      bool inStr=false; bool esc=false;
      for(; i<n; i++)
      {
         ushort ch = StringGetCharacter(arr,i);
         if(inStr)
         {
            if(esc) { esc=false; continue; }
            if(ch=='\\') { esc=true; continue; }
            if(ch=='\"') inStr=false;
            continue;
         }
         if(ch=='\"') { inStr=true; continue; }
         if(ch=='{') depth++;
         else if(ch=='}')
         {
            depth--;
            if(depth==0) { i++; break; }
         }
      }
      string elem = StringSubstr(arr, start, i-start);
      int sz = ArraySize(out);
      ArrayResize(out, sz+1);
      out[sz] = elem;
   }
   return ArraySize(out);
}

//+------------------------------------------------------------------+
//| Position sizing                                                  |
//+------------------------------------------------------------------+
double CalcLotSize(const string sym, double entry, double sl)
{
   double dist = MathAbs(entry - sl);
   if(dist<=0) return 0;

   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0 || tickValue<=0) return 0;

   double lossPerLot = (dist / tickSize) * tickValue;
   if(lossPerLot<=0) return 0;

   double lots = RiskAmount / lossPerLot;

   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(stepLot<=0) stepLot = 0.01;

   lots = MathFloor(lots / stepLot) * stepLot;
   if(lots < minLot) return 0;
   if(lots > maxLot) lots = maxLot;
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Place a pending limit order from a server-provided trade         |
//+------------------------------------------------------------------+
void PlaceFromTrade(const string elem)
{
   string id        = JsonGetString(elem, "id");
   string direction = JsonGetString(elem, "direction");
   string limitStr  = JsonGetString(elem, "limit_price");
   double limit     = (limitStr=="" ? 0 : (double)StringToDouble(limitStr));
   double sl        = JsonGetNumber(elem, "stop_loss",  0);
   string tpStr     = JsonGetString(elem, "take_profit");
   double tp        = (tpStr=="" ? 0 : (double)StringToDouble(tpStr));
   string ltype     = JsonGetString(elem, "level_type");
   string okind     = JsonGetString(elem, "order_kind");
   bool   isMarket  = (okind == "market");

   if(id=="" || sl<=0) return;
   if(!isMarket && limit<=0) return;
   // Only "order" level_type creates real orders.
   // "watch" and "option" are informational; the server still returns them
   // so the UI can show them, but the EA must skip them.
   if(ltype != "order") return;

   if(ArrayContainsStr(g_knownIds, id)) return;
   if(OrderExistsForId(id) || PositionExistsForId(id)) { ArrayPushStr(g_knownIds, id); return; }

   string sym = _Symbol;
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

   // For market orders, size against the current execution price.
   double sizingPrice = limit;
   if(isMarket) sizingPrice = (direction=="long" ? ask : bid);

   double lots = CalcLotSize(sym, sizingPrice, sl);
   if(lots<=0)
   {
      Print("ZoneTrader: lot size 0 for id=", id);
      return;
   }

   bool ok=false;
   string comment = "ZT:" + id;

   if(isMarket)
   {
      // Sanity-check that SL is on the correct side of current price.
      if(direction=="long")
      {
         if(sl >= ask) { Print("ZoneTrader: long market SL ", sl, " >= ask ", ask, ", skipping ", id); return; }
         ok = trade.Buy(lots, sym, 0.0, sl, tp, comment);
      }
      else if(direction=="short")
      {
         if(sl <= bid) { Print("ZoneTrader: short market SL ", sl, " <= bid ", bid, ", skipping ", id); return; }
         ok = trade.Sell(lots, sym, 0.0, sl, tp, comment);
      }
      if(ok)
         Print("ZoneTrader: executed ", direction, " market lots=", lots, " id=", id);
   }
   else if(direction=="long")
   {
      if(limit >= ask)
      {
         Print("ZoneTrader: long limit ", limit, " >= ask ", ask, ", skipping ", id);
         return;
      }
      ok = trade.BuyLimit(lots, limit, sym, sl, tp, ORDER_TIME_GTC, 0, comment);
      if(ok) Print("ZoneTrader: placed long limit ", limit, " lots=", lots, " id=", id);
   }
   else if(direction=="short")
   {
      if(limit <= bid)
      {
         Print("ZoneTrader: short limit ", limit, " <= bid ", bid, ", skipping ", id);
         return;
      }
      ok = trade.SellLimit(lots, limit, sym, sl, tp, ORDER_TIME_GTC, 0, comment);
      if(ok) Print("ZoneTrader: placed short limit ", limit, " lots=", lots, " id=", id);
   }

   if(ok)
   {
      ArrayPushStr(g_knownIds, id);
   }
   else
   {
      Print("ZoneTrader: order placement failed id=", id, " err=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Poll server                                                      |
//+------------------------------------------------------------------+
void PollAndAct()
{
   g_lastPoll = TimeCurrent();
   string url = ServerURL + "/" + g_baseSymbol;
   string body = HttpGet(url);
   if(body=="") return;

   string elems[];
   int n = JsonSplitArray(body, elems);
   for(int i=0;i<n;i++) PlaceFromTrade(elems[i]);

   CacheServerTrades(elems);

   // For every cached id, if there's no live order/position and no report yet,
   // scan deal history. This catches closes that happened while the EA was off
   // (e.g. SL hit, manual close).
   ReconcileMissedCloses();
}

//+------------------------------------------------------------------+
//| Cached server data                                               |
//+------------------------------------------------------------------+
string g_cacheIds[];
double g_cachePartialTP[];
string g_cacheDirection[];
string g_cacheValidUntilUTC[];
string g_cacheReportAtUTC[];
string g_cacheCloseTimeUTC[];
string g_cacheLevelType[];

void CacheServerTrades(const string &elems[])
{
   ArrayResize(g_cacheIds, 0);
   ArrayResize(g_cachePartialTP, 0);
   ArrayResize(g_cacheDirection, 0);
   ArrayResize(g_cacheValidUntilUTC, 0);
   ArrayResize(g_cacheReportAtUTC, 0);
   ArrayResize(g_cacheCloseTimeUTC, 0);
   ArrayResize(g_cacheLevelType, 0);
   for(int i=0;i<ArraySize(elems);i++)
   {
      string id  = JsonGetString(elems[i], "id");
      string dir = JsonGetString(elems[i], "direction");
      string ptp = JsonGetString(elems[i], "partial_take_profit");
      string vu  = JsonGetString(elems[i], "valid_until_utc");
      string ra  = JsonGetString(elems[i], "report_at_utc");
      string ct  = JsonGetString(elems[i], "close_time_utc");
      string lt  = JsonGetString(elems[i], "level_type");
      double p   = (ptp=="" ? 0 : (double)StringToDouble(ptp));
      int sz = ArraySize(g_cacheIds);
      ArrayResize(g_cacheIds,            sz+1);
      ArrayResize(g_cachePartialTP,      sz+1);
      ArrayResize(g_cacheDirection,      sz+1);
      ArrayResize(g_cacheValidUntilUTC,  sz+1);
      ArrayResize(g_cacheReportAtUTC,    sz+1);
      ArrayResize(g_cacheCloseTimeUTC,   sz+1);
      ArrayResize(g_cacheLevelType,      sz+1);
      g_cacheIds[sz]=id;
      g_cachePartialTP[sz]=p;
      g_cacheDirection[sz]=dir;
      g_cacheValidUntilUTC[sz]=vu;
      g_cacheReportAtUTC[sz]=ra;
      g_cacheCloseTimeUTC[sz]=ct;
      g_cacheLevelType[sz]=lt;
   }
}

//+------------------------------------------------------------------+
//| Partial TP                                                       |
//+------------------------------------------------------------------+
void ManagePartials()
{
   for(int i=0;i<ArraySize(g_cacheIds);i++)
   {
      string id = g_cacheIds[i];
      double ptp = g_cachePartialTP[i];
      if(ptp<=0) continue;
      if(ArrayContainsStr(g_partialDoneIds, id)) continue;

      ulong posTicket = FindPositionTicketForId(id);
      if(posTicket==0) continue;
      if(!PositionSelectByTicket(posTicket)) continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      string sym = PositionGetString(POSITION_SYMBOL);
      long   ptype = PositionGetInteger(POSITION_TYPE);
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

      bool reached = false;
      if(ptype==POSITION_TYPE_BUY  && bid >= ptp) reached = true;
      if(ptype==POSITION_TYPE_SELL && ask <= ptp) reached = true;
      if(!reached) continue;

      double stepLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      if(stepLot<=0) stepLot=0.01;
      double half = MathFloor((vol*0.5)/stepLot)*stepLot;
      double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      if(half < minLot)
      {
         ArrayPushStr(g_partialDoneIds, id);
         continue;
      }
      if(trade.PositionClosePartial(posTicket, half))
      {
         Print("ZoneTrader: partial-TP closed ", half, " of id=", id);
         ArrayPushStr(g_partialDoneIds, id);
      }
      else
      {
         Print("ZoneTrader: partial close failed id=", id, " err=", trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//| Auto-close: when close_time passes, force-close any live         |
//| position for this id (and cancel a still-pending order). The     |
//| reconcile / EoD step will pick up the resulting closing deal and |
//| report the real exit price.                                      |
//+------------------------------------------------------------------+
void ManageAutoClose()
{
   datetime now = TimeGMT();
   for(int i=0;i<ArraySize(g_cacheIds);i++)
   {
      string id = g_cacheIds[i];
      if(id=="") continue;
      string ct = g_cacheCloseTimeUTC[i];
      if(ct=="") continue; // only auto-close when user explicitly set close_time
      datetime deadline = ParseISO8601UTC(ct);
      if(deadline==0 || now < deadline) continue;

      // Cancel a still-pending order (limit never filled by close_time).
      ulong ordTicket = FindOrderTicketForId(id);
      if(ordTicket!=0)
      {
         if(trade.OrderDelete(ordTicket))
            Print("ZoneTrader: close_time reached, cancelled pending id=", id);
         else
            Print("ZoneTrader: close_time cancel failed id=", id, " err=", trade.ResultRetcodeDescription());
      }

      // Close any open position for this id.
      ulong posTicket = FindPositionTicketForId(id);
      if(posTicket!=0)
      {
         if(trade.PositionClose(posTicket))
            Print("ZoneTrader: close_time reached, closed position id=", id);
         else
            Print("ZoneTrader: close_time PositionClose failed id=", id, " err=", trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//| Expiry: cancel pending limit orders past valid_until             |
//+------------------------------------------------------------------+
datetime ParseISO8601UTC(const string s)
{
   if(StringLen(s)<19) return 0;
   int y  = (int)StringToInteger(StringSubstr(s, 0, 4));
   int mo = (int)StringToInteger(StringSubstr(s, 5, 2));
   int d  = (int)StringToInteger(StringSubstr(s, 8, 2));
   int h  = (int)StringToInteger(StringSubstr(s,11, 2));
   int mi = (int)StringToInteger(StringSubstr(s,14, 2));
   int se = (int)StringToInteger(StringSubstr(s,17, 2));
   MqlDateTime mdt;
   mdt.year=y; mdt.mon=mo; mdt.day=d; mdt.hour=h; mdt.min=mi; mdt.sec=se;
   return StructToTime(mdt);
}

void ManageExpiry()
{
   datetime now = TimeGMT();
   for(int i=0;i<ArraySize(g_cacheIds);i++)
   {
      string id = g_cacheIds[i];
      string vu = g_cacheValidUntilUTC[i];
      if(vu=="") continue;
      datetime exp = ParseISO8601UTC(vu);
      if(exp==0 || now < exp) continue;
      ulong tk = FindOrderTicketForId(id);
      if(tk==0) continue;
      if(trade.OrderDelete(tk))
         Print("ZoneTrader: cancelled expired pending id=", id);
      else
         Print("ZoneTrader: cancel failed id=", id, " err=", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| End-of-day: send a report once report_at_utc passes, even if the |
//| user keeps managing the position manually. Uses current bid/ask  |
//| as the reported "exit_price" snapshot.                           |
//+------------------------------------------------------------------+
void ManageEndOfDay()
{
   datetime now = TimeGMT();
   for(int i=0;i<ArraySize(g_cacheIds);i++)
   {
      string id = g_cacheIds[i];
      if(id=="") continue;
      if(ArrayContainsStr(g_reportedIds, id)) continue;

      string ra = g_cacheReportAtUTC[i];
      if(ra=="") continue;
      datetime deadline = ParseISO8601UTC(ra);
      if(deadline==0 || now < deadline) continue;

      // Prefer the actual exit price if the position is already closed.
      double price = 0;
      string reason = "eod";
      if(FindClosingDealForId(id, price, reason))
      {
         if(SendReport(id, price, reason))
            ArrayPushStr(g_reportedIds, id);
         continue;
      }

      // Position still open (or never opened). Snapshot current price.
      string sym = _Symbol;
      string dir = g_cacheDirection[i];
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      // Closing price for a long is bid, for a short is ask.
      price = (dir=="short" ? ask : bid);
      if(price<=0) continue;

      if(SendReport(id, price, "eod"))
         ArrayPushStr(g_reportedIds, id);
   }
}

//+------------------------------------------------------------------+
//| Reconcile: catch closes we may have missed while the EA was off  |
//+------------------------------------------------------------------+
void ReconcileMissedCloses()
{
   for(int i=0;i<ArraySize(g_cacheIds);i++)
   {
      string id = g_cacheIds[i];
      if(id=="") continue;
      if(ArrayContainsStr(g_reportedIds, id)) continue;
      if(PositionExistsForId(id)) continue;
      if(OrderExistsForId(id))    continue;

      double price = 0;
      string reason = "manual";
      if(!FindClosingDealForId(id, price, reason)) continue;
      if(SendReport(id, price, reason))
         ArrayPushStr(g_reportedIds, id);
   }
}

//+------------------------------------------------------------------+
//| Send report to /reports/<SYMBOL>                                 |
//+------------------------------------------------------------------+
bool SendReport(const string id, double exitPrice, const string reason)
{
   string url = ServerURL + "/reports/" + g_baseSymbol;
   string nowStr = TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS);
   StringReplace(nowStr, ".", "-");
   StringReplace(nowStr, " ", "T");
   nowStr += "Z";

   string body = StringFormat(
      "{\"id\":\"%s\",\"exit_price\":%.5f,\"exit_reason\":\"%s\",\"exit_time\":\"%s\"}",
      id, exitPrice, reason, nowStr);

   string resp;
   int code = HttpPostJson(url, body, resp);
   if(code==201) { Print("ZoneTrader: reported id=", id, " exit=", exitPrice, " reason=", reason); return true; }
   if(code==409) { Print("ZoneTrader: report duplicate id=", id); return true; }
   Print("ZoneTrader: report failed id=", id, " code=", code, " resp=", resp);
   return false;
}

//+------------------------------------------------------------------+
void OnTick() { }
