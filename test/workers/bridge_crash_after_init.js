// IsolateBridge worker that crashes on its first non-initial-params message.
// Used to verify that worker.onerror after init surfaces as a stream error.

self.onmessage = function() {
  self.postMessage({ type: '$IsolateState', value: 'initialized' });

  self.onmessage = function(e) {
    var data = e.data;
    if (data !== null && typeof data === 'object' &&
        data['type'] === '$IsolateState' && data['value'] === 'dispose') {
      self.close();
      return;
    }
    // Deliberate uncaught throw — triggers worker.onerror on the main side.
    throw new Error('deliberate post-init Worker crash for O1 test');
  };
};
