#include "DesktopInternal.h"

static void browser_snapshot(BridgeBrowser *browser) {
  const gchar *uri = webkit_web_view_get_uri(browser->view);
  bridge_push_event(g_strdup_printf("browser\n%s\n%s\n%d\n%d\n%s\n%s",
      browser->site, browser->state,
      webkit_web_view_can_go_back(browser->view),
      webkit_web_view_can_go_forward(browser->view),
      uri ? uri : browser->home, browser->error ? browser->error : ""));
}

static void browser_state(BridgeBrowser *browser, const gchar *state, const gchar *error) {
  browser->state = state;
  g_free(browser->error);
  browser->error = g_strdup(error);
  browser_snapshot(browser);
}

static void browser_loaded(WebKitWebView *view, WebKitLoadEvent event, gpointer data) {
  (void)view;
  BridgeBrowser *browser = data;
  if (event != WEBKIT_LOAD_STARTED && g_str_equal(browser->state, "failed")) return;
  browser_state(browser, event == WEBKIT_LOAD_FINISHED ? "active" : "loading", NULL);
}

static void browser_uri_changed(WebKitWebView *view, GParamSpec *property, gpointer data) {
  (void)view; (void)property;
  browser_snapshot(data);
}

static gboolean browser_failed(WebKitWebView *view, WebKitLoadEvent event,
                               const gchar *uri, GError *error, gpointer data) {
  (void)view; (void)event; (void)uri;
  if (!g_error_matches(error, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED))
    browser_state(data, "failed", error->message);
  return FALSE;
}

static gboolean browser_tls_failed(WebKitWebView *view, const gchar *uri,
                                   GTlsCertificate *certificate,
                                   GTlsCertificateFlags errors, gpointer data) {
  (void)view; (void)uri; (void)certificate; (void)errors;
  browser_state(data, "failed", "聊天页的 TLS 证书验证失败。");
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

static void connect_browser(BridgeBrowser *browser) {
  g_signal_connect(browser->view, "notify::uri", G_CALLBACK(browser_uri_changed), browser);
  g_signal_connect(browser->view, "load-changed", G_CALLBACK(browser_loaded), browser);
  g_signal_connect(browser->view, "load-failed", G_CALLBACK(browser_failed), browser);
  g_signal_connect(browser->view, "load-failed-with-tls-errors", G_CALLBACK(browser_tls_failed), browser);
  g_signal_connect(browser->view, "create", G_CALLBACK(browser_new_window), browser);
  g_signal_connect(browser->view, "decide-policy", G_CALLBACK(browser_policy), browser);
}

static void apply_viewport(void) {
  for (guint i = 0; i < G_N_ELEMENTS(bridge_desktop.browsers); i++) {
    BridgeBrowser *browser = &bridge_desktop.browsers[i];
    if (!browser->view) continue;
    gboolean selected = browser == bridge_desktop.browser;
    if (selected) {
      gtk_fixed_move(GTK_FIXED(bridge_desktop.layout), GTK_WIDGET(browser->view),
                     bridge_desktop.browser_x, bridge_desktop.browser_y);
      gtk_widget_set_size_request(GTK_WIDGET(browser->view),
                                  MAX(1, bridge_desktop.browser_width),
                                  MAX(1, bridge_desktop.browser_height));
    }
    gtk_widget_set_visible(GTK_WIDGET(browser->view), selected &&
                           bridge_desktop.browser_visible && bridge_desktop.browser_enabled);
  }
}

typedef struct { gchar *site; gchar *uri; } BrowserSelection;

static gboolean browser_select_idle(gpointer raw) {
  BrowserSelection *selection = raw;
  gboolean gemini = g_str_equal(selection->site, "gemini");
  BridgeBrowser *browser = &bridge_desktop.browsers[gemini ? 1 : 0];
  if (!browser->view) {
    browser->site = gemini ? "gemini" : "chatgpt";
    browser->home = gemini ? "https://gemini.google.com/app" : "https://chatgpt.com/";
    browser->state = "loading";
    browser->view = bridge_make_view(bridge_desktop.data_root, gemini ? "Gemini" : "ChatGPT");
    gtk_fixed_put(GTK_FIXED(bridge_desktop.layout), GTK_WIDGET(browser->view), 0, 0);
    connect_browser(browser);
    webkit_web_view_load_uri(browser->view, selection->uri);
  }
  bridge_desktop.browser = browser;
  apply_viewport();
  browser_snapshot(browser);
  g_free(selection->site); g_free(selection->uri); g_free(selection);
  return G_SOURCE_REMOVE;
}

void bridge_linux_browser_select(const char *site, const char *resume_uri) {
  if (!site || !resume_uri || (!g_str_equal(site, "gemini") && !g_str_equal(site, "chatgpt"))) return;
  BrowserSelection *selection = g_new0(BrowserSelection, 1);
  selection->site = g_strdup(site); selection->uri = g_strdup(resume_uri);
  g_idle_add(browser_select_idle, selection);
}

static gboolean browser_action_idle(gpointer value) {
  if (!bridge_desktop.browser) return G_SOURCE_REMOVE;
  WebKitWebView *view = bridge_desktop.browser->view;
  switch (GPOINTER_TO_INT(value)) {
    case 0: webkit_web_view_go_back(view); break;
    case 1: webkit_web_view_go_forward(view); break;
    case 2: webkit_web_view_reload(view); break;
  }
  return G_SOURCE_REMOVE;
}
void bridge_linux_browser_action(int action) { g_idle_add(browser_action_idle, GINT_TO_POINTER(action)); }

typedef struct { gint x, y, width, height; gboolean visible; } Viewport;

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
