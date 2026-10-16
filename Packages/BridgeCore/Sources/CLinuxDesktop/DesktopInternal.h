#include "include/CLinuxDesktop.h"
#include <string.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <jsc/jsc.h>

typedef struct {
  WebKitWebView *view;
  const gchar *site;
  const gchar *home;
  const gchar *state;
  gchar *error;
} BridgeBrowser;

typedef struct {
  GtkWidget *window;
  GtkWidget *layout;
  WebKitWebView *desktop;
  BridgeBrowser browsers[2];
  BridgeBrowser *browser;
  gchar *page_root;
  gchar *data_root;
  gboolean browser_enabled;
  gboolean browser_visible;
  gint browser_x, browser_y, browser_width, browser_height;
} BridgeDesktop;
extern BridgeDesktop bridge_desktop;
void bridge_push_event(gchar *event);
WebKitWebView *bridge_make_view(const gchar *data_root, const gchar *scope);
gboolean bridge_open_uri_idle(gpointer value);
