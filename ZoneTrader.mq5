//+------------------------------------------------------------------+
//|                                                  ZoneTrader.mq5  |
//|  Polls zoneTrader server for trade levels, places limit orders,  |
//|  manages partial TPs, cancels expired pendings, auto-closes.     |
//+------------------------------------------------------------------+
#property copyright "ZoneTrader"
#property version   "1.20"
#property strict

#include <Trade\Trade.mqh>

//--- Inputs
input string  ServerURL    = "http://37.46.211.146:3001";
input double  RiskAmount   = 40.0;     // $ at risk per trade
input int     PollMinutes  = 1;       // polling interval
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

//--- in-memory dedup (placement, partial TP)
string g_knownIds[];
string g_partialDoneIds[];

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
   if(TimeCurrent() - g_lastPoll >= PollMinutes*60)
      PollAndAct();
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
   string okind     = JsonGetString(elem, "order_kind");
   bool   isMarket  = (okind == "market");
   string vu        = JsonGetString(elem, "valid_until_utc");

   if(id=="" || sl<=0) return;
   if(!isMarket && limit<=0) return;
   // level_type (watch/order/option) is record-keeping metadata only;
   // every submitted trade is executed.

   if(ArrayContainsStr(g_knownIds, id)) return;
   if(OrderExistsForId(id) || PositionExistsForId(id)) { ArrayPushStr(g_knownIds, id); return; }

   // Refuse to open a trade whose valid_until has already passed. Market
   // orders cannot be "cancelled" after submission, and there is no point
   // placing a limit order that ManageExpiry would just delete on the next
   // tick. valid_until_utc is the authoritative deadline (the server resolves
   // local_date + valid_until + valid_until_next_day for us).
   if(vu != "")
   {
      datetime exp = ParseISO8601UTC(vu);
      if(exp != 0 && TimeGMT() >= exp)
      {
         Print("ZoneTrader: skipping expired trade id=", id,
               " valid_until_utc=", vu, " (now ", TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS), " UTC)");
         return;
      }
   }

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
}

//+------------------------------------------------------------------+
//| Cached server data                                               |
//+------------------------------------------------------------------+
string g_cacheIds[];
double g_cachePartialTP[];
string g_cacheValidUntilUTC[];
string g_cacheCloseTimeUTC[];
int    g_cacheCloseAfterMin[];

void CacheServerTrades(const string &elems[])
{
   ArrayResize(g_cacheIds, 0);
   ArrayResize(g_cachePartialTP, 0);
   ArrayResize(g_cacheValidUntilUTC, 0);
   ArrayResize(g_cacheCloseTimeUTC, 0);
   ArrayResize(g_cacheCloseAfterMin, 0);
   for(int i=0;i<ArraySize(elems);i++)
   {
      string id  = JsonGetString(elems[i], "id");
      string ptp = JsonGetString(elems[i], "partial_take_profit");
      string vu  = JsonGetString(elems[i], "valid_until_utc");
      string ct  = JsonGetString(elems[i], "close_time_utc");
      string cam = JsonGetString(elems[i], "close_after_minutes");
      int    cami = (cam=="" ? 0 : (int)StringToInteger(cam));
      double p   = (ptp=="" ? 0 : (double)StringToDouble(ptp));
      int sz = ArraySize(g_cacheIds);
      ArrayResize(g_cacheIds,            sz+1);
      ArrayResize(g_cachePartialTP,      sz+1);
      ArrayResize(g_cacheValidUntilUTC,  sz+1);
      ArrayResize(g_cacheCloseTimeUTC,   sz+1);
      ArrayResize(g_cacheCloseAfterMin,  sz+1);
      g_cacheIds[sz]=id;
      g_cachePartialTP[sz]=p;
      g_cacheValidUntilUTC[sz]=vu;
      g_cacheCloseTimeUTC[sz]=ct;
      g_cacheCloseAfterMin[sz]=cami;
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
//| position for this id (and cancel a still-pending order).         |
//| Trades with neither close_time nor close_after_minutes (manual   |
//| close) are never closed by the EA.                               |
//+------------------------------------------------------------------+
void ManageAutoClose()
{
   // UTC clock for absolute deadlines (close_time_utc); broker server clock
   // for elapsed-since-open math because POSITION_TIME is in server time.
   datetime nowUTC    = TimeGMT();
   datetime nowServer = TimeCurrent();
   for(int i=0;i<ArraySize(g_cacheIds);i++)
   {
      string id = g_cacheIds[i];
      if(id=="") continue;
      string ct      = g_cacheCloseTimeUTC[i];
      int    afterMin = g_cacheCloseAfterMin[i];

      // Mode A: absolute close_time (UTC deadline shared by order+position).
      if(ct != "")
      {
         datetime deadline = ParseISO8601UTC(ct);
         if(deadline==0 || nowUTC < deadline) continue;

         ulong ordTicket = FindOrderTicketForId(id);
         if(ordTicket!=0)
         {
            if(trade.OrderDelete(ordTicket))
               Print("ZoneTrader: close_time reached, cancelled pending id=", id);
            else
               Print("ZoneTrader: close_time cancel failed id=", id, " err=", trade.ResultRetcodeDescription());
         }
         ulong posTicket = FindPositionTicketForId(id);
         if(posTicket!=0)
         {
            if(trade.PositionClose(posTicket))
               Print("ZoneTrader: close_time reached, closed position id=", id);
            else
               Print("ZoneTrader: close_time PositionClose failed id=", id, " err=", trade.ResultRetcodeDescription());
         }
         continue;
      }

      // Mode B: close N minutes after fill. Pending orders aren't touched
      // here -- ManageExpiry handles those at valid_until. We only act once
      // a position exists for this id.
      if(afterMin > 0)
      {
         ulong posTicket = FindPositionTicketForId(id);
         if(posTicket==0) continue;
         if(!PositionSelectByTicket(posTicket)) continue;
         datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
         if(opened==0) continue;
         // POSITION_TIME is in broker server time -- compare against
         // TimeCurrent(), NOT TimeGMT(), otherwise the result is offset by
         // the broker's timezone (typically GMT+2/+3) and the close fires
         // hours late or, with unsigned datetime arithmetic, not at all.
         if((long)nowServer - (long)opened < (long)afterMin * 60) continue;
         if(trade.PositionClose(posTicket))
            Print("ZoneTrader: close_after_minutes (", afterMin, ") elapsed, closed position id=", id);
         else
            Print("ZoneTrader: close_after_minutes PositionClose failed id=", id, " err=", trade.ResultRetcodeDescription());
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
void OnTick() { }
