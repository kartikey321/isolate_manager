// Minimal IsolateBridge echo worker for browser tests.
//
// Wire protocol (Worker → Main):
//   Init:   { type: '$IsolateState', value: 'initialized' }
//   Result: { type: 'data', value: <echoed value> }
//
// Wire protocol (Main → Worker):
//   Initial params: <raw JS value>
//   Dispose: { type: '$IsolateState', value: 'dispose' }
//   Message: <raw JS value>

self.onmessage = function() {
  self.postMessage({ type: '$IsolateState', value: 'initialized' });

  self.onmessage = function(e) {
    var data = e.data;
    if (data !== null && typeof data === 'object' &&
        data['type'] === '$IsolateState' && data['value'] === 'dispose') {
      self.close();
      return;
    }
    self.postMessage({ type: 'data', value: data });
  };
};
