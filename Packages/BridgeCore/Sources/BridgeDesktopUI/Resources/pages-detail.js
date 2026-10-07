(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function create(container) {
    var overview = S.node("div", "detail-overview");
    var detail = S.node("section", "detail-page");
    var header = S.node("div", "detail-header");
    var backButton = S.button("返回", null, {}, null, "detail-back");
    var title = S.node("h2", "detail-heading");
    var content = S.node("div", "detail-content");
    var storage = S.node("div", "detail-storage");
    var entries = new Map(), selected = null, parentScroll = 0;
    detail.hidden = true; storage.hidden = true; overview.tabIndex = -1;
    backButton.insertBefore(S.icon("chevron.left"), backButton.firstChild);
    header.appendChild(backButton); header.appendChild(title);
    detail.appendChild(header); detail.appendChild(content);
    container.appendChild(overview); container.appendChild(detail); container.appendChild(storage);
    backButton.addEventListener("click", back);

    function scrollHost() { return document.querySelector(".content-scroll") || container; }

    function open(id) {
      var entry = entries.get(id);
      if (!entry || entry.root.hidden || selected === id) return;
      var scroll = scrollHost();
      if (selected === null) parentScroll = scroll.scrollTop || 0;
      else storage.appendChild(entries.get(selected).body);
      selected = id;
      overview.hidden = true; detail.hidden = false;
      title.textContent = entry.title;
      detail.setAttribute("aria-label", entry.title);
      content.appendChild(entry.body);
      scroll.scrollTop = 0;
      backButton.focus({ preventScroll: true });
    }

    function back(restoreFocus) {
      if (selected === null) return;
      var entry = entries.get(selected);
      storage.appendChild(entry.body);
      selected = null; detail.hidden = true; overview.hidden = false;
      scrollHost().scrollTop = parentScroll;
      (restoreFocus === false ? overview : entry.root).focus({ preventScroll: true });
    }

    function register(id, label, body) {
      if (entries.has(id)) return entries.get(id);
      var root = S.node("button", "detail-row"); root.type = "button";
      var copy = S.node("span", "detail-row-copy");
      var name = S.node("span", "detail-row-title", label);
      var value = S.node("span", "detail-row-value");
      var accessory = S.node("span", "detail-row-accessory");
      copy.appendChild(name); copy.appendChild(value);
      root.appendChild(copy); root.appendChild(accessory);
      root.appendChild(S.icon("chevron.right", "detail-row-chevron"));
      root.dataset.detailID = id;
      root.setAttribute("aria-label", label);
      storage.appendChild(body);
      var entry = {
        root: root, body: body, value: value, accessory: accessory, title: label,
        open: function () { open(id); },
        update: function (next) {
          if (next.title !== undefined) {
            entry.title = next.title; name.textContent = next.title;
            root.setAttribute("aria-label", next.title);
            if (selected === id) title.textContent = next.title;
          }
          if (next.value !== undefined) { value.textContent = next.value || ""; value.hidden = !next.value; }
          if (next.available !== undefined) {
            if (!next.available && selected === id) back(false);
            root.hidden = !next.available;
          }
        }
      };
      value.hidden = true;
      root.addEventListener("click", entry.open);
      entries.set(id, entry);
      return entry;
    }

    function remove(id) {
      var entry = entries.get(id);
      if (!entry) return;
      if (selected === id) back(false);
      entry.root.remove(); entry.body.remove(); entries.delete(id);
    }

    return { overview: overview, register: register, open: open, back: back,
      remove: remove, selectedID: function () { return selected; } };
  }

  global.CodexBridgeDesktopDetailPages = { create: create };
}(window));
