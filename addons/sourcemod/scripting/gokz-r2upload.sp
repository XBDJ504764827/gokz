/*
	gokz-r2upload
	---------------------------------------------
	Uploads an extra copy of GOKZ replays to Cloudflare R2 (proxied via a Worker).

	[Feature: fastest replay per map (WR)]
	  When a player beats the server record (tempReplay == false, i.e. the replay
	  is permanently saved), it is uploaded to:
	    wr/<vnl|skz|kzt>/<map>/<tp|pro><course>.replay
	  e.g. wr/skz/kz_bhop_easy/tp0.replay

	  "Second place" tp1/pro1:
	  Implemented via "shuffle" -- whenever a new record is set, the previous
	  record holder's replay is uploaded as tp1 and the new record as tp0.
	  In other words tp1 = the previous world record holder.
	  (Note: GOKZ only permanently keeps the #1 replay on disk; non-record PB
	    replays are written as temporary files and deleted. An exact "current
	    2nd place" therefore requires the "archive all replays" feature, which
	    can be added later.)

	The plugin only sends the necessary metadata; the Worker builds the path:
	    POST {gokz_r2upload_url}
	    Headers:
	        X-API-Key:   <gokz_r2upload_key>
	        X-GOKZ-Mode: <vnl|skz|kzt>
	        X-Map:       <map name>
	        X-Route:     <tp|pro>             e.g. tp / pro
	    Body: raw .replay file bytes
	  Worker stores it at: wr/<X-GOKZ-Mode>/<X-Map>/<X-Route>.replay

	Does not affect existing functionality:
	  - Does not modify any gokz-replays / gokz-global source.
	  - The forward callback returns Plugin_Continue; local saving and the
	    global upload behave exactly as before.
	  - Uploads are asynchronous; failures only log an error.

	Dependencies: SteamWorks extension, gokz-replays plugin.

	ConVars (auto-generated at first load at cfg/sourcemod/gokz/gokz-r2upload.cfg,
	         alongside the other GOKZ configs):
	  gokz_r2upload_enabled    "1"  master switch
	  gokz_r2upload_wr_enabled "1"  WR (fastest) replay upload switch
	  gokz_r2upload_url        ""   Worker URL (root path)
	  gokz_r2upload_key        ""   X-API-Key
	  gokz_r2upload_debug      "0"  debug logging
*/

#include <sourcemod>
#include <SteamWorks>
#include <autoexecconfig>
#include <gokz>
#include <gokz/core>
#include <gokz/replays>

#pragma newdecls required
#pragma semicolon 1



public Plugin myinfo =
{
	name = "GOKZ Replay R2 Uploader",
	author = "XBDJ50476482",
	description = "Uploads GOKZ WR replays to Cloudflare R2 via a Worker",
	version = "1.2.0",
	url = ""
};



// =====[ CONSTANTS ]=====

#define R2U_CACHE_DIR   "data/gokz-r2upload/wrcache"   // Relative to Path_SM; one subfolder per map
#define R2U_RUNS_DIR    "data/gokz-replays/_runs"      // GOKZ permanent replay dir (relative to Path_SM)



// =====[ CVARS ]=====

ConVar gCV_Enabled;
ConVar gCV_WREnabled;
ConVar gCV_Url;
ConVar gCV_Key;
ConVar gCV_Debug;
ConVar gCV_VerifyCert;

bool gB_SteamWorksOK = false;
char gC_Map[64];



// =====[ PLUGIN LIFECYCLE ]=====

public void OnPluginStart()
{
	CreateConVars();
	RegAdminCmd("sm_r2upload_test", Command_TestUpload, ADMFLAG_ROOT, "Test the R2 upload connection with a small body and log diagnostics.");
}

static void CreateConVars()
{
	// Generates cfg/sourcemod/gokz/gokz-r2upload.cfg (same folder as the other GOKZ configs)
	AutoExecConfig_SetFile("gokz-r2upload", "sourcemod/gokz");
	AutoExecConfig_SetCreateFile(true);

	gCV_Enabled   = AutoExecConfig_CreateConVar("gokz_r2upload_enabled",    "1", "Master switch. Whether to upload replays to R2.", _, true, 0.0, true, 1.0);
	gCV_WREnabled = AutoExecConfig_CreateConVar("gokz_r2upload_wr_enabled", "1", "Upload world-record (fastest) replays. When a player beats the server record, upload to wr/<mode>/<map>/<tp|pro><course>.replay.", _, true, 0.0, true, 1.0);
	gCV_Url       = AutoExecConfig_CreateConVar("gokz_r2upload_url",        "", "Cloudflare Worker URL (root path), e.g. https://cngokzreplay.iquankz.cn");
	gCV_Key       = AutoExecConfig_CreateConVar("gokz_r2upload_key",        "", "X-API-Key shared with the Worker.");
	gCV_Debug     = AutoExecConfig_CreateConVar("gokz_r2upload_debug",      "0", "Print debug logging (recommended to set back to 0 after verifying).", _, true, 0.0, true, 1.0);
	gCV_VerifyCert = AutoExecConfig_CreateConVar("gokz_r2upload_verify_cert", "0", "Verify the HTTPS certificate when uploading. Default 0 (off). If uploads fail with status=0 over HTTPS, leave 0; set 1 only if your Steam CA bundle trusts the cert.", _, true, 0.0, true, 1.0);

	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();
}

public void OnAllPluginsLoaded()
{
	if (!LibraryExists("gokz-replays"))
	{
		LogError("[gokz-r2upload] gokz-replays not found; relies on its GOKZ_RP_OnReplaySaved forward.");
	}
	gB_SteamWorksOK = (GetExtensionFileStatus("SteamWorks.ext") > 0);
	if (!gB_SteamWorksOK)
	{
		LogError("[gokz-r2upload] SteamWorks extension not loaded; required to upload.");
	}
	else if (!SteamWorks_IsConnected())
	{
		// SteamWorks HTTP requires the gameserver to be connected to Steam. This usually
		// means the server needs a valid GSLT (sv_setsteamaccount) and Steam connectivity.
		LogError("[gokz-r2upload] SteamWorks is loaded but the gameserver is NOT connected to Steam. HTTP uploads will fail. Ensure the server has a GSLT and Steam connectivity.");
	}
}

public void OnMapStart()
{
	GetCurrentMapDisplayName(gC_Map, sizeof(gC_Map));
	// Backfill this map's existing server records (_runs) to R2 and seed the "shuffle" cache (once per combo)
	CreateTimer(3.0, Timer_BackfillMap);  // Slight delay to avoid I/O contention during map load
}

public Action Timer_BackfillMap(Handle timer)
{
	BackfillExistingRecords(gC_Map);
	return Plugin_Stop;
}



// =====[ FORWARD FROM gokz-replays ]=====

public Action GOKZ_RP_OnReplaySaved(int client, int replayType,
	const char[] map, int course, int timeType, float time,
	const char[] filePath, bool tempReplay)
{
	// Always pass through; never take over temp-replay deletion
	if (!gCV_Enabled.BoolValue || !gCV_WREnabled.BoolValue)
	{
		return Plugin_Continue;
	}
	if (replayType != ReplayType_Run)
	{
		return Plugin_Continue;
	}
	// tempReplay == false means the replay was permanently saved = the server
	// record was beaten = the current fastest (holds for the very first record too)
	if (tempReplay)
	{
		return Plugin_Continue;
	}
	if (filePath[0] == '\0')
	{
		return Plugin_Continue;
	}
	// Only the main course (course 0) is tracked in R2. Bonus courses are ignored
	// to avoid overwriting the main-course WR (the R2 path has no course component).
	if (course != 0)
	{
		return Plugin_Continue;
	}

	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	UploadWR(map, mode, course, timeType, filePath);
	return Plugin_Continue;
}



// =====[ WR UPLOAD ]=====

static void UploadWR(const char[] map, int mode, int course, int timeType, const char[] newWRPath)
{
	if (!gB_SteamWorksOK)
	{
		return;
	}

	char gokzMode[8];
	GetGOKZModeStr(gokzMode, sizeof(gokzMode), mode);

	char typeStr[4];
	GetTypeStr(typeStr, sizeof(typeStr), timeType);

	// Cache file used as an idempotency marker for backfill (and a local source for gokz-route).
	char cacheFile[PLATFORM_MAX_PATH];
	BuildCachePath(cacheFile, sizeof(cacheFile), map, course, mode, timeType);

	// Upload the single fastest replay for this (mode, type) as tp / pro (no rank).
	bool ok = UploadReplayFile(map, gokzMode, typeStr, newWRPath);

	// Update the cache to the new record.
	if (ok && FileExists(newWRPath))
	{
		EnsureCacheDir(map);
		File_Copy(newWRPath, cacheFile);
	}
}

// Backfill: upload this map's existing server records found under _runs as tp0/pro0, and seed the cache.
// Idempotent via the cache: each (course, mode, type) combo is uploaded only once.
static void BackfillExistingRecords(const char[] map)
{
	if (!gB_SteamWorksOK || map[0] == '\0')
	{
		return;
	}

	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), "%s/%s", R2U_RUNS_DIR, map);

	DirectoryListing listing = OpenDirectory(dir);
	if (listing == null)
	{
		return;  // No replays for this map yet
	}

	char fileName[PLATFORM_MAX_PATH];
	char fullPath[PLATFORM_MAX_PATH];
	FileType fileType;

	while (listing.GetNext(fileName, sizeof(fileName), fileType))
	{
		if (fileType != FileType_File)
		{
			continue;
		}
		// Only permanent .replay files, named <course>_<MODE>_<STYLE>_<TIMETYPE>.replay
		int len = strlen(fileName);
		if (len < 8 || !StrEqual(fileName[len - 7], ".replay"))  // ".replay" = 7 chars
		{
			continue;
		}

		int course; int mode; int timeType;
		if (!ParseRunReplayFileName(fileName, course, mode, timeType))
		{
			continue;
		}
		// Only the main course (course 0) is tracked in R2.
		if (course != 0)
		{
			continue;
		}

		char cacheFile[PLATFORM_MAX_PATH];
		BuildCachePath(cacheFile, sizeof(cacheFile), map, course, mode, timeType);
		if (FileExists(cacheFile))
		{
			continue;  // Already uploaded, skip
		}

		BuildPath(Path_SM, fullPath, sizeof(fullPath), "%s/%s/%s", R2U_RUNS_DIR, map, fileName);

		char gokzMode[8];
		GetGOKZModeStr(gokzMode, sizeof(gokzMode), mode);
		char typeStr[4];
		GetTypeStr(typeStr, sizeof(typeStr), timeType);

		if (gCV_Debug.BoolValue)
		{
			LogMessage("[gokz-r2upload] Backfill tp0 -> wr/%s/%s/%s0.replay", gokzMode, map, typeStr);
		}

		if (UploadReplayFile(map, gokzMode, typeStr, fullPath))
		{
			EnsureCacheDir(map);
			File_Copy(fullPath, cacheFile);
		}
	}
	delete listing;
}

// Parse a GOKZ permanent replay filename: <course>_<MODE>_<STYLE>_<TIMETYPE>.replay
// e.g. 0_SKZ_NRM_PRO.replay -> course=0, mode=SimpleKZ, timeType=Pro
static bool ParseRunReplayFileName(const char[] fileName, int &course, int &mode, int &timeType)
{
	char buf[PLATFORM_MAX_PATH];
	strcopy(buf, sizeof(buf), fileName);

	// Strip the extension
	int dot = StrContains(buf, ".replay");
	if (dot == -1)
	{
		return false;
	}
	buf[dot] = '\0';

	// Split on '_' into 4 fields
	char parts[4][16];
	int n = ExplodeString(buf, "_", parts, sizeof(parts), sizeof(parts[]));
	if (n < 4)
	{
		return false;
	}

	course = StringToInt(parts[0]);
	mode = FindModeByShort(parts[1]);
	timeType = FindTimeTypeByName(parts[3]);
	return mode != -1 && timeType != -1 && course >= 0;
}

static int FindModeByShort(const char[] shortName)
{
	// gC_ModeNamesShort = { "VNL", "SKZ", "KZT" }
	for (int i = 0; i < MODE_COUNT; i++)
	{
		if (StrEqual(shortName, gC_ModeNamesShort[i], false))
		{
			return i;
		}
	}
	return -1;
}

static int FindTimeTypeByName(const char[] name)
{
	if (StrEqual(name, "NUB", false))
	{
		return TimeType_Nub;
	}
	if (StrEqual(name, "PRO", false))
	{
		return TimeType_Pro;
	}
	return -1;
}



// =====[ UPLOAD PRIMITIVE ]=====

static bool UploadReplayFile(const char[] map, const char[] gokzMode, const char[] typeStr, const char[] filePath)
{
	char url[256];
	gCV_Url.GetString(url, sizeof(url));
	if (url[0] == '\0')
	{
		if (gCV_Debug.BoolValue)
		{
			LogMessage("[gokz-r2upload] Skipping upload: gokz_r2upload_url is not set.");
		}
		return false;
	}

	if (!FileExists(filePath))
	{
		return false;
	}

	char key[128];
	gCV_Key.GetString(key, sizeof(key));

	// X-Route = tp / pro (the single fastest replay for this type; no rank)
	if (gCV_Debug.BoolValue)
	{
		LogMessage("[gokz-r2upload] Uploading -> wr/%s/%s/%s.replay (file=%s)", gokzMode, map, typeStr, filePath);
	}

	Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, url);
	if (hRequest == null)
	{
		LogError("[gokz-r2upload] Failed to create HTTP request.");
		return false;
	}

	SteamWorks_SetHTTPRequestNetworkActivityTimeout(hRequest, 60);
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(hRequest, 60000);
	SteamWorks_SetHTTPRequestRequiresVerifiedCertificate(hRequest, gCV_VerifyCert.BoolValue);
	SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-API-Key", key);
	SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-GOKZ-Mode", gokzMode);
	SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-Map", map);
	SteamWorks_SetHTTPRequestHeaderValue(hRequest, "X-Route", typeStr);

	char contentType[] = "application/octet-stream";
	if (!SteamWorks_SetHTTPRequestRawPostBodyFromFile(hRequest, contentType, filePath))
	{
		LogError("[gokz-r2upload] Failed to set POST body from file: %s", filePath);
		delete hRequest;
		return false;
	}

	SteamWorks_SetHTTPCallbacks(hRequest, OnUploadCompleted);

	if (!SteamWorks_SendHTTPRequest(hRequest))
	{
		LogError("[gokz-r2upload] Failed to send HTTP request for wr/%s/%s/%s.replay", gokzMode, map, typeStr);
		delete hRequest;
		return false;
	}
	return true;
}

public void OnUploadCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode)
{
	int code = view_as<int>(eStatusCode);
	if (bFailure || !bRequestSuccessful || code < 200 || code >= 300)
	{
		bool wasTimeout = false;
		SteamWorks_GetHTTPRequestWasTimedOut(hRequest, wasTimeout);
		LogError("[gokz-r2upload] Upload failed. failure=%d successful=%d status=%d timeout=%d verify_cert=%d",
			bFailure ? 1 : 0, bRequestSuccessful ? 1 : 0, code, wasTimeout ? 1 : 0, gCV_VerifyCert.BoolValue ? 1 : 0);
	}
	else if (gCV_Debug.BoolValue)
	{
		LogMessage("[gokz-r2upload] Upload OK, status=%d", code);
	}
	delete hRequest;
}



// =====[ CONNECTION TEST ]=====

// Minimal in-memory POST to isolate connection/TLS issues from file handling.
// Run with: sm_r2upload_test  (logs go to server console)
public Action Command_TestUpload(int client, int args)
{
	char url[256];
	gCV_Url.GetString(url, sizeof(url));
	char key[128];
	gCV_Key.GetString(key, sizeof(key));

	PrintToServer("=== [gokz-r2upload] connection test ===");
	PrintToServer("SteamWorks loaded    : %d", SteamWorks_IsLoaded() ? 1 : 0);
	PrintToServer("Steam server connect : %d", SteamWorks_IsConnected() ? 1 : 0);
	PrintToServer("URL                  : '%s'", url);
	PrintToServer("Key set              : %s", key[0] == '\0' ? "NO (empty)" : "yes");
	PrintToServer("Verify cert          : %d", gCV_VerifyCert.BoolValue ? 1 : 0);

	if (!gB_SteamWorksOK)
	{
		PrintToServer("SteamWorks not loaded, aborting test.");
		return Plugin_Handled;
	}
	if (url[0] == '\0')
	{
		PrintToServer("gokz_r2upload_url is empty, aborting test.");
		return Plugin_Handled;
	}

	char body[] = "gokz-r2upload-connection-test";
	Handle req = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, url);
	if (req == null)
	{
		PrintToServer("Failed to create HTTP request.");
		return Plugin_Handled;
	}
	SteamWorks_SetHTTPRequestNetworkActivityTimeout(req, 60);
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(req, 60000);
	SteamWorks_SetHTTPRequestRequiresVerifiedCertificate(req, gCV_VerifyCert.BoolValue);
	SteamWorks_SetHTTPRequestHeaderValue(req, "X-API-Key", key);
	SteamWorks_SetHTTPRequestHeaderValue(req, "X-Map", "connection-test");
	SteamWorks_SetHTTPRequestHeaderValue(req, "X-Route", "test");
	SteamWorks_SetHTTPRequestRawPostBody(req, "application/octet-stream", body, strlen(body));
	SteamWorks_SetHTTPCallbacks(req, OnTestUploadCompleted);
	bool sent = SteamWorks_SendHTTPRequest(req);
	PrintToServer("Test request %s. Watch the log for the result line.", sent ? "sent" : "FAILED to send");
	return Plugin_Handled;
}

public void OnTestUploadCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode)
{
	bool wasTimeout = false;
	SteamWorks_GetHTTPRequestWasTimedOut(hRequest, wasTimeout);
	PrintToServer("=== TEST RESULT: failure=%d successful=%d status=%d timeout=%d verify_cert=%d ===",
		bFailure ? 1 : 0, bRequestSuccessful ? 1 : 0, view_as<int>(eStatusCode), wasTimeout ? 1 : 0, gCV_VerifyCert.BoolValue ? 1 : 0);
	delete hRequest;
}



// =====[ HELPERS ]=====

static void GetGOKZModeStr(char[] buffer, int maxlength, int mode)
{
	if (mode >= 0 && mode < MODE_COUNT)
	{
		strcopy(buffer, maxlength, gC_ModeNamesShort[mode]);
		// Lowercase it
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

static void BuildCachePath(char[] buffer, int maxlength, const char[] map, int course, int mode, int timeType)
{
	char gokzMode[8];
	GetGOKZModeStr(gokzMode, sizeof(gokzMode), mode);
	char typeStr[4];
	GetTypeStr(typeStr, sizeof(typeStr), timeType);
	BuildPath(Path_SM, buffer, maxlength, "%s/%s/%d_%s_%s.replay", R2U_CACHE_DIR, map, course, gokzMode, typeStr);
}

static void EnsureCacheDir(const char[] map)
{
	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), "%s", R2U_CACHE_DIR);
	if (!DirExists(dir))
	{
		CreateDirectory(dir, 511);
	}
	BuildPath(Path_SM, dir, sizeof(dir), "%s/%s", R2U_CACHE_DIR, map);
	if (!DirExists(dir))
	{
		CreateDirectory(dir, 511);
	}
}

// Copied from gokz-replays/nav.sp File_Copy (shavit-style)
static bool File_Copy(const char[] source, const char[] destination)
{
	File file_source = OpenFile(source, "rb");
	if (file_source == null)
	{
		return false;
	}
	File file_destination = OpenFile(destination, "wb");
	if (file_destination == null)
	{
		delete file_source;
		return false;
	}
	int[] buffer = new int[32];
	int cache = 0;
	while (!IsEndOfFile(file_source))
	{
		cache = ReadFile(file_source, buffer, 32, 1);
		file_destination.Write(buffer, cache, 1);
	}
	delete file_source;
	delete file_destination;
	return true;
}
