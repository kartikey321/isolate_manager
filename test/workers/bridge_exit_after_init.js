// IsolateBridge worker that signals initialized and then crashes immediately.
// Used to regression-test the post-init/pre-listener-install startup race.

self.postMessage({ type: '$IsolateState', value: 'initialized' });
queueMicrotask(function() {
  throw new Error('deliberate immediate post-init Worker crash');
});
