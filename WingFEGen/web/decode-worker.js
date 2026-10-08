/* Decode large binary payloads off the UI thread; transfer their blob storage back. */
importScripts("vendor/msgpack.min.js");
self.onmessage = event => {
  try {
    const data = MessagePack.decode(new Uint8Array(event.data));
    const buffers = new Set();
    function visit(value) {
      if (!value || typeof value !== "object") return;
      if (ArrayBuffer.isView(value)) { buffers.add(value.buffer); return; }
      if (value instanceof ArrayBuffer) { buffers.add(value); return; }
      for (const child of Object.values(value)) visit(child);
    }
    visit(data); self.postMessage({data}, Array.from(buffers));
  } catch (error) { self.postMessage({error:error.message}); }
};
