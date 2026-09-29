/// JavaScript injected into every frame of the MediaSpace web view at document start. It reports
/// Kaltura identifiers to the `lecternKaltura` message handler as soon as they are visible:
///
/// - stream / API URLs seen by `fetch`, `XMLHttpRequest` and media elements (the signed
///   `playManifest/entryId/…/ks/…` URL and `ks=` query parameters),
/// - JSON request bodies of Kaltura API calls,
/// - the player configuration (`KalturaPlayer`, `kalturaIframePackageData`) and inline scripts that embed it.
///
/// Messages are `{partnerId, entryId, ks}` with `null` for what the observation didn't contain.
enum MediaSpaceBrowserScript {
    static let handlerName = "lecternKaltura"

    static let source = #"""
    (function () {
      'use strict';
      if (window.__lecternKaltura) return;
      window.__lecternKaltura = true;
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lecternKaltura;
      if (!handler) return;

      var sent = {};
      function send(partnerId, entryId, ks) {
        if (!partnerId && !entryId && !ks) return;
        var key = [partnerId, entryId, ks].join('|');
        if (sent[key]) return;
        sent[key] = true;
        handler.postMessage({ partnerId: partnerId || null, entryId: entryId || null, ks: ks || null });
      }

      var KS_IN_URL = /(?:\/ks\/|[?&]ks=)([A-Za-z0-9_=-]{20,})/;
      var ENTRY_IN_URL = /\/entryId\/([0-9]_[a-z0-9]{8})(?:[\/?]|$)/;
      var PARTNER_IN_URL = /\/p\/(\d+)\/|[?&]partnerId=(\d+)/;

      function inspectURL(url) {
        if (typeof url !== 'string' || url.indexOf('kaltura') < 0) return;
        var ks = KS_IN_URL.exec(url), entry = ENTRY_IN_URL.exec(url), partner = PARTNER_IN_URL.exec(url);
        if (ks || entry) send(partner && (partner[1] || partner[2]), entry && entry[1], ks && ks[1]);
      }

      function inspectBody(body) {
        if (typeof body !== 'string' || body.length > 200000) return;
        var ks = /"ks"\s*:\s*"([A-Za-z0-9_=-]{20,})"/.exec(body);
        if (!ks) return;
        var entry = /"entryId"\s*:\s*"([0-9]_[a-z0-9]{8})"/.exec(body);
        var partner = /"partnerId"\s*:\s*"?(\d+)/.exec(body);
        send(partner && partner[1], entry && entry[1], ks[1]);
      }

      // Network hooks.
      var originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function (input, init) {
          try {
            inspectURL(typeof input === 'string' ? input : input && input.url);
            if (init && init.body) inspectBody(init.body);
          } catch (e) {}
          return originalFetch.apply(this, arguments);
        };
      }
      var proto = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
      if (proto) {
        var open = proto.open, sendXHR = proto.send;
        proto.open = function (method, url) {
          try { inspectURL(String(url)); } catch (e) {}
          return open.apply(this, arguments);
        };
        proto.send = function (body) {
          try { inspectBody(body); } catch (e) {}
          return sendXHR.apply(this, arguments);
        };
      }

      function inspectMedia(element) {
        if (element && (element.tagName === 'VIDEO' || element.tagName === 'AUDIO')) {
          inspectURL(element.currentSrc || element.src);
        }
      }

      // Player configuration.
      function scanGlobals() {
        try {
          if (window.KalturaPlayer && typeof KalturaPlayer.getPlayers === 'function') {
            var players = KalturaPlayer.getPlayers();
            Object.keys(players).forEach(function (id) {
              var p = players[id], cfg = p.config || {}, provider = cfg.provider || {};
              var entry = (cfg.sources && cfg.sources.id) || (p.sources && p.sources.id);
              send(provider.partnerId, entry, provider.ks);
            });
          }
        } catch (e) {}
        try {
          var data = window.kalturaIframePackageData;
          if (data) {
            var provider = (data.playerConfig && data.playerConfig.provider) || {};
            var meta = data.entryResult && (data.entryResult.meta || data.entryResult.entry);
            send(provider.partnerId || data.partnerId, meta && meta.id, provider.ks || (data.entryResult && data.entryResult.ks));
          }
        } catch (e) {}
      }

      // Inline scripts that embed the player config (MediaSpace renders it into the page).
      var scanned = new WeakSet();
      function scanScripts() {
        var scripts = document.scripts;
        for (var i = 0; i < scripts.length; i++) {
          var script = scripts[i];
          if (script.src || scanned.has(script)) continue;
          scanned.add(script);
          var text = script.textContent;
          if (!text || text.length < 200 || text.indexOf('"provider"') < 0) continue;
          var m = /"provider"\s*:\s*\{\s*"partnerId"\s*:\s*"?(\d+)"?[\s\S]{0,4000}?"ks"\s*:\s*"([A-Za-z0-9_=-]{20,})"/.exec(text);
          if (m) send(m[1], null, m[2]);
        }
      }

      function scan() { scanGlobals(); scanScripts(); }
      ['play', 'playing', 'loadstart'].forEach(function (type) {
        document.addEventListener(type, function (event) { inspectMedia(event.target); scan(); }, true);
      });
      document.addEventListener('DOMContentLoaded', scan);
      window.addEventListener('load', scan);
      var ticks = 0;
      var timer = setInterval(function () { scan(); if (++ticks >= 40) clearInterval(timer); }, 1500);
    })();
    """#
}
