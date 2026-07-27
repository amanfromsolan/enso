// Hash-based router: one panel visible at a time, sidebar tracks it.
// The second-level rail (.subnav) shows the active section's file list;
// the Nth item in a rail group pairs with the Nth pane in that section.

(function () {
  var panels = Array.prototype.slice.call(document.querySelectorAll(".panel"));
  var navItems = Array.prototype.slice.call(document.querySelectorAll(".nav-item"));
  var subnav = document.getElementById("subnav");
  var groups = Array.prototype.slice.call(document.querySelectorAll(".subnav-group"));
  var order = panels.map(function (p) { return p.id; });

  function show(id) {
    if (order.indexOf(id) === -1) id = "overview";

    panels.forEach(function (p) { p.classList.toggle("active", p.id === id); });
    navItems.forEach(function (a) {
      a.classList.toggle("active", a.getAttribute("href") === "#" + id);
    });

    var hasRail = false;
    groups.forEach(function (g) {
      var match = g.dataset.for === id;
      g.classList.toggle("active", match);
      if (match) hasRail = true;
    });
    subnav.classList.toggle("hidden", !hasRail);

    window.scrollTo(0, 0);
  }

  window.addEventListener("hashchange", function () {
    show(location.hash.slice(1));
  });

  show(location.hash.slice(1) || "overview");

  // Wire each rail group's items to its section's panes.
  // Selection persists while flipping sections.
  groups.forEach(function (group) {
    var section = document.getElementById(group.dataset.for);
    if (!section) return;
    var tabs = group.querySelectorAll(".filetab");
    var panes = section.querySelectorAll(".filepane");

    function select(idx) {
      Array.prototype.forEach.call(tabs, function (t, i) {
        t.classList.toggle("active", i === idx);
      });
      Array.prototype.forEach.call(panes, function (p, i) {
        p.classList.toggle("active", i === idx);
      });
    }

    Array.prototype.forEach.call(tabs, function (tab, i) {
      tab.addEventListener("click", function () { select(i); });
    });

    select(0);
  });
})();
