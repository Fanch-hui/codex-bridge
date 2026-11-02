(function () {
  "use strict";

  if (new URLSearchParams(window.location.search).get("surface") === "preferences") {
    document.documentElement.dataset.surface = "preferences";
  }
  var platform = new URLSearchParams(window.location.search).get("platform");
  if (platform === "windows" || platform === "linux") {
    document.documentElement.dataset.platform = platform;
  }
}());
