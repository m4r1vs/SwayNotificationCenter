namespace SwayNotificationCenter {
    /**
     * Enrichment payload returned by hey-computer for a held notification.
     * Shared across floating popup and Control Center instances of the same card.
     */
    public class HcEnrichment : Object {
        public int64 turn_id { get; set; default = 0; }
        public string token { get; set; default = ""; }
        public string context_note { get; set; default = ""; }
        public string draft_text { get; set; default = ""; }
        public bool readonly_mode { get; set; default = true; }
        public bool token_claimed { get; set; default = false; }
    }

    /**
     * Tier 1 deterministic bypass gate + bounded async hold-and-enrich client
     * talking to hey-computer.sock over a UNIX domain socket.
     *
     * Guarantees:
     * - Tier 1 bypasses execute synchronously in memory (0 ms, 0 socket calls).
     * - Every held notification is guarded by a hard fail-open watchdog timer
     *   and fails open immediately on connect error, read error, EOF, or bad JSON.
     */
    internal class HcHoldManager : Object {
        private class HeldEntry : Object {
            public uint32 noti_id;
            public uint32 replace_id;
            public NotifyParams param;
            public Cancellable cancellable = new Cancellable ();
            public SocketConnection ?connection = null;
            public uint timeout_id = 0;
            public int64 deadline_us = 0;
            public bool finished = false;

            public HeldEntry (NotifyParams param, uint32 replace_id) {
                this.noti_id = param.applied_id;
                this.replace_id = replace_id;
                this.param = param;
            }
        }

        private const string[] HARD_EXCLUDED_APPS = {
            "hey-computer",
            "hey-computer-viewer",
            "npu-dictate",
            "notify-send",
            "1password",
            "keepassxc",
            "org.keepassxc.keepassxc",
            "spotify",
            "mpv",
            "networkmanager",
            "nm-applet",
            "blueman",
            "flameshot",
            "swappy",
        };

        private unowned NotiDaemon daemon;
        private HashTable<uint32, HeldEntry> held_notifications =
            new HashTable<uint32, HeldEntry> (direct_hash, direct_equal);
        private Regex ?otp_regex = null;

        public HcHoldManager (NotiDaemon daemon) {
            this.daemon = daemon;
            try {
                this.otp_regex = new Regex (
                    "(?<= |^)(\\d{3}(-| )\\d{3}|\\d{4,8})(?= |$|\\.|,)",
                    RegexCompileFlags.MULTILINE);
            } catch (RegexError e) {
                warning ("Failed to compile OTP regex: %s", e.message);
            }
        }

        public static string resolve_socket_path () {
            string configured = ConfigModel.instance.hc_hold_socket.strip ();
            if (configured.length > 0) {
                return configured;
            }
            unowned string ?xdg_runtime = Environment.get_variable ("XDG_RUNTIME_DIR");
            if (xdg_runtime != null && xdg_runtime.length > 0) {
                return Path.build_filename (xdg_runtime, "hey-computer.sock");
            }
            unowned string ?runtime_dir = Environment.get_user_runtime_dir ();
            if (runtime_dir != null && runtime_dir.length > 0) {
                return Path.build_filename (runtime_dir, "hey-computer.sock");
            }
            return "/tmp/hey-computer.sock";
        }

        /**
         * Cancels and removes a currently held notification without displaying it.
         * Returns true if `id` was held and sets `carried_replace_id` to any
         * earlier displayed notification ID it was scheduled to replace.
         */
        public bool cancel_held (uint32 id, out uint32 carried_replace_id) {
            carried_replace_id = 0;
            HeldEntry ?entry = held_notifications.lookup (id);
            if (entry == null) {
                return false;
            }
            carried_replace_id = entry.replace_id;
            cancel_entry (entry);
            return true;
        }

        /**
         * Handles D-Bus CloseNotification while `id` is held for enrichment.
         * Transient/ephemeral OSD notifications are cancelled immediately;
         * persistent notifications ignore premature CloseNotification (e.g. from
         * Electron/Chromium auto-closing or V8 GC) so enrichment can complete.
         */
        public bool on_close_notification (uint32 id, out bool cancelled) {
            HeldEntry ?entry = held_notifications.lookup (id);
            if (entry == null) {
                cancelled = false;
                return false;
            }
            if (entry.param.ignore_cc ()) {
                cancel_entry (entry);
                cancelled = true;
                return true;
            }
            debug ("Ignoring premature CloseNotification for held persistent notification ID:%u",
                   id);
            cancelled = false;
            return true;
        }

        /**
         * Tier 1 AI-less deterministic gate.
         * Returns false to bypass immediately at 0 ms with zero socket calls.
         */
        public bool should_hold (NotifyParams param) {
            unowned ConfigModel cfg = ConfigModel.instance;

            // 1. Master switch
            if (!cfg.hc_hold_enabled) {
                return false;
            }

            // 2. Do Not Disturb or active inhibitor
            if (daemon.dnd || (swaync_daemon != null && swaync_daemon.inhibited)) {
                return false;
            }

            // 3. Transient OSD / ephemeral notifications (notify-send -e)
            if (param.transient) {
                return false;
            }

            // 4. Progress sliders, self-originated notifications, or no-script hint
            if (param.hints.contains ("value")
                || is_hint_truthy (param.hints, "x-hey-computer")
                || param.swaync_no_script) {
                return false;
            }

            // 5. Urgency gate (default: Normal only)
            if ((param.urgency == UrgencyLevels.LOW && !cfg.hc_hold_low_urgency)
                || (param.urgency == UrgencyLevels.CRITICAL && !cfg.hc_hold_critical_urgency)) {
                return false;
            }

            // 6. Short-lived OSD timeout (1..=3000 ms)
            if (param.expire_timeout > 0 && param.expire_timeout <= 3000) {
                return false;
            }

            // 7. Hard-excluded system, secret-manager, and media apps/categories
            if (is_hard_excluded (param)) {
                return false;
            }

            // 8. 2FA / OTP verification code match
            if (cfg.notification_2fa_action && matches_otp (param)) {
                return false;
            }

            // 9. Configured exclude/include app regexes
            if (cfg.hc_hold_exclude_apps.length > 0
                && matches_any_app_regex (param, cfg.hc_hold_exclude_apps)) {
                return false;
            }
            if (cfg.hc_hold_apps.length > 0
                && !matches_any_app_regex (param, cfg.hc_hold_apps)) {
                return false;
            }

            return true;
        }

        public void hold (NotifyParams param, uint32 replace_id) {
            var entry = new HeldEntry (param, replace_id);
            held_notifications.set (entry.noti_id, entry);

            uint max_secs = (uint) ConfigModel.instance.hc_hold_max_seconds.clamp (1, 300);
            entry.deadline_us = get_monotonic_time () + ((int64) max_secs * 1000000);
            entry.timeout_id = Timeout.add_seconds (max_secs, () => {
                entry.timeout_id = 0;
                debug ("hc hold watchdog expired for ID:%u; failing open", entry.noti_id);
                release_entry (entry, null);
                return Source.REMOVE;
            });

            hold_async.begin (entry);
        }

        private async void hold_async (HeldEntry entry) {
            string sock_path = resolve_socket_path ();
            if (sock_path.length == 0) {
                release_entry (entry, null);
                return;
            }

            try {
                var client = new SocketClient ();
                var address = new UnixSocketAddress (sock_path);
                SocketConnection conn = yield client.connect_async (address, entry.cancellable);
                if (entry.finished) {
                    try {
                        conn.close (null);
                    } catch (Error close_err) {
                        // Ignore best-effort close error
                    }
                    return;
                }
                entry.connection = conn;

                string payload = build_notify_hold_json (entry) + "\n";
                size_t written;
                yield conn.output_stream.write_all_async (
                    payload.data,
                    Priority.DEFAULT,
                    entry.cancellable,
                    out written);
                yield conn.output_stream.flush_async (Priority.DEFAULT, entry.cancellable);

                var dis = new DataInputStream (conn.input_stream);
                dis.set_newline_type (DataStreamNewlineType.LF);

                while (!entry.finished) {
                    size_t line_len;
                    string ?line = yield dis.read_line_async (
                        Priority.DEFAULT,
                        entry.cancellable,
                        out line_len);

                    if (entry.finished) {
                        return;
                    }
                    if (line == null) {
                        // EOF (e.g. hey-computer restarted) -> fail open immediately
                        debug ("hc hold EOF for ID:%u; failing open", entry.noti_id);
                        release_entry (entry, null);
                        return;
                    }

                    string trimmed = line.strip ();
                    if (trimmed.length == 0) {
                        continue;
                    }

                    if (handle_server_line (entry, trimmed)) {
                        return;
                    }
                }
            } catch (Error e) {
                if (!entry.finished) {
                    debug ("hc hold error for ID:%u (%s); failing open",
                           entry.noti_id, e.message);
                    release_entry (entry, null);
                }
            }
        }

        /**
         * Processes a single JSON line from hey-computer.
         * Returns true if the hold is complete (released), false to continue reading.
         */
        private bool handle_server_line (HeldEntry entry, string line) {
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (line, -1);
                unowned Json.Node ?root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                    debug ("hc hold malformed JSON root for ID:%u; failing open", entry.noti_id);
                    release_entry (entry, null);
                    return true;
                }

                unowned Json.Object obj = root.get_object ();
                string msg_type = get_json_string (obj, "type");

                if (msg_type == "notify_accepted") {
                    int64 max_hold_ms = get_json_int (obj, "max_hold_ms", 0);
                    debug ("hc hold accepted for ID:%u (max_hold_ms=%" + int64.FORMAT + ")",
                           entry.noti_id, max_hold_ms);
                    if (max_hold_ms > 0) {
                        shorten_watchdog (entry, max_hold_ms);
                    }
                    return false;
                }

                if (msg_type == "notify_release") {
                    string action = get_json_string (obj, "action");
                    if (action == "show_raw") {
                        debug ("hc hold release show_raw for ID:%u", entry.noti_id);
                        release_entry (entry, null);
                        return true;
                    }
                    if (action == "show_enriched") {
                        var enrichment = new HcEnrichment ();
                        enrichment.turn_id = get_json_int (obj, "turn_id", 0);
                        enrichment.token = get_json_string (obj, "token");
                        enrichment.context_note = get_json_string (obj, "context_note");
                        enrichment.draft_text = get_json_string (obj, "draft_text");
                        enrichment.readonly_mode = get_json_bool (obj, "readonly", true);

                        bool has_content = enrichment.context_note.strip ().length > 0
                            || enrichment.draft_text.strip ().length > 0
                            || enrichment.turn_id > 0;
                        debug ("hc hold release show_enriched for ID:%u (turn=%" + int64.FORMAT + ")",
                               entry.noti_id, enrichment.turn_id);
                        release_entry (entry, has_content ? enrichment : null);
                        return true;
                    }
                    debug ("hc hold unknown release action '%s' for ID:%u; failing open",
                           action, entry.noti_id);
                    release_entry (entry, null);
                    return true;
                }

                debug ("hc hold unexpected message type '%s' for ID:%u; failing open",
                       msg_type, entry.noti_id);
                release_entry (entry, null);
                return true;
            } catch (Error e) {
                debug ("hc hold JSON parse error for ID:%u (%s); failing open",
                       entry.noti_id, e.message);
                release_entry (entry, null);
                return true;
            }
        }

        private void shorten_watchdog (HeldEntry entry, int64 max_hold_ms) {
            int64 now_us = get_monotonic_time ();
            int64 remaining_ms = (entry.deadline_us - now_us) / 1000;
            if (max_hold_ms >= remaining_ms) {
                return;
            }
            uint clamped_ms = (uint) max_hold_ms.clamp (100, 300000);
            if (entry.timeout_id > 0) {
                Source.remove (entry.timeout_id);
                entry.timeout_id = 0;
            }
            entry.deadline_us = now_us + ((int64) clamped_ms * 1000);
            entry.timeout_id = Timeout.add (clamped_ms, () => {
                entry.timeout_id = 0;
                debug ("hc hold adjusted watchdog expired for ID:%u; failing open", entry.noti_id);
                release_entry (entry, null);
                return Source.REMOVE;
            });
        }

        private void release_entry (HeldEntry entry, HcEnrichment ?enrichment) {
            if (entry.finished) {
                return;
            }
            entry.finished = true;
            cleanup_entry (entry);
            if (held_notifications.lookup (entry.noti_id) == entry) {
                held_notifications.remove (entry.noti_id);
            }
            daemon.deliver_notification (entry.param, enrichment, entry.replace_id);
        }

        private void cancel_entry (HeldEntry entry) {
            if (entry.finished) {
                return;
            }
            entry.finished = true;
            cleanup_entry (entry);
            if (held_notifications.lookup (entry.noti_id) == entry) {
                held_notifications.remove (entry.noti_id);
            }
        }

        private void cleanup_entry (HeldEntry entry) {
            if (entry.timeout_id > 0) {
                Source.remove (entry.timeout_id);
                entry.timeout_id = 0;
            }
            if (!entry.cancellable.is_cancelled ()) {
                entry.cancellable.cancel ();
            }
            if (entry.connection != null) {
                try {
                    entry.connection.close (null);
                } catch (Error e) {
                    // Best-effort close
                }
                entry.connection = null;
            }
        }

        private string build_notify_hold_json (HeldEntry entry) {
            unowned NotifyParams param = entry.param;
            uint32 effective_replaces = entry.replace_id > 0 ? entry.replace_id : param.replaces_id;

            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("type");
            builder.add_string_value ("notify_hold");
            builder.set_member_name ("noti_id");
            builder.add_int_value ((int64) param.applied_id);
            builder.set_member_name ("replaces_id");
            builder.add_int_value ((int64) effective_replaces);
            builder.set_member_name ("app_name");
            builder.add_string_value (param.app_name ?? "");
            builder.set_member_name ("desktop_entry");
            builder.add_string_value (param.desktop_entry ?? "");
            builder.set_member_name ("summary");
            builder.add_string_value (param.summary ?? "");
            builder.set_member_name ("body");
            builder.add_string_value (param.body ?? "");
            builder.set_member_name ("category");
            builder.add_string_value (param.category ?? "");
            builder.set_member_name ("urgency");
            builder.add_string_value (param.urgency.to_string ().down ());
            builder.set_member_name ("has_default_action");
            builder.add_boolean_value (param.default_action != null);
            builder.set_member_name ("dnd");
            builder.add_boolean_value (
                daemon.dnd || (swaync_daemon != null && swaync_daemon.inhibited));
            builder.end_object ();

            var generator = new Json.Generator ();
            generator.pretty = false;
            generator.set_root (builder.get_root ());
            return generator.to_data (null);
        }

        /**
         * Fire-and-forget notification to hey-computer.sock when a user copies,
         * edits, or dismisses an enriched draft card.
         */
        public static void send_draft_resume (string token, string action) {
            if (token.strip ().length == 0) {
                return;
            }
            send_draft_resume_async.begin (token, action);
        }

        private static async void send_draft_resume_async (string token, string action) {
            string sock_path = resolve_socket_path ();
            if (sock_path.length == 0) {
                return;
            }

            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("type");
            builder.add_string_value ("draft_resume");
            builder.set_member_name ("token");
            builder.add_string_value (token);
            builder.set_member_name ("action");
            builder.add_string_value (action);
            builder.end_object ();

            var generator = new Json.Generator ();
            generator.pretty = false;
            generator.set_root (builder.get_root ());
            string payload = generator.to_data (null) + "\n";

            var cancellable = new Cancellable ();
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds (3, () => {
                timeout_id = 0;
                cancellable.cancel ();
                return Source.REMOVE;
            });

            SocketConnection ?conn = null;
            try {
                var client = new SocketClient ();
                var address = new UnixSocketAddress (sock_path);
                conn = yield client.connect_async (address, cancellable);
                size_t written;
                yield conn.output_stream.write_all_async (
                    payload.data,
                    Priority.DEFAULT,
                    cancellable,
                    out written);
                yield conn.output_stream.flush_async (Priority.DEFAULT, cancellable);

                // Read one response line (or EOF) so hey-computer finishes handling
                // the request cleanly before we close the socket.
                var dis = new DataInputStream (conn.input_stream);
                dis.set_newline_type (DataStreamNewlineType.LF);
                yield dis.read_line_async (Priority.DEFAULT, cancellable);
            } catch (Error e) {
                debug ("hc draft_resume (%s) failed: %s", action, e.message);
            } finally {
                if (timeout_id > 0) {
                    Source.remove (timeout_id);
                    timeout_id = 0;
                }
                if (conn != null) {
                    try {
                        conn.close (null);
                    } catch (Error close_err) {
                        // Ignore
                    }
                }
            }
        }

        internal static bool is_hint_truthy (HashTable<string, Variant> hints, string key) {
            Variant ?v = hints.lookup (key);
            if (v == null) {
                return false;
            }
            if (v.is_of_type (VariantType.BOOLEAN)) {
                return v.get_boolean ();
            } else if (v.is_of_type (VariantType.INT32)) {
                return v.get_int32 () != 0;
            } else if (v.is_of_type (VariantType.UINT32)) {
                return v.get_uint32 () != 0;
            } else if (v.is_of_type (VariantType.INT64)) {
                return v.get_int64 () != 0;
            } else if (v.is_of_type (VariantType.UINT64)) {
                return v.get_uint64 () != 0;
            } else if (v.is_of_type (VariantType.BYTE)) {
                return v.get_byte () != 0;
            } else if (v.is_of_type (VariantType.STRING)) {
                string s = v.get_string ().strip ().down ();
                return s == "true" || s == "1" || s == "yes";
            }
            return false;
        }

        private static bool is_hard_excluded (NotifyParams param) {
            if (param.category != null && param.category.strip ().down () == "x-gnome.music") {
                return true;
            }

            string app = (param.app_name ?? "").strip ().down ();
            string desktop = (param.desktop_entry ?? "").strip ().down ();
            string desktop_stem = desktop.has_suffix (".desktop")
                ? desktop.slice (0, desktop.length - 8)
                : desktop;

            foreach (unowned string excluded in HARD_EXCLUDED_APPS) {
                if ((app.length > 0 && app == excluded)
                    || (desktop.length > 0 && (desktop == excluded || desktop_stem == excluded))) {
                    return true;
                }
            }
            return false;
        }

        private bool matches_otp (NotifyParams param) {
            if (otp_regex == null) {
                return false;
            }
            if (param.body != null && param.body.strip ().length > 0) {
                if (otp_regex.match (param.body.strip (), RegexMatchFlags.NOTEMPTY)) {
                    return true;
                }
            }
            if (param.summary != null && param.summary.strip ().length > 0) {
                if (otp_regex.match (param.summary.strip (), RegexMatchFlags.NOTEMPTY)) {
                    return true;
                }
            }
            return false;
        }

        private static bool matches_any_app_regex (NotifyParams param,
                                                   GenericArray<string> patterns) {
            string app = param.app_name ?? "";
            string desktop = param.desktop_entry ?? "";

            for (uint i = 0; i < patterns.length; i++) {
                unowned string ?raw = patterns[i];
                if (raw == null || raw.strip ().length == 0) {
                    continue;
                }
                try {
                    var re = new Regex (raw, RegexCompileFlags.CASELESS);
                    if ((app.length > 0 && re.match (app))
                        || (desktop.length > 0 && re.match (desktop))) {
                        return true;
                    }
                } catch (RegexError e) {
                    warning ("Invalid hc-hold regex '%s': %s", raw, e.message);
                }
            }
            return false;
        }

        private static string get_json_string (Json.Object obj, string member) {
            if (!obj.has_member (member)) {
                return "";
            }
            unowned Json.Node ?node = obj.get_member (member);
            if (node == null || node.get_node_type () != Json.NodeType.VALUE) {
                return "";
            }
            if (node.get_value_type () != typeof (string)) {
                return "";
            }
            return node.get_string () ?? "";
        }

        private static int64 get_json_int (Json.Object obj, string member, int64 fallback = 0) {
            if (!obj.has_member (member)) {
                return fallback;
            }
            unowned Json.Node ?node = obj.get_member (member);
            if (node == null || node.get_node_type () != Json.NodeType.VALUE) {
                return fallback;
            }
            Type t = node.get_value_type ();
            if (t == typeof (int64)) {
                return node.get_int ();
            } else if (t == typeof (double)) {
                return (int64) node.get_double ();
            }
            return fallback;
        }

        private static bool get_json_bool (Json.Object obj, string member, bool fallback) {
            if (!obj.has_member (member)) {
                return fallback;
            }
            unowned Json.Node ?node = obj.get_member (member);
            if (node == null || node.get_node_type () != Json.NodeType.VALUE) {
                return fallback;
            }
            if (node.get_value_type () == typeof (bool)) {
                return node.get_boolean ();
            }
            return fallback;
        }
    }
}
