//+------------------------------------------------------------------+
//|                                                  RiskManager.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "6.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

// Set this in the EA properties dialog. Deliberately blank in source so the
// credential is never committed. Blank = Discord alerts silently disabled.
input string InpDiscordWebhook = "";  // Discord Webhook URL

//--- Web bridge (state export to the companion web app) -------------
// RM_VERSION is stamped into every state POST. The web app compares it
// against the contract version it was built for and warns on mismatch,
// so a stale EA can never be mistaken for a live one.
#define RM_VERSION "6.01"

input string InpBridgeURL    = "";   // Web bridge base URL, blank = OFF (e.g. http://127.0.0.1:8787)
input string InpBridgeToken  = "";   // Bridge shared secret (must match RM_TOKEN on the server)
input int    InpStatePostSec = 3;    // Seconds between state POSTs
input bool   InpAllowRemote  = false;// Allow remote ARM commands from the web app
input int    InpCmdPollSec   = 2;    // Seconds between command polls (when remote allowed)

//--- Dashboard layout constants
#define PANEL_X         30
#define PANEL_Y         30
#define BTN_W           180
#define BTN_H           46
#define BTN_GAP         8
#define ROW_GAP         6
#define SECTION_GAP     12
#define LABEL_H         24
#define FONT_SIZE       12
#define FONT_SIZE_LBL   10
#define FONT_SIZE_INFO  20
#define FONT_SIZE_INFO2 13
#define LINE_WIDTH      4

//--- Colour palette
#define CLR_PANEL_BG       C'14,14,22'
#define CLR_SECTION_BG     C'24,26,38'
#define CLR_BTN_OFF        C'50,52,68'
#define CLR_BTN_OFF_HOVER  C'70,72,90'
#define CLR_BTN_ON         C'25,118,210'
#define CLR_BTN_ON_HOVER   C'50,145,235'
#define CLR_BTN_BUY        C'0,150,80'
#define CLR_BTN_BUY_HOVER  C'20,185,105'
#define CLR_BTN_SELL       C'195,35,35'
#define CLR_BTN_SELL_HOVER C'225,65,65'
#define CLR_BTN_WARN       C'180,120,0'
#define CLR_BTN_WARN_HOVER C'210,150,20'
#define CLR_BTN_EXIT       C'120,40,160'
#define CLR_BTN_EXIT_HOVER C'150,65,195'
#define CLR_BTN_HIDDEN       C'65,85,135'
#define CLR_BTN_HIDDEN_HOVER C'90,110,170'
#define CLR_BTN_HIDDEN_ON    C'180,50,50'
#define CLR_BTN_HIDDEN_ON_HV C'200,70,70'
#define CLR_BTN_TEAL       C'0,130,130'
#define CLR_BTN_TEAL_HOVER C'20,165,165'
#define CLR_BORDER         C'55,58,75'
#define CLR_BORDER_GOLD    C'185,155,55'
#define CLR_BORDER_ACCENT  C'40,120,210'
#define CLR_TEXT           clrWhite
#define CLR_TEXT_DIM       C'140,145,170'
#define CLR_ENTRY_LINE     C'160,130,20'
#define CLR_TP_LINE        C'0,160,60'
#define CLR_SL_LINE        C'200,30,30'
#define CLR_SMTP_BEIGE     C'160,145,115'
#define CLR_SMTP_GREEN     C'100,210,80'
#define CLR_EXIT_LINE      C'60,120,230'
#define CLR_PART_LINE      C'0,190,190'
#define CLR_CNCL_LINE      C'200,150,0'
#define CLR_INFO_BG        C'15,60,140'
#define CLR_INFO_TEXT      clrWhite
#define CLR_TOOLS_BG       C'18,20,30'
#define CLR_BTN_PLC        C'30,32,45'
#define CLR_BTN_PLC_HOVER  C'40,42,58'

//--- State variables
int    g_riskIndex    = 1;
int    g_slPctIndex   = 1;
int    g_rrIndex      = 1;

double g_riskValues[] = {500, 1000, 1500, 0};
double g_slPctValues[]= {0.25, 0.33, 0.50, 1.00};
double g_rrValues[]   = {1.0, 2.0, 3.0};

// Custom risk entry
bool   g_customRiskEditing = false;   // keyboard input mode active?
string g_customRiskText    = "";      // digits entered so far

// Order split
int    g_orderSplit         = 1;       // number of orders to split risk into
bool   g_splitEditing       = false;   // keyboard input mode for split
string g_splitText          = "";      // digits entered so far

bool   g_linesActive      = false;
bool   g_slManualOverride = false;   // true when user drags SL line manually
string g_entryLineName= "RM_Entry";
string g_tpLineName   = "RM_TP";
string g_slLineName   = "RM_SL";

double g_riskDollars  = 0;
int    g_orderDir     = 0;
int    g_orderType    = 0;
bool   g_isMarketOrder= false;

// SET SL / SET TP line state
bool   g_setSLActive   = false;
bool   g_setTPActive   = false;
string g_setSLLineName = "RM_SetSL_Line";
string g_setTPLineName = "RM_SetTP_Line";

// SMART TP state: 0=off, 1=today only, 2=all days
int    g_smartTPMode = 0;

// Hidden order state
bool   g_isHiddenLmt      = false;
bool   g_isHiddenStp      = false;
bool   g_isHiddenOrder    = false;
bool   g_hiddenOrderArmed = false;

// Toggle tracking
string g_lastOrderBtn = "";

// Auto-follow mode: market order lines track price in real-time
bool   g_autoOrderActive  = false;   // auto-follow enabled?
string g_autoOrderBtn     = "";      // which button activated auto ("RM_BuyMkt" etc.)

// CHOCH order state (auto-updating stop order)
bool   g_chochOrderActive  = false;  // is a CHOCH order armed?
int    g_chochOrderDir     = 0;      // +1 = buy CHOCH, -1 = sell CHOCH
int    g_chochLastBars     = 0;      // last M15 bar count for update check
int    g_chochMode         = 0;      // 0=SL-range, 1=swing SL, toggled per click
int    g_bosLmtMode        = 0;      // 0=67% retrace, 1=extreme candle, toggled per click

// Exit matrix
bool   g_exitMatrixActive = false;
string g_exitAboveName    = "RM_ExitAbove";
string g_exitBelowName    = "RM_ExitBelow";
string g_exitTimeName     = "RM_ExitTime";

// Partials matrix
bool   g_partialMatrixActive = false;
string g_partAboveName = "RM_PartAbove";
string g_partBelowName = "RM_PartBelow";
string g_partTimeName  = "RM_PartTime";

// Breakeven matrix
bool   g_beMtxActive    = false;
string g_beAboveName     = "RM_BeAbove";
string g_beBelowName     = "RM_BeBelow";
string g_beTimeName      = "RM_BeTime";

// Cancel orders matrix
bool   g_cnclMtxActive   = false;
string g_cnclAboveName   = "RM_CnclAbove";
string g_cnclBelowName   = "RM_CnclBelow";
string g_cnclTimeName    = "RM_CnclTime";

// Trailing SL (swing-based)
bool   g_trailH1Active     = false;  // visual line showing H1 swing trail level
bool   g_trailH4Active     = false;  // visual line showing H4 swing trail level
bool   g_hiddenTrailActive = false;  // hidden trailing (line only, closes on touch)
bool   g_autoTrailActive   = false;  // physically move SL to trail level
double g_trailH1Level      = 0;     // current H1 trail level
double g_trailH4Level      = 0;     // current H4 trail level
double g_hiddenTrailLevel  = 0;     // current hidden trail level
double g_trailH1Prev       = 0;     // previous swing level to detect changes
double g_trailH4Prev       = 0;     // previous swing level to detect changes

// Equity TP/SL
double g_eqTPPct = 0;   // display value; e.g. 2.0 means close at +2% from balance
double g_eqSLPct = 0;   // display value; e.g. 1.0 means close at -1% from balance
bool   g_eqTPActive = false;  // armed when user clicks the label
bool   g_eqSLActive = false;
double g_eqBaseline = 0; // account BALANCE snapshot when armed

// Chart tools (right panel)
bool   g_orActive         = false;
bool   g_sessHLActive     = false;
bool   g_dailyBoxActive   = false;
bool   g_weeklyBoxActive  = false;
bool     g_weeklyORActive   = false;
double   g_worHigh          = 0;
double   g_worLow           = 0;
datetime g_worStartTime     = 0;
datetime g_worWeekOpen      = 0;
int      g_worRectIdx       = 0;
bool     g_worHasRange      = false;
bool   g_dailyMtxActive   = false;
bool   g_weeklyMtxActive  = false;
bool   g_daily150Active   = false;
bool   g_sessGapActive    = true;
bool   g_sessBrkActive    = false;
bool   g_dailyLvlActive   = false;
int    g_dStkMode         = 0;   // 0=off, 1=all (3mo), 2=today only
bool   g_dmxLabelActive   = false;
bool   g_smxActive        = true;    // S.MTX swing matrix label on chart
bool   g_h4MtxActive     = true;    // H4.MTX swing matrix label on chart

// â”€â”€ H1 Thrust Test System â”€â”€
bool   g_tt_pivotActive   = false;
bool   g_tt_thrustActive  = false;
bool   g_tt_bosActive     = false;
bool   g_tt_chochActive   = false;
bool   g_tt_flowActive    = false;
int    g_tt_swingMode     = 0;   // 0=off, 1=lines, 2=dots
bool   g_tt_vsActive      = false;
int    g_tt_fvMode       = 0;   // 0=off, 1=subtle, 2=solid
int    g_tt_fvgMode      = 0;   // 0=off, 1=subtle, 2=solid
bool   g_tt_sretActive   = false; // S.RET swing retracement line
bool   g_tt_drangeActive = true;  // DRange projection (last swing H/L extended 6 candles + dealing-range %)

// ── Auto-recalculate state ──
// Armed orders re-run their recipe on (a) M15 bar change so new swing/BOS data
// gets picked up, and (b) every 3 seconds intra-bar so live-price-derived
// entries (D_MTX market/limit/stop, SWING, UFV, BS_BO, CH_BO, BOS retrace)
// track Ask/Bid. The 3-second throttle gives the user a window to grab and
// drag the lines without them snapping back on every tick.
int      g_armedOrderLastBars   = 0;
string   g_armedOrderTrackedBtn = "";
datetime g_armedOrderLastTime   = 0;   // server time of last rerun (3s throttle)
double g_tt_lastBosSwH   = 0;    // swing high at time of last BOS/CHOCH
double g_tt_lastBosSwL   = 0;    // swing low at time of last BOS/CHOCH
datetime g_tt_lastBosTime = 0;   // time of bar that triggered last BOS/CHOCH
datetime g_tt_lastBosSwHTime = 0; // time of the swing high at last BOS
datetime g_tt_lastBosSwLTime = 0; // time of the swing low at last BOS

int    g_tt_tFlow          = 1;     // 1=up, 2=down
int    g_tt_tTrend         = 1;     // 1=bullish, 2=bearish
double g_tt_swingHigh      = 0;
double g_tt_swingLow       = 0;
datetime g_tt_swingHighTime = 0;
datetime g_tt_swingLowTime  = 0;
double g_tt_highPH         = 0;     // latest pivot high price
double g_tt_lowPH          = 0;     // latest pivot low price
datetime g_tt_highTH       = 0;     // latest pivot high time
datetime g_tt_lowTH        = 0;     // latest pivot low time
bool   g_tt_check4UpBos    = false;
bool   g_tt_check4DnBos    = false;
int    g_tt_lastBars       = 0;
double g_tt_flowLevel      = 0;
double g_tt_vsLevel        = 0;
bool   g_tt_vsValid        = false;

// Bet-function state: separately track most-recent CHOCH and most-recent
// continuation BOS so functions can distinguish "latest mark is CHOCH" from
// "latest mark is BOS". See docs/BET-FUNCTIONS-spec.md.
datetime g_tt_lastChochTime    = 0;
double   g_tt_lastChochSwH     = 0;
double   g_tt_lastChochSwL     = 0;
datetime g_tt_lastChochSwHTime = 0;
datetime g_tt_lastChochSwLTime = 0;
bool     g_tt_lastChochIsHigh  = false;   // true = CHOCH-up (broke swing high)
datetime g_tt_lastContBosTime    = 0;
double   g_tt_lastContBosSwH     = 0;
double   g_tt_lastContBosSwL     = 0;
datetime g_tt_lastContBosSwHTime = 0;
datetime g_tt_lastContBosSwLTime = 0;
bool     g_tt_lastContBosIsHigh  = false; // true = up-BOS (broke swing high)

#define TT_LOOKBACK 6240   // ~3 months of M15 bars (13wk * 5d * 96 bars/day)
#define H4_LOOKBACK 1560   // ~3 months of H1 bars  (13wk * 5d * 24 bars/day)

// â"€â"€ H4 Thrust (runs on H1 bars, 4-bar window â†' captures H4 swings) â"€â"€
bool     g_h4_active       = true;
int      g_h4_tFlow        = 1;    // 1=up, 2=down
int      g_h4_tTrend       = 1;    // 1=bullish, 2=bearish
double   g_h4_swingHigh    = 0;
double   g_h4_swingLow     = 0;
datetime g_h4_swingHighTime = 0;
datetime g_h4_swingLowTime  = 0;
double   g_h4_highPH       = 0;
double   g_h4_lowPH        = 0;
datetime g_h4_highTH       = 0;
datetime g_h4_lowTH        = 0;
bool     g_h4_check4UpBos  = false;
bool     g_h4_check4DnBos  = false;
int      g_h4_lastBars     = 0;
int      g_h4_thrCount     = 0;
bool     g_h4_flowActive   = true;   // H4 flow line on chart
int      g_h4_prevFlow     = 0;     // previous flow direction for change detection
double   g_h4_flowLevel    = 0;     // H4 flow level (from H1 bars)
double   g_h4_lastBosSwH  = 0;    // H4 swing high at time of last BOS
double   g_h4_lastBosSwL  = 0;    // H4 swing low at time of last BOS

struct ThrustLine {
   datetime time;
   double   price;
   color    clr;
};
ThrustLine g_tt_thrLines[];
int        g_tt_thrCount = 0;
ThrustLine g_h4_thrLines[];

struct PivotMark {
   datetime time;
   double   price;
   bool     isHigh;
};
PivotMark g_tt_pivMarks[];
int       g_tt_pivCount = 0;

struct SwingDot {
   datetime time;
   double   swH;
   double   swL;
   color    clr;     // color of last thrust line (olive/green/maroon)
};
SwingDot  g_tt_swDots[];
int       g_tt_swDotCount = 0;

bool   g_tt_bosCountActive = false;

struct BOSLabel {
   datetime time;
   double   price;
   bool     isHigh;  // true = above swing high BOS, false = below swing low BOS
   int      count;
};
BOSLabel  g_tt_bosLabels[];
int       g_tt_bosLabelCount = 0;

// â”€â”€ Discord Alert System â”€â”€
bool     g_alertSBRK            = false;
double   g_alert_activeUpLow    = 0;     // up-close candle's low (support)
double   g_alert_activeDownHigh = 0;     // down-close candle's high (resistance)
bool     g_alert_upLowAlerted   = false;  // already alerted for this level
bool     g_alert_dnHighAlerted  = false;
bool     g_alertCHCH            = false;
bool     g_alert_chchAlerted    = false;  // already alerted for current swing pivot
datetime g_alert_chchTime       = 0;     // dedup on swing TIME (stable across ComputeThrust)

// D.STK zone alerts
bool     g_alertDSTK            = false;
bool     g_alert_dstkUpperAlerted = false;
bool     g_alert_dstkLowerAlerted = false;
int      g_alert_dstkDay        = -1;    // day-of-year to reset alerts each new day

// 150/-50 level alerts
bool     g_alertD150            = false;
bool     g_alert_d150UpperAlerted = false;
bool     g_alert_d150LowerAlerted = false;
int      g_alert_d150Day        = -1;

// H4 Flow Change alert
bool     g_alertH4FC            = true;   // ON by default
bool     g_alert_h4fcAlerted    = false;  // already alerted for current flow direction
int      g_alert_h4fcLastFlow   = 0;     // last flow direction we alerted on

// Close-Trend (ctrend) change alert — watches the 5-minute close-trend
bool     g_alertCTR            = true;    // ON by default
int      g_alert_ctrLastTrend  = 0;      // last cstrend we alerted on (0 = uninitialized)
#define  CTREND_MARK_DAYS  5             // how many days back to paint historical flip candles

// Dashboard visibility
bool   g_dashboardHidden  = false;

// Hover
string g_lastHovered  = "";
int    g_panelW       = 0;
int    g_mainPanelBottom = 0;

#define MAX_BTNS 100
string g_btnNames[];
int    g_btnX[];
int    g_btnY[];
int    g_btnW[];
int    g_btnH[];
int    g_btnCount = 0;

CTrade g_trade;

//+------------------------------------------------------------------+
//| Button name helpers                                              |
//+------------------------------------------------------------------+
string RiskBtnName(int i)  { return "RM_Risk_" + IntegerToString(i); }
string SlPctBtnName(int i) { return "RM_SlPct_" + IntegerToString(i); }
string RRBtnName(int i)    { return "RM_RR_" + IntegerToString(i); }

//+------------------------------------------------------------------+
//| Register a button for hover tracking                             |
//+------------------------------------------------------------------+
void RegisterBtn(string name, int x, int y, int w, int h)
{
   if(g_btnCount >= MAX_BTNS) return;
   int idx = g_btnCount;
   ArrayResize(g_btnNames, g_btnCount + 1);
   ArrayResize(g_btnX, g_btnCount + 1);
   ArrayResize(g_btnY, g_btnCount + 1);
   ArrayResize(g_btnW, g_btnCount + 1);
   ArrayResize(g_btnH, g_btnCount + 1);
   g_btnNames[idx] = name;
   g_btnX[idx] = x;
   g_btnY[idx] = y;
   g_btnW[idx] = w;
   g_btnH[idx] = h;
   g_btnCount++;
}

//+------------------------------------------------------------------+
//| Normal colour for a button                                       |
//+------------------------------------------------------------------+
color GetBtnNormalColor(string name)
{
   if(name == RiskBtnName(3)) return (g_riskIndex == 3) ? CLR_BTN_ON : CLR_BTN_OFF;
   for(int i = 0; i < 4; i++)
   {
      if(name == RiskBtnName(i))  return (i == g_riskIndex)  ? CLR_BTN_ON : CLR_BTN_OFF;
      if(name == SlPctBtnName(i)) return (i == g_slPctIndex) ? CLR_BTN_ON : CLR_BTN_OFF;
      if(name == RRBtnName(i))    return (i == g_rrIndex)    ? CLR_BTN_ON : CLR_BTN_OFF;
   }
   if(name == "RM_BuyMkt" || name == "RM_BuyLmt" || name == "RM_BuyStp" || name == "RM_BuyLmtDK") return CLR_BTN_BUY;
   if(name == "RM_SellMkt"|| name == "RM_SellLmt"|| name == "RM_SellStp" || name == "RM_SellLmtDK") return CLR_BTN_SELL;
   if(name == "RM_BuyMktSw")  return (g_tt_tTrend == 1) ? CLR_BTN_BUY  : CLR_BTN_PLC;
   if(name == "RM_SellMktSw") return (g_tt_tTrend == 2) ? CLR_BTN_SELL : CLR_BTN_PLC;
   if(name == "RM_BuyStpCH")  return (g_tt_tTrend == 2) ? CLR_BTN_BUY  : CLR_BTN_PLC;
   if(name == "RM_SellStpCH") return (g_tt_tTrend == 1) ? CLR_BTN_SELL : CLR_BTN_PLC;
   if(name == "RM_BuyLmtBOS")  return (g_tt_tTrend == 1) ? CLR_BTN_BUY  : CLR_BTN_PLC;
   if(name == "RM_SellLmtBOS") return (g_tt_tTrend == 2) ? CLR_BTN_SELL : CLR_BTN_PLC;
   if(name == "RM_BuyStpBK")   return (g_tt_tTrend == 1) ? CLR_BTN_BUY  : CLR_BTN_PLC;
   if(name == "RM_SellStpBK")  return (g_tt_tTrend == 2) ? CLR_BTN_SELL : CLR_BTN_PLC;
   if(name == "RM_BuyStpCB")   return (g_tt_tTrend == 2) ? CLR_BTN_BUY  : CLR_BTN_PLC;
   if(name == "RM_SellStpCB")  return (g_tt_tTrend == 1) ? CLR_BTN_SELL : CLR_BTN_PLC;
   if(name == "RM_BuyLmtChR")  return (g_tt_tTrend == 1) ? CLR_BTN_BUY  : CLR_BTN_PLC;
   if(name == "RM_SellLmtChR") return (g_tt_tTrend == 2) ? CLR_BTN_SELL : CLR_BTN_PLC;
   if(name == "RM_BuyLmtBoR")  return (g_tt_tTrend == 1) ? CLR_BTN_BUY  : CLR_BTN_PLC;
   if(name == "RM_SellLmtBoR") return (g_tt_tTrend == 2) ? CLR_BTN_SELL : CLR_BTN_PLC;
   if(name == "RM_BuyStpChC")  return (g_tt_tTrend == 1 && g_tt_tFlow == 2 && g_tt_check4UpBos) ? CLR_BTN_BUY  : CLR_BTN_PLC;
   if(name == "RM_SellStpChC") return (g_tt_tTrend == 2 && g_tt_tFlow == 1 && g_tt_check4DnBos) ? CLR_BTN_SELL : CLR_BTN_PLC;
   if(name == "RM_BuyMktUFV")  return (g_tt_tTrend == 2) ? CLR_BTN_BUY  : CLR_BTN_PLC;
   if(name == "RM_SellMktUFV") return (g_tt_tTrend == 1) ? CLR_BTN_SELL : CLR_BTN_PLC;
   if(name == "RM_HiddenLmt") return g_isHiddenLmt ? CLR_BTN_HIDDEN_ON : CLR_BTN_HIDDEN;
   if(name == "RM_HiddenStp") return g_isHiddenStp ? CLR_BTN_HIDDEN_ON : CLR_BTN_HIDDEN;
   if(name == "RM_Partial30" || name == "RM_Partial50" || name == "RM_Partial70") return CLR_BTN_WARN;
   if(name == "RM_CloseSym") return CLR_BTN_SELL;
   if(name == "RM_CloseAll") return CLR_BTN_SELL;
   if(name == "RM_ExitMatrix") return g_exitMatrixActive ? CLR_BTN_ON : CLR_BTN_EXIT;
   if(name == "RM_PartialsMatrix") return g_partialMatrixActive ? CLR_BTN_ON : CLR_BTN_TEAL;
   if(name == "RM_MoveBE") return CLR_BTN_TEAL;
   if(name == "RM_BeMtx") return g_beMtxActive ? CLR_BTN_ON : CLR_BTN_TEAL;
   if(name == "RM_CnclMtx") return g_cnclMtxActive ? CLR_BTN_ON : CLR_BTN_WARN;
   if(name == "RM_CancelAll") return CLR_BTN_WARN;
   if(name == "RM_BtnOR") return g_orActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnSHL") return g_sessHLActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnDBX") return g_dailyBoxActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnWBX") return g_weeklyBoxActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnWOR") return g_weeklyORActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnDMX") return g_dailyMtxActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnWMX") return g_weeklyMtxActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnD150") return g_daily150Active ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnSGAP") return g_sessGapActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnSBRK") return g_sessBrkActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnDLVL") return g_dailyLvlActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnDSTK") return (g_dStkMode > 0) ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnMLVL") return g_dmxLabelActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnSMX")  return g_smxActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnH4MX") return g_h4MtxActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnPIVT") return g_tt_pivotActive  ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnTHRS") return g_tt_thrustActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnBOS")  return g_tt_bosActive    ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnCHCH") return g_tt_chochActive  ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnFLOW") return g_tt_flowActive   ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnSWNG") return (g_tt_swingMode > 0) ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnVSTR") return g_tt_vsActive     ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnFVAL") return (g_tt_fvMode > 0)  ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnFVGP") return (g_tt_fvgMode > 0) ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnBOSC") return g_tt_bosCountActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnSRET") return g_tt_sretActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnDRNG") return g_tt_drangeActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnH4TH") return g_h4_active ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnH4FC") return g_h4_flowActive ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnAltSBRK") return g_alertSBRK ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnAltCHCH") return g_alertCHCH ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnAltDSTK") return g_alertDSTK ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnAltD150") return g_alertD150 ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnAltH4FC") return g_alertH4FC ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnAltCTR") return g_alertCTR ? CLR_BTN_ON : CLR_BTN_OFF;
   if(name == "RM_BtnTrailH1") return g_trailH1Active ? CLR_BTN_ON : CLR_BTN_TEAL;
   if(name == "RM_BtnTrailH4") return g_trailH4Active ? CLR_BTN_ON : CLR_BTN_TEAL;
   if(name == "RM_BtnHTrail") return g_hiddenTrailActive ? CLR_BTN_HIDDEN_ON : CLR_BTN_HIDDEN;
   if(name == "RM_BtnAutoTrail") return g_autoTrailActive ? CLR_BTN_ON : CLR_BTN_SELL;
   if(name == "RM_BtnAltTEST") return CLR_BTN_WARN;
   if(name == "RM_AddLot") return CLR_BTN_BUY;
   if(name == "RM_SetSL")  return g_setSLActive ? CLR_BTN_ON : CLR_BTN_SELL;
   if(name == "RM_SetTP")  return g_setTPActive ? CLR_BTN_ON : CLR_BTN_BUY;
   if(name == "RM_SmartTP") return (g_smartTPMode > 0) ? CLR_BTN_ON : CLR_BTN_BUY;
   if(name == "RM_EqTPP01" || name == "RM_EqTPP10")  return CLR_BTN_BUY;
   if(name == "RM_EqTPM01" || name == "RM_EqTPM10") return CLR_BTN_WARN;
   if(name == "RM_EqTPLbl")   return g_eqTPActive ? CLR_BTN_ON : (g_eqTPPct > 0) ? CLR_BTN_BUY : CLR_BTN_OFF;
   if(name == "RM_EqSLP01" || name == "RM_EqSLP10")  return CLR_BTN_SELL;
   if(name == "RM_EqSLM01" || name == "RM_EqSLM10") return CLR_BTN_WARN;
   if(name == "RM_EqSLLbl")   return g_eqSLActive ? CLR_BTN_ON : (g_eqSLPct > 0) ? CLR_BTN_SELL : CLR_BTN_OFF;
   if(name == "RM_BtnHide") return CLR_BTN_OFF;
   if(StringFind(name, "RM_Plc") == 0 || StringFind(name, "RM_RP_") == 0
      || StringFind(name, "RM_TP_") == 0 || StringFind(name, "RM_AP_") == 0) return CLR_BTN_PLC;
   return CLR_BTN_OFF;
}

//+------------------------------------------------------------------+
//| Hover colour for a button                                        |
//+------------------------------------------------------------------+
color GetBtnHoverColor(string name)
{
   if(name == RiskBtnName(3)) return (g_riskIndex == 3) ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   for(int i = 0; i < 4; i++)
   {
      if(name == RiskBtnName(i))  return (i == g_riskIndex)  ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
      if(name == SlPctBtnName(i)) return (i == g_slPctIndex) ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
      if(name == RRBtnName(i))    return (i == g_rrIndex)    ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   }
   if(name == "RM_BuyMkt" || name == "RM_BuyLmt" || name == "RM_BuyStp" || name == "RM_BuyLmtDK") return CLR_BTN_BUY_HOVER;
   if(name == "RM_SellMkt"|| name == "RM_SellLmt"|| name == "RM_SellStp" || name == "RM_SellLmtDK") return CLR_BTN_SELL_HOVER;
   if(name == "RM_BuyMktSw")  return (g_tt_tTrend == 1) ? CLR_BTN_BUY_HOVER  : CLR_BTN_PLC_HOVER;
   if(name == "RM_SellMktSw") return (g_tt_tTrend == 2) ? CLR_BTN_SELL_HOVER : CLR_BTN_PLC_HOVER;
   if(name == "RM_BuyStpCH")  return (g_tt_tTrend == 2) ? CLR_BTN_BUY_HOVER  : CLR_BTN_PLC_HOVER;
   if(name == "RM_SellStpCH") return (g_tt_tTrend == 1) ? CLR_BTN_SELL_HOVER : CLR_BTN_PLC_HOVER;
   if(name == "RM_BuyLmtBOS")  return (g_tt_tTrend == 1) ? CLR_BTN_BUY_HOVER  : CLR_BTN_PLC_HOVER;
   if(name == "RM_SellLmtBOS") return (g_tt_tTrend == 2) ? CLR_BTN_SELL_HOVER : CLR_BTN_PLC_HOVER;
   if(name == "RM_BuyStpBK")   return (g_tt_tTrend == 1) ? CLR_BTN_BUY_HOVER  : CLR_BTN_PLC_HOVER;
   if(name == "RM_SellStpBK")  return (g_tt_tTrend == 2) ? CLR_BTN_SELL_HOVER : CLR_BTN_PLC_HOVER;
   if(name == "RM_BuyStpCB")   return (g_tt_tTrend == 2) ? CLR_BTN_BUY_HOVER  : CLR_BTN_PLC_HOVER;
   if(name == "RM_SellStpCB")  return (g_tt_tTrend == 1) ? CLR_BTN_SELL_HOVER : CLR_BTN_PLC_HOVER;
   if(name == "RM_BuyLmtChR")  return (g_tt_tTrend == 1) ? CLR_BTN_BUY_HOVER  : CLR_BTN_PLC_HOVER;
   if(name == "RM_SellLmtChR") return (g_tt_tTrend == 2) ? CLR_BTN_SELL_HOVER : CLR_BTN_PLC_HOVER;
   if(name == "RM_BuyLmtBoR")  return (g_tt_tTrend == 1) ? CLR_BTN_BUY_HOVER  : CLR_BTN_PLC_HOVER;
   if(name == "RM_SellLmtBoR") return (g_tt_tTrend == 2) ? CLR_BTN_SELL_HOVER : CLR_BTN_PLC_HOVER;
   if(name == "RM_BuyStpChC")  return (g_tt_tTrend == 1 && g_tt_tFlow == 2 && g_tt_check4UpBos) ? CLR_BTN_BUY_HOVER  : CLR_BTN_PLC_HOVER;
   if(name == "RM_SellStpChC") return (g_tt_tTrend == 2 && g_tt_tFlow == 1 && g_tt_check4DnBos) ? CLR_BTN_SELL_HOVER : CLR_BTN_PLC_HOVER;
   if(name == "RM_BuyMktUFV")  return (g_tt_tTrend == 2) ? CLR_BTN_BUY_HOVER  : CLR_BTN_PLC_HOVER;
   if(name == "RM_SellMktUFV") return (g_tt_tTrend == 1) ? CLR_BTN_SELL_HOVER : CLR_BTN_PLC_HOVER;
   if(name == "RM_HiddenLmt") return g_isHiddenLmt ? CLR_BTN_HIDDEN_ON_HV : CLR_BTN_HIDDEN_HOVER;
   if(name == "RM_HiddenStp") return g_isHiddenStp ? CLR_BTN_HIDDEN_ON_HV : CLR_BTN_HIDDEN_HOVER;
   if(name == "RM_Partial30" || name == "RM_Partial50" || name == "RM_Partial70") return CLR_BTN_WARN_HOVER;
   if(name == "RM_CloseSym") return CLR_BTN_SELL_HOVER;
   if(name == "RM_CloseAll") return CLR_BTN_SELL_HOVER;
   if(name == "RM_ExitMatrix") return g_exitMatrixActive ? CLR_BTN_ON_HOVER : CLR_BTN_EXIT_HOVER;
   if(name == "RM_PartialsMatrix") return g_partialMatrixActive ? CLR_BTN_ON_HOVER : CLR_BTN_TEAL_HOVER;
   if(name == "RM_MoveBE") return CLR_BTN_TEAL_HOVER;
   if(name == "RM_BeMtx") return g_beMtxActive ? CLR_BTN_ON_HOVER : CLR_BTN_TEAL_HOVER;
   if(name == "RM_CnclMtx") return g_cnclMtxActive ? CLR_BTN_ON_HOVER : CLR_BTN_WARN_HOVER;
   if(name == "RM_CancelAll") return CLR_BTN_WARN_HOVER;
   if(name == "RM_BtnOR") return g_orActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnSHL") return g_sessHLActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnDBX") return g_dailyBoxActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnWBX") return g_weeklyBoxActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnWOR") return g_weeklyORActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnDMX") return g_dailyMtxActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnWMX") return g_weeklyMtxActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnD150") return g_daily150Active ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnSGAP") return g_sessGapActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnSBRK") return g_sessBrkActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnDLVL") return g_dailyLvlActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnDSTK") return (g_dStkMode > 0) ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnMLVL") return g_dmxLabelActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnSMX")  return g_smxActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnH4MX") return g_h4MtxActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnPIVT") return g_tt_pivotActive  ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnTHRS") return g_tt_thrustActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnBOS")  return g_tt_bosActive    ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnCHCH") return g_tt_chochActive  ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnFLOW") return g_tt_flowActive   ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnSWNG") return (g_tt_swingMode > 0) ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnVSTR") return g_tt_vsActive     ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnFVAL") return (g_tt_fvMode > 0)  ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnFVGP") return (g_tt_fvgMode > 0) ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnBOSC") return g_tt_bosCountActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnSRET") return g_tt_sretActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnDRNG") return g_tt_drangeActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnH4TH") return g_h4_active ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnH4FC") return g_h4_flowActive ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnAltSBRK") return g_alertSBRK ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnAltCHCH") return g_alertCHCH ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnAltDSTK") return g_alertDSTK ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnAltD150") return g_alertD150 ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnAltH4FC") return g_alertH4FC ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnAltCTR") return g_alertCTR ? CLR_BTN_ON_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnTrailH1") return g_trailH1Active ? CLR_BTN_ON_HOVER : CLR_BTN_TEAL_HOVER;
   if(name == "RM_BtnTrailH4") return g_trailH4Active ? CLR_BTN_ON_HOVER : CLR_BTN_TEAL_HOVER;
   if(name == "RM_BtnHTrail") return g_hiddenTrailActive ? CLR_BTN_HIDDEN_ON_HV : CLR_BTN_HIDDEN_HOVER;
   if(name == "RM_BtnAutoTrail") return g_autoTrailActive ? CLR_BTN_ON_HOVER : CLR_BTN_SELL_HOVER;
   if(name == "RM_BtnAltTEST") return CLR_BTN_WARN_HOVER;
   if(name == "RM_AddLot") return CLR_BTN_BUY_HOVER;
   if(name == "RM_SetSL")  return CLR_BTN_SELL_HOVER;
   if(name == "RM_SetTP")  return CLR_BTN_BUY_HOVER;
   if(name == "RM_SmartTP") return (g_smartTPMode > 0) ? CLR_BTN_ON_HOVER : CLR_BTN_BUY_HOVER;
   if(name == "RM_EqTPP01" || name == "RM_EqTPP10")  return CLR_BTN_BUY_HOVER;
   if(name == "RM_EqTPM01" || name == "RM_EqTPM10") return CLR_BTN_WARN_HOVER;
   if(name == "RM_EqTPLbl")   return g_eqTPActive ? CLR_BTN_ON_HOVER : (g_eqTPPct > 0) ? CLR_BTN_BUY_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_EqSLP01" || name == "RM_EqSLP10")  return CLR_BTN_SELL_HOVER;
   if(name == "RM_EqSLM01" || name == "RM_EqSLM10") return CLR_BTN_WARN_HOVER;
   if(name == "RM_EqSLLbl")   return g_eqSLActive ? CLR_BTN_ON_HOVER : (g_eqSLPct > 0) ? CLR_BTN_SELL_HOVER : CLR_BTN_OFF_HOVER;
   if(name == "RM_BtnHide") return CLR_BTN_OFF_HOVER;
   if(StringFind(name, "RM_Plc") == 0 || StringFind(name, "RM_RP_") == 0
      || StringFind(name, "RM_TP_") == 0 || StringFind(name, "RM_AP_") == 0) return CLR_BTN_PLC_HOVER;
   return CLR_BTN_OFF_HOVER;
}

//+------------------------------------------------------------------+
//| Create a button                                                  |
//+------------------------------------------------------------------+
void CreateButton(string name, int x, int y, int w, int h,
                  string text, color bgClr, color txtClr, int fontSize = 12)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI Semibold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, txtClr);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgClr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, CLR_BORDER);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 100);
   RegisterBtn(name, x, y, w, h);
}

//+------------------------------------------------------------------+
//| Create a label                                                   |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize = 10)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 100);
}

//+------------------------------------------------------------------+
//| Create a background rectangle                                    |
//+------------------------------------------------------------------+
void CreateBgRect(string name, int x, int y, int w, int h, color clr, color borderClr = CLR_BORDER)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, borderClr);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 100);
}

//+------------------------------------------------------------------+
//| Highlight selected button in a toggle group                      |
//+------------------------------------------------------------------+
void SetToggleGroup(string prefix, int count, int selected, color onClr, color offClr)
{
   for(int i = 0; i < count; i++)
   {
      string name = prefix + IntegerToString(i);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, (i == selected) ? onClr : offClr);
      ObjectSetInteger(0, name, OBJPROP_STATE, false);
   }
}

//+------------------------------------------------------------------+
//| Build the entire dashboard                                       |
//+------------------------------------------------------------------+
void BuildDashboard()
{
   g_btnCount = 0;

   int x   = PANEL_X;
   int y   = PANEL_Y;
   int pad = 14;
   int innerW    = 3 * BTN_W + 2 * BTN_GAP;   // 556
   int panelW    = innerW + 2 * pad;            // 584
   g_panelW = panelW;

   int sectionH    = LABEL_H + BTN_H;
   int orderSecH   = LABEL_H + 2 * BTN_H + BTN_GAP;
   int infoBarH    = 102;

   int panelH = pad + sectionH + SECTION_GAP                  // Risk
              + orderSecH + ROW_GAP                            // Market
              + orderSecH + ROW_GAP                            // Limit
              + orderSecH + SECTION_GAP                        // Stop
              + sectionH + SECTION_GAP                         // SL Range
              + sectionH + SECTION_GAP                         // R:R
              + infoBarH + pad + 4;

   int cx = x + pad;

   // â”€â”€ Gold outer frame â”€â”€
   CreateBgRect("RM_Frame", x - 3, y - 3, panelW + 6, panelH + 6, CLR_BORDER_GOLD, CLR_BORDER_GOLD);
   CreateBgRect("RM_BG", x, y, panelW, panelH, CLR_PANEL_BG, CLR_PANEL_BG);

   // â”€â”€ Hide/Show toggle button (always visible, sits above panel) â”€â”€
   CreateButton("RM_BtnHide", x - 3, y - 3 - 30, 36, 26, "\\x25C0",
                CLR_BTN_OFF, CLR_TEXT, 10);
   ObjectSetString(0, "RM_BtnHide", OBJPROP_TOOLTIP, "Toggle dashboard visibility (X key)");

   int cy = y + pad;

   // â•â•â•â•â•â•â•â•â•â•â• RISK AMOUNT â•â•â•â•â•â•â•â•â•â•â•
   CreateBgRect("RM_SecRisk", x + 4, cy - 3, panelW - 8, sectionH + 6, CLR_SECTION_BG, CLR_SECTION_BG);
   CreateLabel("RM_LblRisk", cx + 2, cy + 2, "RISK AMOUNT", CLR_TEXT_DIM, FONT_SIZE_LBL);
   cy += LABEL_H;
   int riskBtnW = (innerW - 4 * BTN_GAP) / 5;
   string riskLabels[] = {"$500", "$1,000", "$1,500"};
   for(int i = 0; i < 3; i++)
      CreateButton(RiskBtnName(i), cx + i * (riskBtnW + BTN_GAP), cy, riskBtnW, BTN_H,
                   riskLabels[i], CLR_BTN_OFF, CLR_TEXT);
   // 4th button: custom risk entry
   string customTxt = (g_riskIndex == 3 && g_riskValues[3] > 0)
                      ? ("$" + IntegerToString((int)g_riskValues[3]))
                      : "CUSTOM";
   CreateButton(RiskBtnName(3), cx + 3 * (riskBtnW + BTN_GAP), cy, riskBtnW, BTN_H,
                customTxt, CLR_BTN_OFF, CLR_TEXT);
   // 5th button: order split
   string splitTxt = (g_orderSplit > 1) ? ("x" + IntegerToString(g_orderSplit)) : "SPLIT";
   CreateButton("RM_BtnSplit", cx + 4 * (riskBtnW + BTN_GAP), cy, riskBtnW, BTN_H,
                splitTxt, (g_orderSplit > 1) ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT);
   SetToggleGroup("RM_Risk_", 4, g_riskIndex, CLR_BTN_ON, CLR_BTN_OFF);
   ObjectSetString(0, RiskBtnName(0), OBJPROP_TOOLTIP, "Risk $500 per trade");
   ObjectSetString(0, RiskBtnName(1), OBJPROP_TOOLTIP, "Risk $1,000 per trade");
   ObjectSetString(0, RiskBtnName(2), OBJPROP_TOOLTIP, "Risk $1,500 per trade");
   ObjectSetString(0, RiskBtnName(3), OBJPROP_TOOLTIP, "Click to enter custom risk amount\nType 0-9 to enter digits, Backspace to delete\nClick again to confirm");
   ObjectSetString(0, "RM_BtnSplit", OBJPROP_TOOLTIP, "Order split: divide risk into N equal orders\nClick to enter split count (1-9)");
   cy += BTN_H + SECTION_GAP;

   // â•â•â•â•â•â•â•â•â•â•â• ORDER SECTION (6-column layout) â•â•â•â•â•â•â•â•â•â•â•
   int sixthW = (innerW - 5 * BTN_GAP) / 6;

   // â”€â”€ MARKET ORDER â”€â”€
   CreateLabel("RM_LblMkt", cx + 2, cy + 2, "MARKET ORDER", CLR_TEXT_DIM, FONT_SIZE_LBL);
   cy += LABEL_H;
   // Row 1 â€“ sell
   CreateButton("RM_SellMkt",   cx,                        cy, sixthW, BTN_H, "-D_MTX", CLR_BTN_SELL, CLR_TEXT, 12);
   ObjectSetString(0, "RM_SellMkt", OBJPROP_TOOLTIP, "SELL MARKET (SL Range)\nMarket sell using SL Range % of prev daily range");
   CreateButton("RM_SellMktSw", cx + (sixthW + BTN_GAP),   cy, sixthW, BTN_H, "-SWING",
                (g_tt_tTrend == 2) ? CLR_BTN_SELL : CLR_BTN_PLC,
                (g_tt_tTrend == 2) ? CLR_TEXT : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_SellMktSw", OBJPROP_TOOLTIP, "SELL MARKET (Swing)\nMarket sell with SL at swing high\nOnly active in bearish trend");
   CreateButton("RM_SellMktUFV", cx + 2*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "-UFV",
                (g_tt_tTrend == 1) ? CLR_BTN_SELL : CLR_BTN_PLC,
                (g_tt_tTrend == 1) ? CLR_TEXT    : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_SellMktUFV", OBJPROP_TOOLTIP,
      "SELL MARKET (UFV Reversion)\n"
      "Fires only when bid > last swing high in an uptrend.\n"
      "Entry = tick price, SL = swing high + FV range,\n"
      "TP from R:R preset.");
   CreateButton("RM_PlcMkt2",   cx + 3*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "\x2014", CLR_BTN_PLC, CLR_TEXT_DIM);
   CreateButton("RM_PlcMkt3",   cx + 4*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "\x2014", CLR_BTN_PLC, CLR_TEXT_DIM);
   CreateButton("RM_PlcMkt4",   cx + 5*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "\x2014", CLR_BTN_PLC, CLR_TEXT_DIM);
   cy += BTN_H + BTN_GAP;
   // Row 2 â€“ buy
   CreateButton("RM_BuyMkt",    cx,                        cy, sixthW, BTN_H, "+D_MTX", CLR_BTN_BUY, CLR_TEXT, 12);
   ObjectSetString(0, "RM_BuyMkt", OBJPROP_TOOLTIP, "BUY MARKET (SL Range)\nMarket buy using SL Range % of prev daily range");
   CreateButton("RM_BuyMktSw",  cx + (sixthW + BTN_GAP),   cy, sixthW, BTN_H, "+SWING",
                (g_tt_tTrend == 1) ? CLR_BTN_BUY : CLR_BTN_PLC,
                (g_tt_tTrend == 1) ? CLR_TEXT : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_BuyMktSw", OBJPROP_TOOLTIP, "BUY MARKET (Swing)\nMarket buy with SL at swing low\nOnly active in bullish trend");
   CreateButton("RM_BuyMktUFV", cx + 2*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "+UFV",
                (g_tt_tTrend == 2) ? CLR_BTN_BUY : CLR_BTN_PLC,
                (g_tt_tTrend == 2) ? CLR_TEXT   : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_BuyMktUFV", OBJPROP_TOOLTIP,
      "BUY MARKET (UFV Reversion)\n"
      "Fires only when ask < last swing low in a downtrend.\n"
      "Entry = tick price, SL = swing low - FV range,\n"
      "TP from R:R preset.");
   CreateButton("RM_PlcMkt6",   cx + 3*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "\x2014", CLR_BTN_PLC, CLR_TEXT_DIM);
   CreateButton("RM_PlcMkt7",   cx + 4*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "\x2014", CLR_BTN_PLC, CLR_TEXT_DIM);
   CreateButton("RM_PlcMkt8",   cx + 5*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "\x2014", CLR_BTN_PLC, CLR_TEXT_DIM);
   cy += BTN_H + ROW_GAP;

   // â”€â”€ LIMIT ORDER (H button next to label) â”€â”€
   int hBtnW = 28;
   CreateLabel("RM_LblLmt", cx + 2, cy + 2, "LIMIT ORDER", CLR_TEXT_DIM, FONT_SIZE_LBL);
   CreateButton("RM_HiddenLmt", cx + 82, cy, hBtnW, LABEL_H, "H",
                g_isHiddenLmt ? CLR_BTN_HIDDEN_ON : CLR_BTN_HIDDEN,
                g_isHiddenLmt ? clrBlack : CLR_TEXT, 10);
   ObjectSetString(0, "RM_HiddenLmt", OBJPROP_TOOLTIP,
      "HIDDEN LIMIT ORDER\nArms a hidden limit order that\nexecutes via market when price reaches entry.");
   cy += LABEL_H;
   // Row 1 â€“ sell
   CreateButton("RM_SellLmt",   cx,                        cy, sixthW, BTN_H, "-D_MTX", CLR_BTN_SELL, CLR_TEXT, 12);
   ObjectSetString(0, "RM_SellLmt", OBJPROP_TOOLTIP, "SELL LIMIT (SL Range)\nPlaces entry/SL/TP lines for a sell limit\nusing SL Range % of prev daily range");
   CreateButton("RM_SellLmtDK", cx + (sixthW + BTN_GAP),   cy, sixthW, BTN_H, "-D_STK", CLR_BTN_SELL, CLR_TEXT, 12);
   ObjectSetString(0, "RM_SellLmtDK", OBJPROP_TOOLTIP, "SELL LIMIT (D.STK)\nSell limit at D.STK matrix level\nBear prev: entry 67, SL 100, TP 0\nBull prev: entry 100, SL 150, TP 33");
   CreateButton("RM_PlcLmt2S", cx + 2*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "\x2014", CLR_BTN_PLC, CLR_TEXT_DIM);
   CreateButton("RM_SellLmtBOS", cx + 3*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "-BOS",
                (g_tt_tTrend == 2) ? CLR_BTN_SELL : CLR_BTN_PLC,
                (g_tt_tTrend == 2) ? CLR_TEXT : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_SellLmtBOS", OBJPROP_TOOLTIP,
      "SELL LIMIT (BOS Retracement)\n"
      "Entry at S.RT 67% retracement level.\n"
      "SL = BOS swing high.\n"
      "TP = lowest low since BOS (2:1 R:R).\n"
      "Active only in bearish trend.");
   CreateButton("RM_SellLmtChR", cx + 4*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "-CH_R",
                (g_tt_tTrend == 2) ? CLR_BTN_SELL : CLR_BTN_PLC,
                (g_tt_tTrend == 2) ? CLR_TEXT    : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_SellLmtChR", OBJPROP_TOOLTIP,
      "SELL LIMIT (CHOCH Retrace)\n"
      "Latest THRS mark must be CHOCH-down (no later BOS).\n"
      "Entry = top of highest unfilled bearish wick FVG\n"
      "below last swing high (deepest retrace).\n"
      "SL = swing high, TP from R:R preset.");
   CreateButton("RM_SellLmtBoR", cx + 5*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "-BS_R",
                (g_tt_tTrend == 2) ? CLR_BTN_SELL : CLR_BTN_PLC,
                (g_tt_tTrend == 2) ? CLR_TEXT    : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_SellLmtBoR", OBJPROP_TOOLTIP,
      "SELL LIMIT (BOS Retrace, wick-FVG)\n"
      "Requires a continuation BOS-down since last CHOCH.\n"
      "Entry = top of highest unfilled bearish wick FVG\n"
      "since that BOS. SL = swing high, TP from R:R.");
   cy += BTN_H + BTN_GAP;
   // Row 2 â€“ buy
   CreateButton("RM_BuyLmt",    cx,                        cy, sixthW, BTN_H, "+D_MTX", CLR_BTN_BUY, CLR_TEXT, 12);
   ObjectSetString(0, "RM_BuyLmt", OBJPROP_TOOLTIP, "BUY LIMIT (SL Range)\nPlaces entry/SL/TP lines for a buy limit\nusing SL Range % of prev daily range");
   CreateButton("RM_BuyLmtDK",  cx + (sixthW + BTN_GAP),   cy, sixthW, BTN_H, "+D_STK", CLR_BTN_BUY, CLR_TEXT, 12);
   ObjectSetString(0, "RM_BuyLmtDK", OBJPROP_TOOLTIP, "BUY LIMIT (D.STK)\nBuy limit at D.STK matrix level\nBull prev: entry 33, SL 0, TP 100\nBear prev: entry 0, SL -50, TP 67");
   CreateButton("RM_PlcLmt2B", cx + 2*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "\x2014", CLR_BTN_PLC, CLR_TEXT_DIM);
   CreateButton("RM_BuyLmtBOS",  cx + 3*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "+BOS",
                (g_tt_tTrend == 1) ? CLR_BTN_BUY : CLR_BTN_PLC,
                (g_tt_tTrend == 1) ? CLR_TEXT : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_BuyLmtBOS", OBJPROP_TOOLTIP,
      "BUY LIMIT (BOS Retracement)\n"
      "Entry at S.RT 67% retracement level.\n"
      "SL = BOS swing low.\n"
      "TP = highest high since BOS (2:1 R:R).\n"
      "Active only in bullish trend.");
   CreateButton("RM_BuyLmtChR",  cx + 4*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "+CH_R",
                (g_tt_tTrend == 1) ? CLR_BTN_BUY : CLR_BTN_PLC,
                (g_tt_tTrend == 1) ? CLR_TEXT   : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_BuyLmtChR", OBJPROP_TOOLTIP,
      "BUY LIMIT (CHOCH Retrace)\n"
      "Latest THRS mark must be CHOCH-up (no later BOS).\n"
      "Entry = bottom of lowest unfilled bullish wick FVG\n"
      "above last swing low (deepest retrace).\n"
      "SL = swing low, TP from R:R preset.");
   CreateButton("RM_BuyLmtBoR",  cx + 5*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "+BS_R",
                (g_tt_tTrend == 1) ? CLR_BTN_BUY : CLR_BTN_PLC,
                (g_tt_tTrend == 1) ? CLR_TEXT   : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_BuyLmtBoR", OBJPROP_TOOLTIP,
      "BUY LIMIT (BOS Retrace, wick-FVG)\n"
      "Requires a continuation BOS-up since last CHOCH.\n"
      "Entry = bottom of lowest unfilled bullish wick FVG\n"
      "since that BOS. SL = swing low, TP from R:R.");
   cy += BTN_H + ROW_GAP;

   // â”€â”€ STOP ORDER (H button next to label) â”€â”€
   CreateLabel("RM_LblStp", cx + 2, cy + 2, "STOP ORDER", CLR_TEXT_DIM, FONT_SIZE_LBL);
   CreateButton("RM_HiddenStp", cx + 82, cy, hBtnW, LABEL_H, "H",
                g_isHiddenStp ? CLR_BTN_HIDDEN_ON : CLR_BTN_HIDDEN,
                g_isHiddenStp ? clrBlack : CLR_TEXT, 10);
   ObjectSetString(0, "RM_HiddenStp", OBJPROP_TOOLTIP,
      "HIDDEN STOP ORDER\nArms a hidden stop order that\nexecutes via market when price reaches entry.");
   cy += LABEL_H;
   int chochBtnX = cx + (sixthW + BTN_GAP);
   int chochRow1Y = cy;
   // Row 1 â€“ buy
   CreateButton("RM_BuyStp",    cx,                        cy, sixthW, BTN_H, "+D_MTX", CLR_BTN_BUY, CLR_TEXT, 12);
   ObjectSetString(0, "RM_BuyStp", OBJPROP_TOOLTIP, "BUY STOP (SL Range)\nPlaces entry/SL/TP lines for a buy stop\nusing SL Range % of prev daily range");
   CreateButton("RM_BuyStpCH",  cx + (sixthW + BTN_GAP),   cy, sixthW, BTN_H, "+CHOCH",
                (g_tt_tTrend == 2) ? CLR_BTN_BUY : CLR_BTN_PLC,
                (g_tt_tTrend == 2) ? CLR_TEXT : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_BuyStpCH", OBJPROP_TOOLTIP, "BUY STOP (CHOCH) [Auto-Update]\nBuy stop at swing high in downtrend\nSL = lowest low from swing to now\nEntry & SL auto-update every M15 bar");
   // Auto-update badge
   CreateBgRect("RM_ABadge1", chochBtnX + sixthW - 12, chochRow1Y, 12, 12, C'45,47,62', C'45,47,62');
   CreateLabel("RM_ABadge1L", chochBtnX + sixthW - 10, chochRow1Y - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_ABadge1", OBJPROP_TOOLTIP, "Auto: Entry & SL update per M15 candle");
   ObjectSetString(0, "RM_ABadge1L", OBJPROP_TOOLTIP, "Auto: Entry & SL update per M15 candle");
   CreateButton("RM_BuyStpChC", cx + 2*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "+CH_C",
                (g_tt_tTrend == 1 && g_tt_tFlow == 2 && g_tt_check4UpBos) ? CLR_BTN_BUY : CLR_BTN_PLC,
                (g_tt_tTrend == 1 && g_tt_tFlow == 2 && g_tt_check4UpBos) ? CLR_TEXT   : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_BuyStpChC", OBJPROP_TOOLTIP,
      "BUY STOP (CHOCH Continuation)\n"
      "After CHOCH-up, wait for a counter-flow (new swing low),\n"
      "then place buy stop at the next swing high that would\n"
      "resume the trend. SL = current swing low.\n"
      "Active when trend bullish, flow down, Up-BOS armed.");
   CreateButton("RM_BuyStpBK",  cx + 3*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "+BS_BO",
                (g_tt_tTrend == 1) ? CLR_BTN_BUY : CLR_BTN_PLC,
                (g_tt_tTrend == 1) ? CLR_TEXT : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_BuyStpBK", OBJPROP_TOOLTIP,
      "BUY STOP (BS_BO Breakout — with-trend continuation)\n"
      "Entry at highest high since last BOS swing high.\n"
      "SL = BOS swing low.\n"
      "TP from R:R preset.\n"
      "Active only in BULLISH trend.");
   CreateButton("RM_BuyStpCB",  cx + 4*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "+CH_BO",
                (g_tt_tTrend == 2) ? CLR_BTN_BUY : CLR_BTN_PLC,
                (g_tt_tTrend == 2) ? CLR_TEXT : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_BuyStpCB", OBJPROP_TOOLTIP,
      "BUY STOP (CH_BO Breakout — anti-trend reversal)\n"
      "Entry at highest high since last BOS swing high.\n"
      "SL = BOS swing low.\n"
      "TP from R:R preset.\n"
      "Active only in BEARISH trend (entry into CHOCH-up break).");
   CreateButton("RM_PlcStp4",   cx + 5*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "\x2014", CLR_BTN_PLC, CLR_TEXT_DIM);
   cy += BTN_H + BTN_GAP;
   int chochRow2Y = cy;
   // Row 2 â€“ sell
   CreateButton("RM_SellStp",   cx,                        cy, sixthW, BTN_H, "-D_MTX", CLR_BTN_SELL, CLR_TEXT, 12);
   ObjectSetString(0, "RM_SellStp", OBJPROP_TOOLTIP, "SELL STOP (SL Range)\nPlaces entry/SL/TP lines for a sell stop\nusing SL Range % of prev daily range");
   CreateButton("RM_SellStpCH", cx + (sixthW + BTN_GAP),   cy, sixthW, BTN_H, "-CHOCH",
                (g_tt_tTrend == 1) ? CLR_BTN_SELL : CLR_BTN_PLC,
                (g_tt_tTrend == 1) ? CLR_TEXT : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_SellStpCH", OBJPROP_TOOLTIP, "SELL STOP (CHOCH) [Auto-Update]\nSell stop at swing low in uptrend\nSL = highest high from swing to now\nEntry & SL auto-update every M15 bar");
   // Auto-update badge
   CreateBgRect("RM_ABadge2", chochBtnX + sixthW - 12, chochRow2Y, 12, 12, C'45,47,62', C'45,47,62');
   CreateLabel("RM_ABadge2L", chochBtnX + sixthW - 10, chochRow2Y - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_ABadge2", OBJPROP_TOOLTIP, "Auto: Entry & SL update per M15 candle");
   ObjectSetString(0, "RM_ABadge2L", OBJPROP_TOOLTIP, "Auto: Entry & SL update per M15 candle");
   CreateButton("RM_SellStpChC", cx + 2*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "-CH_C",
                (g_tt_tTrend == 2 && g_tt_tFlow == 1 && g_tt_check4DnBos) ? CLR_BTN_SELL : CLR_BTN_PLC,
                (g_tt_tTrend == 2 && g_tt_tFlow == 1 && g_tt_check4DnBos) ? CLR_TEXT    : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_SellStpChC", OBJPROP_TOOLTIP,
      "SELL STOP (CHOCH Continuation)\n"
      "After CHOCH-down, wait for a counter-flow (new swing high),\n"
      "then place sell stop at the next swing low that would\n"
      "resume the trend. SL = current swing high.\n"
      "Active when trend bearish, flow up, Dn-BOS armed.");
   CreateButton("RM_SellStpBK", cx + 3*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "-BS_BO",
                (g_tt_tTrend == 2) ? CLR_BTN_SELL : CLR_BTN_PLC,
                (g_tt_tTrend == 2) ? CLR_TEXT : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_SellStpBK", OBJPROP_TOOLTIP,
      "SELL STOP (BS_BO Breakout — with-trend continuation)\n"
      "Entry at lowest low since last BOS swing low.\n"
      "SL = BOS swing high.\n"
      "TP from R:R preset.\n"
      "Active only in BEARISH trend.");
   CreateButton("RM_SellStpCB", cx + 4*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "-CH_BO",
                (g_tt_tTrend == 1) ? CLR_BTN_SELL : CLR_BTN_PLC,
                (g_tt_tTrend == 1) ? CLR_TEXT : CLR_TEXT_DIM, 12);
   ObjectSetString(0, "RM_SellStpCB", OBJPROP_TOOLTIP,
      "SELL STOP (CH_BO Breakout — anti-trend reversal)\n"
      "Entry at lowest low since last BOS swing low.\n"
      "SL = BOS swing high.\n"
      "TP from R:R preset.\n"
      "Active only in BULLISH trend (entry into CHOCH-down break).");
   CreateButton("RM_PlcStp8",   cx + 5*(sixthW + BTN_GAP), cy, sixthW, BTN_H, "\x2014", CLR_BTN_PLC, CLR_TEXT_DIM);
   cy += BTN_H + SECTION_GAP;

   // â”€â”€ Gold divider â”€â”€
   CreateBgRect("RM_Div1", x + 12, cy - SECTION_GAP / 2 + 1, panelW - 24, 2, CLR_BORDER_GOLD, CLR_BORDER_GOLD);

   // â•â•â•â•â•â•â•â•â•â•â• SL RANGE â•â•â•â•â•â•â•â•â•â•â•
   CreateBgRect("RM_SecSL", x + 4, cy - 3, panelW - 8, sectionH + 6, CLR_SECTION_BG, CLR_SECTION_BG);
   CreateLabel("RM_LblSL", cx + 2, cy + 2, "SL RANGE  (% Prev Daily Range)", CLR_TEXT_DIM, FONT_SIZE_LBL);
   cy += LABEL_H;
   int slBtnW = (innerW - 3 * BTN_GAP) / 4;
   string slLabels[] = {"25 %", "33 %", "50 %", "100 %"};
   for(int i = 0; i < 4; i++)
      CreateButton(SlPctBtnName(i), cx + i * (slBtnW + BTN_GAP), cy, slBtnW, BTN_H,
                   slLabels[i], CLR_BTN_OFF, CLR_TEXT);
   SetToggleGroup("RM_SlPct_", 4, g_slPctIndex, CLR_BTN_ON, CLR_BTN_OFF);
   ObjectSetString(0, SlPctBtnName(0), OBJPROP_TOOLTIP, "SL = 25% of prev daily range");
   ObjectSetString(0, SlPctBtnName(1), OBJPROP_TOOLTIP, "SL = 33% of prev daily range");
   ObjectSetString(0, SlPctBtnName(2), OBJPROP_TOOLTIP, "SL = 50% of prev daily range");
   ObjectSetString(0, SlPctBtnName(3), OBJPROP_TOOLTIP, "SL = 100% of prev daily range");
   cy += BTN_H + SECTION_GAP;

   // â•â•â•â•â•â•â•â•â•â•â• REWARD : RISK â•â•â•â•â•â•â•â•â•â•â•
   CreateBgRect("RM_SecRR", x + 4, cy - 3, panelW - 8, sectionH + 6, CLR_SECTION_BG, CLR_SECTION_BG);
   CreateLabel("RM_LblRR", cx + 2, cy + 2, "REWARD : RISK", CLR_TEXT_DIM, FONT_SIZE_LBL);
   cy += LABEL_H;
   string rrLabels[] = {"1 : 1", "2 : 1", "3 : 1"};
   for(int i = 0; i < 3; i++)
      CreateButton(RRBtnName(i), cx + i * (BTN_W + BTN_GAP), cy, BTN_W, BTN_H,
                   rrLabels[i], CLR_BTN_OFF, CLR_TEXT);
   SetToggleGroup("RM_RR_", 3, g_rrIndex, CLR_BTN_ON, CLR_BTN_OFF);
   ObjectSetString(0, RRBtnName(0), OBJPROP_TOOLTIP, "TP = 1x SL distance (1:1 R:R)");
   ObjectSetString(0, RRBtnName(1), OBJPROP_TOOLTIP, "TP = 2x SL distance (2:1 R:R)");
   ObjectSetString(0, RRBtnName(2), OBJPROP_TOOLTIP, "TP = 3x SL distance (3:1 R:R)");
   cy += BTN_H + SECTION_GAP;

   // â”€â”€ Section tooltips â”€â”€
   ObjectSetString(0, "RM_SecRisk", OBJPROP_TOOLTIP, "Presets A");
   ObjectSetString(0, "RM_LblRisk", OBJPROP_TOOLTIP, "Presets A");
   ObjectSetString(0, "RM_LblMkt", OBJPROP_TOOLTIP, "Orders");
   ObjectSetString(0, "RM_LblLmt", OBJPROP_TOOLTIP, "Orders");
   ObjectSetString(0, "RM_LblStp", OBJPROP_TOOLTIP, "Orders");
   ObjectSetString(0, "RM_SecSL", OBJPROP_TOOLTIP, "Presets B");
   ObjectSetString(0, "RM_LblSL", OBJPROP_TOOLTIP, "Presets B");
   ObjectSetString(0, "RM_SecRR", OBJPROP_TOOLTIP, "Presets B");
   ObjectSetString(0, "RM_LblRR", OBJPROP_TOOLTIP, "Presets B");

   // â•â•â•â•â•â•â•â•â•â•â• Info Bar â•â•â•â•â•â•â•â•â•â•â•
   int col1X  = cx + 8;
   int col2X  = cx + innerW / 4;
   int col3X  = cx + innerW / 2;
   int col4X  = cx + 3 * innerW / 4;
   CreateBgRect("RM_InfoBG", x + 4, cy, panelW - 8, infoBarH, CLR_INFO_BG, CLR_BORDER_ACCENT);
   ObjectSetString(0, "RM_InfoBG", OBJPROP_TOOLTIP, "Info Labels");
   CreateLabel("RM_InfoOpenLots", col1X, cy + 8,  "Open: \x2014", CLR_TEXT_DIM, 12);
   CreateLabel("RM_InfoOpenRew",  col2X, cy + 8,  "Rew: \x2014", CLR_TEXT_DIM, 12);
   CreateLabel("RM_InfoOpenRisk", col3X, cy + 8,  "Risk: \x2014", CLR_TEXT_DIM, 12);
   CreateLabel("RM_InfoOpenRR",   col4X, cy + 8,  "R:R \x2014", CLR_TEXT_DIM, 12);
   CreateLabel("RM_InfoPendLots", col1X, cy + 30, "Pend: \x2014", CLR_TEXT_DIM, 12);
   CreateLabel("RM_InfoPendRew",  col2X, cy + 30, "Rew: \x2014", CLR_TEXT_DIM, 12);
   CreateLabel("RM_InfoPendRisk", col3X, cy + 30, "Risk: \x2014", CLR_TEXT_DIM, 12);
   CreateLabel("RM_InfoPendRR",   col4X, cy + 30, "R:R \x2014", CLR_TEXT_DIM, 12);
   CreateLabel("RM_InfoTotalOpen", col1X, cy + 52, "Total: \x2014", CLR_TEXT_DIM, 12);
   CreateLabel("RM_InfoTotalRew",  col2X, cy + 52, "Rew: \x2014", CLR_TEXT_DIM, 12);
   CreateLabel("RM_InfoTotalRisk", col3X, cy + 52, "Risk: \x2014", CLR_TEXT_DIM, 12);
   CreateLabel("RM_InfoTotalRR",   col4X, cy + 52, "R:R \x2014", CLR_TEXT_DIM, 12);
   CreateLabel("RM_InfoEquity",   col1X, cy + 76, "Equity: \x2014", CLR_TEXT_DIM, 13);
   CreateLabel("RM_InfoPnlSym",   cx + innerW / 3, cy + 76, _Symbol + ": \x2014", CLR_TEXT_DIM, 13);
   CreateLabel("RM_InfoPnlAll",   cx + 2 * innerW / 3, cy + 76, "All: \x2014", CLR_TEXT_DIM, 13);

   // â”€â”€ Tooltips for info bar labels â”€â”€
   ObjectSetString(0, "RM_InfoOpenLots", OBJPROP_TOOLTIP, "Total lots of open positions on this symbol");
   ObjectSetString(0, "RM_InfoOpenRew",  OBJPROP_TOOLTIP, "Total reward of open positions (entry to TP)");
   ObjectSetString(0, "RM_InfoOpenRisk", OBJPROP_TOOLTIP, "Total risk of open positions (entry to SL)");
   ObjectSetString(0, "RM_InfoOpenRR",   OBJPROP_TOOLTIP, "Reward-to-risk ratio of open positions");
   ObjectSetString(0, "RM_InfoPendLots", OBJPROP_TOOLTIP, "Total lots of pending orders on this symbol");
   ObjectSetString(0, "RM_InfoPendRew",  OBJPROP_TOOLTIP, "Total reward of pending orders (entry to TP)");
   ObjectSetString(0, "RM_InfoPendRisk", OBJPROP_TOOLTIP, "Total risk of pending orders (entry to SL)");
   ObjectSetString(0, "RM_InfoPendRR",   OBJPROP_TOOLTIP, "Reward-to-risk ratio of pending orders");
   ObjectSetString(0, "RM_InfoTotalOpen", OBJPROP_TOOLTIP, "Total lots of open positions across ALL symbols");
   ObjectSetString(0, "RM_InfoTotalRew",  OBJPROP_TOOLTIP, "Total reward across all symbols (entry to TP)");
   ObjectSetString(0, "RM_InfoTotalRisk", OBJPROP_TOOLTIP, "Total risk across all symbols (entry to SL)");
   ObjectSetString(0, "RM_InfoTotalRR",   OBJPROP_TOOLTIP, "Reward-to-risk ratio across all symbols");
   ObjectSetString(0, "RM_InfoEquity",   OBJPROP_TOOLTIP, "Account equity (balance + floating P/L)");
   ObjectSetString(0, "RM_InfoPnlSym",   OBJPROP_TOOLTIP, "Unrealized P/L for " + _Symbol + " positions");
   ObjectSetString(0, "RM_InfoPnlAll",   OBJPROP_TOOLTIP, "Unrealized P/L across all symbols");

   g_mainPanelBottom = y + panelH + 3;

   // â•â•â•â•â•â•â•â•â•â•â• Tools Panel â•â•â•â•â•â•â•â•â•â•â•
   BuildToolsPanel(x, g_mainPanelBottom + 8, panelW, cx);

   // â•â•â•â•â•â•â•â•â•â•â• Right Panel (Chart Tools) â•â•â•â•â•â•â•â•â•â•â•
   int toolsAtY = g_mainPanelBottom + 8;
   int toolsH2 = 12 + LABEL_H + BTN_H + SECTION_GAP + BTN_H + BTN_GAP + BTN_H + 14;
   int toolsFrameBottom = toolsAtY - 3 + toolsH2 + 6;
   int rpTopY = y - 3;
   int rpTotalH = toolsFrameBottom - rpTopY;
   int rpLeftEdge = x - 3 + panelW + 6;
   BuildRightPanel(rpLeftEdge, rpTopY, rpTotalH);

   // â•â•â•â•â•â•â•â•â•â•â• Test Panel (Thrust Structure) â•â•â•â•â•â•â•â•â•â•â•
   int rpBtnW_calc = 60;
   int rpPad_calc  = 8;
   int rpW_calc    = rpBtnW_calc + 2 * rpPad_calc;    // 76
   int tpLeftEdge  = rpLeftEdge + 8 + rpW_calc + 6;    // right edge of right panel frame
   BuildTestPanel(tpLeftEdge, rpTopY, rpTotalH);

   // â•â•â•â•â•â•â•â•â•â•â• Alerts Panel (Discord Alerts) â•â•â•â•â•â•â•â•â•â•â•
   int tpW_calc = 60 + 2 * 8;   // same width calc as test panel
   int apLeftEdge = tpLeftEdge + 8 + tpW_calc + 6;
   BuildAlertsPanel(apLeftEdge, rpTopY, rpTotalH);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Build the tools panel                                            |
//+------------------------------------------------------------------+
void BuildToolsPanel(int x, int topY, int panelW, int cx)
{
   int innerW   = panelW - 28;
   int thirdW   = (innerW - 2 * BTN_GAP) / 3;
   int ty = topY;

   int toolsH = 12 + LABEL_H + BTN_H + SECTION_GAP + BTN_H + BTN_GAP + BTN_H + BTN_GAP + BTN_H + BTN_GAP + BTN_H + SECTION_GAP + 50 + 14;

   CreateBgRect("RM_ToolsFrame", x - 3, ty - 3, panelW + 6, toolsH + 6, CLR_BORDER_GOLD, CLR_BORDER_GOLD);
   CreateBgRect("RM_ToolsBG", x, ty, panelW, toolsH, CLR_TOOLS_BG, CLR_TOOLS_BG);
   ObjectSetString(0, "RM_ToolsBG", OBJPROP_TOOLTIP, "Trade Management Tools");

   int tcy = ty + 12;

   // â”€â”€ Take Partials â”€â”€
   CreateLabel("RM_LblPartials", cx + 2, tcy + 2, "TAKE PARTIALS (Current Symbol)", CLR_TEXT_DIM, FONT_SIZE_LBL);
   ObjectSetString(0, "RM_LblPartials", OBJPROP_TOOLTIP, "Trade Management Tools");
   tcy += LABEL_H;
   CreateButton("RM_Partial30", cx, tcy, thirdW, BTN_H, "30 %", CLR_BTN_WARN, CLR_TEXT);
   ObjectSetString(0, "RM_Partial30", OBJPROP_TOOLTIP, "Close 30% of all positions on this symbol");
   CreateButton("RM_Partial50", cx + thirdW + BTN_GAP, tcy, thirdW, BTN_H, "50 %", CLR_BTN_WARN, CLR_TEXT);
   ObjectSetString(0, "RM_Partial50", OBJPROP_TOOLTIP, "Close 50% of all positions on this symbol");
   CreateButton("RM_Partial70", cx + 2 * (thirdW + BTN_GAP), tcy, thirdW, BTN_H, "70 %", CLR_BTN_WARN, CLR_TEXT);
   ObjectSetString(0, "RM_Partial70", OBJPROP_TOOLTIP, "Close 70% of all positions on this symbol");
   tcy += BTN_H + SECTION_GAP;

   // â”€â”€ Gold divider â”€â”€
   CreateBgRect("RM_Div2", x + 12, tcy - SECTION_GAP / 2 + 1, panelW - 24, 2, CLR_BORDER_GOLD, CLR_BORDER_GOLD);

   // â”€â”€ Row: Close All | Cancel All | Move BE â”€â”€
   int closeW = (innerW - 3 * BTN_GAP) / 4;
   CreateButton("RM_CloseSym", cx, tcy, closeW, BTN_H, "CLOSE SYM", CLR_BTN_SELL, CLR_TEXT);
   ObjectSetString(0, "RM_CloseSym", OBJPROP_TOOLTIP, "Close all open positions on THIS symbol only");
   CreateButton("RM_CloseAll", cx + closeW + BTN_GAP, tcy, closeW, BTN_H, "CLOSE ALL", CLR_BTN_SELL, CLR_TEXT);
   ObjectSetString(0, "RM_CloseAll", OBJPROP_TOOLTIP, "Close ALL open positions across ALL symbols");
   CreateButton("RM_CancelAll", cx + 2 * (closeW + BTN_GAP), tcy, closeW, BTN_H,
                "CANCEL", CLR_BTN_WARN, CLR_TEXT);
   ObjectSetString(0, "RM_CancelAll", OBJPROP_TOOLTIP, "Cancel ALL pending orders (all symbols)\n+ cancel armed hidden orders");
   CreateButton("RM_MoveBE", cx + 3 * (closeW + BTN_GAP), tcy, closeW, BTN_H,
                "MOVE BE", CLR_BTN_TEAL, CLR_TEXT);
   ObjectSetString(0, "RM_MoveBE", OBJPROP_TOOLTIP, "Move SL to breakeven on all positions\nfor this symbol");
   tcy += BTN_H + BTN_GAP;

   // -- Row: PRT.MTX | EXIT.MTX | BE.MTX | CNCL.MTX --
   int qtrW = (innerW - 3 * BTN_GAP) / 4;
   CreateButton("RM_PartialsMatrix", cx, tcy, qtrW, BTN_H,
                "PRT.MTX", g_partialMatrixActive ? CLR_BTN_ON : CLR_BTN_TEAL, CLR_TEXT);
   ObjectSetString(0, "RM_PartialsMatrix", OBJPROP_TOOLTIP,
      "PARTIALS MATRIX: Places 3 draggable lines.\n"
      "Closes 50% of positions on this symbol\n"
      "when price/time breaches any line.");
   CreateButton("RM_ExitMatrix", cx + qtrW + BTN_GAP, tcy, qtrW, BTN_H,
                "EXIT.MTX", g_exitMatrixActive ? CLR_BTN_ON : CLR_BTN_EXIT, CLR_TEXT);
   ObjectSetString(0, "RM_ExitMatrix", OBJPROP_TOOLTIP,
      "EXIT MATRIX: Places 3 draggable lines.\n"
      "Closes ALL positions on this symbol\n"
      "when price/time breaches any line.");
   CreateButton("RM_BeMtx", cx + 2 * (qtrW + BTN_GAP), tcy, qtrW, BTN_H,
                "BE.MTX", g_beMtxActive ? CLR_BTN_ON : CLR_BTN_TEAL, CLR_TEXT);
   ObjectSetString(0, "RM_BeMtx", OBJPROP_TOOLTIP,
      "BREAKEVEN MATRIX: Places 3 draggable lines.\n"
      "Moves SL to breakeven on all positions\n"
      "when price/time breaches any line.");
   CreateButton("RM_CnclMtx", cx + 3 * (qtrW + BTN_GAP), tcy, qtrW, BTN_H,
                "CNCL.MTX", g_cnclMtxActive ? CLR_BTN_ON : CLR_BTN_WARN, CLR_TEXT);
   ObjectSetString(0, "RM_CnclMtx", OBJPROP_TOOLTIP,
      "CANCEL MATRIX: Places 3 draggable lines.\n"
      "Cancels ALL pending orders on this symbol\n"
      "when price/time breaches any line.");
   tcy += BTN_H + BTN_GAP;

   // -- Row: TRL H1 | TRL H4 | H.TRL | TRAIL --
   {
      int trW = (innerW - 3 * BTN_GAP) / 4;
      string h1Lbl = g_trailH1Active ? "H1 ON" : "H1 OFF";
      string h4Lbl = g_trailH4Active ? "H4 ON" : "H4 OFF";
      string htLbl = g_hiddenTrailActive ? "H.T ON" : "H.T OFF";
      string atLbl = g_autoTrailActive ? "TRL ON" : "TRL OFF";
      CreateButton("RM_BtnTrailH1", cx, tcy, trW, BTN_H,
                   h1Lbl, g_trailH1Active ? CLR_BTN_ON : CLR_BTN_TEAL, CLR_TEXT);
      ObjectSetString(0, "RM_BtnTrailH1", OBJPROP_TOOLTIP,
         "TRAIL LINE (H1 Swings)\n"
         "Shows a visual line at the H1 (M15 thrust) swing level.\n"
         "Long: swing low. Short: swing high.\n"
         "Mutually exclusive with TRL H4.\n"
         "Use TRAIL button to activate physical SL trailing.");
      CreateButton("RM_BtnTrailH4", cx + trW + BTN_GAP, tcy, trW, BTN_H,
                   h4Lbl, g_trailH4Active ? CLR_BTN_ON : CLR_BTN_TEAL, CLR_TEXT);
      ObjectSetString(0, "RM_BtnTrailH4", OBJPROP_TOOLTIP,
         "TRAIL LINE (H4 Swings)\n"
         "Shows a visual line at the H4 (H1 thrust) swing level.\n"
         "Long: swing low. Short: swing high.\n"
         "Mutually exclusive with TRL H1.\n"
         "Use TRAIL button to activate physical SL trailing.");
      CreateButton("RM_BtnHTrail", cx + 2 * (trW + BTN_GAP), tcy, trW, BTN_H,
                   htLbl, g_hiddenTrailActive ? CLR_BTN_HIDDEN_ON : CLR_BTN_HIDDEN, CLR_TEXT);
      ObjectSetString(0, "RM_BtnHTrail", OBJPROP_TOOLTIP,
         "HIDDEN TRAILING SL\n"
         "Closes ALL positions when price touches\n"
         "the active trail line (H1 or H4).\n"
         "Does NOT move physical SL.\n"
         "Requires TRL H1 or TRL H4 to be active.");
      CreateButton("RM_BtnAutoTrail", cx + 3 * (trW + BTN_GAP), tcy, trW, BTN_H,
                   atLbl, g_autoTrailActive ? CLR_BTN_ON : CLR_BTN_SELL, CLR_TEXT);
      ObjectSetString(0, "RM_BtnAutoTrail", OBJPROP_TOOLTIP,
         "AUTO TRAIL SL\n"
         "Physically moves SL to the active trail level\n"
         "(H1 or H4, whichever line is on).\n"
         "Only trails in protective direction (never widens).\n"
         "Requires TRL H1 or TRL H4 to be active.");
   }
   tcy += BTN_H + BTN_GAP;

   // -- Row: +LOT (add position at market using risk preset A) --
   CreateButton("RM_AddLot", cx, tcy, innerW, BTN_H, "+LOT", CLR_BTN_BUY, CLR_TEXT);
   ObjectSetString(0, "RM_AddLot", OBJPROP_TOOLTIP,
      "+LOT: Add position at Market using Risk Preset A\n"
      "Uses avg SL and avg TP of existing positions.\n"
      "Direction matches current position side.\n"
      "Lot size = risk $ / stop distance.");
   tcy += BTN_H + BTN_GAP;

   // ── Row: SET SL | SET TP ──
   int halfBtnW = (innerW - BTN_GAP) / 2;
   CreateButton("RM_SetSL", cx, tcy, halfBtnW, BTN_H,
                "SET SL", g_setSLActive ? CLR_BTN_ON : CLR_BTN_SELL, CLR_TEXT);
   ObjectSetString(0, "RM_SetSL", OBJPROP_TOOLTIP,
      "SET SL: Places a draggable line on chart\n"
      "1 SL Range deviation away in the proper direction.\n"
      "Press Enter to set ALL positions' SL to this line.\n"
      "Click again to cancel.");
   CreateButton("RM_SetTP", cx + halfBtnW + BTN_GAP, tcy, halfBtnW, BTN_H,
                "SET TP", g_setTPActive ? CLR_BTN_ON : CLR_BTN_BUY, CLR_TEXT);
   ObjectSetString(0, "RM_SetTP", OBJPROP_TOOLTIP,
      "SET TP: Places a draggable line on chart\n"
      "1 SL Range deviation away in the proper direction.\n"
      "Press Enter to set ALL positions' TP to this line.\n"
      "Click again to cancel.");
   tcy += BTN_H + BTN_GAP;

   // ── Row: SMART TP (3-way toggle: today → all days → off) ──
   string smtpLabel = (g_smartTPMode == 0) ? "SMART TP" : (g_smartTPMode == 1) ? "SM.TP \x25CF" : "SM.TP \x2605";
   CreateButton("RM_SmartTP", cx, tcy, innerW, BTN_H,
                smtpLabel, (g_smartTPMode > 0) ? CLR_BTN_ON : CLR_BTN_BUY, CLR_TEXT);
   ObjectSetString(0, "RM_SmartTP", OBJPROP_TOOLTIP,
      "SMART TP \x2014 Overbought/Oversold Pace Tracker\n"
      "\n"
      "PURPOSE:\n"
      "Predicts the day's high and low using D.STK/D.BX levels,\n"
      "then draws a diagonal trendline representing the expected\n"
      "average rate of price change throughout the day. If price\n"
      "runs far ahead of this expected pace, you are overbought\n"
      "and should consider taking profits early \x2014 even if price\n"
      "hasn't reached your final TP yet.\n"
      "\n"
      "\x2500\x2500\x2500 CHART OBJECTS \x2500\x2500\x2500\n"
      "Green line = estimated day high (TP target)\n"
      "Red line   = estimated day low (base/SL reference)\n"
      "Diagonal   = expected price path from red at BOD to green at EOD\n"
      "Score text = live score displayed at the green line\n"
      "\n"
      "\x2500\x2500\x2500 LEVELS \x2500\x2500\x2500\n"
      "Current day (uses previous day's range):\n"
      "  Bull prev candle: green = 125% level, red = 25% level\n"
      "  Bear prev candle: green = 75% level,  red = -25% level\n"
      "Historical days (uses that day's own H/L):\n"
      "  Bull candle: green = high, red = low\n"
      "  Bear candle: green = low,  red = high\n"
      "\n"
      "\x2500\x2500\x2500 SCORE FORMULA \x2500\x2500\x2500\n"
      "score = p\x00B2 / t\n"
      "\n"
      "Where:\n"
      "  t = time progress = (now - dayStart) / (dayEnd - dayStart)\n"
      "      Ranges from 0.0 (start of day) to 1.0 (end of day)\n"
      "\n"
      "  p = TP progress = (bid - red) / (green - red)\n"
      "      0.0 = price at the red line (no progress)\n"
      "      1.0 = price at the green line (full TP reached)\n"
      "      >1.0 = price exceeded the green target\n"
      "\n"
      "The formula squares p, then divides by t. This means:\n"
      "  \x2022 You need BOTH high pace AND meaningful TP progress\n"
      "  \x2022 Early-day noise is filtered (small p\x00B2 even if pace is high)\n"
      "  \x2022 A score of 1.0 = exactly on pace (p equals t)\n"
      "  \x2022 Scores above 1.0 = ahead of schedule\n"
      "\n"
      "\x2500\x2500\x2500 EXAMPLE SCENARIOS \x2500\x2500\x2500\n"
      "  80% TP at 25% of day \x2192 0.8\x00B2/0.25 = 2.56 (HEAVY TP)\n"
      "  60% TP at 50% of day \x2192 0.6\x00B2/0.50 = 0.72 (HOLD)\n"
      "  40% TP at 10% of day \x2192 0.4\x00B2/0.10 = 1.60 (MOD TP)\n"
      "  90% TP at 70% of day \x2192 0.9\x00B2/0.70 = 1.16 (LIGHT TP)\n"
      "  50% TP at 50% of day \x2192 0.5\x00B2/0.50 = 0.50 (HOLD)\n"
      "\n"
      "\x2500\x2500\x2500 ACTION TIERS \x2500\x2500\x2500\n"
      "  \x2265 2.5 = HEAVY TP (bright green)\n"
      "    Way ahead of schedule. Take 50-70% off the table.\n"
      "    Price moved fast early \x2014 mean reversion likely.\n"
      "\n"
      "  \x2265 1.5 = MOD TP (green-yellow)\n"
      "    Comfortably ahead. Take ~30% profit.\n"
      "    Good progress but room to run.\n"
      "\n"
      "  \x2265 1.0 = LIGHT TP (yellow)\n"
      "    Slightly ahead of expected pace. Consider 10-20%.\n"
      "    Borderline \x2014 only act if other signals confirm.\n"
      "\n"
      "  < 1.0 = HOLD (gray)\n"
      "    On pace or behind schedule. Do nothing.\n"
      "    Let the trade develop.\n"
      "\n"
      "  BEHIND (red) = p < 0\n"
      "    Price is below the red line. Trade is losing.\n"
      "\n"
      "  WAIT (gray, no score)\n"
      "    Less than 10% of day elapsed. Too early to score.\n"
      "\n"
      "\x2500\x2500\x2500 MODES \x2500\x2500\x2500\n"
      "Click 1 (\x25CF): Today only \x2014 shows current day levels + live score\n"
      "Click 2 (\x2605): All days  \x2014 shows ~93 days of historical levels\n"
      "Click 3: Off \x2014 removes all objects\n"
      "\n"
      "All green and red lines are draggable.\n"
      "Lines auto-snap back to their day if moved horizontally.\n"
      "Diagonal updates automatically when either line is dragged.");
   tcy += BTN_H + SECTION_GAP;

   // â”€â”€ Gold divider â”€â”€
   CreateBgRect("RM_Div3", x + 12, tcy - SECTION_GAP / 2 + 1, panelW - 24, 2, CLR_BORDER_GOLD, CLR_BORDER_GOLD);

   // â”€â”€ Equity TP% / SL% with two rows of +/- â”€â”€
   int halfW = (innerW - BTN_GAP) / 2;
   int sqS   = 25;   // square +/- button size
   int eqH   = 2 * sqS;  // total height (two rows, no gap)
   int lblW  = halfW - 2 * sqS - 2 * 2;  // center label width

   // SL% group (left side)
   int slX = cx;
   CreateButton("RM_EqSLM01", slX, tcy, sqS, sqS, "-", CLR_BTN_WARN, CLR_TEXT, 13);
   CreateButton("RM_EqSLP01", slX + sqS + 2 + lblW + 2, tcy, sqS, sqS, "+", CLR_BTN_SELL, CLR_TEXT, 13);
   CreateButton("RM_EqSLM10", slX, tcy + sqS, sqS, sqS, "--", CLR_BTN_WARN, CLR_TEXT, 12);
   CreateButton("RM_EqSLP10", slX + sqS + 2 + lblW + 2, tcy + sqS, sqS, sqS, "++", CLR_BTN_SELL, CLR_TEXT, 12);
   string slTxt = EqLabelText("SL", g_eqSLPct, g_eqSLActive);
   CreateButton("RM_EqSLLbl", slX + sqS + 2, tcy, lblW, eqH, slTxt,
                g_eqSLActive ? CLR_BTN_ON : (g_eqSLPct > 0) ? CLR_BTN_SELL : CLR_BTN_OFF, CLR_TEXT, 13);
   ObjectSetString(0, "RM_EqSLLbl", OBJPROP_TOOLTIP,
      "EQUITY STOP LOSS\n"
      "Shows target equity. Auto-closes ALL positions\n"
      "when equity drops to this level.\n"
      "Click to arm/disarm. +/- to adjust.");

   // TP% group (right side)
   int tpX = cx + halfW + BTN_GAP;
   CreateButton("RM_EqTPM01", tpX, tcy, sqS, sqS, "-", CLR_BTN_WARN, CLR_TEXT, 13);
   CreateButton("RM_EqTPP01", tpX + sqS + 2 + lblW + 2, tcy, sqS, sqS, "+", CLR_BTN_BUY, CLR_TEXT, 13);
   CreateButton("RM_EqTPM10", tpX, tcy + sqS, sqS, sqS, "--", CLR_BTN_WARN, CLR_TEXT, 12);
   CreateButton("RM_EqTPP10", tpX + sqS + 2 + lblW + 2, tcy + sqS, sqS, sqS, "++", CLR_BTN_BUY, CLR_TEXT, 12);
   string tpTxt = EqLabelText("TP", g_eqTPPct, g_eqTPActive);
   CreateButton("RM_EqTPLbl", tpX + sqS + 2, tcy, lblW, eqH, tpTxt,
                g_eqTPActive ? CLR_BTN_ON : (g_eqTPPct > 0) ? CLR_BTN_BUY : CLR_BTN_OFF, CLR_TEXT, 13);
   ObjectSetString(0, "RM_EqTPLbl", OBJPROP_TOOLTIP,
      "EQUITY TAKE PROFIT\n"
      "Shows target equity. Auto-closes ALL positions\n"
      "when equity reaches this level.\n"
      "Click to arm/disarm. +/- to adjust.");
}

//+------------------------------------------------------------------+
//| Toggle dashboard visibility (hide/show all RM_ objects)          |
//+------------------------------------------------------------------+
void ToggleDashboardVisibility()
{
   g_dashboardHidden = !g_dashboardHidden;
   if(g_dashboardHidden)
   {
      // Hide: delete only dashboard/UI objects (not chart drawings)
      int total = ObjectsTotal(0);
      for(int i = total - 1; i >= 0; i--)
      {
         string name = ObjectName(0, i);
         if(StringFind(name, "RM_") != 0) continue;
         if(name == "RM_BtnHide") continue;
         // Skip chart drawing prefixes
         if(StringFind(name, "RM_OR_") == 0) continue;
         if(StringFind(name, "RM_SH_") == 0) continue;
         if(StringFind(name, "RM_DB_") == 0) continue;
         if(StringFind(name, "RM_WB_") == 0) continue;
         if(StringFind(name, "RM_WOR_") == 0) continue;
         if(StringFind(name, "RM_DMX_") == 0) continue;
         if(StringFind(name, "RM_WMX_") == 0) continue;
         if(StringFind(name, "RM_D150_") == 0) continue;
         if(StringFind(name, "RM_DLVL_") == 0) continue;
         if(StringFind(name, "RM_DSTK_") == 0) continue;
         if(StringFind(name, "RM_MLVL_") == 0) continue;
         if(StringFind(name, "RM_SMX_") == 0) continue;
         if(StringFind(name, "RM_H4MX_") == 0) continue;
         if(StringFind(name, "RM_TT_") == 0) continue;
         if(StringFind(name, "RM_H4_") == 0) continue;
         if(name == g_exitAboveName || name == g_exitBelowName || name == g_exitTimeName) continue;
         if(name == g_partAboveName || name == g_partBelowName || name == g_partTimeName) continue;
         if(name == g_beAboveName || name == g_beBelowName || name == g_beTimeName) continue;
         if(name == g_entryLineName || name == g_tpLineName || name == g_slLineName) continue;
         if(name == g_setSLLineName || name == g_setTPLineName) continue;
         if(StringFind(name, "RM_SmTP_") == 0) continue;
         if(name == g_cnclAboveName || name == g_cnclBelowName || name == g_cnclTimeName) continue;
         if(name == "RM_HiddenTrail" || name == "RM_HiddenTrailLbl") continue;
         if(name == "RM_TrailH1" || name == "RM_TrailH1Lbl") continue;
         if(name == "RM_TrailH4" || name == "RM_TrailH4Lbl") continue;
         ObjectDelete(0, name);
      }
   }
   else
   {
      // Show: rebuild dashboard only (chart drawings are still intact)
      BuildDashboard();
      // Refresh button colors for chart tools
      ObjectSetInteger(0, "RM_BtnOR",  OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnOR"));
      ObjectSetInteger(0, "RM_BtnSHL", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSHL"));
      ObjectSetInteger(0, "RM_BtnDBX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDBX"));
      ObjectSetInteger(0, "RM_BtnWBX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnWBX"));
      ObjectSetInteger(0, "RM_BtnWOR", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnWOR"));
      ObjectSetInteger(0, "RM_BtnDMX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDMX"));
      ObjectSetInteger(0, "RM_BtnWMX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnWMX"));
      ObjectSetInteger(0, "RM_BtnD150",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnD150"));
      ObjectSetInteger(0, "RM_BtnSGAP",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSGAP"));
      ObjectSetInteger(0, "RM_BtnSBRK",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSBRK"));
      ObjectSetInteger(0, "RM_BtnDLVL",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDLVL"));
      ObjectSetInteger(0, "RM_BtnDSTK",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDSTK"));
      ObjectSetInteger(0, "RM_BtnMLVL",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnMLVL"));
      ObjectSetInteger(0, "RM_BtnPIVT",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnPIVT"));
      ObjectSetInteger(0, "RM_BtnTHRS",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnTHRS"));
      ObjectSetInteger(0, "RM_BtnBOS", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnBOS"));
      ObjectSetInteger(0, "RM_BtnFLOW",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnFLOW"));
      ObjectSetInteger(0, "RM_BtnSWNG",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSWNG"));
      ObjectSetInteger(0, "RM_BtnVSTR",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnVSTR"));
      ObjectSetInteger(0, "RM_BtnH4TH",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnH4TH"));
      ObjectSetInteger(0, "RM_BtnH4FC",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnH4FC"));
      ObjectSetInteger(0, "RM_BtnAltH4FC",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltH4FC"));
      ObjectSetInteger(0, "RM_BtnAltCTR",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltCTR"));
      ObjectSetInteger(0, "RM_ExitMatrix", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_ExitMatrix"));
      ObjectSetInteger(0, "RM_PartialsMatrix", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_PartialsMatrix"));
      ObjectSetInteger(0, "RM_BeMtx", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BeMtx"));
      ObjectSetInteger(0, "RM_BtnTrailH1", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnTrailH1"));
      ObjectSetInteger(0, "RM_BtnTrailH4", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnTrailH4"));
      ObjectSetInteger(0, "RM_BtnHTrail", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnHTrail"));
      ObjectSetInteger(0, "RM_BtnAutoTrail", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAutoTrail"));
      UpdatePositionInfo();
      UpdateLiveInfo();
   }
   ObjectSetString(0, "RM_BtnHide", OBJPROP_TEXT,
      g_dashboardHidden ? "\x25B6" : "\x25C0");
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Set chart color theme                                            |
//+------------------------------------------------------------------+
void SetChartTheme()
{
   ChartSetInteger(0, CHART_COLOR_BACKGROUND,  C'245,235,220');
   ChartSetInteger(0, CHART_COLOR_FOREGROUND,  C'80,70,55');
   ChartSetInteger(0, CHART_COLOR_GRID,        C'225,218,205');
   ChartSetInteger(0, CHART_COLOR_CANDLE_BULL, C'0,120,50');
   ChartSetInteger(0, CHART_COLOR_CANDLE_BEAR, clrBlack);
   ChartSetInteger(0, CHART_COLOR_CHART_UP,    clrBlack);
   ChartSetInteger(0, CHART_COLOR_CHART_DOWN,  clrBlack);
   ChartSetInteger(0, CHART_COLOR_CHART_LINE,  C'60,50,40');
   ChartSetInteger(0, CHART_COLOR_BID,         C'200,50,50');
   ChartSetInteger(0, CHART_COLOR_ASK,         C'50,150,50');
   ChartSetInteger(0, CHART_COLOR_VOLUME,      C'140,130,115');
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Build the right panel (chart tools column)                       |
//+------------------------------------------------------------------+
void BuildRightPanel(int leftEdge, int topY, int totalH)
{
   int rpPad  = 8;
   int rpBtnW = 60;
   int rpBtnH = 46;
   int rpGap  = 6;
   int rpW    = rpBtnW + 2 * rpPad;
   int rpX    = leftEdge + 8;

   CreateBgRect("RM_RPFrame", rpX - 3, topY - 3, rpW + 6, totalH + 6,
                CLR_BORDER_GOLD, CLR_BORDER_GOLD);
   CreateBgRect("RM_RPBG", rpX, topY, rpW, totalH, CLR_PANEL_BG, CLR_PANEL_BG);
   ObjectSetString(0, "RM_RPBG", OBJPROP_TOOLTIP, "Chart Plots");

   int btnX = rpX + rpPad;
   int cy   = topY + rpPad;
   int abSz = 12; // auto-badge size

   // Button 1: Daily Matrix Level (D.MXâ˜…) â€” moved to top
   CreateButton("RM_BtnMLVL", btnX, cy, rpBtnW, rpBtnH, "D.MTX\x2606",
                g_dmxLabelActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_MLVL",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_MLVLL", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_MLVL", OBJPROP_TOOLTIP, "Auto: Updates per tick + every 1s");
   ObjectSetString(0, "RM_AB_MLVLL", OBJPROP_TOOLTIP, "Auto: Updates per tick + every 1s");
   cy += rpBtnH + rpGap;

   // Button 1b: Swing Matrix
   CreateButton("RM_BtnSMX", btnX, cy, rpBtnW, rpBtnH, "S.MTX",
                g_smxActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnSMX", OBJPROP_TOOLTIP, "H1 Swing Matrix (last two swings)\nF/U prefix, 0=swing low, 100=swing high");
   cy += rpBtnH + rpGap;

   // Button 1c: H4 Matrix
   CreateButton("RM_BtnH4MX", btnX, cy, rpBtnW, rpBtnH, "H4.MTX",
                g_h4MtxActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnH4MX", OBJPROP_TOOLTIP, "H4 Swing Matrix (last two swings)\nF/U prefix, 0=swing low, 100=swing high");
   cy += rpBtnH + rpGap;

   // Button 2: Daily Opening Range
   CreateButton("RM_BtnOR", btnX, cy, rpBtnW, rpBtnH, "D.OR",
                g_orActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_OR",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_ORL", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_OR", OBJPROP_TOOLTIP, "Auto: Redraws every 60s");
   ObjectSetString(0, "RM_AB_ORL", OBJPROP_TOOLTIP, "Auto: Redraws every 60s");
   cy += rpBtnH + rpGap;

   // Button 2: Session High/Low
   CreateButton("RM_BtnSHL", btnX, cy, rpBtnW, rpBtnH, "S.HL",
                g_sessHLActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_SHL",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_SHLL", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_SHL", OBJPROP_TOOLTIP, "Auto: Checks every 60s");
   ObjectSetString(0, "RM_AB_SHLL", OBJPROP_TOOLTIP, "Auto: Checks every 60s");
   cy += rpBtnH + rpGap;

   // Button 3: Daily Box
   CreateButton("RM_BtnDBX", btnX, cy, rpBtnW, rpBtnH, "D.BX",
                g_dailyBoxActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_DBX",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_DBXL", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_DBX", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   ObjectSetString(0, "RM_AB_DBXL", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   cy += rpBtnH + rpGap;

   // Button 4: Weekly Box
   CreateButton("RM_BtnWBX", btnX, cy, rpBtnW, rpBtnH, "W.BX",
                g_weeklyBoxActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_WBX",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_WBXL", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_WBX", OBJPROP_TOOLTIP, "Auto: Redraws every 10 min");
   ObjectSetString(0, "RM_AB_WBXL", OBJPROP_TOOLTIP, "Auto: Redraws every 10 min");
   cy += rpBtnH + rpGap;

   // Button 5: Weekly Opening Range
   CreateButton("RM_BtnWOR", btnX, cy, rpBtnW, rpBtnH, "W.OR",
                g_weeklyORActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_WOR",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_WORL", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_WOR", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   ObjectSetString(0, "RM_AB_WORL", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   cy += rpBtnH + rpGap;

   // Button 6: Daily Matrix
   CreateButton("RM_BtnDMX", btnX, cy, rpBtnW, rpBtnH, "D.MTX",
                g_dailyMtxActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_DMX",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_DMXL", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_DMX", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   ObjectSetString(0, "RM_AB_DMXL", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   cy += rpBtnH + rpGap;

   // Button 7: Weekly Matrix
   CreateButton("RM_BtnWMX", btnX, cy, rpBtnW, rpBtnH, "W.MTX",
                g_weeklyMtxActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_WMX",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_WMXL", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_WMX", OBJPROP_TOOLTIP, "Auto: Redraws every 10 min");
   ObjectSetString(0, "RM_AB_WMXL", OBJPROP_TOOLTIP, "Auto: Redraws every 10 min");
   cy += rpBtnH + rpGap;

   // Button 8: Daily 150 Detection
   CreateButton("RM_BtnD150", btnX, cy, rpBtnW, rpBtnH, "D.150",
                g_daily150Active ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_D150",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_D150L", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_D150", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   ObjectSetString(0, "RM_AB_D150L", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   cy += rpBtnH + rpGap;

   // Button 9: Session Gap
   CreateButton("RM_BtnSGAP", btnX, cy, rpBtnW, rpBtnH, "S.GAP",
                g_sessGapActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_SGAP",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_SGAPL", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_SGAP", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   ObjectSetString(0, "RM_AB_SGAPL", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   cy += rpBtnH + rpGap;

   // Button 10: Session Breaker
   CreateButton("RM_BtnSBRK", btnX, cy, rpBtnW, rpBtnH, "S.BRK",
                g_sessBrkActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_SBRK",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_SBRKL", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_SBRK", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   ObjectSetString(0, "RM_AB_SBRKL", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   cy += rpBtnH + rpGap;

   // Button 11: Daily Levels tracker
   CreateButton("RM_BtnDLVL", btnX, cy, rpBtnW, rpBtnH, "D.LVL",
                g_dailyLvlActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_DLVL",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_DLVLL", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_DLVL", OBJPROP_TOOLTIP, "Auto: Updates per bar change");
   ObjectSetString(0, "RM_AB_DLVLL", OBJPROP_TOOLTIP, "Auto: Updates per bar change");
   cy += rpBtnH + rpGap;

   // Button 12: Daily Stalk Zones (3-mode)
   string dstkLabel = (g_dStkMode == 0) ? "D.STK" : (g_dStkMode == 1) ? "D.STK\x2605" : "D.STK\x25CF";
   CreateButton("RM_BtnDSTK", btnX, cy, rpBtnW, rpBtnH, dstkLabel,
                (g_dStkMode > 0) ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   CreateBgRect("RM_AB_DSTK",  btnX + rpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_DSTKL", btnX + rpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_DSTK", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   ObjectSetString(0, "RM_AB_DSTKL", OBJPROP_TOOLTIP, "Auto: Redraws every 5 min");
   cy += rpBtnH + rpGap;

   // Placeholder buttons for the rest of the column
   for(int i = 8; cy + rpBtnH <= topY + totalH - rpPad; i++)
   {
      string name = "RM_RP_" + IntegerToString(i);
      CreateButton(name, btnX, cy, rpBtnW, rpBtnH, "\x2014",
                   CLR_BTN_PLC, CLR_TEXT_DIM, FONT_SIZE);
      cy += rpBtnH + rpGap;
   }
}

//+------------------------------------------------------------------+
//| Build the test panel (Thrust Structure)                          |
//+------------------------------------------------------------------+
void BuildTestPanel(int leftEdge, int topY, int totalH)
{
   int tpPad  = 8;
   int tpBtnW = 60;
   int tpBtnH = 46;
   int tpGap  = 6;
   int tpW    = tpBtnW + 2 * tpPad;
   int tpX    = leftEdge + 8;

   CreateBgRect("RM_TPFrame", tpX - 3, topY - 3, tpW + 6, totalH + 6,
                CLR_BORDER_GOLD, CLR_BORDER_GOLD);
   CreateBgRect("RM_TPBG", tpX, topY, tpW, totalH, CLR_PANEL_BG, CLR_PANEL_BG);
   ObjectSetString(0, "RM_TPBG", OBJPROP_TOOLTIP, "Thrust Test");

   int btnX = tpX + tpPad;
   int cy   = topY + tpPad;
   int abSz = 12; // auto-badge size

   // â”€â”€ TREND indicator (top of panel) â”€â”€
   {
      bool isUp = (g_tt_tTrend == 1);
      color trdBg  = isUp ? C'0,120,0' : C'150,30,30';
      color trdTxt = isUp ? C'140,255,140' : C'255,160,160';
      string trdLabel = isUp ? "TREND\x25B2" : "TREND\x25BC";
      CreateButton("RM_BtnTREND", btnX, cy, tpBtnW, tpBtnH, trdLabel,
                   trdBg, trdTxt, FONT_SIZE);
      ObjectSetString(0, "RM_BtnTREND", OBJPROP_TOOLTIP,
         "TREND\nShows current H1 thrust trend direction.\n"
         "Green = bullish / Red = bearish.\n"
         "Does not toggle any chart drawing.");
      CreateBgRect("RM_AB_TRND",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
      CreateLabel("RM_AB_TRNDL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
      ObjectSetString(0, "RM_AB_TRND", OBJPROP_TOOLTIP, "Auto: Direction updates per M15 bar");
      ObjectSetString(0, "RM_AB_TRNDL", OBJPROP_TOOLTIP, "Auto: Direction updates per M15 bar");
   }
   cy += tpBtnH + tpGap;

   CreateButton("RM_BtnPIVT", btnX, cy, tpBtnW, tpBtnH, "PIVT",
                g_tt_pivotActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnPIVT", OBJPROP_TOOLTIP,
      "PIVOT DETECTION\n"
      "Marks 4-bar pivot highs (blue arrow) and\n"
      "pivot lows (orange arrow) on M15.\n"
      "A pivot high = bar whose high >= the high\n"
      "of the 4 bars before it. Pivot low = bar\n"
      "whose low <= the low of the 4 bars before it.\n"
      "These are the anchor points for swing tracking.");
   CreateBgRect("RM_AB_PIVT",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_PIVTL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_PIVT", OBJPROP_TOOLTIP, "Auto: Pivot arrows draw per M15 bar");
   ObjectSetString(0, "RM_AB_PIVTL", OBJPROP_TOOLTIP, "Auto: Pivot arrows draw per M15 bar");
   cy += tpBtnH + tpGap;

   CreateButton("RM_BtnTHRS", btnX, cy, tpBtnW, tpBtnH, "THRS",
                g_tt_thrustActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnTHRS", OBJPROP_TOOLTIP,
      "THRUST DETECTION\n"
      "Draws short horizontal lines at swing points\n"
      "where a thrust occurs (tFlow flips direction).\n"
      "Down thrust: price breaks below the lowest low\n"
      "of the prior 4 bars -> marks the last pivot high\n"
      "as swingHigh. Up thrust: price breaks above the\n"
      "highest high of the prior 4 bars -> marks the\n"
      "last pivot low as swingLow. Olive until BOS fires.");
   CreateBgRect("RM_AB_THRS",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_THRSL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_THRS", OBJPROP_TOOLTIP, "Auto: Thrust lines draw per M15 bar");
   ObjectSetString(0, "RM_AB_THRSL", OBJPROP_TOOLTIP, "Auto: Thrust lines draw per M15 bar");
   cy += tpBtnH + tpGap;

   CreateButton("RM_BtnBOS", btnX, cy, tpBtnW, tpBtnH, "BOS",
                g_tt_bosActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnBOS", OBJPROP_TOOLTIP,
      "BREAK OF STRUCTURE\n"
      "Recolors thrust lines based on structure breaks.\n"
      "When price breaks above swingHigh -> Up BOS.\n"
      "When price breaks below swingLow -> Down BOS.\n"
      "Green = continuation (BOS in trend direction).\n"
      "Maroon = CHoCH (trend reversal).\n"
      "Toggle while THRS is on to see the recoloring.");
   CreateBgRect("RM_AB_BOS",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_BOSL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_BOS", OBJPROP_TOOLTIP, "Auto: BOS recolors per M15 bar");
   ObjectSetString(0, "RM_AB_BOSL", OBJPROP_TOOLTIP, "Auto: BOS recolors per M15 bar");
   cy += tpBtnH + tpGap;

   CreateButton("RM_BtnCHCH", btnX, cy, tpBtnW, tpBtnH, "CHCH",
                g_tt_chochActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnCHCH", OBJPROP_TOOLTIP,
      "CHANGE OF CHARACTER\n"
      "Controls visibility of CHoCH (reversal) thrust lines.\n"
      "When ON, maroon thrust lines are shown.\n"
      "When OFF, CHoCH lines revert to olive (pending).\n"
      "Requires BOS to be active to see the effect.");
   CreateBgRect("RM_AB_CHCH",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_CHCHL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_CHCH", OBJPROP_TOOLTIP, "Auto: CHoCH lines recolor per M15 bar");
   ObjectSetString(0, "RM_AB_CHCHL", OBJPROP_TOOLTIP, "Auto: CHoCH lines recolor per M15 bar");
   cy += tpBtnH + tpGap;

   CreateButton("RM_BtnFLOW", btnX, cy, tpBtnW, tpBtnH, "FLW\x25B2",
                g_tt_flowActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnFLOW", OBJPROP_TOOLTIP,
      "FLOW LINE\n"
      "Aqua dashed extending line showing the current\n"
      "flow level. When tFlow=Up (bullish flow),\n"
      "tracks the lowest low of the last 4 bars.\n"
      "When tFlow=Down (bearish flow), tracks the\n"
      "highest high of the last 4 bars. Acts as\n"
      "a dynamic support/resistance trailing the flow.");
   CreateBgRect("RM_AB_FLOW",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_FLOWL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_FLOW", OBJPROP_TOOLTIP, "Auto: Flow line moves per M15 bar");
   ObjectSetString(0, "RM_AB_FLOWL", OBJPROP_TOOLTIP, "Auto: Flow line moves per M15 bar");
   cy += tpBtnH + tpGap;

   string swLabel = (g_tt_swingMode == 0) ? "SW.HL" : (g_tt_swingMode == 1) ? "SW.HL\x2500" : "SW.HL\x25CF";
   CreateButton("RM_BtnSWNG", btnX, cy, tpBtnW, tpBtnH, swLabel,
                (g_tt_swingMode > 0) ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnSWNG", OBJPROP_TOOLTIP,
      "SWING HIGH / LOW DOTS\n"
      "Plots a dot on every M15 bar at the current\n"
      "swingHigh and swingLow levels.\n"
      "Dot color = last thrust line color:\n"
      "  Green = continuation BOS confirmed\n"
      "  Maroon = CHoCH (reversal) confirmed\n"
      "  Olive = no BOS yet (pending)\n"
      "Shows how the swing structure evolved over time.");
   CreateBgRect("RM_AB_SWNG",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_SWNGL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_SWNG", OBJPROP_TOOLTIP, "Auto: Swing dots draw per M15 bar");
   ObjectSetString(0, "RM_AB_SWNGL", OBJPROP_TOOLTIP, "Auto: Swing dots draw per M15 bar");
   cy += tpBtnH + tpGap;

   CreateButton("RM_BtnVSTR", btnX, cy, tpBtnW, tpBtnH, "VS.TR",
                g_tt_vsActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnVSTR", OBJPROP_TOOLTIP,
      "VS TREND (MEASURED MOVE)\n"
      "Red extending line showing a measured-move\n"
      "target. Active only when close breaks a swing\n"
      "level in the direction of flow.\n"
      "Bullish: close > swingHigh -> target = close +\n"
      "(close - swingLow). Bearish: close < swingLow\n"
      "-> target = close - (swingHigh - close).\n"
      "Disappears when conditions are no longer met.");
   CreateBgRect("RM_AB_VSTR",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_VSTRL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_VSTR", OBJPROP_TOOLTIP, "Auto: VS line updates per M15 bar");
   ObjectSetString(0, "RM_AB_VSTRL", OBJPROP_TOOLTIP, "Auto: VS line updates per M15 bar");
   cy += tpBtnH + tpGap;

   string fvLabel = (g_tt_fvMode == 0) ? "FV" : (g_tt_fvMode == 1) ? "FV\x25CB" : "FV\x25CF";
   CreateButton("RM_BtnFVAL", btnX, cy, tpBtnW, tpBtnH, fvLabel,
                (g_tt_fvMode > 0) ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnFVAL", OBJPROP_TOOLTIP,
      "FAIR VALUE ZONES\n"
      "Fills rectangles between swingHigh and swingLow\n"
      "for each segment where levels stay constant.\n"
      "Light forest green, drawn behind all other objects.\n"
      "Shows the 'fair value' channel the market is\n"
      "trading within between thrust structure changes.");
   CreateBgRect("RM_AB_FVAL",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_FVALL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_FVAL", OBJPROP_TOOLTIP, "Auto: FV zones draw per M15 bar");
   ObjectSetString(0, "RM_AB_FVALL", OBJPROP_TOOLTIP, "Auto: FV zones draw per M15 bar");
   cy += tpBtnH + tpGap;

   string fvgLabel = (g_tt_fvgMode == 0) ? "FVG" : (g_tt_fvgMode == 1) ? "FVG\x25CB" : "FVG\x25CF";
   CreateButton("RM_BtnFVGP", btnX, cy, tpBtnW, tpBtnH, fvgLabel,
                (g_tt_fvgMode > 0) ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnFVGP", OBJPROP_TOOLTIP,
      "FAIR VALUE GAP\n"
      "When price breaks out of a swing H/L range and\n"
      "forms a new FV zone that doesn't touch the old\n"
      "one, the gap between them is the FVG.\n"
      "Drawn as faint amber rectangles extending right\n"
      "until price fills the gap (closes inside it),\n"
      "or to current time if still unfilled.");
   CreateBgRect("RM_AB_FVGP",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_FVGPL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_FVGP", OBJPROP_TOOLTIP, "Auto: FVG zones draw per M15 bar");
   ObjectSetString(0, "RM_AB_FVGPL", OBJPROP_TOOLTIP, "Auto: FVG zones draw per M15 bar");
   cy += tpBtnH + tpGap;

   CreateButton("RM_BtnBOSC", btnX, cy, tpBtnW, tpBtnH, "BOS#",
                g_tt_bosCountActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnBOSC", OBJPROP_TOOLTIP,
      "BOS COUNT\n"
      "Labels each continuation BOS with a sequential\n"
      "number. Count resets to 0 when a CHoCH occurs.\n"
      "Numbers appear above swing high BOS levels and\n"
      "below swing low BOS levels.\n"
      "Requires thrust computation (THRS) to be active.");
   CreateBgRect("RM_AB_BOSC",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_BOSCL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_BOSC", OBJPROP_TOOLTIP, "Auto: BOS count labels per M15 bar");
   ObjectSetString(0, "RM_AB_BOSCL", OBJPROP_TOOLTIP, "Auto: BOS count labels per M15 bar");
   cy += tpBtnH + tpGap;

   CreateButton("RM_BtnSRET", btnX, cy, tpBtnW, tpBtnH, "S.RT",
                g_tt_sretActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnSRET", OBJPROP_TOOLTIP,
      "SWING RETRACEMENT\n"
      "Dashed line at the 67% retracement of the\n"
      "move since the last BOS/CHOCH.\n"
      "Bullish: 67% retrace from highest high toward\n"
      "BOS swing low (SL level).\n"
      "Bearish: 67% retrace from lowest low toward\n"
      "BOS swing high (SL level).");
   CreateBgRect("RM_AB_SRET",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_SRETL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_SRET", OBJPROP_TOOLTIP, "Auto: S.RT line updates per M15 bar");
   ObjectSetString(0, "RM_AB_SRETL", OBJPROP_TOOLTIP, "Auto: S.RT line updates per M15 bar");
   cy += tpBtnH + tpGap;

   CreateButton("RM_BtnDRNG", btnX, cy, tpBtnW, tpBtnH, "D.RNG",
                g_tt_drangeActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnDRNG", OBJPROP_TOOLTIP,
      "DEALING RANGE PROJECTION\n"
      "Projects the last swing high and swing low\n"
      "6 candles into the future, in the same color\n"
      "as the active swing structure (olive / green / maroon).\n"
      "\n"
      "Label = dealing range %:\n"
      "  (swing high - swing low) / (prev daily high - prev daily low)\n"
      "\n"
      "Label position:\n"
      "  Uptrend -> below the swing low\n"
      "  Downtrend -> above the swing high");
   CreateBgRect("RM_AB_DRNG",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_DRNGL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_DRNG", OBJPROP_TOOLTIP, "Auto: D.RNG lines update per M15 bar");
   ObjectSetString(0, "RM_AB_DRNGL", OBJPROP_TOOLTIP, "Auto: D.RNG lines update per M15 bar");
   cy += tpBtnH + tpGap;

   CreateButton("RM_BtnH4TH", btnX, cy, tpBtnW, tpBtnH, "H4",
                g_h4_active ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnH4TH", OBJPROP_TOOLTIP,
      "H4 THRUST STRUCTURE\n"
      "Same thrust algorithm running on H1 bars\n"
      "with a 4-bar lookback to capture H4 swings.\n"
      "BOS lines are thicker and longer than M15.\n"
      "Green = continuation, Maroon = CHoCH,\n"
      "Olive = pending (no BOS yet).");
   CreateBgRect("RM_AB_H4TH",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
   CreateLabel("RM_AB_H4THL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
   ObjectSetString(0, "RM_AB_H4TH", OBJPROP_TOOLTIP, "Auto: H4 thrust lines update per H1 bar");
   ObjectSetString(0, "RM_AB_H4THL", OBJPROP_TOOLTIP, "Auto: H4 thrust lines update per H1 bar");
   cy += tpBtnH + tpGap;

   {
      string h4fLabel = (g_h4_tFlow == 1) ? "H4.F\x25B2" : "H4.F\x25BC";
      CreateButton("RM_BtnH4FC", btnX, cy, tpBtnW, tpBtnH, h4fLabel,
                   g_h4_flowActive ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
      ObjectSetString(0, "RM_BtnH4FC", OBJPROP_TOOLTIP,
         "H4 FLOW LINE\n"
         "Extending line showing the current H4 flow\n"
         "level (computed from H1 bars).\n"
         "When H4 tFlow=Up, tracks lowest low of\n"
         "the last 4 H1 bars. When tFlow=Down,\n"
         "tracks highest high of the last 4 H1 bars.\n"
         "Arrow shows current H4 flow direction.");
      CreateBgRect("RM_AB_H4FC",  btnX + tpBtnW - abSz, cy, abSz, abSz, C'45,47,62', C'45,47,62');
      CreateLabel("RM_AB_H4FCL", btnX + tpBtnW - abSz + 2, cy - 1, "A", C'120,118,130', 7);
      ObjectSetString(0, "RM_AB_H4FC", OBJPROP_TOOLTIP, "Auto: H4 flow line updates per H1 bar");
      ObjectSetString(0, "RM_AB_H4FCL", OBJPROP_TOOLTIP, "Auto: H4 flow line updates per H1 bar");
   }
   cy += tpBtnH + tpGap;

   // Placeholder buttons for the rest of the column
   for(int i = 0; cy + tpBtnH <= topY + totalH - tpPad; i++)
   {
      string name = "RM_TP_" + IntegerToString(i);
      CreateButton(name, btnX, cy, tpBtnW, tpBtnH, "\x2014",
                   CLR_BTN_PLC, CLR_TEXT_DIM, FONT_SIZE);
      cy += tpBtnH + tpGap;
   }
}

//+------------------------------------------------------------------+
//| Build the alerts panel (Discord Alerts)                          |
//+------------------------------------------------------------------+
void BuildAlertsPanel(int leftEdge, int topY, int totalH)
{
   int apPad  = 8;
   int apBtnW = 60;
   int apBtnH = 46;
   int apGap  = 6;
   int apW    = apBtnW + 2 * apPad;
   int apX    = leftEdge + 8;

   CreateBgRect("RM_APFrame", apX - 3, topY - 3, apW + 6, totalH + 6,
                CLR_BORDER_GOLD, CLR_BORDER_GOLD);
   CreateBgRect("RM_APBG", apX, topY, apW, totalH, CLR_PANEL_BG, CLR_PANEL_BG);
   ObjectSetString(0, "RM_APBG", OBJPROP_TOOLTIP, "Alerts");

   int btnX = apX + apPad;
   int cy   = topY + apPad;

   CreateButton("RM_BtnAltTEST", btnX, cy, apBtnW, apBtnH, "TEST",
                CLR_BTN_WARN, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnAltTEST", OBJPROP_TOOLTIP,
      "TEST ALERT\n"
      "Sends a test Discord message and speaks\n"
      "a random phrase via text-to-speech.\n"
      "Use this to verify your webhook URL\n"
      "and TTS are working correctly.");
   cy += apBtnH + apGap;

   CreateButton("RM_BtnAltSBRK", btnX, cy, apBtnW, apBtnH, "S.BRK",
                g_alertSBRK ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnAltSBRK", OBJPROP_TOOLTIP,
      "S.BRK ALERT (Discord)\n"
      "Sends a Discord webhook alert when a new\n"
      "candle breaks a D.LVL (daily level).\n"
      "Monitors the active up-close low (support)\n"
      "and down-close high (resistance) levels.\n"
      "One alert per level â€” won't spam.\n"
      "Requires webhook URL in EA input settings.");
   cy += apBtnH + apGap;

   CreateButton("RM_BtnAltCHCH", btnX, cy, apBtnW, apBtnH, "CHCH",
                g_alertCHCH ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnAltCHCH", OBJPROP_TOOLTIP,
      "CHCH ALERT (Discord)\n"
      "Sends a Discord webhook alert when price\n"
      "breaks a Swing Low in an uptrend (bearish CHCH)\n"
      "or a Swing High in a downtrend (bullish CHCH).\n"
      "One alert per swing level â€” won't spam.\n"
      "Requires thrust computation to be running.");
   cy += apBtnH + apGap;

   CreateButton("RM_BtnAltDSTK", btnX, cy, apBtnW, apBtnH, "DSTK",
                g_alertDSTK ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnAltDSTK", OBJPROP_TOOLTIP,
      "D.STK ZONE ALERT (Discord)\n"
      "Sends a Discord alert when a candle\n"
      "enters a stalk zone for the first time\n"
      "that day. Max 2 alerts per day (upper+lower).\n"
      "Zones: 100-125/25-33 (bull) or 75-66/0 to -25 (bear).");
   cy += apBtnH + apGap;

   CreateButton("RM_BtnAltD150", btnX, cy, apBtnW, apBtnH, "150",
                g_alertD150 ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnAltD150", OBJPROP_TOOLTIP,
      "150/-50 LEVEL ALERT (Discord)\n"
      "Sends a Discord alert when price reaches\n"
      "the 150% or -50% level for the first time\n"
      "that day. Max 2 alerts per day.");
   cy += apBtnH + apGap;

   CreateButton("RM_BtnAltH4FC", btnX, cy, apBtnW, apBtnH, "H4FC",
                g_alertH4FC ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnAltH4FC", OBJPROP_TOOLTIP,
      "H4 FLOW CHANGE ALERT (Discord)\n"
      "Sends a Discord alert when the H4 flow\n"
      "direction changes (computed from H1 bars).\n"
      "One alert per flow change.\n"
      "ON by default.");
   cy += apBtnH + apGap;

   CreateButton("RM_BtnAltCTR", btnX, cy, apBtnW, apBtnH, CtrBtnLabel(),
                g_alertCTR ? CLR_BTN_ON : CLR_BTN_OFF, CLR_TEXT, FONT_SIZE);
   ObjectSetString(0, "RM_BtnAltCTR", OBJPROP_TOOLTIP,
      "CTREND x5  —  Close-Trend Change Alert (Discord)\n"
      "\n"
      "Watches the 5-minute close-trend (ctrend) and sends a\n"
      "Discord TTS alert each time it flips up<->down.\n"
      "\n"
      "The triangle shows the current M5 trend direction:\n"
      "  C.TR\x25B2m5 = uptrend,  C.TR\x25BCm5 = downtrend.\n"
      "Works on ANY chart timeframe (reads M5 data directly).\n"
      "\n"
      "Uptrend holds until close < last buy-pattern's down-candle\n"
      "close; downtrend holds until close > last sell-pattern's\n"
      "up-candle close. Click to toggle the alert. ON by default.");
   cy += apBtnH + apGap;

   // Placeholder buttons for the rest of the column
   for(int i = 0; cy + apBtnH <= topY + totalH - apPad; i++)
   {
      string name = "RM_AP_" + IntegerToString(i);
      CreateButton(name, btnX, cy, apBtnW, apBtnH, "\x2014",
                   CLR_BTN_PLC, CLR_TEXT_DIM, FONT_SIZE);
      cy += apBtnH + apGap;
   }
}

//+==================================================================+
//|                  CLOSE TREND (ctrend) ENGINE                     |
//|------------------------------------------------------------------|
//| Ported from the Pine `ctrend(tf)` function. A candle-close       |
//| pattern trend tracker, evaluated per CLOSED bar of a timeframe.   |
//|                                                                  |
//| Concept:                                                         |
//|  - Continuously records the OHLC of the most recent up candle    |
//|    and most recent down candle on the target timeframe.          |
//|  - A BUY pattern forms when a candle CLOSES above the last down  |
//|    candle's OPEN  -> snapshots that down candle (last_dn_pattern*)|
//|    and sets flow = 1.                                            |
//|  - A SELL pattern forms when a candle CLOSES below the last up   |
//|    candle's OPEN  -> snapshots that up candle (last_up_pattern*)  |
//|    and sets flow = 2.                                            |
//|  - cstrend (1 = up, 2 = down) flips:                             |
//|       down when close < last_dn_pattern_c (buy-pattern's down    |
//|            candle close), up when close > last_up_pattern_c.      |
//|  - candlestate (0-4) classifies the current candle for tooling.  |
//|                                                                  |
//| Each timeframe you want to track needs its own CTrendState.      |
//| Call CTrendUpdate(tf, state, backfillBars) periodically; it      |
//| backfills history on first call, then processes new closed bars  |
//| incrementally. Read state.cstrend / .flow / .candlestate after.  |
//+==================================================================+
struct CTrendState
{
   bool     initialized;
   datetime lastClosedBarTime;       // time of the last closed bar processed

   datetime lastFlipBarTime;         // open time of the bar that caused the last trend flip
   double   lastFlipHigh;            // that bar's high  (for the marker rectangle)
   double   lastFlipLow;             // that bar's low

   int      cstrend;                 // 1 = up, 2 = down
   int      flow;                    // 0 none, 1 buy pattern, 2 sell pattern
   int      candlestate;             // 0-4 classification

   int      check4_dnpattern;
   int      check4_uppattern;

   // last down candle + its running protective low
   double   last_dn_o, last_dn_c, last_dn_h, last_dn_l, last_dn_sl;
   // snapshot of the down candle when a buy pattern formed
   double   last_dn_pattern_o, last_dn_pattern_c, last_dn_pattern_h,
            last_dn_pattern_l, last_dn_pattern_sl, last_dn_pattern_range;

   // last up candle + its running protective high
   double   last_up_o, last_up_c, last_up_h, last_up_l, last_up_sl;
   // snapshot of the up candle when a sell pattern formed
   double   last_up_pattern_o, last_up_pattern_c, last_up_pattern_h,
            last_up_pattern_l, last_up_pattern_sl, last_up_pattern_range;
};

void CTrendInit(CTrendState &s)
{
   s.initialized        = true;
   s.lastClosedBarTime  = 0;
   s.lastFlipBarTime    = 0;
   s.lastFlipHigh       = 0;
   s.lastFlipLow        = 0;
   s.cstrend            = 1;          // initialize as uptrend (matches Pine)
   s.flow               = 0;
   s.candlestate        = 0;
   s.check4_dnpattern   = 1;
   s.check4_uppattern   = 1;
   s.last_dn_o = 0; s.last_dn_c = 0; s.last_dn_h = 0; s.last_dn_l = 0; s.last_dn_sl = 0;
   s.last_dn_pattern_o = 999999999.0; s.last_dn_pattern_c = 0; s.last_dn_pattern_h = 0;
   s.last_dn_pattern_l = 0; s.last_dn_pattern_sl = 0; s.last_dn_pattern_range = 0;
   s.last_up_o = 0; s.last_up_c = 0; s.last_up_h = 0; s.last_up_l = 0; s.last_up_sl = 0;
   s.last_up_pattern_o = 0; s.last_up_pattern_c = 0; s.last_up_pattern_h = 0;
   s.last_up_pattern_l = 0; s.last_up_pattern_sl = 0; s.last_up_pattern_range = 0;
}

// Process exactly one closed candle (mirrors the body of the Pine ctrend()).
void CTrendProcessBar(CTrendState &s, double openx, double highx, double lowx, double closex)
{
   bool dncandlex = (openx > closex);
   bool upcandlex = (closex > openx);

   // 1) Record OHLC of the last up / down candle
   if(dncandlex)
   {
      s.last_dn_o = openx;
      s.last_dn_c = closex;
      s.last_dn_h = highx;
      s.last_dn_l = lowx;
      s.last_dn_sl = lowx;
      s.last_up_sl = (highx > s.last_up_sl) ? highx : s.last_up_sl;
      s.check4_dnpattern = 1;
   }
   else if(upcandlex)
   {
      s.last_up_o = openx;
      s.last_up_c = closex;
      s.last_up_h = highx;
      s.last_up_l = lowx;
      s.last_up_sl = highx;
      s.last_dn_sl = (lowx < s.last_dn_sl) ? lowx : s.last_dn_sl;
      s.check4_uppattern = 1;
   }

   // 2) Patterns found
   if(s.check4_dnpattern == 1 && closex > s.last_dn_o)
   {
      s.last_dn_pattern_o     = s.last_dn_o;
      s.last_dn_pattern_c     = s.last_dn_c;
      s.last_dn_pattern_h     = s.last_dn_h;
      s.last_dn_pattern_l     = s.last_dn_l;
      s.last_dn_pattern_sl    = s.last_dn_sl;
      s.last_dn_pattern_range = s.last_dn_o - s.last_dn_sl;
      s.flow = 1;
   }
   else if(s.check4_uppattern == 1 && closex < s.last_up_o)
   {
      s.last_up_pattern_o     = s.last_up_o;
      s.last_up_pattern_c     = s.last_up_c;
      s.last_up_pattern_h     = s.last_up_h;
      s.last_up_pattern_l     = s.last_up_l;
      s.last_up_pattern_sl    = s.last_up_sl;
      s.last_up_pattern_range = s.last_up_sl - s.last_up_o;
      s.flow = 2;
   }

   // 3) Candlestate classification
   if(s.cstrend == 1)
   {
      if(closex < s.last_dn_pattern_c)                              s.candlestate = 4;
      else if(s.check4_dnpattern == 1 && closex > s.last_dn_o)      s.candlestate = 1;
      else if(upcandlex)                                           s.candlestate = 2;
      else if(dncandlex)                                           s.candlestate = 3;
   }
   if(s.cstrend == 2)
   {
      if(closex > s.last_up_pattern_c)                              s.candlestate = 4;
      else if(s.check4_uppattern == 1 && closex < s.last_up_o)      s.candlestate = 1;
      else if(upcandlex)                                           s.candlestate = 3;
      else if(dncandlex)                                           s.candlestate = 2;
   }

   // 4) Reset the pattern-watch flags once price has cleared the reference open
   if(closex > s.last_dn_o)        s.check4_dnpattern = 0;
   else if(closex < s.last_up_o)   s.check4_uppattern = 0;

   // 5) Trend change
   if(s.cstrend == 1 && closex < s.last_dn_pattern_c)       s.cstrend = 2;   // downtrend started
   else if(s.cstrend == 2 && closex > s.last_up_pattern_c)  s.cstrend = 1;   // uptrend started
}

//+------------------------------------------------------------------+
//| Paint a filled red rectangle over one M5 candle (works on any    |
//| chart timeframe). De-dupes by bar time.                          |
//+------------------------------------------------------------------+
void DrawCTrendFlipMarker(datetime barTime, double bh, double bl)
{
   if(barTime <= 0 || bh <= bl) return;
   string nm = "RM_CTRflip_" + IntegerToString((long)barTime);
   if(ObjectFind(0, nm) >= 0) return;              // already marked
   // Center the zone on the candle (a candle is drawn centered on its time
   // slot, so span half a bar each side of the bar's open time).
   int half = (int)(PeriodSeconds(PERIOD_M5) / 2);
   datetime t1 = barTime - half;
   datetime t2 = barTime + half;
   ObjectCreate(0, nm, OBJ_RECTANGLE, 0, t1, bh, t2, bl);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, C'160,75,75'); // lightened maroon -> reads translucent
   ObjectSetInteger(0, nm, OBJPROP_FILL, true);          // solid zone fill
   ObjectSetInteger(0, nm, OBJPROP_BACK, true);          // behind candles -> candle shows on top
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);            // no distinct border (same color as fill)
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_ZORDER, 0);
}

// Drive a CTrendState off a timeframe's closed bars. Backfills on first call.
// markFlipsFrom > 0 paints a red marker on every flip candle at/after that
// time (used by the M5 alert to backfill the last few days + mark live flips).
void CTrendUpdate(ENUM_TIMEFRAMES tf, CTrendState &s, int backfillBars, datetime markFlipsFrom = 0)
{
   datetime lastClosed = iTime(_Symbol, tf, 1);   // most recent CLOSED bar
   if(lastClosed <= 0) return;                     // history not ready yet

   if(!s.initialized)
   {
      CTrendInit(s);
      int avail = iBars(_Symbol, tf) - 1;          // exclude the forming bar 0
      int n = (backfillBars < avail) ? backfillBars : avail;
      for(int i = n; i >= 1; i--)                  // oldest (high shift) -> newest (shift 1)
      {
         int before = s.cstrend;
         double bh = iHigh(_Symbol,tf,i), bl = iLow(_Symbol,tf,i);
         CTrendProcessBar(s, iOpen(_Symbol,tf,i), bh, bl, iClose(_Symbol,tf,i));
         if(s.cstrend != before)
         {
            datetime ft = iTime(_Symbol,tf,i);
            s.lastFlipBarTime = ft; s.lastFlipHigh = bh; s.lastFlipLow = bl;
            if(markFlipsFrom > 0 && ft >= markFlipsFrom) DrawCTrendFlipMarker(ft, bh, bl);
         }
      }
      s.lastClosedBarTime = lastClosed;
      return;
   }

   if(lastClosed <= s.lastClosedBarTime) return;   // no new closed bar

   int prevShift = iBarShift(_Symbol, tf, s.lastClosedBarTime, false);
   if(prevShift < 1) prevShift = 1;
   for(int i = prevShift - 1; i >= 1; i--)         // process newly-closed bars in order
   {
      int before = s.cstrend;
      double bh = iHigh(_Symbol,tf,i), bl = iLow(_Symbol,tf,i);
      CTrendProcessBar(s, iOpen(_Symbol,tf,i), bh, bl, iClose(_Symbol,tf,i));
      if(s.cstrend != before)
      {
         datetime ft = iTime(_Symbol,tf,i);
         s.lastFlipBarTime = ft; s.lastFlipHigh = bh; s.lastFlipLow = bl;
         if(markFlipsFrom > 0 && ft >= markFlipsFrom) DrawCTrendFlipMarker(ft, bh, bl);
      }
   }
   s.lastClosedBarTime = lastClosed;
}

// ── Live ctrend states (one per timeframe we care about) ──
CTrendState g_ctrM5;     // 5-minute close-trend (drives the C.TR Discord alert)

// Alerts-panel button label with a live direction triangle (▲ up / ▼ down),
// matching the TREND / H4.F button style. "m5" tags the timeframe watched.
string CtrBtnLabel() { return (g_ctrM5.cstrend == 2) ? "C.TR\x25BCm5" : "C.TR\x25B2m5"; }

//+------------------------------------------------------------------+
//| 5-minute close-trend change alert (Discord TTS)                  |
//+------------------------------------------------------------------+
void CheckCTrendAlert()
{
   // Mark flip candles only when the alert is on; cap historical markers to
   // the last CTREND_MARK_DAYS. (Markers for live flips also flow through here.)
   datetime markCutoff = g_alertCTR ? (TimeCurrent() - CTREND_MARK_DAYS * 86400) : 0;

   // Keep the M5 state current even when the alert is off, so future
   // buttons can read g_ctrM5 without a cold start.
   CTrendUpdate(PERIOD_M5, g_ctrM5, 2000, markCutoff);

   // Keep the button's direction triangle live regardless of alert on/off.
   string want = CtrBtnLabel();
   if(ObjectGetString(0, "RM_BtnAltCTR", OBJPROP_TEXT) != want)
      ObjectSetString(0, "RM_BtnAltCTR", OBJPROP_TEXT, want);

   if(!g_alertCTR) { g_alert_ctrLastTrend = g_ctrM5.cstrend; return; }

   int t = g_ctrM5.cstrend;
   if(g_alert_ctrLastTrend == 0) { g_alert_ctrLastTrend = t; return; }  // baseline, no alert
   if(t != g_alert_ctrLastTrend)
   {
      // up emoji / down emoji + spoken text
      string emoji = (t == 1) ? "\xF0\x9F\x93\x88" : "\xF0\x9F\x93\x89";   // 📈 / 📉
      string dir   = (t == 1) ? "uptrend" : "downtrend";
      SendDiscordAlert(AlertMsg(emoji, "C.TREND", "5 minute close-trend flipped to " + dir));
      // (the triggering candle is painted red inside CTrendUpdate above)
      g_alert_ctrLastTrend = t;
   }
}

//+------------------------------------------------------------------+
//| Standard alert-message format — one place defines how every      |
//| Discord/TTS alert reads:                                         |
//|     "<emoji> <TAG> | <Spoken Symbol> | <event>"                  |
//| Deliberately carries NO raw price levels, so the spoken alert    |
//| stays short and clean (e.g. "S.BRK EURUSD broke above daily      |
//| level" instead of reading out 1.07423).                          |
//+------------------------------------------------------------------+
string AlertMsg(string emoji, string tag, string body)
{
   return emoji + " " + tag + " | " + SpokenSymbol() + " | " + body;
}

//+------------------------------------------------------------------+
//| Send a message via Discord webhook (with TTS)                    |
//+------------------------------------------------------------------+
void SendDiscordAlert(string message)
{
   if(InpDiscordWebhook == "") return;

   string headers = "Content-Type: application/json\r\n";
   // Escape any quotes inside message
   StringReplace(message, "\"", "\\\"");
   string body = "{\"username\":\"RiskManager\",\"tts\":true,\"content\":\"" + message + "\"}";

   char bodyData[];
   StringToCharArray(body, bodyData, 0, StringLen(body), CP_UTF8);

   char result[];
   string resultHeaders;
   int res = WebRequest("POST", InpDiscordWebhook, headers, 5000, bodyData, result, resultHeaders);
   if(res != 200 && res != 204)
      Print("Discord webhook failed: HTTP ", res);
}

//+------------------------------------------------------------------+
//| Compute the active D.LVL levels for alert monitoring             |
//+------------------------------------------------------------------+
void ComputeAlertDLVLLevels()
{
   MqlRates daily[];
   ArraySetAsSeries(daily, false);
   int copied = CopyRates(_Symbol, PERIOD_D1, 0, 93, daily);
   if(copied < 2) return;

   datetime lastDayEnd = daily[copied - 1].time + PeriodSeconds(PERIOD_D1);
   bool lastForming = (TimeCurrent() < lastDayEnd);
   int closedCount = lastForming ? copied - 1 : copied;

   double prevUpLow    = g_alert_activeUpLow;
   double prevDnHigh   = g_alert_activeDownHigh;

   double activeUpLow = 0, activeDownHigh = 0;

   for(int d = 0; d < closedCount; d++)
   {
      datetime dayEnd = (d < copied - 1) ? daily[d + 1].time
                                          : (datetime)(daily[d].time + PeriodSeconds(PERIOD_D1));

      // Check if active levels are breached during this day
      if(activeDownHigh > 0 && daily[d].high > activeDownHigh)
         activeDownHigh = 0;
      if(activeUpLow > 0 && daily[d].low < activeUpLow)
         activeUpLow = 0;

      // This closed candle sets the tracked level
      bool isUp = (daily[d].close >= daily[d].open);
      if(isUp)
      {
         activeUpLow = daily[d].low;
      }
      else
      {
         activeDownHigh = daily[d].high;
      }
   }

   // Check if active levels are already breached in the forming period
   bool upAlerted = false, dnAlerted = false;
   if(activeDownHigh > 0 || activeUpLow > 0)
   {
      datetime formStart = daily[closedCount > 0 ? closedCount - 1 : 0].time + PeriodSeconds(PERIOD_D1);
      if(closedCount < copied) formStart = daily[closedCount].time;
      MqlRates curBars[];
      ArraySetAsSeries(curBars, false);
      int cc = CopyRates(_Symbol, PERIOD_CURRENT, formStart, TimeCurrent() + 1, curBars);
      if(cc > 1) // exclude the very last (forming) bar â€” only check closed bars
      {
         for(int i = 0; i < cc - 1; i++)
         {
            if(activeDownHigh > 0 && curBars[i].high > activeDownHigh) dnAlerted = true;
            if(activeUpLow > 0 && curBars[i].low < activeUpLow)       upAlerted = true;
         }
      }
   }

   g_alert_activeUpLow    = activeUpLow;
   g_alert_activeDownHigh = activeDownHigh;

   // Reset alerted flags if the level itself changed (new daily candle)
   if(activeUpLow != prevUpLow)     g_alert_upLowAlerted = upAlerted;
   if(activeDownHigh != prevDnHigh) g_alert_dnHighAlerted = dnAlerted;
}

//+------------------------------------------------------------------+
//| Update alert levels periodically (called from OnTimer)           |
//+------------------------------------------------------------------+
void UpdateAlertLevels()
{
   if(!g_alertSBRK) return;
   static datetime lastDaily = 0;
   datetime curDaily = iTime(_Symbol, PERIOD_D1, 0);
   if(curDaily != lastDaily)
   {
      lastDaily = curDaily;
      ComputeAlertDLVLLevels();
   }
}

//+------------------------------------------------------------------+
//| Get TTS-friendly symbol name (strip .sim, map to spoken name)    |
//+------------------------------------------------------------------+
string SpokenSymbol()
{
   string sym = _Symbol;
   StringToUpper(sym);
   // Strip broker suffixes like .sim, .pro, etc.
   int dot = StringFind(sym, ".");
   if(dot > 0) sym = StringSubstr(sym, 0, dot);

   if(StringFind(sym, "EURUSD") >= 0) return "Euro";
   if(StringFind(sym, "GBPUSD") >= 0) return "Pound";
   if(StringFind(sym, "GBPJPY") >= 0) return "Pound Yen";
   if(StringFind(sym, "EURJPY") >= 0) return "Euro Yen";
   if(StringFind(sym, "USDJPY") >= 0) return "Dollar Yen";
   if(StringFind(sym, "AUDUSD") >= 0) return "Aussie";
   if(StringFind(sym, "NZDUSD") >= 0) return "Kiwi";
   if(StringFind(sym, "USDCAD") >= 0) return "Dollar Cad";
   if(StringFind(sym, "USDCHF") >= 0) return "Dollar Swiss";
   if(StringFind(sym, "US100")  >= 0) return "Nasdaq";
   if(StringFind(sym, "US500")  >= 0) return "S and P";
   if(StringFind(sym, "US30")   >= 0) return "Dow";
   if(StringFind(sym, "BTC")    >= 0) return "Bitcoin";
   if(StringFind(sym, "ETH")    >= 0) return "Ethereum";
   if(StringFind(sym, "USOIL")  >= 0) return "Oil";
   if(StringFind(sym, "XAU")    >= 0) return "Gold";
   if(StringFind(sym, "XAG")    >= 0) return "Silver";
   return sym;  // fallback: cleaned symbol
}

//+------------------------------------------------------------------+
//| Check if current price breaches D.LVL â€” called from OnTick      |
//+------------------------------------------------------------------+
void CheckSBRKAlert()
{
   if(!g_alertSBRK) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Check resistance break (price > activeDownHigh)
   if(g_alert_activeDownHigh > 0 && !g_alert_dnHighAlerted)
   {
      if(bid > g_alert_activeDownHigh)
      {
         g_alert_dnHighAlerted = true;
         string msg = AlertMsg("\xF0\x9F\x94\xB4", "S.BRK", "broke above daily level");
         SendDiscordAlert(msg);
         Print(msg);
      }
   }

   // Check support break (price < activeUpLow)
   if(g_alert_activeUpLow > 0 && !g_alert_upLowAlerted)
   {
      if(bid < g_alert_activeUpLow)
      {
         g_alert_upLowAlerted = true;
         string msg = AlertMsg("\xF0\x9F\x94\xB4", "S.BRK", "broke below daily level");
         SendDiscordAlert(msg);
         Print(msg);
      }
   }
}

//+------------------------------------------------------------------+
//| Toggle S.BRK alert                                               |
//+------------------------------------------------------------------+
void ToggleAlertSBRK()
{
   g_alertSBRK = !g_alertSBRK;
   if(g_alertSBRK)
      ComputeAlertDLVLLevels();
   ObjectSetInteger(0, "RM_BtnAltSBRK", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltSBRK"));
}

//+------------------------------------------------------------------+
//| Toggle CHCH alert                                                |
//+------------------------------------------------------------------+
void ToggleAlertCHCH()
{
   g_alertCHCH = !g_alertCHCH;
   if(g_alertCHCH)
   {
      g_alert_chchAlerted = false;
      // Snapshot the current pivot TIME so we only re-arm when a NEW swing forms.
      // Dedup on time (not price) — swingLow/swingHigh values can shift tick-to-tick
      // when bar 0 acts as the pivot during a fast move, which used to spam alerts.
      if(g_tt_tTrend == 1)
         g_alert_chchTime = g_tt_swingLowTime;
      else
         g_alert_chchTime = g_tt_swingHighTime;
   }
   ObjectSetInteger(0, "RM_BtnAltCHCH", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltCHCH"));
}

//+------------------------------------------------------------------+
//| Check for CHCH alert â€” break of swing in opposing direction      |
//+------------------------------------------------------------------+
void CheckCHCHAlert()
{
   if(!g_alertCHCH) return;
   if(g_tt_swingHigh == 0 || g_tt_swingLow == 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Uptrend: CHCH = price breaks below swingLow.
   // Dedup on swingLowTime (pivot's bar-open time) so we re-arm only when a NEW
   // pivot actually forms. The PRICE g_tt_swingLow can shift tick-to-tick when
   // bar 0 is the active pivot during a fast move (ComputeThrust re-runs on
   // every breach tick and re-derives swingLow from bar 0's intra-bar low),
   // which previously made the dedup useless and produced repeat alerts.
   if(g_tt_tTrend == 1)
   {
      if(g_alert_chchTime != g_tt_swingLowTime)
      {
         g_alert_chchTime = g_tt_swingLowTime;
         g_alert_chchAlerted = false;
      }
      if(!g_alert_chchAlerted && bid < g_tt_swingLow)
      {
         g_alert_chchAlerted = true;
         string msg = AlertMsg("\xF0\x9F\x94\xBB", "CHCH", "broke below swing low, bearish reversal");
         SendDiscordAlert(msg);
         Print(msg);
      }
   }
   // Downtrend: CHCH = price breaks above swingHigh
   else if(g_tt_tTrend == 2)
   {
      if(g_alert_chchTime != g_tt_swingHighTime)
      {
         g_alert_chchTime = g_tt_swingHighTime;
         g_alert_chchAlerted = false;
      }
      if(!g_alert_chchAlerted && bid > g_tt_swingHigh)
      {
         g_alert_chchAlerted = true;
         string msg = AlertMsg("\xF0\x9F\x94\xBA", "CHCH", "broke above swing high, bullish reversal");
         SendDiscordAlert(msg);
         Print(msg);
      }
   }
}

//+------------------------------------------------------------------+
//| Toggle D.STK zone alert                                          |
//+------------------------------------------------------------------+
void ToggleAlertDSTK()
{
   g_alertDSTK = !g_alertDSTK;
   if(g_alertDSTK)
   {
      g_alert_dstkUpperAlerted = false;
      g_alert_dstkLowerAlerted = false;
      g_alert_dstkDay = -1;
   }
   ObjectSetInteger(0, "RM_BtnAltDSTK", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltDSTK"));
}

//+------------------------------------------------------------------+
//| Toggle 150/-50 level alert                                       |
//+------------------------------------------------------------------+
void ToggleAlertD150()
{
   g_alertD150 = !g_alertD150;
   if(g_alertD150)
   {
      g_alert_d150UpperAlerted = false;
      g_alert_d150LowerAlerted = false;
      g_alert_d150Day = -1;
   }
   ObjectSetInteger(0, "RM_BtnAltD150", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltD150"));
}

//+------------------------------------------------------------------+
//| Check D.STK zone alert â€" first candle entering zone each day     |
//+------------------------------------------------------------------+
void CheckDSTKAlert()
{
   if(!g_alertDSTK) return;

   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   if(CopyRates(_Symbol, PERIOD_D1, 0, 2, daily) < 2) return;

   double refH  = daily[1].high;
   double refL  = daily[1].low;
   double range = refH - refL;
   if(range <= 0) return;

   bool prevBull = (daily[1].close >= daily[1].open);

   double upperTop, upperBot, lowerTop, lowerBot;
   if(prevBull)
   {
      upperTop = refH + range * 0.25;
      upperBot = refH;
      lowerTop = refL + range * 0.33;
      lowerBot = refL + range * 0.25;
   }
   else
   {
      upperTop = refL + range * 0.75;
      upperBot = refL + range * 0.66;
      lowerTop = refL;
      lowerBot = refL - range * 0.25;
   }

   MqlDateTime dt;
   TimeCurrent(dt);
   int today = dt.day_of_year;

   // Reset alerts on new day
   if(today != g_alert_dstkDay)
   {
      g_alert_dstkDay = today;
      g_alert_dstkUpperAlerted = false;
      g_alert_dstkLowerAlerted = false;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(!g_alert_dstkUpperAlerted && bid >= upperBot && bid <= upperTop)
   {
      g_alert_dstkUpperAlerted = true;
      string msg = AlertMsg("\xF0\x9F\x9F\xA1", "D.STK", "entered upper zone");
      SendDiscordAlert(msg);
      Print(msg);
   }

   if(!g_alert_dstkLowerAlerted && bid >= lowerBot && bid <= lowerTop)
   {
      g_alert_dstkLowerAlerted = true;
      string msg = AlertMsg("\xF0\x9F\x9F\xA1", "D.STK", "entered lower zone");
      SendDiscordAlert(msg);
      Print(msg);
   }
}

//+------------------------------------------------------------------+
//| Check 150/-50 level alert â€" first candle reaching level each day |
//+------------------------------------------------------------------+
void CheckD150Alert()
{
   if(!g_alertD150) return;

   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   if(CopyRates(_Symbol, PERIOD_D1, 0, 2, daily) < 2) return;

   double refH  = daily[1].high;
   double refL  = daily[1].low;
   double range = refH - refL;
   if(range <= 0) return;

   double level150 = refH + range * 0.50;   // 150% level
   double levelN50 = refL - range * 0.50;   // -50% level

   MqlDateTime dt;
   TimeCurrent(dt);
   int today = dt.day_of_year;

   if(today != g_alert_d150Day)
   {
      g_alert_d150Day = today;
      g_alert_d150UpperAlerted = false;
      g_alert_d150LowerAlerted = false;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(!g_alert_d150UpperAlerted && bid >= level150)
   {
      g_alert_d150UpperAlerted = true;
      string msg = AlertMsg("\xF0\x9F\x94\xB4", "D.150", "reached 150 percent level");
      SendDiscordAlert(msg);
      Print(msg);
   }

   if(!g_alert_d150LowerAlerted && bid <= levelN50)
   {
      g_alert_d150LowerAlerted = true;
      string msg = AlertMsg("\xF0\x9F\x94\xB5", "D.150", "reached minus 50 percent level");
      SendDiscordAlert(msg);
      Print(msg);
   }
}

//+------------------------------------------------------------------+
//| Test alert â€” sends a random phrase via Discord + TTS             |
//+------------------------------------------------------------------+
void RunAlertTest()
{
   string phrases[] = {
      "Session breaker detected. Price just smashed through resistance like it owes it money.",
      "Alert system online. The market is about to get interesting.",
      "Testing, one, two, three. Your levels are being watched.",
      "Beep boop. I am your trading robot and I see everything.",
      "Heads up. Price is doing that thing again.",
      "Alert confirmed. Time to pay attention to the chart.",
      "The daily level has been violated. Repeat. The daily level has been violated.",
      "This is a test. If this were an actual breakout, you'd be rich by now."
   };
   int idx = (int)(MathRand() % ArraySize(phrases));
   string msg = AlertMsg("\xF0\x9F\x94\x94", "TEST", phrases[idx]);
   SendDiscordAlert(msg);
   Print(msg);
}

//+------------------------------------------------------------------+
bool IsCrypto()
{
   string sym = _Symbol;
   StringToUpper(sym);
   return (StringFind(sym, "BTC") >= 0 || StringFind(sym, "ETH") >= 0);
}

//+------------------------------------------------------------------+
//| Check if a GMT datetime falls within US Daylight Saving Time     |
//| DST: 2nd Sunday March 2 AM â†’ 1st Sunday November 2 AM           |
//+------------------------------------------------------------------+
bool IsUSDST(datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);
   int month = dt.mon;
   if(month < 3 || month > 11) return false;   // Jan,Feb,Dec â†’ EST
   if(month > 3 && month < 11) return true;    // Apr-Oct â†’ EDT
   if(month == 3)
   {
      MqlDateTime m1;
      TimeToStruct(gmtTime, m1);
      m1.day = 1; m1.hour = 0; m1.min = 0; m1.sec = 0;
      datetime mar1 = StructToTime(m1);
      TimeToStruct(mar1, m1);
      int dow1 = m1.day_of_week;
      int firstSun  = (dow1 == 0) ? 1 : (8 - dow1);
      int secondSun = firstSun + 7;
      if(dt.day > secondSun) return true;
      if(dt.day < secondSun) return false;
      return (dt.hour >= 7); // 2 AM EST = 7 AM UTC
   }
   // November: DST ends 1st Sunday
   MqlDateTime n1;
   TimeToStruct(gmtTime, n1);
   n1.day = 1; n1.hour = 0; n1.min = 0; n1.sec = 0;
   datetime nov1 = StructToTime(n1);
   TimeToStruct(nov1, n1);
   int dow1 = n1.day_of_week;
   int firstSun = (dow1 == 0) ? 1 : (8 - dow1);
   if(dt.day > firstSun) return false;
   if(dt.day < firstSun) return true;
   return (dt.hour < 6); // 2 AM EDT = 6 AM UTC
}

//+------------------------------------------------------------------+
//| Derive server GMT offset from daily bar open time                |
//| NY close brokers: daily bar opens at 5 PM ET                     |
//| 5 PM EDT = 21:00 GMT, 5 PM EST = 22:00 GMT                      |
//+------------------------------------------------------------------+
int GetServerGMTOffset()
{
   datetime d1 = iTime(_Symbol, PERIOD_D1, 0);
   if(d1 <= 0) return (int)(TimeCurrent() - TimeGMT());

   MqlDateTime d1dt;
   TimeToStruct(d1, d1dt);

   // Determine US DST from the daily bar's date
   bool isDST;
   int mon = d1dt.mon;
   if(mon > 3 && mon < 11)       isDST = true;
   else if(mon < 3 || mon > 11)  isDST = false;
   else if(mon == 3)
   {
      MqlDateTime tmp;
      TimeToStruct(d1, tmp);
      tmp.day = 1; tmp.hour = 0; tmp.min = 0; tmp.sec = 0;
      datetime mar1 = StructToTime(tmp);
      TimeToStruct(mar1, tmp);
      int firstSun = (tmp.day_of_week == 0) ? 1 : (8 - tmp.day_of_week);
      isDST = (d1dt.day >= firstSun + 7);
   }
   else // November
   {
      MqlDateTime tmp;
      TimeToStruct(d1, tmp);
      tmp.day = 1; tmp.hour = 0; tmp.min = 0; tmp.sec = 0;
      datetime nov1 = StructToTime(tmp);
      TimeToStruct(nov1, tmp);
      int firstSun = (tmp.day_of_week == 0) ? 1 : (8 - tmp.day_of_week);
      isDST = (d1dt.day < firstSun);
   }

   int fivePmGMT = isDST ? 21 : 22;
   int offset = (d1dt.hour - fivePmGMT) * 3600 + d1dt.min * 60;
   if(offset < -12 * 3600) offset += 24 * 3600;
   if(offset > 14 * 3600)  offset -= 24 * 3600;
   return offset;
}

//+------------------------------------------------------------------+
//| Convert EST/EDT hour:minute to server time (DST-aware)           |
//+------------------------------------------------------------------+
datetime ESTToServer(int estHour, int estMinute, int dayOffset = 0)
{
   int srvOff = GetServerGMTOffset();
   datetime gmtNow = TimeCurrent() - srvOff;
   MqlDateTime gmtDt;
   TimeToStruct(gmtNow, gmtDt);
   gmtDt.hour = 0; gmtDt.min = 0; gmtDt.sec = 0;
   datetime gmtMidnight = StructToTime(gmtDt);

   // Approximate target in GMT to check DST for that specific date
   datetime approxGMT = (datetime)(gmtMidnight + (long)(estHour + 5) * 3600
                       + estMinute * 60 + (long)dayOffset * 86400);
   int estToGmt = IsUSDST(approxGMT) ? 4 : 5;  // EDT=+4, EST=+5

   datetime targetGMT = (datetime)(gmtMidnight + (long)(estHour + estToGmt) * 3600
                       + estMinute * 60 + (long)dayOffset * 86400);
   return targetGMT + srvOff;
}

//+------------------------------------------------------------------+
void DrawORRect(string name, datetime t1, datetime t2, double high, double low)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, high, t2, low);
   ObjectSetInteger(0, name, OBJPROP_COLOR, C'180,172,158');
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 10);
}

//+------------------------------------------------------------------+
//| Plot Opening Range rectangles                                    |
//+------------------------------------------------------------------+
void PlotOR()
{
   RemoveOR();
   if(Period() >= PERIOD_D1) return;
   bool crypto = IsCrypto();

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   for(int d = 0; d >= -90; d--)
   {
      // AM Opening Range: 9:30 AM EST M15 candle â†’ extends to 4:00 PM
      datetime amStart = ESTToServer(9, 30, d);
      datetime amEnd   = ESTToServer(16, 0, d);
      int copied = CopyRates(_Symbol, PERIOD_M15, amStart, 1, rates);
      if(copied > 0 && MathAbs((long)(rates[0].time - amStart)) < 900)
      {
         DrawORRect("RM_OR_AM" + IntegerToString(-d), rates[0].time, amEnd,
                    rates[0].high, rates[0].low);
         // M15 Open at 9:30 AM EST - thin black line across AM session
         string moName = "RM_OR_MO" + IntegerToString(-d);
         double m15Open = rates[0].open;
         if(ObjectFind(0, moName) >= 0) ObjectDelete(0, moName);
         ObjectCreate(0, moName, OBJ_TREND, 0, rates[0].time, m15Open, amEnd, m15Open);
         ObjectSetInteger(0, moName, OBJPROP_COLOR, clrBlack);
         ObjectSetInteger(0, moName, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, moName, OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, moName, OBJPROP_RAY_LEFT, false);
         ObjectSetInteger(0, moName, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, moName, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, moName, OBJPROP_BACK, false);
      }

      // PM Opening Range: 7:45 PM (or 8:00 PM crypto) â†’ 9:30 AM next day
      int pmH = crypto ? 20 : 19;
      int pmM = crypto ? 0  : 45;
      datetime pmStart = ESTToServer(pmH, pmM, d);
      datetime pmEnd   = ESTToServer(9, 30, d + 1);
      copied = CopyRates(_Symbol, PERIOD_M15, pmStart, 1, rates);
      if(copied > 0 && MathAbs((long)(rates[0].time - pmStart)) < 900)
         DrawORRect("RM_OR_PM" + IntegerToString(-d), rates[0].time, pmEnd,
                    rates[0].high, rates[0].low);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void RemoveOR()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "RM_OR_") == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleOR()
{
   g_orActive = !g_orActive;
   if(g_orActive)
   {
      PlotOR();
      if(g_sessGapActive) PlotSessionGap();
      if(g_sessBrkActive) PlotSessionBreaker();
   }
   else RemoveOR();
   ObjectSetInteger(0, "RM_BtnOR", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnOR"));
}

//+------------------------------------------------------------------+
void UpdateOR()
{
   if(!g_orActive) return;
   static datetime lastUpd = 0;
   if(TimeCurrent() - lastUpd < 60) return;
   lastUpd = TimeCurrent();
   PlotOR();
   // Re-apply S.GAP and S.BRK coloring since PlotOR resets rect colors
   if(g_sessGapActive) PlotSessionGap();
   if(g_sessBrkActive) PlotSessionBreaker();
}

//+------------------------------------------------------------------+
//| Plot one session's high/low as trend lines                       |
//+------------------------------------------------------------------+
void PlotOneSessionHL(string prefix, datetime startTime, datetime endTime)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, PERIOD_M15, startTime, endTime, rates);
   if(copied <= 0) return;

   double high = rates[0].high;
   double low  = rates[0].low;
   for(int i = 1; i < copied; i++)
   {
      if(rates[i].high > high) high = rates[i].high;
      if(rates[i].low  < low)  low  = rates[i].low;
   }

   string nameH = prefix + "_H";
   string nameL = prefix + "_L";

   if(ObjectFind(0, nameH) >= 0) ObjectDelete(0, nameH);
   ObjectCreate(0, nameH, OBJ_TREND, 0, startTime, high, endTime, high);
   ObjectSetInteger(0, nameH, OBJPROP_COLOR, C'50,120,180');
   ObjectSetInteger(0, nameH, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, nameH, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, nameH, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, nameH, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nameH, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nameH, OBJPROP_BACK, true);

   if(ObjectFind(0, nameL) >= 0) ObjectDelete(0, nameL);
   ObjectCreate(0, nameL, OBJ_TREND, 0, startTime, low, endTime, low);
   ObjectSetInteger(0, nameL, OBJPROP_COLOR, C'50,120,180');
   ObjectSetInteger(0, nameL, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, nameL, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, nameL, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, nameL, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nameL, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nameL, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| Plot completed session H/L (3 months)                           |
//+------------------------------------------------------------------+
void PlotSessionHL()
{
   RemoveSessionHL();
   if(Period() >= PERIOD_D1) return;
   bool crypto = IsCrypto();
   datetime now = TimeCurrent();
   int pmH = crypto ? 20 : 19;
   int pmM = crypto ? 0  : 45;

   for(int d = 0; d >= -90; d--)
   {
      // AM session: 9:30 AM â†’ 4:00 PM
      datetime amS = ESTToServer(9, 30, d);
      datetime amE = ESTToServer(16, 0, d);
      if(amE <= now)
         PlotOneSessionHL("RM_SH_AM" + IntegerToString(-d), amS, amE);

      // PM session: pmH:pmM â†’ 9:30 AM next day
      datetime pmS = ESTToServer(pmH, pmM, d);
      datetime pmE = ESTToServer(9, 30, d + 1);
      if(pmE <= now)
         PlotOneSessionHL("RM_SH_PM" + IntegerToString(-d), pmS, pmE);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void RemoveSessionHL()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "RM_SH_") == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleSessionHL()
{
   g_sessHLActive = !g_sessHLActive;
   if(g_sessHLActive) PlotSessionHL(); else RemoveSessionHL();
   ObjectSetInteger(0, "RM_BtnSHL", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSHL"));
}

//+------------------------------------------------------------------+
void CheckSessionEnd()
{
   if(!g_sessHLActive) return;
   static datetime lastCheck = 0;
   if(TimeCurrent() - lastCheck < 60) return;
   lastCheck = TimeCurrent();
   PlotSessionHL();
}

//+------------------------------------------------------------------+
//| Draw a daily candle box with thick directional border             |
//+------------------------------------------------------------------+
void DrawDailyBox(string name, datetime t1, datetime t2, double high, double low, bool bullish)
{
   // Main rectangle outline
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, high, t2, low);
   ObjectSetInteger(0, name, OBJPROP_COLOR, C'160,145,115');
   ObjectSetInteger(0, name, OBJPROP_FILL, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);

   // Thick border: bottom for bull candle, top for bear candle (5x thicker)
   string thickName = name + "_T";
   if(ObjectFind(0, thickName) >= 0) ObjectDelete(0, thickName);
   double thickPrice = bullish ? low : high;
   ObjectCreate(0, thickName, OBJ_TREND, 0, t1, thickPrice, t2, thickPrice);
   ObjectSetInteger(0, thickName, OBJPROP_COLOR, C'160,145,115');
   ObjectSetInteger(0, thickName, OBJPROP_WIDTH, 5);
   ObjectSetInteger(0, thickName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, thickName, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, thickName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, thickName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, thickName, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| Plot daily candle boxes (2 weeks)                                |
//+------------------------------------------------------------------+
void PlotDailyBoxes()
{
   RemoveDailyBoxes();
   if(Period() >= PERIOD_D1) return;
   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   int copied = CopyRates(_Symbol, PERIOD_D1, 1, 90, daily);
   if(copied <= 0) return;

   for(int i = 0; i < copied; i++)
   {
      datetime dayStart = daily[i].time;
      datetime dayEnd   = (i > 0) ? daily[i - 1].time
                                  : dayStart + PeriodSeconds(PERIOD_D1);
      bool bullish = (daily[i].close >= daily[i].open);
      DrawDailyBox("RM_DB_" + IntegerToString(i),
                   dayStart, dayEnd, daily[i].high, daily[i].low, bullish);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void RemoveDailyBoxes()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "RM_DB_") == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleDailyBoxes()
{
   g_dailyBoxActive = !g_dailyBoxActive;
   if(g_dailyBoxActive) PlotDailyBoxes(); else RemoveDailyBoxes();
   ObjectSetInteger(0, "RM_BtnDBX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDBX"));
}

//+------------------------------------------------------------------+
void UpdateDailyBoxes()
{
   if(!g_dailyBoxActive) return;
   static datetime lastUpd = 0;
   if(TimeCurrent() - lastUpd < 300) return;
   lastUpd = TimeCurrent();
   PlotDailyBoxes();
}

//+------------------------------------------------------------------+
//| Draw a weekly candle box (reuses same visual style as daily)     |
//+------------------------------------------------------------------+
void DrawWeeklyBox(string name, datetime t1, datetime t2, double high, double low, bool bullish)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, high, t2, low);
   ObjectSetInteger(0, name, OBJPROP_COLOR, C'130,115,85');
   ObjectSetInteger(0, name, OBJPROP_FILL, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);

   string thickName = name + "_T";
   if(ObjectFind(0, thickName) >= 0) ObjectDelete(0, thickName);
   double thickPrice = bullish ? low : high;
   ObjectCreate(0, thickName, OBJ_TREND, 0, t1, thickPrice, t2, thickPrice);
   ObjectSetInteger(0, thickName, OBJPROP_COLOR, C'130,115,85');
   ObjectSetInteger(0, thickName, OBJPROP_WIDTH, 5);
   ObjectSetInteger(0, thickName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, thickName, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, thickName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, thickName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, thickName, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
void PlotWeeklyBoxes()
{
   RemoveWeeklyBoxes();
   if(Period() >= PERIOD_W1) return;
   MqlRates weekly[];
   ArraySetAsSeries(weekly, true);
   int copied = CopyRates(_Symbol, PERIOD_W1, 1, 13, weekly);
   if(copied <= 0) return;

   for(int i = 0; i < copied; i++)
   {
      datetime wkStart = weekly[i].time;
      datetime wkEnd   = (i > 0) ? weekly[i - 1].time
                                  : wkStart + PeriodSeconds(PERIOD_W1);
      bool bullish = (weekly[i].close >= weekly[i].open);
      DrawWeeklyBox("RM_WB_" + IntegerToString(i),
                    wkStart, wkEnd, weekly[i].high, weekly[i].low, bullish);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void RemoveWeeklyBoxes()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "RM_WB_") == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleWeeklyBoxes()
{
   g_weeklyBoxActive = !g_weeklyBoxActive;
   if(g_weeklyBoxActive) PlotWeeklyBoxes(); else RemoveWeeklyBoxes();
   ObjectSetInteger(0, "RM_BtnWBX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnWBX"));
}

//+------------------------------------------------------------------+
void UpdateWeeklyBoxes()
{
   if(!g_weeklyBoxActive) return;
   static datetime lastUpd = 0;
   if(TimeCurrent() - lastUpd < 600) return;
   lastUpd = TimeCurrent();
   PlotWeeklyBoxes();
}

//+------------------------------------------------------------------+
//| Weekly Opening Range â€” Sunday PM OR (same candle as D.OR PM)     |
//+------------------------------------------------------------------+
void CreateWORRect(int idx, datetime t1, double h, datetime t2, double l)
{
   string name = "RM_WOR_" + IntegerToString(idx);
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, h, t2, l);
   ObjectSetInteger(0, name, OBJPROP_COLOR, C'200,185,150');
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
}

void PlotWeeklyOR()
{
   RemoveWeeklyOR();
   if(Period() >= PERIOD_D1) return;

   bool crypto = IsCrypto();
   int pmH = crypto ? 20 : 19;
   int pmM = crypto ? 0  : 45;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   g_worHasRange = false;
   g_worRectIdx  = 0;

   // Find today's day-of-week in EST to step directly to Sundays
   int srvOff = GetServerGMTOffset();
   datetime gmtNow = TimeCurrent() - srvOff;
   int eOff = IsUSDST(gmtNow) ? 4 : 5;
   MqlDateTime estNow;
   TimeToStruct(gmtNow - (long)eOff * 3600, estNow);
   int todayDOW = estNow.day_of_week;  // 0=Sun, 1=Mon, ...
   int daysToLastSunday = todayDOW;    // offset back to most recent Sunday

   for(int w = 0; w < 13; w++)
   {
      int dayOffset = -(daysToLastSunday + w * 7);
      datetime pmStart = ESTToServer(pmH, pmM, dayOffset);

      int copied = CopyRates(_Symbol, PERIOD_M15, pmStart, 1, rates);
      if(copied <= 0 || MathAbs((long)(rates[0].time - pmStart)) >= 900) continue;

      double orH = rates[0].high;
      double orL = rates[0].low;
      datetime orStart = rates[0].time;

      datetime nextSunPM = ESTToServer(pmH, pmM, dayOffset + 7);
      datetime orEnd;
      if(nextSunPM <= TimeCurrent())
         orEnd = nextSunPM;
      else
         orEnd = iTime(_Symbol, PERIOD_CURRENT, 0);

      CreateWORRect(g_worRectIdx, orStart, orH, orEnd, orL);

      if(nextSunPM > TimeCurrent())
      {
         g_worHasRange  = true;
         g_worHigh      = orH;
         g_worLow       = orL;
         g_worStartTime = orStart;
         g_worWeekOpen  = iTime(_Symbol, PERIOD_W1, 0);
      }
      g_worRectIdx++;
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void RemoveWeeklyOR()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "RM_WOR_") == 0)
         ObjectDelete(0, name);
   }
   g_worHasRange = false;
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleWeeklyOR()
{
   g_weeklyORActive = !g_weeklyORActive;
   if(g_weeklyORActive) PlotWeeklyOR(); else RemoveWeeklyOR();
   ObjectSetInteger(0, "RM_BtnWOR", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnWOR"));
}

//+------------------------------------------------------------------+
void UpdateWeeklyOR()
{
   if(!g_weeklyORActive) return;

   // If plot failed previously (history not loaded), retry periodically
   if(!g_worHasRange)
   {
      static datetime lastRetry = 0;
      if(TimeCurrent() - lastRetry < 10) return;
      lastRetry = TimeCurrent();
      PlotWeeklyOR();
      return;
   }

   // Check if a new week started
   datetime curWeek = iTime(_Symbol, PERIOD_W1, 0);
   if(curWeek != g_worWeekOpen)
   {
      PlotWeeklyOR();
      return;
   }

   // Extend current rectangle to latest bar
   datetime latestBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   string name = "RM_WOR_" + IntegerToString(g_worRectIdx);
   if(ObjectFind(0, name) >= 0)
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, latestBar);
}

//+------------------------------------------------------------------+
//| Helper: draw a small backfill line segment at a price level      |
//| Segment spans from barEnd back by segBars on current timeframe   |
//+------------------------------------------------------------------+
void DrawMtxSegment(string name, datetime barStart, double price, int segBars, color clr, string label)
{
   int totalBars = iBars(_Symbol, PERIOD_CURRENT);
   int shift = iBarShift(_Symbol, PERIOD_CURRENT, barStart);
   if(shift < 0 || shift >= totalBars) return;
   datetime t1 = iTime(_Symbol, PERIOD_CURRENT, shift);
   int endShift = shift - segBars;
   if(endShift < 0) endShift = 0;
   datetime t2 = iTime(_Symbol, PERIOD_CURRENT, endShift);

   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);

   // Label at the right end of the segment (commented out for now)
   // string lblName = name + "_L";
   // if(ObjectFind(0, lblName) >= 0) ObjectDelete(0, lblName);
   // ObjectCreate(0, lblName, OBJ_TEXT, 0, t2, price);
   // ObjectSetString(0, lblName, OBJPROP_TEXT, " " + label);
   // ObjectSetString(0, lblName, OBJPROP_FONT, "Arial");
   // ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 7);
   // ObjectSetInteger(0, lblName, OBJPROP_COLOR, clr);
   // ObjectSetInteger(0, lblName, OBJPROP_ANCHOR, ANCHOR_LEFT);
   // ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
   // ObjectSetInteger(0, lblName, OBJPROP_BACK, false);
}

//+------------------------------------------------------------------+
//| Draw matrix segment backward from a reference point with offset  |
//| Goes offsetBars back from ref, then segBars further back         |
//+------------------------------------------------------------------+
void DrawMtxSegmentBack(string name, datetime barRef, double price, int segBars, int offsetBars, color clr, string label)
{
   int refShift = iBarShift(_Symbol, PERIOD_CURRENT, barRef);
   if(refShift < 0) refShift = 0;
   int startShift = refShift + offsetBars;
   int endShift   = startShift + segBars;
   if(endShift >= iBars(_Symbol, PERIOD_CURRENT)) return;
   datetime t1 = iTime(_Symbol, PERIOD_CURRENT, endShift);
   datetime t2 = iTime(_Symbol, PERIOD_CURRENT, startShift);

   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);

   // string lblName = name + "_L";
   // if(ObjectFind(0, lblName) >= 0) ObjectDelete(0, lblName);
   // ObjectCreate(0, lblName, OBJ_TEXT, 0, t2, price);
   // ObjectSetString(0, lblName, OBJPROP_TEXT, " " + label);
   // ObjectSetString(0, lblName, OBJPROP_FONT, "Arial");
   // ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 7);
   // ObjectSetInteger(0, lblName, OBJPROP_COLOR, clr);
   // ObjectSetInteger(0, lblName, OBJPROP_ANCHOR, ANCHOR_LEFT);
   // ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
   // ObjectSetInteger(0, lblName, OBJPROP_BACK, false);
}

//+------------------------------------------------------------------+
//| Daily Matrix â€” previous day's range levels plotted on each day   |
//| Uses prev day high/low: 0=low, 100=high, extensions beyond      |
//+------------------------------------------------------------------+
void PlotDailyMtx()
{
   RemoveDailyMtx();
   if(Period() > PERIOD_H1) return;
   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   int copied = CopyRates(_Symbol, PERIOD_D1, 1, 91, daily);
   if(copied < 1) return;

   for(int d = 0; d < copied; d++)
   {
      double prevH     = daily[d].high;
      double prevL     = daily[d].low;
      double range     = prevH - prevL;
      if(range <= 0) continue;

      datetime dayStart = (d > 0) ? daily[d - 1].time : daily[d].time + PeriodSeconds(PERIOD_D1);

      // Levels derived from previous day's high and low
      double levels[] = {
         prevL - range / 2.0,             // -50
         prevL - range / 4.0,             // -25
         prevL + range / 4.0,             //  25
         prevL + range / 3.0,             //  33
         prevL + 2.0 * range / 3.0,       //  66
         prevL + 3.0 * range / 4.0,       //  75
         prevH + range / 4.0,             // 125
         prevH + range / 2.0              // 150
      };
      string labels[] = {"-50", "-25", "25", "33", "66", "75", "125", "150"};
      color  clrs[]   = {C'140,30,60', C'160,145,115',
                         C'160,145,115', C'160,145,115',
                         C'160,145,115', C'160,145,115',
                         C'160,145,115', C'140,30,60'};

      for(int p = 0; p < 8; p++)
      {
         double price = NormalizeDouble(levels[p], _Digits);
         string name = "RM_DMX_" + IntegerToString(d) + "_" + IntegerToString(p);
         DrawMtxSegment(name, dayStart, price, 4, clrs[p], labels[p]);
      }
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void RemoveDailyMtx()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "RM_DMX_") == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleDailyMtx()
{
   g_dailyMtxActive = !g_dailyMtxActive;
   if(g_dailyMtxActive) PlotDailyMtx(); else RemoveDailyMtx();
   ObjectSetInteger(0, "RM_BtnDMX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDMX"));
}

//+------------------------------------------------------------------+
void UpdateDailyMtx()
{
   if(!g_dailyMtxActive) return;
   static datetime lastUpd = 0;
   if(TimeCurrent() - lastUpd < 300) return;
   lastUpd = TimeCurrent();
   PlotDailyMtx();
}

//+------------------------------------------------------------------+
//| Weekly Matrix â€” previous week's range levels backfilled          |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Weekly Matrix â€” previous week's range levels plotted on each week|
//+------------------------------------------------------------------+
void PlotWeeklyMtx()
{
   RemoveWeeklyMtx();
   if(Period() > PERIOD_H1) return;
   MqlRates weekly[];
   ArraySetAsSeries(weekly, true);
   int copied = CopyRates(_Symbol, PERIOD_W1, 1, 9, weekly);
   if(copied < 1) return;

   for(int w = 0; w < copied; w++)
   {
      double prevH  = weekly[w].high;
      double prevL  = weekly[w].low;
      double range  = prevH - prevL;
      if(range <= 0) continue;

      datetime wkStart = (w > 0) ? weekly[w - 1].time : weekly[w].time + PeriodSeconds(PERIOD_W1);

      double levels[] = {
         prevL - range / 2.0,
         prevL - range / 4.0,
         prevL + range / 4.0,
         prevL + range / 3.0,
         prevL + 2.0 * range / 3.0,
         prevL + 3.0 * range / 4.0,
         prevH + range / 4.0,
         prevH + range / 2.0
      };
      string labels[] = {"-50", "-25", "25", "33", "66", "75", "125", "150"};
      color  clrs[]   = {C'130,115,85', C'130,115,85',
                         C'130,115,85', C'130,115,85',
                         C'130,115,85', C'130,115,85',
                         C'130,115,85', C'130,115,85'};

      for(int p = 0; p < 8; p++)
      {
         double price = NormalizeDouble(levels[p], _Digits);
         string name = "RM_WMX_" + IntegerToString(w) + "_" + IntegerToString(p);
         DrawMtxSegmentBack(name, wkStart, price, 4, 4, clrs[p], labels[p]);
      }
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void RemoveWeeklyMtx()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "RM_WMX_") == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleWeeklyMtx()
{
   g_weeklyMtxActive = !g_weeklyMtxActive;
   if(g_weeklyMtxActive) PlotWeeklyMtx(); else RemoveWeeklyMtx();
   ObjectSetInteger(0, "RM_BtnWMX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnWMX"));
}

//+------------------------------------------------------------------+
void UpdateWeeklyMtx()
{
   if(!g_weeklyMtxActive) return;
   static datetime lastUpd = 0;
   if(TimeCurrent() - lastUpd < 600) return;
   lastUpd = TimeCurrent();
   PlotWeeklyMtx();
}

//+------------------------------------------------------------------+
//| D.150 â€” detect CLOSED daily candles exceeding matrix 150 or -50  |
//| Backfill plots on the closed day that exceeded those levels      |
//+------------------------------------------------------------------+
#define CLR_D150  C'140,30,60'    // burgundy maroon

void PlotDaily150()
{
   RemoveDaily150();
   if(Period() >= PERIOD_D1) return;
   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   int copied = CopyRates(_Symbol, PERIOD_D1, 0, 93, daily);
   if(copied < 3) return;

   int totalBars = iBars(_Symbol, PERIOD_CURRENT);

   // Detect if daily[0] is still forming or already closed
   int startIdx = 0;
   datetime barEndTime = daily[0].time + PeriodSeconds(PERIOD_D1);
   if(TimeCurrent() < barEndTime)
   {
      datetime lastQuote = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);
      if(TimeCurrent() - lastQuote < 7200)
         startIdx = 1;
   }

   for(int d = startIdx; d < copied - 1; d++)
   {
      double refH   = daily[d + 1].high;
      double refL   = daily[d + 1].low;
      double range  = refH - refL;
      if(range <= 0) continue;

      double level150   = refH + range / 2.0;
      double levelNeg50 = refL - range / 2.0;

      double dayHigh  = daily[d].high;
      double dayLow   = daily[d].low;
      double dayRange = dayHigh - dayLow;
      if(dayRange <= 0) continue;

      bool exceeds150  = (dayHigh > level150);
      bool exceedsN50  = (dayLow < levelNeg50);
      if(!exceeds150 && !exceedsN50) continue;

      datetime dayStart = daily[d].time;
      datetime dayEnd   = (d > 0) ? daily[d - 1].time
                                  : daily[d].time + PeriodSeconds(PERIOD_D1);

      int s1 = iBarShift(_Symbol, PERIOD_CURRENT, dayStart);
      int s2 = iBarShift(_Symbol, PERIOD_CURRENT, dayEnd);
      if(s1 < 0 || s1 >= totalBars) continue;
      if(s2 < 0) s2 = 0;
      datetime t1 = iTime(_Symbol, PERIOD_CURRENT, s1);
      datetime t2 = iTime(_Symbol, PERIOD_CURRENT, s2);

      // 150 exceedance â†’ line at level 0 (exceeding candle's own low)
      if(exceeds150)
      {
         double linePrice = NormalizeDouble(dayLow, _Digits);
         string name = "RM_D150_U_" + IntegerToString(d);
         if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
         ObjectCreate(0, name, OBJ_TREND, 0, t1, linePrice, t2, linePrice);
         ObjectSetInteger(0, name, OBJPROP_COLOR, CLR_D150);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 5);
         ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
         ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_BACK, true);
      }

      // -50 exceedance â†’ line at level 100 (exceeding candle's own high)
      if(exceedsN50)
      {
         double linePrice = NormalizeDouble(dayHigh, _Digits);
         string name = "RM_D150_D_" + IntegerToString(d);
         if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
         ObjectCreate(0, name, OBJ_TREND, 0, t1, linePrice, t2, linePrice);
         ObjectSetInteger(0, name, OBJPROP_COLOR, CLR_D150);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 5);
         ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
         ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_BACK, true);
      }
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void RemoveDaily150()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "RM_D150_") == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleDaily150()
{
   g_daily150Active = !g_daily150Active;
   if(g_daily150Active) PlotDaily150(); else RemoveDaily150();
   ObjectSetInteger(0, "RM_BtnD150", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnD150"));
}

//+------------------------------------------------------------------+
void UpdateDaily150()
{
   if(!g_daily150Active) return;
   static datetime lastUpd = 0;
   if(TimeCurrent() - lastUpd < 300) return;
   lastUpd = TimeCurrent();
   PlotDaily150();
}

//+------------------------------------------------------------------+
//| Session Gap: highlight night OR when day session HL doesn't touch|
//+------------------------------------------------------------------+
#define CLR_SGAP  C'34,139,34'    // forest green

void PlotSessionGap()
{
   // Recolor matching D.OR PM rects instead of creating overlays
   // First reset all PM OR rects to default color
   ResetORColors();

   if(Period() >= PERIOD_D1) return;

   bool crypto = IsCrypto();
   int pmH = crypto ? 20 : 19;
   int pmM = crypto ? 0  : 45;
   datetime now = TimeCurrent();

   for(int d = 0; d >= -90; d--)
   {
      datetime pmS = ESTToServer(pmH, pmM, d);
      datetime pmE = ESTToServer(9, 30, d + 1);
      datetime dayS = pmE;
      datetime dayE = ESTToServer(16, 0, d + 1);

      if(dayE > now) continue;

      MqlRates pmBar[];
      ArraySetAsSeries(pmBar, true);
      int copied = CopyRates(_Symbol, PERIOD_M15, pmS, 1, pmBar);
      if(copied <= 0 || MathAbs((long)(pmBar[0].time - pmS)) >= 900) continue;
      double nightORHigh = pmBar[0].high;
      double nightORLow  = pmBar[0].low;

      MqlRates dayBars[];
      ArraySetAsSeries(dayBars, false);
      int dayCopied = CopyRates(_Symbol, PERIOD_M15, dayS, dayE, dayBars);
      if(dayCopied <= 0) continue;

      double dayHigh = dayBars[0].high;
      double dayLow  = dayBars[0].low;
      for(int i = 1; i < dayCopied; i++)
      {
         if(dayBars[i].high > dayHigh) dayHigh = dayBars[i].high;
         if(dayBars[i].low  < dayLow)  dayLow  = dayBars[i].low;
      }

      bool overlap = (dayLow <= nightORHigh && dayHigh >= nightORLow);
      if(overlap) continue;

      // Recolor the existing D.OR PM rect
      string orName = "RM_OR_PM" + IntegerToString(-d);
      if(ObjectFind(0, orName) >= 0)
         ObjectSetInteger(0, orName, OBJPROP_COLOR, CLR_SGAP);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ResetORColors()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "RM_OR_") == 0)
         ObjectSetInteger(0, name, OBJPROP_COLOR, C'180,172,158');
   }
}

//+------------------------------------------------------------------+
void RemoveSessionGap()
{
   // Just reset colors back to default
   ResetORColors();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleSessionGap()
{
   g_sessGapActive = !g_sessGapActive;
   if(g_sessGapActive) PlotSessionGap(); else RemoveSessionGap();
   // Also re-apply S.BRK on top if active
   if(g_sessBrkActive) PlotSessionBreaker();
   ObjectSetInteger(0, "RM_BtnSGAP", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSGAP"));
}

//+------------------------------------------------------------------+
void UpdateSessionGap()
{
   if(!g_sessGapActive) return;
   static datetime lastUpd = 0;
   if(TimeCurrent() - lastUpd < 300) return;
   lastUpd = TimeCurrent();
   PlotSessionGap();
   // Re-apply S.BRK on top since PlotSessionGap resets colors first
   if(g_sessBrkActive) PlotSessionBreaker();
}

//+------------------------------------------------------------------+
//| Session Breaker â€” when a D.LVL is breached, recolor the         |
//| session OR (AM or PM) that was active during the breach.         |
//| Higher priority than S.GAP â€” applied after S.GAP.               |
//+------------------------------------------------------------------+
#define CLR_SBRK  C'140,30,60'   // burgundy maroon

// Find which session OR contains the breach time and recolor it
void MarkSBRKForBreach(datetime breachTime)
{
   bool crypto = IsCrypto();
   int pmH = crypto ? 20 : 19;
   int pmM = crypto ? 0  : 45;

   for(int d = 0; d >= -92; d--)
   {
      datetime amStart = ESTToServer(9, 30, d);
      datetime amEnd   = ESTToServer(16, 0, d);
      if(breachTime >= amStart && breachTime < amEnd)
      {
         string orName = "RM_OR_AM" + IntegerToString(-d);
         if(ObjectFind(0, orName) >= 0)
            ObjectSetInteger(0, orName, OBJPROP_COLOR, CLR_SBRK);
         return;
      }

      datetime pmStart = ESTToServer(pmH, pmM, d);
      datetime pmEnd   = ESTToServer(9, 30, d + 1);
      if(breachTime >= pmStart && breachTime < pmEnd)
      {
         string orName = "RM_OR_PM" + IntegerToString(-d);
         if(ObjectFind(0, orName) >= 0)
            ObjectSetInteger(0, orName, OBJPROP_COLOR, CLR_SBRK);
         return;
      }
   }
}

//+------------------------------------------------------------------+
void PlotSessionBreaker()
{
   if(Period() >= PERIOD_D1) return;

   MqlRates daily[];
   ArraySetAsSeries(daily, false);
   int copied = CopyRates(_Symbol, PERIOD_D1, 0, 93, daily);
   if(copied < 2) return;

   datetime lastDayEnd = daily[copied - 1].time + PeriodSeconds(PERIOD_D1);
   bool lastForming = (TimeCurrent() < lastDayEnd);
   int closedCount = lastForming ? copied - 1 : copied;

   double activeUpLow = 0, activeDownHigh = 0;
   datetime upStart = 0, downStart = 0;

   for(int d = 0; d < closedCount; d++)
   {
      datetime dayOpen = daily[d].time;
      datetime dayEnd  = (d < copied - 1) ? daily[d + 1].time
                                           : (datetime)(daily[d].time + PeriodSeconds(PERIOD_D1));

      if(activeDownHigh > 0 && daily[d].high > activeDownHigh)
      {
         datetime scanFrom = (downStart > dayOpen) ? downStart : dayOpen;
         datetime bt = FindDLVLBreach(scanFrom, dayEnd, activeDownHigh, true);
         MarkSBRKForBreach(bt);
         activeDownHigh = 0;
      }

      if(activeUpLow > 0 && daily[d].low < activeUpLow)
      {
         datetime scanFrom = (upStart > dayOpen) ? upStart : dayOpen;
         datetime bt = FindDLVLBreach(scanFrom, dayEnd, activeUpLow, false);
         MarkSBRKForBreach(bt);
         activeUpLow = 0;
      }

      bool isUp = (daily[d].close >= daily[d].open);
      if(isUp)
      {
         activeUpLow = daily[d].low;
         upStart = dayEnd;
      }
      else
      {
         activeDownHigh = daily[d].high;
         downStart = dayEnd;
      }
   }

   if(activeDownHigh > 0)
   {
      MqlRates curBars[];
      ArraySetAsSeries(curBars, false);
      int cc = CopyRates(_Symbol, PERIOD_CURRENT, downStart, TimeCurrent() + 1, curBars);
      if(cc > 0)
      {
         for(int i = 0; i < cc; i++)
         {
            if(curBars[i].high > activeDownHigh)
            {
               MarkSBRKForBreach(curBars[i].time);
               break;
            }
         }
      }
   }

   if(activeUpLow > 0)
   {
      MqlRates curBars[];
      ArraySetAsSeries(curBars, false);
      int cc = CopyRates(_Symbol, PERIOD_CURRENT, upStart, TimeCurrent() + 1, curBars);
      if(cc > 0)
      {
         for(int i = 0; i < cc; i++)
         {
            if(curBars[i].low < activeUpLow)
            {
               MarkSBRKForBreach(curBars[i].time);
               break;
            }
         }
      }
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void RemoveSessionBreaker()
{
   // S.BRK no longer creates its own objects â€” just re-apply base colors
   // Re-apply S.GAP if active, otherwise reset to default
   if(g_sessGapActive)
      PlotSessionGap();
   else
      ResetORColors();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleSessionBreaker()
{
   g_sessBrkActive = !g_sessBrkActive;
   if(g_sessBrkActive) PlotSessionBreaker(); else RemoveSessionBreaker();
   ObjectSetInteger(0, "RM_BtnSBRK", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSBRK"));
}

//+------------------------------------------------------------------+
void UpdateSessionBreaker()
{
   if(!g_sessBrkActive) return;
   static datetime lastUpd = 0;
   if(TimeCurrent() - lastUpd < 300) return;
   lastUpd = TimeCurrent();
   PlotSessionBreaker();
}

//+------------------------------------------------------------------+
//| Daily Levels â€” track latest up-close candle's low and latest     |
//| down-close candle's high as dotted lines extending forward.      |
//| Lines stop at breach or when replaced by a new same-dir candle.  |
//+------------------------------------------------------------------+
#define CLR_DLVL  C'140,30,60'   // burgundy maroon

datetime FindDLVLBreach(datetime from, datetime to, double level, bool isAbove)
{
   MqlRates bars[];
   ArraySetAsSeries(bars, false);
   int copied = CopyRates(_Symbol, PERIOD_CURRENT, from, to, bars);
   if(copied <= 0) return from;
   for(int i = 0; i < copied; i++)
   {
      if(isAbove && bars[i].high > level) return bars[i].time;
      if(!isAbove && bars[i].low < level) return bars[i].time;
   }
   return to;
}

//+------------------------------------------------------------------+
void DrawDLVLLine(string name, datetime t1, datetime t2, double price)
{
   if(t2 <= t1) return;
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, CLR_DLVL);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
void PlotDailyLevels()
{
   RemoveDailyLevels();
   if(Period() > PERIOD_H1) return;

   MqlRates daily[];
   ArraySetAsSeries(daily, false);  // oldest first
   int copied = CopyRates(_Symbol, PERIOD_D1, 0, 93, daily);
   if(copied < 2) return;

   // Determine how many daily candles are closed
   datetime lastDayEnd = daily[copied - 1].time + PeriodSeconds(PERIOD_D1);
   bool lastForming = (TimeCurrent() < lastDayEnd);
   int closedCount = lastForming ? copied - 1 : copied;

   double activeUpLow = 0, activeDownHigh = 0;
   datetime upStart = 0, downStart = 0;
   int segIdx = 0;

   for(int d = 0; d < closedCount; d++)
   {
      datetime dayOpen = daily[d].time;
      datetime dayEnd  = (d < copied - 1) ? daily[d + 1].time
                                           : (datetime)(daily[d].time + PeriodSeconds(PERIOD_D1));

      // 1. Check if active levels are breached during this day
      if(activeDownHigh > 0 && downStart <= dayEnd)
      {
         datetime scanFrom = (downStart > dayOpen) ? downStart : dayOpen;
         if(daily[d].high > activeDownHigh)
         {
            datetime bt = FindDLVLBreach(scanFrom, dayEnd, activeDownHigh, true);
            DrawDLVLLine("RM_DLVL_" + IntegerToString(segIdx), downStart, bt, activeDownHigh);
            segIdx++;
            activeDownHigh = 0;
         }
      }
      if(activeUpLow > 0 && upStart <= dayEnd)
      {
         datetime scanFrom = (upStart > dayOpen) ? upStart : dayOpen;
         if(daily[d].low < activeUpLow)
         {
            datetime bt = FindDLVLBreach(scanFrom, dayEnd, activeUpLow, false);
            DrawDLVLLine("RM_DLVL_" + IntegerToString(segIdx), upStart, bt, activeUpLow);
            segIdx++;
            activeUpLow = 0;
         }
      }

      // 2. This closed candle sets/updates the tracked level
      bool isUp = (daily[d].close >= daily[d].open);
      if(isUp)
      {
         // End previous up-low line (replaced by new same-direction candle)
         if(activeUpLow > 0)
         {
            DrawDLVLLine("RM_DLVL_" + IntegerToString(segIdx), upStart, dayEnd, activeUpLow);
            segIdx++;
         }
         activeUpLow = daily[d].low;
         upStart = dayEnd;
      }
      else
      {
         if(activeDownHigh > 0)
         {
            DrawDLVLLine("RM_DLVL_" + IntegerToString(segIdx), downStart, dayEnd, activeDownHigh);
            segIdx++;
         }
         activeDownHigh = daily[d].high;
         downStart = dayEnd;
      }
   }

   // 3. Extend active levels into the current (forming) period
   datetime latestBar = iTime(_Symbol, PERIOD_CURRENT, 0);

   if(activeDownHigh > 0)
   {
      // Scan from downStart to now for breach
      MqlRates curBars[];
      ArraySetAsSeries(curBars, false);
      int cc = CopyRates(_Symbol, PERIOD_CURRENT, downStart, TimeCurrent() + 1, curBars);
      bool breached = false;
      if(cc > 0)
      {
         for(int i = 0; i < cc; i++)
         {
            if(curBars[i].high > activeDownHigh)
            {
               DrawDLVLLine("RM_DLVL_" + IntegerToString(segIdx), downStart, curBars[i].time, activeDownHigh);
               segIdx++;
               breached = true;
               break;
            }
         }
      }
      if(!breached)
      {
         DrawDLVLLine("RM_DLVL_" + IntegerToString(segIdx), downStart, latestBar, activeDownHigh);
         segIdx++;
      }
   }

   if(activeUpLow > 0)
   {
      MqlRates curBars[];
      ArraySetAsSeries(curBars, false);
      int cc = CopyRates(_Symbol, PERIOD_CURRENT, upStart, TimeCurrent() + 1, curBars);
      bool breached = false;
      if(cc > 0)
      {
         for(int i = 0; i < cc; i++)
         {
            if(curBars[i].low < activeUpLow)
            {
               DrawDLVLLine("RM_DLVL_" + IntegerToString(segIdx), upStart, curBars[i].time, activeUpLow);
               segIdx++;
               breached = true;
               break;
            }
         }
      }
      if(!breached)
      {
         DrawDLVLLine("RM_DLVL_" + IntegerToString(segIdx), upStart, latestBar, activeUpLow);
         segIdx++;
      }
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void RemoveDailyLevels()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "RM_DLVL_") == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleDailyLevels()
{
   g_dailyLvlActive = !g_dailyLvlActive;
   if(g_dailyLvlActive) PlotDailyLevels(); else RemoveDailyLevels();
   ObjectSetInteger(0, "RM_BtnDLVL", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDLVL"));
}

//+------------------------------------------------------------------+
void UpdateDailyLevels()
{
   if(!g_dailyLvlActive) return;
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(curBar == lastBar) return;
   lastBar = curBar;
   PlotDailyLevels();
}

//+------------------------------------------------------------------+
//| Daily Stalk Zones â€” plot matrix-based rectangles for stalking    |
//| Bullish prev close: 100-125 and 25-33 zones                     |
//| Bearish prev close: 75-66 and 0 to -25 zones                    |
//+------------------------------------------------------------------+
#define CLR_DSTK  C'180,100,100'
#define CLR_DSTK_BG  C'245,220,220'   // faint light-red background

void PlotDailyStalk()
{
   RemoveDailyStalk();
   if(Period() > PERIOD_H1) return;
   if(g_dStkMode == 0) return;

   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   int lookback = (g_dStkMode == 1) ? 93 : 3;
   int copied = CopyRates(_Symbol, PERIOD_D1, 0, lookback, daily);
   if(copied < 2) return;

   // Always start at d=0 (today) â€” we want zones on the current day
   int limit = (g_dStkMode == 2) ? 1 : copied - 1;

   for(int d = 0; d < limit; d++)
   {
      double refH = daily[d + 1].high;
      double refL = daily[d + 1].low;
      double range = refH - refL;
      if(range <= 0) continue;

      bool prevBull = (daily[d + 1].close >= daily[d + 1].open);

      datetime dayStart = daily[d].time;
      datetime dayEnd   = (d > 0) ? daily[d - 1].time
                                  : daily[d].time + PeriodSeconds(PERIOD_D1);

      double upperTop, upperBot, lowerTop, lowerBot;
      if(prevBull)
      {
         upperTop = refH + range * 0.25;
         upperBot = refH;
         lowerTop = refL + range * 0.33;
         lowerBot = refL + range * 0.25;
      }
      else
      {
         upperTop = refL + range * 0.75;
         upperBot = refL + range * 0.66;
         lowerTop = refL;
         lowerBot = refL - range * 0.25;
      }

      // Upper zone background (faint off-beige, behind everything)
      string nameUBG = "RM_DSTK_UB_" + IntegerToString(d);
      if(ObjectFind(0, nameUBG) >= 0) ObjectDelete(0, nameUBG);
      ObjectCreate(0, nameUBG, OBJ_RECTANGLE, 0, dayStart, upperTop, dayEnd, upperBot);
      ObjectSetInteger(0, nameUBG, OBJPROP_COLOR, CLR_DSTK_BG);
      ObjectSetInteger(0, nameUBG, OBJPROP_FILL, true);
      ObjectSetInteger(0, nameUBG, OBJPROP_BACK, true);
      ObjectSetInteger(0, nameUBG, OBJPROP_SELECTABLE, false);

      // Upper zone dotted outline
      string nameU = "RM_DSTK_U_" + IntegerToString(d);
      if(ObjectFind(0, nameU) >= 0) ObjectDelete(0, nameU);
      ObjectCreate(0, nameU, OBJ_RECTANGLE, 0, dayStart, upperTop, dayEnd, upperBot);
      ObjectSetInteger(0, nameU, OBJPROP_COLOR, CLR_DSTK);
      ObjectSetInteger(0, nameU, OBJPROP_FILL, false);
      ObjectSetInteger(0, nameU, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, nameU, OBJPROP_BACK, true);
      ObjectSetInteger(0, nameU, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nameU, OBJPROP_WIDTH, 1);

      // Lower zone background (faint off-beige, behind everything)
      string nameLBG = "RM_DSTK_LB_" + IntegerToString(d);
      if(ObjectFind(0, nameLBG) >= 0) ObjectDelete(0, nameLBG);
      ObjectCreate(0, nameLBG, OBJ_RECTANGLE, 0, dayStart, lowerTop, dayEnd, lowerBot);
      ObjectSetInteger(0, nameLBG, OBJPROP_COLOR, CLR_DSTK_BG);
      ObjectSetInteger(0, nameLBG, OBJPROP_FILL, true);
      ObjectSetInteger(0, nameLBG, OBJPROP_BACK, true);
      ObjectSetInteger(0, nameLBG, OBJPROP_SELECTABLE, false);

      // Lower zone dotted outline
      string nameL = "RM_DSTK_L_" + IntegerToString(d);
      if(ObjectFind(0, nameL) >= 0) ObjectDelete(0, nameL);
      ObjectCreate(0, nameL, OBJ_RECTANGLE, 0, dayStart, lowerTop, dayEnd, lowerBot);
      ObjectSetInteger(0, nameL, OBJPROP_COLOR, CLR_DSTK);
      ObjectSetInteger(0, nameL, OBJPROP_FILL, false);
      ObjectSetInteger(0, nameL, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, nameL, OBJPROP_BACK, true);
      ObjectSetInteger(0, nameL, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nameL, OBJPROP_WIDTH, 1);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void RemoveDailyStalk()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "RM_DSTK_") == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleDailyStalk()
{
   g_dStkMode = (g_dStkMode + 1) % 3;  // 0â†’1â†’2â†’0
   if(g_dStkMode > 0) PlotDailyStalk(); else RemoveDailyStalk();
   // Update button label to show mode
   string label = (g_dStkMode == 0) ? "D.STK" : (g_dStkMode == 1) ? "D.STK\x2605" : "D.STK\x25CF";
   ObjectSetString(0, "RM_BtnDSTK", OBJPROP_TEXT, label);
   ObjectSetInteger(0, "RM_BtnDSTK", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDSTK"));
}

//+------------------------------------------------------------------+
void UpdateDailyStalk()
{
   if(g_dStkMode == 0) return;
   static datetime lastUpd = 0;
   if(TimeCurrent() - lastUpd < 300) return;
   lastUpd = TimeCurrent();
   PlotDailyStalk();
}

//+------------------------------------------------------------------+
//| Daily Matrix Level Label (top-right header)                      |
//+------------------------------------------------------------------+
void PlotDmxLabel()
{
   if(!g_dmxLabelActive) { RemoveDmxLabel(); return; }

   // Get previous day's high/low
   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, daily) < 1) return;
   double prevH  = daily[0].high;
   double prevL  = daily[0].low;
   double range  = prevH - prevL;
   if(range <= 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Compute matrix percentage: 0 = prevLow, 100 = prevHigh
   double pct = (bid - prevL) / range * 100.0;
   int level = (int)MathRound(pct);

   // â”€â”€ Check if price is inside today's D.STK zones â”€â”€
   bool prevBull = (daily[0].close >= daily[0].open);
   double upperTop, upperBot, lowerTop, lowerBot;
   if(prevBull)
   {
      upperTop = prevH + range * 0.25;
      upperBot = prevH;
      lowerTop = prevL + range * 0.33;
      lowerBot = prevL + range * 0.25;
   }
   else
   {
      upperTop = prevL + range * 0.75;
      upperBot = prevL + range * 0.66;
      lowerTop = prevL;
      lowerBot = prevL - range * 0.25;
   }

   bool inStalk = (bid >= upperBot && bid <= upperTop) ||
                  (bid >= lowerBot && bid <= lowerTop);

   // â”€â”€ 1) D.MX level â€” right edge, Y follows current price â”€â”€
   int baseFontSize = 28;
   int fontSize = inStalk ? (int)(baseFontSize * 1.5) : baseFontSize;
   color lvlClr = inStalk ? C'0,180,80' :
                  (pct >= 0 && pct <= 100) ? C'80,70,55' :
                  (pct > 100) ? C'0,130,70' : C'180,40,40';
   string lvlText = IntegerToString(level);
   if(inStalk) lvlText += "!";

   // Convert bid price to pixel Y
   int pricePixX, pricePixY;
   ChartTimePriceToXY(0, 0, TimeCurrent(), bid, pricePixX, pricePixY);

   if(ObjectFind(0, "RM_MLVL_Main") < 0)
   {
      CreateLabel("RM_MLVL_Main", 0, 0, lvlText, lvlClr, fontSize);
      ObjectSetInteger(0, "RM_MLVL_Main", OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, "RM_MLVL_Main", OBJPROP_ANCHOR, ANCHOR_RIGHT);
      ObjectSetString(0, "RM_MLVL_Main", OBJPROP_FONT, "Segoe UI Bold");
      ObjectSetInteger(0, "RM_MLVL_Main", OBJPROP_XDISTANCE, 20);
      ObjectSetInteger(0, "RM_MLVL_Main", OBJPROP_ZORDER, 90);
   }
   ObjectSetString(0, "RM_MLVL_Main", OBJPROP_TEXT, lvlText);
   ObjectSetInteger(0, "RM_MLVL_Main", OBJPROP_COLOR, lvlClr);
   ObjectSetInteger(0, "RM_MLVL_Main", OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, "RM_MLVL_Main", OBJPROP_YDISTANCE, pricePixY);

   // â”€â”€ 2) EST time â€” top right, large bold, HH:MM AM/PM â”€â”€
   int srvOff = GetServerGMTOffset();
   datetime gmtNow = TimeCurrent() - srvOff;
   int estOff = IsUSDST(gmtNow) ? 4 : 5;
   datetime estNow = (datetime)(gmtNow - (long)estOff * 3600);
   MqlDateTime estDt;
   TimeToStruct(estNow, estDt);

   int hr12 = estDt.hour % 12;
   if(hr12 == 0) hr12 = 12;
   string ampm = (estDt.hour >= 12) ? "PM" : "AM";
   string estTimeText = StringFormat("%d:%02d %s", hr12, estDt.min, ampm);

   if(ObjectFind(0, "RM_MLVL_Time") < 0)
   {
      CreateLabel("RM_MLVL_Time", 0, 0, estTimeText, C'80,70,55', 28);
      ObjectSetInteger(0, "RM_MLVL_Time", OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, "RM_MLVL_Time", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, "RM_MLVL_Time", OBJPROP_XDISTANCE, 20);
      ObjectSetInteger(0, "RM_MLVL_Time", OBJPROP_YDISTANCE, 15);
      ObjectSetString(0, "RM_MLVL_Time", OBJPROP_FONT, "Segoe UI Bold");
      ObjectSetInteger(0, "RM_MLVL_Time", OBJPROP_ZORDER, 90);
   }
   ObjectSetString(0, "RM_MLVL_Time", OBJPROP_TEXT, estTimeText);

   // â”€â”€ Symbol name under timestamp â”€â”€
   if(ObjectFind(0, "RM_MLVL_Sym") < 0)
   {
      CreateLabel("RM_MLVL_Sym", 0, 0, _Symbol, C'80,70,55', 28);
      ObjectSetInteger(0, "RM_MLVL_Sym", OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, "RM_MLVL_Sym", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, "RM_MLVL_Sym", OBJPROP_XDISTANCE, 20);
      ObjectSetInteger(0, "RM_MLVL_Sym", OBJPROP_YDISTANCE, 55);
      ObjectSetString(0, "RM_MLVL_Sym", OBJPROP_FONT, "Segoe UI Bold");
      ObjectSetInteger(0, "RM_MLVL_Sym", OBJPROP_ZORDER, 90);
   }

   // R:R ratio under symbol (only when entry/TP/SL lines exist)
   bool rrLinesExist = (ObjectFind(0, g_entryLineName) >= 0 &&
                        ObjectFind(0, g_tpLineName) >= 0 &&
                        ObjectFind(0, g_slLineName) >= 0);
   if(rrLinesExist)
   {
      double entryP = ObjectGetDouble(0, g_entryLineName, OBJPROP_PRICE);
      double tpP    = ObjectGetDouble(0, g_tpLineName, OBJPROP_PRICE);
      double slP    = ObjectGetDouble(0, g_slLineName, OBJPROP_PRICE);
      double risk   = MathAbs(entryP - slP);
      double reward = MathAbs(tpP - entryP);
      string rrText = "";
      if(risk > 0)
         rrText = StringFormat("R:R  %.1f", reward / risk);
      else
         rrText = "R:R  ---";

      if(ObjectFind(0, "RM_MLVL_RR") < 0)
      {
         CreateLabel("RM_MLVL_RR", 0, 0, rrText, C'80,70,55', 28);
         ObjectSetInteger(0, "RM_MLVL_RR", OBJPROP_CORNER, CORNER_RIGHT_UPPER);
         ObjectSetInteger(0, "RM_MLVL_RR", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
         ObjectSetInteger(0, "RM_MLVL_RR", OBJPROP_XDISTANCE, 20);
         ObjectSetInteger(0, "RM_MLVL_RR", OBJPROP_YDISTANCE, 95);
         ObjectSetString(0, "RM_MLVL_RR", OBJPROP_FONT, "Segoe UI Bold");
         ObjectSetInteger(0, "RM_MLVL_RR", OBJPROP_ZORDER, 90);
      }
      ObjectSetString(0, "RM_MLVL_RR", OBJPROP_TEXT, rrText);
   }
   else
   {
      ObjectDelete(0, "RM_MLVL_RR");
   }

   // â”€â”€ 3) Day % elapsed â€” bottom of chart at current candle x-axis â”€â”€
   int estMinOfDay = estDt.hour * 60 + estDt.min;
   int minSince5PM = (estMinOfDay >= 17 * 60) ? (estMinOfDay - 17 * 60)
                                               : (estMinOfDay + 7 * 60);
   int dayPct = (int)MathRound(minSince5PM / 14.4);
   if(dayPct > 100) dayPct = 100;

   string dayPctText = IntegerToString(dayPct) + "%";

   // Get current candle time â†’ convert to pixel X for bottom placement
   datetime candleTime[];
   ArraySetAsSeries(candleTime, true);
   if(CopyTime(_Symbol, Period(), 0, 1, candleTime) > 0)
   {
      int candlePixX, candlePixY;
      ChartTimePriceToXY(0, 0, candleTime[0], bid, candlePixX, candlePixY);
      int chartH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);

      if(ObjectFind(0, "RM_MLVL_DayPct") < 0)
      {
         CreateLabel("RM_MLVL_DayPct", 0, 0, dayPctText, C'80,70,55', 28);
         ObjectSetInteger(0, "RM_MLVL_DayPct", OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, "RM_MLVL_DayPct", OBJPROP_ANCHOR, ANCHOR_LOWER);
         ObjectSetString(0, "RM_MLVL_DayPct", OBJPROP_FONT, "Segoe UI Bold");
         ObjectSetInteger(0, "RM_MLVL_DayPct", OBJPROP_ZORDER, 90);
      }
      ObjectSetString(0, "RM_MLVL_DayPct", OBJPROP_TEXT, dayPctText);
      ObjectSetInteger(0, "RM_MLVL_DayPct", OBJPROP_XDISTANCE, candlePixX);
      ObjectSetInteger(0, "RM_MLVL_DayPct", OBJPROP_YDISTANCE, chartH - 20);
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void RemoveDmxLabel()
{
   ObjectsDeleteAll(0, "RM_MLVL_");
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleDmxLabel()
{
   g_dmxLabelActive = !g_dmxLabelActive;
   if(g_dmxLabelActive) PlotDmxLabel(); else RemoveDmxLabel();
   ObjectSetInteger(0, "RM_BtnMLVL", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnMLVL"));
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void UpdateDmxLabel()
{
   if(!g_dmxLabelActive) return;
   PlotDmxLabel();
}

//+------------------------------------------------------------------+
void UpdateDmxLevelTick()
{
   if(!g_dmxLabelActive) return;
   if(ObjectFind(0, "RM_MLVL_Main") < 0) return;

   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, daily) < 1) return;
   double prevH  = daily[0].high;
   double prevL  = daily[0].low;
   double range  = prevH - prevL;
   if(range <= 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pct = (bid - prevL) / range * 100.0;
   int level = (int)MathRound(pct);

   // D.STK zone check
   bool prevBull = (daily[0].close >= daily[0].open);
   double upperTop, upperBot, lowerTop, lowerBot;
   if(prevBull)
   { upperTop = prevH + range * 0.25; upperBot = prevH;
     lowerTop = prevL + range * 0.33; lowerBot = prevL + range * 0.25; }
   else
   { upperTop = prevL + range * 0.75; upperBot = prevL + range * 0.66;
     lowerTop = prevL;               lowerBot = prevL - range * 0.25; }

   bool inStalk = (bid >= upperBot && bid <= upperTop) ||
                  (bid >= lowerBot && bid <= lowerTop);

   int baseFontSize = 28;
   int fontSize = inStalk ? (int)(baseFontSize * 1.5) : baseFontSize;
   color lvlClr = inStalk ? C'0,180,80' :
                  (pct >= 0 && pct <= 100) ? C'80,70,55' :
                  (pct > 100) ? C'0,130,70' : C'180,40,40';
   string lvlText = IntegerToString(level);
   if(inStalk) lvlText += "!";

   // Convert bid to pixel Y for right-edge positioning
   int pricePixX, pricePixY;
   ChartTimePriceToXY(0, 0, TimeCurrent(), bid, pricePixX, pricePixY);

   ObjectSetString(0, "RM_MLVL_Main", OBJPROP_TEXT, lvlText);
   ObjectSetInteger(0, "RM_MLVL_Main", OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, "RM_MLVL_Main", OBJPROP_COLOR, lvlClr);
   ObjectSetInteger(0, "RM_MLVL_Main", OBJPROP_YDISTANCE, pricePixY);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| S.MTX — H1 Swing Matrix (last two swings method)                 |
//+------------------------------------------------------------------+
void PlotSmxLabel()
{
   if(!g_smxActive) { RemoveSmxLabel(); return; }

   double smxTop = g_tt_swingHigh;
   double smxBot = g_tt_swingLow;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double smxRange = smxTop - smxBot;
   bool isFair = (smxRange > 0 && bid >= smxBot && bid <= smxTop);
   string fuText = isFair ? "F" : "U";

   int smxLevel = 0;
   if(smxRange > 0)
   {
      double smxPct = (bid - smxBot) / smxRange * 100.0;
      smxLevel = (int)MathRound(smxPct);
   }

   // Real-time BOS: use bar-0 extremes to catch wicks even if bid pulled back
   double b0Lo = iLow(_Symbol, PERIOD_M15, 0);
   double b0Hi = iHigh(_Symbol, PERIOD_M15, 0);
   int eTrend = g_tt_tTrend;
   double anchorPrice;
   if(g_tt_tTrend == 1 && (bid < smxBot || b0Lo < smxBot))       { eTrend = 2; anchorPrice = smxTop; }
   else if(g_tt_tTrend == 2 && (bid > smxTop || b0Hi > smxTop))  { eTrend = 1; anchorPrice = smxBot; }
   else { anchorPrice = (g_tt_tTrend == 1) ? g_tt_lastBosSwL : g_tt_lastBosSwH; }
   if(anchorPrice <= 0) anchorPrice = bid;

   bool deepRet = isFair && ((eTrend == 2 && smxLevel >= 67) || (eTrend == 1 && smxLevel <= 33));
   int baseFontSize = 28;
   int fontSize = deepRet ? 36 : ((smxLevel > 100 || smxLevel < 0) ? 18 : baseFontSize);
   color smxClr = (eTrend == 1) ? C'0,150,130' : C'200,80,50';
   string smxText = fuText + " " + IntegerToString(smxLevel) + (deepRet ? " !" : "");
   int pricePixX, pricePixY;
   ChartTimePriceToXY(0, 0, TimeCurrent(), anchorPrice, pricePixX, pricePixY);

   if(ObjectFind(0, "RM_SMX_Main") < 0)
   {
      CreateLabel("RM_SMX_Main", 0, 0, smxText, smxClr, fontSize);
      ObjectSetInteger(0, "RM_SMX_Main", OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, "RM_SMX_Main", OBJPROP_ANCHOR, ANCHOR_RIGHT);
      ObjectSetString(0, "RM_SMX_Main", OBJPROP_FONT, "Segoe UI Bold");
      ObjectSetInteger(0, "RM_SMX_Main", OBJPROP_XDISTANCE, 20);
      ObjectSetInteger(0, "RM_SMX_Main", OBJPROP_ZORDER, 90);
   }
   ObjectSetString(0, "RM_SMX_Main", OBJPROP_TEXT, smxText);
   ObjectSetInteger(0, "RM_SMX_Main", OBJPROP_COLOR, smxClr);
   ObjectSetInteger(0, "RM_SMX_Main", OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, "RM_SMX_Main", OBJPROP_YDISTANCE, pricePixY);

   ChartRedraw(0);
}

void RemoveSmxLabel()
{
   ObjectsDeleteAll(0, "RM_SMX_");
   ChartRedraw(0);
}

void ToggleSmx()
{
   g_smxActive = !g_smxActive;
   if(g_smxActive) PlotSmxLabel(); else RemoveSmxLabel();
   ObjectSetInteger(0, "RM_BtnSMX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSMX"));
   ChartRedraw(0);
}

void UpdateSmxLabel()
{
   if(!g_smxActive) return;
   PlotSmxLabel();
}

void UpdateSmxTick()
{
   if(!g_smxActive) return;
   if(ObjectFind(0, "RM_SMX_Main") < 0) return;

   double smxTop = g_tt_swingHigh;
   double smxBot = g_tt_swingLow;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double smxRange = smxTop - smxBot;
   bool isFair = (smxRange > 0 && bid >= smxBot && bid <= smxTop);
   string fuText = isFair ? "F" : "U";

   int smxLevel = 0;
   if(smxRange > 0)
   {
      double smxPct = (bid - smxBot) / smxRange * 100.0;
      smxLevel = (int)MathRound(smxPct);
   }

   // Real-time BOS: use bar-0 extremes to catch wicks even if bid pulled back
   double b0Lo = iLow(_Symbol, PERIOD_M15, 0);
   double b0Hi = iHigh(_Symbol, PERIOD_M15, 0);
   int eTrend = g_tt_tTrend;
   double anchorPrice;
   if(g_tt_tTrend == 1 && (bid < smxBot || b0Lo < smxBot))       { eTrend = 2; anchorPrice = smxTop; }
   else if(g_tt_tTrend == 2 && (bid > smxTop || b0Hi > smxTop))  { eTrend = 1; anchorPrice = smxBot; }
   else { anchorPrice = (g_tt_tTrend == 1) ? g_tt_lastBosSwL : g_tt_lastBosSwH; }
   if(anchorPrice <= 0) anchorPrice = bid;

   bool deepRet = isFair && ((eTrend == 2 && smxLevel >= 67) || (eTrend == 1 && smxLevel <= 33));
   int baseFontSize = 28;
   int fontSize = deepRet ? 36 : ((smxLevel > 100 || smxLevel < 0) ? 18 : baseFontSize);
   color smxClr = (eTrend == 1) ? C'0,150,130' : C'200,80,50';
   string smxText = fuText + " " + IntegerToString(smxLevel) + (deepRet ? " !" : "");
   int pricePixX, pricePixY;
   ChartTimePriceToXY(0, 0, TimeCurrent(), anchorPrice, pricePixX, pricePixY);

   ObjectSetString(0, "RM_SMX_Main", OBJPROP_TEXT, smxText);
   ObjectSetInteger(0, "RM_SMX_Main", OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, "RM_SMX_Main", OBJPROP_COLOR, smxClr);
   ObjectSetInteger(0, "RM_SMX_Main", OBJPROP_YDISTANCE, pricePixY);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| H4.MTX — H4 Swing Matrix (last two swings method)               |
//+------------------------------------------------------------------+
void PlotH4MtxLabel()
{
   if(!g_h4MtxActive) { RemoveH4MtxLabel(); return; }

   double top = g_h4_swingHigh;
   double bot = g_h4_swingLow;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double rng = top - bot;
   bool isFair = (rng > 0 && bid >= bot && bid <= top);
   string fuText = isFair ? "F" : "U";

   int level = 0;
   if(rng > 0)
   {
      double pct = (bid - bot) / rng * 100.0;
      level = (int)MathRound(pct);
   }

   // Real-time BOS: use bar-0 extremes to catch wicks even if bid pulled back
   double b0Lo = iLow(_Symbol, PERIOD_H1, 0);
   double b0Hi = iHigh(_Symbol, PERIOD_H1, 0);
   int eTrend = g_h4_tTrend;
   double anchorPrice;
   if(g_h4_tTrend == 1 && (bid < bot || b0Lo < bot))       { eTrend = 2; anchorPrice = top; }
   else if(g_h4_tTrend == 2 && (bid > top || b0Hi > top))  { eTrend = 1; anchorPrice = bot; }
   else { anchorPrice = (g_h4_tTrend == 1) ? g_h4_lastBosSwL : g_h4_lastBosSwH; }
   if(anchorPrice <= 0) anchorPrice = bid;

   bool deepRet = isFair && ((eTrend == 2 && level >= 67) || (eTrend == 1 && level <= 33));
   int baseFontSize = 28;
   int fontSize = deepRet ? 36 : ((level > 100 || level < 0) ? 18 : baseFontSize);
   color clr = (eTrend == 1) ? C'0,130,180' : C'180,60,120';
   string txt = fuText + " " + IntegerToString(level) + (deepRet ? " !" : "");
   int pricePixX, pricePixY;
   ChartTimePriceToXY(0, 0, TimeCurrent(), anchorPrice, pricePixX, pricePixY);

   if(ObjectFind(0, "RM_H4MX_Main") < 0)
   {
      CreateLabel("RM_H4MX_Main", 0, 0, txt, clr, fontSize);
      ObjectSetInteger(0, "RM_H4MX_Main", OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, "RM_H4MX_Main", OBJPROP_ANCHOR, ANCHOR_RIGHT);
      ObjectSetString(0, "RM_H4MX_Main", OBJPROP_FONT, "Segoe UI Bold");
      ObjectSetInteger(0, "RM_H4MX_Main", OBJPROP_XDISTANCE, 80);
      ObjectSetInteger(0, "RM_H4MX_Main", OBJPROP_ZORDER, 90);
   }
   ObjectSetString(0, "RM_H4MX_Main", OBJPROP_TEXT, txt);
   ObjectSetInteger(0, "RM_H4MX_Main", OBJPROP_COLOR, clr);
   ObjectSetInteger(0, "RM_H4MX_Main", OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, "RM_H4MX_Main", OBJPROP_YDISTANCE, pricePixY);

   ChartRedraw(0);
}

void RemoveH4MtxLabel()
{
   ObjectsDeleteAll(0, "RM_H4MX_");
   ChartRedraw(0);
}

void ToggleH4Mtx()
{
   g_h4MtxActive = !g_h4MtxActive;
   if(g_h4MtxActive) PlotH4MtxLabel(); else RemoveH4MtxLabel();
   ObjectSetInteger(0, "RM_BtnH4MX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnH4MX"));
   ChartRedraw(0);
}

void UpdateH4MtxLabel()
{
   if(!g_h4MtxActive) return;
   PlotH4MtxLabel();
}

void UpdateH4MtxTick()
{
   if(!g_h4MtxActive) return;
   if(ObjectFind(0, "RM_H4MX_Main") < 0) return;

   double top = g_h4_swingHigh;
   double bot = g_h4_swingLow;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double rng = top - bot;
   bool isFair = (rng > 0 && bid >= bot && bid <= top);
   string fuText = isFair ? "F" : "U";

   int level = 0;
   if(rng > 0)
   {
      double pct = (bid - bot) / rng * 100.0;
      level = (int)MathRound(pct);
   }

   // Real-time BOS: use bar-0 extremes to catch wicks even if bid pulled back
   double b0Lo = iLow(_Symbol, PERIOD_H1, 0);
   double b0Hi = iHigh(_Symbol, PERIOD_H1, 0);
   int eTrend = g_h4_tTrend;
   double anchorPrice;
   if(g_h4_tTrend == 1 && (bid < bot || b0Lo < bot))       { eTrend = 2; anchorPrice = top; }
   else if(g_h4_tTrend == 2 && (bid > top || b0Hi > top))  { eTrend = 1; anchorPrice = bot; }
   else { anchorPrice = (g_h4_tTrend == 1) ? g_h4_lastBosSwL : g_h4_lastBosSwH; }
   if(anchorPrice <= 0) anchorPrice = bid;

   bool deepRet = isFair && ((eTrend == 2 && level >= 67) || (eTrend == 1 && level <= 33));
   int baseFontSize = 28;
   int fontSize = deepRet ? 36 : ((level > 100 || level < 0) ? 18 : baseFontSize);
   color clr = (eTrend == 1) ? C'0,130,180' : C'180,60,120';
   string txt = fuText + " " + IntegerToString(level) + (deepRet ? " !" : "");
   int pricePixX, pricePixY;
   ChartTimePriceToXY(0, 0, TimeCurrent(), anchorPrice, pricePixX, pricePixY);

   ObjectSetString(0, "RM_H4MX_Main", OBJPROP_TEXT, txt);
   ObjectSetInteger(0, "RM_H4MX_Main", OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, "RM_H4MX_Main", OBJPROP_COLOR, clr);
   ObjectSetInteger(0, "RM_H4MX_Main", OBJPROP_YDISTANCE, pricePixY);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//|          H1 THRUST STRUCTURE - TEST SYSTEM                       |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Walk M15 bars and compute all thrust/BOS/flow/swing/VS state     |
//+------------------------------------------------------------------+
void ComputeThrust()
{
   int bars = iBars(_Symbol, PERIOD_M15);
   if(bars < 10) return;

   int lookback = MathMin(bars - 5, TT_LOOKBACK);

   // Reset state
   g_tt_tFlow = 1;  g_tt_tTrend = 1;
   g_tt_swingHigh = 0;  g_tt_swingLow = 0;
   g_tt_swingHighTime = 0;  g_tt_swingLowTime = 0;
   g_tt_highPH = 0;  g_tt_lowPH = 0;
   g_tt_highTH = 0;  g_tt_lowTH = 0;
   g_tt_check4UpBos = false;  g_tt_check4DnBos = false;
   g_tt_thrCount = 0;  g_tt_pivCount = 0;  g_tt_swDotCount = 0;
   g_tt_bosLabelCount = 0;
   g_tt_lastBosSwH = 0;  g_tt_lastBosSwL = 0;  g_tt_lastBosTime = 0;
   g_tt_lastBosSwHTime = 0;  g_tt_lastBosSwLTime = 0;
   g_tt_lastChochTime = 0; g_tt_lastChochSwH = 0; g_tt_lastChochSwL = 0;
   g_tt_lastChochSwHTime = 0; g_tt_lastChochSwLTime = 0; g_tt_lastChochIsHigh = false;
   g_tt_lastContBosTime = 0; g_tt_lastContBosSwH = 0; g_tt_lastContBosSwL = 0;
   g_tt_lastContBosSwHTime = 0; g_tt_lastContBosSwLTime = 0; g_tt_lastContBosIsHigh = false;
   ArrayResize(g_tt_thrLines, 0);
   ArrayResize(g_tt_pivMarks, 0);
   ArrayResize(g_tt_swDots, 0);
   ArrayResize(g_tt_bosLabels, 0);
   int bosCount = 0;

   // Walk oldest â†’ newest
   for(int i = lookback; i >= 0; i--)
   {
      double hi  = iHigh(_Symbol, PERIOD_M15, i);
      double lo  = iLow(_Symbol, PERIOD_M15, i);
      double cl  = iClose(_Symbol, PERIOD_M15, i);
      double hi1 = iHigh(_Symbol, PERIOD_M15, i+1);
      double lo1 = iLow(_Symbol, PERIOD_M15, i+1);
      double hi2 = iHigh(_Symbol, PERIOD_M15, i+2);
      double lo2 = iLow(_Symbol, PERIOD_M15, i+2);
      double hi3 = iHigh(_Symbol, PERIOD_M15, i+3);
      double lo3 = iLow(_Symbol, PERIOD_M15, i+3);
      double hi4 = iHigh(_Symbol, PERIOD_M15, i+4);
      double lo4 = iLow(_Symbol, PERIOD_M15, i+4);
      datetime t = iTime(_Symbol, PERIOD_M15, i);

      // â”€â”€ Pivot detection â”€â”€
      bool isPivLow  = (lo <= lo1 && lo <= lo2 && lo <= lo3 && lo <= lo4);
      bool isPivHigh = (hi >= hi1 && hi >= hi2 && hi >= hi3 && hi >= hi4);

      if(isPivLow)
      {
         g_tt_lowTH = t;
         g_tt_lowPH = lo;
         int idx = g_tt_pivCount;
         ArrayResize(g_tt_pivMarks, idx + 1);
         g_tt_pivMarks[idx].time   = t;
         g_tt_pivMarks[idx].price  = lo;
         g_tt_pivMarks[idx].isHigh = false;
         g_tt_pivCount++;
      }
      if(isPivHigh)
      {
         g_tt_highTH = t;
         g_tt_highPH = hi;
         int idx = g_tt_pivCount;
         ArrayResize(g_tt_pivMarks, idx + 1);
         g_tt_pivMarks[idx].time   = t;
         g_tt_pivMarks[idx].price  = hi;
         g_tt_pivMarks[idx].isHigh = true;
         g_tt_pivCount++;
      }

      // â”€â”€ 4-bar extremes (bars [i+1]..[i+4]) â”€â”€
      double highestHighof4 = MathMax(MathMax(hi1, hi2), MathMax(hi3, hi4));
      double lowestLowof4   = MathMin(MathMin(lo1, lo2), MathMin(lo3, lo4));

      // â”€â”€ Thrust: Down (first pass) â”€â”€
      if(g_tt_tFlow == 1 && lo < lowestLowof4 && g_tt_highPH > 0)
      {
         g_tt_swingHigh = g_tt_highPH;
         g_tt_swingHighTime = g_tt_highTH;
         g_tt_tFlow = 2;
         g_tt_check4UpBos = true;
         int idx = g_tt_thrCount;
         ArrayResize(g_tt_thrLines, idx + 1);
         g_tt_thrLines[idx].time  = g_tt_highTH;
         g_tt_thrLines[idx].price = g_tt_swingHigh;
         g_tt_thrLines[idx].clr   = C'128,128,0';
         g_tt_thrCount++;
      }

      // â”€â”€ Thrust: Up â”€â”€
      if(g_tt_tFlow == 2 && hi > highestHighof4 && g_tt_lowPH > 0)
      {
         g_tt_swingLow = g_tt_lowPH;
         g_tt_swingLowTime = g_tt_lowTH;
         g_tt_tFlow = 1;
         g_tt_check4DnBos = true;
         int idx = g_tt_thrCount;
         ArrayResize(g_tt_thrLines, idx + 1);
         g_tt_thrLines[idx].time  = g_tt_lowTH;
         g_tt_thrLines[idx].price = g_tt_swingLow;
         g_tt_thrLines[idx].clr   = C'128,128,0';
         g_tt_thrCount++;
      }

      // â”€â”€ Thrust: Down (second pass â€“ same-bar reversal) â”€â”€
      if(g_tt_tFlow == 1 && lo < lowestLowof4 && g_tt_highPH > 0)
      {
         g_tt_swingHigh = g_tt_highPH;
         g_tt_swingHighTime = g_tt_highTH;
         g_tt_tFlow = 2;
         g_tt_check4UpBos = true;
         int idx = g_tt_thrCount;
         ArrayResize(g_tt_thrLines, idx + 1);
         g_tt_thrLines[idx].time  = g_tt_highTH;
         g_tt_thrLines[idx].price = g_tt_swingHigh;
         g_tt_thrLines[idx].clr   = C'128,128,0';
         g_tt_thrCount++;
      }

      // â”€â”€ BOS: Up â”€â”€
      if(g_tt_check4UpBos && hi > g_tt_swingHigh)
      {
         g_tt_check4UpBos = false;
         color bosClr = (g_tt_tTrend == 2) ? C'128,0,0' : C'0,128,0';
         // Recolor the THRS line for the RESPONSIBLE swing: the swing LOW
         // that launched the rally that broke the high. The broken swing
         // high itself is NOT colored.
         for(int k = g_tt_thrCount - 1; k >= 0; k--)
         {
            if(g_tt_thrLines[k].price == g_tt_swingLow)
            {
               g_tt_thrLines[k].clr = bosClr;
               break;
            }
         }
         // BOS count tracking: CHCH=#1, continuation=#2+
         if(g_tt_tTrend == 2) // CHCH (was bearish, now bullish)
            bosCount = 1;
         else
            bosCount++;
         // Label below the swing low responsible for this up BOS
         {
            int bi = g_tt_bosLabelCount;
            ArrayResize(g_tt_bosLabels, bi + 1);
            g_tt_bosLabels[bi].time   = g_tt_swingLowTime;
            g_tt_bosLabels[bi].price  = g_tt_swingLow;
            g_tt_bosLabels[bi].isHigh = false;
            g_tt_bosLabels[bi].count  = bosCount;
            g_tt_bosLabelCount++;
         }
         g_tt_lastBosSwH  = g_tt_swingHigh;
         g_tt_lastBosSwL  = g_tt_swingLow;
         g_tt_lastBosTime = t;
         g_tt_lastBosSwHTime = g_tt_swingHighTime;
         g_tt_lastBosSwLTime = g_tt_swingLowTime;
         // Bet-function tracking: split CHOCH vs continuation BOS
         if(g_tt_tTrend == 2)
         {
            g_tt_lastChochTime    = t;
            g_tt_lastChochSwH     = g_tt_swingHigh;
            g_tt_lastChochSwL     = g_tt_swingLow;
            g_tt_lastChochSwHTime = g_tt_swingHighTime;
            g_tt_lastChochSwLTime = g_tt_swingLowTime;
            g_tt_lastChochIsHigh  = true;
         }
         else
         {
            g_tt_lastContBosTime    = t;
            g_tt_lastContBosSwH     = g_tt_swingHigh;
            g_tt_lastContBosSwL     = g_tt_swingLow;
            g_tt_lastContBosSwHTime = g_tt_swingHighTime;
            g_tt_lastContBosSwLTime = g_tt_swingLowTime;
            g_tt_lastContBosIsHigh  = true;
         }
         g_tt_tTrend = 1;
      }

      // â”€â”€ BOS: Down â”€â”€
      if(g_tt_check4DnBos && lo < g_tt_swingLow)
      {
         g_tt_check4DnBos = false;
         color bosClr = (g_tt_tTrend == 1) ? C'128,0,0' : C'0,128,0';
         // Recolor the THRS line for the RESPONSIBLE swing: the swing HIGH
         // that launched the sell-off that broke the low.
         for(int k = g_tt_thrCount - 1; k >= 0; k--)
         {
            if(g_tt_thrLines[k].price == g_tt_swingHigh)
            {
               g_tt_thrLines[k].clr = bosClr;
               break;
            }
         }
         // BOS count tracking: CHCH=#1, continuation=#2+
         if(g_tt_tTrend == 1) // CHCH (was bullish, now bearish)
            bosCount = 1;
         else
            bosCount++;
         // Label above the swing high responsible for this down BOS
         {
            int bi = g_tt_bosLabelCount;
            ArrayResize(g_tt_bosLabels, bi + 1);
            g_tt_bosLabels[bi].time   = g_tt_swingHighTime;
            g_tt_bosLabels[bi].price  = g_tt_swingHigh;
            g_tt_bosLabels[bi].isHigh = true;
            g_tt_bosLabels[bi].count  = bosCount;
            g_tt_bosLabelCount++;
         }
         g_tt_lastBosSwH  = g_tt_swingHigh;
         g_tt_lastBosSwL  = g_tt_swingLow;
         g_tt_lastBosTime = t;
         g_tt_lastBosSwHTime = g_tt_swingHighTime;
         g_tt_lastBosSwLTime = g_tt_swingLowTime;
         // Bet-function tracking
         if(g_tt_tTrend == 1)
         {
            g_tt_lastChochTime    = t;
            g_tt_lastChochSwH     = g_tt_swingHigh;
            g_tt_lastChochSwL     = g_tt_swingLow;
            g_tt_lastChochSwHTime = g_tt_swingHighTime;
            g_tt_lastChochSwLTime = g_tt_swingLowTime;
            g_tt_lastChochIsHigh  = false;
         }
         else
         {
            g_tt_lastContBosTime    = t;
            g_tt_lastContBosSwH     = g_tt_swingHigh;
            g_tt_lastContBosSwL     = g_tt_swingLow;
            g_tt_lastContBosSwHTime = g_tt_swingHighTime;
            g_tt_lastContBosSwLTime = g_tt_swingLowTime;
            g_tt_lastContBosIsHigh  = false;
         }
         g_tt_tTrend = 2;
      }

      // â”€â”€ Record per-bar swing dot â”€â”€
      if(g_tt_swingHigh > 0 && g_tt_swingLow > 0)
      {
         int di = g_tt_swDotCount;
         ArrayResize(g_tt_swDots, di + 1);
         g_tt_swDots[di].time = t;
         g_tt_swDots[di].swH  = g_tt_swingHigh;
         g_tt_swDots[di].swL  = g_tt_swingLow;
         // Color = last thrust line color (most recent BOS result)
         g_tt_swDots[di].clr  = (g_tt_thrCount > 0) ? g_tt_thrLines[g_tt_thrCount - 1].clr : C'128,128,0';
         g_tt_swDotCount++;
      }
   }

   // â”€â”€ Flow level (from bar 0's [1..4] context) â”€â”€
   double hh4 = 0, ll4 = DBL_MAX;
   for(int j = 1; j <= 4; j++)
   {
      double h = iHigh(_Symbol, PERIOD_M15, j);
      double l = iLow(_Symbol, PERIOD_M15, j);
      if(h > hh4) hh4 = h;
      if(l < ll4) ll4 = l;
   }
   g_tt_flowLevel = (g_tt_tFlow == 1) ? ll4 : hh4;

   // â”€â”€ VS trend level â”€â”€
   double cl0 = iClose(_Symbol, PERIOD_M15, 0);
   g_tt_vsValid = false;
   g_tt_vsLevel = 0;
   if(g_tt_tFlow == 1 && cl0 > g_tt_swingHigh && g_tt_swingLow > 0)
   {
      g_tt_vsLevel = cl0 + (cl0 - g_tt_swingLow);
      g_tt_vsValid = true;
   }
   else if(g_tt_tFlow == 2 && cl0 < g_tt_swingLow && g_tt_swingHigh > 0)
   {
      g_tt_vsLevel = cl0 - (g_tt_swingHigh - cl0);
      g_tt_vsValid = true;
   }

   g_tt_lastBars = bars;
}

//+------------------------------------------------------------------+
//| Pivot markers                                                    |
//+------------------------------------------------------------------+
void PlotTTPivots()
{
   RemoveTTPivots();
   for(int i = 0; i < g_tt_pivCount; i++)
   {
      string name = StringFormat("RM_TT_PIV_%d", i);
      ObjectCreate(0, name, OBJ_ARROW, 0, g_tt_pivMarks[i].time, g_tt_pivMarks[i].price);
      if(g_tt_pivMarks[i].isHigh)
      {
         ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 218);
         ObjectSetInteger(0, name, OBJPROP_COLOR, C'0,150,255');
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
      }
      else
      {
         ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 217);
         ObjectSetInteger(0, name, OBJPROP_COLOR, C'255,150,0');
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_TOP);
      }
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }
   ChartRedraw(0);
}
void RemoveTTPivots() { ObjectsDeleteAll(0, "RM_TT_PIV_"); }

//+------------------------------------------------------------------+
//| Thrust lines (short horizontal segments at swing points)         |
//+------------------------------------------------------------------+
void PlotTTThrust()
{
   RemoveTTThrust();
   for(int i = 0; i < g_tt_thrCount; i++)
   {
      string name = StringFormat("RM_TT_THR_%d", i);
      datetime t1 = g_tt_thrLines[i].time;
      datetime t2 = t1 + 3 * PeriodSeconds(PERIOD_M15);
      color clr = C'128,128,0';  // default olive
      if(g_tt_bosActive)
      {
         color rawClr = g_tt_thrLines[i].clr;
         if(rawClr == C'0,128,0')        clr = rawClr;           // continuation BOS = green
         else if(rawClr == C'128,0,0')   clr = g_tt_chochActive ? rawClr : C'128,128,0';  // CHoCH: maroon or olive
      }
      ObjectCreate(0, name, OBJ_TREND, 0, t1, g_tt_thrLines[i].price,
                   t2, g_tt_thrLines[i].price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 6);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }
   ChartRedraw(0);
}
void RemoveTTThrust() { ObjectsDeleteAll(0, "RM_TT_THR_"); }

//+------------------------------------------------------------------+
//| BOS count labels (number at each continuation BOS)               |
//+------------------------------------------------------------------+
void PlotTTBosCount()
{
   RemoveTTBosCount();
   for(int i = 0; i < g_tt_bosLabelCount; i++)
   {
      string name = StringFormat("RM_TT_BC_%d", i);
      ObjectCreate(0, name, OBJ_TEXT, 0, g_tt_bosLabels[i].time, g_tt_bosLabels[i].price);
      ObjectSetString(0, name, OBJPROP_TEXT, IntegerToString(g_tt_bosLabels[i].count));
      ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 28);
      ObjectSetInteger(0, name, OBJPROP_COLOR, C'0,180,0');
      if(g_tt_bosLabels[i].isHigh)
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LOWER);
      else
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
   }
   ChartRedraw(0);
}
void RemoveTTBosCount() { ObjectsDeleteAll(0, "RM_TT_BC_"); }

//+------------------------------------------------------------------+
//| Swing Retracement line (S.RT – dashed, gold, extends right)      |
//+------------------------------------------------------------------+
void ToggleTTSRet()
{
   g_tt_sretActive = !g_tt_sretActive;
   if(g_tt_sretActive) { EnsureThrustComputed(); PlotTTSRet(); }
   else RemoveTTSRet();
   ObjectSetInteger(0, "RM_BtnSRET", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSRET"));
   ChartRedraw(0);
}
void PlotTTSRet()
{
   RemoveTTSRet();
   if(g_tt_lastBosSwH == 0 && g_tt_lastBosSwL == 0) return;
   if(g_tt_lastBosTime == 0) return;

   double level = 0;

   if(g_tt_tTrend == 1 && g_tt_lastBosSwL > 0)
   {
      // Bullish: find highest high since BOS swing high, retrace 67% toward swing low (SL)
      int swBar = iBarShift(_Symbol, PERIOD_M15, (g_tt_lastBosSwHTime > 0) ? g_tt_lastBosSwHTime : g_tt_lastBosTime);
      if(swBar < 0) swBar = 0;
      double hh = 0;
      for(int j = 0; j <= swBar; j++)
      {
         double h = iHigh(_Symbol, PERIOD_M15, j);
         if(h > hh) hh = h;
      }
      if(hh > g_tt_lastBosSwL)
         level = hh - (hh - g_tt_lastBosSwL) * 2.0 / 3.0;
   }
   else if(g_tt_tTrend == 2 && g_tt_lastBosSwH > 0)
   {
      // Bearish: find lowest low since BOS swing low, retrace 67% toward swing high (SL)
      int swBar = iBarShift(_Symbol, PERIOD_M15, (g_tt_lastBosSwLTime > 0) ? g_tt_lastBosSwLTime : g_tt_lastBosTime);
      if(swBar < 0) swBar = 0;
      double ll = DBL_MAX;
      for(int j = 0; j <= swBar; j++)
      {
         double l = iLow(_Symbol, PERIOD_M15, j);
         if(l < ll) ll = l;
      }
      if(g_tt_lastBosSwH > ll)
         level = ll + (g_tt_lastBosSwH - ll) * 2.0 / 3.0;
   }
   if(level == 0) return;

   string name = "RM_TT_SRET_0";
   datetime t = iTime(_Symbol, PERIOD_M15, 0);
   ObjectCreate(0, name, OBJ_TREND, 0, t, level,
                t + PeriodSeconds(PERIOD_M15), level);
   ObjectSetInteger(0, name, OBJPROP_COLOR, C'180,80,20');
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ChartRedraw(0);
}
void RemoveTTSRet() { ObjectsDeleteAll(0, "RM_TT_SRET_"); }

//+------------------------------------------------------------------+
//| DRange — last swing high/low projected 6 candles into the future |
//| with a dealing-range % label (swingRange / prevDailyRange).      |
//| Label sits BELOW the swing low in uptrend, ABOVE the swing high  |
//| in downtrend. Line color matches the last swing-dot color so it  |
//| follows BOS/CHOCH state (olive / green / maroon).                |
//+------------------------------------------------------------------+
void PlotTTDRange()
{
   RemoveTTDRange();
   if(!g_tt_drangeActive) return;
   if(g_tt_swingHigh <= 0 || g_tt_swingLow <= 0) return;
   if(g_tt_swingHigh <= g_tt_swingLow) return;

   // Color: match the latest swing-dot color (== last thrust line color).
   // Fallback to olive (pending) if no dots yet.
   color clr = C'128,128,0';
   if(g_tt_swDotCount > 0) clr = g_tt_swDots[g_tt_swDotCount - 1].clr;

   datetime t0 = iTime(_Symbol, PERIOD_M15, 0);
   if(t0 == 0) return;
   datetime t1 = t0 + 6 * PeriodSeconds(PERIOD_M15);

   // High projection line
   string nH = "RM_TT_DR_H";
   ObjectCreate(0, nH, OBJ_TREND, 0, t0, g_tt_swingHigh, t1, g_tt_swingHigh);
   ObjectSetInteger(0, nH, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, nH, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, nH, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, nH, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nH, OBJPROP_BACK, true);
   ObjectSetInteger(0, nH, OBJPROP_SELECTABLE, false);

   // Low projection line
   string nL = "RM_TT_DR_L";
   ObjectCreate(0, nL, OBJ_TREND, 0, t0, g_tt_swingLow, t1, g_tt_swingLow);
   ObjectSetInteger(0, nL, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, nL, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, nL, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, nL, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nL, OBJPROP_BACK, true);
   ObjectSetInteger(0, nL, OBJPROP_SELECTABLE, false);

   // Dealing-range % = swingRange / prevDailyRange
   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, daily) < 1) { ChartRedraw(0); return; }
   double prevRange = daily[0].high - daily[0].low;
   if(prevRange <= 0) { ChartRedraw(0); return; }
   double swingRange = g_tt_swingHigh - g_tt_swingLow;
   double pct = (swingRange / prevRange) * 100.0;

   // Label position: bottom in uptrend, top in downtrend.
   // ANCHOR_UPPER  = anchor at top of text   -> text drops below the anchor price
   // ANCHOR_LOWER  = anchor at bottom of text -> text rises above the anchor price
   bool isUp        = (g_tt_tTrend == 1);
   double lblPrice  = isUp ? g_tt_swingLow : g_tt_swingHigh;
   datetime lblTime = t0 + 3 * PeriodSeconds(PERIOD_M15);  // centered in the 6-bar projection

   string lbl = "RM_TT_DR_LBL";
   ObjectCreate(0, lbl, OBJ_TEXT, 0, lblTime, lblPrice);
   ObjectSetString(0, lbl, OBJPROP_TEXT, StringFormat("%.0f%%", pct));
   ObjectSetString(0, lbl, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 11);
   ObjectSetInteger(0, lbl, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, isUp ? ANCHOR_UPPER : ANCHOR_LOWER);
   ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, lbl, OBJPROP_BACK, true);

   ChartRedraw(0);
}
void RemoveTTDRange() { ObjectsDeleteAll(0, "RM_TT_DR_"); }

void ToggleTTDRange()
{
   g_tt_drangeActive = !g_tt_drangeActive;
   if(g_tt_drangeActive) { EnsureThrustComputed(); PlotTTDRange(); }
   else                  RemoveTTDRange();
   ObjectSetInteger(0, "RM_BtnDRNG", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDRNG"));
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Flow line (aqua, extends right)                                  |
//+------------------------------------------------------------------+
void PlotTTFlow()
{
   RemoveTTFlow();
   if(g_tt_flowLevel == 0) return;
   string name = "RM_TT_FLW_0";
   // Anchor to end of current day (17:00 NY = next day start for forex)
   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 23; dt.min = 59; dt.sec = 0;
   datetime dayEnd = StructToTime(dt);
   ObjectCreate(0, name, OBJ_TREND, 0, dayEnd, g_tt_flowLevel,
                dayEnd + PeriodSeconds(PERIOD_M15), g_tt_flowLevel);
   ObjectSetInteger(0, name, OBJPROP_COLOR, C'100,140,160');
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   // Label
   string lbl = "RM_TT_FLWL_0";
   string dir = (g_tt_tFlow == 1) ? "H1.F\x25B2" : "H1.F\x25BC";
   ObjectCreate(0, lbl, OBJ_TEXT, 0, dayEnd, g_tt_flowLevel);
   ObjectSetString(0, lbl, OBJPROP_TEXT, dir);
   ObjectSetString(0, lbl, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 12);
   ObjectSetInteger(0, lbl, OBJPROP_COLOR, C'100,140,160');
   ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
   ChartRedraw(0);
}
void RemoveTTFlow() { ObjectsDeleteAll(0, "RM_TT_FLW_"); ObjectsDeleteAll(0, "RM_TT_FLWL_"); }

//+------------------------------------------------------------------+
//| Swing H/L â€” dotted trend-line segments at swing levels           |
//+------------------------------------------------------------------+
void PlotTTSwing()
{
   RemoveTTSwing();
   if(g_tt_swDotCount < 2) return;

   // Mode: 1=solid lines, 2=dots
   ENUM_LINE_STYLE sty = (g_tt_swingMode == 1) ? STYLE_SOLID : STYLE_DOT;
   int             wid = (g_tt_swingMode == 1) ? 2 : 1;

   // --- Swing High segments (independent pass) ---
   int segH = 0;
   int i = 0;
   while(i < g_tt_swDotCount)
   {
      int j = i + 1;
      while(j < g_tt_swDotCount &&
            g_tt_swDots[j].swH == g_tt_swDots[i].swH &&
            g_tt_swDots[j].clr == g_tt_swDots[i].clr)
         j++;
      if(j - 1 > i)
      {
         string nH = StringFormat("RM_TT_SW_H%d", segH++);
         ObjectCreate(0, nH, OBJ_TREND, 0,
                      g_tt_swDots[i].time, g_tt_swDots[i].swH,
                      g_tt_swDots[j - 1].time, g_tt_swDots[i].swH);
         ObjectSetInteger(0, nH, OBJPROP_COLOR, g_tt_swDots[i].clr);
         ObjectSetInteger(0, nH, OBJPROP_STYLE, sty);
         ObjectSetInteger(0, nH, OBJPROP_WIDTH, wid);
         ObjectSetInteger(0, nH, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, nH, OBJPROP_BACK, true);
         ObjectSetInteger(0, nH, OBJPROP_SELECTABLE, false);
      }
      i = j;
   }

   // --- Swing Low segments (independent pass) ---
   int segL = 0;
   i = 0;
   while(i < g_tt_swDotCount)
   {
      int j = i + 1;
      while(j < g_tt_swDotCount &&
            g_tt_swDots[j].swL == g_tt_swDots[i].swL &&
            g_tt_swDots[j].clr == g_tt_swDots[i].clr)
         j++;
      if(j - 1 > i)
      {
         string nL = StringFormat("RM_TT_SW_L%d", segL++);
         ObjectCreate(0, nL, OBJ_TREND, 0,
                      g_tt_swDots[i].time, g_tt_swDots[i].swL,
                      g_tt_swDots[j - 1].time, g_tt_swDots[i].swL);
         ObjectSetInteger(0, nL, OBJPROP_COLOR, g_tt_swDots[i].clr);
         ObjectSetInteger(0, nL, OBJPROP_STYLE, sty);
         ObjectSetInteger(0, nL, OBJPROP_WIDTH, wid);
         ObjectSetInteger(0, nL, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, nL, OBJPROP_BACK, true);
         ObjectSetInteger(0, nL, OBJPROP_SELECTABLE, false);
      }
      i = j;
   }

   ChartRedraw(0);
}
void RemoveTTSwing() { ObjectsDeleteAll(0, "RM_TT_SW_"); }

//+------------------------------------------------------------------+
//| VS trend line (measured move, red, extends right)                |
//+------------------------------------------------------------------+
void PlotTTVs()
{
   RemoveTTVs();
   if(!g_tt_vsValid || g_tt_vsLevel == 0) return;
   string name = "RM_TT_VS_0";
   datetime t  = iTime(_Symbol, PERIOD_M15, 0);
   ObjectCreate(0, name, OBJ_TREND, 0, t, g_tt_vsLevel,
                t + PeriodSeconds(PERIOD_M15), g_tt_vsLevel);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ChartRedraw(0);
}
void RemoveTTVs() { ObjectsDeleteAll(0, "RM_TT_VS_"); }

//+------------------------------------------------------------------+
//| Toggle helpers                                                   |
//+------------------------------------------------------------------+
void EnsureThrustComputed()
{
   if(g_tt_lastBars == 0) ComputeThrust();
}

void ToggleTTPivots()
{
   g_tt_pivotActive = !g_tt_pivotActive;
   if(g_tt_pivotActive) { EnsureThrustComputed(); PlotTTPivots(); }
   else RemoveTTPivots();
   ObjectSetInteger(0, "RM_BtnPIVT", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnPIVT"));
   ChartRedraw(0);
}

void ToggleTTThrust()
{
   g_tt_thrustActive = !g_tt_thrustActive;
   if(g_tt_thrustActive) { EnsureThrustComputed(); PlotTTThrust(); }
   else RemoveTTThrust();
   ObjectSetInteger(0, "RM_BtnTHRS", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnTHRS"));
   ChartRedraw(0);
}

void ToggleTTBos()
{
   g_tt_bosActive = !g_tt_bosActive;
   if(g_tt_thrustActive) { EnsureThrustComputed(); PlotTTThrust(); }
   ObjectSetInteger(0, "RM_BtnBOS", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnBOS"));
   ChartRedraw(0);
}

void ToggleTTChoch()
{
   g_tt_chochActive = !g_tt_chochActive;
   if(g_tt_thrustActive) { EnsureThrustComputed(); PlotTTThrust(); }
   ObjectSetInteger(0, "RM_BtnCHCH", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnCHCH"));
   ChartRedraw(0);
}

void ToggleTTBosCount()
{
   g_tt_bosCountActive = !g_tt_bosCountActive;
   if(g_tt_bosCountActive) { EnsureThrustComputed(); PlotTTBosCount(); }
   else RemoveTTBosCount();
   ObjectSetInteger(0, "RM_BtnBOSC", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnBOSC"));
   ChartRedraw(0);
}

void ToggleTTFlow()
{
   g_tt_flowActive = !g_tt_flowActive;
   if(g_tt_flowActive) { EnsureThrustComputed(); PlotTTFlow(); }
   else RemoveTTFlow();
   ObjectSetInteger(0, "RM_BtnFLOW", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnFLOW"));
   ChartRedraw(0);
}

void ToggleTTSwing()
{
   g_tt_swingMode = (g_tt_swingMode + 1) % 3;  // 0â†’1â†’2â†’0
   if(g_tt_swingMode > 0) { EnsureThrustComputed(); PlotTTSwing(); }
   else RemoveTTSwing();
   string label = (g_tt_swingMode == 0) ? "SW.HL" : (g_tt_swingMode == 1) ? "SW.HL\x2500" : "SW.HL\x25CF";
   ObjectSetString(0, "RM_BtnSWNG", OBJPROP_TEXT, label);
   ObjectSetInteger(0, "RM_BtnSWNG", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSWNG"));
   ChartRedraw(0);
}

void ToggleTTVs()
{
   g_tt_vsActive = !g_tt_vsActive;
   if(g_tt_vsActive) { EnsureThrustComputed(); PlotTTVs(); }
   else RemoveTTVs();
   ObjectSetInteger(0, "RM_BtnVSTR", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnVSTR"));
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Fair Value rectangles between swing H/L segments                 |
//+------------------------------------------------------------------+
void PlotTTFairValue()
{
   RemoveTTFairValue();
   if(g_tt_swDotCount < 2) return;

   color fvClr = (g_tt_fvMode == 1) ? C'228,235,210' : C'180,200,160';   // subtle / solid
   int seg = 0;
   int i = 0;
   while(i < g_tt_swDotCount)
   {
      // group consecutive bars where both swH and swL are unchanged
      int j = i + 1;
      while(j < g_tt_swDotCount &&
            g_tt_swDots[j].swH == g_tt_swDots[i].swH &&
            g_tt_swDots[j].swL == g_tt_swDots[i].swL)
         j++;
      if(g_tt_swDots[i].swH > g_tt_swDots[i].swL)
      {
         // End time: next segment's start or extend right from last bar
         datetime tEnd = (j < g_tt_swDotCount)
                         ? g_tt_swDots[j].time
                         : g_tt_swDots[j - 1].time + PeriodSeconds(PERIOD_M15);

         string name = StringFormat("RM_TT_FV_%d", seg++);
         ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                      g_tt_swDots[i].time, g_tt_swDots[i].swH,
                      tEnd, g_tt_swDots[i].swL);
         ObjectSetInteger(0, name, OBJPROP_COLOR, fvClr);
         ObjectSetInteger(0, name, OBJPROP_FILL, true);
         ObjectSetInteger(0, name, OBJPROP_BACK, true);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      }
      i = j;
   }
   ChartRedraw(0);
}
void RemoveTTFairValue() { ObjectsDeleteAll(0, "RM_TT_FV_"); }

void ToggleTTFairValue()
{
   g_tt_fvMode = (g_tt_fvMode + 1) % 3;  // 0â†’1â†’2â†’0
   if(g_tt_fvMode > 0) { EnsureThrustComputed(); PlotTTFairValue(); }
   else RemoveTTFairValue();
   string label = (g_tt_fvMode == 0) ? "FV" : (g_tt_fvMode == 1) ? "FV\x25CB" : "FV\x25CF";
   ObjectSetString(0, "RM_BtnFVAL", OBJPROP_TEXT, label);
   ObjectSetInteger(0, "RM_BtnFVAL", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnFVAL"));
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Fair Value Gap â€” new swing vs second-to-last opposite swing      |
//+------------------------------------------------------------------+
void PlotTTFairValueGap()
{
   RemoveTTFairValueGap();
   if(g_tt_swDotCount < 2) return;

   color fvgClr = (g_tt_fvgMode == 1) ? C'240,228,200' : C'210,185,140';   // subtle / solid
   int gapIdx = 0;

   // Preload M15 bars for gap-fill scanning
   double cls[], his[], los[];
   datetime tms[];
   ArraySetAsSeries(cls, true);
   ArraySetAsSeries(his, true);
   ArraySetAsSeries(los, true);
   ArraySetAsSeries(tms, true);
   int totalBars = iBars(_Symbol, PERIOD_M15);
   CopyClose(_Symbol, PERIOD_M15, 0, totalBars, cls);
   CopyHigh(_Symbol, PERIOD_M15, 0, totalBars, his);
   CopyLow(_Symbol, PERIOD_M15, 0, totalBars, los);
   CopyTime(_Symbol, PERIOD_M15, 0, totalBars, tms);

   // Track current and previous (last-last) swing levels
   // prevSwH/prevSwL = last known values
   // prev2SwH/prev2SwL = the values before prevSwH/prevSwL changed
   double prevSwH  = g_tt_swDots[0].swH;
   double prevSwL  = g_tt_swDots[0].swL;
   double prev2SwH = prevSwH;
   double prev2SwL = prevSwL;

   for(int i = 1; i < g_tt_swDotCount; i++)
   {
      double curSwH = g_tt_swDots[i].swH;
      double curSwL = g_tt_swDots[i].swL;

      bool swHChanged = (curSwH != prevSwH);
      bool swLChanged = (curSwL != prevSwL);

      if(!swHChanged && !swLChanged) continue;

      double gapTop = 0, gapBot = 0;
      datetime gapTime = g_tt_swDots[i].time;

      // Engulfing candle: both swH and swL change on the same bar
      // -> compare to the LAST opposite swing (not last-last)
      bool engulfing = (swHChanged && swLChanged);

      // New swing low formed: compare to last-last swH (or last swH if engulfing)
      if(swLChanged)
      {
         double compareH = engulfing ? prevSwH : prev2SwH;
         if(curSwL > compareH)
         {
            gapTop = curSwL;
            gapBot = compareH;
         }
      }

      // New swing high formed: compare to last-last swL (or last swL if engulfing)
      if(swHChanged && gapTop == 0)
      {
         double compareL = engulfing ? prevSwL : prev2SwL;
         if(curSwH < compareL)
         {
            gapTop = compareL;
            gapBot = curSwH;
         }
      }

      // Update history: shift prev -> prev2 when values change
      if(swHChanged) { prev2SwH = prevSwH; prevSwH = curSwH; }
      if(swLChanged) { prev2SwL = prevSwL; prevSwL = curSwL; }

      if(gapTop <= gapBot || gapTop == 0) continue;

      // Scan forward from gap start to find fill (price crosses through gap)
      datetime gapEnd = tms[0] + PeriodSeconds(PERIOD_M15);

      for(int b = totalBars - 1; b >= 0; b--)
      {
         if(tms[b] <= gapTime) continue;
         // Price touches the gap if bar's range overlaps the gap zone
         if(his[b] >= gapBot && los[b] <= gapTop)
         {
            gapEnd = tms[b];
            break;
         }
      }

      string name = StringFormat("RM_TT_FVG_%d", gapIdx++);
      ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                   gapTime, gapTop, gapEnd, gapBot);
      ObjectSetInteger(0, name, OBJPROP_COLOR, fvgClr);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }
   ChartRedraw(0);
}
void RemoveTTFairValueGap() { ObjectsDeleteAll(0, "RM_TT_FVG_"); }

void ToggleTTFairValueGap()
{
   g_tt_fvgMode = (g_tt_fvgMode + 1) % 3;  // 0â†’1â†’2â†’0
   if(g_tt_fvgMode > 0) { EnsureThrustComputed(); PlotTTFairValueGap(); }
   else RemoveTTFairValueGap();
   string label = (g_tt_fvgMode == 0) ? "FVG" : (g_tt_fvgMode == 1) ? "FVG\x25CB" : "FVG\x25CF";
   ObjectSetString(0, "RM_BtnFVGP", OBJPROP_TEXT, label);
   ObjectSetInteger(0, "RM_BtnFVGP", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnFVGP"));
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Refresh TREND button + SWING button colors after trend change    |
//+------------------------------------------------------------------+
void RefreshTrendButtons()
{
   bool isUp = (g_tt_tTrend == 1);
   // TREND button
   ObjectSetInteger(0, "RM_BtnTREND", OBJPROP_BGCOLOR, isUp ? C'0,120,0' : C'150,30,30');
   ObjectSetInteger(0, "RM_BtnTREND", OBJPROP_COLOR,   isUp ? C'140,255,140' : C'255,160,160');
   ObjectSetString(0, "RM_BtnTREND", OBJPROP_TEXT,     isUp ? "TREND\x25B2" : "TREND\x25BC");
   // SWING market buttons
   ObjectSetInteger(0, "RM_BuyMktSw",  OBJPROP_BGCOLOR, isUp ? CLR_BTN_BUY  : CLR_BTN_PLC);
   ObjectSetInteger(0, "RM_BuyMktSw",  OBJPROP_COLOR,   isUp ? CLR_TEXT : CLR_TEXT_DIM);
   ObjectSetInteger(0, "RM_SellMktSw", OBJPROP_BGCOLOR, !isUp ? CLR_BTN_SELL : CLR_BTN_PLC);
   ObjectSetInteger(0, "RM_SellMktSw", OBJPROP_COLOR,   !isUp ? CLR_TEXT : CLR_TEXT_DIM);
   // CHOCH stop buttons (+CHOCH allowed in downtrend, -CHOCH allowed in uptrend)
   ObjectSetInteger(0, "RM_BuyStpCH",  OBJPROP_BGCOLOR, !isUp ? CLR_BTN_BUY  : CLR_BTN_PLC);
   ObjectSetInteger(0, "RM_BuyStpCH",  OBJPROP_COLOR,   !isUp ? CLR_TEXT : CLR_TEXT_DIM);
   ObjectSetInteger(0, "RM_SellStpCH", OBJPROP_BGCOLOR, isUp ? CLR_BTN_SELL : CLR_BTN_PLC);
   ObjectSetInteger(0, "RM_SellStpCH", OBJPROP_COLOR,   isUp ? CLR_TEXT : CLR_TEXT_DIM);
   // Reset CHOCH text and mode when gated
   if(isUp)  { ObjectSetString(0, "RM_BuyStpCH",  OBJPROP_TEXT, "+CHOCH"); g_chochMode = 0; }
   if(!isUp) { ObjectSetString(0, "RM_SellStpCH", OBJPROP_TEXT, "-CHOCH"); g_chochMode = 0; }
   // BOS limit buttons (+BOS allowed in uptrend, -BOS allowed in downtrend)
   ObjectSetInteger(0, "RM_BuyLmtBOS",  OBJPROP_BGCOLOR, isUp ? CLR_BTN_BUY  : CLR_BTN_PLC);
   ObjectSetInteger(0, "RM_BuyLmtBOS",  OBJPROP_COLOR,   isUp ? CLR_TEXT : CLR_TEXT_DIM);
   ObjectSetInteger(0, "RM_SellLmtBOS", OBJPROP_BGCOLOR, !isUp ? CLR_BTN_SELL : CLR_BTN_PLC);
   ObjectSetInteger(0, "RM_SellLmtBOS", OBJPROP_COLOR,   !isUp ? CLR_TEXT : CLR_TEXT_DIM);
   // Reset BOS text and mode when gated
   if(!isUp) { ObjectSetString(0, "RM_BuyLmtBOS",  OBJPROP_TEXT, "+BOS"); g_bosLmtMode = 0; }
   if(isUp)  { ObjectSetString(0, "RM_SellLmtBOS", OBJPROP_TEXT, "-BOS"); g_bosLmtMode = 0; }
   // BS_BO stop buttons (with-trend continuation: +BS_BO in uptrend, -BS_BO in downtrend)
   ObjectSetInteger(0, "RM_BuyStpBK",  OBJPROP_BGCOLOR, isUp ? CLR_BTN_BUY  : CLR_BTN_PLC);
   ObjectSetInteger(0, "RM_BuyStpBK",  OBJPROP_COLOR,   isUp ? CLR_TEXT : CLR_TEXT_DIM);
   ObjectSetInteger(0, "RM_SellStpBK", OBJPROP_BGCOLOR, !isUp ? CLR_BTN_SELL : CLR_BTN_PLC);
   ObjectSetInteger(0, "RM_SellStpBK", OBJPROP_COLOR,   !isUp ? CLR_TEXT : CLR_TEXT_DIM);
   // CH_BO stop buttons (anti-trend reversal: +CH_BO in downtrend, -CH_BO in uptrend)
   ObjectSetInteger(0, "RM_BuyStpCB",  OBJPROP_BGCOLOR, !isUp ? CLR_BTN_BUY  : CLR_BTN_PLC);
   ObjectSetInteger(0, "RM_BuyStpCB",  OBJPROP_COLOR,   !isUp ? CLR_TEXT : CLR_TEXT_DIM);
   ObjectSetInteger(0, "RM_SellStpCB", OBJPROP_BGCOLOR, isUp ? CLR_BTN_SELL : CLR_BTN_PLC);
   ObjectSetInteger(0, "RM_SellStpCB", OBJPROP_COLOR,   isUp ? CLR_TEXT : CLR_TEXT_DIM);

   // Advanced buttons — text grays out when preconditions aren't met
   // (CH_R / BS_R need an unfilled wick FVG; CH_C needs flow+BOS-armed;
   //  UFV needs price beyond the swing on the wrong side).
   ApplyAdvancedBtnGating("RM_BuyLmtChR",  true);
   ApplyAdvancedBtnGating("RM_SellLmtChR", false);
   ApplyAdvancedBtnGating("RM_BuyLmtBoR",  true);
   ApplyAdvancedBtnGating("RM_SellLmtBoR", false);
   ApplyAdvancedBtnGating("RM_BuyStpChC",  true);
   ApplyAdvancedBtnGating("RM_SellStpChC", false);
   ApplyAdvancedBtnGating("RM_BuyMktUFV",  true);
   ApplyAdvancedBtnGating("RM_SellMktUFV", false);
}

//+------------------------------------------------------------------+
//| Update thrust on new M15 bar                                     |
//+------------------------------------------------------------------+
void UpdateThrust()
{
   bool anyActive = g_tt_pivotActive || g_tt_thrustActive || g_tt_bosActive
                  || g_tt_flowActive || (g_tt_swingMode > 0) || g_tt_vsActive
                  || (g_tt_fvMode > 0) || (g_tt_fvgMode > 0) || g_tt_bosCountActive
                  || g_tt_sretActive || g_tt_drangeActive
                  || (g_lastOrderBtn != "" && g_linesActive);  // armed order needs swing refresh
   if(!anyActive) return;

   int bars = iBars(_Symbol, PERIOD_M15);
   if(bars == g_tt_lastBars)
   {
      // Force recompute if bar 0 breaches a swing (instant BOS)
      double b0Hi = iHigh(_Symbol, PERIOD_M15, 0);
      double b0Lo = iLow(_Symbol, PERIOD_M15, 0);
      bool breach = false;
      if(g_tt_check4DnBos && g_tt_swingLow > 0 && b0Lo < g_tt_swingLow) breach = true;
      if(g_tt_check4UpBos && g_tt_swingHigh > 0 && b0Hi > g_tt_swingHigh) breach = true;
      if(!breach) return;
   }

   ComputeThrust();
   RefreshTrendButtons();
   if(g_tt_pivotActive)                     PlotTTPivots();
   if(g_tt_thrustActive || g_tt_bosActive || g_tt_chochActive)  PlotTTThrust();
   if(g_tt_flowActive)                      PlotTTFlow();
   if(g_h4_flowActive)                      PlotH4Flow();
   if(g_tt_swingMode > 0)                    PlotTTSwing();
   if(g_tt_vsActive)                        PlotTTVs();
   if(g_tt_fvMode > 0)                       PlotTTFairValue();
   if(g_tt_fvgMode > 0)                      PlotTTFairValueGap();
   if(g_tt_bosCountActive)                   PlotTTBosCount();
   if(g_tt_sretActive)                       PlotTTSRet();
   if(g_tt_drangeActive)                     PlotTTDRange();
   RerunArmedOrder();   // auto-recalculate lines if an order button is armed
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//|          H4 THRUST STRUCTURE (runs on H1 bars, 4-bar window)     |
//+------------------------------------------------------------------+
void ComputeH4Thrust()
{
   int bars = iBars(_Symbol, PERIOD_H1);
   if(bars < 10) return;

   int lookback = MathMin(bars - 5, H4_LOOKBACK);

   // Reset state
   g_h4_tFlow = 1;  g_h4_tTrend = 1;
   g_h4_swingHigh = 0;  g_h4_swingLow = 0;
   g_h4_swingHighTime = 0;  g_h4_swingLowTime = 0;
   g_h4_highPH = 0;  g_h4_lowPH = 0;
   g_h4_highTH = 0;  g_h4_lowTH = 0;
   g_h4_check4UpBos = false;  g_h4_check4DnBos = false;
   g_h4_thrCount = 0;
   g_h4_lastBosSwH = 0;  g_h4_lastBosSwL = 0;
   ArrayResize(g_h4_thrLines, 0);

   for(int i = lookback; i >= 0; i--)
   {
      double hi  = iHigh(_Symbol, PERIOD_H1, i);
      double lo  = iLow(_Symbol, PERIOD_H1, i);
      double hi1 = iHigh(_Symbol, PERIOD_H1, i+1);
      double lo1 = iLow(_Symbol, PERIOD_H1, i+1);
      double hi2 = iHigh(_Symbol, PERIOD_H1, i+2);
      double lo2 = iLow(_Symbol, PERIOD_H1, i+2);
      double hi3 = iHigh(_Symbol, PERIOD_H1, i+3);
      double lo3 = iLow(_Symbol, PERIOD_H1, i+3);
      double hi4 = iHigh(_Symbol, PERIOD_H1, i+4);
      double lo4 = iLow(_Symbol, PERIOD_H1, i+4);
      datetime t = iTime(_Symbol, PERIOD_H1, i);

      // Pivot detection
      bool isPivLow  = (lo <= lo1 && lo <= lo2 && lo <= lo3 && lo <= lo4);
      bool isPivHigh = (hi >= hi1 && hi >= hi2 && hi >= hi3 && hi >= hi4);
      if(isPivLow)  { g_h4_lowTH = t;  g_h4_lowPH = lo; }
      if(isPivHigh) { g_h4_highTH = t;  g_h4_highPH = hi; }

      // 4-bar extremes
      double highestHighof4 = MathMax(MathMax(hi1, hi2), MathMax(hi3, hi4));
      double lowestLowof4   = MathMin(MathMin(lo1, lo2), MathMin(lo3, lo4));

      // Thrust: Down (first pass)
      if(g_h4_tFlow == 1 && lo < lowestLowof4 && g_h4_highPH > 0)
      {
         g_h4_swingHigh = g_h4_highPH;
         g_h4_swingHighTime = g_h4_highTH;
         g_h4_tFlow = 2;
         g_h4_check4UpBos = true;
         int idx = g_h4_thrCount;
         ArrayResize(g_h4_thrLines, idx + 1);
         g_h4_thrLines[idx].time  = g_h4_highTH;
         g_h4_thrLines[idx].price = g_h4_swingHigh;
         g_h4_thrLines[idx].clr   = C'128,128,0';
         g_h4_thrCount++;
      }

      // Thrust: Up
      if(g_h4_tFlow == 2 && hi > highestHighof4 && g_h4_lowPH > 0)
      {
         g_h4_swingLow = g_h4_lowPH;
         g_h4_swingLowTime = g_h4_lowTH;
         g_h4_tFlow = 1;
         g_h4_check4DnBos = true;
         int idx = g_h4_thrCount;
         ArrayResize(g_h4_thrLines, idx + 1);
         g_h4_thrLines[idx].time  = g_h4_lowTH;
         g_h4_thrLines[idx].price = g_h4_swingLow;
         g_h4_thrLines[idx].clr   = C'128,128,0';
         g_h4_thrCount++;
      }

      // Thrust: Down (second pass — same-bar reversal)
      if(g_h4_tFlow == 1 && lo < lowestLowof4 && g_h4_highPH > 0)
      {
         g_h4_swingHigh = g_h4_highPH;
         g_h4_swingHighTime = g_h4_highTH;
         g_h4_tFlow = 2;
         g_h4_check4UpBos = true;
         int idx = g_h4_thrCount;
         ArrayResize(g_h4_thrLines, idx + 1);
         g_h4_thrLines[idx].time  = g_h4_highTH;
         g_h4_thrLines[idx].price = g_h4_swingHigh;
         g_h4_thrLines[idx].clr   = C'128,128,0';
         g_h4_thrCount++;
      }

      // BOS: Up
      if(g_h4_check4UpBos && hi > g_h4_swingHigh)
      {
         g_h4_check4UpBos = false;
         color bosClr = (g_h4_tTrend == 2) ? C'128,0,0' : C'0,128,0';
         for(int k = g_h4_thrCount - 1; k >= 0; k--)
         {
            if(g_h4_thrLines[k].price == g_h4_swingLow)
            { g_h4_thrLines[k].clr = bosClr; break; }
         }
         g_h4_tTrend = 1;
         g_h4_lastBosSwH = g_h4_swingHigh;
         g_h4_lastBosSwL = g_h4_swingLow;
      }

      // BOS: Down
      if(g_h4_check4DnBos && lo < g_h4_swingLow)
      {
         g_h4_check4DnBos = false;
         color bosClr = (g_h4_tTrend == 1) ? C'128,0,0' : C'0,128,0';
         for(int k = g_h4_thrCount - 1; k >= 0; k--)
         {
            if(g_h4_thrLines[k].price == g_h4_swingHigh)
            { g_h4_thrLines[k].clr = bosClr; break; }
         }
         g_h4_tTrend = 2;
         g_h4_lastBosSwH = g_h4_swingHigh;
         g_h4_lastBosSwL = g_h4_swingLow;
      }
   }

   // -- H4 Flow level (from H1 bar 0's [1..4] context) --
   double h4hh = 0, h4ll = DBL_MAX;
   for(int j = 1; j <= 4; j++)
   {
      double h = iHigh(_Symbol, PERIOD_H1, j);
      double l = iLow(_Symbol, PERIOD_H1, j);
      if(h > h4hh) h4hh = h;
      if(l < h4ll) h4ll = l;
   }
   g_h4_flowLevel = (g_h4_tFlow == 1) ? h4ll : h4hh;

   g_h4_lastBars = bars;
}

//+------------------------------------------------------------------+
//| H4 Thrust lines — thicker (10px) and longer (6 H1 bars)         |
//+------------------------------------------------------------------+
void PlotH4Thrust()
{
   RemoveH4Thrust();
   for(int i = 0; i < g_h4_thrCount; i++)
   {
      string name = StringFormat("RM_H4_THR_%d", i);
      datetime t1 = g_h4_thrLines[i].time;
      datetime t2 = t1 + 2 * PeriodSeconds(PERIOD_H1);
      color clr = g_h4_thrLines[i].clr;
      ObjectCreate(0, name, OBJ_TREND, 0, t1, g_h4_thrLines[i].price,
                   t2, g_h4_thrLines[i].price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 10);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      // Small "H4" label at the end of the line
      string lbl = StringFormat("RM_H4_THRL_%d", i);
      ObjectCreate(0, lbl, OBJ_TEXT, 0, t2, g_h4_thrLines[i].price);
      ObjectSetString(0, lbl, OBJPROP_TEXT, "H4");
      ObjectSetString(0, lbl, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, lbl, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lbl, OBJPROP_BACK, true);
   }
   ChartRedraw(0);
}
void RemoveH4Thrust() { ObjectsDeleteAll(0, "RM_H4_THR_"); ObjectsDeleteAll(0, "RM_H4_THRL_"); }

//+------------------------------------------------------------------+
void ToggleH4Thrust()
{
   g_h4_active = !g_h4_active;
   if(g_h4_active) { if(g_h4_lastBars == 0) ComputeH4Thrust(); PlotH4Thrust(); }
   else RemoveH4Thrust();
   ObjectSetInteger(0, "RM_BtnH4TH", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnH4TH"));
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void UpdateH4Thrust()
{
   if(!g_h4_active && !g_h4_flowActive && !g_alertH4FC) return;
   int bars = iBars(_Symbol, PERIOD_H1);
   if(bars == g_h4_lastBars)
   {
      // Force recompute if bar 0 breaches a swing (instant BOS)
      double b0Hi = iHigh(_Symbol, PERIOD_H1, 0);
      double b0Lo = iLow(_Symbol, PERIOD_H1, 0);
      bool breach = false;
      if(g_h4_check4DnBos && g_h4_swingLow > 0 && b0Lo < g_h4_swingLow) breach = true;
      if(g_h4_check4UpBos && g_h4_swingHigh > 0 && b0Hi > g_h4_swingHigh) breach = true;
      if(!breach) return;
   }
   int prevFlow = g_h4_tFlow;
   ComputeH4Thrust();
   if(g_h4_active)     PlotH4Thrust();
   if(g_h4_flowActive) PlotH4Flow();
   // Check for H4 flow change alert
   if(g_alertH4FC && prevFlow != 0 && g_h4_tFlow != prevFlow)
   {
      string emoji = (g_h4_tFlow == 1) ? "\xF0\x9F\x9F\xA2" : "\xF0\x9F\x94\xB4";   // 🟢 / 🔴
      string dir   = (g_h4_tFlow == 1) ? "bullish" : "bearish";
      string msg = AlertMsg(emoji, "H4.FLOW", "flow flipped to " + dir);
      SendDiscordAlert(msg);
      // Update button arrow
      string lbl = (g_h4_tFlow == 1) ? "H4.F\x25B2" : "H4.F\x25BC";
      ObjectSetString(0, "RM_BtnH4FC", OBJPROP_TEXT, lbl);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| H4 Flow line (magenta, extends right)                            |
//+------------------------------------------------------------------+
void PlotH4Flow()
{
   RemoveH4Flow();
   if(g_h4_flowLevel == 0) return;
   string name = "RM_H4_FLW_0";
   // Anchor to end of current day
   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 23; dt.min = 59; dt.sec = 0;
   datetime dayEnd = StructToTime(dt);
   ObjectCreate(0, name, OBJ_TREND, 0, dayEnd, g_h4_flowLevel,
                dayEnd + PeriodSeconds(PERIOD_H1), g_h4_flowLevel);
   ObjectSetInteger(0, name, OBJPROP_COLOR, C'140,100,160');
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 3);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   // Label
   string lbl = "RM_H4_FLWL_0";
   string dir = (g_h4_tFlow == 1) ? "H4.F\x25B2" : "H4.F\x25BC";
   ObjectCreate(0, lbl, OBJ_TEXT, 0, dayEnd, g_h4_flowLevel);
   ObjectSetString(0, lbl, OBJPROP_TEXT, dir);
   ObjectSetString(0, lbl, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 12);
   ObjectSetInteger(0, lbl, OBJPROP_COLOR, C'140,100,160');
   ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
   ChartRedraw(0);
}
void RemoveH4Flow() { ObjectsDeleteAll(0, "RM_H4_FLW_"); ObjectsDeleteAll(0, "RM_H4_FLWL_"); }

//+------------------------------------------------------------------+
void ToggleH4Flow()
{
   g_h4_flowActive = !g_h4_flowActive;
   if(g_h4_flowActive)
   {
      if(g_h4_lastBars == 0) ComputeH4Thrust();
      PlotH4Flow();
   }
   else RemoveH4Flow();
   ObjectSetInteger(0, "RM_BtnH4FC", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnH4FC"));
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleAlertH4FC()
{
   g_alertH4FC = !g_alertH4FC;
   g_alert_h4fcAlerted = false;
   ObjectSetInteger(0, "RM_BtnAltH4FC", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltH4FC"));
   ChartRedraw(0);
}

void ToggleAlertCTR()
{
   g_alertCTR = !g_alertCTR;
   g_alert_ctrLastTrend = 0;            // re-baseline so we don't fire on the first post-toggle bar
   ObjectsDeleteAll(0, "RM_CTRflip_");  // clear existing flip markers
   if(g_alertCTR)
      g_ctrM5.initialized = false;      // force re-backfill -> re-paints last CTREND_MARK_DAYS of flips
   ObjectSetInteger(0, "RM_BtnAltCTR", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltCTR"));
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Trailing SL — swing-based (H1 / H4 / Hidden / Auto)             |
//+------------------------------------------------------------------+

// Get current position direction: +1 = long, -1 = short, 0 = no position
int GetPositionDirection()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      return (type == POSITION_TYPE_BUY) ? 1 : -1;
   }
   return 0;
}

// Compute the trail level given swing high/low and position direction
double ComputeTrailLevel(double swingHigh, double swingLow, int dir)
{
   if(dir == 0 || swingHigh == 0 || swingLow == 0) return 0;
   return (dir > 0) ? swingLow : swingHigh;
}

// Move physical SL on all positions for this symbol
void TrailSLToLevel(double newSL)
{
   if(newSL <= 0) return;
   double nSL = NormalizeDouble(newSL, _Digits);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double curSL = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      long   type  = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY  && nSL <= curSL && curSL > 0) continue;
      if(type == POSITION_TYPE_SELL && nSL >= curSL && curSL > 0) continue;
      g_trade.PositionModify(ticket, nSL, tp);
   }
}

// Refresh all trail button labels (ON/OFF text)
void RefreshTrailButtons()
{
   ObjectSetString(0, "RM_BtnTrailH1", OBJPROP_TEXT, g_trailH1Active ? "H1 ON" : "H1 OFF");
   ObjectSetInteger(0, "RM_BtnTrailH1", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnTrailH1"));
   ObjectSetString(0, "RM_BtnTrailH4", OBJPROP_TEXT, g_trailH4Active ? "H4 ON" : "H4 OFF");
   ObjectSetInteger(0, "RM_BtnTrailH4", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnTrailH4"));
   ObjectSetString(0, "RM_BtnHTrail", OBJPROP_TEXT, g_hiddenTrailActive ? "H.T ON" : "H.T OFF");
   ObjectSetInteger(0, "RM_BtnHTrail", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnHTrail"));
   ObjectSetString(0, "RM_BtnAutoTrail", OBJPROP_TEXT, g_autoTrailActive ? "TRL ON" : "TRL OFF");
   ObjectSetInteger(0, "RM_BtnAutoTrail", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAutoTrail"));
}

// Plot/update visual trail line
void PlotTrailLine(string name, string lblName, double level, string lblText, color clr)
{
   if(level <= 0) { ObjectDelete(0, name); ObjectDelete(0, lblName); return; }
   datetime t = iTime(_Symbol, PERIOD_M15, 0);
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TREND, 0, t, level, t + PeriodSeconds(PERIOD_M15), level);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }
   else
   {
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, level);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, level);
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t + PeriodSeconds(PERIOD_M15));
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   // Label
   if(ObjectFind(0, lblName) < 0)
   {
      ObjectCreate(0, lblName, OBJ_TEXT, 0, t, level);
      ObjectSetString(0, lblName, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, lblName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
   }
   ObjectSetString(0, lblName, OBJPROP_TEXT, lblText);
   ObjectSetInteger(0, lblName, OBJPROP_COLOR, clr);
   ObjectSetDouble(0, lblName, OBJPROP_PRICE, 0, level);
   ObjectSetInteger(0, lblName, OBJPROP_TIME, 0, t);
}

void RemoveTrailLine(string name, string lblName)
{
   ObjectDelete(0, name);
   ObjectDelete(0, lblName);
}

// Plot/update hidden trail line on chart
void PlotHiddenTrailLine()
{
   string name = "RM_HiddenTrail";
   if(g_hiddenTrailLevel <= 0) { ObjectDelete(0, name); ObjectDelete(0, "RM_HiddenTrailLbl"); return; }
   datetime t = iTime(_Symbol, PERIOD_M15, 0);
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TREND, 0, t, g_hiddenTrailLevel,
                   t + PeriodSeconds(PERIOD_M15), g_hiddenTrailLevel);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }
   else
   {
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, g_hiddenTrailLevel);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, g_hiddenTrailLevel);
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t + PeriodSeconds(PERIOD_M15));
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR, C'255,100,100');
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASHDOTDOT);
   string lbl = "RM_HiddenTrailLbl";
   if(ObjectFind(0, lbl) < 0)
   {
      ObjectCreate(0, lbl, OBJ_TEXT, 0, t, g_hiddenTrailLevel);
      ObjectSetString(0, lbl, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
   }
   ObjectSetString(0, lbl, OBJPROP_TEXT, "HIDDEN TRAIL");
   ObjectSetInteger(0, lbl, OBJPROP_COLOR, C'255,100,100');
   ObjectSetDouble(0, lbl, OBJPROP_PRICE, 0, g_hiddenTrailLevel);
   ObjectSetInteger(0, lbl, OBJPROP_TIME, 0, t);
   ChartRedraw(0);
}

void RemoveHiddenTrailLine()
{
   ObjectDelete(0, "RM_HiddenTrail");
   ObjectDelete(0, "RM_HiddenTrailLbl");
   ChartRedraw(0);
}

// Check if price hit the hidden trail line -> close all
void CheckHiddenTrail()
{
   if(!g_hiddenTrailActive || g_hiddenTrailLevel <= 0) return;
   int dir = GetPositionDirection();
   if(dir == 0) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool hit = false;
   if(dir > 0 && bid <= g_hiddenTrailLevel) hit = true;
   if(dir < 0 && bid >= g_hiddenTrailLevel) hit = true;
   if(hit)
   {
      Print("RM Hidden Trail: Price hit ", g_hiddenTrailLevel, " - closing all positions.");
      SendDiscordAlert(AlertMsg("\xF0\x9F\x94\xB4", "H.TRAIL", "trail level hit, closing all positions"));
      CloseAllForSymbol();
      g_hiddenTrailActive = false;
      g_hiddenTrailLevel  = 0;
      RemoveHiddenTrailLine();
      RefreshTrailButtons();
      ChartRedraw(0);
   }
}

// Get the active trail level (from whichever H1/H4 is selected)
double GetActiveTrailLevel()
{
   int dir = GetPositionDirection();
   if(dir == 0) return 0;
   if(g_trailH1Active)
      return ComputeTrailLevel(g_tt_swingHigh, g_tt_swingLow, dir);
   if(g_trailH4Active)
      return ComputeTrailLevel(g_h4_swingHigh, g_h4_swingLow, dir);
   return 0;
}

// Update visual H1 trail line
void UpdateTrailH1()
{
   if(!g_trailH1Active) return;
   int dir = GetPositionDirection();
   double level = (dir != 0) ? ComputeTrailLevel(g_tt_swingHigh, g_tt_swingLow, dir) : 0;
   if(level > 0) g_trailH1Level = level;
   PlotTrailLine("RM_TrailH1", "RM_TrailH1Lbl", g_trailH1Level, "TRL H1", C'0,180,180');
}

// Update visual H4 trail line
void UpdateTrailH4()
{
   if(!g_trailH4Active) return;
   int dir = GetPositionDirection();
   double level = (dir != 0) ? ComputeTrailLevel(g_h4_swingHigh, g_h4_swingLow, dir) : 0;
   if(level > 0) g_trailH4Level = level;
   PlotTrailLine("RM_TrailH4", "RM_TrailH4Lbl", g_trailH4Level, "TRL H4", C'180,120,0');
}

// Update auto trail (physically move SL)
void UpdateAutoTrail()
{
   if(!g_autoTrailActive) return;
   double level = GetActiveTrailLevel();
   if(level <= 0) return;
   // Only trail when level changes
   double prev = g_trailH1Active ? g_trailH1Level : g_trailH4Level;
   if(level != prev)
   {
      if(g_trailH1Active) g_trailH1Level = level;
      else                g_trailH4Level = level;
      TrailSLToLevel(level);
      string src = g_trailH1Active ? "H1" : "H4";
      Print("RM Auto Trail (", src, "): SL trailed to ", DoubleToString(level, _Digits));
   }
}

// Update hidden trail level (uses the active H1/H4 trail source)
void UpdateHiddenTrail()
{
   if(!g_hiddenTrailActive) return;
   double level = GetActiveTrailLevel();
   if(level <= 0) return;
   // Only trail in protective direction (never widen)
   int dir = GetPositionDirection();
   if(g_hiddenTrailLevel > 0 && dir != 0)
   {
      if(dir > 0 && level < g_hiddenTrailLevel) return;
      if(dir < 0 && level > g_hiddenTrailLevel) return;
   }
   g_hiddenTrailLevel = level;
   PlotHiddenTrailLine();
}

// Toggle functions
void ToggleTrailH1()
{
   g_trailH1Active = !g_trailH1Active;
   if(g_trailH1Active)
   {
      // Turn off H4 (mutually exclusive)
      if(g_trailH4Active)
      {
         g_trailH4Active = false;
         g_trailH4Level = 0;
         RemoveTrailLine("RM_TrailH4", "RM_TrailH4Lbl");
         if(g_autoTrailActive) { g_autoTrailActive = false; }
      }
      if(g_tt_lastBars == 0) ComputeThrust();
      g_trailH1Level = 0;
      UpdateTrailH1();
   }
   else
   {
      g_trailH1Level = 0;
      RemoveTrailLine("RM_TrailH1", "RM_TrailH1Lbl");
      if(g_autoTrailActive) { g_autoTrailActive = false; }
      if(g_hiddenTrailActive) { g_hiddenTrailActive = false; g_hiddenTrailLevel = 0; RemoveHiddenTrailLine(); }
   }
   RefreshTrailButtons();
   ChartRedraw(0);
}

void ToggleTrailH4()
{
   g_trailH4Active = !g_trailH4Active;
   if(g_trailH4Active)
   {
      // Turn off H1 (mutually exclusive)
      if(g_trailH1Active)
      {
         g_trailH1Active = false;
         g_trailH1Level = 0;
         RemoveTrailLine("RM_TrailH1", "RM_TrailH1Lbl");
         if(g_autoTrailActive) { g_autoTrailActive = false; }
      }
      if(g_h4_lastBars == 0) ComputeH4Thrust();
      g_trailH4Level = 0;
      UpdateTrailH4();
   }
   else
   {
      g_trailH4Level = 0;
      RemoveTrailLine("RM_TrailH4", "RM_TrailH4Lbl");
      if(g_autoTrailActive) { g_autoTrailActive = false; }
      if(g_hiddenTrailActive) { g_hiddenTrailActive = false; g_hiddenTrailLevel = 0; RemoveHiddenTrailLine(); }
   }
   RefreshTrailButtons();
   ChartRedraw(0);
}

void ToggleHiddenTrail()
{
   if(!g_trailH1Active && !g_trailH4Active)
   {
      // No trail source selected, ignore
      ObjectSetInteger(0, "RM_BtnHTrail", OBJPROP_STATE, false);
      return;
   }
   g_hiddenTrailActive = !g_hiddenTrailActive;
   if(g_hiddenTrailActive)
   {
      g_hiddenTrailLevel = 0;
      UpdateHiddenTrail();
      PlotHiddenTrailLine();
   }
   else
   {
      g_hiddenTrailLevel = 0;
      RemoveHiddenTrailLine();
   }
   RefreshTrailButtons();
   ChartRedraw(0);
}

void ToggleAutoTrail()
{
   if(!g_trailH1Active && !g_trailH4Active)
   {
      // No trail source selected, ignore
      ObjectSetInteger(0, "RM_BtnAutoTrail", OBJPROP_STATE, false);
      return;
   }
   g_autoTrailActive = !g_autoTrailActive;
   if(g_autoTrailActive)
   {
      // Initial trail
      double level = GetActiveTrailLevel();
      if(level > 0) TrailSLToLevel(level);
   }
   RefreshTrailButtons();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Previous daily range                                             |
//+------------------------------------------------------------------+
double GetPrevDailyRange()
{
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   if(CopyHigh(_Symbol, PERIOD_D1, 1, 1, high) <= 0) return 0;
   if(CopyLow(_Symbol, PERIOD_D1, 1, 1, low) <= 0)   return 0;
   return high[0] - low[0];
}

//+------------------------------------------------------------------+
double CalcSLDistance()
{
   double range = GetPrevDailyRange();
   if(range <= 0) return 0;
   return NormalizeDouble(range * g_slPctValues[g_slPctIndex], _Digits);
}

//+------------------------------------------------------------------+
double CalcLotSize(double slDistance)
{
   if(slDistance <= 0) return 0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0;
   double riskMoney  = g_riskValues[g_riskIndex];
   double lossPerlot = (slDistance / tickSize) * tickValue;
   if(lossPerlot <= 0) return 0;
   double lots    = riskMoney / lossPerlot;
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lotStep <= 0) lotStep = 0.01;
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, lotMin);
   lots = MathMin(lots, lotMax);
   return NormalizeDouble(lots, 8);
}

//+------------------------------------------------------------------+
//| Place 3 order lines on chart                                     |
//+------------------------------------------------------------------+
void PlaceOrderLines(double entry, double sl, double tp)
{
   DeleteOrderLines();

   ENUM_LINE_STYLE lineStyle = g_hiddenOrderArmed ? STYLE_DOT : STYLE_SOLID;

   ObjectCreate(0, g_entryLineName, OBJ_HLINE, 0, 0, entry);
   ObjectSetInteger(0, g_entryLineName, OBJPROP_COLOR, CLR_ENTRY_LINE);
   ObjectSetInteger(0, g_entryLineName, OBJPROP_WIDTH, LINE_WIDTH);
   ObjectSetInteger(0, g_entryLineName, OBJPROP_STYLE, lineStyle);
   ObjectSetInteger(0, g_entryLineName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, g_entryLineName, OBJPROP_SELECTED, !g_isMarketOrder);
   ObjectSetString(0, g_entryLineName, OBJPROP_TEXT, "Entry");

   ObjectCreate(0, g_tpLineName, OBJ_HLINE, 0, 0, tp);
   ObjectSetInteger(0, g_tpLineName, OBJPROP_COLOR, CLR_TP_LINE);
   ObjectSetInteger(0, g_tpLineName, OBJPROP_WIDTH, LINE_WIDTH);
   ObjectSetInteger(0, g_tpLineName, OBJPROP_STYLE, lineStyle);
   ObjectSetInteger(0, g_tpLineName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, g_tpLineName, OBJPROP_SELECTED, true);
   ObjectSetString(0, g_tpLineName, OBJPROP_TEXT, "Take Profit");

   ObjectCreate(0, g_slLineName, OBJ_HLINE, 0, 0, sl);
   ObjectSetInteger(0, g_slLineName, OBJPROP_COLOR, CLR_SL_LINE);
   ObjectSetInteger(0, g_slLineName, OBJPROP_WIDTH, LINE_WIDTH);
   ObjectSetInteger(0, g_slLineName, OBJPROP_STYLE, lineStyle);
   ObjectSetInteger(0, g_slLineName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, g_slLineName, OBJPROP_SELECTED, true);
   ObjectSetString(0, g_slLineName, OBJPROP_TEXT, "Stop Loss");

   g_linesActive = true;
   g_slManualOverride = false;
   UpdateInfoLabel();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void DeleteOrderLines()
{
   ObjectDelete(0, g_entryLineName);
   ObjectDelete(0, g_tpLineName);
   ObjectDelete(0, g_slLineName);
   g_linesActive = false;
   g_slManualOverride = false;
   // Clear auto-follow mode
   if(g_autoOrderActive)
   {
      g_autoOrderActive = false;
      if(g_autoOrderBtn != "")
      {
         // Restore original button text (remove "auto" prefix)
         string origText = "";
         if(g_autoOrderBtn == "RM_BuyMkt")       origText = "+D_MTX";
         else if(g_autoOrderBtn == "RM_SellMkt")  origText = "-D_MTX";
         else if(g_autoOrderBtn == "RM_BuyMktSw") origText = "+SWING";
         else if(g_autoOrderBtn == "RM_SellMktSw")origText = "-SWING";
         if(origText != "")
            ObjectSetString(0, g_autoOrderBtn, OBJPROP_TEXT, origText);
      }
      g_autoOrderBtn = "";
   }
}

//+------------------------------------------------------------------+
//| Update info bar â€” recalculates from chart lines (internal only) |
//+------------------------------------------------------------------+
void UpdateInfoLabel()
{
   if(!g_linesActive) return;

   double entry = ObjectGetDouble(0, g_entryLineName, OBJPROP_PRICE);
   double sl    = ObjectGetDouble(0, g_slLineName, OBJPROP_PRICE);
   if(entry == 0 || sl == 0) return;

   double slDist = MathAbs(entry - sl);
   g_riskDollars = g_riskValues[g_riskIndex];
}

//+------------------------------------------------------------------+
void ClearInfoLabel()
{
   // No planned-order labels to clear anymore
}

//+------------------------------------------------------------------+
double GetCurrentLotSize()
{
   if(!g_linesActive) return 0;
   double entry = ObjectGetDouble(0, g_entryLineName, OBJPROP_PRICE);
   double sl    = ObjectGetDouble(0, g_slLineName, OBJPROP_PRICE);
   if(entry == 0 || sl == 0) return 0;
   return CalcLotSize(MathAbs(entry - sl));
}

//+------------------------------------------------------------------+
//| Cancel hidden order                                              |
//+------------------------------------------------------------------+
void CancelHiddenOrder()
{
   g_hiddenOrderArmed = false;
   g_isHiddenOrder    = false;
}

//+------------------------------------------------------------------+
//| Execute trade (Enter key)                                        |
//+------------------------------------------------------------------+
void ExecuteTrade()
{
   if(!g_linesActive)
   {
      Print("RiskManager: No order lines active.");
      return;
   }

   double entry = ObjectGetDouble(0, g_entryLineName, OBJPROP_PRICE);
   double sl    = ObjectGetDouble(0, g_slLineName, OBJPROP_PRICE);
   double tp    = ObjectGetDouble(0, g_tpLineName, OBJPROP_PRICE);
   double lots  = GetCurrentLotSize();
   if(lots <= 0) { Print("RiskManager: Lot size zero."); return; }

   // Hidden order â†’ arm it instead of sending to broker
   if(g_isHiddenOrder && !g_hiddenOrderArmed)
   {
      g_hiddenOrderArmed = true;
      // Restyle lines to dotted
      ObjectSetInteger(0, g_entryLineName, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, g_tpLineName, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, g_slLineName, OBJPROP_STYLE, STYLE_DOT);
      UpdateInfoLabel();
      Print("RiskManager: Hidden order ARMED. Lots=", lots);
      ChartRedraw(0);
      return;
   }

   g_trade.SetExpertMagicNumber(0);
   g_trade.SetDeviationInPoints(5);

   // Split orders: divide lots evenly across g_orderSplit orders
   int splitCount = MathMax(g_orderSplit, 1);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lotStep <= 0) lotStep = 0.01;
   double splitLots = MathFloor((lots / splitCount) / lotStep) * lotStep;
   if(splitLots < lotMin) splitLots = lotMin;
   splitLots = NormalizeDouble(splitLots, 8);

   int successCount = 0;
   int failCount    = 0;
   for(int s = 0; s < splitCount; s++)
   {
      bool result = false;
      string comment = "";

      if(g_orderType == 0)
      {
         if(g_orderDir > 0)
            result = g_trade.Buy(splitLots, _Symbol, 0, sl, tp, comment);
         else
            result = g_trade.Sell(splitLots, _Symbol, 0, sl, tp, comment);
      }
      else if(g_orderType == 1)
      {
         if(g_orderDir > 0)
            result = g_trade.BuyLimit(splitLots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
         else
            result = g_trade.SellLimit(splitLots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      }
      else
      {
         if(g_orderDir > 0)
            result = g_trade.BuyStop(splitLots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
         else
            result = g_trade.SellStop(splitLots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      }

      if(result) successCount++;
      else       failCount++;
   }

   if(successCount > 0)
   {
      Print("RiskManager: ", successCount, "/", splitCount, " orders placed. Lots=", splitLots, " each");
      DeleteOrderLines();
      CancelHiddenOrder();
      g_lastOrderBtn = "";
      ChartRedraw(0);
   }
   if(failCount > 0)
   {
      Print("RiskManager: ", failCount, "/", splitCount, " orders FAILED. Err=", GetLastError());
      ChartRedraw(0);
   }
}

//+------------------------------------------------------------------+
//| +LOT: Add position at market using risk preset A                 |
//| Uses avg SL & avg TP of existing positions on this symbol.       |
//+------------------------------------------------------------------+
void ExecuteAddLot()
{
   // Gather avg SL, avg TP, and determine direction from open positions
   double sumSL = 0, sumTP = 0;
   int countSL = 0, countTP = 0, countPos = 0;
   int dir = 0; // +1 buy, -1 sell

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      long   posType = PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)  dir = +1;
      else                              dir = -1;

      if(sl > 0) { sumSL += sl; countSL++; }
      if(tp > 0) { sumTP += tp; countTP++; }
      countPos++;
   }

   if(countPos == 0)
   {
      Print("RiskManager +LOT: No open positions on ", _Symbol);
      return;
   }
   if(countSL == 0)
   {
      Print("RiskManager +LOT: No positions have a SL set.");
      return;
   }

   double avgSL = sumSL / countSL;
   double avgTP = (countTP > 0) ? sumTP / countTP : 0;
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Entry is at market
   double entry = (dir > 0) ? ask : bid;

   // Calculate stop distance for lot sizing
   double slDist = MathAbs(entry - avgSL);
   Print("RiskManager +LOT: entry=", entry, " avgSL=", avgSL, " slDist=", slDist,
         " avgTP=", avgTP, " dir=", dir, " risk$=", g_riskValues[g_riskIndex]);

   if(slDist < _Point)
   {
      Print("RiskManager +LOT: SL distance too small.");
      return;
   }

   double lots = CalcLotSize(slDist);
   Print("RiskManager +LOT: CalcLotSize returned ", lots);
   if(lots <= 0)
   {
      Print("RiskManager +LOT: Lot size zero.");
      return;
   }

   g_trade.SetExpertMagicNumber(0);
   g_trade.SetDeviationInPoints(5);
   bool result = false;

   if(dir > 0)
      result = g_trade.Buy(lots, _Symbol, 0, avgSL, avgTP, "");
   else
      result = g_trade.Sell(lots, _Symbol, 0, avgSL, avgTP, "");

   if(result)
      Print("RiskManager +LOT: Added ", lots, " lots at market. SL=", avgSL, " TP=", avgTP);
   else
      Print("RiskManager +LOT: FAILED. Err=", GetLastError());

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| SET SL / SET TP – toggle draggable line + apply on Enter         |
//+------------------------------------------------------------------+
void ToggleSetSL()
{
   if(g_setSLActive)
   {
      // Cancel – remove line
      ObjectDelete(0, g_setSLLineName);
      g_setSLActive = false;
   }
   else
   {
      // Cancel any active SET TP
      if(g_setTPActive) { ObjectDelete(0, g_setTPLineName); g_setTPActive = false; }

      // Determine direction from open positions
      int dir = 0;
      double price = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         long posType = PositionGetInteger(POSITION_TYPE);
         if(posType == POSITION_TYPE_BUY)  dir = +1;
         else                              dir = -1;
         price = PositionGetDouble(POSITION_PRICE_OPEN);
         break;
      }
      if(dir == 0) { Print("RM SET SL: No positions on ", _Symbol); return; }

      double slRange = CalcSLDistance();
      if(slRange <= 0) slRange = 50 * _Point;
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      double linePrice = (dir > 0) ? bid - slRange : bid + slRange;
      linePrice = NormalizeDouble(linePrice, _Digits);

      ObjectCreate(0, g_setSLLineName, OBJ_HLINE, 0, 0, linePrice);
      ObjectSetInteger(0, g_setSLLineName, OBJPROP_COLOR, CLR_SL_LINE);
      ObjectSetInteger(0, g_setSLLineName, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, g_setSLLineName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, g_setSLLineName, OBJPROP_SELECTABLE, true);
      ObjectSetInteger(0, g_setSLLineName, OBJPROP_SELECTED, true);
      ObjectSetString(0, g_setSLLineName, OBJPROP_TEXT, "SET SL – Enter to apply");
      g_setSLActive = true;
   }
   ObjectSetInteger(0, "RM_SetSL", OBJPROP_BGCOLOR, g_setSLActive ? CLR_BTN_ON : CLR_BTN_SELL);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ToggleSetTP()
{
   if(g_setTPActive)
   {
      ObjectDelete(0, g_setTPLineName);
      g_setTPActive = false;
   }
   else
   {
      // Cancel any active SET SL
      if(g_setSLActive) { ObjectDelete(0, g_setSLLineName); g_setSLActive = false; }

      int dir = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         long posType = PositionGetInteger(POSITION_TYPE);
         if(posType == POSITION_TYPE_BUY)  dir = +1;
         else                              dir = -1;
         break;
      }
      if(dir == 0) { Print("RM SET TP: No positions on ", _Symbol); return; }

      double slRange = CalcSLDistance();
      if(slRange <= 0) slRange = 50 * _Point;
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      double linePrice = (dir > 0) ? bid + slRange : bid - slRange;
      linePrice = NormalizeDouble(linePrice, _Digits);

      ObjectCreate(0, g_setTPLineName, OBJ_HLINE, 0, 0, linePrice);
      ObjectSetInteger(0, g_setTPLineName, OBJPROP_COLOR, CLR_TP_LINE);
      ObjectSetInteger(0, g_setTPLineName, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, g_setTPLineName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, g_setTPLineName, OBJPROP_SELECTABLE, true);
      ObjectSetInteger(0, g_setTPLineName, OBJPROP_SELECTED, true);
      ObjectSetString(0, g_setTPLineName, OBJPROP_TEXT, "SET TP – Enter to apply");
      g_setTPActive = true;
   }
   ObjectSetInteger(0, "RM_SetTP", OBJPROP_BGCOLOR, g_setTPActive ? CLR_BTN_ON : CLR_BTN_BUY);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Remove all Smart TP chart objects                                |
//+------------------------------------------------------------------+
void RemoveSmartObjects(string prefix)
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string nm = ObjectName(0, i);
      if(StringFind(nm, prefix) == 0) ObjectDelete(0, nm);
   }
}

//+------------------------------------------------------------------+
//| Create Smart TP visuals for a single day                         |
//|   1. Green level line bounded to day (high / D.STK)              |
//|   2. Red anchor line bounded to day (low / prev open)            |
//|   3. Dashed diagonal from red BOD → green EOD                    |
//+------------------------------------------------------------------+
void CreateSmartVisualsForDay(int dayIdx, double greenLevel, double redLevel,
                               datetime dayStart, datetime dayEnd)
{
   string suffix = "_" + IntegerToString(dayIdx);

   // 1) Green level line bounded to this day (draggable, pre-selected)
   string hName = "RM_SmTP_Level" + suffix;
   ObjectCreate(0, hName, OBJ_TREND, 0, dayStart, greenLevel, dayEnd, greenLevel);
   ObjectSetInteger(0, hName, OBJPROP_COLOR, CLR_SMTP_GREEN);
   ObjectSetInteger(0, hName, OBJPROP_WIDTH, 5);
   ObjectSetInteger(0, hName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, hName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, hName, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, hName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, hName, OBJPROP_SELECTED, true);
   ObjectSetString(0, hName, OBJPROP_TEXT, "SMART TP");

   // 2) Brown/beige anchor line bounded to this day (pre-selected)
   string eName = "RM_SmTP_Entry" + suffix;
   ObjectCreate(0, eName, OBJ_TREND, 0, dayStart, redLevel, dayEnd, redLevel);
   ObjectSetInteger(0, eName, OBJPROP_COLOR, CLR_SMTP_BEIGE);
   ObjectSetInteger(0, eName, OBJPROP_WIDTH, 5);
   ObjectSetInteger(0, eName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, eName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, eName, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, eName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, eName, OBJPROP_SELECTED, true);
   ObjectSetString(0, eName, OBJPROP_TEXT, (dayIdx == 0) ? "Prev Open" : "Day Low");

   // 3) Dashed diagonal from (dayStart, beige) → (dayEnd, green)
   string tName = "RM_SmTP_Trend" + suffix;
   ObjectCreate(0, tName, OBJ_TREND, 0, dayStart, redLevel, dayEnd, greenLevel);
   ObjectSetInteger(0, tName, OBJPROP_COLOR, CLR_SMTP_BEIGE);
   ObjectSetInteger(0, tName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, tName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, tName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, tName, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, tName, OBJPROP_SELECTABLE, false);

   // 4) SL red line — on the beige side, detached with margin
   string slName = "RM_SmTP_SL" + suffix;
   double slMargin = MathAbs(greenLevel - redLevel) * 0.10;  // 10% margin beyond beige
   double slLevel;
   if(greenLevel > redLevel)
      slLevel = redLevel - slMargin;   // beige is below green → SL goes below beige
   else
      slLevel = redLevel + slMargin;   // beige is above green → SL goes above beige
   ObjectCreate(0, slName, OBJ_TREND, 0, dayStart, slLevel, dayEnd, slLevel);
   ObjectSetInteger(0, slName, OBJPROP_COLOR, CLR_SL_LINE);
   ObjectSetInteger(0, slName, OBJPROP_WIDTH, 5);
   ObjectSetInteger(0, slName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, slName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, slName, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, slName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, slName, OBJPROP_SELECTED, true);
   ObjectSetString(0, slName, OBJPROP_TEXT, "SMART SL");

   // 5) Score label for today only — shows Pace×Progress score
   if(dayIdx == 0)
   {
      string sName = "RM_SmTP_Score";
      if(ObjectFind(0, sName) >= 0) ObjectDelete(0, sName);
      ObjectCreate(0, sName, OBJ_TEXT, 0, dayEnd, greenLevel);
      ObjectSetString(0, sName, OBJPROP_TEXT, "Score: ---");
      ObjectSetString(0, sName, OBJPROP_FONT, "Segoe UI Semibold");
      ObjectSetInteger(0, sName, OBJPROP_FONTSIZE, 11);
      ObjectSetInteger(0, sName, OBJPROP_COLOR, CLR_SMTP_GREEN);
      ObjectSetInteger(0, sName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, sName, OBJPROP_SELECTABLE, false);
   }
}

//+------------------------------------------------------------------+
//| Plot Smart TP visuals depending on mode (1=today, 2=all days)    |
//+------------------------------------------------------------------+
void PlotSmartTP()
{
   RemoveSmartObjects("RM_SmTP_");
   if(g_smartTPMode == 0) return;
   if(Period() > PERIOD_H1) return;

   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   int lookback = (g_smartTPMode == 2) ? 93 : 3;
   int copied = CopyRates(_Symbol, PERIOD_D1, 0, lookback, daily);
   if(copied < 2) return;

   int limit = (g_smartTPMode == 1) ? 1 : copied - 1;

   for(int d = 0; d < limit; d++)
   {
      double refH = daily[d + 1].high;
      double refL = daily[d + 1].low;
      double range = refH - refL;
      if(range <= 0) continue;

      datetime dayStart = daily[d].time;
      datetime dayEnd   = (d > 0) ? daily[d - 1].time
                                  : daily[d].time + PeriodSeconds(PERIOD_D1);

      double greenLevel, redLevel;
      bool prevBull = (daily[d + 1].close >= daily[d + 1].open);

      if(d == 0)
      {
         // Current day: D.STK zone boundaries
         // Bull prev: 125 and 25 | Bear prev: 75 and -25
         if(prevBull)
         {
            greenLevel = refH + range * 0.25;   // 125
            redLevel   = refL + range * 0.25;   // 25
         }
         else
         {
            greenLevel = refL + range * 0.75;   // 75
            redLevel   = refL - range * 0.25;   // -25
         }
      }
      else
      {
         // Historical days: D.BX levels using THIS day's H/L and candle direction
         double dayH = daily[d].high;
         double dayL = daily[d].low;
         bool dayBull = (daily[d].close >= daily[d].open);
         if(dayBull)
         {
            greenLevel = dayH;
            redLevel   = dayL;
         }
         else
         {
            greenLevel = dayL;
            redLevel   = dayH;
         }
      }

      CreateSmartVisualsForDay(d, greenLevel, redLevel, dayStart, dayEnd);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Update lines when any Smart TP Level, Entry, or SL line dragged  |
//+------------------------------------------------------------------+
void UpdateSmartTrendline(string objName)
{
   // Determine suffix from any of the three line types
   string suffix;
   bool isLevel = (StringFind(objName, "RM_SmTP_Level_") == 0);
   bool isEntry = (StringFind(objName, "RM_SmTP_Entry_") == 0);
   bool isSL    = (StringFind(objName, "RM_SmTP_SL_")    == 0);

   if(isLevel)
      suffix = StringSubstr(objName, StringLen("RM_SmTP_Level"));
   else if(isEntry)
      suffix = StringSubstr(objName, StringLen("RM_SmTP_Entry"));
   else
      suffix = StringSubstr(objName, StringLen("RM_SmTP_SL"));

   string hName  = "RM_SmTP_Level" + suffix;
   string eName  = "RM_SmTP_Entry" + suffix;
   string tName  = "RM_SmTP_Trend" + suffix;
   string slName = "RM_SmTP_SL"    + suffix;

   if(ObjectFind(0, hName) < 0 || ObjectFind(0, eName) < 0) return;

   double greenLevel = ObjectGetDouble(0, hName, OBJPROP_PRICE, 0);
   double redLevel   = ObjectGetDouble(0, eName, OBJPROP_PRICE, 0);

   // Get day boundaries from a non-dragged line
   string refObj = isLevel ? eName : hName;
   datetime dayStart = (datetime)ObjectGetInteger(0, refObj, OBJPROP_TIME, 0);
   datetime dayEnd   = (datetime)ObjectGetInteger(0, refObj, OBJPROP_TIME, 1);

   // Re-snap the dragged line's X coordinates to its own day
   if(isLevel)
   {
      ObjectSetInteger(0, hName, OBJPROP_TIME, 0, dayStart);
      ObjectSetDouble(0, hName, OBJPROP_PRICE, 0, greenLevel);
      ObjectSetInteger(0, hName, OBJPROP_TIME, 1, dayEnd);
      ObjectSetDouble(0, hName, OBJPROP_PRICE, 1, greenLevel);
   }
   else if(isEntry)
   {
      ObjectSetInteger(0, eName, OBJPROP_TIME, 0, dayStart);
      ObjectSetDouble(0, eName, OBJPROP_PRICE, 0, redLevel);
      ObjectSetInteger(0, eName, OBJPROP_TIME, 1, dayEnd);
      ObjectSetDouble(0, eName, OBJPROP_PRICE, 1, redLevel);
   }

   // Update diagonal: (dayStart, beige) → (dayEnd, green)
   if(ObjectFind(0, tName) >= 0)
   {
      ObjectSetInteger(0, tName, OBJPROP_TIME, 0, dayStart);
      ObjectSetDouble(0, tName, OBJPROP_PRICE, 0, redLevel);
      ObjectSetInteger(0, tName, OBJPROP_TIME, 1, dayEnd);
      ObjectSetDouble(0, tName, OBJPROP_PRICE, 1, greenLevel);
   }

   // Enforce SL constraint: must stay on the beige side (not between beige & green, not on green side)
   if(ObjectFind(0, slName) >= 0)
   {
      double slLevel = ObjectGetDouble(0, slName, OBJPROP_PRICE, 0);
      double margin  = MathAbs(greenLevel - redLevel) * 0.05;  // 5% margin from beige

      if(greenLevel > redLevel)
      {
         // Green is above beige → SL must be below beige
         if(slLevel > redLevel - margin)
            slLevel = redLevel - margin;
      }
      else
      {
         // Green is below beige → SL must be above beige
         if(slLevel < redLevel + margin)
            slLevel = redLevel + margin;
      }

      ObjectSetInteger(0, slName, OBJPROP_TIME, 0, dayStart);
      ObjectSetDouble(0, slName, OBJPROP_PRICE, 0, slLevel);
      ObjectSetInteger(0, slName, OBJPROP_TIME, 1, dayEnd);
      ObjectSetDouble(0, slName, OBJPROP_PRICE, 1, slLevel);
   }
}

//+------------------------------------------------------------------+
void ToggleSmartTP()
{
   g_smartTPMode = (g_smartTPMode + 1) % 3;  // 0→1→2→0
   if(g_smartTPMode > 0)
      PlotSmartTP();
   else
      RemoveSmartObjects("RM_SmTP_");

   string label = (g_smartTPMode == 0) ? "SMART TP" : (g_smartTPMode == 1) ? "SM.TP \x25CF" : "SM.TP \x2605";
   ObjectSetString(0, "RM_SmartTP", OBJPROP_TEXT, label);
   ObjectSetInteger(0, "RM_SmartTP", OBJPROP_BGCOLOR, (g_smartTPMode > 0) ? CLR_BTN_ON : CLR_BTN_BUY);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Smart TP Pace×Progress Score                                     |
//|                                                                  |
//| Formula: score = p² / t                                          |
//|   t = fraction of trading day elapsed (0→1)                      |
//|   p = fraction of TP range reached: (bid - red) / (green - red)  |
//|                                                                  |
//| Interpretation:                                                  |
//|   score >= 2.5  → HEAVY TP  (way ahead of schedule)             |
//|   score >= 1.5  → MOD TP    (comfortably ahead)                 |
//|   score >= 1.0  → LIGHT TP  (slightly ahead)                    |
//|   score <  1.0  → HOLD      (on pace or behind)                 |
//|                                                                  |
//| Minimum 10% of day must elapse before scoring (avoids noise).    |
//| Score label is anchored to the green level line on chart.        |
//+------------------------------------------------------------------+
void CheckSmartTPScore()
{
   if(g_smartTPMode == 0) return;
   string sName = "RM_SmTP_Score";
   if(ObjectFind(0, sName) < 0) return;

   // Read green (TP target) and red (base) from today's lines
   string hName = "RM_SmTP_Level_0";
   string eName = "RM_SmTP_Entry_0";
   if(ObjectFind(0, hName) < 0 || ObjectFind(0, eName) < 0) return;

   double greenLevel = ObjectGetDouble(0, hName, OBJPROP_PRICE, 0);
   double redLevel   = ObjectGetDouble(0, eName, OBJPROP_PRICE, 0);
   double tpRange    = greenLevel - redLevel;
   if(MathAbs(tpRange) < _Point) return;  // degenerate

   // Time progress: t = fraction of day elapsed
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   datetime dayEnd   = dayStart + PeriodSeconds(PERIOD_D1);
   datetime now      = TimeCurrent();
   double t = (double)(now - dayStart) / (double)(dayEnd - dayStart);
   if(t < 0.0) t = 0.0;
   if(t > 1.0) t = 1.0;

   // TP progress: p = how far bid has moved from red toward green
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double p = (bid - redLevel) / tpRange;

   // Score calculation
   double score = 0;
   string tier  = "WAIT";
   color  clr   = CLR_TP_LINE;

   if(t < 0.10)
   {
      // Too early in the day to score
      tier = "WAIT";
      clr  = C'140,140,140';
   }
   else if(p <= 0)
   {
      score = 0;
      tier  = "BEHIND";
      clr   = CLR_SL_LINE;
   }
   else
   {
      score = (p * p) / t;

      if(score >= 2.5)      { tier = "HEAVY TP";  clr = C'50,220,50';  }
      else if(score >= 1.5) { tier = "MOD TP";    clr = C'120,200,80'; }
      else if(score >= 1.0) { tier = "LIGHT TP";  clr = C'200,200,80'; }
      else                  { tier = "HOLD";       clr = C'140,140,140'; }
   }

   // Format label text
   string txt;
   if(tier == "WAIT")
      txt = StringFormat("Score: --- (%s)  t=%.0f%%", tier, t * 100);
   else
      txt = StringFormat("Score: %.2f (%s)  t=%.0f%% p=%.0f%%", score, tier, t * 100, p * 100);

   // Update the chart label
   ObjectSetString(0, sName, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, sName, OBJPROP_COLOR, clr);

   // Reposition label at the green level, end of day
   ObjectSetInteger(0, sName, OBJPROP_TIME, 0, dayEnd);
   ObjectSetDouble(0, sName, OBJPROP_PRICE, 0, greenLevel);
}

//+------------------------------------------------------------------+
void ApplySetSL()
{
   double newSL = ObjectGetDouble(0, g_setSLLineName, OBJPROP_PRICE);
   if(newSL <= 0) { Print("RM SET SL: Invalid line price."); return; }

   int modified = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double tp = PositionGetDouble(POSITION_TP);
      if(g_trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), tp))
         modified++;
      else
         Print("RM SET SL: Failed ticket=", ticket, " err=", GetLastError());
   }
   Print("RM SET SL: Modified ", modified, " positions. New SL=", newSL);

   ObjectDelete(0, g_setSLLineName);
   g_setSLActive = false;
   ObjectSetInteger(0, "RM_SetSL", OBJPROP_BGCOLOR, CLR_BTN_SELL);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ApplySetTP()
{
   double newTP = ObjectGetDouble(0, g_setTPLineName, OBJPROP_PRICE);
   if(newTP <= 0) { Print("RM SET TP: Invalid line price."); return; }

   int modified = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double sl = PositionGetDouble(POSITION_SL);
      if(g_trade.PositionModify(ticket, sl, NormalizeDouble(newTP, _Digits)))
         modified++;
      else
         Print("RM SET TP: Failed ticket=", ticket, " err=", GetLastError());
   }
   Print("RM SET TP: Modified ", modified, " positions. New TP=", newTP);

   ObjectDelete(0, g_setTPLineName);
   g_setTPActive = false;
   ObjectSetInteger(0, "RM_SetTP", OBJPROP_BGCOLOR, CLR_BTN_BUY);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Create order lines from parameters                               |
//+------------------------------------------------------------------+
void HandleOrderButton(int dir, int type)
{
   g_orderDir      = dir;
   g_orderType     = type;
   g_isMarketOrder = (type == 0);

   double slDist = CalcSLDistance();
   if(slDist <= 0)
   {
      Print("RiskManager: ERROR - No daily data for SL calc");
      ChartRedraw(0);
      return;
   }

   double rrRatio = g_rrValues[g_rrIndex];
   double tpDist  = NormalizeDouble(slDist * rrRatio, _Digits);
   double entry;

   if(type == 0)
   {
      entry = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   else if(type == 1)
   {
      double ref = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      entry = (dir > 0) ? ref - slDist : ref + slDist;
   }
   else
   {
      double ref = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      entry = (dir > 0) ? ref + slDist : ref - slDist;
   }

   entry    = NormalizeDouble(entry, _Digits);
   double sl = NormalizeDouble(entry - dir * slDist, _Digits);
   double tp = NormalizeDouble(entry + dir * tpDist, _Digits);

   PlaceOrderLines(entry, sl, tp);
}

//+------------------------------------------------------------------+
//| SWING order: uses last swing H/L as SL, R:R preset for TP       |
//+------------------------------------------------------------------+
void HandleSwingOrderButton(int dir, int type)
{
   g_orderDir      = dir;
   g_orderType     = type;
   g_isMarketOrder = (type == 0);

   // Get swing levels from thrust system
   double swH = g_tt_swingHigh;
   double swL = g_tt_swingLow;
   if(swH == 0 || swL == 0)
   {
      Print("RiskManager: No swing levels available for SWING order");
      ChartRedraw(0);
      return;
   }

   double entry;
   if(type == 0)
      entry = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   else if(type == 1)
   {
      double ref = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double slDist = (dir > 0) ? ref - swL : swH - ref;
      entry = (dir > 0) ? ref - slDist : ref + slDist;
   }
   else
   {
      double ref = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double slDist = (dir > 0) ? ref - swL : swH - ref;
      entry = (dir > 0) ? ref + slDist : ref - slDist;
   }

   entry = NormalizeDouble(entry, _Digits);
   double sl = NormalizeDouble((dir > 0) ? swL : swH, _Digits);
   double slDist2 = MathAbs(entry - sl);
   double rrRatio = g_rrValues[g_rrIndex];
   double tpDist  = NormalizeDouble(slDist2 * rrRatio, _Digits);
   double tp = NormalizeDouble(entry + dir * tpDist, _Digits);

   PlaceOrderLines(entry, sl, tp);
}

//+------------------------------------------------------------------+
//| CHOCH order: buy stop at swingHigh (downtrend) or                |
//|              sell stop at swingLow (uptrend)                     |
//| SL = lowest low (buy) or highest high (sell) from swing to now   |
//| Entry/SL auto-update per candle via UpdateChochOrder()           |
//+------------------------------------------------------------------+
void HandleChochOrderButton(int dir)
{
   g_orderDir      = dir;
   g_orderType     = 2;  // stop order
   g_isMarketOrder = false;

   double entry, sl;
   if(dir > 0)
   {
      // +CHOCH: buy stop at last swing high in downtrend
      entry = g_tt_swingHigh;
      if(entry == 0) { Print("RiskManager: No swing high for +CHOCH"); return; }
      if(g_chochMode == 0)
      {
         // SL Range: use daily range percentage
         double slDist = CalcSLDistance();
         if(slDist <= 0) { Print("RiskManager: No daily data for +CHOCH SL"); return; }
         sl = entry - slDist;
      }
      else
      {
         // Swing SL: use swing low directly
         sl = g_tt_swingLow;
         if(sl == 0) { Print("RiskManager: No swing low for +CHOCH swing SL"); return; }
      }
   }
   else
   {
      // -CHOCH: sell stop at last swing low in uptrend
      entry = g_tt_swingLow;
      if(entry == 0) { Print("RiskManager: No swing low for -CHOCH"); return; }
      if(g_chochMode == 0)
      {
         // SL Range: use daily range percentage
         double slDist = CalcSLDistance();
         if(slDist <= 0) { Print("RiskManager: No daily data for -CHOCH SL"); return; }
         sl = entry + slDist;
      }
      else
      {
         // Swing SL: use swing high directly
         sl = g_tt_swingHigh;
         if(sl == 0) { Print("RiskManager: No swing high for -CHOCH swing SL"); return; }
      }
   }

   entry = NormalizeDouble(entry, _Digits);
   sl    = NormalizeDouble(sl, _Digits);
   double slDist  = MathAbs(entry - sl);
   double rrRatio = g_rrValues[g_rrIndex];
   double tpDist  = NormalizeDouble(slDist * rrRatio, _Digits);
   double tp      = NormalizeDouble(entry + dir * tpDist, _Digits);

   g_chochOrderActive = true;
   g_chochOrderDir    = dir;
   g_chochLastBars    = iBars(_Symbol, PERIOD_M15);

   PlaceOrderLines(entry, sl, tp);
}

//+------------------------------------------------------------------+
//| BKO (Breakout) stop order: with-the-trend                       |
//| +BKO buy stop  = highest high since BOS,  SL = BOS swing low    |
//| -BKO sell stop = lowest low since BOS,    SL = BOS swing high   |
//+------------------------------------------------------------------+
void HandleBkoOrderButton(int dir)
{
   g_orderDir      = dir;
   g_orderType     = 2;  // stop order
   g_isMarketOrder = false;

   if(g_tt_lastBosTime == 0) { Print("RiskManager: No BOS detected for BKO order"); return; }

   double entry, sl;
   if(dir > 0)
   {
      // +BKO: buy stop at highest high since BOS swing high
      entry = FindHighestHighSince((g_tt_lastBosSwHTime > 0) ? g_tt_lastBosSwHTime : g_tt_lastBosTime);
      sl    = g_tt_lastBosSwL;
      if(entry == 0) { Print("RiskManager: Cannot find highest high for +BKO"); return; }
      if(sl == 0)    { Print("RiskManager: No BOS swing low for +BKO SL"); return; }
   }
   else
   {
      // -BKO: sell stop at lowest low since BOS swing low
      entry = FindLowestLowSince((g_tt_lastBosSwLTime > 0) ? g_tt_lastBosSwLTime : g_tt_lastBosTime);
      sl    = g_tt_lastBosSwH;
      if(entry == 0) { Print("RiskManager: Cannot find lowest low for -BKO"); return; }
      if(sl == 0)    { Print("RiskManager: No BOS swing high for -BKO SL"); return; }
   }

   entry = NormalizeDouble(entry, _Digits);
   sl    = NormalizeDouble(sl, _Digits);
   double slDist  = MathAbs(entry - sl);
   double rrRatio = g_rrValues[g_rrIndex];
   double tpDist  = NormalizeDouble(slDist * rrRatio, _Digits);
   double tp      = NormalizeDouble(entry + dir * tpDist, _Digits);

   PlaceOrderLines(entry, sl, tp);
}

//+------------------------------------------------------------------+
//| CH_BO (CHOCH-Breakout) stop order: anti-trend reversal version  |
//| Same recipe as BS_BO (BKO) — entry at extreme since BOS,         |
//| SL at BOS opposite swing — but trend-gated AGAINST the trend so  |
//| the entry break triggers a CHOCH rather than a continuation BOS. |
//| +CH_BO buy   active only in bearish trend (entry = highest high  |
//|                since BOS swing high, SL = BOS swing low).        |
//| -CH_BO sell  active only in bullish trend (entry = lowest low    |
//|                since BOS swing low,  SL = BOS swing high).       |
//+------------------------------------------------------------------+
void HandleChBoOrderButton(int dir)
{
   g_orderDir      = dir;
   g_orderType     = 2;  // stop order
   g_isMarketOrder = false;

   if(g_tt_lastBosTime == 0) { Print("RiskManager: No BOS detected for CH_BO order"); return; }

   double entry, sl;
   if(dir > 0)
   {
      // +CH_BO: buy stop at highest high since last BOS swing high (anti-trend buy in bear)
      entry = FindHighestHighSince((g_tt_lastBosSwHTime > 0) ? g_tt_lastBosSwHTime : g_tt_lastBosTime);
      sl    = g_tt_lastBosSwL;
      if(entry == 0) { Print("RiskManager: Cannot find highest high for +CH_BO"); return; }
      if(sl == 0)    { Print("RiskManager: No BOS swing low for +CH_BO SL");      return; }
   }
   else
   {
      // -CH_BO: sell stop at lowest low since last BOS swing low (anti-trend sell in bull)
      entry = FindLowestLowSince((g_tt_lastBosSwLTime > 0) ? g_tt_lastBosSwLTime : g_tt_lastBosTime);
      sl    = g_tt_lastBosSwH;
      if(entry == 0) { Print("RiskManager: Cannot find lowest low for -CH_BO"); return; }
      if(sl == 0)    { Print("RiskManager: No BOS swing high for -CH_BO SL");  return; }
   }

   entry = NormalizeDouble(entry, _Digits);
   sl    = NormalizeDouble(sl, _Digits);
   double slDist  = MathAbs(entry - sl);
   double rrRatio = g_rrValues[g_rrIndex];
   double tpDist  = NormalizeDouble(slDist * rrRatio, _Digits);
   double tp      = NormalizeDouble(entry + dir * tpDist, _Digits);

   PlaceOrderLines(entry, sl, tp);
}

//+------------------------------------------------------------------+
//| Find lowest low on M15 from 'since' time to current bar         |
//+------------------------------------------------------------------+
double FindLowestLowSince(datetime since)
{
   double low[];
   datetime time[];
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(time, true);
   int bars = iBars(_Symbol, PERIOD_M15);
   int count = MathMin(bars, TT_LOOKBACK);
   if(CopyLow(_Symbol, PERIOD_M15, 0, count, low) <= 0) return 0;
   if(CopyTime(_Symbol, PERIOD_M15, 0, count, time) <= 0) return 0;
   double lowest = DBL_MAX;
   for(int i = 0; i < count; i++)
   {
      if(time[i] < since) break;
      if(low[i] < lowest) lowest = low[i];
   }
   return (lowest == DBL_MAX) ? 0 : lowest;
}

//+------------------------------------------------------------------+
//| Find highest high on M15 from 'since' time to current bar       |
//+------------------------------------------------------------------+
double FindHighestHighSince(datetime since)
{
   double high[];
   datetime time[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(time, true);
   int bars = iBars(_Symbol, PERIOD_M15);
   int count = MathMin(bars, TT_LOOKBACK);
   if(CopyHigh(_Symbol, PERIOD_M15, 0, count, high) <= 0) return 0;
   if(CopyTime(_Symbol, PERIOD_M15, 0, count, time) <= 0) return 0;
   double highest = 0;
   for(int i = 0; i < count; i++)
   {
      if(time[i] < since) break;
      if(high[i] > highest) highest = high[i];
   }
   return highest;
}

//+------------------------------------------------------------------+
//| Auto-update CHOCH order lines on new M15 bar                    |
//+------------------------------------------------------------------+
void UpdateChochOrder()
{
   if(!g_chochOrderActive || !g_linesActive) return;

   int bars = iBars(_Symbol, PERIOD_M15);
   if(bars == g_chochLastBars) return;
   g_chochLastBars = bars;

   double entry, sl;
   int dir = g_chochOrderDir;

   if(dir > 0)
   {
      entry = g_tt_swingHigh;
      if(g_chochMode == 0)
      {
         double slDist = CalcSLDistance();
         if(slDist <= 0) return;
         sl = entry - slDist;
      }
      else
         sl = g_tt_swingLow;
   }
   else
   {
      entry = g_tt_swingLow;
      if(g_chochMode == 0)
      {
         double slDist = CalcSLDistance();
         if(slDist <= 0) return;
         sl = entry + slDist;
      }
      else
         sl = g_tt_swingHigh;
   }

   if(entry == 0 || sl == 0) return;

   entry = NormalizeDouble(entry, _Digits);
   sl    = NormalizeDouble(sl, _Digits);
   double slDist  = MathAbs(entry - sl);
   double rrRatio = g_rrValues[g_rrIndex];
   double tpDist  = NormalizeDouble(slDist * rrRatio, _Digits);
   double tp      = NormalizeDouble(entry + dir * tpDist, _Digits);

   // Move existing lines
   ObjectSetDouble(0, g_entryLineName, OBJPROP_PRICE, entry);
   ObjectSetDouble(0, g_slLineName,    OBJPROP_PRICE, sl);
   ObjectSetDouble(0, g_tpLineName,    OBJPROP_PRICE, tp);
   UpdateInfoLabel();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| DSTK order: limit at matrix levels, ignores R:R                  |
//| dir > 0: +DSTK buy limit                                        |
//|   prev up candle: entry=33, SL=0, TP=100                        |
//|   prev down candle: entry=0, SL=-50, TP=67                      |
//| dir < 0: -DSTK sell limit                                       |
//|   prev down candle: entry=67, SL=100, TP=0                      |
//|   prev up candle: entry=100, SL=150, TP=33                      |
//+------------------------------------------------------------------+
void HandleDstkOrderButton(int dir)
{
   g_orderDir      = dir;
   g_orderType     = 1;  // limit order
   g_isMarketOrder = false;

   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, daily) < 1)
   {
      Print("RiskManager: Cannot get previous daily candle for DSTK");
      return;
   }

   double prevH  = daily[0].high;
   double prevL  = daily[0].low;
   double range  = prevH - prevL;
   if(range <= 0) { Print("RiskManager: Zero range on prev day"); return; }

   bool prevBull = (daily[0].close >= daily[0].open);

   double entry, sl, tp;

   if(dir > 0) // +DSTK buy limit
   {
      if(prevBull)
      {
         entry = prevL + range / 3.0;       // 33
         sl    = prevL;                      // 0
         tp    = prevH;                      // 100
      }
      else
      {
         entry = prevL;                      // 0
         sl    = prevL - range / 2.0;        // -50
         tp    = prevL + 2.0 * range / 3.0;  // 67
      }
   }
   else // -DSTK sell limit
   {
      if(!prevBull) // prev down candle
      {
         entry = prevL + 2.0 * range / 3.0;  // 67
         sl    = prevH;                       // 100
         tp    = prevL;                       // 0
      }
      else // prev up candle
      {
         entry = prevH;                       // 100
         sl    = prevH + range / 2.0;         // 150
         tp    = prevL + range / 3.0;          // 33
      }
   }

   entry = NormalizeDouble(entry, _Digits);
   sl    = NormalizeDouble(sl, _Digits);
   tp    = NormalizeDouble(tp, _Digits);

   PlaceOrderLines(entry, sl, tp);
}

//+------------------------------------------------------------------+
//| R_FV: Limit order at swing level with SL Range + R:R presets     |
//+------------------------------------------------------------------+
void HandleRfvOrderButton(int dir)
{
   g_orderDir      = dir;
   g_orderType     = 1;  // limit order
   g_isMarketOrder = false;

   double entry;
   if(dir > 0)
   {
      entry = g_tt_swingLow;
      if(entry == 0) { Print("RiskManager: No swing low for +R_FV"); return; }
   }
   else
   {
      entry = g_tt_swingHigh;
      if(entry == 0) { Print("RiskManager: No swing high for -R_FV"); return; }
   }

   double slDist = CalcSLDistance();
   if(slDist <= 0)
   {
      Print("RiskManager: ERROR - No daily data for R_FV SL calc");
      return;
   }

   double rrRatio = g_rrValues[g_rrIndex];
   double tpDist  = NormalizeDouble(slDist * rrRatio, _Digits);

   entry      = NormalizeDouble(entry, _Digits);
   double sl  = NormalizeDouble(entry - dir * slDist, _Digits);
   double tp  = NormalizeDouble(entry + dir * tpDist, _Digits);

   PlaceOrderLines(entry, sl, tp);
}

//+------------------------------------------------------------------+
//| BOS retracement limit order: entry at S.RT 67% retrace           |
//| SL = BOS swing level, TP = extreme since BOS (2:1 R:R)          |
//+------------------------------------------------------------------+
void HandleBosOrderButton(int dir)
{
   g_orderDir      = dir;
   g_orderType     = 1;  // limit order
   g_isMarketOrder = false;

   EnsureThrustComputed();
   if((g_tt_lastBosSwH == 0 && g_tt_lastBosSwL == 0) || g_tt_lastBosTime == 0)
   {
      Print("RiskManager: No BOS/CHOCH for BOS order"); return;
   }

   double entry, sl, tp;
   if(dir > 0)
   {
      // +BOS buy limit: bullish, retrace from highest high toward swing low
      if(g_tt_lastBosSwL == 0) { Print("RiskManager: No swing low for +BOS"); return; }
      // Range starts from swing high (where BOS plotted), not from BOS break bar
      int swBar = iBarShift(_Symbol, PERIOD_M15, (g_tt_lastBosSwHTime > 0) ? g_tt_lastBosSwHTime : g_tt_lastBosTime);
      if(swBar < 0) swBar = 0;
      double hh = 0;
      for(int j = 0; j <= swBar; j++)
      {
         double h = iHigh(_Symbol, PERIOD_M15, j);
         if(h > hh) hh = h;
      }
      if(hh <= g_tt_lastBosSwL)
      {
         Print("RiskManager: Highest high not above swing low"); return;
      }
      double retrace67 = hh - (hh - g_tt_lastBosSwL) * 2.0 / 3.0;
      entry = retrace67;
      if(g_bosLmtMode == 1)
      {
         // Find candle with lowest low since BOS, use its high as entry
         double extremeLow = DBL_MAX;
         double extremeCandleHigh = 0;
         for(int j = 0; j <= swBar; j++)
         {
            double l = iLow(_Symbol, PERIOD_M15, j);
            if(l < extremeLow)
            {
               extremeLow = l;
               extremeCandleHigh = iHigh(_Symbol, PERIOD_M15, j);
            }
         }
         if(extremeCandleHigh > 0)
            entry = extremeCandleHigh;
      }
      sl    = g_tt_lastBosSwL;
      tp    = hh;
   }
   else
   {
      // -BOS sell limit: bearish, retrace from lowest low toward swing high
      if(g_tt_lastBosSwH == 0) { Print("RiskManager: No swing high for -BOS"); return; }
      // Range starts from swing low (where BOS plotted), not from BOS break bar
      int swBar = iBarShift(_Symbol, PERIOD_M15, (g_tt_lastBosSwLTime > 0) ? g_tt_lastBosSwLTime : g_tt_lastBosTime);
      if(swBar < 0) swBar = 0;
      double ll = DBL_MAX;
      for(int j = 0; j <= swBar; j++)
      {
         double l = iLow(_Symbol, PERIOD_M15, j);
         if(l < ll) ll = l;
      }
      if(g_tt_lastBosSwH <= ll)
      {
         Print("RiskManager: Lowest low not below swing high"); return;
      }
      double retrace67 = ll + (g_tt_lastBosSwH - ll) * 2.0 / 3.0;
      entry = retrace67;
      if(g_bosLmtMode == 1)
      {
         // Find candle with highest high since BOS, use its low as entry
         double extremeHigh = 0;
         double extremeCandleLow = 0;
         for(int j = 0; j <= swBar; j++)
         {
            double h = iHigh(_Symbol, PERIOD_M15, j);
            if(h > extremeHigh)
            {
               extremeHigh = h;
               extremeCandleLow = iLow(_Symbol, PERIOD_M15, j);
            }
         }
         if(extremeCandleLow > 0)
            entry = extremeCandleLow;
      }
      sl    = g_tt_lastBosSwH;
      tp    = ll;
   }

   entry = NormalizeDouble(entry, _Digits);
   sl    = NormalizeDouble(sl, _Digits);
   tp    = NormalizeDouble(tp, _Digits);

   PlaceOrderLines(entry, sl, tp);
}

//+------------------------------------------------------------------+
//| Wick FVG search (spec: 3-candle gap, deepest unfilled).         |
//| direction: +1 = bullish (c2.high < c0.low), entry = c2.high.    |
//|            -1 = bearish (c2.low  > c0.high), entry = c2.low.    |
//| swingFilter: bullish FVG bottom must be > filter (long swing low);
//|              bearish FVG top must be < filter (short swing high).
//| outEntry receives the FVG edge (c2.high for long, c2.low for short).
//| Returns true if a valid unfilled FVG was found.                 |
//+------------------------------------------------------------------+
bool FindDeepestWickFVG(datetime fromTime, int direction, double swingFilter,
                        double &outEntry)
{
   int fromBar = iBarShift(_Symbol, PERIOD_M15, fromTime);
   if(fromBar < 2) return false;
   bool   found = false;
   double bestEdge = 0;
   // j = older end of triplet (c[2]); c[0] = j-2 (more recent).
   for(int j = fromBar; j >= 2; j--)
   {
      double c2h = iHigh(_Symbol, PERIOD_M15, j);
      double c2l = iLow (_Symbol, PERIOD_M15, j);
      double c0h = iHigh(_Symbol, PERIOD_M15, j-2);
      double c0l = iLow (_Symbol, PERIOD_M15, j-2);

      double edge = 0;
      bool valid = false;
      if(direction > 0 && c2h < c0l)
      {
         edge = c2h;
         valid = (edge > swingFilter);
      }
      else if(direction < 0 && c2l > c0h)
      {
         edge = c2l;
         valid = (edge < swingFilter);
      }
      if(!valid) continue;

      // Filled? Any bar from j-3 down to 0 traded through the gap edge.
      bool filled = false;
      for(int k = j - 3; k >= 0; k--)
      {
         if(direction > 0 && iLow (_Symbol, PERIOD_M15, k) <= edge) { filled = true; break; }
         if(direction < 0 && iHigh(_Symbol, PERIOD_M15, k) >= edge) { filled = true; break; }
      }
      if(filled) continue;

      bool better = !found
         || (direction > 0 && edge < bestEdge)
         || (direction < 0 && edge > bestEdge);
      if(better) { bestEdge = edge; found = true; }
   }
   if(found) outEntry = bestEdge;
   return found;
}

//+------------------------------------------------------------------+
//| CHOCH Retrace limit order: requires latest mark = CHOCH (no      |
//| later continuation BOS). Entry = deepest unfilled wick FVG edge. |
//| SL = opposite swing. dir > 0: +CH_R (long after CHOCH-up).      |
//+------------------------------------------------------------------+
void HandleChochRetraceOrderButton(int dir)
{
   g_orderDir      = dir;
   g_orderType     = 1;  // limit
   g_isMarketOrder = false;

   if(g_tt_lastChochTime == 0)
   { Print("RiskManager: No CHOCH for CH_R order"); return; }
   if(g_tt_lastContBosTime > g_tt_lastChochTime)
   { Print("RiskManager: A continuation BOS occurred after last CHOCH \x2014 use BS_R"); return; }
   if(dir > 0 && !g_tt_lastChochIsHigh)
   { Print("RiskManager: Latest CHOCH is down, +CH_R needs CHOCH-up"); return; }
   if(dir < 0 && g_tt_lastChochIsHigh)
   { Print("RiskManager: Latest CHOCH is up, -CH_R needs CHOCH-down"); return; }

   double swH = g_tt_swingHigh, swL = g_tt_swingLow;
   if(swH == 0 || swL == 0) { Print("RiskManager: No swing levels for CH_R"); return; }
   double swingFilter = (dir > 0) ? swL : swH;
   double entry;
   if(!FindDeepestWickFVG(g_tt_lastChochTime, dir, swingFilter, entry))
   { Print("RiskManager: No unfilled wick FVG for CH_R"); return; }

   double sl = (dir > 0) ? swL : swH;
   if((dir > 0 && entry <= sl) || (dir < 0 && entry >= sl))
   { Print("RiskManager: CH_R entry/SL inverted"); return; }

   entry = NormalizeDouble(entry, _Digits);
   sl    = NormalizeDouble(sl,    _Digits);
   double slDist  = MathAbs(entry - sl);
   double rrRatio = g_rrValues[g_rrIndex];
   double tpDist  = NormalizeDouble(slDist * rrRatio, _Digits);
   double tp      = NormalizeDouble(entry + dir * tpDist, _Digits);

   PlaceOrderLines(entry, sl, tp);
}

//+------------------------------------------------------------------+
//| BOS Retrace limit order (wick-FVG variant). Requires a           |
//| continuation BOS since last CHOCH. Entry = deepest unfilled FVG  |
//| edge between that BOS and now. SL = opposite swing.              |
//+------------------------------------------------------------------+
void HandleBosRetraceFvgOrderButton(int dir)
{
   g_orderDir      = dir;
   g_orderType     = 1;
   g_isMarketOrder = false;

   if(g_tt_lastContBosTime == 0)
   { Print("RiskManager: No continuation BOS for BS_R order"); return; }
   if(g_tt_lastChochTime > g_tt_lastContBosTime)
   { Print("RiskManager: A CHOCH occurred after last BOS \x2014 use CH_R"); return; }
   if(dir > 0 && !g_tt_lastContBosIsHigh)
   { Print("RiskManager: Latest BOS is down, +BS_R needs BOS-up"); return; }
   if(dir < 0 && g_tt_lastContBosIsHigh)
   { Print("RiskManager: Latest BOS is up, -BS_R needs BOS-down"); return; }

   double swH = g_tt_swingHigh, swL = g_tt_swingLow;
   if(swH == 0 || swL == 0) { Print("RiskManager: No swing levels for BS_R"); return; }
   double swingFilter = (dir > 0) ? swL : swH;
   double entry;
   if(!FindDeepestWickFVG(g_tt_lastContBosTime, dir, swingFilter, entry))
   { Print("RiskManager: No unfilled wick FVG for BS_R"); return; }

   double sl = (dir > 0) ? swL : swH;
   if((dir > 0 && entry <= sl) || (dir < 0 && entry >= sl))
   { Print("RiskManager: BS_R entry/SL inverted"); return; }

   entry = NormalizeDouble(entry, _Digits);
   sl    = NormalizeDouble(sl,    _Digits);
   double slDist  = MathAbs(entry - sl);
   double rrRatio = g_rrValues[g_rrIndex];
   double tpDist  = NormalizeDouble(slDist * rrRatio, _Digits);
   double tp      = NormalizeDouble(entry + dir * tpDist, _Digits);

   PlaceOrderLines(entry, sl, tp);
}

//+------------------------------------------------------------------+
//| CHOCH Continuation stop order: after CHOCH, wait for counter-    |
//| flow (new opposite-side swing) and place stop at the swing that  |
//| would resume the trend. SL = swing responsible for counter-flow. |
//+------------------------------------------------------------------+
void HandleChochContinuationOrderButton(int dir)
{
   g_orderDir      = dir;
   g_orderType     = 2;  // stop
   g_isMarketOrder = false;

   if(dir > 0)
   {
      // +CH_C: trend bullish (1), flow down (2), Up-BOS armed.
      if(g_tt_tTrend != 1 || g_tt_tFlow != 2 || !g_tt_check4UpBos)
      { Print("RiskManager: +CH_C requires bullish trend with down-flow & Up-BOS armed"); return; }
      double swH = g_tt_swingHigh, swL = g_tt_swingLow;
      if(swH == 0 || swL == 0) { Print("RiskManager: No swing levels for +CH_C"); return; }
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask >= swH) { Print("RiskManager: Price already broke swing high \x2014 +CH_C invalid"); return; }
      double entry = NormalizeDouble(swH, _Digits);
      double sl    = NormalizeDouble(swL, _Digits);
      double slDist  = MathAbs(entry - sl);
      double rrRatio = g_rrValues[g_rrIndex];
      double tpDist  = NormalizeDouble(slDist * rrRatio, _Digits);
      double tp      = NormalizeDouble(entry + tpDist, _Digits);
      PlaceOrderLines(entry, sl, tp);
   }
   else
   {
      if(g_tt_tTrend != 2 || g_tt_tFlow != 1 || !g_tt_check4DnBos)
      { Print("RiskManager: -CH_C requires bearish trend with up-flow & Dn-BOS armed"); return; }
      double swH = g_tt_swingHigh, swL = g_tt_swingLow;
      if(swH == 0 || swL == 0) { Print("RiskManager: No swing levels for -CH_C"); return; }
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid <= swL) { Print("RiskManager: Price already broke swing low \x2014 -CH_C invalid"); return; }
      double entry = NormalizeDouble(swL, _Digits);
      double sl    = NormalizeDouble(swH, _Digits);
      double slDist  = MathAbs(entry - sl);
      double rrRatio = g_rrValues[g_rrIndex];
      double tpDist  = NormalizeDouble(slDist * rrRatio, _Digits);
      double tp      = NormalizeDouble(entry - tpDist, _Digits);
      PlaceOrderLines(entry, sl, tp);
   }
}

//+------------------------------------------------------------------+
//| UFV Reversion market order.                                     |
//|                                                                  |
//| -UFV (sell): uptrend, bid > swing high. SL = entry + range,     |
//|   where range = (highest high since last swing low) − swing low.|
//|   TP from R:R preset.                                            |
//| +UFV (buy):  downtrend, ask < swing low. SL = entry − range,    |
//|   where range = swing high − (lowest low since last swing high).|
//|   TP from R:R preset.                                            |
//|                                                                  |
//| The range represents the height of a full reversal leg, so SL   |
//| sits one such leg beyond entry — wide on purpose, accounting    |
//| for the worst-case continuation against the reversion thesis.   |
//+------------------------------------------------------------------+
void HandleUfvReversionOrderButton(int dir)
{
   g_orderDir      = dir;
   g_orderType     = 0;  // market
   g_isMarketOrder = true;

   double swH = g_tt_swingHigh, swL = g_tt_swingLow;
   if(swH == 0 || swL == 0) { Print("RiskManager: No swing levels for UFV"); return; }

   double entry, sl, tp;
   if(dir < 0)
   {
      // -UFV: bullish trend, price has overshot above swing high → market sell.
      if(g_tt_tTrend != 1) { Print("RiskManager: -UFV requires bullish trend"); return; }
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid <= swH) { Print("RiskManager: -UFV waits for bid > swing high"); return; }
      if(g_tt_swingLowTime == 0) { Print("RiskManager: -UFV missing swing low time"); return; }
      double hh = FindHighestHighSince(g_tt_swingLowTime);
      if(hh <= 0) { Print("RiskManager: -UFV cannot find highest high since swing low"); return; }
      double range = hh - swL;
      if(range <= 0) { Print("RiskManager: -UFV invalid range (hh <= swL)"); return; }
      entry = bid;
      sl    = entry + range;
      double slDist  = sl - entry;
      double rrRatio = g_rrValues[g_rrIndex];
      tp = entry - slDist * rrRatio;
   }
   else
   {
      // +UFV: bearish trend, price has overshot below swing low → market buy.
      if(g_tt_tTrend != 2) { Print("RiskManager: +UFV requires bearish trend"); return; }
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask >= swL) { Print("RiskManager: +UFV waits for ask < swing low"); return; }
      if(g_tt_swingHighTime == 0) { Print("RiskManager: +UFV missing swing high time"); return; }
      double ll = FindLowestLowSince(g_tt_swingHighTime);
      if(ll <= 0) { Print("RiskManager: +UFV cannot find lowest low since swing high"); return; }
      double range = swH - ll;
      if(range <= 0) { Print("RiskManager: +UFV invalid range (swH <= ll)"); return; }
      entry = ask;
      sl    = entry - range;
      double slDist  = entry - sl;
      double rrRatio = g_rrValues[g_rrIndex];
      tp = entry + slDist * rrRatio;
   }

   entry = NormalizeDouble(entry, _Digits);
   sl    = NormalizeDouble(sl,    _Digits);
   tp    = NormalizeDouble(tp,    _Digits);
   PlaceOrderLines(entry, sl, tp);
}

//+------------------------------------------------------------------+
//| Wrapper: order button click with toggle-off logic                |
//+------------------------------------------------------------------+
void HandleOrderBtnClick(string btnName, int dir, int type, bool isHidden, bool isSwing = false)
{
   ObjectSetInteger(0, btnName, OBJPROP_STATE, false);

   // Toggle off if same button pressed again while lines are active
   if(g_linesActive && g_lastOrderBtn == btnName)
   {
      DeleteOrderLines();
      CancelHiddenOrder();
      g_chochOrderActive = false;
      g_lastOrderBtn = "";
      ClearInfoLabel();
      return;
   }

   // Cancel any previous hidden order / CHOCH
   CancelHiddenOrder();
   g_chochOrderActive = false;

   g_lastOrderBtn  = btnName;
   g_isHiddenOrder = isHidden;
   if(isSwing)
      HandleSwingOrderButton(dir, type);
   else
      HandleOrderButton(dir, type);

   // Activate auto-follow for market buttons (D_MTX and SWING market)
   if(type == 0 && !isHidden)
   {
      g_autoOrderActive = true;
      g_autoOrderBtn    = btnName;
      // Mark button text with "auto" indicator
      string curText = ObjectGetString(0, btnName, OBJPROP_TEXT);
      ObjectSetString(0, btnName, OBJPROP_TEXT, curText + " auto");
   }
}

//+------------------------------------------------------------------+
//| Availability check — used for both the gray-out display and as a |
//| click-time gate. Returns true if the button's preconditions are  |
//| satisfied right now.                                              |
//+------------------------------------------------------------------+
bool IsOrderBtnAvailable(string btn)
{
   bool isUp   = (g_tt_tTrend == 1);
   bool isDown = (g_tt_tTrend == 2);

   // ── Trend-only gating with cheap data checks ──
   if(btn == "RM_BuyMktSw")    return isUp;
   if(btn == "RM_SellMktSw")   return isDown;
   if(btn == "RM_BuyLmtBOS")   return isUp   && g_tt_lastBosSwL > 0;
   if(btn == "RM_SellLmtBOS")  return isDown && g_tt_lastBosSwH > 0;
   if(btn == "RM_BuyStpCH")    return isDown && g_tt_swingHigh > 0;
   if(btn == "RM_SellStpCH")   return isUp   && g_tt_swingLow > 0;
   if(btn == "RM_BuyStpBK")    return isUp   && g_tt_lastBosTime > 0 && g_tt_lastBosSwL > 0;
   if(btn == "RM_SellStpBK")   return isDown && g_tt_lastBosTime > 0 && g_tt_lastBosSwH > 0;
   if(btn == "RM_BuyStpCB")    return isDown && g_tt_lastBosTime > 0 && g_tt_lastBosSwL > 0;
   if(btn == "RM_SellStpCB")   return isUp   && g_tt_lastBosTime > 0 && g_tt_lastBosSwH > 0;

   // ── CH_C (continuation): trend + flow + BOS armed + swings + price-still-inside ──
   if(btn == "RM_BuyStpChC")
   {
      if(!(isUp   && g_tt_tFlow == 2 && g_tt_check4UpBos)) return false;
      if(g_tt_swingHigh == 0 || g_tt_swingLow == 0)        return false;
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      return (ask < g_tt_swingHigh);
   }
   if(btn == "RM_SellStpChC")
   {
      if(!(isDown && g_tt_tFlow == 1 && g_tt_check4DnBos)) return false;
      if(g_tt_swingHigh == 0 || g_tt_swingLow == 0)        return false;
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return (bid > g_tt_swingLow);
   }

   // ── UFV (reversion): anti-trend + price beyond opposite swing ──
   if(btn == "RM_BuyMktUFV")
   {
      if(!isDown || g_tt_swingLow == 0 || g_tt_swingHigh == 0) return false;
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      return (ask < g_tt_swingLow);
   }
   if(btn == "RM_SellMktUFV")
   {
      if(!isUp || g_tt_swingHigh == 0 || g_tt_swingLow == 0) return false;
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return (bid > g_tt_swingHigh);
   }

   // ── CH_R / BS_R (require unfilled wick FVG) ──
   if(btn == "RM_BuyLmtChR")
   {
      if(g_tt_lastChochTime == 0)                          return false;
      if(g_tt_lastContBosTime > g_tt_lastChochTime)        return false;
      if(!g_tt_lastChochIsHigh)                            return false;
      if(g_tt_swingHigh == 0 || g_tt_swingLow == 0)        return false;
      double dummy;
      return FindDeepestWickFVG(g_tt_lastChochTime, +1, g_tt_swingLow, dummy);
   }
   if(btn == "RM_SellLmtChR")
   {
      if(g_tt_lastChochTime == 0)                          return false;
      if(g_tt_lastContBosTime > g_tt_lastChochTime)        return false;
      if(g_tt_lastChochIsHigh)                             return false;
      if(g_tt_swingHigh == 0 || g_tt_swingLow == 0)        return false;
      double dummy;
      return FindDeepestWickFVG(g_tt_lastChochTime, -1, g_tt_swingHigh, dummy);
   }
   if(btn == "RM_BuyLmtBoR")
   {
      if(g_tt_lastContBosTime == 0)                        return false;
      if(g_tt_lastChochTime > g_tt_lastContBosTime)        return false;
      if(!g_tt_lastContBosIsHigh)                          return false;
      if(g_tt_swingHigh == 0 || g_tt_swingLow == 0)        return false;
      double dummy;
      return FindDeepestWickFVG(g_tt_lastContBosTime, +1, g_tt_swingLow, dummy);
   }
   if(btn == "RM_SellLmtBoR")
   {
      if(g_tt_lastContBosTime == 0)                        return false;
      if(g_tt_lastChochTime > g_tt_lastContBosTime)        return false;
      if(g_tt_lastContBosIsHigh)                           return false;
      if(g_tt_swingHigh == 0 || g_tt_swingLow == 0)        return false;
      double dummy;
      return FindDeepestWickFVG(g_tt_lastContBosTime, -1, g_tt_swingHigh, dummy);
   }

   return true;  // always-available buttons (D_MTX market/limit/stop, D_STK)
}

//+------------------------------------------------------------------+
//| Gray-out helper for advanced buttons that depend on wick FVG /   |
//| flow / BOS-armed state. Sets background and text color.           |
//+------------------------------------------------------------------+
void ApplyAdvancedBtnGating(string btn, bool isBuy)
{
   bool ok = IsOrderBtnAvailable(btn);
   color onClr = isBuy ? CLR_BTN_BUY : CLR_BTN_SELL;
   ObjectSetInteger(0, btn, OBJPROP_BGCOLOR, ok ? onClr : CLR_BTN_PLC);
   ObjectSetInteger(0, btn, OBJPROP_COLOR,   ok ? CLR_TEXT : CLR_TEXT_DIM);
}

//+------------------------------------------------------------------+
//| Re-run the armed order's recipe each new M15 bar so entry/SL/TP  |
//| follow new swing data automatically. Skipped if the user has     |
//| manually dragged the SL line (g_slManualOverride).                |
//+------------------------------------------------------------------+
void RerunArmedOrder()
{
   if(g_lastOrderBtn == "")     return;
   if(!g_linesActive)           return;
   if(g_slManualOverride)       return;

   int      curBars = iBars(_Symbol, PERIOD_M15);
   datetime curTime = TimeCurrent();

   // Newly-armed (or re-armed) button: baseline only, do not fire this instant
   if(g_lastOrderBtn != g_armedOrderTrackedBtn)
   {
      g_armedOrderTrackedBtn = g_lastOrderBtn;
      g_armedOrderLastBars   = curBars;
      g_armedOrderLastTime   = curTime;
      return;
   }

   // Fire on (a) bar change — picks up new swing/BOS data — OR
   //         (b) 3-second elapsed — picks up live Ask/Bid drift between bars.
   // The 3-sec throttle gives the user time to grab and drag the lines.
   bool barChanged  = (curBars != g_armedOrderLastBars);
   bool tickElapsed = (curTime - g_armedOrderLastTime >= 3);
   if(!barChanged && !tickElapsed) return;
   g_armedOrderLastBars = curBars;
   g_armedOrderLastTime = curTime;

   string b = g_lastOrderBtn;

   // SLRANGE D_MTX
   if(b == "RM_BuyMkt")        HandleOrderButton(+1, 0);
   else if(b == "RM_SellMkt")  HandleOrderButton(-1, 0);
   else if(b == "RM_BuyLmt")   HandleOrderButton(+1, 1);
   else if(b == "RM_SellLmt")  HandleOrderButton(-1, 1);
   else if(b == "RM_BuyStp")   HandleOrderButton(+1, 2);
   else if(b == "RM_SellStp")  HandleOrderButton(-1, 2);
   // SWING market
   else if(b == "RM_BuyMktSw")  HandleSwingOrderButton(+1, 0);
   else if(b == "RM_SellMktSw") HandleSwingOrderButton(-1, 0);
   // DSTK
   else if(b == "RM_BuyLmtDK")  HandleDstkOrderButton(+1);
   else if(b == "RM_SellLmtDK") HandleDstkOrderButton(-1);
   // BOS retracement
   else if(b == "RM_BuyLmtBOS")  HandleBosOrderButton(+1);
   else if(b == "RM_SellLmtBOS") HandleBosOrderButton(-1);
   // CHOCH stop
   else if(b == "RM_BuyStpCH")  HandleChochOrderButton(+1);
   else if(b == "RM_SellStpCH") HandleChochOrderButton(-1);
   // BS_BO / CH_BO
   else if(b == "RM_BuyStpBK")  HandleBkoOrderButton(+1);
   else if(b == "RM_SellStpBK") HandleBkoOrderButton(-1);
   else if(b == "RM_BuyStpCB")  HandleChBoOrderButton(+1);
   else if(b == "RM_SellStpCB") HandleChBoOrderButton(-1);
   // Advanced (wick-FVG / flow / continuation / reversion)
   else if(b == "RM_BuyLmtChR")  HandleChochRetraceOrderButton(+1);
   else if(b == "RM_SellLmtChR") HandleChochRetraceOrderButton(-1);
   else if(b == "RM_BuyLmtBoR")  HandleBosRetraceFvgOrderButton(+1);
   else if(b == "RM_SellLmtBoR") HandleBosRetraceFvgOrderButton(-1);
   else if(b == "RM_BuyStpChC")  HandleChochContinuationOrderButton(+1);
   else if(b == "RM_SellStpChC") HandleChochContinuationOrderButton(-1);
   else if(b == "RM_BuyMktUFV")  HandleUfvReversionOrderButton(+1);
   else if(b == "RM_SellMktUFV") HandleUfvReversionOrderButton(-1);
}

//+------------------------------------------------------------------+
void ReRenderLinesFromSettings()
{
   if(!g_linesActive) return;
   double entry = ObjectGetDouble(0, g_entryLineName, OBJPROP_PRICE);
   if(entry == 0) return;
   int    dir     = g_orderDir;
   double slDist;

   if(g_slManualOverride)
   {
      // SL was manually dragged – keep its current position
      double sl = ObjectGetDouble(0, g_slLineName, OBJPROP_PRICE);
      slDist = MathAbs(entry - sl);
   }
   else
   {
      slDist = CalcSLDistance();
      if(slDist <= 0) return;
      double sl = NormalizeDouble(entry - dir * slDist, _Digits);
      ObjectSetDouble(0, g_slLineName, OBJPROP_PRICE, sl);
   }

   double rrRatio = g_rrValues[g_rrIndex];
   double tpDist  = NormalizeDouble(slDist * rrRatio, _Digits);
   double tp = NormalizeDouble(entry + dir * tpDist, _Digits);
   ObjectSetDouble(0, g_tpLineName, OBJPROP_PRICE, tp);
   UpdateInfoLabel();
}

//+------------------------------------------------------------------+
void RecalcFromLines()
{
   if(!g_linesActive) return;
   UpdateInfoLabel();
}

//+------------------------------------------------------------------+
//| Auto-follow: move entry to current price and recalculate SL/TP   |
//+------------------------------------------------------------------+
void UpdateAutoOrder()
{
   if(!g_autoOrderActive || !g_linesActive) return;

   int dir = g_orderDir;
   double entry = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   entry = NormalizeDouble(entry, _Digits);

   // Check if entry actually changed to avoid unnecessary redraws
   double curEntry = ObjectGetDouble(0, g_entryLineName, OBJPROP_PRICE);
   if(MathAbs(entry - curEntry) < _Point * 0.5) return;

   // For swing orders, SL stays on swing level, only entry+TP move
   bool isSwing = (g_autoOrderBtn == "RM_BuyMktSw" || g_autoOrderBtn == "RM_SellMktSw");
   double sl, slDist, tp;

   if(isSwing || g_slManualOverride)
   {
      sl     = ObjectGetDouble(0, g_slLineName, OBJPROP_PRICE);
      slDist = MathAbs(entry - sl);
   }
   else
   {
      slDist = CalcSLDistance();
      if(slDist <= 0) return;
      sl = NormalizeDouble(entry - dir * slDist, _Digits);
   }

   double rrRatio = g_rrValues[g_rrIndex];
   double tpDist  = NormalizeDouble(slDist * rrRatio, _Digits);
   tp = NormalizeDouble(entry + dir * tpDist, _Digits);

   ObjectSetDouble(0, g_entryLineName, OBJPROP_PRICE, entry);
   if(!isSwing && !g_slManualOverride)
      ObjectSetDouble(0, g_slLineName, OBJPROP_PRICE, sl);
   ObjectSetDouble(0, g_tpLineName, OBJPROP_PRICE, tp);
   UpdateInfoLabel();
}

//+------------------------------------------------------------------+
//| Close partial % of positions for _Symbol                         |
//+------------------------------------------------------------------+
void ClosePartial(double pct)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double vol     = PositionGetDouble(POSITION_VOLUME);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(lotStep <= 0) lotStep = 0.01;
      double closeVol = MathFloor((vol * pct) / lotStep) * lotStep;
      if(closeVol < lotMin) closeVol = lotMin;
      if(closeVol > vol)    closeVol = vol;
      g_trade.PositionClosePartial(ticket, closeVol);
   }
}

//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      g_trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
void CloseAllForSymbol()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      g_trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Close sym with SL nudge: if in profit, 75% chance to move SL    |
//| closer to current price by a random amount before closing        |
//+------------------------------------------------------------------+
void CloseSymWithSLNudge()
{
   MathSrand((uint)GetTickCount());
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double curSL     = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      long   type      = PositionGetInteger(POSITION_TYPE);
      double profit    = PositionGetDouble(POSITION_PROFIT);

      // Only nudge SL if position is in profit and random roll hits (75%)
      if(profit > 0 && (MathRand() % 100) < 75)
      {
         double curPrice = (type == POSITION_TYPE_BUY) ? bid : ask;
         double dist = MathAbs(curPrice - curSL);
         if(dist > 0 && curSL > 0)
         {
            // Random fraction 20-80% of the distance between SL and current price
            double frac = (20.0 + (MathRand() % 61)) / 100.0;
            double nudge = dist * frac;
            double newSL = 0;
            if(type == POSITION_TYPE_BUY)
               newSL = curSL + nudge;  // move SL up toward bid
            else
               newSL = curSL - nudge;  // move SL down toward ask
            newSL = NormalizeDouble(newSL, _Digits);
            g_trade.PositionModify(ticket, newSL, tp);
         }
      }
      g_trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Equity TP/SL â€” adjust %                                         |
//+------------------------------------------------------------------+
void AdjustEqTP(double delta)
{
   double newPct = NormalizeDouble(g_eqTPPct + delta, 1);
   if(newPct < 0) newPct = 0;
   g_eqTPPct = newPct;
   RefreshEqLabels();
}

void AdjustEqSL(double delta)
{
   double newPct = NormalizeDouble(g_eqSLPct + delta, 1);
   if(newPct < 0) newPct = 0;
   g_eqSLPct = newPct;
   RefreshEqLabels();
}

void ToggleEqTP()
{
   if(g_eqTPPct <= 0) return;  // can't arm with 0%
   g_eqTPActive = !g_eqTPActive;
   if(g_eqTPActive)
      g_eqBaseline = AccountInfoDouble(ACCOUNT_BALANCE);
   RefreshEqLabels();
}

void ToggleEqSL()
{
   if(g_eqSLPct <= 0) return;
   g_eqSLActive = !g_eqSLActive;
   if(g_eqSLActive)
      g_eqBaseline = AccountInfoDouble(ACCOUNT_BALANCE);
   RefreshEqLabels();
}

void RefreshEqLabels()
{
   string tpTxt = EqLabelText("TP", g_eqTPPct, g_eqTPActive);
   ObjectSetString(0, "RM_EqTPLbl", OBJPROP_TEXT, tpTxt);
   ObjectSetInteger(0, "RM_EqTPLbl", OBJPROP_BGCOLOR,
                    g_eqTPActive ? CLR_BTN_ON : (g_eqTPPct > 0) ? CLR_BTN_BUY : CLR_BTN_OFF);

   string slTxt = EqLabelText("SL", g_eqSLPct, g_eqSLActive);
   ObjectSetString(0, "RM_EqSLLbl", OBJPROP_TEXT, slTxt);
   ObjectSetInteger(0, "RM_EqSLLbl", OBJPROP_BGCOLOR,
                    g_eqSLActive ? CLR_BTN_ON : (g_eqSLPct > 0) ? CLR_BTN_SELL : CLR_BTN_OFF);
   ChartRedraw(0);
}

string EqLabelText(string prefix, double pct, bool active)
{
   if(pct <= 0) return prefix + "%  OFF";
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double dollarVal = bal * pct / 100.0;
   double targetEq  = (prefix == "TP") ? bal + dollarVal : bal - dollarVal;
   string state = active ? "ON" : "OFF";
   return StringFormat("%s  %.1f%%\n\n$%.0f  %s", prefix, pct, targetEq, state);
}

//+------------------------------------------------------------------+
//| Check equity TP/SL â€” called from OnTick                         |
//+------------------------------------------------------------------+
void CheckEquityTPSL()
{
   if(!g_eqTPActive && !g_eqSLActive) return;
   if(g_eqBaseline <= 0) return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double pctChange = ((equity - g_eqBaseline) / g_eqBaseline) * 100.0;

   // TP hit
   if(g_eqTPActive && g_eqTPPct > 0 && pctChange >= g_eqTPPct)
   {
      Print(StringFormat("RiskManager: Equity TP hit! +%.1f%% (Balance $%.0f -> Equity $%.0f). Closing %s.",
                         pctChange, g_eqBaseline, equity, _Symbol));
      SendDiscordAlert(AlertMsg("\xE2\x9C\x85", "EQ TP", StringFormat("+%.1f%% from balance, closing all positions", pctChange)));
      CloseAllPositions();
      g_eqTPActive = false;
      g_eqSLActive = false;
      RefreshEqLabels();
      return;
   }

   // SL hit
   if(g_eqSLActive && g_eqSLPct > 0 && pctChange <= -g_eqSLPct)
   {
      Print(StringFormat("RiskManager: Equity SL hit! %.1f%% (Balance $%.0f -> Equity $%.0f). Closing %s.",
                         pctChange, g_eqBaseline, equity, _Symbol));
      SendDiscordAlert(AlertMsg("\xF0\x9F\x9B\x91", "EQ SL", StringFormat("%.1f%% from balance, closing all positions", pctChange)));
      CloseAllPositions();
      g_eqTPActive = false;
      g_eqSLActive = false;
      RefreshEqLabels();
      return;
   }
}

//+------------------------------------------------------------------+
//| Move all SL to breakeven for current symbol                      |
//+------------------------------------------------------------------+
void MoveAllSLToBreakeven()
{
   int moved = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      if(MathAbs(sl - entry) < _Point) continue;
      if(g_trade.PositionModify(ticket, entry, tp))
         moved++;
   }
   Print("RiskManager: Moved ", moved, " position(s) SL to breakeven on ", _Symbol);
}

//+------------------------------------------------------------------+
//| Create matrix lines (shared helper)                              |
//+------------------------------------------------------------------+
void CreateMatrixLines(string aboveName, string belowName, string timeName,
                       color lineClr)
{
   double deviation = CalcSLDistance();
   if(deviation <= 0)
   {
      Print("RiskManager: Cannot create matrix â€” no daily data.");
      return;
   }

   double mid   = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double above = NormalizeDouble(mid + deviation, _Digits);
   double below = NormalizeDouble(mid - deviation, _Digits);

   ObjectCreate(0, aboveName, OBJ_HLINE, 0, 0, above);
   ObjectSetInteger(0, aboveName, OBJPROP_COLOR, lineClr);
   ObjectSetInteger(0, aboveName, OBJPROP_WIDTH, LINE_WIDTH);
   ObjectSetInteger(0, aboveName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, aboveName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, aboveName, OBJPROP_SELECTED, true);
   ObjectSetString(0, aboveName, OBJPROP_TEXT, aboveName);

   ObjectCreate(0, belowName, OBJ_HLINE, 0, 0, below);
   ObjectSetInteger(0, belowName, OBJPROP_COLOR, lineClr);
   ObjectSetInteger(0, belowName, OBJPROP_WIDTH, LINE_WIDTH);
   ObjectSetInteger(0, belowName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, belowName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, belowName, OBJPROP_SELECTED, true);
   ObjectSetString(0, belowName, OBJPROP_TEXT, belowName);

   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
   if(tf < PERIOD_H4)
   {
      MqlDateTime dt;
      TimeCurrent(dt);
      dt.hour = 23; dt.min = 59; dt.sec = 0;
      datetime endOfDay = StructToTime(dt);
      ObjectCreate(0, timeName, OBJ_VLINE, 0, endOfDay, 0);
      ObjectSetInteger(0, timeName, OBJPROP_COLOR, lineClr);
      ObjectSetInteger(0, timeName, OBJPROP_WIDTH, LINE_WIDTH);
      ObjectSetInteger(0, timeName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, timeName, OBJPROP_SELECTABLE, true);
      ObjectSetInteger(0, timeName, OBJPROP_SELECTED, true);
      ObjectSetString(0, timeName, OBJPROP_TEXT, timeName);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void DeleteMatrixLines(string aboveName, string belowName, string timeName)
{
   ObjectDelete(0, aboveName);
   ObjectDelete(0, belowName);
   ObjectDelete(0, timeName);
}

//+------------------------------------------------------------------+
//| Toggle Exit Matrix                                               |
//+------------------------------------------------------------------+
void ToggleExitMatrix()
{
   if(g_exitMatrixActive)
   {
      DeleteMatrixLines(g_exitAboveName, g_exitBelowName, g_exitTimeName);
      g_exitMatrixActive = false;
   }
   else
   {
      CreateMatrixLines(g_exitAboveName, g_exitBelowName, g_exitTimeName, CLR_EXIT_LINE);
      g_exitMatrixActive = true;
   }
   ObjectSetInteger(0, "RM_ExitMatrix", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_ExitMatrix"));
   Print("RiskManager: Exit Matrix ", g_exitMatrixActive ? "ON" : "OFF");
}

//+------------------------------------------------------------------+
//| Toggle Partials Matrix                                           |
//+------------------------------------------------------------------+
void TogglePartialsMatrix()
{
   if(g_partialMatrixActive)
   {
      DeleteMatrixLines(g_partAboveName, g_partBelowName, g_partTimeName);
      g_partialMatrixActive = false;
   }
   else
   {
      CreateMatrixLines(g_partAboveName, g_partBelowName, g_partTimeName, CLR_PART_LINE);
      g_partialMatrixActive = true;
   }
   ObjectSetInteger(0, "RM_PartialsMatrix", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_PartialsMatrix"));
   Print("RiskManager: Partials Matrix ", g_partialMatrixActive ? "ON" : "OFF");
}

//+------------------------------------------------------------------+
//| Check matrix triggers (generic)                                  |
//+------------------------------------------------------------------+
bool CheckMatrixTrigger(string aboveName, string belowName, string timeName)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ObjectFind(0, aboveName) >= 0)
   {
      double p = ObjectGetDouble(0, aboveName, OBJPROP_PRICE);
      if(p > 0 && bid >= p) return true;
   }
   if(ObjectFind(0, belowName) >= 0)
   {
      double p = ObjectGetDouble(0, belowName, OBJPROP_PRICE);
      if(p > 0 && ask <= p) return true;
   }
   if(ObjectFind(0, timeName) >= 0)
   {
      datetime t = (datetime)ObjectGetInteger(0, timeName, OBJPROP_TIME);
      if(t > 0 && TimeCurrent() >= t) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check exit matrix                                                |
//+------------------------------------------------------------------+
void CheckExitMatrix()
{
   if(!g_exitMatrixActive) return;
   if(CheckMatrixTrigger(g_exitAboveName, g_exitBelowName, g_exitTimeName))
   {
      Print("RiskManager: Exit Matrix triggered â€” closing all for ", _Symbol);
      CloseAllForSymbol();
      ToggleExitMatrix();
   }
}

//+------------------------------------------------------------------+
//| Check partials matrix                                            |
//+------------------------------------------------------------------+
void CheckPartialsMatrix()
{
   if(!g_partialMatrixActive) return;
   if(CheckMatrixTrigger(g_partAboveName, g_partBelowName, g_partTimeName))
   {
      Print("RiskManager: Partials Matrix triggered â€” 50%% partial for ", _Symbol);
      ClosePartial(0.50);
      TogglePartialsMatrix();
   }
}

//+------------------------------------------------------------------+
//| Toggle Breakeven Matrix                                          |
//+------------------------------------------------------------------+
void ToggleBeMtx()
{
   if(g_beMtxActive)
   {
      DeleteMatrixLines(g_beAboveName, g_beBelowName, g_beTimeName);
      g_beMtxActive = false;
   }
   else
   {
      CreateMatrixLines(g_beAboveName, g_beBelowName, g_beTimeName, CLR_ENTRY_LINE);
      g_beMtxActive = true;
   }
   ObjectSetInteger(0, "RM_BeMtx", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BeMtx"));
   Print("RiskManager: BE Matrix ", g_beMtxActive ? "ON" : "OFF");
}

//+------------------------------------------------------------------+
//| Check breakeven matrix trigger                                   |
//+------------------------------------------------------------------+
void CheckBeMtx()
{
   if(!g_beMtxActive) return;
   if(CheckMatrixTrigger(g_beAboveName, g_beBelowName, g_beTimeName))
   {
      Print("RiskManager: BE Matrix triggered â€” moving SL to breakeven for ", _Symbol);
      MoveAllSLToBreakeven();
      ToggleBeMtx();
   }
}

//+------------------------------------------------------------------+
//| Toggle cancel-orders matrix                                      |
//+------------------------------------------------------------------+
void ToggleCnclMtx()
{
   if(g_cnclMtxActive)
   {
      DeleteMatrixLines(g_cnclAboveName, g_cnclBelowName, g_cnclTimeName);
      g_cnclMtxActive = false;
   }
   else
   {
      CreateMatrixLines(g_cnclAboveName, g_cnclBelowName, g_cnclTimeName, CLR_CNCL_LINE);
      g_cnclMtxActive = true;
   }
   ObjectSetInteger(0, "RM_CnclMtx", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_CnclMtx"));
   Print("RiskManager: Cancel MTX ", g_cnclMtxActive ? "ON" : "OFF");
}

//+------------------------------------------------------------------+
//| Check cancel-orders matrix trigger                               |
//+------------------------------------------------------------------+
void CheckCnclMtx()
{
   if(!g_cnclMtxActive) return;
   if(CheckMatrixTrigger(g_cnclAboveName, g_cnclBelowName, g_cnclTimeName))
   {
      Print("RiskManager: Cancel MTX triggered – cancelling pending orders for ", _Symbol);
      CancelOrdersForSymbol();
      ToggleCnclMtx();
   }
}

//+------------------------------------------------------------------+
//| Cancel pending orders for current symbol only                    |
//+------------------------------------------------------------------+
void CancelOrdersForSymbol()
{
   if(g_hiddenOrderArmed)
   {
      CancelHiddenOrder();
      DeleteOrderLines();
      g_lastOrderBtn = "";
      ClearInfoLabel();
   }
   int cancelled = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(g_trade.OrderDelete(ticket))
         cancelled++;
      else
         Print("RM CancelOrdersForSymbol: Failed ticket=", ticket, " err=", GetLastError());
   }
   Print("RiskManager: Cancelled ", cancelled, " pending orders for ", _Symbol);
}

//+------------------------------------------------------------------+
//| Check hidden order trigger                                       |
//+------------------------------------------------------------------+
void CheckHiddenOrder()
{
   if(!g_hiddenOrderArmed || !g_linesActive) return;

   double entry = ObjectGetDouble(0, g_entryLineName, OBJPROP_PRICE);
   double sl    = ObjectGetDouble(0, g_slLineName, OBJPROP_PRICE);
   double tp    = ObjectGetDouble(0, g_tpLineName, OBJPROP_PRICE);
   if(entry == 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool   trigger = false;

   // Hidden Buy Limit:  buy when ask drops to entry  (ask <= entry)
   // Hidden Sell Limit: sell when bid rises to entry  (bid >= entry)
   // Hidden Buy Stop:   buy when ask rises to entry   (ask >= entry)
   // Hidden Sell Stop:  sell when bid drops to entry   (bid <= entry)
   if(g_orderType == 1) // limit
   {
      if(g_orderDir > 0) trigger = (ask <= entry);  // buy limit
      else                trigger = (bid >= entry);  // sell limit
   }
   else if(g_orderType == 2) // stop
   {
      if(g_orderDir > 0) trigger = (ask >= entry);  // buy stop
      else                trigger = (bid <= entry);  // sell stop
   }

   if(!trigger) return;

   double lots = CalcLotSize(MathAbs(entry - sl));
   if(lots <= 0) return;

   g_trade.SetExpertMagicNumber(0);
   g_trade.SetDeviationInPoints(5);

   int splitCount = MathMax(g_orderSplit, 1);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lotStep <= 0) lotStep = 0.01;
   double splitLots = MathFloor((lots / splitCount) / lotStep) * lotStep;
   if(splitLots < lotMin) splitLots = lotMin;
   splitLots = NormalizeDouble(splitLots, 8);

   int successCount = 0;
   for(int s = 0; s < splitCount; s++)
   {
      bool result = false;
      string comment = "";
      if(g_orderDir > 0)
         result = g_trade.Buy(splitLots, _Symbol, 0, sl, tp, comment);
      else
         result = g_trade.Sell(splitLots, _Symbol, 0, sl, tp, comment);
      if(result) successCount++;
   }

   Print("RiskManager: Hidden order triggered. ", successCount, "/", splitCount, " filled. Lots=", splitLots, " each");
   DeleteOrderLines();
   CancelHiddenOrder();
   g_lastOrderBtn = "";

   if(successCount < splitCount)
      Print("RiskManager: Hidden order partial fail. Err=", GetLastError());
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Cancel all pending orders (all symbols) + armed hidden orders    |
//+------------------------------------------------------------------+
void CancelAllOrders()
{
   if(g_hiddenOrderArmed)
   {
      CancelHiddenOrder();
      DeleteOrderLines();
      g_lastOrderBtn = "";
      ClearInfoLabel();
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      g_trade.OrderDelete(ticket);
   }
   Print("RiskManager: Cancelled all pending orders.");
}

//+------------------------------------------------------------------+
//| Scan open positions and pending orders for info bar             |
//+------------------------------------------------------------------+
void UpdatePositionInfo()
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   // --- Open positions ---
   double openLots = 0, openRisk = 0, openRew = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double lots  = PositionGetDouble(POSITION_VOLUME);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      openLots += lots;
      if(sl != 0 && tickSize > 0 && tickValue > 0)
         openRisk += (MathAbs(entry - sl) / tickSize) * tickValue * lots;
      if(tp != 0 && tickSize > 0 && tickValue > 0)
         openRew  += (MathAbs(tp - entry) / tickSize) * tickValue * lots;
   }

   if(openLots > 0)
   {
      double openRR = (openRisk > 0) ? openRew / openRisk : 0;
      ObjectSetString(0, "RM_InfoOpenLots", OBJPROP_TEXT, StringFormat("Open: %.2f", openLots));
      ObjectSetInteger(0, "RM_InfoOpenLots", OBJPROP_COLOR, CLR_INFO_TEXT);
      ObjectSetString(0, "RM_InfoOpenRew",  OBJPROP_TEXT, StringFormat("Rew: $%.0f", openRew));
      ObjectSetInteger(0, "RM_InfoOpenRew", OBJPROP_COLOR, CLR_INFO_TEXT);
      ObjectSetString(0, "RM_InfoOpenRisk", OBJPROP_TEXT, StringFormat("Risk: $%.0f", openRisk));
      ObjectSetInteger(0, "RM_InfoOpenRisk", OBJPROP_COLOR, CLR_INFO_TEXT);
      ObjectSetString(0, "RM_InfoOpenRR",   OBJPROP_TEXT, StringFormat("R:R %.1f:1", openRR));
      ObjectSetInteger(0, "RM_InfoOpenRR", OBJPROP_COLOR, CLR_INFO_TEXT);
   }
   else
   {
      ObjectSetString(0, "RM_InfoOpenLots", OBJPROP_TEXT, "Open: \x2014");
      ObjectSetInteger(0, "RM_InfoOpenLots", OBJPROP_COLOR, CLR_TEXT_DIM);
      ObjectSetString(0, "RM_InfoOpenRew",  OBJPROP_TEXT, "Rew: \x2014");
      ObjectSetInteger(0, "RM_InfoOpenRew", OBJPROP_COLOR, CLR_TEXT_DIM);
      ObjectSetString(0, "RM_InfoOpenRisk", OBJPROP_TEXT, "Risk: \x2014");
      ObjectSetInteger(0, "RM_InfoOpenRisk", OBJPROP_COLOR, CLR_TEXT_DIM);
      ObjectSetString(0, "RM_InfoOpenRR",   OBJPROP_TEXT, "R:R \x2014");
      ObjectSetInteger(0, "RM_InfoOpenRR", OBJPROP_COLOR, CLR_TEXT_DIM);
   }

   // --- Pending orders ---
   double pendLots = 0, pendRisk = 0, pendRew = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      double lots  = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double entry = OrderGetDouble(ORDER_PRICE_OPEN);
      double sl    = OrderGetDouble(ORDER_SL);
      double tp    = OrderGetDouble(ORDER_TP);
      pendLots += lots;
      if(sl != 0 && tickSize > 0 && tickValue > 0)
         pendRisk += (MathAbs(entry - sl) / tickSize) * tickValue * lots;
      if(tp != 0 && tickSize > 0 && tickValue > 0)
         pendRew  += (MathAbs(tp - entry) / tickSize) * tickValue * lots;
   }

   if(pendLots > 0)
   {
      double pendRR = (pendRisk > 0) ? pendRew / pendRisk : 0;
      ObjectSetString(0, "RM_InfoPendLots", OBJPROP_TEXT, StringFormat("Pend: %.2f", pendLots));
      ObjectSetInteger(0, "RM_InfoPendLots", OBJPROP_COLOR, CLR_INFO_TEXT);
      ObjectSetString(0, "RM_InfoPendRew",  OBJPROP_TEXT, StringFormat("Rew: $%.0f", pendRew));
      ObjectSetInteger(0, "RM_InfoPendRew", OBJPROP_COLOR, CLR_INFO_TEXT);
      ObjectSetString(0, "RM_InfoPendRisk", OBJPROP_TEXT, StringFormat("Risk: $%.0f", pendRisk));
      ObjectSetInteger(0, "RM_InfoPendRisk", OBJPROP_COLOR, CLR_INFO_TEXT);
      ObjectSetString(0, "RM_InfoPendRR",   OBJPROP_TEXT, StringFormat("R:R %.1f:1", pendRR));
      ObjectSetInteger(0, "RM_InfoPendRR", OBJPROP_COLOR, CLR_INFO_TEXT);
   }
   else
   {
      ObjectSetString(0, "RM_InfoPendLots", OBJPROP_TEXT, "Pend: \x2014");
      ObjectSetInteger(0, "RM_InfoPendLots", OBJPROP_COLOR, CLR_TEXT_DIM);
      ObjectSetString(0, "RM_InfoPendRew",  OBJPROP_TEXT, "Rew: \x2014");
      ObjectSetInteger(0, "RM_InfoPendRew", OBJPROP_COLOR, CLR_TEXT_DIM);
      ObjectSetString(0, "RM_InfoPendRisk", OBJPROP_TEXT, "Risk: \x2014");
      ObjectSetInteger(0, "RM_InfoPendRisk", OBJPROP_COLOR, CLR_TEXT_DIM);
      ObjectSetString(0, "RM_InfoPendRR",   OBJPROP_TEXT, "R:R \x2014");
      ObjectSetInteger(0, "RM_InfoPendRR", OBJPROP_COLOR, CLR_TEXT_DIM);
   }

   // --- Total open positions across ALL symbols (excluding pending) ---
   double totalLots = 0, totalRisk = 0, totalRew = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      string sym   = PositionGetString(POSITION_SYMBOL);
      double lots  = PositionGetDouble(POSITION_VOLUME);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double tSz   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double tVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      totalLots += lots;
      if(sl != 0 && tSz > 0 && tVal > 0)
         totalRisk += (MathAbs(entry - sl) / tSz) * tVal * lots;
      if(tp != 0 && tSz > 0 && tVal > 0)
         totalRew  += (MathAbs(tp - entry) / tSz) * tVal * lots;
   }

   if(totalLots > 0)
   {
      double totalRR = (totalRisk > 0) ? totalRew / totalRisk : 0;
      ObjectSetString(0, "RM_InfoTotalOpen", OBJPROP_TEXT, StringFormat("Total: %.2f", totalLots));
      ObjectSetInteger(0, "RM_InfoTotalOpen", OBJPROP_COLOR, CLR_INFO_TEXT);
      ObjectSetString(0, "RM_InfoTotalRew",  OBJPROP_TEXT, StringFormat("Rew: $%.0f", totalRew));
      ObjectSetInteger(0, "RM_InfoTotalRew", OBJPROP_COLOR, CLR_INFO_TEXT);
      ObjectSetString(0, "RM_InfoTotalRisk", OBJPROP_TEXT, StringFormat("Risk: $%.0f", totalRisk));
      ObjectSetInteger(0, "RM_InfoTotalRisk", OBJPROP_COLOR, CLR_INFO_TEXT);
      ObjectSetString(0, "RM_InfoTotalRR",   OBJPROP_TEXT, StringFormat("R:R %.1f:1", totalRR));
      ObjectSetInteger(0, "RM_InfoTotalRR", OBJPROP_COLOR, CLR_INFO_TEXT);
   }
   else
   {
      ObjectSetString(0, "RM_InfoTotalOpen", OBJPROP_TEXT, "Total: \x2014");
      ObjectSetInteger(0, "RM_InfoTotalOpen", OBJPROP_COLOR, CLR_TEXT_DIM);
      ObjectSetString(0, "RM_InfoTotalRew",  OBJPROP_TEXT, "Rew: \x2014");
      ObjectSetInteger(0, "RM_InfoTotalRew", OBJPROP_COLOR, CLR_TEXT_DIM);
      ObjectSetString(0, "RM_InfoTotalRisk", OBJPROP_TEXT, "Risk: \x2014");
      ObjectSetInteger(0, "RM_InfoTotalRisk", OBJPROP_COLOR, CLR_TEXT_DIM);
      ObjectSetString(0, "RM_InfoTotalRR",   OBJPROP_TEXT, "R:R \x2014");
      ObjectSetInteger(0, "RM_InfoTotalRR", OBJPROP_COLOR, CLR_TEXT_DIM);
   }
}

//+------------------------------------------------------------------+
double GetSymbolPnL()
{
   double pnl = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pnl;
}

//+------------------------------------------------------------------+
double GetAllPnL()
{
   double pnl = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pnl;
}

//+------------------------------------------------------------------+
//| Update live account info (called from timer)                     |
//+------------------------------------------------------------------+
void UpdateLiveInfo()
{
   UpdatePositionInfo();

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double symPnl = GetSymbolPnL();
   double allPnl = GetAllPnL();

   ObjectSetString(0, "RM_InfoEquity", OBJPROP_TEXT, StringFormat("Equity: $%.0f", equity));

   string symSign = (symPnl >= 0) ? "+" : "-";
   ObjectSetString(0, "RM_InfoPnlSym", OBJPROP_TEXT,
      StringFormat("%s: %s$%.0f", _Symbol, symSign, MathAbs(symPnl)));
   ObjectSetInteger(0, "RM_InfoPnlSym", OBJPROP_COLOR,
      (symPnl >= 0) ? C'0,200,100' : C'255,70,70');

   string allSign = (allPnl >= 0) ? "+" : "-";
   ObjectSetString(0, "RM_InfoPnlAll", OBJPROP_TEXT,
      StringFormat("All: %s$%.0f", allSign, MathAbs(allPnl)));
   ObjectSetInteger(0, "RM_InfoPnlAll", OBJPROP_COLOR,
      (allPnl >= 0) ? C'0,200,100' : C'255,70,70');

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Hover effect                                                     |
//+------------------------------------------------------------------+
void HandleHover(int mouseX, int mouseY)
{
   string hovered = "";
   for(int i = 0; i < g_btnCount; i++)
   {
      if(mouseX >= g_btnX[i] && mouseX <= g_btnX[i] + g_btnW[i] &&
         mouseY >= g_btnY[i] && mouseY <= g_btnY[i] + g_btnH[i])
      { hovered = g_btnNames[i]; break; }
   }
   if(hovered == g_lastHovered) return;
   if(g_lastHovered != "")
      ObjectSetInteger(0, g_lastHovered, OBJPROP_BGCOLOR, GetBtnNormalColor(g_lastHovered));
   if(hovered != "")
      ObjectSetInteger(0, hovered, OBJPROP_BGCOLOR, GetBtnHoverColor(hovered));
   g_lastHovered = hovered;
   ChartRedraw(0);
}

//+==================================================================+
//|                   WEB BRIDGE — STATE EXPORT                      |
//|------------------------------------------------------------------|
//| The EA is the single source of truth for all live computation.    |
//| It serialises its engine state to JSON and POSTs it to the        |
//| companion web app, which renders it without recomputing anything. |
//|                                                                   |
//| Contract: see TRADING_SYSTEM.md §8. Version-stamped via           |
//| RM_VERSION so the web app can detect a stale EA.                  |
//|                                                                   |
//| Requires the bridge URL in:                                       |
//|   Tools > Options > Expert Advisors > Allow WebRequest for URL    |
//+==================================================================+

string JBool(bool b) { return b ? "true" : "false"; }
string JNum(double v, int digits) { return DoubleToString(v, digits); }
string JTime(datetime t) { return IntegerToString((long)t); }

// One entry-pattern descriptor. `available` reuses the same gate the
// buttons use, so the web app can never disagree with the dashboard.
string JPattern(string id, string label, string type, int dir)
{
   return "{\"id\":\"" + id + "\",\"label\":\"" + label + "\",\"type\":\"" + type +
          "\",\"dir\":" + IntegerToString(dir) +
          ",\"available\":" + JBool(IsOrderBtnAvailable(id)) + "}";
}

string BuildPatternsJson()
{
   string s = "[";
   // Market
   s += JPattern("RM_BuyMkt",     "+D_MTX", "market", 1)  + ",";
   s += JPattern("RM_SellMkt",    "-D_MTX", "market", -1) + ",";
   s += JPattern("RM_BuyMktSw",   "+SWING", "market", 1)  + ",";
   s += JPattern("RM_SellMktSw",  "-SWING", "market", -1) + ",";
   s += JPattern("RM_BuyMktUFV",  "+UFV",   "market", 1)  + ",";
   s += JPattern("RM_SellMktUFV", "-UFV",   "market", -1) + ",";
   // Limit
   s += JPattern("RM_BuyLmt",     "+D_MTX", "limit", 1)  + ",";
   s += JPattern("RM_SellLmt",    "-D_MTX", "limit", -1) + ",";
   s += JPattern("RM_BuyLmtDK",   "+D_STK", "limit", 1)  + ",";
   s += JPattern("RM_SellLmtDK",  "-D_STK", "limit", -1) + ",";
   s += JPattern("RM_BuyLmtBOS",  "+BOS",   "limit", 1)  + ",";
   s += JPattern("RM_SellLmtBOS", "-BOS",   "limit", -1) + ",";
   s += JPattern("RM_BuyLmtChR",  "+CH_R",  "limit", 1)  + ",";
   s += JPattern("RM_SellLmtChR", "-CH_R",  "limit", -1) + ",";
   s += JPattern("RM_BuyLmtBoR",  "+BS_R",  "limit", 1)  + ",";
   s += JPattern("RM_SellLmtBoR", "-BS_R",  "limit", -1) + ",";
   // Stop
   s += JPattern("RM_BuyStp",     "+D_MTX", "stop", 1)  + ",";
   s += JPattern("RM_SellStp",    "-D_MTX", "stop", -1) + ",";
   s += JPattern("RM_BuyStpCH",   "+CHOCH", "stop", 1)  + ",";
   s += JPattern("RM_SellStpCH",  "-CHOCH", "stop", -1) + ",";
   s += JPattern("RM_BuyStpChC",  "+CH_C",  "stop", 1)  + ",";
   s += JPattern("RM_SellStpChC", "-CH_C",  "stop", -1) + ",";
   s += JPattern("RM_BuyStpBK",   "+BS_BO", "stop", 1)  + ",";
   s += JPattern("RM_SellStpBK",  "-BS_BO", "stop", -1) + ",";
   s += JPattern("RM_BuyStpCB",   "+CH_BO", "stop", 1)  + ",";
   s += JPattern("RM_SellStpCB",  "-CH_BO", "stop", -1);
   s += "]";
   return s;
}

//+------------------------------------------------------------------+
//| Count position ENTRIES since the start of today's daily bar.     |
//| Feeds the game plan's "max trades" cap, so it must count every    |
//| entry — chart clicks and remote arms alike, not just ours.        |
//+------------------------------------------------------------------+
int CountTradesToday(bool symbolOnly)
{
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart <= 0) return 0;
   if(!HistorySelect(dayStart, TimeCurrent() + 60)) return 0;

   int n = 0;
   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      // DEAL_ENTRY_IN = a deal that OPENED exposure. Partial closes and
      // exits are ENTRY_OUT/INOUT and must not inflate the count.
      if((int)HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      if(symbolOnly && HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol) continue;
      n++;
   }
   return n;
}

string BuildStateJson()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    dg  = (int)_Digits;

   // ── daily reference ──
   double prevRange = GetPrevDailyRange();
   double prevH = 0, prevL = 0;  bool prevBull = false;
   {
      MqlRates d[];
      ArraySetAsSeries(d, true);
      if(CopyRates(_Symbol, PERIOD_D1, 1, 1, d) >= 1)
      { prevH = d[0].high; prevL = d[0].low; prevBull = (d[0].close >= d[0].open); }
   }
   double drangePct = 0;
   if(prevRange > 0 && g_tt_swingHigh > 0 && g_tt_swingLow > 0)
      drangePct = (g_tt_swingHigh - g_tt_swingLow) / prevRange * 100.0;

   // ── open position summary (this symbol) ──
   double openLots = 0, openRisk = 0, openRew = 0;  int openCount = 0;
   double tSz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tVl = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double lot = PositionGetDouble(POSITION_VOLUME);
      double ent = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      double tp  = PositionGetDouble(POSITION_TP);
      openLots += lot;  openCount++;
      if(sl != 0 && tSz > 0 && tVl > 0) openRisk += (MathAbs(ent - sl) / tSz) * tVl * lot;
      if(tp != 0 && tSz > 0 && tVl > 0) openRew  += (MathAbs(tp - ent) / tSz) * tVl * lot;
   }

   double slDist = CalcSLDistance();

   string j = "{";
   j += "\"v\":\"" + RM_VERSION + "\",";
   j += "\"ts\":" + JTime(TimeCurrent()) + ",";
   j += "\"symbol\":\"" + _Symbol + "\",";
   j += "\"spoken\":\"" + SpokenSymbol() + "\",";
   j += "\"digits\":" + IntegerToString(dg) + ",";
   j += "\"chartTf\":" + IntegerToString((int)Period()) + ",";

   j += "\"price\":{\"bid\":" + JNum(bid,dg) + ",\"ask\":" + JNum(ask,dg) + "},";

   // ── M15 thrust engine ──
   j += "\"m15\":{";
   j += "\"trend\":"        + IntegerToString(g_tt_tTrend) + ",";
   j += "\"flow\":"         + IntegerToString(g_tt_tFlow) + ",";
   j += "\"swingHigh\":"    + JNum(g_tt_swingHigh,dg) + ",";
   j += "\"swingLow\":"     + JNum(g_tt_swingLow,dg) + ",";
   j += "\"swingHighTime\":"+ JTime(g_tt_swingHighTime) + ",";
   j += "\"swingLowTime\":" + JTime(g_tt_swingLowTime) + ",";
   j += "\"check4UpBos\":"  + JBool(g_tt_check4UpBos) + ",";
   j += "\"check4DnBos\":"  + JBool(g_tt_check4DnBos) + ",";
   j += "\"flowLevel\":"    + JNum(g_tt_flowLevel,dg) + ",";
   j += "\"vsLevel\":"      + JNum(g_tt_vsLevel,dg) + ",";
   j += "\"vsValid\":"      + JBool(g_tt_vsValid) + ",";
   j += "\"lastChochTime\":"     + JTime(g_tt_lastChochTime) + ",";
   j += "\"lastChochIsHigh\":"   + JBool(g_tt_lastChochIsHigh) + ",";
   j += "\"lastContBosTime\":"   + JTime(g_tt_lastContBosTime) + ",";
   j += "\"lastContBosIsHigh\":" + JBool(g_tt_lastContBosIsHigh) + ",";
   j += "\"lastBosSwH\":"   + JNum(g_tt_lastBosSwH,dg) + ",";
   j += "\"lastBosSwL\":"   + JNum(g_tt_lastBosSwL,dg) + ",";
   j += "\"drangePct\":"    + JNum(drangePct,1);
   j += "},";

   // ── H4 thrust engine ──
   j += "\"h4\":{";
   j += "\"trend\":"     + IntegerToString(g_h4_tTrend) + ",";
   j += "\"flow\":"      + IntegerToString(g_h4_tFlow) + ",";
   j += "\"swingHigh\":" + JNum(g_h4_swingHigh,dg) + ",";
   j += "\"swingLow\":"  + JNum(g_h4_swingLow,dg);
   j += "},";

   // ── M5 close-trend engine ──
   j += "\"m5ctrend\":{";
   j += "\"cstrend\":"     + IntegerToString(g_ctrM5.cstrend) + ",";
   j += "\"flow\":"        + IntegerToString(g_ctrM5.flow) + ",";
   j += "\"candlestate\":" + IntegerToString(g_ctrM5.candlestate) + ",";
   j += "\"dnPatternC\":"  + JNum(g_ctrM5.last_dn_pattern_c,dg) + ",";
   j += "\"upPatternC\":"  + JNum(g_ctrM5.last_up_pattern_c,dg) + ",";
   j += "\"lastFlipTime\":"+ JTime(g_ctrM5.lastFlipBarTime);
   j += "},";

   // ── daily structure ──
   j += "\"daily\":{";
   j += "\"prevHigh\":" + JNum(prevH,dg) + ",";
   j += "\"prevLow\":"  + JNum(prevL,dg) + ",";
   j += "\"prevRange\":"+ JNum(prevRange,dg) + ",";
   j += "\"prevBull\":" + JBool(prevBull);
   j += "},";

   // ── risk presets (what the next order will use) ──
   j += "\"risk\":{";
   j += "\"riskUsd\":"    + JNum(g_riskValues[g_riskIndex],2) + ",";
   j += "\"slPct\":"      + JNum(g_slPctValues[g_slPctIndex],2) + ",";
   j += "\"rr\":"         + JNum(g_rrValues[g_rrIndex],1) + ",";
   j += "\"split\":"      + IntegerToString(g_orderSplit) + ",";
   j += "\"slDistance\":" + JNum(slDist,dg) + ",";
   j += "\"lots\":"       + JNum(CalcLotSize(slDist),2);
   j += "},";

   // ── account + exposure ──
   j += "\"account\":{";
   j += "\"balance\":"  + JNum(AccountInfoDouble(ACCOUNT_BALANCE),2) + ",";
   j += "\"equity\":"   + JNum(AccountInfoDouble(ACCOUNT_EQUITY),2) + ",";
   j += "\"pnlSymbol\":"+ JNum(GetSymbolPnL(),2) + ",";
   j += "\"pnlAll\":"   + JNum(GetAllPnL(),2) + ",";
   j += "\"eqTPPct\":"  + JNum(g_eqTPPct,1) + ",";
   j += "\"eqSLPct\":"  + JNum(g_eqSLPct,1) + ",";
   j += "\"eqTPOn\":"   + JBool(g_eqTPActive) + ",";
   j += "\"eqSLOn\":"   + JBool(g_eqSLActive);
   j += "},";

   j += "\"exposure\":{";
   j += "\"openCount\":" + IntegerToString(openCount) + ",";
   j += "\"openLots\":"  + JNum(openLots,2) + ",";
   j += "\"openRisk\":"  + JNum(openRisk,2) + ",";
   j += "\"openReward\":"+ JNum(openRew,2);
   j += "},";

   // ── session counters (drive the plan's trade cap) ──
   j += "\"session\":{";
   j += "\"tradesTodaySymbol\":" + IntegerToString(CountTradesToday(true)) + ",";
   j += "\"tradesTodayAll\":"    + IntegerToString(CountTradesToday(false)) + ",";
   j += "\"remoteAllowed\":"     + JBool(InpAllowRemote);
   j += "},";

   // ── armed order (lines on chart, not yet sent) ──
   j += "\"armed\":{";
   j += "\"active\":" + JBool(g_linesActive) + ",";
   j += "\"button\":\"" + g_lastOrderBtn + "\",";
   j += "\"hidden\":" + JBool(g_hiddenOrderArmed) + ",";
   j += "\"entry\":" + JNum(g_linesActive ? ObjectGetDouble(0, g_entryLineName, OBJPROP_PRICE) : 0, dg) + ",";
   j += "\"sl\":"    + JNum(g_linesActive ? ObjectGetDouble(0, g_slLineName,    OBJPROP_PRICE) : 0, dg) + ",";
   j += "\"tp\":"    + JNum(g_linesActive ? ObjectGetDouble(0, g_tpLineName,    OBJPROP_PRICE) : 0, dg);
   j += "},";

   j += "\"patterns\":" + BuildPatternsJson();
   j += "}";
   return j;
}

//+------------------------------------------------------------------+
//| POST the state snapshot. Throttled; short timeout so a dead      |
//| endpoint can never stall the dashboard.                          |
//+------------------------------------------------------------------+
void PostState()
{
   if(InpBridgeURL == "") return;
   static datetime lastPost = 0;
   int gap = (InpStatePostSec < 1) ? 1 : InpStatePostSec;
   if(TimeCurrent() - lastPost < gap) return;
   lastPost = TimeCurrent();

   string body = BuildStateJson();
   string headers = "Content-Type: application/json\r\n";
   if(InpBridgeToken != "")
      headers += "Authorization: Bearer " + InpBridgeToken + "\r\n";
   char post[], result[];
   string resultHeaders;
   StringToCharArray(body, post, 0, StringLen(body), CP_UTF8);

   int res = WebRequest("POST", InpBridgeURL + "/api/state", headers, 1000,
                        post, result, resultHeaders);
   static bool warned = false;
   if(res != 200 && res != 204)
   {
      if(!warned)
      {
         if(res == 401)
            Print("RM bridge: 401 unauthorised \x2014 InpBridgeToken does not match the server's RM_TOKEN.");
         else
            Print("RM bridge: state POST failed HTTP ", res, " err=", GetLastError());
         warned = true;
      }
   }
   else warned = false;
}

//+==================================================================+
//|                 WEB BRIDGE — REMOTE COMMANDS                     |
//|------------------------------------------------------------------|
//| Deliberate limits on what a remote command may do:                |
//|                                                                   |
//|  * ONLY the "arm" action exists. It draws the entry/SL/TP lines.  |
//|    There is no remote "send order" — pressing Enter on the chart  |
//|    stays a deliberate physical act. The whole point of this       |
//|    system is fewer impulsive entries, not more convenient ones.   |
//|  * InpAllowRemote must be true. Off by default; a compromised or  |
//|    misconfigured server can do nothing while it is off.           |
//|  * An arm is refused unless IsOrderBtnAvailable() agrees, so a    |
//|    remote command can never bypass a pattern's own gate.          |
//|  * The server dispatches each command exactly once, and we ack    |
//|    every one, so a retry cannot double-arm.                       |
//+==================================================================+

// Minimal JSON readers. We control both ends of this channel and the
// payload shape is fixed, so a full parser would be dead weight.
string JsonGetStr(string src, string key)
{
   string pat = "\"" + key + "\":\"";
   int i = StringFind(src, pat);
   if(i < 0) return "";
   i += StringLen(pat);
   int j = StringFind(src, "\"", i);
   if(j < 0) return "";
   return StringSubstr(src, i, j - i);
}

long JsonGetInt(string src, string key)
{
   string pat = "\"" + key + "\":";
   int i = StringFind(src, pat);
   if(i < 0) return -1;
   i += StringLen(pat);
   int n = StringLen(src), j = i;
   while(j < n)
   {
      ushort c = StringGetCharacter(src, j);
      if((c < '0' || c > '9') && c != '-') break;
      j++;
   }
   if(j == i) return -1;
   return StringToInteger(StringSubstr(src, i, j - i));
}

string BridgeHeaders()
{
   string h = "Content-Type: application/json\r\n";
   if(InpBridgeToken != "") h += "Authorization: Bearer " + InpBridgeToken + "\r\n";
   return h;
}

//+------------------------------------------------------------------+
//| Arm a pattern by button id — the same handlers the chart buttons  |
//| use, so a remote arm and a click produce identical lines.         |
//+------------------------------------------------------------------+
bool ArmPatternRemote(string b, string &note)
{
   if(!IsOrderBtnAvailable(b)) { note = "gate not satisfied for " + b; return false; }

   // Clear any previously armed setup first (mirrors the click path).
   CancelHiddenOrder();
   g_chochOrderActive = false;
   g_lastOrderBtn  = b;
   g_isHiddenOrder = false;

   int d = (StringFind(b, "RM_Buy") == 0) ? +1 : -1;

   if(b == "RM_BuyMkt"     || b == "RM_SellMkt")     { HandleOrderButton(d, 0); }
   else if(b == "RM_BuyMktSw"  || b == "RM_SellMktSw")  { HandleSwingOrderButton(d, 0); }
   else if(b == "RM_BuyMktUFV" || b == "RM_SellMktUFV") { HandleUfvReversionOrderButton(d); }
   else if(b == "RM_BuyLmt"    || b == "RM_SellLmt")
        { g_isHiddenOrder = g_isHiddenLmt; HandleOrderButton(d, 1); }
   else if(b == "RM_BuyLmtDK"  || b == "RM_SellLmtDK")
        { g_isHiddenOrder = g_isHiddenLmt; HandleDstkOrderButton(d); }
   else if(b == "RM_BuyLmtBOS" || b == "RM_SellLmtBOS")
        { g_isHiddenOrder = g_isHiddenLmt; HandleBosOrderButton(d); }
   else if(b == "RM_BuyLmtChR" || b == "RM_SellLmtChR")
        { g_isHiddenOrder = g_isHiddenLmt; HandleChochRetraceOrderButton(d); }
   else if(b == "RM_BuyLmtBoR" || b == "RM_SellLmtBoR")
        { g_isHiddenOrder = g_isHiddenLmt; HandleBosRetraceFvgOrderButton(d); }
   else if(b == "RM_BuyStp"    || b == "RM_SellStp")
        { g_isHiddenOrder = g_isHiddenStp; HandleOrderButton(d, 2); }
   else if(b == "RM_BuyStpCH"  || b == "RM_SellStpCH")
        { g_isHiddenOrder = g_isHiddenStp; HandleChochOrderButton(d); }
   else if(b == "RM_BuyStpChC" || b == "RM_SellStpChC")
        { g_isHiddenOrder = g_isHiddenStp; HandleChochContinuationOrderButton(d); }
   else if(b == "RM_BuyStpBK"  || b == "RM_SellStpBK")
        { g_isHiddenOrder = g_isHiddenStp; HandleBkoOrderButton(d); }
   else if(b == "RM_BuyStpCB"  || b == "RM_SellStpCB")
        { g_isHiddenOrder = g_isHiddenStp; HandleChBoOrderButton(d); }
   else { g_lastOrderBtn = ""; note = "unknown button " + b; return false; }

   // The handlers bail out silently on missing data; g_linesActive is the
   // only honest confirmation that lines actually went on the chart.
   if(!g_linesActive) { g_lastOrderBtn = ""; note = "handler produced no lines"; return false; }

   note = "armed " + b;
   ChartRedraw(0);
   return true;
}

void AckCommand(long id, bool ok, string note)
{
   string body = "{\"id\":" + IntegerToString(id) +
                 ",\"ok\":" + (ok ? "true" : "false") +
                 ",\"result\":\"" + note + "\"}";
   char post[], result[];
   string rh;
   StringToCharArray(body, post, 0, StringLen(body), CP_UTF8);
   WebRequest("POST", InpBridgeURL + "/api/commands/ack", BridgeHeaders(), 1000,
              post, result, rh);
}

//+------------------------------------------------------------------+
//| Poll for one pending command and execute it.                     |
//+------------------------------------------------------------------+
void PollCommands()
{
   if(InpBridgeURL == "" || !InpAllowRemote) return;
   static datetime lastPoll = 0;
   int gap = (InpCmdPollSec < 1) ? 1 : InpCmdPollSec;
   if(TimeCurrent() - lastPoll < gap) return;
   lastPoll = TimeCurrent();

   char post[], result[];
   string rh;
   int res = WebRequest("GET", InpBridgeURL + "/api/commands/next", BridgeHeaders(), 1000,
                        post, result, rh);
   if(res != 200) return;

   string body = CharArrayToString(result, 0, ArraySize(result), CP_UTF8);
   if(StringFind(body, "\"command\":null") >= 0) return;   // nothing queued

   long id = JsonGetInt(body, "id");
   if(id < 0) return;

   string action = JsonGetStr(body, "action");
   string button = JsonGetStr(body, "button");
   string note   = "";
   bool   ok     = false;

   if(action == "arm") ok = ArmPatternRemote(button, note);
   else                note = "unsupported action: " + action;

   Print("RM bridge: command #", id, " ", action, " ", button, " -> ", ok ? "OK" : "REFUSED", " (", note, ")");
   AckCommand(id, ok, note);
}

//+------------------------------------------------------------------+
int OnInit()
{
   SetChartTheme();
   g_dStkMode = 1;
   BuildDashboard();
   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   EventSetMillisecondTimer(1000);

   // Restore pending order lines after timeframe change
   string gvE = "RM_SaveEntry_" + IntegerToString(ChartID());
   string gvS = "RM_SaveSL_"    + IntegerToString(ChartID());
   string gvT = "RM_SaveTP_"    + IntegerToString(ChartID());
   if(GlobalVariableCheck(gvE))
   {
      double resE = GlobalVariableGet(gvE);
      double resS = GlobalVariableGet(gvS);
      double resT = GlobalVariableGet(gvT);
      GlobalVariableDel(gvE);
      GlobalVariableDel(gvS);
      GlobalVariableDel(gvT);
      if(resE > 0 && resS > 0)
      {
         g_isMarketOrder = false;
         PlaceOrderLines(resE, resS, resT);
         // Restore hidden order armed state
         string gvH = "RM_SaveHidden_" + IntegerToString(ChartID());
         if(GlobalVariableCheck(gvH))
         {
            GlobalVariableDel(gvH);
            g_hiddenOrderArmed = true;
            g_isHiddenOrder    = true;
            ObjectSetInteger(0, g_entryLineName, OBJPROP_STYLE, STYLE_DOT);
            ObjectSetInteger(0, g_tpLineName, OBJPROP_STYLE, STYLE_DOT);
            ObjectSetInteger(0, g_slLineName, OBJPROP_STYLE, STYLE_DOT);
            ChartRedraw(0);
         }
      }
   }

   // Restore matrix lines after timeframe change
   {
      string cid = IntegerToString(ChartID());
      RestoreMatrixGV("Exit",  g_exitMatrixActive,    g_exitAboveName, g_exitBelowName, g_exitTimeName, cid);
      RestoreMatrixGV("Part",  g_partialMatrixActive, g_partAboveName, g_partBelowName, g_partTimeName, cid);
      RestoreMatrixGV("Be",    g_beMtxActive,         g_beAboveName,   g_beBelowName,   g_beTimeName,   cid);
      RestoreMatrixGV("Cncl",  g_cnclMtxActive,       g_cnclAboveName, g_cnclBelowName, g_cnclTimeName, cid);
      // Refresh matrix button colors after restore
      ObjectSetInteger(0, "RM_ExitMatrix",     OBJPROP_BGCOLOR, GetBtnNormalColor("RM_ExitMatrix"));
      ObjectSetInteger(0, "RM_PartialsMatrix", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_PartialsMatrix"));
      ObjectSetInteger(0, "RM_BeMtx",          OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BeMtx"));
      ObjectSetInteger(0, "RM_CnclMtx",        OBJPROP_BGCOLOR, GetBtnNormalColor("RM_CnclMtx"));
   }

   // Restore equity TP/SL after timeframe change
   {
      string cid = IntegerToString(ChartID());
      string gvTPPct = "RM_EqTPPct_" + cid;
      if(GlobalVariableCheck(gvTPPct))
      {
         g_eqTPPct    = GlobalVariableGet("RM_EqTPPct_" + cid);
         g_eqSLPct    = GlobalVariableGet("RM_EqSLPct_" + cid);
         g_eqTPActive = GlobalVariableGet("RM_EqTPActive_" + cid) > 0.5;
         g_eqSLActive = GlobalVariableGet("RM_EqSLActive_" + cid) > 0.5;
         g_eqBaseline = GlobalVariableGet("RM_EqBaseline_" + cid);
         GlobalVariableDel("RM_EqTPPct_" + cid);
         GlobalVariableDel("RM_EqSLPct_" + cid);
         GlobalVariableDel("RM_EqTPActive_" + cid);
         GlobalVariableDel("RM_EqSLActive_" + cid);
         GlobalVariableDel("RM_EqBaseline_" + cid);
         RefreshEqLabels();
      }
   }

   // Activate all chart tools on startup
   g_orActive = true;        PlotOR();
   g_sessHLActive = true;    PlotSessionHL();
   g_dailyBoxActive = true;  PlotDailyBoxes();
   g_weeklyBoxActive = true; PlotWeeklyBoxes();
   g_weeklyORActive = true;  PlotWeeklyOR();
   g_dailyMtxActive = true;  PlotDailyMtx();
   g_weeklyMtxActive = true; PlotWeeklyMtx();
   g_daily150Active = true;   PlotDaily150();
   g_sessGapActive = true;    PlotSessionGap();
   g_sessBrkActive = true;    PlotSessionBreaker();
   g_dailyLvlActive = true;   PlotDailyLevels();
   PlotDailyStalk();
   g_dmxLabelActive = true;  PlotDmxLabel();
   g_tt_thrustActive = true;  g_tt_bosActive = true;  g_tt_chochActive = true;
   g_tt_flowActive = true;  // FLW on by default
   g_tt_fvMode = 1;  // FV light on by default
   g_alertSBRK = true;  g_alertCHCH = true;  g_alertDSTK = true;  g_alertD150 = true;  // alerts on by default
   ComputeThrust();  PlotTTThrust();  PlotTTFairValue();  PlotTTFlow();
   if(g_tt_drangeActive) PlotTTDRange();
   ComputeH4Thrust();  if(g_h4_active) PlotH4Thrust();  if(g_h4_flowActive) PlotH4Flow();
   RefreshTrendButtons();
   ComputeAlertDLVLLevels();
   UpdatePositionInfo();
   ObjectSetInteger(0, "RM_BtnOR",  OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnOR"));
   ObjectSetInteger(0, "RM_BtnSHL", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSHL"));
   ObjectSetInteger(0, "RM_BtnDBX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDBX"));
   ObjectSetInteger(0, "RM_BtnWBX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnWBX"));
   ObjectSetInteger(0, "RM_BtnWOR", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnWOR"));
   ObjectSetInteger(0, "RM_BtnDMX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDMX"));
   ObjectSetInteger(0, "RM_BtnWMX", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnWMX"));
   ObjectSetInteger(0, "RM_BtnD150",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnD150"));
   ObjectSetInteger(0, "RM_BtnSGAP",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSGAP"));
   ObjectSetInteger(0, "RM_BtnSBRK",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnSBRK"));
   ObjectSetInteger(0, "RM_BtnDLVL",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDLVL"));
   ObjectSetInteger(0, "RM_BtnDSTK",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnDSTK"));
   ObjectSetInteger(0, "RM_BtnMLVL",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnMLVL"));
   ObjectSetInteger(0, "RM_BtnTHRS",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnTHRS"));
   ObjectSetInteger(0, "RM_BtnH4TH",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnH4TH"));
   ObjectSetInteger(0, "RM_BtnH4FC",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnH4FC"));
   ObjectSetInteger(0, "RM_BtnBOS", OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnBOS"));
   ObjectSetInteger(0, "RM_BtnCHCH",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnCHCH"));
   ObjectSetInteger(0, "RM_BtnFVAL",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnFVAL"));
   ObjectSetString(0, "RM_BtnFVAL", OBJPROP_TEXT, "FV\x25CB");
   ObjectSetInteger(0, "RM_BtnFLOW",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnFLOW"));
   ObjectSetInteger(0, "RM_BtnAltSBRK",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltSBRK"));
   ObjectSetInteger(0, "RM_BtnAltCHCH",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltCHCH"));
   ObjectSetInteger(0, "RM_BtnAltDSTK",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltDSTK"));
   ObjectSetInteger(0, "RM_BtnAltD150",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltD150"));
   ObjectSetInteger(0, "RM_BtnAltH4FC",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAltH4FC"));
   ObjectSetInteger(0, "RM_BtnTrailH1",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnTrailH1"));
   ObjectSetInteger(0, "RM_BtnTrailH4",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnTrailH4"));
   ObjectSetInteger(0, "RM_BtnHTrail",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnHTrail"));
   ObjectSetInteger(0, "RM_BtnAutoTrail",OBJPROP_BGCOLOR, GetBtnNormalColor("RM_BtnAutoTrail"));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Save/Restore matrix line prices to GlobalVariables               |
//+------------------------------------------------------------------+
void SaveMatrixGV(string tag, bool isActive, string aboveName, string belowName, string timeName, string cid)
{
   if(!isActive) return;
   double a = ObjectGetDouble(0, aboveName, OBJPROP_PRICE);
   double b = ObjectGetDouble(0, belowName, OBJPROP_PRICE);
   if(a <= 0 && b <= 0) return;
   GlobalVariableSet("RM_Mtx" + tag + "A_" + cid, a);
   GlobalVariableSet("RM_Mtx" + tag + "B_" + cid, b);
   // Save time line if it exists
   if(ObjectFind(0, timeName) >= 0)
      GlobalVariableSet("RM_Mtx" + tag + "T_" + cid, (double)ObjectGetInteger(0, timeName, OBJPROP_TIME));
   GlobalVariableSet("RM_Mtx" + tag + "F_" + cid, 1.0);  // flag = active
}

void RestoreMatrixGV(string tag, bool &isActive, string aboveName, string belowName, string timeName, string cid)
{
   string gvF = "RM_Mtx" + tag + "F_" + cid;
   if(!GlobalVariableCheck(gvF)) return;
   string gvA = "RM_Mtx" + tag + "A_" + cid;
   string gvB = "RM_Mtx" + tag + "B_" + cid;
   string gvT = "RM_Mtx" + tag + "T_" + cid;
   double a = GlobalVariableGet(gvA);
   double b = GlobalVariableGet(gvB);
   GlobalVariableDel(gvF);
   GlobalVariableDel(gvA);
   GlobalVariableDel(gvB);
   // Determine line color from the object names
   color lineClr = clrGray;
   if(StringFind(aboveName, "Exit") >= 0) lineClr = CLR_EXIT_LINE;
   else if(StringFind(aboveName, "Part") >= 0) lineClr = CLR_PART_LINE;
   else if(StringFind(aboveName, "Be") >= 0)   lineClr = CLR_ENTRY_LINE;
   else if(StringFind(aboveName, "Cncl") >= 0) lineClr = CLR_CNCL_LINE;
   if(a > 0)
   {
      ObjectCreate(0, aboveName, OBJ_HLINE, 0, 0, a);
      ObjectSetInteger(0, aboveName, OBJPROP_COLOR, lineClr);
      ObjectSetInteger(0, aboveName, OBJPROP_WIDTH, LINE_WIDTH);
      ObjectSetInteger(0, aboveName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, aboveName, OBJPROP_SELECTABLE, true);
      ObjectSetInteger(0, aboveName, OBJPROP_SELECTED, true);
   }
   if(b > 0)
   {
      ObjectCreate(0, belowName, OBJ_HLINE, 0, 0, b);
      ObjectSetInteger(0, belowName, OBJPROP_COLOR, lineClr);
      ObjectSetInteger(0, belowName, OBJPROP_WIDTH, LINE_WIDTH);
      ObjectSetInteger(0, belowName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, belowName, OBJPROP_SELECTABLE, true);
      ObjectSetInteger(0, belowName, OBJPROP_SELECTED, true);
   }
   if(GlobalVariableCheck(gvT))
   {
      datetime tm = (datetime)(long)GlobalVariableGet(gvT);
      GlobalVariableDel(gvT);
      ObjectCreate(0, timeName, OBJ_VLINE, 0, tm, 0);
      ObjectSetInteger(0, timeName, OBJPROP_COLOR, lineClr);
      ObjectSetInteger(0, timeName, OBJPROP_WIDTH, LINE_WIDTH);
      ObjectSetInteger(0, timeName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, timeName, OBJPROP_SELECTABLE, true);
      ObjectSetInteger(0, timeName, OBJPROP_SELECTED, true);
   }
   isActive = true;
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   // Preserve pending order lines across timeframe changes
   if(reason == REASON_CHARTCHANGE && g_linesActive)
   {
      double e = ObjectGetDouble(0, g_entryLineName, OBJPROP_PRICE);
      double s = ObjectGetDouble(0, g_slLineName, OBJPROP_PRICE);
      double t = ObjectGetDouble(0, g_tpLineName, OBJPROP_PRICE);
      if(e > 0 && s > 0)
      {
         GlobalVariableSet("RM_SaveEntry_" + IntegerToString(ChartID()), e);
         GlobalVariableSet("RM_SaveSL_"    + IntegerToString(ChartID()), s);
         GlobalVariableSet("RM_SaveTP_"    + IntegerToString(ChartID()), t);
         if(g_hiddenOrderArmed)
            GlobalVariableSet("RM_SaveHidden_" + IntegerToString(ChartID()), 1.0);
      }
   }
   // Preserve matrix lines across timeframe changes
   if(reason == REASON_CHARTCHANGE)
   {
      string cid = IntegerToString(ChartID());
      SaveMatrixGV("Exit",  g_exitMatrixActive,    g_exitAboveName, g_exitBelowName, g_exitTimeName, cid);
      SaveMatrixGV("Part",  g_partialMatrixActive, g_partAboveName, g_partBelowName, g_partTimeName, cid);
      SaveMatrixGV("Be",    g_beMtxActive,         g_beAboveName,   g_beBelowName,   g_beTimeName,   cid);
      SaveMatrixGV("Cncl",  g_cnclMtxActive,       g_cnclAboveName, g_cnclBelowName, g_cnclTimeName, cid);
      // Preserve equity TP/SL across timeframe changes
      if(g_eqTPPct > 0 || g_eqSLPct > 0 || g_eqTPActive || g_eqSLActive)
      {
         GlobalVariableSet("RM_EqTPPct_"    + cid, g_eqTPPct);
         GlobalVariableSet("RM_EqSLPct_"    + cid, g_eqSLPct);
         GlobalVariableSet("RM_EqTPActive_" + cid, g_eqTPActive ? 1.0 : 0.0);
         GlobalVariableSet("RM_EqSLActive_" + cid, g_eqSLActive ? 1.0 : 0.0);
         GlobalVariableSet("RM_EqBaseline_" + cid, g_eqBaseline);
      }
   }
   ObjectsDeleteAll(0, "RM_");
   DeleteOrderLines();
   DeleteMatrixLines(g_exitAboveName, g_exitBelowName, g_exitTimeName);
   DeleteMatrixLines(g_partAboveName, g_partBelowName, g_partTimeName);
   DeleteMatrixLines(g_beAboveName, g_beBelowName, g_beTimeName);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_MOUSE_MOVE)
   { HandleHover((int)lparam, (int)dparam); return; }

   if(id == CHARTEVENT_KEYDOWN && lparam == 13 && !g_customRiskEditing && !g_splitEditing)
   {
      if(g_setSLActive) { ApplySetSL(); return; }
      if(g_setTPActive) { ApplySetTP(); return; }
      ExecuteTrade(); return;
   }

   if(id == CHARTEVENT_KEYDOWN && lparam == 88 && !g_customRiskEditing && !g_splitEditing)
   { ToggleDashboardVisibility(); return; }

   // Split keyboard input (1-9) — only active in edit mode
   if(id == CHARTEVENT_KEYDOWN && g_splitEditing)
   {
      int key = (int)lparam;
      int digit = -1;
      if(key >= 49 && key <= 57)   digit = key - 48;   // 1-9
      if(key >= 97 && key <= 105)  digit = key - 96;   // numpad 1-9
      if(digit >= 1)
      {
         g_orderSplit    = digit;
         g_splitEditing  = false;
         g_splitText     = "";
         ObjectSetString(0, "RM_BtnSplit", OBJPROP_TEXT, "x" + IntegerToString(g_orderSplit));
         ObjectSetInteger(0, "RM_BtnSplit", OBJPROP_BGCOLOR, CLR_BTN_ON);
         ChartRedraw(0); return;
      }
      if(key == 27) // Escape — cancel
      {
         g_splitEditing = false;
         g_splitText    = "";
         string sTxt = (g_orderSplit > 1) ? ("x" + IntegerToString(g_orderSplit)) : "SPLIT";
         ObjectSetString(0, "RM_BtnSplit", OBJPROP_TEXT, sTxt);
         ObjectSetInteger(0, "RM_BtnSplit", OBJPROP_BGCOLOR, (g_orderSplit > 1) ? CLR_BTN_ON : CLR_BTN_OFF);
         ChartRedraw(0); return;
      }
      return;  // Consume all other keys while editing split
   }

   // Custom risk keyboard input (0-9, backspace) — only active in edit mode
   if(id == CHARTEVENT_KEYDOWN && g_customRiskEditing)
   {
      int key = (int)lparam;
      // Digit keys: 0-9 (48-57) or numpad 0-9 (96-105)
      int digit = -1;
      if(key >= 48 && key <= 57)   digit = key - 48;
      if(key >= 96 && key <= 105)  digit = key - 96;
      if(digit >= 0)
      {
         if(StringLen(g_customRiskText) < 7)  // max 7 digits
            g_customRiskText += IntegerToString(digit);
         ObjectSetString(0, RiskBtnName(3), OBJPROP_TEXT, "$" + g_customRiskText + "_");
         ChartRedraw(0); return;
      }
      // Backspace (8)
      if(key == 8)
      {
         int len = StringLen(g_customRiskText);
         if(len > 0)
            g_customRiskText = StringSubstr(g_customRiskText, 0, len - 1);
         if(StringLen(g_customRiskText) > 0)
            ObjectSetString(0, RiskBtnName(3), OBJPROP_TEXT, "$" + g_customRiskText + "_");
         else
            ObjectSetString(0, RiskBtnName(3), OBJPROP_TEXT, "$_");
         ChartRedraw(0); return;
      }
      // Escape (27) â€" cancel edit mode
      if(key == 27)
      {
         g_customRiskEditing = false;
         g_customRiskText    = "";
         ObjectSetString(0, RiskBtnName(3), OBJPROP_TEXT, "CUSTOM");
         ObjectSetInteger(0, RiskBtnName(3), OBJPROP_BGCOLOR, CLR_BTN_OFF);
         ChartRedraw(0); return;
      }
      // Enter (13) â€" confirm from keyboard too
      if(key == 13)
      {
         double amt = StringToDouble(g_customRiskText);
         if(amt > 0)
         {
            g_riskValues[3]     = amt;
            g_riskIndex         = 3;
            g_customRiskEditing = false;
            ObjectSetString(0, RiskBtnName(3), OBJPROP_TEXT, "$" + g_customRiskText);
            SetToggleGroup("RM_Risk_", 4, g_riskIndex, CLR_BTN_ON, CLR_BTN_OFF);
            if(g_linesActive) ReRenderLinesFromSettings();
         }
         else
         {
            g_customRiskEditing = false;
            g_customRiskText    = "";
            ObjectSetString(0, RiskBtnName(3), OBJPROP_TEXT, "CUSTOM");
            ObjectSetInteger(0, RiskBtnName(3), OBJPROP_BGCOLOR, CLR_BTN_OFF);
         }
         ChartRedraw(0); return;
      }
      return;  // Consume all other keys while editing
   }

   // Smart TP hotkeys: Ctrl+Shift+Up/Down=SL, Ctrl+Up/Down=green, Shift+Up/Down=beige (today only)
   if(id == CHARTEVENT_KEYDOWN && (lparam == 38 || lparam == 40) && g_smartTPMode > 0)
   {
      bool ctrl  = (TerminalInfoInteger(TERMINAL_KEYSTATE_CONTROL) < 0);
      bool shift = (TerminalInfoInteger(TERMINAL_KEYSTATE_SHIFT)   < 0);

      if(ctrl || shift)
      {
         double step = GetPrevDailyRange() * 0.01;  // 1% of prev daily range
         if(step <= 0) step = _Point * 100;
         if(lparam == 40) step = -step;  // Down arrow = negative

         string target = "";
         if(ctrl && shift) target = "RM_SmTP_SL_0";      // Ctrl+Shift = SL
         else if(ctrl)     target = "RM_SmTP_Level_0";   // Ctrl = green
         else if(shift)    target = "RM_SmTP_Entry_0";   // Shift = beige

         if(ObjectFind(0, target) >= 0)
         {
            double price0 = ObjectGetDouble(0, target, OBJPROP_PRICE, 0);
            double price1 = ObjectGetDouble(0, target, OBJPROP_PRICE, 1);
            ObjectSetDouble(0, target, OBJPROP_PRICE, 0, price0 + step);
            ObjectSetDouble(0, target, OBJPROP_PRICE, 1, price1 + step);
            UpdateSmartTrendline(target);
            ChartRedraw(0);
         }
         return;
      }
   }

   // Shift+Ctrl+/ : swap green and beige line positions (today only)
   if(id == CHARTEVENT_KEYDOWN && lparam == 191 && g_smartTPMode > 0)
   {
      bool ctrl  = (TerminalInfoInteger(TERMINAL_KEYSTATE_CONTROL) < 0);
      bool shift = (TerminalInfoInteger(TERMINAL_KEYSTATE_SHIFT)   < 0);
      if(ctrl && shift)
      {
         string hName = "RM_SmTP_Level_0";
         string eName = "RM_SmTP_Entry_0";
         if(ObjectFind(0, hName) >= 0 && ObjectFind(0, eName) >= 0)
         {
            double greenPrice = ObjectGetDouble(0, hName, OBJPROP_PRICE, 0);
            double beigePrice = ObjectGetDouble(0, eName, OBJPROP_PRICE, 0);
            // Swap
            ObjectSetDouble(0, hName, OBJPROP_PRICE, 0, beigePrice);
            ObjectSetDouble(0, hName, OBJPROP_PRICE, 1, beigePrice);
            ObjectSetDouble(0, eName, OBJPROP_PRICE, 0, greenPrice);
            ObjectSetDouble(0, eName, OBJPROP_PRICE, 1, greenPrice);
            UpdateSmartTrendline(hName);
            ChartRedraw(0);
         }
         return;
      }
   }

   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      // â”€â”€ Toggle groups â”€â”€
      for(int i = 0; i < 3; i++)
      {
         if(sparam == RiskBtnName(i))
         {
            g_riskIndex = i;
            // Reset custom risk editing if active
            g_customRiskEditing = false;
            g_customRiskText    = "";
            ObjectSetString(0, RiskBtnName(3), OBJPROP_TEXT, "CUSTOM");
            SetToggleGroup("RM_Risk_", 4, g_riskIndex, CLR_BTN_ON, CLR_BTN_OFF);
            if(g_linesActive) ReRenderLinesFromSettings();
            ChartRedraw(0); return;
         }
         if(sparam == SlPctBtnName(i))
         {
            g_slPctIndex = i;
            g_slManualOverride = false;
            SetToggleGroup("RM_SlPct_", 4, g_slPctIndex, CLR_BTN_ON, CLR_BTN_OFF);
            if(g_linesActive) ReRenderLinesFromSettings();
            ChartRedraw(0); return;
         }
         if(sparam == RRBtnName(i))
         {
            g_rrIndex = i;
            SetToggleGroup("RM_RR_", 3, g_rrIndex, CLR_BTN_ON, CLR_BTN_OFF);
            if(g_linesActive) ReRenderLinesFromSettings();
            ChartRedraw(0); return;
         }
      }

      // 4th SL Range button (100%)
      if(sparam == SlPctBtnName(3))
      {
         g_slPctIndex = 3;
         g_slManualOverride = false;
         SetToggleGroup("RM_SlPct_", 4, g_slPctIndex, CLR_BTN_ON, CLR_BTN_OFF);
         if(g_linesActive) ReRenderLinesFromSettings();
         ChartRedraw(0); return;
      }

      // Custom risk button
      if(sparam == RiskBtnName(3))
      {
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(!g_customRiskEditing)
         {
            g_customRiskEditing = true;
            g_customRiskText    = "";
            ObjectSetString(0, RiskBtnName(3), OBJPROP_TEXT, "$_");
            ObjectSetInteger(0, RiskBtnName(3), OBJPROP_BGCOLOR, C'80,80,30');
            ChartRedraw(0); return;
         }
         else
         {
            double amt = StringToDouble(g_customRiskText);
            if(amt > 0)
            {
               g_riskValues[3]     = amt;
               g_riskIndex         = 3;
               g_customRiskEditing = false;
               ObjectSetString(0, RiskBtnName(3), OBJPROP_TEXT, "$" + g_customRiskText);
               SetToggleGroup("RM_Risk_", 4, g_riskIndex, CLR_BTN_ON, CLR_BTN_OFF);
               if(g_linesActive) ReRenderLinesFromSettings();
            }
            else
            {
               g_customRiskEditing = false;
               g_customRiskText    = "";
               ObjectSetString(0, RiskBtnName(3), OBJPROP_TEXT, "CUSTOM");
               ObjectSetInteger(0, RiskBtnName(3), OBJPROP_BGCOLOR, CLR_BTN_OFF);
            }
            ChartRedraw(0); return;
         }
      }
      // Split button
      if(sparam == "RM_BtnSplit")
      {
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(!g_splitEditing)
         {
            g_splitEditing = true;
            g_splitText    = "";
            ObjectSetString(0, "RM_BtnSplit", OBJPROP_TEXT, "SPLIT ?_");
            ObjectSetInteger(0, "RM_BtnSplit", OBJPROP_BGCOLOR, C'80,80,30');
            ChartRedraw(0); return;
         }
         else
         {
            g_splitEditing = false;
            g_splitText    = "";
            string sTxt = (g_orderSplit > 1) ? ("x" + IntegerToString(g_orderSplit)) : "SPLIT";
            ObjectSetString(0, "RM_BtnSplit", OBJPROP_TEXT, sTxt);
            ObjectSetInteger(0, "RM_BtnSplit", OBJPROP_BGCOLOR, (g_orderSplit > 1) ? CLR_BTN_ON : CLR_BTN_OFF);
            ChartRedraw(0); return;
         }
      }
      // â”€â”€ Order buttons (with toggle-off) â”€â”€
      // Market SLRANGE
      if(sparam == "RM_BuyMkt")  { HandleOrderBtnClick(sparam, +1, 0, false); return; }
      if(sparam == "RM_SellMkt") { HandleOrderBtnClick(sparam, -1, 0, false); return; }
      // Market SWING (trend-gated)
      if(sparam == "RM_BuyMktSw")
      {
         if(g_tt_tTrend != 1) { ObjectSetInteger(0,sparam,OBJPROP_STATE,false); return; }
         HandleOrderBtnClick(sparam, +1, 0, false, true); return;
      }
      if(sparam == "RM_SellMktSw")
      {
         if(g_tt_tTrend != 2) { ObjectSetInteger(0,sparam,OBJPROP_STATE,false); return; }
         HandleOrderBtnClick(sparam, -1, 0, false, true); return;
      }
      // Limit SLRANGE
      if(sparam == "RM_BuyLmt")  { HandleOrderBtnClick(sparam, +1, 1, g_isHiddenLmt); return; }
      if(sparam == "RM_SellLmt") { HandleOrderBtnClick(sparam, -1, 1, g_isHiddenLmt); return; }
      // Limit DSTK
      if(sparam == "RM_SellLmtDK")
      {
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
            g_lastOrderBtn = ""; ClearInfoLabel(); return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenLmt;
         HandleDstkOrderButton(-1);
         return;
      }
      if(sparam == "RM_BuyLmtDK")
      {
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
            g_lastOrderBtn = ""; ClearInfoLabel(); return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenLmt;
         HandleDstkOrderButton(+1);
         return;
      }
      // R_FV buttons removed; col-2 limit slots are now placeholders.
      // Limit BOS (BOS retracement, trend-gated, 3-way toggle)
      if(sparam == "RM_SellLmtBOS")
      {
         if(g_tt_tTrend != 2) { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            // Already active: cycle mode
            g_bosLmtMode++;
            if(g_bosLmtMode > 1)
            {
               g_bosLmtMode = 0;
               DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
               g_lastOrderBtn = ""; ClearInfoLabel();
               ObjectSetString(0, "RM_SellLmtBOS", OBJPROP_TEXT, "-BOS");
               return;
            }
            DeleteOrderLines();
            ObjectSetString(0, "RM_SellLmtBOS", OBJPROP_TEXT, "-BOS\x25CF");
            HandleBosOrderButton(-1);
            return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenLmt;
         g_bosLmtMode = 0;
         ObjectSetString(0, "RM_SellLmtBOS", OBJPROP_TEXT, "-BOS");
         HandleBosOrderButton(-1);
         return;
      }
      if(sparam == "RM_BuyLmtBOS")
      {
         if(g_tt_tTrend != 1) { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            g_bosLmtMode++;
            if(g_bosLmtMode > 1)
            {
               g_bosLmtMode = 0;
               DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
               g_lastOrderBtn = ""; ClearInfoLabel();
               ObjectSetString(0, "RM_BuyLmtBOS", OBJPROP_TEXT, "+BOS");
               return;
            }
            DeleteOrderLines();
            ObjectSetString(0, "RM_BuyLmtBOS", OBJPROP_TEXT, "+BOS\x25CF");
            HandleBosOrderButton(+1);
            return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenLmt;
         g_bosLmtMode = 0;
         ObjectSetString(0, "RM_BuyLmtBOS", OBJPROP_TEXT, "+BOS");
         HandleBosOrderButton(+1);
         return;
      }
      // Stop SLRANGE
      if(sparam == "RM_BuyStp")  { HandleOrderBtnClick(sparam, +1, 2, g_isHiddenStp); return; }
      if(sparam == "RM_SellStp") { HandleOrderBtnClick(sparam, -1, 2, g_isHiddenStp); return; }
      // Stop CHOCH (trend-gated, 3-way toggle: SL-range → swing SL → off)
      if(sparam == "RM_BuyStpCH")
      {
         if(g_tt_tTrend != 2) { ObjectSetInteger(0,sparam,OBJPROP_STATE,false); return; }
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            g_chochMode++;
            if(g_chochMode > 1)
            {
               g_chochMode = 0;
               DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
               g_lastOrderBtn = ""; ClearInfoLabel();
               ObjectSetString(0, "RM_BuyStpCH", OBJPROP_TEXT, "+CHOCH");
               return;
            }
            DeleteOrderLines();
            ObjectSetString(0, "RM_BuyStpCH", OBJPROP_TEXT, "+CH\x25CF");
            HandleChochOrderButton(+1);
            return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenStp;
         g_chochMode = 0;
         ObjectSetString(0, "RM_BuyStpCH", OBJPROP_TEXT, "+CHOCH");
         HandleChochOrderButton(+1);
         return;
      }
      if(sparam == "RM_SellStpCH")
      {
         if(g_tt_tTrend != 1) { ObjectSetInteger(0,sparam,OBJPROP_STATE,false); return; }
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            g_chochMode++;
            if(g_chochMode > 1)
            {
               g_chochMode = 0;
               DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
               g_lastOrderBtn = ""; ClearInfoLabel();
               ObjectSetString(0, "RM_SellStpCH", OBJPROP_TEXT, "-CHOCH");
               return;
            }
            DeleteOrderLines();
            ObjectSetString(0, "RM_SellStpCH", OBJPROP_TEXT, "-CH\x25CF");
            HandleChochOrderButton(-1);
            return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenStp;
         g_chochMode = 0;
         ObjectSetString(0, "RM_SellStpCH", OBJPROP_TEXT, "-CHOCH");
         HandleChochOrderButton(-1);
         return;
      }
      // Stop BS_BO (Breakout, with-the-trend continuation)
      if(sparam == "RM_BuyStpBK")
      {
         if(g_tt_tTrend != 1) { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
            g_lastOrderBtn = ""; ClearInfoLabel(); return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenStp;
         HandleBkoOrderButton(+1);
         return;
      }
      if(sparam == "RM_SellStpBK")
      {
         if(g_tt_tTrend != 2) { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
            g_lastOrderBtn = ""; ClearInfoLabel(); return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenStp;
         HandleBkoOrderButton(-1);
         return;
      }
      // Stop CH_BO (Breakout, anti-trend reversal — entry where break = CHOCH)
      if(sparam == "RM_BuyStpCB")
      {
         if(g_tt_tTrend != 2) { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
            g_lastOrderBtn = ""; ClearInfoLabel(); return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenStp;
         HandleChBoOrderButton(+1);
         return;
      }
      if(sparam == "RM_SellStpCB")
      {
         if(g_tt_tTrend != 1) { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
            g_lastOrderBtn = ""; ClearInfoLabel(); return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenStp;
         HandleChBoOrderButton(-1);
         return;
      }
      // Advanced-button availability gate: if grayed out, ignore the click.
      if(sparam == "RM_BuyLmtChR"  || sparam == "RM_SellLmtChR" ||
         sparam == "RM_BuyLmtBoR"  || sparam == "RM_SellLmtBoR" ||
         sparam == "RM_BuyStpChC"  || sparam == "RM_SellStpChC" ||
         sparam == "RM_BuyMktUFV"  || sparam == "RM_SellMktUFV")
      {
         if(!IsOrderBtnAvailable(sparam))
         { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      }
      // ── New bet functions (CHOCH retrace, BOS retrace FVG, CHOCH continuation, UFV) ──
      if(sparam == "RM_BuyLmtChR" || sparam == "RM_SellLmtChR")
      {
         int d = (sparam == "RM_BuyLmtChR") ? +1 : -1;
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
            g_lastOrderBtn = ""; ClearInfoLabel(); return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenLmt;
         HandleChochRetraceOrderButton(d);
         return;
      }
      if(sparam == "RM_BuyLmtBoR" || sparam == "RM_SellLmtBoR")
      {
         int d = (sparam == "RM_BuyLmtBoR") ? +1 : -1;
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
            g_lastOrderBtn = ""; ClearInfoLabel(); return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenLmt;
         HandleBosRetraceFvgOrderButton(d);
         return;
      }
      if(sparam == "RM_BuyStpChC" || sparam == "RM_SellStpChC")
      {
         int d = (sparam == "RM_BuyStpChC") ? +1 : -1;
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
            g_lastOrderBtn = ""; ClearInfoLabel(); return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = g_isHiddenStp;
         HandleChochContinuationOrderButton(d);
         return;
      }
      if(sparam == "RM_BuyMktUFV" || sparam == "RM_SellMktUFV")
      {
         int d = (sparam == "RM_BuyMktUFV") ? +1 : -1;
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         if(g_linesActive && g_lastOrderBtn == sparam)
         {
            DeleteOrderLines(); CancelHiddenOrder(); g_chochOrderActive = false;
            g_lastOrderBtn = ""; ClearInfoLabel(); return;
         }
         CancelHiddenOrder(); g_chochOrderActive = false;
         g_lastOrderBtn = sparam;
         g_isHiddenOrder = false;
         HandleUfvReversionOrderButton(d);
         return;
      }
      // Hidden mode toggle
      if(sparam == "RM_HiddenLmt")
      {
         g_isHiddenLmt = !g_isHiddenLmt;
         ObjectSetInteger(0, "RM_HiddenLmt", OBJPROP_BGCOLOR,
                          g_isHiddenLmt ? CLR_BTN_HIDDEN_ON : CLR_BTN_HIDDEN);
         ObjectSetInteger(0, "RM_HiddenLmt", OBJPROP_COLOR,
                          g_isHiddenLmt ? clrBlack : CLR_TEXT);
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         return;
      }
      if(sparam == "RM_HiddenStp")
      {
         g_isHiddenStp = !g_isHiddenStp;
         ObjectSetInteger(0, "RM_HiddenStp", OBJPROP_BGCOLOR,
                          g_isHiddenStp ? CLR_BTN_HIDDEN_ON : CLR_BTN_HIDDEN);
         ObjectSetInteger(0, "RM_HiddenStp", OBJPROP_COLOR,
                          g_isHiddenStp ? clrBlack : CLR_TEXT);
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         return;
      }
      // Placeholder buttons - do nothing
      if(StringFind(sparam, "RM_Plc") == 0 || StringFind(sparam, "RM_RP_") == 0
         || StringFind(sparam, "RM_TP_") == 0
      || StringFind(sparam, "RM_AP_") == 0)
      { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }

      // â”€â”€ Right panel tools â”€â”€
      if(sparam == "RM_BtnHide") { ToggleDashboardVisibility(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnOR")  { ToggleOR(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnSHL") { ToggleSessionHL(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnDBX") { ToggleDailyBoxes(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnWBX") { ToggleWeeklyBoxes(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnWOR") { ToggleWeeklyOR(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnDMX") { ToggleDailyMtx(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnWMX") { ToggleWeeklyMtx(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnD150"){ ToggleDaily150(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnSGAP"){ ToggleSessionGap(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnSBRK"){ ToggleSessionBreaker(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnDLVL"){ ToggleDailyLevels(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnDSTK"){ ToggleDailyStalk(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnMLVL"){ ToggleDmxLabel(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnSMX") { ToggleSmx(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnH4MX"){ ToggleH4Mtx(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }

      // â”€â”€ Test panel (Thrust) â”€â”€
      if(sparam == "RM_BtnTREND"){ ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnPIVT"){ ToggleTTPivots(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnTHRS"){ ToggleTTThrust(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnBOS") { ToggleTTBos();    ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnCHCH"){ ToggleTTChoch();  ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnFLOW"){ ToggleTTFlow();   ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnSWNG"){ ToggleTTSwing();  ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnVSTR"){ ToggleTTVs();     ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnFVAL"){ ToggleTTFairValue(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnFVGP"){ ToggleTTFairValueGap(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnBOSC"){ ToggleTTBosCount(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnSRET"){ ToggleTTSRet();    ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnDRNG"){ ToggleTTDRange();  ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnH4TH"){ ToggleH4Thrust();  ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnH4FC"){ ToggleH4Flow();    ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }

      // â”€â”€ Alerts panel â”€â”€
      if(sparam == "RM_BtnAltTEST"){ RunAlertTest(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnAltSBRK"){ ToggleAlertSBRK(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnAltCHCH"){ ToggleAlertCHCH(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnAltDSTK"){ ToggleAlertDSTK(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnAltD150"){ ToggleAlertD150(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnAltH4FC"){ ToggleAlertH4FC(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnAltCTR"){ ToggleAlertCTR(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }

      // â”€â”€ Tools â”€â”€
      if(sparam == "RM_Partial30")  { ClosePartial(0.30); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_Partial50")  { ClosePartial(0.50); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_Partial70")  { ClosePartial(0.70); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_CloseSym")   { CloseSymWithSLNudge(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_CloseAll")   { CloseAllPositions(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_CancelAll")  { CancelAllOrders(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_ExitMatrix") { ToggleExitMatrix(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_PartialsMatrix") { TogglePartialsMatrix(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_MoveBE")  { MoveAllSLToBreakeven(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BeMtx")   { ToggleBeMtx(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_CnclMtx") { ToggleCnclMtx(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnTrailH1") { ToggleTrailH1(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnTrailH4") { ToggleTrailH4(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnHTrail")  { ToggleHiddenTrail(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_BtnAutoTrail") { ToggleAutoTrail(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_AddLot")  { ExecuteAddLot(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_SetSL")   { ToggleSetSL(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_SetTP")   { ToggleSetTP(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_SmartTP") { ToggleSmartTP(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }

      // â”€â”€ Equity TP/SL +/- â”€â”€
      // SL: - lowers equity (increase %), + raises equity (decrease %)
      if(sparam == "RM_EqSLM01"){ AdjustEqSL(+0.1);  ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_EqSLP01") { AdjustEqSL(-0.1);  ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_EqSLM10"){ AdjustEqSL(+1.0);  ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_EqSLP10") { AdjustEqSL(-1.0);  ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      // TP: - decreases %, + increases %
      if(sparam == "RM_EqTPP01") { AdjustEqTP(+0.1);  ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_EqTPM01"){ AdjustEqTP(-0.1);  ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_EqTPP10") { AdjustEqTP(+1.0);  ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_EqTPM10"){ AdjustEqTP(-1.0);  ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_EqTPLbl") { ToggleEqTP(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
      if(sparam == "RM_EqSLLbl") { ToggleEqSL(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); return; }
   }

   if(id == CHARTEVENT_OBJECT_DRAG)
   {
      if(sparam == g_slLineName)
         g_slManualOverride = true;
      if(sparam == g_entryLineName || sparam == g_slLineName || sparam == g_tpLineName)
         RecalcFromLines();
      // Update Smart TP when any Level, Entry, or SL line is dragged
      if((StringFind(sparam, "RM_SmTP_Level_") == 0 || StringFind(sparam, "RM_SmTP_Entry_") == 0 || StringFind(sparam, "RM_SmTP_SL_") == 0) && g_smartTPMode > 0)
         UpdateSmartTrendline(sparam);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckHiddenOrder();
   CheckExitMatrix();
   CheckPartialsMatrix();
   CheckBeMtx();
   CheckCnclMtx();
   CheckEquityTPSL();
   CheckSBRKAlert();
   CheckCHCHAlert();
   CheckDSTKAlert();
   CheckD150Alert();
   UpdateDmxLevelTick();
   UpdateSmxTick();
   UpdateH4MtxTick();
   // UpdateAutoOrder();  // [deprecated] superseded by 3-sec-throttled RerunArmedOrder
   RerunArmedOrder();    // 3-sec intra-bar throttle so all armed orders track price
   CheckHiddenTrail();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   UpdateLiveInfo();
   UpdateOR();
   CheckSessionEnd();
   UpdateDailyBoxes();
   UpdateWeeklyBoxes();
   UpdateWeeklyOR();
   UpdateDailyMtx();
   UpdateWeeklyMtx();
   UpdateDaily150();
   UpdateSessionGap();
   UpdateSessionBreaker();
   UpdateDailyLevels();
   UpdateDailyStalk();
   UpdateDmxLabel();
   UpdateSmxLabel();
   UpdateH4MtxLabel();
   UpdateThrust();
   UpdateH4Thrust();
   UpdateTrailH1();
   UpdateTrailH4();
   UpdateAutoTrail();
   UpdateHiddenTrail();
   UpdateAlertLevels();
   UpdateChochOrder();
   CheckSmartTPScore();
   CheckCTrendAlert();
   PostState();          // web bridge: throttled state snapshot
   PollCommands();       // web bridge: remote ARM commands (opt-in)
}
