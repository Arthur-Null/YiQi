// C1, C2, C3, C5, C6, C7: Linux 原生 GTK3 设置窗口与系统托盘（StatusNotifierItem + DBusMenu），通过本地 socket 与 yiqi 守护进程通信。
#define _POSIX_C_SOURCE 200809L
#include <gtk/gtk.h>
#include <gio/gio.h>
#include <gdk/gdkkeysyms.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

typedef struct {
    char version[64];
    char scheme[64];
    char hotkey_label[128];
    gboolean is_default_key;
    char status[32];
    char status_label[256];
    char server_host[256];
    gboolean paired;
    char invite_code[32];
    int invite_left;
    char message[512];
    gboolean busy;
    char update_version[64];
    char update_message[512];
    gboolean beta;
    char framework[32];
} YiQiState;

static YiQiState g_state;
static GtkApplication *g_app = NULL;
static GtkWidget *g_win = NULL;
static gboolean g_recording = FALSE;
static gboolean g_tray_mode = FALSE;
static gboolean g_suppress_scheme = FALSE;
static GDBusConnection *g_bus = NULL;
static guint g_sni_reg = 0;
static guint g_menu_reg = 0;
static guint32 g_menu_rev = 1;

static GtkWidget *w_upd_box, *w_upd_label, *w_upd_btn, *w_upd_msg;
static GtkWidget *w_im_hint;
static GtkWidget *w_btn_flypy, *w_btn_quanpin;
static GtkWidget *w_hk_btn, *w_hk_reset;
static GtkWidget *w_dot, *w_status_lbl, *w_host_lbl;
static GtkWidget *w_paired_box, *w_invite_box, *w_unpaired_box;
static GtkWidget *w_inv_host, *w_inv_code, *w_inv_timer;
static GtkWidget *w_srv_entry, *w_code_entry, *w_btn_join, *w_btn_reg;
static GtkWidget *w_msg_lbl;
static GtkWidget *w_ver_lbl, *w_check_msg, *w_beta_chk;

static void get_socket_path(char *buf, size_t len) {
    const char *xdg = getenv("XDG_RUNTIME_DIR");
    if (xdg && *xdg) {
        snprintf(buf, len, "%s/yiqi.sock", xdg);
    } else {
        snprintf(buf, len, "/tmp/yiqi.sock");
    }
}

static void json_escape(const char *src, char *dst, size_t dst_len) {
    size_t j = 0;
    for (size_t i = 0; src && src[i] && j + 6 < dst_len; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c == '"' || c == '\\') {
            dst[j++] = '\\';
            dst[j++] = (char)c;
        } else if (c == '\n') {
            dst[j++] = '\\';
            dst[j++] = 'n';
        } else if (c >= 0x20) {
            dst[j++] = (char)c;
        }
    }
    dst[j] = '\0';
}

static gboolean json_get_str(const char *json, const char *key, char *out, size_t out_len) {
    char pat[128];
    snprintf(pat, sizeof(pat), "\"%s\":\"", key);
    const char *p = strstr(json, pat);
    if (!p) {
        out[0] = '\0';
        return FALSE;
    }
    p += strlen(pat);
    size_t j = 0;
    while (*p && *p != '"' && j + 1 < out_len) {
        if (*p == '\\' && p[1]) {
            p++;
            if (*p == 'n') out[j++] = '\n';
            else out[j++] = *p;
        } else {
            out[j++] = *p;
        }
        p++;
    }
    out[j] = '\0';
    return TRUE;
}

static gboolean json_get_bool(const char *json, const char *key) {
    char pat[128];
    snprintf(pat, sizeof(pat), "\"%s\":true", key);
    return strstr(json, pat) != NULL;
}

static int json_get_int(const char *json, const char *key) {
    char pat[128];
    snprintf(pat, sizeof(pat), "\"%s\":", key);
    const char *p = strstr(json, pat);
    if (!p) return 0;
    return atoi(p + strlen(pat));
}

static gboolean rpc_call(const char *req_json) {
    char path[104];
    get_socket_path(path, sizeof(path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return FALSE;

    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return FALSE;
    }

    size_t n = strlen(req_json);
    if (write(fd, req_json, n) < 0 || write(fd, "\n", 1) < 0) {
        close(fd);
        return FALSE;
    }

    char buf[8192];
    size_t total = 0;
    while (total + 1 < sizeof(buf)) {
        ssize_t r = read(fd, buf + total, sizeof(buf) - 1 - total);
        if (r <= 0) break;
        total += (size_t)r;
        if (memchr(buf, '\n', total)) break;
    }
    close(fd);
    buf[total] = '\0';
    if (total == 0) return FALSE;

    json_get_str(buf, "version", g_state.version, sizeof(g_state.version));
    json_get_str(buf, "scheme", g_state.scheme, sizeof(g_state.scheme));
    json_get_str(buf, "label", g_state.hotkey_label, sizeof(g_state.hotkey_label));
    g_state.is_default_key = json_get_bool(buf, "is_default_key");
    json_get_str(buf, "status", g_state.status, sizeof(g_state.status));
    json_get_str(buf, "status_label", g_state.status_label, sizeof(g_state.status_label));
    json_get_str(buf, "server_host", g_state.server_host, sizeof(g_state.server_host));
    g_state.paired = json_get_bool(buf, "paired");
    json_get_str(buf, "invite_code", g_state.invite_code, sizeof(g_state.invite_code));
    g_state.invite_left = json_get_int(buf, "invite_left");
    json_get_str(buf, "message", g_state.message, sizeof(g_state.message));
    g_state.busy = json_get_bool(buf, "busy");
    json_get_str(buf, "update_version", g_state.update_version, sizeof(g_state.update_version));
    json_get_str(buf, "update_message", g_state.update_message, sizeof(g_state.update_message));
    g_state.beta = json_get_bool(buf, "beta");
    json_get_str(buf, "framework", g_state.framework, sizeof(g_state.framework));
    return TRUE;
}

static void refresh_ui(void);
static void open_settings_window(void);

static void emit_menu_updated(void) {
    if (!g_bus) return;
    g_menu_rev++;
    g_dbus_connection_emit_signal(
        g_bus, NULL, "/MenuBar", "com.canonical.dbusmenu", "LayoutUpdated",
        g_variant_new("(ui)", g_menu_rev, 0), NULL);
}

static void refresh_ui(void) {
    if (!g_win) return;

    gboolean has_upd = g_state.update_version[0] != '\0';
    gtk_widget_set_visible(w_upd_box, has_upd);
    if (has_upd) {
        char t[256];
        snprintf(t, sizeof(t), "有新版本 %s（当前 %s）", g_state.update_version, g_state.version);
        gtk_label_set_text(GTK_LABEL(w_upd_label), t);
        gtk_label_set_text(GTK_LABEL(w_upd_msg), g_state.update_message);
        gtk_widget_set_visible(w_upd_msg, g_state.update_message[0] != '\0');
    }

    gtk_widget_set_visible(w_im_hint, g_state.framework[0] == '\0');

    g_suppress_scheme = TRUE;
    gboolean is_qp = strcmp(g_state.scheme, "rime_frost") == 0;
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(w_btn_flypy), !is_qp);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(w_btn_quanpin), is_qp);
    g_suppress_scheme = FALSE;

    if (g_recording) {
        gtk_button_set_label(GTK_BUTTON(w_hk_btn), "请按下新的快捷键…（Esc 取消）");
    } else {
        gtk_button_set_label(GTK_BUTTON(w_hk_btn), g_state.hotkey_label[0] ? g_state.hotkey_label : "Ctrl + Shift + 1");
    }
    gtk_widget_set_visible(w_hk_reset, !g_recording && !g_state.is_default_key);

    const char *color = "#E68A00";
    if (strcmp(g_state.status, "connected") == 0) color = "#52B17F";
    else if (strcmp(g_state.status, "unpaired") == 0) color = "#8E8E93";
    char dot_markup[128];
    snprintf(dot_markup, sizeof(dot_markup), "<span foreground=\"%s\">●</span>", color);
    gtk_label_set_markup(GTK_LABEL(w_dot), dot_markup);
    gtk_label_set_text(GTK_LABEL(w_status_lbl), g_state.status_label[0] ? g_state.status_label : "未配对");
    if (g_state.server_host[0]) {
        char hs[320];
        snprintf(hs, sizeof(hs), "服务器：%s", g_state.server_host);
        gtk_label_set_text(GTK_LABEL(w_host_lbl), hs);
        gtk_widget_set_visible(w_host_lbl, TRUE);
    } else {
        gtk_widget_set_visible(w_host_lbl, FALSE);
    }

    gboolean inviting = g_state.paired && g_state.invite_code[0] != '\0';
    gtk_widget_set_visible(w_paired_box, g_state.paired && !inviting);
    gtk_widget_set_visible(w_invite_box, inviting);
    gtk_widget_set_visible(w_unpaired_box, !g_state.paired);

    if (inviting) {
        char ih[320], ic[128], it[128];
        snprintf(ih, sizeof(ih), "服务器地址  %s", g_state.server_host);
        gtk_label_set_text(GTK_LABEL(w_inv_host), ih);
        if (strlen(g_state.invite_code) == 6) {
            snprintf(ic, sizeof(ic), "<span font_family=\"monospace\" size=\"xx-large\" weight=\"bold\">%.3s %.3s</span>",
                     g_state.invite_code, g_state.invite_code + 3);
            gtk_label_set_markup(GTK_LABEL(w_inv_code), ic);
        }
        if (g_state.invite_left > 0) {
            snprintf(it, sizeof(it), "%d:%02d 内有效，请保持此窗口打开", g_state.invite_left / 60, g_state.invite_left % 60);
        } else {
            snprintf(it, sizeof(it), "已过期，请重新生成");
        }
        gtk_label_set_text(GTK_LABEL(w_inv_timer), it);
    }

    gtk_widget_set_sensitive(w_btn_join, !g_state.busy);
    gtk_widget_set_sensitive(w_btn_reg, !g_state.busy);
    gtk_label_set_text(GTK_LABEL(w_msg_lbl), g_state.message);
    gtk_widget_set_visible(w_msg_lbl, g_state.message[0] != '\0');

    char ver[128];
    snprintf(ver, sizeof(ver), "版本 %s", g_state.version[0] ? g_state.version : "");
    gtk_label_set_text(GTK_LABEL(w_ver_lbl), ver);
    gtk_label_set_text(GTK_LABEL(w_check_msg), has_upd ? "" : g_state.update_message);
    if (gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(w_beta_chk)) != g_state.beta)
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(w_beta_chk), g_state.beta);
}

static gboolean on_poll_timer(gpointer data) {
    (void)data;
    char prev_scheme[64], prev_upd[64];
    snprintf(prev_scheme, sizeof(prev_scheme), "%s", g_state.scheme);
    snprintf(prev_upd, sizeof(prev_upd), "%s", g_state.update_version);
    if (rpc_call("{\"cmd\":\"state\"}")) {
        refresh_ui();
        if (strcmp(prev_scheme, g_state.scheme) != 0 || strcmp(prev_upd, g_state.update_version) != 0) {
            emit_menu_updated();
        }
    }
    return G_SOURCE_CONTINUE;
}

static void on_scheme_toggled(GtkToggleButton *btn, gpointer user_data) {
    if (g_suppress_scheme || !gtk_toggle_button_get_active(btn)) return;
    const char *sc = (const char *)user_data;
    char req[128];
    snprintf(req, sizeof(req), "{\"cmd\":\"set_scheme\",\"scheme\":\"%s\"}", sc);
    rpc_call(req);
    refresh_ui();
    emit_menu_updated();
}

static void on_record_clicked(GtkButton *b, gpointer d) {
    (void)b; (void)d;
    g_recording = !g_recording;
    refresh_ui();
}

static void on_reset_hk_clicked(GtkButton *b, gpointer d) {
    (void)b; (void)d;
    g_recording = FALSE;
    rpc_call("{\"cmd\":\"reset_hotkey\"}");
    refresh_ui();
    emit_menu_updated();
}

static gboolean on_key_press(GtkWidget *w, GdkEventKey *ev, gpointer d) {
    (void)w; (void)d;
    if (!g_recording) return FALSE;
    if (ev->keyval == GDK_KEY_Escape) {
        g_recording = FALSE;
        refresh_ui();
        return TRUE;
    }
    if (ev->is_modifier) return TRUE;
    const char *sym = gdk_keyval_name(ev->keyval);
    if (!sym) return TRUE;
    gboolean ctrl = (ev->state & GDK_CONTROL_MASK) != 0;
    gboolean alt = (ev->state & GDK_MOD1_MASK) != 0;
    gboolean shift = (ev->state & GDK_SHIFT_MASK) != 0;
    char esc[128], req[384];
    json_escape(sym, esc, sizeof(esc));
    snprintf(req, sizeof(req), "{\"cmd\":\"set_hotkey\",\"sym\":\"%s\",\"ctrl\":%s,\"alt\":%s,\"shift\":%s}",
             esc, ctrl ? "true" : "false", alt ? "true" : "false", shift ? "true" : "false");
    rpc_call(req);
    g_recording = FALSE;
    refresh_ui();
    emit_menu_updated();
    return TRUE;
}

static void on_pair_clicked(GtkButton *b, gpointer user_data) {
    (void)b;
    const char *cmd = (const char *)user_data;
    const char *srv = gtk_entry_get_text(GTK_ENTRY(w_srv_entry));
    const char *code = gtk_entry_get_text(GTK_ENTRY(w_code_entry));
    char es[512], ec[128], req[1024];
    json_escape(srv, es, sizeof(es));
    json_escape(code, ec, sizeof(ec));
    snprintf(req, sizeof(req), "{\"cmd\":\"%s\",\"server\":\"%s\",\"code\":\"%s\"}", cmd, es, ec);
    rpc_call(req);
    refresh_ui();
}

static void on_simple_cmd(GtkButton *b, gpointer user_data) {
    (void)b;
    rpc_call((const char *)user_data);
    refresh_ui();
}

static void on_beta_toggled(GtkToggleButton *b, gpointer d) {
    (void)d;
    gboolean on = gtk_toggle_button_get_active(b);
    if (on == g_state.beta) return;
    rpc_call(on ? "{\"cmd\":\"set_beta\",\"beta\":true}" : "{\"cmd\":\"set_beta\"}");
    refresh_ui();
}

static void on_leave_clicked(GtkButton *b, gpointer d) {
    (void)b; (void)d;
    GtkWidget *dlg = gtk_message_dialog_new(
        GTK_WINDOW(g_win), GTK_DIALOG_MODAL, GTK_MESSAGE_QUESTION, GTK_BUTTONS_OK_CANCEL,
        "让这台电脑退出同步组？");
    gtk_message_dialog_format_secondary_text(
        GTK_MESSAGE_DIALOG(dlg), "之后需要在其他已同步的设备上点「添加设备」才能重新加入。");
    int r = gtk_dialog_run(GTK_DIALOG(dlg));
    gtk_widget_destroy(dlg);
    if (r == GTK_RESPONSE_OK) {
        rpc_call("{\"cmd\":\"leave\"}");
        refresh_ui();
    }
}

static gboolean on_win_delete(GtkWidget *w, GdkEvent *e, gpointer d) {
    (void)e; (void)d;
    rpc_call("{\"cmd\":\"stop_invite\"}");
    if (g_tray_mode) {
        gtk_widget_hide(w);
        return TRUE;
    }
    return FALSE;
}

static GtkWidget *make_note(const char *txt) {
    GtkWidget *l = gtk_label_new(txt);
    gtk_label_set_line_wrap(GTK_LABEL(l), TRUE);
    gtk_label_set_xalign(GTK_LABEL(l), 0.0f);
    gtk_style_context_add_class(gtk_widget_get_style_context(l), "dim-label");
    return l;
}

static void build_window(void) {
    g_win = gtk_application_window_new(g_app);
    gtk_window_set_title(GTK_WINDOW(g_win), "一炁输入法");
    gtk_window_set_default_size(GTK_WINDOW(g_win), 560, -1);
    gtk_window_set_resizable(GTK_WINDOW(g_win), FALSE);
    gtk_window_set_position(GTK_WINDOW(g_win), GTK_WIN_POS_CENTER);
    g_signal_connect(g_win, "delete-event", G_CALLBACK(on_win_delete), NULL);
    g_signal_connect(g_win, "key-press-event", G_CALLBACK(on_key_press), NULL);

    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
    gtk_container_set_border_width(GTK_CONTAINER(root), 18);
    gtk_container_add(GTK_CONTAINER(g_win), root);

    // 更新横幅
    w_upd_box = gtk_frame_new(NULL);
    GtkWidget *ub = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_container_set_border_width(GTK_CONTAINER(ub), 10);
    GtkWidget *ur = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    w_upd_label = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(w_upd_label), 0.0f);
    w_upd_btn = gtk_button_new_with_label("下载并安装");
    g_signal_connect(w_upd_btn, "clicked", G_CALLBACK(on_simple_cmd), "{\"cmd\":\"install_update\"}");
    gtk_box_pack_start(GTK_BOX(ur), w_upd_label, TRUE, TRUE, 0);
    gtk_box_pack_end(GTK_BOX(ur), w_upd_btn, FALSE, FALSE, 0);
    w_upd_msg = make_note("");
    gtk_box_pack_start(GTK_BOX(ub), ur, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(ub), w_upd_msg, FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(w_upd_box), ub);
    gtk_box_pack_start(GTK_BOX(root), w_upd_box, FALSE, FALSE, 0);

    // C2: 输入方式区域
    GtkWidget *sf = gtk_frame_new("输入方式");
    GtkWidget *sb = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_container_set_border_width(GTK_CONTAINER(sb), 12);

    w_im_hint = make_note("提示：请确认系统已安装并启用 Fcitx5（fcitx5-rime）或 IBus（ibus-rime）输入法。");
    gtk_box_pack_start(GTK_BOX(sb), w_im_hint, FALSE, FALSE, 0);

    GtkWidget *sr = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_style_context_add_class(gtk_widget_get_style_context(sr), "linked");
    w_btn_flypy = gtk_radio_button_new_with_label(NULL, "小鹤双拼");
    gtk_toggle_button_set_mode(GTK_TOGGLE_BUTTON(w_btn_flypy), FALSE);
    w_btn_quanpin = gtk_radio_button_new_with_label_from_widget(GTK_RADIO_BUTTON(w_btn_flypy), "全拼");
    gtk_toggle_button_set_mode(GTK_TOGGLE_BUTTON(w_btn_quanpin), FALSE);
    g_signal_connect(w_btn_flypy, "toggled", G_CALLBACK(on_scheme_toggled), "rime_frost_double_pinyin_flypy");
    g_signal_connect(w_btn_quanpin, "toggled", G_CALLBACK(on_scheme_toggled), "rime_frost");
    gtk_box_pack_start(GTK_BOX(sr), w_btn_flypy, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(sr), w_btn_quanpin, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(sb), sr, FALSE, FALSE, 0);

    GtkWidget *hr = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_pack_start(GTK_BOX(hr), gtk_label_new("切换快捷键"), FALSE, FALSE, 0);
    w_hk_btn = gtk_button_new_with_label("Ctrl + Shift + 1");
    w_hk_reset = gtk_button_new_with_label("恢复默认");
    g_signal_connect(w_hk_btn, "clicked", G_CALLBACK(on_record_clicked), NULL);
    g_signal_connect(w_hk_reset, "clicked", G_CALLBACK(on_reset_hk_clicked), NULL);
    gtk_box_pack_start(GTK_BOX(hr), w_hk_btn, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(hr), w_hk_reset, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(sb), hr, FALSE, FALSE, 0);

    gtk_box_pack_start(GTK_BOX(sb), make_note("快捷键需包含 Ctrl 或 Alt（F1–F12 可单独使用）。也可以点任务栏的一炁图标切换。"), FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(sf), sb);
    gtk_box_pack_start(GTK_BOX(root), sf, FALSE, FALSE, 0);

    // C3, C5, C7: 剪贴板同步区域
    GtkWidget *cf = gtk_frame_new("剪贴板同步");
    GtkWidget *cb = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_container_set_border_width(GTK_CONTAINER(cb), 12);

    GtkWidget *st_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    w_dot = gtk_label_new("●");
    w_status_lbl = gtk_label_new("未配对");
    w_host_lbl = make_note("");
    gtk_box_pack_start(GTK_BOX(st_row), w_dot, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(st_row), w_status_lbl, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(st_row), w_host_lbl, FALSE, FALSE, 8);
    gtk_box_pack_start(GTK_BOX(cb), st_row, FALSE, FALSE, 0);

    // 已配对视图
    w_paired_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    GtkWidget *pr = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *bi = gtk_button_new_with_label("添加设备…");
    GtkWidget *bl = gtk_button_new_with_label("退出同步组…");
    g_signal_connect(bi, "clicked", G_CALLBACK(on_simple_cmd), "{\"cmd\":\"start_invite\"}");
    g_signal_connect(bl, "clicked", G_CALLBACK(on_leave_clicked), NULL);
    gtk_box_pack_start(GTK_BOX(pr), bi, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(pr), bl, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(w_paired_box), pr, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(w_paired_box), make_note("要让手机或另一台电脑加入，点「添加设备」，会生成一个 6 位临时密码。"), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(cb), w_paired_box, FALSE, FALSE, 0);

    // 邀请视图
    w_invite_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_box_pack_start(GTK_BOX(w_invite_box), make_note("在新设备的一炁设置里填写："), FALSE, FALSE, 0);
    w_inv_host = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(w_inv_host), 0.0f);
    w_inv_code = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(w_inv_code), 0.0f);
    w_inv_timer = make_note("");
    GtkWidget *ir = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *bd = gtk_button_new_with_label("完成");
    GtkWidget *bg = gtk_button_new_with_label("重新生成");
    g_signal_connect(bd, "clicked", G_CALLBACK(on_simple_cmd), "{\"cmd\":\"stop_invite\"}");
    g_signal_connect(bg, "clicked", G_CALLBACK(on_simple_cmd), "{\"cmd\":\"start_invite\"}");
    gtk_box_pack_start(GTK_BOX(ir), bd, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(ir), bg, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(w_invite_box), w_inv_host, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(w_invite_box), w_inv_code, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(w_invite_box), w_inv_timer, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(w_invite_box), ir, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(cb), w_invite_box, FALSE, FALSE, 0);

    // 未配对视图
    w_unpaired_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 8);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 8);
    w_srv_entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(w_srv_entry), "例如 yiqi.example.com");
    gtk_widget_set_hexpand(w_srv_entry, TRUE);
    w_code_entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(w_code_entry), "6 位数字");
    gtk_entry_set_width_chars(GTK_ENTRY(w_code_entry), 12);
    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("服务器地址"), 0, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), w_srv_entry, 1, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("临时密码"), 0, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), w_code_entry, 1, 1, 1, 1);
    gtk_box_pack_start(GTK_BOX(w_unpaired_box), grid, FALSE, FALSE, 0);

    GtkWidget *jr = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    w_btn_join = gtk_button_new_with_label("加入同步组");
    g_signal_connect(w_btn_join, "clicked", G_CALLBACK(on_pair_clicked), "join");
    gtk_box_pack_start(GTK_BOX(jr), w_btn_join, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(jr), make_note("临时密码在已同步的设备上点「添加设备」获得。"), TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(w_unpaired_box), jr, FALSE, FALSE, 0);

    GtkWidget *rr = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    w_btn_reg = gtk_button_new_with_label("注册新同步组");
    g_signal_connect(w_btn_reg, "clicked", G_CALLBACK(on_pair_clicked), "register");
    gtk_box_pack_start(GTK_BOX(rr), w_btn_reg, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(rr), make_note("第一台设备用这个；临时密码在服务器上运行 yiqi-relay code 生成，10 分钟内有效。"), TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(w_unpaired_box), rr, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(cb), w_unpaired_box, FALSE, FALSE, 0);

    w_msg_lbl = make_note("");
    gtk_box_pack_start(GTK_BOX(cb), w_msg_lbl, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(cb), make_note("复制的文字会在本机加密后，经你的服务器同步到同组的其他设备，在那里直接粘贴即可。"), FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(cf), cb);
    gtk_box_pack_start(GTK_BOX(root), cf, FALSE, FALSE, 0);

    // 底部版本与手动检查更新
    GtkWidget *foot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    w_check_msg = make_note("");
    w_ver_lbl = make_note("");
    GtkWidget *chk_btn = gtk_button_new_with_label("检查更新");
    g_signal_connect(chk_btn, "clicked", G_CALLBACK(on_simple_cmd), "{\"cmd\":\"check_update\",\"manual\":true}");
    w_beta_chk = gtk_check_button_new_with_label("接受测试版更新");
    g_signal_connect(w_beta_chk, "toggled", G_CALLBACK(on_beta_toggled), NULL);
    gtk_box_pack_start(GTK_BOX(foot), w_beta_chk, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(foot), w_check_msg, TRUE, TRUE, 0);
    gtk_box_pack_end(GTK_BOX(foot), chk_btn, FALSE, FALSE, 0);
    gtk_box_pack_end(GTK_BOX(foot), w_ver_lbl, FALSE, FALSE, 4);
    gtk_box_pack_start(GTK_BOX(root), foot, FALSE, FALSE, 0);
}

static void open_settings_window(void) {
    if (!g_win) build_window();
    rpc_call("{\"cmd\":\"check_update\",\"manual\":false}");
    gtk_widget_show_all(g_win);
    refresh_ui();
    gtk_window_present(GTK_WINDOW(g_win));
}

// C2, C6: 通过标准 DBus StatusNotifierItem + DBusMenu 提供跨桌面（GNOME/KDE/XFCE/Waybar）托盘图标与菜单。
static const char *sni_xml =
    "<node>"
    "  <interface name='org.kde.StatusNotifierItem'>"
    "    <property name='Category' type='s' access='read'/>"
    "    <property name='Id' type='s' access='read'/>"
    "    <property name='Title' type='s' access='read'/>"
    "    <property name='Status' type='s' access='read'/>"
    "    <property name='IconName' type='s' access='read'/>"
    "    <property name='Menu' type='o' access='read'/>"
    "    <property name='ItemIsMenu' type='b' access='read'/>"
    "    <method name='Activate'><arg type='i' name='x' direction='in'/><arg type='i' name='y' direction='in'/></method>"
    "  </interface>"
    "</node>";

static const char *menu_xml =
    "<node>"
    "  <interface name='com.canonical.dbusmenu'>"
    "    <property name='Version' type='u' access='read'/>"
    "    <property name='Status' type='s' access='read'/>"
    "    <method name='GetLayout'>"
    "      <arg type='i' name='parentId' direction='in'/>"
    "      <arg type='i' name='recursionDepth' direction='in'/>"
    "      <arg type='as' name='propertyNames' direction='in'/>"
    "      <arg type='u' name='revision' direction='out'/>"
    "      <arg type='(ia{sv}av)' name='layout' direction='out'/>"
    "    </method>"
    "    <method name='Event'>"
    "      <arg type='i' name='id' direction='in'/>"
    "      <arg type='s' name='eventId' direction='in'/>"
    "      <arg type='v' name='data' direction='in'/>"
    "      <arg type='u' name='timestamp' direction='in'/>"
    "    </method>"
    "    <method name='AboutToShow'>"
    "      <arg type='i' name='id' direction='in'/>"
    "      <arg type='b' name='needUpdate' direction='out'/>"
    "    </method>"
    "    <signal name='LayoutUpdated'><arg type='u' name='revision'/><arg type='i' name='parent'/></signal>"
    "  </interface>"
    "</node>";

static GVariant *menu_item(int id, const char *label, gboolean sep) {
    GVariantBuilder props;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
    if (sep) {
        g_variant_builder_add(&props, "{sv}", "type", g_variant_new_string("separator"));
    } else {
        g_variant_builder_add(&props, "{sv}", "label", g_variant_new_string(label));
        g_variant_builder_add(&props, "{sv}", "enabled", g_variant_new_boolean(TRUE));
        g_variant_builder_add(&props, "{sv}", "visible", g_variant_new_boolean(TRUE));
    }
    GVariantBuilder empty;
    g_variant_builder_init(&empty, G_VARIANT_TYPE("av"));
    return g_variant_new("(ia{sv}av)", id, &props, &empty);
}

static void sni_method_call(GDBusConnection *c, const char *s, const char *p, const char *i,
                            const char *m, GVariant *params, GDBusMethodInvocation *inv, gpointer ud) {
    (void)c; (void)s; (void)p; (void)i; (void)params; (void)ud;
    if (strcmp(m, "Activate") == 0) open_settings_window();
    g_dbus_method_invocation_return_value(inv, NULL);
}

static GVariant *sni_get_prop(GDBusConnection *c, const char *s, const char *p, const char *i,
                              const char *prop, GError **e, gpointer ud) {
    (void)c; (void)s; (void)p; (void)i; (void)e; (void)ud;
    if (strcmp(prop, "Category") == 0) return g_variant_new_string("ApplicationStatus");
    if (strcmp(prop, "Id") == 0) return g_variant_new_string("yiqi-input");
    if (strcmp(prop, "Title") == 0) return g_variant_new_string("一炁输入法");
    if (strcmp(prop, "Status") == 0) return g_variant_new_string("Active");
    if (strcmp(prop, "IconName") == 0) return g_variant_new_string("yiqi");
    if (strcmp(prop, "Menu") == 0) return g_variant_new_object_path("/MenuBar");
    if (strcmp(prop, "ItemIsMenu") == 0) return g_variant_new_boolean(FALSE);
    return NULL;
}

static void menu_method_call(GDBusConnection *c, const char *s, const char *p, const char *i,
                             const char *m, GVariant *params, GDBusMethodInvocation *inv, gpointer ud) {
    (void)c; (void)s; (void)p; (void)i; (void)ud;
    if (strcmp(m, "GetLayout") == 0) {
        rpc_call("{\"cmd\":\"state\"}");
        GVariantBuilder children;
        g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
        g_variant_builder_add(&children, "v", menu_item(1, "一炁输入法设置…", FALSE));
        if (g_state.update_version[0]) {
            char ul[128];
            snprintf(ul, sizeof(ul), "有新版本 %s，点此更新…", g_state.update_version);
            g_variant_builder_add(&children, "v", menu_item(2, ul, FALSE));
        }
        g_variant_builder_add(&children, "v", menu_item(3, "检查更新…", FALSE));
        g_variant_builder_add(&children, "v", menu_item(4, "", TRUE));
        char sl[256];
        const char *next = strcmp(g_state.scheme, "rime_frost") == 0 ? "小鹤双拼" : "全拼";
        snprintf(sl, sizeof(sl), "切换至%s（%s）", next, g_state.hotkey_label[0] ? g_state.hotkey_label : "Ctrl + Shift + 1");
        g_variant_builder_add(&children, "v", menu_item(5, sl, FALSE));
        g_variant_builder_add(&children, "v", menu_item(6, "", TRUE));
        g_variant_builder_add(&children, "v", menu_item(7, "退出", FALSE));

        GVariantBuilder root_props;
        g_variant_builder_init(&root_props, G_VARIANT_TYPE("a{sv}"));
        g_variant_builder_add(&root_props, "{sv}", "children-display", g_variant_new_string("submenu"));
        GVariant *layout = g_variant_new("(ia{sv}av)", 0, &root_props, &children);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(u@(ia{sv}av))", g_menu_rev, layout));
        return;
    }
    if (strcmp(m, "AboutToShow") == 0) {
        g_dbus_method_invocation_return_value(inv, g_variant_new("(b)", TRUE));
        return;
    }
    if (strcmp(m, "Event") == 0) {
        gint32 id = 0;
        const char *ev = NULL;
        GVariant *val = NULL;
        guint32 ts = 0;
        g_variant_get(params, "(i&svu)", &id, &ev, &val, &ts);
        if (val) g_variant_unref(val);
        if (ev && strcmp(ev, "clicked") == 0) {
            if (id == 1 || id == 2) open_settings_window();
            else if (id == 3) { open_settings_window(); rpc_call("{\"cmd\":\"check_update\",\"manual\":true}"); refresh_ui(); }
            else if (id == 5) { rpc_call("{\"cmd\":\"toggle_scheme\"}"); refresh_ui(); emit_menu_updated(); }
            else if (id == 7) { rpc_call("{\"cmd\":\"quit\"}"); g_application_quit(G_APPLICATION(g_app)); }
        }
        g_dbus_method_invocation_return_value(inv, NULL);
        return;
    }
    g_dbus_method_invocation_return_value(inv, NULL);
}

static GVariant *menu_get_prop(GDBusConnection *c, const char *s, const char *p, const char *i,
                               const char *prop, GError **e, gpointer ud) {
    (void)c; (void)s; (void)p; (void)i; (void)e; (void)ud;
    if (strcmp(prop, "Version") == 0) return g_variant_new_uint32(3);
    if (strcmp(prop, "Status") == 0) return g_variant_new_string("normal");
    return NULL;
}

static void setup_tray(void) {
    g_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!g_bus) return;
    static const GDBusInterfaceVTable sni_vt = { sni_method_call, sni_get_prop, NULL, {0} };
    static const GDBusInterfaceVTable menu_vt = { menu_method_call, menu_get_prop, NULL, {0} };

    GDBusNodeInfo *sni_info = g_dbus_node_info_new_for_xml(sni_xml, NULL);
    GDBusNodeInfo *menu_info = g_dbus_node_info_new_for_xml(menu_xml, NULL);
    if (sni_info) {
        g_sni_reg = g_dbus_connection_register_object(g_bus, "/StatusNotifierItem", sni_info->interfaces[0], &sni_vt, NULL, NULL, NULL);
        g_dbus_node_info_unref(sni_info);
    }
    if (menu_info) {
        g_menu_reg = g_dbus_connection_register_object(g_bus, "/MenuBar", menu_info->interfaces[0], &menu_vt, NULL, NULL, NULL);
        g_dbus_node_info_unref(menu_info);
    }
    const char *unique = g_dbus_connection_get_unique_name(g_bus);
    if (unique) {
        g_dbus_connection_call(
            g_bus, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
            g_variant_new("(s)", unique), NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
    }
}

static int on_command_line(GApplication *app, GApplicationCommandLine *cmdline, gpointer ud) {
    (void)ud;
    int argc = 0;
    char **argv = g_application_command_line_get_arguments(cmdline, &argc);
    gboolean want_tray = FALSE, want_settings = FALSE;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--tray") == 0) want_tray = TRUE;
        if (strcmp(argv[i], "--settings") == 0) want_settings = TRUE;
    }
    g_strfreev(argv);
    if (!want_tray && !want_settings) want_settings = TRUE;

    static gboolean initialized = FALSE;
    if (!initialized) {
        initialized = TRUE;
        rpc_call("{\"cmd\":\"state\"}");
        g_timeout_add(1000, on_poll_timer, NULL);
    }
    if (want_tray && !g_tray_mode) {
        g_tray_mode = TRUE;
        g_application_hold(app);
        setup_tray();
    }
    if (want_settings) {
        open_settings_window();
    }
    return 0;
}

int main(int argc, char **argv) {
    g_app = gtk_application_new("im.yiqi.app", G_APPLICATION_HANDLES_COMMAND_LINE);
    g_signal_connect(g_app, "command-line", G_CALLBACK(on_command_line), NULL);
    int rc = g_application_run(G_APPLICATION(g_app), argc, argv);
    g_object_unref(g_app);
    return rc;
}
