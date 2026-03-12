/**
 * People page manager.
 *
 * Manage the people/invites UI displayed in the macOS app's WKWebView.
 * Communicates with native code via the bridge to create/revoke invites
 * and display the list of people in the user's network.
 *
 * Bridge actions (people -> native):
 *   - getPeopleState — request current people state
 *   - createInvite   — { name: string|null, email: string|null }
 *   - revokeInvite   — { id: number }
 *   - copyText       — { text: string }
 *   - openBilling    — open billing flow
 *   - closePeople    — close the window
 *
 * Bridge events (native -> people):
 *   - peopleState    — { hasCreditCard, invites, people }
 *   - inviteCreated  — { invite: { id, name, email, inviteUrl, createdAt } }
 *   - inviteRevoked  — { id }
 *   - actionError    — { message }
 *   - pageError      — { message }
 *   - toast          — { message }
 *
 * Depends on bridge.js (window.freeflowbridge).
 */
(function () {
  "use strict";

  var bridge = window.freeflowbridge;

  var state = {
    loading: true,
    hasCreditCard: false,
    invites: [],
    people: [],
    creatingInvite: false,
    lastCreatedInvite: null,
  };

  // ----------------------------------------------------------------
  // Initialization
  // ----------------------------------------------------------------

  function init() {
    // Register bridge event listeners.
    bridge.on("peopleState", handlePeopleState);
    bridge.on("inviteCreated", handleInviteCreated);
    bridge.on("inviteRevoked", handleInviteRevoked);
    bridge.on("actionError", handleActionError);
    bridge.on("pageError", handlePageError);
    bridge.on("toast", handleToast);

    // Wire up UI event handlers.
    bindControls();

    // Request current people state from native side.
    bridge.send("getPeopleState");
  }

  // ----------------------------------------------------------------
  // People state
  // ----------------------------------------------------------------

  function handlePeopleState(data) {
    state.hasCreditCard = !!(data && data.hasCreditCard);
    state.invites = (data && data.invites) || [];
    state.people = (data && data.people) || [];
    state.loading = false;
    render();
  }

  // ----------------------------------------------------------------
  // Render
  // ----------------------------------------------------------------

  function render() {
    var loadingState = document.getElementById("loading-state");
    var errorState = document.getElementById("error-state");
    var lockedState = document.getElementById("locked-state");
    var inviteSection = document.getElementById("invite-section");
    var invitesSection = document.getElementById("invites-section");
    var peopleSection = document.getElementById("people-section");

    // Hide loading
    if (loadingState) {
      loadingState.style.display = "none";
    }

    // Make sure error state is hidden during normal render
    if (errorState) {
      errorState.style.display = "none";
    }

    if (state.hasCreditCard) {
      // Unlocked: show invite form, hide locked state
      if (lockedState) {
        lockedState.style.display = "none";
      }
      if (inviteSection) {
        inviteSection.style.display = "";
      }
    } else {
      // Locked: show locked state, hide invite form
      if (lockedState) {
        lockedState.style.display = "";
      }
      if (inviteSection) {
        inviteSection.style.display = "none";
      }
    }

    // Always show invites and people sections after loading
    if (invitesSection) {
      invitesSection.style.display = "";
    }
    if (peopleSection) {
      peopleSection.style.display = "";
    }

    renderInvites();
    renderPeople();
  }

  // ----------------------------------------------------------------
  // Render invites
  // ----------------------------------------------------------------

  function renderInvites() {
    var invitesList = document.getElementById("invites-list");
    var invitesCount = document.getElementById("invites-count");
    var invitesEmpty = document.getElementById("invites-empty");

    // Filter to pending invites only
    var pending = [];
    for (var i = 0; i < state.invites.length; i++) {
      var inv = state.invites[i];
      if (!inv.revoked && inv.useCount < inv.maxUses) {
        pending.push(inv);
      }
    }

    // Update count badge
    if (invitesCount) {
      invitesCount.textContent = String(pending.length);
    }

    if (pending.length === 0) {
      // Show empty state
      if (invitesEmpty) {
        invitesEmpty.style.display = "";
      }
      if (invitesList) {
        invitesList.innerHTML = "";
      }
      return;
    }

    // Hide empty state
    if (invitesEmpty) {
      invitesEmpty.style.display = "none";
    }

    // Build invite rows
    var html = "";
    for (var j = 0; j < pending.length; j++) {
      var invite = pending[j];
      // Use name, fall back to label (API field), then default
      var name = invite.name || invite.label || "Unnamed invite";
      var metaParts = [];
      if (invite.email) {
        metaParts.push(escapeHtml(invite.email));
      }
      if (invite.createdAt) {
        metaParts.push(formatDate(invite.createdAt));
      }
      var meta = metaParts.join(" &middot; ");
      var url = invite.inviteUrl || "";
      var hasUrl = url && url.length > 0;

      html += '<div class="invite-row">';
      html += '<div class="invite-info">';
      html += '<div class="invite-name">' + escapeHtml(name) + "</div>";
      html += '<div class="invite-meta">' + meta + "</div>";
      html += "</div>";
      html += '<div class="invite-actions">';
      // Disable copy button if no URL available
      html +=
        '<button class="btn btn-small' +
        (hasUrl ? "" : " disabled") +
        '" data-copy-url="' +
        escapeAttr(url) +
        '"' +
        (hasUrl ? "" : " disabled") +
        ">Copy link</button>";
      html += '<button class="btn btn-small btn-danger" data-revoke-id="' + invite.id + '">Revoke</button>';
      html += "</div>";
      html += "</div>";
    }

    if (invitesList) {
      invitesList.innerHTML = html;
      wireInviteButtons(invitesList);
    }
  }

  function wireInviteButtons(container) {
    // Copy link buttons
    var copyBtns = container.querySelectorAll("[data-copy-url]");
    for (var i = 0; i < copyBtns.length; i++) {
      (function (btn) {
        btn.addEventListener("click", function (e) {
          e.preventDefault();
          if (btn.disabled) return;
          var url = btn.getAttribute("data-copy-url");
          if (url && url.length > 0) {
            bridge.send("copyText", { text: url });
            btn.textContent = "Copied!";
            setTimeout(function () {
              btn.textContent = "Copy link";
            }, 2000);
          }
        });
      })(copyBtns[i]);
    }

    // Revoke buttons
    var revokeBtns = container.querySelectorAll("[data-revoke-id]");
    for (var j = 0; j < revokeBtns.length; j++) {
      (function (btn) {
        btn.addEventListener("click", function (e) {
          e.preventDefault();
          var id = parseInt(btn.getAttribute("data-revoke-id"), 10);
          if (!isNaN(id)) {
            bridge.send("revokeInvite", { id: id });
          }
        });
      })(revokeBtns[j]);
    }
  }

  // ----------------------------------------------------------------
  // Render people
  // ----------------------------------------------------------------

  function renderPeople() {
    var peopleList = document.getElementById("people-list");
    var peopleCount = document.getElementById("people-count");
    var peopleEmpty = document.getElementById("people-empty");

    var count = state.people.length;

    // Update count badge
    if (peopleCount) {
      peopleCount.textContent = String(count);
    }

    if (count <= 1) {
      // Only admin (or nobody), show empty state
      if (peopleEmpty) {
        peopleEmpty.style.display = "";
        peopleEmpty.textContent = "You're the only person here.";
      }
      if (peopleList) {
        peopleList.innerHTML = "";
      }
      // Still render the single admin row if there is one
      if (count === 1) {
        if (peopleList) {
          peopleList.innerHTML = buildPersonRow(state.people[0]);
        }
      }
      return;
    }

    // Hide empty state
    if (peopleEmpty) {
      peopleEmpty.style.display = "none";
    }

    // Build person rows
    var html = "";
    for (var i = 0; i < state.people.length; i++) {
      html += buildPersonRow(state.people[i]);
    }

    if (peopleList) {
      peopleList.innerHTML = html;
    }
  }

  function buildPersonRow(person) {
    var name = person.name || "Unnamed";
    var email = person.email || "No email on file";
    var adminBadge = person.isAdmin ? ' <span class="admin-badge">Admin</span>' : "";

    var html = '<div class="person-row">';
    html += '<div class="person-info">';
    html += '<div class="person-name">' + escapeHtml(name) + adminBadge + "</div>";
    html += '<div class="person-meta">' + escapeHtml(email) + "</div>";
    html += "</div>";
    html += "</div>";
    return html;
  }

  // ----------------------------------------------------------------
  // Invite created
  // ----------------------------------------------------------------

  function handleInviteCreated(data) {
    var invite = data && data.invite;
    if (!invite) return;

    // Add to the beginning of the invites list
    state.invites.unshift(invite);
    state.lastCreatedInvite = invite;

    // Show success message with invite URL
    var inviteSuccess = document.getElementById("invite-success");
    var inviteUrlDisplay = document.getElementById("invite-url-display");
    var copyInviteBtn = document.getElementById("copy-invite-btn");

    if (inviteSuccess) {
      inviteSuccess.style.display = "";
    }
    if (inviteUrlDisplay) {
      inviteUrlDisplay.textContent = invite.inviteUrl || "";
    }
    if (copyInviteBtn) {
      copyInviteBtn.onclick = function (e) {
        e.preventDefault();
        if (invite.inviteUrl) {
          bridge.send("copyText", { text: invite.inviteUrl });
          copyInviteBtn.textContent = "Copied!";
          setTimeout(function () {
            copyInviteBtn.textContent = "Copy link";
          }, 2000);
        }
      };
    }

    // Clear input fields
    var nameInput = document.getElementById("invite-name");
    var emailInput = document.getElementById("invite-email");
    if (nameInput) {
      nameInput.value = "";
    }
    if (emailInput) {
      emailInput.value = "";
    }

    // Re-enable create button
    var createBtn = document.getElementById("create-invite-btn");
    if (createBtn) {
      createBtn.disabled = false;
      createBtn.textContent = "Create invite";
    }
    state.creatingInvite = false;

    // Update the invites list
    renderInvites();
  }

  // ----------------------------------------------------------------
  // Invite revoked
  // ----------------------------------------------------------------

  function handleInviteRevoked(data) {
    var id = data && data.id;
    if (id === undefined || id === null) return;

    // Mark the invite as revoked in state
    for (var i = 0; i < state.invites.length; i++) {
      if (state.invites[i].id === id) {
        state.invites[i].revoked = true;
        break;
      }
    }

    renderInvites();
    showToast("Invite revoked");
  }

  // ----------------------------------------------------------------
  // Action error
  // ----------------------------------------------------------------

  function handleActionError(data) {
    var message = (data && data.message) || "An error occurred";

    if (state.creatingInvite) {
      var createBtn = document.getElementById("create-invite-btn");
      if (createBtn) {
        createBtn.disabled = false;
        createBtn.textContent = "Create invite";
      }
    }
    state.creatingInvite = false;

    showToast(message);
  }

  // ----------------------------------------------------------------
  // Page error
  // ----------------------------------------------------------------

  function handlePageError(data) {
    var message = (data && data.message) || "An unexpected error occurred";

    var errorState = document.getElementById("error-state");
    var errorMessage = document.getElementById("error-message");
    var loadingState = document.getElementById("loading-state");
    var lockedState = document.getElementById("locked-state");
    var inviteSection = document.getElementById("invite-section");
    var invitesSection = document.getElementById("invites-section");
    var peopleSection = document.getElementById("people-section");

    // Show error state
    if (errorState) {
      errorState.style.display = "";
    }
    if (errorMessage) {
      errorMessage.textContent = message;
    }

    // Hide everything else
    if (loadingState) {
      loadingState.style.display = "none";
    }
    if (lockedState) {
      lockedState.style.display = "none";
    }
    if (inviteSection) {
      inviteSection.style.display = "none";
    }
    if (invitesSection) {
      invitesSection.style.display = "none";
    }
    if (peopleSection) {
      peopleSection.style.display = "none";
    }
  }

  // ----------------------------------------------------------------
  // Toast
  // ----------------------------------------------------------------

  function handleToast(data) {
    var message = (data && data.message) || "";
    showToast(message);
  }

  function showToast(message) {
    var toast = document.getElementById("toast");
    if (!toast) return;

    toast.textContent = message;
    toast.classList.add("visible");

    setTimeout(function () {
      toast.classList.remove("visible");
    }, 3000);
  }

  // ----------------------------------------------------------------
  // Control bindings
  // ----------------------------------------------------------------

  function bindControls() {
    // Create invite button
    var createBtn = document.getElementById("create-invite-btn");
    if (createBtn) {
      createBtn.addEventListener("click", function (e) {
        e.preventDefault();
        if (state.creatingInvite) return;

        var nameInput = document.getElementById("invite-name");
        var emailInput = document.getElementById("invite-email");
        var name = nameInput ? nameInput.value.trim() : "";
        var email = emailInput ? emailInput.value.trim() : "";

        // Hide previous success message
        var inviteSuccess = document.getElementById("invite-success");
        if (inviteSuccess) {
          inviteSuccess.style.display = "none";
        }

        state.creatingInvite = true;
        createBtn.disabled = true;
        createBtn.textContent = "Creating...";

        bridge.send("createInvite", {
          name: name || null,
          email: email || null,
        });
      });
    }

    // Done button
    var doneBtn = document.getElementById("done-btn");
    if (doneBtn) {
      doneBtn.addEventListener("click", function (e) {
        e.preventDefault();
        bridge.send("closePeople");
      });
    }

    // Add card button
    var addCardBtn = document.getElementById("add-card-btn");
    if (addCardBtn) {
      addCardBtn.addEventListener("click", function (e) {
        e.preventDefault();
        bridge.send("openBilling");
      });
    }

    // Retry button
    var retryBtn = document.getElementById("retry-btn");
    if (retryBtn) {
      retryBtn.addEventListener("click", function (e) {
        e.preventDefault();
        var errorState = document.getElementById("error-state");
        var loadingState = document.getElementById("loading-state");

        if (errorState) {
          errorState.style.display = "none";
        }
        if (loadingState) {
          loadingState.style.display = "";
        }

        state.loading = true;
        bridge.send("getPeopleState");
      });
    }
  }

  // ----------------------------------------------------------------
  // Utilities
  // ----------------------------------------------------------------

  function formatDate(isoString) {
    if (!isoString) return "";
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    var d = new Date(isoString);
    if (isNaN(d.getTime())) return "";
    return months[d.getMonth()] + " " + d.getDate() + ", " + d.getFullYear();
  }

  function escapeHtml(str) {
    if (!str) return "";
    return str
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function escapeAttr(str) {
    if (!str) return "";
    return str
      .replace(/&/g, "&amp;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
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
