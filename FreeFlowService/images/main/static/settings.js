/**
 * Settings page manager.
 *
 * Manage the settings UI displayed in the macOS app's WKWebView.
 * Communicates with native code via the bridge to read/write settings
 * and stream live microphone levels.
 *
 * Bridge actions (settings -> native):
 *   - getSettings        — request current settings state
 *   - setSoundFeedback   — { enabled: bool }
 *   - setHotkey          — { modifierKey: string }
 *   - setLanguage        — { code: string }
 *   - listMicrophones    — request available input devices
 *   - selectMicrophone   — { id: number }
 *   - startMicPreview    — start streaming audio levels
 *   - stopMicPreview     — stop streaming audio levels
 *   - closeSettings      — dismiss the settings window
 *
 * Bridge events (native -> settings):
 *   - settingsState      — { soundFeedback, hotkey, language, languages }
 *   - microphoneList     — { devices: [...], currentId }
 *   - microphoneSelected — { id }
 *   - audioLevel         — { level }
 *
 * Depends on bridge.js (window.freeflowbridge).
 */
(function () {
  "use strict";

  var bridge = window.freeflowbridge;

  // Track whether mic preview is active so we can clean up.
  var micPreviewActive = false;

  // ----------------------------------------------------------------
  // Initialization
  // ----------------------------------------------------------------

  function init() {
    // Register bridge event listeners.
    bridge.on("settingsState", handleSettingsState);
    bridge.on("microphoneList", handleMicrophoneList);
    bridge.on("microphoneSelected", handleMicrophoneSelected);
    bridge.on("audioLevel", handleAudioLevel);

    // Wire up UI event handlers.
    bindControls();

    // Request current settings from native side.
    bridge.send("getSettings");

    // Request mic list and start preview.
    bridge.send("listMicrophones");
    bridge.send("startMicPreview");
    micPreviewActive = true;
  }

  // ----------------------------------------------------------------
  // Settings state
  // ----------------------------------------------------------------

  function handleSettingsState(data) {
    // Sound toggle
    if (data.soundFeedback !== undefined) {
      var toggle = document.getElementById("sound-toggle");
      if (toggle) {
        toggle.checked = !!data.soundFeedback;
      }
    }

    // Shortcut labels
    if (data.shortcuts && window._setShortcutLabel) {
      var s = data.shortcuts;
      if (s.dictate) window._setShortcutLabel("dictate", s.dictate);
      if (s.handsfree) window._setShortcutLabel("handsfree", s.handsfree);
      if (s.paste) window._setShortcutLabel("paste", s.paste);
      if (s.cancel) window._setShortcutLabel("cancel", s.cancel);
    }

    // Language select — populate options if provided
    if (data.languages && data.languages.length > 0) {
      populateLanguages(data.languages, data.language);
    } else if (data.language) {
      // Just select the current language if options already exist
      var langSelect = document.getElementById("language-select");
      if (langSelect) {
        langSelect.value = data.language;
      }
    }
  }

  function populateLanguages(languages, currentCode) {
    var select = document.getElementById("language-select");
    if (!select) return;

    select.innerHTML = "";

    for (var i = 0; i < languages.length; i++) {
      var lang = languages[i];
      var opt = document.createElement("option");
      opt.value = lang.code;
      opt.textContent = lang.name;
      if (lang.code === currentCode) {
        opt.selected = true;
      }
      select.appendChild(opt);
    }
  }

  // ----------------------------------------------------------------
  // Microphone list
  // ----------------------------------------------------------------

  function handleMicrophoneList(data) {
    var select = document.getElementById("mic-select");
    if (!select) return;

    var devices = (data && data.devices) || [];
    var currentId = data && data.currentId;

    select.innerHTML = "";

    for (var i = 0; i < devices.length; i++) {
      var d = devices[i];
      var opt = document.createElement("option");
      opt.value = d.id;
      opt.textContent = d.name + (d.isDefault ? " (default)" : "");
      if (d.id === currentId) {
        opt.selected = true;
      }
      select.appendChild(opt);
    }

    if (devices.length === 0) {
      var empty = document.createElement("option");
      empty.textContent = "No microphones found";
      empty.disabled = true;
      select.appendChild(empty);
    }
  }

  function handleMicrophoneSelected() {
    // Selection confirmed by native side. The dropdown already
    // reflects the choice from the user's interaction.
  }

  // ----------------------------------------------------------------
  // Audio level
  // ----------------------------------------------------------------

  function handleAudioLevel(data) {
    var level = (data && data.level) || 0;
    var bar = document.getElementById("mic-level-bar");
    if (!bar) return;

    // The level is already scaled by AudioCaptureProvider using
    // sqrt(rms * 25), so it is 0-1 and display-ready.
    var percent = Math.round(level * 100);
    bar.style.width = percent + "%";

    if (level > 0.05) {
      bar.classList.add("active");
    } else {
      bar.classList.remove("active");
    }
  }

  function resetMicLevel() {
    var bar = document.getElementById("mic-level-bar");
    if (bar) {
      bar.style.width = "0%";
      bar.classList.remove("active");
    }
  }

  // ----------------------------------------------------------------
  // Control bindings
  // ----------------------------------------------------------------

  function bindControls() {
    // Sound toggle
    var soundToggle = document.getElementById("sound-toggle");
    if (soundToggle) {
      soundToggle.addEventListener("change", function () {
        bridge.send("setSoundFeedback", { enabled: soundToggle.checked });
      });
    }

    // Hotkey recorder is wired in the inline script block via
    // window._setHotkeyLabel and direct bridge.send calls.

    // Language select
    var langSelect = document.getElementById("language-select");
    if (langSelect) {
      langSelect.addEventListener("change", function () {
        bridge.send("setLanguage", { code: langSelect.value });
      });
    }

    // Mic select
    var micSelect = document.getElementById("mic-select");
    if (micSelect) {
      micSelect.addEventListener("change", function () {
        var id = parseInt(micSelect.value, 10);
        if (!isNaN(id)) {
          bridge.send("selectMicrophone", { id: id });
        }
      });
    }

    // Done button
    var doneBtn = document.getElementById("done-btn");
    if (doneBtn) {
      doneBtn.addEventListener("click", function (e) {
        e.preventDefault();
        cleanup();
        bridge.send("closeSettings");
      });
    }
  }

  // ----------------------------------------------------------------
  // Cleanup
  // ----------------------------------------------------------------

  function cleanup() {
    if (micPreviewActive) {
      bridge.send("stopMicPreview");
      micPreviewActive = false;
      resetMicLevel();
    }
  }

  // Stop mic preview if the page is unloaded (window closed, etc.).
  window.addEventListener("beforeunload", function () {
    cleanup();
  });

  // ----------------------------------------------------------------
  // Start
  // ----------------------------------------------------------------

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
