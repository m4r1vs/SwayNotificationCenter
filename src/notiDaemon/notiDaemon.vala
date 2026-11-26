namespace SwayNotificationCenter {
    /** Return true to remove notification, false to skip */
    public delegate bool notification_filter_func (Notification notification);

    private class NotificationRecord : Object {
        public uint32 id;
        public NotifyParams param;
        public string state;
        public int64 closed_time;

        public NotificationRecord (NotifyParams param, string state = "active") {
            this.id = param.applied_id;
            this.param = param;
            this.state = state;
            this.closed_time = 0;
        }
    }

    [DBus (name = "org.freedesktop.Notifications")]
    public class NotiDaemon : Object {
        private const int MAX_HISTORY_RECORDS = 50;
        private uint32 noti_id = 0;
        private HashTable<string, uint32> synchronous_ids =
            new HashTable<string, uint32> (str_hash, str_equal);
        private Gee.HashSet<uint32> notification_ids = new Gee.HashSet<uint32> ();
        private Gee.HashMap<uint32, NotifyParams> active_params =
            new Gee.HashMap<uint32, NotifyParams> ();
        private Gee.ArrayList<NotificationRecord> history_records =
            new Gee.ArrayList<NotificationRecord> ();
        private HcHoldManager hc_hold;

        /** Do Not Disturb state */
        internal bool dnd { get; set; default = false; }
        /** Called when Do Not Disturb state changes */
        internal signal void on_dnd_toggle (bool dnd);

        public NotiDaemon () {
            this.hc_hold = new HcHoldManager (this);
            this.notify["dnd"].connect (() => on_dnd_toggle (dnd));

            // Init dnd from gsettings
            self_settings.bind ("dnd-state", this, "dnd", SettingsBindFlags.DEFAULT);
        }

        internal uint n_notifications {
            get {
                return notifications_widget.n_notifications;
            }
        }

        internal void request_dismiss_notification_id (uint32 id,
                                                       ClosedReasons reason,
                                                       bool ignore_cc) {
            // Expired, non-transient notifications should not be fully dismissed, only hidden
            if (reason == ClosedReasons.EXPIRED && !ignore_cc) {
                debug ("Hiding floating notification with ID:%u, reason:%s",
                       id, reason.to_string ());
                floating_notifications.remove_notification (id);
                return;
            }

            debug ("Dismissing notification with ID:%u, reason:%s",
                   id, reason.to_string ());
            NotificationClosed (id, reason);
            notification_ids.remove (id);
            record_closed (id, reason);

            notifications_widget.remove_notification (id);
            floating_notifications.remove_notification (id);

            swaync_daemon.emit_subscribe ();
        }

        internal inline void request_dismiss_notification (NotifyParams param,
                                                           ClosedReasons reason) {
            request_dismiss_notification_id (param.applied_id, reason, param.ignore_cc ());
        }

        internal void request_dismiss_notification_group (string group_name_id,
                                                          Gee.Set<uint32> ids,
                                                          ClosedReasons reason) {
            debug ("Dismissing notification group with ID:%s, reason:%s",
                   group_name_id, reason.to_string ());
            foreach (unowned uint32 id in ids) {
                NotificationClosed (id, reason);
                notification_ids.remove (id);
                record_closed (id, reason);
                floating_notifications.remove_notification (id);
            }
            notifications_widget.remove_group (group_name_id);

            swaync_daemon.emit_subscribe ();
        }

        internal void request_dismiss_all_notifications (ClosedReasons reason) {
            debug ("Dismissing all notifications, reason:%s", reason.to_string ());
            foreach (uint32 id in notification_ids) {
                NotificationClosed (id, reason);
                record_closed (id, reason);
            }
            notification_ids.clear ();
            active_params.clear ();

            remove_all_floating_notifications (false, null);
            notifications_widget.remove_all_notifications (true);

            swaync_daemon.emit_subscribe ();
        }

        /** Hides all floating notifications (closes transient) */
        internal inline void remove_all_floating_notifications (bool transition,
                                                                notification_filter_func ?func) {
            debug ("Hiding all floating notifications");
            floating_notifications.remove_all_notifications (transition, (notification) => {
                if (func == null || func (notification)) {
                    // Send DISMISSED to valid TRANSIENT notifications
                    unowned NotifyParams param = notification.param;
                    if (param.applied_id > 0 && param.ignore_cc ()) {
                        debug ("Closing floating-only notification with ID:%u while hiding",
                               param.applied_id);
                        NotificationClosed (param.applied_id, ClosedReasons.DISMISSED);
                        notification_ids.remove (param.applied_id);
                        record_closed (param.applied_id, ClosedReasons.DISMISSED);
                    }
                    return true;
                }
                return false;
            });
        }

        /** Hides/closes latest floating notification */
        internal void hide_latest_floating_notification (bool close) {
            NotifyParams ?param = floating_notifications.get_latest_notification ();
            if (param == null) {
                return;
            }

            // note: Hiding a TRANSIENT notification acts as closing it
            if (close || param.ignore_cc ()) {
                request_dismiss_notification (param, ClosedReasons.DISMISSED);
            } else {
                floating_notifications.remove_notification (param.applied_id);
            }
        }

        /** Activates the `action_index` action of the latest notification */
        internal void invoke_latest_floating_action (uint32 action_index) {
            floating_notifications.latest_notification_action (action_index);
        }

        internal bool invoke_notification_action_by_id (uint32 id, string action_id) {
            unowned Notification ?noti = floating_notifications.get_notification (id);
            if (noti == null) {
                noti = notifications_widget.get_notification (id);
            }
            if (noti == null) {
                return false;
            }
            return noti.invoke_action_by_id (action_id);
        }

        private void record_delivered (NotifyParams param, uint32 replaced_id) {
            uint32 id = param.applied_id;
            if (replaced_id > 0) {
                active_params.unset (replaced_id);
                for (int i = history_records.size - 1; i >= 0; i--) {
                    if (history_records[i].id == replaced_id) {
                        history_records.remove_at (i);
                    }
                }
            }
            for (int i = history_records.size - 1; i >= 0; i--) {
                if (history_records[i].id == id) {
                    history_records.remove_at (i);
                }
            }
            active_params.set (id, param);
            history_records.add (new NotificationRecord (param, "active"));
            while (history_records.size > MAX_HISTORY_RECORDS) {
                history_records.remove_at (0);
            }
        }

        private void record_closed (uint32 id, ClosedReasons reason) {
            active_params.unset (id);
            string new_state = (reason == ClosedReasons.EXPIRED) ? "expired" : "dismissed";
            int64 closed_at = (int64) (get_real_time () / 1000000);
            foreach (NotificationRecord rec in history_records) {
                if (rec.id == id) {
                    rec.state = new_state;
                    rec.closed_time = closed_at;
                }
            }
        }

        private static bool is_self_or_osd (NotifyParams param) {
            if (param.hints != null && HcHoldManager.is_hint_truthy (param.hints, "x-hey-computer")) {
                return true;
            }
            if (param.transient && (param.has_synch
                                    || (param.hints != null && param.hints.contains ("value")))) {
                return true;
            }
            string app = (param.app_name ?? "").strip ().down ();
            string desktop = (param.desktop_entry ?? "").strip ().down ();
            string desktop_stem = desktop.has_suffix (".desktop")
                ? desktop.slice (0, desktop.length - 8)
                : desktop;
            if (app == "hey-computer"
                || app == "hey-computer-viewer"
                || app == "npu-dictate"
                || app == "volume-change-notify"
                || app == "brightness-change-notify"
                || desktop_stem == "hey-computer"
                || desktop_stem == "hey-computer-viewer"
                || desktop_stem == "npu-dictate") {
                return true;
            }
            return false;
        }

        private void write_notification_record_json (Json.Builder builder,
                                                     NotificationRecord rec) {
            unowned NotifyParams p = rec.param;
            bool is_active = rec.state == "active";
            bool is_floating = is_active && floating_notifications.get_notification (rec.id) != null;
            bool in_cc = is_active && notifications_widget.get_notification (rec.id) != null;

            builder.begin_object ();
            builder.set_member_name ("id");
            builder.add_int_value ((int64) rec.id);
            builder.set_member_name ("app_name");
            builder.add_string_value (p.app_name ?? "");
            builder.set_member_name ("desktop_entry");
            builder.add_string_value (p.desktop_entry ?? "");
            builder.set_member_name ("display_name");
            builder.add_string_value (p.display_name ?? "");
            builder.set_member_name ("summary");
            builder.add_string_value (p.summary ?? "");
            builder.set_member_name ("body");
            builder.add_string_value (p.body ?? "");
            builder.set_member_name ("category");
            builder.add_string_value (p.category ?? "");
            builder.set_member_name ("urgency");
            builder.add_string_value (p.urgency.to_string ());
            builder.set_member_name ("time");
            builder.add_int_value (p.time);
            if (rec.closed_time > 0) {
                builder.set_member_name ("closed_time");
                builder.add_int_value (rec.closed_time);
            }
            builder.set_member_name ("state");
            builder.add_string_value (rec.state);
            builder.set_member_name ("floating");
            builder.add_boolean_value (is_floating);
            builder.set_member_name ("in_control_center");
            builder.add_boolean_value (in_cc);
            builder.set_member_name ("transient");
            builder.add_boolean_value (p.transient);
            builder.set_member_name ("resident");
            builder.add_boolean_value (p.resident);
            builder.set_member_name ("default_action");
            builder.add_boolean_value (p.default_action != null);
            builder.set_member_name ("inline_reply");
            builder.add_boolean_value (p.inline_reply != null);

            builder.set_member_name ("actions");
            builder.begin_array ();
            if (p.actions != null) {
                for (uint i = 0; i < p.actions.length; i++) {
                    unowned Action act = p.actions.index (i);
                    builder.begin_object ();
                    builder.set_member_name ("id");
                    builder.add_string_value (act.identifier ?? "");
                    builder.set_member_name ("label");
                    builder.add_string_value (act.text ?? "");
                    builder.end_object ();
                }
            }
            builder.end_array ();

            if (p.hc_enrichment != null) {
                unowned HcEnrichment hc = p.hc_enrichment;
                builder.set_member_name ("hc_enrichment");
                builder.begin_object ();
                builder.set_member_name ("turn_id");
                builder.add_int_value (hc.turn_id);
                builder.set_member_name ("context_note");
                builder.add_string_value (hc.context_note ?? "");
                builder.set_member_name ("draft_text");
                builder.add_string_value (hc.draft_text ?? "");
                builder.set_member_name ("readonly");
                builder.add_boolean_value (hc.readonly_mode);
                builder.end_object ();
            }

            builder.end_object ();
        }

        internal string get_notifications_json (bool include_history,
                                                bool include_all,
                                                uint32 limit,
                                                bool latest_only) {
            var candidates = new Gee.ArrayList<NotificationRecord> ();
            foreach (NotifyParams p in active_params.values) {
                if (include_all || !is_self_or_osd (p)) {
                    candidates.add (new NotificationRecord (p, "active"));
                }
            }

            if (include_history || (latest_only && candidates.is_empty)) {
                foreach (NotificationRecord rec in history_records) {
                    if (!active_params.has_key (rec.id)
                        && (include_all || !is_self_or_osd (rec.param))) {
                        candidates.add (rec);
                    }
                }
            }

            candidates.sort ((a, b) => {
                if (a.param.time != b.param.time) {
                    return (a.param.time > b.param.time) ? -1 : 1;
                }
                if (a.id != b.id) {
                    return (a.id > b.id) ? -1 : 1;
                }
                return 0;
            });

            if (latest_only) {
                if (candidates.is_empty) {
                    return "null";
                }
                var single_builder = new Json.Builder ();
                write_notification_record_json (single_builder, candidates[0]);
                var single_gen = new Json.Generator ();
                single_gen.pretty = false;
                single_gen.set_root (single_builder.get_root ());
                return single_gen.to_data (null);
            }

            var arr_builder = new Json.Builder ();
            arr_builder.begin_array ();
            int max_items = (limit > 0 && limit < candidates.size)
                ? (int) limit
                : candidates.size;
            for (int i = 0; i < max_items; i++) {
                write_notification_record_json (arr_builder, candidates[i]);
            }
            arr_builder.end_array ();

            var arr_gen = new Json.Generator ();
            arr_gen.pretty = false;
            arr_gen.set_root (arr_builder.get_root ());
            return arr_gen.to_data (null);
        }

        /*
         * D-Bus Specification
         * https://specifications.freedesktop.org/notification-spec/latest/ar01s09.html
         */

        /**
         * It returns an array of strings. Each string describes an optional
         * capability implemented by the server.
         *
         * New vendor-specific caps may be specified as long as they start with
         * "x-vendor". For instance, "x-gnome-foo-cap". Capability names must
         * not contain spaces. They are limited to alphanumeric characters
         * and dashes ("-").
         */
        [DBus (name = "GetCapabilities")]
        public string[] get_capabilities () throws DBusError, IOError {
            return {
                       "actions",
                       "body",
                       "body-markup",
                       "body-images",
                       "persistence",
                       "synchronous",
                       "private-synchronous",
                       "x-canonical-private-synchronous",
                       "inline-reply",
            };
        }

        /**
         * Sends a notification to the notification server.
         *
         * If replaces_id is 0, the return value is a UINT32 that represent
         * the notification. It is unique, and will not be reused unless a
         * MAXINT number of notifications have been generated. An acceptable
         * implementation may just use an incrementing counter for the ID.
         * The returned ID is always greater than zero. Servers must make
         * sure not to return zero as an ID.
         *
         * If replaces_id is not 0, the returned value is the same value
         * as replaces_id.
         */
        [DBus (name = "Notify")]
        public uint32 new_notification (string app_name,
                                        uint32 replaces_id,
                                        string app_icon,
                                        string summary,
                                        string body,
                                        string[] actions,
                                        HashTable<string, Variant> hints,
                                        int expire_timeout) throws DBusError, IOError {
            uint32 id = replaces_id;
            if (replaces_id == 0 || replaces_id > noti_id) {
                id = ++noti_id;
            }
            id = uint32.max (id, 1);

            var param = new NotifyParams (
                id,
                app_name,
                replaces_id,
                app_icon,
                summary,
                body,
                actions,
                hints,
                expire_timeout);

            debug ("Notification (ID:%u, state: %s): %s\n",
                   param.applied_id, param.status_state.to_string (), param.to_string ());

            // Get the notification id to replace
            uint32 notification_id_to_replace = 0;
            if (id == replaces_id) {
                notification_id_to_replace = replaces_id;
            } else if (param.synchronous != null
                       && param.synchronous.length > 0) {
                // Tries replacing without replaces_id instead
                uint32 r_id;
                // if there is any notification to replace
                if (synchronous_ids.lookup_extended (
                        param.synchronous, null, out r_id)) {
                    notification_id_to_replace = r_id;
                }
                synchronous_ids.set (param.synchronous, id);
            }

            // If this replaces a notification that is still being held, cancel
            // the stale hold (closing its socket so hey-computer aborts the stale
            // turn) and carry forward any earlier displayed ID it was replacing.
            if (notification_id_to_replace > 0) {
                uint32 carried_replace_id = 0;
                if (hc_hold.cancel_held (notification_id_to_replace, out carried_replace_id)) {
                    notification_id_to_replace = carried_replace_id;
                }
            }

            if (hc_hold.should_hold (param)) {
                debug ("Holding Notification for hey-computer: ID:%u\n", param.applied_id);
                hc_hold.hold (param, notification_id_to_replace);
                return id;
            }

            deliver_notification (param, null, notification_id_to_replace);
            return id;
        }

        internal void deliver_notification (NotifyParams param,
                                            HcEnrichment ?enrichment = null,
                                            uint32 notification_id_to_replace = 0) {
            param.hc_enrichment = enrichment;
            uint32 id = param.applied_id;

            // Don't show the floating notification if disabled and not transient
            string[] hide_floating_notification_reasons = {};
            if (param.status_state != NotificationStatusEnum.ENABLED
                && param.status_state != NotificationStatusEnum.TRANSIENT) {
                hide_floating_notification_reasons +=
                    "Notification status is not Enabled or Transient in Config";
            }
            // Don't show the notification window if the control center is open
            if (control_center.get_visibility ()) {
                hide_floating_notification_reasons += "Control Center is visible";
            }
            // Don't show the notification window if dnd or inhibited
            bool bypass_dnd = param.urgency == UrgencyLevels.CRITICAL || param.swaync_bypass_dnd;
            if (!bypass_dnd && (dnd || swaync_daemon.inhibited)) {
                hide_floating_notification_reasons +=
                    "Do Not Disturb is enabled or an Inhibitor is running";
            }

            bool added = false;
            bool removed = false;

            if (hide_floating_notification_reasons.length == 0) {
                added = true;
                if (notification_id_to_replace > 0) {
                    debug ("Replacing Notification: ID:%u -> ID:%u\n",
                           notification_id_to_replace, param.applied_id);
                    floating_notifications.replace_notification (notification_id_to_replace, param);
                } else {
                    debug ("Adding Floating Notification: ID:%u\n", param.applied_id);
                    floating_notifications.add_notification (param);
                }
            } else {
                debug ("Not displaying floating Notification: ID:%u, Reasons: {\"%s\"}\n",
                       param.applied_id,
                       string.joinv ("\", \"", hide_floating_notification_reasons));
                if (notification_id_to_replace > 0) {
                    removed = true;

                    // Remove the old notification due to the replacement possibly
                    // being Control Center-only
                    debug ("Removing replaced Floating Notification: ID:%u\n",
                           notification_id_to_replace);
                    floating_notifications.remove_notification (notification_id_to_replace);
                }
            }

            if (!param.ignore_cc ()) {
                added = true;
                if (notification_id_to_replace > 0) {
                    debug ("Replacing CC Notification: ID:%u -> ID:%u\n",
                           notification_id_to_replace, param.applied_id);
                    notifications_widget.replace_notification (notification_id_to_replace, param);
                } else {
                    debug ("Adding Control Center Notification: ID:%u\n", param.applied_id);
                    notifications_widget.add_notification (param);
                }
            } else {
                debug ("Not Placing Notification in CC: ID:%u\n", param.applied_id);
                if (notification_id_to_replace > 0) {
                    removed = true;

                    // Remove the old notification due to it possibly being floating-only
                    debug ("Removing replaced CC Notification: ID:%u\n",
                           notification_id_to_replace);
                    notifications_widget.remove_notification (notification_id_to_replace);
                }
            }

            // Store notification IDs
            if (added || removed) {
                if (notification_id_to_replace > 0) {
                    notification_ids.remove (notification_id_to_replace);
                    if (!added) {
                        record_closed (notification_id_to_replace, ClosedReasons.DISMISSED);
                    }
                }
                if (added) {
                    notification_ids.add (id);
                    record_delivered (param, notification_id_to_replace);
                }

                swaync_daemon.emit_subscribe ();
            }

#if WANT_SCRIPTING
            if (param.swaync_no_script) {
                debug ("Skipped scripts for this notification\n");
                return;
            }
            // Run matching scripts if notification meets requirements
            OrderedHashTable<Script> scripts = ConfigModel.instance.scripts;
            if (scripts.length == 0) {
                return;
            }
            this.run_scripts (param, ScriptRunOnType.RECEIVE);
#endif
            debug ("\n");
        }

        /**
         * Runs scripts that meet the requirements of the given `param`.
         */
        internal void run_scripts (NotifyParams param, ScriptRunOnType run_on) {
#if WANT_SCRIPTING
            if (param.swaync_no_script) {
                debug ("Skipped action scripts for this notification\n");
                return;
            }
            // Run the first script if notification meets requirements
            OrderedHashTable<Script> scripts = ConfigModel.instance.scripts;
            if (scripts.length == 0) {
                return;
            }
            foreach (string key in scripts.get_keys ()) {
                unowned Script script = scripts[key];
                if (!script.matches_notification (param)) {
                    continue;
                }
                if (script.run_on != run_on) {
                    continue;
                }
                if (script.skip_on_dnd && !param.swaync_bypass_dnd
                    && (dnd || swaync_daemon.inhibited)) {
                    debug ("Skipped script \"%s\" due to DND/inhibited state\n", key);
                    continue;
                }

                script.run_script.begin (param, (obj, res) => {
                    // Gets the end status
                    string error_msg;
                    if (script.run_script.end (res, out error_msg)) {
                        return;
                    }

                    if (!ConfigModel.instance.script_fail_notify) {
                        stderr.printf (
                            "Failed to run script: \"%s\" with exec: \"%s\"\n",
                            key, script.exec);
                    } else {
                        // Send notification with error message
                        try {
                            var _hints = new HashTable<string, Variant> (
                                str_hash,
                                str_equal);
                            // Disable scripts for this notification
                            _hints.insert ("SWAYNC_NO_SCRIPT", true);
                            _hints.insert ("urgency",
                                           UrgencyLevels.CRITICAL.to_byte ());

                            string _summary = "Failed to run script: %s".printf (key);
                            string _body = "<b>Output:</b> " + error_msg;
                            this.new_notification ("SwayNotificationCenter",
                                                   0,
                                                   "dialog-error",
                                                   _summary,
                                                   _body,
                                                   {},
                                                   _hints,
                                                   -1);
                        } catch (Error e) {
                            stderr.printf ("NOTIFING SCRIPT-FAIL ERROR: %s\n",
                                           e.message);
                        }
                    }
                });
                if (!ConfigModel.instance.script_continue_on_match) {
                    break;
                }
            }
#endif
        }

        /**
         * Causes a notification to be forcefully closed and removed from the
         * user's view. It can be used, for example, in the event that what
         * the notification pertains to is no longer relevant, or to cancel a
         * notification with no expiration time.
         *
         * The NotificationClosed signal is emitted by this method.
         *
         * If the notification no longer exists, an empty D-BUS Error message
         * is sent back.
         */
        [DBus (name = "CloseNotification")]
        public void close_notification (uint32 id) throws DBusError, IOError {
            uint32 carried_replace_id = 0;
            if (hc_hold.cancel_held (id, out carried_replace_id)) {
                debug ("Cancelled held notification ID:%u via CloseNotification", id);
                NotificationClosed (id, ClosedReasons.CLOSED_BY_CLOSENOTIFICATION);
                return;
            }
            request_dismiss_notification_id (id, ClosedReasons.CLOSED_BY_CLOSENOTIFICATION, false);
        }

        /**
         * This message returns the information on the server. Specifically, the
         * server name, vendor, and version number.
         */
        [DBus (name = "GetServerInformation")]
        public void get_server_information (out string name,
                                            out string vendor,
                                            out string version,
                                            out string spec_version)
        throws DBusError, IOError {
            name = "SwayNotificationCenter";
            vendor = "ErikReider";
            version = Constants.VERSIONNUM;
            spec_version = "1.3";
        }

        /**
         * A completed notification is one that has timed out, or has been
         * dismissed by the user.
         *
         * The ID specified in the signal is invalidated before the signal
         * is sent and may not be used in any further communications
         * with the server.
         */
        public signal void NotificationClosed (uint32 id, uint32 reason);

        /**
         * This signal is emitted when one of the following occurs:
         *
         * - The user performs some global "invoking" action upon a
         * notification. For instance, clicking somewhere on the
         * notification itself.
         *
         * - The user invokes a specific action as specified in the original
         * Notify request. For example, clicking on an action button.
         *
         * #Note
         *
         * Clients should not assume the server will generate this signal.
         * Some servers may not support user interaction at all, or may not
         * support the concept of being able to "invoke" a notification.
         */
        public signal void ActionInvoked (uint32 id, string action_key);

        /**
         * This signal can be emitted before a ActionInvoked signal. It
         * carries an activation token that can be used to activate a toplevel.
         */
        public signal void ActivationToken (uint32 id, string activation_token);

        /** To be used by the non-standard "inline-reply" capability */
        public signal void NotificationReplied (uint32 id, string text);
    }
}
