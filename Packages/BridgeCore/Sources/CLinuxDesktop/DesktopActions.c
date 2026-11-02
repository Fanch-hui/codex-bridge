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

typedef struct { gchar *id; gchar *title; gchar *suggested; gboolean directory; gboolean save; } FileRequest;

static void file_response(GtkDialog *dialog, gint response, gpointer raw) {
  FileRequest *request = raw;
  gchar *path = response == GTK_RESPONSE_ACCEPT
      ? gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog)) : NULL;
  bridge_push_event(g_strdup_printf("file\n%s\n%s", request->id, path ? path : ""));
  gtk_widget_destroy(GTK_WIDGET(dialog));
  g_free(path); g_free(request->id); g_free(request->title); g_free(request->suggested); g_free(request);
}

static gboolean choose_file_idle(gpointer raw) {
  FileRequest *request = raw;
  GtkFileChooserAction action = GTK_FILE_CHOOSER_ACTION_OPEN;
  if (request->save) action = GTK_FILE_CHOOSER_ACTION_SAVE;
  else if (request->directory) action = GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER;
  GtkWidget *dialog = gtk_file_chooser_dialog_new(request->title,
      GTK_WINDOW(bridge_desktop.window), action,
      "取消", GTK_RESPONSE_CANCEL, request->save ? "保存" : "选择", GTK_RESPONSE_ACCEPT, NULL);
  if (request->save) {
    gtk_file_chooser_set_do_overwrite_confirmation(GTK_FILE_CHOOSER(dialog), TRUE);
    gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(dialog), request->suggested);
  }
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

void bridge_linux_save_file(const char *request_id, const char *title, const char *suggested) {
  FileRequest *request = g_new0(FileRequest, 1);
  request->id = g_strdup(request_id); request->title = g_strdup(title);
  request->suggested = g_strdup(suggested); request->save = TRUE;
  g_idle_add(choose_file_idle, request);
}
