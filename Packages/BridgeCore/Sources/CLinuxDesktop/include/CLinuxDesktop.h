#ifndef CODEX_BRIDGE_LINUX_DESKTOP_H
#define CODEX_BRIDGE_LINUX_DESKTOP_H
int bridge_linux_start(const char *page_uri, const char *data_root);
int bridge_linux_running(void);
char *bridge_linux_next_event(void);
void bridge_linux_free(void *value);
void bridge_linux_script(const char *script);
void bridge_linux_browser_action(int action);
void bridge_linux_browser_viewport(double x, double y, double width, double height, int visible);
void bridge_linux_browser_enabled(int enabled);
void bridge_linux_copy(const char *text);
void bridge_linux_open_uri(const char *uri);
void bridge_linux_choose_file(const char *request_id, const char *title, int directory);
void bridge_linux_stop(void);
#endif
