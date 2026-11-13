import { Xhshow, SessionManager } from '@ikenxuan/xhshow-ts';

// One JavaScript context is owned by one native session. Never log inputs.
const signer = new Xhshow();
const session = new SessionManager();
globalThis.newSearchID = () => signer.getSearchId();
globalThis.setSessionKey = (base64) => {
  session.setWebSsk(base64 ? { 'xhs-pc-web': base64 } : undefined);
};
globalThis.signRequest = (method, path, payloadJSON, cookiesJSON, xrap) => {
  const cookies = JSON.parse(cookiesJSON);
  const payload = JSON.parse(payloadJSON || '{}');
  const headers = method === 'GET'
    ? signer.signHeadersGet(path, cookies, 'xhs-pc-web', payload, undefined, session, 'xys', null, xrap)
    : signer.signHeadersPost(path, cookies, 'xhs-pc-web', payload, undefined, session, 'xys', null, xrap);
  return JSON.stringify({headers, body: method === 'POST' ? JSON.stringify(payload) : ''});
};
