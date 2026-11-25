#ifndef BRIDGE_WINHTTP_H
#define BRIDGE_WINHTTP_H

#if defined(_WIN32)
#include <windows.h>
#include <winhttp.h>

/// Wraps `WinHttpSetOption(WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET)`; returns the
/// Win32 error, or NO_ERROR on success.
DWORD BridgeWinHTTPUpgradeToWebSocket(HINTERNET hRequest);

/// Sets WINHTTP_OPTION_REDIRECT_POLICY, _DISABLE_FEATURE (cookies) and
/// _AUTOLOGON_POLICY in one call; returns the first Win32 error, or NO_ERROR.
DWORD BridgeWinHTTPApplyRequestOptions(HINTERNET hRequest);

#endif
#endif
