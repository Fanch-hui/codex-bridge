#include "include/CLinuxDesktop.h"
#include <string.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <jsc/jsc.h>

typedef struct {
  GtkWidget *window;
  GtkWidget *layout;
  WebKitWebView *desktop;
  WebKitWebView *browser;
  gchar *page_root;
  gboolean browser_enabled;
  gboolean browser_visible;
  gint browser_x, browser_y, browser_width, browser_height;
} BridgeDesktop;
extern BridgeDesktop bridge_desktop;
void bridge_push_event(gchar *event);
void bridge_browser_snapshot(const gchar *state, const gchar *error);
void bridge_connect_browser(void);
gboolean bridge_open_uri_idle(gpointer value);
