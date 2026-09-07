const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function createHarness(scripts, rootIDs = []) {
  const document = { activeElement: null };
  class Element {
    constructor(tag) {
      this.tagName = tag; this.children = []; this.dataset = {}; this.listeners = {};
      this._value = ""; this.checked = false; this.disabled = false;
      this.selectionStart = 0; this.selectionEnd = 0; this.className = "";
      this.classList = { toggle: () => {}, add: () => {}, remove: () => {} };
    }
    get firstChild() { return this.children[0]; }
    get lastChild() { return this.children[this.children.length - 1]; }
    get childNodes() { return this.children; }
    get options() { return findAll(this, node => node.tagName === "option"); }
    get selectedIndex() { return this.options.findIndex(option => option.value === this.value); }
    get value() { return this._value; }
    set value(value) { this._value = value; }
    get textContent() { return this._text || ""; }
    set textContent(value) { this._text = value; this.children = []; }
    appendChild(child) {
      if (child.parentNode) child.parentNode.removeChild(child);
      child.parentNode = this; this.children.push(child);
      if (this.tagName === "select" && child.selected) this.value = child.value;
      return child;
    }
    insertBefore(child, reference) {
      if (child.parentNode) child.parentNode.removeChild(child);
      child.parentNode = this; this.children.splice(this.children.indexOf(reference), 0, child);
      return child;
    }
    removeChild(child) {
      this.children.splice(this.children.indexOf(child), 1); child.parentNode = null;
    }
    remove() { if (this.parentNode) this.parentNode.removeChild(this); }
    addEventListener(name, callback) { (this.listeners[name] ||= []).push(callback); }
    dispatch(name, event = {}) { for (const callback of this.listeners[name] || []) callback(event); }
    setAttribute(key, value) { this[key] = value; }
    getAttribute(key) { return this[key]; }
    contains(child) { return this === child || this.children.some(node => node.contains(child)); }
    querySelector(selector) { return find(this, node => matches(node, selector)); }
    querySelectorAll(selector) { return findAll(this, node => matches(node, selector)); }
    focus() { document.activeElement = this; }
    setSelectionRange(start, end, direction) {
      this.selectionStart = start; this.selectionEnd = end; this.selectionDirection = direction;
    }
  }
  function matches(node, selector) {
    if (selector[0] === ".") return node.className.split(" ").includes(selector.slice(1));
    if (selector[0] === "#") return node.id === selector.slice(1);
    return node.tagName === selector;
  }
  function find(root, predicate) { return findAll(root, predicate)[0] || null; }
  function findAll(root, predicate) {
    return (predicate(root) ? [root] : []).concat(root.children.flatMap(child => findAll(child, predicate)));
  }
  const roots = rootIDs.map(id => { const element = new Element("div"); element.id = id; return element; });
  document.createElement = tag => new Element(tag);
  document.createTextNode = text => { const node = new Element("#text"); node.textContent = text; return node; };
  document.getElementById = id => roots.map(root => find(root, node => node.id === id)).find(Boolean) || null;
  const window = { confirm: () => true };
  const context = vm.createContext({ window, document, TextEncoder, URL });
  const resources = path.join(__dirname, "../Packages/BridgeCore/Sources/BridgeDesktopUI/Resources");
  function load(name) { vm.runInContext(fs.readFileSync(path.join(resources, name), "utf8"), context); }
  scripts.forEach(load);
  return { document, window, roots, find, findAll, load };
}

module.exports = { createHarness };
