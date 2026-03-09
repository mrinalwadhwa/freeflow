/**
 * Bridge between web pages and the native macOS app (WKWebView).
 *
 * When running inside the app's WKWebView, messages are sent via
 * window.webkit.messageHandlers.voice.postMessage(). The native side
 * pushes events back by calling window.voicebridge.onEvent(data).
 *
 * When running in a normal browser (for development/testing), send()
 * is a no-op that logs to the console, and onEvent can be called
 * manually from the browser console to simulate native responses.
 */
(function () {
    "use strict";

    var inWebView = !!(
        window.webkit &&
        window.webkit.messageHandlers &&
        window.webkit.messageHandlers.voice
    );

    /**
     * Send an action to the native side.
     *
     * @param {string} action - The action name (e.g. "redeemInvite").
     * @param {Object} [data] - Optional payload data.
     */
    function send(action, data) {
        var message = { action: action };
        if (data !== undefined && data !== null) {
            message.data = data;
        }

        if (inWebView) {
            window.webkit.messageHandlers.voice.postMessage(message);
        } else {
            console.log("[bridge] send:", JSON.stringify(message));
        }
    }

    /**
     * Whether we are running inside a WKWebView with the native bridge.
     *
     * @returns {boolean}
     */
    function isNative() {
        return inWebView;
    }

    // Event listeners registered via bridge.on().
    var listeners = {};

    /**
     * Register a listener for a specific event type.
     *
     * @param {string} eventName - The event name (e.g. "inviteRedeemed").
     * @param {Function} callback - Called with the event data object.
     */
    function on(eventName, callback) {
        if (!listeners[eventName]) {
            listeners[eventName] = [];
        }
        listeners[eventName].push(callback);
    }

    /**
     * Remove a previously registered listener.
     *
     * @param {string} eventName - The event name.
     * @param {Function} callback - The exact function reference to remove.
     */
    function off(eventName, callback) {
        if (!listeners[eventName]) return;
        listeners[eventName] = listeners[eventName].filter(function (fn) {
            return fn !== callback;
        });
    }

    /**
     * Remove all listeners for an event, or all listeners entirely.
     *
     * @param {string} [eventName] - If omitted, clears all listeners.
     */
    function clear(eventName) {
        if (eventName) {
            delete listeners[eventName];
        } else {
            listeners = {};
        }
    }

    /**
     * Called by the native side to deliver an event.
     * Also callable from the browser console for testing:
     *   window.voicebridge.onEvent({ event: "inviteRedeemed", user: { name: "Alice" } })
     *
     * @param {Object} data - Event payload. Must include an "event" field.
     */
    function onEvent(data) {
        if (!data || !data.event) {
            console.warn("[bridge] onEvent called without event field:", data);
            return;
        }

        if (!inWebView) {
            console.log("[bridge] onEvent:", JSON.stringify(data));
        }

        var eventName = data.event;
        var cbs = listeners[eventName];
        if (cbs && cbs.length > 0) {
            for (var i = 0; i < cbs.length; i++) {
                try {
                    cbs[i](data);
                } catch (err) {
                    console.error(
                        "[bridge] Error in listener for " + eventName + ":",
                        err
                    );
                }
            }
        }
    }

    // Public API exposed as window.voicebridge.
    window.voicebridge = {
        send: send,
        on: on,
        off: off,
        clear: clear,
        onEvent: onEvent,
        isNative: isNative,
    };
})();
