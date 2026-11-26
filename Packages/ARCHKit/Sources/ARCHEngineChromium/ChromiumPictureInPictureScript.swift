// Measures inline videos without reading or copying their pixels. Only Chromium installs this script.
import Foundation

enum ChromiumPictureInPictureScript {
    static let world = "ARCHPictureInPictureGeometry"
    static let refresh = "(channel) => JSON.stringify(globalThis.__archPictureInPictureGeometry?.(true) ?? null)"
    static let stop = #"{"tracking":false}"#

    /// Rectangles use the main document's layout viewport in CSS pixels. Scroll is already included by getBoundingClientRect; visual viewport offsets and scale remain explicit for the native conversion.
    static let source = #"""
    (channel) => {
      const documentID = Array.from(crypto.getRandomValues(new Uint32Array(4)), value => value.toString(16)).join('-');
      const identities = new WeakMap(), previous = new WeakMap();
      const documents = new WeakSet(), observed = new Set(), childReports = new Map(), relayedGeometry = new Map();
      const messageType = '__archPictureInPictureGeometry';
      let nextID = 0, lastReport = '', tracking = false, observer = null;
      const finite = value => Number.isFinite(value);
      const valid = rect => rect && [rect.x, rect.y, rect.width, rect.height].every(finite) && rect.width > 0 && rect.height > 0;
      const watch = doc => {
        if (!documents.has(doc)) {
          documents.add(doc);
          for (const event of ['loadedmetadata', 'loadeddata', 'playing', 'pause', 'ended', 'volumechange', 'emptied',
                               'enterpictureinpicture', 'leavepictureinpicture', 'scroll', 'load', 'DOMContentLoaded', 'visibilitychange'])
            doc.addEventListener(event, event === 'enterpictureinpicture' ? () => refresh() :
              event === 'load' ? () => { if (tracking) refresh(); } : () => publish(), true);
          doc.defaultView?.addEventListener('resize', () => publish());
        }
      };
      const collect = (doc, videos, targets) => {
        watch(doc);
        for (const video of doc.querySelectorAll('video')) { videos.push(video); targets.add(video); }
        for (const frame of doc.querySelectorAll('iframe, frame')) {
          targets.add(frame);
          try {
            if (frame.contentDocument) collect(frame.contentDocument, videos, targets);
          } catch {}
        }
      };
      const measure = (video, allowHidden) => {
        try {
          let win = video.ownerDocument.defaultView;
          if (!video.isConnected || (!allowHidden && (video.ownerDocument.hidden || document.hidden))) return null;
          const style = win.getComputedStyle(video);
          if (style.display === 'none' || style.visibility === 'hidden') return null;
          const box = video.getBoundingClientRect();
          let rect = { x: box.x, y: box.y, width: box.width, height: box.height };
          if (!valid(rect)) return null;
          while (win !== window) {
            const frame = win.frameElement;
            if (!frame || !frame.isConnected) return null;
            const frameBox = frame.getBoundingClientRect();
            const scaleX = frameBox.width / frame.offsetWidth, scaleY = frameBox.height / frame.offsetHeight;
            if (![scaleX, scaleY].every(value => finite(value) && value > 0)) return null;
            rect = { x: frameBox.x + (frame.clientLeft + rect.x) * scaleX,
                     y: frameBox.y + (frame.clientTop + rect.y) * scaleY,
                     width: rect.width * scaleX, height: rect.height * scaleY };
            win = frame.ownerDocument.defaultView;
          }
          const viewport = window.visualViewport;
          const viewportOffset = { x: viewport?.offsetLeft ?? 0, y: viewport?.offsetTop ?? 0 };
          const viewportScale = viewport?.scale ?? 1, devicePixelRatio = window.devicePixelRatio;
          const width = viewport?.width ?? window.innerWidth, height = viewport?.height ?? window.innerHeight;
          if (!valid(rect) || ![viewportOffset.x, viewportOffset.y, viewportScale, devicePixelRatio, width, height].every(finite) ||
              viewportScale <= 0 || devicePixelRatio <= 0 || width <= 0 || height <= 0 ||
              rect.x + rect.width <= viewportOffset.x || rect.y + rect.height <= viewportOffset.y ||
              rect.x >= viewportOffset.x + width || rect.y >= viewportOffset.y + height) return null;
          return { rect, viewportOffset, viewportScale, devicePixelRatio };
        } catch { return null; }
      };
      const directFrames = () => [...document.querySelectorAll('iframe, frame')];
      const relay = (frame, video) => {
        const old = relayedGeometry.get(video.id);
        try {
          const box = frame.getBoundingClientRect(), style = window.getComputedStyle(frame);
          const scaleX = box.width / frame.offsetWidth, scaleY = box.height / frame.offsetHeight;
          const viewport = window.visualViewport;
          const viewportOffset = { x: viewport?.offsetLeft ?? 0, y: viewport?.offsetTop ?? 0 };
          const viewportScale = viewport?.scale ?? 1, devicePixelRatio = window.devicePixelRatio;
          const rect = { x: box.x + (frame.clientLeft + (video.rect.x - video.viewportOffset.x) * video.viewportScale) * scaleX,
                         y: box.y + (frame.clientTop + (video.rect.y - video.viewportOffset.y) * video.viewportScale) * scaleY,
                         width: video.rect.width * video.viewportScale * scaleX, height: video.rect.height * video.viewportScale * scaleY };
          const width = viewport?.width ?? window.innerWidth, height = viewport?.height ?? window.innerHeight;
          if (!frame.isConnected || document.hidden || style.display === 'none' || style.visibility === 'hidden' ||
              !video.visible || !valid(rect) || ![scaleX, scaleY, viewportScale, devicePixelRatio].every(value => finite(value) && value > 0) ||
              rect.x + rect.width <= viewportOffset.x || rect.y + rect.height <= viewportOffset.y ||
              rect.x >= viewportOffset.x + width || rect.y >= viewportOffset.y + height)
            return old ? { ...video, ...old, visible: false, crossOrigin: true } : null;
          const geometry = { rect, viewportOffset, viewportScale, devicePixelRatio };
          relayedGeometry.set(video.id, geometry);
          return { ...video, ...geometry, crossOrigin: true };
        } catch { return old ? { ...video, ...old, visible: false, crossOrigin: true } : null; }
      };
      const snapshot = allowHidden => {
        const elements = [], targets = new Set();
        collect(document, elements, targets);
        for (const target of observed) if (!targets.has(target)) { observer.unobserve(target); observed.delete(target); }
        for (const target of targets) if (!observed.has(target)) { observed.add(target); observer.observe(target); }
        let activeID = null, activeIsCrossOrigin = false;
        const videos = elements.map(video => {
          if (!identities.has(video)) identities.set(video, `${documentID}:${++nextID}`);
          const id = identities.get(video);
          if (video.ownerDocument.pictureInPictureElement === video) activeID = id;
          const measured = measure(video, allowHidden);
          if (measured) previous.set(video, measured);
          const geometry = measured ?? previous.get(video);
          return geometry ? { id, ...geometry, visible: measured !== null } : null;
        }).filter(Boolean);
        const frames = directFrames(), aliveIDs = new Set();
        for (const [source, child] of childReports) {
          const frame = frames.find(value => value.contentWindow === source);
          if (!frame) { childReports.delete(source); continue; }
          let crossOrigin = true;
          try { crossOrigin = !frame.contentDocument; } catch {}
          for (const video of child.videos) {
            if (!crossOrigin && !video.crossOrigin) continue;
            aliveIDs.add(video.id);
            const mapped = relay(frame, video);
            if (mapped) videos.push(mapped);
          }
          if (!activeID && child.activeID && (crossOrigin || child.activeIsCrossOrigin)) {
            activeID = child.activeID; activeIsCrossOrigin = true;
          }
        }
        for (const id of relayedGeometry.keys()) if (!aliveIDs.has(id)) relayedGeometry.delete(id);
        return { documentID, videos, activeID, activeIsCrossOrigin };
      };
      function publish(force = false, allowHidden = false) {
        if (!tracking) return null;
        const report = snapshot(allowHidden), text = JSON.stringify(report);
        if (text !== lastReport || (force === true && window !== window.top)) {
          lastReport = text;
          if (window === window.top) channel.send(report).catch(() => {});
          else window.parent.postMessage({ type: messageType, report }, '*');
        }
        return report;
      }
      function beginTracking() {
        if (tracking) return;
        tracking = true;
        observer = new ResizeObserver(() => publish());
      }
      function stopTracking() {
        tracking = false;
        observer?.disconnect();
        observer = null;
        observed.clear();
        lastReport = '';
        for (const frame of directFrames()) frame.contentWindow?.postMessage({ type: messageType, tracking: false }, '*');
      }
      function refresh(allowHidden = false) {
        beginTracking();
        // Child measurements arrive asynchronously. Keep their rectangles, but require a fresh active-video identity.
        for (const child of childReports.values()) { child.activeID = null; child.activeIsCrossOrigin = false; }
        for (const frame of directFrames()) frame.contentWindow?.postMessage({ type: messageType, refresh: true }, '*');
        return publish(true, allowHidden === true);
      }
      window.addEventListener('message', event => {
        const data = event.data;
        if (!data || data.type !== messageType) return;
        if (data.tracking === false) {
          if (window !== window.top && event.source === window.parent) stopTracking();
          return;
        }
        if (data.refresh === true) {
          if (window !== window.top && event.source === window.parent) refresh();
          return;
        }
        // Native entry requests refresh the frame tree. Late reports from a finished
        // presentation cannot turn idle geometry tracking back on.
        if (!tracking || !directFrames().some(frame => frame.contentWindow === event.source)) return;
        const report = data.report;
        const identifier = value => typeof value === 'string' && value.length > 0 && value.length <= 128;
        if (!report || !identifier(report.documentID) || !Array.isArray(report.videos) || report.videos.length > 256 ||
            (report.activeID !== null && !identifier(report.activeID))) return;
        const videos = report.videos.filter(video => video && identifier(video.id) && valid(video.rect) &&
          video.viewportOffset && [video.viewportOffset.x, video.viewportOffset.y].every(finite) &&
          finite(video.viewportScale) && video.viewportScale > 0 && finite(video.devicePixelRatio) && video.devicePixelRatio > 0)
          .map(video => ({ id: video.id,
            rect: { x: video.rect.x, y: video.rect.y, width: video.rect.width, height: video.rect.height },
            viewportOffset: { x: video.viewportOffset.x, y: video.viewportOffset.y },
            viewportScale: video.viewportScale, devicePixelRatio: video.devicePixelRatio,
            visible: video.visible === true, crossOrigin: video.crossOrigin === true }));
        childReports.set(event.source, { videos, activeID: report.activeID, activeIsCrossOrigin: report.activeIsCrossOrigin === true });
        publish();
      });
      Object.defineProperty(globalThis, '__archPictureInPictureGeometry', { value: refresh });
      window.visualViewport?.addEventListener('scroll', () => publish());
      window.visualViewport?.addEventListener('resize', () => publish());
      channel.onMessage(message => message?.tracking === false ? stopTracking() : refresh());
      // Inline media events only reach the tracking guard. No DOM traversal, layout read,
      // resize observer, or native report is needed until an actual PiP request.
      watch(document);
    }
    """#
}
