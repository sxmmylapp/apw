(function apwBridge() {
  const { port, token } = self.APW_CONFIG;
  const OK = 0, INVALID_SESSION = 9, SERVER_ERROR = 100;
  let ws, pending;
  const send = (message) => ws?.readyState === WebSocket.OPEN && ws.send(JSON.stringify(message));
  const fail = (id, status, error) => send({ id, status, error: String(error) });

  function request(message) {
    if (message.cmd === 2) {
      message.pin == null ? ChallengePIN() : PINSet(message.pin);
      return send({ id: message.id, status: OK });
    }
    if (g_theState !== "SessionKeySet") return fail(message.id, INVALID_SESSION, "unpaired");
    pending = { id: message.id, cmd: message.cmd };
    try {
      const SMSG = g_secretSession.createSMSG(JSON.stringify(message.body));
      g_nativeAppPort.postMessage({
        cmd: message.cmd,
        tabId: message.tabId,
        frameId: message.frameId,
        url: message.url,
        payload: JSON.stringify({ QID: message.qid, SMSG }),
      });
    } catch (error) {
      pending = null;
      fail(message.id, SERVER_ERROR, error);
    }
  }

  function reply(message) {
    if (!pending || message.cmd !== pending.cmd && !(pending.cmd === 6 && message.cmd === 4)) return;
    const { id } = pending;
    pending = null;
    try {
      const data = message.payload
        ? JSON.parse(g_secretSession.parseSMSG(message.payload.SMSG))
        : { STATUS: message.STATUS ?? OK };
      send({ id, data });
    } catch (error) {
      fail(id, SERVER_ERROR, error);
    }
  }

  function connect() {
    ws = new WebSocket(`ws://127.0.0.1:${port}`);
    ws.onopen = () => {
      send({ token });
      pairingSent = false;
      sendPairing();
    };
    ws.onerror = () => ws.close();
    ws.onclose = () => {
      pending = null;
      setTimeout(connect, 3000);
    };
    ws.onmessage = ({ data }) => request(JSON.parse(data));
  }
  if (!g_nativeAppPort) connectToBackgroundNativeAppAndSetUpListeners();
  g_nativeAppPort?.onMessage?.addListener(reply);

  // persist-pairing: report the SRP session to the daemon once paired, restore a saved one at start.
  const hex = (bits) => sjcl.codec.hex.fromBits(bits);
  const unhex = (str) => sjcl.codec.hex.toBits(str.replace(/^0x/, ""));
  const baseSetGlobalState = setGlobalState;
  let pairingSent = false;
  const sendPairing = () => {
    if (pairingSent || g_theState !== "SessionKeySet" || !g_secretSession?.encKey) return;
    if (ws?.readyState !== WebSocket.OPEN) return;
    pairingSent = true;
    send({
      pairing: {
        I: hex(g_secretSession.I.toBits()),
        encKey: hex(g_secretSession.encKey),
        protocolVersion: g_secretSession.protocolVersion,
        shouldUseBase64: g_secretSession.shouldUseBase64,
      },
    });
  };
  setGlobalState = function (state, quiet) {
    baseSetGlobalState(state, quiet);
    if (state !== "SessionKeySet") pairingSent = false;
    sendPairing();
  };
  const saved = self.APW_CONFIG.pairing;
  if (saved && g_secretSession) {
    g_secretSession.I = sjcl.bn.fromBits(unhex(saved.I));
    g_secretSession.encKey = unhex(saved.encKey);
    g_secretSession.protocolVersion = saved.protocolVersion;
    g_secretSession.shouldUseBase64 = saved.shouldUseBase64;
    baseSetGlobalState("SessionKeySet", true);
  }
  connect();
})();
