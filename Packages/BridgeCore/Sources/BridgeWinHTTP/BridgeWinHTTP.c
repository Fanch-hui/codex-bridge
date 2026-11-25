#include "BridgeWinHTTP.h"

#if defined(_WIN32)

DWORD BridgeWinHTTPUpgradeToWebSocket(HINTERNET hRequest)
{
    if (!WinHttpSetOption(hRequest,
                          WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET,
                          NULL,
                          0)) {
        return GetLastError();
    }
    return NO_ERROR;
}

DWORD BridgeWinHTTPApplyRequestOptions(HINTERNET hRequest)
{
    DWORD redirect = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if (!WinHttpSetOption(hRequest,
                          WINHTTP_OPTION_REDIRECT_POLICY,
                          &redirect,
                          sizeof(redirect))) {
        return GetLastError();
    }

    DWORD disable = WINHTTP_DISABLE_COOKIES;
    if (!WinHttpSetOption(hRequest,
                          WINHTTP_OPTION_DISABLE_FEATURE,
                          &disable,
                          sizeof(disable))) {
        return GetLastError();
    }

    DWORD autologon = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH;
    if (!WinHttpSetOption(hRequest,
                          WINHTTP_OPTION_AUTOLOGON_POLICY,
                          &autologon,
                          sizeof(autologon))) {
        return GetLastError();
    }

    return NO_ERROR;
}

#endif
