#include "DesktopInternal.h"

void bridge_browser_snapshot(const gchar *state, const gchar *error) {
  const gchar *uri = webkit_web_view_get_uri(bridge_desktop.browser);
  bridge_push_event(g_strdup_printf("browser\n%s\n%d\n%d\n%s\n%s", state,
      webkit_web_view_can_go_back(bridge_desktop.browser),
      webkit_web_view_can_go_forward(bridge_desktop.browser),
      uri ? uri : "https://chatgpt.com/", error ? error : ""));
}

static void browser_loaded(WebKitWebView *view, WebKitLoadEvent event, gpointer data) {
  (void)view; (void)data;
  bridge_browser_snapshot(event == WEBKIT_LOAD_FINISHED ? "active" : "loading", NULL);
}

static gboolean browser_failed(WebKitWebView *view, WebKitLoadEvent event,
                               const gchar *uri, GError *error, gpointer data) {
  (void)view; (void)event; (void)uri; (void)data;
  bridge_browser_snapshot("failed", error->message);
  return FALSE;
}

static gboolean browser_tls_failed(WebKitWebView *view, const gchar *uri,
                                   GTlsCertificate *certificate,
                                   GTlsCertificateFlags errors, gpointer data) {
  (void)view; (void)uri; (void)certificate; (void)errors; (void)data;
  bridge_browser_snapshot("failed", "聊天页的 TLS 证书验证失败。");
  return FALSE;
}

static WebKitWebView *browser_new_window(WebKitWebView *view,
                                        WebKitNavigationAction *action, gpointer data) {
  (void)view; (void)data;
  WebKitURIRequest *request = webkit_navigation_action_get_request(action);
  bridge_linux_open_uri(webkit_uri_request_get_uri(request));
  return NULL;
}

static gboolean browser_policy(WebKitWebView *view, WebKitPolicyDecision *decision,
                               WebKitPolicyDecisionType type, gpointer data) {
  (void)view; (void)data;
  if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) return FALSE;
  WebKitNavigationPolicyDecision *navigation = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
  const gchar *uri = webkit_uri_request_get_uri(
      webkit_navigation_policy_decision_get_request(navigation));
  if (uri && (g_str_has_prefix(uri, "https://") || g_str_has_prefix(uri, "http://") ||
              g_str_equal(uri, "about:blank"))) return FALSE;
  webkit_policy_decision_ignore(decision);
  return TRUE;
}

void bridge_connect_browser(void) {
  g_signal_connect(bridge_desktop.browser, "load-changed", G_CALLBACK(browser_loaded), NULL);
  g_signal_connect(bridge_desktop.browser, "load-failed", G_CALLBACK(browser_failed), NULL);
  g_signal_connect(bridge_desktop.browser, "load-failed-with-tls-errors", G_CALLBACK(browser_tls_failed), NULL);
  g_signal_connect(bridge_desktop.browser, "create", G_CALLBACK(browser_new_window), NULL);
  g_signal_connect(bridge_desktop.browser, "decide-policy", G_CALLBACK(browser_policy), NULL);
}

static gboolean browser_action_idle(gpointer value) {
  switch (GPOINTER_TO_INT(value)) {
    case 0: webkit_web_view_go_back(bridge_desktop.browser); break;
    case 1: webkit_web_view_go_forward(bridge_desktop.browser); break;
    case 2: webkit_web_view_reload(bridge_desktop.browser); break;
  }
  return G_SOURCE_REMOVE;
}
void bridge_linux_browser_action(int action) { g_idle_add(browser_action_idle, GINT_TO_POINTER(action)); }

typedef struct { gint x, y, width, height; gboolean visible; } Viewport;

static void apply_viewport(void) {
  gtk_fixed_move(GTK_FIXED(bridge_desktop.layout), GTK_WIDGET(bridge_desktop.browser),
                 bridge_desktop.browser_x, bridge_desktop.browser_y);
  gtk_widget_set_size_request(GTK_WIDGET(bridge_desktop.browser),
                              bridge_desktop.browser_width, bridge_desktop.browser_height);
  gtk_widget_set_visible(GTK_WIDGET(bridge_desktop.browser),
                         bridge_desktop.browser_visible && bridge_desktop.browser_enabled);
}

static gboolean viewport_idle(gpointer raw) {
  Viewport *value = raw;
  bridge_desktop.browser_x = value->x; bridge_desktop.browser_y = value->y;
  bridge_desktop.browser_width = value->width; bridge_desktop.browser_height = value->height;
  bridge_desktop.browser_visible = value->visible;
  apply_viewport();
  g_free(value);
  return G_SOURCE_REMOVE;
}

void bridge_linux_browser_viewport(double x, double y, double width, double height, int visible) {
  Viewport *value = g_new0(Viewport, 1);
  value->x = (gint)x; value->y = (gint)y;
  value->width = MAX(1, (gint)width); value->height = MAX(1, (gint)height);
  value->visible = visible;
  g_idle_add(viewport_idle, value);
}

static gboolean browser_enabled_idle(gpointer raw) {
  bridge_desktop.browser_enabled = GPOINTER_TO_INT(raw);
  apply_viewport();
  return G_SOURCE_REMOVE;
}
void bridge_linux_browser_enabled(int enabled) { g_idle_add(browser_enabled_idle, GINT_TO_POINTER(enabled)); }
