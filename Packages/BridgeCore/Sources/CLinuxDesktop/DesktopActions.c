#include "DesktopInternal.h"

static gboolean copy_idle(gpointer text) {
  GtkClipboard *clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  gtk_clipboard_set_text(clipboard, text, -1);
  gtk_clipboard_store(clipboard);
  g_free(text);
  return G_SOURCE_REMOVE;
}
void bridge_linux_copy(const char *text) { g_idle_add(copy_idle, g_strdup(text)); }

gboolean bridge_open_uri_idle(gpointer raw) {
  const gchar *uri = raw;
  if (g_str_has_prefix(uri, "https://") || g_str_has_prefix(uri, "http://"))
    g_app_info_launch_default_for_uri(uri, NULL, NULL);
  g_free(raw);
  return G_SOURCE_REMOVE;
}
void bridge_linux_open_uri(const char *uri) { g_idle_add(bridge_open_uri_idle, g_strdup(uri)); }

typedef struct { gchar *id; gchar *title; gboolean directory; } FileRequest;

static void file_response(GtkDialog *dialog, gint response, gpointer raw) {
  FileRequest *request = raw;
  gchar *path = response == GTK_RESPONSE_ACCEPT
      ? gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog)) : NULL;
  bridge_push_event(g_strdup_printf("file\n%s\n%s", request->id, path ? path : ""));
  gtk_widget_destroy(GTK_WIDGET(dialog));
  g_free(path); g_free(request->id); g_free(request->title); g_free(request);
}

static gboolean choose_file_idle(gpointer raw) {
  FileRequest *request = raw;
  GtkWidget *dialog = gtk_file_chooser_dialog_new(request->title,
      GTK_WINDOW(bridge_desktop.window),
      request->directory ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER : GTK_FILE_CHOOSER_ACTION_OPEN,
      "取消", GTK_RESPONSE_CANCEL, "选择", GTK_RESPONSE_ACCEPT, NULL);
  gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
  g_signal_connect(dialog, "response", G_CALLBACK(file_response), request);
  gtk_widget_show(dialog);
  return G_SOURCE_REMOVE;
}

void bridge_linux_choose_file(const char *request_id, const char *title, int directory) {
  FileRequest *request = g_new0(FileRequest, 1);
  request->id = g_strdup(request_id); request->title = g_strdup(title);
  request->directory = directory;
  g_idle_add(choose_file_idle, request);
}
