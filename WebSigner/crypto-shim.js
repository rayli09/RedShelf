import * as crypto from './node_modules/@jspm/core/nodelibs/browser/crypto.js';
export const createCipheriv = crypto.createCipheriv;
export const createDecipheriv = crypto.createDecipheriv;
export const createHash = crypto.createHash;
export const randomBytes = crypto.randomBytes;
export function createPublicKey() { throw new Error('SSK exchange unavailable'); }
export function diffieHellman() { throw new Error('SSK exchange unavailable'); }
export function generateKeyPairSync() { throw new Error('SSK exchange unavailable'); }
