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

	  --- One-shot playback command ---
	  sm_follow / !follow  plays the WR path around the player's current position:
	  the line is drawn progressively from (now-back) to (now+fwd) seconds of the
	  WR run at 1x speed (so it visibly grows from start to end over back+fwd sec).
	  Once the head reaches (now+fwd), playback stops and the whole line vanishes
	  immediately. The player's current WR-time is inferred from the nearest route
	  segment AT THE MOMENT the command is issued (fixed snapshot; free to move).
	  gokz_route_follow_back   "3.0"  playback starts this many seconds BEHIND the player
	  gokz_route_follow_fwd    "3.0"  playback ends this many seconds AHEAD of the player
	  gokz_route_follow_color  "0 255 255 255"  playback beam color "R G B A"
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
#define DISK_CACHE_DIR    "data/gokz-route/cache"      // downloaded R2 replays cached on disk: <map>/<mode>_<type>.replay[+.meta]
#define LOCAL_CACHE_DIR   "data/gokz-r2upload/wrcache"   // owned by gokz-r2upload; files: <map>/0_<mode>_<type>.replay
#define LOCAL_COURSE      0                       // gokz-r2upload caches main course as "0_..."
#define ROUTE_INF         9999999.0               // stand-in for infinity when finding the closest segment
#define ROUTE_CATEGORY    "GOKZ Route"           // internal !o category key; display text is formatted in the handler



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
ConVar gCV_InterpSteps;
ConVar gCV_FollowBack;
ConVar gCV_FollowFwd;
ConVar gCV_FollowColor;

int gI_BeamModel = 0;
char gC_Map[64];

Handle gH_RefreshTimer = null;

// Per-client active route state (only mode + type matter; rank is always 0)
bool   gB_Active[MAXPLAYERS + 1];
int    gI_Mode[MAXPLAYERS + 1];
int    gI_Type[MAXPLAYERS + 1];     // TimeType_Nub (tp) / TimeType_Pro (pro)

// Per-client one-shot playback state (!follow): the WR path line is drawn
// progressively from T-back to T+fwd at 1x speed; once it reaches T+fwd the
// whole line vanishes immediately. Player can move freely.
bool   gB_PlayActive[MAXPLAYERS + 1];
float  gF_PlayStartGameTime[MAXPLAYERS + 1];  // GetGameTime() when playback began
float  gF_PlayT0[MAXPLAYERS + 1];             // WR-time where playback starts (T-back)
float  gF_PlayT1[MAXPLAYERS + 1];             // WR-time where playback ends   (T+fwd)
int    gI_PlayMode[MAXPLAYERS + 1];
int    gI_PlayType[MAXPLAYERS + 1];

// Per-client display preferences (persisted via clientprefs).
// gI_RouteType picks which WR route to load (TP=save / PRO=no-skip). Full/Next are
// continuous display toggles. Follow is a one-shot command (no persisted state).
int    gI_RouteType[MAXPLAYERS + 1];   // TimeType_Nub (tp) / TimeType_Pro (pro)
bool   gB_ShowFull[MAXPLAYERS + 1];
bool   gB_ShowNext[MAXPLAYERS + 1];
Cookie gC_RouteType;
Cookie gC_ShowFull;
Cookie gC_ShowNext;

// !o (options) menu integration
TopMenu       gTM_Options;
TopMenuObject gTMO_Category;
TopMenuObject gTMO_Toggle[3];   // 0=Next, 1=Mode, 2=Full

// Cache: parsed route origins per (mode, type) for the current map.
// Key "mode_type" -> ArrayList(blocksize 3) of float[3] origins (plugin-owned).
StringMap gH_Cache;
StringMap gH_Pending;   // in-flight downloads keyed by "userid_mode_type"



// =====[ PLUGIN LIFECYCLE ]=====

public void OnPluginStart()
{
	CreateConVars();

	gC_RouteType = RegClientCookie("gokz_route_type", "Route menu: 0=TP(save), 1=PRO(no-skip)", CookieAccess_Private);
	gC_ShowFull = RegClientCookie("gokz_route_show_full", "Route menu: show full route line", CookieAccess_Private);
	gC_ShowNext = RegClientCookie("gokz_route_show_next", "Route menu: show next-step highlight", CookieAccess_Private);

	gH_Cache = new StringMap();
	gH_Pending = new StringMap();

	RegConsoleCmd("sm_follow", Command_Follow, "Draw a one-shot WR path window (a few seconds before/after your position).");

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
	gCV_MinDist      = AutoExecConfig_CreateConVar("gokz_route_mindist",        "16",   "Downsample min distance between kept points (units).", _, true, 1.0);
	gCV_MaxSeg       = AutoExecConfig_CreateConVar("gokz_route_maxseg",         "1200", "Hard cap on number of drawn segments.", _, true, 10.0);
	gCV_VerifyCert   = AutoExecConfig_CreateConVar("gokz_route_verify_cert",    "0",    "Verify HTTPS certificate when downloading from R2.", _, true, 0.0, true, 1.0);
	gCV_ViewDist     = AutoExecConfig_CreateConVar("gokz_route_view_dist",      "1500", "Only draw route segments within this distance (units) of the player.", _, true, 50.0);
	gCV_HighlightColor = AutoExecConfig_CreateConVar("gokz_route_highlight_color","255 255 0 255", "Highlight color \"R G B A\" (0-255).");
	gCV_HighlightCount = AutoExecConfig_CreateConVar("gokz_route_highlight_count","5",    "Total number of segments to highlight around the player's current position.", _, true, 1.0);
	gCV_InterpSteps    = AutoExecConfig_CreateConVar("gokz_route_interp_steps",    "4",    "Catmull-Rom spline sub-steps per segment (higher = smoother curve). 1 = disabled.", _, true, 1.0, true, 10.0);
	gCV_FollowBack     = AutoExecConfig_CreateConVar("gokz_route_follow_back",   "3.0",  "Follow playback: seconds behind the player where playback starts.", _, true, 0.0);
	gCV_FollowFwd      = AutoExecConfig_CreateConVar("gokz_route_follow_fwd",    "3.0",  "Follow playback: seconds ahead of the player where playback ends.", _, true, 0.0);
	gCV_FollowColor    = AutoExecConfig_CreateConVar("gokz_route_follow_color",  "0 255 255 255", "Follow playback beam color \"R G B A\" (0-255).");

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
	gB_PlayActive[client] = false;
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
	BuildPath(Path_SM, dir, sizeof(dir), DISK_CACHE_DIR);  // data/gokz-route/cache
	if (!DirExists(dir))
	{
		CreateDirectory(dir, 511);
	}
}

// Per-map subdirectory under the disk cache.
static void EnsureDiskCacheMapDir(const char[] map)
{
	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), DISK_CACHE_DIR);
	if (!DirExists(dir)) CreateDirectory(dir, 511);
	BuildPath(Path_SM, dir, sizeof(dir), "%s/%s", DISK_CACHE_DIR, map);
	if (!DirExists(dir)) CreateDirectory(dir, 511);
}

// Disk cache file path for a (map, mode, type) combo.
static void BuildDiskCachePath(char[] buffer, int maxlength, const char[] map, int mode, int type)
{
	char modeStr[8]; char typeStr[4];
	GetGOKZModeStr(modeStr, sizeof(modeStr), mode);
	GetTypeStr(typeStr, sizeof(typeStr), type);
	BuildPath(Path_SM, buffer, maxlength, "%s/%s/%s_%s.replay", DISK_CACHE_DIR, map, modeStr, typeStr);
}

// Read the cached replay's time_ms (freshness marker) from the .meta sidecar. -1 if none.
static int ReadCachedTimeMs(const char[] replayPath)
{
	char metaPath[PLATFORM_MAX_PATH];
	Format(metaPath, sizeof(metaPath), "%s.meta", replayPath);
	if (!FileExists(metaPath)) return -1;
	File f = OpenFile(metaPath, "r");
	if (f == null) return -1;
	char line[32];
	f.ReadLine(line, sizeof(line));
	delete f;
	return StringToInt(line);
}

static void WriteCachedTimeMs(const char[] replayPath, int timeMs)
{
	char metaPath[PLATFORM_MAX_PATH];
	Format(metaPath, sizeof(metaPath), "%s.meta", replayPath);
	File f = OpenFile(metaPath, "w");
	if (f == null) return;
	f.WriteLine("%d", timeMs);
	delete f;
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
	// Route type: default TP (save). A cookie reads as empty ("\0") when never saved.
	if (CookieHasValue(client, gC_RouteType))
	{
		gI_RouteType[client] = GetCookieBool(client, gC_RouteType) ? TimeType_Pro : TimeType_Nub;
	}
	else
	{
		gI_RouteType[client] = TimeType_Nub;  // default: save (tp)
	}

	// Full / Next display toggles: default OFF.
	gB_ShowFull[client]   = GetCookieBool(client, gC_ShowFull);
	gB_ShowNext[client]   = GetCookieBool(client, gC_ShowNext);

	UpdateRouteActive(client);
}

// Re-evaluate whether a route should be active for this client, based on the
// current display toggles and the chosen route type. Loads/caches as needed.
static void UpdateRouteActive(int client)
{
	if (!gCV_Enabled.BoolValue)
	{
		gB_Active[client] = false;
		return;
	}

	// The route is only needed when at least one continuous display toggle is on.
	// (Follow is a one-shot command and loads its own route on demand.)
	if (!gB_ShowFull[client] && !gB_ShowNext[client])
	{
		gB_Active[client] = false;
		return;
	}

	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	int type = gI_RouteType[client];
	gI_Mode[client] = mode;
	gI_Type[client] = type;

	ArrayList cached = GetCachedRoute(mode, type);
	if (cached != null)
	{
		gB_Active[client] = true;
	}
	else
	{
		// Not cached yet; fetch (R2/local). It will activate on completion.
		gB_Active[client] = false;
		RequestRouteLoad(client, mode, type);
	}
}

// ---- !o options menu: a top-level route category (same pattern as gokz-paint) ----

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

	gTMO_Toggle[0] = gTM_Options.AddItem("gokz_route_next",   TopMenuHandler_Toggles, gTMO_Category);
	gTMO_Toggle[1] = gTM_Options.AddItem("gokz_route_mode",   TopMenuHandler_Toggles, gTMO_Category);
	gTMO_Toggle[2] = gTM_Options.AddItem("gokz_route_full",   TopMenuHandler_Toggles, gTMO_Category);
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
			Format(buffer, maxlength, "下一步路线 - %s", gB_ShowNext[param] ? "开启" : "关闭");
		}
		else if (topobj_id == gTMO_Toggle[1])
		{
			Format(buffer, maxlength, "当前模式 - %s", gI_RouteType[param] == TimeType_Pro ? "裸跳" : "存点");
		}
		else if (topobj_id == gTMO_Toggle[2])
		{
			Format(buffer, maxlength, "完整路线 - %s", gB_ShowFull[param] ? "开启" : "关闭");
		}
	}
	else if (action == TopMenuAction_SelectOption)
	{
		int client = param;
		if (topobj_id == gTMO_Toggle[0])
		{
			gB_ShowNext[client] = !gB_ShowNext[client];
			SetCookieBool(client, gC_ShowNext, gB_ShowNext[client]);
			UpdateRouteActive(client);
		}
		else if (topobj_id == gTMO_Toggle[1])
		{
			// Cycle TP(save) <-> PRO(no-skip).
			gI_RouteType[client] = (gI_RouteType[client] == TimeType_Pro) ? TimeType_Nub : TimeType_Pro;
			SetCookieBool(client, gC_RouteType, gI_RouteType[client] == TimeType_Pro);
			UpdateRouteActive(client);
		}
		else if (topobj_id == gTMO_Toggle[2])
		{
			gB_ShowFull[client] = !gB_ShowFull[client];
			SetCookieBool(client, gC_ShowFull, gB_ShowFull[client]);
			UpdateRouteActive(client);
		}
		topmenu.Display(client, TopMenuPosition_LastCategory);
	}
}

// sm_follow / !follow: one-shot playback. Locates the player's current WR-time
// from the nearest route segment (snapshot at this moment), then draws the WR
// path progressively from (T-back) to (T+fwd) at 1x speed -- the line grows from
// start to end. Once the head reaches (T+fwd), playback stops and the whole
// line vanishes immediately. The player can move freely during playback.
public Action Command_Follow(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}
	if (!gCV_Enabled.BoolValue)
	{
		PrintToChat(client, "[路线] 插件已被管理员关闭。");
		return Plugin_Handled;
	}

	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	int type = gI_RouteType[client];

	ArrayList route = GetCachedRoute(mode, type);
	if (route == null)
	{
		// Not cached yet -- kick off a load and ask the player to retry shortly.
		RequestRouteLoad(client, mode, type);
		PrintToChat(client, "[路线] WR 路线还在加载，请几秒后再用 !follow 。");
		return Plugin_Handled;
	}

	// Snapshot the player's current WR-time from the nearest route segment.
	float playerTime = NearestRouteTime(client, route);
	if (playerTime < 0.0)
	{
		PrintToChat(client, "[路线] 无法定位你在 WR 路线上的位置，请靠近路线后再试。");
		return Plugin_Handled;
	}

	float t0 = playerTime - gCV_FollowBack.FloatValue;
	float t1 = playerTime + gCV_FollowFwd.FloatValue;
	if (t0 < 0.0) t0 = 0.0;

	gB_PlayActive[client]         = true;
	gF_PlayStartGameTime[client]  = GetGameTime();
	gF_PlayT0[client]             = t0;
	gF_PlayT1[client]             = t1;
	gI_PlayMode[client]           = mode;
	gI_PlayType[client]           = type;

	float dur = t1 - t0;
	PrintToChat(client, "[路线] 开始播放 WR 路线 (%.1f 秒)，可自由移动。", dur);
	return Plugin_Handled;
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

	// ---- FAST PATH: if we already have a disk-cached replay for this combo, show it
	// instantly and then silently refresh from R2 in the background.
	char cachePath[PLATFORM_MAX_PATH];
	BuildDiskCachePath(cachePath, sizeof(cachePath), gC_Map, mode, type);
	if (FileExists(cachePath))
	{
		ArrayList origins = ParseReplayOrigins(cachePath);
		if (origins != null)
		{
			StoreAndActivate(client, mode, type, origins);  // show the cached route right now
		}
		// Refresh in the background regardless (cheap meta check first).
		BackgroundMetaRefresh(client, mode, type);
		return;
	}

	// ---- COLD PATH: no disk cache, do a full download.
	DownloadRouteFromR2(client, mode, type, true, 0);
}

// Full GET of the replay from R2.
//   storeToDiskCache = also write the downloaded file into the disk cache (+ .meta).
//   forcedTimeMs = if > 0, write this time_ms into .meta (we already know it from a meta query).
static void DownloadRouteFromR2(int client, int mode, int type, bool storeToDiskCache, int forcedTimeMs)
{
	char url[512];
	if (!BuildRouteURL(url, sizeof(url), mode, type))
	{
		if (client > 0 && IsClientInGame(client))
			PrintToChat(client, "[Route] gokz_route_source_url is not set.");
		return;
	}

	// De-duplicate concurrent fetches for the same combo (the file is shared across players).
	char pkey[64];
	Format(pkey, sizeof(pkey), "dl_%d_%d", mode, type);
	int dummy;
	if (gH_Pending.GetValue(pkey, dummy))
	{
		return;  // already fetching this combo
	}
	gH_Pending.SetValue(pkey, 1);

	int userid = (client > 0) ? GetClientUserId(client) : 0;
	int combo = (mode & 0xFF) << 8 | (type & 0xFF);

	// Carry storeToDiskCache + forcedTimeMs to the callback via a side StringMap entry.
	char fkey[32];
	Format(fkey, sizeof(fkey), "f_%d_%d", mode, type);
	char flagStr[32];
	Format(flagStr, sizeof(flagStr), "%d|%d", storeToDiskCache ? 1 : 0, forcedTimeMs);
	gH_Pending.SetString(fkey, flagStr);

	Handle req = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
	if (req == null)
	{
		gH_Pending.Remove(pkey);
		gH_Pending.Remove(fkey);
		if (client > 0 && IsClientInGame(client))
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
		gH_Pending.Remove(fkey);
		delete req;
		if (client > 0 && IsClientInGame(client))
			PrintToChat(client, "[Route] Failed to send HTTP request.");
	}
}

// Background freshness check: GET ?meta=1 (tiny), compare time_ms, only do a full download if R2 is faster.
static void BackgroundMetaRefresh(int client, int mode, int type)
{
	if (!SteamWorksAvailable()) return;

	char url[512];
	if (!BuildRouteURL(url, sizeof(url), mode, type)) return;
	Format(url, sizeof(url), "%s?meta=1", url);

	char pkey[64];
	Format(pkey, sizeof(pkey), "meta_%d_%d", mode, type);
	int dummy;
	if (gH_Pending.GetValue(pkey, dummy)) return;  // already checking
	gH_Pending.SetValue(pkey, 1);

	int userid = (client > 0) ? GetClientUserId(client) : 0;
	int combo = (mode & 0xFF) << 8 | (type & 0xFF);

	Handle req = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
	if (req == null)
	{
		gH_Pending.Remove(pkey);
		return;
	}
	SteamWorks_SetHTTPRequestNetworkActivityTimeout(req, 15);
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(req, 15000);
	SteamWorks_SetHTTPRequestRequiresVerifiedCertificate(req, gCV_VerifyCert.BoolValue);
	SteamWorks_SetHTTPRequestContextValue(req, userid, combo);
	SteamWorks_SetHTTPCallbacks(req, OnMetaRefreshCompleted);

	if (!SteamWorks_SendHTTPRequest(req))
	{
		gH_Pending.Remove(pkey);
		delete req;
	}
}

public void OnMetaRefreshCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1, any data2)
{
	int userid = data1;
	int combo = data2;
	int mode = (combo >> 8) & 0xFF;
	int type = combo & 0xFF;
	int client = GetClientOfUserId(userid);

	char pkey[64];
	Format(pkey, sizeof(pkey), "meta_%d_%d", mode, type);
	gH_Pending.Remove(pkey);

	if (!bRequestSuccessful || view_as<int>(eStatusCode) != 200)
	{
		delete hRequest;
		return;  // meta check failed; silently keep the cached version
	}

	// Read the tiny JSON: { exists, time_ms, ... }
	char body[256];
	SteamWorks_GetHTTPResponseBodyData(hRequest, body, sizeof(body));
	delete hRequest;

	bool exists = (StrContains(body, "\"exists\":true") != -1);
	if (!exists) return;  // R2 has nothing; keep cache

	int r2TimeMs = ExtractJsonInt(body, "time_ms");

	char cachePath[PLATFORM_MAX_PATH];
	BuildDiskCachePath(cachePath, sizeof(cachePath), gC_Map, mode, type);
	int localTimeMs = ReadCachedTimeMs(cachePath);

	// Only refresh when R2 is (likely) faster:
	//  - R2 time_ms unknown -> be safe and refresh (rare).
	//  - local time_ms unknown -> refresh.
	//  - R2 time_ms < local time_ms -> R2 is faster -> refresh.
	bool needRefresh = false;
	if (r2TimeMs < 0) needRefresh = true;
	else if (localTimeMs < 0) needRefresh = true;
	else if (r2TimeMs < localTimeMs) needRefresh = true;

	if (needRefresh)
	{
		DownloadRouteFromR2(client, mode, type, true, r2TimeMs);
	}
}

// Tiny JSON int extractor (avoids pulling a full JSON lib for one or two fields).
static int ExtractJsonInt(const char[] json, const char[] key)
{
	char needle[32];
	Format(needle, sizeof(needle), "\"%s\":", key);
	int pos = StrContains(json, needle);
	if (pos == -1) return -1;
	pos += strlen(needle);
	while (pos < strlen(json) && (json[pos] == ' ' || json[pos] == '\t')) pos++;
	if (pos >= strlen(json)) return -1;
	if (json[pos] == 'n') return -1;  // null
	return StringToInt(json[pos]);
}

public void OnR2DownloadCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1, any data2)
{
	int userid = data1;
	int combo = data2;
	int mode = (combo >> 8) & 0xFF;
	int type = combo & 0xFF;
	int client = GetClientOfUserId(userid);

	char pkey[64];
	Format(pkey, sizeof(pkey), "dl_%d_%d", mode, type);
	gH_Pending.Remove(pkey);

	// Retrieve the carry-over flags for this download.
	char fkey[32];
	Format(fkey, sizeof(fkey), "f_%d_%d", mode, type);
	char flagStr[32];
	bool hasFlags = gH_Pending.GetString(fkey, flagStr, sizeof(flagStr));
	gH_Pending.Remove(fkey);
	bool storeToDiskCache = false;
	int forcedTimeMs = 0;
	if (hasFlags)
	{
		char parts[2][16];
		if (ExplodeString(flagStr, "|", parts, sizeof(parts), sizeof(parts[])) >= 2)
		{
			storeToDiskCache = (StringToInt(parts[0]) == 1);
			forcedTimeMs = StringToInt(parts[1]);
		}
	}

	if (!bRequestSuccessful || view_as<int>(eStatusCode) != 200)
	{
		delete hRequest;
		if (client > 0 && IsClientInGame(client))
		{
			PrintToChat(client, "[Route] Failed to download WR replay from R2 (status=%d). No WR uploaded yet?", view_as<int>(eStatusCode));
		}
		return;
	}

	// Try to read time_ms from the response header (set by the Worker). Fallback to forcedTimeMs.
	int timeMs = forcedTimeMs;
	int hdrSize = 0;
	if (SteamWorks_GetHTTPResponseHeaderSize(hRequest, "x-time-ms", hdrSize) && hdrSize > 0)
	{
		char hdr[32];
		SteamWorks_GetHTTPResponseHeaderValue(hRequest, "x-time-ms", hdr, sizeof(hdr));
		int hdrMs = StringToInt(hdr);
		if (hdrMs > 0) timeMs = hdrMs;
	}

	// Dump the response body to a temp file, then parse it.
	EnsureDownloadsDir();
	char dlPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dlPath, sizeof(dlPath), "%s/%d_%d_%d.replay", ROUTE_TEMP_DIR, userid, mode, type);
	if (!SteamWorks_WriteHTTPResponseBodyToFile(hRequest, dlPath))
	{
		delete hRequest;
		if (client > 0 && IsClientInGame(client))
		{
			PrintToChat(client, "[Route] Failed to write downloaded replay to disk.");
		}
		return;
	}
	delete hRequest;

	ArrayList origins = ParseReplayOrigins(dlPath);
	if (origins == null)
	{
		if (client > 0 && IsClientInGame(client))
		{
			PrintToChat(client, "[Route] Downloaded file is not a valid replay for this map.");
		}
		return;
	}

	// Persist into the disk cache (+ .meta with time_ms) so future opens are instant.
	if (storeToDiskCache)
	{
		EnsureDiskCacheMapDir(gC_Map);
		char cachePath[PLATFORM_MAX_PATH];
		BuildDiskCachePath(cachePath, sizeof(cachePath), gC_Map, mode, type);
		File_Copy(dlPath, cachePath);
		if (timeMs > 0) WriteCachedTimeMs(cachePath, timeMs);
	}

	// Update the in-memory cache too (and any client currently viewing this combo).
	StoreAndRefreshViewers(mode, type, origins);
}

// Shared between cache-hit and fresh-download: downsample, store in memory cache,
// and re-activate any client currently displaying this combo.
static void StoreAndRefreshViewers(int mode, int type, ArrayList origins)
{
	ArrayList downsampled = Downsample(origins, gCV_MinDist.FloatValue, gCV_MaxSeg.IntValue);
	delete origins;
	downsampled = SplineInterpolateRoute(downsampled, gCV_InterpSteps.IntValue);
	CacheRoute(mode, type, downsampled);  // cache owns downsampled

	for (int c = 1; c <= MaxClients; c++)
	{
		if (gB_Active[c] && IsClientInGame(c) && gI_Mode[c] == mode && gI_Type[c] == type)
		{
			PrintToChat(c, "[路线] 已更新为最新 WR 路线 (%d 点)。", downsampled.Length);
		}
	}
}

static void StoreAndActivate(int client, int mode, int type, ArrayList origins)
{
	ArrayList downsampled = Downsample(origins, gCV_MinDist.FloatValue, gCV_MaxSeg.IntValue);
	delete origins;
	downsampled = SplineInterpolateRoute(downsampled, gCV_InterpSteps.IntValue);
	CacheRoute(mode, type, downsampled);  // cache owns downsampled
	gI_Mode[client] = mode;
	gI_Type[client] = type;

	// Only activate if the player still wants this type AND still has a continuous
	// display toggle on (they may have changed the menu while the download was in flight).
	bool want = (gI_RouteType[client] == type) && (gB_ShowFull[client] || gB_ShowNext[client]);
	gB_Active[client] = want;
	if (want)
	{
		PrintToChat(client, "[路线] 已加载 %s WR 路线 (%d 点)。", type == TimeType_Pro ? "裸跳" : "存点", downsampled.Length);
	}
}



// =====[ REPLAY PARSING ]=====

// Returns a plugin-owned ArrayList(blocksize 4) of [x, y, z, timeSec] entries, or null on failure.
// timeSec is the WR-run time of that tick (i / tickrate). Used by follow mode.
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
	int sensRaw; file.ReadInt32(sensRaw);
	int mYawRaw; file.ReadInt32(mYawRaw);
	int tickrateRaw; file.ReadInt32(tickrateRaw);
	float tickrate = view_as<float>(tickrateRaw);
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

	ArrayList origins = new ArrayList(4);

	any tickDataArray[RP_V2_TICK_DATA_BLOCKSIZE];
	for (int i = 0; i < RP_V2_TICK_DATA_BLOCKSIZE; i++) tickDataArray[i] = 0;

	float invTickrate = 0.0;
	if (tickrate > 0.0)
	{
		invTickrate = 1.0 / tickrate;
	}

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

		float pt[4];
		pt[0] = view_as<float>(tickDataArray[RPDELTA_ORIGIN_X]);
		pt[1] = view_as<float>(tickDataArray[RPDELTA_ORIGIN_Y]);
		pt[2] = view_as<float>(tickDataArray[RPDELTA_ORIGIN_Z]);

		// Skip zeroed-out trailing ticks (jump-replay quirk safety).
		if (pt[0] == 0.0 && pt[1] == 0.0 && pt[2] == 0.0)
		{
			break;
		}
		pt[3] = float(i) * invTickrate;  // WR-run time of this tick, in seconds
		origins.PushArray(pt);
	}

	delete file;
	return origins;
}

// Downsample by min distance; also hard-cap segment count. Preserves the time slot [3].
static ArrayList Downsample(ArrayList origins, float minDist, int maxSeg)
{
	ArrayList out = new ArrayList(4);
	if (origins == null || origins.Length == 0)
	{
		return out;
	}

	// First pass: keep points that moved at least minDist from the last kept point.
	float last[4];
	origins.GetArray(0, last);
	out.PushArray(last);

	for (int i = 1; i < origins.Length; i++)
	{
		float p[4];
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
	float finalP[4];
	origins.GetArray(origins.Length - 1, finalP);
	float lp[4];
	out.GetArray(out.Length - 1, lp);
	if (!(finalP[0] == lp[0] && finalP[1] == lp[1] && finalP[2] == lp[2]))
	{
		out.PushArray(finalP);
	}

	// If still too many segments, step through uniformly.
	if (out.Length - 1 > maxSeg && out.Length > 2)
	{
		ArrayList capped = new ArrayList(4);
		int step = RoundToCeil(float(out.Length - 1) / float(maxSeg));
		if (step < 1) step = 1;
		float tmp[4];
		for (int i = 0; i < out.Length; i += step)
		{
			out.GetArray(i, tmp);
			capped.PushArray(tmp);
		}
		// ensure last point
		out.GetArray(out.Length - 1, tmp);
		float cl[4];
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

// Catmull-Rom spline interpolation to smooth out the route path.
// Takes a downsampled route and adds (steps-1) intermediate points between each
// pair of existing points, creating a smooth curved path through the original points.
// Returns a new ArrayList; the caller must free the input if needed.
static ArrayList SplineInterpolateRoute(ArrayList route, int steps)
{
	if (route == null || route.Length < 2 || steps <= 1)
	{
		return route;
	}

	ArrayList out = new ArrayList(4);
	int n = route.Length;

	// Control points for Catmull-Rom: for segment [i, i+1] we use points
	// P[i-1], P[i], P[i+1], P[i+2] as the 4 control points.
	// At boundaries we mirror the first/last point to avoid pinching.
	for (int i = 0; i < n - 1; i++)
	{
		// Get the 4 control points for this segment.
		float P0[4], P1[4], P2[4], P3[4];
		route.GetArray(i, P1);     // start of segment
		route.GetArray(i + 1, P2); // end of segment

		// P0 = previous point (mirror if at first segment)
		if (i > 0)
		{
			route.GetArray(i - 1, P0);
		}
		else
		{
			// Reflect P1 across P0 generated from P1 and P2
			for (int a = 0; a < 4; a++)
				P0[a] = P1[a] + (P1[a] - P2[a]);
		}

		// P3 = next next point (mirror if at last segment)
		if (i + 2 < n)
		{
			route.GetArray(i + 2, P3);
		}
		else
		{
			for (int a = 0; a < 4; a++)
				P3[a] = P2[a] + (P2[a] - P1[a]);
		}

		// Always include the first point of each segment (avoids duplicates).
		if (i == 0)
		{
			out.PushArray(P1);
		}

		// Catmull-Rom: t goes from 0 (P1) to 1 (P2).
		float stepSize = 1.0 / float(steps);
		float pt[4];
		for (int s = 1; s <= steps; s++)
		{
			float t = float(s) * stepSize;
			if (t > 1.0) t = 1.0;

			// Catmull-Rom basis
			float t2 = t * t;
			float t3 = t2 * t;
			float h1 =  2.0 * t3 - 3.0 * t2 + 1.0;            // basis for P1
			float h2 = -2.0 * t3 + 3.0 * t2;                   // basis for P2
			float h3 =       t3 - 2.0 * t2 + t;                // basis for tangent at P1
			float h4 =       t3 -       t2;                    // basis for tangent at P2

			for (int a = 0; a < 4; a++)
			{
				// Tangents (Catmull-Rom: tangent at P1 = (P2 - P0)/2, at P2 = (P3 - P1)/2)
				float T1 = (P2[a] - P0[a]) * 0.5;
				float T2 = (P3[a] - P1[a]) * 0.5;
				pt[a] = h1 * P1[a] + h2 * P2[a] + h3 * T1 + h4 * T2;
			}

			out.PushArray(pt);
		}
	}

	delete route;
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
		if (!IsClientInGame(client))
		{
			continue;
		}

		// One-shot !follow playback runs independently of the continuous toggles.
		if (gB_PlayActive[client])
		{
			UpdateFollowPlayback(client);
		}

		if (!gB_Active[client])
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

// Draws route segments near the player (continuous modes only).
//   gB_ShowFull -> draw the nearby segments (green "full route")
//   gB_ShowNext -> draw the highlight band around the closest segment (yellow "next step")
// Both are independent per-player toggles. (Follow is a separate one-shot command.)
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
	float a[4], b[4];
	float oa[3], ob[3];
	int bestIdx = -1;
	float bestDist = ROUTE_INF;
	for (int i = 0; i < n - 1; i++)
	{
		route.GetArray(i, a);
		route.GetArray(i + 1, b);
		oa[0] = a[0]; oa[1] = a[1]; oa[2] = a[2];
		ob[0] = b[0]; ob[1] = b[1]; ob[2] = b[2];
		segDist[i] = PointToSegmentDistance(playerOrigin, oa, ob);
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
		oa[0] = a[0]; oa[1] = a[1]; oa[2] = a[2];
		ob[0] = b[0]; ob[1] = b[1]; ob[2] = b[2];
		if (doHL)
		{
			DrawBeam(client, oa, ob, life, width, highlightColor);
		}
		else
		{
			DrawBeam(client, oa, ob, life, width, normalColor);
		}
	}
}

// Returns the WR-time (seconds) of the route point nearest to the player, or
// -1.0 if it can't be determined (no route / can't read origin).
// On success, also returns via out-params the segment index and its distance.
static float NearestRouteTime(int client, ArrayList route)
{
	int n = route.Length;
	if (n < 2)
	{
		return -1.0;
	}

	float playerOrigin[3];
	if (!GetClientAbsOrigin(client, playerOrigin))
	{
		return -1.0;
	}

	float a[4], b[4];
	float oa[3], ob[3];
	int bestIdx = -1;
	float bestDist = ROUTE_INF;
	for (int i = 0; i < n - 1; i++)
	{
		route.GetArray(i, a);
		route.GetArray(i + 1, b);
		oa[0] = a[0]; oa[1] = a[1]; oa[2] = a[2];
		ob[0] = b[0]; ob[1] = b[1]; ob[2] = b[2];
		float d = PointToSegmentDistance(playerOrigin, oa, ob);
		if (d < bestDist)
		{
			bestDist = d;
			bestIdx = i;
		}
	}
	if (bestIdx < 0)
	{
		return -1.0;
	}

	route.GetArray(bestIdx, a);
	return a[3];
}

// Per-frame update for one-shot !follow playback. Animates the WR path drawing
// itself from gF_PlayT0 to gF_PlayT1 at 1x WR-speed: every frame we redraw the
// whole portion of the path the playback head has already swept over, so the
// line visibly grows from the start. Once the head reaches gF_PlayT1 the line is
// fully drawn and playback ends -- on the next frame nothing is drawn, so the
// entire line vanishes at once (beams use a short life so they don't linger).
// Player can move freely during playback; the snapshot is fixed at command time.
static void UpdateFollowPlayback(int client)
{
	ArrayList route = GetCachedRoute(gI_PlayMode[client], gI_PlayType[client]);
	if (route == null)
	{
		gB_PlayActive[client] = false;
		return;
	}
	int n = route.Length;
	if (n < 2)
	{
		gB_PlayActive[client] = false;
		return;
	}

	float t0 = gF_PlayT0[client];
	float t1 = gF_PlayT1[client];

	float elapsed = GetGameTime() - gF_PlayStartGameTime[client];  // 1x speed => seconds of WR
	float head    = t0 + elapsed;                                  // current playback WR-time

	// Playback complete: stop drawing. Since we redraw every frame and use a short
	// beam life, stopping now makes the whole line vanish immediately.
	if (head >= t1)
	{
		gB_PlayActive[client] = false;
		return;
	}

	int color[4];
	ParseColor(gCV_FollowColor, color);
	// Short life so the line disappears instantly when playback ends/stops.
	// Must cover the gap until the next refresh tick so it doesn't flicker out mid-play.
	float life  = gCV_Refresh.FloatValue * 1.5 + 0.05;
	if (life > gCV_Lifetime.FloatValue) life = gCV_Lifetime.FloatValue;
	float width = gCV_Width.FloatValue;

	float a[4], b[4];
	for (int i = 0; i < n - 1; i++)
	{
		route.GetArray(i, a);
		route.GetArray(i + 1, b);
		float ta = a[3];
		float tb = b[3];

		if (ta > head) break;          // not reached yet (route is time-ordered)
		if (tb > t1)  tb = t1;          // clamp the very last segment to the window end

		// Skip anything entirely before the window start.
		if (tb <= t0) continue;

		// If the segment straddles the window start, start it at t0.
		float segT0 = (ta < t0) ? t0 : ta;

		// Interpolate endpoints so the line grows smoothly up to the head position.
		float pa[3], pb[3];
		if (segT0 > ta)
		{
			float f = (segT0 - ta) / (tb - ta);
			pa[0] = a[0] + (b[0] - a[0]) * f;
			pa[1] = a[1] + (b[1] - a[1]) * f;
			pa[2] = a[2] + (b[2] - a[2]) * f;
		}
		else
		{
			pa[0] = a[0]; pa[1] = a[1]; pa[2] = a[2];
		}

		float segTEnd = (tb <= head) ? tb : head;  // draw up to the head if mid-segment
		float fEnd = (segTEnd - ta) / (tb - ta);
		pb[0] = a[0] + (b[0] - a[0]) * fEnd;
		pb[1] = a[1] + (b[1] - a[1]) * fEnd;
		pb[2] = a[2] + (b[2] - a[2]) * fEnd;

		// Skip degenerate (zero-length) slivers.
		if (GetVectorDistance(pa, pb) < 0.1) continue;

		DrawBeam(client, pa, pb, life, width, color);
	}
}

static void DrawBeam(int client, const float a[3], const float b[3], float life, float width, const int color[4])
{
	TE_SetupBeamPoints(a, b, gI_BeamModel, 0, 0, 0, life, width, width, 1, 0.0, color, 0);
	TE_SendToClient(client);
}

// Byte-for-byte file copy (shavit-style, same as gokz-replays/nav.sp).
static bool File_Copy(const char[] source, const char[] destination)
{
	File src = OpenFile(source, "rb");
	if (src == null) return false;
	File dst = OpenFile(destination, "wb");
	if (dst == null) { delete src; return false; }
	int[] buffer = new int[32];
	int cache = 0;
	while (!IsEndOfFile(src))
	{
		cache = ReadFile(src, buffer, 32, 1);
		dst.Write(buffer, cache, 1);
	}
	delete src;
	delete dst;
	return true;
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
		gB_PlayActive[c] = false;
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
