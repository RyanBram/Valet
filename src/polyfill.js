(function () {
  // =========================================================================
  // VALET POLYFILL - NW.js COMPATIBILITY LAYER (HTTP API VERSION)
  // This polyfill enables NW.js apps to run in Valet browser-based server
  // Filesystem operations use HTTP API endpoints instead of native bindings
  // =========================================================================

  // Determine base path from current document URL
  var basePath = ".";
  var serverOrigin = window.location.origin;

  // Get base directory from server
  window.__valetBaseDir = "";
  (function initBaseDir() {
    var xhr = new XMLHttpRequest();
    xhr.open("GET", "/__get_base_dir__", false);
    try {
      xhr.send(null);
      if (xhr.status === 200) {
        window.__valetBaseDir = xhr.responseText;
      }
    } catch (e) {}
  })();

  // =========================================================================
  // NODE.JS GLOBAL POLYFILLS
  // =========================================================================

  if (typeof window.__dirname === "undefined") {
    window.__dirname = "";
    try {
      var pathParts = window.location.pathname.split("/");
      pathParts.pop();
      window.__dirname = pathParts.join("/") || "/";
    } catch (e) {
      window.__dirname = "/";
    }
  }

  if (typeof window.__filename === "undefined") {
    window.__filename = window.location.pathname || "/index.html";
  }

  // =========================================================================
  // PROCESS OBJECT
  // =========================================================================

  if (typeof window.process === "undefined") {
    var _processStartTime = performance.now();

    window.process = {
      platform: "win32",
      versions: {
        node: "12.0.0",
        nw: "0.45.0",
      },
      mainModule: {
        filename: window.__valetBaseDir + "\\index.html",
      },
      cwd: function () {
        return window.__valetBaseDir || basePath;
      },
      on: function () {},
      argv: [],
      hrtime: function (previousTimestamp) {
        var nowMs = performance.now();
        if (previousTimestamp) {
          var prevTotalMs = previousTimestamp[0] * 1000 + previousTimestamp[1] / 1e6;
          var diffMs = nowMs - _processStartTime - prevTotalMs;
          var diffSeconds = Math.floor(diffMs / 1000);
          var diffNanos = Math.round((diffMs % 1000) * 1e6);
          return [diffSeconds, diffNanos];
        } else {
          var elapsedMs = nowMs - _processStartTime;
          var seconds = Math.floor(elapsedMs / 1000);
          var nanos = Math.round((elapsedMs % 1000) * 1e6);
          return [seconds, nanos];
        }
      },
    };

    window.process.hrtime.bigint = function () {
      var nowMs = performance.now();
      var elapsedMs = nowMs - _processStartTime;
      if (typeof BigInt !== "undefined") {
        return BigInt(Math.round(elapsedMs * 1e6));
      } else {
        return Math.round(elapsedMs * 1e6);
      }
    };
  }

  // =========================================================================
  // NW OBJECT
  // =========================================================================

  if (typeof window.nw === "undefined") {
    window.nw = {
      Window: {
        get: function () {
          return {
            focus: function () { window.focus(); },
            blur: function () { window.blur(); },
            showDevTools: function () { /* N/A in browser */ },
            toggleFullscreen: function () {
              if (document.fullscreenElement) {
                document.exitFullscreen();
              } else {
                document.body.requestFullscreen();
              }
            },
            enterFullscreen: function () {
              if (!document.fullscreenElement) {
                document.body.requestFullscreen();
              }
            },
            leaveFullscreen: function () {
              if (document.fullscreenElement) {
                document.exitFullscreen();
              }
            },
            get isFullscreen() { return !!document.fullscreenElement; },
            on: function () {},
            get x() { return window.screenX || 0; },
            get y() { return window.screenY || 0; },
            get width() { return window.outerWidth || 800; },
            get height() { return window.outerHeight || 600; },
            get title() { return document.title || ""; },
            set title(val) { document.title = val; },
            minimize: function () { /* N/A in browser */ },
            maximize: function () { /* N/A in browser */ },
            restore: function () { /* N/A in browser */ },
            close: function () { window.close(); },
          };
        },
      },
      App: {
        quit: function () { window.close(); },
        closeAllWindows: function () { window.close(); },
        clearCache: function () { /* N/A */ },
        dataPath: window.__valetBaseDir,
        manifest: {},
        argv: [],
        fullArgv: [],
      },
      Shell: {
        openExternal: function (url) { window.open(url, "_blank"); },
        openItem: function (path) { console.log("[Valet] openItem:", path); },
      },
    };
  }

  // =========================================================================
  // GLOBAL REQUIRE FUNCTION
  // =========================================================================

  if (typeof window.require === "undefined") {
    window.require = function (moduleName) {
      // Path module
      if (moduleName === "path") {
        return {
          sep: "\\",
          dirname: function (p) {
            if (!p || typeof p !== "string") return ".";
            p = p.replace(/\//g, "\\");
            var lastSlash = p.lastIndexOf("\\");
            if (lastSlash === -1) return ".";
            if (lastSlash === 0) return "\\";
            return p.substring(0, lastSlash);
          },
          basename: function (p, ext) {
            if (!p || typeof p !== "string") return "";
            p = p.replace(/\//g, "\\");
            var lastSlash = p.lastIndexOf("\\");
            var base = lastSlash === -1 ? p : p.substring(lastSlash + 1);
            if (ext && base.endsWith(ext)) {
              base = base.substring(0, base.length - ext.length);
            }
            return base;
          },
          extname: function (p) {
            if (!p || typeof p !== "string") return "";
            var base = this.basename(p);
            var dotIndex = base.lastIndexOf(".");
            if (dotIndex <= 0) return "";
            return base.substring(dotIndex);
          },
          join: function () {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) {
              if (arguments[i]) parts.push(arguments[i]);
            }
            return this.normalize(parts.join("\\"));
          },
          normalize: function (p) {
            if (!p || typeof p !== "string") return ".";
            p = p.replace(/\//g, "\\");
            p = p.replace(/\\+/g, "\\");
            return p;
          },
          isAbsolute: function (p) {
            if (!p || typeof p !== "string") return false;
            return /^[a-zA-Z]:[\\\/]/.test(p) || p.startsWith("\\\\");
          },
        };
      }

      // OS module
      if (moduleName === "os") {
        return {
          platform: function () { return "win32"; },
          arch: function () { return "x64"; },
          homedir: function () {
            if (window.__valetBaseDir) {
              var parts = window.__valetBaseDir.split("\\");
              if (parts.length >= 3) {
                return parts[0] + "\\" + parts[1] + "\\" + parts[2];
              }
            }
            return "C:\\Users\\User";
          },
        };
      }

      // FS module - uses HTTP API endpoints
      if (moduleName === "fs") {
        return {
          existsSync: function (filePath) {
            if (!filePath) return false;
            try {
              var xhr = new XMLHttpRequest();
              xhr.open("GET", "/__fs_exists__?path=" + encodeURIComponent(filePath), false);
              xhr.send(null);
              return xhr.status === 200 && xhr.responseText === "true";
            } catch (e) {
              return false;
            }
          },

          readFileSync: function (filePath, options) {
            try {
              var xhr = new XMLHttpRequest();
              xhr.open("GET", "/__fs_read__?path=" + encodeURIComponent(filePath), false);
              xhr.send(null);
              if (xhr.status === 200) {
                return xhr.responseText;
              }
              return null;
            } catch (e) {
              return null;
            }
          },

          writeFileSync: function (filePath, data) {
            try {
              var xhr = new XMLHttpRequest();
              xhr.open("POST", "/__fs_write__", false);
              xhr.setRequestHeader("Content-Type", "application/json");
              xhr.send(JSON.stringify({ path: filePath, content: data }));
            } catch (e) {
              console.error("[Valet] writeFileSync error:", e);
            }
          },

          mkdirSync: function (dirPath, options) {
            try {
              var xhr = new XMLHttpRequest();
              xhr.open("POST", "/__fs_mkdir__", false);
              xhr.setRequestHeader("Content-Type", "application/json");
              xhr.send(JSON.stringify({ path: dirPath }));
            } catch (e) {
              // Directory might exist, ignore
            }
          },

          unlinkSync: function (filePath) {
            try {
              var xhr = new XMLHttpRequest();
              xhr.open("POST", "/__fs_unlink__", false);
              xhr.setRequestHeader("Content-Type", "application/json");
              xhr.send(JSON.stringify({ path: filePath }));
            } catch (e) {
              console.error("[Valet] unlinkSync error:", e);
            }
          },

          readdirSync: function (dirPath) {
            try {
              var xhr = new XMLHttpRequest();
              xhr.open("GET", "/__fs_list_dir__?path=" + encodeURIComponent(dirPath), false);
              xhr.send(null);
              if (xhr.status === 200) {
                return JSON.parse(xhr.responseText);
              }
              return [];
            } catch (e) {
              return [];
            }
          },

          // Async versions (for RPG Maker compatibility)
          writeFile: function (filePath, data, callback) {
            var xhr = new XMLHttpRequest();
            xhr.open("POST", "/__fs_write__", true);
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.onload = function () {
              if (callback) callback(xhr.status === 200 ? null : new Error("Write failed"));
            };
            xhr.onerror = function () {
              if (callback) callback(new Error("Write failed"));
            };
            xhr.send(JSON.stringify({ path: filePath, content: data }));
          },

          readFile: function (filePath, encoding, callback) {
            if (typeof encoding === "function") {
              callback = encoding;
            }
            var xhr = new XMLHttpRequest();
            xhr.open("GET", "/__fs_read__?path=" + encodeURIComponent(filePath), true);
            xhr.onload = function () {
              if (xhr.status === 200) {
                if (callback) callback(null, xhr.responseText);
              } else {
                if (callback) callback(new Error("File not found"));
              }
            };
            xhr.onerror = function () {
              if (callback) callback(new Error("Read failed"));
            };
            xhr.send(null);
          },

          mkdir: function (dirPath, options, callback) {
            if (typeof options === "function") {
              callback = options;
            }
            var xhr = new XMLHttpRequest();
            xhr.open("POST", "/__fs_mkdir__", true);
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.onload = function () {
              if (callback) callback(null);
            };
            xhr.onerror = function () {
              if (callback) callback(null); // Dir might exist
            };
            xhr.send(JSON.stringify({ path: dirPath }));
          },

          exists: function (filePath, callback) {
            var xhr = new XMLHttpRequest();
            xhr.open("GET", "/__fs_exists__?path=" + encodeURIComponent(filePath), true);
            xhr.onload = function () {
              if (callback) callback(xhr.status === 200 && xhr.responseText === "true");
            };
            xhr.onerror = function () {
              if (callback) callback(false);
            };
            xhr.send(null);
          },

          readdir: function (dirPath, callback) {
            var xhr = new XMLHttpRequest();
            xhr.open("GET", "/__fs_list_dir__?path=" + encodeURIComponent(dirPath), true);
            xhr.onload = function () {
              if (xhr.status === 200) {
                if (callback) callback(null, JSON.parse(xhr.responseText));
              } else {
                if (callback) callback(null, []);
              }
            };
            xhr.onerror = function () {
              if (callback) callback(null, []);
            };
            xhr.send(null);
          },

          statSync: function (filePath) {
            return {
              size: 0,
              isFile: function () { return true; },
              isDirectory: function () { return false; },
              mtime: new Date(),
              ctime: new Date(),
              atime: new Date(),
            };
          },
        };
      }

      // Nw.gui for legacy NW.js
      if (moduleName === "nw.gui") {
        return window.nw;
      }

      console.warn("[Valet] Unknown module:", moduleName);
      return {};
    };
  }

  console.log("[Valet] Polyfill loaded - NW.js compatibility enabled");
})();
