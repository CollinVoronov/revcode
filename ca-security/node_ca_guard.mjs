// Build-time trust store guard (eMudhra/emSign distrust, 2026-10-22).
// Fails the build if Node's bundled, default, or OS (system) root store still
// trusts a distrusted root, matched by SHA-256 of the full SubjectPublicKeyInfo
// (same definition and set as the fleet audit probe). Reads no env values or app data.
import crypto from 'node:crypto';
import fs from 'node:fs';
import tls from 'node:tls';

const BAD = new Set([
  'bd153ed7b0434f6886b17bce8bbe84ed340c7132d702a8f4fa318f756ecbd6f3',
  'c619e4780ed8e0abeda24ad732567de4383a7ea941338f6d1a7d1b49ac792fe9',
  '8d417db2dd8bf5e3084d1e3f196d583849d81bdd4c00c70b9d39369e96b8c782',
]);

const spki = (pem) => crypto.createHash('sha256')
  .update(new crypto.X509Certificate(pem).publicKey.export({ type: 'spki', format: 'der' }))
  .digest('hex');

const stores = { bundled: tls.rootCertificates };
for (const kind of ['default', 'system']) stores[kind] = tls.getCACertificates(kind);
// Also scan the OS bundle file directly when present (system store may be lazy-loaded).
const osBundle = '/etc/ssl/certs/ca-certificates.crt';
if (fs.existsSync(osBundle)) {
  stores.osBundle = fs.readFileSync(osBundle, 'utf8')
    .match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) || [];
}

let failed = false;
for (const [name, list] of Object.entries(stores)) {
  const hits = list.map(spki).filter((h) => BAD.has(h));
  console.log(`ca-guard ${name}: ${list.length} roots, ${hits.length} distrusted`);
  if (hits.length) failed = true;
}
if (failed) {
  console.error('ca-guard: distrusted root still trusted; refusing to build');
  process.exit(1);
}
