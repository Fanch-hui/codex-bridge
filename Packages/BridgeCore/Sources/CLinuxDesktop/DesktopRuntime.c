#include "DesktopInternal.h"

BridgeDesktop bridge_desktop;
static GMutex state_lock;
static GCond startup_condition;
static GQueue events = G_QUEUE_INIT;
static gboolean running, startup_done, startup_success;

typedef struct { gchar *page; gchar *data; } StartOptions;

void bridge_push_event(gchar *event) {
  g_mutex_lock(&state_lock);
  g_queue_push_tail(&events, event);
  g_mutex_unlock(&state_lock);
}

char *bridge_linux_next_event(void) {
  g_mutex_lock(&state_lock);
  gchar *event = g_queue_pop_head(&events);
  g_mutex_unlock(&state_lock);
  return event;
}

void bridge_linux_free(void *value) { g_free(value); }

int bridge_linux_running(void) {
  g_mutex_lock(&state_lock);
  gboolean value = running;
  g_mutex_unlock(&state_lock);
  return value;
}

static void open_desktop(void);

static gboolean close_window(GtkWidget *widget, GdkEvent *event, gpointer data) {
  (void)event; (void)data;
  if (!bridge_desktop.tray || !gtk_status_icon_is_embedded(bridge_desktop.tray)) {
    gtk_main_quit();
    return TRUE;
  }
  gtk_widget_hide(widget);
  if (bridge_desktop.desktop) {
    webkit_web_view_stop_loading(bridge_desktop.desktop);
    gtk_widget_destroy(GTK_WIDGET(bridge_desktop.desktop));
    bridge_desktop.desktop = NULL;
  }
  bridge_push_event(g_strdup("tray\nhidden"));
  return TRUE;
}

static void tray_open(GtkStatusIcon *icon, gpointer data) {
  (void)icon; (void)data;
  open_desktop();
}

static void tray_open_item(GtkMenuItem *item, gpointer data) {
  (void)item; (void)data;
  open_desktop();
}

static void tray_activity(GtkMenuItem *item, gpointer data) {
  (void)item; (void)data;
  open_desktop();
  bridge_push_event(g_strdup("tray\napprovals"));
}

static void tray_mode(GtkMenuItem *item, gpointer data) {
  (void)item; (void)data;
  bridge_push_event(g_strdup("tray\nmode"));
}

static void tray_gateway(GtkMenuItem *item, gpointer data) {
  (void)item; (void)data;
  bridge_push_event(g_strdup("tray\ngateway"));
}

static void tray_quit(GtkMenuItem *item, gpointer data) {
  (void)item; (void)data;
  gtk_main_quit();
}

static void tray_quit_completely(GtkMenuItem *item, gpointer data) {
  (void)item; (void)data;
  bridge_push_event(g_strdup("tray\nquit-completely"));
}

static void tray_add(GtkWidget *menu, const char *label, GCallback callback) {
  GtkWidget *item = gtk_menu_item_new_with_label(label);
  g_signal_connect(item, "activate", callback, NULL);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
}

static void tray_menu(GtkStatusIcon *icon, guint button, guint activate_time, gpointer data) {
  (void)data;
  GtkWidget *menu = gtk_menu_new();
  tray_add(menu, "打开管理", G_CALLBACK(tray_open_item));
  tray_add(menu, "待处理审批", G_CALLBACK(tray_activity));
  tray_add(menu, "暂停或恢复模型网关", G_CALLBACK(tray_gateway));
  tray_add(menu, "切换轻量 / 完整模式", G_CALLBACK(tray_mode));
  tray_add(menu, "退出应用程序", G_CALLBACK(tray_quit));
  tray_add(menu, "彻底退出并停止后台服务", G_CALLBACK(tray_quit_completely));
  g_signal_connect_swapped(menu, "selection-done", G_CALLBACK(gtk_widget_destroy), menu);
  gtk_widget_show_all(menu);
  gtk_menu_popup(GTK_MENU(menu), NULL, NULL, gtk_status_icon_position_menu, icon, button, activate_time);
}

static void desktop_message(WebKitUserContentManager *manager,
                            WebKitJavascriptResult *result, gpointer data) {
  (void)manager; (void)data;
  JSCValue *value = webkit_javascript_result_get_js_value(result);
  gchar *json = jsc_value_to_json(value, 0);
  if (json) bridge_push_event(g_strconcat("command\n", json, NULL));
  g_free(json);
}

static gboolean desktop_policy(WebKitWebView *view, WebKitPolicyDecision *decision,
                               WebKitPolicyDecisionType type, gpointer data) {
  (void)view; (void)data;
  if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION &&
      type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) return FALSE;
  WebKitNavigationPolicyDecision *navigation = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
  WebKitURIRequest *request = webkit_navigation_policy_decision_get_request(navigation);
  const gchar *uri = webkit_uri_request_get_uri(request);
  if (uri && g_str_has_prefix(uri, bridge_desktop.page_root) &&
      type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) return FALSE;
  webkit_policy_decision_ignore(decision);
  if (uri && (g_str_has_prefix(uri, "https://") || g_str_has_prefix(uri, "http://")))
    bridge_linux_open_uri(uri);
  return TRUE;
}

WebKitWebView *bridge_make_view(const gchar *data_root, const gchar *scope) {
  gchar *data = g_build_filename(data_root, scope, "data", NULL);
  gchar *cache = g_build_filename(data_root, scope, "cache", NULL);
  WebKitWebsiteDataManager *manager = webkit_website_data_manager_new(
      "base-data-directory", data, "base-cache-directory", cache, NULL);
  gchar *cookies = g_build_filename(data_root, scope, "cookies.sqlite", NULL);
  webkit_cookie_manager_set_persistent_storage(
      webkit_website_data_manager_get_cookie_manager(manager), cookies,
      WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
  g_free(cookies);
  WebKitWebContext *context = webkit_web_context_new_with_website_data_manager(manager);
  WebKitWebView *view = WEBKIT_WEB_VIEW(webkit_web_view_new_with_context(context));
  g_object_unref(context); g_object_unref(manager);
  g_free(data); g_free(cache);
  WebKitSettings *settings = webkit_web_view_get_settings(view);
  webkit_settings_set_enable_developer_extras(settings, FALSE);
  return view;
}

static void open_desktop(void) {
  if (!bridge_desktop.desktop) {
    bridge_desktop.desktop = bridge_make_view(bridge_desktop.data_root, "Desktop");
    gtk_container_add(GTK_CONTAINER(bridge_desktop.overlay), GTK_WIDGET(bridge_desktop.desktop));
    gtk_widget_set_hexpand(GTK_WIDGET(bridge_desktop.desktop), TRUE);
    gtk_widget_set_vexpand(GTK_WIDGET(bridge_desktop.desktop), TRUE);
    WebKitUserContentManager *content =
        webkit_web_view_get_user_content_manager(bridge_desktop.desktop);
    g_signal_connect(content, "script-message-received::bridgeDesktopUI", G_CALLBACK(desktop_message), NULL);
    webkit_user_content_manager_register_script_message_handler(content, "bridgeDesktopUI");
    g_signal_connect(bridge_desktop.desktop, "decide-policy", G_CALLBACK(desktop_policy), NULL);
    webkit_web_view_load_uri(bridge_desktop.desktop, bridge_desktop.page_uri);
  }
  gtk_widget_show_all(bridge_desktop.window);
  gtk_window_present(GTK_WINDOW(bridge_desktop.window));
  bridge_push_event(g_strdup("tray\nvisible"));
}

static gpointer desktop_thread(gpointer raw) {
  StartOptions *options = raw;
  gboolean initialized = gtk_init_check(NULL, NULL);
  if (initialized) {
    bridge_desktop.window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(bridge_desktop.window), "Codex Bridge");
    gtk_window_set_default_size(GTK_WINDOW(bridge_desktop.window), 1280, 820);
    gtk_widget_set_size_request(bridge_desktop.window, 860, 600);
    bridge_desktop.overlay = gtk_overlay_new();
    gtk_container_add(GTK_CONTAINER(bridge_desktop.window), bridge_desktop.overlay);
    bridge_desktop.layout = gtk_fixed_new();
    gtk_overlay_add_overlay(GTK_OVERLAY(bridge_desktop.overlay), bridge_desktop.layout);
    gtk_overlay_set_overlay_pass_through(GTK_OVERLAY(bridge_desktop.overlay), bridge_desktop.layout, TRUE);
    bridge_desktop.data_root = g_strdup(options->data);
    bridge_desktop.page_uri = g_strdup(options->page);
    gchar *slash = strrchr(options->page, '/');
    bridge_desktop.page_root = g_strndup(options->page, slash ? slash - options->page + 1 : 0);
    g_signal_connect(bridge_desktop.window, "delete-event", G_CALLBACK(close_window), NULL);
    bridge_desktop.tray = gtk_status_icon_new_from_icon_name("applications-system");
    gtk_status_icon_set_tooltip_text(bridge_desktop.tray, "Codex Bridge");
    g_signal_connect(bridge_desktop.tray, "activate", G_CALLBACK(tray_open), NULL);
    g_signal_connect(bridge_desktop.tray, "popup-menu", G_CALLBACK(tray_menu), NULL);
    gtk_status_icon_set_visible(bridge_desktop.tray, TRUE);
    open_desktop();
  }
  g_free(options->page); g_free(options->data); g_free(options);
  g_mutex_lock(&state_lock);
  running = startup_success = initialized;
  startup_done = TRUE;
  g_cond_signal(&startup_condition);
  g_mutex_unlock(&state_lock);
  if (initialized) {
    gtk_main();
    gtk_status_icon_set_visible(bridge_desktop.tray, FALSE);
    g_clear_object(&bridge_desktop.tray);
    gtk_widget_destroy(bridge_desktop.window);
    g_free(bridge_desktop.page_uri);
    g_free(bridge_desktop.page_root);
    g_free(bridge_desktop.data_root);
    for (guint i = 0; i < G_N_ELEMENTS(bridge_desktop.browsers); i++) {
      g_free(bridge_desktop.browsers[i].resume_uri);
      g_free(bridge_desktop.browsers[i].error);
    }
  }
  g_mutex_lock(&state_lock);
  running = FALSE;
  g_mutex_unlock(&state_lock);
  return NULL;
}

int bridge_linux_start(const char *page_uri, const char *data_root) {
  StartOptions *options = g_new0(StartOptions, 1);
  options->page = g_strdup(page_uri); options->data = g_strdup(data_root);
  g_mutex_lock(&state_lock);
  GThread *thread = g_thread_new("BridgeGTK", desktop_thread, options);
  g_thread_unref(thread);
  while (!startup_done) g_cond_wait(&startup_condition, &state_lock);
  gboolean success = startup_success;
  g_mutex_unlock(&state_lock);
  return success;
}

static gboolean script_idle(gpointer value) {
  if (bridge_desktop.desktop)
    webkit_web_view_evaluate_javascript(bridge_desktop.desktop, value, -1, NULL, NULL, NULL, NULL, NULL);
  g_free(value);
  return G_SOURCE_REMOVE;
}
void bridge_linux_script(const char *script) { g_idle_add(script_idle, g_strdup(script)); }

static gboolean show_idle(gpointer value) {
  (void)value;
  open_desktop();
  return G_SOURCE_REMOVE;
}
void bridge_linux_show(void) { g_idle_add(show_idle, NULL); }

static gboolean stop_idle(gpointer value) {
  (void)value;
  gtk_main_quit();
  return G_SOURCE_REMOVE;
}
void bridge_linux_stop(void) { g_idle_add(stop_idle, NULL); }
