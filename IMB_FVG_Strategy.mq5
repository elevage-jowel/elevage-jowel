//+------------------------------------------------------------------+
//|                                          IMB_FVG_Strategy.mq5   |
//|              Stratégie IMB (FVG) M5 avec structure H1            |
//|              Développé par Elevage Jowel                         |
//+------------------------------------------------------------------+
#property copyright "Elevage Jowel"
#property link      ""
#property version   "1.00"
#property description "Bot IMB/FVG M5 filtré par structure de marché H1"

#include <Trade\Trade.mqh>

//==========================================================================
//  PARAMÈTRES D'ENTRÉE
//==========================================================================
input group              "── Risque ──"
input double             InpRiskPercent  = 0.5;     // Risque par trade (% du capital)

input group              "── Heures de Trading ──"
input int                InpStartHour    = 7;        // Heure de début (inclus)
input int                InpEndHour      = 18;       // Heure de fin (exclus)

input group              "── Structure de Marché H1 ──"
input int                InpH1SwingN     = 5;        // Barres de confirmation swing H1 (chaque côté)

input group              "── FVG / IMB M5 ──"
input int                InpM5Lookback   = 100;      // Nombre de barres lookback pour détecter un FVG M5
input int                InpM5SwingN     = 3;        // Barres de confirmation swing M5 (pour le TP)

input group              "── Général ──"
input long               InpMagic        = 202406;   // Magic Number
input double             InpSlBufferPts  = 5.0;      // Buffer SL au-delà du FVG (en points)

//==========================================================================
//  TYPES ET STRUCTURES
//==========================================================================
enum ENUM_MARKET_DIR
{
    DIR_NONE    = 0,
    DIR_BULLISH = 1,
    DIR_BEARISH = 2
};

// Zone FVG / IMB active
struct SFVG
{
    double          top;         // Borne haute de la zone IMB
    double          bottom;      // Borne basse de la zone IMB
    datetime        fvgTime;     // Temps d'ouverture de la bougie A du pattern
    datetime        h1BarTime;   // H1 ouverte au moment de la détection (pour invalidation)
    ENUM_MARKET_DIR direction;   // Sens du FVG
    bool            active;      // Zone en cours d'observation
    bool            touched;     // Le prix a-t-il pénétré dans la zone ?
};

// Bougie M1 de référence
struct SM1Ref
{
    double   high;
    double   low;
    datetime time;
    bool     active;
};

//==========================================================================
//  VARIABLES GLOBALES
//==========================================================================
CTrade          g_trade;
ENUM_MARKET_DIR g_dir        = DIR_NONE;
SFVG            g_fvg;
SM1Ref          g_ref;
datetime        g_h1LastBar  = 0;   // Dernière barre H1 traitée
datetime        g_m5LastBar  = 0;   // Dernière barre M5 traitée
datetime        g_m1LastBar  = 0;   // Dernière barre M1 traitée

//==========================================================================
//  INITIALISATION / NETTOYAGE
//==========================================================================
int OnInit()
{
    g_trade.SetExpertMagicNumber(InpMagic);
    g_trade.SetDeviationInPoints(20);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);

    ResetAll();

    Print("[IMB EA] Démarré │ Magic=", InpMagic,
          " │ Risque=", InpRiskPercent, "%",
          " │ Session=", InpStartHour, "h-", InpEndHour, "h");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    Print("[IMB EA] Arrêt (code ", reason, ")");
}

//==========================================================================
//  BOUCLE PRINCIPALE
//==========================================================================
void OnTick()
{
    // ── Filtre horaire ──────────────────────────────────────────────────
    if (!InTradingHours()) return;

    bool posOpen = PositionIsOpen();

    // ── Mise à jour structure H1 (sur chaque nouvelle bougie H1) ────────
    UpdateH1Structure();

    // ── Si la direction H1 a changé, invalider tout setup en cours ──────
    if (g_fvg.active && g_fvg.direction != g_dir)
    {
        Print("[IMB EA] Direction H1 modifiée → réinitialisation du FVG actif.");
        ResetAll();
    }

    if (!posOpen)
    {
        // Rechercher un FVG si aucun n'est actif
        if (!g_fvg.active)
            DetectM5FVG();

        if (g_fvg.active)
        {
            // Vérifier l'expiration (bougie H1 suivante fermée sans contact)
            if (!g_fvg.touched)
                CheckFVGExpiry();

            // Vérifier si le prix entre dans la zone
            if (g_fvg.active && !g_fvg.touched)
                CheckFVGTouch();

            // Chercher la bougie M1 de référence (sur nouvelle bougie M1)
            if (g_fvg.active && g_fvg.touched && !g_ref.active)
                DetectM1Ref();

            // Vérifier la condition d'entrée (chaque tick)
            if (g_fvg.active && g_fvg.touched && g_ref.active)
                CheckEntry();
        }
    }
}

//==========================================================================
//  UTILITAIRES GÉNÉRAUX
//==========================================================================
bool InTradingHours()
{
    MqlDateTime t;
    TimeToStruct(TimeCurrent(), t);
    return (t.hour >= InpStartHour && t.hour < InpEndHour);
}

bool PositionIsOpen()
{
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if (ticket > 0 &&
            PositionGetString(POSITION_SYMBOL)  == _Symbol &&
            PositionGetInteger(POSITION_MAGIC)  == InpMagic)
            return true;
    }
    return false;
}

void ResetAll()
{
    ZeroMemory(g_fvg);
    ZeroMemory(g_ref);
    g_fvg.active  = false;
    g_fvg.touched = false;
    g_ref.active  = false;
}

//==========================================================================
//  DÉTECTION DES PIVOTS (SWING HIGH / SWING LOW)
//==========================================================================
// Tableau sérialisé (index 0 = le plus récent)
bool SwingHigh(const double &a[], int idx, int n)
{
    int sz = ArraySize(a);
    if (idx - n < 0 || idx + n >= sz) return false;
    for (int j = 1; j <= n; j++)
        if (a[idx - j] >= a[idx] || a[idx + j] >= a[idx]) return false;
    return true;
}

bool SwingLow(const double &a[], int idx, int n)
{
    int sz = ArraySize(a);
    if (idx - n < 0 || idx + n >= sz) return false;
    for (int j = 1; j <= n; j++)
        if (a[idx - j] <= a[idx] || a[idx + j] <= a[idx]) return false;
    return true;
}

//==========================================================================
//  STRUCTURE DE MARCHÉ H1
//  HH + HL = DIR_BULLISH  │  LH + LL = DIR_BEARISH  │  sinon DIR_NONE
//==========================================================================
void UpdateH1Structure()
{
    datetime t[];
    ArraySetAsSeries(t, true);
    if (CopyTime(_Symbol, PERIOD_H1, 0, 1, t) < 1) return;
    if (t[0] == g_h1LastBar) return;          // Pas de nouvelle bougie H1
    g_h1LastBar = t[0];

    // On a besoin d'assez de barres pour trouver 2 swing highs ET 2 swing lows
    int need = InpH1SwingN * 4 + 10;
    double hi[], lo[];
    ArraySetAsSeries(hi, true);
    ArraySetAsSeries(lo, true);

    if (CopyHigh(_Symbol, PERIOD_H1, 1, need, hi) < need) return;
    if (CopyLow (_Symbol, PERIOD_H1, 1, need, lo) < need) return;

    double SH[2], SL[2];
    int    shN = 0, slN = 0;
    int    sz  = ArraySize(hi);

    for (int i = InpH1SwingN; i < sz - InpH1SwingN && (shN < 2 || slN < 2); i++)
    {
        if (shN < 2 && SwingHigh(hi, i, InpH1SwingN)) SH[shN++] = hi[i];
        if (slN < 2 && SwingLow (lo, i, InpH1SwingN)) SL[slN++] = lo[i];
    }

    if (shN < 2 || slN < 2) { g_dir = DIR_NONE; return; }

    // SH[0] / SL[0] = pivot le plus récent ; SH[1] / SL[1] = précédent
    bool hh = (SH[0] > SH[1]);
    bool hl = (SL[0] > SL[1]);
    bool lh = (SH[0] < SH[1]);
    bool ll = (SL[0] < SL[1]);

    ENUM_MARKET_DIR prev = g_dir;
    if      (hh && hl) g_dir = DIR_BULLISH;
    else if (lh && ll) g_dir = DIR_BEARISH;
    else               g_dir = DIR_NONE;

    if (g_dir != prev)
        Print("[H1] Structure → ", EnumToString(g_dir),
              " │ SH:", SH[0], "/", SH[1], " │ SL:", SL[0], "/", SL[1]);
}

//==========================================================================
//  DÉTECTION DU FVG / IMB M5
//
//  Pattern 3 bougies (A=oldest, B=milieu, C=newest, arrays sérialisés) :
//    Baissier : lo[i+2] > hi[i]  → zone IMB = [hi[i] .. lo[i+2]]
//    Haussier : hi[i+2] < lo[i]  → zone IMB = [hi[i+2] .. lo[i]]
//
//  Contrainte de position :
//    Baissier : zone au-DESSUS du prix actuel (attente du retour haussier)
//    Haussier : zone en-DESSOUS du prix actuel (attente du retour baissier)
//==========================================================================
void DetectM5FVG()
{
    if (g_dir == DIR_NONE) return;

    datetime t[];
    ArraySetAsSeries(t, true);
    if (CopyTime(_Symbol, PERIOD_M5, 0, 1, t) < 1) return;
    if (t[0] == g_m5LastBar) return;          // Pas de nouvelle bougie M5
    g_m5LastBar = t[0];

    int n = InpM5Lookback;
    double hi[], lo[];
    datetime bt[];
    ArraySetAsSeries(hi, true);
    ArraySetAsSeries(lo, true);
    ArraySetAsSeries(bt, true);

    if (CopyHigh(_Symbol, PERIOD_M5, 1, n, hi) < n) return;
    if (CopyLow (_Symbol, PERIOD_M5, 1, n, lo) < n) return;
    if (CopyTime(_Symbol, PERIOD_M5, 1, n, bt) < n) return;

    // Heure de la bougie H1 courante (pour invalidation future)
    datetime h1t[];
    ArraySetAsSeries(h1t, true);
    if (CopyTime(_Symbol, PERIOD_H1, 0, 1, h1t) < 1) return;

    double curBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // Parcours du plus récent vers l'ancien ; on prend le 1er FVG valide trouvé
    for (int i = 0; i <= n - 3; i++)
    {
        if (g_dir == DIR_BEARISH)
        {
            // FVG baissier : bas[A] > haut[C]
            if (lo[i + 2] > hi[i])
            {
                double zBot = hi[i];       // Borne basse = haut de C
                double zTop = lo[i + 2];   // Borne haute = bas de A

                // Zone doit être AU-DESSUS du prix (retour haussier attendu)
                if (zBot > curBid)
                {
                    g_fvg.bottom    = zBot;
                    g_fvg.top       = zTop;
                    g_fvg.fvgTime   = bt[i + 2];
                    g_fvg.h1BarTime = h1t[0];
                    g_fvg.direction = DIR_BEARISH;
                    g_fvg.active    = true;
                    g_fvg.touched   = false;
                    Print("[M5] FVG BAISSIER │ Bot:", zBot, " Top:", zTop,
                          " @ ", TimeToString(bt[i + 2], TIME_DATE | TIME_MINUTES));
                    return;
                }
            }
        }
        else if (g_dir == DIR_BULLISH)
        {
            // FVG haussier : haut[A] < bas[C]
            if (hi[i + 2] < lo[i])
            {
                double zBot = hi[i + 2];   // Borne basse = haut de A
                double zTop = lo[i];       // Borne haute = bas de C

                // Zone doit être EN-DESSOUS du prix (retour baissier attendu)
                if (zTop < curBid)
                {
                    g_fvg.bottom    = zBot;
                    g_fvg.top       = zTop;
                    g_fvg.fvgTime   = bt[i + 2];
                    g_fvg.h1BarTime = h1t[0];
                    g_fvg.direction = DIR_BULLISH;
                    g_fvg.active    = true;
                    g_fvg.touched   = false;
                    Print("[M5] FVG HAUSSIER │ Bot:", zBot, " Top:", zTop,
                          " @ ", TimeToString(bt[i + 2], TIME_DATE | TIME_MINUTES));
                    return;
                }
            }
        }
    }
}

//==========================================================================
//  INVALIDATION DU FVG
//  Si le prix n'a pas touché la zone avant la fermeture de la bougie H1
//  SUIVANTE → la zone est annulée.
//==========================================================================
void CheckFVGExpiry()
{
    // CopyTime(shift=1) renvoie la DERNIÈRE BOUGIE H1 FERMÉE
    datetime h1t[];
    ArraySetAsSeries(h1t, true);
    if (CopyTime(_Symbol, PERIOD_H1, 1, 1, h1t) < 1) return;

    // h1t[0] > g_fvg.h1BarTime signifie que la bougie H1 "suivante"
    // (après celle de la détection) est désormais fermée → invalidation
    if (h1t[0] > g_fvg.h1BarTime)
    {
        Print("[FVG] Expiré (bougie H1 suivante fermée sans contact). Réinit.");
        ResetAll();
    }
}

//==========================================================================
//  CONTACT PRIX / ZONE FVG
//  Le prix entre dans la zone IMB → g_fvg.touched = true
//==========================================================================
void CheckFVGTouch()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if (g_fvg.direction == DIR_BEARISH && ask >= g_fvg.bottom)
    {
        g_fvg.touched = true;
        Print("[FVG] Zone BAISSIÈRE touchée │ Ask:", ask, " ≥ Bot:", g_fvg.bottom);
    }
    else if (g_fvg.direction == DIR_BULLISH && bid <= g_fvg.top)
    {
        g_fvg.touched = true;
        Print("[FVG] Zone HAUSSIÈRE touchée │ Bid:", bid, " ≤ Top:", g_fvg.top);
    }
}

//==========================================================================
//  BOUGIE M1 DE RÉFÉRENCE
//  = première bougie M1 FERMÉE qui pénètre dans la zone IMB,
//    après que la zone ait été touchée.
//==========================================================================
void DetectM1Ref()
{
    // Exécuter une seule fois par bougie M1
    datetime t[];
    ArraySetAsSeries(t, true);
    if (CopyTime(_Symbol, PERIOD_M1, 0, 1, t) < 1) return;
    if (t[0] == g_m1LastBar) return;
    g_m1LastBar = t[0];

    // Bougie M1 juste fermée (shift = 1)
    double hi1[], lo1[];
    datetime bt1[];
    ArraySetAsSeries(hi1, true);
    ArraySetAsSeries(lo1, true);
    ArraySetAsSeries(bt1, true);

    if (CopyHigh(_Symbol, PERIOD_M1, 1, 1, hi1) < 1) return;
    if (CopyLow (_Symbol, PERIOD_M1, 1, 1, lo1) < 1) return;
    if (CopyTime(_Symbol, PERIOD_M1, 1, 1, bt1) < 1) return;

    // Ignorer les bougies antérieures à la formation du FVG
    if (bt1[0] < g_fvg.fvgTime) return;

    bool penetrates = false;
    if (g_fvg.direction == DIR_BEARISH)
        // Le haut de la bougie M1 entre dans la zone (remontée vers l'IMB baissier)
        penetrates = (hi1[0] > g_fvg.bottom && lo1[0] < g_fvg.top);
    else
        // Le bas de la bougie M1 entre dans la zone (descente vers l'IMB haussier)
        penetrates = (lo1[0] < g_fvg.top && hi1[0] > g_fvg.bottom);

    if (penetrates)
    {
        g_ref.high   = hi1[0];
        g_ref.low    = lo1[0];
        g_ref.time   = bt1[0];
        g_ref.active = true;
        Print("[M1 Ref] High:", g_ref.high, " Low:", g_ref.low,
              " @ ", TimeToString(g_ref.time, TIME_DATE | TIME_MINUTES));
    }
}

//==========================================================================
//  CONDITION D'ENTRÉE
//
//  FVG BAISSIER  → SELL quand BID casse AU-DESSUS du High de la bougie M1 ref
//    SL : au-dessus du Top du FVG M5 + buffer
//    TP : dernier swing low M5 en dessous du prix d'entrée
//
//  FVG HAUSSIER  → BUY  quand ASK casse EN-DESSOUS du Low de la bougie M1 ref
//    SL : en dessous du Bottom du FVG M5 - buffer
//    TP : dernier swing high M5 au-dessus du prix d'entrée
//==========================================================================
void CheckEntry()
{
    double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double pt     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double buf    = InpSlBufferPts * pt;

    //── SELL ────────────────────────────────────────────────────────────
    if (g_fvg.direction == DIR_BEARISH && bid > g_ref.high)
    {
        double sl = NormalizeDouble(g_fvg.top + buf, digits);
        double tp = NormalizeDouble(LastM5SwingLow(bid), digits);

        if (tp <= 0)
        {
            Print("[Entry] SELL annulé : pas de swing low M5 sous le prix.");
            return;
        }
        if (tp >= bid)
        {
            Print("[Entry] SELL annulé : TP (", tp, ") ≥ prix entrée (", bid, ").");
            return;
        }
        if (sl <= bid)
        {
            Print("[Entry] SELL annulé : SL (", sl, ") ≤ prix entrée (", bid, ").");
            return;
        }

        double lots = CalcLots(bid, sl);
        if (lots <= 0) { Print("[Entry] SELL annulé : taille de lot invalide."); return; }

        Print("[Entry] Tentative SELL │ Bid:", bid, " SL:", sl, " TP:", tp, " Lots:", lots);

        if (g_trade.Sell(lots, _Symbol, bid, sl, tp, "IMB-SELL"))
        {
            Print("[Entry] SELL ouvert avec succès ✓");
            ResetAll();
        }
        else
            Print("[Entry] Erreur SELL: ", GetLastError(),
                  " │ ", g_trade.ResultRetcodeDescription());
        return;
    }

    //── BUY ─────────────────────────────────────────────────────────────
    if (g_fvg.direction == DIR_BULLISH && ask < g_ref.low)
    {
        double sl = NormalizeDouble(g_fvg.bottom - buf, digits);
        double tp = NormalizeDouble(LastM5SwingHigh(ask), digits);

        if (tp <= 0)
        {
            Print("[Entry] BUY annulé : pas de swing high M5 au-dessus du prix.");
            return;
        }
        if (tp <= ask)
        {
            Print("[Entry] BUY annulé : TP (", tp, ") ≤ prix entrée (", ask, ").");
            return;
        }
        if (sl >= ask)
        {
            Print("[Entry] BUY annulé : SL (", sl, ") ≥ prix entrée (", ask, ").");
            return;
        }

        double lots = CalcLots(ask, sl);
        if (lots <= 0) { Print("[Entry] BUY annulé : taille de lot invalide."); return; }

        Print("[Entry] Tentative BUY │ Ask:", ask, " SL:", sl, " TP:", tp, " Lots:", lots);

        if (g_trade.Buy(lots, _Symbol, ask, sl, tp, "IMB-BUY"))
        {
            Print("[Entry] BUY ouvert avec succès ✓");
            ResetAll();
        }
        else
            Print("[Entry] Erreur BUY: ", GetLastError(),
                  " │ ", g_trade.ResultRetcodeDescription());
    }
}

//==========================================================================
//  RECHERCHE DU DERNIER SWING LOW M5 SOUS LE PRIX DE RÉFÉRENCE
//  Retourne 0 si non trouvé.
//==========================================================================
double LastM5SwingLow(double refPrice)
{
    int n = InpM5Lookback;
    double lo[];
    ArraySetAsSeries(lo, true);
    if (CopyLow(_Symbol, PERIOD_M5, 1, n, lo) < n) return 0;

    for (int i = InpM5SwingN; i < n - InpM5SwingN; i++)
    {
        if (SwingLow(lo, i, InpM5SwingN) && lo[i] < refPrice)
            return lo[i];
    }
    return 0;
}

//==========================================================================
//  RECHERCHE DU DERNIER SWING HIGH M5 AU-DESSUS DU PRIX DE RÉFÉRENCE
//  Retourne 0 si non trouvé.
//==========================================================================
double LastM5SwingHigh(double refPrice)
{
    int n = InpM5Lookback;
    double hi[];
    ArraySetAsSeries(hi, true);
    if (CopyHigh(_Symbol, PERIOD_M5, 1, n, hi) < n) return 0;

    for (int i = InpM5SwingN; i < n - InpM5SwingN; i++)
    {
        if (SwingHigh(hi, i, InpM5SwingN) && hi[i] > refPrice)
            return hi[i];
    }
    return 0;
}

//==========================================================================
//  CALCUL DE LA TAILLE DE LOT (risque fixe % du capital)
//
//  lots = (Balance × Risk%) / (Distance SL en ticks × Valeur du tick)
//==========================================================================
double CalcLots(double entryPrice, double sl)
{
    double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
    double risk     = balance * InpRiskPercent / 100.0;

    double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double slDist   = MathAbs(entryPrice - sl);

    if (slDist < _Point || tickVal <= 0.0 || tickSz <= 0.0)
    {
        Print("[Lots] Paramètres invalides : slDist=", slDist,
              " tickVal=", tickVal, " tickSz=", tickSz);
        return 0;
    }

    double slTicks = slDist / tickSz;
    double lots    = risk / (slTicks * tickVal);

    double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lots = MathFloor(lots / step) * step;
    lots = MathMax(minL, MathMin(maxL, lots));

    Print("[Lots] Balance:", balance, " Risque:", risk,
          " SL dist:", slDist, " → Lots:", lots);
    return lots;
}

//+------------------------------------------------------------------+
