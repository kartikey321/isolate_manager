// JS Worker used by browser tests to verify IsolateBridge initialParams
// delivery ordering and message echo behavior.

self.onmessage = function initialParamsHandler(e) {
  var data = e.data;

  self.postMessage({ type: 'data', value: data });
  self.postMessage({ type: '$IsolateState', value: 'initialized' });

  self.onmessage = function(e) {
    var message = e.data;
    if (message !== null && typeof message === 'object' &&
        message['type'] === '$IsolateState' && message['value'] === 'dispose') {
      self.close();
      return;
    }
    self.postMessage({ type: 'data', value: message });
  };
};
