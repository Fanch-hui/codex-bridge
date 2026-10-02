(function () {
  "use strict";

  var platform = new URLSearchParams(window.location.search).get("platform");
  if (platform === "windows" || platform === "linux") {
    document.documentElement.dataset.platform = platform;
  }
}());
