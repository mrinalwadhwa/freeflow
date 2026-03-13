/**
 * Onboarding step manager.
 *
 * Manage the split-path onboarding flow displayed in the macOS app's
 * WKWebView. Manual launch and deep-link launch have different intents:
 *
 *   - manual launch: user must choose between joining with an invite
 *     or setting up their own FreeFlow
 *   - invite deep link: skip the chooser and go straight into connect
 *
 * After the entry choice, all users continue through the same device
 * setup flow (permissions, microphone selection, try-it, done), but
 * copy and transitions are tailored to whether the user is joining or
 * setting up their own FreeFlow.
 *
 * Depends on bridge.js (window.freeflowbridge).
 */
(function () {
  "use strict";

  var bridge = window.freeflowbridge;
  var steps = ["connect", "accessibility", "microphone", "microphone-select", "try-it", "done"];
  var currentIndex = -1;
  var sections = {};
  var indicators = [];
  var transitioning = false;

  var flow = {
    mode: "chooser", // chooser | invite | admin
    hasToken: false,
    skipConnect: false,
  };

  // Permission state tracked across events.
  var permissions = {
    accessibility: "unknown",
    microphone: "unknown",
  };

  // ----------------------------------------------------------------
  // Initialization
  // ----------------------------------------------------------------

  function init() {
    // Cache section elements.
    for (var i = 0; i < steps.length; i++) {
      var el = document.querySelector('[data-step="' + steps[i] + '"]');
      if (el) {
        sections[steps[i]] = el;
      }
    }

    // Cache step indicator dots.
    var dots = document.querySelectorAll(".step-indicator-dot");
    for (var j = 0; j < dots.length; j++) {
      indicators.push(dots[j]);
    }

    // Register bridge event listeners.
    bridge.on("inviteRedeemed", handleInviteRedeemed);
    bridge.on("inviteRedeemFailed", handleInviteRedeemFailed);
    bridge.on("permissionStatus", handlePermissionStatus);
    bridge.on("microphoneList", handleMicrophoneList);
    bridge.on("microphoneSelected", handleMicrophoneSelected);
    bridge.on("audioLevel", handleAudioLevel);
    bridge.on("dictationResult", handleDictationResult);
    bridge.on("tokenStored", handleTokenStored);

    // Wire up button click handlers.
    bindButtons();

    // Determine entry path.
    flow.hasToken = !!getQueryParam("token");
    flow.skipConnect = getQueryParam("skip") === "connect";

    if (flow.hasToken) {
      flow.mode = "invite";
      configureFlowUI();
      goTo(0);
      startConnect(getQueryParam("token"));
      return;
    }

    if (flow.skipConnect) {
      flow.mode = "admin";
      configureFlowUI();
      goTo(1);
      return;
    }

    flow.mode = "chooser";
    configureFlowUI();
    goTo(0);
    showConnectState("choice");
  }

  // ----------------------------------------------------------------
  // Navigation
  // ----------------------------------------------------------------

  function goTo(index) {
    if (index < 0 || index >= steps.length) return;
    if (index === currentIndex) return;
    if (transitioning) return;

    var prevIndex = currentIndex;
    currentIndex = index;

    transitioning = true;

    // Hide previous section.
    if (prevIndex >= 0 && sections[steps[prevIndex]]) {
      var prev = sections[steps[prevIndex]];
      prev.classList.remove("step-active");
      prev.classList.add("step-exit");
    }

    // Update step indicators.
    updateIndicators();

    // Stop mic preview when leaving the microphone-select step.
    if (prevIndex >= 0 && steps[prevIndex] === "microphone-select") {
      bridge.send("stopMicPreview");
      resetMicLevel();
    }

    // Show new section after a brief delay for the exit transition.
    var delay = prevIndex >= 0 ? 200 : 0;
    setTimeout(function () {
      // Finish hiding the previous section.
      if (prevIndex >= 0 && sections[steps[prevIndex]]) {
        sections[steps[prevIndex]].classList.remove("step-exit");
        sections[steps[prevIndex]].classList.add("step-hidden");
      }

      // Show the new section.
      var next = sections[steps[currentIndex]];
      if (next) {
        next.classList.remove("step-hidden", "step-exit");
        next.classList.add("step-active");
      }

      transitioning = false;

      // Run entry action for the new step.
      onStepEnter(steps[currentIndex]);
    }, delay);
  }

  function next() {
    goTo(currentIndex + 1);
  }

  function back() {
    goTo(currentIndex - 1);
  }

  function updateIndicators() {
    var hiddenIndicator = flow.mode === "chooser" && currentIndex === 0;

    for (var i = 0; i < indicators.length; i++) {
      indicators[i].classList.remove("active", "completed");
      indicators[i].style.visibility = hiddenIndicator ? "hidden" : "visible";

      if (hiddenIndicator) continue;

      if (i < currentIndex) {
        indicators[i].classList.add("completed");
      } else if (i === currentIndex) {
        indicators[i].classList.add("active");
      }
    }
  }

  // ----------------------------------------------------------------
  // Step entry actions
  // ----------------------------------------------------------------

  function onStepEnter(step) {
    switch (step) {
      case "connect":
        if (flow.mode === "chooser") {
          showConnectState("choice");
        } else if (flow.mode === "invite" && !flow.hasToken) {
          showConnectState("waiting");
        }
        break;

      case "accessibility":
        bridge.send("checkAccessibility");
        startPermissionPolling("accessibility");
        break;

      case "microphone":
        // Check current status first; request on button tap.
        bridge.send("checkAccessibility");
        break;

      case "microphone-select":
        bridge.send("listMicrophones");
        bridge.send("startMicPreview");
        break;

      case "try-it":
        bridge.send("registerHotkey");
        clearTryItArea();
        break;

      case "done":
        // Nothing to do on entry.
        break;
    }
  }

  // ----------------------------------------------------------------
  // Connect step
  // ----------------------------------------------------------------

  function startConnect(token) {
    flow.mode = "invite";
    configureFlowUI();
    showConnectState("loading");
    bridge.send("redeemInvite", { token: token });
  }

  function handleInviteRedeemed(data) {
    flow.mode = "invite";
    configureFlowUI();
    showConnectState("success");
    var nameEl = document.getElementById("connect-user-name");
    if (nameEl) {
      if (data && data.user && data.user.name) {
        nameEl.textContent = " " + data.user.name;
      } else {
        nameEl.textContent = "";
      }
    }
    // Auto-advance after a short pause.
    setTimeout(function () {
      next();
    }, 1200);
  }

  function handleInviteRedeemFailed(data) {
    flow.mode = "invite";
    configureFlowUI();
    showConnectState("error");
    var msgEl = document.getElementById("connect-error-message");
    if (msgEl) {
      msgEl.textContent = (data && data.error) || "Could not connect. Please try again.";
    }
  }

  function showConnectState(state) {
    var states = ["choice", "waiting", "loading", "success", "error"];
    for (var i = 0; i < states.length; i++) {
      var el = document.getElementById("connect-" + states[i]);
      if (el) {
        if (states[i] === state) {
          el.classList.remove("hidden");
        } else {
          el.classList.add("hidden");
        }
      }
    }
  }

  function configureFlowUI() {
    updateStepLabels();

    if (flow.mode === "invite") {
      setText("connect-waiting-title", "Open your invite link");
      setText(
        "connect-waiting-copy",
        "Open the invite link that a person sent you in your browser. FreeFlow will connect automatically on this Mac.",
      );
      setText("waiting-setup-admin", "Create my own server instead");
      setText("connect-loading-title", "Connecting you to FreeFlow");
      setText("connect-loading-copy", "Setting up FreeFlow on this Mac\u2026");
      setText("connect-success-title", "You\u2019re connected");
      setText("connect-success-copy", 'Welcome<span id="connect-user-name"></span>! FreeFlow is ready on this Mac.');
      setText("connect-error-title", "Couldn\u2019t connect");
      setText("done-title", "You\u2019re all set");
      setText("done-copy", "FreeFlow lives in your menu bar. Hold Right Option any time to dictate.");
    } else if (flow.mode === "admin") {
      setText("connect-loading-title", "Create your FreeFlow server");
      setText("connect-loading-copy", "We\u2019re setting up your private FreeFlow server and preparing this Mac.");
      setText("connect-success-title", "Your FreeFlow server is ready");
      setText("connect-success-copy", 'Welcome<span id="connect-user-name"></span>! Your FreeFlow server is ready.');
      setText("connect-error-title", "Setup couldn\u2019t continue");
      setText("done-title", "Your FreeFlow server is ready");
      setText("done-copy", "FreeFlow lives in your menu bar. You can invite others anytime from People.");
    } else {
      setText("connect-waiting-title", "Open your invite link");
      setText(
        "connect-waiting-copy",
        "Open the invite link that a person sent you in your browser. FreeFlow will connect automatically on this Mac.",
      );
      setText("waiting-setup-admin", "Create my own server instead");
      setText("connect-loading-title", "Connecting you to FreeFlow");
      setText("connect-loading-copy", "Setting things up on this Mac\u2026");
      setText("connect-success-title", "You\u2019re connected");
      setText("connect-success-copy", 'Welcome<span id="connect-user-name"></span>! FreeFlow is ready on this Mac.');
      setText("connect-error-title", "Couldn\u2019t connect");
      setText("done-title", "You\u2019re all set");
      setText("done-copy", "FreeFlow lives in your menu bar. Hold Right Option any time to dictate.");
    }
  }

  function updateStepLabels() {
    var tryItSkip = document.getElementById("try-it-skip");
    var doneFinish = document.getElementById("done-finish");

    if (flow.mode === "invite") {
      if (tryItSkip) tryItSkip.textContent = "Skip for now";
      if (doneFinish) doneFinish.textContent = "Finish";
    } else if (flow.mode === "admin") {
      if (tryItSkip) tryItSkip.textContent = "Skip for now";
      if (doneFinish) doneFinish.textContent = "Open FreeFlow";
    } else {
      if (tryItSkip) tryItSkip.textContent = "Skip for now";
      if (doneFinish) doneFinish.textContent = "Finish";
    }
  }

  function chooseInvitePath() {
    flow.mode = "invite";
    configureFlowUI();

    var token = getQueryParam("token");
    if (token) {
      startConnect(token);
      return;
    }

    showConnectState("waiting");
  }

  function chooseAdminPath() {
    flow.mode = "admin";
    configureFlowUI();
    bridge.send("openProvisioning");
  }

  // ----------------------------------------------------------------
  // Accessibility step
  // ----------------------------------------------------------------

  var accessibilityPollTimer = null;

  function startPermissionPolling(type) {
    stopPermissionPolling();
    accessibilityPollTimer = setInterval(function () {
      bridge.send("checkAccessibility");
    }, 2000);
  }

  function stopPermissionPolling() {
    if (accessibilityPollTimer) {
      clearInterval(accessibilityPollTimer);
      accessibilityPollTimer = null;
    }
  }

  function handlePermissionStatus(data) {
    if (data.accessibility !== undefined) {
      permissions.accessibility = data.accessibility;
      updateAccessibilityUI();
    }
    if (data.microphone !== undefined) {
      permissions.microphone = data.microphone;
      updateMicrophoneUI();
    }
  }

  function updateAccessibilityUI() {
    var granted = permissions.accessibility === "granted";
    var btn = document.getElementById("accessibility-open-settings");
    var status = document.getElementById("accessibility-status");
    var continueBtn = document.getElementById("accessibility-continue");

    if (status) {
      if (granted) {
        status.textContent = "Accessibility access granted.";
        status.className = "permission-status permission-granted";
      } else {
        status.textContent = "Waiting for accessibility access\u2026";
        status.className = "permission-status permission-waiting";
      }
    }

    if (btn) {
      btn.classList.toggle("hidden", granted);
    }

    if (continueBtn) {
      continueBtn.disabled = !granted;
    }

    // Stop polling and auto-advance once granted.
    if (granted && steps[currentIndex] === "accessibility") {
      stopPermissionPolling();
      setTimeout(function () {
        next();
      }, 800);
    }
  }

  // ----------------------------------------------------------------
  // Microphone step
  // ----------------------------------------------------------------

  function updateMicrophoneUI() {
    var granted = permissions.microphone === "granted";
    var btn = document.getElementById("microphone-request");
    var status = document.getElementById("microphone-status");
    var continueBtn = document.getElementById("microphone-continue");

    if (status) {
      if (granted) {
        status.textContent = "Microphone access granted.";
        status.className = "permission-status permission-granted";
      } else if (permissions.microphone === "denied") {
        status.textContent =
          "Microphone access denied. Open System Settings \u2192 Privacy & Security \u2192 Microphone to enable it.";
        status.className = "permission-status permission-denied";
      } else {
        status.textContent = "";
        status.className = "permission-status";
      }
    }

    if (btn) {
      btn.classList.toggle("hidden", granted);
    }

    if (continueBtn) {
      continueBtn.disabled = !granted;
    }

    // Auto-advance if already granted when entering this step.
    if (granted && steps[currentIndex] === "microphone") {
      setTimeout(function () {
        next();
      }, 800);
    }
  }

  // ----------------------------------------------------------------
  // Microphone selector
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
    // Selection confirmed by native side. Could show a brief
    // indicator, but the dropdown already reflects the choice.
  }

  function handleAudioLevel(data) {
    var level = (data && data.level) || 0;
    var fill = document.getElementById("mic-level-fill");
    if (!fill) return;

    // The level is already scaled by AudioCaptureProvider using
    // sqrt(rms * 25), so it's 0-1 and display-ready. Use directly.
    var percent = Math.round(level * 100);

    fill.style.width = percent + "%";

    if (level > 0.05) {
      fill.classList.add("active");
    } else {
      fill.classList.remove("active");
    }
  }

  function resetMicLevel() {
    var fill = document.getElementById("mic-level-fill");
    if (fill) {
      fill.style.width = "0%";
      fill.classList.remove("active");
    }
  }

  function onMicSelectChange() {
    var select = document.getElementById("mic-select");
    if (!select) return;
    var id = parseInt(select.value, 10);
    if (!isNaN(id)) {
      bridge.send("selectMicrophone", { id: id });
    }
  }

  // ----------------------------------------------------------------
  // Try-it step
  // ----------------------------------------------------------------

  function handleDictationResult(data) {
    var area = document.getElementById("try-it-textarea");
    if (!area) return;

    var text = (data && data.text) || "";
    if (text) {
      area.value = (area.value ? area.value + " " : "") + text;
      area.classList.add("try-it-received");
      setTimeout(function () {
        area.classList.remove("try-it-received");
        area.classList.add("try-it-has-text");
      }, 600);
    }

    // Show success indicator and enable the done button.
    var hint = document.getElementById("try-it-success");
    if (hint) {
      hint.classList.add("visible");
    }
    var doneBtn = document.getElementById("try-it-done");
    if (doneBtn) {
      doneBtn.disabled = false;
    }
  }

  function clearTryItArea() {
    var area = document.getElementById("try-it-textarea");
    if (area) {
      area.value = "";
      area.classList.remove("try-it-received", "try-it-has-text");
    }
    var hint = document.getElementById("try-it-success");
    if (hint) hint.classList.remove("visible");
  }

  // ----------------------------------------------------------------
  // Done step / token stored
  // ----------------------------------------------------------------

  function handleTokenStored() {
    // Token stored confirmation. Used by account pages, not
    // typically needed during onboarding, but handle gracefully.
  }

  function completeOnboarding() {
    bridge.send("completeOnboarding");
  }

  // ----------------------------------------------------------------
  // Button wiring
  // ----------------------------------------------------------------

  function bindButtons() {
    // Connect: chooser actions.
    bindClick("entry-join-invite", function () {
      chooseInvitePath();
    });

    bindClick("entry-setup-admin", function () {
      chooseAdminPath();
    });

    // Waiting state: switch to admin path.
    bindClick("waiting-setup-admin", function () {
      chooseAdminPath();
    });

    // Connect: retry button.
    bindClick("connect-retry", function () {
      var token = getQueryParam("token");
      if (token) {
        startConnect(token);
      } else if (flow.mode === "invite") {
        showConnectState("waiting");
        var msgEl = document.getElementById("connect-error-message");
        if (msgEl) {
          msgEl.textContent = "Click your invite link in your browser to connect this Mac to a FreeFlow server.";
        }
      }
    });

    bindClick("connect-back-to-choice", function () {
      flow.mode = "chooser";
      configureFlowUI();
      showConnectState("choice");
      updateIndicators();
    });

    // Accessibility: open settings.
    bindClick("accessibility-open-settings", function () {
      bridge.send("openAccessibilitySettings");
    });

    // Accessibility: continue.
    bindClick("accessibility-continue", function () {
      next();
    });

    // Microphone: request permission.
    bindClick("microphone-request", function () {
      bridge.send("requestMicrophone");
    });

    // Microphone: continue.
    bindClick("microphone-continue", function () {
      next();
    });

    // Mic selector: device change.
    var micSelect = document.getElementById("mic-select");
    if (micSelect) {
      micSelect.addEventListener("change", onMicSelectChange);
    }

    // Mic select: continue.
    bindClick("mic-select-continue", function () {
      next();
    });

    // Try-it: done / finish.
    bindClick("try-it-done", function () {
      next();
    });

    // Try-it: skip (allow skipping without dictating).
    bindClick("try-it-skip", function () {
      next();
    });

    // Done: finish onboarding.
    bindClick("done-finish", function () {
      completeOnboarding();
    });
  }

  function bindClick(id, handler) {
    var el = document.getElementById(id);
    if (el) {
      el.addEventListener("click", function (e) {
        e.preventDefault();
        handler();
      });
    }
  }

  // ----------------------------------------------------------------
  // Utilities
  // ----------------------------------------------------------------

  function getQueryParam(name) {
    var params = new URLSearchParams(window.location.search);
    return params.get(name);
  }

  function setText(id, text) {
    var el = document.getElementById(id);
    if (!el) return;
    el.innerHTML = text;
  }

  // ----------------------------------------------------------------
  // Start
  // ----------------------------------------------------------------

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
