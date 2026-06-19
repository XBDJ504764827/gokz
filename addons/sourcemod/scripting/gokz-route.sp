/*
	gokz-route
	---------------------------------------------
	Displays the world-record (fastest) replay route as a beam trail in the map,
	so players can see the optimal line the WR holder took.

	Source of the WR replay: by default downloads it from Cloudflare R2
	(the fastest replay uploaded by gokz-r2upload: wr/<mode>/<map>/<tp|pro>.replay).
	Can also read the local WR cache written by gokz-r2upload (source = local) as a
	robust fallback.

	Terminology:
	  - tp  = save/checkpoint mode (teleports used)
	  - pro = no-skip "bare jump" mode (no checkpoints)
	  - the number after tp/pro is the RANK (0 = 1st place / fastest, 1 = 2nd place)
	  - only the main course (course 0) is tracked; there is no course in the path
	  - this plugin always shows the FASTEST (single tp.replay / pro.replay)

	Flow:
	  player runs sm_route [tp|pro]
	    -> build WR replay URL / local path for (mode, type)
	    -> download (R2) or read (local) the .replay
	    -> parse binary -> list of per-tick origins
	    -> downsample by min distance
	    -> draw beams between consecutive points, refreshed periodically,
	       visible only to the requesting player

	Replay binary parsing reuses the constants/structs from <gokz/replays>
	(RP_MAGIC_NUMBER, RP_V2_TICK_DATA_BLOCKSIZE, RPDELTA_*) and mirrors the logic
	in gokz-replays/playback.sp (LoadFormatVersion2Replay).
	Beam drawing uses TE_SetupBeamPoints + materials/sprites/laserbeam.vmt,
	identical to gokz-jumpbeam.

	Dependencies: SteamWorks extension (for R2 download), gokz-core, gokz-replays (includes).

	ConVars (auto-generated at cfg/sourcemod/gokz/gokz-route.cfg):
	  gokz_route_enabled     "1"   master switch
	  gokz_route_source      "r2"  source: "r2" (download) or "local" (read gokz-r2upload cache)
	  gokz_route_source_url  ""    R2 public read base URL, e.g. https://pub-xxxx.r2.dev (no trailing slash)
	  gokz_route_color       "0 255 0 255"  beam color "R G B A"
	  gokz_route_refresh     "1.0" redraw interval in seconds
	  gokz_route_lifetime    "1.2" beam lifetime in seconds
	  gokz_route_width       "2.0" beam width
	  gokz_route_mindist     "32"  downsample min distance between kept points (units)
	  gokz_route_maxseg      "500" hard cap on drawn segments
	  gokz_route_verify_cert "0"   verify HTTPS cert when downloading
	  gokz_route_view_dist   "1500" only draw segments within this distance (units) of the player
	  gokz_route_highlight   "1"   highlight the segment closest to the player
	  gokz_route_highlight_color "255 255 0 255" highlight color
	  gokz_route_highlight_count "5" segments to highlight around the player's position
*/

#include <sourcemod>
#include <SteamWorks>
#include <autoexecconfig>
#include <clientprefs>
#include <gokz>
#include <gokz/core>
#include <gokz/replays>

#pragma newdecls required
#pragma semicolon 1



public Plugin myinfo =
{
	name = "GOKZ Route (WR Path Display)",
	author = "XBDJ50476482",
	description = "Draws the world-record replay route as a beam trail",
	version = "1.1.0",
	url = ""
};



// =====[ CONSTANTS ]=====

#define ROUTE_TEMP_DIR    "data/gokz-route/downloads"
#define LOCAL_CACHE_DIR   "data/gokz-r2upload/wrcache"   // owned by gokz-r2upload; files: <map>/0_<mode>_<type>.replay
#define LOCAL_COURSE      0                       // gokz-r2upload caches main course as "0_..."
#define ROUTE_INF         9999999.0               // stand-in for infinity when finding the closest segment
#define ROUTE_CATEGORY    "寻路菜单"              // top-level !o category (native GOKZ way, like Paint)



// =====[ CVARS ]=====

ConVar gCV_Enabled;
ConVar gCV_Source;       // "r2" or "local"
ConVar gCV_SourceURL;    // R2 public read base URL
ConVar gCV_Color;
ConVar gCV_Refresh;
ConVar gCV_Lifetime;
ConVar gCV_Width;
ConVar gCV_MinDist;
ConVar gCV_MaxSeg;
ConVar gCV_VerifyCert;
ConVar gCV_ViewDist;
ConVar gCV_HighlightColor;
ConVar gCV_HighlightCount;

int gI_BeamModel = 0;
char gC_Map[64];

Handle gH_RefreshTimer = null;

// Per-client active route state (only mode + type matter; rank is always 0)
bool   gB_Active[MAXPLAYERS + 1];
int    gI_Mode[MAXPLAYERS + 1];
int    gI_Type[MAXPLAYERS + 1];     // TimeType_Nub (tp) / TimeType_Pro (pro)

// Per-client display preferences (persisted via clientprefs).
// TP and PRO are mutually exclusive (at most one active). Full = green line, Next = yellow highlight.
bool   gB_ShowTP[MAXPLAYERS + 1];
bool   gB_ShowPRO[MAXPLAYERS + 1];
bool   gB_ShowFull[MAXPLAYERS + 1];
bool   gB_ShowNext[MAXPLAYERS + 1];
Cookie gC_ShowTP;
Cookie gC_ShowPRO;
Cookie gC_ShowFull;
Cookie gC_ShowNext;

// !o (options) menu integration
TopMenu       gTM_Options;
TopMenuObject gTMO_Category;
TopMenuObject gTMO_Toggle[4];   // 0=TP, 1=PRO, 2=Full, 3=Next

// Cache: parsed route origins per (mode, type) for the current map.
// Key "mode_type" -> ArrayList(blocksize 3) of float[3] origins (plugin-owned).
StringMap gH_Cache;
StringMap gH_Pending;   // in-flight downloads keyed by "userid_mode_type"



// =====[ PLUGIN LIFECYCLE ]=====

public void OnPluginStart()
{
	CreateConVars();

	gC_ShowTP   = RegClientCookie("gokz_route_show_tp",   "Route menu: show TP (save) route", CookieAccess_Private);
	gC_ShowPRO  = RegClientCookie("gokz_route_show_pro",  "Route menu: show PRO (no-skip) route", CookieAccess_Private);
	gC_ShowFull = RegClientCookie("gokz_route_show_full", "Route menu: show full route line", CookieAccess_Private);
	gC_ShowNext = RegClientCookie("gokz_route_show_next", "Route menu: show next-step highlight", CookieAccess_Private);

	gH_Cache = new StringMap();
	gH_Pending = new StringMap();

	// Late load: preferences for players already online when the plugin (re)loads.
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && AreClientCookiesCached(i))
		{
			LoadClientPrefs(i);
		}
	}
}

static void CreateConVars()
{
	AutoExecConfig_SetFile("gokz-route", "sourcemod/gokz");
	AutoExecConfig_SetCreateFile(true);

	gCV_Enabled     = AutoExecConfig_CreateConVar("gokz_route_enabled",     "1",   "Master switch for the route display.", _, true, 0.0, true, 1.0);
	gCV_Source      = AutoExecConfig_CreateConVar("gokz_route_source",      "r2",  "WR replay source: \"r2\" (download from R2) or \"local\" (read gokz-r2upload cache).");
	gCV_SourceURL   = AutoExecConfig_CreateConVar("gokz_route_source_url",  "",    "R2 public read base URL (no trailing slash), e.g. https://pub-xxxx.r2.dev. Used when source=r2.");
	gCV_Color       = AutoExecConfig_CreateConVar("gokz_route_color",       "0 255 0 255", "Beam color \"R G B A\" (0-255).");
	gCV_Refresh     = AutoExecConfig_CreateConVar("gokz_route_refresh",     "0.3", "Redraw interval in seconds (keep this smaller than lifetime so there is never a gap).", _, true, 0.05);
	gCV_Lifetime    = AutoExecConfig_CreateConVar("gokz_route_lifetime",    "0.7", "Beam lifetime in seconds (keep this larger than refresh so beams overlap and never flicker out).", _, true, 0.1);
	gCV_Width       = AutoExecConfig_CreateConVar("gokz_route_width",       "2.0", "Beam width.", _, true, 0.1);
	gCV_MinDist      = AutoExecConfig_CreateConVar("gokz_route_mindist",        "32",   "Downsample min distance between kept points (units).", _, true, 1.0);
	gCV_MaxSeg       = AutoExecConfig_CreateConVar("gokz_route_maxseg",         "500",  "Hard cap on number of drawn segments.", _, true, 10.0);
	gCV_VerifyCert   = AutoExecConfig_CreateConVar("gokz_route_verify_cert",    "0",    "Verify HTTPS certificate when downloading from R2.", _, true, 0.0, true, 1.0);
	gCV_ViewDist     = AutoExecConfig_CreateConVar("gokz_route_view_dist",      "1500", "Only draw route segments within this distance (units) of the player.", _, true, 50.0);
	gCV_HighlightColor = AutoExecConfig_CreateConVar("gokz_route_highlight_color","255 255 0 255", "Highlight color \"R G B A\" (0-255).");
	gCV_HighlightCount = AutoExecConfig_CreateConVar("gokz_route_highlight_count","5",    "Total number of segments to highlight around the player's current position.", _, true, 1.0);

	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();
}

public void OnAllPluginsLoaded()
{
	// Hook into the !o options menu if gokz-core is already loaded.
	TopMenu topMenu;
	if (LibraryExists("gokz-core") && ((topMenu = GOKZ_GetOptionsTopMenu()) != null))
	{
		GOKZ_OnOptionsMenuReady(topMenu);
	}
}

public void OnMapStart()
{
	GetCurrentMapDisplayName(gC_Map, sizeof(gC_Map));
	gI_BeamModel = PrecacheModel("materials/sprites/laserbeam.vmt", true);

	// Cache is per-map; clear everything on map change.
	ClearCache();

	// (Re)start the global refresh timer.
	if (gH_RefreshTimer != null)
	{
		KillTimer(gH_RefreshTimer);
	}
	gH_RefreshTimer = CreateTimer(gCV_Refresh.FloatValue, Timer_RefreshRoutes, _, TIMER_REPEAT);
}

public void OnMapEnd()
{
	if (gH_RefreshTimer != null)
	{
		KillTimer(gH_RefreshTimer);
		gH_RefreshTimer = null;
	}
}

public void OnClientDisconnect(int client)
{
	gB_Active[client] = false;
}

public void OnConfigsExecuted()
{
	EnsureDownloadsDir();
}

// Create the downloads dir (CreateDirectory is not recursive, so build each level).
static void EnsureDownloadsDir()
{
	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), "data/gokz-route");
	if (!DirExists(dir))
	{
		CreateDirectory(dir, 511);
	}
	BuildPath(Path_SM, dir, sizeof(dir), ROUTE_TEMP_DIR);  // data/gokz-route/downloads
	if (!DirExists(dir))
	{
		CreateDirectory(dir, 511);
	}
}



// =====[ MENU + ROUTE TOGGLE ]=====

// Read each player's saved preferences once their cookies are available.
public void OnClientCookiesCached(int client)
{
	if (client > 0 && IsClientInGame(client))
	{
		LoadClientPrefs(client);
	}
}

static void LoadClientPrefs(int client)
{
	gB_ShowTP[client]   = GetCookieBool(client, gC_ShowTP);
	gB_ShowPRO[client]  = GetCookieBool(client, gC_ShowPRO);
	gB_ShowFull[client] = GetCookieBool(client, gC_ShowFull);
	gB_ShowNext[client] = GetCookieBool(client, gC_ShowNext);

	// First-time defaults: full + next on, routes off. A cookie reads as empty
	// ("\0") when it has never been saved for this player.
	if (!CookieHasValue(client, gC_ShowFull)) gB_ShowFull[client] = true;
	if (!CookieHasValue(client, gC_ShowNext)) gB_ShowNext[client] = true;

	// Enforce mutual exclusion (TP wins if both are somehow set).
	if (gB_ShowTP[client] && gB_ShowPRO[client])
	{
		gB_ShowPRO[client] = false;
	}

	// Apply the saved route type, if any.
	if (gB_ShowTP[client])      ApplyRouteType(client, TimeType_Nub);
	else if (gB_ShowPRO[client]) ApplyRouteType(client, TimeType_Pro);
	else                         gB_Active[client] = false;
}

// type == -1 means turn the route off. TP and PRO are mutually exclusive.
static void ApplyRouteType(int client, int type)
{
	gB_ShowTP[client]  = (type == TimeType_Nub);
	gB_ShowPRO[client] = (type == TimeType_Pro);
	SetCookieBool(client, gC_ShowTP,  gB_ShowTP[client]);
	SetCookieBool(client, gC_ShowPRO, gB_ShowPRO[client]);

	if (!gCV_Enabled.BoolValue)
	{
		gB_Active[client] = false;
		return;
	}

	if (type == -1)
	{
		gB_Active[client] = false;
		return;
	}

	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	gI_Mode[client] = mode;
	gI_Type[client] = type;

	ArrayList cached = GetCachedRoute(mode, type);
	if (cached != null)
	{
		gB_Active[client] = true;
	}
	else
	{
		// Not cached yet; fetch (R2/local) and it will activate on completion.
		gB_Active[client] = false;
		RequestRouteLoad(client, mode, type);
	}
}

// ---- !o options menu: a top-level "寻路菜单" category (same pattern as gokz-paint) ----

public void GOKZ_OnOptionsMenuCreated(TopMenu topMenu)
{
	if (gTM_Options == topMenu && gTMO_Category != INVALID_TOPMENUOBJECT)
	{
		return;
	}
	gTMO_Category = topMenu.AddCategory(ROUTE_CATEGORY, TopMenuHandler_Category);
}

public void GOKZ_OnOptionsMenuReady(TopMenu topMenu)
{
	// Make sure the category exists (in case this fired without the Created forward).
	if (gTMO_Category == INVALID_TOPMENUOBJECT)
	{
		GOKZ_OnOptionsMenuCreated(topMenu);
	}
	if (gTM_Options == topMenu)
	{
		return;
	}
	gTM_Options = topMenu;

	gTMO_Toggle[0] = gTM_Options.AddItem("gokz_route_tp",   TopMenuHandler_Toggles, gTMO_Category);
	gTMO_Toggle[1] = gTM_Options.AddItem("gokz_route_pro",  TopMenuHandler_Toggles, gTMO_Category);
	gTMO_Toggle[2] = gTM_Options.AddItem("gokz_route_full", TopMenuHandler_Toggles, gTMO_Category);
	gTMO_Toggle[3] = gTM_Options.AddItem("gokz_route_next", TopMenuHandler_Toggles, gTMO_Category);
}

public void TopMenuHandler_Category(TopMenu topmenu, TopMenuAction action, TopMenuObject topobj_id, int param, char[] buffer, int maxlength)
{
	if ((action == TopMenuAction_DisplayOption || action == TopMenuAction_DisplayTitle) && topobj_id == gTMO_Category)
	{
		Format(buffer, maxlength, "寻路菜单");
	}
}

public void TopMenuHandler_Toggles(TopMenu topmenu, TopMenuAction action, TopMenuObject topobj_id, int param, char[] buffer, int maxlength)
{
	if (action == TopMenuAction_DisplayOption)
	{
		if (topobj_id == gTMO_Toggle[0])
		{
			Format(buffer, maxlength, "存点模式路线 - %s", gB_ShowTP[param] ? "开启" : "关闭");
		}
		else if (topobj_id == gTMO_Toggle[1])
		{
			Format(buffer, maxlength, "裸跳模式路线 - %s", gB_ShowPRO[param] ? "开启" : "关闭");
		}
		else if (topobj_id == gTMO_Toggle[2])
		{
			Format(buffer, maxlength, "完整路线 - %s", gB_ShowFull[param] ? "开启" : "关闭");
		}
		else if (topobj_id == gTMO_Toggle[3])
		{
			Format(buffer, maxlength, "下一步路线 - %s", gB_ShowNext[param] ? "开启" : "关闭");
		}
	}
	else if (action == TopMenuAction_SelectOption)
	{
		int client = param;
		if (topobj_id == gTMO_Toggle[0])
		{
			ApplyRouteType(client, gB_ShowTP[client] ? -1 : TimeType_Nub);
		}
		else if (topobj_id == gTMO_Toggle[1])
		{
			ApplyRouteType(client, gB_ShowPRO[client] ? -1 : TimeType_Pro);
		}
		else if (topobj_id == gTMO_Toggle[2])
		{
			gB_ShowFull[client] = !gB_ShowFull[client];
			SetCookieBool(client, gC_ShowFull, gB_ShowFull[client]);
		}
		else if (topobj_id == gTMO_Toggle[3])
		{
			gB_ShowNext[client] = !gB_ShowNext[client];
			SetCookieBool(client, gC_ShowNext, gB_ShowNext[client]);
		}
		topmenu.Display(client, TopMenuPosition_LastCategory);
	}
}

// ---- cookie helpers ----

static bool GetCookieBool(int client, Cookie cookie)
{
	char val[4];
	GetClientCookie(client, cookie, val, sizeof(val));
	return (val[0] == '1');
}

static bool CookieHasValue(int client, Cookie cookie)
{
	char val[4];
	GetClientCookie(client, cookie, val, sizeof(val));
	return (val[0] != '\0');
}

static void SetCookieBool(int client, Cookie cookie, bool value)
{
	SetClientCookie(client, cookie, value ? "1" : "0");
}

// Real-time SteamWorks availability check (survives load-order / reload timing issues).
// Checks both the extension file status and the actual native, to be safe.
static bool SteamWorksAvailable()
{
	if (GetExtensionFileStatus("SteamWorks.ext") <= 0)
	{
		return false;
	}
	return (GetFeatureStatus(FeatureType_Native, "SteamWorks_CreateHTTPRequest") == FeatureStatus_Available);
}



// =====[ ROUTE LOADING ]=====

static void RequestRouteLoad(int client, int mode, int type)
{
	char source[8];
	gCV_Source.GetString(source, sizeof(source));

	if (StrEqual(source, "local", false))
	{
		LoadRouteLocal(client, mode, type);
	}
	else
	{
		LoadRouteR2(client, mode, type);
	}
}

static void LoadRouteLocal(int client, int mode, int type)
{
	char path[PLATFORM_MAX_PATH];
	char modeStr[8]; char typeStr[4];
	GetGOKZModeStr(modeStr, sizeof(modeStr), mode);
	GetTypeStr(typeStr, sizeof(typeStr), type);
	// gokz-r2upload caches the main-course WR as <map>/0_<mode>_<type>.replay
	BuildPath(Path_SM, path, sizeof(path), "%s/%s/%d_%s_%s.replay", LOCAL_CACHE_DIR, gC_Map, LOCAL_COURSE, modeStr, typeStr);

	if (!FileExists(path))
	{
		PrintToChat(client, "[Route] No local WR replay found for this mode/type yet.");
		return;
	}

	ArrayList origins = ParseReplayOrigins(path);
	if (origins == null)
	{
		PrintToChat(client, "[Route] Failed to parse local WR replay.");
		return;
	}
	StoreAndActivate(client, mode, type, origins);
}

static void LoadRouteR2(int client, int mode, int type)
{
	if (!SteamWorksAvailable())
	{
		PrintToChat(client, "[Route] SteamWorks not loaded; cannot download from R2. Set gokz_route_source local as fallback.");
		return;
	}

	char url[512];
	if (!BuildRouteURL(url, sizeof(url), mode, type))
	{
		PrintToChat(client, "[Route] gokz_route_source_url is not set. Configure it or use source=local.");
		return;
	}

	// De-duplicate concurrent fetches for the same player+combo.
	char pkey[64];
	int userid = GetClientUserId(client);
	Format(pkey, sizeof(pkey), "%d_%d_%d", userid, mode, type);
	int dummy;
	if (gH_Pending.GetValue(pkey, dummy))
	{
		return;  // already fetching
	}
	gH_Pending.SetValue(pkey, 1);

	int combo = (mode & 0xFF) << 8 | (type & 0xFF);

	Handle req = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
	if (req == null)
	{
		gH_Pending.Remove(pkey);
		PrintToChat(client, "[Route] Failed to create HTTP request.");
		return;
	}
	SteamWorks_SetHTTPRequestNetworkActivityTimeout(req, 30);
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(req, 30000);
	SteamWorks_SetHTTPRequestRequiresVerifiedCertificate(req, gCV_VerifyCert.BoolValue);
	SteamWorks_SetHTTPRequestContextValue(req, userid, combo);
	SteamWorks_SetHTTPCallbacks(req, OnR2DownloadCompleted);

	if (!SteamWorks_SendHTTPRequest(req))
	{
		gH_Pending.Remove(pkey);
		delete req;
		PrintToChat(client, "[Route] Failed to send HTTP request.");
	}
}

public void OnR2DownloadCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1, any data2)
{
	int userid = data1;
	int combo = data2;
	int mode = (combo >> 8) & 0xFF;
	int type = combo & 0xFF;
	int client = GetClientOfUserId(userid);

	char pkey[64];
	Format(pkey, sizeof(pkey), "%d_%d_%d", userid, mode, type);
	gH_Pending.Remove(pkey);

	if (!bRequestSuccessful || view_as<int>(eStatusCode) != 200)
	{
		delete hRequest;
		if (client > 0 && IsClientInGame(client))
		{
			PrintToChat(client, "[Route] Failed to download WR replay from R2 (status=%d). No WR uploaded yet?", view_as<int>(eStatusCode));
		}
		return;
	}

	// Dump the response body to a temp file, then parse it.
	EnsureDownloadsDir();
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "%s/%d_%d_%d.replay", ROUTE_TEMP_DIR, userid, mode, type);
	if (!SteamWorks_WriteHTTPResponseBodyToFile(hRequest, path))
	{
		delete hRequest;
		if (client > 0 && IsClientInGame(client))
		{
			PrintToChat(client, "[Route] Failed to write downloaded replay to disk.");
		}
		return;
	}
	delete hRequest;

	ArrayList origins = ParseReplayOrigins(path);
	if (origins == null)
	{
		if (client > 0 && IsClientInGame(client))
		{
			PrintToChat(client, "[Route] Downloaded file is not a valid replay for this map.");
		}
		return;
	}

	if (client > 0 && IsClientInGame(client))
	{
		StoreAndActivate(client, mode, type, origins);
	}
	else
	{
		delete origins;
	}
}

static void StoreAndActivate(int client, int mode, int type, ArrayList origins)
{
	ArrayList downsampled = Downsample(origins, gCV_MinDist.FloatValue, gCV_MaxSeg.IntValue);
	delete origins;
	CacheRoute(mode, type, downsampled);  // cache owns downsampled
	gI_Mode[client] = mode;
	gI_Type[client] = type;

	// Only activate if the player still wants this type (they may have turned it
	// off in the menu while the download was in flight).
	bool want = (type == TimeType_Nub) ? gB_ShowTP[client] : (type == TimeType_Pro ? gB_ShowPRO[client] : false);
	gB_Active[client] = want;
	if (want)
	{
		PrintToChat(client, "[路线] 已加载 %s WR 路线 (%d 点)。", type == TimeType_Pro ? "裸跳" : "存点", downsampled.Length);
	}
}



// =====[ REPLAY PARSING ]=====

// Returns a plugin-owned ArrayList(blocksize 3) of origins, or null on failure.
// Mirrors gokz-replays/playback.sp LoadFormatVersion2Replay.
static ArrayList ParseReplayOrigins(const char[] path)
{
	File file = OpenFile(path, "rb");
	if (file == null)
	{
		return null;
	}

	int magic;
	file.ReadInt32(magic);
	if (magic != RP_MAGIC_NUMBER)
	{
		delete file;
		return null;
	}

	int formatVersion;
	file.ReadInt8(formatVersion);
	if (formatVersion != RP_FORMAT_VERSION)
	{
		// Only format v2 is supported.
		delete file;
		return null;
	}

	int replayType;
	file.ReadInt8(replayType);

	// gokz version
	int len;
	file.ReadInt8(len);
	char gokzVersion[64];
	file.ReadString(gokzVersion, len, len);
	gokzVersion[len] = '\0';

	// map name
	file.ReadInt8(len);
	char mapName[64];
	file.ReadString(mapName, len, len);
	mapName[len] = '\0';

	// Reject if the replay is for a different map (coordinates would be invalid).
	if (!StrEqual(mapName, gC_Map, false))
	{
		delete file;
		return null;
	}

	int mapFileSize; file.ReadInt32(mapFileSize);
	int serverIP;    file.ReadInt32(serverIP);
	int timestamp;   file.ReadInt32(timestamp);

	// player alias
	file.ReadInt8(len);
	char alias[MAX_NAME_LENGTH + 1];
	if (len > MAX_NAME_LENGTH) len = MAX_NAME_LENGTH;
	file.ReadString(alias, len, len);
	alias[len] = '\0';

	int steamID; file.ReadInt32(steamID);
	int bMode;   file.ReadInt8(bMode);
	int bStyle;  file.ReadInt8(bStyle);
	int sens;    file.ReadInt32(sens);
	int mYaw;    file.ReadInt32(mYaw);
	int tickrate;file.ReadInt32(tickrate);
	int tickCount; file.ReadInt32(tickCount);
	int weapon;  file.ReadInt32(weapon);
	int knife;   file.ReadInt32(knife);

	if (tickCount <= 0)
	{
		delete file;
		return null;
	}

	// Run header
	int timeAsInt; file.ReadInt32(timeAsInt);
	int rCourse;   file.ReadInt8(rCourse);
	int teleports; file.ReadInt32(teleports);

	ArrayList origins = new ArrayList(3);

	any tickDataArray[RP_V2_TICK_DATA_BLOCKSIZE];
	for (int i = 0; i < RP_V2_TICK_DATA_BLOCKSIZE; i++) tickDataArray[i] = 0;

	for (int i = 0; i < tickCount; i++)
	{
		file.ReadInt32(tickDataArray[RPDELTA_DELTAFLAGS]);
		for (int index = 1; index < sizeof(tickDataArray); index++)
		{
			int currentFlag = (1 << index);
			if (tickDataArray[RPDELTA_DELTAFLAGS] & currentFlag)
			{
				file.ReadInt32(tickDataArray[index]);
			}
		}

		float origin[3];
		origin[0] = view_as<float>(tickDataArray[RPDELTA_ORIGIN_X]);
		origin[1] = view_as<float>(tickDataArray[RPDELTA_ORIGIN_Y]);
		origin[2] = view_as<float>(tickDataArray[RPDELTA_ORIGIN_Z]);

		// Skip zeroed-out trailing ticks (jump-replay quirk safety).
		if (origin[0] == 0.0 && origin[1] == 0.0 && origin[2] == 0.0)
		{
			break;
		}
		origins.PushArray(origin);
	}

	delete file;
	return origins;
}

// Downsample by min distance; also hard-cap segment count.
static ArrayList Downsample(ArrayList origins, float minDist, int maxSeg)
{
	ArrayList out = new ArrayList(3);
	if (origins == null || origins.Length == 0)
	{
		return out;
	}

	// First pass: keep points that moved at least minDist from the last kept point.
	float last[3];
	origins.GetArray(0, last);
	out.PushArray(last);

	for (int i = 1; i < origins.Length; i++)
	{
		float p[3];
		origins.GetArray(i, p);
		float dx = p[0] - last[0];
		float dy = p[1] - last[1];
		float dz = p[2] - last[2];
		float dist = SquareRoot(dx * dx + dy * dy + dz * dz);
		if (dist >= minDist)
		{
			out.PushArray(p);
			last = p;
		}
	}

	// Always keep the final point.
	float finalP[3];
	origins.GetArray(origins.Length - 1, finalP);
	float lp[3];
	out.GetArray(out.Length - 1, lp);
	if (!(finalP[0] == lp[0] && finalP[1] == lp[1] && finalP[2] == lp[2]))
	{
		out.PushArray(finalP);
	}

	// If still too many segments, step through uniformly.
	if (out.Length - 1 > maxSeg && out.Length > 2)
	{
		ArrayList capped = new ArrayList(3);
		int step = RoundToCeil(float(out.Length - 1) / float(maxSeg));
		if (step < 1) step = 1;
		float tmp[3];
		for (int i = 0; i < out.Length; i += step)
		{
			out.GetArray(i, tmp);
			capped.PushArray(tmp);
		}
		// ensure last point
		out.GetArray(out.Length - 1, tmp);
		float cl[3];
		capped.GetArray(capped.Length - 1, cl);
		if (!(tmp[0] == cl[0] && tmp[1] == cl[1] && tmp[2] == cl[2]))
		{
			capped.PushArray(tmp);
		}
		delete out;
		return capped;
	}

	return out;
}



// =====[ DRAWING ]=====

public Action Timer_RefreshRoutes(Handle timer)
{
	if (!gCV_Enabled.BoolValue)
	{
		return Plugin_Continue;
	}

	int normalColor[4];
	int highlightColor[4];
	ParseColor(gCV_Color, normalColor);
	ParseColor(gCV_HighlightColor, highlightColor);

	float life = gCV_Lifetime.FloatValue;
	float width = gCV_Width.FloatValue;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!gB_Active[client] || !IsClientInGame(client))
		{
			continue;
		}
		ArrayList route = GetCachedRoute(gI_Mode[client], gI_Type[client]);
		if (route == null)
		{
			gB_Active[client] = false;
			continue;
		}
		DrawRouteToClient(client, route, normalColor, highlightColor, life, width);
	}
	return Plugin_Continue;
}

// Draws only the route segments near the player.
//   gB_ShowFull -> draw the nearby segments (green "full route")
//   gB_ShowNext -> draw the highlight band around the closest segment (yellow "next step")
// Both are independent per-player toggles.
static void DrawRouteToClient(int client, ArrayList route, const int normalColor[4], const int highlightColor[4], float life, float width)
{
	int n = route.Length;
	if (n < 2)
	{
		return;
	}

	bool drawFull = gB_ShowFull[client];
	bool drawNext = gB_ShowNext[client];
	if (!drawFull && !drawNext)
	{
		return;
	}

	float playerOrigin[3];
	if (!GetClientAbsOrigin(client, playerOrigin))
	{
		return;
	}

	float viewDist = gCV_ViewDist.FloatValue;
	int hlCount = gCV_HighlightCount.IntValue;

	// Pass 1: distance from the player to each segment, and the closest one.
	float[] segDist = new float[n - 1];
	float a[3], b[3];
	int bestIdx = -1;
	float bestDist = ROUTE_INF;
	for (int i = 0; i < n - 1; i++)
	{
		route.GetArray(i, a);
		route.GetArray(i + 1, b);
		segDist[i] = PointToSegmentDistance(playerOrigin, a, b);
		if (segDist[i] < bestDist)
		{
			bestDist = segDist[i];
			bestIdx = i;
		}
	}

	// Pass 2: draw segments. A segment that is both in-view and highlighted is
	// only drawn once, in the highlight color.
	int half = hlCount / 2;
	for (int i = 0; i < n - 1; i++)
	{
		bool inView = (segDist[i] <= viewDist);
		bool isHL = false;
		if (drawNext && bestIdx >= 0 && i >= bestIdx - half && i <= bestIdx + half)
		{
			isHL = true;
		}

		bool doNormal = drawFull && inView && !isHL;
		bool doHL = drawNext && isHL;
		if (!doNormal && !doHL)
		{
			continue;
		}

		route.GetArray(i, a);
		route.GetArray(i + 1, b);
		if (doHL)
		{
			DrawBeam(client, a, b, life, width, highlightColor);
		}
		else
		{
			DrawBeam(client, a, b, life, width, normalColor);
		}
	}
}

static void DrawBeam(int client, const float a[3], const float b[3], float life, float width, const int color[4])
{
	TE_SetupBeamPoints(a, b, gI_BeamModel, 0, 0, 0, life, width, width, 1, 0.0, color, 0);
	TE_SendToClient(client);
}

// Shortest distance from point p to segment [a, b].
static float PointToSegmentDistance(const float p[3], const float a[3], const float b[3])
{
	float ab[3], ap[3];
	SubtractVectors(b, a, ab);
	SubtractVectors(p, a, ap);

	float abLenSq = GetVectorDotProduct(ab, ab);
	float t = 0.0;
	if (abLenSq > 0.0)
	{
		t = GetVectorDotProduct(ap, ab) / abLenSq;
	}
	if (t < 0.0)
	{
		t = 0.0;
	}
	else if (t > 1.0)
	{
		t = 1.0;
	}

	float closest[3];
	closest[0] = a[0] + ab[0] * t;
	closest[1] = a[1] + ab[1] * t;
	closest[2] = a[2] + ab[2] * t;

	return GetVectorDistance(p, closest);
}



// =====[ CACHE ]=====

static void CacheKey(char[] buffer, int maxlength, int mode, int type)
{
	Format(buffer, maxlength, "%d_%d", mode, type);
}

static ArrayList GetCachedRoute(int mode, int type)
{
	char key[16];
	CacheKey(key, sizeof(key), mode, type);
	ArrayList arr;
	if (gH_Cache.GetValue(key, arr))
	{
		return arr;
	}
	return null;
}

static void CacheRoute(int mode, int type, ArrayList origins)
{
	char key[16];
	CacheKey(key, sizeof(key), mode, type);
	ArrayList old;
	if (gH_Cache.GetValue(key, old))
	{
		delete old;
	}
	gH_Cache.SetValue(key, origins);
}

static void ClearCache()
{
	if (gH_Cache == null)
	{
		return;
	}
	StringMapSnapshot snap = gH_Cache.Snapshot();
	ArrayList arr;
	char key[16];
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		if (gH_Cache.GetValue(key, arr))
		{
			delete arr;
		}
	}
	delete snap;
	gH_Cache.Clear();

	// Clear any active display states too.
	for (int c = 1; c <= MaxClients; c++)
	{
		gB_Active[c] = false;
	}
}



// =====[ HELPERS ]=====

static bool BuildRouteURL(char[] buffer, int maxlength, int mode, int type)
{
	char base[256];
	gCV_SourceURL.GetString(base, sizeof(base));
	if (base[0] == '\0')
	{
		return false;
	}
	char modeStr[8]; char typeStr[4];
	GetGOKZModeStr(modeStr, sizeof(modeStr), mode);
	GetTypeStr(typeStr, sizeof(typeStr), type);
	// Strip a trailing slash from base to be safe.
	int blen = strlen(base);
	if (blen > 0 && base[blen - 1] == '/')
	{
		base[blen - 1] = '\0';
	}
	// Fastest replay is stored as tp.replay / pro.replay (no rank).
	Format(buffer, maxlength, "%s/wr/%s/%s/%s.replay", base, modeStr, gC_Map, typeStr);
	return true;
}

static void GetGOKZModeStr(char[] buffer, int maxlength, int mode)
{
	if (mode >= 0 && mode < MODE_COUNT)
	{
		strcopy(buffer, maxlength, gC_ModeNamesShort[mode]);
		for (int i = 0; buffer[i] != '\0'; i++)
		{
			if (buffer[i] >= 'A' && buffer[i] <= 'Z')
			{
				buffer[i] = view_as<char>(buffer[i] + 32);
			}
		}
	}
	else
	{
		strcopy(buffer, maxlength, "unk");
	}
}

static void GetTypeStr(char[] buffer, int maxlength, int timeType)
{
	if (timeType == TimeType_Pro)
	{
		strcopy(buffer, maxlength, "pro");
	}
	else
	{
		strcopy(buffer, maxlength, "tp");
	}
}

static void ParseColor(ConVar cv, int color[4])
{
	char raw[32];
	cv.GetString(raw, sizeof(raw));
	char parts[4][8];
	int n = ExplodeString(raw, " ", parts, sizeof(parts), sizeof(parts[]));
	for (int i = 0; i < 4; i++)
	{
		color[i] = (i < n) ? StringToInt(parts[i]) : 255;
		if (color[i] < 0) color[i] = 0;
		if (color[i] > 255) color[i] = 255;
	}
}
